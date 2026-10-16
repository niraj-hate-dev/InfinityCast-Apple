//
//  WXCastiOSSender.swift
//  ApowerMirror / WXCastiOSSender
//
//  Reconstructed 1:1 from ApowerMirror WXCastiOSSender.framework:
//  - -[WXCastiOSSender init]
//  - -[WXCastiOSSender startMirrorService:result:]
//  - -[WXCastiOSSender stopMirrorService]
//  - -[WXCastiOSSender sendStartCastPayload]
//  - -[WXCastiOSSender sendCustomDeviceMsg]
//

import UIKit
import Foundation

public protocol WXCastiOSSenderDelegate: AnyObject {
    func castSenderDidConnectDesktop()
    func castSenderDidDisconnectDesktop()
    func castSenderDidRequestIDRKeyframe()
}

public final class WXCastiOSSender: WXCastSenderServerDelegate {

    // MARK: - Singleton
    public static let shared = WXCastiOSSender()

    // MARK: - Properties
    public weak var delegate: WXCastiOSSenderDelegate?
    public let server = WXCastSenderServer()

    private var channelPort: UInt16 = 25333
    private var mirrorPort: UInt16 = 25334
    private var isMirroring = false
    private let deviceUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString

    // MARK: - Initialization

    private init() {
        server.delegate = self
    }

    // MARK: - Service Lifecycle

    public func startMirrorService(channelPort: UInt16 = 25333, mirrorPort: UInt16 = 25334, result: ((Bool) -> Void)? = nil) {
        self.channelPort = channelPort
        self.mirrorPort = mirrorPort
        self.isMirroring = true

        // The Main App binds ONLY to channelPort (25333) for control/signaling.
        // mirrorPort (25334) is bound exclusively by the Extension (SampleHandler) for video/audio.
        server.start(channelPort: channelPort)
        result?(true)
        NSLog("[WXCastiOSSender] Service started -> Channel: %d, Mirror: %d", channelPort, mirrorPort)
    }

    public func stopMirrorService() {
        guard isMirroring else { return }
        isMirroring = false

        // Send Close Request to desktop
        server.sendChannelMessage("cmd_Close_req\n")
        server.stop()
        NSLog("[WXCastiOSSender] Service stopped")
    }

    // MARK: - WXCastSenderServerDelegate Callbacks

    public func serverClientConnected(endpoint: String) {
        NSLog("[WXCastiOSSender] Desktop connected: %@", endpoint)
        delegate?.castSenderDidConnectDesktop()

        // 1. Send Device Registration Payload
        sendCustomDeviceMetadata()

        // 2. Send StartCast Handshake JSON
        sendStartCastPayload()

        // 3. Send Initial Screen Dimensions
        sendScreenDimensions()
    }

    public func serverClientDisconnected(endpoint: String) {
        NSLog("[WXCastiOSSender] Desktop disconnected: %@", endpoint)
        delegate?.castSenderDidDisconnectDesktop()
    }

    public func serverDidReceiveCommand(_ command: String, data: [String : Any]?) {
        NSLog("[WXCastiOSSender] Received control command: %@", command)
        switch command {
        case "cmd_Recast_req":
            delegate?.castSenderDidRequestIDRKeyframe()
        case "cmd_Close_req":
            stopMirrorService()
        default:
            break
        }
    }

    public func serverDidRequestKeyframeRefresh() {
        NSLog("[WXCastiOSSender] Desktop requested IDR Keyframe refresh")
        delegate?.castSenderDidRequestIDRKeyframe()
    }

    // MARK: - ApowerMirror JSON Protocol Handshakes (Decompiled directly from ASM @ 0x11868 - 0x11918 & 0x45160)

    /// 1. StartCast Handshake Payload
    public func sendStartCastPayload() {
        let payload: [String: Any] = [
            "Action": "StartCast",
            "Model": UIDevice.current.model,
            "SysVersion": UIDevice.current.systemVersion,
            "FullScreen": "true",
            "Port": Int(mirrorPort),
            "DeviceType": 1,
            "UseH265": false,
            "Msg": ""
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            server.sendChannelMessage(jsonStr + "\n")
            NSLog("[WXCastiOSSender] Dispatched StartCast payload: %@", jsonStr)
        }
    }

    /// 2. Device Metadata Registration Payload
    public func sendCustomDeviceMetadata() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateStr = dateFormatter.string(from: Date())

        let payload: [String: Any] = [
            "Action": "SendCustomMsg",
            "NAME": UIDevice.current.name,
            "DEVICE": "iPhone",
            "DEVICETYPE": 1,
            "DEVICE_ID": deviceUUID,
            "LINKTYPE": "USB",
            "MANUFACTURER": "Apple",
            "PORT": Int(channelPort),
            "MIRROR_PORT": Int(mirrorPort),
            "SERVER_DATE": dateStr
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            server.sendChannelMessage(jsonStr + "\n")
            NSLog("[WXCastiOSSender] Dispatched CustomMsg registration: %@", jsonStr)
        }
    }

    /// 3. Initial Viewport & Screen Dimensions
    public func sendScreenDimensions() {
        let bounds = UIScreen.main.nativeBounds
        let width = Int(bounds.width)
        let height = Int(bounds.height)

        let originalMsg = "cmd-OriginalResolution-Resp:\(width)_\(height)\n"
        let resolutionMsg = "cmd-Resolution-Resp:\(width)_\(height)\n"
        let rotationMsg = "cmd-Rotation-Resp:0\n"

        server.sendChannelMessage(originalMsg)
        server.sendChannelMessage(resolutionMsg)
        server.sendChannelMessage(rotationMsg)
    }

    /// 4. Viewport Rotation Synchronization
    public func sendRotation(rotation: Int, width: Int, height: Int) {
        let rotMsg = "cmd-Rotation-Resp:\(rotation)\n"
        let resMsg = "cmd-Resolution-Resp:\(width)_\(height)\n"
        server.sendChannelMessage(rotMsg)
        server.sendChannelMessage(resMsg)
        NSLog("[WXCastiOSSender] Synced orientation change: rot=%d, %dx%d", rotation, width, height)
    }
}
