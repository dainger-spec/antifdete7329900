#!/usr/bin/env python3
"""A profile's data is deleted by one path, and that path is called only from the person's Delete.

    python3 scripts/check_deletion_paths.py [source root]     (default: Sources)
    python3 scripts/check_deletion_paths.py --self-check       (the check against planted lines)

The owner, 3 November, after a person's history, cookies and saved logins were reported gone from
every profile after signing out, into other accounts and back: profiles are this Mac's (CONTRACT §2,
§12); deleting a profile's data is allowed only from the person's explicit action, by one path,
called from that action's handler — and that has to be seen in the code. Not signing out, not
another account, not a sync, not a server's answer.

A virtual machine's profile (docs/VM.md) is held to the same: its disk — a whole macOS — goes only
by `VMCenter.deleteMachineBecauseThePersonAsked`, called from the machines' own Delete confirmation —
or, for every machine at once, by `VMCenter.deleteEverythingBecauseThePersonAsked`, called from the
Disk Space sheet's own "Delete everything" confirmation.

The one path is `ProfileManager.deleteBecauseThePersonAsked`; its one caller is
`AppModel.deleteProfile`, which the Profiles window's Delete confirmation calls (one profile, or
each of several through `deleteProfiles`). A deleted profile's kept folder (R3) goes only by
`AppModel.removeDeletedProfileForGood`, from its own confirmation.

This fails on any call of a deletion primitive — and any call of those handlers — from a function
other than the ones listed in ALLOWED for it, each with why. The self-test's and the scenarios' own
profiles (files in TEST_FILES) are theirs to make and delete.

`--self-check` runs the same scan over planted lines: each primitive called from a function not
allowed (a sign-out, a sync, a server's answer), which must be found, and each allowed call, which
must not: a scan that cannot fail checks nothing.
"""
import os
import re
import sys
import tempfile

# What deletes a profile's data, and the functions (file, function) that may call it, with why.
RULES = [
    ("the one path that deletes a profile's data",
     re.compile(r"\bdeleteBecauseThePersonAsked\s*\("),
     {("PrivacyBrowser/App/AppModel.swift", "deleteProfile"): "the Delete confirmation's handler"}),
    ("deleting a profile's WebKit store",
     re.compile(r"\.deleteData\s*\(\s*profileID"),
     {("PrivacyBrowser/Browser/ProfileManager.swift", "deleteBecauseThePersonAsked"): "the one path"}),
    ("deleting a profile's Safari home",
     re.compile(r"\bsafariHomeVault\.delete\s*\("),
     {("PrivacyBrowser/Browser/ProfileManager.swift", "deleteBecauseThePersonAsked"): "the one path"}),
    ("deleting a profile from the vault",
     re.compile(r"\brepository\.delete\s*\("),
     {("PrivacyBrowser/Browser/ProfileManager.swift", "deleteBecauseThePersonAsked"): "the one path",
      ("BrowserCore/Profiles/ProfileTransfer.swift", "importProfile"):
          "an import that failed takes back the profile it made a moment before, nothing else in it",
      ("BrowserCore/Profiles/ProfileTransfer.swift", "bringBack"):
          "a bring-back that failed takes back the profile it made a moment before; the old folder stays"}),
    ("removing a deleted profile's kept folder for good",
     re.compile(r"\bremoveKeptDeletedProfile\s*\("),
     {("PrivacyBrowser/App/AppModel.swift", "removeDeletedProfileForGood"): "its own confirmation's handler"}),
    ("a profile's folder removed",
     re.compile(r"removeItem\s*\(\s*at:\s*(self\.)?(repository\.)?directory\s*\(\s*for:\s*[\w.]+\s*\)\s*\)"),
     {("BrowserCore/Profiles/ProfileRepository.swift", "delete"): "the one path's end",
      ("BrowserCore/Profiles/ProfileRepository.swift", "create"):
          "a profile whose making failed: the folder it made a moment before, nothing in it yet",
      ("BrowserCore/Profiles/ProfileRepository.swift", "removeOrphanedDirectories"):
          "only folders this Mac's own deletion marked (`deleted-here`), a deletion that stopped part-way",
      ("BrowserCore/Profiles/ProfileRepository.swift", "removeKeptDeletedProfile"): "the person's removal for good"}),
    ("the Delete's handler called",
     re.compile(r"(^|[^\w])deleteProfile\s*\("),
     {("PrivacyBrowser/UI/ProfileListView.swift", "body"): "the Delete confirmation",
      ("PrivacyBrowser/App/AppModel+Proxies.swift", "deleteProfiles"): "each of the several the person confirmed"}),
    ("the several profiles' Delete called",
     re.compile(r"(^|[^\w])deleteProfiles\s*\("),
     {("PrivacyBrowser/UI/ProfileListView.swift", "body"): "the Delete confirmation for several"}),
    ("the kept folder's removal called",
     re.compile(r"(^|[^\w])removeDeletedProfileForGood\s*\("),
     {("PrivacyBrowser/UI/ProfileListView.swift", "body"): "its confirmation"}),
    # A virtual machine's profile (docs/VM.md) is a whole macOS on a disk of its own: the same rule.
    ("the one path that deletes a virtual machine's disk",
     re.compile(r"\bdeleteMachineBecauseThePersonAsked\s*\("),
     {("PrivacyBrowser/UI/VirtualMachinesView.swift", "delete"): "the machines' Delete confirmation's handler",
      ("PrivacyBrowser/App/VirtualMachines/VMCenter.swift", "deleteEverythingBecauseThePersonAsked"):
          "each of the machines, from the person's Delete Everything"}),
    ("the path that deletes every virtual machine",
     re.compile(r"\bdeleteEverythingBecauseThePersonAsked\s*\("),
     {("PrivacyBrowser/UI/VirtualMachinesStorageView.swift", "deleteEverything"):
          "the Disk Space sheet's Delete Everything confirmation's handler"}),
    ("the virtual machines' library removed",
     re.compile(r"removeItem\s*\(\s*at:\s*(self\.)?library\.(root|machinesDirectory)\b"),
     {("PrivacyBrowser/App/VirtualMachines/VMCenter.swift", "deleteEverythingBecauseThePersonAsked"): "the one path"}),
    ("a virtual machine's folder removed",
     re.compile(r"removeItem\s*\(\s*at:\s*(self\.)?library\.machineDirectory\s*\("),
     {("PrivacyBrowser/App/VirtualMachines/VMCenter.swift", "deleteMachineBecauseThePersonAsked"): "the one path"}),
]

