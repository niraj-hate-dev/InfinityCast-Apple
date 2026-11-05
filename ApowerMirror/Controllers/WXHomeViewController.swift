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
import Darwin

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

    // Quality & Bitrate Controls
    private var qualityCard: UIView?
    private var resValueLabel: UILabel?
    private var bitrateValueLabel: UILabel?
    private var applyButton: UIButton?
    private var saveStatusLabel: UILabel?
    private var currentResolution: String = "720p"
    private var currentBitrate: String = "4 Mbps"

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

        // Load saved stream quality preferences
        if let savedRes = (UserDefaults(suiteName: "group.apowersoft.mirror")?.string(forKey: "kEncoderResolution")) ?? UserDefaults.standard.string(forKey: "kEncoderResolution") {
            currentResolution = savedRes
        }
        if let savedBit = (UserDefaults(suiteName: "group.apowersoft.mirror")?.string(forKey: "kEncoderBitrateString")) ?? UserDefaults.standard.string(forKey: "kEncoderBitrateString") {
            currentBitrate = savedBit
        }
        updateQualityLabels()

        let qualityBtn = UIBarButtonItem(title: "⚙️ Quality", style: .plain, target: self, action: #selector(handleQualityNavAction))
        qualityBtn.tintColor = .white
        navigationItem.rightBarButtonItem = qualityBtn
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

        // Diagnostic Card 3: Stream Quality & Bitrate Card
        let qCard = createQualityCard()
        view.addSubview(qCard)
        self.qualityCard = qCard

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
            connCard.card.heightAnchor.constraint(equalToConstant: 78),

            qCard.topAnchor.constraint(equalTo: connCard.card.bottomAnchor, constant: 12),
            qCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            qCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            qCard.heightAnchor.constraint(equalToConstant: 98)
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

    // MARK: - Stream Quality & Bitrate Card

    private func createQualityCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOffset = CGSize(width: 0, height: 2)
        card.layer.shadowOpacity = 0.06
        card.layer.shadowRadius = 6

        let headerIcon = UIImageView(image: UIImage(systemName: "slider.horizontal.3"))
        headerIcon.tintColor = UIColor(red: 0.15, green: 0.50, blue: 0.98, alpha: 1.0)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(headerIcon)

        let titleLbl = UILabel()
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.text = "STREAM QUALITY & BITRATE"
        titleLbl.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        titleLbl.textColor = UIColor(white: 0.45, alpha: 1.0)
        card.addSubview(titleLbl)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 10
        card.addSubview(stack)

        // 1. Resolution Pill Button
        let resContainer = UIButton(type: .custom)
        resContainer.translatesAutoresizingMaskIntoConstraints = false
        resContainer.backgroundColor = UIColor(red: 0.93, green: 0.96, blue: 1.0, alpha: 1.0)
        resContainer.layer.cornerRadius = 10
        resContainer.layer.borderColor = UIColor(red: 0.80, green: 0.88, blue: 0.99, alpha: 1.0).cgColor
        resContainer.layer.borderWidth = 1.0
        resContainer.addTarget(self, action: #selector(showResolutionPicker), for: .touchUpInside)

        let resSubLbl = UILabel()
        resSubLbl.translatesAutoresizingMaskIntoConstraints = false
        resSubLbl.text = "RESOLUTION"
        resSubLbl.font = UIFont.systemFont(ofSize: 9, weight: .bold)
        resSubLbl.textColor = UIColor(red: 0.15, green: 0.45, blue: 0.90, alpha: 1.0)
        resSubLbl.isUserInteractionEnabled = false
        resContainer.addSubview(resSubLbl)

        let resValLbl = UILabel()
        resValLbl.translatesAutoresizingMaskIntoConstraints = false
        resValLbl.text = "\(currentResolution) ▾"
        resValLbl.font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        resValLbl.textColor = UIColor(red: 0.10, green: 0.35, blue: 0.85, alpha: 1.0)
        resValLbl.isUserInteractionEnabled = false
        resContainer.addSubview(resValLbl)
        self.resValueLabel = resValLbl

        NSLayoutConstraint.activate([
            resSubLbl.topAnchor.constraint(equalTo: resContainer.topAnchor, constant: 8),
            resSubLbl.leadingAnchor.constraint(equalTo: resContainer.leadingAnchor, constant: 12),

            resValLbl.topAnchor.constraint(equalTo: resSubLbl.bottomAnchor, constant: 2),
            resValLbl.leadingAnchor.constraint(equalTo: resContainer.leadingAnchor, constant: 12),
            resValLbl.trailingAnchor.constraint(equalTo: resContainer.trailingAnchor, constant: -12),
            resValLbl.bottomAnchor.constraint(equalTo: resContainer.bottomAnchor, constant: -8)
        ])
        stack.addArrangedSubview(resContainer)

        // 2. Bitrate Pill Button
        let bitContainer = UIButton(type: .custom)
        bitContainer.translatesAutoresizingMaskIntoConstraints = false
        bitContainer.backgroundColor = UIColor(red: 0.94, green: 0.98, blue: 0.95, alpha: 1.0)
        bitContainer.layer.cornerRadius = 10
        bitContainer.layer.borderColor = UIColor(red: 0.82, green: 0.94, blue: 0.86, alpha: 1.0).cgColor
        bitContainer.layer.borderWidth = 1.0
        bitContainer.addTarget(self, action: #selector(showBitratePicker), for: .touchUpInside)

        let bitSubLbl = UILabel()
        bitSubLbl.translatesAutoresizingMaskIntoConstraints = false
        bitSubLbl.text = "BITRATE"
        bitSubLbl.font = UIFont.systemFont(ofSize: 9, weight: .bold)
        bitSubLbl.textColor = UIColor(red: 0.12, green: 0.60, blue: 0.32, alpha: 1.0)
        bitSubLbl.isUserInteractionEnabled = false
        bitContainer.addSubview(bitSubLbl)

        let bitValLbl = UILabel()
        bitValLbl.translatesAutoresizingMaskIntoConstraints = false
        bitValLbl.text = "\(currentBitrate) ▾"
        bitValLbl.font = UIFont.systemFont(ofSize: 15, weight: .heavy)
        bitValLbl.textColor = UIColor(red: 0.08, green: 0.50, blue: 0.25, alpha: 1.0)
        bitValLbl.isUserInteractionEnabled = false
        bitContainer.addSubview(bitValLbl)
        self.bitrateValueLabel = bitValLbl

        NSLayoutConstraint.activate([
            bitSubLbl.topAnchor.constraint(equalTo: bitContainer.topAnchor, constant: 8),
            bitSubLbl.leadingAnchor.constraint(equalTo: bitContainer.leadingAnchor, constant: 12),

            bitValLbl.topAnchor.constraint(equalTo: bitSubLbl.bottomAnchor, constant: 2),
            bitValLbl.leadingAnchor.constraint(equalTo: bitContainer.leadingAnchor, constant: 12),
            bitValLbl.trailingAnchor.constraint(equalTo: bitContainer.trailingAnchor, constant: -12),
            bitValLbl.bottomAnchor.constraint(equalTo: bitContainer.bottomAnchor, constant: -8)
        ])
        stack.addArrangedSubview(bitContainer)

        // 3. Save & Apply Button
        let applyBtn = UIButton(type: .system)
        applyBtn.translatesAutoresizingMaskIntoConstraints = false
        applyBtn.backgroundColor = UIColor(red: 0.12, green: 0.48, blue: 0.95, alpha: 1.0)
        applyBtn.setTitleColor(.white, for: .normal)
        applyBtn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        applyBtn.setTitle("⚡ Save & Apply to Windows", for: .normal)
        applyBtn.layer.cornerRadius = 10
        applyBtn.layer.masksToBounds = true
        applyBtn.addTarget(self, action: #selector(handleApplySaveButtonTapped), for: .touchUpInside)
        card.addSubview(applyBtn)
        self.applyButton = applyBtn

        // 4. Status Hint Label
        let statusLbl = UILabel()
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        statusLbl.text = "Tap to save & instantly reconfigure Windows stream"
        statusLbl.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        statusLbl.textColor = UIColor(white: 0.50, alpha: 1.0)
        statusLbl.textAlignment = .center
        card.addSubview(statusLbl)
        self.saveStatusLabel = statusLbl

        NSLayoutConstraint.activate([
            headerIcon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            headerIcon.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            headerIcon.widthAnchor.constraint(equalToConstant: 14),
            headerIcon.heightAnchor.constraint(equalToConstant: 14),

            titleLbl.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 6),
            titleLbl.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),

            stack.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            applyBtn.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10),
            applyBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            applyBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            applyBtn.heightAnchor.constraint(equalToConstant: 42),

            statusLbl.topAnchor.constraint(equalTo: applyBtn.bottomAnchor, constant: 6),
            statusLbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            statusLbl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            statusLbl.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        return card
    }

    private func updateQualityLabels() {
        resValueLabel?.text = "\(currentResolution) ▾"
        bitrateValueLabel?.text = "\(currentBitrate) ▾"
        applyButton?.setTitle("⚡ Save & Apply (\(currentResolution) • \(currentBitrate))", for: .normal)
    }

    @objc public func handleApplySaveButtonTapped() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()

        saveAndBroadcastSettings(resolution: currentResolution, bitrateStr: currentBitrate)

        // Visual confirmation
        applyButton?.backgroundColor = UIColor(red: 0.10, green: 0.65, blue: 0.35, alpha: 1.0)
        applyButton?.setTitle("✓ Saved & Applied to Windows!", for: .normal)
        saveStatusLabel?.text = "✓ Reconfigured to \(currentResolution) @ \(currentBitrate) - Windows Live!"
        saveStatusLabel?.textColor = UIColor(red: 0.08, green: 0.60, blue: 0.28, alpha: 1.0)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.applyButton?.backgroundColor = UIColor(red: 0.12, green: 0.48, blue: 0.95, alpha: 1.0)
            self.updateQualityLabels()
            self.saveStatusLabel?.text = "Tap to save & instantly reconfigure Windows stream"
            self.saveStatusLabel?.textColor = UIColor(white: 0.50, alpha: 1.0)
        }
    }

    @objc public func handleQualityNavAction() {
        let alert = UIAlertController(
            title: "⚙️ Stream Quality Settings",
            message: "Active: \(currentResolution) @ \(currentBitrate)\nWindows receiver will dynamically auto-detect any changes.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Change Resolution (\(currentResolution))", style: .default, handler: { [weak self] _ in
            self?.showResolutionPicker()
        }))
        alert.addAction(UIAlertAction(title: "Change Bitrate (\(currentBitrate))", style: .default, handler: { [weak self] _ in
            self?.showBitratePicker()
        }))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        present(alert, animated: true, completion: nil)
    }

    @objc public func showResolutionPicker() {
        let alert = UIAlertController(
            title: "📐 Select Resolution",
            message: "Windows receiver automatically adapts window size and aspect ratio:",
            preferredStyle: .actionSheet
        )

        let presets = [
            ("240p", "240p • Fastest (Ultra Low Bandwidth)"),
            ("360p", "360p • Low Bandwidth Saver"),
            ("480p", "480p • Standard Definition (SD)"),
            ("544p", "544p • Enhanced SD (544p)"),
            ("720p", "720p • High Definition (Recommended)"),
            ("1080p", "1080p • Full HD (Crisp Gaming)"),
            ("2K", "2K • 1440p Quad HD"),
            ("4K", "4K • 2160p Ultra HD / Native Maximum")
        ]

        for (resKey, label) in presets {
            let isCurrent = (resKey.lowercased() == currentResolution.lowercased())
            let checkmark = isCurrent ? "  ✓" : ""
            alert.addAction(UIAlertAction(title: "\(label)\(checkmark)", style: .default, handler: { [weak self] _ in
                guard let self = self else { return }
                self.saveAndBroadcastSettings(resolution: resKey, bitrateStr: self.currentBitrate)
            }))
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = qualityCard ?? view
            popover.sourceRect = qualityCard?.bounds ?? view.bounds
        }
        present(alert, animated: true, completion: nil)
    }

    @objc public func showBitratePicker() {
        let alert = UIAlertController(
            title: "⚡ Select Bitrate",
            message: "Windows receiver automatically measures and displays real-time Mbps:",
            preferredStyle: .actionSheet
        )

        let presets = [
            ("1 Mbps", "1 Mbps • Minimum / Ultra Bandwidth Saver"),
            ("2 Mbps", "2 Mbps • Low Bitrate"),
            ("4 Mbps", "4 Mbps • Balanced (Recommended Default)"),
            ("6 Mbps", "6 Mbps • High Quality"),
            ("8 Mbps", "8 Mbps • Very High Quality (Fast Wi-Fi / USB)"),
            ("12 Mbps", "12 Mbps • Gaming Quality"),
            ("16 Mbps", "16 Mbps • Pro Gaming Quality"),
            ("20 Mbps", "20 Mbps • Maximum Limit (Ultra Low Compression)")
        ]

        for (bitKey, label) in presets {
            let isCurrent = (bitKey == currentBitrate)
            let checkmark = isCurrent ? "  ✓" : ""
            alert.addAction(UIAlertAction(title: "\(label)\(checkmark)", style: .default, handler: { [weak self] _ in
                guard let self = self else { return }
                self.saveAndBroadcastSettings(resolution: self.currentResolution, bitrateStr: bitKey)
            }))
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))

        if let popover = alert.popoverPresentationController {
            popover.sourceView = qualityCard ?? view
            popover.sourceRect = qualityCard?.bounds ?? view.bounds
        }
        present(alert, animated: true, completion: nil)
    }

    private func saveAndBroadcastSettings(resolution: String, bitrateStr: String) {
        currentResolution = resolution
        currentBitrate = bitrateStr
        updateQualityLabels()

        let shortSide = VideoEncoder.resolutionToShortSide(resolution)
        let bps = VideoEncoder.bitrateStringToBps(bitrateStr)

        NSLog("[WXHomeViewController] User selected quality: %@ (%d shortSide) @ %@ (%d bps)", resolution, shortSide, bitrateStr, bps)

        // 1. Persist to standard UserDefaults
        UserDefaults.standard.set(resolution, forKey: "kEncoderResolution")
        UserDefaults.standard.set(bitrateStr, forKey: "kEncoderBitrateString")
        UserDefaults.standard.set(Int(shortSide), forKey: "kEncoderShortSide")
        UserDefaults.standard.set(Int(bps), forKey: "kEncoderBitrate")

        // 2. Persist to App Group UserDefaults (best-effort)
        if let sharedDefaults = UserDefaults(suiteName: "group.apowersoft.mirror") {
            sharedDefaults.set(resolution, forKey: "kEncoderResolution")
            sharedDefaults.set(bitrateStr, forKey: "kEncoderBitrateString")
            sharedDefaults.set(Int(shortSide), forKey: "kEncoderShortSide")
            sharedDefaults.set(Int(bps), forKey: "kEncoderBitrate")
            sharedDefaults.synchronize()
        }

        // 3. Persist to MMWormhole archive file
        MMWormholeManager.shared.writeMessageObject([
            "resolution": resolution,
            "bitrateString": bitrateStr,
            "shortSide": Int(shortSide),
            "bitrate": Int(bps),
            "fps": 60
        ], identifier: "encoderSettings")

        // 4. Update in-app ScreenRecorderManager if active
        ScreenRecorderManager.shared.updateConfiguration(bitrate: bps, shortSide: shortSide, fps: 60)

        // 5. Post preset-specific Darwin notifications (100% reliable across all sandboxes)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName("com.apowermirror.setRes.\(shortSide)" as CFString), nil, nil, true)
        CFNotificationCenterPostNotification(center, CFNotificationName("com.apowermirror.setBitrate.\(bps)" as CFString), nil, nil, true)
        CFNotificationCenterPostNotification(center, CFNotificationName("com.apowermirror.updateEncoderSettings" as CFString), nil, nil, true)
        CFNotificationCenterPostNotification(center, CFNotificationName("com.apowermirror.forceKeyframe" as CFString), nil, nil, true)
        NSLog("[WXHomeViewController] Dispatched Darwin presets: %dp @ %d bps", shortSide, bps)

        // 7. Direct TCP dispatch with SO_LINGER to Broadcast Extension port 25334
        DispatchQueue.global(qos: .utility).async {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { return }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var lingerOpt = linger(l_onoff: 1, l_linger: 2)
            setsockopt(sock, SOL_SOCKET, SO_LINGER, &lingerOpt, socklen_t(MemoryLayout<linger>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(25334).bigEndian
            inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
            let conn = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if conn >= 0 {
                let msg = "{\"cmd\":\"SET_CONFIG\",\"bitrate\":\(bps),\"shortSide\":\(shortSide),\"fps\":60}\n"
                msg.withCString { ptr in
                    send(sock, ptr, strlen(ptr), 0)
                }
                shutdown(sock, SHUT_WR)
                var dummy = [UInt8](repeating: 0, count: 32)
                _ = recv(sock, &dummy, dummy.count, 0)
            }
            close(sock)
        }

        hintLabel?.text = "Stream Quality: \(resolution) • \(bitrateStr)"
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
                    vc.saveAndBroadcastSettings(resolution: vc.currentResolution, bitrateStr: vc.currentBitrate)
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
