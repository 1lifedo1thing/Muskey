import AppKit

/// Blurs and dims the screen around the karaoke glass, so that only the lyrics stand out. It sits right below the HUD
/// panel, over everything else on the HUD's screen, the menu bar included. A click on it closes karaoke.
final class KaraokeBackdrop: NSPanel {
    var onClick: () -> Void = {}

    private final class ClickView: NSView {
        var onClick: () -> Void = {}
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
        override func mouseDown(with _: NSEvent) { onClick() }
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        alphaValue = 0

        let view = ClickView()
        view.onClick = { [weak self] in self?.onClick() }
        // The dark blur reads the same over a light or a dark desktop.
        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        let dim = NSView()
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        dim.autoresizingMask = [.width, .height]
        view.addSubview(blur)
        view.addSubview(dim)
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    /// The screen that the backdrop covers.
    var coveredFrame: CGRect { frame }

    /// Covers the screen of `panel` and fades in under it, or fades out, quickly both ways, since a key or a click
    /// opens karaoke.
    func show(_ shown: Bool, below panel: NSWindow) {
        if shown {
            let screen = panel.screen ?? NSScreen.main
            if let frame = screen?.frame, frame != self.frame {
                setFrame(frame, display: false)
                contentView?.subviews.forEach { $0.frame = contentView?.bounds ?? frame }
            }
            if !isVisible { order(.below, relativeTo: panel.windowNumber) }
        } else if !isVisible {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.15 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = shown ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !shown, alphaValue == 0 else { return }
            orderOut(nil)
        }
    }
}

/// The backdrop of karaoke on the HUD's screen. A HUD moved to another screen takes the blur with it: the backdrop fades
/// out on the old screen while a second one fades in on the new screen.
final class KaraokeBackdrops {
    var onClick: () -> Void = {} {
        didSet { panels.forEach { $0.onClick = onClick } }
    }

    private let panels = [KaraokeBackdrop(), KaraokeBackdrop()]
    private var current = 0
    private var shown = false

    func show(_ on: Bool, below panel: NSWindow) {
        shown = on
        panels[current].show(on, below: panel)
    }

    /// The HUD moved. A backdrop that shows on another screen than the HUD's swaps to the HUD's screen.
    func follow(_ panel: NSWindow) {
        guard shown, let screen = panel.screen, screen.frame != panels[current].coveredFrame else { return }
        panels[current].show(false, below: panel)
        current = 1 - current
        panels[current].show(true, below: panel)
    }
}
