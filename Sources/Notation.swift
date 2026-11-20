import AppKit
import Foundation

/// How the notes of a stem are shown in the notes window: tab for bass and guitar, a staff for piano and the other
/// pitched stems, and a piano roll for drums and anything else.
enum NotesView: String, CaseIterable, Identifiable {
    case tab, sheet, roll

    var id: String { rawValue }

    var name: String {
        switch self {
        case .tab: "Tab"
        case .sheet: "Sheet"
        case .roll: "Piano roll"
        }
    }

    static func preferred(for stem: Stem) -> NotesView {
        switch stem {
        case .bass, .guitar: .tab
        case .piano, .vocals, .winds: .sheet
        case .drums, .other: .roll
        }
    }
}

/// The notes of one stem placed on the song's beats: each note gets a bar and a place in it, rounded to a sixteenth,
/// and a string and a fret for tab. Dettato finds no metre and no downbeat, so every bar has four beats and the
/// first beat that the beat tracker found starts the first bar.
struct Score: Sendable {
    struct Note: Sendable, Equatable {
        let pitch: Int
        let start: Double
        let end: Double
        let drum: Bool
        let program: Int
        /// The bar, and the place in it in beats from 0 to 4, rounded to a sixteenth.
        let bar: Int
        let beat: Double
        /// The length in beats, rounded to a sixteenth, at least one sixteenth.
        let length: Double
        var string: Int?
        var fret: Int?
    }

    struct Bar: Sendable, Equatable {
        let index: Int
        let start: Double
        let end: Double
    }

    static let beatsPerBar = 4

    let stem: Stem
    let notes: [Note]
    let bars: [Bar]
    let beats: [Double]
    let bpm: Double
    let key: DetectedKey?
    /// The open strings for tab, lowest first, as MIDI notes: standard tuning for guitar and for a four-string bass.
    let tuning: [Int]

    static func tuning(for stem: Stem) -> [Int] { stem == .bass ? [28, 33, 38, 43] : [40, 45, 50, 55, 59, 64] }

    init(notes raw: [TranscribedNote], stem: Stem, beats: [Double], bpm: Double, key: DetectedKey?, duration: Double) {
        self.stem = stem
        self.key = key
        self.bpm = bpm
        tuning = Self.tuning(for: stem)
        let grid = Self.grid(beats: beats, bpm: bpm, until: max(duration, raw.map(\.end).max() ?? 0) + 2)
        self.beats = grid
        let barCount = max(1, (grid.count - 1) / Self.beatsPerBar)
        bars = (0 ..< barCount).map { index in
            Bar(index: index, start: grid[index * Self.beatsPerBar], end: grid[min(grid.count - 1, (index + 1) * Self.beatsPerBar)])
        }
        let placed: [Note] = raw.compactMap { note in
            let position = Self.position(of: note.start, in: grid)
            let start = (position * 4).rounded() / 4
            let end = (Self.position(of: note.end, in: grid) * 4).rounded() / 4
            guard start >= 0 else { return nil }
            let bar = Int(start) / Self.beatsPerBar
            guard bar < barCount else { return nil }
            return Note(pitch: note.pitch, start: note.start, end: note.end, drum: note.drum, program: note.program, bar: bar,
                        beat: start - Double(bar * Self.beatsPerBar), length: max(0.25, end - start))
        }
        notes = stem == .bass || stem == .guitar ? Self.fret(placed, tuning: tuning) : placed
    }

    /// The beats with the gaps that the tracker left filled at the song's tempo, from the start of the song to its end.
    private static func grid(beats: [Double], bpm: Double, until end: Double) -> [Double] {
        let interval: Double = {
            let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
            if !gaps.isEmpty { return gaps[gaps.count / 2] }
            return bpm > 0 ? 60 / bpm : 0.5
        }()
        var grid = beats.isEmpty ? [0.0] : beats
        // Bars before the first beat, so that notes in a pickup have a place.
        while let first = grid.first, first - interval * Double(beatsPerBar) > -interval / 2 {
            grid.insert(contentsOf: (1 ... beatsPerBar).reversed().map { first - interval * Double($0) }, at: 0)
        }
        while let last = grid.last, last < end {
            grid.append(last + interval)
        }
        // Whole bars.
        while (grid.count - 1) % beatsPerBar != 0, let last = grid.last {
            grid.append(last + interval)
        }
        return grid
    }

