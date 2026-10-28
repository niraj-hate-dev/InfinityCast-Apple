//
//  AudioEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Hardened CoreAudio AAC-LC Real-time Streaming Encoder for ReplayKit
//  - Handles Interleaved & Non-Interleaved 32-bit Float PCM (iOS ReplayKit Native Format)
//  - Converts to Linear 16-bit Signed Integer PCM
//  - Dynamic CoreAudio AudioConverter with Lookahead & Priming Preservation
//  - Multi-chunk pcmRingBuffer with custom non-EOF status to prevent buffer discarding
//  - Formats with standard MPEG-4 7-byte ADTS header for real-time streaming
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

    private var sampleRate: Double = 44100.0
    private let channels: UInt32 = 2
    private let bytesPerFrame: Int = 4 // 16-bit stereo = 4 bytes per frame

    private var pcmRingBuffer = Data()
    private var lastBufferEndPts: Double = -1.0

    private var aacBuffer: UnsafeMutablePointer<UInt8>
    private let aacBufferSize: Int = 4096
    private var frameCount: Int = 0

    public init(sampleRate: Double = 44100.0, channels: UInt32 = 2, handler: @escaping EncodedAudioHandler) {
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
                let inSampleRate = (inFormat.mSampleRate >= 8000 && inFormat.mSampleRate <= 96000) ? inFormat.mSampleRate : 44100.0

                // 1. Initialize or rebuild converter if sample rate changed
                if self.audioConverter == nil || abs(self.sampleRate - inSampleRate) > 1.0 {
                    if let old = self.audioConverter {
                        AudioConverterDispose(old)
                        self.audioConverter = nil
                    }
                    self.pcmRingBuffer.removeAll(keepingCapacity: true)
                    self.lastBufferEndPts = -1.0
                    guard self.setupAudioConverter(sampleRate: inSampleRate) else { return }
                }

                guard let converter = self.audioConverter else { return }

                // 2. Discontinuity Detection (gap > 1.0s or backward jump)
                let bufferDuration = Double(numSamples) / self.sampleRate
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let ptsSeconds = pts.isValid ? pts.seconds : -1.0
                if ptsSeconds > 0 && self.lastBufferEndPts > 0 {
                    let gap = ptsSeconds - self.lastBufferEndPts
                    if gap > 1.0 || gap < -0.1 {
                        self.pcmRingBuffer.removeAll(keepingCapacity: true)
                        AudioConverterReset(converter)
                    }
                }
                if ptsSeconds > 0 {
                    self.lastBufferEndPts = ptsSeconds + bufferDuration
                }

                // 3. Extract AudioBufferList safely
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

                guard status == noErr else {
                    return
                }

                // 4. Convert incoming ReplayKit PCM layout into Little-Endian 16-bit Interleaved Stereo
                let flags = inFormat.mFormatFlags
                let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
                let isBigEndian = (flags & kAudioFormatFlagIsBigEndian) != 0
                let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
                let inChannels = max(1, Int(inFormat.mChannelsPerFrame))
                let rawBits = Int(inFormat.mBitsPerChannel)
                let bitsPerChannel = rawBits > 0 ? rawBits : (inChannels > 0 && inFormat.mBytesPerFrame > 0 ? Int((inFormat.mBytesPerFrame / UInt32(inChannels)) * 8) : 32)

                var stereoPcm16 = [Int16](repeating: 0, count: numSamples * 2)

                if isFloat && bitsPerChannel == 32 {
                    if isNonInterleaved && ablPointer.count >= 2 {
                        guard let b0 = ablPointer[0].mData, let b1 = ablPointer[1].mData else { return }
                        let p0 = b0.assumingMemoryBound(to: UInt32.self)
                        let p1 = b1.assumingMemoryBound(to: UInt32.self)
                        for i in 0..<numSamples {
                            let u0 = isBigEndian ? UInt32(bigEndian: p0[i]) : p0[i]
                            let u1 = isBigEndian ? UInt32(bigEndian: p1[i]) : p1[i]
                            let f0 = Float(bitPattern: u0)
                            let f1 = Float(bitPattern: u1)
                            let c0 = f0.isFinite ? max(-1.0, min(1.0, f0)) : 0.0
                            let c1 = f1.isFinite ? max(-1.0, min(1.0, f1)) : 0.0
                            stereoPcm16[i * 2]     = Int16(c0 * 32767.0)
                            stereoPcm16[i * 2 + 1] = Int16(c1 * 32767.0)
                        }
                    } else if let b0 = ablPointer[0].mData {
                        let p0 = b0.assumingMemoryBound(to: UInt32.self)
                        if inChannels == 1 {
                            for i in 0..<numSamples {
                                let u0 = isBigEndian ? UInt32(bigEndian: p0[i]) : p0[i]
                                let f0 = Float(bitPattern: u0)
                                let c0 = f0.isFinite ? max(-1.0, min(1.0, f0)) : 0.0
                                let s = Int16(c0 * 32767.0)
                                stereoPcm16[i * 2]     = s
                                stereoPcm16[i * 2 + 1] = s
                            }
                        } else {
                            for i in 0..<numSamples {
                                let u0 = isBigEndian ? UInt32(bigEndian: p0[i * inChannels]) : p0[i * inChannels]
                                let u1 = isBigEndian ? UInt32(bigEndian: p0[i * inChannels + 1]) : p0[i * inChannels + 1]
                                let f0 = Float(bitPattern: u0)
                                let f1 = Float(bitPattern: u1)
                                let c0 = f0.isFinite ? max(-1.0, min(1.0, f0)) : 0.0
                                let c1 = f1.isFinite ? max(-1.0, min(1.0, f1)) : 0.0
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
                            let s0 = isBigEndian ? Int16(bigEndian: p0[i]) : p0[i]
                            let s1 = isBigEndian ? Int16(bigEndian: p1[i]) : p1[i]
                            stereoPcm16[i * 2]     = s0
                            stereoPcm16[i * 2 + 1] = s1
                        }
                    } else if let b0 = ablPointer[0].mData {
                        let p0 = b0.assumingMemoryBound(to: Int16.self)
                        if inChannels == 1 {
                            for i in 0..<numSamples {
                                let s = isBigEndian ? Int16(bigEndian: p0[i]) : p0[i]
                                stereoPcm16[i * 2]     = s
                                stereoPcm16[i * 2 + 1] = s
                            }
                        } else {
                            for i in 0..<numSamples {
                                let s0 = isBigEndian ? Int16(bigEndian: p0[i * inChannels]) : p0[i * inChannels]
                                let s1 = isBigEndian ? Int16(bigEndian: p0[i * inChannels + 1]) : p0[i * inChannels + 1]
                                stereoPcm16[i * 2]     = s0
                                stereoPcm16[i * 2 + 1] = s1
                            }
                        }
                    }
                } else {
                    if let b0 = ablPointer[0].mData {
                        let byteCount = min(Int(ablPointer[0].mDataByteSize), stereoPcm16.count * 2)
                        stereoPcm16.withUnsafeMutableBytes { dstBuf in
                            memcpy(dstBuf.baseAddress, b0, byteCount)
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

        // Prevent unbounded memory growth (keep max 1 sec of audio buffer = 176,400 bytes)
        if self.pcmRingBuffer.count > 176_400 {
            self.pcmRingBuffer.removeSubrange(0..<(self.pcmRingBuffer.count - 32768))
        }

        // For initial AAC-LC encoder priming (delay of 2112 samples),
        // wait until we have at least 8192 bytes (2048 stereo 16-bit frames).
        if self.frameCount == 0 && self.pcmRingBuffer.count < 8192 {
            return
        }

        // AAC-LC frame requires 1024 frames = 4096 bytes
        while self.pcmRingBuffer.count >= 4096 {
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
                    return 100 // Custom status: out of input data for now, NOT EOF!
                }

                let requestedPackets = ioNumberDataPackets.pointee
                let toGive = min(requestedPackets, availablePackets)
                let bytesToGive = Int(toGive * 4)

                ctx.pcmData.withUnsafeBytes { rawBuf in
                    if let basePtr = rawBuf.baseAddress {
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mNumberChannels = ctx.channels
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(bytesToGive)
                        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: basePtr.advanced(by: ctx.pcmOffset))
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

            // Consume exactly the bytes CoreAudio read from pcmRingBuffer
            if context.pcmOffset > 0 {
                let toRemove = min(context.pcmOffset, self.pcmRingBuffer.count)
                self.pcmRingBuffer.removeSubrange(0..<toRemove)
            }

            let aacSize = Int(packetDesc.mDataByteSize > 0 ? packetDesc.mDataByteSize : outAbl.mBuffers.mDataByteSize)
            if (convStatus == noErr || convStatus == 100) && ioOutputDataPackets > 0 && aacSize > 0 {
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
                // Not enough input remaining to complete another packet; wait for next buffer
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
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), // MUST ALWAYS BE 2 (AAC-LC)!
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

        let profile: UInt8 = 2 // AAC-LC (MPEG-4 profile is 2, in ADTS header profile-1 = 1)
        let freqIdx = getSampleRateIndex(sampleRate: sampleRate)
        let chanCfg: UInt8 = 2

        // Syncword: 0xFFF + MPEG-4 (ID=0), Layer 0, No CRC (0xFFF1)
        header[0] = 0xFF
        header[1] = 0xF1

        // Profile (2 bits) + Frequency Index (4 bits) + Private (1 bit) + Channel (1 bit)
        header[2] = ((profile - 1) << 6) | (freqIdx << 2) | ((chanCfg >> 2) & 0x01)

        // Channel (2 bits) + Copy (1 bit) + Home (1 bit) + Frame Length MSB (2 bits)
        header[3] = ((chanCfg & 0x03) << 6) | UInt8((totalLength >> 11) & 0x03)

        // Frame Length middle (8 bits)
        header[4] = UInt8((totalLength >> 3) & 0xFF)

        // Frame Length LSB (3 bits) + Buffer Fullness MSB (5 bits)
        header[5] = UInt8((totalLength & 0x07) << 5) | 0x1F

        // Buffer Fullness LSB (6 bits) + Number of AAC frames (2 bits)
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
        default:    return 4 // fallback 44.1 kHz
        }
    }
}
