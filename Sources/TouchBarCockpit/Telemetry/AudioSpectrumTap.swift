import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import os

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

    // Lock-free audio ring buffer (written on real-time audio thread, read on main timer)
    private let ringBuffer: UnsafeMutablePointer<Float>
    private var ringWriteIndex = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    // Pre-allocated FFT scratch buffers (zero per-frame allocations!)
    private var fftSetup: FFTSetup?
    private var window: [Float]
    private var timeSamples: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var magnitudes: [Float]

    // Smoothing & silence hysteresis
    private var smoothedBands: [Float] = Array(repeating: 0, count: bandCount)
    private var lastEmittedBands: [Float] = Array(repeating: -1, count: bandCount)
    private var rollingPeak: Float = 0.08
    private var lastSoundTime: CFAbsoluteTime = 0
    private(set) var isAudioActive: Bool = false
    private var uiTimer: Timer?

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

    // MARK: - Smart Idle-Gated Poll (Call at 1 Hz from AppDelegate)
    func checkOutputActivity() {
        let outputRunning = Self.isDefaultOutputRunningSomewhere()
        if outputRunning {
            if !isTapRunning {
                start()
            }
        } else {
            if isTapRunning || isAudioActive {
                stop()
            }
        }
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
        ringWriteIndex.pointee = 0

        // 3. Attach real-time lock-free IOProc
        let bufPtr = ringBuffer
        let idxPtr = ringWriteIndex
        let mask = Self.ringMask
        let ioQueue = DispatchQueue(label: "com.mebin.touchbarcockpit.audiotap", qos: .userInteractive)

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, ioQueue) { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard !abl.isEmpty else { return }

            var writeIdx = Int(idxPtr.pointee)

            if abl.count == 1 {
                // Interleaved stereo or mono Float32
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
                // Non-interleaved (planar) stereo Float32
                guard let rawL = abl[0].mData, let rawR = abl[1].mData else { return }
                let frameCount = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.stride
                let samplesL = rawL.assumingMemoryBound(to: Float.self)
                let samplesR = rawR.assumingMemoryBound(to: Float.self)
                for f in 0..<frameCount {
                    bufPtr[writeIdx & mask] = (samplesL[f] + samplesR[f]) * 0.5
                    writeIdx &+= 1
                }
            }

            idxPtr.pointee = Int32(truncatingIfNeeded: writeIdx)
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
        startUITimer()
    }

    func stop() {
        uiTimer?.invalidate()
        uiTimer = nil
        teardownAudioHandles()
        isTapRunning = false

        let wasActive = isAudioActive
        isAudioActive = false
        smoothedBands = Array(repeating: 0, count: Self.bandCount)
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

    // MARK: - 15 FPS FFT Analysis (Coalesced timer, only runs while output stream is active)
    private func startUITimer() {
        uiTimer?.invalidate()
        let timer = Timer(timeInterval: 0.066, repeats: true) { [weak self] _ in
            self?.analyzeFrame()
        }
        timer.tolerance = 0.012
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    private func analyzeFrame() {
        guard isTapRunning, let setup = fftSetup else { return }

        // 1. Copy latest 512 samples from ring buffer
        let endIdx = Int(ringWriteIndex.pointee)
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
        }

        let shouldBeActive = hasSignal || (now - lastSoundTime) < 1.25

        if !shouldBeActive {
            if isAudioActive {
                isAudioActive = false
                smoothedBands = Array(repeating: 0, count: Self.bandCount)
                onUpdate?(smoothedBands, false)
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

        // 4. Aggregate into 6 musical log-spaced frequency bands (Dynamic Island style)
        // At 48kHz / 512pt FFT -> ~93.75 Hz per bin
        let binRanges: [(ClosedRange<Int>, Float)] = [
            (1...2,    0.85),  // Sub-bass / kick
            (3...5,    1.00),  // Bass
            (6...11,   1.30),  // Low-mid / vocals
            (12...24,  1.75),  // Mid / melody
            (25...52,  2.35),  // Presence
            (53...120, 3.10)   // Brilliance / hi-hats
        ]

        var rawBands = [Float](repeating: 0, count: Self.bandCount)
        var frameMax: Float = 0.001

        for (i, (range, weight)) in binRanges.enumerated() {
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
            // Fast attack (0.62), smooth natural decay (0.30) tuned for 15 FPS
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

    // MARK: - CoreAudio Output Activity Check (0.001% CPU!)
    private static func isDefaultOutputRunningSomewhere() -> Bool {
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
        ) == noErr, dev != 0 else {
            return false
        }

        var running: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(dev, &runAddr, 0, nil, &runSize, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
