import AppKit
import CPrivateAPIs

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private static let barIdentifier = "com.mebin.touchbarcockpit.modal"
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.mebin.touchbarcockpit.root")

    private var touchBar: NSTouchBar!
    let cockpitView: CockpitView

    private(set) var isPresented: Bool = false

    override init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 1004, height: 30)
        self.cockpitView = CockpitView(frame: initialFrame)
        super.init()

        touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.itemIdentifier]
    }

    func present() {
        TBConfigureSystemModal(false)
        TBPresentSystemModalTouchBar(touchBar, Self.barIdentifier)
        isPresented = true
    }

    func dismiss() {
        TBDismissSystemModalTouchBar(touchBar)
        isPresented = false
    }

    func reattach() {
        guard isPresented else { return }
        TBConfigureSystemModal(false)
        TBPresentSystemModalTouchBar(touchBar, Self.barIdentifier)
    }

    func update(metrics: SystemMetrics) {
        cockpitView.update(metrics: metrics)
    }

    func updateWaveform(bands: [Float], isActive: Bool) {
        cockpitView.updateWaveform(bands: bands, isActive: isActive)
    }

    func triggerAgentFlash(agent: String) {
        cockpitView.triggerAgentFlash(agent: agent)
    }

    func clearWaitingAgent() {
        cockpitView.clearWaitingAgent()
    }

    // MARK: - NSTouchBarDelegate
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = cockpitView
        return item
    }
}
