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
//  and Dynamic ASBD Format Re-initialization (44.1kHz / 48kHz, mono / stereo).
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

    public func encode(sampleBuffer: CMSampleBuffer) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
                return
            }

            let newFormat = asbd.pointee

            // 1. Dynamic ASBD Format Re-initialization
            // ReplayKit dynamically changes format between apps or during pause/resume (44.1kHz / 48kHz, mono / stereo)
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

            guard let converter = self.audioConverter else { return }

            // 2. Discontinuity Detection (Pause / Resume gap > 250ms)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsSeconds = pts.isValid ? pts.seconds : -1.0
            if ptsSeconds > 0 && self.lastBufferPts > 0 {
                let gap = ptsSeconds - self.lastBufferPts
                if gap > 0.25 || gap < 0 {
                    // Audio paused & resumed! Clear leftover partial frames and reset converter state
                    self.pcmBuffer.removeAll()
                    AudioConverterReset(converter)
                    NSLog("[AudioEncoder] Audio discontinuity detected (gap: %.3fs) -> Ring buffer cleared & converter reset", gap)
                }
            }
            if ptsSeconds > 0 {
                self.lastBufferPts = ptsSeconds
            }

            // 3. Extract PCM samples from CMSampleBuffer into persistent ring buffer
            var bufferList = AudioBufferList()
            var blockBuffer: CMBlockBuffer? = nil
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &bufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )

            guard status == noErr, let mData = bufferList.mBuffers.mData else {
                return
            }

            let incomingByteSize = Int(bufferList.mBuffers.mDataByteSize)
            if incomingByteSize > 0 {
                self.pcmBuffer.append(mData.assumingMemoryBound(to: UInt8.self), count: incomingByteSize)
            }

            // Retain blockBuffer until extraction is complete
            _ = blockBuffer

            // 4. Encode exact 1024-frame chunks from the ring buffer
            let bpf = self.bytesPerFrame > 0 ? self.bytesPerFrame : (2 * self.channels)
            let requiredChunkSize = Int(1024 * bpf)

            while self.pcmBuffer.count >= requiredChunkSize {
                var chunkData = self.pcmBuffer.subdata(in: 0..<requiredChunkSize)
                self.pcmBuffer.removeSubrange(0..<requiredChunkSize)

                var inputABL = AudioBufferList()
                inputABL.mNumberBuffers = 1
                inputABL.mBuffers.mNumberChannels = self.channels
                inputABL.mBuffers.mDataByteSize = UInt32(requiredChunkSize)

                chunkData.withUnsafeMutableBytes { (rawBuf: UnsafeMutableRawBufferPointer) in
                    guard let basePtr = rawBuf.baseAddress else { return }
                    inputABL.mBuffers.mData = basePtr

                    var outAudioBufferList = AudioBufferList()
                    outAudioBufferList.mNumberBuffers = 1
                    outAudioBufferList.mBuffers.mNumberChannels = self.channels
                    outAudioBufferList.mBuffers.mDataByteSize = UInt32(self.aacBufferSize)
                    outAudioBufferList.mBuffers.mData = UnsafeMutableRawPointer(self.aacBuffer)

                    var ioOutputDataPacketSize: UInt32 = 1

                    // Input proc matching 1:1 _wxCastSenderAudioEncoderInInputDataProc @ 0xdf20
                    // Returns -1 when dataByteSize == 0 (ASM @ 0xdf40: mov w0, #-1; ret)
                    let inputProc: AudioConverterComplexInputDataProc = { (
                        _,
                        ioNumberDataPackets,
                        ioData,
                        _,
                        inUserData
                    ) -> OSStatus in
                        guard let inUserData = inUserData else {
                            ioNumberDataPackets.pointee = 0
                            return -1
                        }
                        let abl = inUserData.assumingMemoryBound(to: AudioBufferList.self)
                        let byteSize = abl.pointee.mBuffers.mDataByteSize
                        if byteSize == 0 {
                            ioNumberDataPackets.pointee = 0
                            return -1
                        }

                        ioData.pointee.mBuffers.mData = abl.pointee.mBuffers.mData
                        ioData.pointee.mBuffers.mNumberChannels = abl.pointee.mBuffers.mNumberChannels
                        ioData.pointee.mBuffers.mDataByteSize = byteSize

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
                    }
                }
            }
        }
    }

    // MARK: - Converter Initialization (matching ASM @ 0xe374)

    private func setupAudioConverter(for newFormat: AudioStreamBasicDescription) -> Bool {
        var sourceFormat = newFormat
        self.currentSourceFormat = sourceFormat
        self.sampleRate = sourceFormat.mSampleRate > 0 ? sourceFormat.mSampleRate : 44100.0
        self.channels = sourceFormat.mChannelsPerFrame > 0 ? sourceFormat.mChannelsPerFrame : 2
        self.bytesPerFrame = sourceFormat.mBytesPerFrame > 0 ? sourceFormat.mBytesPerFrame : (2 * self.channels)

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

    public func invalidate() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        pcmBuffer.removeAll()
        lastBufferPts = -1.0
    }

    deinit {
        invalidate()
        aacBuffer.deallocate()
    }
}
