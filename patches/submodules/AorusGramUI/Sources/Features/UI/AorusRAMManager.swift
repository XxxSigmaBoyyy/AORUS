import Foundation
import UIKit
import Darwin

// MARK: - AorusRAMManager
//
// Floating RAM label (top-right, white rounded pill) + periodic cache cleanup.
// Uses frame-based layout so the overlay works before any AutoLayout pass.
// Retries scene acquisition if called during early bootstrap.

public final class AorusRAMManager {
    public static let shared = AorusRAMManager()
    private init() {}

    private var overlayWindow: UIWindow?
    private weak var overlayPill: UIView?
    private weak var ramLabel: UILabel?
    private var displayTimer: Timer?
    private var cleanTimer: Timer?
    private var observing = false

    // MARK: - Public entry point

    public func refresh() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(onSettingsChanged),
                name: .aorusSettingsChanged, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(onOrientationChanged),
                name: UIDevice.orientationDidChangeNotification, object: nil)
        }
        let mgr = AorusGramManager.shared
        applyOverlay(enabled: mgr.ramShow)
        applyAutoClean(enabled: mgr.ramAutoClean, intervalMinutes: mgr.ramInterval)
    }

    @objc private func onSettingsChanged() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    @objc private func onOrientationChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.layoutOverlay()
        }
    }

    // MARK: - Memory reading

    public func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint) / (1024 * 1024)
    }

    // MARK: - Floating overlay

    private func applyOverlay(enabled: Bool) {
        if enabled {
            if overlayWindow == nil {
                ensureOverlay()
            }
            if overlayWindow == nil {
                // Window scene not ready yet (early bootstrap) — retry shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard AorusGramManager.shared.ramShow else { return }
                    self?.applyOverlay(enabled: true)
                }
                return
            }
            overlayWindow?.isHidden = false
            updateLabel()
            if displayTimer == nil {
                let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?.updateLabel()
                }
                displayTimer = t
                RunLoop.main.add(t, forMode: .common)
            }
        } else {
            displayTimer?.invalidate(); displayTimer = nil
            overlayWindow?.isHidden = true
            overlayWindow = nil
            overlayPill = nil
            ramLabel = nil
        }
    }

    private func ensureOverlay() {
        guard overlayWindow == nil else { return }
        guard let scene = bestWindowScene() else { return }

        let window = _AGPassthroughWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        // UIWindow(windowScene:) does NOT inherit a frame — without this the
        // window has zero bounds and the pill is laid out off-screen.
        window.frame = sceneBounds(scene)

        let root = UIViewController()
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        window.rootViewController = root
        window.isHidden = false
        overlayWindow = window

        // Pill container — frosted dark capsule.
        let pill = UIView()
        pill.backgroundColor = UIColor(white: 0.06, alpha: 0.72)
        pill.layer.cornerRadius = 12
        pill.layer.masksToBounds = true
        // Subtle highlight border.
        pill.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        pill.layer.borderWidth = 0.5
        root.view.addSubview(pill)
        overlayPill = pill

        // Label — white, rounded monospaced digits.
        let label = UILabel()
        label.textColor = .white
        label.textAlignment = .center
        // SF Rounded gives a modern, clean look without going to a full custom font.
        if let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption2)
            .withDesign(.rounded) {
            label.font = UIFont(descriptor: descriptor.withSymbolicTraits(.traitBold) ?? descriptor, size: 13)
        } else {
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }
        pill.addSubview(label)
        ramLabel = label

        // Layout after the window has been added to the scene so safeAreaInsets exist.
        DispatchQueue.main.async { [weak self] in self?.layoutOverlay() }
    }

    // Lay out pill and label using frame math (avoids AutoLayout timing issues).
    @objc private func layoutOverlay() {
        guard let window = overlayWindow,
              let pill = overlayPill,
              let label = ramLabel else { return }

        // Keep the window sized to its scene (handles rotation / late layout).
        if let scene = window.windowScene {
            window.frame = sceneBounds(scene)
        }
        let bounds = window.bounds
        let safeTop = window.safeAreaInsets.top > 0 ? window.safeAreaInsets.top : 50
        let pillW: CGFloat = 94
        let pillH: CGFloat = 26
        // 14 pt gap from the right edge, not flush against it.
        pill.frame = CGRect(x: bounds.width - pillW - 14,
                            y: safeTop + 7,
                            width: pillW, height: pillH)
        label.frame = CGRect(x: 7, y: 4, width: pillW - 14, height: pillH - 8)
    }

    private func updateLabel() {
        ramLabel?.text = "RAM: \(footprintMB()) MB"
    }

    // MARK: - Auto cleanup

    private func applyAutoClean(enabled: Bool, intervalMinutes: Int) {
        cleanTimer?.invalidate(); cleanTimer = nil
        guard enabled else { return }
        let minutes = max(5, intervalMinutes)
        let t = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60),
                                     repeats: true) { [weak self] _ in self?.performCleanup() }
        cleanTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    public func performCleanup() {
        URLCache.shared.removeAllCachedResponses()
        URLSession.shared.configuration.urlCache?.removeAllCachedResponses()
        autoreleasepool { }
    }

    // MARK: - Helpers

    // Full-screen bounds for a scene, derived from one of its real windows
    // (UIWindowScene has no `coordinateSpace`; we avoid the deprecated `.screen`).
    private func sceneBounds(_ scene: UIWindowScene) -> CGRect {
        if let ref = scene.windows.first(where: {
            !($0 is _AGPassthroughWindow) && $0.bounds.width > 0
        }) {
            return ref.bounds
        }
        return UIScreen.main.bounds
    }

    private func bestWindowScene() -> UIWindowScene? {
        // Prefer an active foreground scene; fall back to any connected scene.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
    }
}

// Window that never intercepts touches — the overlay is display-only.
private final class _AGPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}
