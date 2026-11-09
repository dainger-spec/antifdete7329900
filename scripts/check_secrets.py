#!/usr/bin/env python3
"""No secret of a release is in the repository: one that is fails the release.

    python3 scripts/check_secrets.py [repository]      (default: this one)
    python3 scripts/check_secrets.py --self-check       (the scan against planted secrets)

The repository is public on GitHub. The keys a release runs with come from the environment of the
run only (docs/UPDATES.md §6): R2's (R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY) and the update key (the
file UPDATE_KEY_FILE names). scripts/release.sh runs this before it builds anything, and any finding
stops the release. It searches:

- for each of those values that the environment holds, byte for byte;
- for whatever is shaped like R2's keys, whatever its value: one of R2's variables, or an
  aws_*_key setting, given 32 to 64 hex digits, and an "ID:SECRET" pair of R2's shape (32 and 64
  hex digits). So an old key, or one never put in this environment, is caught too; CI runs this
  part on every push, where no key is set;

in every file of every commit that any ref reaches (branches, tags, remote branches, the stash), in
the index, and in what `git add -A` would take next: files .gitignore does not exclude that are not
tracked yet, and tracked files changed since their commit. A file .gitignore excludes is not
searched: it is where such keys may live.

A finding names the secret, the commit (or the index, or the file) and the line; the value itself
is never printed. A finding in a commit that was pushed means the key is public: rotate it, then
take it out of the history.

`--self-check` plants each kind of secret in a repository of its own — in a commit a later one
deletes, on a branch not checked out, in the index, in an untracked file, in a changed tracked file,
in an ignored one — next to look-alikes (a SHA-256, documented `R2_SECRET_ACCESS_KEY=…` lines), and
fails unless every planted one is found, the ignored one and the look-alikes are not, and no value
appears in the output: a scan that cannot fail checks nothing.
"""
import os
import re
import subprocess
import sys
import tempfile
import threading

# Values shorter than this are not keys: searching for them would find them everywhere.
SHORTEST_VALUE = 16
# Patterns are looked for in text only (no NUL in a file's first 8000 bytes, as git decides) and in
# files up to this size; the values are looked for in every file, whatever it holds.
LARGEST_TEXT = 20 * 1000 * 1000

HEX = rb"[0-9A-Fa-f]"
PATTERNS = [
    ("one of R2's keys written into its variable",
     re.compile(rb"R2_(?:SECRET_ACCESS_KEY|ACCESS_KEY_ID)[\"']?\s*[:=]\s*[\"']?" + HEX + rb"{32,64}(?!" + HEX + rb")")),
    ("an S3 key written into an aws_*_key setting",
     re.compile(rb"(?i)aws_(?:secret_access_key|access_key_id)[\"']?\s*[:=]\s*[\"']?[0-9a-f]{32,64}(?![0-9a-f])")),
    ("a key pair of R2's shape (ID:SECRET)",
     re.compile(rb"(?<!" + HEX + rb")[0-9a-f]{32}:[0-9a-f]{64}(?!" + HEX + rb")")),
]


def secrets_from_environment(environment):
    """(name, value) for each release secret the environment holds."""
    found = []
    for name in ("R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"):
        value = environment.get(name, "").strip()
        if not value:
            continue
        if len(value) < SHORTEST_VALUE:
            raise SystemExit(f"error: {name} holds {len(value)} characters: no key is that short, and it would be found everywhere")
        found.append((name, value.encode()))
    key_file = environment.get("UPDATE_KEY_FILE", "").strip()
    if key_file:
        with open(key_file, "rb") as handle:
            value = handle.read().strip()
        if len(value) < SHORTEST_VALUE:
            raise SystemExit(f"error: UPDATE_KEY_FILE ({key_file}) holds no key")
        found.append(("the update key (the file UPDATE_KEY_FILE names)", value))
    return found


def git(repository, *arguments):
    return subprocess.run(["git", "-C", repository, *arguments], capture_output=True, check=True).stdout


def is_text(content):
    return b"\0" not in content[:8000] and len(content) <= LARGEST_TEXT


def findings_in(content, secrets):
    """(what, line) for every secret value and every pattern in content."""
    found = []
    for name, value in secrets:
        at = content.find(value)
        if at >= 0:
            found.append((name, content.count(b"\n", 0, at) + 1))
    if is_text(content):
        for name, pattern in PATTERNS:
            match = pattern.search(content)
            if match:
                found.append((name, content.count(b"\n", 0, match.start()) + 1))
    return found


