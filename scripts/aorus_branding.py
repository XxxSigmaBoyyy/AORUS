#!/usr/bin/env python3
"""Apply AorusGram branding to a Telegram-iOS checkout (CI or local)."""
from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


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
            out.append("APP_NAME=AorusGram")
        else:
            out.append(line)
    cfg.write_text("\n".join(out) + ("\n" if lines else ""), encoding="utf-8")
    print("Patched Config-AppStoreLLC.xcconfig APP_NAME=AorusGram")


def _scrub_user_visible_strings(pl: dict) -> None:
    for k, v in list(pl.items()):
        if isinstance(v, str) and "Telegram" in v:
            if k.endswith("UsageDescription") or k in ("NSSiriUsageDescription",):
                pl[k] = v.replace("Telegram", "AorusGram")
    ut = pl.get("UTImportedTypeDeclarations")
    if isinstance(ut, list):
        for item in ut:
            if isinstance(item, dict):
                desc = item.get("UTTypeDescription")
                if isinstance(desc, str) and "Telegram" in desc:
                    item["UTTypeDescription"] = desc.replace("Telegram", "AorusGram")


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
            new, c = pattern.subn("AorusGram", raw)
            if c:
                p.write_text(new, encoding="utf-8")
                n += c
                print(f"  {p.relative_to(tg)}: {c} replacements")
    print(f"InfoPlist.strings: {n} Telegram→AorusGram (Localizable untouched for stability)")


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
    for name in ("Info.plist", "InfoBazel.plist"):
        patch_plist_icons_and_urls(tg / "Telegram/Telegram-iOS" / name)
    patch_info_plist_strings_only(tg)


if __name__ == "__main__":
    main()
