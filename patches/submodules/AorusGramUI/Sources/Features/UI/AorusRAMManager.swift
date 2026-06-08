import Foundation
import UIKit
import Darwin

// MARK: - AorusRAMManager
//
// Floating "RAM: N MB" label + periodic cache cleanup.
//
// The label is a passthrough subview added directly to the current key window
// (more reliable than a separate UIWindow, which on iOS starts with a zero
// frame and frequently fails to render). A 2s timer refreshes the value and
// re-attaches the pill if the key window changed (modal, gallery, etc.).

public final class AorusRAMManager {
    public static let shared = AorusRAMManager()
    private init() {}

    private var pill: UIView?
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
        }
        let mgr = AorusGramManager.shared
        applyOverlay(enabled: mgr.ramShow)
        applyAutoClean(enabled: mgr.ramAutoClean, intervalMinutes: mgr.ramInterval)
    }

    @objc private func onSettingsChanged() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
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
            buildPillIfNeeded()
            attachAndLayout()
            updateLabel()
            if pill?.superview == nil {
                // Key window not ready yet (early bootstrap) — retry shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard AorusGramManager.shared.ramShow else { return }
                    self?.applyOverlay(enabled: true)
                }
            }
            if displayTimer == nil {
                let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.attachAndLayout()   // re-home if key window changed
                    self.updateLabel()
                }
                displayTimer = t
                RunLoop.main.add(t, forMode: .common)
            }
        } else {
            displayTimer?.invalidate(); displayTimer = nil
            pill?.removeFromSuperview()
            pill = nil
            ramLabel = nil
        }
    }

    private func buildPillIfNeeded() {
        guard pill == nil else { return }

        let pill = UIView()
        pill.isUserInteractionEnabled = false
        pill.backgroundColor = UIColor(white: 0.06, alpha: 0.72)
        pill.layer.cornerRadius = 12
        pill.layer.masksToBounds = true
        pill.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        pill.layer.borderWidth = 0.5
        pill.layer.zPosition = 100_000   // stay above app content

        let label = UILabel()
        label.textColor = .white
        label.textAlignment = .center
        // SF Rounded bold — clean, modern, monospaced-feel digits.
        if let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption1)
            .withDesign(.rounded) {
            let bold = descriptor.withSymbolicTraits(.traitBold) ?? descriptor
            label.font = UIFont(descriptor: bold, size: 13)
        } else {
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        }
        pill.addSubview(label)
        self.ramLabel = label
        self.pill = pill
    }

    // Attach the pill to the current key window (re-homing if it changed) and
    // position it top-right, comfortably inset from the edge.
    private func attachAndLayout() {
        guard let pill = pill, let label = ramLabel else { return }
        guard let host = keyWindow() else { return }

        if pill.superview !== host {
            pill.removeFromSuperview()
            host.addSubview(pill)
        }
        host.bringSubviewToFront(pill)

        let safeTop = host.safeAreaInsets.top > 0 ? host.safeAreaInsets.top : 44
        let w: CGFloat = 98
        let h: CGFloat = 26
        // 14pt gap from the trailing edge — not flush against the side.
        pill.frame = CGRect(x: host.bounds.width - w - 14, y: safeTop + 6, width: w, height: h)
        pill.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        label.frame = CGRect(x: 8, y: 3, width: w - 16, height: h - 6)
    }

    private func updateLabel() {
        ramLabel?.text = "RAM: \(footprintMB()) MB"
    }

    private func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        guard let scene = active else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow })
            ?? scene.windows.last(where: { !$0.isHidden && $0.bounds.width > 0 })
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
}
