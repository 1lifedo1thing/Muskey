import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Shifts the pitch of everything the Mac plays, except Muskey itself, at the same tempo.
/// A process tap mutes the original while it runs, and a private aggregate device on the default output plays
/// the shifted mix. Main thread only, apart from the IOProc. Adapted from PitchTap's TapEngine.
final class PitchChanger {
    var semitones = 0 {
        didSet { if let shifter { ps_set_semitones(shifter, shifted) } }
    }

    /// Semitones added to the shift, to undo the pitch change of a song that Muskey Player plays faster or slower:
    /// 2.81 for a song at 85 % of its speed.
    var correction = 0.0 {
        didSet { if let shifter { ps_set_semitones(shifter, shifted) } }
    }

    private var shifted: Float { Float(Double(semitones) + correction) }

    var running: Bool { aggregateID != kAudioObjectUnknown }

    /// Callbacks since `start()` that ran out of shifted audio and played silence, for the log.
    private(set) var gaps: UInt64 = 0

    /// Called when a rebuild after an output device change fails; the pitch change has stopped by then.
    var onFailure: ((Error) -> Void)?

    /// Stems that don't play. While any is muted, the output plays the other stems, separated a few seconds behind
    /// the song, in place of the song.
    var mutedStems: Set<Stem> = [] {
        didSet { applyStems() }
    }
    /// Seconds that the next change of `mutedStems` fades over: 20 ms for keys and clicks, longer for karaoke's vocals.
    var stemsFade = 0.02 {
        didSet { if let shifter { ps_stems_set_fade(shifter, stemsFade) } }
    }

    /// The stems are separated and played: while any is muted, and while the HUD shows them after every stem plays
    /// again, so that muting another one doesn't wait for the first block again.
    var stemsEngaged = false {
        didSet {
            if !stemsEngaged { awaitingSeek = false }
            if stemsEngaged != oldValue { applyStems() }
        }
    }

    /// Karaoke starts the song over: the output dips while the player moves the song to its start, and the stems wait
    /// for `restartStems(back:)`, which the move calls. The song then plays from its start as it is, and the stems step
    /// back to it once they are separated. The dip lasts 15 seconds at most.
    var awaitingSeek = false {
        didSet { if let shifter { ps_stems_await_seek(shifter, awaitingSeek ? 1 : 0) } }
    }

    /// The output steps back in the song with a fade out and a fade in, instead of a backspin (Settings > Instruments
    /// and vocals > Rewind effect).
    var fadeSteps = false {
        didSet { if let shifter { ps_set_step_fade(shifter, fadeSteps ? 1 : 0) } }
    }

    /// Called on the main thread when the stems can't be separated; the stems are back on by then.
    var onStemsFailure: ((Error) -> Void)?
    /// Called on the separation thread with how long the windows take.
    var stemsLog: (String) -> Void = { _ in }

    /// The player paused the song. The output holds the stems where they are once the song goes silent, so the pause
    /// and the resume are heard at once instead of the stems' delay later.
    var paused = false {
        didSet { if paused != oldValue, let shifter { ps_set_paused(shifter, paused ? 1 : 0) } }
    }

    /// The song changed or moved while it was paused, so the stems that were held belong to another moment: they
    /// start over, and the song plays as it is until the first block is separated.
    func restartStems() {
        if let shifter, stemsOn || lyricsDelay > 0 { ps_stems_restart(shifter) }
    }

    /// The song started over `back` seconds ago: the stems start over from that moment.
    func restartStems(back: Double) {
        if let shifter, stemsOn || lyricsDelay > 0 { ps_stems_restart_back(shifter, back) }
    }

    /// Seconds that the song plays behind itself while lyrics are written by ear, so each line is written before it
    /// is heard. The song plays as it is until that many seconds have played, then steps back to where it was.
    var lyricsDelay = 0.0 {
        didSet { if lyricsDelay != oldValue, let shifter { ps_set_delay(shifter, lyricsDelay) } }
    }

    /// Seconds until the song steps back for the lyrics delay, nil when it doesn't wait. A pause stops the count.
    var delayWaiting: Double? { shifter.map { ps_delay_waiting($0) }.flatMap { $0 >= 0 ? $0 : nil } }

    var stemsOn: Bool { stemsEngaged }
    /// How many backspins the output played: one each time it stepped back in the song.
    var spins: UInt32 { shifter.map { ps_spins($0) } ?? 0 }
    /// Seconds that the output plays behind the song, for the stems or the lyrics delay.
    var stemsDelay: Double { shifter.map { ps_stems_delay($0) } ?? 0 }
    /// While the stems are on and the song still plays as it is, waiting for the first separated block: the seconds
    /// since the stems were turned on.
    /// The stems are separated and play: nothing is left to wait for.
    var stemsPlaying: Bool { shifter.map { ps_stems_started($0) != 0 } ?? false }
    var stemsWaited: Double? { shifter.map { ps_stems_waiting($0) }.flatMap { $0 >= 0 ? $0 : nil } }
    func stemLevel(_ stem: Stem) -> Float { shifter.map { ps_stems_level($0, Int32(stem.rawValue)) } ?? 0 }

    private var separator: StemSeparator?
    /// Separators that were told to stop and may still read the shifter until their current window is done.
    private var stoppingSeparators: [StemSeparator] = []
    private var rate = 48000.0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var shifter: OpaquePointer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// `--visible-tap` lets other processes list the tap and the aggregate device, to check that they go away
    /// when Muskey quits or crashes.
    private static let visible = TestFlags.has("--visible-tap")

    /// `--shift-wav PATH` keeps the first seconds of the shifter's input and output as a stereo WAV.
    private let wavPath: String?
    /// `--shift-wav-seconds` makes it longer, for the stems that start a few seconds late.
    private let recordSeconds = TestFlags.value("--shift-wav-seconds").flatMap(Double.init) ?? 10.0
    private var recordingTimer: Timer?

    init(recordTo wavPath: String? = nil) {
        self.wavPath = wavPath
    }

