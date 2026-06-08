import Foundation

// MARK: - AorusTamperAccumulator
//
// Distributed soft-check accumulator.  Many lightweight inline checks across
// the codebase call increment() when they notice a suspicious condition.
// No single call-site is the definitive gate — an attacker who patches out
// one check still trips the others.
//
// Once the threshold is reached the reaction is:
//   1. Delayed by a random 3–9 s interval so it is not causally linked to any
//      particular patched instruction.
//   2. Sets _ag_frida in UserDefaults AND AorusTamperGuard.isFridaDetected so
//      all existing proxy gates trip on the next request.
//
// The running count is persisted in UserDefaults under an opaque UUID key so
// it survives process restarts (a patched app re-launched still accumulates
// from where it left off).

final class AorusTamperAccumulator {
    static let shared = AorusTamperAccumulator()
    private init() { _count = max(0, UserDefaults.standard.integer(forKey: udKey)) }

    // Opaque key — UUID format, no semantic name in the binary.
    private let udKey = "d4b9e2f1-8c3a-4d7f-b2e5-1a9c6f4b8e2d"
    private let threshold = 3
    private var _count: Int
    private let lock = NSLock()
    private var reactionScheduled = false

    // MARK: - API

    func increment() {
        lock.lock()
        _count += 1
        let c = _count
        let alreadyArmed = reactionScheduled
        if c >= threshold { reactionScheduled = true }
        lock.unlock()

        UserDefaults.standard.set(c, forKey: udKey)

        guard c >= threshold && !alreadyArmed else { return }
        let delay = Double.random(in: 3...9)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UserDefaults.standard.set(true, forKey: "_ag_frida")
            AorusTamperGuard.isFridaDetected = true
        }
    }

    var isTripped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _count >= threshold
    }

    // Called by AorusGramBootstrap on every clean launch so a repacked IPA
    // can't accumulate across installs; only within a single session.
    func resetForCleanLaunch() {
        lock.lock(); _count = 0; reactionScheduled = false; lock.unlock()
        UserDefaults.standard.removeObject(forKey: udKey)
    }
}
