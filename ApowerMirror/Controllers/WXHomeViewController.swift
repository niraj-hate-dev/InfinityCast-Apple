//
//  WXHomeViewController.swift
//  ApowerMirror
//
//  Clean Direct In-App Screen Recording & Real-time Live Diagnostics:
//  - Prominent Start Screen Recording button with iOS permission prompt
//  - Live ReplayKit Screen Recording Status Card (Success / Error / Duration)
//  - Live Windows PC Receiver Connection Status Card (Connected / Listening / Error)
//  - Seamless fallback to System Broadcast Extension if desired
//

import UIKit
import ReplayKit

@objc(WXHomeViewController)
open class WXHomeViewController: UIViewController, ScreenRecorderManagerDelegate, WXCastiOSSenderDelegate, BroadcastPickerManagerDelegate {

    // MARK: - UI Components
    private var nativePickerView: RPSystemBroadcastPickerView?
    private var stopButton: UIButton?
    private var scanBtnSubLabel: UILabel?
    private var hintLabel: UILabel?
    private var pulseLayer: CAShapeLayer?

    // Live Diagnostic UI Cards
    private var replayKitStatusCard: UIView?
    private var replayKitDotView: UIView?
    private var replayKitTitleLabel: UILabel?
    private var replayKitDetailLabel: UILabel?

    private var connectionStatusCard: UIView?
    private var connectionDotView: UIView?
    private var connectionTitleLabel: UILabel?
    private var connectionDetailLabel: UILabel?

    private var systemBroadcastButton: UIButton?

    // State Tracking
    private var durationTimer: Timer?
    private var recordingSeconds = 0
    private var lastErrorMessage: String?
    private var isDesktopConnected = false

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupObservers()

        // Bind delegates
        ScreenRecorderManager.shared.delegate = self
        WXCastiOSSender.shared.delegate = self
        BroadcastPickerManager.shared.delegate = self

