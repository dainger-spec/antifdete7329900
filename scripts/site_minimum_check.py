#!/usr/bin/env python3
"""Does the website state the minimum macOS the app needs? The app's LSMinimumSystemVersion against
what the site's download pages say in words ("macOS 26 и новее", "macOS 26 or later").

    python3 scripts/site_minimum_check.py --minimum 26.0 --site https://lumenbrowser.io
    python3 scripts/site_minimum_check.py --minimum 26.0 --page ru.html --page en.html   (saved pages)

On 3 November 0.1.1 needed macOS 14.0 by its Info.plist, and so said its download.json and appcast,
while the site said macOS 26 and newer — where the app, needing Safari 26's frameworks, works. Now
the app says 26.0, and release.sh asks the site before anything is published.

The promise lives on the download page of each language — /ru/download and /en/download (the owner,
3 November) — and each is read and must state it on its own; the site's root need not, and the
address without a language is not read. A claim is "macOS", maybe a name ("Tahoe"), a major
version, maybe the name after it, then "и новее", "и выше", "или новее", "или выше", "и более
поздние", "or later", "and later", "or newer", "and newer", "or higher", "and above" or "+".

It says, page by page, the address it read and what it found there: the words of each claim; or no
claim, with what the page says near "macOS" (and whether its text is drawn by JavaScript, which this
check does not run); or that the address could not be read, with its answer. When the site
redirects, the page it led to is named as the one read. Exit 0 when every page
states the app's major version, 1 when one states another (the site and the app disagree), 2 when one
could not be read or states no minimum — the last line names the pages and what was missing.
"""
import argparse
import html
import re
import sys
import urllib.error
import urllib.request

CLAIM = re.compile(
    r"macOS\s+(?:[A-Z][a-z]+\s+)?\(?(\d{2})(?:\.\d+)*\)?(?:\s+[A-Z][a-z]+)?\s*"
    r"(?:и\s+новее|и\s+выше|или\s+новее|или\s+выше|и\s+более\s+поздн\w*|или\s+более\s+поздн\w*|"
    r"or\s+later|and\s+later|or\s+newer|and\s+newer|or\s+higher|and\s+above|\+)",
    re.IGNORECASE)
# What a page says near "macOS" when no claim above is in it: the words, so that whoever reads the
# release's log sees what the site states instead of guessing.
NEAR = re.compile(r".{0,60}\b(?:mac\s?os|tahoe|sequoia|sonoma)\b.{0,60}", re.IGNORECASE)


def text_of(markup):
    """The page's words: tags, scripts and styles out, entities read, spaces made one."""
    markup = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", markup)
    markup = re.sub(r"(?s)<[^>]+>", " ", markup)
    return re.sub(r"\s+", " ", html.unescape(markup))


def claims_in(text):
    return [(int(match.group(1)), match.group(0)) for match in CLAIM.finditer(text)]


def fetch(url):
    """(the address that answered — another when the site redirected — and the page's markup)."""
    request = urllib.request.Request(url, headers={"User-Agent": "Lumen release check"})
    with urllib.request.urlopen(request, timeout=20) as answer:
        return answer.geturl(), answer.read().decode("utf-8", "replace")


# The pages where the promise lives, one per language of the site.
DOWNLOAD_PAGES = ("/ru/download", "/en/download")


def near_macos(text):
    near = [match.group(0).strip() for match in NEAR.finditer(text)][:6]
    return "; ".join(f"“{words}”" for words in near) if near else "no word about macOS at all"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimum", required=True, help="the app's LSMinimumSystemVersion, e.g. 26.0")
    parser.add_argument("--site", help="the site's address; its " + " and ".join(DOWNLOAD_PAGES) + " are read")
    parser.add_argument("--page", action="append", default=[], help="a saved page instead (repeatable)")
    arguments = parser.parse_args()
    major = int(arguments.minimum.split(".")[0])

    pages = []  # (where, the page's markup, or None and why it was not read, the address that answered)
    for path in arguments.page:
        with open(path, encoding="utf-8") as handle:
            pages.append((path, handle.read(), None, path))
    if arguments.site:
        base = arguments.site.rstrip("/")
        for suffix in DOWNLOAD_PAGES:
            url = base + suffix
            try:
                answered, markup = fetch(url)
                pages.append((url, markup, None, answered))
            except (urllib.error.URLError, OSError, ValueError) as error:
                pages.append((url, None, f"{getattr(error, 'code', None) or error}", url))
    if not pages:
        print("site minimum: no page given (--site or --page)")
        return 2

    states, silent, unread = {}, [], []
    for where, markup, problem, answered in pages:
        if markup is None:
            print(f"site minimum: {where}: not read ({problem})")
            unread.append(where)
            continue
        # A redirect is said: what was read is the page it led to, and that page is the one named.
        read_from = "" if answered == where else f" (redirected: what was read is {answered})"
        text = text_of(markup)
        claims = claims_in(text)
        if claims:
            print(f"site minimum: {where}: read{read_from}, {len(markup)} bytes; it states "
                  + "; ".join(f"“{words.strip()}”" for _, words in claims))
            states[where] = sorted({number for number, _ in claims})
            continue
        print(f"site minimum: {where}: read{read_from}, {len(markup)} bytes, {len(text.strip())} characters of text; "
              f"no minimum macOS this check reads (“macOS N и новее”, “macOS N or later”); near “macOS”: {near_macos(text)}")
        if len(text.strip()) < 400 and "<script" in markup.lower():
            print(f"site minimum: {where} holds almost no text but scripts: its words are likely drawn by JavaScript, "
                  "which this check does not run — the site's build can put the claim in the page itself")
        silent.append(where)

    read = ", ".join(where if answered == where else f"{where} (→ {answered})" for where, _, _, answered in pages)
    other = {where: numbers for where, numbers in states.items() if any(number != major for number in numbers)}
    if other:
        print("site minimum: the site and the app disagree — "
              + "; ".join(f"{where} states macOS {', '.join(map(str, numbers))}" for where, numbers in other.items())
              + f"; the app needs macOS {arguments.minimum} (LSMinimumSystemVersion). Addresses asked: {read}")
        return 1
    if silent or unread:
        parts = []
        if unread:
            parts.append("not read: " + ", ".join(unread))
        if silent:
            parts.append("no minimum stated on: " + ", ".join(silent))
        print(f"site minimum: not confirmed — {'; '.join(parts)}"
              + (f"; macOS {major} stated on: {', '.join(states)}" if states else "")
              + f". Addresses asked: {read}")
        return 2
    print(f"site minimum: macOS {major} stated on every address asked, as the app needs (LSMinimumSystemVersion "
          f"{arguments.minimum}): {read}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
