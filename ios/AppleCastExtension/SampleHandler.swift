import ReplayKit
import VideoToolbox
import Darwin

/// ReplayKit 2 Screen Broadcast Extension (Transmitter Core)
/// Captures iOS display surfaces, compresses via VideoToolbox hardware encoder (Zero B-Frames),
/// and streams RFC 2326 Interleaved RTP packets over local loopback TCP socket (127.0.0.1:15333) tunneled via usbmuxd.
class SampleHandler: RPBroadcastSampleHandler {

    // Architecture Specifications (brain.md Blueprint)
    private let streamingPort: UInt16 = 15333
    private let targetFps: Int32 = 60
    private let targetBitrate: Int = 15_000_000 // 15 Mbps
    private let rtpMagicByte: UInt8 = 0x24       // '$'
    private let rtpChannelVideo: UInt8 = 0x00
    private let rtpPayloadType: UInt8 = 96       // Dynamic H.264
    private let ssrcId: UInt32 = 0x11223344

    // VideoToolbox Pipeline
    private var compressionSession: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var rtpSequenceNumber: UInt16 = 0

    // Sockets & Concurrency
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private let socketLock = NSLock()
    private let networkQueue = DispatchQueue(label: "com.applecast.networkQueue", qos: .userInteractive)
    private var isBroadcasting = false

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        isBroadcasting = true
        frameIndex = 0
        rtpSequenceNumber = 0

        // Step 1: Bind BSD TCP server on 127.0.0.1:15333 to receive usbmuxd tunnel
        startLocalTcpServer()
    }

    override func broadcastPaused() {
        // Paused state
    }

    override func broadcastResumed() {
        // Resumed state
    }

    override func broadcastFinished() {
        isBroadcasting = false
        teardownSession()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting else { return }

        switch sampleBufferType {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            handleVideoPixelBuffer(pixelBuffer, pts: pts)

        case .audioApp:
            // Reserved for audio channel (0x01)
            break

        case .audioMic:
            break

        @unknown default:
            break
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
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

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

        // Section 4 Blueprint: Configure Real-Time Zero-Latency Encoding
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: targetFps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFps as CFNumber)

        // CRITICAL FOR ZERO LATENCY: Disable frame reordering (eliminates B-frame buffering latency)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    // MARK: - BSD Socket Server (Port 15333)

    private func startLocalTcpServer() {
        networkQueue.async { [weak self] in
            guard let self = self else { return }

            self.serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            if self.serverSocket < 0 {
                return
            }

            var yes: Int32 = 1
            setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(self.serverSocket, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))

            var serverAddr = sockaddr_in()
            serverAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            serverAddr.sin_family = sa_family_t(AF_INET)
            serverAddr.sin_port = self.streamingPort.bigEndian
            serverAddr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let bindRes = withUnsafePointer(to: &serverAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    bind(self.serverSocket, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindRes < 0 {
                close(self.serverSocket)
                self.serverSocket = -1
                return
            }

            if listen(self.serverSocket, 5) < 0 {
                close(self.serverSocket)
                self.serverSocket = -1
                return
            }

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
                }
            }
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
            close(clientSocket)
            clientSocket = -1
        }
        if serverSocket >= 0 {
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
