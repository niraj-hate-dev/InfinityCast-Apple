//
//  StreamSettingsViewController.swift
//  ApowerMirror / Controllers
//
//  Settings screen matching Android's fragment_settings.xml structure:
//  - Contains ONLY iOS stream settings: Resolution and Bitrate
//  - Bottom #2F8FFF "Save & Apply" button persists settings, dispatches
//    Darwin presets to ReplayKit Extension, and switches back to the Cast tab.
//

import UIKit

public final class StreamSettingsViewController: UIViewController {

    private let headerView = InfinityNavHeaderView(title: "Settings")
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private let saveButton = UIButton(type: .system)

    private var selectedResolution: InfinityStreamSettings.ResolutionOption
    private var selectedBitrate: InfinityStreamSettings.BitrateOption

    private var resolutionButtons: [(InfinityStreamSettings.ResolutionOption, OptionChipButton)] = []
    private var bitrateButtons: [(InfinityStreamSettings.BitrateOption, OptionChipButton)] = []

    private let resolutionValueLabel = UILabel()
    private let bitrateValueLabel = UILabel()

    // MARK: - Init

    public init() {
        let current = InfinityStreamSettings.load()
        self.selectedResolution = current.resolution
        self.selectedBitrate = current.bitrate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        let current = InfinityStreamSettings.load()
        self.selectedResolution = current.resolution
        self.selectedBitrate = current.bitrate
        super.init(coder: coder)
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        setupUI()
        refreshSelectionStates()
    }

    // MARK: - UI Construction

    private func setupUI() {
        let bg = InfinityGradientBackgroundView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        view.addSubview(headerView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        // Category Header
        let categoryLabel = UILabel()
        categoryLabel.text = "DISPLAY & STREAM"
        categoryLabel.font = .systemFont(ofSize: 12, weight: .bold)
        categoryLabel.textColor = InfinityTheme.brandBlue
        contentStack.addArrangedSubview(categoryLabel)

        // 1. Resolution Card
        contentStack.addArrangedSubview(buildResolutionCard())

        // 2. Bitrate Card
        contentStack.addArrangedSubview(buildBitrateCard())

        // Bottom Save & Apply Button (matching Android fragment_settings.xml #2F8FFF)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setTitle("Save & Apply", for: .normal)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        saveButton.backgroundColor = InfinityTheme.saveButtonBlue
        saveButton.layer.cornerRadius = 12
        saveButton.layer.shadowColor = InfinityTheme.saveButtonBlue.cgColor
        saveButton.layer.shadowOpacity = 0.28
        saveButton.layer.shadowOffset = CGSize(width: 0, height: 6)
        saveButton.layer.shadowRadius = 12
        saveButton.addTarget(self, action: #selector(handleSaveAndApply), for: .touchUpInside)
        view.addSubview(saveButton)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),

            saveButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            saveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            saveButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            saveButton.heightAnchor.constraint(equalToConstant: 56),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    private func buildResolutionCard() -> UIView {
        let card = InfinityGlassCardView(cornerRadius: 12)

        let titleRow = makeCardHeader(
            iconName: "viewfinder",
            title: "Resolution",
            subtitle: "Output video clarity (60 FPS)",
            valueLabel: resolutionValueLabel
        )

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.spacing = 8
        topRow.distribution = .fillEqually

        let bottomRow = UIStackView()
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8
        bottomRow.distribution = .fillEqually

        for (index, option) in InfinityStreamSettings.resolutionOptions.enumerated() {
            let chip = OptionChipButton(title: option.key, subtitle: option.subtitle)
            chip.tag = index
            chip.addTarget(self, action: #selector(handleResolutionChipTapped(_:)), for: .touchUpInside)
            resolutionButtons.append((option, chip))
            if index < 3 {
                topRow.addArrangedSubview(chip)
            } else {
                bottomRow.addArrangedSubview(chip)
            }
        }

        let grid = UIStackView(arrangedSubviews: [topRow, bottomRow])
        grid.axis = .vertical
        grid.spacing = 8

        let stack = UIStackView(arrangedSubviews: [titleRow, grid])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])

        return card
    }

    private func buildBitrateCard() -> UIView {
        let card = InfinityGlassCardView(cornerRadius: 12)

        let titleRow = makeCardHeader(
            iconName: "speedometer",
            title: "Bitrate",
            subtitle: "Higher Mbps gives sharper motion clarity",
            valueLabel: bitrateValueLabel
        )

        let row1 = UIStackView()
        row1.axis = .horizontal
        row1.spacing = 8
        row1.distribution = .fillEqually

        let row2 = UIStackView()
        row2.axis = .horizontal
        row2.spacing = 8
        row2.distribution = .fillEqually

        for (index, option) in InfinityStreamSettings.bitrateOptions.enumerated() {
            let chip = OptionChipButton(title: option.label, subtitle: nil)
            chip.tag = index
            chip.addTarget(self, action: #selector(handleBitrateChipTapped(_:)), for: .touchUpInside)
            bitrateButtons.append((option, chip))
            if index < 4 {
                row1.addArrangedSubview(chip)
            } else {
                row2.addArrangedSubview(chip)
            }
        }

        let grid = UIStackView(arrangedSubviews: [row1, row2])
        grid.axis = .vertical
        grid.spacing = 8

        let stack = UIStackView(arrangedSubviews: [titleRow, grid])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])

        return card
    }

