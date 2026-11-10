//
//  WXHomeViewController.swift
//  ApowerMirror / Controllers
//
//  Cast Home tab matching Android's fragment_home.xml UI:
//  - Top translucent glass header with circular InfinityLogo & "InfinityCast"
//  - Ambient radial glow behind a centered status card & 3-ring circular Cast button
//  - Invisible ReplayKit RPSystemBroadcastPickerView overlay for direct iOS broadcast start
//  - Reactive Darwin + UIScreen + WXCastiOSSender state sync
//

import UIKit
import ReplayKit
import Darwin

@objc(WXHomeViewController)
open class WXHomeViewController: UIViewController, ScreenRecorderManagerDelegate, WXCastiOSSenderDelegate, BroadcastPickerManagerDelegate {

    // MARK: - Top Bar UI

    private let topBarView = UIView()
    private let topBarLogo = InfinityBrandLogoView()
    private let topBarTitleLabel = UILabel()
    private let themeToggleButton = InfinityThemeToggleButton()
    private let topBarHairline = UIView()

    // MARK: - Hero UI

    private let centerContainer = UIView()
    private let radialGlowView = InfinityRadialGlowView()

    private let statusCard = InfinityGlassCardView(cornerRadius: 10)
    private let statusTitleLabel = UILabel()
    private let statusSubtitleLabel = UILabel()
    private let streamConfigLabel = UILabel()

    // 220x220 3-ring Cast Button
    private let castCircleContainer = UIView()
    private let outerGlowRing = UIView()
    private let middleRing = UIView()
    private let innerCoreRing = UIView()
    private let castIconView = UIImageView()
    private let castActionLabel = UILabel()

    private var nativePickerView: RPSystemBroadcastPickerView?
    private weak var hookedPickerButton: UIButton?
    private let stopOverlayButton = UIButton(type: .custom)

    private let hintLabel = UILabel()

    // MARK: - State

    private var currentResolutionKey: String = "1080p"
    private var currentBitrateLabel: String = "4 Mbps"
    private var isDesktopConnected = false
    private var lastErrorMessage: String?

    private var recordingStartTime: Date?
    private var durationTimer: Timer?

    // MARK: - Lifecycle

    open override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        loadPersistedSettings()

        ScreenRecorderManager.shared.delegate = self
        WXCastiOSSender.shared.delegate = self
        BroadcastPickerManager.shared.delegate = self
        BroadcastPickerManager.shared.preparePickerView(in: view)

