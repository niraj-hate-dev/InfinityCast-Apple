//
//  InfinityRootTabController.swift
//  ApowerMirror / Controllers
//
//  Root container matching Android's MainActivity: hosts the Cast and Me
//  navigation stacks above a floating translucent bottom pill navigation bar.
//

import UIKit

public final class InfinityRootTabController: UIViewController, UINavigationControllerDelegate {

    // MARK: - Child Stacks

    private let homeVC = WXHomeViewController()
    private lazy var castNav = UINavigationController(rootViewController: homeVC)
    private lazy var meNav = UINavigationController(rootViewController: MeViewController())

    private var activeNav: UINavigationController?
    private var selectedIndex: Int = 0

    // MARK: - Floating Bottom Nav UI

    private let contentContainer = UIView()
    private let bottomBarContainer = UIView()
    private let bottomBarSurface = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let bottomBarTintOverlay = UIView()
    private let castTabButton = FloatingTabButton(title: "Cast", systemImageName: "airplayvideo")
    private let meTabButton = FloatingTabButton(title: "Me", systemImageName: "person.fill")

    private var bottomBarHidden = false
    private var splashVC: InfinitySplashViewController?

    public override var childForStatusBarStyle: UIViewController? {
        return splashVC ?? activeNav
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupContainer()
        setupFloatingBottomBar()
        setupChildNavControllers()
        selectTab(index: 0, animated: false)
        showLaunchSplash()
    }

