import Foundation
import UIKit
import Darwin

// MARK: - AorusRAMManager
//
// "RAM: N MB" pill rendered in a dedicated passthrough UIWindow at
// windowLevel .statusBar + 100 — guaranteed above ALL app content,
// alerts, and Telegram's own overlays without interfering with touches
// or status-bar appearance (window is visible but never key).

public final class AorusRAMManager {
    public static let shared = AorusRAMManager()
    private init() {}

    private var overlayWindow: UIWindow?
    private var pillLabel: UILabel?
    private var displayTimer: Timer?
    private var cleanTimer: Timer?
    private var observing = false

    // MARK: - Public entry point

    public func refresh() {
        DispatchQueue.main.async { [weak self] in self?._doRefresh() }
    }

    private func _doRefresh() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(_onSettings),
                name: .aorusSettingsChanged, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(_onActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        let mgr = AorusGramManager.shared
        _applyOverlay(enabled: mgr.ramShow)
        _applyAutoClean(enabled: mgr.ramAutoClean, intervalMinutes: mgr.ramInterval)
    }

    @objc private func _onSettings() {
        DispatchQueue.main.async { [weak self] in self?._doRefresh() }
    }

    @objc private func _onActive() {
        DispatchQueue.main.async { [weak self] in
            guard AorusGramManager.shared.ramShow else { return }
            self?._ensureWindow()
        }
    }

    // MARK: - Memory footprint

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

    // MARK: - Overlay lifecycle

    private func _applyOverlay(enabled: Bool) {
        if enabled {
            _ensureWindow()
            if displayTimer == nil {
                let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    self?._updateLabel()
                }
                displayTimer = t
                RunLoop.main.add(t, forMode: .common)
            }
        } else {
            displayTimer?.invalidate(); displayTimer = nil
            overlayWindow?.isHidden = true
            overlayWindow = nil
            pillLabel = nil
        }
    }

    private func _ensureWindow() {
        guard let scene = _activeScene() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard AorusGramManager.shared.ramShow else { return }
                self?._ensureWindow()
            }
            return
        }

        if overlayWindow == nil {
            _buildWindow(scene: scene)
        } else {
            overlayWindow?.isHidden = false
        }
        _updateLabel()
    }

    private func _buildWindow(scene: UIWindowScene) {
        let w = UIWindow(windowScene: scene)
        // Above statusBar → renders on top of every Telegram view and alert window.
        // Never calling makeKeyAndVisible() keeps Telegram as key window owner.
        // rawValue arithmetic — UIWindow.Level does not define a `+` operator.
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 100)
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        w.frame = scene.screen.bounds

        let vc = _AorusOverlayVC()
        w.rootViewController = vc
        w.isHidden = false
        overlayWindow = w

        // Pill — Auto Layout relative to safe area so it sits right below the
        // status bar on all device sizes and orientations.
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.isUserInteractionEnabled = false
        pill.backgroundColor = UIColor(white: 0.07, alpha: 0.78)
        pill.layer.cornerRadius = 12
        pill.layer.masksToBounds = true
        pill.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        pill.layer.borderWidth = 0.5

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        if let d = UIFontDescriptor
            .preferredFontDescriptor(withTextStyle: .caption1)
            .withDesign(.rounded) {
            label.font = UIFont(descriptor: d.withSymbolicTraits(.traitBold) ?? d, size: 13)
        } else {
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }

        pill.addSubview(label)
        vc.view.addSubview(pill)

        NSLayoutConstraint.activate([
            pill.trailingAnchor.constraint(
                equalTo: vc.view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            pill.topAnchor.constraint(
                equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 6),
            pill.widthAnchor.constraint(equalToConstant: 98),
            pill.heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])

        pillLabel = label
        _updateLabel()
    }

    private func _activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: {
                $0.activationState == .foregroundActive ||
                $0.activationState == .foregroundInactive
            })
    }

    private func _updateLabel() {
        pillLabel?.text = "RAM: \(footprintMB()) MB"
    }

    // MARK: - Auto cleanup

    private func _applyAutoClean(enabled: Bool, intervalMinutes: Int) {
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
        autoreleasepool {}
    }
}

// Transparent passthrough root VC for the overlay window.
// Never key → Telegram retains full status-bar control.
private final class _AorusOverlayVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }
}
