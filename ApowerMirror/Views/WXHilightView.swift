//
//  WXHilightView.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Interactive card view with smooth touch-down highlight, rounded corners,
//  and tap gesture callback support for mirroring selection cards.
//

import UIKit

@objc(WXHilightView)
open class WXHilightView: UIView {

    public var touchDownColor: UIColor = UIColor(white: 0.94, alpha: 1.0)
    public var normalColor: UIColor = .white
    public var tapAction: (() -> Void)?
    
    @IBInspectable public var cornerRadius: CGFloat = 12.0 {
        didSet {
            layer.cornerRadius = cornerRadius
            layer.masksToBounds = true
        }
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
        backgroundColor = normalColor
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func handleTap() {
        tapAction?()
    }

    open override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        UIView.animate(withDuration: 0.1) {
            self.backgroundColor = self.touchDownColor
            self.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        }
    }

    open override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        UIView.animate(withDuration: 0.15) {
            self.backgroundColor = self.normalColor
            self.transform = .identity
        }
    }

    open override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        UIView.animate(withDuration: 0.15) {
            self.backgroundColor = self.normalColor
            self.transform = .identity
        }
    }
}
