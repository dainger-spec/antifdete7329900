#!/usr/bin/env python3
"""Runs device_reference.py against this Mac's Safari (safaridriver), as a user would: the TLS/HTTP/2
page, its link, then the measurement page until it reads "sent", and checks the JSON was written.

    sudo safaridriver --enable            # once per machine (CI does it)
    python3 scripts/device_reference_safari.py --out build/device-reference-safari.json

Safari under WebDriver cannot click through a certificate warning, so the run's certificate is made
here and trusted in the System keychain (sudo, as on CI); acceptInsecureCerts is asked for as well.
Exit codes: 0 both pages loaded and the result was written; 1 Safari opened a page that stayed blank
or never sent; 2 Safari could not be driven, or the certificate could not be trusted (no verdict).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import device_reference  # noqa: E402
from safari_reference import WebDriver, free_port, wait_for_port  # noqa: E402

NAME = "ci-safari-mac"


def trust(cert):
    """Trusts the run's certificate for TLS in the System keychain; True when security agreed."""
    result = subprocess.run(["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl",
                             "-k", "/Library/Keychains/System.keychain", cert], capture_output=True, text=True)
    print(f"DEVICE-REFERENCE-SAFARI trust: exit {result.returncode} {result.stderr.strip()}", flush=True)
    return result.returncode == 0


def untrust(cert):
    subprocess.run(["sudo", "-n", "security", "remove-trusted-cert", "-d", cert], capture_output=True)
    subprocess.run(["sudo", "-n", "security", "delete-certificate", "-c", "pb-device-reference",
                    "/Library/Keychains/System.keychain"], capture_output=True)


def page_state(driver):
    return driver.execute("return {url: location.href, title: document.title, ready: document.readyState, "
                          "text: (document.body ? document.body.innerText : '').slice(0, 200), "
                          "html: document.documentElement ? document.documentElement.outerHTML.length : 0, "
                          "status: document.getElementById('status') ? document.getElementById('status').textContent : null, "
                          "next: document.getElementById('next') ? document.getElementById('next').href : null}")


def wait_for(driver, test, seconds):
    deadline, state = time.time() + seconds, {}
    while time.time() < deadline:
        try:
            state = page_state(driver)
        except (urllib.error.URLError, OSError, KeyError, ValueError) as error:
            state = {"error": repr(error)}
        if test(state):
            return True, state
        time.sleep(0.5)
    return False, state


def start_session(driver):
    """A Safari session that accepts the run's certificate if it can; plain otherwise."""
    for capabilities in ({"browserName": "Safari", "acceptInsecureCerts": True}, {"browserName": "Safari"}):
        try:
            value = driver.request("POST", "/session", {"capabilities": {"alwaysMatch": capabilities}})
            driver.session = value["sessionId"]
            got = value.get("capabilities", {})
            print(f"DEVICE-REFERENCE-SAFARI session: Safari {got.get('browserVersion')}, "
                  f"acceptInsecureCerts {got.get('acceptInsecureCerts')}", flush=True)
            return got
        except urllib.error.HTTPError as error:
            print(f"DEVICE-REFERENCE-SAFARI session with {capabilities} refused: {error.read().decode(errors='replace')[:300]}",
                  flush=True)
    raise RuntimeError("Safari refused every session")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=18443)
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--out", help="copy the written reference here")
    args = parser.parse_args()
    if not shutil.which("safaridriver"):
        print("DEVICE-REFERENCE-SAFARI: no safaridriver on this machine")
        return 2

    directory = tempfile.mkdtemp(prefix="pb-device-reference-safari-")
    cert, key = device_reference.certificate(directory, "127.0.0.1", None)
    trusted = trust(cert)
    reference = os.path.join(device_reference.REFERENCE_DIR, NAME + ".json")
    if os.path.exists(reference):
        os.remove(reference)
    server = subprocess.Popen([sys.executable, "-u", os.path.join(os.path.dirname(os.path.abspath(__file__)), "device_reference.py"),
                               "--name", NAME, "--port", str(args.port), "--cert", cert, key, "--verbose"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    threading.Thread(target=lambda: [print(f"  server| {line}", end="", flush=True) for line in server.stdout],
                     daemon=True).start()
    driver_port = free_port()
    driver_process = subprocess.Popen(["safaridriver", "-p", str(driver_port)], stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
    driver = WebDriver(f"http://127.0.0.1:{driver_port}")
    try:
        if not wait_for_port(args.port + 1, 20) or not wait_for_port(driver_port, 20):
            print("DEVICE-REFERENCE-SAFARI: the server or safaridriver did not listen")
            return 2
        try:
            capabilities = start_session(driver)
        except (RuntimeError, urllib.error.URLError, OSError) as error:
            print(f"DEVICE-REFERENCE-SAFARI: Safari could not be driven: {error}")
            return 2
        accepted = trusted or capabilities.get("acceptInsecureCerts") is True

        entry_url = f"https://{args.host}:{args.port}/"
        print(f"DEVICE-REFERENCE-SAFARI open {entry_url}", flush=True)
        try:
            driver.navigate(entry_url)
        except urllib.error.HTTPError as error:
            print(f"DEVICE-REFERENCE-SAFARI navigate: {error.read().decode(errors='replace')[:300]}")
        ok, state = wait_for(driver, lambda s: bool(s.get("next")) and s["next"].endswith(f":{args.port + 1}/"), 30)
        print(f"DEVICE-REFERENCE-SAFARI entry page: {'loaded' if ok else 'NOT loaded'} {json.dumps(state)}", flush=True)
        if not ok:
            return 1 if accepted else 2

        element = driver.request("POST", f"/session/{driver.session}/element", {"using": "css selector", "value": "#next"})
        element_id = next(iter(element.values()))  # the element reference, under WebDriver's one key
        driver.request("POST", f"/session/{driver.session}/element/{element_id}/click", {})
        print("DEVICE-REFERENCE-SAFARI clicked Continue", flush=True)
        ok, state = wait_for(driver, lambda s: s.get("status") == "sent" or str(s.get("status", "")).startswith("not sent"), 90)
        print(f"DEVICE-REFERENCE-SAFARI measurement page: status {state.get('status')!r} {json.dumps(state)}", flush=True)
        if state.get("status") != "sent":
            return 1
        deadline = time.time() + 10
        while not os.path.exists(reference) and time.time() < deadline:
            time.sleep(0.3)
        if not os.path.exists(reference):
            print("DEVICE-REFERENCE-SAFARI: the page read 'sent' but no JSON was written")
            return 1
        with open(reference, encoding="utf-8") as handle:
            result = json.load(handle)
        network = result.get("network", {})
        print(f"DEVICE-REFERENCE-SAFARI JSON written: {os.path.relpath(reference, device_reference.ROOT)}, "
              f"{os.path.getsize(reference)} bytes; UA {result.get('probe', {}).get('ua')}; "
              f"TLS {[t.get('ja4') for t in network.get('tls', [])]}; HTTP/2 {[h.get('akamai') for h in network.get('h2', [])]}")
        if args.out:
            os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
            shutil.copyfile(reference, args.out)
        return 0
    finally:
        driver.quit()
        driver_process.terminate()
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
        if os.path.exists(reference):
            os.remove(reference)
        if trusted:
            untrust(cert)
        shutil.rmtree(directory, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