    func start() throws {
        guard !running else { return }
        gaps = 0
        do {
            try build()
        } catch {
            teardown()
            throw error
        }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, listener)
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        if let outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, .main, outputListener)
        }
        outputListener = nil
        teardown()
    }

    private var stopTimer: Timer?

    /// Crossfades back to the original key, then removes the tap and calls `done`. A key picked before the
    /// crossfade ends keeps the pitch change running, and `done` is never called.
    func stopSmoothly(then done: @escaping () -> Void = {}) {
        semitones = 0
        guard running else { return done() }
        stopTimer?.invalidate()
        let deadline = Date().addingTimeInterval(2)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, semitones == 0, running else { return timer.invalidate() }
            if let shifter, ps_playing_semitones(shifter) != 0, Date() < deadline { return }
            stop()
            done()
        }
        RunLoop.main.add(timer, forMode: .common)
        stopTimer = timer
    }

    /// Headphones plugged in or another output picked: the aggregate is tied to the old device, so it is rebuilt.
    private func rebuild() {
        guard running else { return }
        teardown()
        do {
            try build()
        } catch {
            stop()
            onFailure?(error)
        }
    }

    private func build() throws {
        // A global tap that included Muskey would hear its own output and feed it back.
        guard let me = AudioProcess.own else { throw TapError(step: "Finding Muskey's audio process", status: -1) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        description.uuid = UUID()
        description.name = "Muskey pitch change"
        description.isPrivate = !Self.visible
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the process tap")

        let output = try readProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(kAudioObjectUnknown))
        let outputUID = try readString(output, kAudioDevicePropertyDeviceUID)

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Muskey pitch change",
            kAudioAggregateDeviceUIDKey: "Muskey-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: !Self.visible,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the aggregate device")

        let format = try readProperty(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw TapError(step: "Tap format is not Float32", status: -1) }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let sampleRate = try readProperty(aggregateID, kAudioDevicePropertyNominalSampleRate, Float64(0))

        guard let shifter = ps_create(sampleRate, planar ? 1 : 0, wavPath == nil ? 0 : recordSeconds) else {
            throw TapError(step: "Creating the pitch shifter", status: -1)
        }
        self.shifter = shifter
        rate = sampleRate
        ps_set_semitones(shifter, shifted)
        ps_set_paused(shifter, paused ? 1 : 0)
        ps_set_delay(shifter, lyricsDelay)
        ps_set_step_fade(shifter, fadeSteps ? 1 : 0)
        applyStems()

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            ps_process(shifter, input, output)
        }, "Creating the IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "Starting the aggregate device")

        if let wavPath {
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                guard let self, let shifter = self.shifter else { return timer.invalidate() }
                var pairs: UnsafePointer<Float>?
                let frames = ps_recording(shifter, &pairs)
                guard frames >= Int(self.recordSeconds * sampleRate), let pairs else { return }
                writeWAV(Array(UnsafeBufferPointer(start: pairs, count: frames * 2)), rate: UInt32(sampleRate.rounded()), channels: 2, to: wavPath)
                timer.invalidate()
            }
        }
    }

    private func teardown() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // The separation thread reads the shifter until its current window is done.
        separator?.stop()
        if let separator { stoppingSeparators.append(separator) }
        separator = nil
        for stopping in stoppingSeparators { stopping.waitUntilStopped() }
        stoppingSeparators = []
        // The IOProc is stopped and destroyed above, so nothing on the audio thread can still reach the shifter.
        if let shifter {
            gaps += ps_underruns(shifter)
            ps_destroy(shifter)
        }
        shifter = nil
    }

    /// Sets the gains of the stems, and starts or stops their separation.
    private func applyStems() {
        guard let shifter else { return }
        ps_stems_set_fade(shifter, stemsFade)
        for stem in Stem.allCases {
            ps_stems_set_gain(shifter, Int32(stem.rawValue), mutedStems.contains(stem) ? 0 : 1)
        }
        if stemsOn, separator == nil {
            let separator = StemSeparator()
            separator.onFailure = { [weak self] error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.mutedStems = []
                    self.stemsEngaged = false
                    self.onStemsFailure?(error)
                }
            }
            separator.log = stemsLog
            separator.start(shifter: shifter, rate: rate)
            self.separator = separator
        } else if !stemsOn, let separator {
            separator.stop()
            stoppingSeparators.append(separator)
            self.separator = nil
        }
        stoppingSeparators.removeAll { $0.stopped }
        ps_stems_enable(shifter, stemsOn ? 1 : 0)
    }

    deinit { stop() }
}

private func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try withUnsafeMutablePointer(to: &value) {
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0), "Reading audio property \(selector)")
    }
    return value
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var string: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try withUnsafeMutablePointer(to: &string) {
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0), "Reading audio property \(selector)")
    }
    guard let string else { throw TapError(step: "Reading audio property \(selector)", status: -1) }
    return string.takeRetainedValue() as String
}

/// `--selftest` runs a 440 Hz sine through the shifter at several shifts and checks the pitch of what comes out,
/// that no device buffer size leaves gaps in the output, that the limiter holds peaks under −1 dBFS, and that a
/// key change crossfades without a drop in level or a jump in timing. It needs no audio device or permission.
enum PitchSelfTest {
    static let rate = 48000.0

