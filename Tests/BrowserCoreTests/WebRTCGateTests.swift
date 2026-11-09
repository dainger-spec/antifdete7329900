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
                        for udp in ProxyUDPSupport.allCases {
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
        // One address: UDP that leaves from elsewhere than the proxy's TCP, or a TCP exit that is
        // not known, is no relay.
        XCTAssertEqual(reason(socks, udp: .elsewhere), .off(.proxyUDPElsewhere))
        XCTAssertEqual(reason(socks, udp: .exitUnknown), .off(.proxyExitUnknown))
        XCTAssertEqual(reason(socks, own: false, udp: .elsewhere), .off(.notOwnProcess))
        XCTAssertEqual(reason(socks, guardState: .off, udp: .elsewhere), .off(.guardOff))
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


    // MARK: The notice at the foot of the profiles window

    /// Said exactly in the five states where the guard does not work, once macOS has answered, and
    /// only when some profile wants WebRTC through a SOCKS5 proxy; each state its own notice.
    func testTheProtectionNoticeOnlyWhenTheGuardDoesNotWorkAndAProfileWantsIt() {
        let broken: [NetworkGuardState: WebRTCProtectionNotice] = [
            .restartNeeded: .restartNeeded, .notInstalled: .notInstalled, .awaitingApproval: .awaitingApproval,
            .off: .off, .notAnswering: .notAnswering,
        ]
        for state in NetworkGuardState.allCases {
            for checking in [false, true] {
                for wanted in [false, true] {
                    let notice = WebRTCProtectionNotice.notice(state: state, checking: checking, profilesWantingIt: wanted)
                    let expected = wanted && !checking ? broken[state] : nil
                    XCTAssertEqual(notice, expected, "\(state) checking \(checking) wanted \(wanted)")
                }
            }
        }
        // Every notice is reached, by one state each.
        XCTAssertEqual(Set(broken.values), Set(WebRTCProtectionNotice.allCases))
    }

    /// Wanted: a SOCKS5 proxy with WebRTC not switched off; an HTTP proxy, no proxy, or WebRTC off: not.
    func testAProfileWantsTheProtectionOnlyWithSOCKS5AndWebRTCOn() {
        let kinds: [ProxySettings.Kind?] = [nil] + ProxySettings.Kind.allCases.map { $0 }
        for kind in kinds {
            for policy in WebRTCPolicy.allCases {
                XCTAssertEqual(WebRTCProtectionNotice.wants(proxyKind: kind, webRTC: policy),
                               kind == .socks5 && policy != .disabled, "\(String(describing: kind)) \(policy)")
            }
        }
    }
}
