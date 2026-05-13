import UIKit

// Anti-screenshot / anti-screen-recording.
// When the screen is being captured (recording or AirPlay mirror) we cover the
// entire app with a SOLID WHITE overlay that shows only the AORUSGRAM brand —
// any video or photo will record the overlay, not the real content.
// On screenshot the overlay flashes briefly so the user knows it triggered;
// iOS captures the screenshot before any notification fires, so the prior frame
// will still be visible in the screenshot itself. For full screenshot blanking
// the user must rely on screen recording detection (which works pre-capture).
final class AntiScreenshotManager {
    static let shared = AntiScreenshotManager()
    private init() {}

    private var overlayWindow: UIWindow?

    func enable() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didTakeScreenshot),
                       name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        nc.addObserver(self, selector: #selector(screenCaptureDidChange),
                       name: UIScreen.capturedDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(willResignActive),
                       name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        // Handle recording that was already active before app launch.
        if UIScreen.main.isCaptured {
            showOverlay(persistent: true)
        }
    }

    func disable() {
        NotificationCenter.default.removeObserver(self)
        hideOverlay()
    }

    // MARK: - Screenshot

    @objc private func didTakeScreenshot() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        flashOverlay()
    }

    // MARK: - Screen recording / AirPlay mirroring

    @objc private func screenCaptureDidChange() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        if UIScreen.main.isCaptured {
            showOverlay(persistent: true)
        } else {
            hideOverlay()
        }
    }

    // App switcher snapshot — Apple takes one when going inactive.
    // Showing the overlay during willResignActive ensures the snapshot is the
    // branded frame, not the chat content.
    @objc private func willResignActive() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        showOverlay(persistent: true)
    }

    @objc private func didBecomeActive() {
        // Don't hide if still recording
        if !UIScreen.main.isCaptured {
            hideOverlay()
        }
    }

    // MARK: - Overlay

    private func flashOverlay() {
        showOverlay(persistent: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.hideOverlay()
        }
    }

    private func showOverlay(persistent: Bool) {
        DispatchQueue.main.async {
            if self.overlayWindow != nil { return }
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first
            let win: UIWindow
            if let scene { win = UIWindow(windowScene: scene) }
            else { win = UIWindow(frame: UIScreen.main.bounds) }
            win.windowLevel = .alert + 1
            win.isUserInteractionEnabled = false
            win.backgroundColor = .white
            let vc = UIViewController()
            vc.view = self.makeBrandingView(frame: win.bounds)
            win.rootViewController = vc
            win.isHidden = false
            self.overlayWindow = win
        }
    }

    private func hideOverlay() {
        DispatchQueue.main.async {
            self.overlayWindow?.isHidden = true
            self.overlayWindow = nil
        }
    }

    private func makeBrandingView(frame: CGRect) -> UIView {
        let container = UIView(frame: frame)
        container.backgroundColor = .white

        // Brand: "AORUSGRAM" — large, bold, orange gradient
        let brand = UILabel()
        brand.text = "AORUSGRAM"
        brand.font = UIFont.systemFont(ofSize: 44, weight: .black)
        brand.textAlignment = .center
        brand.textColor = UIColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1.0)
        brand.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle: "@aorusgram" — smaller, gray
        let handle = UILabel()
        handle.text = "@aorusgram"
        handle.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        handle.textAlignment = .center
        handle.textColor = UIColor(white: 0.4, alpha: 1.0)
        handle.translatesAutoresizingMaskIntoConstraints = false

        // Lock icon for visual cue
        let lock = UILabel()
        lock.text = "🔒"
        lock.font = UIFont.systemFont(ofSize: 56)
        lock.textAlignment = .center
        lock.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(lock)
        container.addSubview(brand)
        container.addSubview(handle)

        NSLayoutConstraint.activate([
            lock.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            lock.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -80),

            brand.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            brand.topAnchor.constraint(equalTo: lock.bottomAnchor, constant: 20),

            handle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            handle.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 10),
        ])

        return container
    }
}
