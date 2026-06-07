import Foundation
import UIKit

// AorusGram notch / Dynamic Island badge.
//
// A single decorative AORUSGRAM pill placed at the top-centre of the key window,
// in the notch / Dynamic Island zone. It is purely cosmetic (visible on
// screenshots), non-interactive (taps pass through), and shown only on devices
// that have a notch or Dynamic Island, in portrait, while the app is active.
//
// One fixed badge — no selection, no settings, no persistence.
public final class AorusNotchBadge {
    public static let shared = AorusNotchBadge()

    private let badgeView = UIImageView()
    private weak var window: UIWindow?
    private var forceHidden = true
    private var observersInstalled = false

    // Display height of the pill in points; width is derived from the image aspect.
    private let badgeHeight: CGFloat = 22.0

    private init() {
        self.badgeView.image = AorusNotchBadgeAssets.badge
        self.badgeView.contentMode = .scaleAspectFit
        self.badgeView.isUserInteractionEnabled = false
        self.badgeView.isHidden = true
        self.badgeView.accessibilityIdentifier = "AorusNotchBadge"
    }

    // Install the badge into the given key window. Safe to call more than once.
    public func setup(in window: UIWindow) {
        self.window = window
        if self.badgeView.superview !== window {
            self.badgeView.removeFromSuperview()
            window.addSubview(self.badgeView)
        }

        if !self.observersInstalled {
            self.observersInstalled = true
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(self.didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            nc.addObserver(self, selector: #selector(self.willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            nc.addObserver(self, selector: #selector(self.layoutChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        }

        // If the app is already active when setup runs, show immediately.
        if UIApplication.shared.applicationState == .active {
            self.forceHidden = false
        }

        self.updateFrame()
        self.updateVisibility()
    }

    @objc private func didBecomeActive() {
        self.forceHidden = false
        self.updateFrame()
        self.updateVisibility()
    }

    @objc private func willResignActive() {
        self.forceHidden = true
        self.updateVisibility()
    }

    @objc private func layoutChanged() {
        // Defer to the next runloop so window bounds reflect the new orientation.
        DispatchQueue.main.async { [weak self] in
            self?.updateFrame()
            self?.updateVisibility()
        }
    }

    private func updateFrame() {
        guard let window = self.window, let image = self.badgeView.image else { return }
        let aspect = image.size.width / max(1.0, image.size.height)
        let height = self.badgeHeight
        let width = floorToScreenPixels(height * aspect)
        let w = window.bounds.width
        let x = floorToScreenPixels((w - width) / 2.0)
        let y = AorusNotchBadgeDevice.yOffset()
        self.badgeView.frame = CGRect(x: x, y: y, width: width, height: height)
        window.bringSubviewToFront(self.badgeView)
    }

    private func updateVisibility() {
        guard let window = self.window else { return }
        let w = window.bounds.width
        let h = window.bounds.height
        let shouldHide = !AorusNotchBadgeDevice.isSupported()
            || self.forceHidden
            || w > h // landscape

        if !shouldHide {
            window.bringSubviewToFront(self.badgeView)
        }

        if !shouldHide && self.badgeView.isHidden {
            // Small delay on appearance so it settles after launch/foreground.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, let window = self.window else { return }
                let stillVisible = AorusNotchBadgeDevice.isSupported()
                    && !self.forceHidden
                    && window.bounds.width <= window.bounds.height
                self.badgeView.isHidden = !stillVisible
                if stillVisible {
                    window.bringSubviewToFront(self.badgeView)
                }
            }
        } else {
            self.badgeView.isHidden = shouldHide
        }
    }

    private func floorToScreenPixels(_ value: CGFloat) -> CGFloat {
        let scale = UIScreen.main.scale
        return floor(value * scale) / scale
    }
}

// Device model → top Y-offset (points) for the notch / Dynamic Island badge.
// offset 0 means the device has no notch/island → badge not shown.
//
// NOTE: the source guide's switch had duplicate/incorrect identifiers (e.g.
// iPhone14,3 in two groups, iPhone11,6 for 11 Pro Max). This table is the
// corrected, de-duplicated mapping — every identifier appears exactly once.
enum AorusNotchBadgeDevice {
    // Uniform upward lift (points) applied on every device so the pill sits a
    // touch higher and clears the Dynamic Island / notch edge — otherwise a thin
    // sliver of the system island shows below the badge.
    private static let verticalLift: CGFloat = 4.0

    static func isSupported() -> Bool {
        // Device capability is decided by the model table, NOT by the (possibly
        // lifted-to-zero) yOffset, so the badge never disappears on small-offset
        // notch devices after the lift.
        return defaultOffset(for: machineIdentifier()) > 0.0
    }

    static func yOffset() -> CGFloat {
        let base = defaultOffset(for: machineIdentifier())
        if base <= 0.0 {
            return 0.0
        }
        let lifted = max(0.0, base - verticalLift)
        // Account for Display Zoom (Settings → Display → Zoom): nativeScale differs
        // from scale when zoomed, shifting the visual top region.
        let scale = UIScreen.main.scale
        let nativeScale = UIScreen.main.nativeScale
        let scaleFactor = nativeScale > 0.0 ? scale / nativeScale : 1.0
        let value = lifted * scaleFactor
        return floor(value * scale) / scale
    }

    private static func defaultOffset(for model: String) -> CGFloat {
        switch model {
        // Notch — small inset (X / XS / 11 Pro / 12 mini / 13 mini)
        case "iPhone10,3", "iPhone10,6", // iPhone X
             "iPhone11,2",               // iPhone XS
             "iPhone12,3",               // iPhone 11 Pro
             "iPhone13,1",               // iPhone 12 mini
             "iPhone14,4":               // iPhone 13 mini
            return 2.0
        // Notch — medium inset (XS Max / 11 Pro Max / 12 / 12 Pro / 13 / 13 Pro / 14 / 16e)
        case "iPhone11,4", "iPhone11,6", // iPhone XS Max
             "iPhone12,5",               // iPhone 11 Pro Max
             "iPhone13,2",               // iPhone 12
             "iPhone13,3",               // iPhone 12 Pro
             "iPhone14,5",               // iPhone 13
             "iPhone14,2",               // iPhone 13 Pro
             "iPhone14,7",               // iPhone 14
             "iPhone17,5":               // iPhone 16e
            return 4.0
        // Notch — larger inset (XR / 11 / 12 Pro Max / 13 Pro Max / 14 Plus)
        case "iPhone11,8",               // iPhone XR
             "iPhone12,1",               // iPhone 11
             "iPhone13,4",               // iPhone 12 Pro Max
             "iPhone14,3",               // iPhone 13 Pro Max
             "iPhone14,8":               // iPhone 14 Plus
            return 6.0
        // Dynamic Island — standard (14 Pro / 15 / 15 Pro / 16)
        case "iPhone15,2",               // iPhone 14 Pro
             "iPhone15,4",               // iPhone 15
             "iPhone16,1",               // iPhone 15 Pro
             "iPhone17,3":               // iPhone 16
            return 18.0
        // Dynamic Island — plus/max (14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus)
        case "iPhone15,3",               // iPhone 14 Pro Max
             "iPhone15,5",               // iPhone 15 Plus
             "iPhone16,2",               // iPhone 15 Pro Max
             "iPhone17,4":               // iPhone 16 Plus
            return 19.0
        // Dynamic Island — 16 Pro / 17 / 17 Pro
        case "iPhone17,1",               // iPhone 16 Pro
             "iPhone18,3",               // iPhone 17
             "iPhone18,1":               // iPhone 17 Pro
            return 21.0
        // Dynamic Island — 16 Pro Max / 17 Pro Max / Air
        case "iPhone17,2",               // iPhone 16 Pro Max
             "iPhone18,4",               // iPhone 17 Pro Max
             "iPhone18,2":               // iPhone Air
            return 22.0
        default:
            return 0.0
        }
    }

    private static func machineIdentifier() -> String {
        // On the simulator uname() returns the host arch, so prefer the simulated
        // device identifier exposed via the environment.
        if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simModel
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier
    }
}
