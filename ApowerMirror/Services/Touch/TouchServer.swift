//
//  TouchServer.swift
//  InfinityCast
//
//  High-performance touch automation server integrated into InfinityCast.
//  Listens on port 8200 for low-latency touch injection via USB.
//

import Foundation
import Network
import UIKit

@objc
public class TouchServer: NSObject {

    @objc public static let shared = TouchServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.infinitycast.touchserver", qos: .userInteractive)
    private var isRunning = false

    private override init() {
        super.init()
    }

    @objc public func start(port: UInt16 = 8200) {
        queue.async {
            guard !self.isRunning else {
                NSLog("[TouchServer] Server already running on port %d", port)
                return
            }

            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    NSLog("[TouchServer] Invalid port %d", port)
                    return
                }

                self.listener = try NWListener(using: params, on: nwPort)
                self.listener?.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }

                self.listener?.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        NSLog("[TouchServer] Listening on USB/Local port %d (Ready for input)", port)
                    case .failed(let error):
                        NSLog("[TouchServer] Listener failed: %@", error.localizedDescription)
                    default:
                        break
                    }
                }

                self.listener?.start(queue: self.queue)
                self.isRunning = true
                NSLog("[TouchServer] Started successfully on port %d", port)
            } catch {
                NSLog("[TouchServer] Failed to create listener: %@", error.localizedDescription)
            }
        }
    }

    @objc public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.isRunning = false
            NSLog("[TouchServer] Stopped")
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection: connection)
    }

    private func readRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty, let reqStr = String(data: data, encoding: .utf8) {
                let responseData = self.processHTTP(raw: reqStr)
                connection.send(content: responseData, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
                return
            }

            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func processHTTP(raw: String) -> Data {
        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return httpResponse(status: 400, json: ["error": "empty_request"])
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return httpResponse(status: 400, json: ["error": "malformed_request_line"])
        }

        let method = parts[0]
        let path = parts[1]

        // Extract body if present
        var bodyData: [String: Any] = [:]
        if let bodyIndex = raw.range(of: "\r\n\r\n") {
            let bodyString = String(raw[bodyIndex.upperBound...])
            if let d = bodyString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                bodyData = json
            }
        }

        if method == "GET" && (path == "/whoami" || path == "/status") {
            return httpResponse(status: 200, json: [
                "status": 0,
                "value": [
                    "name": "InfinityCast",
                    "version": "1.6.0",
                    "touch_available": IPURBridge.eventSynthesisAvailable(),
                    "state": "success"
                ]
            ])
        }

        if method == "POST" && (path == "/fast_touch" || path == "/touch") {
            return handleFastTouch(body: bodyData)
        }

        if method == "POST" && path.contains("touch/perform") {
            return handleWDAPerform(body: bodyData)
        }

        return httpResponse(status: 200, json: ["status": 0, "value": ["ok": true]])
    }

    private func handleFastTouch(body: [String: Any]) -> Data {
        let action = body["action"] as? String ?? "tap"

        if action == "tap" {
            let x = CGFloat((body["x"] as? NSNumber)?.doubleValue ?? 0.0)
            let y = CGFloat((body["y"] as? NSNumber)?.doubleValue ?? 0.0)
            let pt = CGPoint(x: x, y: y)

            if let err = IPURBridge.synthesizeTap(at: pt, pid: 0) {
                return httpResponse(status: 500, json: ["status": 13, "value": ["error": err]])
            }
            return httpResponse(status: 200, json: ["status": 0, "value": ["ok": true, "x": pt.x, "y": pt.y]])
        } else if action == "drag" {
            let fromX = CGFloat((body["from_x"] as? NSNumber)?.doubleValue ?? 0.0)
            let fromY = CGFloat((body["from_y"] as? NSNumber)?.doubleValue ?? 0.0)
            let toX = CGFloat((body["to_x"] as? NSNumber)?.doubleValue ?? 0.0)
            let toY = CGFloat((body["to_y"] as? NSNumber)?.doubleValue ?? 0.0)
            let duration = max(0.01, (body["duration"] as? NSNumber)?.doubleValue ?? 0.05)

            let pt1 = CGPoint(x: fromX, y: fromY)
            let pt2 = CGPoint(x: toX, y: toY)

            if let err = IPURBridge.synthesizeDrag(from: pt1, to: pt2, duration: duration, pid: 0) {
                return httpResponse(status: 500, json: ["status": 13, "value": ["error": err]])
            }
            return httpResponse(status: 200, json: ["status": 0, "value": ["ok": true]])
        }

        return httpResponse(status: 400, json: ["status": 13, "value": ["error": "invalid_action"]])
    }

    private func handleWDAPerform(body: [String: Any]) -> Data {
        // Standard WDA gesture format fallback
        guard let actions = body["actions"] as? [[String: Any]] else {
            return httpResponse(status: 200, json: ["status": 0, "value": ["ok": true]])
        }

        for act in actions {
            let type = act["action"] as? String ?? ""
            let opts = act["options"] as? [String: Any] ?? [:]
            let x = CGFloat((opts["x"] as? NSNumber)?.doubleValue ?? 0.0)
            let y = CGFloat((opts["y"] as? NSNumber)?.doubleValue ?? 0.0)

            if type == "tap" {
                _ = IPURBridge.synthesizeTap(at: CGPoint(x: x, y: y), pid: 0)
            }
        }

        return httpResponse(status: 200, json: ["status": 0, "value": ["ok": true]])
    }

    private func httpResponse(status: Int, json: [String: Any]) -> Data {
        let jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data()
        let statusText = (status == 200) ? "OK" : ((status == 400) ? "Bad Request" : "Internal Server Error")
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nConnection: close\r\n\r\n"
        var out = header.data(using: .utf8) ?? Data()
        out.append(jsonData)
        return out
    }
}
