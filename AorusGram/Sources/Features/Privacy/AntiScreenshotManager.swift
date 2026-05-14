import UIKit

// Anti-screenshot / anti-screen-recording.
//
// The trick: iOS treats anything inside a `UITextField`'s private secure-canvas
// layer (created when `isSecureTextEntry = true`) as protected. Such content
// renders normally to the user's display, but is BLANK in:
//   - screen recordings
//   - screenshots
//   - AirPlay/screen mirroring
//   - the app switcher snapshot
//
// We exploit this by:
//   1. Placing a separate AORUSGRAM-branded UIWindow BEHIND the main app
//      window (`windowLevel = .normal - 100`). The user can't see it because
//      the main window is on top.
//   2. Re-parenting the main window's rootViewController.view layer INTO the
//      secure canvas of a hidden text field. The user keeps seeing Telegram
//      normally. But to a screen recording the protected layer is blank,
//      so the recording captures the AORUSGRAM window UNDERNEATH instead.
//
// When the capture event ends we reverse the re-parenting and hide the
// branding window. The result is: user always sees real Telegram; any
// recording / screenshot / app-switcher snapshot only ever sees AORUSGRAM.
final class AntiScreenshotManager {
    static let shared = AntiScreenshotManager()
    private init() {}

    private var isEnabled = false
    private var brandingWindow: UIWindow?
    private var protectedField: UITextField?
    private weak var protectedRootView: UIView?
    private weak var originalSuperlayer: CALayer?

    func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didTakeScreenshot),
                       name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        nc.addObserver(self, selector: #selector(screenCaptureDidChange),
                       name: UIScreen.capturedDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(willResignActive),
                       name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(didBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        if UIScreen.main.isCaptured {
            applyProtection()
        }
    }

    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        NotificationCenter.default.removeObserver(self)
        removeProtection()
    }

    @objc private func didTakeScreenshot() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    @objc private func screenCaptureDidChange() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        if UIScreen.main.isCaptured {
            applyProtection()
        } else {
            removeProtection()
        }
    }

    // App switcher snapshot — iOS takes one when going inactive. Protection
    // must be installed BEFORE the snapshot happens, so we install on
    // willResignActive and uninstall on didBecomeActive (if not capturing).
    @objc private func willResignActive() {
        guard AorusGramConfig.isEnabled(.antiScreenshot) else { return }
        applyProtection()
    }

    @objc private func didBecomeActive() {
        if !UIScreen.main.isCaptured {
            removeProtection()
        }
    }

    // MARK: - Protection install / uninstall

    private func applyProtection() {
        DispatchQueue.main.async { [weak self] in
            self?.installProtection()
        }
    }

    private func removeProtection() {
        DispatchQueue.main.async { [weak self] in
            self?.uninstallProtection()
        }
    }

    private func installProtection() {
        guard protectedField == nil else { return }
        guard let keyWindow = findKeyWindow(),
              let rootView = keyWindow.rootViewController?.view,
              let scene = keyWindow.windowScene,
              let parentLayer = rootView.layer.superlayer else { return }

        // 1. Background AORUSGRAM window — visible only to screen capture.
        let brand = UIWindow(windowScene: scene)
        brand.frame = keyWindow.bounds
        brand.windowLevel = UIWindow.Level.normal - 100
        brand.isUserInteractionEnabled = false
        brand.backgroundColor = .white
        let vc = UIViewController()
        vc.view = makeBrandingView(frame: brand.bounds)
        brand.rootViewController = vc
        brand.isHidden = false
        brandingWindow = brand

        // 2. Secure text field — its private canvas layer is excluded from
        //    screen capture by iOS. The field must be full-screen (NOT zero)
        //    so its secure sublayer has proper bounds and doesn't clip content.
        //    We make it completely transparent so the user never sees it.
        let field = UITextField()
        field.isSecureTextEntry = true
        field.frame = keyWindow.bounds
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.textColor = .clear
        field.tintColor = .clear
        field.isUserInteractionEnabled = false
        keyWindow.addSubview(field)

        // Find the secure canvas layer (last sublayer of the field's layer).
        // Bail out cleanly if iOS internals change and we can't find it.
        guard let secureLayer = field.layer.sublayers?.last else {
            field.removeFromSuperview()
            brand.isHidden = true
            brandingWindow = nil
            return
        }

        originalSuperlayer = parentLayer
        protectedRootView = rootView

        // 3. Re-parent rootView.layer INTO the secure canvas. To the user
        //    this is invisible (CA renders the layer fine), but the screen
        //    capture pipeline blanks it out.
        secureLayer.addSublayer(rootView.layer)

        protectedField = field
    }

    private func uninstallProtection() {
        guard let field = protectedField else {
            brandingWindow?.isHidden = true
            brandingWindow = nil
            return
        }

        // Restore rootView.layer back to its original parent layer.
        if let parent = originalSuperlayer, let view = protectedRootView {
            parent.addSublayer(view.layer)
        }
        field.removeFromSuperview()

        protectedField = nil
        protectedRootView = nil
        originalSuperlayer = nil

        brandingWindow?.isHidden = true
        brandingWindow = nil
    }

    // MARK: - Helpers

    private func findKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        // Prefer foreground active scene
        let active = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene = active else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    }

    private func makeBrandingView(frame: CGRect) -> UIView {
        let container = UIView(frame: frame)
        container.backgroundColor = .white

        let brand = UILabel()
        brand.text = "AORUSGRAM"
        brand.font = UIFont.systemFont(ofSize: 44, weight: .black)
        brand.textAlignment = .center
        brand.textColor = UIColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1.0)
        brand.translatesAutoresizingMaskIntoConstraints = false

        let handle = UILabel()
        handle.text = "@aorusgram"
        handle.font = UIFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        handle.textAlignment = .center
        handle.textColor = UIColor(white: 0.4, alpha: 1.0)
        handle.translatesAutoresizingMaskIntoConstraints = false

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
