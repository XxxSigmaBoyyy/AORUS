#!/usr/bin/env python3
"""
AorusCode offline generator — run locally, NEVER in CI.

Code format: AORUS-XXXX-XXXX-XXXX-XXXX
  stripped (no dashes): AORUSXXXXXXXXXXXXXXXXX = 21 chars
  body (16 chars after "AORUS"):
    [0-1]   tier    2 ASCII  "PR"=Pro / "BT"=Beta / "LT"=Lifetime
    [2-9]   exp     8 HEX    unix timestamp in hex, "00000000" = lifetime
    [10-11] uid     2 HEX    random (256 values per batch for uniqueness)
    [12-15] hmac    4 BASE36 HMAC-SHA256(tier+exp+uid, secret)[0:3]

Usage:
  python3 generate_code.py --tier pro --days 365 --count 10
  python3 generate_code.py --tier lifetime --count 5
  python3 generate_code.py --tier beta --days 30 --count 50
"""
from __future__ import annotations
import argparse, hashlib, hmac as _hmac, os, time

# MUST match AorusCodeManager.swift secretXOR ^ xorMask
_SECRET_XOR = bytes([
    0x41,0x4F,0x52,0x55,0x53,0x47,0x52,0x41,
    0x4D,0x5F,0x53,0x45,0x43,0x52,0x45,0x54,
    0x5F,0x4B,0x45,0x59,0x5F,0x56,0x31,0x5F,
    0x32,0x30,0x32,0x35,0x5F,0x41,0x4F,0x52,
])
_XOR_MASK = bytes([
    0x1A,0x2B,0x3C,0x4D,0x5E,0x6F,0x7A,0x1B,
    0x2C,0x3D,0x4E,0x5F,0x60,0x71,0x82,0x13,
    0x24,0x35,0x46,0x57,0x68,0x79,0x8A,0x1B,
    0x2C,0x3D,0x4E,0x5F,0x60,0x71,0x82,0x93,
])
SECRET = bytes(a ^ b for a, b in zip(_SECRET_XOR, _XOR_MASK))

TIER_MAP  = {"pro": "PR", "beta": "BT", "lifetime": "LT"}
ALPHABET  = "0123456789abcdefghijklmnopqrstuvwxyz"

def to_base36(v: int) -> str:
    if v == 0: return "0"
    r = ""
    while v: r = ALPHABET[v % 36] + r; v //= 36
    return r

def make_code(tier: str, expires_ts: int) -> str:
    tier_code = TIER_MAP[tier]
    exp_hex   = f"{expires_ts:08X}"           # 8 hex chars
    uid_hex   = os.urandom(1).hex().upper()   # 2 hex chars

    payload   = (tier_code + exp_hex + uid_hex).encode()
    mac_bytes = _hmac.new(SECRET, payload, hashlib.sha256).digest()

    # First 3 bytes → integer → base36 padded to 4 chars
    mac_int  = (mac_bytes[0] << 16) | (mac_bytes[1] << 8) | mac_bytes[2]
    mac_b36  = to_base36(mac_int).upper()[:4].zfill(4)

    # Body = 16 chars: tier(2)+exp(8)+uid(2)+hmac(4)
    body = tier_code + exp_hex + uid_hex + mac_b36
    assert len(body) == 16, f"body length {len(body)} != 16"

    # Display: AORUS-XXXX-XXXX-XXXX-XXXX
    return f"AORUS-{body[0:4]}-{body[4:8]}-{body[8:12]}-{body[12:16]}"

def main() -> None:
    ap = argparse.ArgumentParser(description="AorusCode offline generator")
    ap.add_argument("--tier",  choices=["pro","beta","lifetime"], required=True)
    ap.add_argument("--days",  type=int, default=0,
                    help="Validity days (0 = lifetime / no expiry)")
    ap.add_argument("--count", type=int, default=1)
    args = ap.parse_args()

    expires_ts = 0
    if args.days > 0:
        expires_ts = int(time.time()) + args.days * 86400
        if expires_ts > 0xFFFF_FFFF:
            raise ValueError("expires_ts overflows 32-bit hex — use fewer days")

    for _ in range(args.count):
        print(make_code(args.tier, expires_ts))

if __name__ == "__main__":
    main()
