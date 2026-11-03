# The licensing client

The app's side of the account server's contract (`dainger-spec/lumen-api-server`,
`docs/CONTRACT.md`, read on 1 November at 24ceb5e and again on 2 November at 150b32b — the server's
release v2026.11.04, deployed with the app's first release). The contract is the source; this page
says where each part of it lives here and what checks it. Its texts are compared with the app's word
for word, both languages: 80 of its 116 are the app's, the same; the 36 others are the site's alone
(payments, teams, invoices) or for screens the app does not have (below, "Open").

## Two ways in, one mechanism

- **Email and password** (§5.2): `POST /v1/auth/login` gives a session; the session activates this
  Mac (§6.1).
- **A key** — a purchase without registration, `LMK-XXXX-…` (the server's `internal/ident`,
  contract §18): read here before anything is sent — case and hyphens do not matter, I/L read as 1
  and O as 0, a wrong character or a swap of two is caught by the two check characters (CRC-10) —
  then it activates this Mac by itself, in the request's body (`AccountAPI.activate`, `.key`). A
  purchase code (`LPC-`) or an invoice number (`LMN-`) typed there is named as such; Cyrillic
  letters say the keyboard is in Russian. The reading passes the server's whole set of vectors
  (`Fixtures/ident-test-vectors.json`, 151 cases of the three codes:
  `LicenseTests.testEveryCaseOfTheServersCodeVectorsReadsAsTheContractSays`).

Behind both: the server answers with a **signed document** (§7), which the app checks itself
(`EntitlementVerifier`, the contract's eight steps in order; nothing of the payload is read before
its Ed25519 signature checks with a key the build carries) and decides from (`LicenseDecision`,
§8.2): FULL, GRACE, EXPORT_ONLY, NOT_SIGNED_IN. The server is never asked whether a profile may
open (§1). The time decided at is this Mac's clock, never earlier than a floor that only moves
forward (`EffectiveClock`, §8.3): setting the clock back does not bring time back.

## Without the network

A document works 4 days, then 3 days of grace with a banner, as the document's own dates say
(never numbers written here, §9.2). "Unreachable" — no network, TLS, 5xx, 429, a captive portal's
page, a document changed on the way — changes nothing (§9.3); only `device_revoked` and
`machine_mismatch` sign the Mac out (§9.4). Settings › Account says until when this Mac works
without the server and how much of it is left; the sidebar's line says it short.

Checked by: `LicenseClientTests.testWithoutTheServerTheMacWorksTheWholeGraceAndSaysUntilWhen`
(200 hours of silence: 4 days full, 3 grace, then export only, the GRACE date said all along), the
clock set back, a document copied to another Mac; the self-test's "licensing" group against a
server played on the loopback (`LicenseSelfTest`), with the server stopped.

## Renewal (the owner, 3 November)

The production server saw one `POST /v1/device/entitlement` from a Mac in nine hours — at its
activation — and nothing through a full relaunch and three profiles made; its `profile_count`
stayed 0, its `label` empty, and the app's own log said nothing. The app renewed only once the
document's refresh time had passed (a day after it was issued), its launch included, and looked
every 15 minutes; before the vault was opened it counted 0 profiles; it never sent a label after
the activation, whose field was empty by default; a failed renewal left one line at `notice`, and
a renewal not asked left none.

Now (`LicenseModel`, `RefreshSchedule`, `LicenseClient.refreshReport`):

- **When.** At each start of a signed-in Mac, whatever the document says. Then whenever the
  document asks (its `refreshAfter`, looked at every minute while the app runs), after a wake and
  when the network comes back, when the vault opens, and two seconds after the number of profiles
  changes (several changes in a row are one renewal). After a failure, the retries' times: 1, 5,
  15, 30, 60 minutes, then every hour.
- **What.** This Mac's id, the app's version (`<version> (<build>)`), the number of profiles — the
  open vault's, or before it is opened the last number known (`account.json`'s `profileCount`, a
  number only) — and the label: the one this Mac was connected with, or this Mac's name from the
  system (`ThisMac.name`). The activation's label field shows that name to begin with; whoever
  wants another changes it, whoever wants none clears it. A server that refuses a renewal with a
  label (HTTP 400) gets it again without one at once, and no label for the rest of the run: the
  renewal matters more than the label.
