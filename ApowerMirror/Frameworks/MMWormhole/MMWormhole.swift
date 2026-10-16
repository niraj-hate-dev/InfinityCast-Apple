//
//  MMWormhole.swift
//  ApowerMirror / Frameworks / MMWormhole
//
//  Reconstructed 1:1 from MMWormhole.framework used in ApowerMirror.
//  Enables high-performance inter-process communication (IPC) between
//  Main App and App Extension using App Group shared container + Darwin Notifications.
//

import Foundation

public final class MMWormhole {

    // MARK: - Properties
    public let applicationGroupIdentifier: String
    public let directory: String?
    private var listeners: [String: (Any?) -> Void] = [:]
    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

    // MARK: - Initialization

    public init(applicationGroupIdentifier: String, optionalDirectory: String? = nil) {
        self.applicationGroupIdentifier = applicationGroupIdentifier
        self.directory = optionalDirectory
    }

    // MARK: - Directory Resolution

    private func messagePassingDirectoryPath() -> URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: applicationGroupIdentifier) else {
            return nil
        }
        if let dir = directory {
            let subDir = containerURL.appendingPathComponent(dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: nil)
            return subDir
        }
        return containerURL
    }

    private func filePath(for identifier: String) -> URL? {
        return messagePassingDirectoryPath()?.appendingPathComponent("\(identifier).archive")
    }

    // MARK: - Message Passing (Producer)

    public func passMessageObject(_ messageObject: Any?, identifier: String) {
        guard let url = filePath(for: identifier) else { return }

        if let object = messageObject {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false) {
                try? data.write(to: url, options: .atomic)
            }
        } else {
            try? FileManager.default.removeItem(at: url)
        }

        // Post Darwin Notification across process boundary
        let notificationName = CFNotificationName(identifier as CFString)
        CFNotificationCenterPostNotification(
            notificationCenter,
            notificationName,
            nil,
            nil,
            true
        )
    }

    // MARK: - Message Retrieval (Consumer)

    public func messageWithIdentifier(_ identifier: String) -> Any? {
        guard let url = filePath(for: identifier),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
    }

    public func clearMessageContents(for identifier: String) {
        guard let url = filePath(for: identifier) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Listening (Observer)

    public func listenForMessageWithIdentifier(_ identifier: String, listener: @escaping (Any?) -> Void) {
        listeners[identifier] = listener

        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let notificationName = CFNotificationName(identifier as CFString)

        CFNotificationCenterAddObserver(
            notificationCenter,
            observer,
            { (_, observer, name, _, _) in
                guard let observer = observer, let name = name else { return }
                let wormhole = Unmanaged<MMWormhole>.fromOpaque(observer).takeUnretainedValue()
                let identifierStr = name.rawValue as String
                let message = wormhole.messageWithIdentifier(identifierStr)

                DispatchQueue.main.async {
                    wormhole.listeners[identifierStr]?(message)
                }
            },
            notificationName.rawValue,
            nil,
            .deliverImmediately
        )
    }

    public func stopListeningForMessageWithIdentifier(_ identifier: String) {
        listeners.removeValue(forKey: identifier)
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let notificationName = CFNotificationName(identifier as CFString)
        CFNotificationCenterRemoveObserver(notificationCenter, observer, notificationName, nil)
    }

    deinit {
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterRemoveEveryObserver(notificationCenter, observer)
    }
}
