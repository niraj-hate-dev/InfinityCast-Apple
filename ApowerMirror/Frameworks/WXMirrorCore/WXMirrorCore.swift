//
//  WXMirrorCore.swift
//  ApowerMirror / WXMirrorCore
//
//  Reconstructed 1:1 from ApowerMirror WXMirrorCore.framework:
//  - Session Coordinator
//  - Viewport & Canvas Geometry Synchronization
//  - Device Orientation Observer
//  - App Group Settings Configuration
//

import UIKit
import Foundation

public enum WXMirrorState {
    case idle
    case waitingForBroadcast
    case streaming
    case paused
    case terminated
}

public protocol WXMirrorCoreDelegate: AnyObject {
    func mirrorCoreStateDidChange(_ state: WXMirrorState)
    func mirrorCoreDidConnectDesktop()
    func mirrorCoreDidDisconnectDesktop()
}

public final class WXMirrorCore: WXCastiOSSenderDelegate {

    // MARK: - Singleton
    public static let shared = WXMirrorCore()

    // MARK: - Properties
    public weak var delegate: WXMirrorCoreDelegate?
    public private(set) var currentState: WXMirrorState = .idle {
        didSet {
            delegate?.mirrorCoreStateDidChange(currentState)
        }
    }

    private let appGroupName = "group.apowersoft.mirror"
    private var lastOrientation: UIDeviceOrientation = .unknown

    // MARK: - Initialization

    private init() {
        WXCastiOSSender.shared.delegate = self
        setupOrientationObserver()
    }

    // MARK: - Configuration Setup

    public func configureMirroringOptions(fps: Int = 60, bitrate: Int = 4_000_000, resolution: Int = 1080) {
        if let defaults = UserDefaults(suiteName: appGroupName) {
            defaults.set(fps, forKey: "kGroupFps")
            defaults.set(bitrate, forKey: "kGroupBitrate")
            defaults.set(resolution, forKey: "kGroupResolution")
            defaults.set(0, forKey: "kGroupReplayKitRecordType") // 0 = ApowerMirror Mirroring
            defaults.set(true, forKey: "kGroupMirrorVoiceSwitch")
            defaults.synchronize()
            NSLog("[WXMirrorCore] Persisted App Group settings: FPS=%d, Bitrate=%d, Res=%d", fps, bitrate, resolution)
        }
    }

    // MARK: - Session Control

    public func prepareForMirroring() {
        configureMirroringOptions()
        WXCastiOSSender.shared.startMirrorService()
        currentState = .waitingForBroadcast
    }

    public func stopMirroring() {
        WXCastiOSSender.shared.stopMirrorService()
        currentState = .idle
    }

    // MARK: - Orientation Detection & Geometry Sync

    private func setupOrientationObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOrientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleOrientationChanged() {
        let currentOri = UIDevice.current.orientation
        guard currentOri.isValidInterfaceOrientation, currentOri != lastOrientation else { return }
        lastOrientation = currentOri

        let bounds = UIScreen.main.nativeBounds
        var w = Int(bounds.width)
        var h = Int(bounds.height)
        let rotationVal: Int

        switch currentOri {
        case .landscapeLeft:
            rotationVal = 1
            if w < h { swap(&w, &h) }
        case .landscapeRight:
            rotationVal = 3
            if w < h { swap(&w, &h) }
        case .portraitUpsideDown:
            rotationVal = 2
            if w > h { swap(&w, &h) }
        default:
            rotationVal = 0
            if w > h { swap(&w, &h) }
        }

        // Forward to desktop receiver to adjust render canvas instantly
        WXCastiOSSender.shared.sendRotation(rotation: rotationVal, width: w, height: h)
    }

    // MARK: - WXCastiOSSenderDelegate Callbacks

    public func castSenderDidConnectDesktop() {
        currentState = .streaming
        delegate?.mirrorCoreDidConnectDesktop()
    }

    public func castSenderDidDisconnectDesktop() {
        currentState = .idle
        delegate?.mirrorCoreDidDisconnectDesktop()
    }

    public func castSenderDidRequestIDRKeyframe() {
        // Post Darwin notification to extension to trigger immediate keyframe
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.apowermirror.broadcast.Recast" as CFString),
            nil,
            nil,
            true
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
