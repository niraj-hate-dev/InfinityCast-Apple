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

import Foundation
import CoreMedia
import AudioToolbox
import Darwin

public final class AudioEncoder {

    // MARK: - Types
    public typealias EncodedAudioHandler = (_ packet: Data) -> Void

    // StackAudioBufferList2 provides stack-allocated memory layout matching AudioBufferList
    // with space for up to 2 buffers (40 bytes), eliminating dynamic allocation while preventing buffer overrun
    private struct StackAudioBufferList2 {
        var mNumberBuffers: UInt32 = 2
        var mBuffer0: AudioBuffer = AudioBuffer()
        var mBuffer1: AudioBuffer = AudioBuffer()
    }

    // MARK: - State
    private var audioConverter: AudioConverterRef?
    private let audioQueue = DispatchQueue(label: "com.apowermirror.audio.queue", qos: .userInteractive)
    private let packetHandler: EncodedAudioHandler

    private var currentSourceFormat: AudioStreamBasicDescription?
    private var sampleRate: Double = 44100.0
    private var channels: UInt32 = 2
    private var aacBuffer: UnsafeMutablePointer<UInt8>
    private let aacBufferSize: Int = 2048
    private var frameCount: Int = 0

    // MARK: - Initialization

    public init(sampleRate: Double = 44100.0, channels: UInt32 = 2, handler: @escaping EncodedAudioHandler) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.packetHandler = handler
        self.aacBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: aacBufferSize)
    }

    // MARK: - Input Context & Ingestion

    private final class InputContext {
        let buffer0Data: UnsafeMutableRawPointer?
        let buffer0Channels: UInt32
        let buffer1Data: UnsafeMutableRawPointer?
        let buffer1Channels: UInt32
        let numBuffers: UInt32
        let bytesPerFrame: UInt32
        let totalFrames: UInt32
        var currentFrameOffset: UInt32 = 0

        init(stackAbl: StackAudioBufferList2, bytesPerFrame: UInt32, totalFrames: UInt32) {
            self.buffer0Data = stackAbl.mBuffer0.mData
            self.buffer0Channels = stackAbl.mBuffer0.mNumberChannels
            self.buffer1Data = stackAbl.mBuffer1.mData
            self.buffer1Channels = stackAbl.mBuffer1.mNumberChannels
            self.numBuffers = stackAbl.mNumberBuffers
            self.bytesPerFrame = max(bytesPerFrame, 1)
            self.totalFrames = totalFrames
            self.currentFrameOffset = 0
        }
    }

    public func encode(sampleBuffer: CMSampleBuffer) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
                return
            }

            let newFormat = asbd.pointee
            let formatChanged: Bool = {
                guard let cur = self.currentSourceFormat else { return true }
                return cur.mSampleRate != newFormat.mSampleRate ||
                       cur.mChannelsPerFrame != newFormat.mChannelsPerFrame ||
                       cur.mFormatFlags != newFormat.mFormatFlags ||
                       cur.mBytesPerFrame != newFormat.mBytesPerFrame
            }()

            if self.audioConverter == nil || formatChanged {
                if let oldConv = self.audioConverter {
                    AudioConverterDispose(oldConv)
                    self.audioConverter = nil
                }
                guard self.setupAudioConverter(for: sampleBuffer) else { return }
            }

            guard let converter = self.audioConverter else { return }

            // 1. Stack-allocated 2-buffer AudioBufferList (zero heap allocation, zero crash risk, supports both interleaved & non-interleaved)
            var stackAbl = StackAudioBufferList2()
            var blockBuffer: CMBlockBuffer? = nil

            let status = withUnsafeMutablePointer(to: &stackAbl) { stackPtr in
                stackPtr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { ablPtr in
                    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                        sampleBuffer,
                        bufferListSizeNeededOut: nil,
                        bufferListOut: ablPtr,
                        bufferListSize: MemoryLayout<StackAudioBufferList2>.size,
                        blockBufferAllocator: nil,
                        blockBufferMemoryAllocator: nil,
                        flags: 0,
                        blockBufferOut: &blockBuffer
                    )
                }
            }

            guard status == noErr else {
                NSLog("[AudioEncoder] CMSampleBufferGetAudioBufferList error: %d", status)
                return
            }

            let numSamples = UInt32(max(CMSampleBufferGetNumSamples(sampleBuffer), 0))
            guard numSamples > 0 else { return }

            let bytesPerFrame = newFormat.mBytesPerFrame > 0 ? newFormat.mBytesPerFrame : (2 * self.channels)
            let context = InputContext(stackAbl: stackAbl, bytesPerFrame: bytesPerFrame, totalFrames: numSamples)

            // Input proc handling arbitrary chunk frames and both interleaved and non-interleaved audio
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
                let ctx = Unmanaged<InputContext>.fromOpaque(inUserData).takeUnretainedValue()
                let remaining = ctx.totalFrames > ctx.currentFrameOffset ? (ctx.totalFrames - ctx.currentFrameOffset) : 0
                if remaining == 0 {
                    ioNumberDataPackets.pointee = 0
                    return noErr
                }

                let framesToProvide = min(ioNumberDataPackets.pointee, remaining)
                let byteOffset = Int(ctx.currentFrameOffset * ctx.bytesPerFrame)
                let byteSize = framesToProvide * ctx.bytesPerFrame

                ioData.pointee.mNumberBuffers = ctx.numBuffers
                if ctx.numBuffers >= 2 {
                    let dstBuffers = UnsafeMutableAudioBufferListPointer(ioData)
                    if let b0 = ctx.buffer0Data {
                        dstBuffers[0].mData = b0.advanced(by: byteOffset)
                        dstBuffers[0].mDataByteSize = byteSize
                        dstBuffers[0].mNumberChannels = ctx.buffer0Channels
                    }
                    if let b1 = ctx.buffer1Data {
                        dstBuffers[1].mData = b1.advanced(by: byteOffset)
                        dstBuffers[1].mDataByteSize = byteSize
                        dstBuffers[1].mNumberChannels = ctx.buffer1Channels
                    }
                } else {
                    if let b0 = ctx.buffer0Data {
                        ioData.pointee.mBuffers.mData = b0.advanced(by: byteOffset)
                        ioData.pointee.mBuffers.mDataByteSize = byteSize
                        ioData.pointee.mBuffers.mNumberChannels = ctx.buffer0Channels
                    }
                }

                ioNumberDataPackets.pointee = framesToProvide
                ctx.currentFrameOffset += framesToProvide
                return noErr
            }

            // Loop to encode ALL audio packets present in this sample buffer without dropping any frames
            while true {
                var outAudioBufferList = AudioBufferList()
                outAudioBufferList.mNumberBuffers = 1
                outAudioBufferList.mBuffers.mNumberChannels = self.channels
                outAudioBufferList.mBuffers.mDataByteSize = UInt32(self.aacBufferSize)
                outAudioBufferList.mBuffers.mData = UnsafeMutableRawPointer(self.aacBuffer)

                var ioOutputDataPacketSize: UInt32 = 1

                let convStatus = AudioConverterFillComplexBuffer(
                    converter,
                    inputProc,
                    Unmanaged.passUnretained(context).toOpaque(),
                    &ioOutputDataPacketSize,
                    &outAudioBufferList,
                    nil
                )

                if convStatus == noErr && ioOutputDataPacketSize > 0 {
                    let aacSize = Int(outAudioBufferList.mBuffers.mDataByteSize)
                    if aacSize > 0 {
                        // Prepend standard 7-byte ADTS Header (matching ASM @ 0xe56c)
                        let adtsHeader = self.createAdtsHeader(packetLength: aacSize)
                        var packet = Data(adtsHeader)
                        packet.append(self.aacBuffer, count: aacSize)

                        self.frameCount += 1
                        if self.frameCount <= 5 || self.frameCount % 200 == 0 {
                            NSLog("[AudioEncoder] Encoded AAC frame #%d (%d bytes)", self.frameCount, packet.count)
                        }

                        self.packetHandler(packet)
                    }
                } else {
                    break
                }
            }

            // Retain blockBuffer throughout conversion
            _ = blockBuffer
        }
    }

    // MARK: - Converter Initialization (matching ASM @ 0xe374)

    private func setupAudioConverter(for sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return false
        }

        var sourceFormat = asbd.pointee
        self.currentSourceFormat = sourceFormat
        self.sampleRate = sourceFormat.mSampleRate > 0 ? sourceFormat.mSampleRate : 44100.0
        self.channels = sourceFormat.mChannelsPerFrame > 0 ? sourceFormat.mChannelsPerFrame : 2

        var destinationFormat = AudioStreamBasicDescription()
        destinationFormat.mSampleRate = self.sampleRate
        destinationFormat.mFormatID = kAudioFormatMPEG4AAC
        destinationFormat.mFormatFlags = AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue) // 2
        destinationFormat.mBytesPerPacket = 0
        destinationFormat.mFramesPerPacket = 1024
        destinationFormat.mBytesPerFrame = 0
        destinationFormat.mChannelsPerFrame = self.channels
        destinationFormat.mBitsPerChannel = 0
        destinationFormat.mReserved = 0

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

        NSLog("[AudioEncoder] Initialized AAC encoder: %.0f Hz, %d channels", self.sampleRate, self.channels)
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

    public func invalidate() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
    }

    deinit {
        invalidate()
        aacBuffer.deallocate()
    }
}