    static func run() -> Int32 {
        var failures = 0
        func report(_ ok: Bool, _ line: String) {
            if !ok { failures += 1 }
            print((ok ? "PASS  " : "FAIL  ") + line)
        }

        for semitones in [0, 2, -5, 12, -12] {
            let out = render(semitones: semitones, chunk: 512).out
            let heard = pitch(out, from: 1.0, to: 4.0)
            let want = hz(semitones)
            report(abs(heard / want - 1) < 0.01, String(format: "%+3d semitones   %7.1f Hz (want %7.1f)", semitones, heard, want))
        }

        // Each run changes the key halfway, so the handover between the stretchers is checked for gaps too.
        for chunk in [64, 128, 256, 480, 512, 1024, 4096] {
            let (out, underruns) = render(semitones: 3, chunk: chunk, changes: [(2.0, -4)])
            report(underruns == 0, String(format: "%4d-frame buffers  %d gaps, %.0f ms delay", chunk, underruns, delay(out) * 1000))
        }

        // A sine louder than full scale, which the limiter has to bring under −1 dBFS without changing its pitch.
        let loud = render(semitones: 2, chunk: 512, amplitude: 1.4).out
        let peak = loud[Int(rate)...].map(abs).max() ?? 0
        let loudHz = pitch(loud, from: 1.0, to: 4.0)
        report(peak <= 0.8912 && abs(loudHz / hz(2) - 1) < 0.01, String(format: "limiter          a 1.4 peak comes out at %.3f, %.1f Hz", peak, loudHz))

        // From +2 to +7 at 1.5 s: the old key holds until then, the new one is there within 0.6 s, and the level
        // never drops below 70% of the steady level in between.
        let changed = render(semitones: 2, chunk: 512, changes: [(1.5, 7)]).out
        let before = pitch(changed, from: 1.0, to: 1.5), after = pitch(changed, from: 2.1, to: 4.0)
        let window = Int(rate * 0.01)
        let levels = stride(from: Int(rate), to: changed.count - window, by: window).map { rms(changed[$0 ..< $0 + window]) }
        let steady = levels.sorted()[levels.count / 2]
        let lowest = levels.min() ?? 0
        let reached = stride(from: 1.5, to: 3.5, by: 0.005).first { abs(pitch(changed, from: $0, to: $0 + 0.02) / hz(7) - 1) < 0.01 } ?? 4
        report(abs(before / hz(2) - 1) < 0.01 && abs(after / hz(7) - 1) < 0.01 && reached - 1.5 < 0.6 && lowest > 0.7 * steady,
               String(format: "crossfade        %.1f Hz to %.1f Hz, new key after %.0f ms, lowest level %.0f%%", before, after, (reached - 1.5) * 1000, lowest / steady * 100))

        // Tone bursts every 250 ms. Rubber Band runs further behind at +7 than at +2, so the bursts may come a little
        // later after the change, but never earlier.
        let bursts = render(semitones: 2, chunk: 512, changes: [(1.6, 7)], bursts: true).out
        let onsets = burstDelays(bursts)
        let early = median(onsets.filter { $0.at >= 0.75 && $0.at < 1.6 }.map(\.delay))
        let late = median(onsets.filter { $0.at >= 2.5 }.map(\.delay))
        let during = onsets.filter { $0.at >= 1.6 && $0.at < 2.5 }.map { String(format: "%.0f", $0.delay * 1000) }
        report(late - early > -0.005 && late - early < 0.025, String(format: "timing           bursts %.0f ms late before the change, %.0f ms after (%@ during)", early * 1000, late * 1000, during.joined(separator: ", ")))

        // Six changes in a row, between +12 and -12, ending at +2: no gaps, and back to the delay that +2 had.
        let changes: [(Double, Int)] = [(1.2, 7), (1.8, -5), (2.4, 12), (3.0, -12), (3.6, 0), (4.2, 2)]
        let (series, seriesGaps) = render(semitones: 2, chunk: 512, seconds: 6, changes: changes, bursts: true)
        let seriesOnsets = burstDelays(series)
        let first = median(seriesOnsets.filter { $0.at >= 0.75 && $0.at < 1.2 }.map(\.delay))
        let last = median(seriesOnsets.filter { $0.at >= 5.0 }.map(\.delay))
        let delays = seriesOnsets.filter { $0.at >= 1.2 && $0.at < 5.0 }.map { String(format: "%.0f", $0.delay * 1000) }
        report(seriesGaps == 0 && abs(last - first) < 0.012, String(format: "six changes      %d gaps, bursts %.0f ms late at first, %.0f ms at the end (%@ between)", seriesGaps, first * 1000, last * 1000, delays.joined(separator: ", ")))

        // The stems a moment behind a 440 Hz song that pauses and plays on at 660 Hz. Past the shifter's own delay of
        // about 115 ms, the output goes quiet at once, comes back with the song's first sound, and carries on with the
        // 440 Hz that it held, then the 660 Hz, with no dropout. First with the pause reported as the song goes
        // silent, then the way players report it: a quarter second after the silence, and the resume a quarter second
        // before the sound.
        for (name, silence, flag, clear, sound) in [("stems pause     ", 3.0, 3.0, 5.0, 5.0), ("late report     ", 3.0, 3.25, 4.75, 5.0)] {
            let held = renderStemsPause(silenceAt: silence, flagAt: flag, clearAt: clear, soundAt: sound)
            let steadyLevel = rms(held[Int(rate * 2.0) ..< Int(rate * 2.9)])
            let pausedLevel = rms(held[Int(rate * (flag + 0.15)) ..< Int(rate * (sound - 0.1))])
            let after = Int(rate * (sound + 0.15))
            let window = Int(rate * 0.02)
            let lowest = stride(from: after, to: Int(rate * 6.9), by: window).map { rms(held[$0 ..< $0 + window]) }.min() ?? 0
            let heldHz = pitch(held, from: sound + 0.15, to: sound + 0.6), newHz = pitch(held, from: 6.2, to: 6.9)
            report(pausedLevel < 0.01 * steadyLevel && lowest > 0.5 * steadyLevel && abs(heldHz / 440 - 1) < 0.01 && abs(newHz / 660 - 1) < 0.01,
                   String(format: "%@ %.1f%% level while paused, lowest %.0f%% after the resume, %.1f Hz held, then %.1f Hz",
                          name, pausedLevel / steadyLevel * 100, lowest / steadyLevel * 100, heldHz, newHz))
        }

        // The lyrics delay with no stems: the song plays as it is for 30 seconds, then steps back to where the delay
        // was raised and plays 30 seconds behind, so the change from 440 to 660 Hz at 40 seconds is heard at 70.
        do {
            var waiting = -1.0
            let run = renderTimeline(seconds: 74, tone: { $0 < 40 ? 440 : 660 }, events: [
                (2, { ps_set_delay($0, 30) }), (12, { waiting = ps_delay_waiting($0) }),
            ])
            let out = run.out
            let steady = rms(out[Int(rate * 20) ..< Int(rate * 30)])
            let window = Int(rate * 0.02)
            let lowest = stride(from: Int(rate * 33), to: Int(rate * 73), by: window).map { rms(out[$0 ..< $0 + window]) }.min() ?? 0
            let before = pitch(out, from: 68.5, to: 69.8), after = pitch(out, from: 70.4, to: 72)
            report(abs(waiting - 20) < 0.1 && lowest > 0.5 * steady && abs(before / 440 - 1) < 0.01 && abs(after / 660 - 1) < 0.01 && abs(run.delay - 30) < 0.05,
                   String(format: "lyrics delay     %.1f s left at 12 s, lowest %.0f%% after the step back, %.1f Hz then %.1f Hz, %.2f s behind",
                          waiting, lowest / steady * 100, before, after, run.delay))
        }

        // A pause while the song plays 6 seconds behind: quiet at once, back with the song's first sound, carrying on
        // with the 440 Hz that it held, in both orders of the report.
        for (name, flag, clear) in [("delay pause     ", 12.0, 14.0), ("delay late pause", 12.25, 13.75)] {
            let run = renderTimeline(seconds: 22, tone: { $0 < 12 ? 440 : $0 < 14 ? nil : 660 }, paused: { $0 >= flag && $0 < clear },
                                     events: [(0.5, { ps_set_delay($0, 6) })])
            let out = run.out
            let steady = rms(out[Int(rate * 9) ..< Int(rate * 11.9)])
            let pausedLevel = rms(out[Int(rate * (flag + 0.15)) ..< Int(rate * 13.9)])
            let window = Int(rate * 0.02)
            let lowest = stride(from: Int(rate * 14.15), to: Int(rate * 21.9), by: window).map { rms(out[$0 ..< $0 + window]) }.min() ?? 0
            let heldHz = pitch(out, from: 14.2, to: 19.5), newHz = pitch(out, from: 20.4, to: 21.9)
            report(pausedLevel < 0.01 * steady && lowest > 0.5 * steady && abs(heldHz / 440 - 1) < 0.01 && abs(newHz / 660 - 1) < 0.01,
                   String(format: "%@ %.1f%% level while paused, lowest %.0f%% after the resume, %.1f Hz held, then %.1f Hz",
                          name, pausedLevel / steady * 100, lowest / steady * 100, heldHz, newHz))
        }

        // The stems with the 30-second delay, past the 60 seconds that the captured song holds: the separation, 2 seconds
        // behind the song, waits for the output, and the stems never run dry.
        do {
            let run = renderTimeline(seconds: 84, tone: { $0 < 45 ? 440 : 660 }, events: [
                (1, { ps_stems_enable($0, 1) }), (3, { ps_set_delay($0, 30) }),
            ], separator: true)
            let out = run.out
            let steady = rms(out[Int(rate * 20) ..< Int(rate * 30)])
            let window = Int(rate * 0.02)
            let lowest = stride(from: Int(rate * 34), to: Int(rate * 83), by: window).map { rms(out[$0 ..< $0 + window]) }.min() ?? 0
            let before = pitch(out, from: 73.5, to: 74.8), after = pitch(out, from: 75.4, to: 77)
            report(run.gaps == 0 && lowest > 0.5 * steady && abs(before / 440 - 1) < 0.01 && abs(after / 660 - 1) < 0.01 && abs(run.delay - 30) < 0.05,
                   String(format: "stems delayed    %d gaps, lowest %.0f%% after the step back, %.1f Hz then %.1f Hz, %.2f s behind",
                          run.gaps, lowest / steady * 100, before, after, run.delay))
        }

        // A stem muted while the song plays 6 seconds behind: the stems are separated from the moment that plays, so
        // the mute is heard as soon as the first window is (2 seconds here), not 6 seconds later. The whole song is in
        // the muted stem.
        do {
            let run = renderTimeline(seconds: 18, tone: { _ in 440 }, events: [
                (0.5, { ps_set_delay($0, 6) }), (10, { ps_stems_set_gain($0, 0, 0); ps_stems_enable($0, 1) }),
            ], separator: true)
            let out = run.out
            let steady = rms(out[Int(rate * 8) ..< Int(rate * 9.9)])
            let muted = rms(out[Int(rate * 12.5) ..< Int(rate * 17.9)])
            report(muted < 0.01 * steady, String(format: "mute in delay    %.1f%% level from 2.5 s after the mute", muted / steady * 100))
        }

        // The stems take over seconds behind the song as it plays, so the output steps back to the moment they were
        // turned on with a backspin: the song heard last plays backwards, sped up and slowing down, which reads as a
        // tone far above the song's. The spin lasts 0.9 seconds, plus the shifter's latency, and the stems carry on
        // after it at full level, with the 660 Hz of the song's second second.
        do {
            let run = renderTimeline(seconds: 10, tone: { $0 < 2 ? 440 : 660 }, events: [(1, { ps_stems_enable($0, 1) })], separator: true)
            let out = run.out
            let steady = rms(out[Int(rate * 2.4) ..< Int(rate * 2.9)])
            let window = 0.02
            let fast = stride(from: 2.5, to: 7, by: window).filter { pitch(out, from: $0, to: $0 + window) > 1000 }
            let spinStart = fast.first ?? 0, spinEnd = spinStart + 1.05
            let lowest = stride(from: spinEnd, to: 9.9, by: window).map { rms(out[Int(rate * $0) ..< Int(rate * ($0 + window))]) }.min() ?? 0
            let before = pitch(out, from: 2.4, to: 2.9), after = pitch(out, from: spinEnd + 0.2, to: 9.9)
            let (handover, rise) = Self.handover(out, from: spinStart + 0.6, to: spinEnd + 0.3)
            report(run.gaps == 0 && fast.count >= 10 && spinStart > 2.4 && lowest > 0.8 * steady && handover > 0.3 * steady && rise < 4
                   && abs(before / 660 - 1) < 0.01 && abs(after / 660 - 1) < 0.01 && run.delay > 1.5,
                   String(format: "stems backspin   %.1f Hz, a spin from %.2f s, then %.1f Hz, lowest %.0f%% after it, %.0f%% and a rise of %.1fx as it ends, %.1f s behind",
                          before, spinStart, after, lowest / steady * 100, handover / steady * 100, rise, run.delay))
        }

        // Karaoke that starts the song over: the stems are turned on at 1 s and the output dips, the player moves the
        // song to its start at 3 s (440 Hz before, 660 Hz from its start) and reports it 0.3 s later. The song comes
        // back from its start as it plays, then the stems of the start step back to it with a backspin, and none of the
        // 440 Hz plays again. The output plays the song from its start at 3 s, so it is as far behind as the stems took
        // to start, less the shifter's latency of about 0.1 s; a restart from the moment of the report would be 0.3 s
        // less behind.
        do {
            let run = renderTimeline(seconds: 10, tone: { $0 < 3 ? 440 : 660 }, events: [
                (1, { ps_stems_await_seek($0, 1); ps_stems_enable($0, 1) }), (3.3, { ps_stems_restart_back($0, 0.3) }),
            ], separator: true)
            let out = run.out
            let steady = rms(out[Int(rate * 0.4) ..< Int(rate * 0.9)])
            let window = 0.02
            let dip = rms(out[Int(rate * 1.5) ..< Int(rate * 3.3)])
            let live = rms(out[Int(rate * 4) ..< Int(rate * 5.5)]), liveHz = pitch(out, from: 4, to: 5.5)
            let fast = stride(from: 5.5, to: 9.8, by: window).filter { pitch(out, from: $0, to: $0 + window) > 1000 }
            let spinStart = fast.first ?? 0
            let after = pitch(out, from: spinStart + 1.1, to: 9.9)
            report(run.gaps == 0 && dip < 0.01 * steady && live > 0.8 * steady && abs(liveHz / 660 - 1) < 0.01 && fast.count >= 10
                   && abs(after / 660 - 1) < 0.01 && abs(run.delay - (spinStart - 3.1)) < 0.15,
                   String(format: "karaoke restart  %.1f%% level until the move, %.0f%% of %.1f Hz after it, a backspin from %.2f s, then %.1f Hz, %.1f s behind",
                          dip / steady * 100, live / steady * 100, liveHz, spinStart, after, run.delay))

            // Karaoke opened again while the stems play from an earlier mute: they fade out at the report, the song
            // comes back from its start after a quarter second as it plays, and the stems of the start step back to it.
            let again = renderTimeline(seconds: 14, tone: { $0 < 6 ? 440 : 660 }, events: [
                (1, { ps_stems_enable($0, 1) }), (6, { ps_stems_await_seek($0, 1) }), (6.3, { ps_stems_restart_back($0, 0.3) }),
            ], separator: true)
            let playing = rms(again.out[Int(rate * 5) ..< Int(rate * 5.9)])
            let hush = rms(again.out[Int(rate * 6.45) ..< Int(rate * 6.6)])
            let start = rms(again.out[Int(rate * 7) ..< Int(rate * 8.5)]), startHz = pitch(again.out, from: 6.8, to: 8.5)
            let spun = stride(from: 8.5, to: 13.8, by: window).filter { pitch(again.out, from: $0, to: $0 + window) > 1000 }
            let resumedHz = pitch(again.out, from: (spun.first ?? 13) + 1.1, to: 13.9)
            report(hush < 0.05 * playing && start > 0.8 * playing && abs(startHz / 660 - 1) < 0.01 && spun.count >= 10 && abs(resumedHz / 660 - 1) < 0.01,
                   String(format: "restart again    %.1f%% level as it moves, %.0f%% of %.1f Hz after, a backspin from %.2f s, then %.1f Hz",
                          hush / playing * 100, start / playing * 100, startHz, spun.first ?? 0, resumedHz))

            // A player that ignores the move: the app ends the dip after 2 seconds, the song comes back at once, and the
            // stems take over later with a backspin to where they were turned on. Without any end, the dip lasts 15 s.
            let ignored = renderTimeline(seconds: 12, tone: { $0 < 6 ? 440 : 660 }, events: [
                (1, { ps_stems_await_seek($0, 1); ps_stems_enable($0, 1) }), (3, { ps_stems_await_seek($0, 0) }),
            ], separator: true).out
            let before = rms(ignored[Int(rate * 0.4) ..< Int(rate * 0.9)])
            let hushed = rms(ignored[Int(rate * 1.6) ..< Int(rate * 3.0)])
            let returned = rms(ignored[Int(rate * 3.6) ..< Int(rate * 4.0)])
            let whirls = stride(from: 3.5, to: 11.8, by: window).filter { pitch(ignored, from: $0, to: $0 + window) > 1000 }
            report(hushed < 0.01 * before && returned > 0.8 * before && !whirls.isEmpty && whirls[0] > 3.6,
                   String(format: "move ignored     %.1f%% level until the app gives up, %.0f%% 0.6 s after, a backspin from %.2f s",
                          hushed / before * 100, returned / before * 100, whirls.first ?? 0))

            let unanswered = renderTimeline(seconds: 22, tone: { _ in 440 }, events: [(1, { ps_stems_await_seek($0, 1); ps_stems_enable($0, 1) })], separator: true).out
            let level = { (from: Double, to: Double) in rms(unanswered[Int(rate * from) ..< Int(rate * to)]) }
            report(level(2, 15.5) < 0.01 * level(0.4, 0.9) && level(16.6, 17.5) > 0.8 * level(0.4, 0.9),
                   String(format: "restart unheard  %.1f%% level for 15 s, %.0f%% after", level(2, 15.5) / level(0.4, 0.9) * 100, level(16.6, 17.5) / level(0.4, 0.9) * 100))
        }

        // Karaoke's vocals fade out over about 450 ms instead of cutting out, while a stem muted by its key or a click
        // goes out at once, in time with the song. The whole song is in the first stem.
        do {
            let slow = renderTimeline(seconds: 10, tone: { _ in 440 }, events: [
                (1, { ps_stems_enable($0, 1) }), (7, { ps_stems_set_fade($0, 0.45); ps_stems_set_gain($0, 0, 0) }),
            ], separator: true)
            let quick = renderTimeline(seconds: 10, tone: { _ in 440 }, events: [(1, { ps_stems_enable($0, 1) }), (7, { ps_stems_set_gain($0, 0, 0) })],
                                       separator: true)
            let steady = rms(slow.out[Int(rate * 6) ..< Int(rate * 6.9)])
            let fading = rms(slow.out[Int(rate * 7.3) ..< Int(rate * 7.35)]), gone = rms(slow.out[Int(rate * 7.7) ..< Int(rate * 9.9)])
            let cut = rms(quick.out[Int(rate * 7.2) ..< Int(rate * 9.9)])
            report(fading > 0.15 * steady && fading < 0.85 * steady && gone < 0.01 * steady && cut < 0.01 * steady,
                   String(format: "stem mute fade   karaoke: %.0f%% level 300 ms after the mute, %.1f%% from 700 ms; a key: %.1f%% from 200 ms",
                          fading / steady * 100, gone / steady * 100, cut / steady * 100))
        }

        // Another sound keeps the tap from going silent during a pause: the fade of the pause lets it through after
        // 1.5 seconds.
        do {
            let run = renderTimeline(seconds: 6, tone: { _ in 440 }, paused: { $0 >= 2 && $0 < 5.5 }, events: [(at: 0, run: { ps_set_semitones($0, 2) })])
            let steady = rms(run.out[Int(rate * 1) ..< Int(rate * 1.9)])
            let held = rms(run.out[Int(rate * 2.05) ..< Int(rate * 3.4)]), through = rms(run.out[Int(rate * 3.8) ..< Int(rate * 5.4)])
            report(held < 0.01 * steady && through > 0.7 * steady,
                   String(format: "pause, no silence %.1f%% level in the first 1.4 s, %.0f%% after 1.8 s", held / steady * 100, through / steady * 100))
        }

        // The Fade rewind effect: the stems take over with the song fading out and the stems fading in, with no
        // backspin, and play as far behind as after a backspin.
        do {
            let run = renderTimeline(seconds: 10, tone: { $0 < 2 ? 440 : 660 }, events: [(0, { ps_set_step_fade($0, 1) }), (1, { ps_stems_enable($0, 1) })], separator: true)
            let out = run.out
            let steady = rms(out[Int(rate * 2.4) ..< Int(rate * 2.9)])
            let window = 0.02
            let fast = stride(from: 2.5, to: 9.8, by: window).filter { pitch(out, from: $0, to: $0 + window) > 1000 }
            let levels = stride(from: 3.0, to: 9.9, by: window).map { (at: $0, level: rms(out[Int(rate * $0) ..< Int(rate * ($0 + window))])) }
            let deepest = levels.min { $0.level < $1.level } ?? (at: 0, level: 1)
            let lowestAfter = levels.filter { $0.at > deepest.at + 0.45 }.map(\.level).min() ?? 0
            let after = pitch(out, from: 6, to: 9.9)
            report(run.gaps == 0 && fast.isEmpty && deepest.level < 0.1 * steady && deepest.at > 3.8 && deepest.at < 4.6 && lowestAfter > 0.8 * steady
                   && abs(after / 660 - 1) < 0.01 && abs(run.delay - 2.8) < 0.2,
                   String(format: "stems fade       %d spins, %.0f%% level at %.2f s, lowest %.0f%% after it, then %.1f Hz, %.1f s behind",
                          fast.count, deepest.level / steady * 100, deepest.at, lowestAfter / steady * 100, after, run.delay))
        }

        // The Fade rewind effect while the stems play: the delay of 6 seconds steps back at 11 s, the stems fade out over
        // 0.4 s, jump back 6 seconds and fade back in. The stems play about 3 seconds behind, so the 660 Hz from 7 s plays
        // before it, and the 440 Hz of the earlier moment after it.
        do {
            let run = renderTimeline(seconds: 16, tone: { $0 < 7 ? 440 : 660 }, events: [
                (0, { ps_set_step_fade($0, 1) }), (1, { ps_stems_enable($0, 1) }), (5, { ps_set_delay($0, 6) }),
            ], separator: true)
            let out = run.out
            let window = 0.02
            let steady = rms(out[Int(rate * 9.5) ..< Int(rate * 10.5)])
            let fast = stride(from: 10, to: 15.8, by: window).filter { pitch(out, from: $0, to: $0 + window) > 1000 }
            let deepest = stride(from: 10.8, to: 12.2, by: window).map { rms(out[Int(rate * $0) ..< Int(rate * ($0 + window))]) }.min() ?? 1
            let before = pitch(out, from: 10.5, to: 10.9), after = pitch(out, from: 11.9, to: 13.1)
            let lowest = stride(from: 12.3, to: 15.9, by: window).map { rms(out[Int(rate * $0) ..< Int(rate * ($0 + window))]) }.min() ?? 0
            report(run.gaps == 0 && fast.isEmpty && deepest < 0.05 * steady && abs(before / 660 - 1) < 0.01 && abs(after / 440 - 1) < 0.01 && lowest > 0.5 * steady,
                   String(format: "delay fade       %d spins, %.0f%% level at the jump, %.1f Hz before, %.1f Hz after, lowest %.0f%% after",
                          fast.count, deepest / steady * 100, before, after, lowest / steady * 100))
        }

        // The lyrics delay steps back 30 seconds with the same backspin.
        do {
            let run = renderTimeline(seconds: 34, tone: { $0 < 20 ? 440 : 660 }, events: [(2, { ps_set_delay($0, 30) })])
            let window = 0.02
            let fast = stride(from: 31.8, to: 33.5, by: window).filter { pitch(run.out, from: $0, to: $0 + window) > 1000 }
            let spinStart = fast.first ?? 0
            let steady = rms(run.out[Int(rate * 30) ..< Int(rate * 31.5)])
            let (handover, rise) = Self.handover(run.out, from: spinStart + 0.6, to: min(33.9, spinStart + 1.35))
            report(fast.count >= 10 && spinStart >= 31.9 && handover > 0.3 * steady && rise < 4,
                   String(format: "delay backspin   a %.0f ms spin from %.2f s, as the delay steps back at 32 s, %.0f%% and a rise of %.1fx as it ends",
                          Double(fast.count) * window * 1000, spinStart, handover / steady * 100, rise))
        }

        // The delay ends while the stems play: the output moves forward to about the stems' own lag, with a window in
        // hand, and the stems, written 4.5 seconds at a time as the separation writes them, never run dry.
        do {
            let run = renderTimeline(seconds: 30, tone: { _ in 440 }, events: [
                (0.5, { ps_stems_enable($0, 1); ps_set_delay($0, 12) }), (17, { ps_set_delay($0, 0) }),
            ], separator: true, block: 4.5)
            let out = run.out
            let steady = rms(out[Int(rate * 14) ..< Int(rate * 16.9)])
            let window = Int(rate * 0.02)
            let lowest = stride(from: Int(rate * 17.3), to: Int(rate * 29.9), by: window).map { rms(out[$0 ..< $0 + window]) }.min() ?? 0
            report(run.gaps == 0 && lowest > 0.5 * steady && run.delay > 4 && run.delay < 12,
                   String(format: "delay ends       %d gaps, lowest %.0f%% after it, %.1f s behind with the stems", run.gaps, lowest / steady * 100, run.delay))
        }

        // Moving a song onto a kept key: the shorter way, and through the relative when the modes differ.
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        func key(_ name: String, _ minor: Bool) -> DetectedKey { DetectedKey(pitchClass: names.firstIndex(of: name)!, minor: minor) }
        let moves: [(DetectedKey, DetectedKey, Int)] = [
            (key("A", true), key("C", true), 3), (key("A", false), key("C", false), 3), (key("C", false), key("C", true), 3),
            (key("A", false), key("C", true), -6), (key("E", true), key("G", false), 0), (key("G", false), key("A", false), 2),
            (key("B", false), key("C", false), 1), (key("C♯", true), key("B", true), -2), (key("F♯", true), key("C", true), -6),
            (key("D", false), key("B", true), 0), (key("E♭", true), key("C", true), -3),
        ]
        let wrong = moves.filter { $0.0.shift(to: $0.1) != $0.2 }.map { "\($0.0.name) to \($0.1.name) gave \($0.0.shift(to: $0.1))" }
        report(wrong.isEmpty, "kept key         \(moves.count) songs moved to a kept key\(wrong.isEmpty ? "" : ": " + wrong.joined(separator: ", "))")

        // The glass dragged past each edge of a 1440 by 870 screen comes back 12 points inside it, and one taller
        // than the screen keeps its top on it.
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 870)
        let drags: [(String, CGRect, CGVector)] = [
            ("inside", CGRect(x: 300, y: 200, width: 656, height: 600), CGVector(dx: 0, dy: 0)),
            ("below", CGRect(x: 300, y: -100, width: 656, height: 600), CGVector(dx: 0, dy: 152)),
            ("above", CGRect(x: 300, y: 500, width: 656, height: 600), CGVector(dx: 0, dy: -202)),
            ("left", CGRect(x: -50, y: 200, width: 656, height: 600), CGVector(dx: 62, dy: 0)),
            ("right", CGRect(x: 1000, y: 200, width: 656, height: 600), CGVector(dx: -228, dy: 0)),
            ("too tall", CGRect(x: 300, y: -200, width: 656, height: 1000), CGVector(dx: 0, dy: 98)),
        ]
        let misplaced = drags.compactMap { name, glass, want -> String? in
            let got = HUDPanel.offset(keeping: glass, inside: visible, margin: 12)
            return got == want ? nil : "\(name) moved by \(got.dx), \(got.dy) instead of \(want.dx), \(want.dy)"
        }
        report(misplaced.isEmpty, "glass on screen  \(drags.count) drags\(misplaced.isEmpty ? "" : ": " + misplaced.joined(separator: ", "))")

