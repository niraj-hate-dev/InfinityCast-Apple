//
//  WXLinkButton.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Custom button with link appearance, underline support, and touch styling.
//

import UIKit

@objc(WXLinkButton)
open class WXLinkButton: UIButton {

    @IBInspectable public var underline: Bool = true {
        didSet {
            updateTitleAppearance()
        }
    }
    
    @IBInspectable public var linkColor: UIColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0) {
        didSet {
            updateTitleAppearance()
        }
    }

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

    private func setupUI() {
        setTitleColor(linkColor, for: .normal)
        titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        updateTitleAppearance()
    }

    public func updateTitleAppearance() {
        guard let currentText = title(for: .normal) else { return }
        
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: linkColor,
            .font: titleLabel?.font ?? UIFont.systemFont(ofSize: 14),
            .underlineStyle: underline ? NSUnderlineStyle.single.rawValue : 0
        ]
        
        let attrString = NSAttributedString(string: currentText, attributes: attributes)
        setAttributedTitle(attrString, for: .normal)
    }

    open override func setTitle(_ title: String?, for state: UIControl.State) {
        super.setTitle(title, for: state)
        if state == .normal {
            updateTitleAppearance()
        }
    }
}