        // Prepare broadcast picker view in hierarchy
        BroadcastPickerManager.shared.preparePickerView(in: view)
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        updateStatusCards()
        startPulseAnimation()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPulseAnimation()
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let picker = nativePickerView {
            picker.preferredExtension = BroadcastPickerManager.shared.extensionBundleId
            for subview in picker.subviews {
                if let button = subview as? UIButton {
                    button.frame = picker.bounds
                    button.tintColor = .white
                    button.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
                }
            }
        }
    }

    // MARK: - UI Construction

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1.0)
        title = "ApowerMirror"

        // Top decorative blue banner
        let topBg = UIView()
        topBg.translatesAutoresizingMaskIntoConstraints = false
        topBg.backgroundColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 1.0)
        view.addSubview(topBg)

        // Device Info Header Card
        let infoCard = UIView()
        infoCard.translatesAutoresizingMaskIntoConstraints = false
        infoCard.backgroundColor = .white
        infoCard.layer.cornerRadius = 14
        infoCard.layer.shadowColor = UIColor.black.cgColor
        infoCard.layer.shadowOffset = CGSize(width: 0, height: 3)
        infoCard.layer.shadowOpacity = 0.08
        infoCard.layer.shadowRadius = 8
        view.addSubview(infoCard)

        let phoneIcon = UIImageView()
        phoneIcon.translatesAutoresizingMaskIntoConstraints = false
        phoneIcon.image = UIImage(systemName: "iphone")
        phoneIcon.tintColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 1.0)
        phoneIcon.contentMode = .scaleAspectFit
        infoCard.addSubview(phoneIcon)

        let devName = UILabel()
        devName.translatesAutoresizingMaskIntoConstraints = false
        devName.text = UIDevice.current.name
        devName.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        devName.textColor = UIColor(white: 0.15, alpha: 1.0)
        infoCard.addSubview(devName)

        let wifiLbl = UILabel()
        wifiLbl.translatesAutoresizingMaskIntoConstraints = false
        let ssid = NetworkDetector.currentSSID() ?? "Wi-Fi Connected"
        wifiLbl.text = "● \(ssid)"
        wifiLbl.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        wifiLbl.textColor = UIColor(red: 0.10, green: 0.65, blue: 0.35, alpha: 1.0)
        infoCard.addSubview(wifiLbl)

        // 1. Center Native ReplayKit Broadcast Picker (START) - 100% Direct Apple Touch Interaction
        let picker = RPSystemBroadcastPickerView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.preferredExtension = BroadcastPickerManager.shared.extensionBundleId
        picker.showsMicrophoneButton = false
        picker.backgroundColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 1.0)
        picker.layer.cornerRadius = 80
        picker.layer.shadowColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 0.45).cgColor
        picker.layer.shadowOffset = CGSize(width: 0, height: 8)
        picker.layer.shadowOpacity = 0.5
        picker.layer.shadowRadius = 16
        picker.layer.masksToBounds = false
        picker.tintColor = .white
        picker.alpha = 1.0
        view.addSubview(picker)
        self.nativePickerView = picker

        let btnSub = UILabel()
        btnSub.translatesAutoresizingMaskIntoConstraints = false
        btnSub.text = "START"
        btnSub.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        btnSub.textColor = UIColor.white.withAlphaComponent(0.95)
        btnSub.isUserInteractionEnabled = false
        picker.addSubview(btnSub)
        self.scanBtnSubLabel = btnSub

        // 2. Center STOP Button (visible only when active recording is in progress)
        let stopBtn = UIButton(type: .custom)
        stopBtn.translatesAutoresizingMaskIntoConstraints = false
        stopBtn.backgroundColor = UIColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 1.0)
        stopBtn.layer.cornerRadius = 80
        stopBtn.layer.shadowColor = UIColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 0.45).cgColor
        stopBtn.layer.shadowOffset = CGSize(width: 0, height: 8)
        stopBtn.layer.shadowOpacity = 0.5
        stopBtn.layer.shadowRadius = 16
        stopBtn.addTarget(self, action: #selector(handleStopAction), for: .touchUpInside)
        stopBtn.isHidden = true
        view.addSubview(stopBtn)
        self.stopButton = stopBtn

        let stopLbl = UILabel()
        stopLbl.translatesAutoresizingMaskIntoConstraints = false
        stopLbl.text = "STOP"
        stopLbl.font = UIFont.systemFont(ofSize: 26, weight: .black)
        stopLbl.textColor = .white
        stopLbl.isUserInteractionEnabled = false
        stopBtn.addSubview(stopLbl)

        let stopSubLbl = UILabel()
        stopSubLbl.translatesAutoresizingMaskIntoConstraints = false
        stopSubLbl.text = "TAP TO END"
        stopSubLbl.font = UIFont.systemFont(ofSize: 11, weight: .heavy)
        stopSubLbl.textColor = UIColor.white.withAlphaComponent(0.9)
        stopSubLbl.isUserInteractionEnabled = false
        stopBtn.addSubview(stopSubLbl)

        let hint = UILabel()
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.text = "Tap to Launch Screen Recording"
        hint.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        hint.textColor = UIColor(white: 0.4, alpha: 1.0)
        view.addSubview(hint)
        self.hintLabel = hint

        // Diagnostic Card 1: ReplayKit Screen Recording Status
        let rkCard = createDiagnosticCard(
            title: "ReplayKit Screen Recording",
            initialStatus: "Ready",
            initialDetail: "Tap 'M' START above to grant screen recording permission.",
            dotColor: UIColor.systemGray
        )
        view.addSubview(rkCard.card)
        self.replayKitStatusCard = rkCard.card
        self.replayKitDotView = rkCard.dot
        self.replayKitTitleLabel = rkCard.titleLbl
        self.replayKitDetailLabel = rkCard.detailLbl

        // Diagnostic Card 2: Windows PC Connection Status
        let connCard = createDiagnosticCard(
            title: "Windows Receiver Connection",
            initialStatus: "Listening on Ports 25333 / 25334",
            initialDetail: "Waiting for Windows Software (Open AppleCast on PC).",
            dotColor: UIColor.systemOrange
        )
        view.addSubview(connCard.card)
        self.connectionStatusCard = connCard.card
        self.connectionDotView = connCard.dot
        self.connectionTitleLabel = connCard.titleLbl
        self.connectionDetailLabel = connCard.detailLbl

        // Constraints
        NSLayoutConstraint.activate([
            topBg.topAnchor.constraint(equalTo: view.topAnchor),
            topBg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBg.heightAnchor.constraint(equalToConstant: 160),

            infoCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            infoCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            infoCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            infoCard.heightAnchor.constraint(equalToConstant: 64),

            phoneIcon.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 16),
            phoneIcon.centerYAnchor.constraint(equalTo: infoCard.centerYAnchor),
            phoneIcon.widthAnchor.constraint(equalToConstant: 28),
            phoneIcon.heightAnchor.constraint(equalToConstant: 28),

            devName.leadingAnchor.constraint(equalTo: phoneIcon.trailingAnchor, constant: 12),
            devName.centerYAnchor.constraint(equalTo: infoCard.centerYAnchor),

            wifiLbl.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor, constant: -16),
            wifiLbl.centerYAnchor.constraint(equalTo: infoCard.centerYAnchor),

            picker.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            picker.topAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: 32),
            picker.widthAnchor.constraint(equalToConstant: 160),
            picker.heightAnchor.constraint(equalToConstant: 160),

            btnSub.centerXAnchor.constraint(equalTo: picker.centerXAnchor),
            btnSub.bottomAnchor.constraint(equalTo: picker.bottomAnchor, constant: -18),

            stopBtn.centerXAnchor.constraint(equalTo: picker.centerXAnchor),
            stopBtn.centerYAnchor.constraint(equalTo: picker.centerYAnchor),
            stopBtn.widthAnchor.constraint(equalToConstant: 160),
            stopBtn.heightAnchor.constraint(equalToConstant: 160),

            stopLbl.centerXAnchor.constraint(equalTo: stopBtn.centerXAnchor),
            stopLbl.centerYAnchor.constraint(equalTo: stopBtn.centerYAnchor, constant: -8),

            stopSubLbl.centerXAnchor.constraint(equalTo: stopBtn.centerXAnchor),
            stopSubLbl.topAnchor.constraint(equalTo: stopLbl.bottomAnchor, constant: 2),

            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 14),

            rkCard.card.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 24),
            rkCard.card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rkCard.card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            rkCard.card.heightAnchor.constraint(equalToConstant: 78),

            connCard.card.topAnchor.constraint(equalTo: rkCard.card.bottomAnchor, constant: 12),
            connCard.card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            connCard.card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            connCard.card.heightAnchor.constraint(equalToConstant: 78)
        ])
    }

    private func createDiagnosticCard(
        title: String,
        initialStatus: String,
        initialDetail: String,
        dotColor: UIColor
    ) -> (card: UIView, dot: UIView, titleLbl: UILabel, detailLbl: UILabel) {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowOpacity = 0.06
        card.layer.shadowRadius = 6

        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = dotColor
        dot.layer.cornerRadius = 6
        card.addSubview(dot)

        let tLbl = UILabel()
        tLbl.translatesAutoresizingMaskIntoConstraints = false
        tLbl.text = "\(title): \(initialStatus)"
        tLbl.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        tLbl.textColor = UIColor(white: 0.15, alpha: 1.0)
        card.addSubview(tLbl)

        let dLbl = UILabel()
        dLbl.translatesAutoresizingMaskIntoConstraints = false
        dLbl.text = initialDetail
        dLbl.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        dLbl.textColor = UIColor(white: 0.5, alpha: 1.0)
        dLbl.numberOfLines = 2
        card.addSubview(dLbl)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            dot.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),

            tLbl.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            tLbl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            tLbl.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            dLbl.leadingAnchor.constraint(equalTo: tLbl.leadingAnchor),
            dLbl.trailingAnchor.constraint(equalTo: tLbl.trailingAnchor),
            dLbl.topAnchor.constraint(equalTo: tLbl.bottomAnchor, constant: 4)
        ])

        return (card, dot, tLbl, dLbl)
    }

    // MARK: - Direct Screen Recording Actions

    @objc public func handleStopAction() {
        NSLog("[WXHomeViewController] User tapped STOP -> Stopping all screen recording")
        BroadcastPickerManager.shared.stopBroadcast()
        ScreenRecorderManager.shared.stopRecording { [weak self] _ in
            self?.updateStatusCards()
        }
        SilentAudioKeepAlive.shared.stop()
        lastErrorMessage = nil
        updateStatusCards()
    }

    @objc public func handleDirectMirrorAction() {
        let isCapturing = UIScreen.main.isCaptured || ScreenRecorderManager.shared.isCapturing
        if isCapturing {
            // STOP Recording
            NSLog("[WXHomeViewController] User tapped STOP -> Stopping all screen recording")
            BroadcastPickerManager.shared.stopBroadcast()
            ScreenRecorderManager.shared.stopRecording { [weak self] _ in
                self?.updateStatusCards()
            }
            SilentAudioKeepAlive.shared.stop()
            lastErrorMessage = nil
            updateStatusCards()
            return
        }

        // START Recording -> Prompts ReplayKit System Broadcast Permission
        NSLog("[WXHomeViewController] User tapped START -> Launching ReplayKit System Broadcast Picker")
        lastErrorMessage = nil

        // Immediate Visual Feedback
        replayKitDotView?.backgroundColor = UIColor.systemOrange
        replayKitTitleLabel?.text = "ReplayKit: Opening Broadcast Dialog..."
        replayKitDetailLabel?.text = "Please tap 'Start Broadcast' on the iOS system prompt to begin mirroring."
        hintLabel?.text = "Waiting for broadcast confirmation..."

        // Start background keepalive audio
        SilentAudioKeepAlive.shared.start()

        // Launch the ReplayKit Broadcast Picker
        BroadcastPickerManager.shared.presentBroadcastPicker()

        // 15-second fallback timer to check if user cancelled or if broadcast started
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            if !UIScreen.main.isCaptured && !ScreenRecorderManager.shared.isCapturing {
                if self.lastErrorMessage == nil {
                    self.lastErrorMessage = "Screen recording is not started. Tap START and choose 'Start Broadcast' on the dialog."
                }
                // Do not stop keepalive here; keep CoreAudio primed and background active
                self.updateStatusCards()
            }
        }
    }

    // MARK: - Observer & State Handling

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenCapturedChanged),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )

        // Darwin notifications from Extension
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let obs = observer else { return }
                let vc = Unmanaged<WXHomeViewController>.fromOpaque(obs).takeUnretainedValue()
                DispatchQueue.main.async {
                    vc.lastErrorMessage = nil
                    SilentAudioKeepAlive.shared.start()
                    vc.updateStatusCards()
                }
            },
            "com.apowermirror.broadcast.BroadcastStarted" as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let obs = observer else { return }
                let vc = Unmanaged<WXHomeViewController>.fromOpaque(obs).takeUnretainedValue()
                DispatchQueue.main.async {
                    SilentAudioKeepAlive.shared.stop()
                    vc.updateStatusCards()
                }
            },
            "com.apowermirror.broadcast.Finish" as CFString,
            nil,
            .deliverImmediately
        )
    }

    @objc private func handleScreenCapturedChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if UIScreen.main.isCaptured {
                self.lastErrorMessage = nil
                SilentAudioKeepAlive.shared.start()
            } else {
                SilentAudioKeepAlive.shared.stop()
            }
            self.updateStatusCards()
        }
    }

    private func updateStatusCards() {
        let isCapturing = ScreenRecorderManager.shared.isCapturing || UIScreen.main.isCaptured

        if isCapturing {
            // Screen Recording ACTIVE
            nativePickerView?.isHidden = true
            stopButton?.isHidden = false

            replayKitDotView?.backgroundColor = UIColor(red: 0.10, green: 0.75, blue: 0.35, alpha: 1.0)
            replayKitTitleLabel?.text = "ReplayKit: Screen Recording ACTIVE"
            replayKitDetailLabel?.text = "Screen recording successfully! Full phone mirroring active."
            hintLabel?.text = "Broadcasting live • Tap STOP to end"

            startDurationTimer()
        } else if let err = lastErrorMessage {
            // Screen Recording FAILED / CANCELLED / NOT STARTED
            stopDurationTimer()
            nativePickerView?.isHidden = false
            stopButton?.isHidden = true

            replayKitDotView?.backgroundColor = UIColor.systemRed
            replayKitTitleLabel?.text = "ReplayKit: Screen is not started"
            replayKitDetailLabel?.text = err
            hintLabel?.text = "Tap START and choose 'Start Broadcast'"
        } else {
            // Screen Recording INACTIVE / READY
            stopDurationTimer()
            nativePickerView?.isHidden = false
            stopButton?.isHidden = true

            replayKitDotView?.backgroundColor = UIColor.systemGray
            replayKitTitleLabel?.text = "ReplayKit: Ready"
            replayKitDetailLabel?.text = "Tap START circle above to begin screen broadcast."
            hintLabel?.text = "Tap START and choose 'Start Broadcast'"
        }

        // Update Windows Connection Card
        if isDesktopConnected {
            connectionDotView?.backgroundColor = UIColor(red: 0.10, green: 0.75, blue: 0.35, alpha: 1.0)
            connectionTitleLabel?.text = "Windows Receiver: CONNECTED"
            connectionDetailLabel?.text = "AppleCast on PC is connected and ready to receive stream."
        } else {
            connectionDotView?.backgroundColor = UIColor.systemRed
            connectionTitleLabel?.text = "Windows Receiver: NOT CONNECTED (Connection Issue)"
            connectionDetailLabel?.text = "Connection issue: Open AppleCast on PC and connect USB cable or Wi-Fi."
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        recordingSeconds = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.recordingSeconds += 1
            let mins = self.recordingSeconds / 60
            let secs = self.recordingSeconds % 60
            let timeStr = String(format: "%02d:%02d", mins, secs)
            self.replayKitDetailLabel?.text = "Live 60 FPS Stream Active • Duration: \(timeStr)"
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingSeconds = 0
    }

    // MARK: - Pulse Animation

    private func startPulseAnimation() {
        stopPulseAnimation()
        guard let btn = nativePickerView ?? stopButton else { return }

        let pulse = CAShapeLayer()
        pulse.frame = btn.bounds
        pulse.path = UIBezierPath(ovalIn: btn.bounds).cgPath
        pulse.strokeColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 0.4).cgColor
        pulse.fillColor = UIColor.clear.cgColor
        pulse.lineWidth = 4
        btn.layer.insertSublayer(pulse, at: 0)
        self.pulseLayer = pulse

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = 1.25

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 0.8
        opacityAnim.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = 1.8
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.add(group, forKey: "pulse")
    }

    private func stopPulseAnimation() {
        pulseLayer?.removeAllAnimations()
        pulseLayer?.removeFromSuperlayer()
        pulseLayer = nil
    }

    // MARK: - ScreenRecorderManagerDelegate Callbacks

    public func screenRecorderDidStart() {
        DispatchQueue.main.async { [weak self] in
            self?.lastErrorMessage = nil
            self?.updateStatusCards()
            WXCastiOSSender.shared.sendStartCastPayload()
        }
    }

    public func screenRecorderDidStop(error: Error?) {
        DispatchQueue.main.async { [weak self] in
            if let error = error {
                self?.lastErrorMessage = error.localizedDescription
            }
            self?.updateStatusCards()
            WXCastiOSSender.shared.sendStartCastPayload()
        }
    }

    public func screenRecorderDidFail(error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.lastErrorMessage = error.localizedDescription
            self?.updateStatusCards()
        }
    }

    // MARK: - BroadcastPickerManagerDelegate

    public func broadcastCaptureStateChanged(isCaptured: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusCards()
        }
    }

    // MARK: - WXCastiOSSenderDelegate

    public func castSenderDidConnectDesktop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isDesktopConnected = true
            self.updateStatusCards()
        }
    }

    public func castSenderDidDisconnectDesktop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isDesktopConnected = false
            self.updateStatusCards()
        }
    }

    public func castSenderDidRequestIDRKeyframe() {
        NSLog("[WXHomeViewController] Desktop requested IDR Keyframe refresh")
        ScreenRecorderManager.shared.requestKeyframe()
    }

    deinit {
        stopDurationTimer()
        NotificationCenter.default.removeObserver(self)
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