        // Space pauses the song: the flag comes 50 ms before the player stops, and the output fades out with the
        // flag instead of playing on for the shifter's latency. The song playing again is heard within that latency.
        do {
            let run = renderTimeline(seconds: 6, tone: { $0 < 3.05 || $0 >= 4.5 ? 440 : nil }, paused: { $0 >= 3 && $0 < 4.5 },
                                     events: [(at: 0, run: { ps_set_semitones($0, 2) })])
            func level(_ from: Double, _ to: Double) -> Float {
                let slice = run.out[Int(from * rate) ..< Int(to * rate)]
                return sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
            }
            let steady = level(2, 3), after = level(3.03, 3.29), back = level(4.65, 5)
            report(after < steady * 0.01 && back > steady * 0.7,
                   String(format: "pause fade       %.1f%% level from 30 ms after the pause, %.0f%% from 150 ms after the resume", after / steady * 100, back / steady * 100))
        }

        // A player that stops 600 ms after Space paused it: nothing of what it still sends is heard, and the song
        // playing again is.
        do {
            let run = renderTimeline(seconds: 6, tone: { $0 < 3.6 || $0 >= 4.5 ? 440 : nil }, paused: { $0 >= 3 && $0 < 4.5 },
                                     events: [(at: 0, run: { ps_set_semitones($0, 2) })])
            func level(_ from: Double, _ to: Double) -> Float {
                let slice = run.out[Int(from * rate) ..< Int(to * rate)]
                return sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
            }
            let steady = level(2, 3), after = level(3.03, 4.45), back = level(4.65, 5)
            report(after < steady * 0.01 && back > steady * 0.7,
                   String(format: "late player stop %.1f%% level during the pause, %.0f%% from 150 ms after the resume", after / steady * 100, back / steady * 100))
        }

