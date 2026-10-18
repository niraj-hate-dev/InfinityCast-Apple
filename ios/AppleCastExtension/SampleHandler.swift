import ReplayKit
import VideoToolbox
import Network
import Darwin

/// ReplayKit 2 Screen Broadcast Extension (Transmitter Core)
/// Reconstructed 1:1 from ApowerMirror WXCastiOSSender Architecture.
///
/// Features:
/// 1. Proper RPBroadcastSampleHandler XPC lifecycle (calls super.broadcastStarted to complete handshake with replayd).
/// 2. Zero-dependency Darwin Notifications across process boundaries (MMWormhole equivalent).
/// 3. Macroblock 16-pixel alignment ((x + 15) & ~15) and dynamic downscaling (<= 1920) to strictly prevent 50MB Jetsam kills.
/// 4. Direct BSD socket server on INADDR_ANY (0.0.0.0:15333) for usbmuxd virtual TCP tunnel.
/// 5. RFC 2326 Interleaved RTP framing ($ + channel 0 + 16-bit length) + H.264 NALUs with SPS/PPS parameter sets.
@objc(SampleHandler)
public class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Constants & Architecture Specifications
    private let appGroupName = "group.applecast.mirror"
    private let defaultPort: UInt16 = 25334
    private var streamingPort: UInt16 = 25334
    private var targetFps: Int32 = 60
    private var targetBitrate: Int32 = 4_000_000 // 4 Mbps (safe for 50MB Jetsam)
    private let rtpMagicByte: UInt8 = 0x24       // '$'
    private let rtpChannelVideo: UInt8 = 0x00
    private let rtpPayloadType: UInt8 = 96       // Dynamic H.264
    private let ssrcId: UInt32 = 0x11223344

    // MARK: - VideoToolbox Pipeline
    private var compressionSession: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var rtpSequenceNumber: UInt16 = 0
    private var lastRawWidth: Int32 = 0
    private var lastRawHeight: Int32 = 0
    private var lastOrientation: CGImagePropertyOrientation = .up

    // MARK: - Memory Management & Backpressure State
    private var sharedDefaults: UserDefaults?
    private var isMemoryLocked = false
    private let encodeQueue = DispatchQueue(label: "com.applecast.encoder.queue", qos: .userInteractive)

    // MARK: - Sockets & Concurrency (BSD Server on 0.0.0.0)
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private let socketLock = NSLock()
    private let networkQueue = DispatchQueue(label: "com.applecast.networkQueue", qos: .userInteractive)
    private var isBroadcasting = false

    // MARK: - Lifecycle
    public override init() {
        super.init()
    }

    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // CRITICAL: MUST call super to finish the internal ReplayKit XPC handshake with replayd!
        // Without this call, replayd times out and the recording circle stays GRAY!
        super.broadcastStarted(withSetupInfo: setupInfo)

        NSLog("[AppleCastExtension] >>> broadcastStarted invoked by ReplayKit host!")
        isBroadcasting = true
        frameIndex = 0
        rtpSequenceNumber = 0
        isMemoryLocked = false

        // Post Darwin notification immediately to notify Main App (like MMWormhole in ApowerMirror)
        notifyMainApp(event: "BroadcastStarted")

        // Read configuration safely from App Group UserDefaults (fallback to standard for sideloading)
        sharedDefaults = UserDefaults(suiteName: appGroupName) ?? UserDefaults.standard
        let targetPortInt = sharedDefaults?.integer(forKey: "wxiosserverport") ?? 0
        streamingPort = targetPortInt > 0 ? UInt16(targetPortInt) : defaultPort

        if let fps = sharedDefaults?.integer(forKey: "videoFps"), fps > 0 {
            targetFps = Int32(fps)
        }
        if let bitrate = sharedDefaults?.integer(forKey: "videoBitrate"), bitrate > 0 {
            targetBitrate = Int32(bitrate)
        }

        // Record active lifecycle state
        sharedDefaults?.set("RUNNING", forKey: "extension_status")
        sharedDefaults?.set(Int(streamingPort), forKey: "extension_active_port")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "extension_start_time")
        sharedDefaults?.set("LISTENING", forKey: "extension_socket_state")
        sharedDefaults?.synchronize()

        NSLog("[AppleCastExtension] Target streaming port: %d (FPS: %d, Bitrate: %d bps)", streamingPort, targetFps, targetBitrate)

        // Bind BSD TCP server on 0.0.0.0 to receive usbmuxd tunnel
        startLocalTcpServer(port: streamingPort)
    }

    public override func broadcastPaused() {
        super.broadcastPaused()
        notifyMainApp(event: "PauseVideo")
        NSLog("[AppleCastExtension] broadcastPaused invoked")
    }

    public override func broadcastResumed() {
        super.broadcastResumed()
        notifyMainApp(event: "ResumeVideo")
        NSLog("[AppleCastExtension] broadcastResumed invoked")
    }

    public override func broadcastFinished() {
        super.broadcastFinished()
        NSLog("[AppleCastExtension] >>> broadcastFinished invoked - shutting down")
        isBroadcasting = false
        sharedDefaults?.set("STOPPED", forKey: "extension_status")
        sharedDefaults?.set("STOPPED", forKey: "extension_socket_state")
        sharedDefaults?.synchronize()
        teardownSession()
        notifyMainApp(event: "Finish")
    }

    // MARK: - Frame Processing Pipeline
    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting else { return }

        switch sampleBufferType {
        case .video:
            // Critical Jetsam 50MB OOM Prevention:
            // If physical footprint reaches 41 MB, drop frame immediately without queuing.
            if isMemoryLocked || getPhysicalFootprintMB() >= 41 {
                isMemoryLocked = true
                scheduleMemoryRecoveryCheck()
                return // Drop frame under memory pressure
            }

            var frameOrientation: CGImagePropertyOrientation = .up
            if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                frameOrientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) ?? .up
            }

            // Encode on dedicated queue with explicit autoreleasepool to drain CoreVideo buffers
            encodeQueue.async { [weak self] in
                autoreleasepool {
                    guard let self = self, self.isBroadcasting else { return }
                    if self.frameIndex == 0 {
                        NSLog("[AppleCastExtension] >>> First video CMSampleBuffer received from ReplayKit pipeline!")
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    self.handleVideoPixelBuffer(pixelBuffer, pts: pts, orientation: frameOrientation)
                }
            }

        case .audioApp, .audioMic:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Mach Kernel Memory Diagnostics (TASK_VM_INFO)
    private func getPhysicalFootprintMB() -> Int64 {
        var vmInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / 4)
        let kr = withUnsafeMutablePointer(to: &vmInfo) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int64(vmInfo.phys_footprint / (1024 * 1024))
    }

    private func scheduleMemoryRecoveryCheck() {
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            if self.getPhysicalFootprintMB() <= 39 {
                self.isMemoryLocked = false
            } else {
                self.scheduleMemoryRecoveryCheck()
            }
        }
    }

    // MARK: - VideoToolbox Hardware Compression (Zero-Latency Setup)
    private func handleVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime, orientation: CGImagePropertyOrientation) {
        let rawWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let rawHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))

        if compressionSession == nil || rawWidth != lastRawWidth || rawHeight != lastRawHeight || orientation != lastOrientation {
            lastRawWidth = rawWidth
            lastRawHeight = rawHeight
            lastOrientation = orientation
            setupCompressionSession(sourceWidth: rawWidth, sourceHeight: rawHeight, orientation: orientation)
        }

        guard let session = compressionSession else { return }

        frameIndex += 1
        let forceKeyframe = (frameIndex % Int64(targetFps) == 1)

        var flags: VTEncodeInfoFlags = []
        let properties: [CFString: Any] = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : [:]

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties as CFDictionary,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
    }

    private func setupCompressionSession(sourceWidth: Int32, sourceHeight: Int32, orientation: CGImagePropertyOrientation) {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        // ApowerMirror Jetsam 50MB Safeguard:
        // Downscale Retina resolution to prevent Jetsam 50MB crash (clamp max dimension to 1920)
        var targetW = sourceWidth
        var targetH = sourceHeight
        let maxDim: Int32 = 1920

        if targetW > maxDim || targetH > maxDim {
            if targetW > targetH {
                targetH = Int32((Float(targetH) / Float(targetW)) * Float(maxDim))
                targetW = maxDim
            } else {
                targetW = Int32((Float(targetW) / Float(targetH)) * Float(maxDim))
                targetH = maxDim
            }
        }

        // Macroblock 16-pixel alignment from decompiled ApowerMirror: (x + 15) & ~15
        let alignedWidth = (targetW + 15) & ~15
        let alignedHeight = (targetH + 15) & ~15

        NSLog("[AppleCastExtension] Initializing VideoToolbox: input=%dx%d -> aligned=%dx%d (targetFps: %d, bitrate: %d bps)",
              sourceWidth, sourceHeight, alignedWidth, alignedHeight, targetFps, targetBitrate)

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: alignedWidth,
            height: alignedHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        guard status == noErr, let session = compressionSession else {
            NSLog("[AppleCastExtension] Failed to create VTCompressionSession: %d", status)
            return
        }

        // 1. Low-latency real-time flags
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // CRITICAL FOR ZERO LATENCY & MEMORY: Disable frame reordering (strictly eliminates B-frames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)

        // 2. Profile Level selection (Main for >=1080p, Baseline for <1080p)
        let profile = alignedWidth >= 1920 ? kVTProfileLevel_H264_Main_AutoLevel : kVTProfileLevel_H264_Baseline_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        // 3. Bitrate, Burst Limits & Quality factor (0.80 for 1080p matching ApowerMirror)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.80 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        let byteLimit = (targetBitrate * 2) / 8 // 2x average bitrate cap per second
        let limits: [CFNumber] = [byteLimit as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)

        // 4. Critical Jetsam OOM Prevention: MaxFrameDelayCount = 1 (forces immediate flush, zero queueing)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)

        // 5. Framerate & Keyframe intervals (GOP size)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFps as CFNumber)
        let gopSize = targetFps >= 60 ? (targetFps * 2) : (targetFps * 3)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gopSize as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    // MARK: - Direct BSD TCP Streaming Server for usbmuxd (Zero-Latency Loopback)
    private func startLocalTcpServer(port: UInt16) {
        networkQueue.async { [weak self] in
            guard let self = self, self.isBroadcasting else { return }

            NSLog("[AppleCastExtension] Initializing BSD streaming server on 0.0.0.0:%d...", port)

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[AppleCastExtension] Failed to create streaming socket: errno %d", errno)
                return
            }

            var yes: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

            var serverAddr = sockaddr_in()
            serverAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            serverAddr.sin_family = sa_family_t(AF_INET)
            serverAddr.sin_port = port.bigEndian
            serverAddr.sin_addr.s_addr = in_addr_t(0) // Bind to INADDR_ANY (0.0.0.0) to accept usbmuxd 127.0.0.1 tunnel

            let bindRes = withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bindRes >= 0, listen(sock, 5) >= 0 else {
                NSLog("[AppleCastExtension] BSD socket bind/listen failed on port %d (errno: %d)", port, errno)
                close(sock)
                return
            }

            self.serverSocket = sock
            NSLog("[AppleCastExtension] >>> SUCCESS: BSD streaming server listening on 0.0.0.0:%d! <<<", port)
            self.sharedDefaults?.set("LISTENING", forKey: "extension_socket_state")
            self.sharedDefaults?.synchronize()

            while self.isBroadcasting {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        accept(sock, saPtr, &addrLen)
                    }
                }
                if client >= 0 {
                    var flag: Int32 = 1
                    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))
                    self.socketLock.lock()
                    if self.clientSocket >= 0 { close(self.clientSocket) }
                    self.clientSocket = client
                    self.socketLock.unlock()
                    NSLog("[AppleCastExtension] >>> SUCCESS: Windows Client connected to video streaming socket! <<<")
                    self.sharedDefaults?.set("CLIENT_CONNECTED", forKey: "extension_socket_state")
                    self.sharedDefaults?.synchronize()
                }
            }
        }
    }

    // MARK: - RFC 2326 Interleaved RTP Packet Packaging
    fileprivate func sendEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        socketLock.lock()
        let hasActiveClient = (clientSocket >= 0)
        socketLock.unlock()

        guard hasActiveClient else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let pts = UInt32((CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 90000.0).truncatingRemainder(dividingBy: Double(UInt32.max)))

        // 1. Send SPS & PPS parameter sets on IDR keyframe or first frame
        var isKeyFrame = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyFrame = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else if frameIndex <= 2 {
            isKeyFrame = true
        }

        if isKeyFrame || frameIndex == 1 {
            sendParameterSets(formatDesc: formatDesc, pts: pts)
        }

        // 2. Extract and send NAL units
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == noErr, let rawData = dataPointer else { return }

        var bufferOffset = 0
        let avccHeaderLength = 4

        while bufferOffset < totalLength - avccHeaderLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, rawData + bufferOffset, avccHeaderLength)
            naluLength = CFSwapInt32BigToHost(naluLength)
            bufferOffset += avccHeaderLength

            guard naluLength > 0, bufferOffset + Int(naluLength) <= totalLength else { break }

            let naluPointer = rawData + bufferOffset
            let isLastNalu = (bufferOffset + Int(naluLength) >= totalLength)

            sendRtpInterleavedPacket(
                naluPointer: UnsafeRawPointer(naluPointer),
                naluLength: Int(naluLength),
                pts: pts,
                isMarker: isLastNalu
            )

            bufferOffset += Int(naluLength)
        }
    }

    private func sendParameterSets(formatDesc: CMFormatDescription, pts: UInt32) {
        var spsCount: size_t = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil)

        for i in 0..<spsCount {
            var paramSetPtr: UnsafePointer<UInt8>?
            var paramSetSize: size_t = 0

            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: i,
                parameterSetPointerOut: &paramSetPtr,
                parameterSetSizeOut: &paramSetSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )

            if status == noErr, let ptr = paramSetPtr, paramSetSize > 0 {
                sendRtpInterleavedPacket(
                    naluPointer: UnsafeRawPointer(ptr),
                    naluLength: paramSetSize,
                    pts: pts,
                    isMarker: false
                )
            }
        }
    }

    private func sendRtpInterleavedPacket(naluPointer: UnsafeRawPointer, naluLength: Int, pts: UInt32, isMarker: Bool) {
        guard naluLength > 0 else { return }

        socketLock.lock()
        let activeBsd = clientSocket
        socketLock.unlock()
        guard activeBsd >= 0 else { return }

        let maxPayloadSize = 1400

        // Single NAL unit packet (fits within standard MTU)
        if naluLength <= maxPayloadSize {
            let rtpPayloadSize = 12 + naluLength
            guard rtpPayloadSize <= 0xFFFF else { return }

            rtpSequenceNumber = rtpSequenceNumber &+ 1

            var packetData = Data(capacity: 4 + rtpPayloadSize)
            packetData.append(rtpMagicByte)
            packetData.append(rtpChannelVideo)
            let payloadLenBE = UInt16(rtpPayloadSize).bigEndian
            withUnsafeBytes(of: payloadLenBE) { packetData.append(contentsOf: $0) }

            let byte0: UInt8 = 0x80 // Version 2
            let byte1: UInt8 = (isMarker ? 0x80 : 0x00) | (rtpPayloadType & 0x7F)
            let seqBE = rtpSequenceNumber.bigEndian
            let ptsBE = pts.bigEndian
            let ssrcBE = ssrcId.bigEndian

            packetData.append(byte0)
            packetData.append(byte1)
            withUnsafeBytes(of: seqBE) { packetData.append(contentsOf: $0) }
            withUnsafeBytes(of: ptsBE) { packetData.append(contentsOf: $0) }
            withUnsafeBytes(of: ssrcBE) { packetData.append(contentsOf: $0) }

            packetData.append(naluPointer.assumingMemoryBound(to: UInt8.self), count: naluLength)

            sendSocketData(packetData, socket: activeBsd)
            return
        }

        // FU-A Fragmentation Unit (RFC 6184 Section 5.8 for large frames e.g. IDR Keyframes)
        let firstByte = naluPointer.load(as: UInt8.self)
        let nri = firstByte & 0x60
        let originalNalType = firstByte & 0x1F
        let fuIndicator = nri | 28 // 28 = FU-A

        var offset = 1 // Skip first byte of NALU
        let rawNalBytes = naluPointer.assumingMemoryBound(to: UInt8.self)

        while offset < naluLength {
            let remaining = naluLength - offset
            let chunkSize = min(remaining, maxPayloadSize)
            let isStart = (offset == 1)
            let isEnd = (offset + chunkSize == naluLength)

            var fuHeader = originalNalType
            if isStart { fuHeader |= 0x80 }
            if isEnd { fuHeader |= 0x40 }

            let rtpPayloadSize = 12 + 2 + chunkSize
            rtpSequenceNumber = rtpSequenceNumber &+ 1

            var packetData = Data(capacity: 4 + rtpPayloadSize)
            packetData.append(rtpMagicByte)
            packetData.append(rtpChannelVideo)
            let payloadLenBE = UInt16(rtpPayloadSize).bigEndian
            withUnsafeBytes(of: payloadLenBE) { packetData.append(contentsOf: $0) }

            let byte0: UInt8 = 0x80
            let byte1: UInt8 = (isEnd && isMarker ? 0x80 : 0x00) | (rtpPayloadType & 0x7F)
            let seqBE = rtpSequenceNumber.bigEndian
            let ptsBE = pts.bigEndian
            let ssrcBE = ssrcId.bigEndian

            packetData.append(byte0)
            packetData.append(byte1)
            withUnsafeBytes(of: seqBE) { packetData.append(contentsOf: $0) }
            withUnsafeBytes(of: ptsBE) { packetData.append(contentsOf: $0) }
            withUnsafeBytes(of: ssrcBE) { packetData.append(contentsOf: $0) }

            packetData.append(fuIndicator)
            packetData.append(fuHeader)
            packetData.append(rawNalBytes.advanced(by: offset), count: chunkSize)

            sendSocketData(packetData, socket: activeBsd)

            offset += chunkSize
        }
    }

    private func sendSocketData(_ data: Data, socket fd: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sentBytes = 0
            let totalBytes = rawBuffer.count
            while sentBytes < totalBytes {
                let res = write(fd, baseAddress.advanced(by: sentBytes), totalBytes - sentBytes)
                if res <= 0 {
                    self.socketLock.lock()
                    if self.clientSocket == fd {
                        close(self.clientSocket)
                        self.clientSocket = -1
                    }
                    self.socketLock.unlock()
                    break
                }
                sentBytes += res
            }
        }
    }

    private func teardownSession() {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }

        socketLock.lock()
        if clientSocket >= 0 {
            shutdown(clientSocket, SHUT_RDWR)
            close(clientSocket)
            clientSocket = -1
        }
        if serverSocket >= 0 {
            shutdown(serverSocket, SHUT_RDWR)
            close(serverSocket)
            serverSocket = -1
        }
        socketLock.unlock()
    }

    // MARK: - Darwin Notification Helper (MMWormhole Equivalent)
    private func notifyMainApp(event: String) {
        let notificationName = "com.applecast.broadcast.\(event)" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName),
            nil,
            nil,
            true
        )
    }
}

// C-style global callback invoked by VideoToolbox hardware encoder
private func compressionCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else {
        return
    }

    let handler = Unmanaged<SampleHandler>.fromOpaque(refCon).takeUnretainedValue()
    handler.sendEncodedSampleBuffer(sampleBuffer)
}
