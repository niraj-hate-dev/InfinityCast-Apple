//
//  WXCastSenderServer.swift
//  ApowerMirror / WXCastiOSSender
//
//  Dual-Port Server Engine for ApowerMirror & AppleCast:
//  - Port 25333: Control / Signaling (/channel.do WebSocket & JSON RPC)
//  - Port 25334: Video Media Stream (/mirror.do HTTP & Raw H.264 NALU Stream)
//  Hosted directly inside the Main App process to bypass iOS 18 extension
//  sandbox network restrictions.
//

import Foundation
import UIKit
import Network
import CommonCrypto
import Darwin

public protocol WXCastSenderServerDelegate: AnyObject {
    func serverDidReceiveCommand(_ command: String, data: [String: Any]?)
    func serverDidRequestKeyframeRefresh()
    func serverClientConnected(endpoint: String)
    func serverClientDisconnected(endpoint: String)
}

public final class WXCastSenderServer {

    // MARK: - Constants
    public static let defaultChannelPort: UInt16 = 25333 // 0x62F5 (/channel.do)
    public static let defaultMirrorPort: UInt16 = 25334  // 0x62F6 (/mirror.do)
    public static let defaultAudioPort: UInt16 = 25335   // 0x62F7 (/mirrorVoice.do)
    public static let defaultIpcPort: UInt16 = 8888      // Internal Video IPC from Broadcast Extension
    public static let defaultAudioIpcPort: UInt16 = 8889 // Internal Audio IPC from Broadcast Extension
    private static let forceKeyframeNotificationName = "com.apowermirror.forceKeyframe" as CFString

    // MARK: - Properties
    public weak var delegate: WXCastSenderServerDelegate?

    // Channel (Port 25333)
    private var channelListener: NWListener?
    private var channelClients: [NWConnection] = []

    // Video Stream (Port 25334)
    private var mirrorListener: NWListener?
    private var mirrorClients: [NWConnection] = []

    // Audio Stream (Port 25335)
    private var audioListener: NWListener?
    private var audioClients: [NWConnection] = []

    // BSD Sockets Engine for Port 25334 (Fail-safe direct video socket stream)
    private var bsdListenSocket: Int32 = -1
    private var bsdClientSockets: [Int32] = []
    private let bsdSocketLock = NSLock()

    // BSD Sockets Engine for Port 25335 (Fail-safe direct audio socket stream)
    private var bsdAudioListenSocket: Int32 = -1
    private var bsdAudioClientSockets: [Int32] = []
    private let bsdAudioSocketLock = NSLock()

    // Internal Video IPC Server for ReplayKit Extension (Port 8888)
    private var ipcListenSocket: Int32 = -1
    private var ipcClientSockets: [Int32] = []
    private let ipcSocketLock = NSLock()

    // Internal Audio IPC Server for ReplayKit Extension (Port 8889)
    private var audioIpcListenSocket: Int32 = -1
    private var audioIpcClientSockets: [Int32] = []
    private let audioIpcSocketLock = NSLock()

    // Cached H.264 Parameter Sets (Annex-B SPS, PPS, & IDR) for late-joining desktop clients
    private var cachedSps: Data?
    private var cachedPps: Data?
    private var cachedIdr: Data?
    private let parameterSetLock = NSLock()

    private let serverQueue = DispatchQueue(label: "com.apowermirror.server.queue", qos: .userInteractive)
    // Audio can arrive from the ReplayKit IPC receiver or the in-app recorder.
    // Serialize the complete dispatch so AAC packets cannot interleave on a TCP
    // client when both capture paths are active.
    private let audioSendQueue = DispatchQueue(label: "com.apowermirror.server.audio.send", qos: .userInteractive)
    private var isRunning = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Lifecycle

