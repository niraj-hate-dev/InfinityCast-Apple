//
//  AudioEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Reconstructed 1:1 from ApowerMirror WXCastiOSSender:
//  - -[WXCastSenderAudioEncoder encodeAACSampleBuffer:completionBlock:]
//  - -[WXCastSenderAudioEncoder adtsDataForPacketLength:]
//  - -[WXCastSenderServer sendAACData:]
//

import Foundation
import CoreMedia
import AudioToolbox

public final class AudioEncoder {

    // MARK: - Types
    public typealias EncodedAudioHandler = (_ packet: Data) -> Void

    // MARK: - Configuration & State
    private var audioConverter: AudioConverterRef?
    private var pcmBuffer = Data()
    private let audioQueue = DispatchQueue(label: "com.apowermirror.audio.queue", qos: .userInteractive)
    private let packetHandler: EncodedAudioHandler

    private var sampleRate: Double = 44100.0
    private var channels: UInt32 = 2
    private var aacPacketMaxSize: UInt32 = 1024

    // MARK: - Initialization

    public init(sampleRate: Double = 44100.0, channels: UInt32 = 2, handler: @escaping EncodedAudioHandler) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.packetHandler = handler
    }

    // MARK: - Ingestion

    public func encode(sampleBuffer: CMSampleBuffer) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }

            if self.audioConverter == nil {
                guard self.setupAudioConverter(for: sampleBuffer) else { return }
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?

            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )

            guard status == noErr, let ptr = dataPointer, totalLength > 0 else { return }

            self.pcmBuffer.append(Data(bytes: ptr, count: totalLength))
            self.convertPcmToAac()
        }
    }

    // MARK: - Converter Initialization

    private func setupAudioConverter(for sampleBuffer: CMSampleBuffer) -> Bool {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return false
        }

        var sourceFormat = asbd.pointee
        self.sampleRate = sourceFormat.mSampleRate
        self.channels = sourceFormat.mChannelsPerFrame

        var destinationFormat = AudioStreamBasicDescription(
            mSampleRate: sourceFormat.mSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: sourceFormat.mChannelsPerFrame,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var description = AudioClassDescription(
            mType: kAudioEncoderComponentType,
            mSubType: kAudioFormatMPEG4AAC,
            mManufacturer: kAppleHardwareAudioCodecManufacturer
        )

        var status = AudioConverterNewSpecific(
            &sourceFormat,
            &destinationFormat,
            1,
            &description,
            &audioConverter
        )

        if status != noErr {
            // Fallback to software encoder if hardware is busy
            description.mManufacturer = kAppleSoftwareAudioCodecManufacturer
            status = AudioConverterNewSpecific(
                &sourceFormat,
                &destinationFormat,
                1,
                &description,
                &audioConverter
            )
        }

        guard status == noErr, let converter = audioConverter else {
            NSLog("[AudioEncoder] AudioConverterNewSpecific failed: %d", status)
            return false
        }

        // Set AAC bitrate to 64 Kbps per channel (128 Kbps stereo)
        var bitrate: UInt32 = 128_000
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )

        return true
    }

    // MARK: - Conversion Loop

    private struct ConverterUserData {
        var pcmData: Data
        var channels: UInt32
    }

    private func convertPcmToAac() {
        guard let converter = audioConverter else { return }

        let bytesPerInputFrame = channels * 2 // 16-bit PCM = 2 bytes per sample
        let bytesNeededPerAacPacket = 1024 * bytesPerInputFrame

        while pcmBuffer.count >= Int(bytesNeededPerAacPacket) {
            let chunk = pcmBuffer.prefix(Int(bytesNeededPerAacPacket))
            pcmBuffer.removeFirst(Int(bytesNeededPerAacPacket))

            var userData = ConverterUserData(pcmData: chunk, channels: channels)

            var ioOutputDataPacketSize: UInt32 = 1
            var outAudioBufferList = AudioBufferList()
            outAudioBufferList.mNumberBuffers = 1

            let outBufferSize = 2048
            let outBuffer = UnsafeMutableRawPointer.allocate(byteCount: outBufferSize, alignment: 16)
            defer { outBuffer.deallocate() }

            outAudioBufferList.mBuffers.mNumberChannels = channels
            outAudioBufferList.mBuffers.mDataByteSize = UInt32(outBufferSize)
            outAudioBufferList.mBuffers.mData = outBuffer

            let callback: AudioConverterComplexInputDataProc = { (
                _,
                ioNumberDataPackets,
                ioData,
                _,
                inUserData
            ) -> OSStatus in
                guard let userDataPtr = inUserData?.assumingMemoryBound(to: ConverterUserData.self) else {
                    ioNumberDataPackets.pointee = 0
                    return -1
                }

                let byteCount = userDataPtr.pointee.pcmData.count
                if byteCount == 0 {
                    ioNumberDataPackets.pointee = 0
                    return noErr
                }

                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mNumberChannels = userDataPtr.pointee.channels
                ioData.pointee.mBuffers.mDataByteSize = UInt32(byteCount)

                // Hand pointer to buffer
                let rawPtr = UnsafeMutableRawPointer(mutating: (userDataPtr.pointee.pcmData as NSData).bytes)
                ioData.pointee.mBuffers.mData = rawPtr

                ioNumberDataPackets.pointee = UInt32(byteCount / Int(userDataPtr.pointee.channels * 2))
                return noErr
            }

            let status = AudioConverterFillComplexBuffer(
                converter,
                callback,
                &userData,
                &ioOutputDataPacketSize,
                &outAudioBufferList,
                nil
            )

            if status == noErr && ioOutputDataPacketSize > 0 {
                let aacSize = Int(outAudioBufferList.mBuffers.mDataByteSize)
                if aacSize > 0, let dataPtr = outAudioBufferList.mBuffers.mData {
                    let rawAac = Data(bytes: dataPtr, count: aacSize)

                    // 1. Generate 7-byte ADTS Header (ASM @ 0xe56c)
                    let adtsHeader = createAdtsHeader(packetLength: aacSize)

                    // 2. Wrap in ApowerMirror 4-byte Audio Tag: [00 00 00 02] (ASM @ 0x10680)
                    var packet = Data([0x00, 0x00, 0x00, 0x02])
                    packet.append(adtsHeader)
                    packet.append(rawAac)

                    // Dispatch packet to /mirrorVoice.do
                    packetHandler(packet)
                }
            }
        }
    }

    // MARK: - ADTS Framing (Decompiled directly from -[WXCastSenderAudioEncoder adtsDataForPacketLength:] @ 0xe56c)

    private func createAdtsHeader(packetLength: Int) -> Data {
        let totalLength = packetLength + 7 // Header length = 7 bytes
        var header = [UInt8](repeating: 0, count: 7)

        let profile: UInt8 = 2 // AAC LC (Low Complexity)
        let sampleRateIndex = getSampleRateIndex(sampleRate: sampleRate)
        let channelConfig = UInt8(channels)

        // Syncword: 0xFFF (all 1s)
        header[0] = 0xFF
        header[1] = 0xF1 // MPEG-4, Layer 0, No CRC

        // Profile (2 bits) + Frequency Index (4 bits) + Private (1 bit) + Channel (1 bit)
        header[2] = ((profile - 1) << 6) | (sampleRateIndex << 2) | ((channelConfig >> 2) & 0x01)

        // Channel (2 bits) + Copy (1 bit) + Home (1 bit) + Frame Length MSB (2 bits)
        header[3] = ((channelConfig & 0x03) << 6) | UInt8((totalLength >> 11) & 0x03)

        // Frame Length middle (8 bits)
        header[4] = UInt8((totalLength >> 3) & 0xFF)

        // Frame Length LSB (3 bits) + Buffer Fullness MSB (5 bits, 0x7FF = VBR)
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
        default:    return 0x4 // Default to 44.1kHz
        }
    }

    public func invalidate() {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
            audioConverter = nil
        }
        pcmBuffer.removeAll()
    }

    deinit {
        invalidate()
    }
}
