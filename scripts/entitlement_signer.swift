// A key of rights made up for a check, and the documents it signs: what the account server does
// (its `docs/CONTRACT.md` §7), for scripts/license_renewal_check.py's stand-in server only. The key
// is made on the runner for one run and never leaves it; the app under check trusts it through
// PB_ENTITLEMENT_PUBLIC_KEYS, which only a development build reads (AccountConfiguration).
//
//   swiftc -O scripts/entitlement_signer.swift -o build/signer
//   build/signer keygen <private key file>      prints {"keyID": …, "publicKey": <base64 of the raw key>}
//   build/signer sign <private key file> < payload   prints the base64 Ed25519 signature of stdin's bytes
import CryptoKit
import Foundation

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: signer keygen|sign <private key file>") }
let path = arguments[2]

switch arguments[1] {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    let raw = key.publicKey.rawRepresentation
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("could not write \(path)") }
    // The app's keyID: the first 8 bytes of the SHA-256 of the raw public key, lowercase hex
    // (EntitlementKeys.keyID(of:)).
    let keyID = SHA256.hash(data: raw).prefix(8).map { String(format: "%02x", $0) }.joined()
    print("{\"keyID\": \"\(keyID)\", \"publicKey\": \"\(raw.base64EncodedString())\"}")
case "sign":
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("no key at \(path)") }
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    guard let signature = try? key.signature(for: payload) else { fail("could not sign") }
    print(signature.base64EncodedString())
default:
    fail("usage: signer keygen|sign <private key file>")
}
