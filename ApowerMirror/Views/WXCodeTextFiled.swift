//
//  WXCodeTextFiled.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Custom PIN/Code input field rendering separated digit boxes with cursor state.
//

import UIKit

@objc(WXCodeTextFiled)
open class WXCodeTextFiled: UIView, UIKeyInput {

    public var maxDigits: Int = 4
    public var codeDidChange: ((String) -> Void)?
    
    private var internalText: String = ""
    private var digitLabels: [UILabel] = []
    private var digitBoxes: [UIView] = []

    public var hasText: Bool {
        return !internalText.isEmpty
    }

    public var keyboardType: UIKeyboardType = .numberPad
    public var textContentType: UITextContentType? = .oneTimeCode

    public var code: String {
        get { return internalText }
        set {
            internalText = String(newValue.prefix(maxDigits))
            updateBoxes()
            codeDidChange?(internalText)
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

    open override var canBecomeFirstResponder: Bool {
        return true
    }

    private func setupUI() {
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(becomeFirstResponder))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
        buildBoxes()
    }

    private func buildBoxes() {
        digitBoxes.forEach { $0.removeFromSuperview() }
        digitBoxes.removeAll()
        digitLabels.removeAll()

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 16
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        for _ in 0..<maxDigits {
            let box = UIView()
            box.layer.cornerRadius = 10
            box.layer.borderWidth = 1.5
            box.layer.borderColor = UIColor(white: 0.85, alpha: 1.0).cgColor
            box.backgroundColor = .white

            let lbl = UILabel()
            lbl.translatesAutoresizingMaskIntoConstraints = false
            lbl.font = UIFont.systemFont(ofSize: 28, weight: .bold)
            lbl.textColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0)
            lbl.textAlignment = .center
            box.addSubview(lbl)

            NSLayoutConstraint.activate([
                lbl.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                lbl.centerYAnchor.constraint(equalTo: box.centerYAnchor)
            ])

            stack.addArrangedSubview(box)
            digitBoxes.append(box)
            digitLabels.append(lbl)
        }
    }

    private func updateBoxes() {
        let chars = Array(internalText)
        for i in 0..<maxDigits {
            if i < chars.count {
                digitLabels[i].text = String(chars[i])
                digitBoxes[i].layer.borderColor = UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 1.0).cgColor
            } else {
                digitLabels[i].text = ""
                digitBoxes[i].layer.borderColor = (isFirstResponder && i == chars.count)
                    ? UIColor(red: 0.20, green: 0.60, blue: 1.0, alpha: 0.8).cgColor
                    : UIColor(white: 0.85, alpha: 1.0).cgColor
            }
        }
    }

    open func insertText(_ text: String) {
        guard internalText.count < maxDigits else { return }
        let filtered = text.filter { $0.isNumber }
        internalText.append(filtered)
        if internalText.count > maxDigits {
            internalText = String(internalText.prefix(maxDigits))
        }
        updateBoxes()
        codeDidChange?(internalText)
    }

    open func deleteBackward() {
        guard !internalText.isEmpty else { return }
        internalText.removeLast()
        updateBoxes()
        codeDidChange?(internalText)
    }

    open override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        updateBoxes()
        return result
    }

    open override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        updateBoxes()
        return result
    }
}
