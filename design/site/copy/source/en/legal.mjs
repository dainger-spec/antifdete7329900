// Legal: privacy policy, terms of use, refund policy. Drafts for a lawyer: the legal entity, jurisdiction,
// retention periods, providers and refund windows are the owner's decisions (questions 8, 9, 10).
// Facts about data: docs/SYNC_FORMAT.md, docs/SYNC_SERVER_API.md, ProxyGeoLookup.swift, README.
export default {
  title: 'Legal',
  tabs: [['privacy.html', 'Privacy'], ['terms.html', 'Terms of use'], ['refunds.html', 'Refunds']],
  updatedLabel: 'In effect from',
  updated: '{{tbd:q9:the publication date}}',
  tocTitle: 'Sections',
  privacy: {
    title: 'Privacy policy',
    lead: 'What we know about you, why, and for how long. And what we do not know and cannot find out.',
    toc: [['short', 'In short'], ['who', 'Who we are'], ['server', 'What the server knows about you'], ['cannot', 'What we do not know'], ['app', 'The app'], ['site', 'This site'], ['processors', 'Who we share data with'], ['rights', 'Your rights'], ['changes', 'Changes']],
    body: `## In short {#short}

- Profiles, what is in them, and your master password stay on your Macs. The server does not see them and cannot decrypt them.
- We know little about you: your email (if you sign in with one), the IP addresses of requests to our server, how many devices you have, the sizes and change times of encrypted sync blocks — and what an invoice needs.
- **A forgotten master password cannot be recovered.** Not by us, not by anyone.
- This site has no analytics and no third-party scripts. The app sends us neither analytics nor crash reports.

## Who we are {#who}

The data controller is {{tbd:q9:company name}}, {{tbd:q9:country of registration, address, registration number}}. For anything about data, write to privacy@{{domain}}.

## What the server knows about you {#server}

This is the complete list.

| Data | Why | How long we keep it |
|---|---|---|
| **Email** — only if you sign in with one | Signing in with a one-time code, invoices, subscription notices | While the account exists |
| **IP addresses** of requests to the server | Abuse prevention and diagnostics | {{tbd:q9:30 days}} in server logs |
| **How many devices** the account has, and when each last called in | The plan’s device limit, revoking a device | While the account exists |
| **Sizes and change times** of encrypted sync blocks, and their revisions | Sync itself | Until you delete them or the account |
| **Payment data**: plan, amount, date, status; for crypto, the address and transaction | Invoices, accounting, refunds | {{tbd:q9:as long as accounting law requires}} |
| **Support correspondence** | To answer you | {{tbd:q9:2 years}} |

Your card number is handled by the payment provider; it never reaches us.

## What we do not know and cannot find out {#cannot}

- Everything in your profiles — settings, proxies, passwords, cookies, history, bookmarks — is encrypted on your Mac with a key derived from your master password **before** anything leaves for the server. The server keeps ciphertext only. It does not have the key.
- **We cannot decrypt profile data** — not on our own initiative and not on anyone’s demand.
- Objects on the server are named by an HMAC of their real names. They do not even say that an object is “a profile’s history”, or exactly how many profiles there are.
- We do not store your master password and cannot reset it. **A forgotten master password cannot be recovered**: without it, profile data cannot be decrypted — by you or by us.
- If you sign in with a licence key, we do not have your email either.

## The app on your Mac {#app}

- The app sends us no analytics, no crash reports, and nothing about the sites you open.
- To learn a proxy’s country, time zone and exit IP, the app asks the geolocation services ipinfo.io, get.geojs.io and ipwho.is — **through the proxy itself**, when a proxied profile starts or when you check a proxy. They see the proxy’s address, not yours.
- The search at the start of a warm-up goes through DuckDuckGo, as from the address bar — through the profile’s proxy as well.
- The sites you open in profiles get what they would get from Safari. That is between you and those sites; their privacy policies apply to them.

## This site {#site}

- This site has no analytics, no advertising pixels and no third-party scripts. Fonts and images come from our own server.
- The site has one cookie: your account session after you sign in. Until you do, there are none.

## Who we share data with {#processors}

- **Payment provider** — {{tbd:q8:name}} — for card payments.
- **Email service** — {{tbd:q9:name}} — to send sign-in codes and invoices.
- **Hosting** — {{tbd:q9:name and country}} — where the server runs.

We do not sell data or pass it to advertising networks. On a lawful demand we can hand over only what we have — the list above. Profile data is encrypted with us, and we cannot decrypt it.

## Your rights {#rights}

- **Find out** what data we hold about you, and get a copy — write to privacy@{{domain}}.
- **Delete** your account and all sync data — in your account, at once, with no emails needed.
- **Correct** your email — in your account settings.
- **Opt out** of release emails — in the same place.
- **Complain** to a supervisory authority — {{tbd:q9:which one depends on the jurisdiction}}.

## Changes {#changes}

We email you about significant changes {{tbd:q9:30 days}} before they take effect. Earlier versions of this policy stay on this page.`,
  },
  terms: {
    title: 'Terms of use',
    lead: 'The rules under which you use {{name}}. Short, and with no small print.',
    toc: [['license', 'Licence'], ['account', 'Account'], ['subscription', 'Subscription and payment'], ['use', 'Acceptable use'], ['data', 'Your data'], ['warranty', 'Liability'], ['end', 'Ending'], ['law', 'Governing law']],
    body: `## Licence {#license}

While your subscription or trial is active, we give you a non-exclusive right to install and use {{name}} on your Macs — within your plan’s number of devices and profiles.

## Account {#account}

- You sign in by email with a one-time code, or with a licence key.
- The key is the only way into an account without an email. Lose it and we cannot restore access.
- The master password of your profiles is not tied to your account and is unknown to us. A forgotten master password cannot be recovered.

## Subscription and payment {#subscription}

- The subscription renews itself at the end of every period until you cancel it. You can cancel in your account at any time; the period you paid for stays in effect.
- Free trial: {{tbd:q3:7 days, no card needed}}. Nothing is charged when it ends.
- Prices are on the pricing page. We tell you before a price changes; the change applies from the next period.
- Refunds follow the [refund policy](refunds.html).

## Acceptable use {#use}

{{name}} is made for privacy and for working with several accounts. You may not use it:

- for fraud, impersonating another person, or anything that breaks the law;
- to spread malware, send spam or attack other people’s systems.

Keeping to the rules of the sites and services you use is up to you. If we learn of prohibited use, we may suspend or end the subscription.

## Your data {#data}

Profiles and everything in them are yours, and are stored on your Macs encrypted. How we handle account data is described in the [privacy policy](privacy.html).

## Liability {#warranty}

We check {{name}} on every build and publish what we measure and how. Still, the software is provided “as is”: we do not promise it suits every purpose, and we are not responsible for how sites treat your accounts. Our liability is limited to what you paid in the last {{tbd:q9:12 months}}, as far as the law allows.

## Ending {#end}

You can cancel the subscription and delete the account at any time. When a subscription ends, your profiles stay on your Macs. {{tbd:q2:Without a subscription the app opens them for export only.}}

## Governing law {#law}

These terms are governed by the law of {{tbd:q9:the country}}. Disputes go {{tbd:q9:to the courts where the company is registered}}. Questions: legal@{{domain}}.`,
  },
  refunds: {
    title: 'Refund policy',
    lead: 'When and how we give your money back.',
    toc: [['when', 'When'], ['how', 'How'], ['crypto', 'Crypto'], ['after', 'After a refund']],
    body: `## When {#when}

- Within **{{tbd:q10:14 days}}** of your first payment — in full, no reason needed.
- On a renewal — if you write within {{tbd:q10:7 days}} of the charge and have not used {{name}} in the new period.
- If {{name}} does not work on your Mac and support could not help — at any time, for the unused days.

## How {#how}

Write to billing@{{domain}} from your account’s address, or give your licence key. The money goes back the way you paid — for cards, usually within {{tbd:q10:5–10 business days}}.

## Crypto {#crypto}

We refund in the same coin to the address the payment came from — the amount in coin at {{tbd:q10:the rate of the payment day}}. We pay the network fee for the refund.

## After a refund {#after}

The subscription ends and devices are signed out. Profiles stay on your Macs — encrypted, as they were.`,
  },
};
