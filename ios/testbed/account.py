"""A stand-in for the Lumen account server, for the iPhone app's end-to-end tests: what the server's
docs/CONTRACT.md (§2–§7) and docs/IPHONE.md say an iPhone meets, until the server itself has it.

  http://127.0.0.1:28395
    POST /v1/auth/login            {"email", "password", "robotToken"?}
    POST /v1/auth/login/confirm    {"email", "code"}          the code is always 424242
    POST /v1/auth/login/resend     {"challenge"}
    POST /v1/auth/logout           (session)
    POST /v1/devices/activate      (session) {"machineID", "platform", "profileCount", "appVersion"}
    POST /v1/device/entitlement    (device token) the same body
    DELETE /v1/device              (device token)

  Every account's password is "correct-horse-1". What an account is, its address says — the part
  before the first "-" or "@" (the rest is the test's own, so that two tests never share one):
    pro, team, personal, trial   a paid plan (or the trial running): features browse, proxies, automation
    free                         no plan: export-only, no_license — features ["browse"], two profiles
    ended                        a paid period that ended: export-only, period_ended — the same
    browseonly                   plan "pro", active, and features ["browse"] alone
    phones                       the license's phones are all taken: the activation is refused
    robot                        signing in asks for the robot check first (403 robot_check)
    code                         signing in asks for the code from the email (202 check_email)
    blocked                      403 account_disabled at sign-in
    disabled                     signs in, and its document says the account is blocked: export-only,
                                 account_disabled, features [] — nothing opens (CONTRACT.md §8.4а)
    forged                       its document is signed with another key under the trusted key's id
    newkey                       its document is signed with a key the app does not carry
  An activation that does not say platform "ios" is a Mac's (CONTRACT.md §6.1), and the stand-in's
  licenses have no Mac place left: 409 device_limit_reached — a Mac's refusal, which an iPhone does
  not take for its own. A platform that is neither is 400 invalid_request (field: platform). An
  iPhone over the license's limit of phones: 409 phone_limit_reached with limits.phones (§4.3).

  The testbed's site shows and changes an account (/__account?email=E[&set=S]): S is a plan's name
  from the list above (what the next document says), "revoked" (the device is unlinked: 401
  device_revoked), "down" / "up" (the device's requests get 503 / work again).

    python3 ios/testbed/account.py --key     # the key id and public key the app must trust
"""
import asyncio
import base64
import hashlib
import json
import os
import re
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ed25519  # noqa: E402

PORT = 28395
PASSWORD = "correct-horse-1"
CODE = "424242"
SEED = hashlib.sha256(b"lumen iphone testbed: the key of the documents of rights").digest()
PUBLIC = ed25519.public_key(SEED)
KEY_ID = hashlib.sha256(PUBLIC).digest()[:8].hex()
OTHER_SEED = hashlib.sha256(b"lumen iphone testbed: a key the app does not carry").digest()
OTHER_KEY_ID = hashlib.sha256(ed25519.public_key(OTHER_SEED)).digest()[:8].hex()

PAID = ["browse", "proxies", "automation"]
PLANS = {
    "pro": dict(plan="pro", status="active", reason=None, features=PAID, profiles=50, phones=3, days=30),
    "team": dict(plan="team", status="active", reason=None, features=PAID, profiles=200, phones=10, days=30),
    "personal": dict(plan="personal", status="active", reason=None, features=PAID, profiles=10, phones=3, days=30),
    "trial": dict(plan="trial", status="active", reason=None, features=PAID, profiles=3, phones=3, days=7),
    "free": dict(plan="none", status="export_only", reason="no_license", features=["browse"], profiles=2, phones=3, days=None),
    "ended": dict(plan="personal", status="export_only", reason="period_ended", features=["browse"], profiles=2, phones=3, days=-1),
    "browseonly": dict(plan="pro", status="active", reason=None, features=["browse"], profiles=50, phones=3, days=30),
    "disabled": dict(plan="pro", status="export_only", reason="account_disabled", features=[], profiles=50, phones=3, days=30),
}
ACCOUNTS = {}    # email -> account
SESSIONS = {}    # session token -> email
DEVICES = {}     # device token -> (email, device)
event = lambda kind, **fields: None   # the testbed sets its own


def kind_of(email):
    return re.split(r"[-@]", email, 1)[0]


def account(email):
    email = email.strip().lower()
    if email not in ACCOUNTS:
        kind = kind_of(email)
        ACCOUNTS[email] = dict(email=email, kind=kind, plan=kind if kind in PLANS else ("free" if kind in ("blocked",) else "pro"),
                               id=str(uuid.uuid4()), license=str(uuid.uuid4()), revoked=False, down=False,
                               activations=[], refreshes=0, logouts=0, signouts=0, devices={})
    return ACCOUNTS[email]


def stamp(seconds):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))


