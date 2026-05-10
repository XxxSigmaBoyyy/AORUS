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


def patch_localizable_strings(tg: Path) -> None:
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
        for p in root.rglob("*.strings"):
            if p.name not in ("Localizable.strings", "InfoPlist.strings"):
                continue
            raw = p.read_text(encoding="utf-8", errors="replace")
            new, c = pattern.subn("AorusGram", raw)
            if c:
                p.write_text(new, encoding="utf-8")
                n += c
                print(f"  {p.relative_to(tg)}: {c} replacements")
    print(f"Localizable .strings: {n} Telegram→AorusGram token replacements")


def main() -> None:
    tg = Path(sys.argv[1]).resolve()
    if not tg.is_dir():
        print(f"Not a directory: {tg}", file=sys.stderr)
        sys.exit(1)
    patch_launch_screen(tg)
    patch_xcconfig(tg)
    for name in ("Info.plist", "InfoBazel.plist"):
        patch_plist_icons_and_urls(tg / "Telegram/Telegram-iOS" / name)
    patch_localizable_strings(tg)


if __name__ == "__main__":
    main()
