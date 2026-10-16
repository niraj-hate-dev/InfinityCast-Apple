//
//  WXHomeMirrorViewController.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Active mirroring in-session HUD controller with live stream controls
//  (Disconnect, Voice/Microphone Mute, Camera Toggle, and PC status).
//

import UIKit

@objc(WXHomeMirrorViewController)
open class WXHomeMirrorViewController: UIViewController {

    @IBOutlet public weak var navBackView: UIView!
    @IBOutlet public weak var disconnectBtn: UIButton!
    @IBOutlet public weak var cameraLabel: UILabel!
    @IBOutlet public weak var disconnectLabel: UILabel!
    @IBOutlet public weak var cameraBtn: UIButton!
    @IBOutlet public weak var titleLbl: UILabel!
    @IBOutlet public weak var voiceBtn: UIButton!
    @IBOutlet public weak var voiceLabel: UILabel!

    @objc public var iosMirror: Bool = true
    public var onDisconnectRequested: (() -> Void)?
    
    private var isAudioMuted: Bool = false
    private var isCameraActive: Bool = false

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        localization()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    @objc public func localization() {
        cameraLabel?.text = "Camera"
        disconnectLabel?.text = "Disconnect"
        voiceLabel?.text = isAudioMuted ? "Unmute" : "Mute"
        titleLbl?.text = "Screen Mirroring Active"
    }

    @objc public func setupUI() {
        view.backgroundColor = UIColor(white: 0.96, alpha: 1.0)
        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard navBackView == nil else { return }

        let nav = UIView()
        nav.translatesAutoresizingMaskIntoConstraints = false
        nav.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        view.addSubview(nav)
        self.navBackView = nav

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Screen Mirroring Active"
        title.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center
        nav.addSubview(title)
        self.titleLbl = title

        // Status Card
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 16
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.05
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.layer.shadowRadius = 10
        view.addSubview(card)

        let pulseDot = UIView()
        pulseDot.translatesAutoresizingMaskIntoConstraints = false
        pulseDot.backgroundColor = UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1.0)
        pulseDot.layer.cornerRadius = 6
        card.addSubview(pulseDot)

        let statusText = UILabel()
        statusText.translatesAutoresizingMaskIntoConstraints = false
        statusText.text = "Connected & Streaming 60 FPS (H.264)"
        statusText.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        statusText.textColor = UIColor(white: 0.3, alpha: 1.0)
        card.addSubview(statusText)

        // Control Buttons Stack
        let buttonsStack = UIStackView()
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false
        buttonsStack.axis = .horizontal
        buttonsStack.distribution = .fillEqually
        buttonsStack.spacing = 20
        view.addSubview(buttonsStack)

        // Voice Item
        let voiceItem = createActionItem(icon: "mic.fill", label: "Mute")
        self.voiceBtn = voiceItem.btn
        self.voiceLabel = voiceItem.lbl
        voiceBtn.addTarget(self, action: #selector(voiceBtnClick(_:)), for: .touchUpInside)
        buttonsStack.addArrangedSubview(voiceItem.container)

        // Camera Item
        let cameraItem = createActionItem(icon: "video.fill", label: "Camera")
        self.cameraBtn = cameraItem.btn
        self.cameraLabel = cameraItem.lbl
        cameraBtn.addTarget(self, action: #selector(cameraBtnClick(_:)), for: .touchUpInside)
        buttonsStack.addArrangedSubview(cameraItem.container)

        // Disconnect Item
        let discItem = createActionItem(icon: "phone.down.fill", label: "Disconnect", tintColor: UIColor(red: 0.95, green: 0.3, blue: 0.3, alpha: 1.0))
        self.disconnectBtn = discItem.btn
        self.disconnectLabel = discItem.lbl
        disconnectBtn.addTarget(self, action: #selector(disconnectBtnClick(_:)), for: .touchUpInside)
        buttonsStack.addArrangedSubview(discItem.container)

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: view.topAnchor),
            nav.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nav.heightAnchor.constraint(equalToConstant: 100),

            title.bottomAnchor.constraint(equalTo: nav.bottomAnchor, constant: -16),
            title.centerXAnchor.constraint(equalTo: nav.centerXAnchor),

            card.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: 24),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            card.heightAnchor.constraint(equalToConstant: 64),

            pulseDot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            pulseDot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            pulseDot.widthAnchor.constraint(equalToConstant: 12),
            pulseDot.heightAnchor.constraint(equalToConstant: 12),

            statusText.leadingAnchor.constraint(equalTo: pulseDot.trailingAnchor, constant: 10),
            statusText.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            statusText.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            buttonsStack.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 40),
            buttonsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            buttonsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            buttonsStack.heightAnchor.constraint(equalToConstant: 90)
        ])
    }

    private func createActionItem(icon: String, label: String, tintColor: UIColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)) -> (container: UIView, btn: UIButton, lbl: UILabel) {
        let container = UIView()
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setImage(UIImage(systemName: icon), for: .normal)
        btn.tintColor = tintColor
        btn.backgroundColor = tintColor.withAlphaComponent(0.12)
        btn.layer.cornerRadius = 28
        btn.layer.masksToBounds = true
        container.addSubview(btn)

        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.text = label
        lbl.textColor = UIColor(white: 0.2, alpha: 1.0)
        lbl.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        lbl.textAlignment = .center
        container.addSubview(lbl)

        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: container.topAnchor),
            btn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            btn.widthAnchor.constraint(equalToConstant: 56),
            btn.heightAnchor.constraint(equalToConstant: 56),

            lbl.topAnchor.constraint(equalTo: btn.bottomAnchor, constant: 8),
            lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lbl.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return (container, btn, lbl)
    }

    @objc @IBAction public func disconnectBtnClick(_ sender: Any) {
        let alert = UIAlertController(title: "Disconnect Mirroring", message: "Do you want to stop casting your screen?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Stop", style: .destructive) { [weak self] _ in
            self?.stopMirror()
        })
        present(alert, animated: true)
    }

    @objc @IBAction public func voiceBtnClick(_ sender: Any) {
        isAudioMuted.toggle()
        voiceLabel?.text = isAudioMuted ? "Unmute" : "Mute"
        let iconName = isAudioMuted ? "mic.slash.fill" : "mic.fill"
        voiceBtn?.setImage(UIImage(systemName: iconName), for: .normal)
        NotificationCenter.default.post(name: NSNotification.Name("com.apowermirror.audioMuteToggled"), object: nil, userInfo: ["isMuted": isAudioMuted])
    }

    @objc @IBAction public func cameraBtnClick(_ sender: Any) {
        isCameraActive.toggle()
        cameraBtn?.tintColor = isCameraActive ? UIColor.systemGreen : UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        showNoCameraAlert()
    }

    @objc public func showNoCameraAlert() {
        let alert = UIAlertController(title: "Camera Cast", message: "Rear/Front camera overlay is available during mirroring.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc public func stopMirror() {
        NotificationCenter.default.post(name: NSNotification.Name("stopBroadCastNotification"), object: nil)
        onDisconnectRequested?()
    }
}
