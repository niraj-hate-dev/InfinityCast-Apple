//
//  MMWormholeManager.swift
//  ApowerMirror / Services
//
//  Cross-process IPC Bridge between Main App and ReplayKit Extension
//  Matching MMWormhole.framework decompiled architecture
//

import Foundation

public protocol MMWormholeManagerDelegate: AnyObject {
    func wormholeDidReceiveBroadcastStarted()
    func wormholeDidReceiveBroadcastFinished()
    func wormholeDidReceivePauseVideo()
    func wormholeDidReceiveResumeVideo()
}

public final class MMWormholeManager {

    // MARK: - Singleton
    public static let shared = MMWormholeManager()

    // MARK: - Properties
    public weak var delegate: MMWormholeManagerDelegate?
    private let appGroupId = "group.apowersoft.mirror"
    private let wormholeDirName = "wormhole"

    // MARK: - Initialization

    private init() {
        setupDarwinNotificationListeners()
    }

    // MARK: - Darwin Notification Setup

    private func setupDarwinNotificationListeners() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        let observer = Unmanaged.passUnretained(self).toOpaque()

        let notifications = [
            "com.apowermirror.broadcast.BroadcastStarted",
            "com.apowermirror.broadcast.Finish",
            "com.apowermirror.broadcast.PauseVideo",
            "com.apowermirror.broadcast.ResumeVideo"
        ]

        for notif in notifications {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { (_, observer, name, _, _) in
                    guard let observer = observer, let name = name else { return }
                    let manager = Unmanaged<MMWormholeManager>.fromOpaque(observer).takeUnretainedValue()
                    manager.handleDarwinNotification(name: name.rawValue as String)
                },
                notif as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func handleDarwinNotification(name: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NSLog("[MMWormholeManager] Received Darwin notification: %@", name)

            if name.contains("BroadcastStarted") {
                // Reply with acknowledgment
                self.sendBroadcastStartedCallback()
                self.delegate?.wormholeDidReceiveBroadcastStarted()
            } else if name.contains("Finish") {
                self.delegate?.wormholeDidReceiveBroadcastFinished()
            } else if name.contains("PauseVideo") {
                self.delegate?.wormholeDidReceivePauseVideo()
            } else if name.contains("ResumeVideo") {
                self.delegate?.wormholeDidReceiveResumeVideo()
            }
        }
    }

    // MARK: - Outgoing Signals to Extension

    public func sendBroadcastStartedCallback() {
        postDarwinNotification(name: "com.apowermirror.broadcast.BroadcastStartedCallBack")
    }

    public func sendStopMirror() {
        postDarwinNotification(name: "com.apowermirror.broadcast.StopMirror")
    }

    public func sendRequestKeyframe() {
        postDarwinNotification(name: "com.apowermirror.broadcast.Recast")
    }

    private func postDarwinNotification(name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    // MARK: - App Group File Storage (Optional MMWormhole Directory)

    public func writeMessageObject(_ object: [String: Any], identifier: String) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return }
        let wormholeURL = containerURL.appendingPathComponent(wormholeDirName)

        try? FileManager.default.createDirectory(at: wormholeURL, withIntermediateDirectories: true)
        let fileURL = wormholeURL.appendingPathComponent("\(identifier).archive")

        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: fileURL)
            postDarwinNotification(name: "com.apowermirror.wormhole.\(identifier)")
        }
    }

    public func readMessageObject(identifier: String) -> [String: Any]? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let fileURL = containerURL.appendingPathComponent(wormholeDirName).appendingPathComponent("\(identifier).archive")

        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return nil
    }
}