        // Karaoke grows the glass past the bottom of the screen: the panel moves up, and back down once it closes.
        _ = NSApplication.shared
        if let visible = NSScreen.main?.visibleFrame {
            let model = HUDModel()
            let panel = HUDPanel(model: model)
            let small = CGRect(x: 50, y: 400, width: 800, height: 300), tall = CGRect(x: 150, y: 50, width: 600, height: 1000)
            let start = NSRect(x: visible.midX - 450, y: visible.minY + 20 + 700 - 1100, width: 900, height: 1100)
            panel.setFrame(start, display: false)
            model.glassFrame = small
            panel.keepOnScreen(animated: false)
            let still = panel.frame
            model.glassFrame = tall
            panel.keepOnScreen(animated: false)
            let raised = panel.frame
            model.glassFrame = small
            panel.keepOnScreen(animated: false)
            let back = panel.frame
            report(still == start && raised.minY > start.minY && back == start,
                   String(format: "karaoke closes   moved up %.0f, then back by %.0f points", raised.minY - start.minY, raised.minY - back.minY))

            // Karaoke opens in the middle of the screen, and the HUD goes back to its place once karaoke closes.
            let karaoke = CGRect(x: 122, y: 250, width: 656, height: 600)
            panel.setFrame(start, display: false)
            model.glassFrame = small
            panel.keepOnScreen(animated: false)
            model.lyricsFocus = true
            model.glassFrame = karaoke
            panel.keepOnScreen(animated: false)
            let open = panel.frame
            let middle = CGPoint(x: open.minX + karaoke.midX, y: open.maxY - karaoke.midY)
            model.lyricsFocus = false
            model.glassFrame = small
            panel.keepOnScreen(animated: false)
            let home = panel.frame
            let off = hypot(middle.x - visible.midX, middle.y - visible.midY)
            report(off < 1 && home == start,
                   String(format: "karaoke centred  %.1f points from the middle of the screen, back home: %@", off, home == start ? "yes" : "no"))
        }

