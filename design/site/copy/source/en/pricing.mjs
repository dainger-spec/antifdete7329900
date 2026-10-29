// Pricing. Tiers, limits, amounts, the trial and the refund window are the owner's decisions
// (questions 2, 3, 8, 10): this is option A from the README, highlighted as undecided.
export default {
  title: 'Pricing',
  description: '{{name}} pricing: every protection in every plan; plans differ by the number of profiles and devices. Free trial, card or crypto, refunds.',
  hero: {
    eyebrow: 'Pricing',
    title: 'Every protection, in every plan',
    lead: 'Plans differ by how many profiles and Macs you get. Real Safari, encryption, a proxy with no way around it, warm-up and sync are in all of them.',
  },
  billing: { monthly: 'Monthly', yearly: 'Yearly', yearlyNote: '{{tbd:q2:two months free}}' },
  per: { month: 'per month', year: 'per year' },
  plans: [
    { name: 'Personal', for: 'For yourself: work, personal and a few projects.', month: '{{tbd:q2:$19}}', year: '{{tbd:q2:$190}}', limits: [['Profiles', '{{tbd:q2:10}}'], ['Macs', '{{tbd:q2:2}}'], ['Seats', '{{tbd:q2:1}}']], cta: 'Try it' },
    { name: 'Professional', for: 'For people who run dozens of accounts.', month: '{{tbd:q2:$49}}', year: '{{tbd:q2:$490}}', limits: [['Profiles', '{{tbd:q2:50}}'], ['Macs', '{{tbd:q2:3}}'], ['Seats', '{{tbd:q2:1}}']], cta: 'Try it', featured: 'Recommended' },
    { name: 'Team', for: 'For agencies: one bill, seats for your people.', month: '{{tbd:q2:$129}}', year: '{{tbd:q2:$1290}}', limits: [['Profiles', '{{tbd:q2:200}}'], ['Macs', '{{tbd:q2:10}}'], ['Seats', '{{tbd:q2:5}}']], cta: 'Try it' },
  ],
  included: {
    title: 'In every plan',
    items: [
      'Real Safari, and a process of its own for every profile',
      'Everything on disk encrypted: Argon2id and AES-256-GCM',
      'A proxy with no way around it; a proxy list checked through the proxy itself',
      'Warm-up: ready-made lists, lists put together for you, a queue and a schedule',
      'Cookie import, password AutoFill, history and bookmarks',
      'Sync between Macs, end-to-end encrypted',
      'Profile export to a file under a password of its own',
      'Updates and email support',
    ],
  },
  trial: {
    title: 'Free trial',
    text: '{{tbd:q3:7 days free, no card needed: every feature, up to 3 profiles}}. Nothing is charged when it ends.',
  },
  payment: {
    title: 'Paying',
    items: [
      { icon: 'creditcard', t: 'By card', d: 'Through {{tbd:q8:our payment provider}}. The provider handles your card number — it never reaches us.' },
      { icon: 'wallet', t: 'In crypto', d: '{{tbd:q8:USDT, BTC or ETH}}. We show an address and an amount; the subscription starts once the network confirms the payment.' },
      { icon: 'key', t: 'Without an email', d: 'Paying in crypto, you can leave the email out: you get a licence key, and the key is your account.' },
    ],
  },
  refunds: {
    title: 'Refunds',
    text: 'Money back within {{tbd:q10:14 days}} of your first payment, no questions asked. Crypto is returned in the same coin to the address it came from.',
    link: 'Refund policy',
  },
  faqTitle: 'Questions',
  faq: [
    { q: 'What happens to my profiles if my subscription ends?', a: 'They stay on your Mac, encrypted as before. {{tbd:q2:Without a subscription the app opens them for export, but does not launch them.}}' },
    { q: 'Can I move profiles to another Mac?', a: 'Yes: with sync between the Macs of your account, or by exporting a profile to a file under a password of its own. An import makes a new profile.' },
    { q: 'Why sign in with a key and no email?', a: 'So that we do not even have your email. The key is the only way in: lose it and access cannot be recovered. Keep it as carefully as your master password.' },
    { q: 'Does the server see my profiles?', a: 'No. It keeps encrypted blocks and knows only their size and when they changed. The key is derived from your master password and never leaves your Mac.' },
    { q: 'Can I change plans?', a: 'Yes, in your account, at any time. {{tbd:q2:Moving up, the difference is prorated for the days left.}}' },
  ],
  cta: {
    title: 'Start with the free trial',
    lead: 'Download {{name}} and check everything described here on your own Mac.',
    primary: 'Download for Mac',
    secondary: 'How we verify',
  },
};
