//
//  AudioEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Reconstructed 1:1 from ApowerMirror WXCastiOSSender:
//  - -[WXCastSenderAudioEncoder setupEncoderFromSampleBuffer:] @ 0xe374
//  - -[WXCastSenderAudioEncoder encodeAACSampleBuffer:completionBlock:] @ 0xdfec
//  - _wxCastSenderAudioEncoderInInputDataProc @ 0xdf20
//  - -[WXCastSenderAudioEncoder adtsDataForPacketLength:] @ 0xe56c
//  - -[WXCastSenderServer sendAACData:] @ 0x10680
//
//  Hardened with Persistent FIFO PCM Ring Buffer, Discontinuity Reset (>250ms gap),
//  Dynamic ASBD Adaptation (44.1kHz / 48kHz, mono / stereo), and Compliant CoreAudio EOF.
//

import Foundation
import CoreMedia
import AudioToolbox
import Darwin

public final class AudioEncoder {

    // MARK: - Types
    public typealias EncodedAudioHandler = (_ packet: Data) -> Void

    // MARK: - State
    private var audioConverter: AudioConverterRef?
    private let audioQueue = DispatchQueue(label: "com.apowermirror.audio.queue", qos: .userInteractive)
    private let packetHandler: EncodedAudioHandler

    private var currentSourceFormat: AudioStreamBasicDescription?
    private var sampleRate: Double = 44100.0
    private var channels: UInt32 = 2
    private var bytesPerFrame: UInt32 = 4

    // Persistent PCM FIFO Buffer
    // Accumulates raw PCM frames across arbitrary chunk sizes (441, 512, 1024, 2048 samples)
    // so AudioConverterFillComplexBuffer always receives exact 1024-frame chunks required by AAC-LC
    private var pcmBuffer = Data()
    private var lastBufferPts: Double = -1.0

    private var aacBuffer: UnsafeMutablePointer<UInt8>
    private let aacBufferSize: Int = 2048
    private var frameCount: Int = 0

    // MARK: - Initialization

