import AppKit
import SwiftUI

/// How a shift is written: `+2` in the menu bar, `+2 semitones` in the HUD.
enum Shift {
    static let range = -12 ... 12

    static func short(_ semitones: Int) -> String { semitones < 0 ? "−\(-semitones)" : "+\(semitones)" }
    static func text(_ semitones: Int) -> String { "\(short(semitones)) semitone\(abs(semitones) == 1 ? "" : "s")" }
}

/// A capsule button in the HUD's ink, for Stop Pitch Change, and a toggle with `isOn` for Lock Key, which turns
/// to a red tint while it is on. `small` is the size that fits in the hint bar and along the bottom of the card.
struct HUDButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let palette: Palette
    var isOn: Bool? = nil
    var small = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    /// The height of a small pill.
    static let smallHeight: CGFloat = 22
    /// The round ? button beside Lock Key. Its outline makes a circle look taller than a pill of the same height, so
    /// it is drawn a little smaller to appear as tall as Lock Key.
    static let questionSize: CGFloat = 20

    private var on: Bool { isOn == true }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(SpacedLabel(spacing: small ? 4 : 6))
                .font(.system(size: small ? 11 : 13, weight: .semibold, design: .rounded))
                .fixedSize()
                .foregroundStyle(on ? StripColors.text(.red, colorScheme) : palette.ink)
                .padding(.horizontal, small ? 9 : 12)
                .padding(.vertical, small ? 4 : 6)
                .frame(minHeight: small ? Self.smallHeight : 0)
                .background(Capsule().fill(background))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        guard on else { return palette.ink.opacity(0.08 + (hovering ? 0.06 : 0)) }
        let tint = StripColors.tint(.red, strong: true, colorScheme)
        return hovering ? tint.mix(with: palette.ink, by: 0.12) : tint
    }
}

private struct SpacedLabel: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

/// A small round button in the corner of the HUD or at the end of the card's bottom row, with a symbol or a
/// character: the ? of the keyboard shortcuts and the switch between the two layouts. With a `label`, hovering it
/// widens it into a pill that names it and shows its key, so the corner buttons read without a tooltip.
struct RoundButton: View {
    var symbol: String? = nil
    var text: String? = nil
    let help: String
    var label: String? = nil
    var key: String? = nil
    var isOn = false
    /// Larger in karaoke, where the buttons sit in one row with the key.
    var size: CGFloat = 20
    /// The label opens to the right of the symbol, for a button at the left edge, so the symbol stays where it was.
    var labelAfter = false
    let palette: Palette
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.cornerLabelsShown) private var labelsShown
    @Environment(\.colorScheme) private var scheme

    private var expanded: Bool { label != nil && (hovering || labelsShown) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if expanded, let label, !labelAfter {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.ink)
                        .fixedSize()
                        .padding(.leading, 9)
                        .transition(.opacity)
                    if let key { Keycap(text: key, palette: palette, small: true).transition(.opacity) }
                }
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .bold))
                    } else {
                        Text(text ?? "").font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
                    }
                }
                .foregroundStyle(isOn || hovering || expanded ? palette.ink : palette.muted)
                .frame(width: size, height: size)
                if expanded, let label, labelAfter {
                    HStack(spacing: 5) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.ink)
                            .fixedSize()
                        if let key { Keycap(text: key, palette: palette, small: true) }
                    }
                    .padding(.trailing, key == nil ? 9 : 4)
                    .transition(.opacity)
                }
            }
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(palette.ink.opacity(isOn ? 0 : 0.22), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        // The pill names the button, so only the buttons without a label keep a tooltip.
        .help(label == nil ? help : "")
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.15), value: expanded)
    }

    /// Opaque enough while the pill is open to read over the keys or the record under it.
    private var fill: Color {
        let tint = palette.ink.opacity(isOn ? 0.14 : hovering ? 0.08 : 0)
        guard expanded else { return tint }
        let base = scheme == .dark ? Color(red: 0.16, green: 0.14, blue: 0.15) : Color(red: 0.98, green: 0.97, blue: 0.97)
        return base.mix(with: palette.ink, by: isOn ? 0.14 : 0.06)
    }
}

extension EnvironmentValues {
    /// Opens the pills of the corner buttons without the pointer over them, for the renders.
    @Entry var cornerLabelsShown = false
    /// The backspins that the output played when it stepped back in the song, which the records turn back with.
    @Entry var recordRewinds = 0
    /// A new song that the stems or the lyrics delay will play only seconds later: from when it started to when it is
    /// heard. Its record waits in a loading state until then.
    @Entry var songArriving: ClosedRange<Date>? = nil
}

/// The shift from the original key, under the key name while a pitch change runs: honey going up, muted blue
/// going down. With no `hue`, it stays in the HUD's ink, for Pitch change failed.
struct ShiftPill: View {
    let text: String
    var hue: StripColors.Hue? = nil
    /// A spinner before the text, while the key that the pill names is still being found.
    var waiting = false
    let palette: Palette
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = hue.map { StripColors.text($0, colorScheme) } ?? palette.ink
        HStack(spacing: 5) {
            if waiting {
                Spinner(color: color)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
            Text(text)
        }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(hue.map { StripColors.tint($0, strong: true, colorScheme) } ?? palette.ink.opacity(0.1)))
            .fixedSize()
    }
}

/// The key that Lock Key moved a new song from, and the key that it moved it to.
struct KeyMove: Equatable {
    let from: DetectedKey
    let to: DetectedKey
}

