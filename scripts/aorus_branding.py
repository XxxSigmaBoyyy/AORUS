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
    # Primary icon name: keep AppIconLLC (set by patch_primary_app_icon via BUILD).
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
    print(f"Patched {path.name}: aorusgram:// URL scheme, usage strings")


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


def _patch_localizable_strings_file_content(text: str) -> tuple[str, int]:
    """Parse .strings entries (multiline values + multiple entries per line), replace
    \\bTelegram\\b in values only (URLs masked). Does not alter localization keys."""
    # NB: no leading \s* in the capture. With it, the match start jumped back across
    # the newline into a preceding "// comment" line, so the comment-skip check below
    # wrongly treated the *next* real entry as commented out (e.g. "Tour.Title1",
    # which sits right under a "// Tour" header, was never rebranded). Anchoring at the
    # key quote keeps the inter-entry gap (incl. indentation) flowing through the
    # text[pos:m.start()] append, so output is byte-identical for normal entries.
    entry_start = re.compile(r'("(?:[^"\\]|\\.)*"\s*=\s*")')
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
                    # raw_val is already in on-disk escaped form: the parser above
                    # preserves backslash-escapes like \n and \" verbatim. The only
                    # substitution we make is the plain word Telegram→Aorusgram, which
                    # needs no escaping. Previously we re-escaped here, which doubled the
                    # existing backslashes (\n → \\n) and surfaced as a literal "\n" in
                    # the intro tour text. Write the value back verbatim so the original
                    # escaping round-trips exactly.
                    out.append(new_val)
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

    Two real delete entry points in current Telegram-iOS (verified against upstream):
      1. submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessages.swift
         — `_internal_deleteMessages(transaction:, mediaBox:, ids: [MessageId], ...)`
         The function ends with `transaction.deleteMessages(ids, forEachMedia: { _ in })`.
         Used for channel + cloud chat deletes; ids are full peer-scoped MessageId so we
         can call `transaction.getMessage(id)` to grab text/author before the row is gone.
      2. submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift
         — `case let .DeleteMessagesWithGlobalIds(ids):` branch.
         Used for legacy non-channel deletes; ids are bare `Int32` globals (no peer).
         We post a global-id-only notification — main app updates pre-cached rows by id.

    The previous version targeted AccountStateManager.swift which doesn't contain
    delete calls at all in current upstream — the hook silently no-op'd.
    """
    sentinel = "// AorusGram: NotificationCenter delete bridge"

    # --- 1. Peer-scoped deletes in _internal_deleteMessages ---
    delete_msgs_path = tg / "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessages.swift"
    if delete_msgs_path.is_file():
        t = delete_msgs_path.read_text(encoding="utf-8")
        if sentinel in t:
            print("DeleteMessages.swift: hook already present")
        else:
            anchor = "transaction.deleteMessages(ids, forEachMedia: { _ in"
            # Architecture (when aorusgram_feature_deleted_messages == true, the default):
            #   1. For each ID, fetch the message. Only preserve if it's an INCOMING
            #      message (sent by someone else). When the user deletes their OWN
            #      outgoing message we let the normal deletion proceed — preserving
            #      our own deletes would be confusing.
            #   2. For each preserved ID:
            #        - Update message text in postbox with prefix "🗑 [Удалено]\n…"
            #          (idempotent — already-marked messages skip).
            #        - Append the (peerId, msgId) pair to UserDefaults
            #          "aorusgram_preserved_msgs" so the "Очистить кеш" button knows
            #          which postbox rows to wipe later.
            #   3. Build a filtered `idsToReallyDelete` (outgoing + non-existent),
            #      replace the parameter to the downstream transaction.deleteMessages
            #      call so the normal delete still runs for those.
            # StoreMessage template copied from
            #   ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift:230
            # (canonical 'rebuild StoreMessage from Message' pattern).
            hook = (
                "    " + sentinel + " — peer-scoped\n"
                "    for id in ids {\n"
                "        let userInfo: [String: Any] = [\n"
                "            \"msgId\":  NSNumber(value: id.id),\n"
                "            \"peerId\": NSNumber(value: id.peerId.toInt64()),\n"
                "        ]\n"
                "        NotificationCenter.default.post(\n"
                "            name: NSNotification.Name(\"aorusgram.willDeleteMessage\"),\n"
                "            object: nil, userInfo: userInfo)\n"
                "    }\n"
                "    // anti-spoof for outgoing deletes is handled deterministically by the\n"
                "    // preflight Signal chain in _internal_deleteMessagesInteractively (see\n"
                "    // patch_anti_spoof_delete_preflight). The previous notification post here\n"
                "    // raced the edit and delete RPCs in parallel; we now run edit synchronously\n"
                "    // (Signal-chain) before delete is even queued, so no fallback is needed.\n"
                "    let __aorusPreserve = (UserDefaults.standard.object(forKey: \"aorusgram_feature_deleted_messages\") as? Bool) ?? true\n"
                "    var __aorusIdsToDelete: [MessageId] = []\n"
                "    for id in ids {\n"
                "        guard __aorusPreserve, let currentMessage = transaction.getMessage(id), currentMessage.flags.contains(.Incoming) else {\n"
                "            __aorusIdsToDelete.append(id)\n"
                "            continue\n"
                "        }\n"
                "        if currentMessage.text.hasPrefix(\"\\u{1F5D1}\") { continue }\n"
                "        transaction.updateMessage(id, update: { msg -> PostboxUpdateMessage in\n"
                "            let aorusDeletedLabel = (UserDefaults.standard.string(forKey: \"aorusgram_lang\") == \"ru\") ? \"Удалено\" : \"Deleted\"\n"
                "            let newText = \"\\u{1F5D1} [\" + aorusDeletedLabel + \"]\\n\" + msg.text\n"
                "            return .update(StoreMessage(\n"
                "                id: msg.id, customStableId: nil,\n"
                "                globallyUniqueId: msg.globallyUniqueId,\n"
                "                groupingKey: msg.groupingKey,\n"
                "                threadId: msg.threadId,\n"
                "                timestamp: msg.timestamp,\n"
                "                flags: StoreMessageFlags(msg.flags),\n"
                "                tags: msg.tags,\n"
                "                globalTags: msg.globalTags,\n"
                "                localTags: msg.localTags,\n"
                "                forwardInfo: msg.forwardInfo.flatMap(StoreMessageForwardInfo.init),\n"
                "                authorId: msg.author?.id,\n"
                "                text: newText,\n"
                "                attributes: msg.attributes,\n"
                "                media: msg.media))\n"
                "        })\n"
                "        var preservedList = (UserDefaults.standard.array(forKey: \"aorusgram_preserved_msgs\") as? [[String: Int64]]) ?? []\n"
                "        preservedList.append([\"peerId\": id.peerId.toInt64(), \"msgId\": Int64(id.id), \"namespace\": Int64(id.namespace)])\n"
                "        UserDefaults.standard.set(preservedList, forKey: \"aorusgram_preserved_msgs\")\n"
                "    }\n"
                "    if __aorusIdsToDelete.isEmpty { return }\n"
                "    "
            )
            if anchor in t:
                # Inject hook AND swap the `ids` argument for our filtered list so
                # only non-preserved (outgoing / unknown) messages actually delete.
                new_call = "transaction.deleteMessages(__aorusIdsToDelete, forEachMedia: { _ in"
                t = t.replace(anchor, hook + new_call, 1)
                delete_msgs_path.write_text(t, encoding="utf-8")
                print("DeleteMessages.swift: peer-scoped delete hook injected (filtered ids)")
            else:
                print("DeleteMessages.swift: anchor not found — skipped")
    else:
        print("DeleteMessages.swift: file not found — skipped")

    # --- 1b. Edit-message capture + inline original display ---
    # Two injection points inside AccountStateManagementUtils.swift:
    #
    #   A. Right after `case let .EditMessage(id, message):`
    #      - Capture the pre-edit message into a `let aorusPrev` so it's reachable
    #        from the AFTER-edit augmentation block (postbox state will have been
    #        rewritten by `transaction.updateMessage` by then).
    #      - Post the willEditMessage notification (cache bookkeeping in main app).
    #
    #   B. Right BEFORE the next `case let .UpdateMessagePoll(...)`
    #      - When the feature flag is on (default true), run a SECOND
    #        `transaction.updateMessage` that rebuilds the StoreMessage with the
    #        new text appended by "\n\n✏️ Оригинал:\n<old text>".
    #      - Idempotent — checks for the marker before re-applying.
    #
    # Together these mean: when someone edits a message, the chat keeps showing
    # the new text but with the original right below it inside the same bubble.
    utils_path_edit = tg / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
    if utils_path_edit.is_file():
        t = utils_path_edit.read_text(encoding="utf-8")
        edit_sentinel = "// AorusGram: capture edit"
        if edit_sentinel not in t:
            # --- A. capture + notification ---
            edit_anchor = (
                "            case let .EditMessage(id, message):\n"
                "                var generatedEvent:"
            )
            edit_hook = (
                "            case let .EditMessage(id, message):\n"
                "                " + edit_sentinel + "\n"
                "                let aorusPrev = transaction.getMessage(id)\n"
                "                if let prev = aorusPrev, prev.text != message.text {\n"
                "                    NotificationCenter.default.post(\n"
                "                        name: NSNotification.Name(\"aorusgram.willEditMessage\"),\n"
                "                        object: nil,\n"
                "                        userInfo: [\n"
                "                            \"msgId\":        NSNumber(value: id.id),\n"
                "                            \"peerId\":       NSNumber(value: id.peerId.toInt64()),\n"
                "                            \"originalText\": prev.text,\n"
                "                            \"newText\":      message.text,\n"
                "                            \"date\":         NSNumber(value: prev.timestamp),\n"
                "                        ])\n"
                "                }\n"
                "                var generatedEvent:"
            )
            if edit_anchor in t:
                t = t.replace(edit_anchor, edit_hook, 1)
                print("AccountStateManagementUtils.swift: edit-capture hook injected")
            else:
                print("AccountStateManagementUtils.swift: EditMessage anchor not found — skipped")

            # --- B. append original under new text ---
            tail_anchor = (
                "                if let generatedEvent = generatedEvent {\n"
                "                    addedReactionEvents.append(generatedEvent)\n"
                "                }\n"
                "            case let .UpdateMessagePoll(pollId, apiPoll, results):"
            )
            tail_hook = (
                "                if let generatedEvent = generatedEvent {\n"
                "                    addedReactionEvents.append(generatedEvent)\n"
                "                }\n"
                "                // AorusGram: inline original under edited text\n"
                "                let __aorusEditEnabled = (UserDefaults.standard.object(forKey: \"aorusgram_feature_deleted_messages\") as? Bool) ?? true\n"
                "                if __aorusEditEnabled, let prev = aorusPrev, prev.flags.contains(.Incoming), prev.text != message.text, !prev.text.isEmpty {\n"
                "                    transaction.updateMessage(id, update: { currentMessage -> PostboxUpdateMessage in\n"
                "                        if currentMessage.text.contains(\"\\n\\n\\u{270F}\\u{FE0F} \") { return .skip }\n"
                "                        let aorusOriginalLabel = (UserDefaults.standard.string(forKey: \"aorusgram_lang\") == \"ru\") ? \"Оригинал:\" : \"Original:\"\n"
                "                        let newText = currentMessage.text + \"\\n\\n\\u{270F}\\u{FE0F} \" + aorusOriginalLabel + \"\\n\" + prev.text\n"
                "                        return .update(StoreMessage(\n"
                "                            id: currentMessage.id, customStableId: nil,\n"
                "                            globallyUniqueId: currentMessage.globallyUniqueId,\n"
                "                            groupingKey: currentMessage.groupingKey,\n"
                "                            threadId: currentMessage.threadId,\n"
                "                            timestamp: currentMessage.timestamp,\n"
                "                            flags: StoreMessageFlags(currentMessage.flags),\n"
                "                            tags: currentMessage.tags,\n"
                "                            globalTags: currentMessage.globalTags,\n"
                "                            localTags: currentMessage.localTags,\n"
                "                            forwardInfo: currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init),\n"
                "                            authorId: currentMessage.author?.id,\n"
                "                            text: newText,\n"
                "                            attributes: currentMessage.attributes,\n"
                "                            media: currentMessage.media))\n"
                "                    })\n"
                "                    var preservedList = (UserDefaults.standard.array(forKey: \"aorusgram_preserved_msgs\") as? [[String: Int64]]) ?? []\n"
                "                    preservedList.append([\"peerId\": id.peerId.toInt64(), \"msgId\": Int64(id.id), \"namespace\": Int64(id.namespace)])\n"
                "                    UserDefaults.standard.set(preservedList, forKey: \"aorusgram_preserved_msgs\")\n"
                "                }\n"
                "            case let .UpdateMessagePoll(pollId, apiPoll, results):"
            )
            if tail_anchor in t:
                t = t.replace(tail_anchor, tail_hook, 1)
                print("AccountStateManagementUtils.swift: edit-augment tail hook injected")
            else:
                print("AccountStateManagementUtils.swift: edit-augment tail anchor not found — skipped")

            utils_path_edit.write_text(t, encoding="utf-8")

    # --- 2. Global-id deletes in AccountStateManagementUtils (REGULAR CHAT deletes-for-everyone) ---
    # This is the critical path for "other person deleted a message for everyone" — comes
    # from `update.DeleteMessages` with Int32 global IDs (NOT MessageId). Goes through
    # `transaction.deleteMessagesWithGlobalIds(ids, forEachMedia: ...)`. The previous patch
    # only POSTED a notification (didn't block deletion), so messages still vanished. Now
    # we resolve global IDs to MessageIds via Postbox.Transaction.messageIdsForGlobalIds,
    # filter to .Incoming, mark with 🗑 prefix, and skip them from the delete call.
    utils_path = tg / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
    new_marker = "__aorusFilteredGlobalIds"
    if utils_path.is_file():
        t = utils_path.read_text(encoding="utf-8")
        if new_marker in t:
            print("AccountStateManagementUtils.swift: global-id preserve already present")
        else:
            import re as _re_glob
            # Remove any legacy notification-only hook left in cached trees (idempotent upgrade).
            old_hook_re = _re_glob.compile(
                r"                // AorusGram: NotificationCenter delete bridge — global\n"
                r"                for gid in ids \{\n"
                r"                    NotificationCenter\.default\.post\(\n"
                r"                        name: NSNotification\.Name\(\"aorusgram\.willDeleteMessageGlobalId\"\),\n"
                r"                        object: nil,\n"
                r"                        userInfo: \[\"msgId\": NSNumber\(value: gid\)\]\)\n"
                r"                \}\n"
                r"                "
            )
            if old_hook_re.search(t):
                t = old_hook_re.sub("", t, count=1)
                print("AccountStateManagementUtils.swift: removed legacy notification-only hook")

            anchor = "transaction.deleteMessagesWithGlobalIds(ids, forEachMedia: { media in"
            preserve_block = (
                sentinel + " — server-side preserve\n"
                "                let __aorusPreserveGlobal = (UserDefaults.standard.object(forKey: \"aorusgram_feature_deleted_messages\") as? Bool) ?? true\n"
                "                var __aorusFilteredGlobalIds: [Int32] = []\n"
                "                if __aorusPreserveGlobal {\n"
                "                    for gid in ids {\n"
                "                        NotificationCenter.default.post(\n"
                "                            name: NSNotification.Name(\"aorusgram.willDeleteMessageGlobalId\"),\n"
                "                            object: nil,\n"
                "                            userInfo: [\"msgId\": NSNumber(value: gid)])\n"
                "                        let resolved = transaction.messageIdsForGlobalIds([gid])\n"
                "                        guard let mid = resolved.first, let msg = transaction.getMessage(mid), msg.flags.contains(.Incoming) else {\n"
                "                            __aorusFilteredGlobalIds.append(gid)\n"
                "                            continue\n"
                "                        }\n"
                "                        if !msg.text.hasPrefix(\"\\u{1F5D1}\") {\n"
                "                            transaction.updateMessage(mid, update: { current -> PostboxUpdateMessage in\n"
                "                                let aorusDeletedLabel = (UserDefaults.standard.string(forKey: \"aorusgram_lang\") == \"ru\") ? \"Удалено\" : \"Deleted\"\n"
                "                                let newText = \"\\u{1F5D1} [\" + aorusDeletedLabel + \"]\\n\" + current.text\n"
                "                                return .update(StoreMessage(\n"
                "                                    id: current.id, customStableId: nil,\n"
                "                                    globallyUniqueId: current.globallyUniqueId,\n"
                "                                    groupingKey: current.groupingKey,\n"
                "                                    threadId: current.threadId,\n"
                "                                    timestamp: current.timestamp,\n"
                "                                    flags: StoreMessageFlags(current.flags),\n"
                "                                    tags: current.tags,\n"
                "                                    globalTags: current.globalTags,\n"
                "                                    localTags: current.localTags,\n"
                "                                    forwardInfo: current.forwardInfo.flatMap(StoreMessageForwardInfo.init),\n"
                "                                    authorId: current.author?.id,\n"
                "                                    text: newText,\n"
                "                                    attributes: current.attributes,\n"
                "                                    media: current.media))\n"
                "                            })\n"
                "                            var preservedList = (UserDefaults.standard.array(forKey: \"aorusgram_preserved_msgs\") as? [[String: Int64]]) ?? []\n"
                "                            preservedList.append([\"peerId\": mid.peerId.toInt64(), \"msgId\": Int64(mid.id), \"namespace\": Int64(mid.namespace)])\n"
                "                            UserDefaults.standard.set(preservedList, forKey: \"aorusgram_preserved_msgs\")\n"
                "                        }\n"
                "                    }\n"
                "                } else {\n"
                "                    __aorusFilteredGlobalIds = ids\n"
                "                }\n"
                "                "
            )
            new_call = "transaction.deleteMessagesWithGlobalIds(__aorusFilteredGlobalIds, forEachMedia: { media in"
            if anchor in t:
                t = t.replace(anchor, preserve_block + new_call, 1)
                # Also rewrite downstream `deletedMessageIds.append(contentsOf: ids.map { .global($0) })`
                # so consumers don't think we deleted incoming messages we actually preserved.
                old_tail = "deletedMessageIds.append(contentsOf: ids.map { .global($0) })"
                new_tail = "deletedMessageIds.append(contentsOf: __aorusFilteredGlobalIds.map { .global($0) })"
                if old_tail in t:
                    t = t.replace(old_tail, new_tail, 1)
                utils_path.write_text(t, encoding="utf-8")
                print("AccountStateManagementUtils.swift: global-id preserve hook injected (.Incoming-filtered)")
            else:
                print("AccountStateManagementUtils.swift: deleteMessagesWithGlobalIds anchor not found — skipped")
    else:
        print("AccountStateManagementUtils.swift: file not found — skipped")


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
    """Raise MTProto multipart download concurrency when the accelerator is on.

    Telegram fetches large files with `parallelParts = 8` concurrent part
    requests. When the "Ускоритель загрузок" toggle is enabled (flat key
    aorusgram_feature_download_accel, written by AorusGramManager) we raise
    that to 16 — the exact value Telegram itself already uses for small-file
    fetches, so it is a safe, server-friendly bump that doubles concurrency on
    big media (videos, documents, photos).

    This is a single fully-anchored one-line replacement — no fragile
    scaffolding, unlike the earlier attempt that broke Swift parsing on CI.
    """
    path = tg / "submodules/TelegramCore/Sources/Network/MultipartFetch.swift"
    if not path.is_file():
        print("DownloadAccelerator: MultipartFetch.swift not found — skipped")
        return
    t = path.read_text(encoding="utf-8")
    if "aorusgram_feature_download_accel" in t:
        print("DownloadAccelerator: already patched")
        return
    anchor = (
        "                self.defaultPartSize = 512 * 1024\n"
        "                self.parallelParts = 8\n"
    )
    if anchor not in t:
        print("DownloadAccelerator: parallelParts anchor not found — skipped")
        return
    replacement = (
        "                self.defaultPartSize = 512 * 1024\n"
        "                self.parallelParts = UserDefaults.standard.bool(forKey: \"aorusgram_feature_download_accel\") ? 16 : 8\n"
    )
    t = t.replace(anchor, replacement, 1)
    path.write_text(t, encoding="utf-8")
    print("DownloadAccelerator: parallelParts 8 -> 16 when accelerator enabled")


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


def patch_block_ads(tg: Path) -> None:
    """Block Telegram sponsored (ad) messages — works like Telegram Premium.

    Patched file:
      submodules/TelegramCore/Sources/TelegramEngine/Messages/AdMessages.swift

    How sponsored messages work:
      AdMessageContext.activate() calls messages.getSponsoredMessages via the
      network and stores results. The UI layer reads the cached results and inserts
      the ad bubble into the channel chat view.

    Patch strategy:
      Inside the `mapToSignal` closure that calls `getSponsoredMessages`, the
      existing guard `guard let inputPeer else { return .single((nil,nil,nil,[])) }`
      already short-circuits when the peer can't be resolved. We extend it to ALSO
      short-circuit when `aorusgram_block_ads` UserDefaults flag is true:

        guard let inputPeer, !UserDefaults.standard.bool(forKey: \"aorusgram_block_ads\") else {
            return .single((nil, nil, nil, []))
        }

      This returns an empty ad list WITHOUT contacting the server — identical to what
      Telegram Premium does internally. The flag is set to true in AorusGramBootstrap.setup()
      so ads are blocked from first launch with no UI toggle needed.

    The anchor is unique within the file (verified against current upstream).
    """
    path = tg / "submodules/TelegramCore/Sources/TelegramEngine/Messages/AdMessages.swift"
    if not path.is_file():
        print("BlockAds: AdMessages.swift not found — skipped")
        return

    t = path.read_text(encoding="utf-8")
    if "aorusgram_block_ads" in t:
        print("BlockAds: already patched")
        return

    # Patch activate() to mark itself activated and return immediately.
    # We set isActivated=true so repeat calls are no-ops (same as normal flow).
    # No unreachable code: the guard is inside the branch that does NOT execute.
    # Anchor is unique: "        self.isActivated = true" followed by blank line exists
    # only once in activate() in this file.
    old = (
        "    func activate() {\n"
        "        if self.isActivated {\n"
        "            return\n"
        "        }\n"
        "        self.isActivated = true"
    )
    new = (
        "    func activate() {\n"
        "        if self.isActivated {\n"
        "            return\n"
        "        }\n"
        "        self.isActivated = true\n"
        "        // AorusGram: block sponsored ads — no server request, always empty\n"
        "        guard !self.isActivated else { return }"
    )
    if old in t:
        t = t.replace(old, new, 1)
        path.write_text(t, encoding="utf-8")
        print("BlockAds: AdMessages.swift — activate() short-circuits, ads permanently disabled")
    else:
        print("BlockAds: activate() anchor not found (upstream drift) — skipped gracefully")


def patch_ghost_mode_hide_typing(tg: Path) -> None:
    """Hide the 'typing...' indicator from peers when Ghost Mode is on.

    Patched file: submodules/TelegramCore/Sources/State/ManagedLocalInputActivities.swift

    Telegram's `requestActivity(...)` is the single entry point through which the
    client tells the server about every input action (typing, recording audio,
    uploading, etc.). It returns Signal<Void, NoError> and is called from the
    activity-throttling pipeline. The body wraps everything in
    `postbox.transaction { transaction -> Signal<Void, NoError> in ... }`.

    We inject an early `return .complete()` BEFORE the postbox transaction when
    the master ghost flag is set. This is the cleanest seam: one anchor, valid
    Swift in expression context, blocks every typing-related setTyping API call
    upstream of the network layer.
    """
    path = tg / "submodules/TelegramCore/Sources/State/ManagedLocalInputActivities.swift"
    if not path.is_file():
        print("HideTyping: ManagedLocalInputActivities.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: hide typing"
    if sentinel in t:
        print("HideTyping: already injected")
        return

    anchor = "return postbox.transaction { transaction -> Signal<Void, NoError> in"
    if anchor not in t:
        print("HideTyping: anchor not found — skipped (upstream drift)")
        return

    guard = (
        sentinel + "\n"
        "    if UserDefaults.standard.bool(forKey: \"aorusgram_ghost_mode\") {\n"
        "        return .complete()\n"
        "    }\n"
        "    "
    )
    t = t.replace(anchor, guard + anchor, 1)
    path.write_text(t, encoding="utf-8")
    print("HideTyping: injected early-return guard in requestActivity")


def patch_ghost_mode_hide_online(tg: Path) -> None:
    """Override every "go online" attempt with an explicit "stay offline" broadcast
    while Ghost Mode is on.

    Patched file: submodules/TelegramCore/Sources/State/ManagedAccountPresence.swift

    Why v3 isn't just a return:
    Telegram's server marks an account as online whenever MTProto session activity
    is detected — e.g. sending a message produces side-effects that the server
    reads as "this user is active right now" even WITHOUT an explicit
    account.updateStatus(offline: false) RPC. The v2 patch (early-return) silently
    let the server make that inference, so peers still saw the account come
    online every time a message was sent.

    Fix (v3): when updatePresence(true) is invoked under ghost mode, instead of
    early-return we PROACTIVELY fire account.updateStatus(offline: .boolTrue)
    through the same disposable so the server is told "no, still offline" — and
    re-schedule the same 30s recurrence timer so the offline assertion is kept
    fresh. The result is that every server-side promotion to "online" is
    immediately countered by an explicit offline broadcast.
    """
    path = tg / "submodules/TelegramCore/Sources/State/ManagedAccountPresence.swift"
    if not path.is_file():
        print("HideOnline: ManagedAccountPresence.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: hide online presence v3"
    if sentinel in t:
        print("HideOnline: already injected (v3)")
        return

    # Strip any old v1/v2 injection so we can re-apply the new override.
    for old in ("// AorusGram: hide online presence v2", "// AorusGram: hide online presence"):
        if old in t:
            t = t.replace(
                "        " + old + "\n"
                "        if isOnline && UserDefaults.standard.bool(forKey: \"aorusgram_ghost_mode\") { return }\n",
                "",
                1,
            )
            t = t.replace(
                "        " + old + "\n"
                "        if UserDefaults.standard.bool(forKey: \"aorusgram_ghost_mode\") { return }\n",
                "",
                1,
            )
            print(f"HideOnline: stripped previous '{old}' guard")

    anchor = "private func updatePresence(_ isOnline: Bool) {"
    if anchor not in t:
        print("HideOnline: updatePresence anchor not found — skipped")
        return

    override = (
        anchor + "\n"
        "        " + sentinel + "\n"
        "        if isOnline && UserDefaults.standard.bool(forKey: \"aorusgram_ghost_mode\") {\n"
        "            self.onlineTimer?.invalidate()\n"
        "            let aorusTimer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in\n"
        "                guard let s = self else { return }\n"
        "                s.updatePresence(true)\n"
        "            }, queue: self.queue)\n"
        "            self.onlineTimer = aorusTimer\n"
        "            aorusTimer.start()\n"
        "            let aorusOfflineReq = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))\n"
        "            self.currentRequestDisposable.set((aorusOfflineReq\n"
        "            |> `catch` { _ -> Signal<Api.Bool, NoError> in return .single(.boolFalse) }\n"
        "            |> deliverOn(self.queue)).start())\n"
        "            return\n"
        "        }"
    )
    t = t.replace(anchor, override, 1)
    path.write_text(t, encoding="utf-8")
    print("HideOnline: injected proactive offline override in updatePresence (v3)")


def patch_ghost_mode_proactive_offline(tg: Path) -> None:
    """Kick off the v3 self-sustaining offline-ping chain the moment ghost mode
    is toggled ON.

    When ghost mode flips on, we want the server to be told "offline" right now
    AND for the recurrence to keep firing so server-side activity inference
    (caused by e.g. sendMessage RPCs) is continuously countered. The simplest
    way is to call updatePresence(true) from this observer — that hits the v3
    ghost-mode branch which: schedules a 30s repeating timer + sends
    updateStatus(offline: .boolTrue). Subsequent timer fires keep reinvoking
    updatePresence(true) under the same branch, perpetuating the chain.

    We intentionally do NOT invalidate the existing onlineTimer here, because
    a pre-existing online ping cadence (from before ghost was enabled) firing
    updatePresence(true) will now hit the v3 branch and broadcast offline, so
    the cadence remains useful.

    Patched file: submodules/TelegramCore/Sources/State/ManagedAccountPresence.swift
    """
    path = tg / "submodules/TelegramCore/Sources/State/ManagedAccountPresence.swift"
    if not path.is_file():
        print("ProactiveOffline: ManagedAccountPresence.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: proactive offline on ghost"
    if sentinel in t:
        print("ProactiveOffline: already injected")
        return

    # Inject inside init(...) right after `self.network = network`, before the
    # shouldKeepOnlinePresenceDisposable assignment. This gives us access to
    # self.network and self.queue for sending the offline request.
    anchor = (
        "        self.queue = queue\n"
        "        self.network = network\n"
        "        \n"
        "        self.shouldKeepOnlinePresenceDisposable"
    )
    if anchor not in t:
        # Try a more lenient match (no trailing blank line)
        anchor = (
            "        self.queue = queue\n"
            "        self.network = network\n"
            "        self.shouldKeepOnlinePresenceDisposable"
        )
        if anchor not in t:
            print("ProactiveOffline: init anchor not found — skipped")
            return

    injection = (
        "        self.queue = queue\n"
        "        self.network = network\n"
        "        \n"
        "        " + sentinel + "\n"
        "        let aorusQueue = queue\n"
        "        NotificationCenter.default.addObserver(\n"
        "            forName: NSNotification.Name(\"aorusgram_settings_changed\"),\n"
        "            object: nil, queue: nil\n"
        "        ) { [weak self] _ in\n"
        "            guard UserDefaults.standard.bool(forKey: \"aorusgram_ghost_mode\") else { return }\n"
        "            aorusQueue.async {\n"
        "                self?.updatePresence(true)\n"
        "            }\n"
        "        }\n"
        "        \n"
        "        self.shouldKeepOnlinePresenceDisposable"
    )
    t = t.replace(anchor, injection, 1)
    path.write_text(t, encoding="utf-8")
    print("ProactiveOffline: injected ghost-mode-change observer in init")


def patch_ghost_mode_block_read(tg: Path) -> None:
    """Block read-receipt sync (messages.readHistory / channels.readHistory)
    when Ghost Mode is on.

    Patched file: submodules/TelegramCore/Sources/State/SynchronizePeerReadState.swift

    `synchronizePeerReadState(...)` is the main pipeline that pushes read state
    to the server. It returns Signal<Never, PeerReadStateValidationError>.

    CRITICAL FIX (v2): The previous implementation returned .complete() which
    caused an infinite CPU loop and app crash when sending messages with ghost
    mode on. Root cause:
      ManagedSynchronizePeerReadStates.update() is driven by
      postbox.synchronizePeerReadStatesView(). When the push operation "completes"
      (our .complete() early return), update() removes the active operation and
      re-checks the postbox view — which still shows the pending push (because we
      never actually fulfilled it server-side). This restarts the operation, which
      immediately completes again, creating an infinite tight loop on the queue
      that the watchdog kills as a crash.

    Fix: return a signal that NEVER completes. The active operation stays in
    ManagedSynchronizePeerReadStates.activeOperations forever (until session end),
    so update() sees it as "already in progress" and does nothing on subsequent
    calls. No loop, no crash.

    sentinel v2: invalidates old v1 injection that used the crashing .complete().
    """
    path = tg / "submodules/TelegramCore/Sources/State/SynchronizePeerReadState.swift"
    if not path.is_file():
        print("BlockRead: SynchronizePeerReadState.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: block read receipts v2"
    if sentinel in t:
        print("BlockRead: already injected (v2)")
        return

    # Strip any old v1 injection that used the crashing .complete() return
    old_sentinel = "// AorusGram: block read receipts"
    if old_sentinel in t and sentinel not in t:
        t = t.replace(
            "    " + old_sentinel + "\n"
            "    if UserDefaults.standard.bool(forKey: \"aorusgram_ghost_mode\") {\n"
            "        return .complete()\n"
            "    }",
            "",
            1,
        )
        print("BlockRead: removed crashing v1 guard")

    anchor = (
        "func synchronizePeerReadState(network: Network, postbox: Postbox, "
        "stateManager: AccountStateManager, peerId: PeerId, push: Bool, validate: Bool) "
        "-> Signal<Never, PeerReadStateValidationError> {"
    )
    if anchor not in t:
        print("BlockRead: synchronizePeerReadState anchor not found — skipped")
        return

    # Return a signal that hangs forever — keeps the op "active" in the caller's
    # activeOperations dict so update() never re-queues. No CPU loop, no crash.
    guard = (
        anchor + "\n"
        "    " + sentinel + "\n"
        "    if UserDefaults.standard.bool(forKey: \"aorusgram_ghost_mode\") {\n"
        "        return Signal { _ in ActionDisposable {} }\n"
        "    }"
    )
    t = t.replace(anchor, guard, 1)
    path.write_text(t, encoding="utf-8")
    print("BlockRead: injected non-completing guard in synchronizePeerReadState (v2)")


def patch_aorus_code_encode(tg: Path) -> None:
    """Encode outgoing message text with AorusCode steganography when enabled.

    Patched file: submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift

    When UserDefaults 'aorusgram_aorus_code_enabled' is true, outgoing `.message`
    enum cases have their text encoded: the original text is preserved as the
    visible cover, and the same text is hidden as invisible zero-width Unicode
    appended after the cover. AorusGram recipients auto-decode and see a ✉ badge.
    Non-AorusGram clients see the plain text unchanged.

    The encoding is inlined here (not calling AorusStealthCodec) because
    EnqueueMessage.swift is in TelegramCore which cannot import AorusGramUI.
    The algorithm is identical to AorusStealthCodec.encode(cover:, secret:).
    """
    path = tg / "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift"
    if not path.is_file():
        print("AorusCodeEncode: EnqueueMessage.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: AorusCode encoding"
    if sentinel in t:
        print("AorusCodeEncode: already injected")
        return

    anchor = "public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[MessageId?], NoError> {"
    if anchor not in t:
        print("AorusCodeEncode: enqueueMessages anchor not found — skipped")
        return

    encode_block = (
        sentinel + "\n"
        "    var messages = messages\n"
        "    if UserDefaults.standard.bool(forKey: \"aorusgram_aorus_code_enabled\") {\n"
        "        let aorusLo: [Character] = [\n"
        "            \"\\u{200B}\",\"\\u{200C}\",\"\\u{200D}\",\"\\u{2060}\",\n"
        "            \"\\u{2061}\",\"\\u{2062}\",\"\\u{2063}\",\"\\u{2064}\",\n"
        "            \"\\u{206A}\",\"\\u{206B}\",\"\\u{206C}\",\"\\u{206D}\",\n"
        "            \"\\u{206E}\",\"\\u{206F}\",\"\\u{FEFF}\",\"\\u{FFA0}\"\n"
        "        ]\n"
        "        let aorusHi: [Character] = [\n"
        "            \"\\u{180B}\",\"\\u{180C}\",\"\\u{180D}\",\"\\u{180E}\",\n"
        "            \"\\u{180F}\",\"\\u{FE00}\",\"\\u{FE01}\",\"\\u{FE02}\",\n"
        "            \"\\u{FE03}\",\"\\u{FE04}\",\"\\u{FE05}\",\"\\u{FE06}\",\n"
        "            \"\\u{FE07}\",\"\\u{FE08}\",\"\\u{FE09}\",\"\\u{FE0A}\"\n"
        "        ]\n"
        "        messages = messages.map { msg -> EnqueueMessage in\n"
        "            guard case let .message(text, attrs, stickers, media, threadId, replyTo, replyToStory, groupKey, corrId, bubbles) = msg,\n"
        "                  !text.isEmpty else { return msg }\n"
        "            var hidden = \"\\u{2063}\\u{2064}\"\n"
        "            for byte in Array(text.utf8) {\n"
        "                hidden.append(aorusHi[Int(byte >> 4)])\n"
        "                hidden.append(aorusLo[Int(byte & 0x0F)])\n"
        "            }\n"
        "            hidden += \"\\u{2064}\\u{2063}\"\n"
        "            return .message(text: text + hidden, attributes: attrs, inlineStickers: stickers,\n"
        "                mediaReference: media, threadId: threadId, replyToMessageId: replyTo,\n"
        "                replyToStoryId: replyToStory, localGroupingKey: groupKey,\n"
        "                correlationId: corrId, bubbleUpEmojiOrStickersets: bubbles)\n"
        "        }\n"
        "    }\n"
        "    "
    )
    t = t.replace(anchor, anchor + "\n    " + encode_block, 1)
    path.write_text(t, encoding="utf-8")
    print("AorusCodeEncode: injected steganographic encoder in enqueueMessages")


def patch_chat_context_menu_translate_transcribe(tg: Path) -> None:
    """Add native AorusGram Translate + Transcribe items to the long-press context menu.

    v4 — toggles via UserDefaults + settings-gated.

    Translate button:
      First press  — saves original text under aorusgram_orig_text_<peer>_<msg>,
                     replaces message.text with API translation.
      Second press — context menu shows "↩️ Оригинал" instead; tapping it
                     restores the saved original and clears the keys.

    Transcribe button (voice messages):
      First press  — runs SFSpeechRecognizer, writes result to message.text.
                     Saves prior text (usually empty) as the original.
      Second press — shows "↩️ Скрыть транскрипцию"; restores prior text.

    Gating: each button reads `aorusgram_feature_translator` /
    `aorusgram_feature_voice_transcription` UserDefaults flags at menu-build time.
    AorusGramManager mirrors all toggles into those keys on every save().
    """
    path = tg / "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
    if not path.is_file():
        print("ChatContextMenu: ChatInterfaceStateContextMenus.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: native translate/transcribe v4"
    if sentinel in t:
        print("ChatContextMenu: v4 already injected")
        return

    # Strip any earlier v1/v2/v3 injection (recognisable by the common prefix).
    # The end is always the unique Reply-action anchor.
    old_prefix = "// AorusGram: native translate/transcribe"
    if old_prefix in t:
        start = t.find("        " + old_prefix)
        anchor_pos = t.find("        if !isPinnedMessages, !isReplyThreadHead, data.canReply {")
        if start != -1 and anchor_pos != -1 and anchor_pos > start:
            t = t[:start] + t[anchor_pos:]
            print("ChatContextMenu: stripped previous translate/transcribe injection")

    # Add Speech import after Foundation if not present already
    if "import Speech" not in t:
        t = t.replace(
            "import Foundation\n",
            "import Foundation\n#if canImport(Speech)\nimport Speech\n#endif\n",
            1,
        )

    # File-level disposable holder — the native translate RPC must outlive the
    # context-menu action closure, otherwise releasing its disposable cancels
    # the request before the response arrives.
    if "aorusTranslateDisposableSet" not in t:
        t = t.replace(
            "import AccountContext\n",
            "import AccountContext\nprivate let aorusTranslateDisposableSet = DisposableSet()\n",
            1,
        )

    # New anchor: the Reply-action gate, which runs for both text and voice messages.
    anchor = "        if !isPinnedMessages, !isReplyThreadHead, data.canReply {"
    if anchor not in t:
        print("ChatContextMenu: reply-action anchor not found — skipped")
        return

    injection = (
        "        " + sentinel + "\n"
        "        do {\n"
        "            let aorusMsg = messages[0]\n"
        "            let aorusMid = aorusMsg.id\n"
        "            let aorusBody = aorusMsg.text\n"
        "            let aorusKeyText = \"aorusgram_orig_text_\\(aorusMid.peerId.toInt64())_\\(aorusMid.id)\"\n"
        "            let aorusKeyType = \"aorusgram_orig_type_\\(aorusMid.peerId.toInt64())_\\(aorusMid.id)\"\n"
        "            let aorusSavedText = UserDefaults.standard.string(forKey: aorusKeyText)\n"
        "            let aorusSavedType = UserDefaults.standard.string(forKey: aorusKeyType)\n"
        "            let aorusIsTranslated = aorusSavedType == \"translation\"\n"
        "            let aorusIsTranscribed = aorusSavedType == \"transcription\"\n"
        "            var aorusVoiceFile: TelegramMediaFile?\n"
        "            for aorusMedia in aorusMsg.media {\n"
        "                if let f = aorusMedia as? TelegramMediaFile, f.isVoice {\n"
        "                    aorusVoiceFile = f\n"
        "                    break\n"
        "                }\n"
        "            }\n"
        "\n"
        "            // -- Translate / Show Original (gated by translator flag) --\n"
        "            if UserDefaults.standard.bool(forKey: \"aorusgram_feature_translator\") {\n"
        "                if aorusIsTranslated, let aorusOrig = aorusSavedText {\n"
        "                    actions.append(.action(ContextMenuActionItem(text: \"AorusGram Оригинал\", icon: { theme in\n"
        "                        return generateTintedImage(image: UIImage(bundleImageName: \"Chat/Context Menu/Translate\"), color: theme.actionSheet.primaryTextColor)\n"
        "                    }, action: { [weak context] _, f in\n"
        "                        f(.default)\n"
        "                        guard let context = context else { return }\n"
        "                        let _ = context.account.postbox.transaction { transaction -> Void in\n"
        "                            transaction.updateMessage(aorusMid, update: { current in\n"
        "                                let storeForwardInfo = current.forwardInfo.flatMap(StoreMessageForwardInfo.init)\n"
        "                                let attrs = current.attributes.filter { !($0 is TranslationMessageAttribute) }\n"
        "                                return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: storeForwardInfo, authorId: current.author?.id, text: aorusOrig, attributes: attrs, media: current.media))\n"
        "                            })\n"
        "                        }.start()\n"
        "                        UserDefaults.standard.removeObject(forKey: aorusKeyText)\n"
        "                        UserDefaults.standard.removeObject(forKey: aorusKeyType)\n"
        "                    })))\n"
        "                } else if !aorusBody.isEmpty && !aorusIsTranscribed {\n"
        "                    actions.append(.action(ContextMenuActionItem(text: \"AorusGram Перевод\", icon: { theme in\n"
        "                        return generateTintedImage(image: UIImage(bundleImageName: \"Chat/Context Menu/Translate\"), color: theme.actionSheet.primaryTextColor)\n"
        "                    }, action: { [weak context] _, f in\n"
        "                        f(.default)\n"
        "                        guard let context = context else { return }\n"
        "                        let aorusOriginal = aorusBody\n"
        "                        let aorusTarget = Locale.current.languageCode ?? \"en\"\n"
        "                        // Native Telegram translation engine (messages.translateText):\n"
        "                        // free, no API key, no per-IP limit. The disposable is held in\n"
        "                        // a file-level set so the RPC is not cancelled when this closure\n"
        "                        // returns.\n"
        "                        aorusTranslateDisposableSet.add((context.engine.messages.translate(text: aorusOriginal, toLang: aorusTarget)\n"
        "                        |> deliverOnMainQueue).start(next: { aorusResult in\n"
        "                            guard let aorusPair = aorusResult else { return }\n"
        "                            let aorusTranslated = aorusPair.0\n"
        "                            guard !aorusTranslated.isEmpty, aorusTranslated != aorusOriginal else { return }\n"
        "                            let _ = context.account.postbox.transaction { transaction -> Void in\n"
        "                                transaction.updateMessage(aorusMid, update: { current in\n"
        "                                    let storeForwardInfo = current.forwardInfo.flatMap(StoreMessageForwardInfo.init)\n"
        "                                    let attrs = current.attributes.filter { !($0 is TranslationMessageAttribute) }\n"
        "                                    return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: storeForwardInfo, authorId: current.author?.id, text: aorusTranslated, attributes: attrs, media: current.media))\n"
        "                                })\n"
        "                            }.start()\n"
        "                            UserDefaults.standard.set(aorusOriginal, forKey: aorusKeyText)\n"
        "                            UserDefaults.standard.set(\"translation\", forKey: aorusKeyType)\n"
        "                        }))\n"
        "                    })))\n"
        "                }\n"
        "            }\n"
        "\n"
        "            // -- Transcribe / Hide Transcription (gated by voice transcription flag) --\n"
        "            if UserDefaults.standard.bool(forKey: \"aorusgram_feature_voice_transcription\"), let aorusVoiceFile = aorusVoiceFile {\n"
        "                if aorusIsTranscribed, let aorusOrig = aorusSavedText {\n"
        "                    actions.append(.action(ContextMenuActionItem(text: \"AorusGram Скрыть транскрипцию\", icon: { theme in\n"
        "                        return generateTintedImage(image: UIImage(bundleImageName: \"Chat/Context Menu/Translate\"), color: theme.actionSheet.primaryTextColor)\n"
        "                    }, action: { [weak context] _, f in\n"
        "                        f(.default)\n"
        "                        guard let context = context else { return }\n"
        "                        let _ = context.account.postbox.transaction { transaction -> Void in\n"
        "                            transaction.updateMessage(aorusMid, update: { current in\n"
        "                                let storeForwardInfo = current.forwardInfo.flatMap(StoreMessageForwardInfo.init)\n"
        "                                return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: storeForwardInfo, authorId: current.author?.id, text: aorusOrig, attributes: current.attributes, media: current.media))\n"
        "                            })\n"
        "                        }.start()\n"
        "                        UserDefaults.standard.removeObject(forKey: aorusKeyText)\n"
        "                        UserDefaults.standard.removeObject(forKey: aorusKeyType)\n"
        "                    })))\n"
        "                } else if !aorusIsTranslated {\n"
        "                    actions.append(.action(ContextMenuActionItem(text: \"AorusGram Транскрипция\", icon: { theme in\n"
        "                        return generateTintedImage(image: UIImage(bundleImageName: \"Chat/Context Menu/Translate\"), color: theme.actionSheet.primaryTextColor)\n"
        "                    }, action: { [weak context] _, f in\n"
        "                        f(.default)\n"
        "                        guard let context = context else { return }\n"
        "                        let aorusResource = aorusVoiceFile.resource\n"
        "                        let aorusOriginal = aorusBody\n"
        "                        guard let aorusPath = context.account.postbox.mediaBox.completedResourcePath(aorusResource, pathExtension: \"ogg\") else { return }\n"
        "                        #if canImport(Speech)\n"
        "                        SFSpeechRecognizer.requestAuthorization { status in\n"
        "                            guard status == .authorized else { return }\n"
        "                            guard let aorusRecognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: \"ru-RU\")), aorusRecognizer.isAvailable else { return }\n"
        "                            let aorusReq = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: aorusPath))\n"
        "                            aorusReq.shouldReportPartialResults = false\n"
        "                            aorusReq.taskHint = .dictation\n"
        "                            if aorusRecognizer.supportsOnDeviceRecognition {\n"
        "                                aorusReq.requiresOnDeviceRecognition = true\n"
        "                            }\n"
        "                            _ = aorusRecognizer.recognitionTask(with: aorusReq) { result, error in\n"
        "                                guard let result = result, result.isFinal else { return }\n"
        "                                let aorusText = result.bestTranscription.formattedString\n"
        "                                let _ = context.account.postbox.transaction { transaction -> Void in\n"
        "                                    transaction.updateMessage(aorusMid, update: { current in\n"
        "                                        let storeForwardInfo = current.forwardInfo.flatMap(StoreMessageForwardInfo.init)\n"
        "                                        return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: storeForwardInfo, authorId: current.author?.id, text: aorusText, attributes: current.attributes, media: current.media))\n"
        "                                    })\n"
        "                                }.start()\n"
        "                                DispatchQueue.main.async {\n"
        "                                    UserDefaults.standard.set(aorusOriginal, forKey: aorusKeyText)\n"
        "                                    UserDefaults.standard.set(\"transcription\", forKey: aorusKeyType)\n"
        "                                }\n"
        "                            }\n"
        "                        }\n"
        "                        #endif\n"
        "                    })))\n"
        "                }\n"
        "            }\n"
        "        }\n"
        "\n"
    )
    t = t.replace(anchor, injection + anchor, 1)
    path.write_text(t, encoding="utf-8")
    print("ChatContextMenu: injected AorusGram translate + transcribe v4")


def patch_incoming_message_hook(tg: Path) -> None:
    """Post NotificationCenter event for each incoming message.

    Verified upstream call site is AccountStateManagementUtils.swift around the
    `let _ = transaction.addMessages(messages, location: location)` line that runs
    inside the .UpperHistoryBlock branch — that's the path server-sent message updates
    flow through after they're materialised as `[StoreMessage]`.

    The main-app AorusGramBootstrap observes 'aorusgram.didReceiveMessage' and
    dispatches to:
      - AntiSpamManager.processIncoming (anti-spam keyword scan)
      - AutoReplyManager.handleIncoming  (auto-reply trigger)
      - DeletedMessagesCache.handleIncomingNotification (pre-cache for delete recovery)
    """
    path = tg / "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
    if not path.is_file():
        print("IncomingMessageHook: AccountStateManagementUtils.swift not found, skip")
        return

    t = path.read_text(encoding="utf-8")
    if "aorusgram.didReceiveMessage" in t:
        print("IncomingMessageHook: already injected")
        return

    sentinel = "// AorusGram: incoming message hook"

    # Anchor is intentionally precise — this line exists in current upstream and
    # gives us `messages: [StoreMessage]` in scope.
    anchor = "let _ = transaction.addMessages(messages, location: location)"
    if anchor not in t:
        print("IncomingMessageHook: addMessages(messages, location: location) anchor not found — skipped")
        return

    # StoreMessage.id is StoreMessageId — `.Id(MessageId)` or `.Partial(...)`.
    # We only post for fully-resolved IDs (the .Id case) on the StoreMessage's
    # author/text/timestamp. Filter for .Incoming flag.
    hook_code = (
        sentinel + "\n"
        "                for storeMsg in messages {\n"
        "                    guard storeMsg.flags.contains(.Incoming) else { continue }\n"
        "                    guard case let .Id(mid) = storeMsg.id else { continue }\n"
        "                    var userInfo: [String: Any] = [\n"
        "                        \"msgId\":  NSNumber(value: mid.id),\n"
        "                        \"peerId\": NSNumber(value: mid.peerId.toInt64()),\n"
        "                        \"text\":   storeMsg.text,\n"
        "                        \"date\":   NSNumber(value: storeMsg.timestamp),\n"
        "                    ]\n"
        "                    if let authorId = storeMsg.authorId {\n"
        "                        userInfo[\"senderId\"] = NSNumber(value: authorId.toInt64())\n"
        "                    }\n"
        "                    NotificationCenter.default.post(\n"
        "                        name: NSNotification.Name(\"aorusgram.didReceiveMessage\"),\n"
        "                        object: nil, userInfo: userInfo)\n"
        "                }\n"
        "                "
    )

    t = t.replace(anchor, hook_code + anchor, 1)
    path.write_text(t, encoding="utf-8")
    print("IncomingMessageHook: injected at addMessages(messages, location: location)")


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

    # --- Repair previously injected broken hooks (CI cache / older branding) ---
    repaired = False
    if "aorusgram.sendAutoReply" in t:
        if "let context = self?.context else { return }" in t:
            t = t.replace(
                "let context = self?.context else { return }",
                "let app = self?.contextValue else { return }",
                1,
            )
            repaired = True
        # Telegram iOS uses top-level enqueueMessages(account:peerId:messages:), not *.engine.messages.enqueueMessages
        for wrong_lead, fixed_lead in (
            (
                "let _ = context.engine.messages.enqueueMessages(\n                peerId: peerId,",
                "let _ = enqueueMessages(\n                account: app.context.account,\n                peerId: peerId,",
            ),
            (
                "let _ = app.context.engine.messages.enqueueMessages(\n                peerId: peerId,",
                "let _ = enqueueMessages(\n                account: app.context.account,\n                peerId: peerId,",
            ),
        ):
            if wrong_lead in t:
                t = t.replace(wrong_lead, fixed_lead, 1)
                repaired = True
        if repaired:
            path.write_text(t, encoding="utf-8")
            print("AutoReplySend: repaired legacy auto-reply injection")
            return

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
        "                  let app = self?.contextValue else { return }\n"
        "            let peerId = PeerId(peerIdNum.int64Value)\n"
        "            let _ = enqueueMessages(\n"
        "                account: app.context.account,\n"
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


def patch_chat_title_anti_spoof_status(tg: Path) -> None:
    """Override the chat-header status string when AntiSpoofManager has fresher data.

    The conversation-view header shows "online" / "last seen X min ago" derived from
    the server-provided TelegramUserPresence. When the recipient uses ghost mode the
    server value is stale or "recently/lastWeek/lastMonth" — but we have direct
    evidence they were online from incoming-message timestamps recorded by
    AntiSpoofManager (UserDefaults key aorusgram_peer_last_seen_<peerId>).

    Patch shadows the existing `string` binding with our override, keeping `activity`
    intact. Reads UserDefaults directly to avoid adding a cross-module dep on
    AorusGramUI / AorusGram from the ChatTitleView module.
    """
    path = tg / "submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleView.swift"
    if not path.is_file():
        print("ChatTitleAntiSpoof: ChatTitleView.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: anti-spoof presence override"
    if sentinel in t:
        print("ChatTitleAntiSpoof: already injected")
        return

    # Match the entire source line that contains this binding — using ^ / $ with
    # MULTILINE so `.*` consumes everything including nested parens on that one line.
    # The previous DOTALL + [^)]* approach stopped at Int32(timestamp)'s closing `)`
    # and left the outer `)` of stringAndActivityForUserPresence dangling after }().
    import re as _re
    pattern = _re.compile(
        r"^([ \t]*)let \(string, activity\) = stringAndActivityForUserPresence\(.*\)$",
        flags=_re.MULTILINE,
    )
    match = pattern.search(t)
    if not match:
        print("ChatTitleAntiSpoof: stringAndActivityForUserPresence anchor not found — skipped")
        return

    indent = match.group(1)
    matched = match.group(0)

    # We can't declare `let string` again in the same scope (redeclaration error),
    # and we can't change `let (string, activity)` to `var` without also triggering a
    # warning about `activity` being mutable-but-unused. So we:
    #   1. Rename the destructured `string` → `aorusBaseString`
    #   2. Add a fresh `let string: String = …` that derives its value from
    #      aorusBaseString. Subsequent `NSAttributedString(string: string, …)` lines
    #      now consume our overridden value.
    renamed = matched.replace("(string, activity)", "(aorusBaseString, activity)", 1)
    override = (
        "\n" + indent + sentinel + "\n"
        + indent + "let string: String = {\n"
        + indent + "    let string = aorusBaseString\n"
        + indent + "    guard UserDefaults.standard.bool(forKey: \"aorusgram_antispoof_online\") else { return string }\n"
        + indent + "    if string.range(of: \"в сети\", options: .caseInsensitive) != nil { return string }\n"
        + indent + "    if string.range(of: \"online\", options: .caseInsensitive) != nil { return string }\n"
        + indent + "    let aorusTs = UserDefaults.standard.double(forKey: \"aorusgram_peer_last_seen_\\(peer.id.toInt64())\")\n"
        + indent + "    guard aorusTs > 0 else { return string }\n"
        + indent + "    let ago = Date().timeIntervalSince1970 - aorusTs\n"
        + indent + "    if ago < 60 { return \"в сети • AORUS\" }\n"
        + indent + "    if ago < 3600 { return \"был(а) \\(Int(ago / 60)) мин назад • AORUS\" }\n"
        + indent + "    return string\n"
        + indent + "}()"
    )
    t = t[:match.start()] + renamed + override + t[match.end():]
    path.write_text(t, encoding="utf-8")
    print("ChatTitleAntiSpoof: injected presence override in ChatTitleView.swift")


def patch_anti_spoof_delete_preflight(tg: Path) -> None:
    """Guarantee anti-spoof edit completes BEFORE the delete RPC is even queued.

    Rewrites `_internal_deleteMessagesInteractively` (in TelegramCore) to wrap
    its body in a Signal chain:

        editPreflight  |> then(normalDeleteTransaction)

    The preflight reads outgoing message ids inside a postbox transaction,
    builds a sequential chain of `_internal_requestEditMessage` signals (one
    per id, errors swallowed), and only after the LAST edit's server response
    arrives does the original delete transaction run. The cloud delete operation
    (which schedules the server delete RPC) is registered inside that
    transaction — so it cannot fire before the edits are confirmed.

    This is the deterministic replacement for the previous notification-based
    fire-and-forget approach which raced the edit and delete RPCs in parallel.
    """
    path = tg / "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
    if not path.is_file():
        print("AntiSpoofDeletePreflight: DeleteMessagesInteractively.swift not found")
        return
    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: anti-spoof deleted preflight"
    if sentinel in t:
        print("AntiSpoofDeletePreflight: already injected")
        return

    needle = (
        "func _internal_deleteMessagesInteractively(account: Account, messageIds: [MessageId], "
        "type: InteractiveMessagesDeletionType, deleteAllInGroup: Bool = false) -> Signal<Void, NoError> {\n"
        "    return account.postbox.transaction { transaction -> Void in\n"
        "        deleteMessagesInteractively(transaction: transaction, stateManager: account.stateManager, "
        "postbox: account.postbox, messageIds: messageIds, type: type, removeIfPossiblyDelivered: true)\n"
        "    }\n"
        "}"
    )
    if needle not in t:
        print("AntiSpoofDeletePreflight: anchor not found — skipped")
        return

    replacement = (
        "func _internal_deleteMessagesInteractively(account: Account, messageIds: [MessageId], "
        "type: InteractiveMessagesDeletionType, deleteAllInGroup: Bool = false) -> Signal<Void, NoError> {\n"
        "    " + sentinel + "\n"
        "    let normalDelete: Signal<Void, NoError> = account.postbox.transaction { transaction -> Void in\n"
        "        deleteMessagesInteractively(transaction: transaction, stateManager: account.stateManager, "
        "postbox: account.postbox, messageIds: messageIds, type: type, removeIfPossiblyDelivered: true)\n"
        "    }\n"
        "    guard UserDefaults.standard.bool(forKey: \"aorusgram_antispoof_deleted\"), type == .forEveryone else {\n"
        "        return normalDelete\n"
        "    }\n"
        "    return account.postbox.transaction { transaction -> [MessageId] in\n"
        "        return messageIds.filter { id in\n"
        "            guard let msg = transaction.getMessage(id) else { return false }\n"
        "            return !msg.flags.contains(.Incoming) && !msg.text.isEmpty && !msg.text.hasPrefix(\"Ты не увидишь\")\n"
        "        }\n"
        "    }\n"
        "    |> mapToSignal { (outgoingIds: [MessageId]) -> Signal<Void, NoError> in\n"
        "        guard !outgoingIds.isEmpty else { return normalDelete }\n"
        "        let decoy = \"Ты не увидишь это сообщение. Привет от AORUS! 🔥\"\n"
        "        let initial: Signal<Void, NoError> = .complete()\n"
        "        let editPreflight: Signal<Void, NoError> = outgoingIds.reduce(initial) { acc, msgId -> Signal<Void, NoError> in\n"
        "            let editSignal: Signal<Void, NoError> = _internal_requestEditMessage(\n"
        "                account: account,\n"
        "                messageId: msgId,\n"
        "                text: decoy,\n"
        "                media: .keep,\n"
        "                entities: nil,\n"
        "                inlineStickers: [:],\n"
        "                webpagePreviewAttribute: nil,\n"
        "                disableUrlPreview: false,\n"
        "                scheduleInfoAttribute: nil,\n"
        "                invertMediaAttribute: nil\n"
        "            )\n"
        "            |> map { _ -> Void in }\n"
        "            |> `catch` { _ -> Signal<Void, NoError> in .complete() }\n"
        "            return acc |> then(editSignal)\n"
        "        }\n"
        "        return editPreflight |> then(normalDelete)\n"
        "    }\n"
        "}"
    )
    t = t.replace(needle, replacement, 1)
    path.write_text(t, encoding="utf-8")
    print("AntiSpoofDeletePreflight: rewrote _internal_deleteMessagesInteractively with edit-before-delete chain")


def patch_app_delegate_import_telegram_api(tg: Path) -> None:
    """Ensure AppDelegate.swift imports TelegramApi so we can call Api.functions.*.

    Most Telegram-iOS builds already import TelegramApi here, but we add it
    defensively because the anti-spoof-delete observer references
    Api.functions.messages.editMessage / Api.InputPeer.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        return
    t = path.read_text(encoding="utf-8")
    if "import TelegramApi" in t:
        return
    needle = "import TelegramCore"
    pos = t.find(needle)
    if pos == -1:
        return
    line_end = t.find("\n", pos)
    if line_end == -1:
        return
    t = t[:line_end + 1] + "import TelegramApi\n" + t[line_end + 1:]
    path.write_text(t, encoding="utf-8")
    print("AppDelegate: added import TelegramApi after import TelegramCore")


