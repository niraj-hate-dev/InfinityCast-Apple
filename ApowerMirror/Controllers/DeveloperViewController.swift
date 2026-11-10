//
//  DeveloperViewController.swift
//  ApowerMirror / Controllers
//
//  Developer screen matching Android's fragment_developer.xml & DeveloperFragment.kt:
//  - Back header + centered 100pt circular InfinityLogo
//  - "Developer" subtitle + "Niraj Hate" bold title
//

import UIKit

public final class DeveloperViewController: UIViewController {

    private let headerView = InfinityNavHeaderView(title: "Developer")
    private let logoView = InfinityBrandLogoView()
    private let roleLabel = UILabel()
    private let nameLabel = UILabel()

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupUI()
    }

    private func setupUI() {
        let bg = InfinityGradientBackgroundView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        view.addSubview(headerView)

        logoView.translatesAutoresizingMaskIntoConstraints = false

        roleLabel.text = "Developer"
        roleLabel.font = .systemFont(ofSize: 18, weight: .regular)
        roleLabel.textColor = InfinityTheme.textSecondary
        roleLabel.textAlignment = .center

        nameLabel.text = "Niraj Hate"
        nameLabel.font = .systemFont(ofSize: 32, weight: .bold)
        nameLabel.textColor = InfinityTheme.textPrimary
        nameLabel.textAlignment = .center

        let centerStack = UIStackView(arrangedSubviews: [logoView, roleLabel, nameLabel])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 8
        centerStack.setCustomSpacing(24, after: logoView)
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(centerStack)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),

            logoView.widthAnchor.constraint(equalToConstant: 100),
            logoView.heightAnchor.constraint(equalToConstant: 100),

            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 12),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }
}
