//
//  WXPCMirrorChooseVC.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Modal bottom-sheet presenting the 3 mirroring modes:
//  1) Phone Screen mirror (iOS -> PC via ReplayKit)
//  2) Computer screen mirror (PC -> iOS reverse display)
//  3) PPT Remote Control (Slide deck controller)
//

import UIKit
import ReplayKit

@objc(WXPCMirrorChooseVC)
open class WXPCMirrorChooseVC: UIViewController {

    @IBOutlet public weak var phoneView: WXHilightView!
    @IBOutlet public weak var phoneLbl: UILabel!
    @IBOutlet public weak var pcView: WXHilightView!
    @IBOutlet public weak var pcLbl: UILabel!
    @IBOutlet public weak var pptView: WXHilightView!
    @IBOutlet public weak var pptLbl: UILabel!

    public var selectedPCName: String = "Apowersoft PC"
    public var selectedPCHost: String = "127.0.0.1"
    public var selectedPCPort: Int = 25333

    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let cardsStackView = UIStackView()

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        view.backgroundColor = UIColor(white: 0.98, alpha: 1.0)
        buildProgrammaticUIIfNeeded()
        setupCardActions()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard phoneView == nil else { return }

        // Header Title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = selectedPCName
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = UIColor(white: 0.15, alpha: 1.0)
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        // Close Button
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = UIColor(white: 0.7, alpha: 1.0)
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        view.addSubview(closeButton)

        // Subtitle
        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.text = "Select a mirroring mode to start"
        subtitle.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = UIColor(white: 0.5, alpha: 1.0)
        subtitle.textAlignment = .center
        view.addSubview(subtitle)

        // Stack View for 3 Option Cards
        cardsStackView.translatesAutoresizingMaskIntoConstraints = false
        cardsStackView.axis = .vertical
        cardsStackView.spacing = 16
        cardsStackView.distribution = .fillEqually
        view.addSubview(cardsStackView)

        // Card 1: Phone Screen Mirror
        let (card1, lbl1) = buildOptionCard(
            title: "Phone Screen mirror",
            subtitle: "Cast iOS screen to PC with sound & 60 FPS",
            icon: "iphone.radiowaves.left.and.right",
            accentColor: UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        )
        self.phoneView = card1
        self.phoneLbl = lbl1
        cardsStackView.addArrangedSubview(card1)

        // Card 2: Computer Screen Mirror
        let (card2, lbl2) = buildOptionCard(
            title: "Computer screen mirror",
            subtitle: "Control and view computer screen on iPhone",
            icon: "display",
            accentColor: UIColor(red: 0.35, green: 0.78, blue: 0.40, alpha: 1.0)
        )
        self.pcView = card2
        self.pcLbl = lbl2
        cardsStackView.addArrangedSubview(card2)

        // Card 3: PPT Remote Control
        let (card3, lbl3) = buildOptionCard(
            title: "PPT Remote Control",
            subtitle: "Turn iPhone into PowerPoint presentation remote",
            icon: "play.rectangle.fill",
            accentColor: UIColor(red: 0.98, green: 0.55, blue: 0.20, alpha: 1.0)
        )
        self.pptView = card3
        self.pptLbl = lbl3
        cardsStackView.addArrangedSubview(card3)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            subtitle.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitle.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cardsStackView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),
            cardsStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cardsStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            cardsStackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func buildOptionCard(title: String, subtitle: String, icon: String, accentColor: UIColor) -> (WXHilightView, UILabel) {
        let card = WXHilightView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.cornerRadius = 14
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.90, alpha: 1.0).cgColor
        card.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = accentColor.withAlphaComponent(0.12)
        iconContainer.layer.cornerRadius = 12
        card.addSubview(iconContainer)

        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: icon)
        iconView.tintColor = accentColor
        iconView.contentMode = .scaleAspectFit
        iconContainer.addSubview(iconView)

        let titleLbl = UILabel()
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        titleLbl.text = title
        titleLbl.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        titleLbl.textColor = UIColor(white: 0.15, alpha: 1.0)
        card.addSubview(titleLbl)

        let subLbl = UILabel()
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        subLbl.text = subtitle
        subLbl.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        subLbl.textColor = UIColor(white: 0.55, alpha: 1.0)
        card.addSubview(subLbl)

        let chevron = UIImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = UIImage(systemName: "chevron.right")
        chevron.tintColor = UIColor(white: 0.75, alpha: 1.0)
        card.addSubview(chevron)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            iconContainer.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 48),
            iconContainer.heightAnchor.constraint(equalToConstant: 48),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            chevron.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 16),

            titleLbl.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 14),
            titleLbl.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            titleLbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),

            subLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            subLbl.trailingAnchor.constraint(equalTo: titleLbl.trailingAnchor),
            subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 4)
        ])

        return (card, titleLbl)
    }

    private func setupCardActions() {
        phoneView?.tapAction = { [weak self] in
            self?.actionForPhone()
        }
        pcView?.tapAction = { [weak self] in
            self?.actionForPc()
        }
        pptView?.tapAction = { [weak self] in
            self?.actionForPpt()
        }
    }

    @objc public func handleClose() {
        dismiss(animated: true)
    }

    // MARK: - Actions matching ApowerMirror decompiled selectors

    @objc public func actionForPhone() {
        // Launch ReplayKit system broadcast picker
        BroadcastPickerManager.shared.presentBroadcastPicker()
        dismiss(animated: true) {
            NotificationCenter.default.post(name: NSNotification.Name("kBroadCastConnectedNotification"), object: nil)
        }
    }

    @objc public func actionForPc() {
        let alert = UIAlertController(
            title: "Computer Screen Mirror",
            message: "Reverse PC display projection requires desktop permission.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc public func actionForPpt() {
        let pptVC = WXPPTControlVC()
        let nav = UINavigationController(rootViewController: pptVC)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    @objc public func onJumpToolPage() {
        // Jump to advanced tools
    }

    @objc public func qmui_navigationBarBackgroundImage() -> UIImage? {
        return UIImage()
    }
}
