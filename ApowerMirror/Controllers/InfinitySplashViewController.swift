//
//  InfinitySplashViewController.swift
//  ApowerMirror / Controllers
//
//  Animated launch/loading screen matching Android's SplashActivity.kt & activity_splash.xml:
//  - Deep navy #0A0E1A background
//  - 200x200 rotating 3-arc comet ring in #2F8FFF
//  - 120x120 pulsing white vector Infinity logo
//  - Fade-in "InfinityCast" (#2F8FFF) + animated "Loading..." (#6680A0)
//  - Bottom version label (#3A4A60)
//  - Smooth fade transition after 2.5 seconds
//

import UIKit

public final class InfinitySplashViewController: UIViewController {

    public var onFinished: (() -> Void)?

    // MARK: - UI Elements

    private let ringContainer = UIView()
    private let ringView = SplashRingView()
    private let logoView = SplashInfinityLogoView()
    private let appNameLabel = UILabel()
    private let loadingLabel = UILabel()
    private let versionLabel = UILabel()

    // MARK: - Timers & State

    private var dotTimer: Timer?
    private var dotCount = 0
    private var hasScheduledDismiss = false

    public override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 10.0 / 255.0, green: 14.0 / 255.0, blue: 26.0 / 255.0, alpha: 1.0)
        setupUI()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startAnimations()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopTimersAndAnimations()
    }

    deinit {
        stopTimersAndAnimations()
    }

    // MARK: - UI Setup

    private func setupUI() {
        ringContainer.translatesAutoresizingMaskIntoConstraints = false
        ringContainer.backgroundColor = .clear

        ringView.translatesAutoresizingMaskIntoConstraints = false
        logoView.translatesAutoresizingMaskIntoConstraints = false
        ringContainer.addSubview(ringView)
        ringContainer.addSubview(logoView)

        appNameLabel.text = "InfinityCast"
        appNameLabel.textColor = UIColor(red: 47.0 / 255.0, green: 143.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
        appNameLabel.font = .systemFont(ofSize: 26, weight: .medium)
        appNameLabel.textAlignment = .center
        appNameLabel.alpha = 0

        loadingLabel.text = "Loading..."
        loadingLabel.textColor = UIColor(red: 102.0 / 255.0, green: 128.0 / 255.0, blue: 160.0 / 255.0, alpha: 1.0)
        loadingLabel.font = .systemFont(ofSize: 13, weight: .regular)
        loadingLabel.textAlignment = .center
        loadingLabel.alpha = 0

        let centerStack = UIStackView(arrangedSubviews: [ringContainer, appNameLabel, loadingLabel])
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 0
        centerStack.setCustomSpacing(24, after: ringContainer)
        centerStack.setCustomSpacing(12, after: appNameLabel)
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(centerStack)

        versionLabel.text = "v 1.0.0"
        versionLabel.textColor = UIColor(red: 58.0 / 255.0, green: 74.0 / 255.0, blue: 96.0 / 255.0, alpha: 1.0)
        versionLabel.font = .systemFont(ofSize: 12, weight: .regular)
        versionLabel.textAlignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            ringContainer.widthAnchor.constraint(equalToConstant: 200),
            ringContainer.heightAnchor.constraint(equalToConstant: 200),

            ringView.topAnchor.constraint(equalTo: ringContainer.topAnchor),
            ringView.leadingAnchor.constraint(equalTo: ringContainer.leadingAnchor),
            ringView.trailingAnchor.constraint(equalTo: ringContainer.trailingAnchor),
            ringView.bottomAnchor.constraint(equalTo: ringContainer.bottomAnchor),

            logoView.centerXAnchor.constraint(equalTo: ringContainer.centerXAnchor),
            logoView.centerYAnchor.constraint(equalTo: ringContainer.centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 120),
            logoView.heightAnchor.constraint(equalToConstant: 120),

            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            versionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            versionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])
    }

    // MARK: - Animations

    private func startAnimations() {
        ringView.startRotating()
        logoView.startPulse()

        UIView.animate(withDuration: 0.8, delay: 0.4, options: [.curveEaseOut]) {
            self.appNameLabel.alpha = 1.0
        }

        UIView.animate(withDuration: 0.6, delay: 0.7, options: [.curveEaseOut]) {
            self.loadingLabel.alpha = 1.0
        }

        guard !hasScheduledDismiss else { return }
        hasScheduledDismiss = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.startDotTimer()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.finishSplash()
        }
    }

    private func startDotTimer() {
        dotTimer?.invalidate()
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.dotCount = (self.dotCount + 1) % 4
            let dots = String(repeating: ".", count: self.dotCount)
            self.loadingLabel.text = "Loading\(dots)"
        }
    }

    private func finishSplash() {
        dotTimer?.invalidate()
        dotTimer = nil
        onFinished?()
    }

    private func stopTimersAndAnimations() {
        dotTimer?.invalidate()
        dotTimer = nil
        ringView.stopRotating()
        logoView.stopPulse()
    }
}

// MARK: - Rotating 3-Arc Comet Ring View

private final class SplashRingView: UIView {

    private let rotatingArcsLayer = SplashArcsLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.addSublayer(rotatingArcsLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rotatingArcsLayer.frame = bounds
        rotatingArcsLayer.contentsScale = UIScreen.main.scale
        rotatingArcsLayer.setNeedsDisplay()
    }

    func startRotating() {
        rotatingArcsLayer.removeAnimation(forKey: "splashRingRotation")
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0.0
        rotation.toValue = CGFloat.pi * 2.0
        rotation.duration = 2.0
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        rotation.isRemovedOnCompletion = false
        rotatingArcsLayer.add(rotation, forKey: "splashRingRotation")
    }