/// The change of key under the title, written short: `A → Cm` with the shift in a circle. While the pointer is over
/// it, it widens to `A major → C minor` and `−6 semitones`. The wide pill is drawn over the short one, so the row
/// keeps its layout, and `expanded` lets the row hide the pills that the wide one covers.
struct KeyMovePill: View {
    /// No key yet while a new song waits for its key to be found: `→ Cm` with a spinner.
    let from: DetectedKey?
    let to: DetectedKey
    var shift = 0
    let hue: StripColors.Hue
    var waiting = false
    let palette: Palette
    @Binding var expanded: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.keyPillExpanded) private var forcedExpanded

    var body: some View {
        pill(full: false)
            .hidden()
            // Pinned at its right end, so it widens to the left, over the tempo pills that the row hides meanwhile,
            // and never past the edge of the card.
            .overlay(alignment: .trailing) {
                pill(full: hovering || forcedExpanded)
                    .contentShape(Capsule())
                    .onHover { on in
                        hovering = on
                        expanded = on
                    }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onDisappear { if hovering { expanded = false } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys(full: true) + (shift == 0 ? "" : ", " + Shift.text(shift)))
    }

    private func keys(full: Bool) -> String {
        let name = { (key: DetectedKey) in full ? key.name : key.short }
        return from.map { "\(name($0)) → \(name(to))" } ?? "→ \(name(to))"
    }

    private func pill(full: Bool) -> some View {
        let color = StripColors.text(hue, colorScheme)
        return HStack(spacing: 5) {
            if waiting {
                Spinner(color: color)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
            }
            Text(keys(full: full))
            if shift != 0 {
                // A circle for the short shift, which widens into a capsule for the full one.
                Text(full ? Shift.text(shift) : Shift.short(shift))
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: Double(shift)))
                    .padding(.horizontal, full ? 5 : 1.5)
                    .frame(minWidth: 17, minHeight: 17)
                    .background(Capsule().fill(color.opacity(0.17)))
            }
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(color)
        .padding(.leading, 8)
        .padding(.trailing, shift == 0 ? 8 : 1.5)
        .frame(minHeight: 20)
        .background(Capsule().fill(StripColors.tint(hue, strong: true, colorScheme)))
        .fixedSize()
    }
}

/// An arc that turns, in the colour of the text beside it. It is shown only while the HUD is up, since a repeating
/// animation keeps rendering in a window that is ordered out.
struct Spinner: View {
    let color: Color
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// A traffic-light close button for the HUD while it waits for a key to be picked.
struct CloseButton: View {
    /// Larger in karaoke, where it sits in one row with the key and the karaoke button.
    var size: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(red: 1, green: 0.37, blue: 0.34))
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .overlay(Image(systemName: "xmark").font(.system(size: size / 2, weight: .heavy)).foregroundStyle(.black.opacity(0.55)))
                .frame(width: size, height: size)
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}

/// How close two keys of the same mode sit on the circle of fifths, which is how smooth a change between them
/// sounds: 1 for a fourth or a fifth apart (neighbours on the Camelot wheel), 2 for a whole step, 6 for a tritone.
enum Harmony {
    static func distance(semitones: Int) -> Int {
        let steps = ((semitones * 7) % 12 + 12) % 12
        return min(steps, 12 - steps)
    }
}

/// Two rows of keys, from six semitones below the original key to five above, so a key's column is its shift. The main
/// row has the keys in the song's mode, and the smaller row under it has their relatives in the other mode: the same
/// notes, so both keys of a column play the same shift and only the name that the HUD shows differs. Holding Option
/// flips every key to the other mode, so Option-clicking a key picks it in that mode. Nothing else renames a key, so
/// a key stays under the pointer and under its letter. The arrows step one semitone at a time, up to an octave either
/// way.
/// Keys a fourth or a fifth from the key heard now are highlighted, and keys a whole step away less so: those are
/// the changes that don't sound harsh. `StripColors` picks the colours.
struct KeyPicker: View {
    let original: DetectedKey
    let shift: Int
    /// The selected key is in the second row.
    var relative = false
    var showsRelatives = true
    /// Option is held: every key shows the other mode.
    var flipped = false
    let palette: Palette
    var colors = StripColors.current
    /// The shift, and whether the key is in the other mode than the song.
    let select: (Int, Bool) -> Void

