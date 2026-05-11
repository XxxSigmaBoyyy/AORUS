#!/usr/bin/env python3
"""Post-branding checks for CI (telegram-ios tree after aorus_branding + icon fill + PlistBuddy)."""
from __future__ import annotations

import plistlib
import sys
from pathlib import Path


def main() -> None:
    tg = Path(sys.argv[1]).resolve()
    err: list[str] = []

    here = Path(__file__).resolve().parent
    candidates = [
        tg.parent / "aorusgram" / "patches" / "assets" / "AorusGramAppIcon.png",
        Path("aorusgram/patches/assets/AorusGramAppIcon.png"),
        here.parent / "patches" / "assets" / "AorusGramAppIcon.png",
    ]
    master = next((p for p in candidates if p.is_file()), candidates[0])
    if not master.is_file():
        err.append("Missing aorusgram/patches/assets/AorusGramAppIcon.png")
    elif master.stat().st_size < 50_000:
        err.append("Master icon file suspiciously small")
    else:
        try:
            from PIL import Image

            im = Image.open(master)
            if im.size != (1024, 1024):
                err.append(f"Master icon must be 1024x1024, got {im.size}")
        except ImportError:
            pass
    plist_path = tg / "Telegram" / "Telegram-iOS" / "Info.plist"
    with plist_path.open("rb") as f:
        pl = plistlib.load(f)
    for k in pl:
        if isinstance(k, str) and k.startswith("CFBundleIcons"):
            name = pl[k].get("CFBundlePrimaryIcon", {}).get("CFBundleIconName")
            if name != "BlueIcon":
                err.append(f"{k} primary CFBundleIconName expected BlueIcon, got {name!r}")
    schemes = pl.get("CFBundleURLTypes", [{}])[0].get("CFBundleURLSchemes", [])
    if schemes != ["aorusgram"]:
        err.append(f"First CFBundleURLSchemes expected ['aorusgram'], got {schemes}")

    if pl.get("CFBundleDisplayName") != "Aorusgram":
        err.append(f"CFBundleDisplayName expected Aorusgram, got {pl.get('CFBundleDisplayName')!r}")
    if pl.get("CFBundleName") != "Aorusgram":
        err.append(f"CFBundleName expected Aorusgram, got {pl.get('CFBundleName')!r}")

    ad = tg / "submodules" / "TelegramUI" / "Sources" / "AppDelegate.swift"
    t = ad.read_text(encoding="utf-8")
    if "AorusgramGroupFallback" not in t:
        err.append("AppDelegate: missing App Group sandbox fallback (AltStore / no shared container)")
    if 'setAlternateIconName("Blue"' not in t:
        err.append('AppDelegate: missing setAlternateIconName("Blue") for branded home-screen icon')
    if "self.nativeWindow = window\n        self.window?.makeKeyAndVisible()" not in t:
        err.append("AppDelegate: missing early makeKeyAndVisible after window wiring")
    # Accept either the legacy guard pattern or the improved hasAppGroup pattern
    has_url_guard = (
        "if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) != nil" in t
        or "hasAppGroup" in t
    )
    if not has_url_guard:
        err.append("AppDelegate: missing URLSession App Group guard (hasAppGroup or containerURL check)")

    build_path = tg / "Telegram" / "BUILD"
    if build_path.is_file():
        bt = build_path.read_text(encoding="utf-8")
        needle = "<key>CFBundleDisplayName</key>\n    <string>Telegram</string>"
        if needle in bt:
            err.append("Telegram/BUILD: CFBundleDisplayName still Telegram (Bazel plist_fragment not patched)")
        want_scheme = (
            "<key>CFBundleURLSchemes</key>\n            <array>\n                <string>aorusgram</string>\n            </array>"
        )
        if want_scheme not in bt:
            err.append("Telegram/BUILD: primary URL scheme should be aorusgram (UrlTypesInfoPlist template)")

    nw = tg / "submodules" / "Display" / "Source" / "NativeWindowHostView.swift"
    if nw.is_file():
        nt = nw.read_text(encoding="utf-8")
        if "init(windowScene: UIWindowScene)" not in nt:
            err.append("NativeWindowHostView: missing init(windowScene:) (scene-attached window)")
        if "windowScenes.first(where: { $0.activationState == .foregroundActive })" not in nt:
            err.append("NativeWindowHostView: missing UIWindowScene selection in nativeWindowHostView()")

    # AorusGramBootstrap injection
    if "AorusGramBootstrap" not in t:
        err.append("AppDelegate: missing AorusGramBootstrap.shared.setup() call (feature initialisation)")

    # BGTask identifier in plist
    bgtask_key = "BGTaskSchedulerPermittedIdentifiers"
    bgtask_val = "com.aorusgram.dmc.sync"
    bgtask_ok = bgtask_key in pl and bgtask_val in pl.get(bgtask_key, [])
    if not bgtask_ok:
        err.append(f"Info.plist: missing {bgtask_key} = [{bgtask_val}] (required for deleted-messages BGTask)")

    xc = (tg / "Telegram" / "Telegram-iOS" / "Config-AppStoreLLC.xcconfig").read_text(encoding="utf-8")
    if "APP_NAME=Aorusgram" not in xc:
        err.append("Config-AppStoreLLC.xcconfig missing APP_NAME=Aorusgram")

    if err:
        print("VERIFY FAILED:", file=sys.stderr)
        for e in err:
            print(" ", e, file=sys.stderr)
        sys.exit(1)
    print("verify_aorus_branding: OK")


if __name__ == "__main__":
    main()
