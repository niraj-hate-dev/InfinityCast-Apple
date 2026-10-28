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
    private var targetBitrate: Int32 = 4_000_000

    public override init() {
        super.init()
    }

    // MARK: - ReplayKit Audio Sample Handling

    private func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        self.lastAudioReceivedTime = CACurrentMediaTime()

        if self.audioEncoder == nil {
            self.audioEncoder = AudioEncoder(sampleRate: 44100.0, channels: 2) { [weak self] packet in
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
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1) // 10 times a second
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isBroadcasting else { return }

            // Only generate comfort silence when a desktop client is connected to port 25335
            self.directAudioLock.lock()
            let hasClients = !self.directAudioClients.isEmpty
            self.directAudioLock.unlock()
            guard hasClients else { return }

            let now = CACurrentMediaTime()
            if now - self.lastAudioReceivedTime >= 0.25 {
                if self.audioEncoder == nil {
                    self.audioEncoder = AudioEncoder(sampleRate: 44100.0, channels: 2) { [weak self] packet in
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

        notifyMainApp(event: "BroadcastStarted")
        setupDarwinStopReceiver()
        setupDarwinKeyframeReceiver()

        // 1. Start Direct Extension Servers (25334 Video, 25335 Audio) - immune to Main App background suspension!
        startDirectVideoServer(port: Self.kDirectVideoPort)
        startDirectAudioServer(port: Self.kDirectAudioPort)
        startComfortNoiseGenerator()

        // 2. Also connect to Main App Video IPC (8888)
        connectToMainAppIPC()
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

                if videoEncoder == nil {
                    videoEncoder = VideoEncoder(bitrate: targetBitrate, fps: targetFps) { [weak self] (packet, isKeyFrame, _) in
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
                self.handleAudioSampleBuffer(sampleBuffer, sampleBufferType: .audioMic)

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
                var sndBuf: Int32 = 2 * 1024 * 1024
                setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                self.headerLock.lock()
                let cached = self.latestKeyFrameHeader
                self.headerLock.unlock()
                if let hdr = cached {
                    hdr.withUnsafeBytes { rawBuf in
                        if let base = rawBuf.baseAddress {
                            _ = send(clientFd, base, hdr.count, 0)
                        }
                    }
                }

                self.directVideoLock.lock()
                self.directVideoClients.append(clientFd)
                self.directVideoLock.unlock()

                self.pendingKeyframeRequest = true
                self.videoEncoder?.forceKeyFrame()
                NSLog("[SampleHandler] Desktop connected directly to Extension Video port %d", port)
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
                var sndBuf: Int32 = 512 * 1024
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
                        self.audioEncoder = AudioEncoder(sampleRate: 44100.0, channels: 2) { [weak self] packet in
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

        videoPacketQueueLock.lock()
        if videoPacketQueue.count >= 12 {
            if !isKeyFrame {
                videoPacketQueueLock.unlock()
                videoEncoder?.forceKeyFrame()
                return
            } else {
                videoPacketQueue.removeAll(where: { !$0.isKeyFrame })
            }
        }
        videoPacketQueue.append(VideoQueueItem(data: data, isKeyFrame: isKeyFrame))
        videoPacketQueueLock.unlock()

        triggerVideoQueueDrain()
    }

    private func triggerVideoQueueDrain() {
        networkQueue.async { [weak self] in
            guard let self = self, self.isBroadcasting else { return }

            while true {
                self.videoPacketQueueLock.lock()
                if self.videoPacketQueue.isEmpty {
                    self.videoPacketQueueLock.unlock()
                    break
                }
                let item = self.videoPacketQueue.removeFirst()
                self.videoPacketQueueLock.unlock()

                self.sendToDirectVideoClients(item.data)
                self.sendVideoDataToMainApp(item.data)
            }
        }
    }

    private func sendToDirectVideoClients(_ data: Data) {
        directVideoLock.lock()
        let clients = directVideoClients
        directVideoLock.unlock()
        guard !clients.isEmpty else { return }

        data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress else { return }
            var dead: [Int32] = []
            for fd in clients {
                var totalSent = 0
                var retries = 0
                while totalSent < data.count {
                    let sent = send(fd, basePtr.advanced(by: totalSent), data.count - totalSent, 0)
                    if sent > 0 {
                        totalSent += sent
                        retries = 0
                    } else if (errno == EAGAIN || errno == EWOULDBLOCK) && retries < 20 {
                        retries += 1
                        usleep(1000)
                    } else {
                        dead.append(fd)
                        self.videoEncoder?.forceKeyFrame()
                        break
                    }
                }
            }
            if !dead.isEmpty {
                directVideoLock.lock()
                directVideoClients.removeAll { dead.contains($0) }
                directVideoLock.unlock()
                dead.forEach { close($0) }
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
                var retries = 0
                while totalSent < data.count {
                    let sent = send(fd, basePtr.advanced(by: totalSent), data.count - totalSent, 0)
                    if sent > 0 {
                        totalSent += sent
                        retries = 0
                    } else if (errno == EAGAIN || errno == EWOULDBLOCK) && retries < 10 {
                        retries += 1
                        usleep(1000)
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
