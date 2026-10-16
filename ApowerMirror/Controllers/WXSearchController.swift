//
//  WXSearchController.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Local network WiFi receiver search controller discovering desktop receivers.
//

import UIKit
import Network

@objc(WXSearchController)
open class WXSearchController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    @IBOutlet public weak var backView: UIView!
    @IBOutlet public weak var tableView: UITableView!
    @IBOutlet public weak var wifiLbl: UILabel!
    @IBOutlet public weak var tryCodeBtn: UIButton!

    @objc public var unsearchedCount: Int = 0
    @objc public var tryCodeClosure: (() -> Void)?
    @objc public var helpDocClosure: (() -> Void)?

    public struct DiscoveredPC {
        public let name: String
        public let host: String
        public let port: Int
    }

    public var discoveredDevices: [DiscoveredPC] = []
    private var browser: NWBrowser?
    private var refreshControl = UIRefreshControl()

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startSearch()
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateWifiLabel()
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        browser?.cancel()
    }

    private func setupUI() {
        view.backgroundColor = UIColor(white: 0.96, alpha: 1.0)
        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard tableView == nil else { return }

        let bView = UIView()
        bView.translatesAutoresizingMaskIntoConstraints = false
        bView.backgroundColor = .clear
        view.addSubview(bView)
        self.backView = bView

        let wifiLabel = UILabel()
        wifiLabel.translatesAutoresizingMaskIntoConstraints = false
        wifiLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        wifiLabel.textColor = UIColor(white: 0.5, alpha: 1.0)
        wifiLabel.text = "WiFi : Detecting network..."
        bView.addSubview(wifiLabel)
        self.wifiLbl = wifiLabel

        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.backgroundColor = .clear
        tv.separatorStyle = .none
        tv.dataSource = self
        tv.delegate = self
        tv.register(WXSearchDeviceTableViewCell.self, forCellReuseIdentifier: WXSearchDeviceTableViewCell.reuseIdentifier)
        bView.addSubview(tv)
        self.tableView = tv

        refreshControl.addTarget(self, action: #selector(startSearch), for: .valueChanged)
        tv.addSubview(refreshControl)

        let codeBtn = UIButton(type: .system)
        codeBtn.translatesAutoresizingMaskIntoConstraints = false
        codeBtn.setTitle("Cannot find your PC? Connect via PIN Code", for: .normal)
        codeBtn.setTitleColor(UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0), for: .normal)
        codeBtn.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        codeBtn.addTarget(self, action: #selector(tryCodeBtnAction), for: .touchUpInside)
        bView.addSubview(codeBtn)
        self.tryCodeBtn = codeBtn

        NSLayoutConstraint.activate([
            bView.topAnchor.constraint(equalTo: view.topAnchor),
            bView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            wifiLabel.topAnchor.constraint(equalTo: bView.topAnchor, constant: 14),
            wifiLabel.leadingAnchor.constraint(equalTo: bView.leadingAnchor, constant: 20),
            wifiLabel.trailingAnchor.constraint(equalTo: bView.trailingAnchor, constant: -20),

            tv.topAnchor.constraint(equalTo: wifiLabel.bottomAnchor, constant: 10),
            tv.leadingAnchor.constraint(equalTo: bView.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: bView.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: codeBtn.topAnchor, constant: -10),

            codeBtn.leadingAnchor.constraint(equalTo: bView.leadingAnchor, constant: 20),
            codeBtn.trailingAnchor.constraint(equalTo: bView.trailingAnchor, constant: -20),
            codeBtn.bottomAnchor.constraint(equalTo: bView.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            codeBtn.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func updateWifiLabel() {
        wifiLbl?.text = "WiFi: \(NetworkDetector.currentSSID() ?? "Connected")"
    }

    @objc public func startSearch() {
        discoveredDevices.removeAll()
        // Provide immediate default candidate for fast connection
        discoveredDevices.append(DiscoveredPC(name: "Apowersoft [PC-Local]", host: "127.0.0.1", port: 25333))
        
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_apowermirror._tcp", domain: "local.")
        let params = NWParameters()
        let nwBrowser = NWBrowser(for: descriptor, using: params)
        
        nwBrowser.browseResultsChangedHandler = { [weak self] results, changes in
            DispatchQueue.main.async {
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        if !(self?.discoveredDevices.contains(where: { $0.name == name }) ?? false) {
                            self?.discoveredDevices.append(DiscoveredPC(name: "Apowersoft [\(name)]", host: "local", port: 25333))
                        }
                    }
                }
                self?.tableView?.reloadData()
                self?.refreshControl.endRefreshing()
            }
        }
        
        nwBrowser.start(queue: .main)
        self.browser = nwBrowser
        tableView?.reloadData()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshControl.endRefreshing()
        }
    }

    @objc public func showFail() {
        let alert = UIAlertController(title: "Search Failed", message: "Make sure PC and iPhone are connected to the exact same Wi-Fi router.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc public func tryCodeBtnAction() {
        tryCodeClosure?()
    }

    // MARK: - UITableViewDataSource & Delegate

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return discoveredDevices.count
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return 72
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: WXSearchDeviceTableViewCell.reuseIdentifier, for: indexPath) as? WXSearchDeviceTableViewCell else {
            return UITableViewCell()
        }
        let dev = discoveredDevices[indexPath.row]
        cell.configure(name: dev.name, ip: dev.host, port: dev.port)
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let dev = discoveredDevices[indexPath.row]
        
        let chooseVC = WXPCMirrorChooseVC()
        chooseVC.selectedPCName = dev.name
        chooseVC.selectedPCHost = dev.host
        chooseVC.selectedPCPort = dev.port
        chooseVC.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            if let sheet = chooseVC.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
        }
        present(chooseVC, animated: true)
    }
}
