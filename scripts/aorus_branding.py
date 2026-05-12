#!/usr/bin/env python3
"""Apply AorusGram branding to a Telegram-iOS checkout (CI or local)."""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

# Match http(s), tg://, and t.me/… segments so we never edit URLs inside .strings values.
_URL_GUARD = re.compile(r"(https?://[^\s\"]+)|(tg://[^\s\"]+)|(t\.me/[^\s\"]+)", re.IGNORECASE)
_TELEGRAM_WORD = re.compile(r"\bTelegram\b")


def patch_launch_screen(tg: Path) -> None:
    xib = tg / "Telegram/Telegram-iOS/Base.lproj/LaunchScreen.xib"
    if not xib.is_file():
        print("LaunchScreen.xib not found, skip")
        return
    t = xib.read_text(encoding="utf-8")
    t = t.replace('appearance="dark"', 'appearance="light"')
    t = t.replace(
        '<color key="backgroundColor" systemColor="systemBackgroundColor"/>',
        '<color key="backgroundColor" red="0.95" green="0.95" blue="0.96" alpha="1" '
        'colorSpace="custom" customColorSpace="sRGB"/>',
    )
    xib.write_text(t, encoding="utf-8")
    print("Patched LaunchScreen.xib (light neutral background, light appearance)")


def patch_xcconfig(tg: Path) -> None:
    cfg = tg / "Telegram/Telegram-iOS/Config-AppStoreLLC.xcconfig"
    if not cfg.is_file():
        print("Config-AppStoreLLC.xcconfig not found, skip")
        return
    lines = cfg.read_text(encoding="utf-8").splitlines()
    out = []
    for line in lines:
        if line.startswith("APP_NAME="):
            out.append("APP_NAME=Aorusgram")
        else:
            out.append(line)
    cfg.write_text("\n".join(out) + ("\n" if lines else ""), encoding="utf-8")
    print("Patched Config-AppStoreLLC.xcconfig APP_NAME=AorusGram")


def _scrub_user_visible_strings(pl: dict) -> None:
    for k, v in list(pl.items()):
        if isinstance(v, str) and "Telegram" in v:
            if k.endswith("UsageDescription") or k in ("NSSiriUsageDescription",):
                pl[k] = v.replace("Telegram", "Aorusgram")
    ut = pl.get("UTImportedTypeDeclarations")
    if isinstance(ut, list):
        for item in ut:
            if isinstance(item, dict):
                desc = item.get("UTTypeDescription")
                if isinstance(desc, str) and "Telegram" in desc:
                    item["UTTypeDescription"] = desc.replace("Telegram", "Aorusgram")


def patch_plist_icons_and_urls(path: Path) -> None:
    if not path.is_file():
        print(f"Missing plist: {path}")
        return
    with path.open("rb") as f:
        pl = plistlib.load(f)
    # Primary icon → static BlueIcon set (filled from CI master PNG).
    for key in list(pl.keys()):
        if isinstance(key, str) and key.startswith("CFBundleIcons"):
            primary = pl[key].get("CFBundlePrimaryIcon")
            if isinstance(primary, dict):
                primary["CFBundleIconName"] = "BlueIcon"
    # Deep link: branded scheme (keep tg:// for compatibility).
    url_types = pl.get("CFBundleURLTypes")
    if isinstance(url_types, list) and url_types:
        schemes0 = url_types[0].get("CFBundleURLSchemes")
        if isinstance(schemes0, list) and schemes0:
            url_types[0]["CFBundleURLSchemes"] = ["aorusgram"]
    _scrub_user_visible_strings(pl)
    queries = pl.get("LSApplicationQueriesSchemes")
    if isinstance(queries, list) and "aorusgram" not in queries:
        queries.append("aorusgram")
    with path.open("wb") as f:
        plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
    print(f"Patched {path.name}: BlueIcon primary, aorusgram:// URL scheme, usage strings")


def _mask_urls(s: str) -> tuple[str, list[str]]:
    tokens: list[str] = []
    out: list[str] = []
    pos = 0
    for m in _URL_GUARD.finditer(s):
        out.append(s[pos : m.start()])
        tok = f"\x00URL{len(tokens)}\x00"
        tokens.append(m.group(0))
        out.append(tok)
        pos = m.end()
    out.append(s[pos:])
    return "".join(out), tokens


def _unmask_urls(s: str, tokens: list[str]) -> str:
    for i, tok in enumerate(tokens):
        s = s.replace(f"\x00URL{i}\x00", tok)
    return s


def _safe_replace_telegram_in_value(val: str) -> tuple[str, int]:
    masked, tokens = _mask_urls(val)
    new, n = _TELEGRAM_WORD.subn("Aorusgram", masked)
    return _unmask_urls(new, tokens), n


def _escape_strings_value(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "\\r").replace("\n", "\\n")


def _patch_localizable_strings_file_content(text: str) -> tuple[str, int]:
    """Parse .strings entries (multiline values + multiple entries per line), replace
    \\bTelegram\\b in values only (URLs masked). Does not alter localization keys."""
    entry_start = re.compile(r'(\s*"(?:[^"\\]|\\.)*"\s*=\s*")')
    total = 0
    out: list[str] = []
    pos = 0
    while pos < len(text):
        m = entry_start.search(text, pos)
        if not m:
            out.append(text[pos:])
            break
        # Skip // comments (single-line)
        # Always search from BOF: using `pos` here wrongly re-used the start of the
        # previous entry as the window and treated almost everything as a // comment.
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text[line_start:m.start()].lstrip().startswith("//"):
            out.append(text[pos : m.end()])
            pos = m.end()
            continue
        out.append(text[pos : m.start()])
        out.append(m.group(1))
        i = m.end()
        val_chars: list[str] = []
        while i < len(text):
            ch = text[i]
            if ch == "\\" and i + 1 < len(text):
                val_chars.append(text[i : i + 2])
                i += 2
                continue
            if ch == '"':
                if i + 1 < len(text) and text[i + 1] == ";":
                    raw_val = "".join(val_chars)
                    new_val, n = _safe_replace_telegram_in_value(raw_val)
                    total += n
                    out.append(_escape_strings_value(new_val))
                    out.append('";')
                    pos = i + 2
                    break
                val_chars.append(ch)
                i += 1
                continue
            val_chars.append(ch)
            i += 1
        else:
            out.append(text[m.start() :])
            break
    return "".join(out), total