# Files whose own profiles are made and deleted for a check, never the person's.
TEST_FILES = {
    "PrivacyBrowser/App/SelfTest.swift",
    "PrivacyBrowser/App/SiteCapture.swift",
    "PrivacyBrowser/App/Account/AccountSwitchScenario.swift",
}

FUNC = re.compile(r"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|static|override|final|nonisolated|mutating|@MainActor)\s+)*(?:func\s+(\w+)|var\s+(body)\b)")


def enclosing(lines, index):
    """The name of the function (or `body`) the line at `index` is in: the nearest one above it
    declared with less indentation."""
    indent = len(lines[index]) - len(lines[index].lstrip())
    for above in range(index - 1, -1, -1):
        match = FUNC.match(lines[above])
        if match and len(match.group(1)) < indent:
            return match.group(2) or match.group(3)
    return None


def scan(root):
    """(path, line number, what, function, line) for every call not allowed."""
    found = []
    for directory, _, files in os.walk(root):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            if relative in TEST_FILES:
                continue
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().split("\n")
            for index, line in enumerate(lines):
                code = line.split("//", 1)[0]
                if re.match(r"\s*(public |private |internal |@\w+ )*func ", code):
                    continue  # a declaration, not a call
                for what, pattern, allowed in RULES:
                    if pattern.search(code):
                        function = enclosing(lines, index)
                        if (relative, function) not in allowed:
                            found.append((relative, index + 1, what, function, line.strip()))
    return found