    public init(sampleRate: Double = 44100.0, channels: UInt32 = 2, handler: @escaping EncodedAudioHandler) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bytesPerFrame = 2 * channels
        self.packetHandler = handler
        self.aacBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: aacBufferSize)
    }

    deinit {
        invalidate()
        aacBuffer.deallocate()
    }

    public func invalidate() {
        audioQueue.sync {
            if let converter = self.audioConverter {
                AudioConverterDispose(converter)
                self.audioConverter = nil
            }
            self.pcmBuffer.removeAll()
            self.lastBufferPts = -1.0
            self.frameCount = 0
        }
    }

    // MARK: - Direct PCM Encoding (Comfort Noise & Silence Priming)

    public func encodePCM(_ pcm16Data: Data) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            if self.audioConverter == nil {
                guard self.setupAudioConverter(sampleRate: self.sampleRate, channels: self.channels) else { return }
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

            let newFormat = asbd.pointee

            // 1. Dynamic ASBD Format Re-initialization
            let formatChanged: Bool = {
                guard let cur = self.currentSourceFormat else { return true }
                return cur.mSampleRate != newFormat.mSampleRate ||
                       cur.mChannelsPerFrame != newFormat.mChannelsPerFrame ||
                       cur.mFormatFlags != newFormat.mFormatFlags ||
                       cur.mBytesPerFrame != newFormat.mBytesPerFrame ||
                       cur.mBitsPerChannel != newFormat.mBitsPerChannel
            }()

            if self.audioConverter == nil || formatChanged {
                if let oldConv = self.audioConverter {
                    AudioConverterDispose(oldConv)
                    self.audioConverter = nil
                }
                self.pcmBuffer.removeAll()
                self.lastBufferPts = -1.0
                guard self.setupAudioConverter(for: newFormat) else { return }
            }

            guard self.audioConverter != nil else { return }

            // 2. Discontinuity Detection (Pause / Resume gap > 250ms)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsSeconds = pts.isValid ? pts.seconds : -1.0
            if ptsSeconds > 0 && self.lastBufferPts > 0 {
                let gap = ptsSeconds - self.lastBufferPts
                if gap > 0.25 || gap < 0 {
                    self.pcmBuffer.removeAll()
                    if let conv = self.audioConverter {
                        AudioConverterReset(conv)
                    }
                    NSLog("[AudioEncoder] Audio discontinuity detected (gap: %.3fs) -> Ring buffer cleared & converter reset", gap)
                }
            }
            if ptsSeconds > 0 {
                self.lastBufferPts = ptsSeconds
            }

            // 3. Extract PCM samples from CMSampleBuffer into persistent ring buffer
            let inFlags = newFormat.mFormatFlags
            let inChannels = max(1, Int(newFormat.mChannelsPerFrame))
            let isNonInterleaved = (inFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let isFloat = (inFlags & kAudioFormatFlagIsFloat) != 0
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0 else { return }

            let ablPointer = AudioBufferList.allocate(maximumBuffers: inChannels)
            defer { free(ablPointer.unsafeMutablePointer) }

            var blockBuffer: CMBlockBuffer? = nil
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: ablPointer.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: inChannels),
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr else { return }

            var pcm16 = [Int16](repeating: 0, count: numSamples * 2)

            if isFloat {
                if isNonInterleaved && ablPointer.count >= 2 && inChannels >= 2 {
                    if let leftPtr = ablPointer[0].mData?.assumingMemoryBound(to: Float.self),
                       let rightPtr = ablPointer[1].mData?.assumingMemoryBound(to: Float.self) {
                        for i in 0..<numSamples {
                            let l = max(-1.0, min(1.0, leftPtr[i]))
                            let r = max(-1.0, min(1.0, rightPtr[i]))
                            pcm16[i * 2]     = Int16(l * 32767.0)
                            pcm16[i * 2 + 1] = Int16(r * 32767.0)
                        }
                    }
                } else if let floatPtr = ablPointer[0].mData?.assumingMemoryBound(to: Float.self) {
                    if inChannels == 1 {
                        for i in 0..<numSamples {
                            let s = Int16(max(-1.0, min(1.0, floatPtr[i])) * 32767.0)
                            pcm16[i * 2]     = s
                            pcm16[i * 2 + 1] = s
                        }
                    } else {
                        for i in 0..<numSamples {
                            pcm16[i * 2]     = Int16(max(-1.0, min(1.0, floatPtr[i * 2])) * 32767.0)
                            pcm16[i * 2 + 1] = Int16(max(-1.0, min(1.0, floatPtr[i * 2 + 1])) * 32767.0)
                        }
                    }
                }
            } else {
                if isNonInterleaved && ablPointer.count >= 2 && inChannels >= 2 {
                    if let leftPtr = ablPointer[0].mData?.assumingMemoryBound(to: Int16.self),
                       let rightPtr = ablPointer[1].mData?.assumingMemoryBound(to: Int16.self) {
                        for i in 0..<numSamples {
                            pcm16[i * 2]     = leftPtr[i]
                            pcm16[i * 2 + 1] = rightPtr[i]
                        }
                    }
                } else if let intPtr = ablPointer[0].mData?.assumingMemoryBound(to: Int16.self) {
                    if inChannels == 1 {
                        for i in 0..<numSamples {
                            pcm16[i * 2]     = intPtr[i]
                            pcm16[i * 2 + 1] = intPtr[i]
                        }
                    } else {
                        for i in 0..<numSamples * 2 {
                            pcm16[i] = intPtr[i]
                        }
                    }
                }
            }

            pcm16.withUnsafeBytes { rawBytes in
                self.pcmBuffer.append(contentsOf: rawBytes)
            }

            _ = blockBuffer

            self.drainPcmBuffer()
        }
    }

    // MARK: - CoreAudio AAC Ingestion & Packet Emission

    private func drainPcmBuffer() {
        guard let converter = self.audioConverter else { return }

        // Bounded buffer protection (prevent unbounded growth if stalled)
        if self.pcmBuffer.count > 192_000 {
            self.pcmBuffer.removeSubrange(0..<(self.pcmBuffer.count - 32768))
        }

        // Standard AAC-LC requires exact 1024-frame chunks (1024 * 4 bytes for 16-bit stereo)
        let requiredChunkSize = 1024 * 4

        while self.pcmBuffer.count >= requiredChunkSize {
            var chunkData = self.pcmBuffer.subdata(in: 0..<requiredChunkSize)
            self.pcmBuffer.removeSubrange(0..<requiredChunkSize)

            var inputABL = AudioBufferList()
            inputABL.mNumberBuffers = 1
            inputABL.mBuffers.mNumberChannels = 2
            inputABL.mBuffers.mDataByteSize = UInt32(requiredChunkSize)

            chunkData.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
                guard let basePtr = rawBuf.baseAddress else { return }
                inputABL.mBuffers.mData = basePtr

                var outAudioBufferList = AudioBufferList()
                outAudioBufferList.mNumberBuffers = 1
                outAudioBufferList.mBuffers.mNumberChannels = 2
                outAudioBufferList.mBuffers.mDataByteSize = UInt32(self.aacBufferSize)
                outAudioBufferList.mBuffers.mData = UnsafeMutableRawPointer(self.aacBuffer)

                var ioOutputDataPacketSize: UInt32 = 1

                let inputProc: AudioConverterComplexInputDataProc = { (
                    _,
                    ioNumberDataPackets,
                    ioData,
                    _,
                    inUserData
                ) -> OSStatus in
                    guard let inUserData = inUserData else {
                        ioNumberDataPackets.pointee = 0
                        return noErr
                    }
                    let abl = inUserData.assumingMemoryBound(to: AudioBufferList.self)
                    let byteSize = abl.pointee.mBuffers.mDataByteSize
                    if byteSize == 0 {
                        ioNumberDataPackets.pointee = 0
                        return noErr // CoreAudio standard EOF return
                    }

                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mData = abl.pointee.mBuffers.mData
                    ioData.pointee.mBuffers.mNumberChannels = 2
                    ioData.pointee.mBuffers.mDataByteSize = byteSize
                    ioNumberDataPackets.pointee = byteSize / 4

                    abl.pointee.mBuffers.mDataByteSize = 0
                    return noErr
                }

                let convStatus = AudioConverterFillComplexBuffer(
                    converter,
                    inputProc,
                    &inputABL,
                    &ioOutputDataPacketSize,
                    &outAudioBufferList,
                    nil
                )

                if (convStatus == noErr || ioOutputDataPacketSize > 0) && outAudioBufferList.mBuffers.mDataByteSize > 0 {
                    let aacSize = Int(outAudioBufferList.mBuffers.mDataByteSize)
                    if aacSize > 0 {
                        // Prepend standard 7-byte ADTS Header (matching ASM @ 0xe56c)
                        let adtsHeader = self.createAdtsHeader(packetLength: aacSize)
                        var packet = Data(adtsHeader)
                        packet.append(self.aacBuffer, count: aacSize)

                        self.frameCount += 1
                        if self.frameCount <= 5 || self.frameCount % 200 == 0 {
                            NSLog("[AudioEncoder] Encoded AAC frame #%d (%d bytes @ %.0f Hz)", self.frameCount, packet.count, self.sampleRate)
                        }

                        self.packetHandler(packet)
                    }
                }
            }
        }
    }

    // MARK: - Converter Initialization (matching ASM @ 0xe374)

    private func setupAudioConverter(for newFormat: AudioStreamBasicDescription) -> Bool {
        self.currentSourceFormat = newFormat
        let sr = newFormat.mSampleRate > 0 ? newFormat.mSampleRate : 44100.0
        return setupAudioConverter(sampleRate: sr, channels: 2)
    }

    private func setupAudioConverter(sampleRate: Double, channels: UInt32) -> Bool {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bytesPerFrame = 4 // Standard 16-bit packed stereo PCM

        var sourceFormat = AudioStreamBasicDescription(
            mSampleRate: self.sampleRate,
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
            mSampleRate: self.sampleRate,
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
            &audioConverter
        )

        if status != noErr {
            status = AudioConverterNew(&sourceFormat, &destinationFormat, &audioConverter)
        }

        guard status == noErr, let converter = audioConverter else {
            NSLog("[AudioEncoder] AudioConverter initialization failed with status: %d", status)
            return false
        }

        var bitrate: UInt32 = 128_000
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )

        NSLog("[AudioEncoder] Initialized AAC encoder: %.0f Hz, %d channels, %d bytes/frame", self.sampleRate, self.channels, self.bytesPerFrame)
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
