import SwiftUI

/// Every key and gesture of the HUD on one glass, in groups with a warm tint each, which `?` and the ? buttons show
/// in place of the HUD. It names the keys of the layout that it covers: the arrows step a semitone on the key row of
/// the wide layout, and a fifth around the ring of the card.
struct ShortcutsSheet: View {
    let card: Bool
    /// The other mode than the song's, which Option picks a key in.
    let otherMode: String
    /// The hotkey from Settings, which finds the key of the song that plays.
    let hotkey: String
    let palette: Palette
    let close: () -> Void

    private struct KeyGroup: Identifiable {
        let name: String
        let symbol: String
        let hue: Double
        let rows: [Row]
        var id: String { name }
    }

    private struct Row {
        let caps: [Cap]
        let name: String
        var condition: String?
    }

    private enum Cap: Hashable {
        case key(String)
        /// A gesture with the mouse or the trackpad, a symbol and its word.
        case gesture(String, symbol: String)
    }

    private static let width: CGFloat = 226

    private var columns: [[KeyGroup]] {
        let stems = "1–\(Stem.shown.count)"
        let key = KeyGroup(name: "Key", symbol: "tuningfork", hue: 20, rows: [
            Row(caps: [.key("A–G")], name: "key"),
            Row(caps: [.key("⌥"), .key("A–G")], name: "\(otherMode) key"),
            Row(caps: [.key("⇧"), .key("A–G")], name: "sharp or flat"),
            Row(caps: [.key("←"), .key("→")], name: card ? "fifth" : "semitone"),
            Row(caps: [.key("↑"), .key("↓")], name: "octave"),
            Row(caps: [.key("⌫")], name: "original key"),
            Row(caps: [.key("K")], name: "lock key"),
        ])
        let tempo = KeyGroup(name: "Tempo", symbol: "metronome", hue: 70, rows: [
            Row(caps: [.key("["), .key("]")], name: "slower or faster"),
            Row(caps: [.key("=")], name: "original tempo"),
        ])
        let hud = KeyGroup(name: "HUD", symbol: "macwindow", hue: 95, rows: [
            Row(caps: [.key(hotkey)], name: "find key"),
            Row(caps: [.key("S")], name: card ? "wide style" : "card style"),
            Row(caps: [.key("M")], name: "mini player"),
            Row(caps: [.key("⌘"), .key("⌥"), .key("C")], name: "move to bottom centre"),
            Row(caps: [.key("?")], name: "shortcuts"),
            Row(caps: [.key("esc")], name: "close"),
        ])
        let playback = KeyGroup(name: "Playback", symbol: "playpause", hue: 45, rows: [
            Row(caps: [.key("space")], name: "play or pause"),
            Row(caps: [.key("N"), .key("P")], name: "next or previous song"),
            Row(caps: [.key("←"), .key("→")], name: "5 seconds back/forward", condition: "when hovering the record"),
            Row(caps: [.key("0")], name: "from the beginning", condition: "when hovering the record"),
            Row(caps: [.key("1–9")], name: "seek to 10%-90%", condition: "when hovering the record"),
        ])
        let lyrics = KeyGroup(name: "Lyrics and karaoke", symbol: "quote.bubble", hue: 8, rows: [
            Row(caps: [.key("L")], name: "lyrics"),
            Row(caps: [.key("⌘"), .key("K")], name: "karaoke"),
            Row(caps: [.key("↩")], name: "karaoke", condition: "when lyrics are visible"),
            Row(caps: [.key("0–9")], name: "seek to 0%-90%", condition: "in karaoke"),
        ])
        let instruments = KeyGroup(name: "Instruments and vocals", symbol: "slider.vertical.3", hue: 82, rows: [
            Row(caps: [.key(stems)], name: "mute instrument"),
            Row(caps: [.key("⌥"), .key(stems)], name: "solo instrument"),
            Row(caps: [.key("V")], name: "toggle vocals"),
            Row(caps: [.key("0")], name: "play all"),
        ])
        let song = KeyGroup(name: "Song", symbol: "music.note", hue: 32, rows: [
            Row(caps: [.key("⌘"), .key("S")], name: "save song"),
            Row(caps: [.key("⌘"), .key("⌫")], name: "original song"),
            Row(caps: [.key("⌘"), .key("V")], name: "play copied file or link"),
            Row(caps: [.key("⌘"), .key("O")], name: "open file"),
            Row(caps: [.key("⌘"), .key("L")], name: "open URL"),
        ])
        let waveform = KeyGroup(name: "Waveform and loop", symbol: "waveform", hue: 74, rows: [
            Row(caps: [.key("W")], name: "waveform"),
            Row(caps: [.key("⌥"), .key("W")], name: "instrument lanes", condition: "once the whole song is separated"),
            Row(caps: [.key("⌘"), .key("+"), .key("−")], name: "zoom"),
            Row(caps: [.key("R")], name: "region loop", condition: "start, end, clear"),
            Row(caps: [.key("⌥"), .key("R")], name: "region loop end without snapping"),
        ])
        let queue = KeyGroup(name: "Queue", symbol: "list.bullet", hue: 40, rows: [
            Row(caps: [.key("Q")], name: "queue"),
            Row(caps: [.key("↩")], name: "play song", condition: "in the queue"),
            Row(caps: [.key("⌫")], name: "remove songs", condition: "in the queue"),
            Row(caps: [.key("⇧"), .key("⌘"), .key("O")], name: "add files"),
            Row(caps: [.key("⇧"), .key("⌘"), .key("V")], name: "add copied songs"),
            Row(caps: [.gesture("swipe on song", symbol: "arrow.left.and.right")], name: "remove or play next"),
        ])
        let pointer = KeyGroup(name: "Mouse and trackpad", symbol: "computermouse", hue: 58, rows: [
            Row(caps: [.gesture("click record", symbol: "cursorarrow.click")], name: "play or pause"),
            Row(caps: [.gesture("swipe", symbol: "arrow.left.and.right")], name: "next or previous song"),
            Row(caps: [.gesture("scroll on instrument", symbol: "arrow.up.and.down")], name: "adjust volume"),
            Row(caps: [.gesture("scroll on tempo", symbol: "arrow.up.and.down")], name: "adjust tempo"),
            Row(caps: [.key("⌥"), .gesture("click instrument", symbol: "cursorarrow.click")], name: "solo instrument"),
            Row(caps: [.gesture("drop file", symbol: "arrow.down.doc")], name: "play file or link"),
            Row(caps: [.gesture("pinch on waveform", symbol: "arrow.up.left.and.arrow.down.right")], name: "zoom"),
        ])
        return [[key, tempo, hud], [playback, lyrics, instruments, queue], [song, waveform, pointer]]
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Shortcuts")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(palette.ink)
                .frame(height: 22)
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: 12) {
                        // The last group of each column reaches the bottom of the tallest one, so the columns end
                        // on one line.
                        ForEach(column) { GroupTile(group: $0, fills: $0.id == column.last?.id, palette: palette) }
                    }
                    // As wide as its widest group, the mouse and trackpad's chips with their words included.
                    .frame(minWidth: Self.width)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .overlay(alignment: .topTrailing) {
            RoundButton(symbol: "questionmark", help: "Close the shortcuts (?)", isOn: true, palette: palette, action: close)
                .padding(10)
        }
    }

    /// A group: its symbol in a tile of its hue and its name, then a row for each key or gesture. The keycaps take
    /// the group's hue, so a key reads as part of its group at a glance.
    private struct GroupTile: View {
        let group: KeyGroup
        let fills: Bool
        let palette: Palette
        @Environment(\.colorScheme) private var scheme

        private var fill: Color { scheme == .dark ? .oklch(0.44, 0.07, group.hue) : .oklch(0.9, 0.055, group.hue) }
        private var ink: Color { scheme == .dark ? .oklch(0.9, 0.07, group.hue) : .oklch(0.45, 0.11, group.hue) }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: group.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ink)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
                    Text(group.name)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.ink)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        GridRow(alignment: .firstTextBaseline) {
                            HStack(spacing: 3) {
                                ForEach(Array(row.caps.enumerated()), id: \.offset) { _, cap in capView(cap) }
                            }
                            .gridColumnAlignment(.trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.name)
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(palette.ink.opacity(0.86))
                                if let condition = row.condition {
                                    Text(condition)
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(palette.muted.opacity(0.75))
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(palette.ink.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.ink.opacity(0.06), lineWidth: 1))
        }

        @ViewBuilder private func capView(_ cap: Cap) -> some View {
            switch cap {
            case let .key(text):
                Text(text)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    // Brackets reach below the baseline, which centres them a point lower than the text beside them.
                    .offset(y: text == "[" || text == "]" ? -1 : 0)
                    .foregroundStyle(ink)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 19, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(fill.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(ink.opacity(0.22), lineWidth: 0.5))
                    .fixedSize()
            case let .gesture(word, symbol):
                HStack(spacing: 3) {
                    Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
                    Text(word).font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 7)
                .frame(minHeight: 18)
                .background(Capsule().fill(fill.opacity(0.6)))
                .overlay(Capsule().strokeBorder(ink.opacity(0.22), lineWidth: 0.5))
                .fixedSize()
            }
        }
    }
}