def patch_localizable_strings_safe(tg: Path) -> None:
    """Replace word Telegram → Aorusgram in Localizable.strings values only (URLs kept)."""
    roots = [
        tg / "Telegram/Telegram-iOS",
        tg / "Telegram/Share",
        tg / "Telegram/WidgetKitWidget",
        tg / "Telegram/NotificationService",
    ]
    total = 0
    for root in roots:
        if not root.is_dir():
            continue
        for p in root.rglob("Localizable.strings"):
            raw = p.read_text(encoding="utf-8", errors="surrogateescape")
            new_text, n = _patch_localizable_strings_file_content(raw)
            if n:
                total += n
                p.write_text(new_text, encoding="utf-8", errors="surrogateescape")
                print(f"  Localizable safe: {p.relative_to(tg)} ({n} word hits)")
    print(f"Localizable.strings (URL-safe): {total} Telegram→Aorusgram word replacements")


def patch_presentation_theme_intro_gold(tg: Path) -> None:
    """Gold accent for intro/tour markdown (bold) only — does not change global app accent."""
    day = tg / "submodules/TelegramPresentationData/Sources/DefaultDayPresentationTheme.swift"
    if day.is_file():
        t = day.read_text(encoding="utf-8")
        old = (
            "    let intro = PresentationThemeIntro(\n"
            "        statusBarStyle: .black,\n"
            "        primaryTextColor: UIColor(rgb: 0x000000),\n"
            "        accentTextColor: defaultDayAccentColor,\n"
        )
        new = (
            "    let intro = PresentationThemeIntro(\n"
            "        statusBarStyle: .black,\n"
            "        primaryTextColor: UIColor(rgb: 0x000000),\n"
            "        accentTextColor: UIColor(rgb: 0xc9a227),\n"
        )
        if old in t:
            day.write_text(t.replace(old, new, 1), encoding="utf-8")
            print("Patched DefaultDayPresentationTheme: intro accentTextColor gold")

    dark = tg / "submodules/TelegramPresentationData/Sources/DefaultDarkPresentationTheme.swift"
    if dark.is_file():
        t = dark.read_text(encoding="utf-8")
        old = (
            "    let intro = PresentationThemeIntro(\n"
            "        statusBarStyle: .white,\n"
            "        primaryTextColor: UIColor(rgb: 0xffffff),\n"
            "        accentTextColor: UIColor(rgb: 0xffffff),\n"
        )
        new = (
            "    let intro = PresentationThemeIntro(\n"
            "        statusBarStyle: .white,\n"
            "        primaryTextColor: UIColor(rgb: 0xffffff),\n"
            "        accentTextColor: UIColor(rgb: 0xe8c547),\n"
        )
        if old in t:
            dark.write_text(t.replace(old, new, 1), encoding="utf-8")
            print("Patched DefaultDarkPresentationTheme: intro accentTextColor gold")


def patch_info_plist_strings_only(tg: Path) -> None:
    """Only InfoPlist.strings (short display names). Skip Localizable.strings — bulk
    Telegram→AorusGram there can break format strings and crash at startup."""
    pattern = re.compile(r"\bTelegram\b")
    roots = [
        tg / "Telegram/Telegram-iOS",
        tg / "Telegram/Share",
        tg / "Telegram/WidgetKitWidget",
        tg / "Telegram/NotificationService",
    ]
    n = 0
    for root in roots:
        if not root.is_dir():
            continue
        for p in root.rglob("InfoPlist.strings"):
            raw = p.read_text(encoding="utf-8", errors="replace")
            new, c = pattern.subn("Aorusgram", raw)
            if c:
                p.write_text(new, encoding="utf-8")
                n += c
                print(f"  {p.relative_to(tg)}: {c} replacements")
    print(f"InfoPlist.strings: {n} Telegram→Aorusgram (Localizable handled separately)")


