// The account — four sections: overview, Macs and sync, payments, settings. On a phone, a tab bar at the bottom, as
// in an app; on a computer, a column on the left. The user's values (email, dates, device codes, sync size,
// payments) are sample data. The account shows only what the server really knows (the owner's decision, question
// 6): the server doesn't know your Macs' names or your profiles' names or number — and the page shows it as proof
// of the main promise. Crypto only, which can't be charged automatically: "paid until" and "Renew".
export default {
  title: 'Account',
  description: 'Your {{name}} account: plan and paid period, Macs and sync, payments and account settings.',
  who: { email: 'you@example.com', initial: 'Y', plan: 'Professional plan' },
  nav: [
    ['account.html', 'house', 'Overview'],
    ['account-devices.html', 'laptop', 'Macs'],
    ['account-invoices.html', 'doc', 'Payments'],
    ['account-settings.html', 'gearshape', 'Settings'],
  ],
  logout: 'Sign out',
  overview: {
    title: 'Overview',
    plan: 'Professional',
    status: 'Paid',
    meta: '$59 per month · up to 50 profiles · 3 Macs',
    untilLabel: 'Paid until',
    until: '29 November 2026',
    left: '29 days left',
    renew: 'Renew',
    change: 'Change plan',
    hint: 'We remind you by email in advance. If you don’t renew, profiles open for export only — your data is never deleted.',
    year: { t: 'A year at once', d: 'One payment instead of twelve, at the price of ten months.', action: 'Renew for a year — $590' },
    rows: [
      ['account-devices.html', 'laptop', 'Macs', '2 of 3'],
      ['account-devices.html#sync', 'syncArrows', 'Sync', '12 minutes ago'],
      ['account-invoices.html', 'doc', 'Last payment', '$59 · 29 October'],
      ['account-settings.html', 'person', 'Sign-in', 'you@example.com'],
    ],
  },
  devices: {
    title: 'Macs and sync',
    macs: 'Macs in the account',
    count: '2 of 3',
    list: [
      { code: 'A7F3', current: true, seen: 'Online now', ip: '203.0.113.24' },
      { code: '3KQ9', seen: 'Synced 3 days ago', ip: '198.51.100.7' },
    ],
    mac: 'Mac',
    thisMac: 'This Mac',
    revoke: 'Revoke',
    note: 'We don’t know your Macs’ names. Match the code: the app shows it in its sync settings.',
    sync: {
      title: 'Sync',
      stats: [['Objects', '38'], ['Size', '4.2 MB'], ['Changed', '12 minutes ago']],
      serverTitle: 'Your data, as the server sees it',
      serverLead: 'Ciphertext only: opaque names and sizes. Only you can read it — on your Mac, with your master password.',
      rows: [['vault-header', '0.6 KB'], ['3f9a07c1…b84e21c9', '1.1 MB'], ['a41d9e30…07f5c2aa', '612 KB'], ['c0e8b512…9d1a47f0', '48 KB'], ['7b26fd04…e3c90b18', '4.1 KB']],
      more: '33 more objects',
      names: 'There are no profile names here: the server doesn’t know them. They exist only in the app on your Macs.',
      headerNote: '`vault-header` is the vault’s header: the salt, the Argon2id parameters and the encrypted key — no secrets.',
      danger: { action: 'Delete sync data…', text: 'The server deletes every encrypted object. The data on your Macs stays.' },
    },
  },
  invoices: {
    title: 'Payments',
    rows: [
      ['29 October 2026', 'LMN-0003', '$59', 'USDT', 'Received'],
      ['29 September 2026', 'LMN-0002', '$59', 'BTC', 'Received'],
      ['29 August 2026', 'LMN-0001', '$19', 'USDT', 'Received'],
    ],
    pdf: 'PDF receipt',
    note: 'A receipt shows the amount in dollars, the coin, how much of it, and the transaction. Refunds go by it: the same coin, the same amount.',
  },
  settings: {
    title: 'Settings',
    signin: {
      title: 'Sign-in',
      rows: [['Email', 'you@example.com'], ['Method', 'One-time code by email']],
      change: 'Change',
      toKey: 'Switch to a licence key',
      toKeyText: 'We delete your email and give you a licence key. Without the key, access can’t be recovered, and there are no email reminders.',
    },
    email: {
      title: 'Emails',
      items: [['Receipts, and a reminder before a period ends', true, true], ['New releases — at most once a month', false, false]],
      lang: 'Email language',
    },
    sessions: {
      title: 'Sessions',
      current: 'This browser — now',
      all: 'Sign out everywhere',
    },
    danger: {
      title: 'Delete account',
      text: 'We delete the account and the encrypted sync data from the server. The profiles on your Macs stay.',
      action: 'Delete account…',
    },
  },
};