def document(acc, device):
    plan = PLANS[acc["plan"]]
    now = int(time.time())
    export = plan["status"] != "active"
    payload = {
        "kind": "lumen.entitlement", "version": 1, "documentID": str(uuid.uuid4()), "accountID": acc["id"],
        "licenseID": acc["license"], "deviceID": device["deviceID"], "machineID": device["machineID"], "platform": "ios",
        "role": "owner", "plan": plan["plan"], "status": plan["status"], "exportReason": plan["reason"],
        "limits": {"profiles": plan["profiles"], "devices": 3, "seats": 1, "phones": plan["phones"]},
        "profilesOnOtherDevices": 0,
        "periodEndsAt": stamp(now + plan["days"] * 86400) if plan["days"] is not None else None,
        "issuedAt": stamp(now), "refreshAfter": stamp(now + (3600 if export else 86400)),
        "expiresAt": stamp(now + 4 * 86400), "graceEndsAt": stamp(now + 7 * 86400),
        "features": plan["features"],
    }
    raw = json.dumps(payload, separators=(",", ":")).encode()
    seed, key_id = SEED, KEY_ID
    if acc["kind"] == "forged":
        seed = OTHER_SEED
    elif acc["kind"] == "newkey":
        seed, key_id = OTHER_SEED, OTHER_KEY_ID
    return {"format": 1, "keyID": key_id, "payload": base64.b64encode(raw).decode(),
            "signature": base64.b64encode(ed25519.sign(seed, raw)).decode()}


def answer(status, body=None):
    reasons = {200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
               404: "Not Found", 409: "Conflict", 415: "Unsupported Media Type", 429: "Too Many Requests", 503: "Service Unavailable"}
    data = b"" if body is None else json.dumps(body).encode()
    head = [f"HTTP/1.1 {status} {reasons.get(status, 'OK')}", "Connection: close", f"Content-Length: {len(data)}"]
    if body is not None:
        head.append("Content-Type: application/json")
    return ("\r\n".join(head) + "\r\n\r\n").encode() + data


def refuse(status, code, **more):
    return answer(status, {"error": dict(code=code, message=f"the stand-in refuses: {code}", **more)})


def session_answer(acc):
    token = "lms_" + uuid.uuid4().hex
    SESSIONS[token] = acc["email"]
    return answer(200, {"sessionToken": token, "expiresAt": stamp(time.time() + 30 * 86400), "accountID": acc["id"],
                        "idleTimeoutSeconds": 604800})


def check_email(acc):
    now = time.time()
    return answer(202, {"status": "check_email", "codeValidSeconds": 900, "codeAttempts": 5, "challenge": "lmc_" + acc["id"],
                        "codeExpiresAt": stamp(now + 900), "codeSentAt": stamp(now), "resendAvailableAt": stamp(now + 60),
                        "resendsLeft": 3})


