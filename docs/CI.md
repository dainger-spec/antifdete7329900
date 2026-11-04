# CI: the fast pipeline and the full one

The owner, 3 November: run 682 (33a4c83) took 77 minutes on macOS 26, 29 on macOS 27 and 3½ on
Linux; every commit ran twice (a push and a pull_request of the same head: 674/675, 678/679,
682/683); and more than half of the steps were measurements that could not fail the build.

## Two pipelines

| | `.github/workflows/ci.yml` — fast | `.github/workflows/full.yml` — full |
|---|---|---|
| runs | on every push to a branch, once | daily (01:41 UTC), on request (Actions › CI — full › Run workflow), on a pushed tag `full/…` |
| holds | the checks whose failure means "do not release", and nothing that cannot fail | every check, measurement, inventory and snapshot, on macOS 26 and 27 — the fast pipeline's checks included |
| aim | 20 minutes: three macOS runners and two Linux ones side by side | as long as it takes |

**One trigger.** A push runs every branch of this repository once; the pull_request run was the
same commit a second time, and pull requests here come only from these branches.

**The rule.** A step is in the fast pipeline only if its failure means "do not release". A step that
cannot fail (continue-on-error, "a measurement", "reported", "an inventory", "never fails the
build") is a measurement: its place is the full pipeline. A check that can stop a release but does
not fit in 20 minutes is in the full one too, which a release needs anyway.
`scripts/check_ci_split.py` keeps both rules: the fast pipeline on push only, with no step that
cannot fail and none named as a measurement; the full one never on a branch's push or a pull request,
and running every script the fast one runs. It fails on its planted faults first.

## Where each check is

Fast (`ci.yml`):

- Linux: the core tests (swift-crypto), the JavaScript shims under V8 and JavaScriptCore, and the
  checks of the code — localization complete, log privacy, no quiet skip in the self-test,
  SystemOpen only, deletion paths, the account's key, a release's publication, download.json, the
  site's minimum macOS, no secret in the repository, this split, the release gate's own tests.
- macOS 26, one runner: `swift test`; both builds; the release's dry run; the release gate where
  Safari's chrome is not hosted; download.json and the minimum macOS; the release gate reads every
  line; a relaxation beside the network extension's right is refused; the interface's language at
  start; a profile's data through signing out, into other accounts and back (with its control);
  the App Sandbox container migration.
- macOS 26, two runners, one per build: the self-test against real WebKit — sandboxed, and
  unsandboxed inside its packet capture and file trace — and with the unsandboxed build: the crash
  reports (and their control), the account's key in a crash report, Safari's private classes the
  hosted chrome relies on, the fingerprint surface against this Mac's Safari, the leak check (QUIC,
  WebRTC), the network guard's probe (and its control), `--guard-diagnose`.

Full only (`full.yml`), and why:

| check | why not fast |
|---|---|
| the license's renewals (9.9 min) | can stop a release; does not fit in 20 min |
| the product's rename (9.3 min) | can stop a release; does not fit |
| updates end to end (3.4 min), its result | can stop a release; does not fit |
| Safari's menu walk (4.5 min), macOS 26 and 27 | an inventory compared with docs/menu-walk |
| UI snapshots (5 min), the Settings window's picture | snapshots for design review |
| the disk image's window, the download control | the image's layout never stops a release (the owner) |
| what sites see (three), live fingerprinting pages | measured against this Mac's Safari |
| Apple Pay, Payment Request and Web Push (4.2 min) | a measurement and its comparisons |
| what follows the SDK (5.4 min), the AIA variants, SwiftPM's SDK, WebKit's features as Safari's | measurements |
| Safari's paths, history, default-browser question, Export › Bookmarks, chrome inventory | measurements |
| the account's keychain before and after the run | a measurement around the whole run |
| a jump to a fragment, the window's properties by name | measurements |
| macOS 27, the whole job (29 min) | the newest macOS, a preview image |

## Before a release

`scripts/release.sh` (step 0b) releases only a commit the full pipeline passed: anything signed with
a Developer ID or published needs a tree with no change beside the commit and a run of `full.yml` on
exactly that commit that completed with success — `scripts/full_run_gate.py` asks GitHub, before
anything is built. A run on another commit, however close, does not count; a run still going, failed
or cancelled does not; GitHub not answering is not a yes. A dry run says what it would need, in its
DRY RUN block. Start a full run on the commit to release with

    git tag full/<sha12> <sha> && git push origin full/<sha12>

(`scripts/test_full_run_gate.sh`: the gate against saved answers of GitHub's API — a passed run of
the commit, a failed attempt then a passed one: yes; none, running, failed, cancelled, another
commit, the fast pipeline's run, an answer that is not GitHub's, a short SHA: no.)

GitHub starts a schedule, and offers Run workflow, only for a workflow the repository's default
branch has, and a schedule runs that branch's code. The default branch could not be changed (GitHub:
"Could not change default branch", the owner, 4 November), so the same `full.yml` is also on it
(`claude/macos-privacy-browser-prototype-0ns2oj`, one commit, that file alone). On a schedule only its
job `nightly` runs: it starts the pipeline on `claude/redesign` (a workflow_dispatch made with the
run's own token starts a run), and that run checks the branch's newest commit under its own SHA —
the one release.sh's gate looks for. Every other job is skipped on a schedule. Run workflow (choose
`claude/redesign`) and a pushed tag `full/…` run the checks on the commit asked for. When `full.yml`
changes here, the default branch's copy is brought to the same text.
