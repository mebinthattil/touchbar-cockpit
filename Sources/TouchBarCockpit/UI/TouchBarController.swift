import AppKit
import CPrivateAPIs

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private static let barIdentifier = "com.mebin.touchbarcockpit.modal"
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.mebin.touchbarcockpit.root")

    private var touchBar: NSTouchBar!
    private let containerView: NSView
    let cockpitView: CockpitView
    let classicStripView: ClassicStripView

    private(set) var isPresented: Bool = false
    private(set) var isShowingClassicStrip: Bool = false

    override init() {
        let initialFrame = NSRect(x: 0, y: 0, width: 1004, height: 30)
        self.containerView = NSView(frame: initialFrame)
        self.cockpitView = CockpitView(frame: initialFrame)
        self.classicStripView = ClassicStripView(frame: initialFrame)
        super.init()

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.black.cgColor

        for sub in [cockpitView, classicStripView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                sub.topAnchor.constraint(equalTo: containerView.topAnchor),
                sub.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }
        classicStripView.isHidden = true

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

    func setClassicStripVisible(_ visible: Bool) {
        guard visible != isShowingClassicStrip else { return }
        isShowingClassicStrip = visible
        if !visible {
            classicStripView.clearPress()
        }
        cockpitView.isHidden = visible
        classicStripView.isHidden = !visible
        if visible {
            classicStripView.needsDisplay = true
        } else {
            cockpitView.needsDisplay = true
        }
    }

    func toggleClassicStrip() {
        setClassicStripVisible(!isShowingClassicStrip)
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

    // MARK: - NSTouchBarDelegate
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = containerView
        return item
    }
}
