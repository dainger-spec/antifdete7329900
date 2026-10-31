// Pricing — as the owner decided (questions 2, 3, 8, 10): three plans by profiles, US dollars only, a year costs ten
// months; a 7-day trial with up to 3 profiles; crypto only — it can't be charged automatically, so a period simply
// ends: we remind by email in advance and the person renews. Running profiles at once is unlimited on every plan
// and is never a plan parameter. Without a paid period the app opens profiles for export only; data is never deleted.
export default {
  title: 'Pricing',
  description: '{{name}} pricing: every protection in every plan; plans differ by the number of profiles and Macs. 7 days free, crypto payments, refunds.',
  hero: {
    eyebrow: 'Pricing',
    title: 'Simple plans, every feature in each',
    lead: 'Plans differ only by the number of profiles and Macs. Start with 7 free days.',
  },
  billing: { monthly: 'Monthly', yearly: 'Yearly', yearlyNote: 'the price of 10 months' },
  per: { month: 'per month', year: 'per year' },
  assurances: ['7 days free, up to 3 profiles', 'Run profiles at once, no limit', 'Money back within 14 days', 'Your data is never deleted'],
  plans: [
    { name: 'Personal', for: 'For yourself: work, personal and a few projects.', month: '$19', year: '$190', limits: [['Profiles', '10'], ['Macs', '2'], ['Seats', '1']], cta: 'Try it' },
    { name: 'Professional', for: 'For people who run dozens of accounts.', month: '$59', year: '$590', limits: [['Profiles', '50'], ['Macs', '3'], ['Seats', '1']], cta: 'Try it', featured: 'Recommended' },
    { name: 'Team', for: 'For agencies: one account and seats for the team.', month: '$149', year: '$1490', limits: [['Profiles', '200'], ['Macs', '10'], ['Seats', '5']], cta: 'Try it' },
  ],
  included: {
    title: 'In every plan',
    items: [
      'Real Safari and a separate process for every profile',
      'As many profiles at once as you like: a plan only limits how many you have',
      'Everything on disk encrypted: Argon2id and AES-256-GCM',
      'Proxies with no way around them, and a proxy list checked through the proxy itself',
      'Warm-up: ready lists, smart picks, a queue and a schedule',
      'Cookie import, passwords with AutoFill, history and bookmarks',
      'Sync between Macs, end-to-end encrypted',
      'Profile export to a file under its own password',
      'Updates and email support',
    ],
  },
  trial: {
    title: 'Free trial',
    text: '7 days free, up to 3 profiles, with every feature. If you like it, pick a plan and pay for a period.',
  },
  payment: {
    title: 'Payment',
    items: [
      { icon: 'wallet', t: 'In crypto', d: '{{tbd:q13:USDT, BTC or ETH}}, on our own payment page: the address, a QR code, the amount and a timer. Your period starts when the network confirms the payment.' },
      { icon: 'calendar', t: 'A year at once', d: 'One payment instead of twelve, at the price of ten months.' },
      { icon: 'key', t: 'No email', d: 'You can skip the email: you get a licence key, and it becomes your account.' },
    ],
  },
  period: {
    title: 'When a period ends',
    text: 'Crypto can’t be charged automatically, so you renew yourself, when it suits you. We remind you by email in advance. If you don’t renew, the app opens your profiles for data export only. **Your data is never deleted**: renew, and everything works as before.',
  },
  refunds: {
    title: 'Refunds',
    text: 'We refund within 14 days of your first payment, no questions asked, and within 7 days of a renewal if you haven’t worked in the new period. We return the same coin and the same amount we received, whatever the exchange rate has done.',
    link: 'Refund policy',
  },
  faqTitle: 'Questions',
  faq: [
    { q: 'What happens when my paid period ends?', a: 'Your profiles stay on your Mac, encrypted as they were. Until you renew, the app opens them for data export only. Your data is never deleted.' },
    { q: 'How do I renew?', a: 'In your account: choose a month or a year and pay in crypto on our payment page. We remind you by email in advance that your period is ending.' },
    { q: 'How many profiles can I run at once?', a: 'As many as you need. Running profiles at once is unlimited on every plan: a plan only sets how many profiles and Macs you have.' },
    { q: 'Can I move profiles to another Mac?', a: 'Yes: by syncing between the Macs in your account, or by exporting a profile to a file under its own password. Importing creates a new profile.' },
    { q: 'Why sign in with a key and no email?', a: 'So that we don’t even have your email. The key is the only way in: lose it and access can’t be restored. Keep it as carefully as your master password. There is no reminder email in that case — the end of your period is shown in your account.' },
    { q: 'Can the server see my profiles?', a: 'No. It stores encrypted blocks and knows only their size and when they changed. The key comes from your master password and never leaves your Mac.' },
    { q: 'Can I change plans?', a: 'Yes, in your account. {{tbd:q14:Moving up, you pay the difference for the days left; moving down takes effect from the next period.}}' },
  ],
  cta: {
    title: 'Start with 7 free days',
    lead: 'Download {{name}} and check everything described here on your own Mac.',
    primary: 'Download for Mac',
    secondary: 'How we verify',
  },
};