        LyricsSelfTest.run(report: report)

        // Noiseblend's answers: every Camelot code back to its key, and which failures count as an unknown song.
        let keys = (0 ..< 24).map { DetectedKey(pitchClass: $0 % 12, minor: $0 >= 12) }
        let misread = keys.filter { DetectedKey(camelot: $0.camelot) != $0 }.map(\.name)
        report(misread.isEmpty, "camelot codes    24 keys read back\(misread.isEmpty ? "" : ", wrong: " + misread.joined(separator: ", "))")
        let answers: [(Int, String?, String, KeyLookup.Answer)] = [
            (200, nil, #"{"key":"8A","pitchClass":9,"minor":true,"tempo":120.1}"#, .found(DetectedKey(pitchClass: 9, minor: true), tempo: 120.1)),
            (200, nil, #"{"key":"1B"}"#, .found(DetectedKey(pitchClass: 11, minor: false), tempo: nil)),
            (200, nil, #"{"key":"1B","tempo":0}"#, .found(DetectedKey(pitchClass: 11, minor: false), tempo: nil)),
            (200, nil, #"{"key":null}"#, .unknown),
            (404, nil, #"{"error":"no match"}"#, .unknown),
            (429, "30", "", .wait(30)),
            (502, nil, "", .failed("HTTP 502")),
            (200, nil, "<html>", .failed("unreadable answer")),
        ]
        let wrongAnswers = answers.filter { KeyLookup.answer(status: $0.0, retryAfter: $0.1, body: Data($0.2.utf8)) != $0.3 }.map { "\($0.0) \($0.2)" }
        report(wrongAnswers.isEmpty, "online keys      \(answers.count) answers read\(wrongAnswers.isEmpty ? "" : ", wrong: " + wrongAnswers.joined(separator: "; "))")

        // The tempo of a drum loop at the tap's rate, which the detector resamples to 44.1 kHz first.
        for bpm in [92.0, 128] {
            let started = Date()
            let found = TempoDetector.bpm(drums(bpm: bpm, seconds: 20, rate: 48000), sourceRate: 48000)
            report(abs((found?.bpm ?? 0) - bpm) / bpm < 0.02,
                   String(format: "tempo            %.1f BPM at confidence %.2f for a loop at %.0f BPM, in %.2fs", found?.bpm ?? 0, found?.confidence ?? 0, bpm,
                          Date().timeIntervalSince(started)))
        }
        let pairs: [(heard: Double, online: Double?, shown: Double)] = [(121, 120, 120), (60.5, 120, 120), (240, 120, 120), (40.1, 120, 120), (90, 120, 90), (97, nil, 97)]
        let wrongTempos = pairs.filter { TempoDetector.reconcile(heard: $0.heard, online: $0.online) != $0.shown }.map { "\($0.heard) with \($0.online ?? 0)" }
        report(wrongTempos.isEmpty, "tempo levels     \(pairs.count) pairs\(wrongTempos.isEmpty ? "" : ", wrong: " + wrongTempos.joined(separator: "; "))")

        return failures == 0 ? 0 : 1
    }

    static func hz(_ semitones: Int) -> Double { 440 * pow(2, Double(semitones) / 12) }

    /// A mono drum loop: a kick on every beat, a noise snare on two and four, and a short hat on every eighth.
    static func drums(bpm: Double, seconds: Double, rate: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * rate))
        var noise = SystemRandomNumberGenerator()
        let beat = 60 / bpm
        for step in 0 ..< Int(seconds / beat * 2) {
            let start = Int(Double(step) * beat / 2 * rate)
            let onBeat = step % 2 == 0
            let snare = step % 4 == 2
            for i in 0 ..< Int(0.2 * rate) where start + i < out.count {
                let t = Double(i) / rate
                var sample = 0.0
                if onBeat { sample += 0.8 * sin(2 * .pi * (50 + 80 * exp(-t * 30)) * t) * exp(-t * 12) }
                if snare { sample += 0.5 * Double.random(in: -1 ... 1, using: &noise) * exp(-t * 25) }
                sample += 0.15 * Double.random(in: -1 ... 1, using: &noise) * exp(-t * 120)
                out[start + i] += Float(sample)
            }
        }
        return out
    }

    /// Feeds the shifter the way the IOProc does, `chunk` frames of interleaved stereo in and out per call: half a
    /// second of silence, then the sine (or tone bursts every 250 ms). Each change sets another shift at that
    /// second, between two calls, as the app does from the main thread.
    private static func render(semitones: Int, chunk: Int, seconds: Double = 4, amplitude: Double = 0.5, changes: [(at: Double, to: Int)] = [], bursts: Bool = false) -> (out: [Float], underruns: UInt64) {
        let shifter = ps_create(rate, 0, 0)!
        defer { ps_destroy(shifter) }
        ps_set_semitones(shifter, Float(semitones))

        let chunks = Int(rate * seconds) / chunk
        let onset = Int(rate / 2)
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { free(input.unsafeMutablePointer); free(output.unsafeMutablePointer); inData.deallocate(); outData.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: inData)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: outData)

        var out: [Float] = []
        var frame = 0
        for _ in 0 ..< chunks {
            for change in changes where frame <= Int(change.at * rate) && frame + chunk > Int(change.at * rate) {
                ps_set_semitones(shifter, Float(change.to))
            }
            for i in 0 ..< chunk {
                let n = frame + i
                var sample = n < onset ? 0 : amplitude * sin(2 * .pi * 440 * Double(n) / rate)
                if bursts { sample *= envelope(Double(n - onset) / rate) }
                inData[i * 2] = Float(sample)
                inData[i * 2 + 1] = Float(sample)
            }
            frame += chunk
            ps_process(shifter, input.unsafePointer, output.unsafeMutablePointer)
            for i in 0 ..< chunk { out.append(outData[i * 2]) }
        }
        return (out, ps_underruns(shifter))
    }

    /// The stems on, with each block "separated" at once, the way the separation thread writes it: the first stem
    /// gets the captured audio and the others silence. A 440 Hz song goes silent at `silenceAt` and plays on at
    /// 660 Hz from `soundAt`, and `ps_set_paused` is on from `flagAt` to `clearAt`.
    private static func renderStemsPause(silenceAt: Double, flagAt: Double, clearAt: Double, soundAt: Double, chunk: Int = 512, seconds: Double = 7) -> [Float] {
        let shifter = ps_create(rate, 0, 0)!
        defer { ps_destroy(shifter) }
        ps_stems_enable(shifter, 1)

        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { free(input.unsafeMutablePointer); free(output.unsafeMutablePointer); inData.deallocate(); outData.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: inData)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: outData)

        let most = 8192
        let left = UnsafeMutablePointer<Float>.allocate(capacity: most), right = UnsafeMutablePointer<Float>.allocate(capacity: most)
        let zeros = UnsafeMutablePointer<Float>.allocate(capacity: most)
        zeros.initialize(repeating: 0, count: most)
        defer { left.deallocate(); right.deallocate(); zeros.deallocate() }
        let planes: [UnsafePointer<Float>?] = [UnsafePointer(left), UnsafePointer(right)] + Array(repeating: UnsafePointer(zeros), count: Int(PS_STEMS) * 2 - 2)

        var out: [Float] = []
        var frame = 0, generation: UInt64 = 0, position: UInt64 = 0
        for _ in 0 ..< Int(rate * seconds) / chunk {
            let t = Double(frame) / rate
            ps_set_paused(shifter, t >= flagAt && t < clearAt ? 1 : 0)
            let silent = t >= silenceAt && t < soundAt
            for i in 0 ..< chunk {
                let sample = silent ? 0 : 0.5 * sin(2 * .pi * (t < silenceAt ? 440 : 660) * Double(frame + i) / rate)
                inData[i * 2] = Float(sample)
                inData[i * 2 + 1] = Float(sample)
            }
            frame += chunk
            ps_process(shifter, input.unsafePointer, output.unsafeMutablePointer)
            for i in 0 ..< chunk { out.append(outData[i * 2]) }

            var start: UInt64 = 0
            let current = ps_stems_generation(shifter, &start)
            if current != generation {
                generation = current
                position = start
                ps_stems_begin(shifter, current, start)
            }
            let got = ps_captured_read(shifter, &position, left, right, most)
            if got > 0 { planes.withUnsafeBufferPointer { ps_stems_write(shifter, $0.baseAddress!, got) } }
        }
        return out
    }

