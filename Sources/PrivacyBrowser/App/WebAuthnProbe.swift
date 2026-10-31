import AppKit
import AuthenticationServices
import Foundation
import ObjectiveC
import WebKit

/// Measurement only, never merged (the owner's questions of 1 November): where a Web Authentication
/// call goes in this process, whether it can be taken here before the system shows its sheet, and
/// what the page gets when it is.
///
///   * The page marks the beginning and end of each step through a script message handler only
///     the parity variant's view has (`pbmark`). Between the two, libobjc logs every Objective-C
///     message this process sends (`instrumentObjcMessageSends`, /tmp/msgSends-<pid>); after the
///     run, the ones about authentication are printed, step by step.
///   * The methods of AuthenticationServices' and WebKit's classes that a ceremony could pass
///     through are recorded as they are called, with their arguments' classes and a block's
///     signature. On ASAuthorizationController, the page's mode decides: "pass" lets WebKit's call
///     through; "cancel" holds it two seconds and then tells the controller's delegate the user
///     cancelled, as AuthenticationServices tells it; "hold" holds it until the page aborts.
@MainActor
final class WebAuthnProbe: NSObject, WKScriptMessageHandler {
    static let shared = WebAuthnProbe()

    private var segments: [(step: String, from: UInt64, to: UInt64)] = []
    private var from: UInt64 = 0
    private let tracePath = "/tmp/msgSends-\(getpid())"
    private typealias Instrument = @convention(c) (Bool) -> Void
    private lazy var instrument: Instrument? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "instrumentObjcMessageSends") else { return nil }
        return unsafeBitCast(symbol, to: Instrument.self)
    }()

    private static func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let step = body["step"] as? String,
              let phase = body["phase"] as? String else { return }
        if phase == "begin" {
            WebAuthnIntercept.mode = body["mode"] as? String ?? "pass"
            from = fileSize()
            instrument?(true)
            print("PAYMENTS-CHECK parity mark: begin \(step) (mode \(WebAuthnIntercept.mode)) at \(Self.stamp())")
        } else {
            instrument?(false)
            segments.append((step, from, fileSize()))
            print("PAYMENTS-CHECK parity mark: end \(step) at \(Self.stamp()): \(body["result"] as? String ?? "")")
            WebAuthnIntercept.mode = "pass"
        }
    }

    private func fileSize() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: tracePath))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The messages about authentication of each step, deduplicated, in the order they first came.
    func printTrace() {
        guard instrument != nil else {
            print("PAYMENTS-CHECK parity trace: this libobjc has no instrumentObjcMessageSends")
            return
        }
        guard let data = FileManager.default.contents(atPath: tracePath) else {
            print("PAYMENTS-CHECK parity trace: nothing at \(tracePath)")
            return
        }
        print("PAYMENTS-CHECK parity trace: \(data.count) bytes at \(tracePath)")
        let pattern = try? NSRegularExpression(pattern: "^[+-] (_?ASC?[A-Z]|_?LA[A-Z]|_?SF[A-Z])|Authenticat|Authoriz|Credential|Passkey|PublicKey|WebAuthn|Assertion|Registration")
        for segment in segments {
            let lower = Int(min(segment.from, UInt64(data.count))), upper = Int(min(segment.to, UInt64(data.count)))
            guard upper > lower else {
                print("PAYMENTS-CHECK parity trace \(segment.step): no message")
                continue
            }
            let text = String(decoding: data[lower..<upper], as: UTF8.self)
            var counts: [String: Int] = [:]
            var order: [String] = []
            var total = 0
            for line in text.split(separator: "\n") {
                total += 1
                let string = String(line)
                guard pattern?.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else { continue }
                if counts[string] == nil { order.append(string) }
                counts[string, default: 0] += 1
            }
            print("PAYMENTS-CHECK parity trace \(segment.step): \(total) messages, \(order.count) about authentication")
            for line in order.prefix(160) {
                print("PAYMENTS-CHECK parity trace \(segment.step):   \(counts[line] ?? 0)x \(line)")
            }
        }
    }

}

