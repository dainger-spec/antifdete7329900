# The licensing client

The app's side of the account server's contract (`dainger-spec/lumen-api-server`,
`docs/CONTRACT.md`, read on 1 November at 24ceb5e). The contract is the source; this page says
where each part of it lives here and what checks it.

## Two ways in, one mechanism

- **Email and password** (§5.2): `POST /v1/auth/login` gives a session; the session activates this
  Mac (§6.1).
- **A key** — a purchase without registration, `LMK-XXXX-…` (the server's `internal/ident`,
  contract §18 when it is written): read here before anything is sent — case and hyphens do not
  matter, I/L read as 1 and O as 0, a wrong character or a swap of two is caught by the two check
  characters (CRC-10) — then it activates this Mac by itself, in the request's body
  (`AccountAPI.activate`, `.key`). A purchase code (`LPC-`) or an invoice number (`LMN-`) typed
  there is named as such; Cyrillic letters say the keyboard is in Russian.

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
  themselves (`AccountKey`, `ServerToken`: `LMK-…`, `lmd_…` in any interpolation, dump or mirror).
- **On disk only inside the vault**: `account-key.bin`, AES-GCM under `HKDF(VMK, "account-key")`,
  this Mac's, never synced (`AccountKeyVault`). A profile's own process, opened with a grant,
  cannot derive the key. Never in `account.json`, the defaults, a log or a report.
- **Its text comes out in four places** — the key's own type, the request that carries it, the
  vault's file, the token in `Authorization` — and `scripts/check_account_key.py` fails CI on any
  other `unredacted()` (its `--self-check` plants four forbidden calls and must find them).
- **Behind that**, `LogRedaction` masks license codes and tokens in exception reasons.
- **Checked by** the self-test: `account.json`, the vault's file, the defaults and the diagnostics
  ZIP searched for every form of the key and for the device's token, the search first shown to
  find a key planted in a ZIP of its own.

What it cannot promise: the system's crash report keeps an uncaught exception's reason as it was;
the app never puts the key in one (its type never says itself), but a crash report is the
system's, not rewritten here.

`account.json` (§4.2): the device's token, the document, the clock's floor — owner-only, beside the
vault, read before it is unlocked; a newer format is refused and never written over, an unreadable
one moved aside.

## Screens

The design's "Аккаунт" boards (`docs/DESIGN.md`), in `UI/AccountViews.swift`:

- **Sign in** (`SignInFlow`): email and password, or key; "Forgot password?" opens the site's
  reset; "Lost your key?" says why no letter can bring it back and what can; "Create account"
  opens the site — no registration and no payment in the app.
- **Connect this Mac**: the label, `activation.server_learns`, all places taken → unlink one here.
- **First launch**: sign in → connect → master password (the owner's order); the master password
  equal to the account's is refused, compared directly as an HMAC under a one-time key — never a key
  derived from it (§10.1, the owner's rule).
- **Settings › Account**: the plan and until when, how long without the server, this Mac's code,
  sign out (`signout.consequences`), the license's Macs with this one marked and the others
  unlinkable (`unlink.consequences`), the site.
- **Banners** above the profiles in §8.5's order, the period's end warned a week and a day before;
  **the sidebar's line** about the rights; a profile that may only be exported says so in its row
  and does not open — the rule, said as a rule.

## Builds

A release carries `PBAccountServerURL` (https), `PBAccountSiteURL` and `PBEntitlementPublicKeys`
(`scripts/build-app.sh` from `scripts/release.sh`), and nothing in the environment changes them.
`--release-check` refuses a build without a server, without keys, or trusting the development
server's key (`445c6300da0205b1`); CI checks that a development build fails it. A development build
has no licensing unless the self-test gives it a server and keys through the environment.

## Open

- Linking an email to a key's account (asked of the server; no address in the contract yet).
- The contract's texts for keys (§18), and for export-only after the grace ran out (asked).
- UI snapshots of the account screens (before the redesign is merged).