    /// Starts Control (25333), Video (25334), Audio (25335), Video IPC (8888), and Audio IPC (8889) server engines
    public func start(channelPort: UInt16 = defaultChannelPort, mirrorPort: UInt16 = defaultMirrorPort, audioPort: UInt16 = defaultAudioPort, ipcPort: UInt16 = defaultIpcPort, audioIpcPort: UInt16 = defaultAudioIpcPort) {
        serverQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true

            self.setupChannelListener(port: channelPort)
            self.setupBsdMirrorServer(port: mirrorPort)
            self.setupBsdAudioServer(port: audioPort)
            self.setupIpcListener(port: ipcPort)
            self.setupAudioIpcListener(port: audioIpcPort)
            NSLog("[WXCastSenderServer] Control (0.0.0.0:%d), Video (0.0.0.0:%d), Audio (0.0.0.0:%d), Video IPC (127.0.0.1:%d), Audio IPC (127.0.0.1:%d) active", channelPort, mirrorPort, audioPort, ipcPort, audioIpcPort)
        }
    }

    public func stop() {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false

            // Stop Channel Listener & Clients
            self.channelListener?.cancel()
            self.channelListener = nil
            self.channelClients.forEach { $0.cancel() }
            self.channelClients.removeAll()

            // Stop Mirror Listener & Clients
            self.mirrorListener?.cancel()
            self.mirrorListener = nil
            self.mirrorClients.forEach { $0.cancel() }
            self.mirrorClients.removeAll()

            // Stop Audio Listener & Clients
            self.audioListener?.cancel()
            self.audioListener = nil
            self.audioClients.forEach { $0.cancel() }
            self.audioClients.removeAll()

            // Close BSD Video Sockets
            self.bsdSocketLock.lock()
            if self.bsdListenSocket >= 0 {
                close(self.bsdListenSocket)
                self.bsdListenSocket = -1
            }
            for fd in self.bsdClientSockets {
                close(fd)
            }
            self.bsdClientSockets.removeAll()
            self.bsdSocketLock.unlock()

            // Close BSD Audio Sockets
            self.bsdAudioSocketLock.lock()
            if self.bsdAudioListenSocket >= 0 {
                close(self.bsdAudioListenSocket)
                self.bsdAudioListenSocket = -1
            }
            for fd in self.bsdAudioClientSockets {
                close(fd)
            }
            self.bsdAudioClientSockets.removeAll()
            self.bsdAudioSocketLock.unlock()

            // Close Video IPC Sockets
            self.ipcSocketLock.lock()
            if self.ipcListenSocket >= 0 {
                close(self.ipcListenSocket)
                self.ipcListenSocket = -1
            }
            for fd in self.ipcClientSockets {
                close(fd)
            }
            self.ipcClientSockets.removeAll()
            self.ipcSocketLock.unlock()

            // Close Audio IPC Sockets
            self.audioIpcSocketLock.lock()
            if self.audioIpcListenSocket >= 0 {
                close(self.audioIpcListenSocket)
                self.audioIpcListenSocket = -1
            }
            for fd in self.audioIpcClientSockets {
                close(fd)
            }
            self.audioIpcClientSockets.removeAll()
            self.audioIpcSocketLock.unlock()

            NSLog("[WXCastSenderServer] Stopped all listeners and closed client connections")
        }
    }

    // MARK: - Keyframe Request & Cached SPS/PPS Helpers

    private func requestEncoderKeyframeRefresh() {
        delegate?.serverDidRequestKeyframeRefresh()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.forceKeyframeNotificationName),
            nil,
            nil,
            true
        )
    }

    private func getCachedParameterSetsData() -> Data? {
        parameterSetLock.lock()
        defer { parameterSetLock.unlock() }
        guard let sps = cachedSps, let pps = cachedPps else { return nil }
        var combined = Data(capacity: sps.count + pps.count + (cachedIdr?.count ?? 0))
        combined.append(sps)
        combined.append(pps)
        if let idr = cachedIdr {
            combined.append(idr)
        }
        return combined
    }

    private func cacheParameterSetsIfPresent(in data: Data) {
        guard data.count > 5 else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuffer.count
            var i = 0
            var nalStarts: [Int] = []

            while i <= count - 4 {
                if base[i] == 0x00 && base[i + 1] == 0x00 && base[i + 2] == 0x00 && base[i + 3] == 0x01 {
                    nalStarts.append(i)
                    i += 4
                } else {
                    i += 1
                }
            }

            guard !nalStarts.isEmpty else { return }

            for idx in 0..<nalStarts.count {
                let startOffset = nalStarts[idx]
                let headerIndex = startOffset + 4
                guard headerIndex < count else { continue }

                let nalType = base[headerIndex] & 0x1F
                if nalType == 7 || nalType == 8 || nalType == 5 {
                    let endOffset = (idx + 1 < nalStarts.count) ? nalStarts[idx + 1] : count
                    let nalData = Data(bytes: base.advanced(by: startOffset), count: endOffset - startOffset)

                    parameterSetLock.lock()
                    if nalType == 7 {
                        cachedSps = nalData
                    } else if nalType == 8 {
                        cachedPps = nalData
                    } else if nalType == 5 {
                        cachedIdr = nalData
                    }
                    parameterSetLock.unlock()
                }
            }
        }
    }

    // MARK: - Channel Server (/channel.do on 25333)

    private func setupChannelListener(port: UInt16) {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleChannelConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("[WXCastSenderServer] Successfully bound channel listener to 0.0.0.0:%d", port)
                case .failed(let err):
                    NSLog("[WXCastSenderServer] Channel listener failed: %@", err.localizedDescription)
                default:
                    break
                }
            }
            listener.start(queue: serverQueue)
            self.channelListener = listener
        } catch {
            NSLog("[WXCastSenderServer] Failed to bind Channel Listener on port %d: %@", port, error.localizedDescription)
        }
    }

    public var isAnyClientConnected: Bool {
        return !channelClients.isEmpty || !mirrorClients.isEmpty || !bsdClientSockets.isEmpty || !audioClients.isEmpty || !bsdAudioClientSockets.isEmpty
    }

    private func handleChannelConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.serverQueue.async {
                    self.channelClients.append(conn)
                    let endpoint = String(describing: conn.endpoint)
                    NSLog("[WXCastSenderServer] Control client connected: %@", endpoint)
                    self.delegate?.serverClientConnected(endpoint: endpoint)
                    self.receiveHttpOrWebSocket(connection: conn)
                }
            case .failed, .cancelled:
                self.serverQueue.async {
                    self.channelClients.removeAll { $0 === conn }
                    let endpoint = String(describing: conn.endpoint)
                    if !self.isAnyClientConnected {
                        self.delegate?.serverClientDisconnected(endpoint: endpoint)
                    }
                }
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
    }

    // MARK: - Video Mirror Server (/mirror.do on 25334)

    private func setupMirrorListener(port: UInt16) {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = false

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleMirrorConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    NSLog("[WXCastSenderServer] Successfully bound Video Mirror listener to 0.0.0.0:%d", port)
                case .failed(let err):
                    NSLog("[WXCastSenderServer] Video Mirror listener failed: %@, falling back to BSD socket", err.localizedDescription)
                    self?.setupBsdMirrorServer(port: port)
                default:
                    break
                }
            }
            listener.start(queue: serverQueue)
            self.mirrorListener = listener
        } catch {
            NSLog("[WXCastSenderServer] Failed to bind Mirror Listener on port %d, falling back to BSD socket: %@", port, error.localizedDescription)
            setupBsdMirrorServer(port: port)
        }
    }

    private func handleMirrorConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.serverQueue.async {
                    // Send cached SPS/PPS before adding client to active broadcast list
                    if let headerData = self.getCachedParameterSetsData() {
                        conn.send(content: headerData, completion: .idempotent)
                        NSLog("[WXCastSenderServer] Sent cached SPS/PPS (%d bytes) to new NWConnection client", headerData.count)
                    }
                    self.mirrorClients.append(conn)
                    let endpoint = String(describing: conn.endpoint)
                    NSLog("[WXCastSenderServer] Desktop Mirror client connected on 25334: %@", endpoint)
                    self.delegate?.serverClientConnected(endpoint: endpoint)
                    self.requestEncoderKeyframeRefresh()
                    self.receiveMirrorHandshake(connection: conn)
                }
            case .failed, .cancelled:
                self.serverQueue.async {
                    self.mirrorClients.removeAll { $0 === conn }
                    NSLog("[WXCastSenderServer] Desktop Mirror client disconnected on 25334")
                }
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
    }

    private func receiveMirrorHandshake(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] (data, _, isComplete, error) in
            guard let self = self, let conn = connection, let data = data, !data.isEmpty else { return }

            if let text = String(data: data, encoding: .utf8), text.contains("GET ") {
                if text.contains("mirrorVoice") {
                    self.serverQueue.async {
                        self.mirrorClients.removeAll { $0 === conn }
                        self.audioClients.append(conn)
                    }
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: audio/aac\r\nConnection: keep-alive\r\n\r\n"
                    if let respData = response.data(using: .utf8) {
                        conn.send(content: respData, completion: .idempotent)
                    }
                    NSLog("[WXCastSenderServer] Acknowledged HTTP /mirrorVoice.do request on 25334")
                } else {
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: video/h264\r\nConnection: keep-alive\r\n\r\n"
                    if let respData = response.data(using: .utf8) {
                        conn.send(content: respData, completion: .idempotent)
                    }
                    if let headerData = self.getCachedParameterSetsData() {
                        conn.send(content: headerData, completion: .idempotent)
                    }
                    self.requestEncoderKeyframeRefresh()
                    NSLog("[WXCastSenderServer] Acknowledged HTTP /mirror.do stream request and dispatched SPS/PPS")
                }
            }
        }
    }

    // MARK: - BSD Sockets Engine for Port 25334

    private func setupBsdMirrorServer(port: UInt16) {
        serverQueue.async { [weak self] in
            guard let self = self, self.bsdListenSocket == -1 else { return }

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[WXCastSenderServer] BSD socket creation failed: %d", errno)
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
            addr.sin_addr.s_addr = in_addr_t(0) // 0.0.0.0

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bindRes >= 0 else {
                NSLog("[WXCastSenderServer] BSD socket bind note on port %d: %d", port, errno)
                close(sock)
                return
            }

            guard listen(sock, 5) >= 0 else {
                NSLog("[WXCastSenderServer] BSD socket listen error: %d", errno)
                close(sock)
                return
            }

            self.bsdSocketLock.lock()
            self.bsdListenSocket = sock
            self.bsdSocketLock.unlock()

            NSLog("[WXCastSenderServer] BSD Video Mirror socket listening on 0.0.0.0:%d", port)

            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                while let self = self, self.isRunning, self.bsdListenSocket >= 0 {
                    var clientAddr = sockaddr_in()
                    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            accept(self.bsdListenSocket, $0, &addrLen)
                        }
                    }

                    guard clientFd >= 0 else { break }

                    var noSigpipe: Int32 = 1
                    setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

                    var nd: Int32 = 1
                    setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))

                    var sndBuf: Int32 = 2 * 1024 * 1024
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

                    var timeout = timeval(tv_sec: 1, tv_usec: 0)
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                    // Immediately prime the new BSD socket client with cached SPS & PPS headers
                    if let headerData = self.getCachedParameterSetsData() {
                        headerData.withUnsafeBytes { rawBuf in
                            if let basePtr = rawBuf.baseAddress {
                                _ = send(clientFd, basePtr, headerData.count, 0)
                            }
                        }
                        NSLog("[WXCastSenderServer] Sent cached SPS/PPS (%d bytes) to new BSD client (fd: %d)", headerData.count, clientFd)
                    }

                    self.bsdSocketLock.lock()
                    self.bsdClientSockets.append(clientFd)
                    self.bsdSocketLock.unlock()

                    NSLog("[WXCastSenderServer] Desktop connected to BSD socket on port %d (fd: %d)", port, clientFd)
                    self.requestEncoderKeyframeRefresh()
                    DispatchQueue.main.async {
                        self.delegate?.serverClientConnected(endpoint: "BSD-Socket:\(clientFd)")
                    }
                }
            }
        }
    }

    // MARK: - Video Dispatcher (Port 25334)

    public func sendVideoData(_ data: Data) {
        // 0. Cache latest SPS (type 7) and PPS (type 8) NAL units for future clients
        cacheParameterSetsIfPresent(in: data)

        // 1. Dispatch via NWConnection clients
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.mirrorClients {
                client.send(content: data, completion: .idempotent)
            }
        }

        // 2. Dispatch via BSD sockets (Port 25334)
        bsdSocketLock.lock()
        let clientFds = bsdClientSockets
        bsdSocketLock.unlock()

        if !clientFds.isEmpty {
            data.withUnsafeBytes { rawBuf in
                guard let basePtr = rawBuf.baseAddress else { return }
                var deadFds: [Int32] = []
                for fd in clientFds {
                    var totalSent = 0
                    var retries = 0
                    while totalSent < data.count {
                        let sent = send(fd, basePtr.advanced(by: totalSent), data.count - totalSent, 0)
                        if sent > 0 {
                            totalSent += sent
                            retries = 0
                        } else {
                            if (errno == EAGAIN || errno == EWOULDBLOCK) && retries < 25 {
                                retries += 1
                                usleep(1000) // Wait up to 25ms for USB tunnel drain
                                continue
                            }
                            // If we already wrote part of the frame (`totalSent > 0`), leaving the
                            // socket open will corrupt the H.264 stream on the desktop!
                            // Close the stalled client socket or force an immediate IDR keyframe recovery.
                            deadFds.append(fd)
                            self.requestEncoderKeyframeRefresh()
                            break
                        }
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

    // MARK: - Audio Mirror Server (/mirrorVoice.do on 25335)

    private func setupAudioMirrorListener(port: UInt16) {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = false

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleAudioConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    NSLog("[WXCastSenderServer] Successfully bound Audio Mirror listener to 0.0.0.0:%d", port)
                case .failed(let err):
                    NSLog("[WXCastSenderServer] Audio listener failed: %@, falling back to BSD socket", err.localizedDescription)
                    self?.setupBsdAudioServer(port: port)
                default:
                    break
                }
            }
            listener.start(queue: serverQueue)
            self.audioListener = listener
        } catch {
            NSLog("[WXCastSenderServer] Failed to bind Audio Listener on port %d, falling back to BSD socket: %@", port, error.localizedDescription)
            setupBsdAudioServer(port: port)
        }
    }

    private func handleAudioConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.serverQueue.async {
                    self.audioClients.append(conn)
                    let endpoint = String(describing: conn.endpoint)
                    NSLog("[WXCastSenderServer] Desktop Audio client connected on 25335: %@", endpoint)
                }
            case .failed, .cancelled:
                self.serverQueue.async {
                    self.audioClients.removeAll { $0 === conn }
                    NSLog("[WXCastSenderServer] Desktop Audio client disconnected on 25335")
                }
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
    }

    private func setupBsdAudioServer(port: UInt16) {
        serverQueue.async { [weak self] in
            guard let self = self, self.bsdAudioListenSocket == -1 else { return }

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[WXCastSenderServer] BSD Audio socket creation failed: %d", errno)
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
            addr.sin_addr.s_addr = in_addr_t(0) // 0.0.0.0

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bindRes >= 0 else {
                NSLog("[WXCastSenderServer] BSD Audio socket bind note on port %d: %d", port, errno)
                close(sock)
                return
            }

            guard listen(sock, 5) >= 0 else {
                NSLog("[WXCastSenderServer] BSD Audio socket listen error: %d", errno)
                close(sock)
                return
            }

            self.bsdAudioSocketLock.lock()
            self.bsdAudioListenSocket = sock
            self.bsdAudioSocketLock.unlock()

            NSLog("[WXCastSenderServer] BSD Audio Mirror socket listening on 0.0.0.0:%d", port)

            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                while let self = self, self.isRunning, self.bsdAudioListenSocket >= 0 {
                    var clientAddr = sockaddr_in()
                    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            accept(self.bsdAudioListenSocket, $0, &addrLen)
                        }
                    }

                    guard clientFd >= 0 else { break }

                    var noSigpipe: Int32 = 1
                    setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

                    var nd: Int32 = 1
                    setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))

                    var sndBuf: Int32 = 2 * 1024 * 1024
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

                    var timeout = timeval(tv_sec: 1, tv_usec: 0)
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                    self.bsdAudioSocketLock.lock()
                    self.bsdAudioClientSockets.append(clientFd)
                    self.bsdAudioSocketLock.unlock()

                    NSLog("[WXCastSenderServer] Desktop connected to BSD Audio socket on port %d (fd: %d)", port, clientFd)
                }
            }
        }
    }

    // MARK: - Audio Dispatcher (Port 25335 & Port 25334 /mirrorVoice)

    public func sendAudioData(_ data: Data) {
        audioSendQueue.async { [weak self] in
            self?.sendAudioDataSerialized(data)
        }
    }

    private func sendAudioDataSerialized(_ data: Data) {
        // 1. Dispatch via NWConnection audio clients
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.audioClients {
                client.send(content: data, completion: .idempotent)
            }
        }

        // 2. Dispatch via BSD audio sockets
        bsdAudioSocketLock.lock()
        let clientFds = bsdAudioClientSockets
        bsdAudioSocketLock.unlock()

        if !clientFds.isEmpty {
            data.withUnsafeBytes { rawBuf in
                guard let basePtr = rawBuf.baseAddress else { return }
                var deadFds: [Int32] = []
                for fd in clientFds {
                    var totalSent = 0
                    var retries = 0
                    while totalSent < data.count {
                        let sent = send(fd, basePtr.advanced(by: totalSent), data.count - totalSent, 0)
                        if sent > 0 {
                            totalSent += sent
                            retries = 0
                        } else {
                            if (errno == EAGAIN || errno == EWOULDBLOCK) && retries < 25 {
                                retries += 1
                                usleep(1000)
                                continue
                            }
                            deadFds.append(fd)
                            break
                        }
                    }
                }
                if !deadFds.isEmpty {
                    self.bsdAudioSocketLock.lock()
                    self.bsdAudioClientSockets.removeAll { deadFds.contains($0) }
                    self.bsdAudioSocketLock.unlock()
                    deadFds.forEach { close($0) }
                }
            }
        }
    }

    // MARK: - ReplayKit Extension IPC Server (Port 8888 on 127.0.0.1)

    private func setupIpcListener(port: UInt16) {
        serverQueue.async { [weak self] in
            guard let self = self, self.ipcListenSocket == -1 else { return }

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[WXCastSenderServer] IPC socket creation failed: %d", errno)
                return
            }

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var noDelay: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            var rcvBuf: Int32 = 2 * 1024 * 1024
            setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bindRes >= 0 else {
                NSLog("[WXCastSenderServer] IPC socket bind note on port %d: %d", port, errno)
                close(sock)
                return
            }

            guard listen(sock, 5) >= 0 else {
                NSLog("[WXCastSenderServer] IPC socket listen error: %d", errno)
                close(sock)
                return
            }

            self.ipcSocketLock.lock()
            self.ipcListenSocket = sock
            self.ipcSocketLock.unlock()

            NSLog("[WXCastSenderServer] IPC socket listening for ReplayKit Extension on 127.0.0.1:%d", port)

            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                while let self = self, self.isRunning, self.ipcListenSocket >= 0 {
                    var clientAddr = sockaddr_in()
                    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            accept(self.ipcListenSocket, $0, &addrLen)
                        }
                    }

                    guard clientFd >= 0 else { break }

                    var noSigpipe: Int32 = 1
                    setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

                    var nd: Int32 = 1
                    setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))

                    var sndBuf: Int32 = 2 * 1024 * 1024
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

                    var timeout = timeval(tv_sec: 1, tv_usec: 0)
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                    self.ipcSocketLock.lock()
                    self.ipcClientSockets.append(clientFd)
                    self.ipcSocketLock.unlock()

                    NSLog("[WXCastSenderServer] Broadcast Extension connected to IPC on port %d (fd: %d)!", port, clientFd)
                    self.requestEncoderKeyframeRefresh()
                    self.startIpcReceiveLoop(clientFd: clientFd)
                }
            }
        }
    }

    private func startIpcReceiveLoop(clientFd: Int32) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)

            while self.isRunning {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuf in
                    recv(clientFd, rawBuf.baseAddress, rawBuf.count, 0)
                }

                if bytesRead > 0 {
                    let packetData = Data(buffer[0..<bytesRead])
                    // Forward received video packet immediately to Desktop receiver on port 25334!
                    self.sendVideoData(packetData)
                } else if bytesRead <= 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    NSLog("[WXCastSenderServer] Broadcast Extension disconnected from IPC (fd: %d)", clientFd)
                    break
                }
            }

            self.ipcSocketLock.lock()
            self.ipcClientSockets.removeAll { $0 == clientFd }
            self.ipcSocketLock.unlock()
            close(clientFd)
        }
    }

    // MARK: - ReplayKit Extension Audio IPC Server (Port 8889 on 127.0.0.1)

    private func setupAudioIpcListener(port: UInt16) {
        serverQueue.async { [weak self] in
            guard let self = self, self.audioIpcListenSocket == -1 else { return }

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[WXCastSenderServer] Audio IPC socket creation failed: %d", errno)
                return
            }

            var reuse: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var noDelay: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            var rcvBuf: Int32 = 1024 * 1024
            setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bindRes >= 0 else {
                NSLog("[WXCastSenderServer] Audio IPC socket bind note on port %d: %d", port, errno)
                close(sock)
                return
            }

            guard listen(sock, 5) >= 0 else {
                NSLog("[WXCastSenderServer] Audio IPC socket listen error: %d", errno)
                close(sock)
                return
            }

            self.audioIpcSocketLock.lock()
            self.audioIpcListenSocket = sock
            self.audioIpcSocketLock.unlock()

            NSLog("[WXCastSenderServer] Audio IPC socket listening for ReplayKit Extension on 127.0.0.1:%d", port)

            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                while let self = self, self.isRunning, self.audioIpcListenSocket >= 0 {
                    var clientAddr = sockaddr_in()
                    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            accept(self.audioIpcListenSocket, $0, &addrLen)
                        }
                    }

                    guard clientFd >= 0 else { break }

                    var noSigpipe: Int32 = 1
                    setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

                    var nd: Int32 = 1
                    setsockopt(clientFd, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))

                    var sndBuf: Int32 = 2 * 1024 * 1024
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

                    var timeout = timeval(tv_sec: 1, tv_usec: 0)
                    setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                    self.audioIpcSocketLock.lock()
                    self.audioIpcClientSockets.append(clientFd)
                    self.audioIpcSocketLock.unlock()

                    NSLog("[WXCastSenderServer] Broadcast Extension connected to Audio IPC on port %d (fd: %d)!", port, clientFd)
                    self.startAudioIpcReceiveLoop(clientFd: clientFd)
                }
            }
        }
    }

    private func startAudioIpcReceiveLoop(clientFd: Int32) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 16384)
            var totalPacketsReceived = 0

            while self.isRunning {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuf in
                    recv(clientFd, rawBuf.baseAddress, rawBuf.count, 0)
                }

                if bytesRead > 0 {
                    totalPacketsReceived += 1
                    if totalPacketsReceived <= 5 || totalPacketsReceived % 200 == 0 {
                        NSLog("[WXCastSenderServer] Audio IPC received packet #%d (%d bytes) from Extension", totalPacketsReceived, bytesRead)
                    }
                    let packetData = Data(buffer[0..<bytesRead])
                    self.sendAudioData(packetData)
                } else if bytesRead <= 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    NSLog("[WXCastSenderServer] Broadcast Extension disconnected from Audio IPC (fd: %d, errno: %d)", clientFd, errno)
                    break
                }
            }

            self.audioIpcSocketLock.lock()
            self.audioIpcClientSockets.removeAll { $0 == clientFd }
            self.audioIpcSocketLock.unlock()
            close(clientFd)
        }
    }

    // MARK: - HTTP Upgrade & Protocol Parsing

    private func receiveHttpOrWebSocket(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak connection] (data, _, isComplete, error) in
            guard let self = self, let conn = connection, let data = data, !data.isEmpty else { return }

            if let text = String(data: data, encoding: .utf8), text.contains("GET ") && text.contains("Upgrade: websocket") {
                // Perform WebSocket Upgrade Handshake for /channel.do
                self.handleWebSocketHandshake(connection: conn, request: text)
            } else {
                // Parse Incoming Signaling or Control Message
                self.handleIncomingData(connection: conn, data: data)
            }

            if !isComplete && error == nil {
                self.receiveHttpOrWebSocket(connection: conn)
            }
        }
    }

    private func handleWebSocketHandshake(connection: NWConnection, request: String) {
        var secKey = ""
        for line in request.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("sec-websocket-key:") {
                secKey = line.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard !secKey.isEmpty else { return }

        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let acceptKey = computeSha1Base64(string: secKey + magic)

        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

        if let respData = response.data(using: .utf8) {
            connection.send(content: respData, completion: .contentProcessed { error in
                if error == nil {
                    NSLog("[WXCastSenderServer] Handshake completed successfully on /channel.do")
                }
            })
        }
    }

    private func handleIncomingData(connection: NWConnection, data: Data) {
        if let stringMsg = String(data: data, encoding: .utf8) {
            let trimmed = stringMsg.trimmingCharacters(in: .whitespacesAndNewlines)

            // Decompiled ApowerMirror Control Commands (ASM @ 0x44920, 0x456a0, 0x456c0)
            if trimmed == "cmd_Recast_req" {
                requestEncoderKeyframeRefresh()
            } else if trimmed == "cmd_Pause_req" {
                delegate?.serverDidReceiveCommand("cmd_Pause_req", data: nil)
            } else if trimmed == "cmd_Close_req" {
                delegate?.serverDidReceiveCommand("cmd_Close_req", data: nil)
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let action = json["Action"] as? String ?? json["cmd"] as? String ?? ""
                if action == "PING" {
                    let isCaptured = ScreenRecorderManager.shared.isCapturing || UIScreen.main.isCaptured
                    let pongPayload: [String: Any] = [
                        "cmd": "PONG",
                        "status": "online",
                        "name": UIDevice.current.name,
                        "model": UIDevice.current.model,
                        "isCaptured": isCaptured
                    ]
                    if let pongData = try? JSONSerialization.data(withJSONObject: pongPayload) {
                        connection.send(content: pongData + "\n".data(using: .utf8)!, completion: .idempotent)
                    }
                }
                delegate?.serverDidReceiveCommand(action, data: json)
            }
        }
    }

    // MARK: - Outgoing Dispatchers

    public func sendChannelMessage(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.channelClients {
                client.send(content: data, completion: .idempotent)
            }
        }
    }

    // MARK: - SHA-1 Helper for WebSocket Accept

    private func computeSha1Base64(string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
    }
}
