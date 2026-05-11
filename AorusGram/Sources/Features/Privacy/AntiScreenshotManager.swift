import UIKit

// Detects screenshots and screen recording. When a screenshot is taken the
// window briefly blurs. When screen recording starts, a persistent blur overlay
// covers the entire app until recording stops.
final class AntiScreenshotManager {
    static let shared = AntiScreenshotManager()
    private init() {}

    private var blurWindow: UIWindow?
    private var isRecordingBlocked = false

    func enable() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didTakeScreenshot),
                       name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        nc.addObserver(self, selector: #selector(screenCaptureDidChange),
                       name: UIScreen.capturedDidChangeNotification, object: nil)
        // Handle recording that was already active before app launch
        if UIScreen.main.isCaptured {
            showPersistentBlur()
        }
    }

    func disable() {
        NotificationCenter.default.removeObserver(self)
        hidePersistentBlur()
    }

    // MARK: - Screenshot

    @objc private func didTakeScreenshot() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        flashBlur()
    }

    private func flashBlur() {
        let overlay = makeBlurView()
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) else { return }
        keyWindow.addSubview(overlay)
        UIView.animate(withDuration: 0.15, animations: {
            overlay.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.4, delay: 0.6, animations: {
                overlay.alpha = 0
            }, completion: { _ in overlay.removeFromSuperview() })
        })
    }

    // MARK: - Screen recording / AirPlay mirroring

    @objc private func screenCaptureDidChange() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        if UIScreen.main.isCaptured {
            showPersistentBlur()
        } else {
            hidePersistentBlur()
        }
    }

    private func showPersistentBlur() {
        guard blurWindow == nil else { return }
        DispatchQueue.main.async {
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            let win: UIWindow
            if let scene { win = UIWindow(windowScene: scene) }
            else { win = UIWindow(frame: UIScreen.main.bounds) }
            win.windowLevel = .alert + 1
            win.isUserInteractionEnabled = false
            let vc = UIViewController()
            vc.view = self.makeBlurView()
            win.rootViewController = vc
            win.isHidden = false
            self.blurWindow = win
            self.isRecordingBlocked = true
        }
    }

    private func hidePersistentBlur() {
        DispatchQueue.main.async {
            self.blurWindow?.isHidden = true
            self.blurWindow = nil
            self.isRecordingBlocked = false
        }
    }

    // MARK: - Blur view factory

    private func makeBlurView() -> UIView {
        let container = UIView(frame: UIScreen.main.bounds)
        container.alpha = 0

        let blur = UIBlurEffect(style: .systemUltraThinMaterial)
        let blurView = UIVisualEffectView(effect: blur)
        blurView.frame = container.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(blurView)

        let label = UILabel()
        label.text = "AorusGram\n🔒 Защищено"
        label.textAlignment = .center
        label.numberOfLines = 2
        label.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        blurView.contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: blurView.contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
        ])

        container.alpha = 1
        return container
    }
}
