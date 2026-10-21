//
//  SampleHandler.swift
//  ApowerMirrorUpload / AppleCast
//
//  ReplayKit Broadcast Upload Extension
//  Subclass: RPBroadcastSampleHandler
//  Pure POSIX BSD Socket streaming to Main App loopback IPC (127.0.0.1:8888)
//  Hardened for iOS 18: Immediate XPC handshake return, Zero-Jetsam OOM,
//  SO_NOSIGPIPE protection against pipe termination signals.
//

import ReplayKit
import VideoToolbox
import CoreMedia
import Darwin

@objcMembers
public class SampleHandler: RPBroadcastSampleHandler {

    // MARK: - Constants
    private static let kIpcPort: UInt16 = 8888
    private static let kAudioIpcPort: UInt16 = 8889
    private static let kStopNotification = "com.apowermirror.broadcast.StopBroadcast"

    // MARK: - Encoders & Network Transport
    private var videoEncoder: VideoEncoder?
    private var audioEncoder: AudioEncoder?
    private var isBroadcasting = false
    private var bsdClientSocket: Int32 = -1
    private var audioBsdClientSocket: Int32 = -1
    private let socketLock = NSLock()
    private let audioSocketLock = NSLock()
    private var audioFrameCount: Int = 0
    private var isAudioConnecting = false
    private let audioConnectLock = NSLock()

    private let networkQueue = DispatchQueue(label: "com.apowermirror.upload.network", qos: .userInteractive)
    private var targetFps: Int32 = 60
    private var targetBitrate: Int32 = 4_000_000

    // MARK: - Lifecycle

    public override init() {
        super.init()
    }

    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // =========================================================================
        // CRITICAL iOS 18 REQUIREMENT:
        // Must return in < 20ms so replayd XPC watchdog finishes the handshake.
        // Calling super turns the indicator pulsating RED and starts frame ingestion.
        // =========================================================================
        super.broadcastStarted(withSetupInfo: setupInfo)
        isBroadcasting = true

        NSLog("[SampleHandler] ReplayKit broadcast started -> XPC handshake acknowledged")

        // 1. Notify Main App via Darwin Notification Center
        notifyMainApp(event: "BroadcastStarted")

        // 2. Setup observer to stop broadcast when user taps Stop in Main App
        setupDarwinStopReceiver()

        // 3. Connect non-blocking BSD sockets to Main App IPC on 127.0.0.1:8888 (Video) & 8889 (Audio)
        connectToMainAppIPC()
        connectToAudioIPC()
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

        // Invalidate and free video encoder
        videoEncoder?.invalidate()
        videoEncoder = nil

        // Invalidate and free audio encoder
        audioEncoder?.invalidate()
        audioEncoder = nil
        audioFrameCount = 0

        // Clean up BSD sockets
        closeSocket()
        closeAudioSocket()

