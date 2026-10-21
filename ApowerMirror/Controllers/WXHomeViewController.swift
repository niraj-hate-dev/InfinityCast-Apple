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
    private var scanBtn: UIButton?
    private var scanBtnLabel: UILabel?
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

        // Center Prominent Direct "START SCREEN RECORDING" Button
        let btn = UIButton(type: .custom)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.backgroundColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 1.0)
        btn.layer.cornerRadius = 80
        btn.layer.shadowColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 0.45).cgColor
        btn.layer.shadowOffset = CGSize(width: 0, height: 8)
        btn.layer.shadowOpacity = 0.5
        btn.layer.shadowRadius = 16
        btn.addTarget(self, action: #selector(handleDirectMirrorAction), for: .touchUpInside)
        view.addSubview(btn)
        self.scanBtn = btn

        let btnTitle = UILabel()
        btnTitle.translatesAutoresizingMaskIntoConstraints = false
        btnTitle.text = "M"
        btnTitle.font = UIFont.systemFont(ofSize: 56, weight: .black)
        btnTitle.textColor = .white
        btnTitle.isUserInteractionEnabled = false
        btn.addSubview(btnTitle)
        self.scanBtnLabel = btnTitle

        let btnSub = UILabel()
        btnSub.translatesAutoresizingMaskIntoConstraints = false
        btnSub.text = "START"
        btnSub.font = UIFont.systemFont(ofSize: 13, weight: .heavy)
        btnSub.textColor = UIColor.white.withAlphaComponent(0.9)
        btnSub.isUserInteractionEnabled = false
        btn.addSubview(btnSub)
        self.scanBtnSubLabel = btnSub

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

            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.topAnchor.constraint(equalTo: infoCard.bottomAnchor, constant: 32),
            btn.widthAnchor.constraint(equalToConstant: 160),
            btn.heightAnchor.constraint(equalToConstant: 160),

            btnTitle.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            btnTitle.centerYAnchor.constraint(equalTo: btn.centerYAnchor, constant: -8),

            btnSub.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            btnSub.topAnchor.constraint(equalTo: btnTitle.bottomAnchor, constant: -4),

            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: btn.bottomAnchor, constant: 12),

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
            replayKitDotView?.backgroundColor = UIColor(red: 0.10, green: 0.75, blue: 0.35, alpha: 1.0)
            replayKitTitleLabel?.text = "ReplayKit: Screen Recording ACTIVE"
            replayKitDetailLabel?.text = "Screen recording successfully! Full phone mirroring active."

            scanBtn?.backgroundColor = UIColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 1.0)
            scanBtnSubLabel?.text = "STOP"
            hintLabel?.text = "Full device screen recording is live • Tap to stop"

            startDurationTimer()
        } else if let err = lastErrorMessage {
            // Screen Recording FAILED / CANCELLED / NOT STARTED
            stopDurationTimer()
            replayKitDotView?.backgroundColor = UIColor.systemRed
            replayKitTitleLabel?.text = "ReplayKit: Screen is not started"
            replayKitDetailLabel?.text = err

            scanBtn?.backgroundColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 1.0)
            scanBtnSubLabel?.text = "START"
            hintLabel?.text = "Tap to retry screen recording"
        } else {
            // Screen Recording INACTIVE / READY
            stopDurationTimer()
            replayKitDotView?.backgroundColor = UIColor.systemGray
            replayKitTitleLabel?.text = "ReplayKit: Ready"
            replayKitDetailLabel?.text = "Tap 'M' START above to start full device screen recording."

            scanBtn?.backgroundColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 1.0)
            scanBtnSubLabel?.text = "START"
            hintLabel?.text = "Tap to Launch Screen Recording"
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
        guard let btn = scanBtn else { return }

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
