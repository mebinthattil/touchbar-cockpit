import Foundation
import CoreAudio
import AudioToolbox
import CPrivateAPIs

final class AudioController {
    static let shared = AudioController()

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return (status == noErr && deviceID != 0) ? deviceID : nil
    }

    func getVolume() -> Float {
        guard let dev = defaultOutputDeviceID() else { return 0 }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &address),
           AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &vol) == noErr {
            return vol
        }

        // Fallback to channel 1 scalar
        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mElement = 1
        if AudioObjectHasProperty(dev, &address),
           AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &vol) == noErr {
            return vol
        }
        return 0
    }

    func setVolume(_ value: Float, showOSD: Bool = true) {
        guard let dev = defaultOutputDeviceID() else { return }
        var vol: Float32 = max(0.0, min(1.0, value))
        let size = UInt32(MemoryLayout<Float32>.size)

        // Unmute automatically if raising volume above 0
        if vol > 0.005 && isMuted() {
            setMuted(false)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &address) {
            AudioObjectSetPropertyData(dev, &address, 0, nil, size, &vol)
        } else {
            // Fallback to L/R channels
            address.mSelector = kAudioDevicePropertyVolumeScalar
            for ch: UInt32 in [1, 2] {
                address.mElement = ch
                if AudioObjectHasProperty(dev, &address) {
                    AudioObjectSetPropertyData(dev, &address, 0, nil, size, &vol)
                }
            }
        }

        if showOSD {
            TBShowVolumeOSD(vol, isMuted())
        }
    }

    func stepVolume(delta: Float) -> Float {
        if TBIsAccessibilityTrusted(false) {
            // Native macOS HID volume step (triggers real macOS 27 Control Center HUD)
            TBPostAuxKey(delta >= 0 ? 0 : 1, false)
            return getVolume()
        }
        let next = max(0.0, min(1.0, getVolume() + delta))
        setVolume(next, showOSD: true)
        return next
    }

    /// Fine-grained 1/64th native macOS HID volume step (triggers real macOS 27 HUD!)
    func nudgeVolumeFine(steps: Int) -> Float {
        guard steps != 0 else { return getVolume() }
        if TBIsAccessibilityTrusted(false) {
            let key: Int32 = steps > 0 ? 0 : 1 // NX_KEYTYPE_SOUND_UP=0, SOUND_DOWN=1
            let count = min(16, abs(steps))
            for _ in 0..<count {
                TBPostAuxKey(key, true)
            }
            return getVolume()
        }
        let next = max(0.0, min(1.0, getVolume() + Float(steps) / 64.0))
        setVolume(next, showOSD: true)
        return next
    }

    func isMuted() -> Bool {
        guard let dev = defaultOutputDeviceID() else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &address),
           AudioObjectGetPropertyData(dev, &address, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return false
    }

    func setMuted(_ muted: Bool) {
        guard let dev = defaultOutputDeviceID() else { return }
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &address) {
            AudioObjectSetPropertyData(dev, &address, 0, nil, size, &val)
        }
    }

    @discardableResult
    func toggleMute() -> Bool {
        if TBIsAccessibilityTrusted(false) {
            TBPostAuxKey(7, false) // NX_KEYTYPE_MUTE = 7 (triggers native macOS HUD)
            return !isMuted()
        }
        let next = !isMuted()
        setMuted(next)
        TBShowVolumeOSD(getVolume(), next)
        return next
    }
}
