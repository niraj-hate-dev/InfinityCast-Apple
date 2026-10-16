//
//  WXMirrorViewController.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Mirroring connection hub controller hosting the 3 connection sub-controllers:
//  - WXSearchController (WiFi Device Discovery)
//  - WXQRScanViewController (QR Code Camera Scanner)
//  - WXCodeLinkViewController (4-Digit PIN Code Link)
//  - WXUSBMirrorView (USB Lightning / Type-C Mirroring instructions)
//

import UIKit

@objc(WXMirrorViewController)
open class WXMirrorViewController: UIViewController {

    @IBOutlet public weak var topView: UIView!
    @IBOutlet public weak var topImgV: UIImageView!
    @IBOutlet public weak var mirrorSegmentImgV: UIImageView!
    @IBOutlet public weak var mirrorSegmentView: UIStackView!
    @IBOutlet public weak var searchLinkBtn: UIButton!
    @IBOutlet public weak var codeLinkBtn: UIButton!
    @IBOutlet public weak var scanLinkBtn: UIButton!

    @objc public var searchLinkVC: WXSearchController?
    @objc public var codeLinkVC: WXCodeLinkViewController?
    @objc public var scanLinkVC: WXQRScanViewController?
    @objc public var usbMirrorView: WXUSBMirrorView?

    @objc public var linkType: Int = 0 // 0: Search, 1: QR Scan, 2: PIN Code, 3: USB
    @objc public var modalJump: Bool = false

