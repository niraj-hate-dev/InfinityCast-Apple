//
//  InfinityTheme.swift
//  ApowerMirror / Views
//
//  Shared Android-aligned visual theme, glassmorphism primitives,
//  and persisted iOS stream configuration helper.
//

import UIKit
import CoreFoundation

// MARK: - Color Palette & Typography

public enum InfinityTheme {

    private static func hex(_ rgb: UInt32, alpha: CGFloat = 1.0) -> UIColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
        return UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
    }

    // Brand Colors (from Android values/colors.xml)
    public static let brandBlue = hex(0x3B82F6)
    public static let brandBlueLight = hex(0x60A5FA)
    public static let brandBlueDark = hex(0x2563EB)
    public static let saveButtonBlue = hex(0x2F8FFF)

    // Backgrounds
    public static let bgMainStart = adaptive(
        light: hex(0xEBF2FA),
        dark: hex(0x101A34)
    )
    public static let bgMainEnd = adaptive(
        light: hex(0xDCE5F2),
        dark: hex(0x0A1023)
    )

    // Glass Surfaces & Bars
    public static let topBarBg = adaptive(
        light: hex(0xFFFFFF, alpha: 0.60),
        dark: hex(0x070B1A, alpha: 0.50)
    )
    public static let statusCardBg = adaptive(
        light: hex(0xFFFFFF, alpha: 0.70),
        dark: hex(0xFFFFFF, alpha: 0.10)
    )
    public static let statusCardStroke = adaptive(
        light: hex(0x000000, alpha: 0.20),
        dark: hex(0xFFFFFF, alpha: 0.20)
    )
    public static let bottomNavBg = adaptive(
        light: hex(0xFFFFFF, alpha: 0.85),
        dark: hex(0x101A34, alpha: 0.60)
    )
    public static let bottomNavStroke = adaptive(
        light: hex(0x000000, alpha: 0.30),
        dark: hex(0xFFFFFF, alpha: 0.30)
    )

    // Navigation Item Tint
    public static let navItemActive = hex(0x3B82F6)
    public static let navItemInactive = hex(0x8DA0C3)

    // Text Colors
    public static let textPrimary = adaptive(
        light: hex(0x1F2937),
        dark: .white
    )
    public static let textSecondary = adaptive(
        light: hex(0x6B7280),
        dark: hex(0x9DB3D7)
    )

    // Hero Cast Button Ring Colors
    public static let circleGlow = hex(0x3B82F6, alpha: 0.20)
    public static let circleRing = hex(0x60A5FA, alpha: 0.30)
    public static let circleCore = adaptive(
        light: hex(0xFFFFFF, alpha: 0.80),
        dark: hex(0x16213E, alpha: 0.80)
    )

    // Accents
    public static let statusRed = hex(0xEF4444)
    public static let statusGreen = hex(0x10B981)
    public static let separator = adaptive(
        light: hex(0x000000, alpha: 0.10),
        dark: hex(0xFFFFFF, alpha: 0.14)
    )
    public static let chipInactiveBg = adaptive(
        light: hex(0x000000, alpha: 0.05),
        dark: hex(0xFFFFFF, alpha: 0.08)
    )
}

// MARK: - Gradient Background View (bg_main_gradient)

public final class InfinityGradientBackgroundView: UIView {

    public override class var layerClass: AnyClass {
        return CAGradientLayer.self
    }

    private var gradientLayer: CAGradientLayer {
        return layer as! CAGradientLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        updateColors()
    }

    private func updateColors() {
        gradientLayer.colors = [
            InfinityTheme.bgMainStart.resolvedColor(with: traitCollection).cgColor,
            InfinityTheme.bgMainEnd.resolvedColor(with: traitCollection).cgColor
        ]
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateColors()
        }
    }
}

// MARK: - Radial Ambient Glow View (bg_radial_glow)

public final class InfinityRadialGlowView: UIView {

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors: [CGColor] = [
            UIColor(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0, alpha: 0.14).cgColor,
            UIColor(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0, alpha: 0.05).cgColor,
            UIColor.clear.cgColor
        ]
        let locations: [CGFloat] = [0.0, 0.50, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.5
        ctx.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
    }
}

// MARK: - Glass Card View (bg_status_card)

public class InfinityGlassCardView: UIView {

    public init(cornerRadius: CGFloat = 10) {
        super.init(frame: .zero)
        configure(cornerRadius: cornerRadius)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure(cornerRadius: 10)
    }

    private func configure(cornerRadius: CGFloat) {
        backgroundColor = InfinityTheme.statusCardBg
        layer.cornerRadius = cornerRadius
        layer.borderWidth = 1.0
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer.borderColor = InfinityTheme.statusCardStroke.resolvedColor(with: traitCollection).cgColor
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateBorderColor()
        }
    }
}

