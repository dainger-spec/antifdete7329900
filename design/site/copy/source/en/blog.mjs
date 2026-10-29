// Updates and articles: the list template and the post template. The posts are about real parts of the
// product; the dates are those of the matching changes in the repository (README, git log) and will be
// replaced by publication dates before launch.
export default {
  title: 'Updates',
  description: 'What changed in {{name}}, and why it is built the way it is.',
  list: {
    eyebrow: 'Updates',
    title: 'Updates and articles',
    lead: 'What changed in {{name}}, and why it is built the way it is.',
    filters: [['all', 'All'], ['updates', 'Updates'], ['articles', 'Articles']],
    feed: 'Subscribe by RSS',
  },
  types: { update: 'Update', article: 'Article' },
  posts: [
    { date: '29 October 2026', type: 'article', title: 'What every build checks', summary: 'A capture of every packet, a trace of every write to disk, a comparison with Safari across 448 page signals — how the checks work, and why you can trust them.', href: 'verification.html' },
    { date: '29 October 2026', type: 'update', title: 'Warm-up: a queue, a schedule and 26 countries', summary: 'Several profiles warm up one after another, each encrypted again before the next starts. Repeats on a schedule, and a report by site.', href: 'blog-no-noise.html' },
    { date: '29 October 2026', type: 'update', title: 'A page cannot learn which ports your Mac has open', summary: 'A proxied profile refuses page requests to `127.0.0.1`, `localhost` and `::1`. Every build checks it with a listener on loopback.', href: 'blog-no-noise.html' },
    { date: '29 October 2026', type: 'update', title: 'A proxy list, checked through the proxy itself', summary: 'Import lines in any usual format, and check each: alive or not, exit country and IP, latency — never directly. One proxy for many profiles, or several in turn.', href: 'blog-no-noise.html' },
    { date: '26 October 2026', type: 'article', title: 'Why a profile has no noise', summary: 'Random values in canvas and WebGL look like protection and give a forgery away. What a fingerprint test sees, and why a match with real Safari is stronger.', href: 'blog-no-noise.html' },
  ],
  post: {
    crumb: 'Updates',
    date: '26 October 2026',
    type: 'article',
    title: 'Why a profile has no noise',
    lead: 'Nearly every multi-account browser lists “canvas spoofing”, “WebGL noise” and “font protection” among its features. {{name}} has none of them — and that is a decision, not a gap.',
    byline: 'The {{name}} team',
    readTime: 'About a seven-minute read',
    body: `## What noise is

A site can draw text and shapes on an invisible canvas and read the pixels back. The result depends on the graphics chip, the driver, the fonts and the engine — which is how devices are told apart. Noise is random changes to the pixels as they are read. The idea is to get a “different” fingerprint every time.

## Why noise shows

**It contradicts everything else.** The canvas says one thing, WebGL another, the font metrics a third. A real device does not look like that, and fingerprint tests look for exactly these mismatches.

**It reaches neither workers nor the server.** A script adding noise in the page does not control the code in workers. And a service sees the TLS handshake, HTTP/2 and the order of headers before the page runs a single line.

**It is a signal in itself.** A test can draw the same thing twice and compare, or check whether built-in functions were replaced. Noise it finds is flagged for what it is — forgery.

## What {{name}} does instead

A {{name}} profile is real Safari on your Mac. It adds nothing: canvas, WebGL, fonts and screen are exactly what Safari would show.

We check this on every build. The same probe of 448 signals runs in Safari and in a profile on one machine. 434 match; the 14 differences are explained and published, and none of them is about canvas, WebGL or fonts.

> Noise tries to pass you off as someone else. A match leaves you as what you are: Safari on a Mac.

## So what tells profiles apart

What really is different:

- **storage** — every profile has its own cookies, localStorage and cache;
- **network** — every profile has its own proxy, and so its own address;
- **language and time zone** — from the proxy’s country, at the level of the process.

Hardware signals — the graphics chip, the screen, the system fonts — are the same for every profile on one Mac, as for every tab of one Safari. We do not hide that: they cannot be changed honestly, and changing them dishonestly means going back to noise.

## Check it yourself

Open the same fingerprint test page in Safari and in a profile on one Mac. The values match — apart from Apple Pay and Web Push, which only Safari itself has.

::: note
deviceinfo.me shows “Canvas: Spoofed” in real Safari 26 too: its test accepts only PNGs of certain lengths, and today’s WebKit encodes the same picture differently. That is the test, not the profile.
:::`,
    share: 'Copy link',
    more: 'More posts',
    back: 'All updates',
  },
};
