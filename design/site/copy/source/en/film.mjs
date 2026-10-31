// The promo film v2, 30 seconds, "Graphite" (tools/film, design/site/video). The words in frame, shot by shot
// (S01–S21 of the v2 spec): five cards (S03, S06, S09, S14, S16), captions, the table of numbers, the end card.
// A card's first line is white, the second grey. Numbers from copy/facts.mjs (31/31, 15/15, 10/10, 448, 0,
// 84). No "antidetect", no "all 448", no "all match", no trial length; domains are *.example only. The build
// (tools/film/build.mjs) sets the no-break spaces and the hanging punctuation; there are none here.
export default {
  // S03 · 4.5–5.5
  claim: ['Every account', 'gets its own Safari.'],
  // S06 · 8.5–9.5: one big word and a line under it (from the home page: "side by side, and they can't see each other")
  atOnce: ['At once.', 'And they can’t see each other.'],
  // S07 · 9.5–11.5: each profile its own country. One moment: 29 October 2026, 13:32 UTC. The build pads the hour
  // with a figure space (U+2007) so the colon never moves.
  sites: 'Its own IP, language and time zone',
  countries: [['DE', 'Germany', '14:32', 'de-DE · Europe/Berlin'], ['US', 'USA', '9:32', 'en-US · America/New_York'], ['JP', 'Japan', '22:32', 'ja-JP · Asia/Tokyo']],
  // S08 · 11.5–13.5: the labels over the halves
  vs: ['Lumen profile', 'Safari'],
  // S09 · 13.5–14.5
  safari: ['Sites see', 'an ordinary Safari.'],
  // S10 · 14.5–16.0: the scores and the line under the table (as on the page "How we verify")
  rows: [['31', '31', 'Request headers'], ['15', '15', 'TLS and HTTP/2'], ['10', '10', 'Window geometry']],
  probe: ['448', 'signals checked against real Safari on every build'],
  // S14 · 19.0–20.5: on black
  proxy: ['The proxy is down.', 'No connection.'],
  proxyProof: '0 packets around the proxy',
  // S16 · 22.0–23.0
  encryption: ['Not even we', 'can read it.'],
  cipher: 'AES-256-GCM · Argon2id',
  // S17 · 23.0–24.5: the warm-up's hidden window (its lines as in the app)
  warmup: 'The profile warms up while you work.',
  hidden: 'Hidden window',
  page: 'Page {n} of {total}',
  unit: 'cookies collected',
  // S18 · 24.5–26.5: four tiles (the home page's words)
  tiles: [
    ['Passwords', 'AutoFill, just like Safari: save, update, fill.'],
    ['Cookie import', 'Bring a sign-in over from another browser: JSON or cookies.txt.'],
    ['Sync', 'Your profiles on all your Macs. Only ciphertext goes to the server.'],
    ['Ephemeral profiles', 'Close it, and nothing is left.'],
  ],
  // S20 · 27.5–29.5: the end card — the mark, what it is, the call (plain text, not a button)
  platform: 'The multi-account browser for Mac',
  cta: 'Try it free',
};