    private func makeCardHeader(
        iconName: String,
        title: String,
        subtitle: String,
        valueLabel: UILabel
    ) -> UIView {
        let iconView = UIImageView(image: UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)))
        iconView.tintColor = InfinityTheme.brandBlue
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = title
        titleLbl.font = .systemFont(ofSize: 17, weight: .bold)
        titleLbl.textColor = InfinityTheme.textPrimary

        let subLbl = UILabel()
        subLbl.text = subtitle
        subLbl.font = .systemFont(ofSize: 13, weight: .regular)
        subLbl.textColor = InfinityTheme.textSecondary

        let textStack = UIStackView(arrangedSubviews: [titleLbl, subLbl])
        textStack.axis = .vertical
        textStack.spacing = 2

        valueLabel.font = .systemFont(ofSize: 14, weight: .bold)
        valueLabel.textColor = InfinityTheme.brandBlue
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconView, textStack, valueLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])

        return row
    }

    // MARK: - Selection & Actions

    private func refreshSelectionStates() {
        resolutionValueLabel.text = selectedResolution.key
        bitrateValueLabel.text = selectedBitrate.label

        for (opt, chip) in resolutionButtons {
            chip.isSelectedOption = (opt == selectedResolution)
        }
        for (opt, chip) in bitrateButtons {
            chip.isSelectedOption = (opt == selectedBitrate)
        }
    }

    @objc private func handleResolutionChipTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < InfinityStreamSettings.resolutionOptions.count else { return }
        selectedResolution = InfinityStreamSettings.resolutionOptions[idx]
        refreshSelectionStates()
    }

    @objc private func handleBitrateChipTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < InfinityStreamSettings.bitrateOptions.count else { return }
        selectedBitrate = InfinityStreamSettings.bitrateOptions[idx]
        refreshSelectionStates()
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func handleSaveAndApply() {
        InfinityStreamSettings.saveAndApply(resolution: selectedResolution, bitrate: selectedBitrate)

        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)

        // Match Android MainSettingsFragment: save & redirect to Cast tab
        if let rootTab = findRootTabController() {
            rootTab.switchToCastTab()
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    private func findRootTabController() -> InfinityRootTabController? {
        var current: UIViewController? = self
        while let parent = current?.parent {
            if let root = parent as? InfinityRootTabController {
                return root
            }
            current = parent
        }
        return view.window?.rootViewController as? InfinityRootTabController
    }
}

// MARK: - Selectable Preset Chip Button

private final class OptionChipButton: UIButton {

    private let primaryLabel = UILabel()
    private let secondaryLabel = UILabel()

    var isSelectedOption: Bool = false {
        didSet { updateAppearance() }
    }

    init(title: String, subtitle: String?) {
        super.init(frame: .zero)

        layer.cornerRadius = 10
        layer.borderWidth = 1.0

        primaryLabel.text = title
        primaryLabel.font = .systemFont(ofSize: 14, weight: .bold)
        primaryLabel.textAlignment = .center
        primaryLabel.adjustsFontSizeToFitWidth = true
        primaryLabel.minimumScaleFactor = 0.75

        let stack = UIStackView(arrangedSubviews: [primaryLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let sub = subtitle, !sub.isEmpty {
            secondaryLabel.text = sub
            secondaryLabel.font = .systemFont(ofSize: 11, weight: .medium)
            secondaryLabel.textAlignment = .center
            stack.addArrangedSubview(secondaryLabel)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 44 : 52),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateAppearance() {
        if isSelectedOption {
            backgroundColor = InfinityTheme.brandBlue
            layer.borderColor = InfinityTheme.brandBlueLight.resolvedColor(with: traitCollection).cgColor
            primaryLabel.textColor = .white
            secondaryLabel.textColor = UIColor(white: 1.0, alpha: 0.85)
        } else {
            backgroundColor = InfinityTheme.chipInactiveBg
            layer.borderColor = InfinityTheme.statusCardStroke.resolvedColor(with: traitCollection).cgColor
            primaryLabel.textColor = InfinityTheme.textPrimary
            secondaryLabel.textColor = InfinityTheme.textSecondary
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateAppearance()
        }
    }
}
