#!/usr/bin/env python3
"""Drives a profile through Lumen's WebDriver, as a team's own script would.

    python3 scripts/webdriver_check.py <address> <form url>

`address` is a profile's WebDriver address (`http://127.0.0.1:<port>/wd/<token>/<profile>`, what
the profile's inspector gives to copy; `Lumen --webdriver-serve` prints one for CI); `form url` is
the self-test proxy's automation form (`/pb-automation/form`).

With Selenium installed it is Selenium that speaks (webdriver.Remote, as in docs/AUTOMATION.md);
without it, the same commands of the W3C protocol sent by hand — and the last line says which.
The basic scenario: open the page, find the field, type into it, click the button, read the text —
then a script with an element for its argument, a cookie, a screenshot, the window's size, and
the session's end. Prints `WEBDRIVER PASS …` and exits 0, or `WEBDRIVER FAIL …` and exits 1.
"""
import base64
import json
import sys
import urllib.error
import urllib.request

ELEMENT = "element-6066-11e4-a52e-4f735466cecf"


class Raw:
    """The protocol by hand, for a Mac without Selenium: the calls the check makes, no more."""

    def __init__(self, address):
        self.address = address.rstrip("/")
        self.session = self.call("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}})["sessionId"]

    def call(self, method, path, body=None):
        data = None if body is None and method != "POST" else json.dumps(body or {}).encode()
        request = urllib.request.Request(self.address + path, data=data, method=method,
                                         headers={"Content-Type": "application/json; charset=utf-8"})
        try:
            with urllib.request.urlopen(request, timeout=330) as response:
                return json.load(response)["value"]
        except urllib.error.HTTPError as error:
            value = json.load(error).get("value", {})
            raise RuntimeError(f"{value.get('error')}: {value.get('message')}") from None

    def s(self, method, path, body=None):
        return self.call(method, f"/session/{self.session}{path}", body)

    def wait(self, seconds): self.s("POST", "/timeouts", {"implicit": int(seconds * 1000)})
    def get(self, url): self.s("POST", "/url", {"url": url})
    def find(self, using, value): return self.s("POST", "/element", {"using": using, "value": value})[ELEMENT]
    def send_keys(self, element, text): self.s("POST", f"/element/{element}/value", {"text": text})
    def click(self, element): self.s("POST", f"/element/{element}/click", {})
    def text(self, element): return self.s("GET", f"/element/{element}/text")
    def execute(self, script, *elements): return self.s("POST", "/execute/sync", {"script": script, "args": [{ELEMENT: e} for e in elements]})
    def title(self): return self.s("GET", "/title")
    def add_cookie(self, cookie): self.s("POST", "/cookie", {"cookie": cookie})
    def cookies(self): return self.s("GET", "/cookie")
    def screenshot(self): return base64.b64decode(self.s("GET", "/screenshot"))
    def set_window_size(self, width, height): return self.s("POST", "/window/rect", {"width": width, "height": height})
    def window_size(self): rect = self.s("GET", "/window/rect"); return rect["width"], rect["height"]
    def quit(self): self.call("DELETE", f"/session/{self.session}")


class WithSelenium:
    """The same through Selenium's own client."""

    def __init__(self, address):
        from selenium import webdriver
        from selenium.webdriver.common.by import By
        self.By = By
        self.driver = webdriver.Remote(command_executor=address, options=webdriver.SafariOptions())

    def wait(self, seconds): self.driver.implicitly_wait(seconds)
    def get(self, url): self.driver.get(url)
    def find(self, using, value): return self.driver.find_element(self.By.XPATH if using == "xpath" else self.By.CSS_SELECTOR, value)
    def send_keys(self, element, text): element.send_keys(text)
    def click(self, element): element.click()
    def text(self, element): return element.text
    def execute(self, script, *elements): return self.driver.execute_script(script, *elements)
    def title(self): return self.driver.title
    def add_cookie(self, cookie): self.driver.add_cookie(cookie)
    def cookies(self): return self.driver.get_cookies()
    def screenshot(self): return self.driver.get_screenshot_as_png()
    def set_window_size(self, width, height): self.driver.set_window_size(width, height)
    def window_size(self): size = self.driver.get_window_size(); return size["width"], size["height"]
    def quit(self): self.driver.quit()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 64
    address, form = sys.argv[1], sys.argv[2]
    try:
        import selenium
        client, by = WithSelenium, f"Selenium {selenium.__version__}"
    except ImportError:
        client, by = Raw, "the protocol by hand (Selenium is not installed)"
    problems = []
    driver = None
    try:
        driver = client(address)
        driver.wait(10)
        driver.get(form)
        # The page puts this one in 0.8 s after it loads, and everything under it moves: found
        # only by waiting for it (the session's implicit wait), and acted on after.
        driver.find("css selector", "#late")
        field = driver.find("css selector", "#field")
        driver.send_keys(field, "Hello")
        button = driver.find("xpath", "//button[@id='button']")
        driver.click(button)
        clicked = driver.text(driver.find("css selector", "#clicked"))
        if clicked != "clicked 1":
            problems.append(f"after the click the button's count says {clicked!r}")
        typed = driver.execute("return arguments[0].value;", field)
        if typed != "Hello":
            problems.append(f"the field holds {typed!r}")
        title = driver.execute("return document.title;")
        if not title or title != driver.title():
            problems.append(f"the title by script is {title!r}, by the command {driver.title()!r}")
        driver.add_cookie({"name": "pbwd", "value": "1"})
        if not any(c.get("name") == "pbwd" and c.get("value") == "1" for c in driver.cookies()):
            problems.append("the cookie added is not among the page's cookies")
        if driver.screenshot()[:8] != b"\x89PNG\r\n\x1a\n":
            problems.append("the screenshot is not a PNG")
        driver.set_window_size(1100, 760)
        size = driver.window_size()
        if abs(size[0] - 1100) > 2 or abs(size[1] - 760) > 2:
            problems.append(f"the window set to 1100 x 760 is {size[0]} x {size[1]}")
    except Exception as error:  # noqa: BLE001 — whatever the client raises is the finding
        problems.append(f"{type(error).__name__}: {str(error)[:400]}")
    finally:
        if driver is not None:
            try:
                driver.quit()
            except Exception as error:  # noqa: BLE001
                problems.append(f"ending the session: {str(error)[:200]}")
    if problems:
        print(f"WEBDRIVER FAIL with {by}: " + "; ".join(problems))
        return 1
    print(f"WEBDRIVER PASS with {by}: a session started the profile; the page opened, the field found by CSS and typed into, "
          "the button found by XPath and clicked, its text read; a script with an element, a cookie, a screenshot and the "
          "window's size; the session ended")
    return 0


if __name__ == "__main__":
    sys.exit(main())
