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

    err2 = (
        "        guard let appGroupUrl = maybeAppGroupUrl else {\n"
        "            self.mainWindow?.presentNative(UIAlertController(title: nil, message: \"Error 2\", preferredStyle: .alert))\n"
        "            return true\n"
        "        }"
    )
    err2_new = (
        "        guard let appGroupUrl = maybeAppGroupUrl else {\n"
        "            self.window?.makeKeyAndVisible()\n"
        "            self.mainWindow?.presentNative(UIAlertController(title: nil, message: \"Error 2\", preferredStyle: .alert))\n"
        "            return true\n"
        "        }"
    )
    if err2 in t:
        t = t.replace(err2, err2_new, 1)
        print("AppDelegate: makeKeyAndVisible before App Group Error 2 alert")

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


def main() -> None:
    tg = Path(sys.argv[1]).resolve()
    if not tg.is_dir():
        print(f"Not a directory: {tg}", file=sys.stderr)
        sys.exit(1)
    patch_launch_screen(tg)
    patch_xcconfig(tg)
    patch_app_delegate_launch_fixes(tg)
    patch_presentation_theme_intro_gold(tg)
    for name in ("Info.plist", "InfoBazel.plist"):
        patch_plist_icons_and_urls(tg / "Telegram/Telegram-iOS" / name)
    patch_info_plist_strings_only(tg)
    patch_localizable_strings_safe(tg)


if __name__ == "__main__":
    main()
