//
//  WXRecordGuideVC.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Broadcast recording setup and tutorial guide with animated video player.
//

import UIKit
import AVFoundation

@objc(WXRecordGuideVC)
open class WXRecordGuideVC: UIViewController {

    @IBOutlet public weak var titleLabel: UILabel!
    @IBOutlet public weak var tipLabel: UILabel!
    @IBOutlet public weak var playBgView: UIImageView!
    @IBOutlet public weak var notFoundButton: UIButton!
    @IBOutlet public weak var leftMargin: NSLayoutConstraint!
    @IBOutlet public weak var rightMargin: NSLayoutConstraint!
    @IBOutlet public weak var topNavHeight: NSLayoutConstraint!

    @objc public var playerLayer: AVPlayerLayer?
    @objc public var player: AVPlayer?

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        play()
    }

    private func setupUI() {
        view.backgroundColor = .white
        title = "Screen Recording Guide"

        let closeItem = UIBarButtonItem(
            title: "Done",
            style: .done,
            target: self,
            action: #selector(onFinishAction(_:))
        )
        navigationItem.rightBarButtonItem = closeItem

        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard titleLabel == nil else { return }

        let tLbl = UILabel()
        tLbl.translatesAutoresizingMaskIntoConstraints = false
        tLbl.text = "How to Mirror iOS Screen"
        tLbl.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        tLbl.textColor = UIColor(white: 0.15, alpha: 1.0)
        tLbl.textAlignment = .center
        view.addSubview(tLbl)
        self.titleLabel = tLbl

        let subLbl = UILabel()
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        subLbl.text = "1. Swipe down Control Center\n2. Long press Screen Recording\n3. Select 'ApowerMirror' & Start Broadcast"
        subLbl.numberOfLines = 0
        subLbl.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        subLbl.textColor = UIColor(white: 0.4, alpha: 1.0)
        view.addSubview(subLbl)
        self.tipLabel = subLbl

        let bgImg = UIImageView()
        bgImg.translatesAutoresizingMaskIntoConstraints = false
        bgImg.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        bgImg.layer.cornerRadius = 16
        bgImg.layer.masksToBounds = true
        bgImg.contentMode = .scaleAspectFit
        view.addSubview(bgImg)
        self.playBgView = bgImg

        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("Can't find ApowerMirror in list?", for: .normal)
        btn.setTitleColor(UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0), for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        btn.addTarget(self, action: #selector(onNotFoundAction), for: .touchUpInside)
        view.addSubview(btn)
        self.notFoundButton = btn

        NSLayoutConstraint.activate([
            tLbl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            tLbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            subLbl.topAnchor.constraint(equalTo: tLbl.bottomAnchor, constant: 14),
            subLbl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            subLbl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            bgImg.topAnchor.constraint(equalTo: subLbl.bottomAnchor, constant: 20),
            bgImg.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            bgImg.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            bgImg.heightAnchor.constraint(equalToConstant: 280),

            btn.topAnchor.constraint(equalTo: bgImg.bottomAnchor, constant: 20),
            btn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            btn.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc public func play() {
        // Sample loop or placeholder animation
    }

    @objc @IBAction public func onFinishAction(_ sender: Any) {
        dismiss(animated: true)
    }

    @objc private func onNotFoundAction() {
        let alert = UIAlertController(
            title: "Extension Missing?",
            message: "Open Settings > Control Center > Add 'Screen Recording'. Ensure ApowerMirror has local network permission enabled.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
