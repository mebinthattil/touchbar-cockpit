import AppKit

/// Faithful 1:1 recreation of the user's original Expanded Control Strip layout,
/// shown instantaneously while holding the Fn key:
/// [Bright- | Bright+] [Screenshot] [Kbd- | Kbd+] [Prev | Play | Next] [Mute | Vol- | Vol+] [Siri] [Lock]
final class ClassicStripView: NSView {
    private enum Action {
        case brightnessDown
        case brightnessUp
        case screenshot
        case keyboardDown
        case keyboardUp
        case mediaPrev
        case mediaPlayPause
        case mediaNext
        case volumeMute
        case volumeDown
        case volumeUp
        case siri
        case lockScreen
    }

    private struct ButtonSpec {
        let action: Action
        let symbol: String
        let groupIndex: Int
        let repeatable: Bool
        let isSiri: Bool
    }

    private let buttons: [ButtonSpec] = [
        // Group 0: Display Brightness
        ButtonSpec(action: .brightnessDown, symbol: "sun.min.fill", groupIndex: 0, repeatable: true, isSiri: false),
        ButtonSpec(action: .brightnessUp,   symbol: "sun.max.fill", groupIndex: 0, repeatable: true, isSiri: false),
        // Group 1: Screenshot
        ButtonSpec(action: .screenshot,     symbol: "camera.fill",  groupIndex: 1, repeatable: false, isSiri: false),
        // Group 2: Keyboard Backlight
        ButtonSpec(action: .keyboardDown,   symbol: "light.min",    groupIndex: 2, repeatable: true, isSiri: false),
        ButtonSpec(action: .keyboardUp,     symbol: "light.max",    groupIndex: 2, repeatable: true, isSiri: false),
        // Group 3: Media
        ButtonSpec(action: .mediaPrev,      symbol: "backward.fill",  groupIndex: 3, repeatable: false, isSiri: false),
        ButtonSpec(action: .mediaPlayPause, symbol: "play.fill",      groupIndex: 3, repeatable: false, isSiri: false),
        ButtonSpec(action: .mediaNext,      symbol: "forward.fill",   groupIndex: 3, repeatable: false, isSiri: false),
        // Group 4: Volume
        ButtonSpec(action: .volumeMute,     symbol: "speaker.slash.fill",  groupIndex: 4, repeatable: false, isSiri: false),
        ButtonSpec(action: .volumeDown,     symbol: "speaker.wave.1.fill", groupIndex: 4, repeatable: true, isSiri: false),
        ButtonSpec(action: .volumeUp,       symbol: "speaker.wave.3.fill", groupIndex: 4, repeatable: true, isSiri: false),
        // Group 5: Siri
        ButtonSpec(action: .siri,           symbol: "circle.fill",    groupIndex: 5, repeatable: false, isSiri: true),
        // Group 6: Lock Screen
        ButtonSpec(action: .lockScreen,     symbol: "lock.rectangle.fill", groupIndex: 6, repeatable: false, isSiri: false)
    ]