def handle(method, path, headers, body):
    """One request, as the server would answer it."""
    auth = headers.get("authorization", "")
    token = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
    if body and "application/json" not in headers.get("content-type", ""):
        return refuse(415, "unsupported_media_type")
    try:
        fields = json.loads(body) if body else {}
        assert isinstance(fields, dict)
    except Exception:
        return refuse(400, "invalid_request")

    if (method, path) == ("POST", "/v1/auth/login"):
        email, password = str(fields.get("email", "")), str(fields.get("password", ""))
        acc = account(email)
        event("account", what="login", email=acc["email"], robot=bool(fields.get("robotToken")))
        if password != PASSWORD or "@" not in email:
            return refuse(401, "invalid_credentials")
        if acc["kind"] == "blocked":
            return refuse(403, "account_disabled")
        if acc["kind"] == "robot" and fields.get("robotToken") != "robot-ok-login":
            return refuse(403, "robot_check")
        if acc["kind"] == "code":
            return check_email(acc)
        return session_answer(acc)

    if (method, path) == ("POST", "/v1/auth/login/confirm"):
        acc = account(str(fields.get("email", "")))
        event("account", what="confirm", email=acc["email"])
        return session_answer(acc) if str(fields.get("code", "")) == CODE else refuse(400, "invalid_code")

    if (method, path) == ("POST", "/v1/auth/login/resend"):
        for acc in ACCOUNTS.values():
            if fields.get("challenge") == "lmc_" + acc["id"]:
                event("account", what="resend", email=acc["email"])
                return check_email(acc)
        return refuse(400, "login_expired")

    if (method, path) == ("POST", "/v1/auth/logout"):
        email = SESSIONS.pop(token, None)
        if email:
            ACCOUNTS[email]["logouts"] += 1
        return answer(204) if email else refuse(401, "unauthorized")

    if (method, path) == ("POST", "/v1/devices/activate"):
        email = SESSIONS.get(token)
        if not email:
            return refuse(401, "unauthorized")
        acc = ACCOUNTS[email]
        machine = str(fields.get("machineID", ""))
        acc["activations"].append(dict(platform=fields.get("platform"), machineID=machine, profileCount=fields.get("profileCount"),
                                       appVersion=fields.get("appVersion"), label=fields.get("label")))
        event("account", what="activate", email=email, platform=fields.get("platform"), machineID=machine)
        if not re.fullmatch(r"[0-9a-f]{64}", machine):
            return refuse(400, "invalid_request", field="machineID")
        if fields.get("platform") not in (None, "mac", "ios"):
            return refuse(400, "invalid_request", field="platform")
        if fields.get("platform") != "ios":
            # A Mac's activation: the stand-in's licenses have no Mac place left.
            return refuse(409, "device_limit_reached", devices=[{"deviceID": str(uuid.uuid4()), "code": "A001"}],
                          unlinkAvailableAt=None, unlinkCooldownSeconds=604800, offlineWorkSeconds=604800)
        if acc["kind"] == "phones":
            return refuse(409, "phone_limit_reached", limits={"phones": PLANS[acc["plan"]]["phones"]})
        device = acc["devices"].get(machine) or dict(deviceID=str(uuid.uuid4()), machineID=machine, code=uuid.uuid4().hex[:4].upper())
        acc["devices"][machine] = device
        for old in [t for t, (e, d) in DEVICES.items() if d is device]:
            del DEVICES[old]   # the same iPhone again: a new token, the old one stops working
        device_token = "lmd_" + uuid.uuid4().hex
        DEVICES[device_token] = (email, device)
        acc["revoked"] = False
        now = stamp(time.time())
        return answer(200, {"device": {"deviceID": device["deviceID"], "code": device["code"], "label": "", "createdAt": now,
                                       "lastSeenAt": now, "profileCount": fields.get("profileCount"),
                                       "appVersion": fields.get("appVersion"), "mine": True, "accountEmail": None, "platform": "ios"},
                            "deviceToken": device_token, "entitlement": document(acc, device), "serverTime": now,
                            "unlinkCooldownSeconds": 604800})

    if path == "/v1/device/entitlement" and method == "POST" or (method, path) == ("DELETE", "/v1/device"):
        if token not in DEVICES:
            return refuse(401, "device_revoked")
        email, device = DEVICES[token]
        acc = ACCOUNTS[email]
        if acc["down"]:
            return refuse(503, "internal")
        if acc["revoked"]:
            del DEVICES[token]
            return refuse(401, "device_revoked")
        if method == "DELETE":
            del DEVICES[token]
            acc["signouts"] += 1
            event("account", what="signout", email=email)
            return answer(204)
        if str(fields.get("machineID", "")) != device["machineID"]:
            return refuse(409, "machine_mismatch")
        acc["refreshes"] += 1
        acc["lastProfileCount"] = fields.get("profileCount")
        event("account", what="refresh", email=email, platform=fields.get("platform"), profileCount=fields.get("profileCount"))
        return answer(200, {"entitlement": document(acc, device), "serverTime": stamp(time.time()), "unlinkCooldownSeconds": 604800})

    return None


def control(query):
    """The lines of the site's /__account page: what the stand-in saw of an account, after an optional change."""
    acc = account(query.get("email", ""))
    change = query.get("set")
    if change in PLANS:
        acc["plan"] = change
    elif change == "revoked":
        acc["revoked"] = True
    elif change in ("down", "up"):
        acc["down"] = change == "down"
    last = acc["activations"][-1] if acc["activations"] else {}
    machines = {a["machineID"] for a in acc["activations"]}
    machine = last.get("machineID") or ""
    return [
        f"account: {acc['email']}",
        f"plan: {acc['plan']}",
        f"activations: {len(acc['activations'])}",
        f"platform: {last.get('platform') or 'none'}",
        f"machine: {'64 hex' if re.fullmatch(r'[0-9a-f]{64}', machine) else (machine or 'none')}",
        f"machines: {len(machines)}",
        f"label: {last.get('label') if last.get('label') is not None else 'none'}",
        f"profiles sent: {acc.get('lastProfileCount', last.get('profileCount', 'none'))}",
        f"refreshes: {acc['refreshes']}",
        f"session logouts: {acc['logouts']}",
        f"device signouts: {acc['signouts']}",
        f"sessions open: {sum(1 for e in SESSIONS.values() if e == acc['email'])}",
    ]


async def serve(reader, writer):
    try:
        head = (await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)).decode("latin-1").split("\r\n")
        method, target, _ = head[0].split(" ", 2)
        headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in head[1:] if line)}
        length = int(headers.get("content-length", "0") or 0)
        body = await asyncio.wait_for(reader.readexactly(length), 30) if length else b""
        out = handle(method, target.split("?", 1)[0], headers, body)
        if out is None:   # as the real server: plain text, not the JSON of a refusal
            out = b"HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: 19\r\n\r\n404 page not found\n"
        writer.write(out)
        await writer.drain()
    except Exception:
        pass
    finally:
        writer.close()


async def start(log=None):
    global event
    if log:
        event = log
    return await asyncio.start_server(serve, "127.0.0.1", PORT)


if __name__ == "__main__":
    if "--key" in sys.argv:
        print(f"keyID       {KEY_ID}\npublic key  {base64.b64encode(PUBLIC).decode()}")
    else:
        async def main():
            await start(lambda kind, **f: print(kind, f, flush=True))
            print(f"account stand-in up: http://127.0.0.1:{PORT}", flush=True)
            await asyncio.Event().wait()
        asyncio.run(main())
