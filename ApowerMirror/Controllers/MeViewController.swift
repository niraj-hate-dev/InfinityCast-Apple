//
//  MeViewController.swift
//  ApowerMirror / Controllers
//
//  Me tab matching Android's fragment_me.xml & MeFragment.kt:
//  - "Me" header title
//  - Glass menu cards for Settings, Developer, and About
//

import UIKit

public final class MeViewController: UIViewController {

    private let titleLabel = UILabel()
    private let cardsStack = UIStackView()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupUI()
    }

    private func setupUI() {
        titleLabel.text = "Me"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = InfinityTheme.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        cardsStack.axis = .vertical
        cardsStack.spacing = 16
        cardsStack.alignment = .fill
        cardsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardsStack)

        let settingsCard = MeMenuCard(title: "Settings", systemImageName: "gearshape.fill")
        settingsCard.addTarget(self, action: #selector(openSettings), for: .touchUpInside)

        let developerCard = MeMenuCard(title: "Developer", systemImageName: "chevron.left.forwardslash.chevron.right")
        developerCard.addTarget(self, action: #selector(openDeveloper), for: .touchUpInside)

        let aboutCard = MeMenuCard(title: "About", systemImageName: "info.circle.fill")
        aboutCard.addTarget(self, action: #selector(openAbout), for: .touchUpInside)

        cardsStack.addArrangedSubview(settingsCard)
        cardsStack.addArrangedSubview(developerCard)
        cardsStack.addArrangedSubview(aboutCard)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            cardsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            cardsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            cardsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(StreamSettingsViewController(), animated: true)
    }

    @objc private func openDeveloper() {
        navigationController?.pushViewController(DeveloperViewController(), animated: true)
    }

    @objc private func openAbout() {
        navigationController?.pushViewController(AboutViewController(), animated: true)
    }
}

// MARK: - Glass Menu Row Card (matches Android LinearLayout + bg_status_card)

private final class MeMenuCard: UIControl {

    private let cardView = InfinityGlassCardView(cornerRadius: 10)
    private let iconView = UIImageView()
    private let label = UILabel()
    private let chevronView = UIImageView()

    init(title: String, systemImageName: String) {
        super.init(frame: .zero)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.isUserInteractionEnabled = false
        addSubview(cardView)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        iconView.image = UIImage(systemName: systemImageName, withConfiguration: iconConfig)
        iconView.tintColor = InfinityTheme.brandBlue
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.text = title
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = InfinityTheme.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false

        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: chevronConfig)
        chevronView.tintColor = InfinityTheme.textSecondary
        chevronView.contentMode = .scaleAspectFit
        chevronView.translatesAutoresizingMaskIntoConstraints = false

        cardView.addSubview(iconView)
        cardView.addSubview(label)
        cardView.addSubview(chevronView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            chevronView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            chevronView.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            chevronView.widthAnchor.constraint(equalToConstant: 14),
            chevronView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.cardView.alpha = self.isHighlighted ? 0.65 : 1.0
                self.cardView.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
            }
        }
    }
}
