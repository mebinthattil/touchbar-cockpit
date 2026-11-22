import Foundation
import IOKit.pwr_mgt

final class KeepAwakeManager {
    static let shared = KeepAwakeManager()

    private var assertionID: IOPMAssertionID = 0
    private(set) var isActive: Bool = false

    @discardableResult
    func toggle() -> Bool {
        if isActive {
            disable()
        } else {
            enable()
        }
        return isActive
    }

    func enable() {
        guard !isActive else { return }
        let reason = "TouchBarCockpit Keep-Awake" as CFString
        let res = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if res == kIOReturnSuccess {
            isActive = true
        }
    }

    func disable() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    deinit {
        disable()
    }
}
