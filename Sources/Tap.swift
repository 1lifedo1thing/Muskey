import AudioToolbox
import CoreAudio
import Foundation

struct TapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw TapError(step: step, status: status) }
}

/// Where the lyrics hear the song: the system's audio, or a file in the replay test.
protocol AudioTapping: AnyObject {
    var sampleRate: Double { get }
    func prepare() throws
    func start(onSamples: @escaping ([Float]) -> Void) throws
    func stop()
}

/// Everything the Mac is playing, mixed down to mono, through a Core Audio process tap.
/// A global tap needs no output device in the aggregate, so no microphone channels leak in.
/// Muskey's own output is left out, so a listen during a pitch change hears the song in its original key.
final class SystemAudioTap: AudioTapping {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "muskey.io", qos: .userInitiated)
    private(set) var sampleRate: Double = 48000

    /// Closed by `stop`, which returns before Core Audio has stopped the device: no samples are handed on after it.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = true
        var open: Bool { lock.withLock { isOpen } }
        func close() { lock.withLock { isOpen = false } }
    }

    private var gate: Gate?
    /// Stopping a device and destroying it and its tap takes tens of milliseconds, which the main thread doesn't wait
    /// for: the HUD starts and stops a tap whenever it shows and hides.
    private static let teardown = DispatchQueue(label: "muskey.io.teardown", qos: .utility)

    private let description = CATapDescription(stereoGlobalTapButExcludeProcesses: AudioProcess.own.map { [$0] } ?? [])

    /// Creates the tap and reads its format, so `sampleRate` is known before any audio arrives.
    func prepare() throws {
        description.uuid = UUID()
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the process tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Reading the tap format")
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw TapError(step: "Tap format is not Float32", status: -1) }
        sampleRate = format.mSampleRate
    }

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Muskey",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the aggregate device")

        let gate = Gate()
        self.gate = gate
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            guard gate.open else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0, let first = buffers.first, first.mNumberChannels > 0 else { return }

            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
            guard frames > 0 else { return }

            // Interleaved or not, every channel lands in the same mono frame.
            var mono = [Float](repeating: 0, count: frames)
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let stride = Int(buffer.mNumberChannels)
                let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
                for frame in 0 ..< min(frames, available) {
                    for channel in 0 ..< stride {
                        mono[frame] += data[frame * stride + channel]
                    }
                }
            }
            let scale = 1 / Float(channels)
            for i in mono.indices { mono[i] *= scale }
            onSamples(mono)
        }, "Creating the IO proc")

        try check(AudioDeviceStart(aggregateID, procID), "Starting the aggregate device")
    }

    func stop() {
        gate?.close()
        gate = nil
        let aggregate = aggregateID, proc = procID, tap = tapID
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        guard aggregate != kAudioObjectUnknown || tap != kAudioObjectUnknown else { return }
        Self.teardown.async {
            if aggregate != kAudioObjectUnknown {
                if let proc {
                    AudioDeviceStop(aggregate, proc)
                    AudioDeviceDestroyIOProcID(aggregate, proc)
                }
                AudioHardwareDestroyAggregateDevice(aggregate)
            }
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        }
    }

    deinit { stop() }
}

enum AudioProcess {
    /// Muskey's Core Audio process object, which a global tap leaves out to avoid hearing its own output.
    static var own: AudioObjectID? { object(for: getpid()) }

    /// The Core Audio process object of a running process, once it has played audio.
    static func object(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// System audio capture sits behind TCC's kTCCServiceAudioCapture, which has no public preflight API.
enum AudioCapturePermission {
    enum Status { case granted, denied, undetermined }

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    static var status: Status {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .undetermined }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return completion(true) }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
