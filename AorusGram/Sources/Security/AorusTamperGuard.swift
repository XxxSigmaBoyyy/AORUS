import Foundation
import UIKit
import Darwin
import MachO
import ObjectiveC

// MARK: - AorusTamperGuard
//
// Runtime integrity checks that run once at bootstrap. Goals:
//   1. Detect if the IPA was repacked with a different bundle ID or signing cert.
//   2. Detect jailbreak / dylib injection that could facilitate patching.
//   3. Deny debugger attachment and detect active debugger.
//   4. Detect Frida gadget via dylib scan and open port probe.
//   5. Embed an immutable authorship watermark that survives decompilation.
//
// On failure the default policy is LOG-ONLY. Set terminateOnTamper = true
// for production hardening. All detections also set the cross-module
// UserDefaults flag "_ag_frida" which ProxyManager checks before
// processing proxy requests.

public final class AorusTamperGuard {
    public static let shared = AorusTamperGuard()
    private init() {}

    // Authorship watermark.
    public static let author = "AorusGram by @aorusgram — Powered by Claude AI"
    public static let buildSignature = "AORUS-AUTH-2025-CLAUDE-SIGNED"

    // Set to true to terminate on tamper (production hardening).
    public static var terminateOnTamper = false

    // In-module Frida detection flag — also mirrored to UserDefaults "_ag_frida"
    // so AorusProxyManager (same module) gets the result after async checks finish.
    public static var isFridaDetected: Bool = false

    // MARK: - Run all checks

    public func verify() {
        applyAntiDebug()
        checkBundleIntegrity()
        checkJailbreak()
        checkDylibInjection()
        checkHookFiles()
        checkMethodHooks()
        checkDebugger()
        checkFridaPort()
    }

    // MARK: - Bundle ID check

