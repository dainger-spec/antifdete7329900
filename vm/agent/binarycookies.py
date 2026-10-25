#!/usr/bin/env python3
"""Encode (and decode, for tests) Safari's Cookies.binarycookies format.

Layout (per libyal dtformats "Safari Cookies"): a file header with a big-endian
page count and page sizes, then pages whose headers/records are little-endian,
then an 8-byte footer. Times are Cocoa timestamps (seconds since 2001-01-01).

We encode the normalized cookies from CookieImport (dicts with keys domain,
path, name, value, secure, httpOnly, expires[, unix seconds]) into one page.

The byte layout round-trips through decode() in the tests. Whether a given
macOS Safari *accepts* a hand-written store (exact container path, sandbox,
the footer checksum it ignores) is the one thing that needs a real Mac.
"""
from __future__ import annotations

import struct
import time

# Cocoa/Mac reference date (2001-01-01 UTC) in Unix seconds.
MAC_EPOCH = 978307200
PAGE_SIGNATURE = b"\x00\x00\x01\x00"
FLAG_SECURE = 0x1
FLAG_HTTPONLY = 0x4
RECORD_HEADER_SIZE = 56
# The format has no "session cookie" marker: expiry 0 means 2001-01-01, i.e.
# already expired. A cookie imported without an expiry gets this lifetime.
SESSION_LIFETIME = 30 * 24 * 3600


def _cstr(text: str) -> bytes:
    return text.encode("utf-8") + b"\x00"


def _cocoa(unix_seconds: float | None) -> float:
    return float(unix_seconds) - MAC_EPOCH if unix_seconds else 0.0


def encode_record(cookie: dict, now: float | None = None) -> bytes:
    now = time.time() if now is None else now
    domain = _cstr(cookie["domain"])
    name = _cstr(cookie["name"])
    path = _cstr(cookie.get("path") or "/")
    value = _cstr(cookie["value"])

    domain_off = RECORD_HEADER_SIZE
    name_off = domain_off + len(domain)
    path_off = name_off + len(name)
    value_off = path_off + len(path)
    size = value_off + len(value)

    # A cookie read back from Safari's own store keeps its raw flags (they
    # carry more than secure/httpOnly, e.g. SameSite on newer macOS).
    flags = cookie.get("_flags")
    if not isinstance(flags, int):
        flags = 0
        if cookie.get("secure"):
            flags |= FLAG_SECURE
        if cookie.get("httpOnly"):
            flags |= FLAG_HTTPONLY

    expiration = _cocoa(cookie.get("expires") or now + SESSION_LIFETIME)
    creation = _cocoa(now)

    record = struct.pack("<IIII", size, 0, flags, 0)
    record += struct.pack("<IIII", domain_off, name_off, path_off, value_off)
    record += struct.pack("<Q", 0)              # 8 bytes, documented as 0
    record += struct.pack("<dd", expiration, creation)
    record += domain + name + path + value
    assert len(record) == size, (len(record), size)
    return record


def encode_page(cookies: list[dict], now: float | None = None) -> bytes:
    records = [encode_record(c, now=now) for c in cookies]
    # sig(4) + count(4) + offsets(4*n) + footer(4), then the records.
    records_start = 12 + 4 * len(records)
    offsets = []
    position = records_start
    for record in records:
        offsets.append(position)
        position += len(record)
    page = PAGE_SIGNATURE + struct.pack("<I", len(records))
    page += b"".join(struct.pack("<I", off) for off in offsets)
    page += b"\x00\x00\x00\x00"
    page += b"".join(records)
    return page


def encode(cookies: list[dict], now: float | None = None) -> bytes:
    """One page holding every cookie — plenty for a profile's cookie set."""
    pages = [encode_page(cookies, now=now)] if cookies else [encode_page([], now=now)]
    header = b"cook" + struct.pack(">I", len(pages))
    header += b"".join(struct.pack(">I", len(page)) for page in pages)
    footer = b"\x00" * 8  # unknown checksum; readers (and Safari) ignore it
    return header + b"".join(pages) + footer


def decode(data: bytes) -> list[dict]:
    """Parse a binarycookies blob back into cookie dicts. Used by the tests to
    prove encode() is self-consistent."""
    if data[:4] != b"cook":
        raise ValueError("not a binarycookies file")
    (num_pages,) = struct.unpack(">I", data[4:8])
    page_sizes = [struct.unpack(">I", data[8 + 4 * i:12 + 4 * i])[0] for i in range(num_pages)]
    cursor = 8 + 4 * num_pages
    cookies: list[dict] = []
    for size in page_sizes:
        page = data[cursor:cursor + size]
        cursor += size
        if page[:4] != PAGE_SIGNATURE:
            raise ValueError("bad page signature")
        (count,) = struct.unpack("<I", page[4:8])
        offsets = [struct.unpack("<I", page[8 + 4 * i:12 + 4 * i])[0] for i in range(count)]
        for off in offsets:
            rec = page[off:]
            (_size, _u1, flags, _u2) = struct.unpack("<IIII", rec[0:16])
            (domain_off, name_off, path_off, value_off) = struct.unpack("<IIII", rec[16:32])
            (expiration, _creation) = struct.unpack("<dd", rec[40:56])

            def cstr(base: int) -> str:
                end = rec.index(b"\x00", base)
                return rec[base:end].decode("utf-8")

            cookies.append({
                "domain": cstr(domain_off),
                "name": cstr(name_off),
                "path": cstr(path_off),
                "value": cstr(value_off),
                "secure": bool(flags & FLAG_SECURE),
                "httpOnly": bool(flags & FLAG_HTTPONLY),
                "expires": int(expiration + MAC_EPOCH) if expiration else None,
                "_flags": flags,
            })
    return cookies


def try_decode(data: bytes) -> list[dict] | None:
    """decode(), or None for a store this decoder can't read."""
    try:
        return decode(data) if data else []
    except (ValueError, IndexError, struct.error, UnicodeDecodeError):
        return None


def merge(existing: list[dict], incoming: list[dict]) -> list[dict]:
    """`existing` with `incoming` laid over it: an imported cookie replaces
    the one with the same (domain, name, path); every other cookie stays."""
    def key(cookie: dict) -> tuple:
        return (cookie["domain"], cookie["name"], cookie.get("path") or "/")

    replaced = {key(c) for c in incoming}
    return [c for c in existing if key(c) not in replaced] + list(incoming)
