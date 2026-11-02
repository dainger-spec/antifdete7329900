import XCTest
@testable import BrowserCore

final class WebRTCGateTests: XCTestCase {
    private let socks = ProxySettings(kind: .socks5, host: "proxy.example", port: 1080)
    private let http = ProxySettings(kind: .httpConnect, host: "proxy.example", port: 8080)

    /// Every combination: the relay only when each condition holds, and never otherwise.
    func testRelayOnlyWhenEveryConditionHolds() {
        for policy in WebRTCPolicy.allCases {
            for proxy in [nil, socks, http] {
                for ownProcess in [false, true] {
                    for guardState in NetworkGuardState.allCases {
                        for udp in [ProxyUDPSupport.unknown, .supported, .unsupported] {
                            let decision = WebRTCGate.decide(policy: policy, proxy: proxy, ownProcess: ownProcess,
                                                             guardState: guardState, udp: udp)
                            let all = policy != .disabled && proxy?.kind == .socks5 && ownProcess
                                && guardState == .ready && udp == .supported
                            let label = "\(policy) \(proxy?.kind.rawValue ?? "none") own \(ownProcess) \(guardState) \(udp)"
                            XCTAssertEqual(decision == .relay, all, label)
                            if proxy == nil {
                                XCTAssertEqual(decision, policy == .disabled ? .off(nil) : .native(policy), label)
                            }
                            if proxy != nil, decision != .relay, policy != .disabled {
                                guard case .off(let reason?) = decision else {
                                    return XCTFail("a proxied profile without the relay is off with a reason: \(label) → \(decision)")
                                }
                                _ = reason
                            }
                        }
                    }
                }
            }
        }
    }

    func testTheFirstFailingConditionIsTheReason() {
        func reason(_ proxy: ProxySettings?, own: Bool = true, guardState: NetworkGuardState = .ready,
                    udp: ProxyUDPSupport = .supported) -> WebRTCLaunchDecision {
            WebRTCGate.decide(policy: .unrestricted, proxy: proxy, ownProcess: own, guardState: guardState, udp: udp)
        }
        // The proxy's kind first: no guard makes an HTTP proxy carry UDP.
        XCTAssertEqual(reason(http, own: false, guardState: .notInBuild, udp: .unsupported), .off(.httpProxy))
        XCTAssertEqual(reason(socks, own: false, guardState: .notInBuild, udp: .unsupported), .off(.guardNotInBuild))
        XCTAssertEqual(reason(socks, guardState: .notInstalled), .off(.guardNotInstalled))
        XCTAssertEqual(reason(socks, guardState: .awaitingApproval), .off(.guardAwaitingApproval))
        XCTAssertEqual(reason(socks, guardState: .off), .off(.guardOff))
        XCTAssertEqual(reason(socks, guardState: .notAnswering), .off(.guardNotAnswering))
        XCTAssertEqual(reason(socks, guardState: .unproven), .off(.guardUnproven))
        XCTAssertEqual(reason(socks, own: false, udp: .unsupported), .off(.notOwnProcess))
        XCTAssertEqual(reason(socks, udp: .unsupported), .off(.proxyWithoutUDP))
        XCTAssertEqual(reason(socks, udp: .unknown), .off(.proxyUDPUnknown))
        XCTAssertEqual(reason(socks), .relay)
        // The profile's own setting is no refusal: Disabled is off without a reason.
        XCTAssertEqual(WebRTCGate.decide(policy: .disabled, proxy: socks, ownProcess: true, guardState: .ready, udp: .supported),
                       .off(nil))
    }

    func testOnlyASOCKS5ProfileThatWantsWebRTCAsks() {
        XCTAssertTrue(WebRTCGate.wantsRelay(policy: .unrestricted, proxy: socks))
        XCTAssertTrue(WebRTCGate.wantsRelay(policy: .relayOnly, proxy: socks))
        XCTAssertFalse(WebRTCGate.wantsRelay(policy: .disabled, proxy: socks))
        XCTAssertFalse(WebRTCGate.wantsRelay(policy: .unrestricted, proxy: http))
        XCTAssertFalse(WebRTCGate.wantsRelay(policy: .unrestricted, proxy: nil))
    }
}
