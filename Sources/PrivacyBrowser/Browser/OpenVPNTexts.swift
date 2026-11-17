import BrowserCore
import Foundation

/// What is said of an OpenVPN configuration, in the person's language.
enum OpenVPNTexts {
    static func problem(_ problem: OpenVPNConfigProblem) -> String {
        switch problem {
        case .empty: return L("openvpn.problem.empty")
        case .tooLarge: return L("openvpn.problem.tooLarge")
        case .notText: return L("openvpn.problem.notText")
        case .malformed(let line): return String(format: L("openvpn.problem.malformed"), line)
        case .unterminatedBlock(let name): return String(format: L("openvpn.problem.unterminatedBlock"), name)
        case .unknown(let directive, _): return String(format: L("openvpn.problem.unknown"), directive)
        case .unsupported(let directive, let reason):
            return String(format: L("openvpn.problem.unsupported"), directive) + " " + L("openvpn.reason.\(reason.rawValue)")
        case .fileReference(let directive, let file): return String(format: L("openvpn.problem.fileReference"), directive, file)
        case .missing(let what): return String(format: L("openvpn.problem.missing"), what)
        case .noRemote: return L("openvpn.problem.noRemote")
        case .invalidRemote(let text): return String(format: L("openvpn.problem.invalidRemote"), text)
        case .encryptedKey: return L("openvpn.problem.encryptedKey")
        }
    }

    static func notice(_ notice: OpenVPNConfiguration.Notice) -> String {
        switch notice {
        case .leftOut(let directive): return String(format: L("openvpn.notice.leftOut"), directive)
        case .nsCertType: return L("openvpn.notice.nsCertType")
        case .cipherDropped(let cipher): return String(format: L("openvpn.notice.cipherDropped"), cipher)
        case .openSSLCipherList: return L("openvpn.notice.openSSLCipherList")
        case .credentialsTaken: return L("openvpn.notice.credentialsTaken")
        }
    }
}