    private func showLaunchSplash() {
        let splash = InfinitySplashViewController()
        addChild(splash)
        splash.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splash.view)
        NSLayoutConstraint.activate([
            splash.view.topAnchor.constraint(equalTo: view.topAnchor),
            splash.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splash.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splash.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        splash.didMove(toParent: self)
        self.splashVC = splash
        setNeedsStatusBarAppearanceUpdate()

        splash.onFinished = { [weak self, weak splash] in
            guard let self = self, let splash = splash else { return }
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut], animations: {
                splash.view.alpha = 0.0
            }, completion: { _ in
                splash.willMove(toParent: nil)
                splash.view.removeFromSuperview()
                splash.removeFromParent()
                if self.splashVC === splash {
                    self.splashVC = nil
                    self.setNeedsStatusBarAppearanceUpdate()
                }
            })
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            bottomBarContainer.layer.borderColor = InfinityTheme.bottomNavStroke.resolvedColor(with: traitCollection).cgColor
        }
    }

    // MARK: - Setup

    private func setupContainer() {
        let bg = InfinityGradientBackgroundView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.backgroundColor = .clear
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupFloatingBottomBar() {
        bottomBarContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomBarContainer.layer.cornerRadius = 24
        bottomBarContainer.layer.borderWidth = 1.0
        bottomBarContainer.layer.borderColor = InfinityTheme.bottomNavStroke.resolvedColor(with: traitCollection).cgColor
        bottomBarContainer.layer.shadowColor = UIColor.black.cgColor
        bottomBarContainer.layer.shadowOpacity = 0.18
        bottomBarContainer.layer.shadowOffset = CGSize(width: 0, height: 6)
        bottomBarContainer.layer.shadowRadius = 12
        view.addSubview(bottomBarContainer)

        bottomBarSurface.translatesAutoresizingMaskIntoConstraints = false
        bottomBarSurface.layer.cornerRadius = 24
        bottomBarSurface.clipsToBounds = true
        bottomBarContainer.addSubview(bottomBarSurface)

        bottomBarTintOverlay.translatesAutoresizingMaskIntoConstraints = false
        bottomBarTintOverlay.backgroundColor = InfinityTheme.bottomNavBg
        bottomBarTintOverlay.isUserInteractionEnabled = false
        bottomBarSurface.contentView.addSubview(bottomBarTintOverlay)

        let stack = UIStackView(arrangedSubviews: [castTabButton, meTabButton])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        bottomBarSurface.contentView.addSubview(stack)

        castTabButton.addTarget(self, action: #selector(castTabTapped), for: .touchUpInside)
        meTabButton.addTarget(self, action: #selector(meTabTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            bottomBarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bottomBarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomBarContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            bottomBarContainer.heightAnchor.constraint(equalToConstant: 64),

            bottomBarSurface.topAnchor.constraint(equalTo: bottomBarContainer.topAnchor),
            bottomBarSurface.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor),
            bottomBarSurface.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor),
            bottomBarSurface.bottomAnchor.constraint(equalTo: bottomBarContainer.bottomAnchor),

            bottomBarTintOverlay.topAnchor.constraint(equalTo: bottomBarSurface.contentView.topAnchor),
            bottomBarTintOverlay.leadingAnchor.constraint(equalTo: bottomBarSurface.contentView.leadingAnchor),
            bottomBarTintOverlay.trailingAnchor.constraint(equalTo: bottomBarSurface.contentView.trailingAnchor),
            bottomBarTintOverlay.bottomAnchor.constraint(equalTo: bottomBarSurface.contentView.bottomAnchor),

            stack.topAnchor.constraint(equalTo: bottomBarSurface.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: bottomBarSurface.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bottomBarSurface.contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomBarSurface.contentView.bottomAnchor)
        ])
    }

    private func setupChildNavControllers() {
        for nav in [castNav, meNav] {
            nav.isNavigationBarHidden = true
            nav.delegate = self
            nav.interactivePopGestureRecognizer?.delegate = nil
            // Keep root controllers comfortably clear of floating bottom pill
            nav.viewControllers.first?.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 82, right: 0)
        }
    }

    // MARK: - Actions

    @objc private func castTabTapped() {
        selectTab(index: 0, animated: true)
    }

    @objc private func meTabTapped() {
        selectTab(index: 1, animated: true)
    }

    public func switchToCastTab() {
        meNav.popToRootViewController(animated: false)
        selectTab(index: 0, animated: true)
    }

    public func selectTab(index: Int, animated: Bool) {
        let targetNav = (index == 0) ? castNav : meNav

        if activeNav === targetNav {
            targetNav.popToRootViewController(animated: animated)
            updateTabAppearance(selectedIndex: index)
            return
        }

        selectedIndex = index
        let previousNav = activeNav

        addChild(targetNav)
        targetNav.view.frame = contentContainer.bounds
        targetNav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentContainer.addSubview(targetNav.view)
        targetNav.didMove(toParent: self)

        if let prev = previousNav {
            prev.willMove(toParent: nil)
            prev.view.removeFromSuperview()
            prev.removeFromParent()
        }

        activeNav = targetNav
        updateTabAppearance(selectedIndex: index)
        setFloatingBarHidden(targetNav.viewControllers.count > 1, animated: animated)
    }

    private func updateTabAppearance(selectedIndex: Int) {
        castTabButton.setActive(selectedIndex == 0)
        meTabButton.setActive(selectedIndex == 1)
    }

    // MARK: - UINavigationControllerDelegate

    public func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        let shouldHideBar = navigationController.viewControllers.count > 1
        setFloatingBarHidden(shouldHideBar, animated: animated)
    }

    private func setFloatingBarHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != bottomBarHidden else { return }
        bottomBarHidden = hidden

        let applyState = {
            self.bottomBarContainer.alpha = hidden ? 0.0 : 1.0
            self.bottomBarContainer.transform = hidden ? CGAffineTransform(translationX: 0, y: 24) : .identity
            self.bottomBarContainer.isUserInteractionEnabled = !hidden
        }

        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseInOut], animations: applyState)
        } else {
            applyState()
        }
    }
}

// MARK: - Floating Tab Button Item

private final class FloatingTabButton: UIControl {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    init(title: String, systemImageName: String) {
        super.init(frame: .zero)

        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        iconView.image = UIImage(systemName: systemImageName, withConfiguration: config)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            iconView.widthAnchor.constraint(equalToConstant: 26)
        ])

        setActive(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setActive(_ active: Bool) {
        let color = active ? InfinityTheme.navItemActive : InfinityTheme.navItemInactive
        iconView.tintColor = color
        titleLabel.textColor = color
        titleLabel.font = .systemFont(ofSize: 11, weight: active ? .bold : .medium)
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.6 : 1.0
        }
    }
}
