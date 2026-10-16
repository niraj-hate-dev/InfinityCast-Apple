//
//  WXSearchDeviceTableViewCell.swift
//  ApowerMirror
//
//  1:1 Reconstructed from ApowerMirror package
//  Custom TableView Cell displaying discovered desktop mirroring receivers.
//

import UIKit

@objc(WXSearchDeviceTableViewCell)
open class WXSearchDeviceTableViewCell: UITableViewCell {

    public static let reuseIdentifier = "WXSearchDeviceTableViewCell"

    @IBOutlet public weak var backView: UIView!
    @IBOutlet public weak var iconImgV: UIImageView!
    @IBOutlet public weak var titleLbl: UILabel!
    
    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        buildProgrammaticUIIfNeeded()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    open override func awakeFromNib() {
        super.awakeFromNib()
        setupAppearance()
    }

    private func buildProgrammaticUIIfNeeded() {
        guard backView == nil else { return }
        
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = .white
        card.layer.cornerRadius = 12
        card.layer.masksToBounds = true
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(white: 0.92, alpha: 1.0).cgColor
        contentView.addSubview(card)
        self.backView = card

        let img = UIImageView()
        img.translatesAutoresizingMaskIntoConstraints = false
        img.contentMode = .scaleAspectFit
        img.image = UIImage(named: "AirMore+.png") ?? UIImage(systemName: "display")
        card.addSubview(img)
        self.iconImgV = img

        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        lbl.textColor = UIColor(white: 0.15, alpha: 1.0)
        card.addSubview(lbl)
        self.titleLbl = lbl

        let arrow = UIImageView()
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.image = UIImage(systemName: "chevron.right")
        arrow.tintColor = UIColor(white: 0.7, alpha: 1.0)
        card.addSubview(arrow)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),

            img.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            img.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 32),
            img.heightAnchor.constraint(equalToConstant: 32),

            arrow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            arrow.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 12),
            arrow.heightAnchor.constraint(equalToConstant: 16),

            lbl.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 12),
            lbl.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -8),
            lbl.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
    }

    private func setupAppearance() {
        selectionStyle = .none
        backgroundColor = .clear
        backView?.layer.cornerRadius = 12
        backView?.layer.masksToBounds = true
        backView?.layer.borderWidth = 1
        backView?.layer.borderColor = UIColor(white: 0.92, alpha: 1.0).cgColor
    }

    public func configure(name: String, ip: String, port: Int = 25333) {
        buildProgrammaticUIIfNeeded()
        titleLbl?.text = name
    }

    open override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        UIView.animate(withDuration: 0.1) {
            self.backView?.backgroundColor = highlighted ? UIColor(white: 0.95, alpha: 1.0) : .white
        }
    }
}
