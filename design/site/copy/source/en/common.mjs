// Strings every page shares: header, footer, screen-reader labels.
// {{name}} is the product's name (working name: Lumen), {{domain}} its domain (lumen.example for now).
// {{tbd:qN:…}} marks a value the owner decides (question N in the README).
export default {
  meta: {
    tagline: 'a macOS browser where every profile is real Safari',
    description: '{{name}} is a macOS browser with separate profiles. Every profile is real Safari in its own process, with its own cookies, language, time zone and proxy. What it stores on disk is encrypted with your master password.',
  },
  nav: [
    ['features', 'Features'],
    ['how-it-works', 'How it works'],
    ['verification', 'Verification'],
    ['pricing', 'Pricing'],
    ['docs', 'Docs'],
  ],
  header: {
    login: 'Sign in',
    download: 'Try it free',
    downloadShort: 'Try it',
    downloadLong: 'Download for Mac',
  },
  footer: {
    about: 'A macOS browser where every profile is real Safari in a process of its own, with its data encrypted on disk.',
    columns: [
      ['Product', [['features.html', 'Features'], ['how-it-works.html', 'How it works'], ['verification.html', 'How we verify'], ['pricing.html', 'Pricing'], ['download.html', 'Download'], ['blog.html', 'Updates']]],
      ['Help', [['docs.html', 'Docs'], ['support.html', 'Support'], ['support.html#contacts', 'Contact'], ['account.html', 'Account']]],
      ['Legal', [['privacy.html', 'Privacy'], ['terms.html', 'Terms of use'], ['refunds.html', 'Refunds']]],
    ],
    copyright: '© 2026 {{tbd:q9:Company name}}',
    noTracking: 'No analytics and no third-party scripts on this site.',
  },
  a11y: {
    skip: 'Skip to content',
    home: 'home',
    mainNav: 'Main navigation',
    language: 'Site language',
    menu: 'Menu',
  },
  ui: {
    readMore: 'Read more',
    copy: 'Copy',
    copied: 'Copied',
    replay: 'Replay',
    onThisPage: 'On this page',
    sample: 'Example',
  },
};
