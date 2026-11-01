// Pricing — as the owner decided and the account server has it (docs/SITE_API.md §3): three plans by profiles and
// devices ("devices", not "Macs": an iOS version will come), US dollars only, a year costs ten months; a Team has 5
// seats, including the owner; a 7-day trial with up to 3 profiles; crypto only — it can't be charged automatically, so a
// period simply ends: reminders by email 7 days and 1 day before, and the person renews. Running profiles at once is
// not limited on any plan and is no parameter on the site. Without a paid period the app opens profiles for export
// only; data is never deleted. The space for sync is 20 MiB per profile in the plan, never less than 100 MiB (the owner's
// decision, question 16): 200 MB, 1 GB, 4 GB — a row of its own in every plan, like the other limits: no hidden limits.
export default {
  title: 'Pricing',
  description: '{{name}} pricing: every protection in every plan; plans differ by the number of profiles and devices and the space for sync. 7 days free, crypto payments, refunds.',
  hero: {
    eyebrow: 'Pricing',
    title: 'Simple plans, every feature in each',
    lead: 'Plans differ only by their limits: profiles, devices and space for sync. Start with 7 free days.',
  },
  billing: { monthly: 'Monthly', yearly: 'Yearly', yearlyNote: 'the price of 10 months' },
  per: { month: 'per month', year: 'per year' },
  assurances: ['7 days free, up to 3 profiles', 'Money back within 14 days', 'Your data is never deleted'],
  plans: [
    { name: 'Personal', for: 'For yourself: work, personal and a few projects.', month: '$19', year: '$190', limits: [['Profiles', '10'], ['Devices', '2'], ['Sync', '200 MB'], ['Seats', '1']], cta: 'Try it' },
    { name: 'Professional', for: 'For people who run dozens of accounts.', month: '$59', year: '$590', limits: [['Profiles', '50'], ['Devices', '3'], ['Sync', '1 GB'], ['Seats', '1']], cta: 'Try it', featured: 'Recommended' },
    { name: 'Team', for: 'For agencies: seats for the team, shared limits.', month: '$149', year: '$1490', limits: [['Profiles', '200'], ['Devices', '10'], ['Sync', '4 GB'], ['Seats', '5, including the owner']], cta: 'Try it' },
  ],
  included: {
    title: 'In every plan',
    items: [
      'Real Safari and a separate process for every profile',
      'Everything on disk encrypted: Argon2id and AES-256-GCM',
      'Proxies with no way around them, and a proxy list checked through the proxy itself',
      'Warm-up: ready lists, smart picks, a queue and a schedule',
      'Cookie import, passwords with AutoFill, history and bookmarks',
      'Sync between Macs, end-to-end encrypted',
      'Profile export to a file under its own password',
      'Updates and email support',
    ],
  },
  payment: {
    title: 'Payment',
    items: [
      { icon: 'wallet', t: 'In crypto', d: '{{tbd:q13:USDT on Tron, BTC or ETH}}, on Lumen Pay, our own payment page: the address, a QR code, the amount and a timer. Your period starts when the network confirms the payment.' },
      { icon: 'calendar', t: 'A year at once', d: 'One payment instead of twelve, at the price of ten months.' },
    ],
  },
  period: {
    title: 'When a period ends',
    text: 'Crypto can’t be charged automatically, so you renew yourself, when it suits you. We remind you by email 7 days and 1 day before. If you don’t renew, the app opens your profiles for data export only. **Your data is never deleted**: renew, and everything works as before.',
  },
  refunds: {
    title: 'Refunds',
    text: 'We refund within 14 days of your first payment, no questions asked, and within 7 days of a renewal if you haven’t worked in the new period. We return the same coin and the same amount we received, whatever the exchange rate has done.',
    link: 'Refund policy',
  },
  faqTitle: 'Questions',
  faq: [
    { q: 'How do I renew?', a: 'In your account: choose a month or a year and pay in crypto on our payment page. You can renew early — the new period starts when the current one ends. We remind you by email 7 days and 1 day before your period ends.' },
    { q: 'How many people are in a Team?', a: 'Five seats, including the owner. Each person signs in with their own email and password; the profile and device limits and the space for sync are shared by the team. The owner pays; members don’t see the team’s invoices.' },
    { q: 'How much space is there for sync?', a: '20 MB for each profile in your plan, and never less than 100 MB: 200 MB on Personal, 1 GB on Professional, 4 GB for the whole Team, 100 MB during the trial. Sync carries settings, passwords, bookmarks, history and persistent cookies — no cache and no other website data. If the space runs out, changes that need more space stop syncing, and everything already saved stays available. Your account shows how much is used.' },
    { q: 'Can I move profiles to another Mac?', a: 'Yes: by syncing between the Macs in your account, or by exporting a profile to a file under its own password. Importing creates a new profile.' },
    { q: 'Can the server see my profiles?', a: 'Only their number. Each Mac tells the server how many profiles it has, so that your plan’s profile limit is shared by all your Macs. Their names, tags, notes, cookies, site passwords, history and proxy addresses never reach it. Sync sends profile data only encrypted: the key comes from your master password and never leaves your Mac.' },
    { q: 'Can I change plans?', a: 'Yes, in your account. {{tbd:q14:Moving up, you pay the difference for the days left; moving down takes effect from the next period.}}' },
  ],
  cta: {
    title: 'Start with 7 free days',
    lead: 'Download {{name}} and check everything described here on your own Mac.',
    primary: 'Download for Mac',
    secondary: 'How we verify',
  },
};