def blobs_of_history(repository):
    """{blob: first path seen} for every file of every commit any ref reaches, and of the index."""
    listing = git(repository, "rev-list", "--objects", "--all", "--indexed-objects")
    candidates = {}
    for line in listing.splitlines():
        name, _, path = line.partition(b" ")
        if name and name not in candidates:
            candidates[name] = path
    if not candidates:
        return {}
    kinds = subprocess.run(["git", "-C", repository, "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                           input=b"\n".join(candidates) + b"\n", capture_output=True, check=True).stdout
    blobs = {}
    for line in kinds.splitlines():
        name, _, kind = line.partition(b" ")
        if kind == b"blob":
            blobs[name] = candidates[name]
    return blobs


def read_blobs(repository, names):
    """(name, content) for each blob, read through one `git cat-file --batch`."""
    process = subprocess.Popen(["git", "-C", repository, "cat-file", "--batch"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def feed():
        for name in names:
            process.stdin.write(name + b"\n")
        process.stdin.close()

    writer = threading.Thread(target=feed)
    writer.start()
    for _ in names:
        header = process.stdout.readline().split()
        if len(header) != 3:
            raise SystemExit(f"error: git cat-file answered {b' '.join(header).decode(errors='replace')!r}")
        size = int(header[2])
        content = process.stdout.read(size)
        process.stdout.read(1)  # the newline after each object
        yield header[0], content
    writer.join()
    process.wait()


def commits_with(repository, blob):
    """The commits that add the blob (the first of them is where the secret came in)."""
    log = git(repository, "log", "--all", "--reverse", "--format=%h %s", f"--find-object={blob.decode()}")
    return [line.decode(errors="replace") for line in log.splitlines() if line.strip()]


def working_tree_files(repository):
    """What `git add -A` would take next: untracked files .gitignore does not exclude, and changed
    tracked ones (paths relative to the repository)."""
    untracked = git(repository, "ls-files", "-z", "--others", "--exclude-standard").split(b"\0")
    changed = git(repository, "ls-files", "-z", "--modified").split(b"\0")
    return [("an untracked file", path) for path in untracked if path] + \
           [("a changed tracked file", path) for path in changed if path]


def scan(repository, secrets):
    """Every finding, as a line of text that never holds a value."""
    report = []
    index = set()
    for line in git(repository, "ls-files", "-s", "-z").split(b"\0"):
        if line:
            index.add(line.split(b" ")[1])
    blobs = blobs_of_history(repository)
    for blob, content in read_blobs(repository, list(blobs)):
        found = findings_in(content, secrets)
        if not found:
            continue
        path = blobs[blob].decode(errors="replace")
        commits = commits_with(repository, blob)
        where = []
        if commits:
            more = f" (and {len(commits) - 1} more that add or remove it)" if len(commits) > 1 else ""
            where.append(f"commit {commits[0]}{more}")
        if blob in index:
            where.append("the index")
        for name, line in found:
            report.append(f"{name}: {path} line {line}, in {' and '.join(where) or 'an object no commit names'}")
    root = os.path.abspath(repository)
    for kind, path in working_tree_files(repository):
        full = os.path.join(root, path.decode(errors="surrogateescape"))
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        with open(full, "rb") as handle:
            content = handle.read()
        for name, line in findings_in(content, secrets):
            report.append(f"{name}: {path.decode(errors='replace')} line {line}, in {kind}")
    return report, len(blobs)


def main(repository):
    secrets = secrets_from_environment(os.environ)
    try:
        report, files = scan(repository, secrets)
    except subprocess.CalledProcessError as failure:
        print(f"error: git could not list this repository's history ({' '.join(failure.cmd[3:])}): "
              f"{failure.stderr.decode(errors='replace').strip()} — a release is made from a clone of it", file=sys.stderr)
        return 1
    looked_for = [name for name, _ in secrets] + [f"{len(PATTERNS)} shapes of R2's keys"]
    if report:
        for line in report:
            print(f"SECRET {line}")
        print(f"error: {len(report)} secret(s) of a release written into this repository, which is public. "
              "Rotate any key that was pushed, then take it out of the history; no release until then.", file=sys.stderr)
        return 1
    print(f"check_secrets: none of {', '.join(looked_for)} in any commit ({files} versions of files), "
          "the index or the working tree")
    return 0


def self_check():
    ident = "0f1e2d3c4b5a69788796a5b4c3d2e1f0"
    secret = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9f"
    old_secret = "9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0"
    other_ident = "11112222333344445555666677778888"
    update_key = "dGhpcyBpcyBub3QgYSByZWFsIGtleSwgb25seSBhIHBsYW50ZWQgb25l"
    values = [ident, secret, old_secret, other_ident, update_key]
    with tempfile.TemporaryDirectory() as root:
        repository = os.path.join(root, "repository")
        os.mkdir(repository)
        environment = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "HOME": root,
                       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}

        def run(*arguments):
            subprocess.run(["git", "-C", repository, "-c", "commit.gpgsign=false", *arguments],
                           capture_output=True, check=True, env=environment)

        def write(path, text):
            with open(os.path.join(repository, path), "w") as handle:
                handle.write(text)

        run("init", "-q", "-b", "main")
        write(".gitignore", "secret.env\n")
        # Look-alikes, committed: a SHA-256, the documented forms, an endpoint.
        write("README.md", "sha256 " + "ab" * 32 + "\nR2_SECRET_ACCESS_KEY=… R2_ACCESS_KEY_ID=<id>\n"
              "R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com\nmd5:" + "cd" * 16 + "\n")
        write("tracked.txt", "nothing here\n")
        run("add", "-A")
        run("commit", "-q", "-m", "clean")
        clean, _ = scan(repository, [("R2_SECRET_ACCESS_KEY", secret.encode())])
        if clean:
            print("SELF-CHECK FAILED: findings in a clean repository:", *clean, sep="\n  ")
            return 1
        # 1. The secret in a commit that a later one takes out again.
        write("deploy.sh", f"export R2_SECRET_ACCESS_KEY={secret}\n")
        run("add", "-A")
        run("commit", "-q", "-m", "deploy with the key")
        write("deploy.sh", "export R2_SECRET_ACCESS_KEY=\"$1\"\n")
        run("add", "-A")
        run("commit", "-q", "-m", "the key from the argument")
        # 2. The update key on a branch that is not checked out.
        run("checkout", "-q", "-b", "elsewhere")
        write("update.key", update_key + "\n")
        run("add", "-A")
        run("commit", "-q", "-m", "the update key")
        run("checkout", "-q", "main")
        # 3. The key's id in the index only.
        write("notes.txt", f"id {ident}\n")
        run("add", "notes.txt")
        # 4. An old key in a setting, untracked.
        write("credentials", f"[r2]\naws_secret_access_key = {old_secret}\n")
        # 5. A pair of R2's shape in a tracked file changed since its commit.
        write("tracked.txt", f"curl --user {other_ident}:{old_secret}\n")
        # 6. Ignored: never searched.
        write("secret.env", f"R2_SECRET_ACCESS_KEY={secret}\n")

        key_file = os.path.join(root, "update.key")
        with open(key_file, "w") as handle:
            handle.write(update_key + "\n")
        secrets = secrets_from_environment({"R2_ACCESS_KEY_ID": ident, "R2_SECRET_ACCESS_KEY": secret,
                                            "UPDATE_KEY_FILE": key_file})
        report, _ = scan(repository, secrets)
        text = "\n".join(report)
        expected = [
            ("R2_SECRET_ACCESS_KEY: deploy.sh line 1, in commit", "the key in a commit taken out later"),
            ("one of R2's keys written into its variable: deploy.sh line 1, in commit", "R2's variable with a key in history"),
            ("the update key (the file UPDATE_KEY_FILE names): update.key line 1, in commit", "the update key on another branch"),
            ("R2_ACCESS_KEY_ID: notes.txt line 1, in the index", "the key's id in the index"),
            ("an S3 key written into an aws_*_key setting: credentials line 2, in an untracked file", "an old key in an untracked file"),
            ("a key pair of R2's shape (ID:SECRET): tracked.txt line 1, in a changed tracked file", "a key pair in a changed tracked file"),
        ]
        failures = [f"not found: {why}" for line, why in expected if line not in text]
        failures += [f"found though ignored: {line}" for line in report if "secret.env" in line]
        failures += [f"found a look-alike: {line}" for line in report if "README.md" in line]
        failures += [f"a value is in the output: {value[:6]}…" for value in values if value in text]
        if len(report) != len(expected):
            failures.append(f"{len(report)} findings, {len(expected)} planted: " + "; ".join(report))
        if failures:
            print("SELF-CHECK FAILED:", *failures, sep="\n  ")
            return 1
    print(f"SELF-CHECK PASSED: {len(expected)} planted secrets found, the ignored one and the look-alikes not, no value printed")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-check"]:
        sys.exit(self_check())
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))