    /// The shift folded into the row, so an octave up still highlights the original key.
    private var selectedOffset: Int { FifthsRing.fold(shift) }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                StepButton(symbol: "chevron.left", help: "Semitone down (←)", hue: StripColors.down, palette: palette) { select(shift - 1, relative) }
                    .disabled(shift <= Shift.range.lowerBound)
                ForEach(-6 ... 5, id: \.self) { offset in
                    chip(offset, second: false)
                }
                StepButton(symbol: "chevron.right", help: "Semitone up (→)", hue: StripColors.up, palette: palette) { select(shift + 1, relative) }
                    .disabled(shift >= Shift.range.upperBound)
            }
            if showsRelatives {
                HStack(spacing: 2) {
                    ForEach(-6 ... 5, id: \.self) { offset in
                        chip(offset, second: true)
                    }
                }
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.ink.opacity(0.045)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 13).fill(palette.ink.opacity(0.06)))
    }

    // No tooltip: one popped up over the row whenever the pointer rested on a key.
    private func chip(_ offset: Int, second: Bool) -> some View {
        KeyChip(
            front: Self.face(original: original, offset: offset, shift: shift, relative: relative, other: second),
            back: Self.face(original: original, offset: offset, shift: shift, relative: relative, other: !second),
            flipped: flipped,
            // The keys flip from left to right, like the digits of a flip clock.
            flipDelay: Double(offset + 6) * 0.022,
            harmony: offset == selectedOffset ? 0 : Harmony.distance(semitones: offset - shift),
            size: second ? .small : .regular,
            colors: colors,
            palette: palette
        ) {
            Self.click(offset: offset, second: second, flipped: flipped, inColumn: offset == selectedOffset, shift: shift, select: select)
        }
        .zIndex(offset == selectedOffset ? 1 : 0)
    }

    /// The key at `offset` in the song's mode, or with `other` in the other mode, and how it is marked: selected
    /// when it is the key heard now, outlined when the key heard now has the same notes in the other mode.
    static func face(original: DetectedKey, offset: Int, shift: Int, relative: Bool, other: Bool) -> KeyChip.Face {
        let transposed = original.transposed(by: offset)
        let inColumn = offset == FifthsRing.fold(shift)
        return KeyChip.Face(
            key: other ? transposed.relative : transposed,
            selected: inColumn && relative == other,
            partner: inColumn && relative != other,
            isOriginal: offset == 0 && !other
        )
    }

    /// A click on the key at `offset`, in the mode that it shows while Option is held or not. The column of the
    /// selected key keeps the shift, which can be an octave away from the column's offset after ↑ or ↓, so a click
    /// there changes only the mode.
    /// `flipped`: the chips show the other mode, from a key picked in it or from Option held, so a click picks a key
    /// in the mode that the chip shows.
    static func click(offset: Int, second: Bool, flipped: Bool, inColumn: Bool, shift: Int, select: (Int, Bool) -> Void) {
        select(inColumn ? shift : offset, second != flipped)
    }
}

/// The keys on a circle of fifths around the record of the single card: the song's mode on the outer ring, and the
/// relatives in the other mode on a smaller inner ring, the way a circle of fifths is drawn. The original key sits at
/// the top and each step clockwise is a fifth up, so the keys beside the selected one are the changes that sound
/// smoothest. A key's shift is the same as in the rows of the wide layout, and so are the clicks and the colours.
struct FifthsRing: View {
    let original: DetectedKey
    let shift: Int
    var relative = false
    let palette: Palette
    let radius: CGFloat
    let innerRadius: CGFloat
    var showsRelatives = true
    var flipped = false
    var colors = StripColors.current
    let select: (Int, Bool) -> Void

    private var selectedOffset: Int { Self.fold(shift) }

    /// A shift folded into the row's range of six down to five up, the way the ring shows it.
    static func fold(_ shift: Int) -> Int { ((shift + 6) % 12 + 12) % 12 - 6 }

    /// The shift of the key at a place on the ring. A fifth up is 7 semitones, folded into the row's range.
    static func offset(at step: Int) -> Int { fold(step * 7) }

    /// The shift of the key `steps` places clockwise from the one at `shift`, for the ← and → keys. It is the same
    /// shift that a click on that key picks. Since 7 × 7 is 49, which is 1 more than 48, the place of a shift on the
    /// ring is its offset times 7.
    static func step(from shift: Int, by steps: Int) -> Int {
        let place = ((fold(shift) * 7 + steps) % 12 + 12) % 12
        return offset(at: place)
    }

    /// How far each ring reaches from its middle: the outer ring is 38 points wide and the inner one 26.
    private static let outerBand: CGFloat = 19
    private static let innerBand: CGFloat = 13

    var body: some View {
        ZStack {
            // Each key owns its slice of the ring, as on a printed circle of fifths, and the slices draw the ring.
            ForEach(0 ..< 12, id: \.self) { step in
                let angle = Double(step) * .pi / 6
                chip(Self.offset(at: step), place: step, second: false,
                     slice: RingSlice(distance: radius, inner: radius - Self.outerBand, outer: radius + Self.outerBand, angle: angle))
                    .offset(x: sin(angle) * radius, y: -cos(angle) * radius)
                if showsRelatives {
                    chip(Self.offset(at: step), place: step, second: true,
                         slice: RingSlice(distance: innerRadius, inner: innerRadius - Self.innerBand, outer: innerRadius + Self.innerBand, angle: angle))
                        .offset(x: sin(angle) * innerRadius, y: -cos(angle) * innerRadius)
                }
            }
        }
        .frame(width: radius * 2 + 40, height: radius * 2 + 40)
    }

    /// The keys flip clockwise from the top.
    private func chip(_ offset: Int, place: Int, second: Bool, slice: RingSlice) -> some View {
        KeyChip(
            front: KeyPicker.face(original: original, offset: offset, shift: shift, relative: relative, other: second),
            back: KeyPicker.face(original: original, offset: offset, shift: shift, relative: relative, other: !second),
            flipped: flipped,
            flipDelay: Double(place) * 0.022,
            harmony: offset == selectedOffset ? 0 : Harmony.distance(semitones: offset - shift),
            size: second ? .ring : .regular,
            slice: slice,
            colors: colors,
            palette: palette
        ) {
            KeyPicker.click(offset: offset, second: second, flipped: flipped, inColumn: offset == selectedOffset, shift: shift, select: select)
        }
    }
}

/// A key's slice of a ring on the circle of fifths, a twelfth of the ring between two radii, drawn in the coordinates
/// of the key's chip, which sits `distance` from the middle of the ring at `angle` clockwise from the top.
struct RingSlice: Shape {
    let distance: CGFloat
    let inner: CGFloat
    let outer: CGFloat
    let angle: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX - sin(angle) * distance, y: rect.midY + cos(angle) * distance)
        // A point at `radius` and `turn` clockwise from the top, in the y-down coordinates of the view.
        func point(_ radius: CGFloat, _ turn: Double) -> CGPoint { CGPoint(x: center.x + sin(turn) * radius, y: center.y - cos(turn) * radius) }
        let half = Double.pi / 12, steps = 16
        var path = Path()
        for step in 0 ... steps {
            let turn = angle - half + 2 * half * Double(step) / Double(steps)
            step == 0 ? path.move(to: point(outer, turn)) : path.addLine(to: point(outer, turn))
        }
        for step in 0 ... steps {
            path.addLine(to: point(inner, angle + half - 2 * half * Double(step) / Double(steps)))
        }
        path.closeSubpath()
        return path
    }
}

