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
import faulthandler
import json
import os
import shutil
import signal
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
STARTED = time.time()
DEADLINE = 270  # seconds: under the CI step's limit, so a hang is reported here rather than cut off


def say(message):
    print(f"DEVICE-REFERENCE-SAFARI [{time.time() - STARTED:5.1f}s] {message}", flush=True)


def run(command, seconds=30):
    """A command that may not hang the run (sudo security can wait for an authorization no one gives)."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=seconds)
        return result.returncode, (result.stdout + result.stderr).strip()
    except subprocess.TimeoutExpired:
        return None, f"timed out after {seconds}s"


def trust(cert):
    """Trusts the run's certificate for TLS in the System keychain; True when security agreed."""
    code, output = run(["sudo", "-n", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-p", "ssl",
                        "-k", "/Library/Keychains/System.keychain", cert])
    say(f"trust: exit {code} {output}")
    return code == 0


def untrust():
    # Deleting the certificate is enough: remove-trusted-cert waits for an authorization (it hung on CI).
    code, output = run(["sudo", "-n", "security", "delete-certificate", "-c", "pb-device-reference",
                        "/Library/Keychains/System.keychain"], 20)
    say(f"untrust: exit {code} {output[:200]}")


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
            say(f"session: Safari {got.get('browserVersion')}, acceptInsecureCerts {got.get('acceptInsecureCerts')}")
            return got
        except urllib.error.HTTPError as error:
            say(f"session with {capabilities} refused: {error.read().decode(errors='replace')[:300]}")
    raise RuntimeError("Safari refused every session")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=18443)
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--out", help="copy the written reference here")
    args = parser.parse_args()
    if not shutil.which("safaridriver"):
        say("no safaridriver on this machine")
        return 2
    faulthandler.dump_traceback_later(DEADLINE + 20, exit=True)  # the last resort, if even the report below hangs

    directory = tempfile.mkdtemp(prefix="pb-device-reference-safari-")
    cert, key = device_reference.certificate(directory, "127.0.0.1", None)
    trusted = trust(cert)
    reference = os.path.join(device_reference.REFERENCE_DIR, NAME + ".json")
    if os.path.exists(reference):
        os.remove(reference)
    say("certificate made; starting the server")
    server = subprocess.Popen([sys.executable, "-u", "-X", "faulthandler", os.path.join(os.path.dirname(os.path.abspath(__file__)), "device_reference.py"),
                               "--name", NAME, "--port", str(args.port), "--cert", cert, key, "--verbose"],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    threading.Thread(target=lambda: [print(f"  server| {line}", end="", flush=True) for line in server.stdout],
                     daemon=True).start()
    driver_port = free_port()
    driver_log = os.path.join(directory, "safaridriver.log")
    with open(driver_log, "w") as log_handle:
        driver_process = subprocess.Popen(["safaridriver", "-p", str(driver_port)], stdout=log_handle,
                                          stderr=subprocess.STDOUT)
    driver = WebDriver(f"http://127.0.0.1:{driver_port}")

    has_session = threading.Event()

    def watchdog():
        # At the deadline: where every thread here is, the server's stacks (SIGABRT, -X faulthandler),
        # safaridriver's output; then out: 2 if Safari never gave a session, a failure if the pages hung.
        say(f"no verdict after {DEADLINE}s ({'pages opened' if has_session.is_set() else 'no Safari session'}); "
            "stacks follow")
        faulthandler.dump_traceback(all_threads=True)
        try:
            server.send_signal(signal.SIGABRT)
            time.sleep(2)
        except OSError:
            pass
        with open(driver_log, errors="replace") as handle:
            say("safaridriver output: " + handle.read()[-2000:])
        driver_process.kill()
        server.kill()
        sys.stdout.flush()
        os._exit(1 if has_session.is_set() else 2)

    timer = threading.Timer(DEADLINE, watchdog)
    timer.daemon = True
    timer.start()
    try:
        say("waiting for the server and safaridriver")
        if not wait_for_port(args.port + 1, 30):
            say("the server did not listen; its stacks follow")
            server.send_signal(signal.SIGABRT)
            time.sleep(2)
            return 1
        if not wait_for_port(driver_port, 20):
            say("safaridriver did not listen")
            return 2
        say("starting a Safari session")
        try:
            capabilities = start_session(driver)
            has_session.set()
        except (RuntimeError, urllib.error.URLError, OSError) as error:
            say(f"Safari could not be driven: {error}")
            return 2
        accepted = trusted or capabilities.get("acceptInsecureCerts") is True

        entry_url = f"https://{args.host}:{args.port}/"
        say(f"open {entry_url}")
        try:
            driver.navigate(entry_url)
        except urllib.error.HTTPError as error:
            say(f"navigate: {error.read().decode(errors='replace')[:300]}")
        ok, state = wait_for(driver, lambda s: bool(s.get("next")) and s["next"].endswith(f":{args.port + 1}/"), 30)
        say(f"entry page: {'loaded' if ok else 'NOT loaded'} {json.dumps(state)}")
        if not ok:
            return 1 if accepted else 2

        element = driver.request("POST", f"/session/{driver.session}/element", {"using": "css selector", "value": "#next"})
        element_id = next(iter(element.values()))  # the element reference, under WebDriver's one key
        driver.request("POST", f"/session/{driver.session}/element/{element_id}/click", {})
        say("clicked Continue")
        ok, state = wait_for(driver, lambda s: s.get("status") == "sent" or str(s.get("status", "")).startswith("not sent"), 90)
        say(f"measurement page: status {state.get('status')!r} {json.dumps(state)}")
        if state.get("status") != "sent":
            return 1
        deadline = time.time() + 10
        while not os.path.exists(reference) and time.time() < deadline:
            time.sleep(0.3)
        if not os.path.exists(reference):
            say("the page read 'sent' but no JSON was written")
            return 1
        with open(reference, encoding="utf-8") as handle:
            result = json.load(handle)
        network = result.get("network", {})
        say(f"JSON written: {os.path.relpath(reference, device_reference.ROOT)}, "
              f"{os.path.getsize(reference)} bytes; UA {result.get('probe', {}).get('ua')}; "
              f"TLS {[t.get('ja4') for t in network.get('tls', [])]}; HTTP/2 {[h.get('akamai') for h in network.get('h2', [])]}")
        if args.out:
            os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
            shutil.copyfile(reference, args.out)
        return 0
    finally:
        say("cleaning up")
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
            untrust()
        timer.cancel()
        shutil.rmtree(directory, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