    /// The place of `time` in beats from the first beat of the grid.
    static func position(of time: Double, in grid: [Double]) -> Double {
        guard grid.count > 1 else { return 0 }
        if time <= grid[0] { return (time - grid[0]) / (grid[1] - grid[0]) }
        var low = 0, high = grid.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if grid[middle] <= time { low = middle } else { high = middle }
        }
        let span = grid[high] - grid[low]
        return Double(low) + (span > 0 ? min(1, (time - grid[low]) / span) : 0)
    }

    /// The time of a place in beats, the opposite of `position`.
    func time(at position: Double) -> Double {
        guard beats.count > 1 else { return 0 }
        let index = max(0, min(beats.count - 2, Int(position.rounded(.down))))
        return beats[index] + (beats[index + 1] - beats[index]) * (position - Double(index))
    }

    /// The bar that plays at `time`, and how far into it, from 0 to 1.
    func place(at time: Double) -> (bar: Int, fraction: Double)? {
        let position = Self.position(of: time, in: beats)
        guard position >= 0 else { return nil }
        let bar = Int(position) / Self.beatsPerBar
        guard bar < bars.count else { return nil }
        return (bar, (position - Double(bar * Self.beatsPerBar)) / Double(Self.beatsPerBar))
    }

    /// A string and a fret for every note, keeping the hand near where it was: notes that start together go on
    /// different strings, the highest note on the highest string that can play it.
    private static func fret(_ notes: [Note], tuning: [Int]) -> [Note] {
        var result: [Note] = []
        var hand = 3.0
        let groups = Dictionary(grouping: notes.indices) { notes[$0].bar * 64 + Int(notes[$0].beat * 4) }
        for key in groups.keys.sorted() {
            var taken = Set<Int>()
            for index in groups[key]!.sorted(by: { notes[$0].pitch > notes[$1].pitch }) {
                var note = notes[index]
                let options = tuning.indices.compactMap { string -> (string: Int, fret: Int, cost: Double)? in
                    let fret = note.pitch - tuning[string]
                    guard (0 ... 20).contains(fret), !taken.contains(string) else { return nil }
                    // Open strings are easy, and high frets far from the hand are not.
                    return (string, fret, fret == 0 ? 0.5 : abs(Double(fret) - hand))
                }
                if let best = options.min(by: { $0.cost < $1.cost }) {
                    note.string = best.string
                    note.fret = best.fret
                    taken.insert(best.string)
                    if best.fret > 0 { hand = hand * 0.6 + Double(best.fret) * 0.4 }
                }
                result.append(note)
            }
        }
        return result.sorted { ($0.bar, $0.beat, $0.pitch) < ($1.bar, $1.beat, $1.pitch) }
    }

    /// The notes of each bar, in one pass.
    var notesByBar: [[Note]] {
        var byBar = [[Note]](repeating: [], count: bars.count)
        for note in notes where byBar.indices.contains(note.bar) { byBar[note.bar].append(note) }
        return byBar
    }
}

// MARK: Spelling

/// Note names in the key of the song: its key signature, and the letter, accidental and staff step of each pitch.
struct Spelling {
    /// Pitch classes that the key signature raises or lowers, and whether it uses flats.
    let flats: Bool
    let signature: [Int]

    private static let sharpOrder = [5, 0, 7, 2, 9, 4, 11]
    private static let flatOrder = [11, 4, 9, 2, 7, 0, 5]

    init(key: DetectedKey?) {
        // The major key with the same notes: the relative major of a minor key.
        let major = key.map { $0.minor ? ($0.pitchClass + 3) % 12 : $0.pitchClass } ?? 0
        let sharps = [0: 0, 7: 1, 2: 2, 9: 3, 4: 4, 11: 5, 6: 6]
        let flats = [5: 1, 10: 2, 3: 3, 8: 4, 1: 5]
        if let count = sharps[major] {
            self.flats = false
            signature = Array(Self.sharpOrder.prefix(count))
        } else {
            self.flats = true
            signature = Array(Self.flatOrder.prefix(flats[major] ?? 0))
        }
    }

