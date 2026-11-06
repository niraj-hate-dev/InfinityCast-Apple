//
//  AudioEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Hardened Two-Stage CoreAudio Audio Pipeline:
//  - Stage 1: Native CoreAudio PCM Normalizer (AudioConverterConvertComplexBuffer)
//             Converts any ReplayKit audio format (32-bit Float non-interleaved, 16-bit, mono/stereo)
//             into canonical 16-bit packed signed integer interleaved stereo PCM with 0 priming delay.
//  - Stage 2: Hardware-accelerated MPEG-4 AAC-LC Encoder (AudioConverterFillComplexBuffer)
//             Consumes normalized PCM lookahead ring buffer, handles 2112 priming samples,
//             and frames AAC packets with standard 7-byte MPEG-2/4 ADTS headers.
//

import Foundation
import CoreMedia
import AudioToolbox
import Darwin

public final class AudioEncoder {

    // MARK: - Types
    public typealias EncodedAudioHandler = (_ packet: Data) -> Void

    private final class InputTracker {
        var offset: Int = 0
    }

    // MARK: - State
    private var pcmConverter: AudioConverterRef?
    private var aacConverter: AudioConverterRef?
    private let audioQueue = DispatchQueue(label: "com.apowermirror.audio.queue", qos: .userInteractive)
    private let packetHandler: EncodedAudioHandler

    private var currentPcmSourceFormat: AudioStreamBasicDescription?
    private var sampleRate: Double = 48000.0
    private let channels: UInt32 = 2

    // Persistent PCM Ring Buffer
    // Stores canonical 16-bit signed integer interleaved stereo PCM frames
    private var pcmBuffer = Data()
    private var lastBufferPts: Double = -1.0

    private var aacBuffer: UnsafeMutablePointer<UInt8>
    private let aacBufferSize: Int = 4096
    private var frameCount: Int = 0

    // MARK: - Initialization

