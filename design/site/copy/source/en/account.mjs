// The account. The user's values (email, dates, device codes, sync size, payments) are sample data for the mock-up.
// The account shows only what the server really knows (the owner's decision, question 6): the server doesn't know
// your Macs' names or your profiles' names or number — and the page shows it as proof of the main promise, not as a
// limitation. Payment is crypto only, which can't be charged automatically: "paid until" instead of "next charge",
// "renew" instead of "cancel subscription".
export default {
  title: 'Account',
  description: 'Your {{name}} account: plan and paid period, devices, sync, payments and account settings.',
  who: { email: 'you@example.com', plan: 'Professional plan' },
  nav: [
    ['account.html', 'wallet', 'Plan and payment'],
    ['account-devices.html', 'laptop', 'Devices'],
    ['account-sync.html', 'syncArrows', 'Sync'],
    ['account-invoices.html', 'doc', 'Payments'],
    ['account-settings.html', 'gearshape', 'Settings'],
  ],
  logout: 'Sign out',
  subscription: {
    title: 'Plan and payment',
    lead: 'Your plan, the period you’ve paid for, and renewing.',
    plan: {
      title: 'Plan',
      name: 'Professional',
      status: 'Paid',
      rows: [['Price', '$59 per month'], ['Paid until', '29 November 2026'], ['Macs in the account', '2 of 3'], ['Profiles', 'up to 50 — counted by the app on your Mac']],
      renew: 'Renew',
      change: 'Change plan',
      foot: 'The server doesn’t know how many profiles you have or what they’re called — so neither does this page. The app on your Mac checks the plan’s limit.',
    },
    renewal: {
      title: 'Renewing',
      lead: 'Crypto can’t be charged automatically: your period simply ends. You renew yourself, when it suits you.',
      points: [
        ['envelope', 'We remind you by email in advance that your period is ending.'],
        ['box', 'If you don’t renew, the app opens your profiles for data export only. Your data is never deleted.'],
        ['calendar', 'A year at once: one payment instead of twelve, at the price of ten months.'],
      ],
      month: 'One month — $59',
      year: 'One year — $590',
    },
  },
  devices: {
    title: 'Devices',
    lead: 'The Macs signed in to your account. Revoke one you no longer use: it signs out and stops syncing.',
    count: 'Macs in the account: 2 of 3',
    list: [
      { code: 'A7F3', current: true, added: 'Added 12 October 2026', seen: 'Online now', ip: '203.0.113.24' },
      { code: '3KQ9', added: 'Added 2 October 2026', seen: 'Last synced 3 days ago', ip: '198.51.100.7' },
    ],
    mac: 'Mac',
    codeLabel: 'code',
    thisMac: 'This Mac',
    revoke: 'Revoke…',
    note: 'We do not know your Macs’ names. To tell them apart, match the code: the app shows it in its sync settings.',
    ipLabel: 'IP',
  },
  sync: {
    title: 'Sync',
    lead: '{{name}}’s main promise, right in your account: the server holds only ciphertext. Only you can read it — on your Mac, with your master password.',
    stats: [['Objects', '38'], ['Size', '4.2 MB'], ['Last change', '12 minutes ago']],
    objectsTitle: 'Your data, as the server sees it',
    objectsLead: 'Opaque names, sizes and times. What is inside only your Macs know.',
    head: ['Object', 'Size', 'Revision', 'Changed'],
    rows: [
      ['vault-header', '0.6 KB', '1', '12 October 2026'],
      ['3f9a07c1…b84e21c9', '1.1 MB', '57', '12 minutes ago'],
      ['a41d9e30…07f5c2aa', '612 KB', '23', '12 minutes ago'],
      ['c0e8b512…9d1a47f0', '48 KB', '9', 'yesterday'],
      ['7b26fd04…e3c90b18', '4.1 KB', '4', '3 days ago'],
    ],
    more: '33 more objects',
    headerNote: '`vault-header` is the vault’s header: the salt, the Argon2id parameters and the encrypted key. It holds no secret: a new Mac needs it to open the vault with your password.',
    names: 'There are no profile names here: the server doesn’t know them. They exist only in the app on your Macs.',
    danger: {
      title: 'Delete sync data',
      text: 'The server deletes every encrypted object. The data on your Macs stays; sync starts over from the next Mac that runs it.',
      action: 'Delete from the server…',
    },
  },
  invoices: {
    title: 'Payments',
    lead: 'Every payment on the account. The PDF receipt is for your records.',
    head: ['Date', 'Number', 'Amount', 'Paid in', 'Status', ''],
    rows: [
      ['29 October 2026', 'LMN-0003', '$59', 'USDT', 'Received'],
      ['29 September 2026', 'LMN-0002', '$59', 'BTC', 'Received'],
      ['29 August 2026', 'LMN-0001', '$19', 'USDT', 'Received'],
    ],
    pdf: 'PDF',
    note: 'A receipt shows the amount in dollars, the coin and how much of it, and the network transaction. Refunds go by it: the same coin, the same amount.',
  },
  settings: {
    title: 'Account settings',
    lead: 'Signing in, emails, and deleting the account.',
    signin: {
      title: 'Signing in',
      rows: [['Email', 'you@example.com'], ['Method', 'One-time code by email']],
      change: 'Change',
      toKey: 'Switch to a licence key',
      toKeyText: 'We delete your email and give you a licence key. Without the key, access cannot be recovered, and there will be no email reminders when a period ends.',
    },
    email: {
      title: 'Emails',
      items: [['Receipts, and a reminder before your paid period ends', true, true], ['New releases — at most once a month', false, false]],
      lang: 'Email language',
    },
    sessions: {
      title: 'Sessions',
      current: 'This browser — now',
      all: 'Sign out everywhere',
    },
    danger: {
      title: 'Delete account',
      text: 'We delete the account and all encrypted sync data from the server. The profiles on your Macs stay — encrypted, as they were.',
      action: 'Delete account…',
    },
  },
};
