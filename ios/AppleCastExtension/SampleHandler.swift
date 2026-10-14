import ReplayKit
import VideoToolbox
import Darwin

/// ReplayKit 2 Screen Broadcast Extension (Transmitter Core)
/// Captures iOS display surfaces, compresses via VideoToolbox hardware encoder (Zero B-Frames),
/// monitors Mach kernel memory to prevent Jetsam 50MB OOM kills, and streams RFC 2326 Interleaved RTP
/// packets over local loopback TCP socket tunneled via usbmuxd.
class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Constants & Architecture Specifications
    private let appGroupName = "group.applecast.mirror"
    private let defaultPort: UInt16 = 15333
    private var streamingPort: UInt16 = 15333
    private var targetFps: Int32 = 60
    private var targetBitrate: Int32 = 8_000_000 // 8 Mbps (Prevents 50MB Jetsam OOM)
    private let rtpMagicByte: UInt8 = 0x24       // '$'
    private let rtpChannelVideo: UInt8 = 0x00
    private let rtpPayloadType: UInt8 = 96       // Dynamic H.264
    private let ssrcId: UInt32 = 0x11223344

    // MARK: - VideoToolbox Pipeline
    private var compressionSession: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var rtpSequenceNumber: UInt16 = 0

    // MARK: - Memory Management & Backpressure State
    private var sharedDefaults: UserDefaults?
    private var isMemoryLocked = false
    private let encodeQueue = DispatchQueue(label: "com.applecast.encoder.queue", qos: .userInteractive)

    // MARK: - Sockets & Concurrency
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private let socketLock = NSLock()
    private let networkQueue = DispatchQueue(label: "com.applecast.networkQueue", qos: .userInteractive)
    private var isBroadcasting = false

    // MARK: - Broadcast Lifecycle
    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        NSLog("[AppleCastExtension] >>> broadcastStarted invoked by ReplayKit host!")
        isBroadcasting = true
        frameIndex = 0
        rtpSequenceNumber = 0
        isMemoryLocked = false

        // Read configuration from shared App Group UserDefaults
        sharedDefaults = UserDefaults(suiteName: appGroupName)
        let targetPortInt = sharedDefaults?.integer(forKey: "wxiosserverport") ?? 0
        streamingPort = targetPortInt > 0 ? UInt16(targetPortInt) : defaultPort

        if let fps = sharedDefaults?.integer(forKey: "videoFps"), fps > 0 {
            targetFps = Int32(fps)
        }
        if let bitrate = sharedDefaults?.integer(forKey: "videoBitrate"), bitrate > 0 {
            targetBitrate = Int32(bitrate)
        }

        // Record active lifecycle state for companion host app
        sharedDefaults?.set("RUNNING", forKey: "extension_status")
        sharedDefaults?.set(Int(streamingPort), forKey: "extension_active_port")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "extension_start_time")
        sharedDefaults?.set("INITIALIZING", forKey: "extension_socket_state")
        sharedDefaults?.synchronize()

        NSLog("[AppleCastExtension] Target streaming port: %d (FPS: %d, Bitrate: %d bps)", streamingPort, targetFps, targetBitrate)

        // Bind BSD TCP server to receive usbmuxd tunnel
        startLocalTcpServer(port: streamingPort)
    }

    override func broadcastPaused() {
        NSLog("[AppleCastExtension] broadcastPaused invoked")
    }

    override func broadcastResumed() {
        NSLog("[AppleCastExtension] broadcastResumed invoked")
    }

    override func broadcastFinished() {
        NSLog("[AppleCastExtension] >>> broadcastFinished invoked - shutting down")
        isBroadcasting = false
        sharedDefaults?.set("STOPPED", forKey: "extension_status")
        sharedDefaults?.set("STOPPED", forKey: "extension_socket_state")
        sharedDefaults?.synchronize()
        teardownSession()
    }

    // MARK: - Frame Processing Pipeline
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
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

            // Encode on dedicated queue with explicit autoreleasepool to drain CoreVideo buffers
            encodeQueue.async { [weak self] in
                autoreleasepool {
                    guard let self = self, self.isBroadcasting else { return }
                    if self.frameIndex == 0 {
                        NSLog("[AppleCastExtension] >>> First video CMSampleBuffer received from ReplayKit pipeline!")
                    }
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    self.handleVideoPixelBuffer(pixelBuffer, pts: pts)
                }
            }

        case .audioApp:
            let voiceMuted = sharedDefaults?.bool(forKey: "kGroupMirrorVoiceSwitch") ?? false
            if !voiceMuted {
                // Reserved for audio channel
            }
            break

        case .audioMic:
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
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(vmInfo.phys_footprint >> 20) // Bytes to Megabytes
    }

    private func scheduleMemoryRecoveryCheck() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if self.getPhysicalFootprintMB() <= 39 {
                self.isMemoryLocked = false
            } else {
                self.scheduleMemoryRecoveryCheck()
            }
        }
    }

    // MARK: - VideoToolbox Hardware Compression (Zero-Latency Setup)
    private func handleVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if compressionSession == nil {
            setupCompressionSession(for: pixelBuffer)
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

    private func setupCompressionSession(for pixelBuffer: CVPixelBuffer) {
        let rawWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let rawHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))

        // OpenTok / ReplayKit Jetsam 50MB Safeguard:
        // Modern iPhones capture at native 3x Retina (e.g. 2556x1179 or 2796x1290).
        // Encoding at full Retina allocates >40MB of hardware reference frames,
        // instantly exceeding the 50MB Jetsam kernel limit. Clamping maximum dimension
        // to 1600 allows VideoToolbox to hardware downscale with zero latency and keeps
        // memory usage strictly around 20-25MB.
        let maxDimension: Int32 = 1600
        var width = rawWidth
        var height = rawHeight

        if max(rawWidth, rawHeight) > maxDimension {
            if rawWidth > rawHeight {
                width = maxDimension
                height = Int32(Double(rawHeight) * Double(maxDimension) / Double(rawWidth))
            } else {
                height = maxDimension
                width = Int32(Double(rawWidth) * Double(maxDimension) / Double(rawHeight))
            }
        }
        // H.264 macroblock alignment (must be divisible by 2)
        width = (width / 2) * 2
        height = (height / 2) * 2

        NSLog("[AppleCastExtension] Initializing VideoToolbox session: input=%dx%d -> encoded=%dx%d (targetFps: %d, bitrate: %d bps)",
              rawWidth, rawHeight, width, height, targetFps, targetBitrate)

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        guard status == noErr, let session = compressionSession else {
            return
        }

        // 1. Low-latency real-time flags
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        // CRITICAL FOR ZERO LATENCY & MEMORY: Disable frame reordering (strictly eliminates B-frames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)

        // 2. Profile Level selection (Main for >=1080p, Baseline for <1080p)
        let profile = width >= 1920 ? kVTProfileLevel_H264_Main_AutoLevel : kVTProfileLevel_H264_Baseline_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC)

        // 3. Bitrate & Burst Limits (DataRateLimits clamps memory buffers during complex scenes)
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

    // MARK: - BSD Socket Server (Port from wxiosserverport)
    private func startLocalTcpServer(port: UInt16) {
        networkQueue.async { [weak self] in
            guard let self = self else { return }

            NSLog("[AppleCastExtension] Initializing TCP server socket on port %d...", port)

            self.serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if self.serverSocket < 0 {
                NSLog("[AppleCastExtension] FAILED to create server socket: errno=%d (%s)", errno, strerror(errno))
                self.sharedDefaults?.set("ERROR_SOCKET_CREATE", forKey: "extension_socket_state")
                self.sharedDefaults?.synchronize()
                return
            }

            var yes: Int32 = 1
            setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(self.serverSocket, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

            var serverAddr = sockaddr_in()
            serverAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            serverAddr.sin_family = sa_family_t(AF_INET)
            serverAddr.sin_port = port.bigEndian
            // Bind to INADDR_ANY (in_addr_t(0)) so usbmuxd daemon connects via loopback (127.0.0.1) or composite interface
            serverAddr.sin_addr.s_addr = in_addr_t(0)

            let bindRes = withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(self.serverSocket, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindRes < 0 {
                NSLog("[AppleCastExtension] FAILED to bind server socket to port %d: errno=%d (%s)", port, errno, strerror(errno))
                self.sharedDefaults?.set("ERROR_BIND_\(errno)", forKey: "extension_socket_state")
                self.sharedDefaults?.synchronize()
                close(self.serverSocket)
                self.serverSocket = -1
                return
            }

            if listen(self.serverSocket, 5) < 0 {
                NSLog("[AppleCastExtension] FAILED to listen on server socket: errno=%d (%s)", errno, strerror(errno))
                self.sharedDefaults?.set("ERROR_LISTEN_\(errno)", forKey: "extension_socket_state")
                self.sharedDefaults?.synchronize()
                close(self.serverSocket)
                self.serverSocket = -1
                return
            }

            NSLog("[AppleCastExtension] SUCCESS: TCP server listening on 0.0.0.0:%d", port)
            self.sharedDefaults?.set("LISTENING", forKey: "extension_socket_state")
            self.sharedDefaults?.synchronize()

            // Connection Accept Loop
            while self.isBroadcasting {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

                let client = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        accept(self.serverSocket, saPtr, &addrLen)
                    }
                }

                if client >= 0 {
                    var flag: Int32 = 1
                    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))

                    self.socketLock.lock()
                    if self.clientSocket >= 0 {
                        close(self.clientSocket)
                    }
                    self.clientSocket = client
                    self.socketLock.unlock()

                    NSLog("[AppleCastExtension] SUCCESS: Windows client connected to port %d via usbmuxd tunnel!", port)
                    self.sharedDefaults?.set("CLIENT_CONNECTED", forKey: "extension_socket_state")
                    self.sharedDefaults?.synchronize()
                } else if self.isBroadcasting {
                    NSLog("[AppleCastExtension] accept returned errno=%d", errno)
                }
            }
            NSLog("[AppleCastExtension] Server accept loop terminated.")
        }
    }

    // MARK: - RFC 2326 Interleaved RTP Packet Packaging
    fileprivate func sendEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard clientSocket >= 0 else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        // Check if sample buffer contains an IDR Keyframe
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let firstAttachment = attachments.first {
            isKeyframe = !(firstAttachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else {
            isKeyframe = false
        }

        let ptsSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let pts90kHz = UInt32(ptsSeconds * 90000.0)

        // If IDR keyframe, extract and send SPS and PPS parameter sets first
        if isKeyframe {
            sendParameterSets(formatDesc: formatDesc, pts: pts90kHz)
        }

        // Extract elementary slice NALUs from AVCC block buffer
        var bufferOffset: size_t = 0
        var totalLength: size_t = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let rawBytes = dataPointer else { return }

        while bufferOffset < totalLength - 4 {
            // Read 4-byte Big-Endian NAL length
            var naluLengthBE: UInt32 = 0
            memcpy(&naluLengthBE, rawBytes.advanced(by: bufferOffset), 4)
            let naluLength = Int(UInt32(bigEndian: naluLengthBE))
            bufferOffset += 4

            if bufferOffset + naluLength > totalLength {
                break
            }

            let naluBytes = rawBytes.advanced(by: bufferOffset)
            let isLastSlice = (bufferOffset + naluLength >= totalLength)

            sendRtpInterleavedPacket(
                naluPointer: UnsafeRawPointer(naluBytes),
                naluLength: naluLength,
                pts: pts90kHz,
                isMarker: isLastSlice
            )

            bufferOffset += naluLength
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
        let rtpPayloadSize = 12 + naluLength
        guard rtpPayloadSize <= 0xFFFF else { return }

        rtpSequenceNumber = rtpSequenceNumber &+ 1

        // 4-byte RFC 2326 Interleaved Header: '$' (0x24) | Channel (0x00) | 16-bit BE Length
        var packetData = Data(capacity: 4 + rtpPayloadSize)
        packetData.append(rtpMagicByte)
        packetData.append(rtpChannelVideo)
        let payloadLenBE = UInt16(rtpPayloadSize).bigEndian
        withUnsafeBytes(of: payloadLenBE) { packetData.append(contentsOf: $0) }

        // 12-byte RTP Header
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

        // Elementary NAL Unit Body
        packetData.append(naluPointer.assumingMemoryBound(to: UInt8.self), count: naluLength)

        // Send over TCP virtual tunnel
        socketLock.lock()
        defer { socketLock.unlock() }

        if clientSocket >= 0 {
            packetData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var sentBytes = 0
                let totalBytes = rawBuffer.count
                while sentBytes < totalBytes {
                    let res = write(self.clientSocket, baseAddress.advanced(by: sentBytes), totalBytes - sentBytes)
                    if res <= 0 {
                        close(self.clientSocket)
                        self.clientSocket = -1
                        break
                    }
                    sentBytes += res
                }
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

/// Objective-C runtime alias ensuring that both "AppleCastExtension.SampleHandler"
/// and "@objc(SampleHandler)" resolve in NSClassFromString / ReplayKit plugin loader.
@objc(SampleHandler)
class DirectSampleHandler: SampleHandler {}
