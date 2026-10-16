//
//  ExtensionSocketBridge.swift
//  ApowerMirrorUpload / AppleCast
//
//  Dedicated low-latency network bridge for streaming H.264 video and AAC audio
//  from the ReplayKit Broadcast Extension process directly to desktop receiver over usbmuxd / TCP.
//

import Foundation
import Network

public protocol ExtensionSocketBridgeDelegate: AnyObject {
    func bridgeClientDidConnect(_ endpoint: String)
    func bridgeClientDidDisconnect(_ endpoint: String)
    func bridgeDidReceiveCommand(_ command: String)
}

public final class ExtensionSocketBridge {

    // MARK: - Properties
    public weak var delegate: ExtensionSocketBridgeDelegate?
    private var listener: NWListener?
    private var activeClients: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.apowermirror.extension.socketbridge", qos: .userInteractive)
    private var isListening = false

    // MARK: - Initialization
    public init() {}

    // MARK: - Server Lifecycle

    /// Binds TCP listener to 0.0.0.0 on specified port (default 25334 for /mirror.do & /mirrorVoice.do)
    public func start(port: UInt16 = 25334) {
        queue.async { [weak self] in
            guard let self = self, !self.isListening else { return }
            do {
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.noDelay = true // Disable Nagle algorithm for zero latency
                let params = NWParameters(tls: nil, tcp: tcpOptions)

                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    NSLog("[ExtensionSocketBridge] Invalid port: %d", port)
                    return
                }

                let listener = try NWListener(using: params, on: nwPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleNewConnection(connection)
                }

                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        NSLog("[ExtensionSocketBridge] Listening on 0.0.0.0:%d", port)
                        self?.isListening = true
                    case .failed(let error):
                        NSLog("[ExtensionSocketBridge] Listener failed: %@", error.localizedDescription)
                        self?.isListening = false
                    default:
                        break
                    }
                }

                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                NSLog("[ExtensionSocketBridge] Failed to create listener: %@", error.localizedDescription)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.isListening = false
            self.listener?.cancel()
            self.listener = nil

            for client in self.activeClients {
                client.cancel()
            }
            self.activeClients.removeAll()
            NSLog("[ExtensionSocketBridge] Stopped listener and closed all client connections")
        }
    }

    // MARK: - Client Management

    private func handleNewConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.activeClients.append(connection)

            let endpointStr = String(describing: connection.endpoint)
            NSLog("[ExtensionSocketBridge] Client connected: %@", endpointStr)
            self.delegate?.bridgeClientDidConnect(endpointStr)

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self = self, let conn = connection else { return }
                switch state {
                case .ready:
                    self.receiveLoop(connection: conn)
                case .failed, .cancelled:
                    self.queue.async {
                        self.activeClients.removeAll { $0 === conn }
                        self.delegate?.bridgeClientDidDisconnect(endpointStr)
                        NSLog("[ExtensionSocketBridge] Client disconnected: %@", endpointStr)
                    }
                default:
                    break
                }
            }

            connection.start(queue: self.queue)
        }
    }

    private func receiveLoop(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let conn = connection else { return }

            if let data = data, !data.isEmpty, let cmd = String(data: data, encoding: .utf8) {
                self.delegate?.bridgeDidReceiveCommand(cmd)
            }

            if isComplete || error != nil {
                self.queue.async {
                    self.activeClients.removeAll { $0 === conn }
                    conn.cancel()
                }
            } else {
                self.receiveLoop(connection: conn)
            }
        }
    }

    // MARK: - Data Dispatch

    /// Broadcasts encoded video slice / AAC chunk to all active desktop connections
    public func broadcast(data: Data) {
        queue.async { [weak self] in
            guard let self = self, !self.activeClients.isEmpty else { return }
            for client in self.activeClients {
                client.send(content: data, completion: .idempotent)
            }
        }
    }
}