def self_check():
    planted_bad = {
        "PrivacyBrowser/App/Account/LicenseModel.swift": """
final class LicenseModel {
    func signOut(vault: UnlockedVault?) async {
        await manager.deleteBecauseThePersonAsked(id)
    }
}
""",
        "PrivacyBrowser/App/AppModel.swift": """
final class AppModel {
    func syncNow() async {
        for id in report.deletedProfileIDs {
            await webDataVault.deleteData(profileID: id)
        }
    }
    func deleteProfile(_ id: UUID) async {
        await perform { try await self.manager?.deleteBecauseThePersonAsked(id) }
    }
}
""",
        "PrivacyBrowser/Browser/ProfileManager.swift": """
final class ProfileManager {
    func accountChanged() {
        safariHomeVault.delete(profileID: id)
        try repository.delete(id)
    }
    func deleteBecauseThePersonAsked(_ id: UUID) async throws {
        await webDataVault.deleteData(profileID: id)
        safariHomeVault.delete(profileID: id)
        try repository.delete(id)
    }
}
""",
        "BrowserCore/Profiles/ProfileRepository.swift": """
public final class ProfileRepository {
    public func wipe(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }
    public func delete(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: directory(for: id))
    }
}
""",
        "PrivacyBrowser/App/Account/AccountViews.swift": """
struct AccountView: View {
    func signedInAsAnother() {
        Task { await model.deleteProfiles(ids) }
        model.removeDeletedProfileForGood(id)
    }
}
""",
        "PrivacyBrowser/App/VirtualMachines/VMCenter.swift": """
final class VMCenter {
    func stopAll() async {
        try? FileManager.default.removeItem(at: library.machineDirectory(for: id))
    }
    func deleteMachineBecauseThePersonAsked(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: library.machineDirectory(for: id))
    }
}
""",
        "PrivacyBrowser/UI/VirtualMachinesView.swift": """
struct VirtualMachinesScreen: View {
    private func signedOut() {
        try? center.deleteMachineBecauseThePersonAsked(profile.id)
    }
    private func delete(_ profile: VMProfile) {
        try center.deleteMachineBecauseThePersonAsked(profile.id)
    }
}
""",
        "PrivacyBrowser/UI/VirtualMachinesStorageView.swift": """
struct VMStorageView: View {
    private func planEnded() {
        try? center.deleteEverythingBecauseThePersonAsked()
    }
    private func deleteEverything() {
        try center.deleteEverythingBecauseThePersonAsked()
    }
}
""",
        "PrivacyBrowser/App/VirtualMachines/VMHelperProcess.swift": """
final class VMHelperProcess {
    func ended(status: Int32) {
        try? FileManager.default.removeItem(at: library.root)
    }
}
""",
    }
    expected = {
        ("PrivacyBrowser/App/Account/LicenseModel.swift", "signOut"),
        ("PrivacyBrowser/App/AppModel.swift", "syncNow"),
        ("PrivacyBrowser/Browser/ProfileManager.swift", "accountChanged"),
        ("BrowserCore/Profiles/ProfileRepository.swift", "wipe"),
        ("PrivacyBrowser/App/Account/AccountViews.swift", "signedInAsAnother"),
        ("PrivacyBrowser/App/VirtualMachines/VMCenter.swift", "stopAll"),
        ("PrivacyBrowser/UI/VirtualMachinesView.swift", "signedOut"),
        ("PrivacyBrowser/UI/VirtualMachinesStorageView.swift", "planEnded"),
        ("PrivacyBrowser/App/VirtualMachines/VMHelperProcess.swift", "ended"),
    }
    with tempfile.TemporaryDirectory() as root:
        for relative, text in planted_bad.items():
            path = os.path.join(root, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as handle:
                handle.write(text)
        found = scan(root)
    places = {(path, function) for path, _, _, function, _ in found}
    missed = expected - places
    wrong = places - expected
    counts = {}
    for path, _, _, function, _ in found:
        counts[(path, function)] = counts.get((path, function), 0) + 1
    if missed or wrong or counts.get(("PrivacyBrowser/Browser/ProfileManager.swift", "accountChanged")) != 2 \
            or counts.get(("PrivacyBrowser/App/Account/AccountViews.swift", "signedInAsAnother")) != 2:
        print("deletion paths self-check: FAILED — planted calls missed: "
              f"{sorted(missed)}; allowed ones flagged: {sorted(wrong)}; counts {counts}")
        return 1
    print(f"deletion paths self-check: every planted call from a sign-out, a sync or another account found "
          f"({len(found)}), no allowed one flagged")
    return 0


def main():
    if "--self-check" in sys.argv[1:]:
        return self_check()
    root = next((argument for argument in sys.argv[1:] if not argument.startswith("-")), "Sources")
    found = scan(root)
    for path, number, what, function, line in found:
        print(f"{os.path.join(root, path)}:{number}: {what} from {function or 'outside any function'}(), "
              f"which is not the person's Delete: {line}")
    if found:
        print(f"deletion paths: {len(found)} call(s) outside the one path — a profile's data goes only by the "
              "person's own Delete (ProfileManager.deleteBecauseThePersonAsked, from AppModel.deleteProfile)")
        return 1
    print("deletion paths: a profile's data is deleted by one path (ProfileManager.deleteBecauseThePersonAsked), "
          "called only from the person's Delete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