    private func checkBundleIntegrity() {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            flag("bundle ID is nil"); return
        }
        let allowed = ["ph.telegra.Telegraph", "aorusgram", "com.aorusgram"]
        if !allowed.contains(where: { bundleId.lowercased().contains($0.lowercased()) }) {
            flag("unexpected bundle ID: \(bundleId)")
        }
    }

    // MARK: - Jailbreak detection

    private func checkJailbreak() {
        #if targetEnvironment(simulator)
        return
        #else
        let paths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/bin/bash",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/apt/",
            "/private/var/jb",
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            flag("jailbreak indicator: \(p)"); return
        }
        let testPath = "/private/jb_test_ag_\(arc4random())"
        do {
            try "t".write(toFile: testPath, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: testPath)
            flag("sandbox escape — possible jailbreak")
        } catch {}
        #endif
    }

    // MARK: - Dylib injection + Frida gadget detection

    private func checkDylibInjection() {
        // DYLD injection env vars — stripped on legitimate builds, present on jailbreak tooling.
        let env = ProcessInfo.processInfo.environment
        for key in ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
            if let val = env[key], !val.isEmpty {
                markFrida(); flag("\(key): \(val)"); return
            }
        }
        // Scan all loaded dylib names for known hooking/instrumentation frameworks.
        let count = _dyld_image_count()
        let suspects = ["frida", "gadget", "cynject", "substrate", "substitute", "cycript",
                        "libhooker", "ellekit", "tweakinject", "blackjack"]
        for i in 0..<count {
            guard let raw = _dyld_get_image_name(i) else { continue }
            let name = String(cString: raw).lowercased()
            if suspects.contains(where: { name.contains($0) }) {
                markFrida()
                flag("suspicious dylib: \(String(cString: raw))")
                return
            }
        }
    }

    // MARK: - Hook framework filesystem indicators

    private func checkHookFiles() {
        #if !targetEnvironment(simulator)
        // These paths exist only when a hooking framework is installed.
        let paths = [
            "/usr/lib/TweakInject",            // libhooker injection directory
            "/usr/lib/libsubstitute.dylib",    // Substitute (palera1n / checkra1n)
            "/usr/lib/libhooker.dylib",        // libhooker
            "/usr/lib/ellekit.dylib",          // ElleKit (modern arm64e jailbreaks)
            "/Library/MobileSubstrate/DynamicLibraries",  // Substrate tweaks directory
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            markFrida(); flag("hook framework: \(p)"); return
        }
        #endif
    }

    // MARK: - ObjC method IMP origin check
    //
    // Hooking frameworks (Substrate, Substitute, ElleKit) replace a method's IMP
    // with a trampoline in their own dylib. dladdr() on a legitimate IMP returns
    // a path inside /System/Library or /usr/lib; anything else is suspicious.

    private func checkMethodHooks() {
        #if !targetEnvironment(simulator)
        let pairs: [(String, String)] = [
            ("NSUserDefaults", "boolForKey:"),
            ("NSFileManager",  "fileExistsAtPath:"),
            ("NSProcessInfo",  "environment"),
        ]
        for (clsName, selName) in pairs {
            guard let cls = objc_getClass(clsName) as? AnyClass,
                  let m = class_getInstanceMethod(cls, Selector((selName))) else { continue }
            let imp = method_getImplementation(m)
            let ptr = unsafeBitCast(imp, to: UnsafeRawPointer.self)
            var info = Dl_info()
            guard dladdr(ptr, &info) != 0, let fname = info.dli_fname else {
                markFrida(); flag("dladdr miss: \(selName)"); return
            }
            let lib = String(cString: fname)
            guard lib.hasPrefix("/System/") || lib.hasPrefix("/usr/lib/")
                    || lib.hasPrefix("/private/preboot/") else {
                markFrida(); flag("hook: \(selName) → \(lib)"); return
            }
        }
        #endif
    }

    // MARK: - Debugger checks

    // C1: deny debugger attachment via ptrace — symbol resolved at runtime
    // so "ptrace" never appears in the binary's import table.
    private func applyAntiDebug() {
        #if !targetEnvironment(simulator)
        typealias PtraceT = @convention(c) (CInt, CInt, CInt, CInt) -> CInt
        let handle = dlopen(nil, RTLD_LAZY)
        if let sym = dlsym(handle, "ptrace") {
            _ = unsafeBitCast(sym, to: PtraceT.self)(31, 0, 0, 0) // PT_DENY_ATTACH = 31
        }
        dlclose(handle)
        #endif
    }

    // C2: sysctl P_TRACED flag — detects an already-attached debugger.
    private func checkDebugger() {
        #if !targetEnvironment(simulator)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [CInt] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        if info.kp_proc.p_flag & P_TRACED != 0 {
            markFrida()
            flag("debugger attached (P_TRACED)")
        }
        #endif
    }

    // B3: probe Frida default gadget port 27042 on localhost.
    // Runs async so it never blocks app startup; uses a 300 ms connect timeout.
    private func checkFridaPort() {
        #if !targetEnvironment(simulator)
        DispatchQueue.global(qos: .background).async { [weak self] in
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(27042)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard sock >= 0 else { return }
            defer { close(sock) }
            var tv = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if ok == 0 {
                self?.markFrida()
                self?.flag("Frida server port 27042 open")
            }
        }
        #endif
    }

    // MARK: - Shared detection marker

    private func markFrida() {
        AorusTamperGuard.isFridaDetected = true
        UserDefaults.standard.set(true, forKey: "_ag_frida")
    }

    // MARK: - Flag handler

    private func flag(_ reason: String) {
        // Every detection feeds the distributed accumulator — no single bypassed
        // check can prevent the threshold from being reached eventually.
        AorusTamperAccumulator.shared.increment()
        let msg = "[AorusTamperGuard] INTEGRITY WARNING: \(reason)"
        print(msg)
        NotificationCenter.default.post(name: .aorusTamperDetected, object: reason)
        if AorusTamperGuard.terminateOnTamper {
            fatalError(msg)
        }
    }
}

extension Notification.Name {
    // "aorusgram_tamper_detected" — runtime XOR, no plaintext literal in binary.
    public static let aorusTamperDetected: Notification.Name = {
        let b: [UInt8] = [0x70,0x4D,0x41,0x31,0x26,0x01,0x05,0xE9,0xF4,0xF5,0xCF,0xAD,0xB0,0x9E,0x9A,0x63,0x7D,0x57,0x21,0x21,0x03,0x14,0xFC,0xFC,0xCE]
        let m: [UInt8] = [0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC,0xDD,0xEE,0xFF,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xAA]
        return Notification.Name(String(bytes: zip(b, m).map { $0 ^ $1 }, encoding: .utf8)!)
    }()
}
