#!/usr/bin/env python3
"""The iPhone's path against the real Lumen account server, with the test account (the lead,
10 November): sign in, activate as an iPhone, the document of rights checked with the production
key, a renewal, another device's renewal refused, and the sign-out that frees the phone's place.

    LUMEN_E2E_EMAIL=… LUMEN_E2E_PASSWORD=… python3 ios/scripts/real_server.py [server]

The address and the password come from the environment only; neither they nor a token is printed.
The device it activates is unlinked at the end, whatever happened before. Run by hand (the
"RealServerTests" suite of ios-app.yml), never on a push: it talks to production.
"""
import base64, datetime, hashlib, json, os, sys, urllib.error, urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "testbed"))
import ed25519

SERVER = "https://api.lumenbrowser.io"
# The production key of the documents of rights (the lead, 10 November 2026; server v2026.11.10.3).
KEY_ID = "63a9a50f8cc6f129"
KEY = "bOCnaE4nVmmeqieu9CNIo0AY86OOYqe65OwSJbTwYn0="
DEVELOPMENT_KEY_ID = "445c6300da0205b1"

failures = []


def check(ok, what, detail=""):
    print(("ok    " if ok else "FAIL  ") + what + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(what)
    return ok


def call(server, method, path, body=None, token=None):
    request = urllib.request.Request(server + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    request.add_header("User-Agent", "Lumen/1.0 (1) iOS/e2e")
    if body is not None:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=30) as answer:
            status, data = answer.status, answer.read()
    except urllib.error.HTTPError as error:
        status, data = error.code, error.read()
    try:
        return status, json.loads(data) if data else {}
    except ValueError:
        return status, {"notJSON": data[:80].decode("utf-8", "replace")}


def uuid_like(text):
    return isinstance(text, str) and len(text) == 36 and text.count("-") == 4


def code_of(answer):
    return (answer.get("error") or {}).get("code") if isinstance(answer, dict) else None


def time_of(text):
    return datetime.datetime.strptime(text[:19] + "Z", "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def document(envelope, device_id, machine_id, what):
    """The steps of the contract's §7.4 on an envelope; the content when all pass."""
    if not check(isinstance(envelope, dict) and envelope.get("format") == 1, f"{what}: an envelope of format 1"):
        return None
    check(envelope.get("keyID") != DEVELOPMENT_KEY_ID, f"{what}: not signed with the development key")
    if not check(envelope.get("keyID") == KEY_ID, f"{what}: signed with the production key {KEY_ID}", str(envelope.get("keyID"))):
        return None
    payload = base64.b64decode(envelope["payload"])
    if not check(ed25519.verify(base64.b64decode(KEY), payload, base64.b64decode(envelope["signature"])), f"{what}: the signature is the key's"):
        return None
    changed = bytearray(payload); changed[len(changed) // 2] ^= 1
    check(not ed25519.verify(base64.b64decode(KEY), bytes(changed), base64.b64decode(envelope["signature"])), f"{what}: a changed content does not pass (the check's own red)")
    content = json.loads(payload)
    check(content.get("kind") == "lumen.entitlement" and content.get("version") == 1, f"{what}: kind and version", f"{content.get('kind')} {content.get('version')}")
    check(content.get("deviceID") == device_id and content.get("machineID") == machine_id, f"{what}: bound to this device and this phone's id")
    check(content.get("platform") == "ios", f"{what}: platform ios", str(content.get("platform")))
    return content


def main():
    server = sys.argv[1] if len(sys.argv) > 1 else SERVER
    email, password = os.environ.get("LUMEN_E2E_EMAIL", ""), os.environ.get("LUMEN_E2E_PASSWORD", "")
    if not email or not password:
        print("real server: LUMEN_E2E_EMAIL and LUMEN_E2E_PASSWORD are not set — nothing was run")
        return 2
    check(hashlib.sha256(base64.b64decode(KEY)).digest()[:8].hex() == KEY_ID, "the production key's id is its key's")
    print(f"server {server}")

    # The phone's id as the app makes it: a hash of a random value kept in the Keychain.
    machine_id = hashlib.sha256(b"lumen.machine-id.ios.v1\n" + os.urandom(32).hex().encode()).hexdigest()
    other_machine = hashlib.sha256(b"lumen.machine-id.ios.v1\n" + os.urandom(32).hex().encode()).hexdigest()
    body = {"machineID": machine_id, "profileCount": 1, "appVersion": "1.0 (1)", "platform": "ios"}

    status, answer = call(server, "POST", "/v1/auth/login", {"email": email, "password": password})
    if not check(status == 200 and "sessionToken" in answer, "sign-in: 200 with a session", f"{status} {code_of(answer) or answer.get('status')}"):
        return 1
    session = answer["sessionToken"]
    device_token = None
    try:
        status, answer = call(server, "POST", "/v1/devices/activate", body, token=session)
        if not check(status == 200 and "deviceToken" in answer, "activation as an iPhone: 200", f"{status} {code_of(answer)} {(answer.get('error') or {}).get('limits')}"):
            return 1
        device_token, device_id = answer["deviceToken"], answer["device"]["deviceID"]
        content = document(answer.get("entitlement"), device_id, machine_id, "the activation's document")
        if content:
            now = time_of(answer["serverTime"])
            print(f"      plan {content.get('plan')}, status {content.get('status')}, features {content.get('features')}, limits {content.get('limits')}, "
                  f"profilesOnOtherDevices {content.get('profilesOnOtherDevices')}, period ends {content.get('periodEndsAt')}")
            check(content.get("plan") == "pro" and content.get("status") == "active", "the test account's plan: pro, active", f"{content.get('plan')} {content.get('status')}")
            features = content.get("features")
            check(isinstance(features, list) and "browse" in features and "proxies" in features, "features open browse and proxies", str(features))
            limits = content.get("limits") or {}
            check(limits.get("phones") == 3, "limits.phones is 3", str(limits.get("phones")))
            check(limits.get("profiles") == 50, "limits.profiles is 50", str(limits.get("profiles")))
            check(time_of(content["issuedAt"]) <= now + datetime.timedelta(minutes=5) and now < time_of(content["refreshAfter"]) <= time_of(content["expiresAt"]) <= time_of(content["graceEndsAt"]),
                  "the document's times are in order around the server's time")
            check(content.get("periodEndsAt") and time_of(content["periodEndsAt"]) > now, "the paid period is running")

        status, answer = call(server, "POST", "/v1/auth/logout", token=session)
        check(status == 204, "the account's session ends after the activation: 204", str(status))
        session = None

        status, answer = call(server, "POST", "/v1/device/entitlement", body, token=device_token)
        if check(status == 200, "renewal with the device's token: 200", f"{status} {code_of(answer)}"):
            document(answer.get("entitlement"), device_id, machine_id, "the renewal's document")

        # The sync's list of vaults on the device token (CONTRACT.md §16.1): the test account's plan has it.
        status, answer = call(server, "GET", "/v1/device/sync/vaults", token=device_token)
        vaults = answer.get("vaults") if isinstance(answer, dict) else None
        check(status == 200 and isinstance(vaults, list), "the sync's vaults on the device token: 200 with a list", f"{status} {code_of(answer)}")
        if isinstance(vaults, list):
            print(f"      vaults: {len(vaults)}")
            check(all(set(v) >= {"vaultID", "changedAt"} and uuid_like(v["vaultID"]) for v in vaults), "each vault: an id and when it changed")

        tokens = dict(body, profileTokens=[hashlib.sha256(b"e2e").hexdigest()[:32]])
        status, answer = call(server, "POST", "/v1/device/entitlement", tokens, token=device_token)
        check(status == 200, "renewal with profileTokens is taken: 200", f"{status} {code_of(answer)}")

        status, answer = call(server, "POST", "/v1/device/entitlement", dict(body, machineID=other_machine), token=device_token)
        check(status == 409 and code_of(answer) == "machine_mismatch", "another phone with this token: 409 machine_mismatch", f"{status} {code_of(answer)}")
    finally:
        if session:
            call(server, "POST", "/v1/auth/logout", token=session)
        if device_token:
            status, answer = call(server, "DELETE", "/v1/device", token=device_token)
            check(status == 204, "sign-out of the iPhone: 204, no cooldown", f"{status} {code_of(answer)}")
            status, answer = call(server, "POST", "/v1/device/entitlement", body, token=device_token)
            check(status == 401 and code_of(answer) == "device_revoked", "after the sign-out the token is refused: 401 device_revoked", f"{status} {code_of(answer)}")
    print("real server: " + ("all checks pass" if not failures else f"{len(failures)} FAILED"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