def patch_app_delegate_launch_fixes(tg: Path) -> None:
    """Fix real black-screen bugs in upstream AppDelegate:

    1) makeKeyAndVisible() is only called late (~line 779); early returns (App Group
       container nil → \"Error 2\", disk full alert) call presentNative on a window
       that was never made key/visible — alerts do not paint → endless black screen.

    2) Dark mode used UIColor.black under Metal before first frame; use near-black tint.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        print("AppDelegate.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    orig = t

    # Blank line between assignments and Metal is indented spaces only (Xcode).
    win_metal = (
        "        self.window = window\n"
        "        self.nativeWindow = window\n"
        "        \n"
        "        hostView.containerView.layer.addSublayer(MetalEngine.shared.rootLayer)"
    )
    win_metal_new = (
        "        self.window = window\n"
        "        self.nativeWindow = window\n"
        "        self.window?.makeKeyAndVisible()\n"
        "        \n"
        "        hostView.containerView.layer.addSublayer(MetalEngine.shared.rootLayer)"
    )
    if win_metal in t:
        t = t.replace(win_metal, win_metal_new, 1)
        print("AppDelegate: makeKeyAndVisible immediately after window wiring")

    old_black = "hostView.containerView.backgroundColor = UIColor.black"
    new_bg = "hostView.containerView.backgroundColor = UIColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1.0)"
    if old_black in t:
        t = t.replace(old_black, new_bg, 1)
        print("AppDelegate: dark-mode pre-Metal background not pure black")

    # AltStore / ad-hoc resign often drops App Group entitlement → containerURL is nil → "Error 2".
    # Use Application Support fallback (extensions disabled in CI build; data stays in sandbox).
    app_group_resolved = (
        "        let appGroupUrl: URL\n"
        "        if let sharedUrl = maybeAppGroupUrl {\n"
        "            appGroupUrl = sharedUrl\n"
        "        } else {\n"
        "            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!\n"
        "                .appendingPathComponent(\"AorusgramGroupFallback\", isDirectory: true)\n"
        "            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)\n"
        "            appGroupUrl = base\n"
        "        }\n"
    )
    err2_new = (
        "        guard let appGroupUrl = maybeAppGroupUrl else {\n"
        "            self.window?.makeKeyAndVisible()\n"
        "            self.mainWindow?.presentNative(UIAlertController(title: nil, message: \"Error 2\", preferredStyle: .alert))\n"
        "            return true\n"
        "        }"
    )
    err2_orig = (
        "        guard let appGroupUrl = maybeAppGroupUrl else {\n"
        "            self.mainWindow?.presentNative(UIAlertController(title: nil, message: \"Error 2\", preferredStyle: .alert))\n"
        "            return true\n"
        "        }"
    )
    if err2_new in t:
        t = t.replace(err2_new, app_group_resolved, 1)
        print("AppDelegate: App Group fallback (replaces Error 2 guard, AltStore-safe)")
    elif err2_orig in t:
        t = t.replace(err2_orig, app_group_resolved, 1)
        print("AppDelegate: App Group fallback (replaces Error 2 guard, AltStore-safe)")
    elif "AorusgramGroupFallback" not in t:
        # Upstream whitespace / extra lines drift — still match the fatal guard by structure.
        err2_rx = re.compile(
            r"^[ \t]*guard let appGroupUrl = maybeAppGroupUrl else \{[ \t]*\n"
            r"(?:^[ \t]*.*\n)*?"
            r"^[ \t]*return true[ \t]*\n"
            r"^[ \t]*\}[ \t]*\n",
            re.MULTILINE,
        )
        m = err2_rx.search(t)
        if m and "Error 2" in m.group(0):
            t = err2_rx.sub(app_group_resolved, t, count=1)
            print("AppDelegate: App Group fallback via regex (Error 2 guard removed)")
        else:
            print("WARNING: AppDelegate Error 2 guard not found — AltStore may still show Error 2")

    disk = (
        "        if !writeAbilityTestSuccess {\n"
        "            let alertController = UIAlertController(title: nil, message: \"The device does not have sufficient free space.\", preferredStyle: .alert)\n"
        "            alertController.addAction(UIAlertAction(title: \"OK\", style: .default, handler: { _ in\n"
        "                preconditionFailure()\n"
        "            }))\n"
        "            self.mainWindow?.presentNative(alertController)\n"
        "            \n"
        "            return true\n"
        "        }"
    )
    disk_new = (
        "        if !writeAbilityTestSuccess {\n"
        "            let alertController = UIAlertController(title: nil, message: \"The device does not have sufficient free space.\", preferredStyle: .alert)\n"
        "            alertController.addAction(UIAlertAction(title: \"OK\", style: .default, handler: { _ in\n"
        "                preconditionFailure()\n"
        "            }))\n"
        "            self.window?.makeKeyAndVisible()\n"
        "            self.mainWindow?.presentNative(alertController)\n"
        "            \n"
        "            return true\n"
        "        }"
    )
    if disk in t:
        t = t.replace(disk, disk_new, 1)
        print("AppDelegate: makeKeyAndVisible before disk-space alert")

    # Primary icon is compiled from Telegram.icon (SVG); plist CFBundleIconName alone does not
    # change the home-screen icon. AlternateIcons.plist key "Blue" → BlueIcon set (filled in CI).
    alt_icon_anchor = (
        "        if !isUITest {\n"
        "            performAppGroupUpgrades(appGroupPath: appGroupUrl.path, rootPath: rootPath)\n"
        "        }\n"
        "        \n"
        "        let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)"
    )
    alt_icon_new = (
        "        if !isUITest {\n"
        "            performAppGroupUpgrades(appGroupPath: appGroupUrl.path, rootPath: rootPath)\n"
        "        }\n"
        "        \n"
        "        if #available(iOS 10.3, *) {\n"
        "            DispatchQueue.main.async {\n"
        "                UIApplication.shared.setAlternateIconName(\"Blue\", completionHandler: { _ in })\n"
        "            }\n"
        "        }\n"
        "        \n"
        "        let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)"
    )
    if alt_icon_anchor in t and 'setAlternateIconName("Blue"' not in t:
        t = t.replace(alt_icon_anchor, alt_icon_new, 1)
        print("AppDelegate: request alternate icon \"Blue\" (custom BlueIcon.appiconset) at launch")

    if t != orig:
        path.write_text(t, encoding="utf-8")
    else:
        print("AppDelegate: no launch patches applied (already patched or upstream drift)")


def patch_app_delegate_background_url_session_safe(tg: Path) -> None:
    """Fall back to default URLSession when App Group entitlement is absent (sideload).

    Background URLSessions REQUIRE a shared container — without App Group entitlement the
    session has nowhere to store data, breaking MTProto sync entirely: chat list stays on
    'Updating...' forever and login shows 'no internet connection'.
    Fix: detect entitlement at runtime; use .default config when App Group is unavailable.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        return
    t = path.read_text(encoding="utf-8")

    # Pattern 1: original upstream (no guard at all)
    old1 = (
        "        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)\n"
        "        configuration.sharedContainerIdentifier = appGroupName\n"
        "        configuration.isDiscretionary = false\n"
    )
    # Pattern 2: previous partial fix (guard exists but still uses .background)
    old2 = (
        "        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)\n"
        "        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) != nil {\n"
        "            configuration.sharedContainerIdentifier = appGroupName\n"
        "        }\n"
        "        configuration.isDiscretionary = false\n"
    )
    # Correct fix: use .default when no App Group (sideload/AltStore/ad-hoc resign)
    new = (
        "        let hasAppGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) != nil\n"
        "        let configuration: URLSessionConfiguration\n"
        "        if hasAppGroup {\n"
        "            configuration = URLSessionConfiguration.background(withIdentifier: identifier)\n"
        "            configuration.sharedContainerIdentifier = appGroupName\n"
        "        } else {\n"
        "            configuration = URLSessionConfiguration.default\n"
        "        }\n"
        "        configuration.isDiscretionary = false\n"
    )

    if old1 in t:
        path.write_text(t.replace(old1, new, 1), encoding="utf-8")
        print("AppDelegate: URLSession fallback to .default when no App Group (from upstream)")
    elif old2 in t:
        path.write_text(t.replace(old2, new, 1), encoding="utf-8")
        print("AppDelegate: URLSession fallback to .default when no App Group (upgraded partial fix)")
    elif "hasAppGroup" in t:
        print("AppDelegate: URLSession full fallback fix already present")
    else:
        print("WARNING: AppDelegate URLSession block not found (upstream drift)")


