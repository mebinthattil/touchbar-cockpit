import Foundation
import CPrivateAPIs

final class BrightnessController {
    static let shared = BrightnessController()

    func getDisplayBrightness() -> Float {
        var val: Float = 0.5
        if TBGetDisplayBrightness(&val) {
            return val
        }
        return 0.5
    }

    @discardableResult
    func setDisplayBrightness(_ value: Float, showOSD: Bool = true) -> Float {
        let clamped = max(0.0, min(1.0, value))
        TBSetDisplayBrightness(clamped)
        if showOSD {
            TBShowBrightnessOSD(clamped)
        }
        return clamped
    }

    @discardableResult
    func stepDisplayBrightness(delta: Float) -> Float {
        if TBIsAccessibilityTrusted(false) {
            TBPostAuxKey(delta >= 0 ? 2 : 3, false) // NX_KEYTYPE_BRIGHTNESS_UP=2, DOWN=3
            return getDisplayBrightness()
        }
        return setDisplayBrightness(getDisplayBrightness() + delta, showOSD: true)
    }

    /// Fine-grained 1/64th native macOS HID brightness step (triggers real macOS 27 HUD!)
    @discardableResult
    func nudgeDisplayBrightnessFine(steps: Int) -> Float {
        guard steps != 0 else { return getDisplayBrightness() }
        if TBIsAccessibilityTrusted(false) {
            let key: Int32 = steps > 0 ? 2 : 3 // NX_KEYTYPE_BRIGHTNESS_UP=2, DOWN=3
            let count = min(16, abs(steps))
            for _ in 0..<count {
                TBPostAuxKey(key, true)
            }
            return getDisplayBrightness()
        }
        return setDisplayBrightness(getDisplayBrightness() + Float(steps) / 64.0, showOSD: true)
    }

    func stepKeyboardBrightness(delta: Float) {
        if TBIsAccessibilityTrusted(false) {
            TBPostAuxKey(delta >= 0 ? 21 : 22, false) // NX_KEYTYPE_ILLUMINATION_UP=21, DOWN=22
            return
        }
        TBStepKeyboardBrightness(delta)
        TBShowKeyboardBrightnessOSD(TBGetKeyboardBrightness())
    }

    // Standard macOS HID Media Key constants
    func mediaPlayPause() { TBPostMediaKey(16) } // NX_KEYTYPE_PLAY
    func mediaNext()      { TBPostMediaKey(19) } // NX_KEYTYPE_FAST
    func mediaPrevious()  { TBPostMediaKey(20) } // NX_KEYTYPE_REWIND

    func triggerScreenshot() { TBTriggerScreenshotUI() }
    func triggerSiri()       { TBTriggerSiri() }
    func lockScreen()        { TBLockScreenImmediate() }
}