/// Measurement only, never merged: the recording, and on ASAuthorizationController the taking, of
/// the calls a ceremony could pass through in this process (see `WebAuthnProbe`). Outside the main
/// actor: those calls come on any thread.
enum WebAuthnIntercept {
    /// The page's mode for the step under way: "pass", "cancel" or "hold".
    nonisolated(unsafe) static var mode = "pass"

    private static func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    /// The classes a ceremony could pass through in this process, and the words of the methods
    /// recorded on them.
    private static let classes = ["ASAuthorizationController", "ASCAgentProxy", "ASCWebKitSPISupport", "_ASCWebKitSPISupport",
                                  "ASCAuthorizationRemotePresenter", "ASCAuthorizationPresenter",
                                  "ASAuthorizationWebBrowserPublicKeyCredentialManager", "ASCPublicKeyCredentialManager",
                                  "_WKWebAuthenticationPanel", "_WKASDelegate", "WKASCAuthorizationPresenterDelegate",
                                  "ASCCredentialRequestContext"]
    private static let words = ["perform", "present", "cancel", "available", "should", "passkey", "credential", "authoriz",
                                "conditional", "request", "complete", "handle", "dismiss", "begin", "start", "allowed"]
    private static let skipped: Set<String> = ["dealloc", ".cxx_destruct", "retain", "release", "autorelease", "class",
                                               "respondsToSelector:", "isKindOfClass:", "methodSignatureForSelector:",
                                               "forwardInvocation:", "description", "debugDescription", "hash", "isEqual:"]

    typealias Raw = UnsafeRawPointer?

    static func install() {
        for path in ["/System/Library/Frameworks/AuthenticationServices.framework/AuthenticationServices",
                     "/System/Library/PrivateFrameworks/AuthenticationServicesCore.framework/AuthenticationServicesCore"] {
            _ = dlopen(path, RTLD_NOW)
        }
        for name in classes {
            guard let type: AnyClass = NSClassFromString(name) else {
                print("PAYMENTS-CHECK parity intercept: no class \(name) in this process")
                continue
            }
            var recorded: [String] = []
            let owners: [(AnyClass?, Bool)] = [(type, false), (object_getClass(type), true)]
            for (owner, meta) in owners {
                guard let owner else { continue }
                var count: UInt32 = 0
                guard let methods = class_copyMethodList(owner, &count) else { continue }
                for index in 0..<Int(count) {
                    if let selector = record(methods[index], of: name, meta: meta) { recorded.append(selector) }
                }
                free(methods)
            }
            print("PAYMENTS-CHECK parity intercept: \(name): recording \(recorded.count) method(s): \(recorded.joined(separator: " "))")
        }
    }

    /// Whether a method's arguments and result all travel in integer registers (objects, blocks,
    /// selectors, pointers, integers): only such a method is recorded, through one trampoline.
    private static func simple(_ method: Method) -> Bool {
        let count = Int(method_getNumberOfArguments(method))
        guard count <= 6 else { return false }
        func ok(_ type: String, result: Bool) -> Bool {
            let code = type.drop { "rnNoORV".contains($0) }.first ?? "?"
            return "@#:*^qQiIlLsScCB".contains(code) || (result && code == "v")
        }
        let returnType = method_copyReturnType(method)
        let returned = String(cString: returnType)
        free(returnType)
        guard ok(returned, result: true) else { return false }
        for index in 2..<count {
            guard let type = method_copyArgumentType(method, UInt32(index)) else { return false }
            defer { free(type) }
            guard ok(String(cString: type), result: false) else { return false }
        }
        return true
    }

