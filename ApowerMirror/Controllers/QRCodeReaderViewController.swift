//
//  QRCodeReaderViewController.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Alternative QR Code reader view controller with flashlight control,
//  Wi-Fi network indicator, and callback block.
//

import UIKit
import AVFoundation

@objc(QRCodeReaderViewController)
open class QRCodeReaderViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    @IBOutlet public weak var cameraView: UIView!
    @IBOutlet public weak var readerLabel: UILabel!
    @IBOutlet public weak var readerHeaderLabel: UILabel!
    @IBOutlet public weak var loadProgress: UIActivityIndicatorView!
    @IBOutlet public weak var torchButton: UIButton!
    @IBOutlet public weak var WiFiLabel: UILabel!
    @IBOutlet public weak var backButton: UIButton!
    @IBOutlet public weak var wifiNameLabel: UILabel!

    @objc public var defaultDevice: AVCaptureDevice?
    @objc public var session: AVCaptureSession?
    @objc public var previewLayer: AVCaptureVideoPreviewLayer?
    @objc public var completionBlock: ((String?) -> Void)?
    
    private var isTorchOn: Bool = false

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        configureDefaultComponents()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    private func setupUI() {
        view.backgroundColor = .black
        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard cameraView == nil else { return }

        let cam = UIView()
        cam.translatesAutoresizingMaskIntoConstraints = false
        cam.backgroundColor = .black
        view.addSubview(cam)
        self.cameraView = cam

        let header = UILabel()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.text = "Scan QR Code"
        header.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        header.textColor = .white
        header.textAlignment = .center
        view.addSubview(header)
        self.readerHeaderLabel = header

        let back = UIButton(type: .system)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        back.tintColor = .white
        back.addTarget(self, action: #selector(cancelAction(_:)), for: .touchUpInside)
        view.addSubview(back)
        self.backButton = back

        let torch = UIButton(type: .system)
        torch.translatesAutoresizingMaskIntoConstraints = false
        torch.setImage(UIImage(systemName: "flashlight.off.fill"), for: .normal)
        torch.tintColor = .white
        torch.addTarget(self, action: #selector(turnTorchOnOrOff(_:)), for: .touchUpInside)
        view.addSubview(torch)
        self.torchButton = torch

        let wifi = UILabel()
        wifi.translatesAutoresizingMaskIntoConstraints = false
        wifi.text = "WiFi: \(NetworkDetector.currentSSID() ?? "Connected")"
        wifi.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        wifi.textColor = UIColor(white: 0.8, alpha: 1.0)
        wifi.textAlignment = .center
        view.addSubview(wifi)
        self.wifiNameLabel = wifi

        let reader = UILabel()
        reader.translatesAutoresizingMaskIntoConstraints = false
        reader.text = "Scan QR Code displayed on PC ApowerMirror"
        reader.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        reader.textColor = UIColor(white: 0.9, alpha: 1.0)
        reader.textAlignment = .center
        view.addSubview(reader)
        self.readerLabel = reader

        let progress = UIActivityIndicatorView(style: .large)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.color = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        progress.hidesWhenStopped = true
        view.addSubview(progress)
        self.loadProgress = progress

        NSLayoutConstraint.activate([
            cam.topAnchor.constraint(equalTo: view.topAnchor),
            cam.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cam.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cam.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            back.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            back.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            back.widthAnchor.constraint(equalToConstant: 32),
            back.heightAnchor.constraint(equalToConstant: 32),

            header.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            header.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            torch.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            torch.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            torch.widthAnchor.constraint(equalToConstant: 32),
            torch.heightAnchor.constraint(equalToConstant: 32),

            wifi.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            wifi.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            reader.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
            reader.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc public func configureDefaultComponents() {
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        self.defaultDevice = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            let captureSession = AVCaptureSession()
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }

            let output = AVCaptureMetadataOutput()
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }

            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            cameraView?.layer.insertSublayer(preview, at: 0)

            self.session = captureSession
            self.previewLayer = preview
        } catch {
            print("[QRCodeReaderViewController] Camera setup error: \(error)")
        }
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    @objc public func startScanning() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session?.startRunning()
        }
    }

    @objc public func stopScanning() {
        session?.stopRunning()
    }

    @objc @IBAction public func turnTorchOnOrOff(_ sender: Any) {
        guard let device = defaultDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            isTorchOn.toggle()
            device.torchMode = isTorchOn ? .on : .off
            device.unlockForConfiguration()
            let icon = isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill"
            torchButton?.setImage(UIImage(systemName: icon), for: .normal)
        } catch {
            print("[QRCodeReaderViewController] Torch error: \(error)")
        }
    }

    @objc @IBAction public func cancelAction(_ sender: Any) {
        dismiss(animated: true) { [weak self] in
            self?.completionBlock?(nil)
        }
    }

    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let first = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let val = first.stringValue else {
            return
        }
        stopScanning()
        dismiss(animated: true) { [weak self] in
            self?.completionBlock?(val)
        }
    }
}
