//
//  WXUSBMirrorView.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  USB Mirroring guide view displaying cable connection steps and status.
//

import UIKit

@objc(WXUSBMirrorView)
open class WXUSBMirrorView: UIView {

    @IBOutlet public var titleLbl: UILabel!
    
    private let iconImageView = UIImageView()
    private let step1Label = UILabel()
    private let step2Label = UILabel()
    private let step3Label = UILabel()
    private let usbCard = UIView()

    public convenience init() {
        self.init(frame: .zero)
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    @objc public func setupUI() {
        backgroundColor = .clear

        usbCard.translatesAutoresizingMaskIntoConstraints = false
        usbCard.backgroundColor = .white
        usbCard.layer.cornerRadius = 16
        usbCard.layer.shadowColor = UIColor.black.cgColor
        usbCard.layer.shadowOffset = CGSize(width: 0, height: 4)
        usbCard.layer.shadowOpacity = 0.06
        usbCard.layer.shadowRadius = 12
        addSubview(usbCard)

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.image = UIImage(systemName: "cable.connector") ?? UIImage(systemName: "link")
        iconImageView.tintColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        iconImageView.contentMode = .scaleAspectFit
        usbCard.addSubview(iconImageView)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "USB Lightning / Type-C Mirroring"
        title.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        title.textColor = UIColor(white: 0.15, alpha: 1.0)
        title.textAlignment = .center
        usbCard.addSubview(title)
        self.titleLbl = title

        let stepsStack = UIStackView()
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        stepsStack.axis = .vertical
        stepsStack.spacing = 14
        stepsStack.distribution = .fill
        usbCard.addSubview(stepsStack)

        stepsStack.addArrangedSubview(createStep(number: "1", text: "Connect iPhone to PC using a certified USB cable."))
        stepsStack.addArrangedSubview(createStep(number: "2", text: "When prompted on iPhone, tap 'Trust This Computer'."))
        stepsStack.addArrangedSubview(createStep(number: "3", text: "ApowerMirror PC will auto-recognize your device and mirror."))

        NSLayoutConstraint.activate([
            usbCard.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            usbCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            usbCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            usbCard.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),

            iconImageView.topAnchor.constraint(equalTo: usbCard.topAnchor, constant: 28),
            iconImageView.centerXAnchor.constraint(equalTo: usbCard.centerXAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 54),
            iconImageView.heightAnchor.constraint(equalToConstant: 54),

            title.topAnchor.constraint(equalTo: iconImageView.bottomAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: usbCard.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: usbCard.trailingAnchor, constant: -16),

            stepsStack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),
            stepsStack.leadingAnchor.constraint(equalTo: usbCard.leadingAnchor, constant: 24),
            stepsStack.trailingAnchor.constraint(equalTo: usbCard.trailingAnchor, constant: -24),
            stepsStack.bottomAnchor.constraint(equalTo: usbCard.bottomAnchor, constant: -28)
        ])
    }

    private func createStep(number: String, text: String) -> UIView {
        let row = UIView()
        let badge = UILabel()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.text = number
        badge.textColor = .white
        badge.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        badge.textAlignment = .center
        badge.backgroundColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
        badge.layer.cornerRadius = 12
        badge.layer.masksToBounds = true
        row.addSubview(badge)

        let desc = UILabel()
        desc.translatesAutoresizingMaskIntoConstraints = false
        desc.text = text
        desc.textColor = UIColor(white: 0.35, alpha: 1.0)
        desc.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        desc.numberOfLines = 0
        row.addSubview(desc)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            badge.topAnchor.constraint(equalTo: row.topAnchor),
            badge.widthAnchor.constraint(equalToConstant: 24),
            badge.heightAnchor.constraint(equalToConstant: 24),

            desc.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            desc.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            desc.topAnchor.constraint(equalTo: row.topAnchor),
            desc.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }
}
