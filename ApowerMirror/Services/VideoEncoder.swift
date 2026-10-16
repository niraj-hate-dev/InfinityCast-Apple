//
//  VideoEncoder.swift
//  ApowerMirror / Services
//
//  Hardware accelerated H.264 VideoToolbox encoder for ReplayKit screen capture.
//  Encodes CVPixelBuffer into Annex-B H.264 NALUs with ApowerMirror framing tags
//  ([00 00 00 00] and [00 00 00 02]) compatible with desktop receivers.
//

import Foundation
import VideoToolbox
import CoreMedia
import ImageIO

public final class VideoEncoder {

    // MARK: - Types & Callbacks
    public typealias EncodedPacketHandler = (_ packet: Data, _ isKeyFrame: Bool, _ isEndFrame: Bool) -> Void
    public typealias DimensionChangeHandler = (_ width: Int32, _ height: Int32, _ rotation: Int32) -> Void

    // MARK: - Configuration
    private var bitrate: Int32
    private var fps: Int32
    private var maxDimension: Int32 = 1920
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var currentOrientation: CGImagePropertyOrientation = .up

    // MARK: - State
    private var compressionSession: VTCompressionSession?
    private let packetHandler: EncodedPacketHandler
    private var dimensionHandler: DimensionChangeHandler?
    private let encoderQueue = DispatchQueue(label: "com.apowermirror.encoder.queue", qos: .userInteractive)
    private var spsHeader: Data?
    private var ppsHeader: Data?
    private let annexBStartCode = Data([0x00, 0x00, 0x00, 0x01])
    private var forceNextKeyframe = false

    // Maximum sub-packet size before slicing (10 KB / 0x2800 from ApowerMirror decompiled ASM)
    private let kMaxSliceChunkSize = 10240

    // MARK: - Initialization

    public init(bitrate: Int32 = 4_000_000, fps: Int32 = 60, packetHandler: @escaping EncodedPacketHandler) {
        self.bitrate = bitrate
        self.fps = fps
        self.packetHandler = packetHandler
    }

    public func setDimensionChangeHandler(_ handler: @escaping DimensionChangeHandler) {
        self.dimensionHandler = handler
    }

    public func forceKeyFrame() {
        encoderQueue.async { [weak self] in
            self?.forceNextKeyframe = true
        }
    }

    // MARK: - Frame Ingestion & Session Management

    public func encode(sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        encoderQueue.async { [weak self] in
            autoreleasepool {
                guard let self = self else { return }

                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

                let rawWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
                let rawHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))

                // Re-create compression session if orientation or dimensions changed
                if self.compressionSession == nil || orientation != self.currentOrientation {
                    self.currentOrientation = orientation
                    self.rebuildCompressionSession(sourceWidth: rawWidth, sourceHeight: rawHeight, orientation: orientation)
                }

                guard let session = self.compressionSession else { return }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let duration = CMSampleBufferGetDuration(sampleBuffer)

                var frameProperties: CFDictionary? = nil
                if self.forceNextKeyframe {
                    self.forceNextKeyframe = false
                    frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: kCFBooleanTrue] as CFDictionary
                    NSLog("[VideoEncoder] Forcing IDR keyframe insertion on next frame")
                }

                var flags: VTEncodeInfoFlags = []
                let status = VTCompressionSessionEncodeFrame(
                    session,
                    imageBuffer: pixelBuffer,
                    presentationTimeStamp: pts,
                    duration: duration,
                    frameProperties: frameProperties,
                    sourceFrameRefcon: nil,
                    infoFlagsOut: &flags
                )

