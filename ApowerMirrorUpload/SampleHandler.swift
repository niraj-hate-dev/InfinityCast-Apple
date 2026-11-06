//  SampleHandler.swift
//  ApowerMirrorUpload / AppleCast
//
//  ReplayKit Broadcast Upload Extension
//  - Direct BSD TCP Server on Port 25334 (Video) & Port 25335 (Audio) for Zero Background Freeze
//  - Loopback IPC Client to 127.0.0.1:8888 (Video)
//

import ReplayKit
import VideoToolbox
import CoreMedia
import Darwin

@objcMembers
public class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Constants
    private static let kIpcPort: UInt16 = 8888
    private static let kDirectVideoPort: UInt16 = 25334
    private static let kDirectAudioPort: UInt16 = 25335
    private static let kStopNotification = "com.apowermirror.broadcast.StopBroadcast"
    private static let kForceKeyframeNotification = "com.apowermirror.forceKeyframe"
    private static let kUpdateSettingsNotification = "com.apowermirror.updateEncoderSettings"
    private static let kAppGroupId = "group.apowersoft.mirror"

    // MARK: - Encoders & State
    private var videoEncoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private var isBroadcasting = false
    private var pendingKeyframeRequest = true
    private var audioFrameCount: Int = 0
    private var lastAudioReceivedTime: CFTimeInterval = 0
    private var silentAudioTimer: DispatchSourceTimer?

    // Direct Extension Server Sockets (Never suspended when Main App is in background!)
    private var directVideoListenSock: Int32 = -1
    private var directVideoClients: [Int32] = []
    private let directVideoLock = NSLock()

    private var directAudioListenSock: Int32 = -1
    private var directAudioClients: [Int32] = []
    private let directAudioLock = NSLock()

    // Cached SPS/PPS Header for late-joining direct clients
    private var latestKeyFrameHeader: Data?
    private let headerLock = NSLock()

    // Outbound Main App Video IPC Socket (8888)
    private var bsdClientSocket: Int32 = -1
    private let socketLock = NSLock()
    private var isVideoConnecting = false
    private let videoConnectLock = NSLock()

    private struct VideoQueueItem {
        let data: Data
        let isKeyFrame: Bool
    }
    private var videoPacketQueue: [VideoQueueItem] = []
    private let videoPacketQueueLock = NSLock()

    // MARK: - Mach Memory Throttle Thresholds (Jetsam Protection)
    private var videoFrameCount: Int = 0
    private var isMemoryLocked = false
    private let kMemoryLockThresholdMB: Double = 46.0
    private let kMemoryUnlockThresholdMB: Double = 42.0
    private var consecutiveMemoryLockedFrames = 0

    private let networkQueue = DispatchQueue(label: "com.apowermirror.upload.network", qos: .userInteractive)
    private var targetFps: Int32 = 60
    private var targetBitrate: Int32 = 8_000_000
    private var targetShortSide: Int32 = 720

    public override init() {
        super.init()
    }

    // MARK: - ReplayKit Audio Sample Handling

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        self.lastAudioReceivedTime = CACurrentMediaTime()

        if self.audioEncoder == nil {
            self.audioEncoder = AudioEncoder(sampleRate: 48000.0, channels: 2) { [weak self] packet in
                self?.sendToDirectAudioClients(packet)
            }
        }
        self.audioEncoder?.encode(sampleBuffer: sampleBuffer)
    }

    // MARK: - Comfort Noise / Continuous Audio Carrier (Port 25335)

    private func startComfortNoiseGenerator() {
        stopComfortNoiseGenerator()
        lastAudioReceivedTime = CACurrentMediaTime()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .default))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5) // Low-overhead heartbeat every 500ms
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isBroadcasting else { return }

            // Only generate comfort silence when a desktop client is connected to port 25335
            self.directAudioLock.lock()
            let hasClients = !self.directAudioClients.isEmpty
            self.directAudioLock.unlock()
            guard hasClients else { return }

            let now = CACurrentMediaTime()
            if now - self.lastAudioReceivedTime >= 0.5 {
                if self.audioEncoder == nil {
                    self.audioEncoder = AudioEncoder(sampleRate: 48000.0, channels: 2) { [weak self] packet in
                        self?.sendToDirectAudioClients(packet)
                    }
                }
                let silentPcm = Data(count: 4096)
                self.audioEncoder?.encodePCM(silentPcm)
            }
        }
        silentAudioTimer = timer
        timer.resume()
    }

    private func stopComfortNoiseGenerator() {
        silentAudioTimer?.cancel()
        silentAudioTimer = nil
    }

    // MARK: - ReplayKit Lifecycle

    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        super.broadcastStarted(withSetupInfo: setupInfo)
        isBroadcasting = true

        NSLog("[SampleHandler] ReplayKit broadcast started -> Launching direct servers & IPC")

        // Setup Darwin receivers first so kernel notify state is read immediately
        setupDarwinStopReceiver()
        setupDarwinKeyframeReceiver()
        setupDarwinSettingsReceiver()

        // Fallback to persisted encoder preferences from App Group / Wormhole if notify state empty
        let settings = readEncoderSettings()
        if targetShortSide <= 0 { targetShortSide = settings.shortSide }
        if targetBitrate <= 0 { targetBitrate = settings.bitrate }
        if targetFps <= 0 { targetFps = settings.fps }

        notifyMainApp(event: "BroadcastStarted")

        // 1. Start Direct Extension Servers (25334 Video, 25335 Audio) - immune to Main App background suspension!
        startDirectVideoServer(port: Self.kDirectVideoPort)
        startDirectAudioServer(port: Self.kDirectAudioPort)
        startComfortNoiseGenerator()
    }

    public override func broadcastPaused() {
        super.broadcastPaused()
        notifyMainApp(event: "PauseVideo")
    }

    public override func broadcastResumed() {
        super.broadcastResumed()
        pendingKeyframeRequest = true
        videoEncoder?.forceKeyFrame()
        notifyMainApp(event: "ResumeVideo")
    }

    public override func broadcastFinished() {
        super.broadcastFinished()
        isBroadcasting = false

        videoEncoder?.invalidate()
        videoEncoder = nil
        videoPacketQueueLock.lock()
        videoPacketQueue.removeAll()
        videoPacketQueueLock.unlock()

        audioEncoder?.invalidate()
        audioEncoder = nil

        removeDarwinKeyframeReceiver()
        removeDarwinSettingsReceiver()
        closeSocket()
        stopComfortNoiseGenerator()
        stopDirectServers()

        notifyMainApp(event: "Finish")
    }

    // MARK: - Frame Processing

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting else { return }

        autoreleasepool {
            switch sampleBufferType {
            case .video:
                self.videoFrameCount += 1
                if self.videoFrameCount <= 5 || self.videoFrameCount % 300 == 0 {
                    NSLog("[SampleHandler] Received video sample #%d", self.videoFrameCount)
                }

                if videoEncoder == nil {
                    if targetShortSide <= 0 || targetBitrate <= 0 {
                        let settings = readEncoderSettings()
                        if targetShortSide <= 0 { targetShortSide = settings.shortSide }
                        if targetBitrate <= 0 { targetBitrate = settings.bitrate }
                        if targetFps <= 0 { targetFps = settings.fps }
                    }
                    videoEncoder = VideoEncoder(bitrate: targetBitrate, fps: targetFps, targetShortSide: targetShortSide) { [weak self] (packet, isKeyFrame, _) in
                        self?.enqueueVideoFrame(packet, isKeyFrame: isKeyFrame)
                    }
                    if pendingKeyframeRequest {
                        videoEncoder?.forceKeyFrame()
                        pendingKeyframeRequest = false
                    }
                } else if pendingKeyframeRequest {
                    videoEncoder?.forceKeyFrame()
                    pendingKeyframeRequest = false
                }

                var orientation: CGImagePropertyOrientation = .up
                if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                    orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) ?? .up
                }

                videoEncoder?.encode(sampleBuffer: sampleBuffer, orientation: orientation)

            case .audioApp:
                self.audioFrameCount += 1
                if self.audioFrameCount <= 5 || self.audioFrameCount % 200 == 0 {
                    NSLog("[SampleHandler] Received audioApp buffer #%d", self.audioFrameCount)
                }
                self.handleAudioSampleBuffer(sampleBuffer, sampleBufferType: .audioApp)

            case .audioMic:
                // Ignore microphone audio during screen mirror to prevent format resets and echo (matching commit 41bf9d1)
                break

            @unknown default:
                break
            }
        }
    }

    // MARK: - Direct Extension TCP Servers (Ports 25334 & 25335)

    private func startDirectVideoServer(port: UInt16) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { return }

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = in_addr_t(0)

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes >= 0, listen(sock, 5) >= 0 else {
                NSLog("[SampleHandler] Failed to bind direct video server on port %d, error: %d (%s)", port, errno, strerror(errno))
                close(sock)
                return
            }

            self.directVideoLock.lock()
            self.directVideoListenSock = sock
            self.directVideoLock.unlock()
            NSLog("[SampleHandler] Direct Video Server listening on port %d", port)

            while self.isBroadcasting && self.directVideoListenSock >= 0 {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(sock, $0, &addrLen)
                    }
                }
                guard clientFd >= 0 else { break }

                var noSigpipe: Int32 = 1
                setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                var noDelay: Int32 = 1
                setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
                var sndBuf: Int32 = 1024 * 1024 // 1 MB kernel socket buffer
                if setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                    sndBuf = 512 * 1024
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
                }
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                self.directVideoLock.lock()
                self.directVideoClients.append(clientFd)
                self.directVideoLock.unlock()

                self.pendingKeyframeRequest = true
                self.videoEncoder?.forceKeyFrame()
                NSLog("[SampleHandler] Desktop connected directly to Extension Video port %d", port)
                self.broadcastStreamMetrics()
                self.listenForClientCommands(clientFd: clientFd)
            }
        }
    }

    // MARK: - Incoming Control Socket Listener (Port 25334)

    func broadcastStreamMetrics() {
        let presetTag: String
        switch targetShortSide {
        case 240: presetTag = "240p"
        case 360: presetTag = "360p"
        case 480: presetTag = "480p"
        case 544: presetTag = "544p"
        case 720: presetTag = "720p"
        case 1080: presetTag = "1080p"
        case 1440: presetTag = "2K"
        case 2160: presetTag = "4K"
        default: presetTag = "\(targetShortSide)p"
        }

        let mbps = Double(targetBitrate) / 1_000_000.0
        NSLog("[SampleHandler] Stream configuration: %dp (%@) @ %.2f Mbps, %d fps", targetShortSide, presetTag, mbps, targetFps)
    }

    private func listenForClientCommands(clientFd: Int32) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while let self = self, self.isBroadcasting {
                let bytesRead = recv(clientFd, &buffer, buffer.count - 1, 0)
                guard bytesRead > 0 else { break }
                buffer[bytesRead] = 0
                if let str = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                    self.handleIncomingControlMessage(str)
                }
            }
        }
    }

    private func handleIncomingControlMessage(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = json["cmd"] as? String else { continue }

            if cmd == "SET_CONFIG" {
                var newBitrate = targetBitrate
                var newShortSide = targetShortSide
                var newFps = targetFps

                if let b = json["bitrate"] as? Int, b > 0 { newBitrate = Int32(b) }
                if let s = json["shortSide"] as? Int, s > 0 { newShortSide = Int32(s) }
                if let f = json["fps"] as? Int, f > 0 { newFps = Int32(f) }

                NSLog("[SampleHandler] Received SET_CONFIG via TCP -> %dp @ %d bps, %d fps", newShortSide, newBitrate, newFps)
                targetBitrate = newBitrate
                targetShortSide = newShortSide
                targetFps = newFps
                videoEncoder?.updateConfiguration(bitrate: newBitrate, targetShortSide: newShortSide, fps: newFps)
                broadcastStreamMetrics()
            } else if cmd == "FORCE_KEYFRAME" || cmd == "PING" {
                broadcastStreamMetrics()
                videoEncoder?.forceKeyFrame()
            }
        }
    }

    private func startDirectAudioServer(port: UInt16) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { return }

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = in_addr_t(0)

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes >= 0, listen(sock, 5) >= 0 else {
                close(sock)
                return
            }

            self.directAudioLock.lock()
            self.directAudioListenSock = sock
            self.directAudioLock.unlock()
            NSLog("[SampleHandler] Direct Audio Server listening on port %d", port)

            while self.isBroadcasting && self.directAudioListenSock >= 0 {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(sock, $0, &addrLen)
                    }
                }
                guard clientFd >= 0 else { break }

                var noSigpipe: Int32 = 1
                setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                var noDelay: Int32 = 1
                setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
                var sndBuf: Int32 = 16384 // Jitter-resilient low-latency 16KB send buffer
                setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                self.directAudioLock.lock()
                self.directAudioClients.append(clientFd)
                self.directAudioLock.unlock()
                NSLog("[SampleHandler] Desktop connected directly to Extension Audio port %d", port)

                // Prime initial comfort silence immediately upon desktop connection so transport is verified instantly
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    guard let self = self, self.isBroadcasting else { return }
                    if self.audioEncoder == nil {
                        self.audioEncoder = AudioEncoder(sampleRate: 48000.0, channels: 2) { [weak self] packet in
                            self?.sendToDirectAudioClients(packet)
                        }
                    }
                    let initialSilence = Data(count: 4096)
                    self.audioEncoder?.encodePCM(initialSilence)
                }
            }
        }
    }

    private func stopDirectServers() {
        directVideoLock.lock()
        if directVideoListenSock >= 0 { close(directVideoListenSock); directVideoListenSock = -1 }
        directVideoClients.forEach { close($0) }
        directVideoClients.removeAll()
        directVideoLock.unlock()

        directAudioLock.lock()
        if directAudioListenSock >= 0 { close(directAudioListenSock); directAudioListenSock = -1 }
        directAudioClients.forEach { close($0) }
        directAudioClients.removeAll()
        directAudioLock.unlock()
    }

    // MARK: - Video & Audio Dispatch

    private func enqueueVideoFrame(_ data: Data, isKeyFrame: Bool) {
        if isKeyFrame {
            headerLock.lock()
            latestKeyFrameHeader = data
            headerLock.unlock()
        }
        // Prepend 4-byte little-endian length prefix for 100% deterministic framing over TCP
        var frameLen = UInt32(data.count).littleEndian
        var framedData = Data(bytes: &frameLen, count: 4)
        framedData.append(data)

        // Direct zero-latency dispatch straight to connected desktop clients (matching Audio architecture)
        sendToDirectVideoClients(framedData)
    }

    private var videoPacketsDispatched: Int = 0

    private func sendToDirectVideoClients(_ data: Data) {
        directVideoLock.lock()
        let clients = directVideoClients
        directVideoLock.unlock()
        guard !clients.isEmpty else { return }

        self.videoPacketsDispatched += 1
        if self.videoPacketsDispatched <= 5 || self.videoPacketsDispatched % 300 == 0 {
            NSLog("[SampleHandler] Dispatched video frame #%d (%d bytes) to %d direct client(s)", self.videoPacketsDispatched, data.count, clients.count)
        }

        data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress else { return }
            var dead: [Int32] = []
            for fd in clients {
                var totalSent = 0
                while totalSent < data.count {
                    let sent = send(fd, basePtr.advanced(by: totalSent), data.count - totalSent, 0)
                    if sent > 0 {
                        totalSent += sent
                    } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let pr = poll(&pfd, 1, 5) // Wait up to 5ms for socket buffer to drain
                        if pr < 0 && errno != EINTR {
                            dead.append(fd)
                            break
                        }
                        continue
                    } else {
                        // Fatal socket failure (e.g. EPIPE, ECONNRESET): peer disconnected
                        dead.append(fd)
                        break
                    }
                }
            }
            if !dead.isEmpty {
                directVideoLock.lock()
                directVideoClients.removeAll { dead.contains($0) }
                directVideoLock.unlock()
                dead.forEach { close($0) }
                self.videoEncoder?.forceKeyFrame()
                NSLog("[SampleHandler] Closed %d dead video client socket(s)", dead.count)
            }
        }
    }

    private var audioPacketsDispatched: Int = 0

    private func sendToDirectAudioClients(_ data: Data) {
        directAudioLock.lock()
        let clients = directAudioClients
        directAudioLock.unlock()
        guard !clients.isEmpty else { return }

        self.audioPacketsDispatched += 1
        if self.audioPacketsDispatched <= 5 || self.audioPacketsDispatched % 200 == 0 {
            NSLog("[SampleHandler] Dispatched audio packet #%d (%d bytes) to %d direct client(s)", self.audioPacketsDispatched, data.count, clients.count)
        }

        data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress else { return }
            var dead: [Int32] = []
            for fd in clients {
                var totalSent = 0
                while totalSent < data.count {
                    let sent = send(fd, basePtr.advanced(by: totalSent), data.count - totalSent, 0)
                    if sent > 0 {
                        totalSent += sent
                    } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let pr = poll(&pfd, 1, 5) // Wait up to 5ms for socket buffer to drain
                        if pr < 0 && errno != EINTR {
                            dead.append(fd)
                            break
                        }
                        continue
                    } else {
                        dead.append(fd)
                        break
                    }
                }
            }
            if !dead.isEmpty {
                directAudioLock.lock()
                directAudioClients.removeAll { dead.contains($0) }
                directAudioLock.unlock()
                dead.forEach { close($0) }
            }
        }
    }

    // MARK: - Outbound Main App Video IPC (8888)

    private func connectToMainAppIPC() {
        videoConnectLock.lock()
        if isVideoConnecting { videoConnectLock.unlock(); return }
        isVideoConnecting = true
        videoConnectLock.unlock()

        networkQueue.async { [weak self] in
            guard let self = self, self.isBroadcasting else {
                self?.videoConnectLock.lock()
                self?.isVideoConnecting = false
                self?.videoConnectLock.unlock()
                return
            }

            self.socketLock.lock()
            if self.bsdClientSocket >= 0 { close(self.bsdClientSocket); self.bsdClientSocket = -1 }
            self.socketLock.unlock()

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                self.videoConnectLock.lock()
                self.isVideoConnecting = false
                self.videoConnectLock.unlock()
                return
            }

            var noSigpipe: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            var noDelay: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            var sndBuf: Int32 = 2 * 1024 * 1024
            setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 0, tv_usec: 150_000) // 150ms max timeout so suspended Main App never blocks Extension!
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = SampleHandler.kIpcPort.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            self.videoConnectLock.lock()
            self.isVideoConnecting = false
            self.videoConnectLock.unlock()

            if res == 0 {
                self.socketLock.lock()
                self.bsdClientSocket = sock
                self.socketLock.unlock()
                self.pendingKeyframeRequest = true
                self.videoEncoder?.forceKeyFrame()
            } else {
                close(sock)
                if self.isBroadcasting {
                    self.networkQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.connectToMainAppIPC()
                    }
                }
            }
        }
    }

    private func sendVideoDataToMainApp(_ data: Data) {
        // If Desktop is connected directly to the Extension on port 25334, skip Main App IPC to save CPU & RAM!
        directVideoLock.lock()
        let hasDirectClients = !directVideoClients.isEmpty
        directVideoLock.unlock()
        if hasDirectClients { return }

        socketLock.lock()
        let sock = bsdClientSocket
        socketLock.unlock()
        guard sock >= 0 else {
            connectToMainAppIPC()
            return
        }

        data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = send(sock, basePtr.advanced(by: totalSent), data.count - totalSent, 0)
                if sent > 0 {
                    totalSent += sent
                } else {
                    closeSocket()
                    videoEncoder?.forceKeyFrame()
                    connectToMainAppIPC()
                    break
                }
            }
        }
    }

    private func closeSocket() {
        socketLock.lock()
        defer { socketLock.unlock() }
        if bsdClientSocket >= 0 { close(bsdClientSocket); bsdClientSocket = -1 }
    }

    // MARK: - Darwin Notifications & Mach Memory

    private func notifyMainApp(event: String) {
        let notificationName = "com.apowermirror.broadcast.\(event)" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName),
            nil,
            nil,
            true
        )
    }

    private func setupDarwinStopReceiver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let obs = observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(obs).takeUnretainedValue()
                let error = NSError(
                    domain: "com.apowermirror.ScreenShare",
                    code: -1,
                    userInfo: [NSLocalizedFailureReasonErrorKey: "Screen mirror broadcast stopped by user."]
                )
                handler.finishBroadcastWithError(error)
            },
            SampleHandler.kStopNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func setupDarwinKeyframeReceiver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
                handler.pendingKeyframeRequest = true
                handler.videoEncoder?.forceKeyFrame()
            },
            SampleHandler.kForceKeyframeNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func removeDarwinKeyframeReceiver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(SampleHandler.kForceKeyframeNotification as CFString), nil)
    }

    private func readEncoderSettings() -> (bitrate: Int32, shortSide: Int32, fps: Int32) {
        var bitrate: Int32 = 4_000_000
        var shortSide: Int32 = 720
        var fps: Int32 = 60

        // 1. Try App Group UserDefaults
        if let sharedDefaults = UserDefaults(suiteName: Self.kAppGroupId) {
            let b = sharedDefaults.integer(forKey: "kEncoderBitrate")
            let s = sharedDefaults.integer(forKey: "kEncoderShortSide")
            let f = sharedDefaults.integer(forKey: "kEncoderFps")
            if b > 0 { bitrate = Int32(b) }
            if s > 0 { shortSide = Int32(s) }
            if f > 0 { fps = Int32(f) }
        }

        // 2. Try App Group Shared File (Wormhole archive)
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.kAppGroupId) {
            let fileURL = containerURL.appendingPathComponent("wormhole").appendingPathComponent("encoderSettings.archive")
            if let data = try? Data(contentsOf: fileURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let b = json["bitrate"] as? Int, b > 0 { bitrate = Int32(b) }
                if let s = json["shortSide"] as? Int, s > 0 { shortSide = Int32(s) }
                if let f = json["fps"] as? Int, f > 0 { fps = Int32(f) }
            }
        }

        NSLog("[SampleHandler] Active encoder settings -> Bitrate: %d, ShortSide: %dp, FPS: %d", bitrate, shortSide, fps)
        return (bitrate, shortSide, fps)
    }

    private func setupDarwinSettingsReceiver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let resCallback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer, let cfName = name else { return }
            let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
            let nameStr = (cfName.rawValue as String)
            if let resStr = nameStr.components(separatedBy: ".").last, let res = Int32(resStr) {
                NSLog("[SampleHandler] Received Darwin SET_RES -> %dp", res)
                handler.targetShortSide = res
                handler.videoEncoder?.updateConfiguration(bitrate: handler.targetBitrate, targetShortSide: res, fps: handler.targetFps)
                handler.broadcastStreamMetrics()
            }
        }

        let bitCallback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer = observer, let cfName = name else { return }
            let handler = Unmanaged<SampleHandler>.fromOpaque(observer).takeUnretainedValue()
            let nameStr = (cfName.rawValue as String)
            if let bitStr = nameStr.components(separatedBy: ".").last, let bit = Int32(bitStr) {
                NSLog("[SampleHandler] Received Darwin SET_BITRATE -> %d bps", bit)
                handler.targetBitrate = bit
                handler.videoEncoder?.updateConfiguration(bitrate: bit, targetShortSide: handler.targetShortSide, fps: handler.targetFps)
                handler.broadcastStreamMetrics()
            }
        }

        let resNames = [
            "com.apowermirror.setRes.240", "com.apowermirror.setRes.360",
            "com.apowermirror.setRes.480", "com.apowermirror.setRes.544",
            "com.apowermirror.setRes.720", "com.apowermirror.setRes.1080",
            "com.apowermirror.setRes.1440", "com.apowermirror.setRes.2160"
        ]
        for n in resNames {
            CFNotificationCenterAddObserver(center, observer, resCallback, n as CFString, nil, .deliverImmediately)
        }

        let bitNames = [
            "com.apowermirror.setBitrate.1000000", "com.apowermirror.setBitrate.2000000",
            "com.apowermirror.setBitrate.4000000", "com.apowermirror.setBitrate.6000000",
            "com.apowermirror.setBitrate.8000000", "com.apowermirror.setBitrate.12000000",
            "com.apowermirror.setBitrate.16000000", "com.apowermirror.setBitrate.20000000"
        ]
        for n in bitNames {
            CFNotificationCenterAddObserver(center, observer, bitCallback, n as CFString, nil, .deliverImmediately)
        }
    }

    private func removeDarwinSettingsReceiver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let allNames = [
            "com.apowermirror.setRes.240", "com.apowermirror.setRes.360",
            "com.apowermirror.setRes.480", "com.apowermirror.setRes.544",
            "com.apowermirror.setRes.720", "com.apowermirror.setRes.1080",
            "com.apowermirror.setRes.1440", "com.apowermirror.setRes.2160",
            "com.apowermirror.setBitrate.1000000", "com.apowermirror.setBitrate.2000000",
            "com.apowermirror.setBitrate.4000000", "com.apowermirror.setBitrate.6000000",
            "com.apowermirror.setBitrate.8000000", "com.apowermirror.setBitrate.12000000",
            "com.apowermirror.setBitrate.16000000", "com.apowermirror.setBitrate.20000000"
        ]
        for n in allNames {
            CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(n as CFString), nil)
        }
    }

    private func getMemoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(info.phys_footprint) / (1024.0 * 1024.0)
        }
        return 0.0
    }
}