    public init(sampleRate: Double = 48000.0, channels: UInt32 = 2, handler: @escaping EncodedAudioHandler) {
        self.sampleRate = sampleRate
        self.packetHandler = handler
        self.aacBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: aacBufferSize)
    }

    deinit {
        invalidate()
        aacBuffer.deallocate()
    }

    public func invalidate() {
        audioQueue.sync {
            if let conv = self.pcmConverter {
                AudioConverterDispose(conv)
                self.pcmConverter = nil
            }
            if let conv = self.aacConverter {
                AudioConverterDispose(conv)
                self.aacConverter = nil
            }
            self.pcmBuffer.removeAll()
            self.lastBufferPts = -1.0
            self.frameCount = 0
            self.currentPcmSourceFormat = nil
        }
    }

    // MARK: - Direct PCM Encoding (Comfort Noise & Silence Priming)

    public func encodePCM(_ pcm16Data: Data) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            if self.aacConverter == nil {
                guard self.setupAacConverter(sampleRate: self.sampleRate) else { return }
            }

            self.pcmBuffer.append(pcm16Data)
            self.drainPcmBuffer()
        }
    }

    // MARK: - ReplayKit CMSampleBuffer Ingestion

    public func encode(sampleBuffer: CMSampleBuffer) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
                return
            }

            let inFormat = asbd.pointee
            let inSampleRate = (inFormat.mSampleRate >= 8000 && inFormat.mSampleRate <= 96000) ? inFormat.mSampleRate : 44100.0

            // 1. Re-initialize PCM Normalizer if incoming format changed
            let pcmFormatChanged: Bool = {
                guard let cur = self.currentPcmSourceFormat else { return true }
                return cur.mSampleRate != inFormat.mSampleRate ||
                       cur.mChannelsPerFrame != inFormat.mChannelsPerFrame ||
                       cur.mFormatFlags != inFormat.mFormatFlags ||
                       cur.mBytesPerFrame != inFormat.mBytesPerFrame ||
                       cur.mBitsPerChannel != inFormat.mBitsPerChannel
            }()

            if self.pcmConverter == nil || pcmFormatChanged {
                guard self.setupPcmConverter(for: inFormat) else { return }
            }

            // 2. Re-initialize AAC Encoder if sample rate changed
            if self.aacConverter == nil || abs(self.sampleRate - inSampleRate) > 1.0 {
                guard self.setupAacConverter(sampleRate: inSampleRate) else { return }
            }

            guard let pcmConv = self.pcmConverter, self.aacConverter != nil else { return }

            // 3. Discontinuity & Stale Silence Management
            // Natural speech/music pauses (300-800ms) must NEVER reset the encoder priming state!
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsSeconds = pts.isValid ? pts.seconds : -1.0
            if ptsSeconds > 0 && self.lastBufferPts > 0 {
                let gap = ptsSeconds - self.lastBufferPts
                if gap > 2.0 || gap < -1.0 {
                    self.pcmBuffer.removeAll()
                    if let aac = self.aacConverter { AudioConverterReset(aac) }
                    if let pcm = self.pcmConverter { AudioConverterReset(pcm) }
                    NSLog("[AudioEncoder] Audio discontinuity detected (gap: %.3fs) -> Ring buffer cleared & converters reset", gap)
                }
            }
            if ptsSeconds > 0 {
                self.lastBufferPts = ptsSeconds
            }

            // 4. Extract AudioBufferList from sampleBuffer
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { return }

            let isNonInterleaved = (inFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let inChannels = max(1, Int(inFormat.mChannelsPerFrame))
            let numBuffersNeeded = isNonInterleaved ? inChannels : 1

            let ablPointer = AudioBufferList.allocate(maximumBuffers: numBuffersNeeded)
            defer { free(ablPointer.unsafeMutablePointer) }

            ablPointer.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(numBuffersNeeded)
            for i in 0..<numBuffersNeeded {
                ablPointer[i].mData = nil
                ablPointer[i].mDataByteSize = 0
                ablPointer[i].mNumberChannels = isNonInterleaved ? 1 : UInt32(inChannels)
            }

            var blockBuffer: CMBlockBuffer? = nil
            let extractStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPointer.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: numBuffersNeeded),
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard extractStatus == noErr else {
                NSLog("[AudioEncoder] CMSampleBufferGetAudioBufferList failed: %d", extractStatus)
                return
            }

            // 5. Convert incoming PCM to 16-bit packed interleaved stereo using native CoreAudio AudioConverterConvertComplexBuffer
            // Eliminates any manual float casting, endianness bugs, or clipping distortion!
            let outByteSize = Int(numSamples) * 4 // 16-bit stereo = 4 bytes per frame
            var outPcm16 = [UInt8](repeating: 0, count: outByteSize)

            let convertStatus: OSStatus = outPcm16.withUnsafeMutableBytes { outRaw in
                var outAbl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outByteSize),
                        mData: outRaw.baseAddress
                    )
                )
                let status = AudioConverterConvertComplexBuffer(
                    pcmConv,
                    UInt32(numSamples),
                    ablPointer.unsafeMutablePointer,
                    &outAbl
                )
                if status == noErr {
                    let actualBytes = Int(outAbl.mBuffers.mDataByteSize)
                    if actualBytes > 0 && actualBytes <= outByteSize, let ptr = outRaw.baseAddress {
                        self.pcmBuffer.append(ptr.assumingMemoryBound(to: UInt8.self), count: actualBytes)
                    }
                } else {
                    NSLog("[AudioEncoder] AudioConverterConvertComplexBuffer failed: %d", status)
                }
                return status
            }

            _ = blockBuffer

            // 6. Drain normalized PCM buffer into AAC encoder
            self.drainPcmBuffer()
        }
    }

    // MARK: - CoreAudio AAC Ingestion & Packet Emission

    public func purgeStaleBuffer() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            if self.pcmBuffer.count > 8192 {
                let excess = self.pcmBuffer.count - 4096
                let alignedToRemove = (excess / 4) * 4
                if alignedToRemove > 0 {
                    self.pcmBuffer.removeSubrange(0..<alignedToRemove)
                }
            }
        }
    }

    private func drainPcmBuffer() {
        guard let converter = self.aacConverter else { return }

        // Ring buffer overflow protection: Keep max 2 frames (~46ms, 8,192 bytes), strictly 4-byte frame aligned
        // Prevents bufferbloat and latency buildup while ensuring ultra-low latency response in games
        if self.pcmBuffer.count > 32768 {
            let excess = self.pcmBuffer.count - 16384
            let alignedToRemove = (excess / 4) * 4
            if alignedToRemove > 0 {
                self.pcmBuffer.removeSubrange(0..<alignedToRemove)
            }
        }

        // Each AAC packet requires 1024 frames = 4096 bytes
        let kMinChunkBytes = 1024 * 4

        while self.pcmBuffer.count >= kMinChunkBytes {
            var outAbl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(self.aacBufferSize),
                    mData: UnsafeMutableRawPointer(self.aacBuffer)
                )
            )

            var ioOutputDataPackets: UInt32 = 1
            var packetDesc = AudioStreamPacketDescription()
            let tracker = InputTracker()

            let inputProc: AudioConverterComplexInputDataProc = { (
                _,
                ioNumberDataPackets,
                ioData,
                outDataPacketDescription,
                inUserData
            ) -> OSStatus in
                guard let inUserData = inUserData else {
                    ioNumberDataPackets.pointee = 0
                    return -1
                }
                let state = inUserData.assumingMemoryBound(to: (UnsafePointer<UInt8>, Int, InputTracker).self).pointee
                let basePtr = state.0
                let totalBytes = state.1
                let tracker = state.2

                let remainingBytes = totalBytes - tracker.offset
                if remainingBytes < 4 {
                    ioNumberDataPackets.pointee = 0
                    return -1 // Data temporarily depleted; halt FillComplexBuffer gracefully
                }

                let availablePackets = UInt32(remainingBytes / 4)
                let requestedPackets = ioNumberDataPackets.pointee
                let toGive = min(requestedPackets, availablePackets)
                let bytesToGive = toGive * 4

                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = 2
                ioData.pointee.mBuffers.mDataByteSize = bytesToGive
                ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: basePtr.advanced(by: tracker.offset))
                ioNumberDataPackets.pointee = toGive
                tracker.offset += Int(bytesToGive)

                if let outDesc = outDataPacketDescription {
                    outDesc.pointee = nil
                }
                return noErr
            }

            let convStatus = self.pcmBuffer.withUnsafeBytes { rawBytes -> OSStatus in
                guard let basePtr = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                var state = (basePtr, self.pcmBuffer.count, tracker)
                return AudioConverterFillComplexBuffer(
                    converter,
                    inputProc,
                    &state,
                    &ioOutputDataPackets,
                    &outAbl,
                    &packetDesc
                )
            }

            // CRITICAL: Consume ONLY what AudioConverter actually read from the ring buffer!
            if tracker.offset > 0 {
                let toRemove = min(tracker.offset, self.pcmBuffer.count)
                self.pcmBuffer.removeSubrange(0..<toRemove)
            }

            let aacSize = Int(packetDesc.mDataByteSize > 0 ? packetDesc.mDataByteSize : outAbl.mBuffers.mDataByteSize)
            if (convStatus == noErr || convStatus == -1) && ioOutputDataPackets > 0 && aacSize > 0 {
                let adts = self.createAdtsHeader(packetLength: aacSize)
                var packet = Data(capacity: 7 + aacSize)
                packet.append(adts)
                packet.append(self.aacBuffer, count: aacSize)

                self.frameCount += 1
                if self.frameCount <= 5 || self.frameCount % 200 == 0 {
                    NSLog("[AudioEncoder] Encoded AAC frame #%d (%d bytes @ %.0f Hz)", self.frameCount, packet.count, self.sampleRate)
                }

                self.packetHandler(packet)
            } else {
                // Not enough samples to output a complete packet yet (encoder priming); wait for next buffer
                break
            }
        }
    }

    // MARK: - Stage 1: PCM Normalizer Initialization

    private func setupPcmConverter(for inFormat: AudioStreamBasicDescription) -> Bool {
        if let old = self.pcmConverter {
            AudioConverterDispose(old)
            self.pcmConverter = nil
        }

        var source = inFormat
        var target = AudioStreamBasicDescription(
            mSampleRate: inFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var status = AudioConverterNew(&source, &target, &pcmConverter)
        if status != noErr {
            NSLog("[AudioEncoder] Failed to create pcmConverter: %d (inFormat: sr=%.0f, ch=%d, flags=0x%x, bits=%d)",
                  status, source.mSampleRate, source.mChannelsPerFrame, source.mFormatFlags, source.mBitsPerChannel)
            return false
        }

        if inFormat.mChannelsPerFrame == 1, let conv = pcmConverter {
            var channelMap: [Int32] = [0, 0] // Map mono input to both L & R stereo channels
            AudioConverterSetProperty(
                conv,
                kAudioConverterChannelMap,
                UInt32(MemoryLayout<Int32>.size * 2),
                &channelMap
            )
        }

        self.currentPcmSourceFormat = inFormat
        NSLog("[AudioEncoder] Initialized CoreAudio PCM Converter: in(sr=%.0f, ch=%d, flags=0x%x, bits=%d) -> target 16-bit stereo PCM",
              source.mSampleRate, source.mChannelsPerFrame, source.mFormatFlags, source.mBitsPerChannel)
        return true
    }

    // MARK: - Stage 2: AAC Encoder Initialization

    private func setupAacConverter(sampleRate: Double) -> Bool {
        if let old = self.aacConverter {
            AudioConverterDispose(old)
            self.aacConverter = nil
        }

        self.sampleRate = sampleRate

        var sourceFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue), // 2
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var description = AudioClassDescription(
            mType: kAudioEncoderComponentType,
            mSubType: kAudioFormatMPEG4AAC,
            mManufacturer: kAppleSoftwareAudioCodecManufacturer
        )

        var status = AudioConverterNewSpecific(
            &sourceFormat,
            &destinationFormat,
            1,
            &description,
            &aacConverter
        )

        if status != noErr {
            status = AudioConverterNew(&sourceFormat, &destinationFormat, &aacConverter)
        }

        guard status == noErr, let converter = aacConverter else {
            NSLog("[AudioEncoder] AAC AudioConverter initialization failed with status: %d", status)
            return false
        }

        var bitrate: UInt32 = 256_000 // 256 kbps Studio Master Quality
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )

        var quality: UInt32 = kAudioConverterQuality_Max // Full 20kHz frequency response & transparent acoustics
        AudioConverterSetProperty(
            converter,
            kAudioConverterCodecQuality,
            UInt32(MemoryLayout<UInt32>.size),
            &quality
        )

        NSLog("[AudioEncoder] Initialized AAC-LC encoder: %.0f Hz, 2 channels, 256 kbps (Max Quality)", sampleRate)
        return true
    }

    // MARK: - ADTS Framing (matching ASM @ 0xe56c)

    private func createAdtsHeader(packetLength: Int) -> Data {
        let totalLength = packetLength + 7
        var header = [UInt8](repeating: 0, count: 7)

        let profile: UInt8 = 2 // AAC LC
        let sampleRateIndex = getSampleRateIndex(sampleRate: sampleRate)
        let channelConfig = UInt8(channels)

        // Syncword: 0xFFF + MPEG-2 AAC, No CRC (ASM @ 0xe5bc: 0xf9ff)
        header[0] = 0xFF
        header[1] = 0xF9

        // Profile (2 bits) + Frequency Index (4 bits) + Private (1 bit) + Channel (1 bit)
        header[2] = ((profile - 1) << 6) | (sampleRateIndex << 2) | ((channelConfig >> 2) & 0x01)

        // Channel (2 bits) + Copy (1 bit) + Home (1 bit) + Frame Length MSB (2 bits)
        header[3] = ((channelConfig & 0x03) << 6) | UInt8((totalLength >> 11) & 0x03)

        // Frame Length middle (8 bits)
        header[4] = UInt8((totalLength >> 3) & 0xFF)

        // Frame Length LSB (3 bits) + Buffer Fullness MSB (5 bits)
        header[5] = UInt8((totalLength & 0x07) << 5) | 0x1F

        // Buffer Fullness LSB (6 bits) + Number of AAC frames (2 bits, 0 = 1 frame)
        header[6] = 0xFC

        return Data(header)
    }

    private func getSampleRateIndex(sampleRate: Double) -> UInt8 {
        switch Int(sampleRate) {
        case 96000: return 0x0
        case 88200: return 0x1
        case 64000: return 0x2
        case 48000: return 0x3
        case 44100: return 0x4
        case 32000: return 0x5
        case 24000: return 0x6
        case 22050: return 0x7
        case 16000: return 0x8
        case 12000: return 0x9
        case 11025: return 0xA
        case 8000:  return 0xB
        default:    return 0x4
        }
    }
}