- **Said.** Each renewal in the app's log (subsystem `PrivacyBrowser`, category `License`): asked,
  and why (`launch`, `unlocked`, `profiles`, `timer`, `network`, `wake`, `active`, `retry`,
  `manual`); done, and for how long the document works; or `License renewal failed` at `error`
  level, with why (no answer and the error's kind, the server's HTTP status and code, an answer
  not taken and the check's name), the next try, and how long this Mac works without the server.
  Nothing of the person's: no address, no message, no label. And to the person: once renewals
  have been failing and the document has less than two days left, a banner says since when, why,
  and until when this Mac works without a renewal, with "Проверить сейчас"; past the document's
  expiry the grace's own banner says it (§8.5). Silence is no longer success.

What the server must do with the label of a renewal is the server's: it is sent in the body of
`POST /v1/device/entitlement` as `label` (64 characters at most), beside `machineID`,
`profileCount` and `appVersion`. The server should take it — at least where the device's label is
empty — and must not refuse the renewal for it.

Checked by what the server sees, never by what the app says it sent:
`scripts/license_renewal_check.py` (CI, "The license's renewals, as the account server sees them").
A stand-in server on 127.0.0.1 signs documents with a key made for the run and keeps every request;
the development build is started as a person starts it. Each start must reach the server; running,
a document that asks to be renewed a minute after it is issued must be renewed again without a
start; every request carries the version, this Mac's id and name; through the app's own model a
vault with three profiles is opened and a fourth made, and the server must be told 3, then 4; a
renewal the server refuses (500) must be said in the app's log; and the control — an address where
nothing listens — must fail the check. Before this change the same check measured today's code
(`--measure`, the measurement branch `claude/measure-license-renewal`).

## The key, kept like the master password

A key is the whole account for whoever holds it — no email, no password. So (the owner, 1 November):

- **In memory** from the moment it is typed until the vault keeps it; the types never say
  themselves (`AccountKey`, `PurchaseCode`, `ServerToken`: `LMK-…`, `LPC-…`, `lmd_…` in any
  interpolation, dump or mirror).
- **Or not kept at all** — "Don't remember the key" on the key's screen (§10.1, off by default),
  with `key.remember` beside it: the key is then forgotten as soon as its request is answered, the
  vault keeps no copy (one kept by an earlier sign-in is removed at the next unlock), and each time
  the key is needed it is asked for — the license's Macs (`key.devices_need_key` and a field),
  unlinking one, linking an email, a new key. `account.json` keeps the choice (`rememberKey: false`),
  never the key. Within one action of two steps (an email: the letter, then its code; all places
  taken: unlink one, then connect) the key is held until the action ends.
- **A key the server no longer knows** (`key_not_found`: replaced by support or on another Mac) is
  removed from the vault and asked for anew (§10.1).
- **On disk only inside the vault**: `account-key.bin`, AES-GCM under `HKDF(VMK, "account-key")`,
  this Mac's, never synced (`AccountKeyVault`). A profile's own process, opened with a grant,
  cannot derive the key. Never in `account.json`, the defaults, a log or a report.
- **Its text comes out in six places** — the key's own type, the request that carries it, the
  vault's file, the token in `Authorization`, the token's own type, and the new key shown once after
  a replacement (`NewKeyView`: on screen while its sheet is open, copied only at a click and marked
  concealed for clipboard managers) — and `scripts/check_account_key.py` fails CI on any other
  `unredacted()` (its `--self-check` plants four forbidden calls and must find them).
- **Behind that**, `LogRedaction` masks license codes and tokens in exception reasons.
- **Checked by** the self-test: `account.json`, the vault's file, the defaults and the diagnostics
  ZIP searched for every form of the key and for the device's token, the search first shown to
  find a key planted in a ZIP of its own; this process's whole log since the check began (every
  subsystem — a marker written in clear must be found there first); every answer of the automation
  API's routes, with the key signed in (the API reads profiles only, never the account).
