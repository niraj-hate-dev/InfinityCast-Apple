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
    private let extensionBundleId = "com.apowersoft.ApowerMirror.ApowerMirrorUpload"
    private var pickerView: RPSystemBroadcastPickerView?

    // MARK: - Initialization

    private init() {
        setupScreenCaptureObserver()
    }

    // MARK: - Setup & Programmatic Presentation

    /// Creates and configures the RPSystemBroadcastPickerView
    public func preparePickerView(in view: UIView) {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = extensionBundleId
        picker.showsMicrophoneButton = true
        picker.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin]
        
        // Hide visually while keeping in view hierarchy so touch events can be synthesized
        picker.alpha = 0.01
        view.addSubview(picker)
        self.pickerView = picker
    }

    /// Programmatically triggers the ReplayKit broadcast picker dialog modal
    public func launchBroadcastPicker(from parentView: UIView) {
        if pickerView == nil || pickerView?.superview == nil {
            preparePickerView(in: parentView)
        }

        guard let picker = pickerView else { return }

        // Find the internal UIButton inside RPSystemBroadcastPickerView
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                NSLog("[BroadcastPickerManager] Programmatically triggered RPSystemBroadcastPickerView modal")
                return
            }
        }

        NSLog("[BroadcastPickerManager] Warning: Could not find internal button inside RPSystemBroadcastPickerView")
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
