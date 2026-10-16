//
//  WXCodeLinkViewController.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  PIN Code connection controller with digit input boxes, error alert banner,
//  and direct desktop link handshake.
//

import UIKit

@objc(WXCodeLinkViewController)
open class WXCodeLinkViewController: UIViewController, UITextFieldDelegate {

    @IBOutlet public weak var backView: UIView!
    @IBOutlet public weak var codeView: UIView!
    @IBOutlet public weak var codeInputView: WXCodeTextFiled!
    @IBOutlet public weak var codeTF: UITextField!
    @IBOutlet public weak var connectBtn: UIButton!
    @IBOutlet public weak var alertView: UIView!
    @IBOutlet public weak var alertLbl: UILabel!
    @IBOutlet public weak var myCodeTipLbl: UILabel!
    @IBOutlet public weak var myCodeLbl: UILabel!
    @IBOutlet public weak var wifiLbl: UILabel!

    @objc public var code: String = ""
    @objc public var isConnectedAirPlay: Bool = false
    private var showAlert: Bool = false

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        view.endEditing(true)
    }

    @objc public func setupUI() {
        view.backgroundColor = UIColor(white: 0.96, alpha: 1.0)
        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard backView == nil else { return }

        let bView = UIView()
        bView.translatesAutoresizingMaskIntoConstraints = false
        bView.backgroundColor = .clear
        view.addSubview(bView)
        self.backView = bView

        // Alert View (Warning bar)
        let aView = UIView()
        aView.translatesAutoresizingMaskIntoConstraints = false
        aView.backgroundColor = UIColor(red: 1.0, green: 0.95, blue: 0.90, alpha: 1.0)
        aView.layer.cornerRadius = 8
        aView.layer.borderWidth = 1
        aView.layer.borderColor = UIColor(red: 1.0, green: 0.70, blue: 0.40, alpha: 1.0).cgColor
        aView.isHidden = true
        bView.addSubview(aView)
        self.alertView = aView

        let aIcon = UIImageView()
        aIcon.translatesAutoresizingMaskIntoConstraints = false
        aIcon.image = UIImage(systemName: "exclamationmark.triangle.fill")
        aIcon.tintColor = UIColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1.0)
        aView.addSubview(aIcon)

        let aLbl = UILabel()
        aLbl.translatesAutoresizingMaskIntoConstraints = false
        aLbl.text = "Please enter the correct PIN code"
        aLbl.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        aLbl.textColor = UIColor(red: 0.85, green: 0.40, blue: 0.05, alpha: 1.0)
        aView.addSubview(aLbl)
        self.alertLbl = aLbl

        let aClose = UIButton(type: .system)
        aClose.translatesAutoresizingMaskIntoConstraints = false
        aClose.setImage(UIImage(systemName: "xmark"), for: .normal)
        aClose.tintColor = UIColor(white: 0.6, alpha: 1.0)
        aClose.addTarget(self, action: #selector(alertCloseBtnAction(_:)), for: .touchUpInside)
        aView.addSubview(aClose)

        // WiFi info label
        let wLbl = UILabel()
        wLbl.translatesAutoresizingMaskIntoConstraints = false
        wLbl.text = "WiFi: \(NetworkDetector.currentSSID() ?? "Connected")"
        wLbl.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        wLbl.textColor = UIColor(white: 0.5, alpha: 1.0)
        bView.addSubview(wLbl)
        self.wifiLbl = wLbl

        // Card Container for PIN input
        let cView = UIView()
        cView.translatesAutoresizingMaskIntoConstraints = false
        cView.backgroundColor = .white
        cView.layer.cornerRadius = 16
        cView.layer.shadowColor = UIColor.black.cgColor
        cView.layer.shadowOffset = CGSize(width: 0, height: 4)
        cView.layer.shadowOpacity = 0.05
        cView.layer.shadowRadius = 10
        bView.addSubview(cView)
        self.codeView = cView

        let pinTitle = UILabel()
        pinTitle.translatesAutoresizingMaskIntoConstraints = false
        pinTitle.text = "Enter 4-Digit PIN Code"
        pinTitle.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        pinTitle.textColor = UIColor(white: 0.2, alpha: 1.0)
        pinTitle.textAlignment = .center
        cView.addSubview(pinTitle)

        // Custom Digit Boxes
        let input = WXCodeTextFiled()
        input.translatesAutoresizingMaskIntoConstraints = false
        input.maxDigits = 4
        cView.addSubview(input)
        self.codeInputView = input

        input.codeDidChange = { [weak self] newCode in
            self?.code = newCode
            self?.refreshConnectBtn()
        }

        // Start Mirror Connect Button
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setTitle("Start Mirroring", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        btn.backgroundColor = UIColor(white: 0.75, alpha: 1.0)
        btn.layer.cornerRadius = 24
        btn.layer.masksToBounds = true
        btn.isEnabled = false
        btn.addTarget(self, action: #selector(startMirror(_:)), for: .touchUpInside)
        bView.addSubview(btn)
        self.connectBtn = btn

        // My PIN Code display
        let tipLbl = UILabel()
        tipLbl.translatesAutoresizingMaskIntoConstraints = false
        tipLbl.text = "My PIN Code"
        tipLbl.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        tipLbl.textColor = UIColor(white: 0.6, alpha: 1.0)
        tipLbl.textAlignment = .center
        bView.addSubview(tipLbl)
        self.myCodeTipLbl = tipLbl

        let myLbl = UILabel()
        myLbl.translatesAutoresizingMaskIntoConstraints = false
        myLbl.text = "8 3 9 1"
        myLbl.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        myLbl.textColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        myLbl.textAlignment = .center
        bView.addSubview(myLbl)
        self.myCodeLbl = myLbl

        NSLayoutConstraint.activate([
            bView.topAnchor.constraint(equalTo: view.topAnchor),
            bView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            aView.topAnchor.constraint(equalTo: bView.topAnchor, constant: 12),
            aView.leadingAnchor.constraint(equalTo: bView.leadingAnchor, constant: 20),
            aView.trailingAnchor.constraint(equalTo: bView.trailingAnchor, constant: -20),
            aView.heightAnchor.constraint(equalToConstant: 44),

            aIcon.leadingAnchor.constraint(equalTo: aView.leadingAnchor, constant: 12),
            aIcon.centerYAnchor.constraint(equalTo: aView.centerYAnchor),
            aIcon.widthAnchor.constraint(equalToConstant: 18),
            aIcon.heightAnchor.constraint(equalToConstant: 18),

            aClose.trailingAnchor.constraint(equalTo: aView.trailingAnchor, constant: -12),
            aClose.centerYAnchor.constraint(equalTo: aView.centerYAnchor),
            aClose.widthAnchor.constraint(equalToConstant: 24),
            aClose.heightAnchor.constraint(equalToConstant: 24),

            aLbl.leadingAnchor.constraint(equalTo: aIcon.trailingAnchor, constant: 8),
            aLbl.trailingAnchor.constraint(equalTo: aClose.leadingAnchor, constant: -8),
            aLbl.centerYAnchor.constraint(equalTo: aView.centerYAnchor),

            wLbl.topAnchor.constraint(equalTo: aView.bottomAnchor, constant: 14),
            wLbl.leadingAnchor.constraint(equalTo: bView.leadingAnchor, constant: 20),

            cView.topAnchor.constraint(equalTo: wLbl.bottomAnchor, constant: 14),
            cView.leadingAnchor.constraint(equalTo: bView.leadingAnchor, constant: 20),
            cView.trailingAnchor.constraint(equalTo: bView.trailingAnchor, constant: -20),
            cView.heightAnchor.constraint(equalToConstant: 150),

            pinTitle.topAnchor.constraint(equalTo: cView.topAnchor, constant: 20),
            pinTitle.centerXAnchor.constraint(equalTo: cView.centerXAnchor),

            input.topAnchor.constraint(equalTo: pinTitle.bottomAnchor, constant: 18),
            input.centerXAnchor.constraint(equalTo: cView.centerXAnchor),
            input.widthAnchor.constraint(equalToConstant: 260),
            input.heightAnchor.constraint(equalToConstant: 54),

            btn.topAnchor.constraint(equalTo: cView.bottomAnchor, constant: 28),
            btn.leadingAnchor.constraint(equalTo: bView.leadingAnchor, constant: 30),
            btn.trailingAnchor.constraint(equalTo: bView.trailingAnchor, constant: -30),
            btn.heightAnchor.constraint(equalToConstant: 48),

            tipLbl.topAnchor.constraint(equalTo: btn.bottomAnchor, constant: 30),
            tipLbl.centerXAnchor.constraint(equalTo: bView.centerXAnchor),

            myLbl.topAnchor.constraint(equalTo: tipLbl.bottomAnchor, constant: 6),
            myLbl.centerXAnchor.constraint(equalTo: bView.centerXAnchor)
        ])
    }

    @objc public func refreshConnectBtn() {
        let isComplete = (code.count == 4)
        connectBtn?.isEnabled = isComplete
        connectBtn?.backgroundColor = isComplete
            ? UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
            : UIColor(white: 0.75, alpha: 1.0)
    }

    @objc @IBAction public func alertCloseBtnAction(_ sender: Any) {
        alertView?.isHidden = true
    }

    @objc @IBAction public func startMirror(_ sender: Any) {
        guard code.count == 4 else {
            showErrorAlert("Please enter a valid 4-digit code")
            return
        }

        view.endEditing(true)
        // Launch ReplayKit broadcast picker
        BroadcastPickerManager.shared.presentBroadcastPicker()
        NotificationCenter.default.post(name: NSNotification.Name("kNotificationCodeLink"), object: nil, userInfo: ["code": code])
    }

    @objc public func showErrorAlert(_ message: String) {
        alertLbl?.text = message
        alertView?.isHidden = false
    }

    @objc public func showNotFoundAlert() {
        showErrorAlert("PIN code expired or PC is not responding.")
    }

    @objc public func showCodeLinkView() {
        view.isHidden = false
    }

    @objc public func hideCodeLinkView() {
        view.isHidden = true
    }

    @objc public func showDefaultView() {
        alertView?.isHidden = true
        code = ""
        codeInputView?.code = ""
        refreshConnectBtn()
    }
}
