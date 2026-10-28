//
//  AudioEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Hardened CoreAudio AAC-LC Real-time Streaming Encoder for ReplayKit
//

import Foundation
import CoreMedia
import AudioToolbox
import Darwin

private final class AudioInputContext {
    let pcmData: Data
    var pcmOffset: Int = 0
    let channels: UInt32

    init(pcmData: Data, channels: UInt32) {
        self.pcmData = pcmData
        self.channels = channels
    }
}

public final class AudioEncoder {
    public typealias EncodedAudioHandler = (_ packet: Data) -> Void

    private var audioConverter: AudioConverterRef?
    private let audioQueue = DispatchQueue(label: "com.apowermirror.audio.queue", qos: .userInteractive)
    private let packetHandler: EncodedAudioHandler

    private var sampleRate: Double = 48000.0
    private let channels: UInt32 = 2
    private let bytesPerFrame: Int = 4 // 16-bit stereo = 4 bytes per frame

    private var pcmRingBuffer = Data()
    private var lastBufferEndPts: Double = -1.0

    private var aacBuffer: UnsafeMutablePointer<UInt8>
    private let aacBufferSize: Int = 4096
    private var frameCount: Int = 0

    public init(sampleRate: Double = 48000.0, channels: UInt32 = 2, handler: @escaping EncodedAudioHandler) {
        self.sampleRate = sampleRate
        self.packetHandler = handler
        self.aacBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: aacBufferSize)
    }

    deinit {
        aacBuffer.deallocate()
        if let converter = audioConverter {
            AudioConverterDispose(converter)
        }
    }

    public func invalidate() {
        audioQueue.sync {
            if let converter = self.audioConverter {
                AudioConverterDispose(converter)
                self.audioConverter = nil
            }
            self.pcmRingBuffer.removeAll()
            self.frameCount = 0
            self.lastBufferEndPts = -1.0
        }
    }

    /// Feeds raw 16-bit signed integer little-endian interleaved stereo PCM into the AAC encoder
    public func encodePCM(_ pcm16Data: Data) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            if self.audioConverter == nil {
                guard self.setupAudioConverter(sampleRate: self.sampleRate) else { return }
            }
            self.pcmRingBuffer.append(pcm16Data)
            self.processPcmRingBuffer()
        }
    }

    /// Encodes a ReplayKit CMSampleBuffer (.audioApp or .audioMic)
    public func encode(sampleBuffer: CMSampleBuffer) {
        audioQueue.async { [weak self] in
            autoreleasepool {
                guard let self = self else { return }
                let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
                guard numSamples > 0,
                      let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
                    return
                }

                let inFormat = asbdPtr.pointee
                let inSampleRate = (inFormat.mSampleRate >= 8000 && inFormat.mSampleRate <= 96000)
                    ? inFormat.mSampleRate
                    : 48000.0

                // 1. Rebuild converter if sample rate changed (e.g. 48kHz -> 44.1kHz)
                if self.audioConverter == nil || abs(self.sampleRate - inSampleRate) > 1.0 {
                    if let old = self.audioConverter {
                        AudioConverterDispose(old)
                        self.audioConverter = nil
                    }
                    self.pcmRingBuffer.removeAll(keepingCapacity: true)
                    self.frameCount = 0
                    self.lastBufferEndPts = -1.0
                    guard self.setupAudioConverter(sampleRate: inSampleRate) else { return }
                }

                guard let converter = self.audioConverter else { return }

                // 2. Discontinuity Detection
                let bufferDuration = Double(numSamples) / self.sampleRate
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let ptsSeconds = pts.isValid ? pts.seconds : -1.0
                if ptsSeconds > 0 && self.lastBufferEndPts > 0 {
                    let gap = ptsSeconds - self.lastBufferEndPts
                    if gap > 1.0 || gap < -0.1 {
                        self.pcmRingBuffer.removeAll(keepingCapacity: true)
                        self.frameCount = 0
                        AudioConverterReset(converter)
                    }
                }
                if ptsSeconds > 0 {
                    self.lastBufferEndPts = ptsSeconds + bufferDuration
                }

                // 3. Extract AudioBufferList
                let maxBuffers = 4
                let ablPointer = AudioBufferList.allocate(maximumBuffers: maxBuffers)
                defer { free(ablPointer.unsafeMutablePointer) }

                var blockBuffer: CMBlockBuffer? = nil
                let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer,
                    bufferListSizeNeededOut: nil,
                    bufferListOut: ablPointer.unsafeMutablePointer,
                    bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: maxBuffers),
                    blockBufferAllocator: nil,
                    blockBufferMemoryAllocator: nil,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                guard status == noErr else { return }

                // 4. Convert incoming PCM layout into Little-Endian 16-bit Interleaved Stereo
                let flags = inFormat.mFormatFlags
                let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
                let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
                let inChannels = max(1, Int(inFormat.mChannelsPerFrame))
                let rawBits = Int(inFormat.mBitsPerChannel)
                let bitsPerChannel = rawBits > 0
                    ? rawBits
                    : (inChannels > 0 && inFormat.mBytesPerFrame > 0
                        ? Int((inFormat.mBytesPerFrame / UInt32(inChannels)) * 8)
                        : 32)

                var stereoPcm16 = [Int16](repeating: 0, count: numSamples * 2)

                if isFloat && bitsPerChannel == 32 {
                    if isNonInterleaved && ablPointer.count >= 2 {
                        guard let b0 = ablPointer[0].mData, let b1 = ablPointer[1].mData else { return }
                        let f0 = b0.assumingMemoryBound(to: Float.self)
                        let f1 = b1.assumingMemoryBound(to: Float.self)
                        for i in 0..<numSamples {
                            let c0 = f0[i].isFinite ? max(-1.0, min(1.0, f0[i])) : 0.0
                            let c1 = f1[i].isFinite ? max(-1.0, min(1.0, f1[i])) : 0.0
                            stereoPcm16[i * 2]     = Int16(c0 * 32767.0)
                            stereoPcm16[i * 2 + 1] = Int16(c1 * 32767.0)
                        }
                    } else if let b0 = ablPointer[0].mData {
                        let f = b0.assumingMemoryBound(to: Float.self)
                        if inChannels == 1 {
                            for i in 0..<numSamples {
                                let c0 = f[i].isFinite ? max(-1.0, min(1.0, f[i])) : 0.0
                                let s = Int16(c0 * 32767.0)
                                stereoPcm16[i * 2]     = s
                                stereoPcm16[i * 2 + 1] = s
                            }
                        } else {
                            for i in 0..<numSamples {
                                let c0 = f[i * inChannels].isFinite ? max(-1.0, min(1.0, f[i * inChannels])) : 0.0
                                let c1 = f[i * inChannels + 1].isFinite ? max(-1.0, min(1.0, f[i * inChannels + 1])) : 0.0
                                stereoPcm16[i * 2]     = Int16(c0 * 32767.0)
                                stereoPcm16[i * 2 + 1] = Int16(c1 * 32767.0)
                            }
                        }
                    }
                } else if bitsPerChannel == 16 {
                    if isNonInterleaved && ablPointer.count >= 2 {
                        guard let b0 = ablPointer[0].mData, let b1 = ablPointer[1].mData else { return }
                        let p0 = b0.assumingMemoryBound(to: Int16.self)
                        let p1 = b1.assumingMemoryBound(to: Int16.self)
                        for i in 0..<numSamples {
                            stereoPcm16[i * 2]     = p0[i]
                            stereoPcm16[i * 2 + 1] = p1[i]
                        }
                    } else if let b0 = ablPointer[0].mData {
                        let p = b0.assumingMemoryBound(to: Int16.self)
                        if inChannels == 1 {
                            for i in 0..<numSamples {
                                let s = p[i]
                                stereoPcm16[i * 2]     = s
                                stereoPcm16[i * 2 + 1] = s
                            }
                        } else {
                            for i in 0..<numSamples {
                                stereoPcm16[i * 2]     = p[i * inChannels]
                                stereoPcm16[i * 2 + 1] = p[i * inChannels + 1]
                            }
                        }
                    }
                } else {
                    if let b0 = ablPointer[0].mData {
                        let byteCount = min(Int(ablPointer[0].mDataByteSize), stereoPcm16.count * 2)
                        stereoPcm16.withUnsafeMutableBytes { dstBuf in
                            if let baseAddress = dstBuf.baseAddress {
                                memcpy(baseAddress, b0, byteCount)
                            }
                        }
                    }
                }

                stereoPcm16.withUnsafeBytes { rawBytes in
                    self.pcmRingBuffer.append(contentsOf: rawBytes)
                }
                _ = blockBuffer
                self.processPcmRingBuffer()
            }
        }
    }

    private func processPcmRingBuffer() {
        guard let converter = self.audioConverter else { return }

        // Prevent unbounded memory growth (max 1 second @ 48kHz stereo 16-bit = 192,000 bytes)
        if self.pcmRingBuffer.count > 192_000 {
            self.pcmRingBuffer.removeSubrange(0..<(self.pcmRingBuffer.count - 32768))
        }

        // Standard AAC-LC requires 1024 samples per frame (4096 bytes for stereo 16-bit).
        // Maintaining at least 8192 bytes (2048 samples) ensures CoreAudio's MDCT filter has both
        // the 1024-sample current frame and 1024-sample lookahead/overlap window without stalling!
        while self.pcmRingBuffer.count >= 8192 {
            let context = AudioInputContext(pcmData: self.pcmRingBuffer, channels: self.channels)

            var outAbl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: self.channels,
                    mDataByteSize: UInt32(self.aacBufferSize),
                    mData: UnsafeMutableRawPointer(self.aacBuffer)
                )
            )

            var ioOutputDataPackets: UInt32 = 1
            var packetDesc = AudioStreamPacketDescription()

            let inputProc: AudioConverterComplexInputDataProc = { (
                _,
                ioNumberDataPackets,
                ioData,
                outDataPacketDescription,
                inUserData
            ) -> OSStatus in
                guard let inUserData = inUserData else {
                    ioNumberDataPackets.pointee = 0
                    return 100
                }
                let ctx = Unmanaged<AudioInputContext>.fromOpaque(inUserData).takeUnretainedValue()
                let remainingBytes = ctx.pcmData.count - ctx.pcmOffset
                let availablePackets = UInt32(remainingBytes / 4)

                if availablePackets == 0 {
                    ioNumberDataPackets.pointee = 0
                    return 100
                }

                let requestedPackets = ioNumberDataPackets.pointee
                let toGive = min(requestedPackets, availablePackets)
                let bytesToGive = Int(toGive * 4)

                ctx.pcmData.withUnsafeBytes { rawBuf in
                    if let basePtr = rawBuf.baseAddress {
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = ctx.channels
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(bytesToGive)
                        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
                            mutating: basePtr.advanced(by: ctx.pcmOffset)
                        )
                    }
                }

                ctx.pcmOffset += bytesToGive
                ioNumberDataPackets.pointee = toGive

                if let outDesc = outDataPacketDescription {
                    outDesc.pointee = nil
                }
                return noErr
            }

            let convStatus = AudioConverterFillComplexBuffer(
                converter,
                inputProc,
                Unmanaged.passUnretained(context).toOpaque(),
                &ioOutputDataPackets,
                &outAbl,
                &packetDesc
            )

            let aacSize = Int(packetDesc.mDataByteSize > 0 ? packetDesc.mDataByteSize : outAbl.mBuffers.mDataByteSize)

            if (convStatus == noErr || convStatus == 100) && ioOutputDataPackets > 0 && aacSize > 0 {
                // Advance exactly 1024 audio frames (4096 bytes) for this encoded AAC frame
                let pcmBytesConsumed = 1024 * self.bytesPerFrame
                if self.pcmRingBuffer.count >= pcmBytesConsumed {
                    self.pcmRingBuffer.removeSubrange(0..<pcmBytesConsumed)
                } else {
                    self.pcmRingBuffer.removeAll(keepingCapacity: true)
                }

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
                break
            }
        }
    }

    private func setupAudioConverter(sampleRate: Double) -> Bool {
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
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var status = AudioConverterNew(&sourceFormat, &destinationFormat, &audioConverter)
        if status != noErr {
            var softDesc = AudioClassDescription(
                mType: kAudioEncoderComponentType,
                mSubType: kAudioFormatMPEG4AAC,
                mManufacturer: kAppleSoftwareAudioCodecManufacturer
            )
            status = AudioConverterNewSpecific(&sourceFormat, &destinationFormat, 1, &softDesc, &audioConverter)
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

        NSLog("[AudioEncoder] Initialized AAC-LC encoder: %.0f Hz, 2 channels", sampleRate)
        return true
    }

    private func createAdtsHeader(packetLength: Int) -> Data {
        let totalLength = packetLength + 7
        var header = [UInt8](repeating: 0, count: 7)
        let profile: UInt8 = 2 // AAC-LC
        let freqIdx = getSampleRateIndex(sampleRate: sampleRate)
        let chanCfg: UInt8 = 2

        header[0] = 0xFF
        header[1] = 0xF1
        header[2] = ((profile - 1) << 6) | (freqIdx << 2) | ((chanCfg >> 2) & 0x01)
        header[3] = ((chanCfg & 0x03) << 6) | UInt8((totalLength >> 11) & 0x03)
        header[4] = UInt8((totalLength >> 3) & 0xFF)
        header[5] = UInt8((totalLength & 0x07) << 5) | 0x1F
        header[6] = 0xFC

        return Data(header)
    }

    private func getSampleRateIndex(sampleRate: Double) -> UInt8 {
        switch Int(sampleRate) {
        case 96000: return 0
        case 88200: return 1
        case 64000: return 2
        case 48000: return 3
        case 44100: return 4
        case 32000: return 5
        case 24000: return 6
        case 22050: return 7
        case 16000: return 8
        case 12000: return 9
        case 11025: return 10
        case 8000:  return 11
        case 7350:  return 12
        default:    return 3 // fallback 48.0 kHz
        }
    }
}
