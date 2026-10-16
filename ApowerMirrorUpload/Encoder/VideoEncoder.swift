//
//  VideoEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Reconstructed 1:1 from ApowerMirror WXCastiOSSender:
//  - -[WXCastSenderVideoEncoder createSessionRotation:]
//  - -[WXCastSenderVideoEncoder _encodeH264SampleBuffer:param:]
//  - -[WXCastSenderVideoEncoder gotSpsPps:pps:]
//  - -[WXCastSenderVideoEncoder gotEncodedData:]
//  - -[WXCastSenderServer sendH264Data:type:]
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

                var flags: VTEncodeInfoFlags = []
                let status = VTCompressionSessionEncodeFrame(
                    session,
                    imageBuffer: pixelBuffer,
                    presentationTimeStamp: pts,
                    duration: duration,
                    frameProperties: nil,
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

        // 5. Apply exact ApowerMirror hardware encoder properties
        // Real-time low-latency profile
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // Zero B-frames for zero presentation delay
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        // Profile Level: High AutoLevel (universally supported by Apple VideoToolbox hardware with CABAC)
        let profile = kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)

        // Dynamic Quality factor (ASM @ 0x12e8c - 0x12ec0)
        let quality: Float
        if currentWidth >= 2560 {
            quality = 0.85
        } else if currentWidth >= 1920 {
            quality = 0.80
        } else {
            quality = 0.70
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber)

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber) // 1 keyframe/sec

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compressionSession = session

        // Notify geometry change
        let rotationVal: Int32 = isLandscape ? 1 : 0
        dimensionHandler?(currentWidth, currentHeight, rotationVal)
    }

    // MARK: - Frame Parsing & Annex-B Packetization

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Determine if keyframe (IDR)
        var isKeyFrame = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyFrame = !notSync
        }

        // On keyframe, extract SPS and PPS parameters (ASM @ 0x1349c)
        if isKeyFrame {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var spsSize = 0
                var spsCount = 0
                var spsPtr: UnsafePointer<UInt8>?

                let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPtr,
                    parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: &spsCount,
                    nalUnitHeaderLengthOut: nil
                )

                var ppsSize = 0
                var ppsCount = 0
                var ppsPtr: UnsafePointer<UInt8>?

                let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 1,
                    parameterSetPointerOut: &ppsPtr,
                    parameterSetSizeOut: &ppsSize,
                    parameterSetCountOut: &ppsCount,
                    nalUnitHeaderLengthOut: nil
                )

                if spsStatus == noErr, ppsStatus == noErr, let sps = spsPtr, let pps = ppsPtr {
                    var spsPpsData = Data()
                    spsPpsData.append(annexBStartCode)
                    spsPpsData.append(sps, count: spsSize)
                    spsPpsData.append(annexBStartCode)
                    spsPpsData.append(pps, count: ppsSize)

                    // Dispatch SPS/PPS as keyframe preamble
                    dispatchNetworkPackets(data: spsPpsData, isKeyFrame: true)
                }
            }
        }

        // Extract AVCC format slice and convert length prefixes to Annex-B start codes
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let pointer = dataPointer, totalLength > 0 else { return }

        var bufferOffset = 0
        let avccHeaderLength = 4

        while bufferOffset < totalLength - avccHeaderLength {
            // Read 4-byte big endian length prefix
            var naluLength: UInt32 = 0
            memcpy(&naluLength, pointer + bufferOffset, avccHeaderLength)
            naluLength = CFSwapInt32BigToHost(naluLength)

            guard naluLength > 0 else { break }

            bufferOffset += avccHeaderLength

            guard bufferOffset + Int(naluLength) <= totalLength else { break }

            // Construct Annex-B slice: [00 00 00 01] + [NALU Payload]
            var sliceData = Data()
            sliceData.append(annexBStartCode)
            sliceData.append(Data(bytes: pointer + bufferOffset, count: Int(naluLength)))

            // Slice into 10 KB packets and send
            dispatchNetworkPackets(data: sliceData, isKeyFrame: isKeyFrame)

            bufferOffset += Int(naluLength)
        }
    }

    // MARK: - ApowerMirror 10 KB Slicing & Header Framing
    // Decompiled directly from -[WXCastSenderServer sendH264Data:type:] @ 0x10450 - 0x10584:
    // Slices larger than 10 KB (0x2800) are broken into chunks with tags:
    // 0x00000000 = Intermediate slice chunk
    // 0x00000002 = End of frame chunk

    private func dispatchNetworkPackets(data: Data, isKeyFrame: Bool) {
        var offset = 0
        let totalSize = data.count

        while offset < totalSize {
            let remaining = totalSize - offset
            let chunkSize = min(remaining, kMaxSliceChunkSize)
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