// MARK: - Circular Brand Logo View

public final class InfinityBrandLogoView: UIImageView {

    public init() {
        super.init(frame: .zero)
        image = UIImage(named: "InfinityLogo")
        contentMode = .scaleAspectFill
        clipsToBounds = true
        backgroundColor = UIColor(white: 1.0, alpha: 0.06)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        image = UIImage(named: "InfinityLogo")
        contentMode = .scaleAspectFill
        clipsToBounds = true
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.width, bounds.height) * 0.5
    }
}

// MARK: - Subpage Top Navigation Header

public final class InfinityNavHeaderView: UIView {

    public let backButton = UIButton(type: .system)
    public let titleLabel = UILabel()
    private let hairline = UIView()

    public init(title: String) {
        super.init(frame: .zero)
        backgroundColor = InfinityTheme.topBarBg

        if let chevron = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)) {
            backButton.setImage(chevron, for: .normal)
        }
        backButton.setTitle(" Back", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        backButton.tintColor = InfinityTheme.brandBlue
        backButton.contentHorizontalAlignment = .leading
        backButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = InfinityTheme.textPrimary
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        hairline.backgroundColor = InfinityTheme.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        addSubview(backButton)
        addSubview(titleLabel)
        addSubview(hairline)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            backButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            backButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Persisted Stream Settings (Resolution & Bitrate)

public enum InfinityStreamSettings {

    public struct ResolutionOption: Equatable {
        public let key: String       // Stored key ("544p", "720p", "1080p", "2K", "4K")
        public let shortSide: Int    // Exact pixel short-side recognized by SampleHandler
        public let subtitle: String  // Short human label
    }

    public struct BitrateOption: Equatable {
        public let label: String     // Stored label ("1 Mbps" ... "20 Mbps")
        public let bps: Int          // Exact bitrate recognized by SampleHandler
    }

    public static let resolutionOptions: [ResolutionOption] = [
        ResolutionOption(key: "544p",  shortSide: 544,  subtitle: "SD"),
        ResolutionOption(key: "720p",  shortSide: 720,  subtitle: "HD"),
        ResolutionOption(key: "1080p", shortSide: 1080, subtitle: "Full HD"),
        ResolutionOption(key: "2K",    shortSide: 1440, subtitle: "QHD"),
        ResolutionOption(key: "4K",    shortSide: 2160, subtitle: "Ultra HD")
    ]

    public static let bitrateOptions: [BitrateOption] = [
        BitrateOption(label: "1 Mbps",  bps: 1_000_000),
        BitrateOption(label: "2 Mbps",  bps: 2_000_000),
        BitrateOption(label: "4 Mbps",  bps: 4_000_000),
        BitrateOption(label: "6 Mbps",  bps: 6_000_000),
        BitrateOption(label: "8 Mbps",  bps: 8_000_000),
        BitrateOption(label: "12 Mbps", bps: 12_000_000),
        BitrateOption(label: "16 Mbps", bps: 16_000_000),
        BitrateOption(label: "20 Mbps", bps: 20_000_000)
    ]

    public static let appGroupSuite = "group.apowersoft.mirror"
    public static let didChangeNotification = Notification.Name("InfinityStreamSettingsDidChange")

    private static var groupDefaults: UserDefaults? {
        return UserDefaults(suiteName: appGroupSuite)
    }

    public static func load() -> (resolution: ResolutionOption, bitrate: BitrateOption) {
        let group = groupDefaults
        let std = UserDefaults.standard

        let savedShortSide = (group?.integer(forKey: "kEncoderShortSide") ?? 0) > 0
            ? (group?.integer(forKey: "kEncoderShortSide") ?? 0)
            : std.integer(forKey: "kEncoderShortSide")

        let savedResString = group?.string(forKey: "kEncoderResolution")
            ?? std.string(forKey: "kEncoderResolution")

        let resolution: ResolutionOption
        if let matchByKey = resolutionOptions.first(where: { $0.key == savedResString }) {
            resolution = matchByKey
        } else if let matchBySide = resolutionOptions.first(where: { $0.shortSide == savedShortSide }) {
            resolution = matchBySide
        } else {
            // Default: 1080p
            resolution = resolutionOptions[2]
        }

        let savedBitrate = (group?.integer(forKey: "kEncoderBitrate") ?? 0) > 0
            ? (group?.integer(forKey: "kEncoderBitrate") ?? 0)
            : std.integer(forKey: "kEncoderBitrate")

        let savedBitrateString = group?.string(forKey: "kEncoderBitrateString")
            ?? std.string(forKey: "kEncoderBitrateString")

        let bitrate: BitrateOption
        if let matchByLabel = bitrateOptions.first(where: { $0.label == savedBitrateString }) {
            bitrate = matchByLabel
        } else if let matchByBps = bitrateOptions.first(where: { $0.bps == savedBitrate }) {
            bitrate = matchByBps
        } else {
            // Default: 4 Mbps
            bitrate = bitrateOptions[2]
        }

        return (resolution, bitrate)
    }

    public static func saveAndApply(resolution: ResolutionOption, bitrate: BitrateOption) {
        let targets: [UserDefaults] = [groupDefaults, UserDefaults.standard].compactMap { $0 }
        for defaults in targets {
            defaults.set(resolution.key, forKey: "kEncoderResolution")
            defaults.set(resolution.shortSide, forKey: "kEncoderShortSide")
            defaults.set(bitrate.label, forKey: "kEncoderBitrateString")
            defaults.set(bitrate.bps, forKey: "kEncoderBitrate")
            defaults.set(60, forKey: "kEncoderFps")

            // Keep WXMirrorCore / Legacy keys aligned
            defaults.set(resolution.shortSide, forKey: "kGroupResolution")
            defaults.set(bitrate.bps, forKey: "kGroupBitrate")
            defaults.set(60, forKey: "kGroupFps")
            defaults.synchronize()
        }

        // Update IPC wormhole for ReplayKit Broadcast Extension
        MMWormholeManager.shared.writeMessageObject([
            "resolution": resolution.key,
            "bitrateString": bitrate.label,
            "shortSide": resolution.shortSide,
            "bitrate": bitrate.bps,
            "fps": 60
        ], identifier: "encoderSettings")

        // Update active in-app recorder immediately if capturing
        ScreenRecorderManager.shared.updateConfiguration(
            bitrate: Int32(bitrate.bps),
            shortSide: Int32(resolution.shortSide),
            fps: 60
        )
        ScreenRecorderManager.shared.requestKeyframe()

        // Notify ReplayKit Extension via Darwin notifications for live hot-swap
        postDarwinNotification("com.apowermirror.setRes.\(resolution.shortSide)")
        postDarwinNotification("com.apowermirror.setBitrate.\(bitrate.bps)")
        postDarwinNotification("com.apowermirror.forceKeyframe")

        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func postDarwinNotification(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }
}

// MARK: - Theme Preference Manager (White / Light <-> Dark)

public final class InfinityThemeManager {

    public static let shared = InfinityThemeManager()
    public static let didChangeNotification = Notification.Name("InfinityThemeDidChange")

    private let defaultsKey = "kInfinityDarkThemeEnabled"

    public private(set) var isDark: Bool

    private init() {
        self.isDark = UserDefaults.standard.bool(forKey: defaultsKey)
    }

    public func toggle(in window: UIWindow?) {
        setDark(!isDark, in: window, animated: true)
    }

    public func setDark(_ dark: Bool, in window: UIWindow?, animated: Bool) {
        isDark = dark
        UserDefaults.standard.set(dark, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
        apply(to: window, animated: animated)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    public func apply(to window: UIWindow?, animated: Bool = false) {
        let targetStyle: UIUserInterfaceStyle = isDark ? .dark : .light
        guard let win = window else { return }

        let applyStyle = {
            win.overrideUserInterfaceStyle = targetStyle
            win.rootViewController?.setNeedsStatusBarAppearanceUpdate()
        }

        if animated {
            UIView.transition(
                with: win,
                duration: 0.36,
                options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: applyStyle,
                completion: nil
            )
        } else {
            applyStyle()
        }
    }
}

// MARK: - Animated Light / Dark Theme Toggle Pill (Cast Top Bar)

public final class InfinityThemeToggleButton: UIControl {

    private let trackView = UIView()
    private let sunTrackIcon = UIImageView()
    private let moonTrackIcon = UIImageView()
    private let thumbView = UIView()
    private let thumbIconView = UIImageView()

    private var thumbLeadingConstraint: NSLayoutConstraint!

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        updateState(animated: false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        updateState(animated: false)
    }

    private func setupUI() {
        accessibilityLabel = "Toggle Light or Dark Theme"

        trackView.translatesAutoresizingMaskIntoConstraints = false
        trackView.layer.cornerRadius = 17
        trackView.layer.borderWidth = 1.0
        trackView.isUserInteractionEnabled = false
        addSubview(trackView)

        let trackCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        sunTrackIcon.image = UIImage(systemName: "sun.max.fill", withConfiguration: trackCfg)
        sunTrackIcon.contentMode = .scaleAspectFit
        sunTrackIcon.translatesAutoresizingMaskIntoConstraints = false

        moonTrackIcon.image = UIImage(systemName: "moon.stars.fill", withConfiguration: trackCfg)
        moonTrackIcon.contentMode = .scaleAspectFit
        moonTrackIcon.translatesAutoresizingMaskIntoConstraints = false

        trackView.addSubview(sunTrackIcon)
        trackView.addSubview(moonTrackIcon)

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.layer.cornerRadius = 13
        thumbView.layer.shadowColor = UIColor.black.cgColor
        thumbView.layer.shadowOpacity = 0.20
        thumbView.layer.shadowOffset = CGSize(width: 0, height: 2)
        thumbView.layer.shadowRadius = 4
        thumbView.isUserInteractionEnabled = false
        trackView.addSubview(thumbView)

        thumbIconView.translatesAutoresizingMaskIntoConstraints = false
        thumbIconView.contentMode = .scaleAspectFit
        thumbView.addSubview(thumbIconView)

        thumbLeadingConstraint = thumbView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor, constant: 4)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 64),
            heightAnchor.constraint(equalToConstant: 34),

            trackView.topAnchor.constraint(equalTo: topAnchor),
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            sunTrackIcon.leadingAnchor.constraint(equalTo: trackView.leadingAnchor, constant: 9),
            sunTrackIcon.centerYAnchor.constraint(equalTo: trackView.centerYAnchor),
            sunTrackIcon.widthAnchor.constraint(equalToConstant: 15),
            sunTrackIcon.heightAnchor.constraint(equalToConstant: 15),

            moonTrackIcon.trailingAnchor.constraint(equalTo: trackView.trailingAnchor, constant: -9),
            moonTrackIcon.centerYAnchor.constraint(equalTo: trackView.centerYAnchor),
            moonTrackIcon.widthAnchor.constraint(equalToConstant: 15),
            moonTrackIcon.heightAnchor.constraint(equalToConstant: 15),

            thumbLeadingConstraint,
            thumbView.centerYAnchor.constraint(equalTo: trackView.centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 26),
            thumbView.heightAnchor.constraint(equalToConstant: 26),

            thumbIconView.centerXAnchor.constraint(equalTo: thumbView.centerXAnchor),
            thumbIconView.centerYAnchor.constraint(equalTo: thumbView.centerYAnchor),
            thumbIconView.widthAnchor.constraint(equalToConstant: 15),
            thumbIconView.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    public func updateState(animated: Bool) {
        let isDark = InfinityThemeManager.shared.isDark
        thumbLeadingConstraint.constant = isDark ? 34.0 : 4.0

        let thumbCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        let iconName = isDark ? "moon.stars.fill" : "sun.max.fill"
        thumbIconView.image = UIImage(systemName: iconName, withConfiguration: thumbCfg)

        let applyColors = {
            if isDark {
                self.trackView.backgroundColor = UIColor(red: 16.0 / 255.0, green: 28.0 / 255.0, blue: 58.0 / 255.0, alpha: 0.90)
                self.trackView.layer.borderColor = UIColor(white: 1.0, alpha: 0.24).cgColor
                self.thumbView.backgroundColor = InfinityTheme.brandBlue
                self.thumbIconView.tintColor = .white
                self.sunTrackIcon.tintColor = UIColor(white: 1.0, alpha: 0.45)
                self.moonTrackIcon.tintColor = .clear
            } else {
                self.trackView.backgroundColor = UIColor(red: 218.0 / 255.0, green: 230.0 / 255.0, blue: 248.0 / 255.0, alpha: 0.92)
                self.trackView.layer.borderColor = UIColor(white: 0.0, alpha: 0.14).cgColor
                self.thumbView.backgroundColor = .white
                self.thumbIconView.tintColor = UIColor(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
                self.sunTrackIcon.tintColor = .clear
                self.moonTrackIcon.tintColor = UIColor(red: 75.0 / 255.0, green: 95.0 / 255.0, blue: 130.0 / 255.0, alpha: 0.55)
            }
            self.layoutIfNeeded()
        }

        if animated {
            self.thumbIconView.transform = CGAffineTransform(rotationAngle: isDark ? -0.45 : 0.45).scaledBy(x: 0.75, y: 0.75)
            UIView.animate(
                withDuration: 0.36,
                delay: 0,
                usingSpringWithDamping: 0.72,
                initialSpringVelocity: 0.4,
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                self.thumbIconView.transform = .identity
                applyColors()
            }
        } else {
            self.thumbIconView.transform = .identity
            applyColors()
        }
    }

    public override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.93, y: 0.93) : .identity
            }
        }
    }
}