    /// Plays `tone` (a frequency at each second, or silence) through the shifter in 512-frame calls, with the
    /// player's pause flag from `paused`, and runs each event once at its second. With `separator`, a stand-in for
    /// the separation thread puts the whole song in the first stem, starting 2 seconds after each generation begins
    /// and then faster than real time, as far as `ps_stems_room` lets it. Returns the output's left channel, the gaps in the stems, and the delay at the end.
    private static func renderTimeline(seconds: Double, tone: (Double) -> Double?, paused: (Double) -> Bool = { _ in false },
                                       events: [(at: Double, run: (OpaquePointer) -> Void)], separator: Bool = false,
                                       block: Double = 0) -> (out: [Float], gaps: UInt64, delay: Double) {
        let chunk = 512
        let shifter = ps_create(rate, 0, 0)!
        defer { ps_destroy(shifter) }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { free(input.unsafeMutablePointer); free(output.unsafeMutablePointer); inData.deallocate(); outData.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: inData)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(chunk * 8), mData: outData)

        // Faster than real time, as the separation is once its first window is done.
        let most = 8192
        let left = UnsafeMutablePointer<Float>.allocate(capacity: most), right = UnsafeMutablePointer<Float>.allocate(capacity: most)
        let zeros = UnsafeMutablePointer<Float>.allocate(capacity: most)
        zeros.initialize(repeating: 0, count: most)
        defer { left.deallocate(); right.deallocate(); zeros.deallocate() }
        let planes: [UnsafePointer<Float>?] = [UnsafePointer(left), UnsafePointer(right)] + Array(repeating: UnsafePointer(zeros), count: Int(PS_STEMS) * 2 - 2)