/// A key name with its sharp or flat dimmed, so the letter reads first.
enum Accidental {
    static func text(_ name: String, color: Color) -> Text {
        name.reduce(Text("")) { text, character in
            text + ("♯♭".contains(character) ? Text(String(character)).foregroundStyle(color.opacity(0.45)) : Text(String(character)))
        }
    }
}

/// A key's tonic, with a small m after it for a minor key, the way chord charts write it.
struct KeyName: View {
    let key: DetectedKey
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Accidental.text(key.tonic, color: color)
                .font(.system(size: size, weight: weight, design: .rounded))
            if key.minor {
                Text("m")
                    .font(.system(size: size * 0.74, weight: .semibold, design: .rounded))
                    .opacity(0.72)
            }
        }
        .fixedSize()
    }
}

struct KeyChip: View {
    enum Size {
        /// The main row and the outer ring.
        case regular
        /// The second row of the wide layout, as wide as the main row so that each key sits under its relative.
        case small
        /// The inner ring of the card.
        case ring

        var frame: CGSize {
            switch self {
            case .regular: CGSize(width: 32, height: 34)
            case .small: CGSize(width: 32, height: 22)
            case .ring: CGSize(width: 26, height: 19)
            }
        }

        var font: CGFloat { self == .regular ? 14 : 11 }
        var corner: CGFloat { self == .regular ? 9 : 6 }
    }

    /// One side of a chip: a key, and how it is marked.
    struct Face: Equatable {
        let key: DetectedKey
        let selected: Bool
        /// The key heard now has the same notes in the other mode.
        let partner: Bool
        /// The key that the song was found in, marked with a dot.
        let isOriginal: Bool
    }

    let front: Face
    /// The same notes in the other mode, which the chip flips to while Option is held.
    let back: Face
    let flipped: Bool
    var flipDelay = 0.0
    /// Steps on the circle of fifths from the key heard now.
    let harmony: Int
    var size = Size.regular
    /// On the card's circle of fifths, the chip's background is its slice of the ring rather than a rounded square.
    var slice: RingSlice?
    let colors: StripColors
    let palette: Palette
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var small: Bool { size != .regular }

    /// A square around the chip that holds its whole slice: the slice is as deep as the ring and, at its outer edge,
    /// a twelfth of the circle wide.
    private var sliceBox: CGFloat? {
        slice.map { max(2 * ($0.outer - $0.distance), 2 * $0.outer * sin(.pi / 12)) + 6 }
    }

    /// The colour of a fourth or a fifth, or of a whole step, from the key heard now.
    private var hue: StripColors.Hue? { harmony == 1 ? colors.strong : harmony == 2 ? colors.light : nil }

    var body: some View {
        Button(action: action) {
            side(front)
                .modifier(Flip(angle: flipped ? 180 : 0, reduceMotion: reduceMotion, back: side(back)))
                // Room for the whole slice around the name, so the pointer over any part of it hovers and clicks it.
                .frame(width: sliceBox, height: sliceBox)
                // The slice stays still while the name on it flips, and takes the colours of the side that shows.
                .background { if let slice { sliceBackground(slice, flipped ? back : front) } }
                .contentShape(slice.map { AnyShape($0) } ?? AnyShape(RoundedRectangle(cornerRadius: size.corner)))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: front)
        .animation(.snappy(duration: 0.18), value: harmony)
        // A spring with a little bounce, so each key settles like a card on a flip clock. Released mid-flip, the
        // keys turn back from where they are.
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.28).delay(flipDelay), value: flipped)
    }

    private func side(_ face: Face) -> some View {
        let text = textColor(face)
        // The related keys are filled too, so the selected key in the main row also gets a ring and a little glow.
        let marked = face.selected && size == .regular && slice == nil
        return KeyName(key: face.key, size: size.font, weight: face.selected ? .bold : .semibold, color: text)
            .foregroundStyle(text)
            // The second row stays quieter than the main one until a key in it is picked.
            .opacity(small && !face.selected && !face.partner && !hovering ? 0.78 : 1)
            .frame(width: size.frame.width, height: size.frame.height)
            // Drawn over the chip's bottom edge, so the label stays centred like the others and the arrows.
            .overlay(alignment: .bottom) {
                if face.isOriginal {
                    Circle()
                        .fill(text.opacity(0.85))
                        .frame(width: small ? 3 : 4, height: small ? 3 : 4)
                        .padding(.bottom, small ? 1 : 4)
                }
            }
            .background { if slice == nil { chipBackground(face, glow: marked) } }
            .overlay {
                if face.partner, slice == nil {
                    RoundedRectangle(cornerRadius: size.corner)
                        .strokeBorder(StripColors.solid(colors.selected, colorScheme).fill.opacity(0.75), lineWidth: 1.5)
                }
            }
            .overlay {
                if marked {
                    RoundedRectangle(cornerRadius: size.corner + 3).strokeBorder(palette.ink.opacity(0.9), lineWidth: 2).padding(-4)
                }
            }
    }

    @ViewBuilder private func chipBackground(_ face: Face, glow: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: size.corner)
        if glow {
            shape.fill(background(face)).shadow(color: StripColors.solid(colors.selected, colorScheme).fill.opacity(0.7), radius: 6)
        } else {
            shape.fill(background(face))
        }
    }

    /// The slice filled like a chip, with a faint fill of its own where a chip has none, so the slices draw the
    /// whole ring, and a hairline between it and its neighbours.
    private func sliceBackground(_ slice: RingSlice, _ face: Face) -> some View {
        let plain = !face.selected && hue == nil
        return ZStack {
            if plain {
                slice.fill(palette.ink.opacity(hovering ? 0.11 : small ? 0.04 : 0.06))
            } else {
                slice.fill(background(face))
            }
            slice.stroke(palette.ink.opacity(0.1), lineWidth: 0.75)
            if face.partner {
                slice.stroke(StripColors.solid(colors.selected, colorScheme).fill.opacity(0.75), lineWidth: 1.5)
            }
        }
        .animation(.snappy(duration: 0.18), value: face)
    }

    private func textColor(_ face: Face) -> Color {
        if face.selected { return StripColors.solid(colors.selected, colorScheme).text }
        if face.partner { return StripColors.text(colors.selected, colorScheme) }
        if let hue { return StripColors.text(hue, colorScheme) }
        return face.isOriginal ? palette.ink : palette.muted
    }

    private func background(_ face: Face) -> some ShapeStyle {
        if face.selected { return AnyShapeStyle(StripColors.solid(colors.selected, colorScheme).fill) }
        if let hue {
            // The second row repeats the colours of the main row more faintly, since a column shares one shift.
            let tint = StripColors.tint(hue, strong: harmony == 1 && !small, colorScheme).opacity(small ? 0.6 : 1)
            return AnyShapeStyle(hovering ? tint.mix(with: palette.ink, by: 0.12) : tint)
        }
        return AnyShapeStyle(palette.ink.opacity(hovering ? 0.1 : 0))
    }
}