    private static func record(_ method: Method, of className: String, meta: Bool) -> String? {
        let selector = method_getName(method)
        let name = NSStringFromSelector(selector)
        let lower = name.lowercased()
        guard !skipped.contains(name), !name.hasPrefix("init"), words.contains(where: { lower.contains($0) }), simple(method) else {
            return nil
        }
        let argumentCount = Int(method_getNumberOfArguments(method)) - 2
        var types: [String] = []
        for index in 0..<argumentCount {
            if let type = method_copyArgumentType(method, UInt32(index + 2)) {
                types.append(String(cString: type))
                free(type)
            }
        }
        typealias Original = @convention(c) (UnsafeRawPointer, Selector, Raw, Raw, Raw, Raw) -> Raw
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let label = "\(meta ? "+" : "-")[\(className) \(name)]"
        let takes = className == "ASAuthorizationController" && !meta && name.hasPrefix("perform")
        let block: @convention(block) (UnsafeRawPointer, Raw, Raw, Raw, Raw) -> Raw = { receiver, a, b, c, d in
            let arguments = [a, b, c, d].prefix(argumentCount)
            let described = zip(types, arguments).map { describe(type: $0.0, value: $0.1) }
            print("PAYMENTS-CHECK parity intercept: \(stamp()) \(label) (\(describeObject(receiver))) "
                  + "args: \(described.joined(separator: "; ")); mode \(mode)")
            if takes, mode == "cancel" || mode == "hold" {
                let controller = Unmanaged<NSObject>.fromOpaque(receiver).takeUnretainedValue()
                if mode == "cancel" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let delegate = controller.value(forKey: "delegate") as? NSObject
                        let error = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue)
                        let report = NSSelectorFromString("authorizationController:didCompleteWithError:")
                        if let delegate, delegate.responds(to: report) {
                            _ = delegate.perform(report, with: controller, with: error)
                            print("PAYMENTS-CHECK parity intercept: \(stamp()) held 2 s, then told \(type(of: delegate)) the user cancelled")
                        } else {
                            print("PAYMENTS-CHECK parity intercept: \(stamp()) held 2 s; the controller's delegate (\(String(describing: delegate))) takes no completion")
                        }
                    }
                } else {
                    print("PAYMENTS-CHECK parity intercept: \(stamp()) held, never answered")
                }
                return nil
            }
            let result = original(receiver, selector, a, b, c, d)
            return result
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return name
    }

    private static func describeObject(_ pointer: UnsafeRawPointer) -> String {
        guard let type = object_getClass(Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()) else { return "?" }
        return NSStringFromClass(type)
    }

    private static func describe(type: String, value: Raw) -> String {
        guard type.hasPrefix("@") || type.hasPrefix("#") else {
            return "\(type)=\(Int(bitPattern: value))"
        }
        guard let value else { return "\(type)=nil" }
        let object = Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
        let name = object_getClass(object).map { NSStringFromClass($0) } ?? "?"
        if name.contains("Block") { return "block \(blockSignature(value))" }
        if let array = object as? [AnyObject] {
            return "array of \(array.map { object_getClass($0).map { NSStringFromClass($0) } ?? "?" }.joined(separator: ", "))"
        }
        if let error = object as? NSError { return "NSError \(error.domain) \(error.code)" }
        return name
    }

    /// A block's type signature, from its descriptor (the Blocks ABI), when it carries one.
    private static func blockSignature(_ block: UnsafeRawPointer) -> String {
        let flags = block.load(fromByteOffset: 8, as: Int32.self)
        guard flags & (1 << 30) != 0 else { return "(no signature)" }
        let bits = UInt(bitPattern: block.load(fromByteOffset: 24, as: Int.self)) & 0x0000_7FFF_FFFF_FFFF
        guard let descriptor = UnsafeRawPointer(bitPattern: bits) else { return "(no descriptor)" }
        let offset = flags & (1 << 25) != 0 ? 32 : 16
        let signatureBits = UInt(bitPattern: descriptor.load(fromByteOffset: offset, as: Int.self)) & 0x0000_7FFF_FFFF_FFFF
        guard let signature = UnsafePointer<CChar>(bitPattern: signatureBits) else { return "(no signature)" }
        return String(cString: signature)
    }
}
