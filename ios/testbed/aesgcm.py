"""AES-256-GCM (NIST SP 800-38D) in plain Python, for the testbed's stand-in sync server: the vault
header it serves wraps the vault's key the way the Mac's core does (AEAD.seal: nonce(12) | ciphertext
| tag(16)). The standard library has none, and the testbed installs nothing. Slow and not
constant-time: for tests only.

    python3 ios/testbed/aesgcm.py     # checks itself against NIST's GCM test vectors
"""


def _xtime(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1


def _sbox():
    box, p, q = [0] * 256, 1, 1
    while True:
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) & 0xFF ^ ((q << 2) | (q >> 6)) & 0xFF ^ ((q << 3) | (q >> 5)) & 0xFF ^ ((q << 4) | (q >> 4)) & 0xFF
        box[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    box[0] = 0x63
    return box


SBOX = _sbox()


def _expand(key):
    assert len(key) == 32
    words = [list(key[i:i + 4]) for i in range(0, 32, 4)]
    rcon = 1
    for i in range(8, 60):
        t = list(words[i - 1])
        if i % 8 == 0:
            t = [SBOX[b] for b in t[1:] + t[:1]]
            t[0] ^= rcon
            rcon = _xtime(rcon)
        elif i % 8 == 4:
            t = [SBOX[b] for b in t]
        words.append([a ^ b for a, b in zip(words[i - 8], t)])
    return [sum(words[r * 4:r * 4 + 4], []) for r in range(15)]


def _encrypt_block(rounds, block):
    s = [a ^ b for a, b in zip(block, rounds[0])]
    for r in range(1, 15):
        s = [SBOX[b] for b in s]
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]   # ShiftRows (column-major state)
        if r < 14:
            m = []
            for c in range(4):
                a = s[4 * c:4 * c + 4]
                t = a[0] ^ a[1] ^ a[2] ^ a[3]
                m += [a[i] ^ t ^ _xtime(a[i] ^ a[(i + 1) % 4]) for i in range(4)]
            s = m
        s = [a ^ b for a, b in zip(s, rounds[r])]
    return bytes(s)


def _gmul(x, y):
    r = 0xE1 << 120
    z = 0
    for i in range(127, -1, -1):
        if (y >> i) & 1:
            z ^= x
        x = (x >> 1) ^ r if x & 1 else x >> 1
    return z


def _ghash(h, aad, ct):
    def blocks(b):
        b = b + b"\0" * (-len(b) % 16)
        return [int.from_bytes(b[i:i + 16], "big") for i in range(0, len(b), 16)]
    y = 0
    for x in blocks(aad) + blocks(ct) + [((len(aad) * 8) << 64) | (len(ct) * 8)]:
        y = _gmul(y ^ x, h)
    return y


def _ctr(rounds, counter, data):
    out = bytearray()
    for i in range(0, len(data), 16):
        counter = counter[:12] + ((int.from_bytes(counter[12:], "big") + 1) & 0xFFFFFFFF).to_bytes(4, "big")
        stream = _encrypt_block(rounds, counter)
        out += bytes(a ^ b for a, b in zip(data[i:i + 16], stream))
    return bytes(out)


def seal(key, nonce, plaintext, aad):
    """nonce(12) | ciphertext | tag(16), as CryptoKit's AES.GCM.SealedBox.combined."""
    rounds = _expand(key)
    h = int.from_bytes(_encrypt_block(rounds, bytes(16)), "big")
    j0 = nonce + b"\0\0\0\1"
    ct = _ctr(rounds, j0, plaintext)
    tag = (_ghash(h, aad, ct) ^ int.from_bytes(_encrypt_block(rounds, j0), "big")).to_bytes(16, "big")
    return nonce + ct + tag


def open_(key, combined, aad):
    nonce, ct, tag = combined[:12], combined[12:-16], combined[-16:]
    rounds = _expand(key)
    h = int.from_bytes(_encrypt_block(rounds, bytes(16)), "big")
    j0 = nonce + b"\0\0\0\1"
    want = (_ghash(h, aad, ct) ^ int.from_bytes(_encrypt_block(rounds, j0), "big")).to_bytes(16, "big")
    if want != tag:
        raise ValueError("authentication failed")
    return _ctr(rounds, j0, ct)


def self_test():
    # FIPS-197 C.3: AES-256.
    k = bytes(range(32))
    assert _encrypt_block(_expand(k), bytes.fromhex("00112233445566778899aabbccddeeff")).hex() == "8ea2b7ca516745bfeafc49904b496089", "AES-256"
    # NIST GCM test case 14 (AES-256, zero key, one zero block) and 16 (with AAD).
    z = bytes(32)
    out = seal(z, bytes(12), bytes(16), b"")
    assert out[12:].hex() == "cea7403d4d606b6e074ec5d3baf39d18" + "d0d1c8a799996bf0265b98b5d48ab919", "GCM 14"
    key = bytes.fromhex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308")
    nonce = bytes.fromhex("cafebabefacedbaddecaf888")
    pt = bytes.fromhex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525"
                       "b16aedf5aa0de657ba637b39")
    aad = bytes.fromhex("feedfacedeadbeeffeedfacedeadbeefabaddad2")
    out = seal(key, nonce, pt, aad)
    assert out[12:-16].hex() == ("522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b10"
                                 "56828838c5f61e6393ba7a0abcc9f662"), "GCM 16 ciphertext"
    assert out[-16:].hex() == "76fc6ece0f4e1768cddf8853bb2d551b", "GCM 16 tag"
    assert open_(key, out, aad) == pt
    bad = bytearray(out)
    bad[20] ^= 1
    try:
        open_(key, bytes(bad), aad)
        raise AssertionError("a changed ciphertext opened")
    except ValueError:
        pass
    return 3


if __name__ == "__main__":
    print(f"aesgcm: {self_test()} NIST vectors pass")
