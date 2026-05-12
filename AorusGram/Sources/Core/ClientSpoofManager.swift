import Foundation
import UIKit
import ObjectiveC

// Патчит MTApiEnvironment так чтобы initConnection выглядел как официальный Telegram iOS.
//
// ЧТО МЕНЯЕТСЯ:
//   app_version  "AorusGram 1.0" → "11.5.3"  (поле отображается в Активных сессиях)
//   lang_pack    ""              → "ios"       (идентификатор пакета локализации)
//
// ЧТО НЕ ТРОГАЕТСЯ (интернет не ломается):
//   api_id       34110820        — НЕ МЕНЯЕТСЯ, нужен для MTProto-авторизации
//   api_hash                     — НЕ МЕНЯЕТСЯ
//   device_model                 — уже реальный iPhone
//   system_version               — уже реальная iOS версия
//
// Зачем это нужно:
//   Боты типа @userinfobot и некоторые сервисы читают поле app_version из initConnection.
//   Если там "AorusGram 1.0" — помечают как "unofficial client".
//   После спуфинга в "Активных сессиях" будет видно "Telegram 11.5.3" вместо "AorusGram".
public final class ClientSpoofManager {
    public static let shared = ClientSpoofManager()
    private init() {}

    // Синхронизировать с текущей версией Telegram в App Store при каждом обновлении.
    public static let officialAppVersion = "11.5.3"
    public static let officialLangPack   = "ios"

    // MARK: - Swizzle (главный механизм)
    //
    // Свиззлим getter -appVersion и -langPack на MTApiEnvironment.
    // MTApiEnvironment — ObjC-класс внутри MtProtoKit, поэтому runtime-свиззл работает.
    // Вызывается из AorusGramBootstrap.setup() ДО любого сетевого соединения.

    public static func applySwizzle() {
        guard let cls = NSClassFromString("MTApiEnvironment") else {
            print("[AorusSpoof] MTApiEnvironment not found — runtime spoof skipped")
            return
        }
        swizzleSelector(
            cls: cls,
            original: NSSelectorFromString("appVersion"),
            replacement: #selector(spoofed_appVersion)
        )
        swizzleSelector(
            cls: cls,
            original: NSSelectorFromString("langPack"),
            replacement: #selector(spoofed_langPack)
        )
        print("[AorusSpoof] MTApiEnvironment patched — client presents as Telegram \(officialAppVersion)")
    }

    private static func swizzleSelector(cls: AnyClass, original: Selector, replacement: Selector) {
        guard
            let orig = class_getInstanceMethod(cls, original),
            let rep  = class_getInstanceMethod(ClientSpoofManager.self, replacement)
        else { return }
        method_exchangeImplementations(orig, rep)
    }

    @objc private func spoofed_appVersion() -> String { ClientSpoofManager.officialAppVersion }
    @objc private func spoofed_langPack()   -> String { ClientSpoofManager.officialLangPack   }

    // MARK: - KVC-patch (дополнительный, вызывается из AppDelegate через aorus_branding.py)
    //
    // На случай если свиззл не сработал (другая архитектура MTProtoKit).
    // aorus_branding.py инжектирует вызов: ClientSpoofManager.shared.applyToEnvironment(env)

    public func applyToEnvironment(_ env: NSObject) {
        env.setValue(ClientSpoofManager.officialAppVersion, forKey: "appVersion")
        env.setValue(ClientSpoofManager.officialLangPack,   forKey: "langPack")
    }
}
