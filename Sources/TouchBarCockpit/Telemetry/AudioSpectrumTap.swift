import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import IOKit.pwr_mgt
import CPrivateAPIs

/// Ultra-lightweight native macOS 14.2+ CoreAudio Process Tap + 512-pt vDSP FFT
/// Produces 6 real-time frequency bands (Dynamic Island style) with ZERO virtual drivers
/// and 0.00% CPU when no audio is outputting.
final class AudioSpectrumTap {
    static let bandCount = 6
    private static let fftSize = 512
    private static let log2n = vDSP_Length(9) // 2^9 = 512
    private static let ringMask = 1023        // 1024-sample lock-free ring buffer

    // Callback fired on main thread at ~20 FPS only while audio is active (or on active state transitions)
    var onUpdate: ((_ bands: [Float], _ isActive: Bool) -> Void)?

    // CoreAudio handles
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isTapRunning: Bool = false
    private var activeOutputDeviceID: AudioDeviceID = 0
    private let ioQueue = DispatchQueue(label: "com.mebin.touchbarcockpit.audiotap", qos: .userInteractive)

    // Lock-free audio ring buffer (ARM64 release/acquire atomic cursor)
    private let ringBuffer: UnsafeMutablePointer<Float>
    private var ringWriteIndex = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    // Pre-allocated FFT scratch buffers (zero per-frame allocations!)
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var timeSamples: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var magnitudes: [Float]
    private var rawBands: [Float] = Array(repeating: 0, count: bandCount)

    private static let binRanges: [(ClosedRange<Int>, Float)] = [
        (1...2,    0.85),  // Sub-bass / kick
        (3...5,    1.00),  // Bass
        (6...11,   1.30),  // Low-mid / vocals
        (12...24,  1.75),  // Mid / melody
        (25...52,  2.35),  // Presence
        (53...120, 3.10)   // Brilliance / hi-hats
    ]

    // Smoothing & silence hysteresis
    private var smoothedBands: [Float] = Array(repeating: 0, count: bandCount)
    private var lastEmittedBands: [Float] = Array(repeating: -1, count: bandCount)
    private var rollingPeak: Float = 0.08
    private var tapStartTime: CFAbsoluteTime = 0
    private var lastSoundTime: CFAbsoluteTime = 0
    private(set) var isAudioActive: Bool = false
    private var isTimerInFastMode: Bool = false
    private var uiTimer: Timer?

    // Silent-holder suppression: if an app (e.g. a paused browser tab) holds an open silent
    // CoreAudio output stream (runOut == 1, RMS == 0), we tear down our CATap after a few seconds
    // so macOS clears the "System Audio Recording" privacy indicator & sleep assertion, and only
    // re-arm when a new process outputs audio, the stream restarts, or playback resumes.
    private var suppressedSilentPIDs: Set<pid_t> = []
    private var suppressedAssertionIDs: Set<Int> = []

