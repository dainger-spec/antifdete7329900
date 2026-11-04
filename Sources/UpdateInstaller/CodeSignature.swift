import Foundation
import Security

/// The code signature of an app bundle, checked the strict way (docs/UPDATES.md §2): every
/// architecture, nested code included, and a requirement — the bundle identifier always, and with a
/// Team ID, an Apple-issued certificate of that team.
public enum CodeSignature {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Throws unless `bundle` is signed, its signature validates, and it satisfies
    /// `identifier "<identifier>"` — and, with a `teamID`, `anchor apple generic and
    /// certificate leaf[subject.OU] = "<teamID>"`.
    public static func check(_ bundle: URL, identifier: String, teamID: String?) throws {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, SecCSFlags(rawValue: 0), &code)
        guard created == errSecSuccess, let code else {
            throw Failure(description: "\(bundle.lastPathComponent): no code object (OSStatus \(created))")
        }
        var text = "identifier \"\(identifier)\""
        if let teamID { text += " and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" }
        var requirement: SecRequirement?
        let parsed = SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &requirement)
        guard parsed == errSecSuccess, let requirement else {
            throw Failure(description: "requirement \(text) (OSStatus \(parsed))")
        }
        let flags = SecCSFlags(rawValue: UInt32(truncatingIfNeeded: kSecCSCheckAllArchitectures)
            | UInt32(truncatingIfNeeded: kSecCSCheckNestedCode) | UInt32(truncatingIfNeeded: kSecCSStrictValidate))
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "OSStatus \(status)"
            throw Failure(description: "\(bundle.lastPathComponent): the signature does not hold (\(reason))")
        }
    }
}
