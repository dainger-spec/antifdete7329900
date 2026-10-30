// Home scene "mission": one Safari window becomes many. A deck of windows spreads out as in Mission Control:
// each profile has its own window and its own site (the sites are samples in the language of the profile's
// country; they live in the scene's template and are not translated). Profile names and countries are
// samples; under the windows (on a phone, in each window's bar) they show as text.
export default {
  title: 'Profiles',
  head: ['As many profiles as you need.', 'Each in a window of its own.'],
  lead: 'Open them side by side: each has its own Safari window, its own tabs and its own sign-ins.',
  label: 'Safari windows side by side, each with a profile and a site of its own: “Store” from Germany, “Ads” from the United States, “Support” from the United Kingdom, “QA” from Japan, “Sales” from the Netherlands and “Blog” from France.',
  profiles: [
    { name: 'Store', code: 'DE', country: 'Germany' },
    { name: 'Ads', code: 'US', country: 'United States' },
    { name: 'Support', code: 'GB', country: 'United Kingdom' },
    { name: 'QA', code: 'JP', country: 'Japan' },
    { name: 'Sales', code: 'NL', country: 'Netherlands' },
    { name: 'Blog', code: 'FR', country: 'France' },
  ],
};
