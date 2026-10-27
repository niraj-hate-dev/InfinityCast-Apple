//
//  AudioEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Hardened CoreAudio AAC-LC Encoder for ReplayKit (.audioApp):
//  - Handles Big-Endian & Little-Endian 16-bit/32-bit Int and 32-bit Float PCM
//  - Handles Interleaved (1 buffer) and Non-Interleaved (2 buffers) AudioBufferLists
//  - Persistent 1024-frame FIFO ring buffer for exact AAC-LC packet sizing
//  - Dynamic sample-rate re-initialization (44.1kHz / 48kHz)
//

import Foundation
import CoreMedia
import AudioToolbox
import Darwin

private struct AudioEncoderInputState {
    var basePtr: UnsafePointer<UInt8>
    var totalBytes: Int
    var offset: Int
}

public final class AudioEncoder {

    public typealias EncodedAudioHandler = (_ packet: Data) -> Void

    private var audioConverter: AudioConverterRef?
    private let audioQueue = DispatchQueue(label: "com.apowermirror.audio.queue", qos: .userInteractive)
    private let packetHandler: EncodedAudioHandler

    private var sampleRate: Double = 44100.0
    private let channels: UInt32 = 2
    private let bytesPerFrame: Int = 4 // 16-bit stereo = 4 bytes per frame

    // Persistent FIFO ring buffer holding normalized Little-Endian 16-bit Stereo PCM
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