- **And in a crash report**, which macOS writes after the process is gone:
  `scripts/key_crash_check.py` runs `Lumen --key-crash-check`, which signs in with the key, keeps it
  in a vault and crashes on purpose, on a queue of its own; its report must hold no form of the key.
  Its control crashes the same way on a queue named with the key's text — the report keeps the
  crashed queue's name, not a fatal error's message (CI run 601) — and that report must hold it.

What it cannot promise: the system's crash report keeps an uncaught exception's reason as it was;
the app never puts the key in one (its type never says itself), but a crash report is the
system's, not rewritten here.

## The master password is not the key (§10.1)

The key goes to the server at every activation and passes Cloudflare, so — as with the account's
password — it must not lock what the server must not read:

- **At creation, and at a change of the master password**: one that is the key is refused under
  its field (`master_password.same_as_key`). Compared directly, in memory: the candidate read as a
  key is read (§18) against the key typed in this session — an HMAC of its canonical text under a
  key made for this once (`AccountKeyEcho`), so that it works even when the key itself is not kept —
  or against the key the vault keeps. Nothing is derived from either; nothing is tried on the vault.
- **At an unlock**: the master password just typed is compared with the key typed in this session
  or the one the vault keeps; the same — said, not refused (the data is already locked with it), with
  "Change master password" beside the text. The contract has no `…_existing` text for the key yet:
  `master_password.same_as_key` is shown (asked of the server).
- The account's password: the same, as before (`master_password.same_as_account`, `…_existing`) —
  also refused under the field now, and with the action beside it at an unlock.
- Checked by `LicenseTests.testTheKeysEchoKnowsItInEveryFormItCanBeTypedInAndNothingElse` and the
  self-test (six forms of the key known with the key not kept; another key, a plain password and the
  key with a character more not; nothing left after the step; the kept key compared at an unlock).

## An email for a key's purchase, and a new key (§11.1)

Settings › Account › Key, for a Mac connected with a key:

