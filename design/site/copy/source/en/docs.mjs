// Docs: nine articles from the browser's code and the measurements in the repository (the product branch at 194828b).
// Where behaviour isn't confirmed by the code or a measurement, the article says so with a {{unv:…}} mark — not a
// guess. Here: the index (sections and the order of articles, which Previous and Next follow); the articles' texts
// are copy/source/en/docs-<article>.mjs.
export default {
  title: 'Docs',
  description: '{{name}} documentation: installing and the first launch, the vault and the master password, updates, profiles, mobile profiles, proxies, cookies, several profiles at once, and what to do when something fails.',
  index: {
    eyebrow: 'Docs',
    title: 'Using {{name}}',
    lead: 'From installing to working with several profiles. Every article describes what the app has — in the words on its own buttons. Where behaviour isn’t confirmed by the code or a measurement, the article says so.',
    search: 'Search the docs',
    popularTitle: 'Read most often',
    popular: [['docs-install', 'Installing and the first launch'], ['docs-proxy', 'Proxies: setup, and when one fails'], ['docs-cookies', 'Importing and exporting cookies'], ['docs-trouble', 'When something fails']],
  },
  sections: [
    { icon: 'download', title: 'Getting started', items: [['docs-install', 'Installing and the first launch'], ['docs-vault', 'The vault and the master password'], ['docs-updates', 'Updates']] },
    { icon: 'person2', title: 'Profiles', items: [['docs-profile', 'Creating a profile'], ['docs-multiple', 'Several profiles at once'], ['docs-mobile', 'Mobile profiles']] },
    { icon: 'network', title: 'Proxies', items: [['docs-proxy', 'Proxies: setup, and when one fails']] },
    { icon: 'cookie', title: 'Profile data', items: [['docs-cookies', 'Importing and exporting cookies']] },
    { icon: 'lifebuoy', title: 'When something is wrong', items: [['docs-trouble', 'When something fails']] },
  ],
  nav: {
    search: 'Search',
    toggle: 'Doc sections',
  },
  article: {
    home: 'Docs',
    source: 'From the code as of 31 October 2026',
    read: 'Reading time',
    unv: 'Marked “Unconfirmed”: behaviour neither the code nor a measurement confirms',
    feedback: 'Found a mistake, or is something missing? [Write to us](support.html).',
    prevLabel: 'Previous',
    nextLabel: 'Next',
  },
};