    private let containerView = UIView()
    private var segmentIndicator = UIView()
    private var indicatorLeadingConstraint: NSLayoutConstraint?

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNavigation()
        setupNotification()
        actionForSearchLink(self)
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        updateWifi()
        startScan()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScan()
    }

    @objc public func setupNavigation() {
        title = "Connect & Mirror"
        
        let backItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(backAction)
        )
        backItem.tintColor = .white
        navigationItem.leftBarButtonItem = backItem

        let usbItem = UIBarButtonItem(
            image: UIImage(systemName: "cable.connector"),
            style: .plain,
            target: self,
            action: #selector(showUSBMirrorView)
        )
        usbItem.tintColor = .white
        navigationItem.rightBarButtonItem = usbItem

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 17, weight: .bold)]
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
    }

    @objc public func setupUI() {
        view.backgroundColor = UIColor(white: 0.96, alpha: 1.0)
        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard topView == nil else { return }

        // Top blue banner view
        let tView = UIView()
        tView.translatesAutoresizingMaskIntoConstraints = false
        tView.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        view.addSubview(tView)
        self.topView = tView

        // 3-Segment Selector Bar
        let segCard = UIView()
        segCard.translatesAutoresizingMaskIntoConstraints = false
        segCard.backgroundColor = .white
        segCard.layer.cornerRadius = 12
        segCard.layer.shadowColor = UIColor.black.cgColor
        segCard.layer.shadowOffset = CGSize(width: 0, height: 2)
        segCard.layer.shadowOpacity = 0.08
        segCard.layer.shadowRadius = 8
        view.addSubview(segCard)

        let segStack = UIStackView()
        segStack.translatesAutoresizingMaskIntoConstraints = false
        segStack.axis = .horizontal
        segStack.distribution = .fillEqually
        segStack.alignment = .fill
        segCard.addSubview(segStack)
        self.mirrorSegmentView = segStack

        // Search Button
        let sBtn = createSegmentButton(title: "WiFi Search", icon: "wifi", action: #selector(actionForSearchLink(_:)))
        self.searchLinkBtn = sBtn
        segStack.addArrangedSubview(sBtn)

        // QR Scan Button
        let qBtn = createSegmentButton(title: "QR Code", icon: "qrcode.viewfinder", action: #selector(actionForScanLink(_:)))
        self.scanLinkBtn = qBtn
        segStack.addArrangedSubview(qBtn)

        // PIN Code Button
        let cBtn = createSegmentButton(title: "PIN Code", icon: "number", action: #selector(actionForCodeLink(_:)))
        self.codeLinkBtn = cBtn
        segStack.addArrangedSubview(cBtn)

        // Sliding indicator line
        segmentIndicator.translatesAutoresizingMaskIntoConstraints = false
        segmentIndicator.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        segmentIndicator.layer.cornerRadius = 2
        segCard.addSubview(segmentIndicator)

        // Container View for embedded child view controllers
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.backgroundColor = .clear
        view.addSubview(containerView)

        let indicatorLeading = segmentIndicator.leadingAnchor.constraint(equalTo: segCard.leadingAnchor, constant: 10)
        indicatorLeading.isActive = true
        self.indicatorLeadingConstraint = indicatorLeading

        NSLayoutConstraint.activate([
            tView.topAnchor.constraint(equalTo: view.topAnchor),
            tView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tView.heightAnchor.constraint(equalToConstant: 120),

            segCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            segCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            segCard.heightAnchor.constraint(equalToConstant: 48),

            segStack.topAnchor.constraint(equalTo: segCard.topAnchor),
            segStack.leadingAnchor.constraint(equalTo: segCard.leadingAnchor),
            segStack.trailingAnchor.constraint(equalTo: segCard.trailingAnchor),
            segStack.bottomAnchor.constraint(equalTo: segCard.bottomAnchor, constant: -4),

            segmentIndicator.bottomAnchor.constraint(equalTo: segCard.bottomAnchor, constant: -2),
            segmentIndicator.widthAnchor.constraint(equalTo: segCard.widthAnchor, multiplier: 1.0 / 3.0, constant: -20),
            segmentIndicator.heightAnchor.constraint(equalToConstant: 3),

            containerView.topAnchor.constraint(equalTo: segCard.bottomAnchor, constant: 12),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func createSegmentButton(title: String, icon: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(" \(title)", for: .normal)
        btn.setImage(UIImage(systemName: icon), for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        btn.setTitleColor(UIColor(white: 0.4, alpha: 1.0), for: .normal)
        btn.tintColor = UIColor(white: 0.4, alpha: 1.0)
        btn.addTarget(self, action: action, for: .touchUpInside)
        return btn
    }

    @objc public func backAction() {
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc public func setupNotification() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnected),
            name: NSNotification.Name("kBroadCastConnectedNotification"),
            object: nil
        )
    }

    @objc private func handleConnected() {
        backAction()
    }

    @objc public func updateWifi() {
        searchLinkVC?.startSearch()
    }

    @objc public func startScan() {
        if linkType == 0 {
            searchLinkVC?.startSearch()
        } else if linkType == 1 {
            scanLinkVC?.startScan()
        }
    }

    @objc public func stopScan() {
        scanLinkVC?.stopScan()
    }

    // MARK: - Tab Switching Actions

    @objc @IBAction public func actionForSearchLink(_ sender: Any) {
        linkType = 0
        updateSegmentUI(activeIndex: 0)
        clearChildVCs()
        addSearchLinkVC()
    }

    @objc @IBAction public func actionForScanLink(_ sender: Any) {
        linkType = 1
        updateSegmentUI(activeIndex: 1)
        clearChildVCs()
        addScanLinkVC()
    }

    @objc @IBAction public func actionForCodeLink(_ sender: Any) {
        linkType = 2
        updateSegmentUI(activeIndex: 2)
        clearChildVCs()
        addCodeLinkVC()
    }

    private func updateSegmentUI(activeIndex: Int) {
        let buttons = [searchLinkBtn, scanLinkBtn, codeLinkBtn]
        let activeColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        let inactiveColor = UIColor(white: 0.45, alpha: 1.0)

        for (idx, btn) in buttons.enumerated() {
            let isActive = (idx == activeIndex)
            btn?.setTitleColor(isActive ? activeColor : inactiveColor, for: .normal)
            btn?.tintColor = isActive ? activeColor : inactiveColor
        }

        let segmentWidth = (view.bounds.width - 32) / 3.0
        let newX = CGFloat(activeIndex) * segmentWidth + 10

        UIView.animate(withDuration: 0.25) {
            self.indicatorLeadingConstraint?.constant = newX
            self.view.layoutIfNeeded()
        }
    }

    private func clearChildVCs() {
        usbMirrorView?.removeFromSuperview()
        usbMirrorView = nil
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }

    @objc public func addSearchLinkVC() {
        let vc = searchLinkVC ?? WXSearchController()
        vc.tryCodeClosure = { [weak self] in
            guard let self = self else { return }
            self.actionForCodeLink(self)
        }
        self.searchLinkVC = vc
        embedChild(vc)
    }

    @objc public func addScanLinkVC() {
        let vc = scanLinkVC ?? WXQRScanViewController()
        self.scanLinkVC = vc
        embedChild(vc)
    }

    @objc public func addCodeLinkVC() {
        let vc = codeLinkVC ?? WXCodeLinkViewController()
        self.codeLinkVC = vc
        embedChild(vc)
    }

    private func embedChild(_ vc: UIViewController) {
        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        vc.didMove(toParent: self)
    }

    @objc public func showUSBMirrorView() {
        clearChildVCs()
        let usb = WXUSBMirrorView(frame: containerView.bounds)
        usb.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(usb)
        NSLayoutConstraint.activate([
            usb.topAnchor.constraint(equalTo: containerView.topAnchor),
            usb.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            usb.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            usb.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        self.usbMirrorView = usb
    }
}