def patch_app_delegate_anti_spoof_delete_observer(tg: Path) -> None:
    """Observe aorusgram.antiSpoofDelete notification and send editMessage RPC.

    The notification is posted by the patched transaction.deleteMessages hook for
    each outgoing message the user is deleting. We go through the public engine
    API (context.engine.messages.requestEditMessage) which handles InputPeer
    construction internally via the postbox. The peer (not the message) stays in
    postbox even after a message is deleted, so the engine call always finds it.
    The server processes the edit RPC, then when the delete RPC arrives later
    (from the operation queue) the message text on the server is already the decoy.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        print("AntiSpoofDeleteObserver: AppDelegate.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    if "aorusgram.antiSpoofDelete" in t:
        print("AntiSpoofDeleteObserver: already injected")
        return
    sentinel = "// AorusGram: anti-spoof delete observer"
    hook = (
        "\n        " + sentinel + "\n"
        "        NotificationCenter.default.addObserver(forName: NSNotification.Name(\"aorusgram.antiSpoofDelete\"),\n"
        "            object: nil, queue: .main) { [weak self] note in\n"
        "            guard UserDefaults.standard.bool(forKey: \"aorusgram_antispoof_deleted\"),\n"
        "                  let info = note.userInfo,\n"
        "                  let peerIdNum = info[\"peerId\"] as? NSNumber,\n"
        "                  let msgIdNum  = info[\"msgId\"]  as? NSNumber,\n"
        "                  let app = self?.contextValue else { return }\n"
        "            let peerId = PeerId(peerIdNum.int64Value)\n"
        "            let msgId  = msgIdNum.int32Value\n"
        "            let messageId = MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: msgId)\n"
        "            let decoy = \"Ты не увидишь это сообщение. Привет от AORUS! 🔥\"\n"
        "            let _ = app.context.engine.messages.requestEditMessage(\n"
        "                messageId: messageId,\n"
        "                text: decoy,\n"
        "                media: .keep,\n"
        "                entities: nil,\n"
        "                inlineStickers: [:],\n"
        "                disableUrlPreview: false\n"
        "            ).start(error: { _ in })\n"
        "        }\n"
    )
    anchor = "AorusGramBootstrap.shared.setup(accountPath: rootPath)"
    if anchor in t:
        t = t.replace(anchor, anchor + hook, 1)
        path.write_text(t, encoding="utf-8")
        print("AntiSpoofDeleteObserver: observer injected into AppDelegate")
    else:
        print("AntiSpoofDeleteObserver: bootstrap anchor not found — skipped gracefully")


def patch_app_delegate_account_restore_hook(tg: Path) -> None:
    """Apply a pending account-backup restore at the very start of app launch.

    AccountBackupManager.prepareRestore() (run from the settings UI) decrypts a
    backup into a staging directory and raises a UserDefaults flag. This hook —
    injected right after `rootPath` is resolved and BEFORE performAppGroupUpgrades
    or any postbox is opened — swaps the staged account data into place, taking a
    safety snapshot of the current data first. Running this pre-postbox is what
    makes the restore safe: nothing has the account databases open yet.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        print("AccountRestoreHook: AppDelegate.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    if "AccountBackupManager.applyPendingRestoreIfNeeded" in t:
        print("AccountRestoreHook: already injected")
        return
    anchor = (
        "        if !isUITest {\n"
        "            performAppGroupUpgrades(appGroupPath: appGroupUrl.path, rootPath: rootPath)\n"
        "        }\n"
    )
    if anchor not in t:
        print("AccountRestoreHook: performAppGroupUpgrades anchor not found — skipped")
        return
    hook = (
        "        // AorusGram: apply a pending account-backup restore before any postbox opens\n"
        "        AccountBackupManager.applyPendingRestoreIfNeeded(rootPath: rootPath)\n"
    )
    t = t.replace(anchor, hook + anchor, 1)
    path.write_text(t, encoding="utf-8")
    print("AccountRestoreHook: injected applyPendingRestoreIfNeeded before performAppGroupUpgrades")


def patch_app_delegate_siri_continue_activity(tg: Path) -> None:
    """Route NSUserActivity continuations through SiriShortcutsManager.handle.

    When Siri invokes a donated shortcut, iOS calls
    application(_:continue:restorationHandler:). We inject a prefix that lets
    AorusGram-prefixed activity types short-circuit through SiriShortcutsManager
    before the upstream Telegram handling. If our handler claims it (returns
    true), the default handling is suppressed.
    """
    path = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not path.is_file():
        print("SiriContinue: AppDelegate.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    sentinel = "// AorusGram: Siri activity continuation"
    if sentinel in t:
        print("SiriContinue: already injected")
        return

    # Find a matching signature. Telegram iOS overloads this method; we target the
    # one with NSUserActivity + restorationHandler signature (the canonical form).
    candidates = [
        "func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler",
        "func application(_ application: UIApplication, continue userActivity: NSUserActivity,",
    ]
    method_pos = -1
    for cand in candidates:
        method_pos = t.find(cand)
        if method_pos != -1:
            break

    if method_pos == -1:
        print("SiriContinue: continueUserActivity method not found — skipped")
        return

    open_brace = t.find("{", method_pos)
    if open_brace == -1:
        print("SiriContinue: opening brace not found — skipped")
        return

    injection = (
        "\n        " + sentinel + "\n"
        "        if #available(iOS 16.0, *),\n"
        "           userActivity.activityType.hasPrefix(\"com.aorusgram.\"),\n"
        "           SiriShortcutsManager.shared.handle(activity: userActivity) {\n"
        "            return true\n"
        "        }\n"
    )
    t = t[:open_brace + 1] + injection + t[open_brace + 1:]
    path.write_text(t, encoding="utf-8")
    print("SiriContinue: injected Siri activity handler prefix into AppDelegate")


def patch_peer_info_account_details(tg: Path) -> None:
    """Add a "Подробнее" row to user, channel and group profiles.

    Patches PeerInfoProfileItems.swift (the `infoItems` builder) to append a
    PeerInfoScreenDisclosureItem in the user, channel and legacy-group blocks.
    Tapping it pushes accountDetailsController (AorusGramUI) which shows the id,
    the data-center, and a creation date: estimated from the numeric id for
    users, and the exact Telegram-provided creationDate for channels / groups.
    """
    path = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoProfileItems.swift"
    if not path.is_file():
        print("PeerInfoAccountDetails: PeerInfoProfileItems.swift not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    if "AorusGram: account details" in t:
        print("PeerInfoAccountDetails: already injected")
        return

    # import AorusGramUI (so accountDetailsController / AorusDetailKind are visible)
    if "import AorusGramUI" not in t:
        needle = "import Foundation\n"
        if needle not in t:
            print("PeerInfoAccountDetails: import anchor not found — skipped")
            return
        t = t.replace(needle, needle + "import AorusGramUI\n", 1)

    def disclosure(peer_var: str, kind_expr: str, creation_expr: str, item_id: int) -> str:
        return (
            "\n"
            "        // AorusGram: account details (\"Подробнее\") row\n"
            "        do {\n"
            "            let aorusEntityId = " + peer_var + ".id.id._internalGetInt64Value()\n"
            "            var aorusDcId: Int = 0\n"
            "            for aorusRep in " + peer_var + ".photo {\n"
            "                if let aorusRes = aorusRep.resource as? CloudPeerPhotoSizeMediaResource {\n"
            "                    aorusDcId = aorusRes.datacenterId\n"
            "                    break\n"
            "                }\n"
            "            }\n"
            "            let aorusTitle = EnginePeer(" + peer_var + ").compactDisplayTitle\n"
            "            let aorusKind: AorusDetailKind = " + kind_expr + "\n"
            "            let aorusCreation: Int32 = " + creation_expr + "\n"
            "            items[currentPeerInfoSection]!.append(PeerInfoScreenDisclosureItem(id: " + str(item_id) + ", text: \"Подробнее\", action: {\n"
            "                guard let aorusParent = interaction.getController(),\n"
            "                      let aorusNav = aorusParent.navigationController as? NavigationController else {\n"
            "                    return\n"
            "                }\n"
            "                aorusNav.pushViewController(accountDetailsController(context: context, entityId: aorusEntityId, dcId: aorusDcId, title: aorusTitle, kind: aorusKind, creationDate: aorusCreation))\n"
            "            }))\n"
            "        }\n"
        )

    applied = []

    # User block — inject after the item-id constants.
    user_anchor = "        let ItemVerification = 9004\n"
    if user_anchor in t:
        t = t.replace(user_anchor, user_anchor + disclosure("user", ".user", "0", 770077), 1)
        applied.append("user")

    # Channel / supergroup block — inject after the item-id constants.
    chan_anchor = "        let ItemPeerPersonalChannel = 11\n"
    if chan_anchor in t:
        chan_kind = "{ if case .broadcast = channel.info { return .channel } else { return .group } }()"
        t = t.replace(chan_anchor, chan_anchor + disclosure("channel", chan_kind, "channel.creationDate", 770078), 1)
        applied.append("channel")

    # Legacy group block — inject right after the block opens.
    grp_anchor = "    } else if case let .legacyGroup(group) = data.peer {\n"
    if grp_anchor in t:
        t = t.replace(grp_anchor, grp_anchor + disclosure("group", ".group", "group.creationDate", 770079), 1)
        applied.append("group")

    if not applied:
        print("PeerInfoAccountDetails: no anchors found — skipped")
        return
    path.write_text(t, encoding="utf-8")
    print("PeerInfoAccountDetails: injected Подробнее row for " + ", ".join(applied))


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


def patch_info_plist_speech_usage(tg: Path) -> None:
    """Add NSSpeechRecognitionUsageDescription to Info.plist.

    Without this key, calling SFSpeechRecognizer.requestAuthorization triggers
    an immediate hard crash with the system message:
      "This app has crashed because it attempted to access privacy-sensitive
       data without a usage description."
    Required by both the VoiceTranscriberView (microphone live recording) and
    the long-press transcribe action on voice messages.

    NSMicrophoneUsageDescription is already present upstream (Telegram uses it
    for voice messages), so we only need to add the speech recognition key.
    """
    description = (
        "AorusGram использует распознавание речи для транскрипции голосовых "
        "сообщений прямо на устройстве (никакие данные не покидают ваш телефон)."
    )
    for name in ("Info.plist", "InfoBazel.plist"):
        path = tg / "Telegram/Telegram-iOS" / name
        if not path.is_file():
            continue
        with path.open("rb") as f:
            pl = plistlib.load(f)
        if pl.get("NSSpeechRecognitionUsageDescription"):
            print(f"{name}: NSSpeechRecognitionUsageDescription already present")
            continue
        pl["NSSpeechRecognitionUsageDescription"] = description
        with path.open("wb") as f:
            plistlib.dump(pl, f, fmt=plistlib.FMT_XML)
        print(f"{name}: added NSSpeechRecognitionUsageDescription")


# Inline Swift that builds an MTSocksProxySettings from the flat UserDefaults
# keys written by AorusProxyManager (aorusgram_proxy_server / _port / _secret).
# Returns nil when no system proxy is configured. Foundation + MtProtoKit only —
# safe to inline into TelegramCore (no UIKit). The fake-TLS secret is stored as a
# hex string and decoded to Data here.
_AORUS_PROXY_SNIPPET = (
    "({ () -> MTSocksProxySettings? in\n"
    "                let aorusDefaults = UserDefaults.standard\n"
    "                guard let aorusHost = aorusDefaults.string(forKey: \"aorusgram_proxy_server\"), !aorusHost.isEmpty else { return nil }\n"
    "                let aorusPort = aorusDefaults.integer(forKey: \"aorusgram_proxy_port\")\n"
    "                guard aorusPort > 0, let aorusSecretHex = aorusDefaults.string(forKey: \"aorusgram_proxy_secret\"), !aorusSecretHex.isEmpty else { return nil }\n"
    "                var aorusSecret = Data(capacity: aorusSecretHex.count / 2)\n"
    "                var aorusIdx = aorusSecretHex.startIndex\n"
    "                while aorusIdx < aorusSecretHex.endIndex {\n"
    "                    let aorusNext = aorusSecretHex.index(aorusIdx, offsetBy: 2, limitedBy: aorusSecretHex.endIndex) ?? aorusSecretHex.endIndex\n"
    "                    if let aorusByte = UInt8(aorusSecretHex[aorusIdx..<aorusNext], radix: 16) { aorusSecret.append(aorusByte) }\n"
    "                    aorusIdx = aorusNext\n"
    "                }\n"
    "                return MTSocksProxySettings(ip: aorusHost, port: UInt16(clamping: aorusPort), username: nil, password: nil, secret: aorusSecret)\n"
    "            })()"
)


def patch_system_proxy_network_override(tg: Path) -> None:
    """Force the AorusGram system proxy onto every MTProto connection.

    The proxy is applied at the network layer (MTApiEnvironment) and is NEVER
    stored in ProxySettings, so it never appears in the proxy list UI, has no
    on/off toggle, shows no proxy status icon and cannot be copied as a
    tg://proxy link. All DC connections, media, file downloads, updates and
    call signalling inherit it because they all flow through this single
    MTApiEnvironment chokepoint.
    """
    path = tg / "submodules/TelegramCore/Sources/Network/Network.swift"
    if not path.is_file():
        print("Network.swift not found, skip system proxy override")
        return
    t = path.read_text(encoding="utf-8")
    if "aorusgram_proxy_server" in t:
        print("Network.swift: system proxy override already present")
        return

    anchor = (
        "            if let effectiveActiveServer = proxySettings?.effectiveActiveServer {\n"
        "                apiEnvironment = apiEnvironment.withUpdatedSocksProxySettings(effectiveActiveServer.mtProxySettings)\n"
        "            }\n"
    )
    injection = anchor + (
        "            // AorusGram: system proxy overrides any user setting and is applied\n"
        "            // invisibly at the network layer (never stored in ProxySettings).\n"
        "            if let aorusSystemProxy = " + _AORUS_PROXY_SNIPPET + " {\n"
        "                apiEnvironment = apiEnvironment.withUpdatedSocksProxySettings(aorusSystemProxy)\n"
        "            }\n"
    )
    if anchor in t:
        t = t.replace(anchor, injection, 1)
        path.write_text(t, encoding="utf-8")
        print("Network.swift: injected AorusGram system proxy override")
    else:
        print("WARNING: Network.swift proxy anchor not found — system proxy NOT applied")


def patch_system_proxy_runtime_monitor(tg: Path) -> None:
    """Keep the system proxy applied at runtime and reconnect when it arrives.

    1. The existing shared-data proxy monitor is patched so the AorusGram system
       proxy always wins over whatever (if anything) is in ProxySettings.
    2. A NotificationCenter observer reacts to `aorusgram_proxy_config_updated`
       (posted by AorusProxyManager after a fresh fetch) and re-applies the
       proxy + drops the connection so the very first launch starts using the
       proxy as soon as the control API responds — without needing a relaunch.
    """
    path = tg / "submodules/TelegramCore/Sources/Account/Account.swift"
    if not path.is_file():
        print("Account.swift not found, skip system proxy runtime monitor")
        return
    t = path.read_text(encoding="utf-8")
    if "aorusgram_proxy_config_updated" in t:
        print("Account.swift: system proxy runtime monitor already present")
        return

    # 1) Force system proxy to win inside the existing monitor.
    monitor_anchor = (
        "        |> distinctUntilChanged).start(next: { activeServer in\n"
        "            let updated = activeServer.flatMap { activeServer -> MTSocksProxySettings? in\n"
        "                return activeServer.mtProxySettings\n"
        "            }\n"
    )
    monitor_replacement = (
        "        |> distinctUntilChanged).start(next: { activeServer in\n"
        "            var updated = activeServer.flatMap { activeServer -> MTSocksProxySettings? in\n"
        "                return activeServer.mtProxySettings\n"
        "            }\n"
        "            if let aorusSystemProxy = " + _AORUS_PROXY_SNIPPET + " { updated = aorusSystemProxy }\n"
    )

    # 2) Observer block, injected right after the monitor's closing `}))`.
    monitor_close = monitor_replacement + (
        "            network.context.updateApiEnvironment { environment in\n"
        "                let current = environment?.socksProxySettings\n"
        "                let updateNetwork: Bool\n"
        "                if let current = current, let updated = updated {\n"
        "                    updateNetwork = !current.isEqual(updated)\n"
        "                } else {\n"
        "                    updateNetwork = (current != nil) != (updated != nil)\n"
        "                }\n"
        "                if updateNetwork {\n"
        "                    network.dropConnectionStatus()\n"
        "                    return environment?.withUpdatedSocksProxySettings(updated)\n"
        "                } else {\n"
        "                    return nil\n"
        "                }\n"
        "            }\n"
        "        }))\n"
    )

    observer_block = monitor_close + (
        "        // AorusGram: apply the system proxy the moment the control API\n"
        "        // delivers a fresh config (first launch needs no relaunch).\n"
        "        self.managedOperationsDisposable.add({ () -> Disposable in\n"
        "            let aorusObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(\"aorusgram_proxy_config_updated\"), object: nil, queue: nil) { _ in\n"
        "                let updated = " + _AORUS_PROXY_SNIPPET + "\n"
        "                network.context.updateApiEnvironment { environment in\n"
        "                    let current = environment?.socksProxySettings\n"
        "                    let updateNetwork: Bool\n"
        "                    if let current = current, let updated = updated {\n"
        "                        updateNetwork = !current.isEqual(updated)\n"
        "                    } else {\n"
        "                        updateNetwork = (current != nil) != (updated != nil)\n"
        "                    }\n"
        "                    if updateNetwork {\n"
        "                        network.dropConnectionStatus()\n"
        "                        return environment?.withUpdatedSocksProxySettings(updated)\n"
        "                    } else {\n"
        "                        return nil\n"
        "                    }\n"
        "                }\n"
        "            }\n"
        "            return ActionDisposable { NotificationCenter.default.removeObserver(aorusObserver) }\n"
        "        }())\n"
    )

    # The full original block we are replacing (monitor_anchor + its body + close).
    original_block = (
        monitor_anchor +
        "            network.context.updateApiEnvironment { environment in\n"
        "                let current = environment?.socksProxySettings\n"
        "                let updateNetwork: Bool\n"
        "                if let current = current, let updated = updated {\n"
        "                    updateNetwork = !current.isEqual(updated)\n"
        "                } else {\n"
        "                    updateNetwork = (current != nil) != (updated != nil)\n"
        "                }\n"
        "                if updateNetwork {\n"
        "                    network.dropConnectionStatus()\n"
        "                    return environment?.withUpdatedSocksProxySettings(updated)\n"
        "                } else {\n"
        "                    return nil\n"
        "                }\n"
        "            }\n"
        "        }))\n"
    )

    if original_block in t:
        t = t.replace(original_block, observer_block, 1)
        path.write_text(t, encoding="utf-8")
        print("Account.swift: injected system proxy runtime monitor + config-update observer")
    else:
        print("WARNING: Account.swift proxy monitor block not found — runtime monitor NOT applied")


def patch_disable_call_p2p(tg: Path) -> None:
    """Force every call through Telegram relays — never direct peer-to-peer.

    With P2P the two devices exchange UDP directly, exposing each other's real
    IP. Forcing relay keeps the user's IP private (the peer only ever sees a
    Telegram reflector). Call signalling already rides the proxied MTProto
    connection; the media leg uses Telegram relays. (MTProxy cannot tunnel the
    WebRTC/UDP media leg itself — that is a Telegram protocol limitation, so
    relay-forcing is the strongest available privacy guarantee for calls.)
    """
    path = tg / "submodules/TelegramVoip/Sources/OngoingCallContext.swift"
    if not path.is_file():
        print("OngoingCallContext.swift not found, skip call P2P disable")
        return
    t = path.read_text(encoding="utf-8")
    if "AorusGram: never use direct peer-to-peer" in t:
        print("OngoingCallContext.swift: call P2P disable already present")
        return

    anchor = "                var allowP2P = allowP2P\n"
    replacement = (
        "                var allowP2P = allowP2P\n"
        "                // AorusGram: never use direct peer-to-peer for calls — forces\n"
        "                // media through Telegram relays so the user's IP is never\n"
        "                // exposed to the call peer.\n"
        "                allowP2P = false\n"
    )
    if anchor in t:
        t = t.replace(anchor, replacement, 1)
        path.write_text(t, encoding="utf-8")
        print("OngoingCallContext.swift: forced allowP2P = false (relay-only calls)")
    else:
        print("WARNING: OngoingCallContext.swift allowP2P anchor not found — P2P NOT disabled")




def patch_intro_brand_logo(tg: Path) -> None:
    """Replace the OpenGL Telegram paper-plane logo on the intro/welcome screen
    with the AorusGram brand logo.

    The intro logo is rendered by an OpenGL GLKView (RMIntroViewController.m,
    fed by telegram_sphere.png / telegram_plane1.png textures). Rather than fight
    the GL animation we overlay an opaque UIImageView (the brand logo, embedded as
    a base64 PNG) as a subview of the GLKView, filling its bounds. Because it is a
    child of _glkView it inherits every position/scale transform the controller
    applies during page transitions, so it tracks the original logo exactly. The
    logo art sits on black, matching the intro background, so edges blend cleanly.
    """
    path = tg / "submodules/RMIntro/Sources/platform/ios/RMIntroViewController.m"
    if not path.is_file():
        print("IntroLogo: RMIntroViewController.m not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    if "AorusGram: brand logo overlay" in t:
        print("IntroLogo: already injected")
        return
    anchor = "        [self.view addSubview:_glkView];\n"
    if anchor not in t:
        print("IntroLogo: addSubview:_glkView anchor not found — skipped")
        return
    inject = (
        "        // AorusGram: brand logo overlay (covers the GL Telegram logo)\n"
        "        {\n"
        "            UIImageView *aorusIntroLogo = [[UIImageView alloc] initWithFrame:_glkView.bounds];\n"
        "            aorusIntroLogo.contentMode = UIViewContentModeScaleAspectFit;\n"
        "            aorusIntroLogo.userInteractionEnabled = NO;\n"
        "            aorusIntroLogo.backgroundColor = _backgroundColor;\n"
        "            aorusIntroLogo.opaque = YES;\n"
        "            aorusIntroLogo.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;\n"
        "            NSData *aorusLogoData = [[NSData alloc] initWithBase64EncodedString:@\"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\" options:NSDataBase64DecodingIgnoreUnknownCharacters];\n"
        "            if (aorusLogoData != nil) {\n"
        "                aorusIntroLogo.image = [UIImage imageWithData:aorusLogoData];\n"
        "            }\n"
        "            [_glkView addSubview:aorusIntroLogo];\n"
        "        }\n"
    )
    t = t.replace(anchor, anchor + inject, 1)
    path.write_text(t, encoding="utf-8")
    print("IntroLogo: brand logo overlay injected into RMIntroViewController.m")


def patch_intro_animation_snapshot(tg: Path) -> None:
    """Make the intro→login transition snapshot include the brand logo overlay.

    createAnimationSnapshot() captured `_glkView.snapshot`, which reads ONLY the
    OpenGL framebuffer (the original Telegram paper-plane) and ignores UIKit
    subviews — so our brand logo overlay was missing from the transition image and
    the Telegram logo flashed for a moment when the user tapped Continue. We render
    the full GLKView view hierarchy (GL content + opaque brand overlay on top)
    into the snapshot image instead. Idempotent.
    """
    path = tg / "submodules/RMIntro/Sources/platform/ios/RMIntroViewController.m"
    if not path.is_file():
        print("IntroSnapshot: RMIntroViewController.m not found, skip")
        return
    t = path.read_text(encoding="utf-8")
    if "AorusGram: snapshot full GLKView hierarchy" in t:
        print("IntroSnapshot: already patched")
        return
    old = "    UIImage *image = _glkView.snapshot;\n"
    if old not in t:
        print("IntroSnapshot: WARNING _glkView.snapshot anchor not found — skipped")
        return
    new = (
        "    // AorusGram: snapshot full GLKView hierarchy (GL content + brand logo\n"
        "    // overlay). _glkView.snapshot reads only the GL framebuffer (the original\n"
        "    // Telegram logo) and ignores UIKit subviews, which made that logo flash\n"
        "    // during the intro transition. Local strong ref avoids implicit self\n"
        "    // capture inside the block (-Wimplicit-retain-self).\n"
        "    GLKView *aorusGLKView = _glkView;\n"
        "    UIGraphicsImageRendererFormat *aorusFmt = [UIGraphicsImageRendererFormat preferredFormat];\n"
        "    aorusFmt.opaque = NO;\n"
        "    UIGraphicsImageRenderer *aorusRenderer = [[UIGraphicsImageRenderer alloc] initWithBounds:aorusGLKView.bounds format:aorusFmt];\n"
        "    UIImage *image = [aorusRenderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull aorusCtx) {\n"
        "        [aorusGLKView drawViewHierarchyInRect:aorusGLKView.bounds afterScreenUpdates:NO];\n"
        "    }];\n"
    )
    t = t.replace(old, new, 1)
    path.write_text(t, encoding="utf-8")
    print("IntroSnapshot: createAnimationSnapshot now includes brand logo overlay")


def patch_alternate_icons(tg: Path) -> None:
    """Replace all alternate icons in Appearance settings with the user's icons.

    User icons live in patches/alticons/ as pre-rendered .alticon folders (loose
    PNGs, full iPhone+iPad size set) consumed by ios_application(alternate_icons);
    they switch the home-screen icon and double as the picker preview via
    UIImage(named:). The first entry "MainIcon" is the default
    (is_default=True): the picker shows the brand logo as "Основная" and selecting
    it reverts to the primary app icon. Old Telegram icons are deleted. BUILD
    alternate_icon_folders, AppDelegate getAvailableAlternateIcons list, and
    ThemeSettingsAppIconItem Russian display names are all patched atomically.
    """
    import shutil

    # (icon_name, display_name_ru, is_default)
    # "MainIcon" must be first and is_default=True (name avoids the Bazel target "Main"): selecting it calls
    # requestSetAlternateIconName(nil) which reverts to the primary brand icon
    # (AppIconLLC). Its preview appiconset (patches/alticons/Main.appiconset) is
    # rendered from the same brand logo, so the picker shows our icon as "Основная".
    # (icon_name, display_name_ru, display_name_en, is_default)
    ICONS = [
        ("MainIcon",   "Основная",     "Default",     True),
        ("Airplane",   "Самолет",      "Airplane",    False),
        ("Sky",        "Небо",         "Sky",         False),
        ("SkyWhite",   "Небо-белый",   "Sky White",   False),
        ("Sunset",     "Закат",        "Sunset",      False),
        ("Cosmos",     "Космос",       "Cosmos",      False),
        ("Duck",       "Утка",         "Duck",        False),
        ("BlueWhite",  "Сине-белая",   "Blue White",  False),
        ("BlackWhite", "Черно-белая",  "Black White", False),
        ("Black",      "Черный",       "Black",       False),
    ]

    repo_root = Path(__file__).resolve().parent.parent
    alticons_src = repo_root / "patches/alticons"
    if not alticons_src.is_dir():
        print("AlternateIcons: patches/alticons not found, skip")
        return

    iosdir = tg / "Telegram/Telegram-iOS"
    if not iosdir.is_dir():
        print(f"AlternateIcons: {iosdir} not found, skip")
        return

    # Alternate icons in this build are .alticon folders of loose PNGs (no
    # Contents.json). The ios_application(alternate_icons=...) rule copies them to
    # the bundle root and synthesises CFBundleAlternateIcons; the settings picker
    # then loads previews via UIImage(named: "<Icon>") from those same bundle-root
    # PNGs. (AppIcons.xcassets is NOT bundled — its filegroup is unreferenced.)

    # Remove all stock .alticon folders so only our icons remain.
    for d in iosdir.glob("*.alticon"):
        shutil.rmtree(d)
        print(f"AlternateIcons: removed {d.name}")
    # Remove stock alternate appiconsets too (cosmetic — catalog is unused).
    xcassets = iosdir / "AppIcons.xcassets"
    if xcassets.is_dir():
        for name in ("BlackIcon", "BlackClassicIcon", "BlackFilledIcon",
                     "BlueClassicIcon", "BlueFilledIcon", "WhiteFilledIcon",
                     "New1", "New2", "Premium", "PremiumBlack", "PremiumTurbo"):
            d = xcassets / f"{name}.appiconset"
            if d.exists():
                shutil.rmtree(d)

    # Install our .alticon folders (pre-rendered loose PNGs from patches/alticons/).
    for icon_name, _, _, _ in ICONS:
        src_alticon = alticons_src / f"{icon_name}.alticon"
        if not src_alticon.is_dir():
            print(f"AlternateIcons: WARNING {icon_name}.alticon not in patches/alticons, skip")
            continue
        dst_alticon = iosdir / f"{icon_name}.alticon"
        if dst_alticon.exists():
            shutil.rmtree(dst_alticon)
        shutil.copytree(src_alticon, dst_alticon)
        print(f"AlternateIcons: installed {icon_name}.alticon ({len(list(src_alticon.glob('*.png')))} pngs)")

    # Update alternate_icon_folders in Telegram/BUILD
    build = tg / "Telegram/BUILD"
    if build.is_file():
        t = build.read_text(encoding="utf-8")
        new_folders = ", ".join(f'"{n}"' for n, _, _, _ in ICONS)
        t_new = re.sub(
            r"alternate_icon_folders\s*=\s*\[.*?\]",
            f"alternate_icon_folders = [{new_folders}]",
            t,
            flags=re.DOTALL,
        )
        if t_new != t:
            build.write_text(t_new, encoding="utf-8")
            print("AlternateIcons: updated alternate_icon_folders in BUILD")
        else:
            print("AlternateIcons: WARNING alternate_icon_folders not found/changed in BUILD")

    # Patch AppDelegate.swift: replace getAvailableAlternateIcons icon list.
    # Idempotent: works on both the original Telegram tree (var icons = [)
    # and a cached tree that was already patched (let icons: [PresentationAppIcon]).
    delegate = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if delegate.is_file():
        t = delegate.read_text(encoding="utf-8")
        closure_marker = "getAvailableAlternateIcons: {"
        closure_idx = t.find(closure_marker)
        if closure_idx >= 0:
            return_icons_idx = t.find("return icons", closure_idx)
            # Accept both the original "var icons = [" and already-patched "let icons: [PresentationAppIcon]"
            icons_var_idx = -1
            for needle in ("var icons = [", "let icons: [PresentationAppIcon]"):
                idx = t.find(needle, closure_idx)
                if 0 <= idx < return_icons_idx:
                    icons_var_idx = idx
                    break
            if icons_var_idx >= 0 and return_icons_idx > icons_var_idx:
                # Replace the whole span from the declaration line through the end
                # of the "return icons" line, re-emitting both with clean indent.
                decl_line_start = t.rfind("\n", 0, icons_var_idx) + 1
                indent = " " * (icons_var_idx - decl_line_start)
                return_line_end = t.find("\n", return_icons_idx)
                if return_line_end < 0:
                    return_line_end = len(t)
                lines = [f'{indent}let icons: [PresentationAppIcon] = [']
                for n, _, _, is_default in ICONS:
                    default_arg = ", isDefault: true" if is_default else ""
                    lines.append(f'{indent}    PresentationAppIcon(name: "{n}", imageName: "{n}"{default_arg}),')
                lines.append(f'{indent}]')
                lines.append(f'{indent}return icons')
                new_block = "\n".join(lines)
                t = t[:decl_line_start] + new_block + t[return_line_end:]
                delegate.write_text(t, encoding="utf-8")
                print("AlternateIcons: patched AppDelegate getAvailableAlternateIcons")
            else:
                print("AlternateIcons: WARNING icons list not found in AppDelegate closure")
        else:
            print("AlternateIcons: WARNING getAvailableAlternateIcons not found in AppDelegate")

    # Patch ThemeSettingsAppIconItem.swift: add Russian display names to switch
    icon_item = tg / "submodules/SettingsUI/Sources/Themes/ThemeSettingsAppIconItem.swift"
    if icon_item.is_file():
        t = icon_item.read_text(encoding="utf-8")
        old_default = (
            "                                default:\n"
            "                                    name = icon.name"
        )
        # Idempotent cleanup: strip any previously-inserted AorusGram cases (including
        # the legacy "Main" name used before the rename to "MainIcon"). The name-
        # assignment RHS matches both the old plain-string form and the new
        # localized ternary form, so the patch is safe on fresh and cached trees.
        aorus_names = [n for n, _, _, _ in ICONS] + ["Main", "Violet"]
        for icon_name in aorus_names:
            t = re.sub(
                r'                                case "' + re.escape(icon_name) + r'":\n'
                r'                                    name = [^\n]*\n',
                '',
                t,
            )
        # Remove any previously-injected language flag line (idempotent re-inject below).
        flag_line = (
            '                            let aorusIsRu = item.strings.baseLanguageCode == "ru" '
            '|| item.strings.baseLanguageCode.hasPrefix("ru-")\n'
        )
        switch_line = "                            switch icon.name {\n"
        t = t.replace(flag_line + switch_line, switch_line)

        if old_default in t and switch_line in t:
            # Inject the RU/EN selector once, right before the switch.
            t = t.replace(switch_line, flag_line + switch_line, 1)
            # Localized cases: each name follows the in-app Telegram language.
            new_cases = "".join(
                f'                                case "{n}":\n'
                f'                                    name = aorusIsRu ? "{ru}" : "{en}"\n'
                for n, ru, en, _ in ICONS
            )
            t = t.replace(old_default, new_cases + old_default, 1)
            icon_item.write_text(t, encoding="utf-8")
            print("AlternateIcons: patched ThemeSettingsAppIconItem with localized names")
        else:
            print("AlternateIcons: WARNING default/switch branch not found in ThemeSettingsAppIconItem")


def patch_primary_app_icon(tg: Path) -> None:
    """Replace the primary home-screen app icon with the AorusGram brand icon.

    On the iOS 26 SDK the project's primary icon is produced from the Icon
    Composer bundle Telegram.icon (app_icons in Telegram/BUILD), which renders
    the stock blue Telegram plane. We switch the primary icon to a classic
    AppIconLLC.appiconset (fully supported on every SDK incl. 26) pre-rendered
    with the brand logo at all required sizes, and point app_icons at it. The
    Info.plist CFBundlePrimaryIcon is already CFBundleIconName=AppIconLLC, so the
    appiconset basename matches and actool wires it as the primary icon. The
    Icon Composer bundle and its filegroup stay defined but become unreferenced.

    Pre-rendered PNGs (no alpha, per Apple's requirement) live in the repo at
    patches/appicon/AppIconLLC.appiconset so the macOS runner needs no image
    tooling. Idempotent.
    """
    import shutil
    repo_root = Path(__file__).resolve().parent.parent
    src = repo_root / "patches/appicon/AppIconLLC.appiconset"
    if not src.is_dir():
        print(f"PrimaryIcon: source appiconset not found at {src}, skip")
        return
    dst = tg / "Telegram/Telegram-iOS/DefaultAppIcon.xcassets/AppIconLLC.appiconset"
    if not dst.parent.is_dir():
        print("PrimaryIcon: DefaultAppIcon.xcassets not found, skip")
        return
    # Replace the appiconset contents wholesale with the brand icon set.
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    print(f"PrimaryIcon: installed brand AppIconLLC.appiconset ({len(list(src.glob('*.png')))} pngs)")

    # Point Telegram/BUILD app_icons at the appiconset instead of Icon Composer.
    build = tg / "Telegram/BUILD"
    if not build.is_file():
        print("PrimaryIcon: Telegram/BUILD not found, skip BUILD switch")
        return
    t = build.read_text(encoding="utf-8")
    new_line = '    app_icons = glob(["Telegram-iOS/DefaultAppIcon.xcassets/AppIconLLC.appiconset/*"]),  # AorusGram primary icon'
    if "DefaultAppIcon.xcassets/AppIconLLC.appiconset/*" in t:
        print("PrimaryIcon: BUILD app_icons already switched")
        return
    old_line = '    app_icons = [ ":{}_icon".format(name) for name in composer_icon_folders ],'
    if old_line in t:
        t = t.replace(old_line, new_line, 1)
        build.write_text(t, encoding="utf-8")
        print("PrimaryIcon: BUILD app_icons -> AppIconLLC.appiconset")
    else:
        print("PrimaryIcon: WARNING app_icons composer line not found — BUILD not switched")

def patch_app_delegate_language_bridge(tg: Path) -> None:
    """Persist the resolved AorusGram language (ru/en) to UserDefaults.

    The AorusGram client follows the in-app Telegram language. UI with direct
    access to PresentationData reads strings.baseLanguageCode itself; context-free
    call sites (the deleted-message chat bubble, TelegramCore postbox markers that
    write "Удалено"/"Оригинал") instead read the resolved value persisted here
    under the flat "aorusgram_lang" key. The observer fires on every presentation
    update, so a mid-session language change is picked up immediately.
    """
    delegate = tg / "submodules/TelegramUI/Sources/AppDelegate.swift"
    if not delegate.is_file():
        print("LanguageBridge: AppDelegate.swift not found — skipped")
        return
    t = delegate.read_text(encoding="utf-8")
    sentinel = "// AorusGram: persist resolved language for context-free call sites"
    if sentinel in t:
        print("LanguageBridge: already present")
        return
    anchor = "presentationDataPromise.set(sharedContext.presentationData)\n"
    idx = t.find(anchor)
    if idx < 0:
        print("LanguageBridge: anchor not found — skipped")
        return
    indent = " " * (idx - (t.rfind("\n", 0, idx) + 1))
    injection = (
        f"{indent}{sentinel}\n"
        f"{indent}let _ = (sharedContext.presentationData |> deliverOnMainQueue).start(next: {{ aorusPD in\n"
        f"{indent}    let aorusCode = aorusPD.strings.baseLanguageCode.lowercased()\n"
        f"{indent}    let aorusResolved = (aorusCode == \"ru\" || aorusCode.hasPrefix(\"ru-\") || aorusCode.hasPrefix(\"ru_\")) ? \"ru\" : \"en\"\n"
        f"{indent}    UserDefaults.standard.set(aorusResolved, forKey: \"aorusgram_lang\")\n"
        f"{indent}}})\n"
    )
    insert_at = idx + len(anchor)
    t = t[:insert_at] + injection + t[insert_at:]
    delegate.write_text(t, encoding="utf-8")
    print("LanguageBridge: injected presentationData language observer into AppDelegate")


def patch_default_dark_theme(tg: Path) -> None:
    """Make the dark theme the default for fresh installs.

    PresentationThemeSettings.defaultSettings ships with theme=.dayClassic and an
    automatic switch trigger of .system (so the app follows the device appearance).
    We pin a dark default that does not auto-switch: theme=.night and
    trigger=.explicitNone. Existing users keep their stored preference; only the
    default applied on first launch changes.
    """
    settings_file = tg / "submodules/TelegramUIPreferences/Sources/PresentationThemeSettings.swift"
    if not settings_file.is_file():
        print("DarkDefault: PresentationThemeSettings.swift not found — skipped")
        return
    t = settings_file.read_text(encoding="utf-8")
    old_default = (
        "return PresentationThemeSettings(theme: .builtin(.dayClassic), themePreferredBaseTheme: [:], "
        "themeSpecificAccentColors: [:], themeSpecificChatWallpapers: [:], useSystemFont: true, "
        "fontSize: .regular, listsFontSize: .regular, chatBubbleSettings: .default, "
        "automaticThemeSwitchSetting: AutomaticThemeSwitchSetting(force: false, trigger: .system, "
        "theme: .builtin(.night)), largeEmoji: true, reduceMotion: false)"
    )
    new_default = (
        "return PresentationThemeSettings(theme: .builtin(.night), themePreferredBaseTheme: [:], "
        "themeSpecificAccentColors: [:], themeSpecificChatWallpapers: [:], useSystemFont: true, "
        "fontSize: .regular, listsFontSize: .regular, chatBubbleSettings: .default, "
        "automaticThemeSwitchSetting: AutomaticThemeSwitchSetting(force: false, trigger: .explicitNone, "
        "theme: .builtin(.night)), largeEmoji: true, reduceMotion: false)"
    )
    if new_default in t:
        print("DarkDefault: already applied")
        return
    if old_default in t:
        t = t.replace(old_default, new_default, 1)
        settings_file.write_text(t, encoding="utf-8")
        print("DarkDefault: defaultSettings theme -> .night (trigger .explicitNone)")
    else:
        print("DarkDefault: WARNING defaultSettings line not found (upstream drift) — skipped")


def _add_aorus_build_dep(build_path: Path) -> None:
    """Add the AorusBadge dependency to a Bazel BUILD file (idempotent)."""
    if not build_path.is_file():
        return
    bt = build_path.read_text(encoding="utf-8")
    if "//submodules/AorusBadge:AorusBadge" in bt:
        return
    needle = '        "//submodules/TelegramPresentationData:TelegramPresentationData",\n'
    if needle in bt:
        bt = bt.replace(needle, needle + '        "//submodules/AorusBadge:AorusBadge",\n', 1)
        build_path.write_text(bt, encoding="utf-8")
        print(f"Badges: added AorusBadge dep to {build_path.parent.name} BUILD")
    else:
        print(f"Badges: WARNING {build_path.parent.name} BUILD needle not found")


def patch_aorus_badges(tg: Path) -> None:
    """Local AorusGram badge system.

    1. Native verified: TelegramCore `isVerified` returns true for the AorusGram
       channel/chat ids, so the genuine Telegram checkmark is shown in every
       surface (chat list, header, profile, search) with no custom rendering.
    2. Custom user badges (DEV tag, meme cat) are injected into the chat-list /
       search rows via the existing EmojiStatusComponent `.image` slot, which is
       laid out AFTER the premium/credibility icon — so it never replaces a
       system badge and respects the premium-first ordering.
    """
    # --- 1. Native verified flag for AorusGram channels/chats ---
    peer_utils = tg / "submodules/TelegramCore/Sources/Utils/PeerUtils.swift"
    if peer_utils.is_file():
        t = peer_utils.read_text(encoding="utf-8")
        anchor = "    var isVerified: Bool {\n        switch self {"
        if "AorusGram local verification" in t:
            print("Badges: PeerUtils isVerified already patched")
        elif anchor in t:
            injected = (
                "    var isVerified: Bool {\n"
                "        // AorusGram local verification — show the native Telegram checkmark\n"
                "        // for our official channel/chat without any server flag.\n"
                "        if [3956524111, 3710166840].contains(self.id.id._internalGetInt64Value()) {\n"
                "            return true\n"
                "        }\n"
                "        switch self {"
            )
            t = t.replace(anchor, injected, 1)
            peer_utils.write_text(t, encoding="utf-8")
            print("Badges: patched PeerUtils isVerified (native verified for AorusGram peers)")
        else:
            print("Badges: WARNING isVerified anchor not found in PeerUtils")
    else:
        print("Badges: PeerUtils.swift not found — skipped")

    # --- 2. DEV / meme badge image in chat-list & search rows (display only) ---
    # Per product decision the tap→toast lives ONLY in the profile; the list and
    # search just show the badge in the verified slot (after premium).
    chat_list_item = tg / "submodules/ChatListUI/Sources/Node/ChatListItem.swift"
    if chat_list_item.is_file():
        t = chat_list_item.read_text(encoding="utf-8")
        if "import AorusBadge" not in t:
            t = t.replace("import Foundation\n", "import Foundation\nimport AorusBadge\n", 1)
        # Inject before each `if peer.isVerified {` (two indentation variants).
        # Anchors/markers are newline-prefixed so a shorter indent never matches as
        # a leading-space substring of a deeper-indented injected line.
        for indent in ("                            ", "                    "):
            anchor = f"\n{indent}if peer.isVerified {{"
            inject_marker = f"\n{indent}if currentVerifiedIconContent == nil, let aorusBadgeImage = AorusBadge.image(forPeerRawId:"
            inject = (
                f"\n{indent}if currentVerifiedIconContent == nil, let aorusBadgeImage = AorusBadge.image(forPeerRawId: peer.id.id._internalGetInt64Value(), height: 16.0, accent: item.presentationData.theme.list.itemAccentColor) {{\n"
                f"{indent}    currentVerifiedIconContent = .image(image: aorusBadgeImage, tintColor: nil)\n"
                f"{indent}}}\n"
                f"{indent}if peer.isVerified {{"
            )
            if inject_marker in t:
                continue
            if anchor in t:
                t = t.replace(anchor, inject, 1)
        chat_list_item.write_text(t, encoding="utf-8")
        print("Badges: patched ChatListItem (DEV/meme image in verified slot, display only)")
    else:
        print("Badges: ChatListItem.swift not found — skipped")

    # --- 2b. Chat header (ChatTitleComponent): DEV/meme badge, display only ---
    title_comp = tg / "submodules/TelegramUI/Components/ChatTitleView/Sources/ChatTitleComponent.swift"
    if title_comp.is_file():
        t = title_comp.read_text(encoding="utf-8")
        if "import AorusBadge" not in t:
            t = t.replace("import Foundation\n", "import Foundation\nimport AorusBadge\n", 1)
        prop_anchor = "        private var statusIcon: ComponentView<Empty>?\n"
        if "private var aorusBadgeView: UIImageView?" not in t and prop_anchor in t:
            t = t.replace(
                prop_anchor,
                prop_anchor
                + "        private var aorusBadgeView: UIImageView?\n"
                + "        private var aorusBadgeRawId: Int64?\n",
                1,
            )
        reset_anchor = "            var titleStatusIcon: ChatTitleCredibilityIcon = .none\n"
        if reset_anchor in t and "self.aorusBadgeRawId = nil // AorusGram" not in t:
            t = t.replace(reset_anchor, reset_anchor + "            self.aorusBadgeRawId = nil // AorusGram\n", 1)
        cap_anchor = (
            "                            if peer.isVerified {\n"
            "                                titleCredibilityIcon = .verified\n"
            "                            }\n"
        )
        if "self.aorusBadgeRawId = peer.id.id._internalGetInt64Value()" not in t and cap_anchor in t:
            t = t.replace(
                cap_anchor,
                cap_anchor
                + "                            if AorusBadge.kind(forPeerRawId: peer.id.id._internalGetInt64Value()) != nil {\n"
                + "                                self.aorusBadgeRawId = peer.id.id._internalGetInt64Value()\n"
                + "                            }\n",
                1,
            )
        layout_anchor = (
            "                nextRightIconX += statusIconsSpacing + credibilityIconSize.width\n"
            "            }\n"
        )
        if "// AorusGram header badge layout" not in t and layout_anchor in t:
            layout_inject = layout_anchor + (
                "            // AorusGram header badge layout\n"
                "            if let aorusRawId = self.aorusBadgeRawId, let aorusImg = AorusBadge.image(forPeerRawId: aorusRawId, height: 18.0, accent: component.theme.list.itemAccentColor) {\n"
                "                let aorusBadge: UIImageView\n"
                "                if let cur = self.aorusBadgeView {\n"
                "                    aorusBadge = cur\n"
                "                } else {\n"
                "                    aorusBadge = UIImageView()\n"
                "                    aorusBadge.contentMode = .scaleAspectFit\n"
                "                    aorusBadge.isUserInteractionEnabled = false\n"
                "                    self.aorusBadgeView = aorusBadge\n"
                "                    self.contentContainer.addSubview(aorusBadge)\n"
                "                }\n"
                "                aorusBadge.image = aorusImg\n"
                "                let aorusAspect = aorusImg.size.width / max(1.0, aorusImg.size.height)\n"
                "                let aorusW = floor(18.0 * aorusAspect)\n"
                "                aorusBadge.frame = CGRect(x: nextRightIconX + statusIconsSpacing, y: titleFrame.minY, width: aorusW, height: 18.0)\n"
                "                nextRightIconX += statusIconsSpacing + aorusW\n"
                "            } else if let aorusBadge = self.aorusBadgeView {\n"
                "                self.aorusBadgeView = nil\n"
                "                aorusBadge.removeFromSuperview()\n"
                "            }\n"
            )
            t = t.replace(layout_anchor, layout_inject, 1)
        title_comp.write_text(t, encoding="utf-8")
        print("Badges: patched ChatTitleComponent (header DEV/meme badge, display only)")
        # BUILD dep
        tv_build = tg / "submodules/TelegramUI/Components/ChatTitleView/BUILD"
        if tv_build.is_file():
            bt = tv_build.read_text(encoding="utf-8")
            if "//submodules/AorusBadge:AorusBadge" not in bt:
                needle = '        "//submodules/TelegramPresentationData:TelegramPresentationData",\n'
                if needle in bt:
                    bt = bt.replace(needle, needle + '        "//submodules/AorusBadge:AorusBadge",\n', 1)
                    tv_build.write_text(bt, encoding="utf-8")
                    print("Badges: added AorusBadge dep to ChatTitleView BUILD")
                else:
                    print("Badges: WARNING ChatTitleView BUILD needle not found")
    else:
        print("Badges: ChatTitleComponent.swift not found — skipped")

    # --- 2c. Profile (PeerInfoHeaderNode): DEV/meme badge + tap→toast ---
    peer_header = tg / "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"
    if peer_header.is_file():
        t = peer_header.read_text(encoding="utf-8")
        if "import AorusBadge" not in t:
            t = t.replace("import Foundation\n", "import Foundation\nimport AorusBadge\n", 1)
        prop_anchor = "    let titleVerifiedIconView: ComponentHostView<Empty>\n"
        if "var aorusBadgeView: AorusTappableBadgeView?" not in t and prop_anchor in t:
            t = t.replace(
                prop_anchor,
                prop_anchor
                + "    var aorusBadgeView: AorusTappableBadgeView?\n"
                + "    var aorusBadgeExpandedView: AorusTappableBadgeView?\n"
                + "    var aorusBadgeRawId: Int64?\n"
                + "    var aorusBadgePeerName: String = \"\"\n",
                1,
            )
        reset_anchor = (
            "        var credibilityIcon: CredibilityIcon = .none\n"
            "        var verifiedIcon: CredibilityIcon = .none\n"
            "        var statusIcon: CredibilityIcon = .none\n"
        )
        if reset_anchor in t and "self.aorusBadgeRawId = nil // AorusGram" not in t:
            t = t.replace(reset_anchor, reset_anchor + "        self.aorusBadgeRawId = nil // AorusGram\n", 1)
        cap_anchor = (
            "            if peer.isVerified {\n"
            "                credibilityIcon = .verified\n"
            "            }\n"
        )
        if "self.aorusBadgeRawId = peer.id.id._internalGetInt64Value()" not in t and cap_anchor in t:
            t = t.replace(
                cap_anchor,
                cap_anchor
                + "            if AorusBadge.kind(forPeerRawId: peer.id.id._internalGetInt64Value()) != nil {\n"
                + "                self.aorusBadgeRawId = peer.id.id._internalGetInt64Value()\n"
                + "                self.aorusBadgePeerName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)\n"
                + "            }\n",
                1,
            )
        layout_anchor = "        var titleFrame: CGRect\n        var subtitleFrame: CGRect\n"
        if "// AorusGram profile badge" not in t and layout_anchor in t:
            layout_inject = (
                "        // AorusGram profile badge (display + tap→toast), shown in BOTH the\n"
                "        // collapsed and expanded (tapped-avatar) title states so it never\n"
                "        // disappears when the avatar is enlarged.\n"
                "        if let aorusRawId = self.aorusBadgeRawId, let aorusImg = AorusBadge.image(forPeerRawId: aorusRawId, height: 25.0, accent: presentationData.theme.list.itemAccentColor) {\n"
                "            let aorusName = self.aorusBadgePeerName\n"
                "            let aorusAccent = presentationData.theme.list.itemAccentColor\n"
                "            let aorusAspect = aorusImg.size.width / max(1.0, aorusImg.size.height)\n"
                "            let aorusW = floor(25.0 * aorusAspect)\n"
                "            let aorusOnTap: () -> Void = {\n"
                "                AorusBadgeToast.present(icon: aorusImg, text: AorusBadge.toastText(forPeerRawId: aorusRawId, peerName: aorusName) ?? \"\", accent: aorusAccent)\n"
                "            }\n"
                "            // Collapsed (regular) title state\n"
                "            let aorusBadge: AorusTappableBadgeView\n"
                "            if let cur = self.aorusBadgeView {\n"
                "                aorusBadge = cur\n"
                "            } else {\n"
                "                aorusBadge = AorusTappableBadgeView(image: nil)\n"
                "                self.aorusBadgeView = aorusBadge\n"
                "                self.titleNode.stateNode(forKey: TitleNodeStateRegular)?.view.addSubview(aorusBadge)\n"
                "            }\n"
                "            aorusBadge.image = aorusImg\n"
                "            aorusBadge.onTap = aorusOnTap\n"
                "            transition.updateFrame(view: aorusBadge, frame: CGRect(x: nextIconX + 4.0, y: floor((titleSize.height - 25.0) / 2.0), width: aorusW, height: 25.0))\n"
                "            nextIconX += 4.0 + aorusW\n"
                "            // Expanded (tapped-avatar) title state\n"
                "            let aorusBadgeExpanded: AorusTappableBadgeView\n"
                "            if let cur = self.aorusBadgeExpandedView {\n"
                "                aorusBadgeExpanded = cur\n"
                "            } else {\n"
                "                aorusBadgeExpanded = AorusTappableBadgeView(image: nil)\n"
                "                self.aorusBadgeExpandedView = aorusBadgeExpanded\n"
                "                self.titleNode.stateNode(forKey: TitleNodeStateExpanded)?.view.addSubview(aorusBadgeExpanded)\n"
                "            }\n"
                "            aorusBadgeExpanded.image = aorusImg\n"
                "            aorusBadgeExpanded.onTap = aorusOnTap\n"
                "            transition.updateFrame(view: aorusBadgeExpanded, frame: CGRect(x: nextExpandedIconX + 4.0, y: floor((titleExpandedSize.height - 25.0) / 2.0), width: aorusW, height: 25.0))\n"
                "            nextExpandedIconX += 4.0 + aorusW\n"
                "        } else {\n"
                "            if let aorusBadge = self.aorusBadgeView {\n"
                "                self.aorusBadgeView = nil\n"
                "                aorusBadge.removeFromSuperview()\n"
                "            }\n"
                "            if let aorusBadgeExpanded = self.aorusBadgeExpandedView {\n"
                "                self.aorusBadgeExpandedView = nil\n"
                "                aorusBadgeExpanded.removeFromSuperview()\n"
                "            }\n"
                "        }\n"
                "        \n"
                + layout_anchor
            )
            t = t.replace(layout_anchor, layout_inject, 1)
        # hitTest routing: the header's hitTest only forwards taps to specific icon
        # views, so our badge needs its own case to become tappable. Route to whichever
        # title state is currently shown (expanded when the avatar is enlarged).
        hit_anchor = "        if let subtitleBackgroundButton = self.subtitleBackgroundButton, subtitleBackgroundButton.view.convert"
        if "// AorusGram badge hit routing" not in t and hit_anchor in t:
            t = t.replace(
                hit_anchor,
                "// AorusGram badge hit routing\n"
                "        if self.isAvatarExpanded, let aorusBadge = self.aorusBadgeExpandedView {\n"
                "            let aorusHitFrame = aorusBadge.convert(aorusBadge.bounds, to: self.view)\n"
                "            if aorusHitFrame.contains(point) {\n"
                "                return aorusBadge\n"
                "            }\n"
                "        }\n"
                "        if !self.isAvatarExpanded, let aorusBadge = self.aorusBadgeView {\n"
                "            let aorusHitFrame = aorusBadge.convert(aorusBadge.bounds, to: self.view)\n"
                "            if aorusHitFrame.contains(point) {\n"
                "                return aorusBadge\n"
                "            }\n"
                "        }\n"
                "        " + hit_anchor,
                1,
            )
        peer_header.write_text(t, encoding="utf-8")
        print("Badges: patched PeerInfoHeaderNode (profile DEV/meme badge + tap→toast + hitTest)")
    else:
        print("Badges: PeerInfoHeaderNode.swift not found — skipped")

    # --- 2d. Member lists / search / contacts (ItemListPeerItem, ContactsPeerItem) ---
    # Proper approach: a DEDICATED, self-owned UIImageView for the AorusGram badge,
    # completely independent of Telegram's built-in icon slots (premium/verified/
    # emoji-status). Reusing those slots caused the badge to clash with the premium
    # badge. Instead the dedicated view is laid out AFTER the name and after every
    # built-in icon (so the order is always: name → premium/verified → DEV/cat) and
    # never replaces anything. The badge image is computed once in the measurement
    # scope (reserving title width) and captured by the apply closure for layout.

    # ContactsPeerItem (people search & member lists)
    cp = tg / "submodules/ContactsPeerItem/Sources/ContactsPeerItem.swift"
    if cp.is_file():
        t = cp.read_text(encoding="utf-8")
        if "import AorusBadge" not in t:
            t = t.replace("import Foundation\n", "import Foundation\nimport AorusBadge\n", 1)
        # 1) dedicated view property
        prop_anchor = "    private var emojiStatusIconComponent: EmojiStatusComponent?\n"
        if "private var aorusBadgeView: UIImageView?" not in t and prop_anchor in t:
            t = t.replace(prop_anchor, prop_anchor + "    private var aorusBadgeView: UIImageView?\n", 1)
        # 2) declare the badge image in the measurement scope
        decl_anchor = "            var emojiStatusParticleColor: UIColor?\n"
        if "var aorusBadgeImage: UIImage?" not in t and decl_anchor in t:
            t = t.replace(decl_anchor, decl_anchor + "            var aorusBadgeImage: UIImage?\n", 1)
        # 3) compute it where `peer` is in scope (before the isVerified check)
        assign_anchor = "                    if peer.isVerified {\n"
        if "aorusBadgeImage = AorusBadge.image(forPeerRawId: peer.id" not in t and assign_anchor in t:
            t = t.replace(
                assign_anchor,
                "                    aorusBadgeImage = AorusBadge.image(forPeerRawId: peer.id.id._internalGetInt64Value(), height: 16.0, accent: item.presentationData.theme.list.itemAccentColor)\n"
                + assign_anchor,
                1,
            )
        # 4) reserve title width for the badge
        width_anchor = (
            "            if let _ = emojiStatusIcon {\n"
            "                additionalTitleInset += 3.0\n"
            "                additionalTitleInset += 16.0\n"
            "            }\n"
        )
        if "additionalTitleInset += 4.0 + aorusBadgeImage.size.width" not in t and width_anchor in t:
            t = t.replace(
                width_anchor,
                width_anchor
                + "            if let aorusBadgeImage {\n"
                + "                additionalTitleInset += 4.0 + aorusBadgeImage.size.width\n"
                + "            }\n",
                1,
            )
        # 5) lay out the dedicated view after the emoji-status icon (last built-in icon)
        apply_anchor = (
            "                            } else if let emojiStatusIconView = strongSelf.emojiStatusIconView {\n"
            "                                strongSelf.emojiStatusIconView = nil\n"
            "                                emojiStatusIconView.removeFromSuperview()\n"
            "                            }\n"
        )
        if "// AorusGram dedicated badge" not in t and apply_anchor in t:
            t = t.replace(
                apply_anchor,
                apply_anchor
                + "                            // AorusGram dedicated badge (after name + all built-in icons)\n"
                + "                            if let aorusBadgeImage {\n"
                + "                                let aorusBadgeView: UIImageView\n"
                + "                                if let current = strongSelf.aorusBadgeView {\n"
                + "                                    aorusBadgeView = current\n"
                + "                                } else {\n"
                + "                                    aorusBadgeView = UIImageView()\n"
                + "                                    aorusBadgeView.contentMode = .scaleAspectFit\n"
                + "                                    strongSelf.offsetContainerNode.view.addSubview(aorusBadgeView)\n"
                + "                                    strongSelf.aorusBadgeView = aorusBadgeView\n"
                + "                                }\n"
                + "                                aorusBadgeView.image = aorusBadgeImage\n"
                + "                                let aorusBadgeSize = aorusBadgeImage.size\n"
                + "                                nextIconX += 4.0\n"
                + "                                transition.updateFrame(view: aorusBadgeView, frame: CGRect(origin: CGPoint(x: nextIconX, y: floorToScreenPixels(titleFrame.midY - aorusBadgeSize.height / 2.0)), size: aorusBadgeSize))\n"
                + "                                nextIconX += aorusBadgeSize.width\n"
                + "                            } else if let aorusBadgeView = strongSelf.aorusBadgeView {\n"
                + "                                strongSelf.aorusBadgeView = nil\n"
                + "                                aorusBadgeView.removeFromSuperview()\n"
                + "                            }\n",
                1,
            )
        cp.write_text(t, encoding="utf-8")
        print("Badges: patched ContactsPeerItem (dedicated badge view, after name+premium)")
        _add_aorus_build_dep(tg / "submodules/ContactsPeerItem/BUILD")
    else:
        print("Badges: ContactsPeerItem.swift not found — skipped")

    # ItemListPeerItem (member lists)
    ip = tg / "submodules/ItemListPeerItem/Sources/ItemListPeerItem.swift"
    if ip.is_file():
        t = ip.read_text(encoding="utf-8")
        if "import AorusBadge" not in t:
            t = t.replace("import Foundation\n", "import Foundation\nimport AorusBadge\n", 1)
        # 1) dedicated view property
        prop_anchor = "    private var verifiedIconView: ComponentHostView<Empty>?\n"
        if "private var aorusBadgeView: UIImageView?" not in t and prop_anchor in t:
            t = t.replace(prop_anchor, prop_anchor + "    private var aorusBadgeView: UIImageView?\n", 1)
        # 2) declare + compute the badge image right before titleIconsWidth
        decl_anchor = "            var titleIconsWidth: CGFloat = 0.0\n"
        if "let aorusBadgeImage: UIImage? = AorusBadge.image(forPeerRawId: item.peer.id" not in t and decl_anchor in t:
            t = t.replace(
                decl_anchor,
                "            let aorusBadgeImage: UIImage? = AorusBadge.image(forPeerRawId: item.peer.id.id._internalGetInt64Value(), height: 16.0, accent: item.presentationData.theme.list.itemAccentColor)\n"
                + decl_anchor,
                1,
            )
        # 3) reserve title width
        width_anchor = "            var badgeColor: UIColor?\n"
        if "titleIconsWidth += 4.0 + aorusBadgeImage.size.width" not in t and width_anchor in t:
            t = t.replace(
                width_anchor,
                "            if let aorusBadgeImage {\n"
                + "                titleIconsWidth += 4.0 + aorusBadgeImage.size.width\n"
                + "            }\n"
                + width_anchor,
                1,
            )
        # 4) lay out the dedicated view after the credibility icon. nextIconX is not a
        # reliable right-edge here, so anchor off the credibility view's actual frame.
        apply_anchor = (
            "                    } else if let credibilityIconView = strongSelf.credibilityIconView {\n"
            "                        strongSelf.credibilityIconView = nil\n"
            "                        credibilityIconView.removeFromSuperview()\n"
            "                    }\n"
        )
        if "// AorusGram dedicated badge" not in t and apply_anchor in t:
            t = t.replace(
                apply_anchor,
                apply_anchor
                + "                    // AorusGram dedicated badge (after name + credibility icon)\n"
                + "                    if let aorusBadgeImage {\n"
                + "                        let aorusBadgeView: UIImageView\n"
                + "                        if let current = strongSelf.aorusBadgeView {\n"
                + "                            aorusBadgeView = current\n"
                + "                        } else {\n"
                + "                            aorusBadgeView = UIImageView()\n"
                + "                            aorusBadgeView.contentMode = .scaleAspectFit\n"
                + "                            strongSelf.containerNode.view.addSubview(aorusBadgeView)\n"
                + "                            strongSelf.aorusBadgeView = aorusBadgeView\n"
                + "                        }\n"
                + "                        aorusBadgeView.image = aorusBadgeImage\n"
                + "                        var aorusStartX = titleFrame.maxX\n"
                + "                        if let credView = strongSelf.credibilityIconView, credView.superview != nil {\n"
                + "                            aorusStartX = max(aorusStartX, credView.frame.maxX)\n"
                + "                        }\n"
                + "                        let aorusBadgeSize = aorusBadgeImage.size\n"
                + "                        transition.updateFrame(view: aorusBadgeView, frame: CGRect(origin: CGPoint(x: aorusStartX + 4.0, y: floorToScreenPixels(titleFrame.midY - aorusBadgeSize.height / 2.0)), size: aorusBadgeSize))\n"
                + "                    } else if let aorusBadgeView = strongSelf.aorusBadgeView {\n"
                + "                        strongSelf.aorusBadgeView = nil\n"
                + "                        aorusBadgeView.removeFromSuperview()\n"
                + "                    }\n",
                1,
            )
        ip.write_text(t, encoding="utf-8")
        print("Badges: patched ItemListPeerItem (dedicated badge view, after name+credibility)")
        _add_aorus_build_dep(tg / "submodules/ItemListPeerItem/BUILD")
    else:
        print("Badges: ItemListPeerItem.swift not found — skipped")

    # --- 2e. Chat message sender names (ChatMessageBubbleItemNode) ---
    # The sender name row in message bubbles uses `currentCredibilityIcon` placed
    # after the name. We inject right after the isPremium branch so our badge
    # always overrides (premium is rare for these internal users).
    msg_bubble = tg / "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift"
    if msg_bubble.is_file():
        t = msg_bubble.read_text(encoding="utf-8")
        if "import AorusBadge" not in t:
            t = t.replace("import Foundation\n", "import Foundation\nimport AorusBadge\n", 1)
        bubble_anchor = (
            "                } else if effectiveAuthor.isPremium {\n"
            "                    currentCredibilityIcon = (.premium(color: color.withMultipliedAlpha(0.4)), nil)\n"
            "                }\n"
        )
        bubble_marker = "if let aorusBadgeImage = AorusBadge.image(forPeerRawId: effectiveAuthor.id.id._internalGetInt64Value()"
        if bubble_marker not in t and bubble_anchor in t:
            t = t.replace(
                bubble_anchor,
                bubble_anchor
                + "                if let aorusBadgeImage = AorusBadge.image(forPeerRawId: effectiveAuthor.id.id._internalGetInt64Value(), height: 16.0, accent: item.presentationData.theme.theme.list.itemAccentColor) {\n"
                + "                    currentCredibilityIcon = (.image(image: aorusBadgeImage, tintColor: nil), nil)\n"
                + "                }\n",
                1,
            )
        msg_bubble.write_text(t, encoding="utf-8")
        print("Badges: patched ChatMessageBubbleItemNode (sender name badge)")
        mb_build = tg / "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/BUILD"
        if mb_build.is_file():
            bt = mb_build.read_text(encoding="utf-8")
            if "//submodules/AorusBadge" not in bt:
                needle = '        "//submodules/TelegramPresentationData",\n'
                if needle in bt:
                    bt = bt.replace(needle, needle + '        "//submodules/AorusBadge:AorusBadge",\n', 1)
                    mb_build.write_text(bt, encoding="utf-8")
                    print("Badges: added AorusBadge dep to ChatMessageBubbleItemNode BUILD")
                else:
                    print("Badges: WARNING ChatMessageBubbleItemNode BUILD needle not found")
    else:
        print("Badges: ChatMessageBubbleItemNode.swift not found — skipped")

    # --- 3. Add AorusBadge dep to ChatListUI BUILD ---
    cl_build = tg / "submodules/ChatListUI/BUILD"
    if cl_build.is_file():
        t = cl_build.read_text(encoding="utf-8")
        dep = '        "//submodules/AorusBadge:AorusBadge",\n'
        if "//submodules/AorusBadge:AorusBadge" in t:
            print("Badges: ChatListUI BUILD dep already present")
        else:
            needle = '        "//submodules/TelegramPresentationData:TelegramPresentationData",\n'
            if needle in t:
                t = t.replace(needle, needle + dep, 1)
                cl_build.write_text(t, encoding="utf-8")
                print("Badges: added AorusBadge dep to ChatListUI BUILD")
            else:
                print("Badges: WARNING ChatListUI BUILD needle not found")


def patch_default_auto_night(tg: Path) -> None:
    """Pin the default auto-night setting to System + "Night" (.night) theme.

    The auto-night settings screen derives the selected mode purely from
    `automaticThemeSwitchSetting.trigger`: .system → "Системная", .explicitNone →
    "Выключена". Stock already defaults to .system, but a previous AorusGram build
    forced .explicitNone (which showed "Выключена"). This regex pins both the
    defaultSettings value and the decode-fallback to System + Night so the result
    is correct regardless of any cached/forced state — fully idempotent.
    """
    f = tg / "submodules/TelegramUIPreferences/Sources/PresentationThemeSettings.swift"
    if not f.is_file():
        print("AutoNight: PresentationThemeSettings.swift not found — skipped")
        return
    t = f.read_text(encoding="utf-8")
    desired = "AutomaticThemeSwitchSetting(force: false, trigger: .system, theme: .builtin(.night))"
    pattern = r"AutomaticThemeSwitchSetting\(force: [^,]+, trigger: \.[A-Za-z]+, theme: \.builtin\(\.[A-Za-z]+\)\)"
    new_t, n = re.subn(pattern, desired, t)
    if n and new_t != t:
        f.write_text(new_t, encoding="utf-8")
        print(f"AutoNight: pinned System + .night in {n} place(s)")
    elif n:
        print("AutoNight: already System + .night")
    else:
        print("AutoNight: WARNING AutomaticThemeSwitchSetting pattern not found")


def patch_local_premium(tg: Path) -> None:
    """Local Telegram Premium for the user's OWN account(s), client-side only.

    Everything funnels through `Peer.isPremium` (PeerUtils.swift): the account
    context's `isPremium`, the per-message `associatedData.isPremium`, premium
    limits, premium-gated UI, etc. all read it. So we make that single accessor
    return true — but ONLY for the user's own logged-in account ids, registered
    at `AccountContextImpl.init`. Other peers keep their real server flag, so a
    premium badge never appears on contacts who aren't actually premium.

    This unlocks client-gated premium features (premium stickers/emoji, message
    effects, profile customisation, folder tags, no upsell walls, premium limits
    in the UI). Server-enforced limits remain governed by the server.
    """
    # 1) Self-account premium registry (new file, auto-globbed into TelegramCore).
    registry = tg / "submodules/TelegramCore/Sources/Utils/AorusGramPremium.swift"
    registry_src = (
        "import Foundation\n"
        "\n"
        "// AorusGram local Telegram Premium.\n"
        "//\n"
        "// Premium is unlocked purely on the client for the user's OWN logged-in\n"
        "// account(s): when an account becomes active its peer id is registered here,\n"
        "// and `Peer.isPremium` short-circuits to true for those ids. Every other peer\n"
        "// keeps its real (server) premium flag, so premium badges are never shown on\n"
        "// contacts who aren't actually premium.\n"
        "public enum AorusGramPremium {\n"
        "    private static let lock = NSLock()\n"
        "    private static var accountPeerRawIds = Set<Int64>()\n"
        "\n"
        "    public static func registerCurrentAccount(_ rawId: Int64) {\n"
        "        lock.lock()\n"
        "        accountPeerRawIds.insert(rawId)\n"
        "        lock.unlock()\n"
        "    }\n"
        "\n"
        "    public static func isOwnAccount(_ rawId: Int64) -> Bool {\n"
        "        lock.lock()\n"
        "        let result = accountPeerRawIds.contains(rawId)\n"
        "        lock.unlock()\n"
        "        return result\n"
        "    }\n"
        "}\n"
    )
    registry.write_text(registry_src, encoding="utf-8")
    print("Premium: wrote AorusGramPremium.swift registry")

    # 2) Short-circuit Peer.isPremium for own account(s).
    peer_utils = tg / "submodules/TelegramCore/Sources/Utils/PeerUtils.swift"
    if peer_utils.is_file():
        t = peer_utils.read_text(encoding="utf-8")
        anchor = (
            "    var isPremium: Bool {\n"
            "        switch self {\n"
            "        case let user as TelegramUser:\n"
            "            return user.flags.contains(.isPremium)\n"
        )
        if "AorusGramPremium.isOwnAccount" in t:
            print("Premium: PeerUtils isPremium already patched")
        elif anchor in t:
            injected = (
                "    var isPremium: Bool {\n"
                "        // AorusGram local premium — the user's own account(s) always read as premium.\n"
                "        if AorusGramPremium.isOwnAccount(self.id.id._internalGetInt64Value()) {\n"
                "            return true\n"
                "        }\n"
                "        switch self {\n"
                "        case let user as TelegramUser:\n"
                "            return user.flags.contains(.isPremium)\n"
            )
            t = t.replace(anchor, injected, 1)
            peer_utils.write_text(t, encoding="utf-8")
            print("Premium: patched PeerUtils isPremium (local premium for own account)")
        else:
            print("Premium: WARNING isPremium anchor not found in PeerUtils")
    else:
        print("Premium: PeerUtils.swift not found — skipped")

    # 3) Register the account id + set context premium at AccountContextImpl.init.
    acc_ctx = tg / "submodules/TelegramUI/Sources/AccountContext.swift"
    if acc_ctx.is_file():
        t = acc_ctx.read_text(encoding="utf-8")
        anchor = "        self.isPremium = false\n"
        if "AorusGramPremium.registerCurrentAccount" in t:
            print("Premium: AccountContextImpl already patched")
        elif anchor in t:
            t = t.replace(
                anchor,
                "        AorusGramPremium.registerCurrentAccount(account.peerId.id._internalGetInt64Value()) // AorusGram local premium\n"
                "        self.isPremium = true\n",
                1,
            )
            acc_ctx.write_text(t, encoding="utf-8")
            print("Premium: patched AccountContextImpl (register own account + isPremium = true)")
        else:
            print("Premium: WARNING self.isPremium = false anchor not found in AccountContext")
    else:
        print("Premium: AccountContext.swift not found — skipped")


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
    patch_intro_brand_logo(tg)
    patch_intro_animation_snapshot(tg)
    patch_alternate_icons(tg)
    patch_primary_app_icon(tg)
    patch_settings_entry_point(tg)
    patch_download_accelerator(tg)
    patch_deleted_messages_interception(tg)
    patch_anti_spoof_delete_preflight(tg)
    patch_block_ads(tg)
    patch_ghost_mode_hide_typing(tg)
    patch_ghost_mode_hide_online(tg)
    patch_ghost_mode_proactive_offline(tg)
    patch_ghost_mode_block_read(tg)
    patch_aorus_code_encode(tg)
    patch_chat_context_menu_translate_transcribe(tg)
    patch_incoming_message_hook(tg)
    patch_auto_reply_send_hook(tg)
    patch_app_delegate_import_telegram_api(tg)
    patch_app_delegate_account_restore_hook(tg)
    patch_app_delegate_siri_continue_activity(tg)
    patch_peer_info_account_details(tg)
    patch_chat_title_anti_spoof_status(tg)
    patch_client_spoof_app_version(tg)
    patch_app_delegate_import_aorusgram(tg)
    patch_client_spoof_build_info(tg)
    patch_system_proxy_network_override(tg)
    patch_system_proxy_runtime_monitor(tg)
    patch_disable_call_p2p(tg)
    patch_app_delegate_language_bridge(tg)
    # patch_default_dark_theme intentionally NOT called (it forced .explicitNone,
    # which showed "Off"). Instead pin auto-night to System + Night explicitly:
    patch_default_auto_night(tg)
    patch_aorus_badges(tg)
    patch_local_premium(tg)
    for name in ("Info.plist", "InfoBazel.plist"):
        patch_plist_icons_and_urls(tg / "Telegram/Telegram-iOS" / name)
    patch_info_plist_bgtask(tg)
    patch_info_plist_speech_usage(tg)
    patch_info_plist_strings_only(tg)
    patch_localizable_strings_safe(tg)


if __name__ == "__main__":
    main()