    private var pressedIndex: Int? = nil
    private var repeatTimer: Timer?
    private var cachedRects: [NSRect] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = [.direct]
        wantsRestingTouches = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }

    // MARK: - Layout
    private func computeButtonRects() -> [NSRect] {
        let count = buttons.count
        guard count > 0, bounds.width > 0 else { return [] }

        let outerPad: CGFloat = 10
        let groupGap: CGFloat = 12
        let intraGap: CGFloat = 1.5

        var totalGaps: CGFloat = outerPad * 2
        for i in 1..<count {
            if buttons[i].groupIndex != buttons[i - 1].groupIndex {
                totalGaps += groupGap
            } else {
                totalGaps += intraGap
            }
        }

        let btnW = (bounds.width - totalGaps) / CGFloat(count)
        let btnH: CGFloat = bounds.height - 2
        let y: CGFloat = 1

        var rects: [NSRect] = []
        var x = outerPad
        for i in 0..<count {
            if i > 0 {
                x += (buttons[i].groupIndex != buttons[i - 1].groupIndex) ? groupGap : intraGap
            }
            rects.append(NSRect(x: x, y: y, width: btnW, height: btnH))
            x += btnW
        }
        return rects
    }

    // MARK: - Touch Handling
    override func touchesBegan(with event: NSEvent) {
        guard let touch = event.touches(matching: .touching, in: self).first else { return }
        let pt = touch.location(in: self)
        let rects = computeButtonRects()
        cachedRects = rects

        if let idx = rects.firstIndex(where: { $0.contains(pt) }) {
            pressedIndex = idx
            needsDisplay = true

            let spec = buttons[idx]
            perform(spec.action)

            repeatTimer?.invalidate()
            if spec.repeatable {
                let timer = Timer(timeInterval: 0.14, repeats: true) { [weak self] _ in
                    guard let self = self, self.pressedIndex == idx else { return }
                    self.perform(spec.action)
                }
                RunLoop.main.add(timer, forMode: .common)
                repeatTimer = timer
            }
        }
    }

    override func touchesEnded(with event: NSEvent) {
        clearPress()
    }

    override func touchesCancelled(with event: NSEvent) {
        clearPress()
    }

    func clearPress() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        if pressedIndex != nil {
            pressedIndex = nil
            needsDisplay = true
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .brightnessDown:
            BrightnessController.shared.stepDisplayBrightness(delta: -0.0625)
        case .brightnessUp:
            BrightnessController.shared.stepDisplayBrightness(delta: 0.0625)
        case .screenshot:
            BrightnessController.shared.triggerScreenshot()
        case .keyboardDown:
            BrightnessController.shared.stepKeyboardBrightness(delta: -0.1)
        case .keyboardUp:
            BrightnessController.shared.stepKeyboardBrightness(delta: 0.1)
        case .mediaPrev:
            BrightnessController.shared.mediaPrevious()
        case .mediaPlayPause:
            BrightnessController.shared.mediaPlayPause()
        case .mediaNext:
            BrightnessController.shared.mediaNext()
        case .volumeMute:
            AudioController.shared.toggleMute()
        case .volumeDown:
            _ = AudioController.shared.stepVolume(delta: -0.0625)
        case .volumeUp:
            _ = AudioController.shared.stepVolume(delta: 0.0625)
        case .siri:
            BrightnessController.shared.triggerSiri()
        case .lockScreen:
            BrightnessController.shared.lockScreen()
        }
    }

    // MARK: - Drawing (Apple Classic Control Strip Aesthetic)
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        let rects = computeButtonRects()
        cachedRects = rects

        for (i, spec) in buttons.enumerated() {
            let r = rects[i]
            let isPressed = (pressedIndex == i)

            // Determine rounded corners based on position inside group
            let prevSame = (i > 0 && buttons[i - 1].groupIndex == spec.groupIndex)
            let nextSame = (i < buttons.count - 1 && buttons[i + 1].groupIndex == spec.groupIndex)

            let pillPath = roundedRectPath(
                rect: r,
                topLeft: prevSame ? 1.5 : 6.0,
                bottomLeft: prevSame ? 1.5 : 6.0,
                topRight: nextSame ? 1.5 : 6.0,
                bottomRight: nextSame ? 1.5 : 6.0
            )

            ctx.saveGState()
            let bg = isPressed
                ? NSColor(calibratedWhite: 0.42, alpha: 1.0)
                : NSColor(calibratedWhite: 0.22, alpha: 1.0)
            ctx.setFillColor(bg.cgColor)
            ctx.addPath(pillPath)
            ctx.fillPath()
            ctx.restoreGState()

            if spec.isSiri {
                drawSiriOrb(ctx: ctx, center: CGPoint(x: r.midX, y: r.midY), radius: 8.5)
            } else {
                drawSymbol(spec.symbol, in: r)
            }
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        let styled = base.withSymbolConfiguration(cfg) ?? base

        let img = styled.copy() as! NSImage
        img.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false

        let sz = img.size
        img.draw(in: NSRect(
            x: rect.midX - sz.width / 2.0,
            y: rect.midY - sz.height / 2.0,
            width: sz.width,
            height: sz.height
        ))
    }

    private func drawSiriOrb(ctx: CGContext, center: CGPoint, radius: CGFloat) {
        ctx.saveGState()
        let orbRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ctx.addEllipse(in: orbRect)
        ctx.clip()

        let colors = [
            NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.99, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.54, green: 0.28, blue: 0.96, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.96, green: 0.28, blue: 0.62, alpha: 1.0).cgColor
        ] as CFArray
        let locs: [CGFloat] = [0.0, 0.55, 1.0]
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: orbRect.minX, y: orbRect.maxY),
                end: CGPoint(x: orbRect.maxX, y: orbRect.minY),
                options: []
            )
        }

        // Specular glow highlight
        let glowColors = [
            NSColor.white.withAlphaComponent(0.75).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor
        ] as CFArray
        if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1]) {
            ctx.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: center.x - 2, y: center.y + 2),
                startRadius: 0.5,
                endCenter: center,
                endRadius: radius,
                options: []
            )
        }
        ctx.restoreGState()
    }

    private func roundedRectPath(rect: NSRect, topLeft: CGFloat, bottomLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let minX = rect.minX, maxX = rect.maxX
        let minY = rect.minY, maxY = rect.maxY

        path.move(to: CGPoint(x: minX + bottomLeft, y: minY))
        path.addLine(to: CGPoint(x: maxX - bottomRight, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + bottomRight), radius: bottomRight)
        path.addLine(to: CGPoint(x: maxX, y: maxY - topRight))
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - topRight, y: maxY), radius: topRight)
        path.addLine(to: CGPoint(x: minX + topLeft, y: maxY))
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - topLeft), radius: topLeft)
        path.addLine(to: CGPoint(x: minX, y: minY + bottomLeft))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + bottomLeft, y: minY), radius: bottomLeft)
        path.closeSubpath()
        return path
    }
}
