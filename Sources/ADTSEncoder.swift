import AudioToolbox
import Foundation

/// Encodes the phone stream into AAC-LC, about a tenth of the 16-bit PCM it replaces, for a phone that listens over
/// mobile data. Each packet of 1024 frames goes out with an ADTS header, so the page can find the packets in the byte
/// stream and hand them to WebCodecs' AudioDecoder without any setup. AudioToolbox encodes a second of stereo in about
/// a millisecond, so the encoder adds only its own delay of about 45 ms. Used only on the queue of `WebStream`.
final class ADTSEncoder {
    let rate: Double

    init?(rate: Double, bitRate: UInt32 = 160_000) {
        // ADTS names the sample rate by its index in this list.
        let indexes: [Double: UInt8] = [96000: 0, 88200: 1, 64000: 2, 48000: 3, 44100: 4, 32000: 5, 24000: 6, 22050: 7, 16000: 8]
        guard let index = indexes[rate] else { return nil }
        var input = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        var bits = bitRate
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bits)
        var largest: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &largest)
        self.rate = rate
        self.converter = converter
        frequencyIndex = index
        packet = [UInt8](repeating: 0, count: Int(max(largest, 1536)))
    }

    /// AAC can be encoded at `rate`. AudioToolbox has no AAC encoder above 48 kHz, and below 32 kHz, as on a headset
    /// in a call, the converter takes the bit rate but writes no packets, so those rates get PCM.
    static func supports(_ rate: Double) -> Bool {
        (32000 ... 48000).contains(rate) && ADTSEncoder(rate: rate) != nil
    }

    deinit {
        AudioConverterDispose(converter)
        feed.deallocate()
    }

    /// The ADTS frames that `samples` (interleaved stereo) complete. Samples left over wait for the next call.
    func encode(_ samples: UnsafeBufferPointer<Int16>) -> Data {
        pending.append(contentsOf: samples)
        var frames = Data()
        while pending.count - used >= 2048 {
            var count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = packet.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                let status = AudioConverterFillComplexBuffer(converter, Self.supply, Unmanaged.passUnretained(self).toOpaque(), &count, &list, &description)
                produced = Int(list.mBuffers.mDataByteSize)
                return status
            }
            guard status == noErr || status == Self.waiting else { break }
            if count > 0, produced > 0 { frames.append(adts(produced)) }
            if status == Self.waiting, count == 0 { break }
        }
        pending.removeFirst(used)
        used = 0
        return frames
    }

    private let converter: AudioConverterRef
    private let frequencyIndex: UInt8
    private var packet: [UInt8]
    private var produced = 0
    /// Interleaved samples that the converter hasn't taken yet, from `used` on.
    private var pending: [Int16] = []
    private var used = 0
    /// What the converter reads from during one fill, which has to stay in place until the next callback.
    private let feed = UnsafeMutablePointer<Int16>.allocate(capacity: 2 * 4096)

    /// The status that tells the converter to stop for now: the samples that it asked for haven't arrived yet.
    private static let waiting: OSStatus = 0x7761_6974

    private static let supply: AudioConverterComplexInputDataProc = { _, packets, data, _, context in
        let encoder = Unmanaged<ADTSEncoder>.fromOpaque(context!).takeUnretainedValue()
        let available = (encoder.pending.count - encoder.used) / 2
        let frames = min(Int(packets.pointee), available, 4096)
        guard frames > 0 else {
            packets.pointee = 0
            return waiting
        }
        encoder.pending.withUnsafeBufferPointer { buffer in
            encoder.feed.update(from: buffer.baseAddress! + encoder.used, count: frames * 2)
        }
        encoder.used += frames * 2
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 4), mData: encoder.feed)
        packets.pointee = UInt32(frames)
        return noErr
    }

    /// The packet in `packet` behind a 7-byte ADTS header: AAC-LC, the rate's index, two channels, no checksum.
    private func adts(_ size: Int) -> Data {
        let length = size + 7
        var frame = Data(capacity: length)
        frame.append(contentsOf: [
            0xFF, 0xF1,
            UInt8((1 << 6) | (Int(frequencyIndex) << 2) | (2 >> 2)),
            UInt8(((2 & 3) << 6) | (length >> 11)),
            UInt8((length >> 3) & 0xFF),
            UInt8(((length & 7) << 5) | 0x1F),
            0xFC,
        ])
        frame.append(contentsOf: packet[0 ..< size])
        return frame
    }
}
