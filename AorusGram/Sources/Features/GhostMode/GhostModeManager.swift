import Foundation
import ObjectiveC

// Ghost Mode: blocks outgoing online presence, read receipts, and typing indicators.
// Works via two complementary layers:
//   1. MTRequestMessageService ObjC swizzle — intercepts serialised MTProto requests
//      BEFORE they leave the process and drops ghost-mode-irrelevant ones.
//   2. UserDefaults flag "aorusgram_ghost_mode" — read by branding.py-injected guards
//      inside AccountStateManager / AccountPresenceManager source patches.
final class GhostModeManager {
    static let shared = GhostModeManager()
    private init() {}

    private(set) var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "aorusgram_ghost_mode")
            NotificationCenter.default.post(name: .ghostModeChanged, object: isEnabled)
        }
    }

    private(set) var hideLastSeen: Bool = true
    private(set) var blockReadReceipts: Bool = true
    private(set) var hidePeekStatus: Bool = true

    func load() {
        isEnabled = UserDefaults.standard.bool(forKey: "aorusgram_ghost_mode")
    }

    func toggle() { setEnabled(!isEnabled) }

    func setEnabled(_ value: Bool) { isEnabled = value }

    func configure(hideLastSeen: Bool, blockReadReceipts: Bool, hidePeekStatus: Bool) {
        self.hideLastSeen = hideLastSeen
        self.blockReadReceipts = blockReadReceipts
        self.hidePeekStatus = hidePeekStatus
        UserDefaults.standard.set(hideLastSeen,     forKey: "aorusgram_ghost_hide_last_seen")
        UserDefaults.standard.set(blockReadReceipts, forKey: "aorusgram_ghost_block_read")
        UserDefaults.standard.set(hidePeekStatus,   forKey: "aorusgram_ghost_hide_typing")
    }

    func shouldSendOnlinePresence() -> Bool  { !isEnabled }
    func shouldSendReadReceipt(peerId: Int64) -> Bool {
        guard isEnabled else { return true }
        return !UserDefaults.standard.bool(forKey: "aorusgram_ghost_block_read")
    }
    func shouldSendTypingIndicator() -> Bool {
        guard isEnabled else { return true }
        return !UserDefaults.standard.bool(forKey: "aorusgram_ghost_hide_typing")
    }
}

extension Notification.Name {
    static let ghostModeChanged = Notification.Name("aorusgram_ghost_mode_changed")
}

// MARK: - MTProto-level request interceptor (ObjC runtime — works because MtProtoKit is ObjC)

// TL constructor IDs for requests blocked in ghost mode (little-endian UInt32 matching TL schema):
//   account.updateStatus  #6628562c
//   messages.setTyping    #58943ee2
//   messages.readHistory  #0e306d3a  (older clients)
//   messages.readMessageContents #36a73f77
private let kGhostBlockedConstructors: Set<UInt32> = [
    0x6628562c,
    0x58943ee2,
    0x0e306d3a,
    0x36a73f77,
]

// NSObject category installed on MTRequestMessageService at runtime.
// After swizzle:
//   MTRequestMessageService.addRequest:  →  _aorusGhost_addRequest:  (our code below)
//   NSObject._aorusGhost_addRequest:     →  original addRequest: implementation
// Calling self._aorusGhost_addRequest() from inside _aorusGhost_addRequest therefore
// calls the original — the standard ObjC swizzle-with-call-through pattern.
// Ghost-mode keywords in the class name / description of MTRequest body objects.
// MtProtoKit TL-generated ObjC classes follow patterns like:
//   TL_account_updateStatus, TLaccount_updateStatus, Api_functions_account_updateStatus
// Swift-generated wrappers bridged to ObjC may have mangled names containing:
//   "updateStatus", "setTyping", "readHistory", "readMessageContents"
private let kGhostBlockedKeywords: [String] = [
    "updateStatus",       // account.updateStatus  — online/offline
    "setTyping",          // messages.setTyping    — typing indicator
    "readHistory",        // messages.readHistory  — read receipts (older API)
    "readMessageContents",// messages.readMessageContents
]

private extension NSObject {
    @objc func _aorusGhost_addRequest(_ request: AnyObject) {
        if UserDefaults.standard.bool(forKey: "aorusgram_ghost_mode") {
            // Layer 1: inspect body class name (MtProtoKit ObjC TL-generated classes)
            if let body = request.value(forKey: "body") {
                let className = NSStringFromClass(type(of: body as AnyObject))
                if kGhostBlockedKeywords.contains(where: { className.contains($0) }) {
                    return
                }
                // Layer 2: check description (catches Swift-bridged types)
                let desc = (body as AnyObject).description
                if kGhostBlockedKeywords.contains(where: { desc.contains($0) }) {
                    return
                }
            }
            // Layer 3: try binary TL constructor ID in body bytes (multiple property names)
            let byteKeys = ["bodyData", "payload", "data", "rawData", "serializedData"]
            for key in byteKeys {
                if let d = request.value(forKey: key) as? Data, d.count >= 4 {
                    let c = d.withUnsafeBytes { $0.load(as: UInt32.self) }
                    if kGhostBlockedConstructors.contains(c) { return }
                    break
                }
            }
        }
        self._aorusGhost_addRequest(request) // call original
    }
}

final class GhostModeSwizzler {
    static func apply() {
        guard let cls = NSClassFromString("MTRequestMessageService") else {
            print("[GhostMode] MTRequestMessageService not found — MTProto layer swizzle skipped")
            return
        }
        let original   = NSSelectorFromString("addRequest:")
        let replacement = #selector(NSObject._aorusGhost_addRequest(_:))

        guard
            let origMethod = class_getInstanceMethod(cls, original),
            let repMethod  = class_getInstanceMethod(NSObject.self, replacement)
        else { return }

        // Install our method on the target class, then swap implementations.
        let added = class_addMethod(cls, replacement,
                                    method_getImplementation(repMethod),
                                    method_getTypeEncoding(repMethod))
        if added {
            guard let installed = class_getInstanceMethod(cls, replacement) else { return }
            method_exchangeImplementations(origMethod, installed)
            print("[GhostMode] MTRequestMessageService.addRequest swizzled — presence/typing/read blocked")
        } else {
            method_exchangeImplementations(origMethod, repMethod)
        }
    }
}