    init() {
        ringBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.ringMask + 1)
        ringBuffer.initialize(repeating: 0, count: Self.ringMask + 1)
        ringWriteIndex.initialize(to: 0)

        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))

        timeSamples = [Float](repeating: 0, count: Self.fftSize)
        realBuf = [Float](repeating: 0, count: Self.fftSize / 2)
        imagBuf = [Float](repeating: 0, count: Self.fftSize / 2)
        magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
    }

    deinit {
        stop()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
        ringBuffer.deinitialize(count: Self.ringMask + 1)
        ringBuffer.deallocate()
        ringWriteIndex.deinitialize(count: 1)
        ringWriteIndex.deallocate()
    }

    // MARK: - Smart Idle-Gated Poll (Per-Process Output Tracking + Silence Auto-Teardown)
    func checkOutputActivity() {
        let devID = Self.defaultOutputDeviceID()
        let activeOutPIDs = Self.runningOutputProcessPIDs()

        // No OTHER process is outputting audio at all -> tear down tap immediately!
        // (Avoids self-sustaining loop where our own global CATap kept DeviceIsRunningSomewhere == 1.)
        if activeOutPIDs.isEmpty {
            suppressedSilentPIDs.removeAll()
            suppressedAssertionIDs.removeAll()
            if isTapRunning || isAudioActive {
                stop()
            }
            activeOutputDeviceID = 0
            return
        }

        // Default output device switched (e.g. Speakers <-> AirPods) -> clear suppression & restart cleanly
        if devID != 0 && activeOutputDeviceID != 0 && devID != activeOutputDeviceID {
            suppressedSilentPIDs.removeAll()
            suppressedAssertionIDs.removeAll()
            if isTapRunning {
                stop()
            }
        }

        // Prune any previously-silent PID that has since closed its audio output stream
        if !suppressedSilentPIDs.isEmpty {
            suppressedSilentPIDs.formIntersection(activeOutPIDs)
            if suppressedSilentPIDs.isEmpty {
                suppressedAssertionIDs.removeAll()
            }
        }

        // If all currently-running output PIDs were suppressed for digital silence, check whether
        // any of them opened a NEW CoreAudio stream assertion or video/media assertion (e.g. hit Play in browser)
        if !isTapRunning && !suppressedSilentPIDs.isEmpty {
            let currentIDs = Self.audioAssertionIDs(for: suppressedSilentPIDs)
            if !currentIDs.subtracting(suppressedAssertionIDs).isEmpty {
                suppressedSilentPIDs.removeAll()
                suppressedAssertionIDs.removeAll()
            }
        }

        let unsuppressed = activeOutPIDs.subtracting(suppressedSilentPIDs)
        if !unsuppressed.isEmpty && !isTapRunning {
            activeOutputDeviceID = devID
            start()
        }
    }

    /// Called when an external playback event occurs (e.g. Spotify/Apple Music notification or media play action)
    /// so any suppressed silent-holder PID is immediately re-checked.
    func nudgeWake() {
        suppressedSilentPIDs.removeAll()
        suppressedAssertionIDs.removeAll()
        checkOutputActivity()
    }

    // MARK: - Start / Stop CoreAudio Process Tap
    func start() {
        guard !isTapRunning else { return }
        guard #available(macOS 14.2, *) else { return }

        // 1. Create a passive global stereo tap (excludes nothing, never mutes output)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "TouchBarCockpitAudioTap"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            return
        }
        tapID = newTapID

        // 2. Create a lightweight private Aggregate Device containing ONLY our tap
        let tapUUID = desc.uuid.uuidString
        let aggUID = "com.mebin.touchbarcockpit.agg.\(UUID().uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TouchBarCockpitTapDevice",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggStatus == noErr, newAggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            return
        }
        aggregateDeviceID = newAggID

        // Reset ring buffer
        ringBuffer.update(repeating: 0, count: Self.ringMask + 1)
        TBAtomicStoreInt32(ringWriteIndex, 0)

        // 3. Attach real-time lock-free IOProc (ARM64 release/acquire memory ordering)
        let bufPtr = ringBuffer
        let idxPtr = ringWriteIndex
        let mask = Self.ringMask

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, ioQueue) { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !abl.isEmpty else { return }

            var writeIdx = Int(TBAtomicLoadInt32(idxPtr))

            if abl.count == 1 {
                let b = abl[0]
                guard let raw = b.mData else { return }
                let channels = max(1, Int(b.mNumberChannels))
                let floatCount = Int(b.mDataByteSize) / MemoryLayout<Float>.stride
                let frameCount = floatCount / channels
                let samples = raw.assumingMemoryBound(to: Float.self)

                if channels >= 2 {
                    for f in 0..<frameCount {
                        let base = f * channels
                        let mono = (samples[base] + samples[base + 1]) * 0.5
                        bufPtr[writeIdx & mask] = mono
                        writeIdx &+= 1
                    }
                } else {
                    for f in 0..<frameCount {
                        bufPtr[writeIdx & mask] = samples[f]
                        writeIdx &+= 1
                    }
                }
            } else {
                guard let rawL = abl[0].mData, let rawR = abl[1].mData else { return }
                let frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.stride
                let samplesL = rawL.assumingMemoryBound(to: Float.self)
                let samplesR = rawR.assumingMemoryBound(to: Float.self)
                for f in 0..<frameCount {
                    bufPtr[writeIdx & mask] = (samplesL[f] + samplesR[f]) * 0.5
                    writeIdx &+= 1
                }
            }

            TBAtomicStoreInt32(idxPtr, Int32(truncatingIfNeeded: writeIdx))
        }

        guard procStatus == noErr, let procID = newProcID else {
            teardownAudioHandles()
            return
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            teardownAudioHandles()
            return
        }

        isTapRunning = true
        tapStartTime = CFAbsoluteTimeGetCurrent()
        lastSoundTime = 0
        setUITimerCadence(fast: true)
    }

    func stop() {
        uiTimer?.invalidate()
        uiTimer = nil
        isTimerInFastMode = false
        teardownAudioHandles()
        isTapRunning = false

        let wasActive = isAudioActive
        isAudioActive = false
        smoothedBands = Array(repeating: 0, count: Self.bandCount)
        lastEmittedBands = Array(repeating: -1, count: Self.bandCount)
        if wasActive {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onUpdate?(self.smoothedBands, false)
            }
        }
    }

    private func teardownAudioHandles() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateDeviceID, procID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Adaptive FFT Analysis (15 FPS while playing, drops to 2 Hz when paused/silent!)
    private func setUITimerCadence(fast: Bool) {
        if uiTimer != nil && isTimerInFastMode == fast { return }
        uiTimer?.invalidate()
        isTimerInFastMode = fast
        let interval: TimeInterval = fast ? 0.066 : 0.5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.analyzeFrame()
        }
        timer.tolerance = fast ? 0.012 : 0.1
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    private func analyzeFrame() {
        guard isTapRunning, let setup = fftSetup else { return }

        // 1. Copy latest 512 samples from ring buffer (ARM64 acquire load)
        let endIdx = Int(TBAtomicLoadInt32(ringWriteIndex))
        let n = Self.fftSize
        let mask = Self.ringMask
        let startIdx = endIdx &- n
        for i in 0..<n {
            timeSamples[i] = ringBuffer[(startIdx &+ i) & mask]
        }

        // 2. Compute RMS energy to detect real audio vs silent paused stream
        var rms: Float = 0
        vDSP_rmsqv(timeSamples, 1, &rms, vDSP_Length(n))

        let now = CFAbsoluteTimeGetCurrent()
        let hasSignal = rms > 0.0016
        if hasSignal {
            lastSoundTime = now
            if !isTimerInFastMode {
                setUITimerCadence(fast: true)
            }
        }

        let shouldBeActive = hasSignal || (lastSoundTime > 0 && (now - lastSoundTime) < 1.25)

        if !shouldBeActive {
            if isAudioActive {
                isAudioActive = false
                smoothedBands = Array(repeating: 0, count: Self.bandCount)
                lastEmittedBands = Array(repeating: -1, count: Self.bandCount)
                onUpdate?(smoothedBands, false)
            }
            if isTimerInFastMode {
                setUITimerCadence(fast: false)
            }

            // Tear down the CoreAudio Process Tap completely after sustained digital silence so macOS
            // turns OFF the "System Audio Recording" indicator and releases the coreaudiod sleep assertion.
            let silentFor = lastSoundTime > 0 ? (now - lastSoundTime) : (now - tapStartTime)
            let teardownThreshold: CFAbsoluteTime = lastSoundTime > 0 ? 6.0 : 4.0
            if silentFor >= teardownThreshold {
                let silentPIDs = Self.runningOutputProcessPIDs()
                if !silentPIDs.isEmpty {
                    suppressedSilentPIDs.formUnion(silentPIDs)
                    suppressedAssertionIDs = Self.audioAssertionIDs(for: suppressedSilentPIDs)
                }
                stop()
            }
            return
        }

        isAudioActive = true

        // 3. Apply Hann window & run 512-point real FFT via Apple Accelerate (vDSP)
        vDSP_vmul(timeSamples, 1, window, 1, &timeSamples, 1, vDSP_Length(n))

        let halfN = n / 2
        realBuf.withUnsafeMutableBufferPointer { rPtr in
            imagBuf.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                timeSamples.withUnsafeBufferPointer { tPtr in
                    tPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Scale magnitudes to amplitude
        var scale = Float(1.0 / Float(n))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))

        // 4. Aggregate into 6 musical log-spaced frequency bands (zero per-frame allocations!)
        var frameMax: Float = 0.001

        for (i, (range, weight)) in Self.binRanges.enumerated() {
            var sum: Float = 0
            var cnt: Float = 0
            for b in range where b < halfN {
                sum += sqrtf(max(0, magnitudes[b]))
                cnt += 1
            }
            let avg = cnt > 0 ? (sum / cnt) * weight : 0
            rawBands[i] = avg
            if avg > frameMax { frameMax = avg }
        }

        // Adaptive auto-gain so both soft songs and loud drops dance cleanly without clipping
        if frameMax > rollingPeak {
            rollingPeak = rollingPeak * 0.70 + frameMax * 0.30
        } else {
            rollingPeak = max(0.035, rollingPeak * 0.985 + frameMax * 0.015)
        }

        var changed = false
        for i in 0..<Self.bandCount {
            let norm = min(1.0, max(0.0, powf(rawBands[i] / max(0.025, rollingPeak * 1.15), 0.72)))
            let target = hasSignal ? norm : 0.0
            let prev = smoothedBands[i]
            let alpha: Float = target > prev ? 0.62 : 0.30
            let next = prev + (target - prev) * alpha
            smoothedBands[i] = next
            if abs(next - lastEmittedBands[i]) > 0.008 {
                changed = true
            }
        }

        if changed {
            lastEmittedBands = smoothedBands
            onUpdate?(smoothedBands, true)
        }
    }

    // MARK: - CoreAudio Per-Process Output Activity & Device ID Check (Zero Self-Triggering)
    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var dev = AudioDeviceID(0)
        var devSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devAddr,
            0,
            nil,
            &devSize,
            &dev
        ) == noErr else {
            return 0
        }
        return dev
    }

    /// Returns PIDs of OTHER processes currently running CoreAudio output (strictly excluding ourselves).
    private static func runningOutputProcessPIDs() -> Set<pid_t> {
        let selfPID = getpid()
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &byteSize
        ) == noErr, byteSize > 0 else {
            return []
        }

        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var procObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr,
            0,
            nil,
            &byteSize,
            &procObjects
        ) == noErr else {
            return []
        }

        var result: Set<pid_t> = []
        var runOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for obj in procObjects {
            var runOut: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(obj, &runOutAddr, 0, nil, &runSize, &runOut) == noErr,
                  runOut != 0 else {
                continue
            }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
               pid > 0, pid != selfPID {
                result.insert(pid)
            }
        }
        return result
    }

    /// Snapshots IOKit power assertion IDs associated with suppressed silent-holder PIDs
    /// (both coreaudiod output assertions on behalf of the PID and browser media/video display-sleep assertions).
    private static func audioAssertionIDs(for targetPIDs: Set<pid_t>) -> Set<Int> {
        guard !targetPIDs.isEmpty else { return [] }
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess,
              let dict = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
            return []
        }

        var ids: Set<Int> = []
        for (ownerNum, assertions) in dict {
            let ownerPID = pid_t(ownerNum.int32Value)
            for a in assertions {
                guard let assertID = a["AssertionId"] as? Int else { continue }
                if let behalfPID = a["AssertionOnBehalfOfPID"] as? Int,
                   targetPIDs.contains(pid_t(behalfPID)) {
                    ids.insert(assertID)
                    continue
                }
                if targetPIDs.contains(ownerPID) {
                    let assertType = a["AssertType"] as? String ?? ""
                    let assertName = (a["AssertName"] as? String ?? "").lowercased()
                    if assertType == "PreventUserIdleDisplaySleep" ||
                       assertType == "NoDisplaySleepAssertion" ||
                       assertName.contains("video") ||
                       assertName.contains("audio") ||
                       assertName.contains("media") ||
                       assertName.contains("playing") {
                        ids.insert(assertID)
                    }
                }
            }
        }
        return ids
    }
}
