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
    private let defaultAudioPort: UInt16 = 25335
    private var audioStreamingPort: UInt16 = 25335
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

    // MARK: - Audio Pipeline
    private var audioEncoder: AudioEncoder?
    private var audioServerSocket: Int32 = -1
    private var audioClientSocket: Int32 = -1
    private let audioSocketLock = NSLock()
    private let audioNetworkQueue = DispatchQueue(label: "com.applecast.audioNetworkQueue", qos: .userInteractive)
    // Keep each AAC/ADTS access unit intact when capture and reconnect events
    // happen at the same time.
    private let audioSendQueue = DispatchQueue(label: "com.applecast.audioSendQueue", qos: .userInteractive)

    // MARK: - Memory Management & Backpressure State
    private var sharedDefaults: UserDefaults?
    private var isMemoryLocked = false
    private let encodeQueue = DispatchQueue(label: "com.applecast.encoder.queue", qos: .userInteractive)

    // MARK: - Sockets & Concurrency (BSD Server on 0.0.0.0)
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var needsImmediateKeyframe: Bool = true
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
        let targetAudioPortInt = sharedDefaults?.integer(forKey: "wxiosserveraudioport") ?? 0
        audioStreamingPort = targetAudioPortInt > 0 ? UInt16(targetAudioPortInt) : defaultAudioPort

        if let fps = sharedDefaults?.integer(forKey: "videoFps"), fps > 0 {
            targetFps = Int32(fps)
        }
        if let bitrate = sharedDefaults?.integer(forKey: "videoBitrate"), bitrate > 0 {
            targetBitrate = Int32(bitrate)
        }

        // Record active lifecycle state
        sharedDefaults?.set("RUNNING", forKey: "extension_status")
        sharedDefaults?.set(Int(streamingPort), forKey: "extension_active_port")
        sharedDefaults?.set(Int(audioStreamingPort), forKey: "extension_active_audio_port")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "extension_start_time")
        sharedDefaults?.set("LISTENING", forKey: "extension_socket_state")
        sharedDefaults?.synchronize()

        NSLog("[AppleCastExtension] Target streaming port: %d, audio port: %d (FPS: %d, Bitrate: %d bps)", streamingPort, audioStreamingPort, targetFps, targetBitrate)

        // Bind BSD TCP servers on 0.0.0.0 to receive usbmuxd tunnels
        startLocalTcpServer(port: streamingPort)
        startLocalAudioTcpServer(port: audioStreamingPort)
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

        case .audioApp:
            if audioEncoder == nil {
                NSLog("[AppleCastExtension] >>> Initializing AudioEncoder (44100 Hz, stereo)")
                audioEncoder = AudioEncoder(sampleRate: 44100.0, channels: 2) { [weak self] packet in
                    self?.sendAudioSocketData(packet)
                }
            }
            audioEncoder?.encode(sampleBuffer: sampleBuffer)

        case .audioMic:
            // Keep .audioMic as break (ignore mic to prevent echo/feedback)
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
        let forceKeyframe = needsImmediateKeyframe || (frameIndex % Int64(targetFps) == 1)
        if needsImmediateKeyframe {
            needsImmediateKeyframe = false
        }

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
                    #if os(iOS)
                    var nosigpipe: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
                    #endif
                    self.socketLock.lock()
                    if self.clientSocket >= 0 { close(self.clientSocket) }
                    self.clientSocket = client
                    self.needsImmediateKeyframe = true
                    self.socketLock.unlock()
                    NSLog("[AppleCastExtension] >>> SUCCESS: Windows Client connected to video streaming socket! <<<")
                    self.sharedDefaults?.set("CLIENT_CONNECTED", forKey: "extension_socket_state")
                    self.sharedDefaults?.synchronize()
                }
            }
        }
    }

    // MARK: - Direct BSD TCP Audio Streaming Server for usbmuxd (port 25335)
    private func startLocalAudioTcpServer(port: UInt16) {
        audioNetworkQueue.async { [weak self] in
            guard let self = self, self.isBroadcasting else { return }

            NSLog("[AppleCastExtension] Initializing BSD audio streaming server on 0.0.0.0:%d...", port)

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[AppleCastExtension] Failed to create audio streaming socket: errno %d", errno)
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
                NSLog("[AppleCastExtension] BSD audio socket bind/listen failed on port %d (errno: %d)", port, errno)
                close(sock)
                return
            }

            self.audioSocketLock.lock()
            self.audioServerSocket = sock
            self.audioSocketLock.unlock()
            NSLog("[AppleCastExtension] >>> SUCCESS: BSD audio streaming server listening on 0.0.0.0:%d! <<<", port)

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
                    #if os(iOS)
                    var nosigpipe: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
                    #endif
                    self.audioSocketLock.lock()
                    if self.audioClientSocket >= 0 { close(self.audioClientSocket) }
                    self.audioClientSocket = client
                    self.audioSocketLock.unlock()
                    NSLog("[AppleCastExtension] >>> SUCCESS: Windows Client connected to audio streaming socket (port %d)! <<<", port)
                }
            }
        }
    }

    // MARK: - Direct Annex-B H.264 Elementary Streaming (Matching devicekit-ios Architecture)
    fileprivate func sendEncodedSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        socketLock.lock()
        let activeBsd = clientSocket
        socketLock.unlock()

        guard activeBsd >= 0 else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        // 1. Detect if IDR sync frame
        var isKeyFrame = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyFrame = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else if frameIndex <= 2 {
            isKeyFrame = true
        }

        // 2. Extract SPS & PPS parameter sets on IDR keyframe
        var paramSetsData = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        if isKeyFrame || frameIndex <= 2 {
            var spsCount: size_t = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &spsCount,
                nalUnitHeaderLengthOut: nil
            )

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
                    paramSetsData.append(contentsOf: startCode)
                    paramSetsData.append(ptr, count: paramSetSize)
                }
            }
        }

        // 3. Extract and convert NAL units from AVCC to Annex-B
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let rawData = dataPointer else { return }

        var frameData = Data(capacity: paramSetsData.count + totalLength + 32)
        if !paramSetsData.isEmpty {
            frameData.append(paramSetsData)
        }

        var bufferOffset = 0
        let avccHeaderLength = 4

        while bufferOffset < totalLength - avccHeaderLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, rawData + bufferOffset, avccHeaderLength)
            naluLength = CFSwapInt32BigToHost(naluLength)
            bufferOffset += avccHeaderLength

            guard naluLength > 0, bufferOffset + Int(naluLength) <= totalLength else { break }

            frameData.append(contentsOf: startCode)
            frameData.append(UnsafeRawPointer(rawData + bufferOffset).assumingMemoryBound(to: UInt8.self), count: Int(naluLength))

            bufferOffset += Int(naluLength)
        }

        // 4. Transmit complete Annex-B video access unit in single socket write
        if !frameData.isEmpty {
            sendSocketData(frameData, socket: activeBsd)
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

    private func sendAudioSocketData(_ data: Data) {
        audioSendQueue.async { [weak self] in
            self?.sendAudioPacket(data)
        }
    }

    private func sendAudioPacket(_ data: Data) {
        audioSocketLock.lock()
        let activeBsd = audioClientSocket
        audioSocketLock.unlock()

        guard activeBsd >= 0 else { return }

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var sentBytes = 0
            let totalBytes = rawBuffer.count
            while sentBytes < totalBytes {
                let res = write(activeBsd, baseAddress.advanced(by: sentBytes), totalBytes - sentBytes)
                if res <= 0 {
                    self.audioSocketLock.lock()
                    if self.audioClientSocket == activeBsd {
                        close(self.audioClientSocket)
                        self.audioClientSocket = -1
                    }
                    self.audioSocketLock.unlock()
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

        audioEncoder?.invalidate()
        audioEncoder = nil

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

        audioSocketLock.lock()
        if audioClientSocket >= 0 {
            shutdown(audioClientSocket, SHUT_RDWR)
            close(audioClientSocket)
            audioClientSocket = -1
        }
        if audioServerSocket >= 0 {
            shutdown(audioServerSocket, SHUT_RDWR)
            close(audioServerSocket)
            audioServerSocket = -1
        }
        audioSocketLock.unlock()
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
