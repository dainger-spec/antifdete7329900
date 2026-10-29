// Home — a presentation, in Apple's manner: it scrolls in scenes, each with a device of its own — a MacBook
// that opens, a statement word by word, a page that "renders" from its outline and moves onto a MacBook's
// screen, an exploded view of a profile, a beam through the proxy, "strength in numbers", a bento grid.
// The detail and the tables are on Features, How it works and How we verify. Numbers from copy/facts.mjs;
// periods and prices are the owner's.
export default {
  title: null,
  description: '{{name}} is a multi-account browser for Mac. Every account gets its own Safari: its own cookies, IP, language and time zone. A proxy that never leaks, warm-up and encryption.',
  intro: {
    section: 'A multi-account browser',
    eyebrow: 'A multi-account browser for Mac',
    title: ['Every account gets', 'its own Safari.'],
    lead: 'Its own cookies, IP, language and time zone for every profile. No signing in and out, and no leaks.',
    primary: 'Try it free',
    secondary: 'Features',
    meta: ['{{tbd:q3:7 days free}}', 'No card needed', 'macOS 14 or later'],
    caption: ['One Mac, many Safaris.', 'And they never mix.'],
    scroll: 'Scroll',
  },
  art: {
    label: 'A MacBook whose display shows half of the Lumen mark drawn in code; the other half has come out of the screen towards us. Two halves, two profiles, each with its own language and time zone',
    chips: [
      { name: 'Store', code: 'DE', id: 'de-DE · Europe/Berlin' },
      { name: 'Ads', code: 'US', id: 'en-US · America/New_York' },
    ],
  },
  statementTitle: 'The idea',
  statement: '{{name}} opens every account in *a Safari of its own*. Its own cookies, passwords and history. Its own proxy, language and time zone. Sites see an ordinary Safari — and you see *every account at once*.',
  zoom: {
    title: 'The real thing',
    overlay: ['The page is drawn by the real WebKit.', 'Exactly as in Safari.'],
    head: ['One Mac, many Safaris.', 'Each from a country of its own.'],
    sees: 'The site sees',
    profiles: [
      { name: 'Store', code: 'DE', country: 'Germany', lang: 'de-DE', site: 'shop.example', c1: '#FF9A62', c2: '#E2466E' },
      { name: 'Ads', code: 'US', country: 'USA', lang: 'en-US', site: 'ads.example', c1: '#5E8DFF', c2: '#8C5CFF' },
      { name: 'QA', code: 'JP', country: 'Japan', lang: 'ja-JP', site: 'app.example', c1: '#FF5D8F', c2: '#FFB5CB' },
    ],
  },
  layers: {
    title: 'Isolation',
    k: 'Isolation',
    head: ['A profile is apart', 'at every level.'],
    lead: 'Window, process, data, network and key — every profile has its own.',
    items: [
      { icon: 'compass', t: 'A Safari window', d: 'Its own tabs, history and bookmarks' },
      { icon: 'cpu', t: 'A process of its own', d: 'Its own WebKit, folder and temporary files' },
      { icon: 'cookie', t: 'Its own data', d: 'Cookies and passwords other profiles cannot see' },
      { icon: 'network', t: 'Its own network', d: 'Only through its proxy; direct is closed' },
      { icon: 'key', t: 'Its own key', d: 'Everything on disk under AES-256-GCM' },
    ],
  },
  beam: {
    title: 'Proxy',
    profile: 'Ads',
    proxy: 'Proxy',
    site: 'Site',
    down: 'down',
    head: ['The proxy is down.', 'No connection.'],
    sub: 'A profile with a proxy goes online only through it. Your IP stays hidden.',
  },
  nums: {
    title: 'Verification',
    head: 'Strength in numbers.',
    items: [
      { n: '448', t: 'signals compared with real Safari on every build' },
      { n: '31', of: '31', t: 'headers, the same set and order as Safari’s' },
      { n: '15', of: '15', t: 'TLS and HTTP/2 values match' },
      { n: '0', t: 'packets around the proxy' },
      { n: '26', t: 'countries with ready-made warm-up site lists' },
      { code: 'AES-256-GCM', t: 'encryption of everything a profile keeps on disk' },
    ],
    link: 'How we verify',
  },
  bento: {
    title: 'Features',
    head: ['And everything you expect', 'from Safari.'],
    passwords: { t: 'Passwords', d: 'AutoFill as in Safari: save, update, fill.', site: 'shop.example', save: 'Save password' },
    history: { t: 'History and bookmarks', d: 'Every profile has its own.', rows: ['Orders', 'Seller dashboard', 'Support'] },
    cookies: { t: 'Cookie import', d: 'JSON and cookies.txt from extensions, Puppeteer, Playwright and Selenium.', file: 'cookies.txt' },
    sync: { t: 'Sync', d: 'Your profiles on all your Macs. Only ciphertext goes to the server.' },
    export: { t: 'Profile export', d: 'A whole profile in one file under a password.' },
    ephemeral: { t: 'Ephemeral profiles', d: 'Close it, and nothing is left.' },
    link: 'All features',
  },
  cta: {
    title: 'Try {{name}} free',
    lead: '{{tbd:q3:7 days}}, every feature, no card needed.',
    primary: 'Download for Mac',
    secondary: 'Pricing',
  },
};
