//
//  AboutViewController.swift
//  ApowerMirror / Controllers
//
//  About screen matching Android's fragment_about.xml & AboutFragment.kt:
//  - Back header + centered 120pt circular InfinityLogo
//  - "Infinity Cast" title + dynamic app version
//  - Full-width #3B82F6 "Check Software Update" button linking to GitHub releases
//

import UIKit

public final class AboutViewController: UIViewController {

    private let headerView = InfinityNavHeaderView(title: "About")
    private let logoView = InfinityBrandLogoView()
    private let appNameLabel = UILabel()
    private let versionLabel = UILabel()
    private let checkUpdateButton = UIButton(type: .system)

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

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        versionLabel.text = "Version \(version)"
        versionLabel.font = .systemFont(ofSize: 16, weight: .regular)
        versionLabel.textColor = InfinityTheme.textSecondary
        versionLabel.textAlignment = .center

        checkUpdateButton.translatesAutoresizingMaskIntoConstraints = false
        checkUpdateButton.setTitle("Check Software Update", for: .normal)
        checkUpdateButton.setTitleColor(.white, for: .normal)
        checkUpdateButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        checkUpdateButton.backgroundColor = InfinityTheme.brandBlue
        checkUpdateButton.layer.cornerRadius = 12
        checkUpdateButton.layer.shadowColor = InfinityTheme.brandBlue.cgColor
        checkUpdateButton.layer.shadowOpacity = 0.25
        checkUpdateButton.layer.shadowOffset = CGSize(width: 0, height: 6)
        checkUpdateButton.layer.shadowRadius = 12
        checkUpdateButton.addTarget(self, action: #selector(handleCheckUpdate), for: .touchUpInside)

        let centerStack = UIStackView(arrangedSubviews: [
            logoView,
            appNameLabel,
            versionLabel,
            checkUpdateButton
        ])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 8
        centerStack.setCustomSpacing(24, after: logoView)
        centerStack.setCustomSpacing(40, after: versionLabel)
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

            checkUpdateButton.widthAnchor.constraint(equalTo: centerStack.widthAnchor),
            checkUpdateButton.heightAnchor.constraint(equalToConstant: 56),

            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 16),
            centerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            centerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func handleCheckUpdate() {
        guard let url = URL(string: "https://github.com/niraj-hate-dev/InfinityCast/tags") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
