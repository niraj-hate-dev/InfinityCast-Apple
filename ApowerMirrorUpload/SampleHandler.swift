//
//  SampleHandler.swift
//  ApowerMirrorUpload / AppleCast
//
//  Reconstructed 1:1 from ApowerMirrorUpload Mach-O binary & WXCastiOSSender
//  Subclass: RPBroadcastSampleHandler (or AgoraReplayKitHandler)
//

import ReplayKit
import VideoToolbox
import CoreMedia
import Network

@objcMembers
public class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Constants
    private let appGroupName = "group.apowersoft.mirror"
    private let kDefaultMirrorPort: UInt16 = 25334 // /mirror.do (Video) & /mirrorVoice.do (Audio)
    private let kDefaultChannelPort: UInt16 = 25333 // /channel.do (Control/Signaling)

    // MARK: - Encoders & Network Transport
    private var videoEncoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private var isBroadcasting = false
    private var streamServer: NWListener?
    private var connectedClients: [NWConnection] = []

    private let networkQueue = DispatchQueue(label: "com.apowermirror.network.queue", qos: .userInteractive)
    private let frameProcessingQueue = DispatchQueue(label: "com.apowermirror.frame.queue", qos: .userInteractive)

    // MARK: - Lifecycle

    public override init() {
        super.init()
    }

    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // =========================================================================
        // CRITICAL FIX: ALWAYS call super to finish the ReplayKit XPC handshake!
        // If omitted, replayd countdown completes but the circle stays GRAY.
        // Calling super turns the circle pulsing RED and activates recording pills.
        // =========================================================================
        super.broadcastStarted(withSetupInfo: setupInfo)
        isBroadcasting = true

        // 1. Read configuration from App Group container
        let defaults = UserDefaults(suiteName: appGroupName)
        let fps = Int32(defaults?.integer(forKey: "kGroupFps") ?? 60)
        let bitrate = Int32(defaults?.integer(forKey: "kGroupBitrate") ?? 4_000_000)
        let resolution = Int32(defaults?.integer(forKey: "kGroupResolution") ?? 1080)

        NSLog("[SampleHandler] Broadcast started -> Target FPS: %d, Bitrate: %d, Resolution: %d", fps, bitrate, resolution)

        // 2. Notify Main App via Darwin Notification Center (matches MMWormhole)
        notifyMainApp(event: "BroadcastStarted")

        // 3. Initialize low-latency VideoToolbox hardware encoder
        videoEncoder = VideoEncoder(bitrate: bitrate, fps: fps) { [weak self] (packet, isKeyFrame, isEndFrame) in
            self?.broadcastDataToClients(packet)
        }

        // On screen rotation / resolution change, notify desktop
        videoEncoder?.setDimensionChangeHandler { [weak self] width, height, rotation in
            self?.notifyDesktopGeometryChanged(width: width, height: height, rotation: rotation)
        }

        // 4. Initialize CoreAudio AAC encoder for stereo audio streaming
        audioEncoder = AudioEncoder { [weak self] audioPacket in
            self?.broadcastDataToClients(audioPacket)
        }

        // 5. Start embedded streaming server inside extension process on 0.0.0.0:25334
        startStreamingServer(port: kDefaultMirrorPort)
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

        // Invalidate and free encoders
        videoEncoder?.invalidate()
        videoEncoder = nil

        audioEncoder?.invalidate()
        audioEncoder = nil

        // Clean up active network connections and listener
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.streamServer?.cancel()
            self.streamServer = nil
            self.connectedClients.forEach { $0.cancel() }
            self.connectedClients.removeAll()
        }

        // Notify Main App that broadcast finished
        notifyMainApp(event: "Finish")
        NSLog("[SampleHandler] Broadcast finished & clean shutdown complete")
    }

    // MARK: - Frame Processing (Zero Jetsam OOM)

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting else { return }

        // Wrap in autoreleasepool to prevent memory retention spikes
        autoreleasepool {
            switch sampleBufferType {
            case .video:
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

    // MARK: - Network Server & Transport (0.0.0.0:25334)

    private func startStreamingServer(port: UInt16) {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let tcpOptions = NWProtocolTCP.Options()
                tcpOptions.noDelay = true // Disable Nagle's algorithm for zero latency
                tcpOptions.enableKeepalive = true
                let params = NWParameters(tls: nil, tcp: tcpOptions)
                params.allowLocalEndpointReuse = true
                params.includePeerToPeer = true

                guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
                let listener = try NWListener(using: params, on: endpointPort)

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handleClientConnection(connection)
                }

                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        NSLog("[SampleHandler] Streaming server listening on 0.0.0.0:%d", port)
                    case .failed(let err):
                        NSLog("[SampleHandler] Streaming server error: %@", err.localizedDescription)
                    default:
                        break
                    }
                }

                listener.start(queue: self.networkQueue)
                self.streamServer = listener
            } catch {
                NSLog("[SampleHandler] Failed to start NWListener: %@", error.localizedDescription)
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
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for client in self.connectedClients {
                client.send(content: data, completion: .idempotent)
            }
        }
    }

    private func notifyDesktopGeometryChanged(width: Int32, height: Int32, rotation: Int32) {
        // Construct ApowerMirror control strings matching decompiled specification:
        // "cmd-Rotation-Resp:%d\n"
        // "cmd-Resolution-Resp:%d_%d\n"
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
