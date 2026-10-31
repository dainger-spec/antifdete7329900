// The promo film, 30 seconds (tools/film, design/site/video). The titles shot by shot: the first line white,
// the second grey — as the home page's headlines, only larger. Everything else in frame is the home page's
// scenes, rearranged for the film, and the film's own shots (the name at the start, the comparison with
// Safari, the end card). Numbers from copy/facts.mjs. No "antidetect", as on the site (question 5): the film
// may end up where the site is, and acquirers read the wording.
export default {
  hero: ['Every account', 'gets its own Safari.'],
  mission: ['Every account.', 'At once.'],
  // The countries are the app's samples, as in the scene "Every profile, its own country" (the same moment:
  // 29 October 2026, 13:32 UTC).
  sites: 'Its own IP, language and time zone',
  countries: [['DE', 'Germany', '14:32', 'de-DE · Europe/Berlin'], ['US', 'USA', '9:32', 'en-US · America/New_York'], ['JP', 'Japan', '22:32', 'ja-JP · Asia/Tokyo']],
  // The comparison with Safari: the rows and scores of the page "How we verify".
  safari: ['Sites see', 'an ordinary Safari.'],
  vs: ['Safari', 'Lumen profile'],
  rows: [['Request headers', '31', '31'], ['TLS and HTTP/2', '15', '15'], ['Window geometry', '10', '10']],
  probe: ['signals compared with real Safari', 'on every build'],
  layers: ['Isolated', 'at every level.'],
  layerWords: ['Window', 'Process', 'Data', 'Network', 'Key'],
  proxy: ['The proxy is down.', 'No connection.'],
  proxyProof: '0 packets around the proxy',
  encryption: ['Not even we', 'can read it.'],
  cipher: ['AES-256-GCM', 'Argon2id'],
  warmup: ['Warm-up runs', 'while you work.'],
  features: ['And everything', 'you expect from Safari.'],
  // The end card: the mark, the name, what it is, the button.
  cta: 'Try it free',
  platform: 'The multi-account browser for Mac',
};
