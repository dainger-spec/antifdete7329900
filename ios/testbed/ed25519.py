"""Ed25519 signatures (RFC 8032), in plain Python: the account server's stand-in signs its documents
of rights with it. Python's standard library has no Ed25519, and the testbed installs nothing. Slow
(a few milliseconds a signature) and not constant-time: for tests only.

    python3 ios/testbed/ed25519.py     # checks itself against RFC 8032's test vectors
"""
import hashlib

P = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
I = pow(2, (P - 1) // 4, P)


def _recover_x(y):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = x * I % P
    if x % 2 != 0:
        x = P - x
    return x


_BY = 4 * pow(5, P - 2, P) % P
_BX = _recover_x(_BY)
B = (_BX, _BY, 1, _BX * _BY % P)   # extended coordinates (X, Y, Z, T)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    A = (y1 - x1) * (y2 - x2) % P
    Bv = (y1 + x1) * (y2 + x2) % P
    C = t1 * 2 * D * t2 % P
    Dv = z1 * 2 * z2 % P
    E, F, G, H = Bv - A, Dv - C, Dv + C, Bv + A
    return (E * F % P, G * H % P, F * G % P, E * H % P)


def _mul(s, point):
    result = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            result = _add(result, point)
        point = _add(point, point)
        s >>= 1
    return result


def _encode(point):
    x, y, z, _ = point
    inverse = pow(z, P - 2, P)
    x, y = x * inverse % P, y * inverse % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _expand(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def public_key(seed):
    """The 32-byte public key of a 32-byte private seed."""
    a, _ = _expand(seed)
    return _encode(_mul(a, B))


def sign(seed, message):
    """The 64-byte signature of `message` with the private seed."""
    a, prefix = _expand(seed)
    public = _encode(_mul(a, B))
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % L
    R = _encode(_mul(r, B))
    h = int.from_bytes(hashlib.sha512(R + public + message).digest(), "little") % L
    return R + ((r + h * a) % L).to_bytes(32, "little")


def _decode(data):
    y = int.from_bytes(data, "little")
    sign_bit, y = y >> 255, y & ((1 << 255) - 1)
    if y >= P:
        return None
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = x * I % P
    if (x * x - xx) % P != 0 or (x == 0 and sign_bit):
        return None
    if x & 1 != sign_bit:
        x = P - x
    return (x, y, 1, x * y % P)


def verify(public, message, signature):
    """Is `signature` (64 bytes) the signature of `message` under the 32-byte public key?"""
    if len(public) != 32 or len(signature) != 64:
        return False
    A, R = _decode(public), _decode(signature[:32])
    s = int.from_bytes(signature[32:], "little")
    if A is None or R is None or s >= L:
        return False
    h = int.from_bytes(hashlib.sha512(signature[:32] + public + message).digest(), "little") % L
    return _encode(_mul(s, B)) == _encode(_add(R, _mul(h, A)))


def self_test():
    # RFC 8032, 7.1: TEST 1 (an empty message), TEST 2 (one byte), TEST 3 (two bytes).
    vectors = [
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "72",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "af82",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
    ]
    for seed, message, public, signature in vectors:
        assert public_key(bytes.fromhex(seed)).hex() == public, "public key"
        assert sign(bytes.fromhex(seed), bytes.fromhex(message)).hex() == signature, "signature"
        assert verify(bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)), "verify"
        # The reds of the check: another message, a changed signature, another key.
        assert not verify(bytes.fromhex(public), bytes.fromhex(message) + b"x", bytes.fromhex(signature)), "another message passed"
        changed = bytearray(bytes.fromhex(signature)); changed[40] ^= 1
        assert not verify(bytes.fromhex(public), bytes.fromhex(message), bytes(changed)), "a changed signature passed"
        assert not verify(bytes.fromhex(vectors[0][2] if public != vectors[0][2] else vectors[1][2]), bytes.fromhex(message), bytes.fromhex(signature)), "another key passed"
    return len(vectors)


if __name__ == "__main__":
    print(f"ed25519: {self_test()} RFC 8032 vectors pass")