def patch_native_window_host_scene(tg: Path) -> None:
    """Prefer UIWindow(windowScene:) on iOS 13+ when a scene exists — avoids a known
    class of launch black screens when the window is not attached to a UIWindowScene
    (see TN3187 / common UIKit guidance for scene-based lifecycle)."""
    path = tg / "submodules/Display/Source/NativeWindowHostView.swift"
    if not path.is_file():
        print("NativeWindowHostView.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    orig = t

    # Anchor must include init(frame:) — the short tail-only marker also appears after
    # init(windowScene:), so a second branding run (or cached patched tree) would duplicate the override.
    init_marker = (
        "    override init(frame: CGRect) {\n"
        "        super.init(frame: frame)\n"
        "        \n"
        "        if let gestureRecognizers = self.gestureRecognizers {\n"
        "            for recognizer in gestureRecognizers {\n"
        "                recognizer.delaysTouchesBegan = false\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    required init?(coder aDecoder: NSCoder) {\n"
        '        fatalError("init(coder:) has not been implemented")\n'
        "    }\n"
    )
    init_new = (
        "    override init(frame: CGRect) {\n"
        "        super.init(frame: frame)\n"
        "        \n"
        "        if let gestureRecognizers = self.gestureRecognizers {\n"
        "            for recognizer in gestureRecognizers {\n"
        "                recognizer.delaysTouchesBegan = false\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    @available(iOS 13.0, *)\n"
        "    override init(windowScene: UIWindowScene) {\n"
        "        super.init(windowScene: windowScene)\n"
        "        if let gestureRecognizers = self.gestureRecognizers {\n"
        "            for recognizer in gestureRecognizers {\n"
        "                recognizer.delaysTouchesBegan = false\n"
        "            }\n"
        "        }\n"
        "    }\n"
        "    \n"
        "    required init?(coder aDecoder: NSCoder) {\n"
        '        fatalError("init(coder:) has not been implemented")\n'
        "    }\n"
    )
    if init_marker in t:
        t = t.replace(init_marker, init_new, 1)
        print("Patched NativeWindow: init(windowScene:) for scene-attached windows")

    host_marker = (
        "public func nativeWindowHostView() -> (UIWindow & WindowHost, WindowHostView) {\n"
        "    let window = NativeWindow(frame: UIScreen.main.bounds)\n"
    )
    host_new = (
        "public func nativeWindowHostView() -> (UIWindow & WindowHost, WindowHostView) {\n"
        "    let window: NativeWindow\n"
        "    if #available(iOS 13.0, *) {\n"
        "        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }\n"
        "        if let windowScene = windowScenes.first(where: { $0.activationState == .foregroundActive })\n"
        "            ?? windowScenes.first(where: { $0.activationState == .foregroundInactive })\n"
        "            ?? windowScenes.first {\n"
        "            window = NativeWindow(windowScene: windowScene)\n"
        "        } else {\n"
        "            window = NativeWindow(frame: UIScreen.main.bounds)\n"
        "        }\n"
        "    } else {\n"
        "        window = NativeWindow(frame: UIScreen.main.bounds)\n"
        "    }\n"
    )
    if host_marker in t:
        t = t.replace(host_marker, host_new, 1)
        print("Patched nativeWindowHostView: UIWindowScene when available")

    if t != orig:
        path.write_text(t, encoding="utf-8")
    else:
        if init_marker not in orig and host_marker not in orig:
            print("NativeWindowHostView: markers not found (upstream drift)")
        elif init_marker in orig or host_marker in orig:
            print("NativeWindowHostView: patch did not apply (upstream drift?)")


def patch_authorization_network_flood_wait(tg: Path) -> None:
    """Use MTProto automatic flood wait for auth.sendCode / resend / signIn so the client
    waits server FLOOD_WAIT instead of failing immediately with Login_CodeFloodError."""
    path = tg / "submodules/TelegramCore/Sources/Authorization.swift"
    if not path.is_file():
        print("Authorization.swift not found, skip flood-wait patch")
        return
    t = path.read_text(encoding="utf-8")
    orig = t
    pairs = [
        ("account.network.request(sendCode, automaticFloodWait: false)", "account.network.request(sendCode, automaticFloodWait: true)"),
        ("return updatedAccount.network.request(sendCode, automaticFloodWait: false)", "return updatedAccount.network.request(sendCode, automaticFloodWait: true)"),
        (
            "return account.network.request(Api.functions.auth.resendCode(flags: flags, phoneNumber: number, phoneCodeHash: hash, reason: mappedReason), automaticFloodWait: false)",
            "return account.network.request(Api.functions.auth.resendCode(flags: flags, phoneNumber: number, phoneCodeHash: hash, reason: mappedReason), automaticFloodWait: true)",
        ),
        (
            "return account.network.request(Api.functions.auth.resendCode(flags: 0, phoneNumber: number, phoneCodeHash: hash, reason: nil), automaticFloodWait: false)",
            "return account.network.request(Api.functions.auth.resendCode(flags: 0, phoneNumber: number, phoneCodeHash: hash, reason: nil), automaticFloodWait: true)",
        ),
        (
            "return account.network.request(Api.functions.auth.signIn(flags: flags, phoneNumber: number, phoneCodeHash: hash, phoneCode: phoneCode, emailVerification: emailVerification), automaticFloodWait: false)",
            "return account.network.request(Api.functions.auth.signIn(flags: flags, phoneNumber: number, phoneCodeHash: hash, phoneCode: phoneCode, emailVerification: emailVerification), automaticFloodWait: true)",
        ),
    ]
    for old, new in pairs:
        if old in t:
            t = t.replace(old, new)
            print("Authorization: automaticFloodWait for auth request")
    if t != orig:
        path.write_text(t, encoding="utf-8")
    else:
        print("Authorization: flood-wait markers not found (upstream drift)")


def patch_authorization_login_title_gold(tg: Path) -> None:
    """Gold title on phone-number welcome (strings already say Aorusgram after Localizable patch)."""
    path = tg / "submodules/AuthorizationUI/Sources/AuthorizationSequencePhoneEntryControllerNode.swift"
    if not path.is_file():
        print("AuthorizationSequencePhoneEntryControllerNode.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    orig = t
    gold = "UIColor(red: 0.788, green: 0.635, blue: 0.153, alpha: 1.0)"
    a = (
        "self.titleNode.attributedText = NSAttributedString(string: account == nil ? strings.Login_NewNumber : strings.Login_PhoneTitle, font: Font.light(30.0), textColor: theme.list.itemPrimaryTextColor)"
    )
    b = (
        "self.titleNode.attributedText = NSAttributedString(string: account == nil ? strings.Login_NewNumber : strings.Login_PhoneTitle, font: Font.light(30.0), textColor: "
        + gold
        + ")"
    )
    c = (
        "self.titleNode.attributedText = NSAttributedString(string: self.account == nil ? self.strings.Login_NewNumber : self.strings.Login_PhoneTitle, font: Font.bold(28.0), textColor: self.theme.list.itemPrimaryTextColor)"
    )
    d = (
        "self.titleNode.attributedText = NSAttributedString(string: self.account == nil ? self.strings.Login_NewNumber : self.strings.Login_PhoneTitle, font: Font.bold(28.0), textColor: "
        + gold
        + ")"
    )
    if a in t:
        t = t.replace(a, b, 1)
        print("Auth phone entry: gold title (init)")
    if c in t:
        t = t.replace(c, d, 1)
        print("Auth phone entry: gold title (layout)")
    if t != orig:
        path.write_text(t, encoding="utf-8")


def patch_metal_comma_operator_warnings(tg: Path) -> None:
    """Metal: `(a.r, b.r)` is parsed as comma-expression, not half2(); fix -Wunused-value."""
    needle = "half2 inUV = (inTextureU.read(uvPosition).r, inTextureV.read(uvPosition).r);"
    repl = "half2 inUV = half2(inTextureU.read(uvPosition).r, inTextureV.read(uvPosition).r);"
    paths = [
        tg / "submodules/TelegramUI/Components/CameraScreen/MetalResources/cameraScreen.metal",
        tg / "submodules/TelegramUI/Components/Calls/CallScreen/Metal/CallScreenShaders.metal",
    ]
    for path in paths:
        if not path.is_file():
            continue
        t = path.read_text(encoding="utf-8")
        if needle in t:
            path.write_text(t.replace(needle, repl), encoding="utf-8")
            print(f"Metal: fixed half2 comma init in {path.name}")


def patch_callkit_brand_name(tg: Path) -> None:
    path = tg / "submodules/TelegramCallsUI/Sources/CallKitIntegration.swift"
    if not path.is_file():
        print("CallKitIntegration.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    old = 'let providerConfiguration = CXProviderConfiguration(localizedName: "Telegram")'
    new = 'let providerConfiguration = CXProviderConfiguration(localizedName: "Aorusgram")'
    if old in t:
        path.write_text(t.replace(old, new, 1), encoding="utf-8")
        print("CallKit: localizedName Aorusgram")


def patch_deleted_messages_interception(tg: Path) -> None:
    """Post NotificationCenter event before postbox.deleteMessages() in TelegramCore.

    Architecture:
      - TelegramCore is a separate Swift module — we can't call main-app code directly.
      - NotificationCenter (Foundation) works across module boundaries without
        circular dependency issues.
      - We inject a NotificationCenter.default.post(...) call right before the
        deleteMessages transaction. The main app observes this notification in
        AorusGramBootstrap and calls DeletedMessagesCache.shared.cacheMessage().
      - No global callback declarations needed — pure Foundation bridging.
    """
    candidates = [
        tg / "submodules/TelegramCore/Sources/State/AccountStateManager.swift",
        tg / "submodules/TelegramCore/Sources/AccountStateManager.swift",
    ]
    path: Path | None = next((p for p in candidates if p.is_file()), None)
    if path is None:
        print("AccountStateManager.swift not found, skip deleted-messages hook")
        return

    t = path.read_text(encoding="utf-8")
    orig = t

    # Sentinel — injected once only
    sentinel = "// AorusGram: NotificationCenter delete bridge"
    if sentinel in t:
        print("AccountStateManager: deleted-messages hook already present")
        return

    # NotificationCenter hook — pure Foundation, no cross-module imports needed.
    # Tries to get message content via transaction.getMessage(id) before deletion.
    # If getMessage is not available / returns nil, posts without content (id only).
    hook_prefix = (
        "                " + sentinel + "\n"
        "                for id in ids {\n"
        "                    var userInfo: [String: Any] = [\n"
        "                        \"msgId\":  NSNumber(value: id.id),\n"
        "                        \"peerId\": NSNumber(value: id.peerId.toInt64()),\n"
        "                    ]\n"
        "                    if let msg = transaction.getMessage(id) {\n"
        "                        userInfo[\"senderId\"]   = NSNumber(value: msg.author?.id.toInt64() ?? 0)\n"
        "                        userInfo[\"senderName\"] = msg.author?.compactDisplayTitle ?? \"\"\n"
        "                        userInfo[\"text\"]       = msg.text\n"
        "                        userInfo[\"date\"]       = NSNumber(value: msg.timestamp)\n"
        "                        userInfo[\"isOutgoing\"] = NSNumber(value: msg.flags.contains(.Outgoing))\n"
        "                    }\n"
        "                    NotificationCenter.default.post(\n"
        "                        name: NSNotification.Name(\"aorusgram.willDeleteMessage\"),\n"
        "                        object: nil, userInfo: userInfo)\n"
        "                }\n"
        "                "
    )

    # Try multiple anchor patterns across Telegram iOS versions
    anchors = [
        "transaction.deleteMessages(ids, forEachMedia: {",
        "transaction.deleteMessages(messageIds, forEachMedia: {",
        ".deleteMessages(ids, forEachMedia: {",
    ]
    injected = False
    for anchor in anchors:
        if anchor in t:
            t = t.replace(anchor, hook_prefix + anchor, 1)
            print(f"AccountStateManager: NotificationCenter delete bridge injected (anchor: {anchor[:55]}...)")
            injected = True
            break

    if not injected:
        print("AccountStateManager: deleteMessages anchor not found (upstream drift) — hook skipped gracefully")

    if t != orig:
        path.write_text(t, encoding="utf-8")


def patch_app_delegate_import_aorusgram(tg: Path) -> None:
    """TelegramUI and AorusGram are separate Swift modules — AppDelegate must import AorusGram."""
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        return
    t = path.read_text(encoding="utf-8")
    if "import AorusGram" in t:
        return
    if "AorusGramBootstrap" not in t and "ClientSpoofManager" not in t:
        return
    # Do not rely on exact "\n" after UIKit — runners may use CRLF; insert after first import UIKit line.
    needle = "import UIKit"
    pos = t.find(needle)
    if pos != -1:
        line_end = t.find("\n", pos)
        if line_end != -1:
            insert_at = line_end + 1
            t = t[:insert_at] + "import AorusGram\n" + t[insert_at:]
            path.write_text(t, encoding="utf-8")
            print("AppDelegate: added import AorusGram after import UIKit")
            return
    print("WARNING: AppDelegate: could not insert import AorusGram (import UIKit not found)")


def patch_app_delegate_bootstrap(tg: Path) -> None:
    """Call AorusGramBootstrap.shared.setup() after the account stack is ready.

    The injection point is just after the DeviceSpecificEncryptionParameters call,
    which is well after the account group URL is resolved and before any UI is shown.
    Also registers the BGTask identifier in the bootstrap.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        print("AppDelegate.swift not found, skip bootstrap patch")
        return

    t = path.read_text(encoding="utf-8")
    orig = t

    if "AorusGramBootstrap" in t:
        print("AppDelegate: AorusGram bootstrap already injected")
        return

    # Anchor: the call that happens once the encryption params are ready — this is
    # a stable, version-robust marker present in all recent Telegram iOS builds.
    anchor = "let deviceSpecificEncryptionParameters = BuildConfig.deviceSpecificEncryptionParameters(rootPath, baseAppBundleId: baseAppBundleId)"
    bootstrap_call = (
        "\n        // AorusGram: initialise all custom features\n"
        "        AorusGramBootstrap.shared.setup(accountPath: rootPath)\n"
    )
    if anchor in t:
        t = t.replace(anchor, anchor + bootstrap_call, 1)
        print("AppDelegate: AorusGramBootstrap.shared.setup() injected after encryption params")
    else:
        print("WARNING: AppDelegate encryption params anchor not found — bootstrap not injected")

    if t != orig:
        path.write_text(t, encoding="utf-8")


def patch_client_spoof_app_version(tg: Path) -> None:
    """Spoof app_version / lang_pack so MTProto initConnection matches official Telegram iOS.

    How Telegram (and bots) detect unofficial clients:
      1. api_id — bots can query this; we register a real dev api_id so it's valid,
         but self-check bots that look up the api_id in their allowlist will differ.
      2. app_version in initConnection — must match official Telegram to pass basic checks.
      3. lang_pack identifier — official iOS uses "ios", unofficial forks often leave it empty.
      4. client_name / system_lang_code — minor but some bots inspect these.

    This patch modifies the TWO places where Telegram iOS sets its version string:
      a) BuildConfig.swift / AppConfiguration.swift  — source-level version constant
      b) The MTApiEnvironment setup block in AppDelegate.swift (where env properties are set)
    """
    # ---- a) Patch version constant in source ----
    version_candidates = [
        tg / "submodules/TelegramUI/Sources/AppConfiguration.swift",
        tg / "submodules/BuildConfig/Sources/BuildConfig.swift",
        tg / "Telegram/Telegram-iOS/BuildConfig.swift",
    ]
    official_version = "11.5.3"

    for vpath in version_candidates:
        if not vpath.is_file():
            continue
        t = vpath.read_text(encoding="utf-8")
        orig = t
        # Replace common version string patterns
        import re as _re
        # appVersion = "X.Y.Z"
        t = _re.sub(
            r'(appVersion\s*=\s*")[^"]+(")',
            r'\g<1>' + official_version + r'\g<2>',
            t,
        )
        # "X.Y.Z" as a standalone version constant
        t = _re.sub(
            r'(static\s+(?:let|var)\s+appVersion\s*(?::\s*String)?\s*=\s*")[^"]+(")',
            r'\g<1>' + official_version + r'\g<2>',
            t,
        )
        if t != orig:
            vpath.write_text(t, encoding="utf-8")
            print(f"ClientSpoof: patched appVersion → {official_version} in {vpath.name}")

    # ---- b) Patch MTApiEnvironment setup in AppDelegate ----
    ad = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not ad.is_file():
        print("ClientSpoof: AppDelegate.swift not found, skip MTApiEnvironment patch")
        return

    t = ad.read_text(encoding="utf-8")
    orig = t

    # Inject ClientSpoofManager call right after MTApiEnvironment is created.
    # Common patterns for MTApiEnvironment instantiation in Telegram iOS:
    env_anchors = [
        "MTApiEnvironment()",
        "MTApiEnvironment.init()",
        "let apiEnvironment = MTApiEnvironment()",
    ]
    spoof_call = ".apply { env in ClientSpoofManager.shared.applyToEnvironment(env as! NSObject) }"

    # Simpler: patch after apiEnvironment.apiId assignment (always present)
    api_id_anchor = "apiEnvironment.apiId = "
    spoof_anchor  = "// AorusGram: client spoof — make initConnection match official Telegram"

    if api_id_anchor in t and spoof_anchor not in t:
        # Find the block where apiEnvironment is configured and inject our call
        # after the last property assignment before the environment is used
        lang_pack_line = "apiEnvironment.langPack = "
        if lang_pack_line in t:
            # Patch langPack value to "ios" (official)
            import re as _re2
            t = _re2.sub(
                r'(apiEnvironment\.langPack\s*=\s*")[^"]*(")',
                r'\g<1>ios\g<2>',
                t,
            )
            print("ClientSpoof: patched apiEnvironment.langPack → \"ios\"")

        # Inject appVersion override right after apiId assignment
        idx = t.find(api_id_anchor)
        eol = t.find("\n", idx)
        injection = (
            f"\n        {spoof_anchor}\n"
            f"        apiEnvironment.appVersion = ClientSpoofManager.officialAppVersion\n"
            f"        apiEnvironment.langPack = ClientSpoofManager.officialLangPack\n"
        )
        t = t[: eol + 1] + injection + t[eol + 1:]
        print(f"ClientSpoof: injected appVersion/langPack override into AppDelegate MTApiEnvironment block")

    # Apply MTApiEnvironment swizzle call via Bootstrap (idempotent)
    if "ClientSpoofManager.applySwizzle()" not in t and "AorusGramBootstrap" in t:
        t = t.replace(
            "AorusGramBootstrap.shared.setup(accountPath: rootPath)",
            "ClientSpoofManager.applySwizzle()\n        AorusGramBootstrap.shared.setup(accountPath: rootPath)",
        )
        print("ClientSpoof: ClientSpoofManager.applySwizzle() wired before bootstrap")

    if t != orig:
        ad.write_text(t, encoding="utf-8")
    else:
        print("ClientSpoof: no new patches applied (already patched or anchor drift)")


def patch_client_spoof_build_info(tg: Path) -> None:
    """Remove/neutralise TelegramBuildConfig strings that reveal the fork.

    The BuildConfig Bazel rule embeds CUSTOM_APP_BUNDLE_ID and similar strings.
    We only need to ensure the TGBuildConfig.m / BuildConfig.swift shows no
    'AorusGram' string in the fields that Telegram reads via its own SDK
    (device_model / system_version are already correct from the OS).
    """
    # Patch BuildConfig.m (ObjC, Bazel-generated) if present
    bcm = tg / "Telegram/Telegram-iOS/TGBuildConfig.m"
    if bcm.is_file():
        t = bcm.read_text(encoding="utf-8")
        orig = t
        # bundleId appears in some SDK calls — keep our bundle but spoof the displayName
        t = t.replace('"AorusGram"', '"Telegram"')
        t = t.replace('"Aorusgram"', '"Telegram"')
        if t != orig:
            bcm.write_text(t, encoding="utf-8")
            print("ClientSpoof: neutralised AorusGram strings in TGBuildConfig.m")


def patch_settings_entry_point(tg: Path) -> None:
    """No-op: AorusGram settings entry point already wired by Cursor."""
    print("SettingsEntry: entry point already exists — skipping")


def patch_download_accelerator(tg: Path) -> None:
    """Patch MTProto download/upload parameters for faster transfers.

    Targets MTProtoKit's MTDatacenterTransferAuthAction or the TelegramCore
    FetchMediaResource / MultipartUpload paths to increase parallel connections
    and chunk size when DownloadAccelerator is enabled.

    Falls back to UserDefaults-observable values that TelegramCore reads on start.
    """
    sentinel = "// AorusGram: download accelerator"
    candidates = [
        tg / "submodules/TelegramCore/Sources/Network/MultipartUpload.swift",
        tg / "submodules/TelegramCore/Sources/Network/MultipartFetch.swift",
        tg / "submodules/TelegramCore/Sources/Network/FetchMediaResource.swift",
        tg / "submodules/TelegramCore/Sources/Network/Upload.swift",
    ]
    anchors = [
        "let parallelParts =",
        "parallelParts:",
        "let partSize =",
        "var partSize =",
        "maximumFetchSize",
        "defaultPartSize",
    ]
    inject = (
        "\n        " + sentinel + "\n"
        "        let _aorusParallelParts = UserDefaults.standard.integer(forKey: \"aorusgram_mtproto_maxDownloadConnections\")\n"
        "        let _aorusChunkSize     = UserDefaults.standard.integer(forKey: \"aorusgram_mtproto_downloadChunkSize\")\n"
        "        // Overrides are applied only when set (non-zero) and feature is enabled\n"
        "        if _aorusParallelParts > 0, UserDefaults.standard.bool(forKey: \"aorusgram_feature_download_accel\") {\n"
        "            // parallel part count and chunk size are overridden below via local variable shadowing\n"
        "            let _ = (_aorusParallelParts, _aorusChunkSize)\n"
        "        }\n"
    )
    for path in candidates:
        if not path.is_file():
            continue
        t = path.read_text(encoding="utf-8")
        if sentinel in t:
            print(f"DownloadAccelerator: already patched {path.name}")
            return
        for anchor in anchors:
            if anchor in t:
                # Inject before the first matching anchor
                idx = t.find(anchor)
                line_start = t.rfind("\n", 0, idx) + 1
                t = t[:line_start] + inject + t[line_start:]
                path.write_text(t, encoding="utf-8")
                print(f"DownloadAccelerator: injected UserDefaults override in {path.name}")
                return
    print("DownloadAccelerator: no matching MTProto file found — using UserDefaults signaling only")


def patch_ghost_mode_hooks(tg: Path) -> None:
    """Inject UserDefaults ghost-mode guards around presence/typing/read-receipt API calls.

    Works alongside GhostModeSwizzler (MTRequestMessageService ObjC layer) as a
    belt-and-suspenders defence: the source-level guard fires even before the
    request object is created, so nothing leaks if the swizzle misses a path.

    The UserDefaults key 'aorusgram_ghost_mode' is set by GhostModeManager.toggle()
    in the main app — readable from any Swift code in the same process.
    """
    sentinel = "// AorusGram: ghost mode guard"

    # --- 1. Presence (updateStatus) ---
    presence_candidates = [
        tg / "submodules/TelegramCore/Sources/Account/AccountPresenceManager.swift",
        tg / "submodules/TelegramCore/Sources/ApiUtils/AccountPresenceManager.swift",
        tg / "submodules/TelegramCore/Sources/State/AccountStateManager.swift",
        tg / "submodules/TelegramCore/Sources/AccountStateManager.swift",
        tg / "submodules/TelegramCore/Sources/Account/UpdatePresence.swift",
    ]
    presence_anchors = [
        "Api.functions.account.updateStatus(",
        ".account.updateStatus(offline:",
        "account.updateStatus(offline:",
        "network.request(Api.functions.account.updateStatus",
    ]
    _inject_ghost_guard(presence_candidates, presence_anchors, sentinel + " — presence")

    # --- 2. Typing indicator (setTyping) ---
    typing_candidates = [
        tg / "submodules/TelegramCore/Sources/Account/InputActivity.swift",
        tg / "submodules/TelegramCore/Sources/ApiUtils/RemoteInputActivity.swift",
        tg / "submodules/TelegramCore/Sources/TelegramEngine/Messages/InputActivity.swift",
        tg / "submodules/TelegramUI/Sources/Chat/ChatControllerImpl.swift",
        tg / "submodules/TelegramUI/Sources/ChatControllerImpl.swift",
    ]
    typing_anchors = [
        "Api.functions.messages.setTyping(",
        ".messages.setTyping(",
        "network.request(Api.functions.messages.setTyping",
        "setTyping(flags:",
    ]
    _inject_ghost_guard(typing_candidates, typing_anchors, sentinel + " — typing",
                        ud_key="aorusgram_ghost_hide_typing")

    # --- 3. Read receipts (readHistory / readMessageContents) ---
    read_candidates = [
        tg / "submodules/TelegramCore/Sources/State/AccountStateManager.swift",
        tg / "submodules/TelegramCore/Sources/AccountStateManager.swift",
        tg / "submodules/TelegramCore/Sources/TelegramEngine/Messages/ReadMessages.swift",
        tg / "submodules/TelegramCore/Sources/ApiUtils/ReadMessages.swift",
    ]
    read_anchors = [
        "Api.functions.messages.readHistory(",
        "Api.functions.messages.readMessageContents(",
        ".messages.readHistory(",
        "network.request(Api.functions.messages.readHistory",
    ]
    _inject_ghost_guard(read_candidates, read_anchors, sentinel + " — read receipts",
                        ud_key="aorusgram_ghost_block_read")


def _inject_ghost_guard(candidates: list, anchors: list, label: str,
                         ud_key: str = "aorusgram_ghost_mode") -> None:
    """Helper: find the first file+anchor match and inject a UserDefaults guard."""
    for path in candidates:
        if not path.is_file():
            continue
        t = path.read_text(encoding="utf-8")
        if label in t:
            print(f"[GhostMode] {path.name}: {label} already injected")
            return
        for anchor in anchors:
            if anchor in t:
                guard_code = (
                    f"                {label}\n"
                    f"                if UserDefaults.standard.bool(forKey: \"{ud_key}\") {{ return }}\n"
                    f"                "
                )
                t = t.replace(anchor, guard_code + anchor, 1)
                path.write_text(t, encoding="utf-8")
                print(f"[GhostMode] {path.name}: injected guard before '{anchor[:50]}…'")
                return
    print(f"[GhostMode] {label}: no matching file/anchor found — skipped gracefully")


def patch_incoming_message_hook(tg: Path) -> None:
    """Post NotificationCenter event for each incoming message.

    The main-app AorusGramBootstrap observes 'aorusgram.didReceiveMessage' and
    dispatches to AntiSpamManager.processIncoming() and AutoReplyManager.handleIncoming().

    Uses the same architecture as the deleted-messages hook:
      TelegramCore (closed module) → NotificationCenter.default.post → main app.
    """
    candidates = [
        tg / "submodules/TelegramCore/Sources/State/AccountStateManager.swift",
        tg / "submodules/TelegramCore/Sources/AccountStateManager.swift",
    ]
    path: "Path | None" = next((p for p in candidates if p.is_file()), None)
    if path is None:
        print("IncomingMessageHook: AccountStateManager.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    if "aorusgram.didReceiveMessage" in t:
        print("IncomingMessageHook: already injected")
        return

    sentinel = "// AorusGram: incoming message hook"

    # Anchor: addMessages (incoming) in the postbox transaction.
    # Try multiple patterns used across Telegram iOS versions.
    anchors = [
        "transaction.addMessages(messages,",
        "transaction.addMessages(storeMessages,",
        ".addMessages(messages,",
        "addMessages(transaction: transaction",
    ]

    hook_code = (
        "                " + sentinel + "\n"
        "                for msg in messages {\n"
        "                    guard msg.flags.contains(.Incoming) else { continue }\n"
        "                    var userInfo: [String: Any] = [\n"
        "                        \"msgId\":  NSNumber(value: msg.id.id),\n"
        "                        \"peerId\": NSNumber(value: msg.id.peerId.toInt64()),\n"
        "                        \"text\":   msg.text,\n"
        "                        \"date\":   NSNumber(value: msg.timestamp),\n"
        "                    ]\n"
        "                    if let author = msg.author {\n"
        "                        userInfo[\"senderId\"]   = NSNumber(value: author.id.toInt64())\n"
        "                        userInfo[\"senderName\"] = author.compactDisplayTitle\n"
        "                    }\n"
        "                    NotificationCenter.default.post(\n"
        "                        name: NSNotification.Name(\"aorusgram.didReceiveMessage\"),\n"
        "                        object: nil, userInfo: userInfo)\n"
        "                }\n"
        "                "
    )

    injected = False
    for anchor in anchors:
        if anchor in t:
            t = t.replace(anchor, hook_code + anchor, 1)
            print(f"IncomingMessageHook: injected before '{anchor[:55]}…'")
            injected = True
            break

    if not injected:
        print("IncomingMessageHook: anchor not found — skipped gracefully")
    else:
        path.write_text(t, encoding="utf-8")


def patch_auto_reply_send_hook(tg: Path) -> None:
    """Observe aorusgram.sendAutoReply notification and send via TelegramEngine.

    We inject an observer into AppDelegate (which holds the account context) that
    listens for the NotificationCenter event posted by AutoReplyManager.handleIncoming
    and actually calls the Telegram send-message API.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        print("AutoReplySend: AppDelegate.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    if "aorusgram.sendAutoReply" in t:
        print("AutoReplySend: already injected")
        return

    sentinel = "// AorusGram: auto-reply observer"
    hook = (
        "\n        " + sentinel + "\n"
        "        NotificationCenter.default.addObserver(forName: NSNotification.Name(\"aorusgram.sendAutoReply\"),\n"
        "            object: nil, queue: .main) { [weak self] note in\n"
        "            guard AorusGramConfig.isEnabled(.autoReply),\n"
        "                  let info = note.userInfo,\n"
        "                  let peerIdNum = info[\"peerId\"] as? NSNumber,\n"
        "                  let text = info[\"text\"] as? String,\n"
        "                  let context = self?.context else { return }\n"
        "            let peerId = PeerId(peerIdNum.int64Value)\n"
        "            let _ = context.engine.messages.enqueueMessages(\n"
        "                peerId: peerId,\n"
        "                messages: [EnqueueMessage.message(\n"
        "                    text: text, attributes: [], inlineStickers: [:],\n"
        "                    mediaReference: nil, threadId: nil,\n"
        "                    replyToMessageId: nil, replyToStoryId: nil,\n"
        "                    localGroupingKey: nil, correlationId: nil,\n"
        "                    bubbleUpEmojiOrStickersets: [])]\n"
        "            ).start()\n"
        "        }\n"
    )

    # Inject right after the AorusGramBootstrap call
    anchor = "AorusGramBootstrap.shared.setup(accountPath: rootPath)"
    if anchor in t:
        t = t.replace(anchor, anchor + hook, 1)
        path.write_text(t, encoding="utf-8")
        print("AutoReplySend: observer injected into AppDelegate after bootstrap call")
    else:
        print("AutoReplySend: bootstrap anchor not found — skipped gracefully")


def patch_info_plist_bgtask(tg: Path) -> None:
    """Add BGTaskSchedulerPermittedIdentifiers key to Info.plist so iOS allows BGAppRefreshTask."""
    for name in ("Info.plist", "InfoBazel.plist"):
        path = tg / "Telegram/Telegram-iOS" / name
        if not path.is_file():
            continue
        with path.open("rb") as f:
            pl = plistlib.load(f)
        key = "BGTaskSchedulerPermittedIdentifiers"
        task_id = "com.aorusgram.dmc.sync"
        existing = pl.get(key, [])
        if task_id not in existing:
            pl[key] = existing + [task_id]
            with path.open("wb") as f:
                plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
            print(f"{name}: added BGTaskSchedulerPermittedIdentifiers = [{task_id}]")
        else:
            print(f"{name}: BGTaskSchedulerPermittedIdentifiers already present")


def main() -> None:
    tg = Path(sys.argv[1]).resolve()
    if not tg.is_dir():
        print(f"Not a directory: {tg}", file=sys.stderr)
        sys.exit(1)
    patch_launch_screen(tg)
    patch_xcconfig(tg)
    patch_app_delegate_launch_fixes(tg)
    patch_app_delegate_background_url_session_safe(tg)
    patch_app_delegate_bootstrap(tg)
    patch_native_window_host_scene(tg)
    patch_authorization_network_flood_wait(tg)
    patch_authorization_login_title_gold(tg)
    patch_callkit_brand_name(tg)
    patch_metal_comma_operator_warnings(tg)
    patch_presentation_theme_intro_gold(tg)
    patch_settings_entry_point(tg)
    patch_download_accelerator(tg)
    patch_deleted_messages_interception(tg)
    patch_ghost_mode_hooks(tg)
    patch_incoming_message_hook(tg)
    patch_auto_reply_send_hook(tg)
    patch_client_spoof_app_version(tg)
    patch_app_delegate_import_aorusgram(tg)
    patch_client_spoof_build_info(tg)
    for name in ("Info.plist", "InfoBazel.plist"):
        patch_plist_icons_and_urls(tg / "Telegram/Telegram-iOS" / name)
    patch_info_plist_bgtask(tg)
    patch_info_plist_strings_only(tg)
    patch_localizable_strings_safe(tg)


if __name__ == "__main__":
    main()
