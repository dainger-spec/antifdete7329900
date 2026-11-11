#!/usr/bin/env python3
"""The sync's first steps against the real Lumen server with the test account (the owner gave the
account for checks, 11 November 2026): a vault is made as a Mac makes one (its header only), the
iPhone finds it on its device token, fetches its header and turns the master password into the
key — then the account's sync data is deleted again, as the cabinet deletes it.

    LUMEN_E2E_EMAIL=… LUMEN_E2E_PASSWORD=… python3 ios/scripts/real_server_sync.py

It touches nothing but the test account, and refuses to start if the account already has a vault
(that would be someone's data, not this script's). Nothing secret is printed.
"""
import base64, hashlib, json, os, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "testbed"))
sys.path.insert(0, HERE)
import aesgcm  # noqa: E402
import real_server as rs  # noqa: E402

SERVER = rs.SERVER
GEN = "X-Lumen-Server-Generation"


def put(path, data, token, headers):
    import urllib.request, urllib.error
    request = urllib.request.Request(SERVER + path, method="PUT", data=data)
    request.add_header("User-Agent", "Lumen/1.0 (1) iOS/e2e")
    request.add_header("Authorization", "Bearer " + token)
    for name, value in headers.items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request, timeout=30) as answer:
            return answer.status, dict(answer.headers), answer.read()
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers), error.read()


def get_raw(path, token):
    import urllib.request, urllib.error
    request = urllib.request.Request(SERVER + path)
    request.add_header("User-Agent", "Lumen/1.0 (1) iOS/e2e")
    request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=30) as answer:
            return answer.status, answer.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def main():
    email, password = os.environ.get("LUMEN_E2E_EMAIL", ""), os.environ.get("LUMEN_E2E_PASSWORD", "")
    if not email or not password:
        print("real server sync: LUMEN_E2E_EMAIL and LUMEN_E2E_PASSWORD are not set — nothing was run")
        return 2
    check = rs.check
    status, answer = rs.call(SERVER, "POST", "/v1/auth/login", {"email": email, "password": password})
    if not check(status == 200, "sign-in: 200", str(status)):
        return 1
    session = answer["sessionToken"]
    machine = hashlib.sha256(b"lumen.machine-id.ios.v1\n" + os.urandom(32).hex().encode()).hexdigest()
    device_token = None
    made = False
    try:
        status, answer = rs.call(SERVER, "POST", "/v1/devices/activate",
                                 {"machineID": machine, "profileCount": 0, "appVersion": "1.0 (1)", "platform": "ios"}, token=session)
        if not check(status == 200, "activation as an iPhone: 200", f"{status} {rs.code_of(answer)}"):
            return 1
        device_token = answer["deviceToken"]

        status, answer = rs.call(SERVER, "GET", "/v1/device/sync/vaults", token=device_token)
        if not check(status == 200 and answer.get("vaults") == [], "the test account has no vault before the check",
                     f"{status} {len(answer.get('vaults') or [])} vault(s) — not touched"):
            return 1

        # A vault as a Mac makes one (MasterVault.create): PBKDF2 with few rounds, the master key wrapped.
        master = "e2e-" + os.urandom(9).hex()
        vault_id = str(uuid.uuid4()).upper()
        salt = os.urandom(16)
        kek = hashlib.pbkdf2_hmac("sha256", master.encode(), salt, 1000, 32)
        wrapped = aesgcm.seal(kek, os.urandom(12), os.urandom(32), f"vault-master-key:v1:{vault_id}".encode())
        header = json.dumps({"format": 2, "vaultID": vault_id,
                             "kdf": {"algorithm": "pbkdf2-hmac-sha256", "iterations": 1000, "salt": base64.b64encode(salt).decode()},
                             "wrappedMasterKey": base64.b64encode(wrapped).decode(), "createdAt": "2026-11-11T21:00:00Z",
                             "passwordRevision": 0}).encode()
        path = f"/v1/vaults/{vault_id.lower()}/objects/vault-header"
        status, headers, _ = put(path, header, device_token,
                                 {"Content-Type": "application/octet-stream", "X-PB-Revision": "1", "If-None-Match": "*", GEN: "none"})
        made = status in (200, 201, 204)
        check(made, "the vault made with its header: 201", str(status))
        generation = {k.lower(): v for k, v in headers.items()}.get(GEN.lower())
        check(bool(generation) and len(generation) == 32, "the new vault has a generation", str(generation))

        # The iPhone's path: the list on the device token, the header, the key.
        status, answer = rs.call(SERVER, "GET", "/v1/device/sync/vaults", token=device_token)
        ids = [v.get("vaultID") for v in (answer.get("vaults") or [])]
        check(status == 200 and ids == [vault_id.lower()], "the vault is listed on the device token, its id in lower case", f"{status} {ids}")
        status, blob = get_raw(path, device_token)
        check(status == 200 and blob == header, "its header comes back as it was put", str(status))
        got = json.loads(blob)
        key = hashlib.pbkdf2_hmac("sha256", master.encode(), base64.b64decode(got["kdf"]["salt"]), got["kdf"]["iterations"], 32)
        try:
            vmk = aesgcm.open_(key, base64.b64decode(got["wrappedMasterKey"]), f"vault-master-key:v1:{got['vaultID']}".encode())
            check(len(vmk) == 32, "the master password's key opens it")
        except ValueError:
            check(False, "the master password's key opens it")
        wrong = hashlib.pbkdf2_hmac("sha256", b"wrong", base64.b64decode(got["kdf"]["salt"]), got["kdf"]["iterations"], 32)
        try:
            aesgcm.open_(wrong, base64.b64decode(got["wrappedMasterKey"]), f"vault-master-key:v1:{got['vaultID']}".encode())
            check(False, "a wrong password opens nothing")
        except ValueError:
            check(True, "a wrong password opens nothing")
    finally:
        if made:
            status, answer = rs.call(SERVER, "POST", "/v1/account/sync/delete", {"password": password}, token=session)
            check(status == 204, "the test vault deleted again (the cabinet's deletion): 204", f"{status} {rs.code_of(answer)}")
            if device_token:
                status, answer = rs.call(SERVER, "GET", "/v1/device/sync/vaults", token=device_token)
                check(status == 200 and answer.get("vaults") == [], "no vault left", str(answer.get("vaults")))
        rs.call(SERVER, "POST", "/v1/auth/logout", token=session)
        if device_token:
            status, _ = rs.call(SERVER, "DELETE", "/v1/device", token=device_token)
            check(status == 204, "the iPhone signed out: 204", str(status))
    print("real server sync: " + ("all checks pass" if not rs.failures else f"{len(rs.failures)} FAILED"))
    return 1 if rs.failures else 0


if __name__ == "__main__":
    sys.exit(main())