        setupUI()
        setupObservers()
        updateUIState()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadPersistedSettings()
        updateUIState()
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
                    if hookedPickerButton !== button {
                        button.addTarget(self, action: #selector(handlePickerTouchDown), for: .touchUpInside)
                        hookedPickerButton = button
                    }
                }
            }
        }
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateUIState()
            themeToggleButton.updateState(animated: false)
        }
    }

    deinit {
        stopDurationTimer()
        NotificationCenter.default.removeObserver(self)
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - UI Setup

    private func setupUI() {
        setupTopBar()
        setupCenterWorkspace()
    }

    private func setupTopBar() {
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = InfinityTheme.topBarBg
        view.addSubview(topBarView)

        topBarLogo.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(topBarLogo)

        topBarTitleLabel.text = "InfinityCast"
        topBarTitleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        topBarTitleLabel.textColor = InfinityTheme.textPrimary
        topBarTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(topBarTitleLabel)

        themeToggleButton.translatesAutoresizingMaskIntoConstraints = false
        themeToggleButton.addTarget(self, action: #selector(handleThemeToggle), for: .touchUpInside)
        topBarView.addSubview(themeToggleButton)

        topBarHairline.backgroundColor = InfinityTheme.separator
        topBarHairline.translatesAutoresizingMaskIntoConstraints = false
        topBarView.addSubview(topBarHairline)

        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 64),

            topBarLogo.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 20),
            topBarLogo.bottomAnchor.constraint(equalTo: topBarView.bottomAnchor, constant: -16),
            topBarLogo.widthAnchor.constraint(equalToConstant: 32),
            topBarLogo.heightAnchor.constraint(equalToConstant: 32),

            topBarTitleLabel.leadingAnchor.constraint(equalTo: topBarLogo.trailingAnchor, constant: 12),
            topBarTitleLabel.centerYAnchor.constraint(equalTo: topBarLogo.centerYAnchor),
            topBarTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: themeToggleButton.leadingAnchor, constant: -12),

            themeToggleButton.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -20),
            themeToggleButton.centerYAnchor.constraint(equalTo: topBarLogo.centerYAnchor),

            topBarHairline.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor),
            topBarHairline.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor),
            topBarHairline.bottomAnchor.constraint(equalTo: topBarView.bottomAnchor),
            topBarHairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
    }

    private func setupCenterWorkspace() {
        centerContainer.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.backgroundColor = .clear
        view.addSubview(centerContainer)

        radialGlowView.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(radialGlowView)

        // Status Card (bg_status_card)
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(statusCard)

        statusTitleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        statusTitleLabel.textColor = InfinityTheme.textPrimary
        statusTitleLabel.textAlignment = .center

        statusSubtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        statusSubtitleLabel.textColor = InfinityTheme.textSecondary
        statusSubtitleLabel.textAlignment = .center
        statusSubtitleLabel.numberOfLines = 2

        streamConfigLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        streamConfigLabel.textColor = InfinityTheme.brandBlueLight
        streamConfigLabel.textAlignment = .center

        let cardStack = UIStackView(arrangedSubviews: [statusTitleLabel, statusSubtitleLabel, streamConfigLabel])
        cardStack.axis = .vertical
        cardStack.alignment = .center
        cardStack.spacing = 6
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(cardStack)

        // 220x220 Concentric 3-Ring Circle Cast Button
        castCircleContainer.translatesAutoresizingMaskIntoConstraints = false
        castCircleContainer.backgroundColor = .clear
        centerContainer.addSubview(castCircleContainer)

        outerGlowRing.translatesAutoresizingMaskIntoConstraints = false
        outerGlowRing.backgroundColor = InfinityTheme.circleGlow
        outerGlowRing.layer.cornerRadius = 110
        outerGlowRing.isUserInteractionEnabled = false
        castCircleContainer.addSubview(outerGlowRing)

        middleRing.translatesAutoresizingMaskIntoConstraints = false
        middleRing.backgroundColor = InfinityTheme.circleRing
        middleRing.layer.cornerRadius = 102
        middleRing.layer.borderWidth = 2
        middleRing.layer.borderColor = InfinityTheme.circleRing.cgColor
        middleRing.isUserInteractionEnabled = false
        castCircleContainer.addSubview(middleRing)

        innerCoreRing.translatesAutoresizingMaskIntoConstraints = false
        innerCoreRing.backgroundColor = InfinityTheme.circleCore
        innerCoreRing.layer.cornerRadius = 94
        innerCoreRing.layer.borderWidth = 4
        innerCoreRing.layer.borderColor = InfinityTheme.brandBlueLight.resolvedColor(with: traitCollection).cgColor
        innerCoreRing.isUserInteractionEnabled = false
        castCircleContainer.addSubview(innerCoreRing)

        castIconView.contentMode = .scaleAspectFit
        castIconView.tintColor = InfinityTheme.brandBlue
        castIconView.translatesAutoresizingMaskIntoConstraints = false

        castActionLabel.font = .systemFont(ofSize: 20, weight: .bold)
        castActionLabel.textColor = InfinityTheme.brandBlue
        castActionLabel.textAlignment = .center
        castActionLabel.translatesAutoresizingMaskIntoConstraints = false

        let circleContentStack = UIStackView(arrangedSubviews: [castIconView, castActionLabel])
        circleContentStack.axis = .vertical
        circleContentStack.alignment = .center
        circleContentStack.spacing = 10
        circleContentStack.isUserInteractionEnabled = false
        circleContentStack.translatesAutoresizingMaskIntoConstraints = false
        innerCoreRing.addSubview(circleContentStack)

        // ReplayKit System Broadcast Picker (nearly transparent touch surface over the Start button)
        let picker = RPSystemBroadcastPickerView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.preferredExtension = BroadcastPickerManager.shared.extensionBundleId
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        picker.tintColor = .clear
        picker.alpha = 0.02
        picker.layer.cornerRadius = 110
        picker.clipsToBounds = true
        castCircleContainer.addSubview(picker)
        self.nativePickerView = picker

        // Stop button overlay (active only while streaming)
        stopOverlayButton.translatesAutoresizingMaskIntoConstraints = false
        stopOverlayButton.backgroundColor = .clear
        stopOverlayButton.layer.cornerRadius = 110
        stopOverlayButton.isHidden = true
        stopOverlayButton.addTarget(self, action: #selector(handleStopAction), for: .touchUpInside)
        castCircleContainer.addSubview(stopOverlayButton)

        // Subtle Footer Hint
        hintLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hintLabel.textColor = InfinityTheme.textSecondary
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        centerContainer.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            centerContainer.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            centerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            centerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            centerContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            radialGlowView.centerXAnchor.constraint(equalTo: centerContainer.centerXAnchor),
            radialGlowView.centerYAnchor.constraint(equalTo: castCircleContainer.centerYAnchor, constant: -40),
            radialGlowView.widthAnchor.constraint(equalToConstant: 380),
            radialGlowView.heightAnchor.constraint(equalToConstant: 380),

            statusCard.centerXAnchor.constraint(equalTo: centerContainer.centerXAnchor),
            statusCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 264),
            statusCard.widthAnchor.constraint(lessThanOrEqualTo: centerContainer.widthAnchor, constant: -48),

            cardStack.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 16),
            cardStack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 24),
            cardStack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -24),
            cardStack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -16),

            castCircleContainer.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 38),
            castCircleContainer.centerXAnchor.constraint(equalTo: centerContainer.centerXAnchor),
            castCircleContainer.centerYAnchor.constraint(equalTo: centerContainer.centerYAnchor, constant: 46),
            castCircleContainer.widthAnchor.constraint(equalToConstant: 220),
            castCircleContainer.heightAnchor.constraint(equalToConstant: 220),

            outerGlowRing.topAnchor.constraint(equalTo: castCircleContainer.topAnchor),
            outerGlowRing.leadingAnchor.constraint(equalTo: castCircleContainer.leadingAnchor),
            outerGlowRing.trailingAnchor.constraint(equalTo: castCircleContainer.trailingAnchor),
            outerGlowRing.bottomAnchor.constraint(equalTo: castCircleContainer.bottomAnchor),

            middleRing.topAnchor.constraint(equalTo: castCircleContainer.topAnchor, constant: 8),
            middleRing.leadingAnchor.constraint(equalTo: castCircleContainer.leadingAnchor, constant: 8),
            middleRing.trailingAnchor.constraint(equalTo: castCircleContainer.trailingAnchor, constant: -8),
            middleRing.bottomAnchor.constraint(equalTo: castCircleContainer.bottomAnchor, constant: -8),

            innerCoreRing.topAnchor.constraint(equalTo: castCircleContainer.topAnchor, constant: 16),
            innerCoreRing.leadingAnchor.constraint(equalTo: castCircleContainer.leadingAnchor, constant: 16),
            innerCoreRing.trailingAnchor.constraint(equalTo: castCircleContainer.trailingAnchor, constant: -16),
            innerCoreRing.bottomAnchor.constraint(equalTo: castCircleContainer.bottomAnchor, constant: -16),

            castIconView.widthAnchor.constraint(equalToConstant: 46),
            castIconView.heightAnchor.constraint(equalToConstant: 46),

            circleContentStack.centerXAnchor.constraint(equalTo: innerCoreRing.centerXAnchor),
            circleContentStack.centerYAnchor.constraint(equalTo: innerCoreRing.centerYAnchor),

            picker.topAnchor.constraint(equalTo: castCircleContainer.topAnchor),
            picker.leadingAnchor.constraint(equalTo: castCircleContainer.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: castCircleContainer.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: castCircleContainer.bottomAnchor),

            stopOverlayButton.topAnchor.constraint(equalTo: castCircleContainer.topAnchor),
            stopOverlayButton.leadingAnchor.constraint(equalTo: castCircleContainer.leadingAnchor),
            stopOverlayButton.trailingAnchor.constraint(equalTo: castCircleContainer.trailingAnchor),
            stopOverlayButton.bottomAnchor.constraint(equalTo: castCircleContainer.bottomAnchor),

            hintLabel.topAnchor.constraint(equalTo: castCircleContainer.bottomAnchor, constant: 18),
            hintLabel.leadingAnchor.constraint(equalTo: centerContainer.leadingAnchor, constant: 28),
            hintLabel.trailingAnchor.constraint(equalTo: centerContainer.trailingAnchor, constant: -28)
        ])
    }

    // MARK: - Settings & Observers

    private func loadPersistedSettings() {
        let loaded = InfinityStreamSettings.load()
        currentResolutionKey = loaded.resolution.key
        currentBitrateLabel = loaded.bitrate.label
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenCapturedChanged),
            name: UIScreen.capturedDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: InfinityStreamSettings.didChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeDidChange),
            name: InfinityThemeManager.didChangeNotification,
            object: nil
        )

        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            darwinCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let obs = observer else { return }
                let vc = Unmanaged<WXHomeViewController>.fromOpaque(obs).takeUnretainedValue()
                DispatchQueue.main.async {
                    vc.lastErrorMessage = nil
                    SilentAudioKeepAlive.shared.start()
                    let loaded = InfinityStreamSettings.load()
                    InfinityStreamSettings.saveAndApply(resolution: loaded.resolution, bitrate: loaded.bitrate)
                    vc.updateUIState()
                }
            },
            "com.apowermirror.broadcast.BroadcastStarted" as CFString,
            nil,
            .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            darwinCenter,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, _, _, _) in
                guard let obs = observer else { return }
                let vc = Unmanaged<WXHomeViewController>.fromOpaque(obs).takeUnretainedValue()
                DispatchQueue.main.async {
                    SilentAudioKeepAlive.shared.stop()
                    vc.recordingStartTime = nil
                    vc.stopDurationTimer()
                    vc.updateUIState()
                }
            },
            "com.apowermirror.broadcast.Finish" as CFString,
            nil,
            .deliverImmediately
        )
    }

    @objc private func handleSettingsChanged() {
        loadPersistedSettings()
        updateUIState()
    }

    @objc private func handleScreenCapturedChanged() {
        DispatchQueue.main.async { [weak self] in
            if UIScreen.main.isCaptured {
                SilentAudioKeepAlive.shared.start()
            } else if !ScreenRecorderManager.shared.isCapturing {
                SilentAudioKeepAlive.shared.stop()
            }
            self?.updateUIState()
        }
    }

    // MARK: - Actions

    @objc private func handleThemeToggle() {
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred()
        let targetWindow = view.window ?? UIApplication.shared.windows.first
        InfinityThemeManager.shared.toggle(in: targetWindow)
        themeToggleButton.updateState(animated: true)
    }

    @objc private func handleThemeDidChange() {
        themeToggleButton.updateState(animated: true)
    }

    @objc private func handlePickerTouchDown() {
        lastErrorMessage = nil
        SilentAudioKeepAlive.shared.start()
        hintLabel.text = "Select 'Start Broadcast' on the iOS prompt..."
    }

    @objc public func handleStopAction() {
        BroadcastPickerManager.shared.stopBroadcast()
        ScreenRecorderManager.shared.stopRecording { [weak self] _ in
            self?.updateUIState()
        }
        SilentAudioKeepAlive.shared.stop()
        recordingStartTime = nil
        stopDurationTimer()
        updateUIState()
    }

    @objc public func handleDirectMirrorAction() {
        let isCapturing = UIScreen.main.isCaptured || ScreenRecorderManager.shared.isCapturing
        if isCapturing {
            handleStopAction()
        } else {
            lastErrorMessage = nil
            SilentAudioKeepAlive.shared.start()
            BroadcastPickerManager.shared.presentBroadcastPicker()
        }
    }

    // MARK: - State & Animations

    private func updateUIState() {
        let isCapturing = ScreenRecorderManager.shared.isCapturing || UIScreen.main.isCaptured

        streamConfigLabel.text = "\(currentResolutionKey)  •  60 FPS  •  \(currentBitrateLabel)"

        if isCapturing {
            if recordingStartTime == nil {
                recordingStartTime = Date()
            }
            startDurationTimer()

            statusTitleLabel.text = "🟢 Streaming"
            statusSubtitleLabel.text = "Screen is shared • \(formattedElapsedTime())"

            let stopImg = UIImage(systemName: "stop.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 38, weight: .bold))
            castIconView.image = stopImg
            castIconView.tintColor = InfinityTheme.statusRed
            castActionLabel.text = "Stop"
            castActionLabel.textColor = InfinityTheme.statusRed
            innerCoreRing.layer.borderColor = InfinityTheme.statusRed.withAlphaComponent(0.75).cgColor

            nativePickerView?.isHidden = true
            nativePickerView?.isUserInteractionEnabled = false
            stopOverlayButton.isHidden = false

            hintLabel.text = lastErrorMessage ?? "Mirroring live • Tap Stop to end"
            hintLabel.textColor = lastErrorMessage != nil ? InfinityTheme.statusRed : InfinityTheme.textSecondary
        } else {
            recordingStartTime = nil
            stopDurationTimer()

            if isDesktopConnected {
                statusTitleLabel.text = "🟢 Connected"
                statusSubtitleLabel.text = "Ready to cast!"
            } else {
                statusTitleLabel.text = "🔴 Disconnected"
                statusSubtitleLabel.text = "Waiting for connection..."
            }

            let playImg = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .bold))
            castIconView.image = playImg
            castIconView.tintColor = InfinityTheme.brandBlue
            castActionLabel.text = "Start Casting"
            castActionLabel.textColor = InfinityTheme.brandBlue
            innerCoreRing.layer.borderColor = InfinityTheme.brandBlueLight.resolvedColor(with: traitCollection).cgColor

            nativePickerView?.isHidden = false
            nativePickerView?.isUserInteractionEnabled = true
            stopOverlayButton.isHidden = true

            if let err = lastErrorMessage {
                hintLabel.text = err
                hintLabel.textColor = InfinityTheme.statusRed
            } else {
                hintLabel.text = "Tap Start Casting to mirror your iPhone screen"
                hintLabel.textColor = InfinityTheme.textSecondary
            }
        }
    }

    private func formattedElapsedTime() -> String {
        guard let start = recordingStartTime else { return "00:00" }
        let elapsed = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func startDurationTimer() {
        guard durationTimer == nil else { return }
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if ScreenRecorderManager.shared.isCapturing || UIScreen.main.isCaptured {
                self.statusSubtitleLabel.text = "Screen is shared • \(self.formattedElapsedTime())"
            } else {
                self.stopDurationTimer()
                self.updateUIState()
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func startPulseAnimation() {
        outerGlowRing.layer.removeAnimation(forKey: "pulseScale")
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.08
        scale.duration = 1.6
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        outerGlowRing.layer.add(scale, forKey: "pulseScale")
    }

    private func stopPulseAnimation() {
        outerGlowRing.layer.removeAnimation(forKey: "pulseScale")
    }

    // MARK: - ScreenRecorderManagerDelegate

    public func screenRecorderDidStart() {
        DispatchQueue.main.async { [weak self] in
            self?.lastErrorMessage = nil
            WXCastiOSSender.shared.sendStartCastPayload()
            self?.updateUIState()
        }
    }

    public func screenRecorderDidStop(error: Error?) {
        DispatchQueue.main.async { [weak self] in
            if let error = error {
                self?.lastErrorMessage = error.localizedDescription
            }
            WXCastiOSSender.shared.sendStartCastPayload()
            self?.updateUIState()
        }
    }

    public func screenRecorderDidFail(error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.lastErrorMessage = error.localizedDescription
            self?.updateUIState()
        }
    }

    // MARK: - BroadcastPickerManagerDelegate

    public func broadcastCaptureStateChanged(isCaptured: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.updateUIState()
        }
    }

    // MARK: - WXCastiOSSenderDelegate

    public func castSenderDidConnectDesktop() {
        DispatchQueue.main.async { [weak self] in
            self?.isDesktopConnected = true
            self?.updateUIState()
        }
    }

    public func castSenderDidDisconnectDesktop() {
        DispatchQueue.main.async { [weak self] in
            self?.isDesktopConnected = false
            self?.updateUIState()
        }
    }

    public func castSenderDidRequestIDRKeyframe() {
        ScreenRecorderManager.shared.requestKeyframe()
    }
}
