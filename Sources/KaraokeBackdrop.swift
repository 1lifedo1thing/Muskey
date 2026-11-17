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

    /// Covers the screen of `panel` and fades in under it, or fades out. Karaoke opens with a short ease-out, and the
    /// way back is quicker.
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
            context.duration = shown ? 0.3 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = shown ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, !shown, alphaValue == 0 else { return }
            orderOut(nil)
        }
    }
}