- **Link an email** (optional): `email_link.explain` before the fields; the key (asked when not
  kept) and the **purchase code** (always asked, never kept: the key alone is not enough), the
  address and a password → `POST /v1/anonymous/email` (`202 check_email`) → the six digits of the
  letter (`signup.check_email`, `signup.code_terms` with the server's numbers) →
  `POST /v1/anonymous/email/confirm` → a session for the account screen; `emailLinked` in
  `account.json`. The key works on, nothing is reissued, this Mac stays the key's.
- **Replace the key**: `key.replace.confirm`; the key and the purchase code
  (`POST /v1/anonymous/key/replace`), or — an email linked and its session here — the account's
  password (`POST /v1/account/key/replace`). The new key is shown once (`key.replaced`, with Copy);
  the vault keeps it instead of the old one when the key is remembered (the vault must then be open);
  this Mac, unlinked with every other, is connected again with it at once.
- **Texts by `emailLinked`**: `account.key_license` / `.email` on the account screen; "Lost your
  key?" — `key.no_reset.email`, or `key.no_reset` with the time from `GET /v1/plans`
  (`error.unreachable` when it does not answer: never a number of the app's own). The reminders by
  the system's notifications are offered only while no email is linked.
- **Errors by code**: `proof_refused`, `email_already_linked`, `invalid_purchase_code`
  (`purchase_code.typo`, also caught before sending), `invalid_key` (`key.typo`), `key_not_found`
  (`key.not_found`), `invalid_code`, `letters_busy`, `no_key`, `account_deletion_pending` with a key
  (`error.account_deletion_pending.key`).
- Checked by `LicenseClientTests` (the requests' paths, bodies and authorization; the answers) and
  the self-test against the server it plays: another purchase code refused, this one accepted; a
  wrong letter code refused, the right one linking; the key replaced, kept, this Mac connected with
  the new key; a kept key the server no longer knows removed from another Mac's vault; the keys and
  the purchase code in no address (found in a body: the search can find), no `account.json`, log
  (a marker found first) or diagnostics ZIP.

## The server of 2 November (v2026.11.04)

What changed for the app, each working with the server live since 2 November (v2026.11.02) as well —
before v2026.11.04 is deployed, and after a rollback to it:

- **A sign-in that waits for the letter's code** (§5.2). The password right, the server may answer
  `202 check_email` and send a code to the account's address: after five failed attempts for the
  address, or five wrong passwords in a row for the account. Before, the app read only a session
  and said "the Lumen server isn't responding" — this was already so with v2026.11.02. Now the code's
  screen: `login.check_email`, `login.code_terms` (when the letter went, until when the code works,
  how many tries — from the answer), the code → `POST /v1/auth/login/confirm` → the session, then
  the activation as after a password. "Send the code again" → `POST /v1/auth/login/resend` with the
  attempt's `challenge` (in memory only, never written or logged): `login.code_resent`, not before
  `resendAvailableAt` (`login.resend_wait` counts down), at most three times (`login.resends_used`),
  an attempt that ended (`login_expired`) back to the password with `error.login_expired`. A
  v2026.11.02 answer has no challenge and no times: the screen counts from when it came and offers
  no resend.
- **The robot check** (§5.5). `403 robot_check` opens the site's `/robot-check?action=login` in a
  sheet: a web view of the app's own process whose store keeps nothing, which takes a token from
  `lumenRobotCheck` only from the site's own page — its main frame, the site's origin — and only one
  that looks like one; the main frame cannot leave the site, nothing opens a window. The sign-in is
  sent again with the token, once. `503 robot_check_unavailable` and `503 server_busy` are the
  server's words with their wait (`error.robot_check_unavailable`, `error.server_busy`), no longer
  "unreachable" — except for a refresh, which waits as long as the server said.
- **Signing out under the unlink cooldown** (§6.3, F4). `429 unlink_cooldown` to `DELETE /v1/device`
  leaves this Mac as it was — token, document, session, the key in the vault — and says until when
  (`signout.cooldown`). The confirmation before says how long the next unlink waits
  (`signout.consequences`, from `unlinkCooldownSeconds` of the last activation or refresh, kept in
  `account.json`); a server that sends none has no cooldown on a sign-out, and the confirmation is
  then the contract's text before it.
- **A key replaced with the purchase code unlinks a linked email** (§11.1, F3):
  `key.replace.confirm.email` says so before — also while it is not known whether one is linked (the
  license's view not read since this Mac was connected; it is asked when the key is at hand). After
  it this Mac's session goes and whether an email is linked is asked again — at once, whether or not
  this Mac connects again with the new key. With the account's password the email stays
  (`key.replace.confirm`); a wrong password there is `error.invalid_credentials.password`.
- **Export only, said** (§8.5 item 7): after the grace — `mode.expired.unreachable` (or
  `.outdated`, then without `app.outdated` beside it); no document that checks — `mode.unverified`.
  Both stop work, so they come before every other notice above the profiles, in red; the sidebar's
  line after the grace is "No connection to the server" (or "Lumen is out of date") / "Export only".
- **The period's end can be closed** (§8.5 item 10): closed during the week it comes back for the
  last day; closed on the last day, not again before the next end (kept per end and level). A
  refresh that was out when it was closed does not bring it back: a refresh's answer keeps the app's
  own notes made meanwhile, and one that did not come changes nothing.
- **Renewal of a key's license without an email** is on the key's page (`<site>/key`, §11.1, §17.4),
  from the banners and from Settings › Account; otherwise the plans.
- **Texts** changed by the contract: `activation.trial_used` (the trial was this Mac's, with another
  account), `key.no_reset` (the wallet's signature, a payer from an exchange).
- Checked by `LicenseClientTests` (both servers' 202, confirm and resend with every refusal, the two
  503s and a refresh's wait, the sign-out under the cooldown and after it, the cooldown from each
  answer and none from an older server's), `LicenseTests` (the banners, the closing, `account.json`'s
  new notes read back and an odd one left out), and the self-test against the server it plays: the
  code's screen, a wrong and the right code, the activation after it, three resends then
  `resend_limit`, another attempt over; an older server's code; the robot check's page handing over a
  token from a frame of its own origin and a malformed one before the real one — only the real one
  taken — and the sign-in going through with it; the sign-out under the cooldown leaving
  `account.json` signed in, after it signing out.

## Documents that must be refused

The self-test's licensing group, against the account server it plays, through the same activation
and the same gate a profile meets: a document whose grace and period are over gives export only and
no profile opens; one signed by another key under the server's key id, and another Mac's (its
`machineID` not this one's), are refused at activation and leave this Mac not connected; a stored
document given a year more on disk, its signature kept, is refused at the next start. The valid
document, through the same steps, connects this Mac and opens the profile — their control.

## Reminders for an account with a key alone

Such an account has no email, so no letter says its period is ending (the owner, 2 November). The
system's notifications do, a week and a day before the end (`ExpiryReminders`, `ExpiryNotifications`):

- **Asked once, by itself**: right after a key connected this Mac, or when the first warning before
  the period's end appears — never at a launch for its own sake, never over the lock screen.
- **The app's line first**, why it asks at all: «Напомнить об окончании подписки нам больше нечем:
  почты у вас нет.» Only "Remind me" leads to the system's question.
- **Refused, nothing changes**: the banner warns as before; the offer is not made again by itself.
  Settings › Account offers it again — the system's question, or System Settings › Notifications
  when they were turned off there.
- Set again whenever the period's end moves; removed when this Mac is signed out or the account
  is not a key's. An account with an email is never asked.

`account.json` (§4.2): the device's token, the document, the clock's floor — owner-only, beside the
vault, read before it is unlocked; a newer format is refused and never written over, an unreadable
one moved aside.

## Screens

The design's "Аккаунт" boards (`docs/DESIGN.md`), in `UI/AccountViews.swift`:

- **Sign in** (`SignInFlow`): email and password, or key with "Don't remember the key" and
  `key.remember`; "Forgot password?" opens the site's reset; "Lost your key?" says the contract's
  `key.no_reset` (or `.email`); "Create account" opens the site — no registration and no payment in
  the app.
- **Connect this Mac**: the label, `activation.server_learns`, all places taken → unlink one here.
- **First launch**: sign in → connect → master password (the owner's order); the master password
  equal to the account's password or to the license's key is refused under its field, compared
  directly as an HMAC under a one-time key — never a key derived from it (§10.1, the owner's rule).
- **Settings › Account**: the plan and until when, how long without the server, for a key's
  account without an email its reminders, this Mac's code, sign out (`signout.consequences`), for a
  key's account linking an email and replacing the key, the license's Macs with this one marked and
  the others unlinkable (`unlink.consequences`; the key asked for when not kept), the site.
- **Banners** above the profiles in §8.5's order, the period's end warned a week and a day before;
  **the sidebar's line** about the rights; a profile that may only be exported says so in its row
  and does not open — the rule, said as a rule.

## Builds

A release carries `PBAccountServerURL` (https), `PBAccountSiteURL` and `PBEntitlementPublicKeys`
(`scripts/build-app.sh` from `scripts/release.sh`), and nothing in the environment changes them.
`--release-check` refuses a build without a server, without keys, or trusting the development
server's key (`445c6300da0205b1`) — so `scripts/release.sh`, which runs it on the app it is about to
publish, refuses to make such a release, as it refuses one whose profiles would not open in
Safari's window. CI proves each refusal: a development build (no server), and copies of the release
changed in one thing each (its keys removed; the development key added).

## Open

- The site's `/robot-check?action=login` page for the app (`docs/SITE_API.md` §4.1 proposes it to
  be confirmed with the app): the app takes the token exactly as the contract writes it —
  `window.webkit.messageHandlers.lumenRobotCheck.postMessage(token)` from the page's main frame, at
  the site's origin. Until the site has it, a sign-in that needs the check cannot be finished in the
  app (the site's own sign-in can).
- Texts for screens the app does not have: `profile.export_only.address` and `.strip` (a profile
  that may only be exported does not open; it is exported from the list), `account.label_needs_session`
  (a Mac's label is set at its activation only), `signup.trial` (registration is the site's),
  `error.not_found.device` (an unlink of a Mac already unlinked refreshes the list).
- A `master_password.same_as_key_existing` text for the unlock (the contract has the account's
  variant only); `signup.code_terms` on the email-link screen says "start the registration again"
  (asked of the server).
- `account.json` names the way this Mac was connected `signedInWith` (`email`/`key`) where §4.2 of
  the contract says `via` (`account`/`key`): the file is the app's alone, the meaning the same; a
  rename with a reading of the old name is a change of its own.