/// Turns a chip over on its horizontal axis to the side behind it, like a card on a flip clock. With Reduce Motion
/// the two sides crossfade instead.
private struct Flip<Back: View>: ViewModifier, Animatable {
    var angle: Double
    let reduceMotion: Bool
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        if reduceMotion {
            ZStack {
                content.opacity(1 - angle / 180)
                back.opacity(angle / 180)
            }
        } else {
            ZStack {
                if angle < 90 {
                    content
                } else {
                    back.rotation3DEffect(.degrees(180), axis: (x: 1, y: 0, z: 0))
                }
            }
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
        }
    }
}

private struct StepButton: View {
    let symbol: String
    let help: String
    let hue: StripColors.Hue
    let palette: Palette
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            let tint = StripColors.tint(hue, strong: false, colorScheme)
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StripColors.text(hue, colorScheme))
                .frame(width: 26, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(hovering && isEnabled ? tint.mix(with: palette.ink, by: 0.12) : tint))
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .opacity(isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The keys of the key picker. `band` is the short list on one line at the left of the hint bar of the wide layout,
/// which has Lock Key and Stop Pitch Change at its right end. Every key is on the shortcuts, which ? shows.
struct KeyHints: View {
    /// The band along the bottom of the wide layout, the hints under the instruments and vocals, and karaoke's
    /// footer.
    enum Style { case band, stems, footer }

    var style = Style.band
    /// The lyrics show in place of the key row, and only the keys that work there are listed.
    var lyrics = false
    /// Karaoke shows, and Return goes back to the lyrics.
    var focus = false
    /// V mutes the vocals or plays them again, with the separation model installed.
    var vocals = false
    /// The arrows and, in karaoke, the number keys seek.
    var seek = false
    /// The key 0 starts the song over in karaoke.
    var restart = false
    /// The key row shows in karaoke, and the keys that change the key are listed.
    var karaokeKeys = false
    /// Chords show over the lyrics, and the arrows transpose instead of seeking.
    var chords = false
    /// The pointer is over the waveform, and only its keys are listed: ⌥W with the stems of the whole song.
    var waveform = false
    var lanes = false
    /// The pointer is over the tab of an end of the region loop, and the arrows nudge it.
    var loopEnd: LoopEnd?
    /// The waveform shows a close-up, which ⌘0 takes back to the whole song.
    var zoomed = false
    /// The other mode than the song's, which Option shows and picks.
    let otherMode: String
    let palette: Palette

    private struct Hint {
        let keys: [String]
        let name: String
    }

    /// The keys of the stems are listed only in the pill on their tray.
    private var hints: [Hint] { listed }

    private var listed: [Hint] {
        switch style {
        case _ where waveform && loopEnd != nil:
            [Hint(keys: ["←", "→"], name: loopEnd == .start ? "nudge A" : "nudge B"), Hint(keys: ["⌥", "←", "→"], name: "by a beat"),
             Hint(keys: ["R"], name: "region loop"), Hint(keys: ["⌘", "+", "−"], name: "zoom")]
        case _ where waveform:
            [Hint(keys: ["R"], name: "region loop")] + (lanes ? [Hint(keys: ["⌥", "W"], name: "lanes")] : [])
                // In a close-up, ⌘0 joins the zoom keys, which keeps the row within the card.
                + [Hint(keys: ["⌘", "+", "−"] + (zoomed ? ["0"] : []), name: "zoom"), Hint(keys: ["scroll"], name: "move song")]
        case .band where karaokeKeys, .footer where karaokeKeys:
            [Hint(keys: ["A–G"], name: "key"), Hint(keys: ["⌥", "A–G"], name: otherMode), Hint(keys: ["⇧", "A–G"], name: "♯ or ♭"),
             Hint(keys: ["↑", "↓"], name: "octave"), Hint(keys: ["⌫"], name: "original key"), Hint(keys: ["esc"], name: "close")]
        case .band where lyrics, .footer:
            // Karaoke's footer, no wider than its record, leaves out L, which leaves karaoke for the keys, while the
            // seek hints need the room.
            // The band names L after the toggle, as the keys view and the Lyrics button do; karaoke's footer says that L
            // leaves it. The band leaves L out with the chords and the vocals, which need the room.
            ((style == .footer ? seek || chords : chords && vocals) ? [] : [Hint(keys: ["L"], name: style == .footer ? "close lyrics" : "lyrics")]) + [Hint(keys: ["↩"], name: focus ? "close karaoke" : "karaoke")]
                + (vocals ? [Hint(keys: ["V"], name: "vocals")] : [])
                + [Hint(keys: ["space"], name: "play or pause")]
                + (focus && seek ? [Hint(keys: ["0–9"], name: "seek")] : focus && restart ? [Hint(keys: ["0"], name: "start over")] : [])
                + (chords ? [Hint(keys: ["←", "→"], name: "transpose")] : seek ? [Hint(keys: ["←", "→"], name: "5 s")] : [])
                + [Hint(keys: ["N", "P"], name: "skip")]
                // The band keeps the wide glass's width: transpose, or the 5 s keys with the vocals, take the place of K,
                // since the Lock Key button sits in the same row.
                + (style == .band && (chords || seek && vocals) ? [] : [Hint(keys: ["K"], name: "lock key")]) + [Hint(keys: ["esc"], name: "close")]
        case .band:
            [Hint(keys: ["A–G"], name: "key"), Hint(keys: ["⌥", "A–G"], name: otherMode), Hint(keys: ["⇧", "A–G"], name: "♯ or ♭"),
             Hint(keys: ["↑", "↓"], name: "octave"), Hint(keys: ["⌫"], name: "original key"), Hint(keys: ["L"], name: "lyrics"),
             Hint(keys: ["esc"], name: "close")]
        case .stems:
            // The lyrics list V in their own hints, so the tray under them leaves it out.
            [Hint(keys: ["1–\(Stem.shown.count)"], name: "mute"), Hint(keys: ["⌥", "1–\(Stem.shown.count)"], name: "solo")]
                + (vocals ? [Hint(keys: ["V"], name: "vocals")] : []) + [Hint(keys: ["0"], name: "play all"), Hint(keys: ["scroll"], name: "volume")]
        }
    }

    var body: some View {
        HStack(spacing: style == .stems ? 11 : style == .footer ? 10 : 13) {
            ForEach(hints, id: \.name) { hint in
                HStack(spacing: 5) { keycaps(hint); name(hint) }
            }
        }
        .opacity(0.62)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func keycaps(_ hint: Hint) -> some View {
        HStack(spacing: 3) {
            ForEach(hint.keys, id: \.self) { Keycap(text: $0, palette: palette, small: style == .stems || style == .footer) }
        }
    }

    private func name(_ hint: Hint) -> some View {
        Text(hint.name)
            .font(.system(size: style == .footer ? 9.5 : 11, weight: .medium, design: .rounded))
            .foregroundStyle(palette.muted)
            // A row laid out at exactly its ideal width can come up a fraction short, which shortens a name to "…".
            .fixedSize()
    }
}

/// The keys of the waveform in place of `content` while the pointer is over the waveform, so that they cover nothing.
struct WaveformKeysSwap<Content: View>: View {
    @ObservedObject var wave: WaveState
    let alignment: Alignment
    /// The smaller keycaps of karaoke's footer, for the narrower card.
    var small = false
    let palette: Palette
    @ViewBuilder let content: Content

    var body: some View {
        let on = (wave.hovered || wave.loopEnd != nil) && wave.waveform != nil
        ZStack(alignment: alignment) {
            content.opacity(on ? 0 : 1)
            if on {
                KeyHints(style: small ? .footer : .band, waveform: true, lanes: wave.waveform?.stems != nil && Preferences.shared.waveformStyle == .ribbon,
                         loopEnd: wave.loopEnd, zoomed: wave.zoom > 1, otherMode: "", palette: palette)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

struct Keycap: View {
    let text: String
    let palette: Palette
    /// The size that fits inside a pill.
    var small = false

    var body: some View {
        Text(text)
            .font(.system(size: small ? 9 : 10, weight: .semibold, design: .rounded))
            // Brackets reach below the baseline, which centres them a point lower than the text beside the keycap.
            .offset(y: text == "[" || text == "]" ? -1 : 0)
            .foregroundStyle(palette.ink.opacity(0.8))
            .padding(.horizontal, small ? 3 : 4)
            .frame(minWidth: small ? 14 : 17, minHeight: small ? 13 : 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(palette.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.ink.opacity(0.18), lineWidth: 0.5))
            // Keeps its whole width in a row that offers less, instead of shortening the text to an ellipsis.
            .fixedSize()
    }
}

/// The menu bar item. Settings shows it always or only while a pitch change runs or Lock Key holds a key. It shows
/// the key that the song plays in when Muskey knows it, and a turntable when it doesn't.
final class StatusItem: NSObject {
    /// A turntable as a template silhouette: the record with its label cut out, and the tonearm on its right, in a
    /// rounded plinth. The old record with the twelve keys cut out of it read as a filled circle at this size.
    static let turntable: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            func disc(_ center: CGPoint, _ radius: CGFloat) -> CGRect {
                CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            }
            cg.setStrokeColor(.black)
            cg.setFillColor(.black)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineWidth(1.2)
            cg.addPath(CGPath(roundedRect: CGRect(x: 1.4, y: 2.4, width: 15.2, height: 13.2), cornerWidth: 2.8, cornerHeight: 2.8, transform: nil))
            cg.strokePath()
            let center = CGPoint(x: 7.4, y: 9)
            cg.fillEllipse(in: disc(center, 4.6))
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: disc(center, 1.5))
            // The tonearm gets a gap cut around it, so it stays apart from the record where it reaches it.
            let pivot = CGPoint(x: 13.3, y: 12.4)
            let arm = CGMutablePath()
            arm.move(to: pivot)
            arm.addLine(to: CGPoint(x: 13.3, y: 7.4))
            arm.addLine(to: CGPoint(x: 11.0, y: 5.4))
            cg.setLineWidth(2.75)
            cg.addPath(arm)
            cg.strokePath()
            cg.fillEllipse(in: disc(pivot, 1.85))
            cg.setBlendMode(.normal)
            cg.fillEllipse(in: disc(center, 0.55))
            cg.setLineWidth(1.25)
            cg.addPath(arm)
            cg.strokePath()
            cg.fillEllipse(in: disc(pivot, 1.1))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Muskey"
        return image
    }()

    private static var pills: [String: NSImage] = [:]
    private static let pillFont: NSFont = {
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? font
    }()

    /// The key in a rounded outline, written like the keys of the HUD: the tonic, with an m after it for a minor key.
    static func pill(_ key: DetectedKey) -> NSImage {
        let label = key.short
        if let image = pills[label] { return image }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: pillFont, .foregroundColor: NSColor.black]))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        // The ink of the letters, which the typographic width overstates on the right for a trailing m or ♯.
        let ink = CTLineGetImageBounds(line, nil)
        let size = NSSize(width: ceil(max(textWidth, ink.width) + 12), height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // A 1.5 point outline on whole points keeps its outer edge sharp at 1x and 2x. It is 16 points tall, about
            // as tall as the system's icons next to it.
            let outline = CGRect(x: 0, y: 1, width: size.width, height: 16).insetBy(dx: 0.75, dy: 0.75)
            cg.setStrokeColor(.black)
            cg.setLineWidth(1.5)
            cg.addPath(CGPath(roundedRect: outline, cornerWidth: 4.75, cornerHeight: 4.75, transform: nil))
            cg.strokePath()
            // Centred on the ink across, and on the cap height up and down, so every key sits on the same baseline
            // and a sharp or a flat rises above the letters instead of pushing them down. The baseline lands on a
            // whole pixel at 2x.
            let x = (size.width - ink.width) / 2 - ink.minX
            let y = ((outline.midY - pillFont.capHeight / 2) * 2).rounded() / 2
            cg.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, cg)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Muskey, \(key.name)"
        pills[label] = image
        return image
    }

    /// `--render-menubar FILE` draws the menu bar images at 2x on a dark and a light bar, next to system symbols and
    /// with the shift after them, then each key large, and prints how far each label sits from the middle of its
    /// outline.
    static func renderSheet(to path: String) {
        let keys = ["C", "Em", "E♭m", "F♯m", "B♭", "G♯m"].compactMap { DetectedKey(name: $0) }
        let width: CGFloat = 1000, height: CGFloat = 250
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
            NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        let barFont = NSFont.menuBarFont(ofSize: 0)
        let symbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let bars: [(NSColor, NSColor)] = [(NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.2, alpha: 1), .white),
                                          (NSColor(calibratedRed: 0.91, green: 0.91, blue: 0.93, alpha: 1), NSColor(white: 0, alpha: 0.85))]
        for (row, (background, ink)) in bars.enumerated() {
            let bar = NSRect(x: 16, y: height - 52 - CGFloat(row) * 40, width: width - 32, height: 28)
            background.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
            var x = bar.minX + 14
            func place(_ image: NSImage, title: String = "") {
                tinted(image, ink).draw(in: NSRect(x: x, y: bar.midY - image.size.height / 2, width: image.size.width, height: image.size.height))
                x += image.size.width
                if !title.isEmpty {
                    let text = NSAttributedString(string: title, attributes: [.font: barFont, .foregroundColor: ink])
                    x += 3
                    text.draw(at: NSPoint(x: x, y: bar.midY - barFont.capHeight / 2 + barFont.descender))
                    x += text.size().width
                }
                x += 16
            }
            if let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symbol) { place(sun) }
            place(turntable)
            for (i, key) in keys.enumerated() {
                place(pill(key), title: i == 3 ? "+2" : i == 4 ? "−3" : "")
            }
            if let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(symbol) { place(wifi) }
            NSAttributedString(string: "Mon 23:40", attributes: [.font: barFont, .foregroundColor: ink])
                .draw(at: NSPoint(x: x, y: bar.midY - barFont.capHeight / 2 + barFont.descender))
        }
        // Large, with a line through the middle of the outline.
        var x: CGFloat = 16
        for image in [turntable] + keys.map(pill) {
            let scale: CGFloat = 4.4
            let rect = NSRect(x: x, y: 24, width: image.size.width * scale, height: image.size.height * scale)
            NSColor.white.setFill()
            rect.fill()
            tinted(image, .black).draw(in: rect)
            NSColor.systemRed.withAlphaComponent(0.6).setFill()
            NSRect(x: rect.minX, y: rect.midY - 0.25, width: rect.width, height: 0.5).fill()
            x += rect.width + 10
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        for key in keys {
            let label = key.short
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: pillFont]))
            let ink = CTLineGetImageBounds(line, nil)
            let baseline = ((9 - pillFont.capHeight / 2) * 2).rounded() / 2
            print(String(format: "%@: baseline at %.1f, capitals from %.2f to %.2f, ink to %.2f, outline middle at 9", label, baseline, baseline,
                         baseline + pillFont.capHeight, baseline + ink.maxY))
        }
        print(path)
    }

    var onFindKey: () -> Void = {}
    var onChangeKey: () -> Void = {}
    var onKeep: () -> Void = {}
    var onStop: () -> Void = {}
    var onPlayAllStems: () -> Void = {}
    var onSettings: () -> Void = {}
    var onOpenFile: () -> Void = {}
    var onOpenLocation: () -> Void = {}
    var onStopPlaying: () -> Void = {}
    var onSave: () -> Void = {}
    var onAddFiles: () -> Void = {}
    var onAddLocation: () -> Void = {}
    var onMiniPlayer: () -> Void = {}
    private var item: NSStatusItem?

    /// Opens the menu as a click on the icon does, for `--open-menu-after`, since no automation can open it.
    func openMenu() { item?.button?.performClick(nil) }

    /// Picks the item with this title, for `--menu`, the way a click on it does. A title may leave out its "…", which
    /// a shell can mangle. False when the menu has none.
    func perform(_ title: String) -> Bool {
        guard let menu = item?.menu, let index = menu.items.firstIndex(where: { $0.title == title || $0.title == title + "…" }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// `heard` is the key that the song plays in, as the HUD names it, and `kept` the key that the next songs get.
    /// `current` is the key that the song playing now is heard in, with the pitch change, and nil while Muskey
    /// doesn't know it. `stems` lists the stems that play while the others are muted, and is nil while every stem plays.
    /// `playing` is true while Muskey Player has a song, which the menu can stop, so the icon shows then too.
    /// `savable` is true while the song can be saved with its changes.
    func update(shift: Int, from original: DetectedKey?, heard: DetectedKey?, kept: DetectedKey?, current: DetectedKey?, stems: [Stem]?,
                alwaysShown: Bool, playing: Bool, savable: Bool, miniPlayer: Bool, hotkey: Shortcut)
    {
        let changing = shift != 0 || kept != nil || stems != nil
        guard changing || alwaysShown || playing else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        let item = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            button.image = current.map(Self.pill) ?? Self.turntable
            button.imagePosition = .imageLeading
            button.title = shift == 0 ? "" : Shift.short(shift)
        }

        let menu = NSMenu()
        if changing {
            let header = if let original, let heard, shift != 0 { "\(original.name) → \(heard.name)" } else { heard?.name ?? Shift.text(shift) }
            menu.addItem(.sectionHeader(title: header))
            menu.addItem(menuItem("Change Key…", #selector(changeKey), hotkey: hotkey))
            let keep = menuItem("Lock Key for Next Songs", #selector(keep))
            keep.state = kept == nil ? .off : .on
            menu.addItem(keep)
            if let stems {
                let item = menuItem("Play All Stems", #selector(playAllStems))
                // Every stem plays when only their volumes changed.
                item.toolTip = stems.isEmpty ? "Every stem is muted"
                    : stems.count == Stem.shown.count ? "Stems at their own volumes" : "Playing only \(stems.map(\.name).joined(separator: ", "))"
                menu.addItem(item)
            }
            if shift != 0 || kept != nil { menu.addItem(menuItem("Stop Pitch Change", #selector(stop))) }
            menu.addItem(.separator())
            menu.addItem(menuItem("Find Key", #selector(findKey)))
        } else {
            menu.addItem(menuItem("Find Key", #selector(findKey), hotkey: hotkey))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Open File…", #selector(openFile), key: "o"))
        menu.addItem(menuItem("Open URL…", #selector(openLocation), key: "l"))
        // Songs added while Muskey Player plays wait in its queue.
        if playing {
            let files = menuItem("Add Files to Queue…", #selector(addFiles), key: "O")
            let link = menuItem("Add URL to Queue…", #selector(addLocation), key: "L")
            menu.addItem(files)
            menu.addItem(link)
        }
        if savable { menu.addItem(menuItem("Save Song…", #selector(save), key: "s")) }
        if playing { menu.addItem(menuItem("Stop Playing", #selector(stopPlaying))) }
        menu.addItem(.separator())
        let mini = menuItem("Mini Player", #selector(toggleMiniPlayer))
        mini.state = miniPlayer ? .on : .off
        menu.addItem(mini)
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(settings), key: ","))
        menu.addItem(menuItem("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Muskey", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
        item.menu = menu
    }

    /// The hotkey is global, so the menu only shows it.
    private func menuItem(_ title: String, _ action: Selector, key: String = "", hotkey: Shortcut? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let hotkey {
            item.keyEquivalent = hotkey.keyEquivalent.key
            item.keyEquivalentModifierMask = hotkey.keyEquivalent.modifiers
        }
        return item
    }

    @objc private func findKey() { onFindKey() }
    @objc private func changeKey() { onChangeKey() }
    @objc private func keep() { onKeep() }
    @objc private func stop() { onStop() }
    @objc private func save() { onSave() }
    @objc private func playAllStems() { onPlayAllStems() }
    @objc private func settings() { onSettings() }
    @objc private func openFile() { onOpenFile() }
    @objc private func openLocation() { onOpenLocation() }
    @objc private func stopPlaying() { onStopPlaying() }
    @objc private func addFiles() { onAddFiles() }
    @objc private func addLocation() { onAddLocation() }
    @objc private func toggleMiniPlayer() { onMiniPlayer() }
    @objc private func checkForUpdates() { Updates.shared.check() }
}
