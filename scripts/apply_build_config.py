#!/usr/bin/env python3
"""
Apply AorusGram build configuration to a Telegram iOS checkout.
Must be run from the telegram-ios directory.

Usage:
    python3 apply_build_config.py [--config-path <path>] [--api-id <id>] [--api-hash <hash>]
"""
import argparse
import json
import os
import sys

DEFAULT_CONFIG = {
    "bundle_id": "org.aorusgram.Telegram-iOS",
    "api_id": os.environ.get("TG_API_ID", "8"),
    "api_hash": os.environ.get("TG_API_HASH", "7245de8e747a0d6fbe11f7cc14fcc0bb"),
    "team_id": os.environ.get("TG_TEAM_ID", "AORUSGRAM1"),
    "app_center_id": "0",
    "is_internal_build": "true",
    "is_appstore_build": "false",
    "appstore_id": "0",
    "app_specific_url_scheme": "aorusgram",
    "premium_iap_product_id": "",
    "enable_siri": False,
    "enable_icloud": False,
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-path", default=None, help="Path to custom appstore-configuration.json")
    parser.add_argument("--api-id", default=None, help="Telegram API ID (overrides config and env)")
    parser.add_argument("--api-hash", default=None, help="Telegram API Hash (overrides config and env)")
    parser.add_argument("--tg-dir", default=".", help="Path to telegram-ios checkout")
    args = parser.parse_args()

    config = dict(DEFAULT_CONFIG)

    if args.config_path and os.path.exists(args.config_path):
        with open(args.config_path) as f:
            override = json.load(f)
        config.update(override)
        print(f"Loaded config from {args.config_path}")

    if args.api_id:
        config["api_id"] = args.api_id
    if args.api_hash:
        config["api_hash"] = args.api_hash

    out_path = os.path.join(args.tg_dir, "build-system/appstore-configuration.json")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(config, f, indent="\t")

    print(f"Written: {out_path}")
    print(f"  bundle_id : {config['bundle_id']}")
    print(f"  api_id    : {config['api_id']}")
    print(f"  team_id   : {config['team_id']}")
    print(f"  url_scheme: {config['app_specific_url_scheme']}")

if __name__ == "__main__":
    main()