    func stopRotating() {
        rotatingArcsLayer.removeAnimation(forKey: "splashRingRotation")
    }
}

private final class SplashArcsLayer: CALayer {

    override func draw(in ctx: CGContext) {
        let size = min(bounds.width, bounds.height)
        guard size > 0 else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Matches Android 250 / 300 ratio -> 83.3% of half-box
        let radius = (size * 0.5) * (250.0 / 300.0)

        // Subtle full outline circle (Color.argb(30, 47, 143, 255))
        ctx.saveGState()
        ctx.setStrokeColor(UIColor(red: 47.0 / 255.0, green: 143.0 / 255.0, blue: 255.0 / 255.0, alpha: 30.0 / 255.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2.0, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()

        // Three 50-degree rotating comet arcs spaced 120 degrees apart
        let segments = 32
        let sweepRadians = CGFloat(50.0 * .pi / 180.0)
        let strokeWidth = max(2.5, size * (8.0 / 600.0))

        ctx.setLineCap(.round)
        ctx.setLineWidth(strokeWidth)

        for arcIndex in 0..<3 {
            let baseAngle = CGFloat(arcIndex) * (2.0 * .pi / 3.0)
            for s in 0..<segments {
                let t0 = CGFloat(s) / CGFloat(segments)
                let t1 = CGFloat(s + 1) / CGFloat(segments)
                let a0 = baseAngle + sweepRadians * t0
                let a1 = baseAngle + sweepRadians * t1

                // Smooth trailing gradient tapering up to head alpha 220/255
                let alpha = (220.0 / 255.0) * pow(t1, 1.45)
                ctx.setStrokeColor(UIColor(red: 47.0 / 255.0, green: 143.0 / 255.0, blue: 255.0 / 255.0, alpha: alpha).cgColor)
                ctx.beginPath()
                ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
                ctx.strokePath()
            }
        }
    }
}

// MARK: - Pulsing White Vector Infinity Logo (matches SplashActivity SVG path)

private final class SplashInfinityLogoView: UIView {

    private let shapeLayer = CAShapeLayer()

    private static let svgPathData =
        "M 807,374 L 783,368 L 755,366 L 722,370 L 693,379 L 663,394 L 635,414 " +
        "L 601,446 L 580,470 L 581,475 L 600,497 L 624,521 L 627,521 L 680,469 " +
        "L 711,447 L 740,439 L 759,440 L 775,445 L 791,455 L 800,464 L 814,489 " +
        "L 818,505 L 819,524 L 818,539 L 810,571 L 819,579 L 845,587 L 849,591 " +
        "L 842,598 L 820,606 L 783,612 L 725,612 L 692,606 L 646,682 L 647,685 " +
        "L 679,697 L 712,702 L 742,700 L 767,694 L 804,677 L 833,656 L 859,629 " +
        "L 881,595 L 895,559 L 900,533 L 901,497 L 894,461 L 881,433 L 864,411 " +
        "L 836,388 Z " +
        "M 432,364 L 405,396 L 380,431 L 380,434 L 398,449 L 427,478 L 513,577 " +
        "L 553,619 L 590,651 L 613,667 L 622,671 L 653,626 L 670,597 L 670,594 " +
        "L 644,573 L 611,541 L 539,461 L 487,408 L 458,382 L 435,364 Z " +
        "M 301,319 L 271,324 L 234,338 L 203,358 L 175,385 L 151,421 L 138,452 " +
        "L 130,488 L 129,528 L 134,558 L 146,593 L 167,629 L 190,655 L 217,676 " +
        "L 255,694 L 286,701 L 324,702 L 368,693 L 397,681 L 421,667 L 453,642 " +
        "L 496,596 L 496,592 L 451,545 L 448,545 L 421,572 L 391,595 L 364,609 " +
        "L 340,616 L 304,617 L 276,610 L 256,600 L 232,577 L 223,562 L 215,538 " +
        "L 214,501 L 222,471 L 237,446 L 262,424 L 294,411 L 330,410 L 358,419 " +
        "L 411,349 L 410,346 L 398,339 L 364,325 L 341,320 Z"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shapeLayer.fillColor = UIColor.white.cgColor
        layer.addSublayer(shapeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        shapeLayer.path = buildScaledPath(for: bounds.size).cgPath
    }

    func startPulse() {
        layer.removeAnimation(forKey: "splashLogoPulse")
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.06, 1.0]
        pulse.keyTimes = [0.0, 0.5, 1.0]
        pulse.duration = 1.5
        pulse.repeatCount = .infinity
        pulse.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        pulse.isRemovedOnCompletion = false
        layer.add(pulse, forKey: "splashLogoPulse")
    }

    func stopPulse() {
        layer.removeAnimation(forKey: "splashLogoPulse")
    }

    private func buildScaledPath(for size: CGSize) -> UIBezierPath {
        let bezier = UIBezierPath()
        let scale = min(size.width, size.height) / 1024.0
        guard scale > 0 else { return bezier }

        let tokens = Self.svgPathData.split { $0.isWhitespace }
        var i = 0
        while i < tokens.count {
            let cmd = tokens[i]
            if (cmd == "M" || cmd == "L"), i + 1 < tokens.count {
                let coords = tokens[i + 1].split(separator: ",")
                if coords.count == 2,
                   let rawX = Double(coords[0]),
                   let rawY = Double(coords[1]) {
                    let pt = CGPoint(x: CGFloat(rawX) * scale, y: CGFloat(rawY) * scale)
                    if cmd == "M" {
                        bezier.move(to: pt)
                    } else {
                        bezier.addLine(to: pt)
                    }
                }
                i += 2
            } else if cmd == "Z" {
                bezier.close()
                i += 1
            } else {
                i += 1
            }
        }
        return bezier
    }
}
