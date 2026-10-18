//
//  BroadcastPickerManager.swift
//  ApowerMirror / Services
//
//  Programmatic RPSystemBroadcastPickerView presentation & extension binding
//

import UIKit
import ReplayKit

public protocol BroadcastPickerManagerDelegate: AnyObject {
    func broadcastCaptureStateChanged(isCaptured: Bool)
}

public final class BroadcastPickerManager {

    // MARK: - Singleton
    public static let shared = BroadcastPickerManager()

    // MARK: - Properties
    public weak var delegate: BroadcastPickerManagerDelegate?
    public var extensionBundleId: String {
        if let pluginsUrl = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: pluginsUrl, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "appex" {
                if let extBundle = Bundle(url: item), let extId = extBundle.bundleIdentifier {
                    NSLog("[BroadcastPickerManager] Discovered embedded extension bundle ID: %@", extId)
                    return extId
                }
            }
        }
        if let mainId = Bundle.main.bundleIdentifier, !mainId.isEmpty {
            return "\(mainId).ApowerMirrorUpload"
        }
        return "com.apowersoft.ApowerMirror.ApowerMirrorUpload"
    }
    private var pickerView: RPSystemBroadcastPickerView?

    // MARK: - Initialization

    private init() {
        setupScreenCaptureObserver()
    }

    // MARK: - Setup & Programmatic Presentation

    /// Creates and configures the RPSystemBroadcastPickerView
    public func preparePickerView(in view: UIView) {
        if let existing = pickerView, existing.superview != nil {
            existing.removeFromSuperview()
        }
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = extensionBundleId
        picker.showsMicrophoneButton = false
        picker.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin]
        
        // Keep in view hierarchy with minimal opacity so touch events can be synthesized
        picker.alpha = 0.02
        view.addSubview(picker)
        self.pickerView = picker
        NSLog("[BroadcastPickerManager] Prepared RPSystemBroadcastPickerView with extension: %@", extensionBundleId)
    }

    /// Programmatically triggers the ReplayKit broadcast picker dialog modal
    public func launchBroadcastPicker(from parentView: UIView) {
        if pickerView == nil || pickerView?.superview == nil {
            preparePickerView(in: parentView)
        }

        guard let picker = pickerView else { return }
        picker.preferredExtension = extensionBundleId

        // Find the internal UIButton inside RPSystemBroadcastPickerView
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                NSLog("[BroadcastPickerManager] Programmatically triggered RPSystemBroadcastPickerView modal for %@", extensionBundleId)
                return
            }
        }

        NSLog("[BroadcastPickerManager] Warning: Could not find internal button inside RPSystemBroadcastPickerView")
    }

    /// Programmatically presents the ReplayKit broadcast picker dialog modal from top window
    public func presentBroadcastPicker() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
            guard let targetView = window else { return }
            self.launchBroadcastPicker(from: targetView)
        }
    }

    /// Signals the ReplayKit Broadcast Extension to finish and stop recording via Darwin Notification
    public func stopBroadcast() {
        let notificationName = "com.apowermirror.broadcast.StopBroadcast" as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName),
            nil,
            nil,
            true
        )
        NSLog("[BroadcastPickerManager] Dispatched StopBroadcast Darwin notification to Extension")
    }

    // MARK: - Screen Capture Observation

    private func setupScreenCaptureObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenCapturedChanged),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleScreenCapturedChanged() {
        let isCaptured = UIScreen.main.isCaptured
        NSLog("[BroadcastPickerManager] UIScreen.main.isCaptured changed to: %@", isCaptured ? "TRUE (Recording)" : "FALSE (Stopped)")
        delegate?.broadcastCaptureStateChanged(isCaptured: isCaptured)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
