//
//  WXCastSenderServer.swift
//  ApowerMirror / WXCastiOSSender
//
//  Reconstructed 1:1 from ApowerMirror WXCastiOSSender.framework:
//  - -[WXCastSenderServer init]
//  - -[WXCastSenderServer startMirror:port:msg:]
//  - -[WXCastSenderServer webSocketServer:didAcceptSocket:]
//  - -[WXCastSenderServer webSocketServer:didReceiveData:fromConnection:]
//
//  NOTE ON PORT SEPARATION (Preventing EADDRINUSE / errno 48):
//  The Main App process binds ONLY to port 25333 (/channel.do) for control, signaling,
//  and geometry sync.
//  The Extension process (SampleHandler) binds to port 25334 (/mirror.do and /mirrorVoice.do)
//  for real-time H.264/AAC data.
//

import Foundation
import Network
import CommonCrypto

public protocol WXCastSenderServerDelegate: AnyObject {
    func serverDidReceiveCommand(_ command: String, data: [String: Any]?)
    func serverDidRequestKeyframeRefresh()
    func serverClientConnected(endpoint: String)
    func serverClientDisconnected(endpoint: String)
}

public final class WXCastSenderServer {

    // MARK: - Constants
    public static let defaultChannelPort: UInt16 = 25333 // 0x62F5 (/channel.do)
    public static let defaultMirrorPort: UInt16 = 25334  // 0x62F6 (Extension only)

    // MARK: - Properties
    public weak var delegate: WXCastSenderServerDelegate?
    private var channelListener: NWListener?
    private var channelClients: [NWConnection] = []

    private let serverQueue = DispatchQueue(label: "com.apowermirror.server.queue", qos: .userInteractive)
    private var isRunning = false

    // MARK: - Initialization

    public init() {}

    // MARK: - Lifecycle

    /// Starts the Control / Signaling server on 0.0.0.0:25333 (/channel.do)
    public func start(channelPort: UInt16 = defaultChannelPort) {
        serverQueue.async { [weak self] in
            guard let self = self, !self.isRunning else { return }
            self.isRunning = true

            self.setupChannelListener(port: channelPort)
            NSLog("[WXCastSenderServer] Control server active on 0.0.0.0:%d (/channel.do)", channelPort)
        }
    }

    public func stop() {
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRunning = false

            self.channelListener?.cancel()
            self.channelListener = nil

            self.channelClients.forEach { $0.cancel() }
            self.channelClients.removeAll()

            NSLog("[WXCastSenderServer] Stopped control listener and closed client connections")
        }
    }

    // MARK: - Channel Server (/channel.do on 25333)

    private func setupChannelListener(port: UInt16) {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleChannelConnection(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("[WXCastSenderServer] Successfully bound channel listener to 0.0.0.0:%d", port)
                case .failed(let err):
                    NSLog("[WXCastSenderServer] Channel listener failed (check for EADDRINUSE): %@", err.localizedDescription)
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

    private func handleChannelConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let conn = connection else { return }
            switch state {
            case .ready:
                self.serverQueue.async {
                    self.channelClients.append(conn)
                    self.delegate?.serverClientConnected(endpoint: String(describing: conn.endpoint))
                    self.receiveHttpOrWebSocket(connection: conn)
                }
            case .failed, .cancelled:
                self.serverQueue.async {
                    self.channelClients.removeAll { $0 === conn }
                    self.delegate?.serverClientDisconnected(endpoint: String(describing: conn.endpoint))
                }
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
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
                delegate?.serverDidRequestKeyframeRefresh()
            } else if trimmed == "cmd_Pause_req" {
                delegate?.serverDidReceiveCommand("cmd_Pause_req", data: nil)
            } else if trimmed == "cmd_Close_req" {
                delegate?.serverDidReceiveCommand("cmd_Close_req", data: nil)
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let action = json["Action"] as? String ?? ""
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
