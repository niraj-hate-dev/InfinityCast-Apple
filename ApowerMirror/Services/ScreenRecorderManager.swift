//
//  ScreenRecorderManager.swift
//  ApowerMirror / Services
//
//  Direct In-App Screen Recording Manager using RPScreenRecorder.
//  Operates directly in the Main App process to eliminate Extension crashes,
//  bypasses the 50MB Jetsam limit, and uses the standard iOS Screen Recording
//  permission prompt. Encodes CVPixelBuffer via VideoEncoder and forwards
//  H.264 streams to WXCastiOSSender on port 25334.
//

import UIKit
import ReplayKit
import CoreMedia
import ImageIO

public protocol ScreenRecorderManagerDelegate: AnyObject {
    func screenRecorderDidStart()
    func screenRecorderDidStop(error: Error?)
    func screenRecorderDidFail(error: Error)
}

public final class ScreenRecorderManager {

    // MARK: - Singleton
    public static let shared = ScreenRecorderManager()

    // MARK: - Properties
    public weak var delegate: ScreenRecorderManagerDelegate?
    private let recorder = RPScreenRecorder.shared()
    private var videoEncoder: VideoEncoder?
    private var isRecording = false

    // MARK: - Initialization
    private init() {
        recorder.isMicrophoneEnabled = false
    }

    public var isCapturing: Bool {
        return recorder.isRecording
    }

    // MARK: - Screen Capture Lifecycle

    /// Starts in-app screen capture and prompts the user with the native iOS permission dialog
    public func startRecording(completion: ((Bool, Error?) -> Void)? = nil) {
        guard !recorder.isRecording else {
            completion?(true, nil)
            return
        }

        guard recorder.isAvailable else {
            let error = NSError(
                domain: "com.apowermirror",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ReplayKit Screen Recording is not available on this device."]
            )
            self.delegate?.screenRecorderDidFail(error: error)
            completion?(false, error)
            return
        }

        // Initialize hardware H.264 VideoEncoder (60 FPS, 4 Mbps)
        videoEncoder = VideoEncoder(bitrate: 4_000_000, fps: 60) { (packet, isKeyFrame, isEndFrame) in
            // Stream encoded H.264 NALUs directly to desktop receiver on port 25334
            WXCastiOSSender.shared.sendVideoData(packet)
        }

        videoEncoder?.setDimensionChangeHandler { width, height, rotation in
            WXCastiOSSender.shared.sendRotation(rotation: Int(rotation), width: Int(width), height: Int(height))
        }

        NSLog("[ScreenRecorderManager] Requesting in-app screen capture permission from iOS...")

        recorder.startCapture(handler: { [weak self] (sampleBuffer, bufferType, error) in
            if let error = error {
                NSLog("[ScreenRecorderManager] Capture buffer error: %@", error.localizedDescription)
                return
            }

            guard let self = self, self.isRecording else { return }

            if bufferType == .video {
                autoreleasepool {
                    self.videoEncoder?.encode(sampleBuffer: sampleBuffer, orientation: .up)
                }
            }
        }) { [weak self] (error) in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("[ScreenRecorderManager] Screen recording failed to start: %@", error.localizedDescription)
                    self?.isRecording = false
                    self?.delegate?.screenRecorderDidFail(error: error)
                    completion?(false, error)
                } else {
                    NSLog("[ScreenRecorderManager] Screen recording started successfully!")
                    self?.isRecording = true
                    self?.delegate?.screenRecorderDidStart()
                    completion?(true, nil)
                }
            }
        }
    }

    /// Stops in-app screen capture cleanly
    public func stopRecording(completion: ((Error?) -> Void)? = nil) {
        guard recorder.isRecording else {
            isRecording = false
            completion?(nil)
            return
        }

        NSLog("[ScreenRecorderManager] Stopping screen recording...")
        recorder.stopCapture { [weak self] (error) in
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.videoEncoder?.invalidate()
                self?.videoEncoder = nil
                if let error = error {
                    NSLog("[ScreenRecorderManager] Stop capture error: %@", error.localizedDescription)
                } else {
                    NSLog("[ScreenRecorderManager] Screen capture stopped cleanly")
                }
                self?.delegate?.screenRecorderDidStop(error: error)
                completion?(error)
            }
        }
    }

    /// Triggers an immediate IDR keyframe insertion for new client connections or cmd_Recast_req
    public func requestKeyframe() {
        videoEncoder?.forceKeyFrame()
    }
}
