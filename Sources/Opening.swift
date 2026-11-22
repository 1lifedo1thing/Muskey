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
    /// The artist of the song once yt-dlp names it.
    var artist: String?
    /// The part done, from 0 to 1, while it is known.
    var progress: Double?
    /// What a failure offers. A file that can't be played offers nothing.
    var recovery: Recovery?

    var failed: Bool { step == nil }

    /// Nil for the activities of a save, which the HUD shows in its own layout.
    init?(_ activity: OpenActivity?) {
        switch activity {
        case let .opening(step, name, artist, progress):
            self.init(step: Self.title(step), name: name, artist: artist, progress: progress)
        case let .installing(progress):
            // The step names what installs, so nothing repeats it under the title.
            self.init(step: "Installing yt-dlp", name: "", progress: progress)
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

    init(step: String?, name: String, artist: String? = nil, progress: Double? = nil, recovery: Recovery? = nil) {
        self.step = step
        self.name = name
        self.artist = artist
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

/// The song that plays while another one opens: its record stays where it was and keeps turning.
struct OpeningDeck {
    let track: NowPlaying.Track
    let artwork: NSImage?
    let playing: Bool
    let spinning: Bool
    var flash: PlayFlash?
    /// The size of the glass before the song started to open, while the HUD showed the record. The glass keeps it, so
    /// the record stays at the same place.
    var glass: CGSize?
    /// The card shows the inner ring of keys, with a smaller record inside it.
    var relativeKeys = false
}

/// The HUD while a song opens. It keeps the shape of the layout that the song plays in next, so the glass doesn't
/// change twice: the step beside the record in the wide layout, and under it on the card. While nothing plays, the
/// platter is empty, and a ring around it fills with the part done, as the ring of a listen and of a save does.
/// While a song plays, its record keeps turning without a ring, which would read as the progress of that song, and
/// a bar under the name of the song that opens fills instead.
struct OpeningView: View {
    let opening: OpeningState
    let card: Bool
    let palette: Palette
    var deck: OpeningDeck?
    let cancel: () -> Void
    let background: () -> Void
    let retry: () -> Void
    let install: () -> Void
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// The card of a song that plays: its record and the ring of keys around it, in `HUDCard`.
    private var cardRecord: CGFloat { deck?.relativeKeys == true ? 136 : 160 }
    private var cardRing: CGFloat { deck?.relativeKeys == true ? 304 : 260 }

    var body: some View {
        if card, let deck {
            // The record where `HUDCard` has it, with the room of the ring of keys around it.
            VStack(spacing: 0) {
                RecordDisc(track: deck.track, artwork: deck.artwork, spinning: deck.spinning, side: cardRecord, flash: deck.flash)
                    .frame(width: cardRing, height: cardRing)
                status(titleSize: 22)
                    .frame(height: 118)
                    .frame(maxHeight: deck.glass == nil ? nil : .infinity)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)
            .frame(width: cardRing + 84)
            .frame(height: deck.glass?.height, alignment: .top)
        } else if card {
            VStack(spacing: 16) {
                OpeningRecord(opening: opening, side: 150, palette: palette)
                status(titleSize: 22)
                    // A failure is shorter than a step, and the glass keeps its height between them.
                    .frame(height: 104)
            }
            .padding(.top, 34)
            .padding(.bottom, 22)
            .padding(.horizontal, 24)
            .frame(width: 344)
        } else if let deck {
            // The deck where the wide layout has it: at the top right of the glass, which keeps its size.
            HStack(alignment: .top, spacing: 0) {
                status(titleSize: 32)
                    .frame(width: deck.glass == nil ? 300 : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle()
                    .fill(palette.ink.opacity(0.1))
                    .frame(width: 1)
                    .padding(.leading, 30)
                TurntableDeck(track: deck.track, artwork: deck.artwork, playing: deck.playing, spinning: deck.spinning, flash: deck.flash, palette: palette)
                    .padding(.leading, 30)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
            .frame(width: deck.glass?.width, height: deck.glass?.height, alignment: .top)
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

    /// The artist, then the part done, under the name: `Rick Astley · 45%`.
    private var byline: Text {
        let artist = opening.artist?.isEmpty == false ? opening.artist : nil
        // Rounded down and held at 99, since the step still runs while it shows.
        let percent = opening.progress.map { "\(min(99, Int(($0 * 100).rounded(.down))))%" }
        let font = Font.system(size: 12, weight: .medium, design: .rounded)
        var text = Text(artist ?? "").font(font).foregroundStyle(palette.muted)
        if artist != nil, percent != nil { text = text + Text(" · ").font(font).foregroundStyle(palette.muted) }
        if let percent { text = text + Text(percent).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(palette.ink) }
        return artist == nil && percent == nil ? Text(" ").font(font) : text
    }

    @ViewBuilder private func status(titleSize: CGFloat) -> some View {
        if let step = opening.step {
            VStack(spacing: 4) {
                // The title fills with the part done, as Listening does.
                ListenTitle(text: step, size: titleSize, progress: opening.progress, palette: palette)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                // The title and the artist as the record shows them once the song plays. Both lines keep their
                // height while a step has nothing to say there, so the buttons stay where they are.
                Text(opening.name.isEmpty ? " " : opening.name)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                byline
                    .lineLimit(1)
                    .truncationMode(.middle)
                if deck != nil {
                    OpeningBar(progress: opening.progress, palette: palette)
                        .padding(.top, 5)
                }
                HStack(spacing: 8) {
                    OpeningButton(title: "Cancel", key: "esc", palette: palette, solid: StripColors.solid(.red, colorScheme), action: cancel)
                        .help("Stop opening the song")
                    OpeningButton(title: "Continue in Background", key: "⌫", palette: palette, action: background)
                        .help("Close the HUD and keep opening the song")
                }
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
                case .retry: OpeningButton(title: "Retry", palette: palette, solid: StripColors.solid(.red, colorScheme), compact: true, action: retry)
                case .install: OpeningButton(title: "Install yt-dlp", palette: palette, solid: StripColors.solid(.red, colorScheme), compact: true, action: install)
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

/// The part done as a bar, beside the record of the song that plays: it fills, and a short piece of it travels from
/// end to end while the part isn't known.
private struct OpeningBar: View {
    let progress: Double?
    let palette: Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.renderingPreview) private var renderingPreview

    private static let width: CGFloat = 150
    private static let piece: CGFloat = 36

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(palette.ink.opacity(0.12))
            if let progress {
                Capsule()
                    .fill(palette.accent)
                    .frame(width: max(3, Self.width * min(1, max(0, progress))))
                    .animation(.linear(duration: 0.2), value: progress)
            } else {
                // 30 frames a second are smooth for a piece this small, and the HUD draws less for it.
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || renderingPreview)) { context in
                    let turn = renderingPreview || reduceMotion ? 0.35 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Capsule()
                        .fill(palette.accent)
                        .frame(width: Self.piece)
                        .offset(x: (Self.width + Self.piece) * turn - Self.piece)
                }
            }
        }
        .frame(width: Self.width, height: 3)
        .clipShape(Capsule())
    }
}

/// Cancel and Continue in Background with their keys beside them, in the look of the buttons that open a file or a
/// link, and Retry or Install yt-dlp solid in the red pill.
private struct OpeningButton: View {
    let title: String
    var key: String?
    let palette: Palette
    var solid: (fill: Color, text: Color)?
    /// Inside the red pill of a failure, which is the height of a row.
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(solid?.text ?? palette.ink)
                    .fixedSize()
                if let key {
                    if let solid {
                        // A key cap in the colour of the text on the red fill, where the ink of the palette wouldn't read.
                        Text(key)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(solid.text.opacity(0.9))
                            .padding(.horizontal, 3)
                            .frame(minWidth: 14, minHeight: 13)
                            .background(RoundedRectangle(cornerRadius: 4).fill(solid.text.opacity(0.16)))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(solid.text.opacity(0.3), lineWidth: 0.5))
                            .fixedSize()
                    } else {
                        Keycap(text: key, palette: palette, small: true)
                    }
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, key == nil ? 13 : 9)
            .padding(.vertical, compact ? 5 : 7)
            .background(Capsule().fill(solid.map { $0.fill.opacity(hovering ? 1 : 0.9) } ?? palette.ink.opacity(hovering ? 0.14 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
