import AppKit
import SwiftUI

/// A pill at the top right of the screen for a song that Muskey opens: a link that downloads, with its progress, or a
/// failure, in red, with the action that recovers from it and a button that dismisses it. A song that plays opens the
/// HUD, which takes the pill's place.
final class ActivityPill {
    var onRetry: () -> Void = {}
    var onInstall: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onReveal: () -> Void = {}

    private let model = ActivityPillModel()
    private static let size = CGSize(width: 460, height: 64)

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The transparent part of the panel lets clicks through to what is under it.
        panel.contentView = FirstClickHostingView(rootView: ActivityPillView(model: model))
        return panel
    }()

    init() {
        model.retry = { [weak self] in self?.onRetry() }
        model.install = { [weak self] in self?.onInstall() }
        model.reveal = { [weak self] in self?.onReveal() }
        model.dismiss = { [weak self] in
            self?.show(nil)
            self?.onDismiss()
        }
    }

    func show(_ activity: OpenActivity?) {
        let shown = model.activity != nil
        model.activity = activity
        guard activity != nil else {
            guard shown else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) { [weak self] in
                guard let self, model.activity == nil else { return }
                panel.orderOut(nil)
            }
            return
        }
        guard !shown || !panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - 8, y: visible.maxY - Self.size.height - 4))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
    }
}

final class ActivityPillModel: ObservableObject {
    @Published var activity: OpenActivity?
    var retry: () -> Void = {}
    var install: () -> Void = {}
    var dismiss: () -> Void = {}
    var reveal: () -> Void = {}
}

struct ActivityPillView: View {
    @ObservedObject var model: ActivityPillModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.renderingPreview) private var renderingPreview

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if let activity = model.activity {
                pill(activity)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.15), value: model.activity)
    }

    @ViewBuilder private func pill(_ activity: OpenActivity) -> some View {
        switch activity {
        case let .downloading(name, progress):
            working(name, progress: progress)
        case let .installing(progress):
            working("yt-dlp", progress: progress)
        case let .failed(name):
            failure(name) { button("Retry", action: model.retry) }
        case let .needsDownloader(name):
            failure(name) { button("Install yt-dlp", action: model.install) }
        case .installFailed:
            failure("yt-dlp") { button("Retry", action: model.retry) }
        case let .unplayable(name):
            failure(name) { EmptyView() }
        case let .saving(name, progress):
            working("Saving \(name)", progress: progress)
        case let .recording(name, left, progress):
            working("Recording \(name)", progress: progress, detail: left)
        case let .saved(name):
            done("\(name) saved") { button("Show in Finder", action: model.reveal) }
        case let .saveFailed(name):
            failure("Saving \(name) failed") { button("Retry", action: model.retry) }
        }
    }

    private func working(_ name: String, progress: Double?, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            ProgressRing(progress: progress)
                .frame(width: 14, height: 14)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            // Rounded down, as on the HUD's save layout, so the two agree and neither reads 100% before the end.
            if let detail = detail ?? progress.map({ "\(Int(($0 * 100).rounded(.down)))%" }) {
                Text(detail)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(PillGlass(preview: renderingPreview, scheme: colorScheme))
    }

    private func failure(_ name: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(StripColors.text(.red, colorScheme))
            action()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Capsule().fill(StripColors.tint(.red, strong: false, colorScheme)))
        .modifier(PillGlass(preview: renderingPreview, scheme: colorScheme))
        .overlay(alignment: .topLeading) {
            CloseButton(size: 13, action: model.dismiss)
                .offset(x: -4, y: -4)
        }
    }

    /// Work that finished, with the action that follows from it and a button that dismisses the pill.
    private func done(_ text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(StripColors.text(.sage, colorScheme))
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            action()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .modifier(PillGlass(preview: renderingPreview, scheme: colorScheme))
        .overlay(alignment: .topLeading) {
            CloseButton(size: 13, action: model.dismiss)
                .offset(x: -4, y: -4)
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .controlSize(.small)
            .buttonBorderShape(.capsule)
    }
}

/// Glass around the pill. ImageRenderer draws neither glass nor what sits inside it, so `--render` gets a flat stand-in.
private struct PillGlass: ViewModifier {
    let preview: Bool
    let scheme: ColorScheme

    func body(content: Content) -> some View {
        if preview {
            content.background(Capsule().fill(scheme == .dark ? Color(white: 0.2) : Color(white: 0.97)).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
        } else {
            content.glassEffect(in: Capsule())
        }
    }
}

/// How much of a download is done, or a turning arc while that isn't known.
private struct ProgressRing: View {
    let progress: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 2)
            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
            } else {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            }
        }
    }
}
