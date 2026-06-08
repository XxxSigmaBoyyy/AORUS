import Foundation
import UIKit
import Darwin

// MARK: - AorusRAMManager
//
// Replaces the former Streak feature in the Performance section. Provides:
//   1. A floating "RAM: NNN MB" label in a passthrough overlay window
//      (top-right, below the status bar) when ramShow is enabled.
//   2. Periodic auto-cleanup of app-side caches at a user-chosen interval
//      when ramAutoClean is enabled.
//
// Reads its state from AorusGramManager and reacts to .aorusSettingsChanged.
// Everything is best-effort and uses only public APIs — on iOS an app can only
// release ITS OWN caches, never another process's memory.

public final class AorusRAMManager {
    public static let shared = AorusRAMManager()
    private init() {}

    private var overlayWindow: UIWindow?
    private weak var ramLabel: UILabel?
    private var displayTimer: Timer?
    private var cleanTimer: Timer?
    private var observing = false

    // MARK: - Public entry point

    /// Call once at bootstrap and whenever settings change.
    public func refresh() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(refreshFromNotification),
                name: .aorusSettingsChanged, object: nil)
        }
        let mgr = AorusGramManager.shared
        applyOverlay(enabled: mgr.ramShow)
        applyAutoClean(enabled: mgr.ramAutoClean, intervalMinutes: mgr.ramInterval)
    }

    @objc private func refreshFromNotification() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    // MARK: - Memory reading

    /// Current physical memory footprint of this process, in megabytes.
    public func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
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
            ensureOverlay()
            updateLabel()
            if displayTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?.updateLabel()
                }
                displayTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            displayTimer?.invalidate(); displayTimer = nil
            overlayWindow?.isHidden = true
            overlayWindow = nil
            ramLabel = nil
        }
    }

    private func ensureOverlay() {
        guard overlayWindow == nil else { return }
        guard let scene = activeWindowScene() else { return }

        let window = _AGPassthroughWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false

        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root

        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = UIColor(white: 0, alpha: 0.55)
        pill.layer.cornerRadius = 11
        pill.layer.masksToBounds = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center

        pill.addSubview(label)
        root.view.addSubview(pill)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
            pill.trailingAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            pill.topAnchor.constraint(equalTo: root.view.safeAreaLayoutGuide.topAnchor, constant: 6),
            pill.heightAnchor.constraint(equalToConstant: 22),
        ])

        window.isHidden = false
        overlayWindow = window
        ramLabel = label
    }

    private func updateLabel() {
        ramLabel?.text = "RAM: \(footprintMB()) MB"
    }

    // MARK: - Auto cleanup

    private func applyAutoClean(enabled: Bool, intervalMinutes: Int) {
        cleanTimer?.invalidate(); cleanTimer = nil
        guard enabled else { return }
        let minutes = max(5, intervalMinutes)
        let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
        cleanTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Best-effort release of app-side caches. Public so a manual "clean now"
    /// control can call it too.
    public func performCleanup() {
        URLCache.shared.removeAllCachedResponses()
        URLSession.shared.configuration.urlCache?.removeAllCachedResponses()
        // Ask the system to release purgeable memory we hold.
        autoreleasepool { }
    }

    // MARK: - Helpers

    private func activeWindowScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene, ws.activationState == .foregroundActive {
                return ws
            }
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

// A window that never intercepts touches — the RAM label is display-only and
// must never block interaction with the app beneath it.
private final class _AGPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }
}
