import Accelerate
import AVFoundation

/// The tempo of a song, from a listen or from Noiseblend, for the pill under the key.
struct SongTempo: Equatable {
    let song: [String?]?
    let bpm: Double
    /// Noiseblend's tempo, which no listen found yet.
    var online = false

    /// `128 BPM`: tempos are whole numbers on every DJ app and in Spotify's data.
    var text: String { "\(Int(bpm.rounded())) BPM" }
}

/// Finds the tempo of the audio that a listen heard, with Essentia's RhythmExtractor2013.
enum TempoDetector {
    /// Essentia's RhythmExtractor2013 works only on audio at 44.1 kHz.
    static let rate = 44100.0
    static let method = "multifeature"
    /// Fewer seconds than this hold too few beats for a tempo.
    static let shortest = 6.0

    /// The tempo of mono `samples` at `sourceRate`, or nil when no beat was found.
    static func bpm(_ samples: [Float], sourceRate: Double) -> (bpm: Double, confidence: Float)? {
        guard Double(samples.count) / sourceRate >= shortest else { return nil }
        let audio = sourceRate == rate ? samples : resample(samples, from: sourceRate, to: rate)
        guard !audio.isEmpty else { return nil }
        let result = audio.withUnsafeBufferPointer { ek_tempo($0.baseAddress, UInt32($0.count), method) }
        return result.bpm > 0 ? (Double(result.bpm), result.confidence) : nil
    }

    /// Mono Float32 from one rate to another with AVAudioConverter, which filters out what the lower rate can't hold.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float] {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount((Double(samples.count) * target / source).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// The tempo to show for a listen that heard `heard`, next to Noiseblend's. Spotify's tempo is measured over the
    /// whole song, so it wins when the two agree, and also when the listen found half or double of it, or a third or
    /// three times: the beats were counted at another level, and Spotify's level is the one that people count along
    /// to. A tempo far from all of those comes from another song, or from a part of the song at another tempo, so the
    /// listen's tempo is kept. Essentia's confidence decides nothing here, since it doesn't tell a right tempo from a
    /// wrong one.
    static func reconcile(heard: Double, online: Double?) -> Double {
        guard let online, online > 0 else { return heard }
        let related = [1.0, 2, 0.5, 3, 1.0 / 3].contains { abs(heard * $0 - online) / online <= 0.04 }
        return related ? online : heard
    }

    /// Prints the tempo of `seconds` of the file from `start`, mixed to mono and resampled to the 48 kHz of the tap,
    /// for `--tempo`. Returns the exit code.
    static func printTempo(of path: String, from start: Double, seconds: Double) -> Int32 {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            print("can't read \(path)")
            return 1
        }
        let fileRate = file.processingFormat.sampleRate
        file.framePosition = min(AVAudioFramePosition(start * fileRate), max(0, file.length - AVAudioFramePosition(seconds * fileRate)))
        let frames = AVAudioFrameCount(min(Double(file.length - file.framePosition), seconds * fileRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames), (try? file.read(into: buffer, frameCount: frames)) != nil,
              let channels = buffer.floatChannelData
        else {
            print("can't decode \(path)")
            return 1
        }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: count)
        for channel in 0 ..< channelCount {
            for i in 0 ..< count { mono[i] += channels[channel][i] / Float(channelCount) }
        }
        let tapped = fileRate == 48000 ? mono : resample(mono, from: fileRate, to: 48000)
        let started = Date()
        let found = bpm(tapped, sourceRate: 48000)
        print(String(format: "tempo: %@  confidence %.2f  %.2fs", found.map { String(format: "%.1f BPM", $0.bpm) } ?? "none", found?.confidence ?? 0,
                     Date().timeIntervalSince(started)))
        return 0
    }
}

extension KeyAnalyzer {
    /// The longest part of a file that `read` decodes, from its start.
    static let fileLimit = 600.0

    /// The key, the peak and the tempo of a song's file, read from the file instead of heard as it plays: the whole
    /// song up to 10 minutes, mixed to mono at the file's rate. A song shorter than a listen gets its key from all of
    /// it. Nil when the file can't be decoded.
    static func read(_ path: String) -> (result: EKResult, peak: Float, tempo: (bpm: Double, confidence: Float)?, seconds: Double)? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let rate = file.processingFormat.sampleRate
        let total = AVAudioFrameCount(min(Double(file.length), fileLimit * rate))
        let chunk: AVAudioFrameCount = 1 << 16
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        var mono = [Float]()
        mono.reserveCapacity(Int(total))
        var peak: Float = 0
        while mono.count < Int(total) {
            let wanted = min(chunk, total - AVAudioFrameCount(mono.count))
            guard (try? file.read(into: buffer, frameCount: wanted)) != nil, buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
            var mixed = [Float](repeating: 0, count: count)
            for channel in 0 ..< channelCount {
                vDSP_vsma(channels[channel], 1, [1 / Float(channelCount)], mixed, 1, &mixed, 1, vDSP_Length(count))
            }
            peak = max(peak, vDSP.maximumMagnitude(mixed))
            mono += mixed
        }
        guard !mono.isEmpty else { return nil }
        // A recording from the microphone gets its key from its music only, without the talk and the noise around it.
        if let ranges = RecordingStore.keyRanges(forSong: path) {
            var music = [Float]()
            for range in ranges {
                let from = max(0, Int(range.lowerBound * rate)), to = min(mono.count, Int(range.upperBound * rate))
                if from < to { music += mono[from ..< to] }
            }
            if !music.isEmpty { mono = music }
        }
        let result = mono.withUnsafeBufferPointer { ek_key($0.baseAddress, UInt32($0.count), rate, profile) }
        let tempo = peak >= 0.0005 ? TempoDetector.bpm(mono, sourceRate: rate) : nil
        return (result, peak, tempo, Double(mono.count) / rate)
    }
}
