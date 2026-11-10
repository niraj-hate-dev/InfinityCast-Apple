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
