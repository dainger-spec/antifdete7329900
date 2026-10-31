// Home scene "mission": one Safari window becomes many. The windows spread out as in Mission Control: each
// profile has its own window and its own site (the sites are samples in the language of the profile's
// country; they live in the scene's template and are not translated). Profile names and countries are
// samples; under the windows (on a phone, in each window's bar) they show as text. The headline picks up the
// last words of the statement before it ("every account at once").
export default {
  title: 'Profiles',
  head: ['Every profile at once.', 'Each in its own window.'],
  lead: 'No signing out of one account to get into another: the windows sit side by side and can’t see each other.',
  label: 'Safari windows open side by side, each with a profile and a site of its own: “Store” from Germany, “Ads” from the United States, “Support” from the United Kingdom, “QA” from Japan, “Sales” from the Netherlands and “Blog” from France.',
  profiles: [
    { name: 'Store', code: 'DE', country: 'Germany' },
    { name: 'Ads', code: 'US', country: 'United States' },
    { name: 'Support', code: 'GB', country: 'United Kingdom' },
    { name: 'QA', code: 'JP', country: 'Japan' },
    { name: 'Sales', code: 'NL', country: 'Netherlands' },
    { name: 'Blog', code: 'FR', country: 'France' },
  ],
};
