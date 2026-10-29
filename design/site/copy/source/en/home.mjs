// Home — short, only what matters: the first screen, five animated tiles (what we are good at), three
// verification numbers, a call to try it. The detail is on Features. Numbers from copy/facts.mjs; the tiles'
// values (4 of 12, 84 cookies) are the app's samples (UISnapshots.swift). Periods and prices are the owner's.
export default {
  title: null,
  description: '{{name}} is a multi-account browser for Mac. Every account gets its own Safari: its own cookies, IP, language and time zone. A proxy that never leaks, warm-up and encryption.',
  hero: {
    eyebrow: 'A multi-account browser for Mac',
    title: 'Every account gets its own Safari',
    lead: 'Its own cookies, IP, language and time zone for every profile. No signing in and out, and no leaks.',
    primary: 'Try it free',
    secondary: 'Features',
    meta: ['{{tbd:q3:7 days free}}', 'No card needed', 'macOS 14 or later'],
  },
  globe: {
    label: 'A planet cut by a seam: profiles go online from different countries and never mix',
    pins: [
      { name: 'Store', code: 'DE', lat: 52.52, lon: 13.40 },
      { name: 'Ads', code: 'US', lat: 40.71, lon: -74.0 },
      { name: 'Client', code: 'SE', lat: 59.33, lon: 18.07, side: 'l' },
      { name: 'QA', code: 'JP', lat: 35.68, lon: 139.69 },
      { name: 'Sales', code: 'BR', lat: -23.55, lon: -46.63 },
    ],
  },
  bentoTitle: 'Why {{name}}',
  tiles: {
    safari: {
      title: 'It is real Safari',
      text: 'The engine, the network handshake and the headers are those of Safari on your Mac.',
      rows: ['WebKit engine', 'TLS handshake', 'HTTP/2', 'Header order', 'Canvas and WebGL', 'Fonts'],
      ok: 'as in Safari',
      foot: '448 signals compared with Safari on every build',
    },
    proxy: {
      title: 'A proxy that never leaks',
      text: 'Proxy down, and the profile does not go online directly. Your IP stays hidden.',
      profile: 'Ads',
      proxy: 'Proxy',
      site: 'Site',
      down: 'down',
      direct: 'Direct',
      closed: 'closed',
      hidden: 'IP hidden',
    },
    isolation: {
      title: 'Accounts never mix',
      text: 'Its own cookies, passwords and history for every profile. And its own process.',
      left: { name: 'Store', code: 'DE' },
      right: { name: 'Ads', code: 'US' },
      tags: ['cookies', 'passwords', 'history'],
    },
    warmup: {
      title: 'Warm-up runs itself',
      text: 'A profile browses its country’s sites in a hidden window and collects cookies.',
      unit: 'cookies',
      page: 'Page 4 of 12',
    },
    encryption: {
      title: 'Not even we can read it',
      text: 'Everything on disk is encrypted with a key from your master password.',
      items: ['Passwords', 'Cookies', 'History', 'Bookmarks'],
      tag: 'AES-256-GCM',
    },
  },
  proof: {
    stats: [
      { n: '448', t: 'signals compared with Safari' },
      { n: '31', of: '31', t: 'headers as in Safari' },
      { n: '0', t: 'packets around the proxy' },
    ],
    link: 'How we verify',
  },
  cta: {
    title: 'Try {{name}} free',
    lead: '{{tbd:q3:7 days}}, every feature, no card needed.',
    primary: 'Download for Mac',
    secondary: 'Pricing',
  },
};
