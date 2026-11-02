# The licensing client

The app's side of the account server's contract (`dainger-spec/lumen-api-server`,
`docs/CONTRACT.md`, read on 1 November at 24ceb5e). The contract is the source; this page says
where each part of it lives here and what checks it.

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

- The contract's texts for export-only after the grace ran out (asked).
- A `master_password.same_as_key_existing` text for the unlock (the contract has the account's
  variant only); `signup.code_terms` on the email-link screen says "start the registration again"
  (asked of the server).
- `account.json` names the way this Mac was connected `signedInWith` (`email`/`key`) where §4.2 of
  the contract says `via` (`account`/`key`): the file is the app's alone, the meaning the same; a
  rename with a reading of the old name is a change of its own.
