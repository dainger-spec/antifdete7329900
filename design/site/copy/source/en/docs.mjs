// Docs: the section structure (by the app's features) and the article template. The sample article is
// "Importing cookies", from the README and Localizable.strings (cookies.*, profiles.row.importCookies, cookieExport.*).
export default {
  title: 'Docs',
  description: '{{name}} documentation: installing, profiles, proxies, language and time zone, profile data, warm-up, security and verification.',
  index: {
    eyebrow: 'Docs',
    title: 'Using {{name}}',
    lead: 'From installing to warm-up and sync. Every article describes what the app has — in the words on its own buttons.',
    search: 'Search the docs',
    popularTitle: 'Read most often',
    popular: [['docs-import-cookies.html', 'Importing cookies'], ['docs.html', 'If a profile does not start'], ['docs.html', 'The proxy list: importing and checking'], ['docs.html', 'If you forgot the master password']],
  },
  sections: [
    { icon: 'download', title: 'Getting started', items: ['Installing and the first launch', 'The master password', 'Your first profile', 'Moving to another Mac'] },
    { icon: 'person2', title: 'Profiles', items: ['Creating and setting up a profile', 'Ephemeral profiles', 'Several profiles at once', 'Exporting and importing a profile'] },
    { icon: 'network', title: 'Proxies', items: ['A proxy for a profile', 'The proxy list: importing and checking', 'One proxy for many profiles, or in turn', 'If a profile does not start'] },
    { icon: 'globe', title: 'Language, time and place', items: ['Language and region from the proxy’s country', 'Time zone', 'Geolocation', 'WebRTC'] },
    { icon: 'key', title: 'Profile data', items: ['Importing cookies', 'Exporting cookies', 'Passwords and AutoFill', 'History and bookmarks', 'Sync between Macs'] },
    { icon: 'flame', title: 'Warm-up', items: ['Ready-made lists and lists put together for you', 'Time and thoroughness', 'The queue and the schedule', 'The warm-up report'] },
    { icon: 'lockFill', title: 'Security', items: ['How data is encrypted', 'What the server sees', 'If you forgot the master password', 'Locking and quitting'] },
    { icon: 'shieldCheck', title: 'Verification', items: ['Checking a proxy yourself', 'Compared with Safari', 'Build reports'] },
  ],
  nav: {
    search: 'Search',
    toggle: 'Doc sections',
  },
  article: {
    crumbs: ['Docs', 'Profile data'],
    title: 'Importing cookies',
    lead: 'Bring cookies from a file into a profile: from a browser extension, an automation tool, or another browser’s export.',
    meta: ['Updated 29 October 2026', 'About a five-minute read'],
    toc: [['formats', 'Which files work'], ['steps', 'How to import'], ['when', 'Running and stopped profiles'], ['skipped', 'What is not imported'], ['export', 'Exporting cookies']],
    body: `## Which files work {#formats}

{{name}} reads cookie exports in JSON and in the Netscape \`cookies.txt\` format.

| Format | From |
|---|---|
| JSON | EditThisCookie, Cookie-Editor |
| JSON | Puppeteer and Chrome DevTools, Playwright, Selenium |
| JSON | Chrome and Firefox cookie databases, JSON Lines |
| Netscape \`cookies.txt\` | curl, yt-dlp, “cookies.txt” extensions |

A file can be up to 32 MB.

## How to import {#steps}

1. In the profile list, open the profile’s **⋯** menu and choose **Import Cookies…**
2. Click **Choose File…** {{name}} checks it before anything is imported: how many cookies can come across, and which cannot — with the line and why.
3. Click **Import Cookies** — the button shows how many.

::: note
A damaged file does not stop the import. Everything readable is imported; a broken entry costs only itself.
:::

## Running and stopped profiles {#when}

- A **running** profile gets the cookies at once.
- A **stopped** one gets them at its next launch, before the first page loads. Until then they wait in the vault, encrypted.

Session cookies — those with no expiry — last until the profile stops, as in Safari.

## What is not imported {#skipped}

The report lists every entry it skipped. The most common reasons:

| Reason | What to do |
|---|---|
| Expired | Nothing: a site would not take it anyway |
| An encrypted value from Chrome’s database | Only Chrome can read it — export the cookies with an extension |
| Invalid domain | The domain is a public suffix such as \`co.uk\`, or empty |
| \`__Host-\` rules broken | Such a cookie must be Secure, host-only, with the path \`/\` |
| Damaged bytes | The entry is broken; the others are imported |

## Exporting cookies {#export}

The other way round — **⋯ → Export Cookies…** Every cookie of the profile, session ones included, goes into a file other browsers and tools read: \`cookies.txt\` (Netscape), JSON for EditThisCookie and Cookie-Editor, or JSON for Playwright and Puppeteer.

::: warn
The export file is not encrypted. Whoever has it signs in as this profile wherever cookies are the sign-in.
:::`,
    feedback: 'Found a mistake, or is something missing? [Write to us](support.html).',
    prev: ['Profile data', 'Exporting and importing a profile'],
    next: ['Profile data', 'Exporting cookies'],
    prevLabel: 'Previous',
    nextLabel: 'Next',
  },
};
