import Foundation
import UIKit

// A small image view that invokes a closure when tapped. Lets host screens
// (e.g. the profile header) wire a badge → toast without adding @objc handlers
// to their own classes.
public final class AorusTappableBadgeView: UIImageView {
    public var onTap: (() -> Void)?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = true
        self.contentMode = .scaleAspectFit
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.handleTap))
        self.addGestureRecognizer(tap)
    }

    public override init(image: UIImage?) {
        super.init(image: image)
        self.isUserInteractionEnabled = true
        self.contentMode = .scaleAspectFit
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.handleTap))
        self.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.isUserInteractionEnabled = true
        self.contentMode = .scaleAspectFit
        let tap = UITapGestureRecognizer(target: self, action: #selector(self.handleTap))
        self.addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        self.onTap?()
    }
}