        var out: [Float] = []
        out.reserveCapacity(Int(rate * seconds))
        var frame = 0, generation: UInt64 = 0, position: UInt64 = 0, next = 0
        var phase = 0.0
        var pending: [Float] = []
        // Callbacks since each generation began: the stand-in starts 2 seconds in, as a first window would.
        var calls = 0
        let lag = Int(rate * 2) / chunk
        for _ in 0 ..< Int(rate * seconds) / chunk {
            let t = Double(frame) / rate
            while next < events.count, events[next].at <= t {
                events[next].run(shifter)
                next += 1
            }
            ps_set_paused(shifter, paused(t) ? 1 : 0)
            let hz = tone(t)
            for i in 0 ..< chunk {
                if let hz { phase += 2 * .pi * hz / rate }
                let sample = hz == nil ? 0 : 0.5 * sin(phase)
                inData[i * 2] = Float(sample)
                inData[i * 2 + 1] = Float(sample)
            }
            frame += chunk
            ps_process(shifter, input.unsafePointer, output.unsafeMutablePointer)
            for i in 0 ..< chunk { out.append(outData[i * 2]) }

            guard separator else { continue }
            var start: UInt64 = 0
            let current = ps_stems_generation(shifter, &start)
            if current != generation {
                generation = current
                position = start
                calls = 0
                ps_stems_begin(shifter, current, start)
            }
            calls += 1
            guard generation != 0, calls > lag else { continue }
            let room = ps_stems_room(shifter, position)
            if block > 0 {
                // A whole window at a time, once that much is captured, as the separation writes them.
                let size = Int(rate * block)
                guard room >= size else { continue }
                pending.removeAll(keepingCapacity: true)
                var at = position
                for _ in 0 ..< size / most + 1 where pending.count / 2 < size {
                    let got = ps_captured_read(shifter, &at, left, right, min(most, size - pending.count / 2))
                    if got == 0 { break }
                    for i in 0 ..< got { pending.append(left[i]); pending.append(right[i]) }
                }
                guard pending.count / 2 == size else { continue }
                position = at
                for start in stride(from: 0, to: size, by: most) {
                    let n = min(most, size - start)
                    for i in 0 ..< n { left[i] = pending[(start + i) * 2]; right[i] = pending[(start + i) * 2 + 1] }
                    planes.withUnsafeBufferPointer { ps_stems_write(shifter, $0.baseAddress!, n) }
                }
                continue
            }
            let got = room > 0 ? ps_captured_read(shifter, &position, left, right, min(most, room)) : 0
            if got > 0 { planes.withUnsafeBufferPointer { ps_stems_write(shifter, $0.baseAddress!, got) } }
        }
        return (out, ps_underruns(shifter), ps_stems_delay(shifter))
    }

    /// On for 100 ms out of every 250 ms, with 2 ms ramps.
    private static func envelope(_ t: Double) -> Double {
        guard t >= 0 else { return 0 }
        let phase = t.truncatingRemainder(dividingBy: 0.25)
        return phase < 0.002 ? phase / 0.002 : phase < 0.1 ? min(1, (0.1 - phase) / 0.002) : 0
    }

    /// Pitch from rising zero crossings between two seconds of the output.
    private static func pitch(_ out: [Float], from: Double, to: Double) -> Double {
        var first = -1.0, last = -1.0, crossings = 0
        for i in max(1, Int(from * rate)) ..< min(out.count, Int(to * rate)) where out[i - 1] < 0 && out[i] >= 0 {
            let t = Double(i - 1) + Double(-out[i - 1] / (out[i] - out[i - 1]))
            if first < 0 { first = t } else { crossings += 1 }
            last = t
        }
        return crossings > 0 ? Double(crossings) * rate / (last - first) : 0
    }

    /// The amplitude of a sine at `hz` in the 20 ms of `out` from `from`.
    private static func amplitude(_ out: [Float], hz: Double, from: Double) -> Double {
        let start = Int(from * rate), count = Int(rate * 0.02)
        guard start >= 0, start + count <= out.count else { return 0 }
        var re = 0.0, im = 0.0
        for i in 0 ..< count {
            let angle = 2 * .pi * hz * Double(i) / rate
            re += Double(out[start + i]) * cos(angle)
            im += Double(out[start + i]) * sin(angle)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(count)
    }

    /// From the sine starting to it being heard, as it would be in a running stream.
    private static func delay(_ out: [Float]) -> Double {
        Double((out.firstIndex { abs($0) > 0.05 } ?? out.count) - Int(rate / 2)) / rate
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }

    /// Where a backspin hands over to the song: the lowest level in 20 ms windows, and the largest rise from one
    /// window to the next. A gap reads as a low level, and a hard restart after it as a large rise.
    private static func handover(_ out: [Float], from: Double, to: Double) -> (lowest: Float, rise: Float) {
        let window = 0.02
        let levels = stride(from: from, to: to, by: window).map { rms(out[Int(rate * $0) ..< min(out.count, Int(rate * ($0 + window)))]) }
        let rise = zip(levels, levels.dropFirst()).map { $1 / max($0, 1e-6) }.max() ?? 0
        return (levels.min() ?? 0, rise)
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? .nan : values.sorted()[values.count / 2]
    }

    /// Where each burst rises past half its level in the output (1 ms RMS), and how long after its start in the input.
    private static func burstDelays(_ out: [Float]) -> [(at: Double, delay: Double)] {
        let window = Int(rate * 0.001)
        let threshold = Float(0.5 * 0.5 / 2.0.squareRoot())
        var result: [(at: Double, delay: Double)] = []
        var above = false
        for start in stride(from: Int(rate / 2), to: out.count - window, by: window) {
            let level = rms(out[start ..< start + window])
            if !above, level > threshold {
                let t = Double(start) / rate
                let sent = 0.5 + ((t - 0.5) / 0.25).rounded(.down) * 0.25
                result.append((sent, t - sent))
                above = true
            } else if above, level < threshold * 0.5 {
                above = false
            }
        }
        return result
    }
}