    public func encode(sampleBuffer: CMSampleBuffer) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0,
                  let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
                return
            }

            let inFormat = asbdPtr.pointee
            let inSampleRate = inFormat.mSampleRate > 0 ? inFormat.mSampleRate : 44100.0

            // 1. Rebuild AAC converter if not initialized or if sample rate changed (e.g., 44.1kHz <-> 48kHz)
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

            // 2. Discontinuity Detection: only reset if user paused audio for > 1.5 seconds
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid && pts.seconds > 0 {
                let startSec = pts.seconds
                let durationSec = Double(numSamples) / inSampleRate
                if self.lastBufferEndPts > 0 {
                    let gap = startSec - self.lastBufferEndPts
                    if gap > 1.5 || gap < -1.5 {
                        self.pcmRingBuffer.removeAll(keepingCapacity: true)
                        AudioConverterReset(converter)
                        NSLog("[AudioEncoder] Pause/Resume gap (%.2fs) -> Reset AAC converter", gap)
                    }
                }
                self.lastBufferEndPts = startSec + durationSec
            }

            // 3. Dynamically allocate AudioBufferList with capacity for non-interleaved stereo (4 buffers)
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
                NSLog("[AudioEncoder] CMSampleBufferGetAudioBufferList failed: %d", status)
                return
            }

            // 4. Normalize any ReplayKit PCM format (Big-Endian/Little-Endian, Float/Int, Planar/Interleaved)
            //    into standard Little-Endian 16-bit Interleaved Stereo PCM (4 bytes/frame)
            let abl = ablPointer
            let flags = inFormat.mFormatFlags
            let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
            let isBigEndian = (flags & kAudioFormatFlagIsBigEndian) != 0
            let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
            let inChannels = max(1, Int(inFormat.mChannelsPerFrame))
            let bitsPerChannel = Int(inFormat.mBitsPerChannel)

            var stereoPcm16 = [Int16](repeating: 0, count: numSamples * 2)

            if isFloat && bitsPerChannel == 32 {
                if isNonInterleaved && abl.count >= 2 {
                    guard let b0 = abl[0].mData, let b1 = abl[1].mData else { return }
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
                } else if let b0 = abl[0].mData {
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
                // 16-bit Signed Integer PCM (ReplayKit often sets kAudioFormatFlagIsBigEndian here!)
                if isNonInterleaved && abl.count >= 2 {
                    guard let b0 = abl[0].mData, let b1 = abl[1].mData else { return }
                    let p0 = b0.assumingMemoryBound(to: Int16.self)
                    let p1 = b1.assumingMemoryBound(to: Int16.self)
                    for i in 0..<numSamples {
                        stereoPcm16[i * 2]     = isBigEndian ? Int16(bigEndian: p0[i]) : p0[i]
                        stereoPcm16[i * 2 + 1] = isBigEndian ? Int16(bigEndian: p1[i]) : p1[i]
                    }
                } else if let b0 = abl[0].mData {
                    let p0 = b0.assumingMemoryBound(to: Int16.self)
                    if inChannels == 1 {
                        for i in 0..<numSamples {
                            let s = isBigEndian ? Int16(bigEndian: p0[i]) : p0[i]
                            stereoPcm16[i * 2]     = s
                            stereoPcm16[i * 2 + 1] = s
                        }
                    } else {
                        for i in 0..<numSamples {
                            let s0 = p0[i * inChannels]
                            let s1 = p0[i * inChannels + 1]
                            stereoPcm16[i * 2]     = isBigEndian ? Int16(bigEndian: s0) : s0
                            stereoPcm16[i * 2 + 1] = isBigEndian ? Int16(bigEndian: s1) : s1
                        }
                    }
                }
            } else if bitsPerChannel == 32 && !isFloat {
                // 32-bit Signed Integer PCM
                if isNonInterleaved && abl.count >= 2 {
                    guard let b0 = abl[0].mData, let b1 = abl[1].mData else { return }
                    let p0 = b0.assumingMemoryBound(to: Int32.self)
                    let p1 = b1.assumingMemoryBound(to: Int32.self)
                    for i in 0..<numSamples {
                        let s0 = isBigEndian ? Int32(bigEndian: p0[i]) : p0[i]
                        let s1 = isBigEndian ? Int32(bigEndian: p1[i]) : p1[i]
                        stereoPcm16[i * 2]     = Int16(s0 >> 16)
                        stereoPcm16[i * 2 + 1] = Int16(s1 >> 16)
                    }
                } else if let b0 = abl[0].mData {
                    let p0 = b0.assumingMemoryBound(to: Int32.self)
                    for i in 0..<numSamples {
                        let s0 = isBigEndian ? Int32(bigEndian: p0[i * inChannels]) : p0[i * inChannels]
                        let s1 = inChannels > 1 ? (isBigEndian ? Int32(bigEndian: p0[i * inChannels + 1]) : p0[i * inChannels + 1]) : s0
                        stereoPcm16[i * 2]     = Int16(s0 >> 16)
                        stereoPcm16[i * 2 + 1] = Int16(s1 >> 16)
                    }
                }
            }

            stereoPcm16.withUnsafeBytes { rawBytes in
                self.pcmRingBuffer.append(contentsOf: rawBytes)
            }

            _ = blockBuffer

            // Cap ring buffer to prevent memory buildup if encoding is delayed
            if self.pcmRingBuffer.count > 176_400 { // > 1 second of 44.1kHz 16-bit stereo PCM
                self.pcmRingBuffer.removeSubrange(0..<(self.pcmRingBuffer.count - 4096 * 4))
            }

            // 5. Feed into AudioConverterFillComplexBuffer dynamically from the ring buffer
            let kMinInputBytes = 1024 * self.bytesPerFrame // 4096 bytes

            while self.pcmRingBuffer.count >= kMinInputBytes {
                var outAbl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(self.aacBufferSize),
                        mData: UnsafeMutableRawPointer(self.aacBuffer)
                    )
                )

                var ioOutputDataPackets: UInt32 = 1

                let inputProc: AudioConverterComplexInputDataProc = { (
                    _,
                    ioNumberDataPackets,
                    ioData,
                    _,
                    inUserData
                ) -> OSStatus in
                    guard let inUserData = inUserData else {
                        ioNumberDataPackets.pointee = 0
                        ioData.pointee.mBuffers.mDataByteSize = 0
                        ioData.pointee.mBuffers.mData = nil
                        return noErr
                    }
                    let state = inUserData.assumingMemoryBound(to: AudioEncoderInputState.self)
                    let remainingBytes = state.pointee.totalBytes - state.pointee.offset
                    if remainingBytes < 4 {
                        ioNumberDataPackets.pointee = 0
                        ioData.pointee.mBuffers.mDataByteSize = 0
                        ioData.pointee.mBuffers.mData = nil
                        return 500 // Controlled EOF signal to stop AudioConverter without infinite loop
                    }

                    let availablePackets = UInt32(remainingBytes / 4)
                    let requestedPackets = ioNumberDataPackets.pointee
                    let toGive = min(requestedPackets, availablePackets)
                    let bytesToGive = toGive * 4

                    ioData.pointee.mBuffers.mNumberChannels = 2
                    ioData.pointee.mBuffers.mDataByteSize = bytesToGive
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: state.pointee.basePtr.advanced(by: state.pointee.offset))
                    ioNumberDataPackets.pointee = toGive
                    state.pointee.offset += Int(bytesToGive)
                    return noErr
                }

                var finalOffset = 0
                let convStatus = self.pcmRingBuffer.withUnsafeBytes { rawBytes -> OSStatus in
                    guard let basePtr = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
                    var state = AudioEncoderInputState(basePtr: basePtr, totalBytes: self.pcmRingBuffer.count, offset: 0)
                    let st = AudioConverterFillComplexBuffer(
                        converter,
                        inputProc,
                        &state,
                        &ioOutputDataPackets,
                        &outAbl,
                        nil
                    )
                    finalOffset = state.offset
                    return st
                }

                if finalOffset > 0 {
                    let removeCount = min(finalOffset, self.pcmRingBuffer.count)
                    self.pcmRingBuffer.removeSubrange(0..<removeCount)
                }

                if finalOffset == 0 && ioOutputDataPackets == 0 {
                    break
                }

                let aacSize = Int(outAbl.mBuffers.mDataByteSize)
                if ioOutputDataPackets > 0 && aacSize > 0 {
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
                    if convStatus != noErr && convStatus != 500 && convStatus != -1 {
                        NSLog("[AudioEncoder] AudioConverterFillComplexBuffer note: status=%d", convStatus)
                    }
                    // Not enough samples to output a packet yet (e.g. priming); wait for next buffer
                    break
                }
            }
        }
    }

    private func setupAudioConverter(sampleRate: Double) -> Bool {
        self.sampleRate = sampleRate

        // Input is always our normalized Little-Endian 16-bit packed stereo PCM
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
            mFormatFlags: 0, // CRITICAL: Must be 0 for standard AAC-LC in AudioConverterNew!
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
            NSLog("[AudioEncoder] AudioConverterNew failed with status: %d", status)
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
        header[1] = 0xF9
        header[2] = ((profile - 1) << 6) | (freqIdx << 2) | ((chanCfg >> 2) & 0x01)
        header[3] = ((chanCfg & 0x03) << 6) | UInt8((totalLength >> 11) & 0x03)
        header[4] = UInt8((totalLength >> 3) & 0xFF)
        header[5] = UInt8((totalLength & 0x07) << 5) | 0x1F
        header[6] = 0xFC

        return Data(header)
    }

    private func getSampleRateIndex(sampleRate: Double) -> UInt8 {
        switch Int(sampleRate.rounded()) {
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
        pcmRingBuffer.removeAll()
        lastBufferEndPts = -1.0
    }

    deinit {
        invalidate()
        aacBuffer.deallocate()
    }
}
