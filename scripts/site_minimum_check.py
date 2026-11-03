#!/usr/bin/env python3
"""Does the website state the minimum macOS the app needs? The app's LSMinimumSystemVersion against
what the site says in words ("macOS 26 и новее", "macOS 26 or later").

    python3 scripts/site_minimum_check.py --minimum 26.0 --site https://lumenbrowser.io
    python3 scripts/site_minimum_check.py --minimum 26.0 --page saved.html      (a page as text)

On 3 November 0.1.1 needed macOS 14.0 by its Info.plist, and so said its download.json and appcast,
while the site said macOS 26 and newer — where the app, needing Safari 26's frameworks, works. Now
the app says 26.0, and release.sh asks the site before anything is published.

Every page given (the site's address and its /download) is read as text; a claim is "macOS", maybe a
name ("Tahoe"), a major version, maybe the name after it, then "и новее", "и выше", "или новее",
"или выше", "и более поздние", "or later", "and later", "or newer", "and newer", "or higher", "and
above" or "+". Exit 0 when every claim found names the app's major version, 1 when one names another
(the site and the app disagree), 2 when no page could be read or none states a minimum this check
can read — each said in words, with what was read and, when no claim was found, what each page says
near "macOS" (CI run 669: the live site's root held none this check reads, and /download was 404).
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
    request = urllib.request.Request(url, headers={"User-Agent": "Lumen release check"})
    with urllib.request.urlopen(request, timeout=20) as answer:
        return answer.read().decode("utf-8", "replace")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--minimum", required=True, help="the app's LSMinimumSystemVersion, e.g. 26.0")
    parser.add_argument("--site", help="the site's address; its root and /download are read")
    parser.add_argument("--page", action="append", default=[], help="a saved page instead (repeatable)")
    arguments = parser.parse_args()
    major = int(arguments.minimum.split(".")[0])

    pages = []
    for path in arguments.page:
        with open(path, encoding="utf-8") as handle:
            pages.append((path, handle.read()))
    if arguments.site:
        base = arguments.site.rstrip("/")
        for url in (base + "/", base + "/download"):
            try:
                pages.append((url, fetch(url)))
            except (urllib.error.URLError, OSError, ValueError) as error:
                print(f"site minimum: {url} not read ({getattr(error, 'code', None) or error})")
    if not pages:
        print("site minimum: no page of the site could be read: the macOS it states is not known")
        return 2

    found = []
    for where, markup in pages:
        for number, words in claims_in(text_of(markup)):
            found.append((number, words, where))
            print(f"site minimum: {where} says “{words.strip()}”")
    if not found:
        print(f"site minimum: none of {len(pages)} page(s) states a minimum macOS this check reads "
              "(“macOS N и новее”, “macOS N or later”)")
        for where, markup in pages:
            text = text_of(markup)
            near = [match.group(0).strip() for match in NEAR.finditer(text)][:6]
            said = "; ".join(f"“{words}”" for words in near) if near else "no word about macOS at all"
            print(f"site minimum: {where}: {len(markup)} bytes, {len(text.strip())} characters of text; near “macOS”: {said}")
            if len(text.strip()) < 400 and "<script" in markup.lower():
                print(f"site minimum: {where} holds almost no text but scripts: its words are likely drawn by JavaScript, "
                      "which this check does not run — the site's build can put the claim in the page itself")
        return 2
    other = sorted({number for number, _, _ in found if number != major})
    if other:
        print(f"site minimum: the site states macOS {', '.join(map(str, other))} where the app needs macOS "
              f"{arguments.minimum} (LSMinimumSystemVersion): they disagree")
        return 1
    print(f"site minimum: the site states macOS {major}, as the app needs (LSMinimumSystemVersion {arguments.minimum})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
