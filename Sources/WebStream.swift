import Foundation
import os

private let log = Logger(subsystem: LOG_SUBSYSTEM, category: "WebStream")

/// The Mac's output for the phones that picked **Phone** in the web remote. The pitch change copies what it plays into
/// a ring, and every 20 ms the frames written since are sent to each phone as AAC in ADTS frames (about 160 kbps), or
/// as 16-bit stereo PCM to a browser that can't decode AAC itself, which the page plays with Web Audio about a quarter
/// of a second later. While the pitch change doesn't run, silence goes out at the
/// same pace, so a phone never runs out.
final class WebStream: @unchecked Sendable {
    static let shared = WebStream()

    /// Eight seconds at 48 kHz, which the pitch change writes into from its audio thread.
    let ring: OpaquePointer = ps_stream_create(8 * 48000)

    /// The rate of the frames in the ring: the output device's, set when the pitch change starts. A phone that
    /// listens at another rate is sent away, and the page connects again at the new one.
    var rate: Double {
        get { lock.withLock { frameRate } }
        set { lock.withLock { frameRate = newValue } }
    }

    /// True on the main thread when the first phone starts listening, false a few seconds after the last one left.
    var onListening: (Bool) -> Void = { _ in }

    var listeners: Int { queue.sync { sinks.count } }

    func add(_ sink: WebSink, aac: Bool = false) -> Double {
        let rate = rate
        queue.async { [self] in
            sink.ended = { [weak self, weak sink] in self?.queue.async { self?.drop(sink) } }
            sinks.append((sink, rate, aac))
            endWork?.cancel()
            endWork = nil
            if timer == nil {
                ps_stream_skip(ring)
                lastWritten = ps_stream_written(ring)
                lastFrames = .distantPast
                silentUntil = Date()
                start()
                DispatchQueue.main.async { [onListening] in onListening(true) }
            }
            log.info("remote: a phone listens (\(self.sinks.count) now, \(Int(rate)) Hz)")
        }
        return rate
    }

    private let lock = NSLock()
    private var frameRate: Double = 48000
    private let queue = DispatchQueue(label: "muskey.web.stream", qos: .userInteractive)
    private var sinks: [(sink: WebSink, rate: Double, aac: Bool)] = []
    /// One encoder for every phone that takes AAC, made again when the rate changes.
    private var encoder: ADTSEncoder?
    private var timer: DispatchSourceTimer?
    private var endWork: DispatchWorkItem?
    private var lastWritten: UInt64 = 0
    private var lastFrames = Date.distantPast
    /// How far the silence sent while nothing is written reaches.
    private var silentUntil = Date()
    private var samples = [Int16](repeating: 0, count: 2 * 24000)

    private func drop(_ sink: WebSink?) {
        sinks.removeAll { $0.sink === sink || $0.sink.closed }
        log.info("remote: a phone stopped listening (\(self.sinks.count) left)")
        guard sinks.isEmpty, endWork == nil else { return }
        // Safari may close the stream and open it again, so the Mac waits a moment before it plays out loud again.
        let work = DispatchWorkItem { [self] in
            endWork = nil
            guard sinks.isEmpty else { return }
            timer?.cancel()
            timer = nil
            DispatchQueue.main.async { [onListening] in onListening(false) }
        }
        endWork = work
        queue.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let rate = rate
        // A phone at another rate connects again and learns the new one.
        for listener in sinks where listener.rate != rate { listener.sink.close() }
        sinks.removeAll { $0.sink.closed }

        var chunk = Data()
        let written = ps_stream_written(ring)
        if written != lastWritten {
            lastWritten = written
            lastFrames = now
            silentUntil = now
            samples.withUnsafeMutableBufferPointer { buffer in
                for _ in 0 ..< 16 {
                    let frames = ps_stream_read(ring, buffer.baseAddress!, buffer.count / 2)
                    guard frames > 0 else { break }
                    chunk.append(UnsafeBufferPointer(start: buffer.baseAddress, count: frames * 2))
                }
            }
        } else if now.timeIntervalSince(lastFrames) > 0.12 {
            // The pitch change stopped, or hasn't started yet: silence, paced by the clock.
            let seconds = min(now.timeIntervalSince(silentUntil), 0.5)
            let frames = Int(seconds * rate)
            if frames > 0 {
                chunk = Data(count: frames * 4)
                silentUntil = silentUntil.addingTimeInterval(Double(frames) / rate)
            }
        }
        guard !chunk.isEmpty else { return }
        var encoded: Data?
        if sinks.contains(where: \.aac) {
            if encoder?.rate != rate { encoder = ADTSEncoder(rate: rate) }
            encoded = encoder.map { encoder in chunk.withUnsafeBytes { encoder.encode($0.bindMemory(to: Int16.self)) } }
        } else {
            encoder = nil
        }
        for listener in sinks {
            if listener.aac {
                // A rate that ADTS can't name closes the stream, and the page asks for PCM next.
                guard let encoded else {
                    listener.sink.close()
                    continue
                }
                if !encoded.isEmpty { listener.sink.send(encoded) }
            } else {
                listener.sink.send(chunk)
            }
        }
    }
}
