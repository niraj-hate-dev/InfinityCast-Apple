//
//  VideoEncoder.swift
//  ApowerMirrorUpload / AppleCast
//
//  Hardware VideoToolbox H.264 Video Encoder
//  Supports dynamic resolution presets: 240p, 360p, 480p, 544p, 720p, 1080p, 2K, 4K
//  Supports dynamic bitrate configuration: 1 Mbps to 20 Mbps (Max)
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import ImageIO

public final class VideoEncoder {

    // MARK: - Types & Callbacks
    public typealias EncodedPacketHandler = (_ packet: Data, _ isKeyFrame: Bool, _ isEndFrame: Bool) -> Void
    public typealias DimensionChangeHandler = (_ width: Int32, _ height: Int32, _ rotation: Int32) -> Void

    // MARK: - Configuration
    private var bitrate: Int32
    private var fps: Int32
    private var targetShortSide: Int32
    private var currentWidth: Int32 = 0
    private var currentHeight: Int32 = 0
    private var lastRawWidth: Int32 = 0
    private var lastRawHeight: Int32 = 0
    private var currentOrientation: CGImagePropertyOrientation = .up

    // MARK: - State
    private var compressionSession: VTCompressionSession?
    private let packetHandler: EncodedPacketHandler
    private var dimensionHandler: DimensionChangeHandler?
    private let encoderQueue = DispatchQueue(label: "com.apowermirror.encoder.queue", qos: .userInteractive)
    private var spsHeader: Data?
    private var ppsHeader: Data?
    private let annexBStartCode = Data([0x00, 0x00, 0x00, 0x01])
    private var forceNextKeyframe = true

    private static let forceKeyframeNotificationName = "com.apowermirror.forceKeyframe" as CFString

    // MARK: - Helpers for Presets

    public static func resolutionToShortSide(_ res: String) -> Int32 {
        let clean = res.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.contains("240") { return 240 }
        if clean.contains("360") { return 360 }
        if clean.contains("480") { return 480 }
        if clean.contains("544") { return 544 }
        if clean.contains("720") { return 720 }
        if clean.contains("1080") { return 1080 }
        if clean.contains("2k") || clean.contains("1440") { return 1440 }
        if clean.contains("4k") || clean.contains("2160") { return 2160 }
        return 720
    }

    public static func bitrateStringToBps(_ bitStr: String) -> Int32 {
        let clean = bitStr.lowercased()
        if clean.contains("20") || clean.contains("max") { return 20_000_000 }
        if clean.contains("16") { return 16_000_000 }
        if clean.contains("12") { return 12_000_000 }
        if clean.contains("8") { return 8_000_000 }
        if clean.contains("6") { return 6_000_000 }
        if clean.contains("4") { return 4_000_000 }
        if clean.contains("2") { return 2_000_000 }
        if clean.contains("1") { return 1_000_000 }
        return 4_000_000
    }

    // MARK: - Initialization

    public init(
        bitrate: Int32 = 4_000_000,
        fps: Int32 = 60,
        targetShortSide: Int32 = 720,
        maxDimension: Int32 = 1600,
        packetHandler: @escaping EncodedPacketHandler
    ) {
        self.bitrate = bitrate
        self.fps = fps
        if targetShortSide > 0 {
            self.targetShortSide = targetShortSide
        } else if maxDimension > 0 {
            self.targetShortSide = (maxDimension <= 1440) ? maxDimension : Int32(Float(maxDimension) * 9.0 / 19.5)
        } else {
            self.targetShortSide = 720
        }
        self.packetHandler = packetHandler
        registerCrossProcessKeyframeObserver()
    }

    public func updateConfiguration(bitrate: Int32, targetShortSide: Int32, fps: Int32 = 60) {
        encoderQueue.async { [weak self] in
            guard let self = self else { return }
            if self.bitrate != bitrate || self.targetShortSide != targetShortSide || self.fps != fps {
                NSLog("[VideoEncoder] Updating Configuration -> Bitrate: %d, ShortSide: %d, FPS: %d", bitrate, targetShortSide, fps)
                self.bitrate = bitrate
                self.targetShortSide = targetShortSide
                self.fps = fps
                self.invalidate()
                self.forceNextKeyframe = true
            }
        }
    }

    public func updateConfiguration(bitrate: Int32, maxDimension: Int32, fps: Int32 = 60) {
        let shortSide = (maxDimension <= 1440) ? maxDimension : Int32(Float(maxDimension) * 9.0 / 19.5)
        updateConfiguration(bitrate: bitrate, targetShortSide: shortSide, fps: fps)
    }

    private func registerCrossProcessKeyframeObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(observer).takeUnretainedValue()
                encoder.forceKeyFrame()
            },
            Self.forceKeyframeNotificationName,
            nil,
            .deliverImmediately
        )
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
                if self.compressionSession == nil ||
                   orientation != self.currentOrientation ||
                   rawWidth != self.lastRawWidth ||
                   rawHeight != self.lastRawHeight {
                    self.currentOrientation = orientation
                    self.lastRawWidth = rawWidth
                    self.lastRawHeight = rawHeight
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

        var targetW = sourceWidth
        var targetH = sourceHeight

        let isLandscape = (orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored)
        if isLandscape && targetW < targetH {
            swap(&targetW, &targetH)
        } else if !isLandscape && targetW > targetH {
            swap(&targetW, &targetH)
        }

        let currentShort = min(targetW, targetH)
        let currentLong = max(targetW, targetH)

        // Scale resolution according to targetShortSide (240p, 360p, 480p, 544p, 720p, 1080p, 2K, 4K)
        if targetShortSide > 0 && currentShort != targetShortSide {
            let scale = Float(targetShortSide) / Float(currentShort)
            let scaledLong = Int32(Float(currentLong) * scale)
            if targetW >= targetH {
                targetW = scaledLong
                targetH = targetShortSide
            } else {
                targetW = targetShortSide
                targetH = scaledLong
            }
        }

        // Clamp maximum dimension to 3840 (H.264 level limit safety for 4K / 2K)
        if max(targetW, targetH) > 3840 {
            let maxDim = max(targetW, targetH)
            let clampScale = Float(3840) / Float(maxDim)
            targetW = Int32(Float(targetW) * clampScale)
            targetH = Int32(Float(targetH) * clampScale)
        }

        // Macroblock 16-pixel alignment: strictly divisible by 16
        currentWidth = (targetW / 16) * 16
        currentHeight = (targetH / 16) * 16

        NSLog("[VideoEncoder] Initializing VTCompressionSession: %dx%d (Orientation: %d, Bitrate: %d)", currentWidth, currentHeight, orientation.rawValue, bitrate)

        var newSession: VTCompressionSession?
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, infoFlags, sampleBuffer in
            guard status == noErr, let buffer = sampleBuffer, let refCon = outputCallbackRefCon else { return }
            autoreleasepool {
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refCon).takeUnretainedValue()
                encoder.handleEncodedSampleBuffer(buffer)
            }
        }

        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: currentWidth,
            height: currentHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession
        )

        guard createStatus == noErr, let session = newSession else {
            NSLog("[VideoEncoder] VTCompressionSessionCreate failed: %d", createStatus)
            return
        }

        // Apply Hardened Low-Latency Properties with High Profile 8x8 Transform
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)

        // Enforce true 12-16 Mbps bitrate without quality-override throttling
        if #available(iOS 16.0, *) {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ConstantBitRate, value: bitrate as CFNumber)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        }

        // Permissive 1-second burst cap (2.0x bitrate) guarantees full bitrate allocation during fast motion
        let byteLimit = Int(Float(bitrate) / 8.0 * 2.0)
        let dataRateLimits: [CFNumber] = [byteLimit as CFNumber, 1.0 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)

        // Keyframe cadence: 1 keyframe every 3.0s (180 frames at 60fps) to eliminate IDR bitrate starvation of P-frames
        let keyFrameIntervalFrames = max(90, Int(fps) * 3)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameIntervalFrames as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 3.0 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.compressionSession = session
        self.forceNextKeyframe = true

        // Notify Desktop Receiver of Geometry Change
        let rotationVal: Int32 = isLandscape ? 90 : 0
        dimensionHandler?(currentWidth, currentHeight, rotationVal)
    }

    // MARK: - Output Sample Handling & H.264 NAL Parsing

    private func handleEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let firstAttachment = attachments.first {
            let notSync = (firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            isKeyFrame = !notSync
        }

        // Extract SPS & PPS on IDR keyframe
        if isKeyFrame, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            extractSpsPps(from: formatDesc)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(dataBuffer)
        guard totalLength > 4 else { return }

        var fullFrameData = Data()

        // Prepend Annex-B SPS & PPS before IDR slice
        if isKeyFrame, let sps = spsHeader, let pps = ppsHeader {
            fullFrameData.append(annexBStartCode)
            fullFrameData.append(sps)
            fullFrameData.append(annexBStartCode)
            fullFrameData.append(pps)
        }

        // Iterate AVCC length-prefixed NALUs using safe non-contiguous block copy
        var offset = 0
        while offset + 4 <= totalLength {
            var naluLengthBE: UInt32 = 0
            let status = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset, dataLength: 4, destination: &naluLengthBE)
            guard status == kCMBlockBufferNoErr else { break }

            let naluLength = Int(CFSwapInt32BigToHost(naluLengthBE))
            offset += 4
            guard naluLength > 0, offset + naluLength <= totalLength else { break }

            fullFrameData.append(annexBStartCode)
            let prevCount = fullFrameData.count
            fullFrameData.count += naluLength
            fullFrameData.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: offset, dataLength: naluLength, destination: base.advanced(by: prevCount))
            }
            offset += naluLength
        }

        guard !fullFrameData.isEmpty else { return }

        // Dispatch complete Annex-B NAL unit frame directly (no sub-packet slicing in TCP)
        packetHandler(fullFrameData, isKeyFrame, true)
    }

    private func extractSpsPps(from formatDesc: CMFormatDescription) {
        var spsCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )

        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPtr,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPtr,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        if spsStatus == noErr, let ptr = spsPtr, spsSize > 0 {
            spsHeader = Data(bytes: ptr, count: spsSize)
        }
        if ppsStatus == noErr, let ptr = ppsPtr, ppsSize > 0 {
            ppsHeader = Data(bytes: ptr, count: ppsSize)
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
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(Self.forceKeyframeNotificationName), nil)
    }
}
