import CoreAudio
import Foundation

/// Records the song that another player plays, for Save Song, into memory only: the original is never written to a
/// file, and it is dropped once the changed song is rendered from it. The tap hears the processes of the player when
/// Core Audio knows them, so other sounds stay out of the song, and the whole Mac without Muskey otherwise.
/// Main thread, apart from the IOProc.
final class SongRecorder {
    /// The longest song that a recording keeps.
    static let maxSeconds = 15.0 * 60

    /// The tap hears only the player, and no other sound.
    let playerOnly: Bool
    private(set) var rate = 48000.0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let description: CATapDescription
    private let queue = DispatchQueue(label: "muskey.save", qos: .userInitiated)

    private let lock = NSLock()
    private var left: [Float] = []
    private var right: [Float] = []
    private var capacity = 0
    /// Frames before the first sound, which the song starts after.
    private var silent = 0

    /// The processes of the player with this bundle ID, and of its helpers, that Core Audio knows. `pid` is the process
    /// that Now Playing names, which can be a helper of another app, like Safari's media process.
    init(bundleID: String, pid: pid_t?) {
        let processes = Self.processes { process in
            process.pid == pid || process.bundleID == bundleID || process.bundleID?.hasPrefix(bundleID + ".") == true
        }
        // `--record-everything` records every app, as for a player that Core Audio doesn't know, for testing that case.
        playerOnly = !processes.isEmpty && !TestFlags.has("--record-everything")
        let description = playerOnly ? CATapDescription(stereoMixdownOfProcesses: processes)
            : CATapDescription(stereoGlobalTapButExcludeProcesses: AudioProcess.own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        self.description = description
    }

    /// Core Audio knows the processes of the player, which a recording then hears alone.
    static func hearsPlayerOnly(bundleID: String, pid: pid_t?) -> Bool {
        !TestFlags.has("--record-everything") && !processes { $0.pid == pid || $0.bundleID == bundleID || $0.bundleID?.hasPrefix(bundleID + ".") == true }.isEmpty
    }

    /// Frames of the song so far, from its first sound.
    var frames: Int { lock.withLock { max(0, left.count - silent) } }

    /// The song has started: something other than silence was heard.
    var heard: Bool { lock.withLock { left.count > silent } }

    func start() throws {
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the recording tap")
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Reading the recording tap's format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
        else { throw TapError(step: "The recording tap isn't Float32", status: -1) }
        rate = format.mSampleRate
        lock.withLock {
            capacity = Int(rate * Self.maxSeconds)
            left.reserveCapacity(capacity)
            right.reserveCapacity(capacity)
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Muskey Save",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the recording device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            self?.append(input)
        }, "Creating the recording IO proc")
        try check(AudioDeviceStart(aggregateID, procID), "Starting the recording")
    }

    /// Stops the tap and hands back the song from its first sound, at most `frames` long.
    func stop(frames limit: Int? = nil) -> StereoAudio {
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
        return lock.withLock {
            let end = min(left.count, silent + (limit ?? left.count))
            let song = StereoAudio(left: Array(left[silent ..< max(silent, end)]), right: Array(right[silent ..< max(silent, end)]), rate: rate)
            left = []
            right = []
            silent = 0
            return song
        }
    }

    deinit { _ = stop() }

    private func append(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        // A stereo tap comes as one interleaved buffer, or as two buffers of one channel each.
        let second = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        lock.withLock {
            let room = min(frames, capacity - left.count)
            guard room > 0 else { return }
            let started = left.count > silent
            for f in 0 ..< room {
                let l = data[f * channels], r = channels > 1 ? data[f * channels + 1] : second?[f] ?? l
                left.append(l)
                right.append(r)
            }
            // The song starts at its first sound: the silence before it is dropped as it comes.
            if !started, let sound = (silent ..< left.count).first(where: { abs(left[$0]) > 1e-4 || abs(right[$0]) > 1e-4 }) {
                silent = sound
            } else if !started {
                silent = left.count
            }
        }
    }

    private struct Process {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String?
    }

    /// The processes that Core Audio knows and that `matches` picks.
    private static func processes(_ matches: (Process) -> Bool) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return false }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            let bundleID = AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr
                ? bundle?.takeRetainedValue() as String? : nil
            return matches(Process(object: object, pid: pid, bundleID: bundleID))
        }
    }
}
