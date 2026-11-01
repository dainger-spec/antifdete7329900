// Legal: privacy policy, terms of use, refund policy. As the owner decided: the seller is a private individual, and
// there will be no legal entity; the owner fills in the name, country and governing law — here they are marked places
// (question 15), no values made up. Crypto only, and the crypto processor is the only recipient of payment data; no
// automatic charges, reminders 7 days and 1 day before; data is never deleted; refunds within 14 days, and 7 days after a
// renewal, in the same coin and the same amount. What the server keeps and doesn't, sync, the periods and the payment
// service are the ready wording of lumen-api-server, docs/SITE_API.md §9, word for word (it may be rearranged for the
// page, but no point may go and the paragraph on the number of profiles may not be softened); the rights log goes on the
// payments' schedule (internal/core/retention.go). Service names and how long support mail is kept: question 12.
export default {
  title: 'Legal',
  tabs: [['privacy.html', 'Privacy'], ['terms.html', 'Terms of use'], ['refunds.html', 'Refunds']],
  updatedLabel: 'In effect from',
  updated: '{{tbd:q12:the publication date}}',
  tocTitle: 'Sections',
  privacy: {
    title: 'Privacy policy',
    lead: 'What we know about you, why, and for how long. And what we don’t know and can’t find out.',
    toc: [['short', 'In short'], ['who', 'Who is responsible'], ['server', 'What the server keeps'], ['devices', 'About your Macs'], ['sync', 'Sync'], ['not', 'What the server doesn’t keep'], ['terms', 'How long'], ['app', 'The app'], ['site', 'The site'], ['processors', 'Who we share data with'], ['rights', 'Your rights'], ['changes', 'Changes']],
    body: `## In short {#short}

- Profiles, what’s in them and your master password stay on your Macs. Turn on sync and only ciphertext goes to the server: the key never leaves your Macs.
- The server knows your email, a hash of your password, your plan and paid period, your invoices and your devices — and **how many profiles each Mac has**. That number is all it knows about your profiles.
- The server doesn’t keep IP addresses. It has no computer names.
- **A forgotten master password can’t be recovered.** Not by us, not by anyone.
- The site has no analytics, no cookies and no third-party scripts. The app sends us no analytics and no crash reports.

## Who is responsible {#who}

{{name}} is a Mac app, the site {{domain}}, an account server and a sync server. They are sold and supported by a private individual: {{tbd:q15:[the seller’s full name]}}, {{tbd:q15:[country]}}, who is responsible for the processing described here. Questions about data: privacy@{{domain}}.

## What the {{name}} server keeps {#server}

- Your email address and a hash of your password (we neither keep nor know the password itself).
- Your plan, its limits and the date your paid period ends.
- Invoices: the amount in dollars, the coin and its amount, the address issued for the payment, the transaction on the network, dates.
- If you have a team, the addresses of the people you invited.
- A record of changes to your rights: what changed, when and why (payment, extension, refund, end of period).

## About your Macs {#devices}

For each Mac: an identifier derived from the Mac’s hardware identifier (the hardware identifier itself never reaches us), the label you gave it, if any, the app’s version, when the Mac was added and when it was last in touch — and **how many profiles are on that Mac**.

**The number of profiles is the only thing the server knows about your profiles.** It is needed so that your plan’s profile limit is shared by all your Macs and by your whole team. The server never receives profile names, their contents, cookies, saved passwords, history or proxy addresses.

## Sync {#sync}

If you turn it on, the server keeps your data encrypted only — the key never leaves your Macs, and only you can read it. The server sees that your account has a vault, how many objects it holds, their sizes and when they changed.

Object names on the server are HMACs of their real names: they don’t even reveal that an object is “a profile’s history”. **We cannot decrypt profile data** — not of our own will, not on anyone’s demand.

## What the server does not keep {#not}

IP addresses (used only in memory, to limit request rates), computer names, profile data.

The server never receives your master password. We can’t reset it: without it profile data can’t be decrypted — not by you, not by us.

## How long {#terms}

- **Your account** is deleted 7 days after you ask (until then you can cancel), and your sync data with it. You ask in your account; the account is blocked at once.
- **Payment records** are then kept without your email address for three full calendar years after the year of the payment, and deleted.
- **The record of changes to your rights** goes on the same schedule: three full calendar years after the year of the entry.
- **Database backups** are kept for up to 30 days: a deleted email disappears from them with the oldest copies.
- **Messages with support** are kept for {{tbd:q12:[period]}}.

## The app on your Mac {#app}

- The app sends us no analytics, no crash reports and nothing about which sites you open.
- To learn a proxy’s country, time zone and external IP, the app asks the geolocation services ipinfo.io, get.geojs.io and ipwho.is — **through the proxy itself**, when a profile with a proxy starts or you check a proxy. They see the proxy’s address, not yours.
- The search at the start of a warm-up goes through DuckDuckGo, as from the address bar — also through the profile’s proxy.
- Sites you open in profiles get what they would get from Safari. That is between you and those sites; their privacy policies apply to them.

## The site {#site}

- The site has no analytics, no ad pixels, no third-party scripts and no cookies. Fonts and images come from our server.
- After you sign in, the site keeps the session key in the tab’s memory and forgets it when you sign out. A session lasts 30 days and ends after 7 days without use.
- The payment page is ours: you don’t leave the site, and the server gets the address for the transfer from the payment service.

## Who we share data with {#processors}

- **The payment service** ({{tbd:q12:[name]}}) receives from us only the amount in dollars, the coin, the invoice number and the plan’s name — not your email address, nothing else about you. It issues the address for the transfer.
- **The email service** — {{tbd:q12:[name]}} — to send codes, receipts and reminders.
- **Hosting** — {{tbd:q12:[name and country]}} — where the servers run.

We don’t sell data and don’t pass it to ad networks. On a lawful demand we can hand over only what we have — the lists above. Profile data is encrypted, and we can’t decrypt it.

## Your rights {#rights}

- **Find out** what data we have about you and get a copy — write to privacy@{{domain}}.
- **Delete** your account — in your account; sync data — there too, separately.
- **Correct** your data — write to privacy@{{domain}}.
- **Complain** to your country’s data protection authority.

## Changes {#changes}

We email you about material changes {{tbd:q12:30 days}} before they take effect. Earlier versions of the policy stay on this page.`,
  },
  terms: {
    title: 'Terms of use',
    lead: 'The rules on which you use {{name}}. Short, and no small print.',
    toc: [['parties', 'The parties'], ['license', 'Licence'], ['account', 'Account'], ['team', 'Team'], ['payment', 'Payment and period'], ['use', 'Acceptable use'], ['data', 'Your data'], ['warranty', 'Liability'], ['law', 'Governing law'], ['end', 'Ending'], ['contact', 'Questions']],
    body: `## The parties {#parties}

{{name}} is sold by a private individual: {{tbd:q15:[the seller’s full name]}}, {{tbd:q15:[country]}}. These terms are an agreement between you and the seller.

## Licence {#license}

While you have a trial or a paid period, you may install and use {{name}} on your devices — within your plan’s number of profiles and devices.

{{name}} runs on Macs with Apple Silicon and macOS 26 or later. Intel Macs are not supported.

## Account {#account}

- Your account is your email and password. A code from an email confirms a registration and a password reset.
- Your profiles’ master password isn’t tied to the account, and we don’t know it. A forgotten master password can’t be recovered.

## Team {#team}

The Team plan has 5 seats, including the owner. Each person signs in with their own email and password. The profile and device limits are shared by the team. The owner pays; members don’t see the team’s invoices.

## Payment and period {#payment}

- You pay in crypto, for a month or a whole year; a year costs ten months. Prices are in US dollars, on the [pricing page](pricing.html).
- A payment is one-off: there are no automatic charges and nothing to cancel. A paid period simply ends; a new payment renews it. Pay early and the new period starts when the current one ends.
- We remind you by email 7 days and 1 day before a period ends. You can renew in your account at any time.
- The trial is 7 days free, up to 3 profiles.
- When a period ends, the app opens your profiles for data export only until you renew. **Your data is never deleted.**
- We tell you about a price change in advance; the new price applies to periods paid after the change.
- Refunds follow the [refund policy](refunds.html).

## Acceptable use {#use}

{{name}} is built for privacy and for working with several accounts. You may not use it:

- for fraud, for passing yourself off as someone else, or for anything that breaks the law;
- to spread malware, send spam or attack other people’s systems.

You follow the rules of the sites and services you use. If the seller learns of prohibited use, they may close access to the account.

## Your data {#data}

Profiles and everything in them are yours, kept encrypted on your Macs. We never delete them — not when a period ends, not when you stop paying. If you turned on sync, its encrypted copy on the server is deleted with the account — or earlier, when you ask in your account; the data on your Macs stays. How we handle account data is in the [privacy policy](privacy.html).

## Liability {#warranty}

We check {{name}} on every build and publish what we measure and how. But the software is provided “as is”: the seller doesn’t promise it suits every task and isn’t responsible for how sites treat your accounts. The seller’s liability is limited to what you paid over the last {{tbd:q12:12 months}}, as far as the governing law allows.

## Governing law {#law}

These terms are governed by {{tbd:q15:[the governing law]}}.

## Ending {#end}

You can delete your account at any time, in your account. It is blocked at once: devices leave the account, team seats close. After 7 days the email, password, devices and the encrypted sync data on the server are deleted; until then the deletion can be cancelled by signing in. The profiles on your Macs are not touched: they are kept only by you, and {{name}} does not delete them.

## Questions {#contact}

Questions about these terms: legal@{{domain}}.`,
  },
  refunds: {
    title: 'Refund policy',
    lead: 'When and how we give your money back.',
    toc: [['when', 'When'], ['how', 'How'], ['crypto', 'Crypto'], ['after', 'After a refund']],
    body: `## When {#when}

- Within **14 days** of your first payment — in full, no reason needed.
- After a renewal — within **7 days**, if you haven’t worked in {{name}} in the new period.
- If you sent more than needed, the payment counts, and we return the excess when you ask.

## How {#how}

Write to billing@{{domain}} from your account’s email. Add the address for the refund, on the same network you paid on.

## Crypto {#crypto}

We return **the same coin and the same amount** we received — whatever the exchange rate has done since. Whether the coin went up or down, the refund doesn’t change in your favour or in ours. We pay the network fee for the refund.

## After a refund {#after}

The part of the period that payment paid for is removed. Your profiles stay on your Macs, encrypted as they were; if no paid days are left, the app opens them for data export only. Your data is never deleted.`,
  },
};
