//
//  WXHomeViewController.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Main Dashboard View Controller matching ApowerMirror's exact UI:
//  - Device info card (Apowersoft[iPhone], WiFi SSID)
//  - Iconic large circular "M" Start Mirror button with pulse animation
//  - Navigation bar scan shortcut and tutorial link
//  - Embedded WXHomeMirrorViewController container for live session HUD
//

import UIKit

@objc(WXHomeViewController)
open class WXHomeViewController: UIViewController {

    @IBOutlet public weak var scanBtn: UIButton!
    @IBOutlet public weak var tutorialBtn: WXLinkButton!
    @IBOutlet public weak var deviceNameTipLbl: UILabel!
    @IBOutlet public weak var deviceNameLbl: UILabel!
    @IBOutlet public weak var wifiNameTipLabel: UILabel!
    @IBOutlet public weak var wifiNameLabel: UILabel!
    @IBOutlet public weak var hintImgV: UIImageView!
    @IBOutlet public weak var scanLbl: UILabel!
    @IBOutlet public weak var topImgVTopConstraint: NSLayoutConstraint!
    @IBOutlet public weak var scanBtnCenterYConstraint: NSLayoutConstraint!
    @IBOutlet public weak var hintImgVBottomConstraint: NSLayoutConstraint!

    @objc public var mirrorVC: WXHomeMirrorViewController?
    @objc public var trackMark: Int32 = 0
    private var isIOSMirror: Bool = false
    private var pulseLayer: CAShapeLayer?

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        localization()
        setupNotification()
        setupNavScanBtn()
        updateWifi()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        updateWifi()
        startPulseAnimation()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPulseAnimation()
    }

    @objc public func localization() {
        deviceNameTipLbl?.text = "Device Name"
        deviceNameLbl?.text = UIDevice.current.name
        wifiNameTipLabel?.text = "WiFi:"
        scanLbl?.text = "Tap to Mirror"
        tutorialBtn?.setTitle("How to use ApowerMirror?", for: .normal)
    }

    @objc public func setupUI() {
        view.backgroundColor = UIColor(white: 0.96, alpha: 1.0)
        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard scanBtn == nil else { return }

        // Top decorative curved background
        let topBg = UIView()
        topBg.translatesAutoresizingMaskIntoConstraints = false
        topBg.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        view.addSubview(topBg)

        // Device Info Card
        let infoCard = UIView()
        infoCard.translatesAutoresizingMaskIntoConstraints = false
        infoCard.backgroundColor = .white
        infoCard.layer.cornerRadius = 16
        infoCard.layer.shadowColor = UIColor.black.cgColor
        infoCard.layer.shadowOffset = CGSize(width: 0, height: 4)
        infoCard.layer.shadowOpacity = 0.08
        infoCard.layer.shadowRadius = 12
        view.addSubview(infoCard)

        let phoneIcon = UIImageView()
        phoneIcon.translatesAutoresizingMaskIntoConstraints = false
        phoneIcon.image = UIImage(systemName: "iphone")
        phoneIcon.tintColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        phoneIcon.contentMode = .scaleAspectFit
        infoCard.addSubview(phoneIcon)

        let devTip = UILabel()
        devTip.translatesAutoresizingMaskIntoConstraints = false
        devTip.text = "Apowersoft [iOS]"
        devTip.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        devTip.textColor = UIColor(white: 0.5, alpha: 1.0)
        infoCard.addSubview(devTip)
        self.deviceNameTipLbl = devTip

        let devName = UILabel()
        devName.translatesAutoresizingMaskIntoConstraints = false
        devName.text = UIDevice.current.name
        devName.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        devName.textColor = UIColor(white: 0.15, alpha: 1.0)
        infoCard.addSubview(devName)
        self.deviceNameLbl = devName

        let wifiTip = UILabel()
        wifiTip.translatesAutoresizingMaskIntoConstraints = false
        wifiTip.text = "WiFi:"
        wifiTip.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        wifiTip.textColor = UIColor(white: 0.4, alpha: 1.0)
        infoCard.addSubview(wifiTip)
        self.wifiNameTipLabel = wifiTip

        let wifiName = UILabel()
        wifiName.translatesAutoresizingMaskIntoConstraints = false
        wifiName.text = "Connected"
        wifiName.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        wifiName.textColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        infoCard.addSubview(wifiName)
        self.wifiNameLabel = wifiName

        // Center Start Mirror Button (Iconic Blue Circle with "M")
        let btn = UIButton(type: .custom)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        btn.layer.cornerRadius = 85
        btn.layer.shadowColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 0.4).cgColor
        btn.layer.shadowOffset = CGSize(width: 0, height: 10)
        btn.layer.shadowOpacity = 0.5
        btn.layer.shadowRadius = 20
        btn.addTarget(self, action: #selector(scanAction(_:)), for: .touchUpInside)
        view.addSubview(btn)
        self.scanBtn = btn

        let mLabel = UILabel()
        mLabel.translatesAutoresizingMaskIntoConstraints = false
        mLabel.text = "M"
        mLabel.font = UIFont.systemFont(ofSize: 72, weight: .heavy)
        mLabel.textColor = .white
        mLabel.isUserInteractionEnabled = false
        btn.addSubview(mLabel)

        let mirrorText = UILabel()
        mirrorText.translatesAutoresizingMaskIntoConstraints = false
        mirrorText.text = "MIRROR"
        mirrorText.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        mirrorText.textColor = UIColor.white.withAlphaComponent(0.9)
        mirrorText.isUserInteractionEnabled = false
        btn.addSubview(mirrorText)

        // Subtitle prompt below button
        let sLbl = UILabel()
        sLbl.translatesAutoresizingMaskIntoConstraints = false
        sLbl.text = "Tap to search and mirror"
        sLbl.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        sLbl.textColor = UIColor(white: 0.4, alpha: 1.0)
        view.addSubview(sLbl)
        self.scanLbl = sLbl

        // Tutorial Link Button at bottom
        let tutBtn = WXLinkButton(type: .system)
        tutBtn.translatesAutoresizingMaskIntoConstraints = false
        tutBtn.setTitle("How to use ApowerMirror?", for: .normal)
        tutBtn.addTarget(self, action: #selector(showTutorialButtonClick(_:)), for: .touchUpInside)
        view.addSubview(tutBtn)
        self.tutorialBtn = tutBtn

        NSLayoutConstraint.activate([
            topBg.topAnchor.constraint(equalTo: view.topAnchor),
            topBg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBg.heightAnchor.constraint(equalToConstant: 220),

            infoCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            infoCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            infoCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            infoCard.heightAnchor.constraint(equalToConstant: 80),

            phoneIcon.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 16),
            phoneIcon.centerYAnchor.constraint(equalTo: infoCard.centerYAnchor),
            phoneIcon.widthAnchor.constraint(equalToConstant: 32),
            phoneIcon.heightAnchor.constraint(equalToConstant: 32),

            devTip.leadingAnchor.constraint(equalTo: phoneIcon.trailingAnchor, constant: 12),
            devTip.topAnchor.constraint(equalTo: infoCard.topAnchor, constant: 18),

            devName.leadingAnchor.constraint(equalTo: devTip.leadingAnchor),
            devName.topAnchor.constraint(equalTo: devTip.bottomAnchor, constant: 2),

            wifiName.trailingAnchor.constraint(equalTo: infoCard.trailingAnchor, constant: -16),
            wifiName.centerYAnchor.constraint(equalTo: infoCard.centerYAnchor),

            wifiTip.trailingAnchor.constraint(equalTo: wifiName.leadingAnchor, constant: -4),
            wifiTip.centerYAnchor.constraint(equalTo: wifiName.centerYAnchor),

            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 30),
            btn.widthAnchor.constraint(equalToConstant: 170),
            btn.heightAnchor.constraint(equalToConstant: 170),

            mLabel.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            mLabel.centerYAnchor.constraint(equalTo: btn.centerYAnchor, constant: -10),

            mirrorText.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
            mirrorText.topAnchor.constraint(equalTo: mLabel.bottomAnchor, constant: -6),

            sLbl.topAnchor.constraint(equalTo: btn.bottomAnchor, constant: 20),
            sLbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            tutBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            tutBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tutBtn.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc public func setupNavScanBtn() {
        let scanItem = UIBarButtonItem(
            image: UIImage(systemName: "qrcode.viewfinder"),
            style: .plain,
            target: self,
            action: #selector(goScanViewController)
        )
        scanItem.tintColor = .white
        navigationItem.rightBarButtonItem = scanItem

        let settingItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(rightItemToSettingClicked(_:))
        )
        settingItem.tintColor = .white
        navigationItem.leftBarButtonItem = settingItem
    }

    @objc public func updateWifi() {
        let ssid = NetworkDetector.currentSSID() ?? "Wi-Fi Connected"
        wifiNameLabel?.text = ssid
    }

    private func startPulseAnimation() {
        stopPulseAnimation()
        guard let btn = scanBtn else { return }

        let pulse = CAShapeLayer()
        pulse.frame = btn.bounds
        pulse.path = UIBezierPath(ovalIn: btn.bounds).cgPath
        pulse.strokeColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 0.5).cgColor
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

    @objc public func setupNotification() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onIOSConnected(_:)),
            name: NSNotification.Name("kBroadCastConnectedNotification"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onIOSDisconnect),
            name: NSNotification.Name("stopBroadCastNotification"),
            object: nil
        )
    }

    // MARK: - Actions

    @objc @IBAction public func scanAction(_ sender: Any) {
        let mirrorHubVC = WXMirrorViewController()
        navigationController?.pushViewController(mirrorHubVC, animated: true)
    }

    @objc @IBAction public func showTutorialButtonClick(_ sender: Any) {
        let guideVC = WXRecordGuideVC()
        let nav = UINavigationController(rootViewController: guideVC)
        present(nav, animated: true)
    }

    @objc public func goScanViewController() {
        let qrVC = WXQRScanViewController()
        navigationController?.pushViewController(qrVC, animated: true)
    }

    @objc public func goCodeLinkViewController() {
        let codeVC = WXCodeLinkViewController()
        navigationController?.pushViewController(codeVC, animated: true)
    }

    @objc public func rightItemToSettingClicked(_ sender: Any) {
        let alert = UIAlertController(title: "Settings", message: "ApowerMirror Version 1.5.2 (Build 2026)", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Resolution: 1080P (High)", style: .default))
        alert.addAction(UIAlertAction(title: "Framerate: 60 FPS", style: .default))
        alert.addAction(UIAlertAction(title: "AirPlay Receiver: Enabled", style: .default))
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    @objc public func onIOSConnected(_ notification: Notification) {
        showMirrorView(true)
    }

    @objc public func onIOSDisconnect() {
        hideMirrorView()
    }

    @objc public func showMirrorView(_ show: Bool) {
        isIOSMirror = true
        let mVC = WXHomeMirrorViewController()
        mVC.onDisconnectRequested = { [weak self] in
            self?.hideMirrorView()
        }
        addChild(mVC)
        mVC.view.frame = view.bounds
        view.addSubview(mVC.view)
        mVC.didMove(toParent: self)
        self.mirrorVC = mVC
    }

    @objc public func hideMirrorView() {
        isIOSMirror = false
        mirrorVC?.willMove(toParent: nil)
        mirrorVC?.view.removeFromSuperview()
        mirrorVC?.removeFromParent()
        mirrorVC = nil
    }
}
