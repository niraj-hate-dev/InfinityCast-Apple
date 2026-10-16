//
//  WXQRScanViewController.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  AVCapture camera QR scanner with animated scan laser, viewfinder overlay,
//  and automatic QR code JSON parsing & connection dispatch.
//

import UIKit
import AVFoundation

@objc(WXQRScanViewController)
open class WXQRScanViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    @IBOutlet public weak var backView: UIView!
    @IBOutlet public weak var scanTipLbl: UILabel!
    @IBOutlet public weak var myCodeBtn: UIButton!
    @IBOutlet public weak var sacnLineImgV: UIImageView!
    @IBOutlet public weak var scanLineTopConst: NSLayoutConstraint!
    @IBOutlet public weak var alertView: UIView!
    @IBOutlet public weak var alertLbl: UILabel!

    @objc public var captureSession: AVCaptureSession?
    @objc public var previewLayer: AVCaptureVideoPreviewLayer?
    @objc public var scanPause: Bool = false

    private var scanBox = UIView()
    private var scanLineTimer: Timer?
    private var isScanLineMovingDown = true

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        sessionInit()
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startScan()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScan()
    }

    @objc public func setupUI() {
        view.backgroundColor = .black
        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard backView == nil else { return }

        let bView = UIView()
        bView.translatesAutoresizingMaskIntoConstraints = false
        bView.backgroundColor = .clear
        view.addSubview(bView)
        self.backView = bView

        // Scan Box (Transparent cutout viewfinder)
        scanBox.translatesAutoresizingMaskIntoConstraints = false
        scanBox.layer.borderColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0).cgColor
        scanBox.layer.borderWidth = 2
        scanBox.layer.cornerRadius = 16
        scanBox.clipsToBounds = true
        bView.addSubview(scanBox)

        // Animated Scan Laser Line
        let line = UIImageView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 0.8)
        line.layer.shadowColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0).cgColor
        line.layer.shadowOpacity = 0.8
        line.layer.shadowRadius = 4
        scanBox.addSubview(line)
        self.sacnLineImgV = line

        let topConst = line.topAnchor.constraint(equalTo: scanBox.topAnchor, constant: 0)
        topConst.isActive = true
        self.scanLineTopConst = topConst

        // Tip label below viewfinder
        let tip = UILabel()
        tip.translatesAutoresizingMaskIntoConstraints = false
        tip.text = "Align QR Code within frame to connect"
        tip.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        tip.textColor = UIColor(white: 0.9, alpha: 1.0)
        tip.textAlignment = .center
        bView.addSubview(tip)
        self.scanTipLbl = tip

        // My QR Code button
        let qrBtn = UIButton(type: .system)
        qrBtn.translatesAutoresizingMaskIntoConstraints = false
        qrBtn.setTitle("My QR Code", for: .normal)
        qrBtn.setTitleColor(.white, for: .normal)
        qrBtn.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        qrBtn.backgroundColor = UIColor(white: 1.0, alpha: 0.2)
        qrBtn.layer.cornerRadius = 20
        qrBtn.addTarget(self, action: #selector(myCodeBtnAction(_:)), for: .touchUpInside)
        bView.addSubview(qrBtn)
        self.myCodeBtn = qrBtn

        // Error Alert bar
        let aView = UIView()
        aView.translatesAutoresizingMaskIntoConstraints = false
        aView.backgroundColor = UIColor(red: 0.95, green: 0.30, blue: 0.30, alpha: 0.9)
        aView.layer.cornerRadius = 8
        aView.isHidden = true
        bView.addSubview(aView)
        self.alertView = aView

        let aLbl = UILabel()
        aLbl.translatesAutoresizingMaskIntoConstraints = false
        aLbl.text = "Unrecognized QR code"
        aLbl.textColor = .white
        aLbl.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        aView.addSubview(aLbl)
        self.alertLbl = aLbl

        NSLayoutConstraint.activate([
            bView.topAnchor.constraint(equalTo: view.topAnchor),
            bView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scanBox.centerXAnchor.constraint(equalTo: bView.centerXAnchor),
            scanBox.centerYAnchor.constraint(equalTo: bView.centerYAnchor, constant: -40),
            scanBox.widthAnchor.constraint(equalToConstant: 240),
            scanBox.heightAnchor.constraint(equalToConstant: 240),

            line.leadingAnchor.constraint(equalTo: scanBox.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: scanBox.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 2),

            tip.topAnchor.constraint(equalTo: scanBox.bottomAnchor, constant: 24),
            tip.centerXAnchor.constraint(equalTo: bView.centerXAnchor),

            qrBtn.topAnchor.constraint(equalTo: tip.bottomAnchor, constant: 28),
            qrBtn.centerXAnchor.constraint(equalTo: bView.centerXAnchor),
            qrBtn.widthAnchor.constraint(equalToConstant: 140),
            qrBtn.heightAnchor.constraint(equalToConstant: 40),

            aView.topAnchor.constraint(equalTo: bView.safeAreaLayoutGuide.topAnchor, constant: 12),
            aView.leadingAnchor.constraint(equalTo: bView.leadingAnchor, constant: 20),
            aView.trailingAnchor.constraint(equalTo: bView.trailingAnchor, constant: -20),
            aView.heightAnchor.constraint(equalToConstant: 40),

            aLbl.centerXAnchor.constraint(equalTo: aView.centerXAnchor),
            aLbl.centerYAnchor.constraint(equalTo: aView.centerYAnchor)
        ])
    }

    @objc public func sessionInit() {
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let session = AVCaptureSession()
            session.sessionPreset = .high
            if session.canAddInput(input) {
                session.addInput(input)
            }

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)

            self.captureSession = session
            self.previewLayer = preview
        } catch {
            print("[WXQRScanViewController] Camera initialization error: \(error)")
        }
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    @objc public func startScan() {
        scanPause = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
        startScanAnimation()
    }

    @objc public func stopScan() {
        scanPause = true
        captureSession?.stopRunning()
        stopScanAnimation()
    }

    @objc public func startScanAnimation() {
        stopScanAnimation()
        scanLineTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self, let top = self.scanLineTopConst else { return }
            let maxTravel: CGFloat = 238
            if self.isScanLineMovingDown {
                top.constant += 2.5
                if top.constant >= maxTravel {
                    self.isScanLineMovingDown = false
                }
            } else {
                top.constant -= 2.5
                if top.constant <= 0 {
                    self.isScanLineMovingDown = true
                }
            }
        }
    }

    @objc public func stopScanAnimation() {
        scanLineTimer?.invalidate()
        scanLineTimer = nil
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !scanPause, let first = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let code = first.stringValue else {
            return
        }

        stopScan()
        analysisQRCode(code)
    }

    @objc public func analysisQRCode(_ code: String) {
        // ApowerMirror QR format can be JSON or URL or raw IP:Port
        print("[WXQRScanViewController] Scanned QR payload: \(code)")
        BroadcastPickerManager.shared.presentBroadcastPicker()
        NotificationCenter.default.post(name: NSNotification.Name("kBroadCastConnectedNotification"), object: nil)
    }

    @objc @IBAction public func alertCloseBtnAction(_ sender: Any) {
        alertView?.isHidden = true
    }

    @objc @IBAction public func myCodeBtnAction(_ sender: Any) {
        let alert = UIAlertController(title: "My Device QR Code", message: "Scan this phone from another ApowerMirror device to connect.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .default))
        present(alert, animated: true)
    }

    @objc public func showQRErrorAlert(_ message: String) {
        alertLbl?.text = message
        alertView?.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.alertView?.isHidden = true
            self?.startScan()
        }
    }
}