    /// The letter (0 = C .. 6 = B) and the octave of `pitch`, and the accidental it needs in this key: nil for none,
    /// "♯", "♭" or "♮".
    func spell(_ pitch: Int) -> (step: Int, accidental: String?) {
        let pitchClass = ((pitch % 12) + 12) % 12
        let octave = pitch / 12 - 1
        let naturals = [0: 0, 2: 1, 4: 2, 5: 3, 7: 4, 9: 5, 11: 6]
        if let letter = naturals[pitchClass] {
            // A natural note whose letter the signature alters needs a natural sign.
            let altered = signature.contains { flats ? ($0 + 1) % 12 == pitchClass : ($0 + 11) % 12 == pitchClass }
            return (octave * 7 + letter, altered ? "♮" : nil)
        }
        let inSignature = signature.contains(pitchClass)
        if flats {
            let letter = naturals[(pitchClass + 1) % 12]!
            return (octave * 7 + letter, inSignature ? nil : "♭")
        }
        let letter = naturals[(pitchClass + 11) % 12]!
        return (octave * 7 + letter, inSignature ? nil : "♯")
    }
}

// MARK: Exports

extension Score {
    /// MusicXML with one part on one staff, four beats a bar and a sixteenth as the smallest note. Notes that start
    /// together are written as a chord, as long as the shortest of them, and gaps are rests.
    func musicXML(title: String) -> String {
        let divisions = 4
        let spelling = Spelling(key: key)
        let fifths = spelling.flats ? -spelling.signature.count : spelling.signature.count
        let pitches = notes.filter { !$0.drum }.map(\.pitch).sorted()
        let median = pitches.isEmpty ? 60 : pitches[pitches.count / 2]
        let bass = stem == .bass || median < 55
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func pitchXML(_ pitch: Int) -> String {
            let names = ["C", "D", "E", "F", "G", "A", "B"]
            let step = spelling.spell(pitch).step
            let natural = [0, 2, 4, 5, 7, 9, 11][((step % 7) + 7) % 7]
            let octave = step >= 0 ? step / 7 : (step - 6) / 7
            let alter = ((pitch - (octave + 1) * 12 - natural) + 18) % 12 - 6
            return "<pitch><step>\(names[((step % 7) + 7) % 7])</step>\(alter != 0 ? "<alter>\(alter)</alter>" : "")<octave>\(octave)</octave></pitch>"
        }
        func type(_ sixteenths: Int) -> (String, Bool) {
            switch sixteenths {
            case 16: ("whole", false)
            case 12: ("half", true)
            case 8: ("half", false)
            case 6: ("quarter", true)
            case 4: ("quarter", false)
            case 3: ("eighth", true)
            case 2: ("eighth", false)
            default: ("16th", false)
            }
        }
        /// Splits a length into lengths that one note can have.
        func pieces(_ sixteenths: Int) -> [Int] {
            var left = sixteenths, out: [Int] = []
            for size in [16, 12, 8, 6, 4, 3, 2, 1] {
                while left >= size {
                    out.append(size)
                    left -= size
                }
            }
            return out
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <work><work-title>\(escape(title))</work-title></work>
          <part-list><score-part id="P1"><part-name>\(escape(stem.name))</part-name></score-part></part-list>
          <part id="P1">

        """
        for (index, barNotes) in notesByBar.enumerated() {
            xml += "    <measure number=\"\(index + 1)\">\n"
            if index == 0 {
                xml += "      <attributes><divisions>\(divisions)</divisions><key><fifths>\(fifths)</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time>"
                xml += bass ? "<clef><sign>F</sign><line>4</line></clef>" : "<clef><sign>G</sign><line>2</line></clef>"
                xml += "</attributes>\n"
                xml += "      <direction placement=\"above\"><sound tempo=\"\(Int(bpm.rounded()))\"/></direction>\n"
            }
            let groups = Dictionary(grouping: barNotes) { Int(($0.beat * 4).rounded()) }
            let onsets = groups.keys.sorted()
            var at = 0
            for (position, onset) in onsets.enumerated() {
                if onset > at {
                    for rest in pieces(onset - at) {
                        let (name, dot) = type(rest)
                        xml += "      <note><rest/><duration>\(rest)</duration><type>\(name)</type>\(dot ? "<dot/>" : "")</note>\n"
                    }
                }
                let next = position + 1 < onsets.count ? onsets[position + 1] : 16
                let chord = groups[onset]!.sorted { $0.pitch < $1.pitch }
                let length = max(1, min(next - onset, chord.map { Int(($0.length * 4).rounded()) }.min() ?? 1, 16 - onset))
                let parts = pieces(length)
                for (part, size) in parts.enumerated() {
                    let (name, dot) = type(size)
                    for (member, note) in chord.enumerated() {
                        xml += "      <note>\(member > 0 ? "<chord/>" : "")\(note.drum ? "<unpitched><display-step>C</display-step><display-octave>5</display-octave></unpitched>" : pitchXML(note.pitch))"
                        xml += "<duration>\(size)</duration>"
                        if parts.count > 1 { xml += part < parts.count - 1 ? "<tie type=\"start\"/>" : "<tie type=\"stop\"/>" }
                        xml += "<type>\(name)</type>\(dot ? "<dot/>" : "")</note>\n"
                    }
                }
                at = onset + length
            }
            if at < 16 {
                for rest in pieces(16 - at) {
                    let (name, dot) = type(rest)
                    xml += "      <note><rest/><duration>\(rest)</duration><type>\(name)</type>\(dot ? "<dot/>" : "")</note>\n"
                }
            }
            xml += "    </measure>\n"
        }
        xml += "  </part>\n</score-partwise>\n"
        return xml
    }

    /// A standard MIDI file of format 0: the song's tempo, and each note at its place in the bars, 480 ticks a beat.
    var midi: Data {
        let ticksPerBeat = 480
        var events: [(tick: Int, bytes: [UInt8])] = []
        let channel: UInt8 = notes.contains { $0.drum } && notes.allSatisfy(\.drum) ? 9 : 0
        let tempo = Int((60_000_000 / max(20, bpm)).rounded())
        events.append((0, [0xFF, 0x51, 0x03, UInt8((tempo >> 16) & 0xFF), UInt8((tempo >> 8) & 0xFF), UInt8(tempo & 0xFF)]))
        events.append((0, [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]))
        if channel != 9, let program = notes.first?.program { events.append((0, [0xC0 | channel, UInt8(max(0, min(127, program)))])) }
        for note in notes {
            let start = Int(((Double(note.bar * Self.beatsPerBar) + note.beat) * Double(ticksPerBeat)).rounded())
            let end = start + max(1, Int((note.length * Double(ticksPerBeat)).rounded()))
            let pitch = UInt8(max(0, min(127, note.pitch)))
            events.append((start, [0x90 | channel, pitch, 96]))
            events.append((end, [0x80 | channel, pitch, 0]))
        }
        // Note offs before note ons at the same tick, so a repeated note sounds twice.
        events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : ($0.bytes[0] & 0xF0) == 0x80 && ($1.bytes[0] & 0xF0) != 0x80 }
        var track: [UInt8] = []
        var last = 0
        func variable(_ value: Int) -> [UInt8] {
            var value = value, bytes = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
                value >>= 7
            }
            return bytes
        }
        for event in events {
            track += variable(event.tick - last) + event.bytes
            last = event.tick
        }
        track += [0x00, 0xFF, 0x2F, 0x00]
        func be32(_ value: Int) -> [UInt8] { [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
        var data: [UInt8] = Array("MThd".utf8) + be32(6) + [0, 0, 0, 1, UInt8(ticksPerBeat >> 8), UInt8(ticksPerBeat & 0xFF)]
        data += Array("MTrk".utf8) + be32(track.count) + track
        return Data(data)
    }

    /// Plain text tab, four bars a line, with a sixteenth for each dash: the highest string at the top, as tabs are
    /// written.
    var textTab: String {
        let names = tuning.map { ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][$0 % 12] }
        let byBar = notesByBar
        var lines: [String] = []
        for first in stride(from: 0, to: bars.count, by: 4) {
            var rows = tuning.indices.reversed().map { string in (names[string] == "E" && string == tuning.count - 1 ? "e" : names[string]).padding(toLength: 2, withPad: " ", startingAt: 0) + "|" }
            for bar in first ..< min(bars.count, first + 4) {
                var cells = [[String]](repeating: [String](repeating: "-", count: 16), count: tuning.count)
                for note in byBar[bar] {
                    guard let string = note.string, let fret = note.fret else { continue }
                    let slot = min(15, Int((note.beat * 4).rounded()))
                    cells[string][slot] = "\(fret)"
                }
                for (row, string) in tuning.indices.reversed().enumerated() {
                    var text = ""
                    var skip = 0
                    for cell in cells[string] {
                        if skip > 0 {
                            skip -= 1
                            continue
                        }
                        text += cell
                        // A fret of two digits takes the place of the dash after it.
                        if cell.count > 1 { skip = cell.count - 1 }
                    }
                    rows[row] += text + "|"
                }
            }
            lines += rows
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