        // Notify Main App that broadcast finished
        notifyMainApp(event: "Finish")
        NSLog("[SampleHandler] Clean shutdown complete")
    }

    // MARK: - Frame Processing (Zero Jetsam OOM)

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isBroadcasting else { return }

        // Wrap in autoreleasepool to prevent memory spikes under high frame rates
        autoreleasepool {
            switch sampleBufferType {
            case .video:
                // Lazily initialize hardware VideoEncoder on the very first video frame
                if videoEncoder == nil {
                    videoEncoder = VideoEncoder(bitrate: targetBitrate, fps: targetFps) { [weak self] (packet, isKeyFrame, isEndFrame) in
                        self?.sendDataToMainApp(packet)
                    }

                    videoEncoder?.setDimensionChangeHandler { [weak self] width, height, rotation in
                        self?.sendGeometryChange(width: width, height: height, rotation: rotation)
                    }
                }

                // Extract orientation attachment if available
                var orientation: CGImagePropertyOrientation = .up
                if let orientationAttachment = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber {
                    orientation = CGImagePropertyOrientation(rawValue: orientationAttachment.uint32Value) ?? .up
                }

                // Feed CVPixelBuffer to hardware encoder
                videoEncoder?.encode(sampleBuffer: sampleBuffer, orientation: orientation)

            case .audioApp:
                self.audioFrameCount += 1
                if self.audioFrameCount <= 5 || self.audioFrameCount % 200 == 0 {
                    let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
                    NSLog("[SampleHandler] .audioApp frame #%d received (%d samples)", self.audioFrameCount, numSamples)
                }

                // Lazily initialize AudioEncoder on the first audio frame
                if audioEncoder == nil {
                    NSLog("[SampleHandler] First .audioApp frame received -> Initializing AudioEncoder")
                    audioEncoder = AudioEncoder(sampleRate: 44100.0, channels: 2) { [weak self] packet in
                        self?.sendAudioDataToMainApp(packet)
                    }
                }
                audioEncoder?.encode(sampleBuffer: sampleBuffer)

            case .audioMic:
                // Microphone audio ignored to prevent ASBD sampling conflicts with app audio
                break

            @unknown default:
                break
            }
        }
    }

    // MARK: - Outbound POSIX BSD Socket IPC (to 127.0.0.1:8888)

    private func connectToMainAppIPC() {
        networkQueue.async { [weak self] in
            guard let self = self, self.isBroadcasting else { return }

            self.socketLock.lock()
            if self.bsdClientSocket >= 0 {
                close(self.bsdClientSocket)
                self.bsdClientSocket = -1
            }
            self.socketLock.unlock()

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[SampleHandler] Failed to create BSD socket: errno %d", errno)
                return
            }

            // CRITICAL: Prevent SIGPIPE signal termination when peer closes connection
            var noSigpipe: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

            // Disable Nagle algorithm for real-time low-latency packet streaming
            var noDelay: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            // Expand socket send buffer to 2 MB to absorb frame bursts
            var sndBuf: Int32 = 2 * 1024 * 1024
            setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

            // Set sending timeout to 1 second so frame thread is never blocked
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
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

            if res == 0 {
                self.socketLock.lock()
                self.bsdClientSocket = sock
                self.socketLock.unlock()
                NSLog("[SampleHandler] Connected to Main App IPC on 127.0.0.1:%d", SampleHandler.kIpcPort)
                // Force an immediate SPS + PPS + IDR keyframe now that IPC is live
                self.videoEncoder?.forceKeyFrame()
            } else {
                NSLog("[SampleHandler] Connect to 127.0.0.1:%d failed (errno: %d), retrying in 250ms...", SampleHandler.kIpcPort, errno)
                close(sock)
                // Retry connection if broadcast is still active
                if self.isBroadcasting {
                    self.networkQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.connectToMainAppIPC()
                    }
                }
            }
        }
    }

    private func sendDataToMainApp(_ data: Data) {
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
            let totalLength = data.count

            while totalSent < totalLength {
                let bytesToSend = totalLength - totalSent
                let sent = send(sock, basePtr.advanced(by: totalSent), bytesToSend, 0)
                if sent <= 0 {
                    // Send failed (EPIPE / ECONNRESET)
                    NSLog("[SampleHandler] Socket send failed (%d), reconnecting...", errno)
                    closeSocket()
                    connectToMainAppIPC()
                    break
                }
                totalSent += sent
            }
        }
    }

    private func sendGeometryChange(width: Int32, height: Int32, rotation: Int32) {
        // Pure H.264 video stream: SPS headers already carry width, height, and display aspect ratio.
        // Keeping the video stream pure binary prevents socket desynchronization.
        NSLog("[SampleHandler] Stream geometry updated: %dx%d (rotation: %d)", width, height, rotation)
    }

    private func closeSocket() {
        socketLock.lock()
        defer { socketLock.unlock() }
        if bsdClientSocket >= 0 {
            close(bsdClientSocket)
            bsdClientSocket = -1
        }
    }

    // MARK: - Outbound Audio POSIX BSD Socket IPC (to 127.0.0.1:8889)

    private func connectToAudioIPC() {
        audioConnectLock.lock()
        if isAudioConnecting {
            audioConnectLock.unlock()
            return
        }
        isAudioConnecting = true
        audioConnectLock.unlock()

        networkQueue.async { [weak self] in
            guard let self = self, self.isBroadcasting else {
                self?.audioConnectLock.lock()
                self?.isAudioConnecting = false
                self?.audioConnectLock.unlock()
                return
            }

            self.audioSocketLock.lock()
            if self.audioBsdClientSocket >= 0 {
                close(self.audioBsdClientSocket)
                self.audioBsdClientSocket = -1
            }
            self.audioSocketLock.unlock()

            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                NSLog("[SampleHandler] Failed to create audio BSD socket: errno %d", errno)
                self.audioConnectLock.lock()
                self.isAudioConnecting = false
                self.audioConnectLock.unlock()
                return
            }

            var noSigpipe: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

            var noDelay: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

            var sndBuf: Int32 = 512 * 1024
            setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = SampleHandler.kAudioIpcPort.bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            self.audioConnectLock.lock()
            self.isAudioConnecting = false
            self.audioConnectLock.unlock()

            if res == 0 {
                self.audioSocketLock.lock()
                self.audioBsdClientSocket = sock
                self.audioSocketLock.unlock()
                NSLog("[SampleHandler] Connected to Main App Audio IPC on 127.0.0.1:%d", SampleHandler.kAudioIpcPort)
            } else {
                close(sock)
                if self.isBroadcasting {
                    self.networkQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.connectToAudioIPC()
                    }
                }
            }
        }
    }

    private func sendAudioDataToMainApp(_ data: Data) {
        audioSocketLock.lock()
        let sock = audioBsdClientSocket
        audioSocketLock.unlock()

        guard sock >= 0 else {
            connectToAudioIPC()
            return
        }

        data.withUnsafeBytes { rawBuf in
            guard let basePtr = rawBuf.baseAddress else { return }
            var totalSent = 0
            let totalLength = data.count

            while totalSent < totalLength {
                let bytesToSend = totalLength - totalSent
                let sent = send(sock, basePtr.advanced(by: totalSent), bytesToSend, 0)
                if sent <= 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK {
                        NSLog("[SampleHandler] Audio socket send failed (errno: %d), reconnecting...", errno)
                        closeAudioSocket()
                        connectToAudioIPC()
                    }
                    break
                }
                totalSent += sent
            }
        }
    }

    private func closeAudioSocket() {
        audioSocketLock.lock()
        defer { audioSocketLock.unlock() }
        if audioBsdClientSocket >= 0 {
            close(audioBsdClientSocket)
            audioBsdClientSocket = -1
        }
    }

    // MARK: - Darwin Notification Inter-Process Communication

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
}