                if status != noErr {
                    NSLog("[VideoEncoder] VTCompressionSessionEncodeFrame failed with status: %d", status)
                }
            }
        }
    }

    // MARK: - Session Creation & Jetsam 50MB Protection

    private func rebuildCompressionSession(sourceWidth: Int32, sourceHeight: Int32, orientation: CGImagePropertyOrientation) {
        invalidate()

        // 1. Swap width/height if orientation is landscape (matches ASM @ 0x12d68 - 0x12dc0)
        var targetW = sourceWidth
        var targetH = sourceHeight

        let isLandscape = (orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored)
        if isLandscape && targetW < targetH {
            swap(&targetW, &targetH)
        } else if !isLandscape && targetW > targetH {
            swap(&targetW, &targetH)
        }

        // 2. Downscale Retina resolution to clamp within 50MB Jetsam limit
        if targetW > maxDimension || targetH > maxDimension {
            if targetW >= targetH {
                targetH = Int32((Float(targetH) / Float(targetW)) * Float(maxDimension))
                targetW = maxDimension
            } else {
                targetW = Int32((Float(targetW) / Float(targetH)) * Float(maxDimension))
                targetH = maxDimension
            }
        }

        // 3. Macroblock 16-pixel alignment: (w + 15) & ~15 (decompiled ASM @ 0x13d14 - 0x13d30)
        currentWidth = (targetW + 15) & ~15
        currentHeight = (targetH + 15) & ~15

        NSLog("[VideoEncoder] Initializing VTCompressionSession: %dx%d (Orientation: %d)", currentWidth, currentHeight, orientation.rawValue)

        // 4. Create VideoToolbox Compression Session
        var newSession: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, infoFlags, sampleBuffer in
            guard status == noErr, let buffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.handleEncodedSampleBuffer(buffer)
        }

        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: currentWidth,
            height: currentHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )

        guard createStatus == noErr, let session = newSession else {
            NSLog("[VideoEncoder] VTCompressionSessionCreate failed: %d", createStatus)
            return
        }

        // 5. Apply Hardened Low-Latency Properties
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Data rate limit ceiling: (bitrate / 8) * 1.5 bytes/sec
        let byteLimit = Int(Float(bitrate) / 8.0 * 1.5)
        let dataRateLimits: [CFNumber] = [byteLimit as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        // Keyframe cadence: 1 keyframe per second
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compressionSession = session

        // 6. Notify Desktop Receiver of Geometry Change
        let rotationVal: Int32 = isLandscape ? 90 : 0
        dimensionHandler?(currentWidth, currentHeight, rotationVal)
    }

    // MARK: - Output Sample Handling & H.264 NAL Parsing

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Determine if keyframe (IDR) using type-safe CFDictionary casting
        var isKeyFrame = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let firstAttachment = attachments.first,
           let notSync = firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyFrame = !notSync
        }

        // On keyframe, extract SPS and PPS parameters (ASM @ 0x1349c)
        if isKeyFrame {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: nil
            )

            // Extract SPS (Index 0)
            var spsPointer: UnsafePointer<UInt8>?
            var spsSize = 0
            let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            // Extract PPS (Index 1)
            var ppsPointer: UnsafePointer<UInt8>?
            var ppsSize = 0
            let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            if spsStatus == noErr, ppsStatus == noErr, let sps = spsPointer, let pps = ppsPointer {
                spsHeader = Data(bytes: sps, count: spsSize)
                ppsHeader = Data(bytes: pps, count: ppsSize)

                if let spsData = spsHeader, let ppsData = ppsHeader {
                    var spsPpsData = Data()
                    spsPpsData.append(annexBStartCode)
                    spsPpsData.append(spsData)
                    spsPpsData.append(annexBStartCode)
                    spsPpsData.append(ppsData)

                    // Dispatch SPS/PPS as keyframe preamble
                    dispatchNetworkPackets(data: spsPpsData, isKeyFrame: true)
                }
            }
        }

        // Extract AVCC length-prefixed NALUs and convert to Annex-B [00 00 00 01]
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard blockStatus == noErr, let rawData = dataPointer else { return }

        var bufferOffset = 0
        let avccHeaderLength = 4

        while bufferOffset < totalLength - avccHeaderLength {
            // Read 4-byte big-endian NALU length
            var naluLength: UInt32 = 0
            memcpy(&naluLength, rawData + bufferOffset, avccHeaderLength)
            naluLength = CFSwapInt32BigToHost(naluLength)

            bufferOffset += avccHeaderLength

            guard bufferOffset + Int(naluLength) <= totalLength else { break }

            // Construct Annex-B slice
            var sliceData = Data()
            sliceData.append(annexBStartCode)
            sliceData.append(Data(bytes: rawData + bufferOffset, count: Int(naluLength)))

            // Dispatch slice packets with ApowerMirror slicing tags
            dispatchNetworkPackets(data: sliceData, isKeyFrame: isKeyFrame)

            bufferOffset += Int(naluLength)
        }
    }

    // MARK: - ApowerMirror Network Slicing & Header Tagging

    private func dispatchNetworkPackets(data: Data, isKeyFrame: Bool) {
        let totalSize = data.count
        var offset = 0

        while offset < totalSize {
            let chunkSize = min(kMaxSliceChunkSize, totalSize - offset)
            let isEnd = (offset + chunkSize >= totalSize)

            // Framing tag: 4 bytes big-endian
            var tagBytes: [UInt8] = isEnd ? [0x00, 0x00, 0x00, 0x02] : [0x00, 0x00, 0x00, 0x00]
            var packet = Data(tagBytes)

            // Append sub-slice payload
            packet.append(data.subdata(in: offset..<(offset + chunkSize)))

            // Forward to network transmission
            packetHandler(packet, isKeyFrame, isEnd)

            offset += chunkSize
        }
    }

    public func invalidate() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    deinit {
        invalidate()
    }
}
