#!/usr/bin/env python3
"""Puts fingerprint probe results side by side (claude/measure-ios-sim): one column per file,
one row per key, nested objects flattened ("webgl.unmaskedRenderer"). Rows where all columns agree
are counted, not printed, unless --all.

    python3 scripts/compare_probes.py ours=surface-iphone.json simulator=probe-simulator.json iphone=probe-iphone.json

Keys a page sees only in a secure context (https, or loopback) are marked "secure context": a page
opened over plain http on a LAN address (a real iPhone with scripts/iphone_probe.sh) lacks them for
that reason alone, not because the device does."""
import json, sys

SECURE_ONLY = ("mediaDevices", "serviceWorker", "storage", "clipboard", "PaymentRequest", "PushManager",
               "Notification", "PublicKeyCredential", "credentials", "crypto.subtle", "subtle", "ApplePaySetup",
               "MerchantValidationEvent", "isSecureContext", "BluetoothUUID", "CookieStore", "cookieStore",
               "IdentityCredential", "DigitalCredential", "ServiceWorker", "Cache", "caches", "StorageManager",
               "PaymentResponse", "PaymentAddress", "PaymentMethodChangeEvent", "PaymentRequestUpdateEvent",
               "WebTransport", "FileSystemHandle", "SharedWorker")

def flatten(value, prefix=""):
    out = {}
    if isinstance(value, dict):
        for key, inner in value.items():
            out.update(flatten(inner, prefix + key + "."))
    else:
        out[prefix[:-1]] = value if isinstance(value, str) else json.dumps(value)
    return out

def main():
    show_all = "--all" in sys.argv
    columns = [a.split("=", 1) for a in sys.argv[1:] if "=" in a]
    data = [(name, flatten(json.load(open(path)))) for name, path in columns]
    keys = sorted(set().union(*(d.keys() for _, d in data)) - {k for _, d in data for k in d if k.startswith(("_page", "_engine"))})
    same = 0
    print("| key | " + " | ".join(name for name, _ in data) + " | note |")
    print("|---|" + "---|" * len(data) + "---|")
    for key in keys:
        values = [d.get(key, "—") for _, d in data]
        if len(set(values)) == 1 and not show_all:
            same += 1
            continue
        note = "secure context" if any(s in key for s in SECURE_ONLY) else ""
        print("| " + key + " | " + " | ".join(str(v).replace("|", "¦")[:160] for v in values) + " | " + note + " |")
    print("\n%d keys the same in every column" % same)

if __name__ == "__main__":
    main()
