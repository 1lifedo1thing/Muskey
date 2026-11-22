import SwiftUI

/// A link or a file on a network volume that opens, as the HUD shows it until the song plays: the step that runs
/// with the part done, or a failure with the action that recovers from it.
struct OpeningState: Equatable {
    enum Recovery: Equatable {
        case retry
        case install
    }

    /// The step that runs, nil for a failure.
    var step: String?
    /// The title of the song once it is known, the site before that, or the name of the file.
    var name: String
    /// The part done, from 0 to 1, while it is known.
    var progress: Double?
    /// What a failure offers. A file that can't be played offers nothing.
    var recovery: Recovery?

    var failed: Bool { step == nil }

    /// Nil for the activities of a save, which the HUD shows in its own layout.
    init?(_ activity: OpenActivity?) {
        switch activity {
        case let .opening(step, name, progress):
            self.init(step: Self.title(step), name: name, progress: progress)
        case let .installing(progress):
            self.init(step: "Installing yt-dlp", name: "yt-dlp", progress: progress)
        case let .failed(name):
            self.init(step: nil, name: name, recovery: .retry)
        case let .needsDownloader(name):
            self.init(step: nil, name: name, recovery: .install)
        case .installFailed:
            self.init(step: nil, name: "yt-dlp", recovery: .retry)
        case let .unplayable(name):
            self.init(step: nil, name: name)
        default:
            return nil
        }
    }

    init(step: String?, name: String, progress: Double? = nil, recovery: Recovery? = nil) {
        self.step = step
        self.name = name
        self.progress = progress
        self.recovery = recovery
    }

    private static func title(_ step: OpenStep) -> String {
        switch step {
        case .reading: "Reading"
        case .downloading: "Downloading"
        case .converting: "Converting"
        case .updating: "Updating yt-dlp"
        }
    }
}

/// The HUD while a song opens. It keeps the shape of the layout that the song plays in next, so the glass doesn't
/// change twice: the step beside the empty platter in the wide layout, and under it on the card. A ring around the
/// platter fills with the part done, as the ring of a listen and of a save does.
struct OpeningView: View {
    let opening: OpeningState
    let card: Bool
    let palette: Palette
    let cancel: () -> Void
    let retry: () -> Void
    let install: () -> Void
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if card {
            VStack(spacing: 16) {
                OpeningRecord(opening: opening, side: 150, palette: palette)
                status(titleSize: 22)
                    // A failure is shorter than a step, and the glass keeps its height between them.
                    .frame(height: 92)
            }
            .padding(.top, 34)
            .padding(.bottom, 22)
            .padding(.horizontal, 24)
            .frame(width: 304)
        } else {
            HStack(spacing: 0) {
                status(titleSize: 32)
                    .frame(width: 300)
                Rectangle()
                    .fill(palette.ink.opacity(0.1))
                    .frame(width: 1)
                    .padding(.leading, 30)
                OpeningRecord(opening: opening, side: 166, palette: palette)
                    .padding(.leading, 30)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
        }
    }

    @ViewBuilder private func status(titleSize: CGFloat) -> some View {
        if let step = opening.step {
            VStack(spacing: 5) {
                // The title fills with the part done, as Listening does.
                ListenTitle(text: step, size: titleSize, progress: opening.progress, palette: palette)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 7) {
                    Text(opening.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let progress = opening.progress {
                        // Rounded down, so it never reads 100% before the end.
                        Text("\(Int((progress * 100).rounded(.down)))%")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(palette.ink)
                            .fixedSize()
                    }
                }
                OpeningButton(title: "Cancel", palette: palette, action: cancel)
                    .help("Stop opening the song")
                    .padding(.top, 9)
            }
        } else {
            // A failure says nothing about its cause: the red pill names what failed, with the action that recovers.
            HStack(spacing: 8) {
                Text(opening.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(StripColors.text(.red, colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch opening.recovery {
                case .retry: OpeningButton(title: "Retry", palette: palette, solid: StripColors.solid(.red, colorScheme), action: retry)
                case .install: OpeningButton(title: "Install yt-dlp", palette: palette, solid: StripColors.solid(.red, colorScheme), action: install)
                case nil: EmptyView()
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, opening.recovery == nil ? 14 : 5)
            .padding(.vertical, opening.recovery == nil ? 9 : 5)
            .background(Capsule().fill(StripColors.tint(.red, strong: false, colorScheme)))
            .overlay(alignment: .topLeading) {
                CloseButton(size: 14, help: "Dismiss", action: dismiss)
                    .offset(x: -4, y: -4)
            }
        }
    }
}

/// The empty platter inside the ring: the part done, an arc that turns while the part isn't known, and red all
/// around for a failure.
private struct OpeningRecord: View {
    let opening: OpeningState
    let side: CGFloat
    let palette: Palette

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renderingPreview) private var renderingPreview

    var body: some View {
        ZStack {
            EmptyPlatter(side: side)
            Circle().stroke(palette.ink.opacity(0.1), lineWidth: 3)
            if opening.failed {
                Circle().stroke(StripColors.solid(.red, colorScheme).fill, lineWidth: 3)
            } else if let progress = opening.progress {
                Circle()
                    .trim(from: 0, to: min(1, max(0.01, progress)))
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
            } else {
                TimelineView(.animation(paused: reduceMotion || renderingPreview)) { context in
                    Circle()
                        .trim(from: 0, to: 0.2)
                        .stroke(palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(renderingPreview ? 20 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                }
            }
        }
        .frame(width: side + 18, height: side + 18)
    }
}

/// Cancel, in the look of the buttons that open a file or a link, and Retry or Install yt-dlp solid in the red pill.
private struct OpeningButton: View {
    let title: String
    let palette: Palette
    var solid: (fill: Color, text: Color)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(solid?.text ?? palette.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, solid == nil ? 7 : 5)
                .background(Capsule().fill(solid.map { $0.fill.opacity(hovering ? 1 : 0.9) } ?? palette.ink.opacity(hovering ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
