//
//  WXPPTControlVC.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  PowerPoint Presentation Remote Control view controller with
//  slide up / down page turn actions and slide counter.
//

import UIKit

@objc(WXPPTControlVC)
open class WXPPTControlVC: UIViewController {

    @IBOutlet public weak var nextBtn: UIButton!
    @IBOutlet public weak var upBtn: UIButton!
    @IBOutlet public weak var pageLabel: UILabel!
    @IBOutlet public weak var tipsLabel: UILabel!

    private var currentPage: Int = 1
    private var totalPages: Int = 30

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = UIColor(white: 0.95, alpha: 1.0)
        title = "PPT Remote Control"

        let closeItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            style: .plain,
            target: self,
            action: #selector(handleClose)
        )
        navigationItem.leftBarButtonItem = closeItem

        buildProgrammaticUIIfNeeded()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard nextBtn == nil else { return }

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 20
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.08
        card.layer.shadowOffset = CGSize(width: 0, height: 6)
        card.layer.shadowRadius = 14
        view.addSubview(card)

        let pLbl = UILabel()
        pLbl.translatesAutoresizingMaskIntoConstraints = false
        pLbl.text = "\(currentPage)/\(totalPages)"
        pLbl.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        pLbl.textColor = UIColor(white: 0.15, alpha: 1.0)
        pLbl.textAlignment = .center
        card.addSubview(pLbl)
        self.pageLabel = pLbl

        let tLbl = UILabel()
        tLbl.translatesAutoresizingMaskIntoConstraints = false
        tLbl.text = "Click the button to turn the page up and down"
        tLbl.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        tLbl.textColor = UIColor(white: 0.5, alpha: 1.0)
        tLbl.textAlignment = .center
        card.addSubview(tLbl)
        self.tipsLabel = tLbl

        // Up / Prev Button
        let uBtn = UIButton(type: .system)
        uBtn.translatesAutoresizingMaskIntoConstraints = false
        uBtn.setTitle("  Previous Slide", for: .normal)
        uBtn.setImage(UIImage(systemName: "chevron.up.circle.fill"), for: .normal)
        uBtn.tintColor = .white
        uBtn.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        uBtn.layer.cornerRadius = 28
        uBtn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        uBtn.addTarget(self, action: #selector(onPrePage(_:)), for: .touchUpInside)
        card.addSubview(uBtn)
        self.upBtn = uBtn

        // Down / Next Button
        let nBtn = UIButton(type: .system)
        nBtn.translatesAutoresizingMaskIntoConstraints = false
        nBtn.setTitle("  Next Slide", for: .normal)
        nBtn.setImage(UIImage(systemName: "chevron.down.circle.fill"), for: .normal)
        nBtn.tintColor = .white
        nBtn.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        nBtn.layer.cornerRadius = 28
        nBtn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        nBtn.addTarget(self, action: #selector(onNextPage(_:)), for: .touchUpInside)
        card.addSubview(nBtn)
        self.nextBtn = nBtn

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),

            pLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
            pLbl.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            tLbl.topAnchor.constraint(equalTo: pLbl.bottomAnchor, constant: 8),
            tLbl.centerXAnchor.constraint(equalTo: card.centerXAnchor),

            uBtn.topAnchor.constraint(equalTo: tLbl.bottomAnchor, constant: 60),
            uBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 30),
            uBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -30),
            uBtn.heightAnchor.constraint(equalToConstant: 56),

            nBtn.topAnchor.constraint(equalTo: uBtn.bottomAnchor, constant: 24),
            nBtn.leadingAnchor.constraint(equalTo: uBtn.leadingAnchor),
            nBtn.trailingAnchor.constraint(equalTo: uBtn.trailingAnchor),
            nBtn.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    @objc public func handleClose() {
        dismiss(animated: true)
    }

    @objc @IBAction public func onPrePage(_ sender: Any) {
        if currentPage > 1 {
            currentPage -= 1
            pageLabel?.text = "\(currentPage)/\(totalPages)"
        }
        // Send command to PC server via WXCastSenderServer
        WXCastiOSSender.shared.sendCustomMsg(action: "ppt_pre_page")
    }

    @objc @IBAction public func onNextPage(_ sender: Any) {
        currentPage += 1
        pageLabel?.text = "\(currentPage)/\(totalPages)"
        // Send command to PC server via WXCastSenderServer
        WXCastiOSSender.shared.sendCustomMsg(action: "ppt_next_page")
    }
}
