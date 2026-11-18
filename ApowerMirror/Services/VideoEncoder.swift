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
import CoreImage

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
    // Reuse the GPU context and avoid retaining intermediate frame textures.
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

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
                guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
                var preparedBuffer: CVPixelBuffer?
                let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    kCFAllocatorDefault, pool,
                    [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary,
                    &preparedBuffer)
                guard allocation == kCVReturnSuccess, let prepared = preparedBuffer else {
                    // Drop rather than build a backlog or exceed the extension memory limit.
                    return
                }
                let cleanRect = CVImageBufferGetCleanRect(pixelBuffer)
                let sourceImage = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: cleanRect)
                let oriented = sourceImage.oriented(orientation)
                let orientedExtent = oriented.extent
                let normalized = oriented.transformed(by: CGAffineTransform(
                    translationX: -orientedExtent.minX, y: -orientedExtent.minY))
                let srcW = max(1.0, normalized.extent.width)
                let srcH = max(1.0, normalized.extent.height)
                let targetBounds = CGRect(x: 0, y: 0, width: Int(self.currentWidth), height: Int(self.currentHeight))
                let scaleX = targetBounds.width / srcW
                let scaleY = targetBounds.height / srcH
                let scaled: CIImage
                if abs(scaleX - 1.0) < 0.001 && abs(scaleY - 1.0) < 0.001 {
                    scaled = normalized.clampedToExtent().cropped(to: targetBounds)
                } else {
                    scaled = normalized
                        .clampedToExtent()
                        .applyingFilter("CILanczosScaleTransform", parameters: [
                            kCIInputScaleKey: scaleY,
                            kCIInputAspectRatioKey: scaleX / scaleY
                        ])
                        .cropped(to: targetBounds)
                }
                self.imageContext.render(scaled, to: prepared,
                    bounds: targetBounds,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

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
                    imageBuffer: prepared,
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

        // Orientation describes a transform of the actual buffer, not its shape.
        let quarterTurn = (orientation == .left || orientation == .right || orientation == .leftMirrored || orientation == .rightMirrored)
        if quarterTurn { swap(&targetW, &targetH) }
        let isLandscape = targetW > targetH

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

        // Macroblock 16-pixel alignment: eliminates H.264 crop padding & left-edge NV12 artifacts
        currentWidth = max(16, (targetW / 16) * 16)
        currentHeight = max(16, (targetH / 16) * 16)

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
            kCVPixelBufferWidthKey: currentWidth,
            kCVPixelBufferHeightKey: currentHeight,
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

        // 1-frame hardware pipelining: enables hardware H.264 engine to encode asynchronously
        // without blocking the dispatch queue, guaranteeing rock-solid 60 FPS cadence
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)

        // Pure low-latency rate control: AverageBitRate (CBR is strictly avoided because it forces HRD buffer lookahead delay)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)

        // Permissive 2.0x burst ceiling allows complex motion scenes to expand freely without rate throttling
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
        let rotationVal: Int32 = Int32(touchRotationDegrees(for: orientation))
        dimensionHandler?(currentWidth, currentHeight, rotationVal)
    }

    private func touchRotationDegrees(for orientation: CGImagePropertyOrientation) -> Int {
        switch orientation {
        case .right, .rightMirrored: return 90
        case .down, .downMirrored: return 180
        case .left, .leftMirrored: return 270
        default: return 0
        }
    }

    private func buildOrientationSeiNal() -> Data {
        // Standard H.264 SEI NAL (type 6, payloadType 5 user_data_unregistered, size 20)
        // 16-byte UUID ("ICOR-ORIENT-META") + 4-byte payload ("ROT" + code 1..4) + 0x80 RBSP stop bit
        let deg = touchRotationDegrees(for: currentOrientation)
        let code = UInt8(1 + (deg / 90)) // 1=0, 2=90, 3=180, 4=270
        let bytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x06, 0x05, 0x14,
            0x49, 0x43, 0x4F, 0x52, 0x2D, 0x4F, 0x52, 0x49,
            0x45, 0x4E, 0x54, 0x2D, 0x4D, 0x45, 0x54, 0x41,
            0x52, 0x4F, 0x54, code,
            0x80
        ]
        return Data(bytes)
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
            fullFrameData.append(buildOrientationSeiNal())
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
