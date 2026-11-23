import Accelerate
import AVFoundation
import Foundation

/// The part of the song that the region loop repeats: its start, and its end once the second press set it. The
/// moments where R was pressed are kept for a moment, for the dashed lines that show how far each end was snapped.
struct LoopRegion: Equatable {
    var start: Double
    var end: Double?
    var startPress: Double?
    var endPress: Double?

    var length: Double? { end.map { $0 - start } }

    /// A click on an arrow beside an end, or ← and → over its tab, moves the end by this many seconds, and by a beat
    /// with ⌥.
    static let nudge = 0.02

    func time(of end: LoopEnd) -> Double? { end == .start ? start : self.end }

    /// The loop repeats the whole song, as ⇧R sets it.
    func coversSong(_ duration: Double?) -> Bool {
        guard let end, let duration, duration > 0 else { return false }
        return start <= 0.05 && end >= duration - 0.05
    }

    /// The ends stay in the song, and at least a quarter of a second apart.
    func clamped(_ end: LoopEnd, _ time: Double, duration: Double) -> Double {
        switch end {
        case .start: min(max(0, time), (self.end ?? duration) - 0.25)
        case .end: max(min(duration, time), start + 0.25)
        }
    }
}

/// One end of the region loop.
enum LoopEnd: Hashable {
    case start, end
}

/// Where the ends of the region loop land. People press late, so each end goes to the strongest attack from 0.4
/// seconds before the press to 0.15 seconds after it. A beat of the song's beat grid that close wins over a plain
/// attack, and an attack within 40 ms of that beat gives its exact moment. The length is then rounded to whole beats,
/// or to whole bars when it is within a beat of one.
enum LoopSnap {
    static let rate = 44100.0
    static let before = 0.4
    static let after = 0.15

    struct Grid {
        var beats: [Double] = []
        var onsets: [Double] = []
        var strengths: [Float] = []
        var bpm: Double?
    }

    /// The beats and the attacks in `samples` (mono at 44.1 kHz), in song seconds from `start`.
    static func grid(_ samples: [Float], start: Double) -> Grid {
        var grid = Grid()
        guard samples.count > Int(rate) else { return grid }
        samples.withUnsafeBufferPointer { buffer in
            let count = UInt32(buffer.count)
            // A beat grid needs a few bars of song, and the tempo detection gives nothing on less.
            if Double(buffer.count) >= 6 * rate {
                var ticks = [Float](repeating: 0, count: 1024)
                var bpm: Float = 0
                let found = Int(ek_beats(buffer.baseAddress, count, &ticks, Int32(ticks.count), &bpm))
                grid.beats = ticks.prefix(found).map { start + Double($0) }
                if bpm > 0 { grid.bpm = Double(bpm) }
            }
            var onsets = [Float](repeating: 0, count: 4096)
            let found = Int(ek_onsets(buffer.baseAddress, count, &onsets, Int32(onsets.count)))
            for onset in onsets.prefix(found) {
                // How much louder the 25 ms after the attack are than the 25 ms before it.
                let at = Int(Double(onset) * rate), span = Int(0.025 * rate)
                let rms = { (from: Int) -> Float in
                    let a = max(0, from), b = min(buffer.count, from + span)
                    guard b > a else { return 0 }
                    var squares: Float = 0
                    vDSP_svesq(buffer.baseAddress! + a, 1, &squares, vDSP_Length(b - a))
                    return (squares / Float(b - a)).squareRoot()
                }
                grid.onsets.append(start + Double(onset))
                grid.strengths.append(max(0, rms(at) - rms(at - span)))
            }
        }
        return grid
    }

    /// The moment for a press at `t`.
    static func snap(_ t: Double, grid: Grid) -> Double {
        let window = (t - before) ... (t + after)
        let attacks = zip(grid.onsets, grid.strengths).filter { window.contains($0.0) }
        let strongest = attacks.max { $0.1 < $1.1 }?.0
        if let beat = grid.beats.filter({ window.contains($0) }).min(by: { abs($0 - (strongest ?? t)) < abs($1 - (strongest ?? t)) }) {
            return exact(beat, grid: grid)
        }
        return strongest ?? t
    }

    /// The end for a press at `t`, with the length from `start` rounded to whole beats, or to whole bars within a
    /// beat of one. The tempo is the beat grid's when the grids around both ends agree on it, since they measured this
    /// part of the song, and otherwise the song's tempo from a listen. A rounded end that would land more than about
    /// half a beat from the press is dropped for the plain snap, so a wrong tempo can't move the end far.
    static func snapEnd(_ t: Double, start: Double, grid: Grid, bpm: Double?, startBPM: Double? = nil) -> Double {
        let end = snap(t, grid: grid)
        let tempo: Double? = if let a = startBPM, let b = grid.bpm, abs(a / b - 1) < 0.04 { (a + b) / 2 } else { bpm ?? startBPM ?? grid.bpm }
        guard let tempo, tempo > 30, tempo < 300 else { return end }
        let beat = 60 / tempo
        var beats = max(1, ((end - start) / beat).rounded())
        let bars = (beats / 4).rounded() * 4
        if bars >= 4, abs(beats - bars) <= 1 { beats = bars }
        var target = start + beats * beat
        // The grid's own beat next to the count is more exact than the count, since tempos drift a little.
        if let closest = grid.beats.min(by: { abs($0 - target) < abs($1 - target) }), abs(closest - target) < beat / 4 {
            target = exact(closest, grid: grid)
        }
        return abs(target - t) <= max(before, beat * 0.6) ? target : end
    }

    /// An attack within 40 ms of `beat` gives its exact moment, since the beat tracker's ticks can sit a little off.
    private static func exact(_ beat: Double, grid: Grid) -> Double {
        let near = grid.onsets.filter { abs($0 - beat) < 0.04 }
        return near.min { abs($0 - beat) < abs($1 - beat) } ?? beat
    }

    /// Mono samples at 44.1 kHz from `from` to `to` seconds of the file at `url`.
    static func excerpt(_ url: URL, from: Double, to: Double) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let start = max(0, from)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 44100), duration: CMTime(seconds: max(0.1, to - start), preferredTimescale: 44100))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var size = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &size, dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: size / 4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: size / 4)) }
        }
        return samples
    }
}
