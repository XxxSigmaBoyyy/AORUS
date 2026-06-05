import Foundation
import UIKit

// Bottom toast in the Telegram-iOS / .nightAccent style: a dark blur capsule
// with the badge icon on the left and a single line of text on the right.
// Slides up + fades in, holds briefly, then fades out. Self-presenting on the
// key window so any badge tap from any screen can trigger it.
public enum AorusBadgeToast {
    private static weak var current: UIView?

    public static func present(icon: UIImage?, text: String, accent: UIColor) {
        guard let window = keyWindow() else { return }

        // Replace any visible toast immediately.
        current?.removeFromSuperview()

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isUserInteractionEnabled = false

        // Soft shadow on the container (outside the clipped blur).
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.35
        container.layer.shadowRadius = 16.0
        container.layer.shadowOffset = CGSize(width: 0.0, height: 6.0)

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 23.0
        blur.clipsToBounds = true
        blur.layer.borderWidth = 1.0
        blur.layer.borderColor = accent.withAlphaComponent(0.45).cgColor
        container.addSubview(blur)

        let iconView = UIImageView(image: icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
        label.numberOfLines = 1

        blur.contentView.addSubview(iconView)
        blur.contentView.addSubview(label)
        window.addSubview(container)
        current = container

        let bottomConstraint = container.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -16.0)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 16.0),
            container.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -16.0),
            bottomConstraint,

            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blur.heightAnchor.constraint(equalToConstant: 46.0),

            iconView.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 12.0),
            iconView.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30.0),
            iconView.heightAnchor.constraint(equalToConstant: 30.0),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10.0),
            label.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -16.0),
            label.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor)
        ])

        container.alpha = 0.0
        container.transform = CGAffineTransform(translationX: 0.0, y: 16.0)
        window.layoutIfNeeded()

        UIView.animate(withDuration: 0.28, delay: 0.0, options: [.curveEaseOut], animations: {
            container.alpha = 1.0
            container.transform = .identity
        }, completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 2.4, options: [.curveEaseIn], animations: {
                container.alpha = 0.0
                container.transform = CGAffineTransform(translationX: 0.0, y: 16.0)
            }, completion: { _ in
                if current === container {
                    current = nil
                }
                container.removeFromSuperview()
            })
        })
    }

    private static func keyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, windowScene.activationState == .foregroundActive else { continue }
            if let key = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return key
            }
            if let first = windowScene.windows.first {
                return first
            }
        }
        return UIApplication.shared.windows.first(where: { $0.isKeyWindow }) ?? UIApplication.shared.windows.first
    }
}
