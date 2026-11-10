//
//  AboutViewController.swift
//  ApowerMirror / Controllers
//
//  About screen matching Android's fragment_about.xml:
//  - Back header + centered 120pt circular InfinityLogo
//  - "Infinity Cast" title + "Version 1.0.0"
//

import UIKit

public final class AboutViewController: UIViewController {

    private let headerView = InfinityNavHeaderView(title: "About")
    private let logoView = InfinityBrandLogoView()
    private let appNameLabel = UILabel()
    private let versionLabel = UILabel()

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

        appNameLabel.text = "Infinity Cast"
        appNameLabel.font = .systemFont(ofSize: 28, weight: .bold)
        appNameLabel.textColor = InfinityTheme.textPrimary
        appNameLabel.textAlignment = .center

        versionLabel.text = "Version 1.0.0"
        versionLabel.font = .systemFont(ofSize: 16, weight: .regular)
        versionLabel.textColor = InfinityTheme.textSecondary
        versionLabel.textAlignment = .center

        let centerStack = UIStackView(arrangedSubviews: [
            logoView,
            appNameLabel,
            versionLabel
        ])
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

            logoView.widthAnchor.constraint(equalToConstant: 120),
            logoView.heightAnchor.constraint(equalToConstant: 120),

            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 16),
            centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }
}
