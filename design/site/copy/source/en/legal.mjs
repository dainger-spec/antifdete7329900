// Legal: privacy policy, terms of use, refund policy. As the owner decided: there is no legal entity and no
// company details — the party is called {{name}} throughout; crypto is the only way to pay, and the crypto
// processor is the only one that receives payment data; nothing renews by itself; data is never deleted; refunds
// within 14 days, and 7 days after a renewal, in the same coin and the same amount. Retention periods and service
// names are still the owner's call (question 12). Facts about data: docs/SYNC_FORMAT.md, docs/SYNC_SERVER_API.md,
// ProxyGeoLookup.swift, README.
export default {
  title: 'Legal',
  tabs: [['privacy.html', 'Privacy'], ['terms.html', 'Terms of use'], ['refunds.html', 'Refunds']],
  updatedLabel: 'In effect from',
  updated: '{{tbd:q12:the publication date}}',
  tocTitle: 'Sections',
  privacy: {
    title: 'Privacy policy',
    lead: 'What we know about you, why, and for how long. And what we do not know and cannot find out.',
    toc: [['short', 'In short'], ['who', 'What this covers'], ['server', 'What the server knows about you'], ['cannot', 'What we don’t know'], ['app', 'The app'], ['site', 'The website'], ['processors', 'Who we share data with'], ['rights', 'Your rights'], ['changes', 'Changes']],
    body: `## In short {#short}

- Your profiles, what’s in them and your master password stay on your Macs. The server can’t see them and can’t decrypt them.
- We know little about you: your email (if you sign in by email), the IP addresses of requests to the server, how many devices you have, the sizes and change times of encrypted sync blocks — and your payment data.
- **A forgotten master password cannot be recovered.** Not by us, not by anyone.
- The website has no analytics and no third-party scripts. The app sends us no analytics and no crash reports.

## What this covers {#who}

{{name}}: the Mac app, the {{domain}} website and the sync server. For questions about your data, write to privacy@{{domain}}.

## What the server knows about you {#server}

This is the complete list.

| Data | Why | How long we keep it |
|---|---|---|
| **Email** — only if you sign in by email | One-time sign-in codes, receipts, the reminder before a period ends | As long as the account exists |
| **IP addresses** of requests to the server | Abuse protection and diagnostics | {{tbd:q12:30 days}} in server logs |
| **The number of devices** in the account and when each last checked in | The plan’s Mac limit, revoking a device | As long as the account exists |
| **Sizes and change times** of encrypted sync blocks, and their revisions | Sync itself | Until you delete them or the account |
| **Payment data**: the plan, the period, the amount in dollars, the coin and how much of it, the payment address and the network transaction | Receipts, the paid period, refunds | {{tbd:q12:the retention period}} |
| **Support emails** | To answer you | {{tbd:q12:2 years}} |

## What we don’t know and can’t find out {#cannot}

- Everything in your profiles — settings, proxies, passwords, cookies, history, bookmarks — is encrypted on your Mac with a key from your master password **before** anything goes to the server. The server stores only ciphertext. It has no key.
- **We cannot decrypt your profile data** — not by choice, not on anyone’s demand.
- Object names on the server are HMACs of their real names. They don’t even reveal that an object is “a profile’s history”, or the exact number of profiles.
- We don’t store your master password and can’t reset it. **A forgotten master password cannot be recovered**: without it, profile data can’t be decrypted — by you or by us.
- If you sign in with a licence key, we don’t have your email either.

## The app on your Mac {#app}

- The app sends us no analytics, no crash reports and nothing about which sites you open.
- To learn a proxy’s country, time zone and external IP, the app asks the geolocation services ipinfo.io, get.geojs.io and ipwho.is — **through the proxy itself**, when a profile with a proxy starts or you check a proxy. They see the proxy’s address, not yours.
- The search at the start of a warm-up goes through DuckDuckGo, as from the address bar — through the profile’s proxy too.
- Sites you open in your profiles get what they would get from Safari. That is between you and those sites; their privacy policies apply to them.

## The website {#site}

- The website has no analytics, no ad pixels and no third-party scripts. Fonts and images come from our own server.
- The website has one cookie: your account session after you sign in. Until you sign in, there are no cookies.
- The payment page is ours: you don’t leave the site; the server gets the address to pay to from the crypto processor.

## Who we share data with {#processors}

- **The crypto processor** — {{tbd:q12:name}} — takes crypto payments: it gets the amount, the coin and the order number and gives back an address to pay to. It is the only one that receives payment data. Neither your email nor any profile data is passed to it.
- **The email service** — {{tbd:q12:name}} — to send sign-in codes, receipts and reminders.
- **Hosting** — {{tbd:q12:name and country}} — where the server runs.

We don’t sell data or pass it to ad networks. On a lawful demand we can hand over only what we have — the list above. Your profile data is encrypted on our side, and we can’t decrypt it.

## Your rights {#rights}

- **Find out** what data we have about you and get a copy — write to privacy@{{domain}}.
- **Delete** your account and all sync data — in your account, at once, no emails needed.
- **Correct** your email — in account settings.
- **Opt out** of release emails — there too.
- **Complain** to the data protection authority of your country.

## Changes {#changes}

We’ll email you about material changes {{tbd:q12:30 days}} before they take effect. Earlier versions of this policy stay on this page.`,
  },
  terms: {
    title: 'Terms of use',
    lead: 'The rules on which you use {{name}}. Short, and no small print.',
    toc: [['license', 'Licence'], ['account', 'Account'], ['payment', 'Payment and periods'], ['use', 'Acceptable use'], ['data', 'Your data'], ['warranty', 'Liability'], ['end', 'Ending'], ['contact', 'Questions']],
    body: `## Licence {#license}

While you have a trial or a paid period, you may install and use {{name}} on your Macs — within your plan’s number of profiles and Macs. How many profiles run at once is not limited on any plan.

{{name}} runs on Macs with Apple Silicon and macOS 26 or later. Intel Macs are not supported.

## Account {#account}

- You sign in by email with a one-time code, or with a licence key.
- The key is the only way into an account without an email. Lose it and we can’t restore access.
- Your profiles’ master password is not tied to the account and is unknown to us. A forgotten master password cannot be recovered.

## Payment and periods {#payment}

- You pay in crypto, for a month or for a whole year; a year costs ten months. Prices are in US dollars, on the [pricing page](pricing.html).
- Crypto can’t be charged automatically, so nothing renews by itself and there is nothing to cancel: a paid period simply ends. We remind you by email in advance if you sign in by email. You can renew in your account at any time.
- The trial is 7 days free, up to 3 profiles, with every feature.
- When a period has ended, the app opens your profiles for data export only, until you renew. **Your data is never deleted.**
- We tell you about a price change in advance; the new price applies to periods paid for after the change.
- Refunds follow the [refund policy](refunds.html).

## Acceptable use {#use}

{{name}} is made for privacy and for working with several accounts. You may not use it:

- for fraud, for impersonating someone else, or for anything that breaks the law;
- to spread malware, send spam or attack other people’s systems.

You follow the rules of the sites and services you use. If we learn of prohibited use, we may close access to the account.

## Your data {#data}

Your profiles and everything in them belong to you and are stored on your Macs, encrypted. We never delete them — not when a period ends, not when you stop paying. How we handle account data is described in the [privacy policy](privacy.html).

## Liability {#warranty}

We check {{name}} on every build and publish what we measure and how. But the software is provided “as is”: we don’t promise it fits every task, and we are not responsible for how sites treat your accounts. Our liability is limited to what you paid in the last {{tbd:q12:12 months}}, as far as the law allows.

## Ending {#end}

You can delete your account at any time, in your account. When a paid period ends, your profiles stay on your Macs: the app opens them for data export only. Your data is never deleted.

## Questions {#contact}

Questions about these terms: legal@{{domain}}.`,
  },
  refunds: {
    title: 'Refund policy',
    lead: 'When and how we give your money back.',
    toc: [['when', 'When'], ['how', 'How'], ['crypto', 'Crypto'], ['after', 'After a refund']],
    body: `## When {#when}

- Within **14 days** of your first payment — in full, no questions asked.
- After a renewal — within **7 days**, if you haven’t worked in {{name}} in the new period.

## How {#how}

Write to billing@{{domain}} from your account’s address, or give your licence key. Add the address for the refund, on the same network you paid on.

## Crypto {#crypto}

We return **the same coin and the same amount** we received, however the exchange rate has moved since you paid. Whether the coin went up or down, the refund doesn’t change in your favour or ours. We pay the network fee for the refund.

## After a refund {#after}

The paid period ends and your devices are signed out of the account. Your profiles stay on your Macs, encrypted as they were; the app opens them for data export. Your data is never deleted.`,
  },
};
