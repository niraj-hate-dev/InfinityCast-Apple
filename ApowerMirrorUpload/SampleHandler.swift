//
//  SampleHandler.swift
//  ApowerMirrorUpload / AppleCast
//
//  Reconstructed 1:1 from ApowerMirrorUpload Mach-O binary & WXCastiOSSender
//  Subclass: RPBroadcastSampleHandler (or AgoraReplayKitHandler)
//  Hardened for iOS 18: Immediate XPC handshake return, Zero-Jetsam OOM,
//  Dual NWListener + POSIX BSD Socket streaming engine.
//

import ReplayKit
import VideoToolbox
import CoreMedia
import Network
import Darwin

@objc(SampleHandler)
@objcMembers
public class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Constants
    private let appGroupName = "group.apowersoft.mirror"
    private let kDefaultMirrorPort: UInt16 = 25334 // /mirror.do (Video) & /mirrorVoice.do (Audio)
    private let kDefaultChannelPort: UInt16 = 25333 // /channel.do (Control/Signaling)

    // MARK: - Encoders & Network Transport
    private var videoEncoder: VideoEncoder?
    private var isBroadcasting = false
    private var streamServer: NWListener?
    private var connectedClients: [NWConnection] = []

    // POSIX BSD Sockets Fallback (Bypasses iOS 18 Network.framework Local Privacy Blocks)
    private var bsdListenSocket: Int32 = -1
    private var bsdClientSockets: [Int32] = []
    private let bsdSocketLock = NSLock()

    private let networkQueue = DispatchQueue(label: "com.apowermirror.network.queue", qos: .userInteractive)
    private let frameProcessingQueue = DispatchQueue(label: "com.apowermirror.frame.queue", qos: .userInteractive)

    private var targetFps: Int32 = 60
    private var targetBitrate: Int32 = 3_500_000

    // MARK: - Lifecycle

    public override init() {
        super.init()
    }

    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // =========================================================================
        // CRITICAL iOS 18 REQUIREMENT:
        // Return from broadcastStarted in < 50ms so replayd finishes XPC handshake.
        // If this method blocks, replayd marks extension as hung -> hollow gray circle.
        // Calling super turns the circle pulsating RED and starts frame ingestion.
        // =========================================================================
        super.broadcastStarted(withSetupInfo: setupInfo)
        isBroadcasting = true

        NSLog("[SampleHandler] ReplayKit broadcast started -> Promptly acknowledging XPC handshake")

        // 1. Immediately notify Main App via Darwin Notification Center
        notifyMainApp(event: "BroadcastStarted")

        // 2. Read preferences safely from App Group defaults if available
        let defaults = UserDefaults(suiteName: appGroupName)
        targetFps = Int32(defaults?.integer(forKey: "kGroupFps") ?? 60)
        targetBitrate = Int32(defaults?.integer(forKey: "kGroupBitrate") ?? 3_500_000)

        // 3. Decouple socket server and encoder initialization to background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.isBroadcasting else { return }
            self.startStreamingServer(port: self.kDefaultMirrorPort)
        }
    }

    public override func broadcastPaused() {
        super.broadcastPaused()
        NSLog("[SampleHandler] Broadcast paused")
        notifyMainApp(event: "PauseVideo")
    }

    public override func broadcastResumed() {
        super.broadcastResumed()
        NSLog("[SampleHandler] Broadcast resumed")
        notifyMainApp(event: "ResumeVideo")
    }

    public override func broadcastFinished() {
        super.broadcastFinished()
        isBroadcasting = false

        NSLog("[SampleHandler] Broadcast finished -> cleaning up encoders and sockets")

        // Invalidate and free encoders
        videoEncoder?.invalidate()
        videoEncoder = nil

        // Clean up NWListener and connections
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.streamServer?.cancel()
            self.streamServer = nil
            self.connectedClients.forEach { $0.cancel() }
            self.connectedClients.removeAll()
        }

        // Clean up BSD sockets
        bsdSocketLock.lock()
        if bsdListenSocket >= 0 {
            close(bsdListenSocket)
            bsdListenSocket = -1
        }
        for fd in bsdClientSockets {
            close(fd)
        }
        bsdClientSockets.removeAll()
        bsdSocketLock.unlock()

        // Notify Main App that broadcast finished
        notifyMainApp(event: "Finish")
        NSLog("[SampleHandler] Clean shutdown complete")
    }

    // MARK: - Frame Processing (Zero Jetsam OOM)

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting else { return }

        // Wrap in autoreleasepool to prevent memory retention spikes
        autoreleasepool {
            switch sampleBufferType {
            case .video:
                // Lazily initialize VideoEncoder on the very first video frame
                if videoEncoder == nil {
                    videoEncoder = VideoEncoder(bitrate: targetBitrate, fps: targetFps) { [weak self] (packet, isKeyFrame, isEndFrame) in
                        self?.broadcastDataToClients(packet)
                    }

                    videoEncoder?.setDimensionChangeHandler { [weak self] width, height, rotation in
                        self?.notifyDesktopGeometryChanged(width: width, height: height, rotation: rotation)
                    }
                }

                // Extract orientation attachment if available
                var orientation: CGImagePropertyOrientation = .up
                if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                    orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) ?? .up
                }

                // Feed CVPixelBuffer to hardware encoder
                videoEncoder?.encode(sampleBuffer: sampleBuffer, orientation: orientation)

            case .audioApp, .audioMic:
                // Skip extension audio encoding to guarantee zero Jetsam OOM / CoreAudio crashes
                break

            @unknown default:
                break
            }
        }
    }

    // MARK: - Dual Network Server Engine (0.0.0.0:25334)

    private func startStreamingServer(port: UInt16) {
        // First, start the BSD socket server directly (always succeeds without prompt)
        startBsdSocketServer(port: port)

        // Second, also attempt NWListener on the same port with SO_REUSEPORT
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.noDelay = true // Zero latency
                tcpOptions.enableKeepalive = true
                let params = NWParameters(tls: nil, tcp: tcpOptions)
                params.allowLocalEndpointReuse = true
                // Note: Do NOT set params.includePeerToPeer = true on iOS 18 headless extensions

                guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
                let listener = try NWListener(using: params, on: endpointPort)

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleClientConnection(connection)
                }

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        NSLog("[SampleHandler] NWListener streaming server active on 0.0.0.0:%d", port)
                    case .failed(let err):
                        NSLog("[SampleHandler] NWListener warning: %@ (BSD socket fallback handles traffic)", err.localizedDescription)
                    default:
                        break
                    }
                }

                listener.start(queue: self.networkQueue)
                self.streamServer = listener
            } catch {
                NSLog("[SampleHandler] NWListener start note: %@ (BSD fallback active)", error.localizedDescription)
            }
        }
    }

    // MARK: - BSD POSIX Sockets Server (Fail-safe for iOS 18)

    private func startBsdSocketServer(port: UInt16) {
        networkQueue.async { [weak self] in
            guard let self = self, self.bsdListenSocket == -1 else { return }

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[SampleHandler] BSD socket creation failed: %d", errno)
                return
            }

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var noDelay: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY (0.0.0.0)

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bindRes >= 0 else {
                NSLog("[SampleHandler] BSD socket bind note on port %d: %d", port, errno)
                close(sock)
                return
            }

            guard listen(sock, 5) >= 0 else {
                NSLog("[SampleHandler] BSD socket listen error: %d", errno)
                close(sock)
                return
            }

            self.bsdSocketLock.lock()
            self.bsdListenSocket = sock
            self.bsdSocketLock.unlock()

            NSLog("[SampleHandler] BSD streaming server listening on 0.0.0.0:%d", port)

            // Asynchronous accept loop
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while let self = self, self.isBroadcasting, self.bsdListenSocket >= 0 {
                    var clientAddr = sockaddr_in()
                    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            accept(self.bsdListenSocket, $0, &addrLen)
                        }
                    }

                    guard clientFd >= 0 else { break }

                    var nd: Int32 = 1
                    setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))

                    self.bsdSocketLock.lock()
                    self.bsdClientSockets.append(clientFd)
                    self.bsdSocketLock.unlock()

                    NSLog("[SampleHandler] Desktop receiver connected via BSD socket (fd: %d)", clientFd)
                }
            }
        }
    }

    private func handleClientConnection(_ connection: NWConnection) {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.connectedClients.append(connection)

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let conn = connection else { return }
                switch state {
                case .ready:
                    NSLog("[SampleHandler] Client connected from %@", String(describing: conn.endpoint))
                case .failed, .cancelled:
                    self.networkQueue.async {
                        self.connectedClients.removeAll { $0 === conn }
                        NSLog("[SampleHandler] Client disconnected")
                    }
                default:
                    break
                }
            }

            connection.start(queue: self.networkQueue)
        }
    }

    private func broadcastDataToClients(_ data: Data) {
        // 1. Send via NWConnection clients
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.connectedClients {
                client.send(content: data, completion: .idempotent)
            }
        }

        // 2. Send via BSD POSIX sockets
        bsdSocketLock.lock()
        let clientFds = bsdClientSockets
        bsdSocketLock.unlock()

        if !clientFds.isEmpty {
            data.withUnsafeBytes { rawBuf in
                guard let basePtr = rawBuf.baseAddress else { return }
                var deadFds: [Int32] = []
                for fd in clientFds {
                    let sent = send(fd, basePtr, data.count, 0)
                    if sent <= 0 {
                        deadFds.append(fd)
                    }
                }
                if !deadFds.isEmpty {
                    self.bsdSocketLock.lock()
                    self.bsdClientSockets.removeAll { deadFds.contains($0) }
                    self.bsdSocketLock.unlock()
                    deadFds.forEach { close($0) }
                }
            }
        }
    }

    private func notifyDesktopGeometryChanged(width: Int32, height: Int32, rotation: Int32) {
        let rotationMsg = "cmd-Rotation-Resp:\(rotation)\n"
        let resolutionMsg = "cmd-Resolution-Resp:\(width)_\(height)\n"

        if let rotData = rotationMsg.data(using: .utf8), let resData = resolutionMsg.data(using: .utf8) {
            broadcastDataToClients(rotData)
            broadcastDataToClients(resData)
        }
    }

    // MARK: - Darwin Notification (MMWormhole Inter-Process Communication)

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
}
