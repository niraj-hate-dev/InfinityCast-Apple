//
//  SampleHandler.swift
//  ApowerMirrorUpload / AppleCast
//
//  Reconstructed 1:1 from ApowerMirrorUpload Mach-O binary & WXCastiOSSender
//  Subclass: RPBroadcastSampleHandler
//  Hardened for iOS 18: Immediate XPC handshake return, Zero-Jetsam OOM,
//  Outbound client stream piping directly to Main App's 127.0.0.1:25334 bridge.
//

import ReplayKit
import VideoToolbox
import CoreMedia
import Network
import Darwin

@objcMembers
public class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Constants
    private let appGroupName = "group.apowersoft.mirror"
    private let kDefaultMirrorPort: UInt16 = 25334 // /mirror.do (Video)

    // MARK: - Encoders & Network Transport
    private var videoEncoder: VideoEncoder?
    private var isBroadcasting = false
    private var mainAppConnection: NWConnection?
    private var bsdClientSocket: Int32 = -1

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
        // Calling super turns the circle pulsating RED and starts frame ingestion.
        // =========================================================================
        super.broadcastStarted(withSetupInfo: setupInfo)
        isBroadcasting = true

        NSLog("[SampleHandler] ReplayKit broadcast started -> Acknowledging XPC handshake")

        // 1. Notify Main App via Darwin Notification Center
        notifyMainApp(event: "BroadcastStarted")

        // 2. Read preferences from App Group defaults if available
        let defaults = UserDefaults(suiteName: appGroupName)
        targetFps = Int32(defaults?.integer(forKey: "kGroupFps") ?? 60)
        targetBitrate = Int32(defaults?.integer(forKey: "kGroupBitrate") ?? 3_500_000)

        // 3. Connect as outbound client to Main App's streaming engine on 127.0.0.1:25334
        connectToMainAppBridge(port: kDefaultMirrorPort)
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

        NSLog("[SampleHandler] Broadcast finished -> cleaning up encoders and connections")

        // Invalidate and free encoders
        videoEncoder?.invalidate()
        videoEncoder = nil

        // Clean up outbound bridge connection
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.mainAppConnection?.cancel()
            self.mainAppConnection = nil
        }

        // Clean up BSD socket
        if bsdClientSocket >= 0 {
            close(bsdClientSocket)
            bsdClientSocket = -1
        }

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
                        self?.broadcastDataToBridge(packet)
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
                break

            @unknown default:
                break
            }
        }
    }

    // MARK: - Outbound Client Streaming Engine (to 127.0.0.1:25334)

    private func connectToMainAppBridge(port: UInt16) {
        networkQueue.async { [weak self] in
            guard let self = self, self.isBroadcasting else { return }

            // 1. Attempt NWConnection (outbound)
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)

            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            let conn = NWConnection(host: "127.0.0.1", port: endpointPort, using: params)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("[SampleHandler] Connected to Main App streaming bridge on 127.0.0.1:%d", port)
                case .failed(let err):
                    NSLog("[SampleHandler] NWConnection bridge note: %@ (attempting BSD fallback)", err.localizedDescription)
                default:
                    break
                }
            }

            conn.start(queue: self.networkQueue)
            self.mainAppConnection = conn

            // 2. Direct BSD Socket connection (outbound fallback)
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            if sock >= 0 {
                var nd: Int32 = 1
                setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &nd, socklen_t(MemoryLayout<Int32>.size))

                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

                let res = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }

                if res == 0 {
                    self.bsdClientSocket = sock
                    NSLog("[SampleHandler] Connected via BSD client socket to 127.0.0.1:%d", port)
                } else {
                    close(sock)
                }
            }
        }
    }

    private func broadcastDataToBridge(_ data: Data) {
        // 1. Dispatch via NWConnection
        if let conn = mainAppConnection, conn.state == .ready {
            conn.send(content: data, completion: .idempotent)
        }

        // 2. Dispatch via BSD client socket
        if bsdClientSocket >= 0 {
            data.withUnsafeBytes { rawBuf in
                guard let basePtr = rawBuf.baseAddress else { return }
                _ = send(self.bsdClientSocket, basePtr, data.count, 0)
            }
        }
    }

    private func notifyDesktopGeometryChanged(width: Int32, height: Int32, rotation: Int32) {
        let rotationMsg = "cmd-Rotation-Resp:\(rotation)\n"
        let resolutionMsg = "cmd-Resolution-Resp:\(width)_\(height)\n"

        if let rotData = rotationMsg.data(using: .utf8), let resData = resolutionMsg.data(using: .utf8) {
            broadcastDataToBridge(rotData)
            broadcastDataToBridge(resData)
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
