// Support and contacts. Response times and company details are the owner's decisions (question 9). The
// app's logs are checked on every build (scripts/check_log_privacy.py): no user data in them in the clear.
export default {
  title: 'Support',
  description: '{{name}} support: answers in the docs, a contact form, and how to reach us.',
  hero: {
    eyebrow: 'Support',
    title: 'How can we help?',
    lead: 'Most answers are in the docs. If yours is not, write to us: we answer by email {{tbd:q9:within a business day}}.',
    search: 'Search the docs',
  },
  topics: {
    title: 'Common questions',
    items: [
      { icon: 'network', t: 'A profile does not start', d: 'Usually the proxy: a wrong address, or it wants a password. The profile does not open sites directly in that case.' },
      { icon: 'cookie', t: 'Importing cookies', d: 'Which files work, and what to do with the report of skipped entries.' },
      { icon: 'syncArrows', t: 'Sync between Macs', d: 'What syncs, how conflicts are resolved, how to revoke a Mac.' },
      { icon: 'key', t: 'Forgot the master password', d: 'It cannot be recovered. What you can do with the old vault.' },
    ],
  },
  form: {
    title: 'Write to us',
    topic: 'Topic',
    topics: ['A question about using it', 'Billing and subscription', 'A bug in the app', 'Security'],
    email: 'Email for our reply',
    emailHint: 'Signing in with a key? Give any address for the reply — we delete it with the conversation.',
    message: 'Message',
    messagePlaceholder: 'What you did, what you expected, and what happened',
    logs: 'Attach the app’s log',
    logsHint: 'The logs hold none of your data in the clear — every build checks that.',
    send: 'Send',
    never: 'Never send your master password, licence key or cookie export files. We will not ask for them.',
  },
  contacts: {
    title: 'Contact',
    items: [
      { icon: 'lifebuoy', t: 'Support', v: 'support@{{domain}}' },
      { icon: 'shieldCheck', t: 'Security', v: 'security@{{domain}}', d: 'Found a vulnerability? Write here — we reply, and tell you when the fix ships.' },
      { icon: 'creditcard', t: 'Billing and refunds', v: 'billing@{{domain}}' },
      { icon: 'lock', t: 'Privacy', v: 'privacy@{{domain}}' },
      { icon: 'doc', t: 'Legal', v: 'legal@{{domain}}' },
    ],
    company: 'Company',
    companyValue: '{{tbd:q9:name, country, address}}',
  },
};
