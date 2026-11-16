import XCTest
@testable import BrowserCore

/// WebRTC that goes the way the profile's connection goes (the owner, 16 November: "if a proxy is
/// set up, everything goes through it; whoever does not need it turns it off"), and WebRTC that must
/// not connect kept in the pages as Safari has it, connecting nowhere — only where nothing a page
/// could get past the script would show another address than the pages show.
final class WebRTCAutomaticTests: XCTestCase {
    private let socks = ProxySettings(kind: .socks5, host: "proxy.example", port: 1080)
    private let http = ProxySettings(kind: .httpConnect, host: "proxy.example", port: 8080)
    private var socksBypassing: ProxySettings {
        var proxy = socks
        proxy.excludedDomains = ["bank.example"]
        return proxy
    }

    // MARK: The choice, stored

    func testAutomaticIsStoredBesideThePolicyAsRelayOnly() throws {
        var configuration = ProfileConfiguration()
        XCTAssertEqual(configuration.webRTCMode, .disabled)
        configuration.webRTCMode = .automatic
        XCTAssertTrue(configuration.webRTCAutomatic)
        // What a build that does not know Automatic reads.
        XCTAssertEqual(configuration.webRTCPolicy, .relayOnly)
        XCTAssertEqual(configuration.webRTCMode, .automatic)
        let json = String(decoding: try JSONCoding.encoder.encode(configuration), as: UTF8.self)
        XCTAssertTrue(json.contains("\"webRTCAutomatic\":true"), json)
        XCTAssertTrue(json.contains("\"webRTCPolicy\":\"relayOnly\""), json)
        XCTAssertEqual(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(json.utf8)).webRTCMode, .automatic)
        // Each of the three policies takes Automatic away again, and is written as before.
        for mode in [WebRTCMode.disabled, .relayOnly, .unrestricted] {
            configuration.webRTCMode = mode
            XCTAssertFalse(configuration.webRTCAutomatic)
            XCTAssertEqual(configuration.webRTCPolicy, mode.policy)
            XCTAssertEqual(configuration.webRTCMode, mode)
            let plain = String(decoding: try JSONCoding.encoder.encode(configuration), as: UTF8.self)
            XCTAssertFalse(plain.contains("webRTCAutomatic"), plain)
        }
    }

    /// Profiles from before keep their explicit choice: nothing is switched for them.
    func testAProfileFromBeforeKeepsItsChoice() throws {
        for policy in WebRTCPolicy.allCases {
            let old = #"{"geolocation":{"deny":{}},"webRTCPolicy":"\#(policy.rawValue)"}"#
            let decoded = try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(old.utf8))
            XCTAssertFalse(decoded.webRTCAutomatic)
            XCTAssertEqual(decoded.webRTCMode, WebRTCMode(policy))
            XCTAssertEqual(decoded.webRTCLaunchPolicy, policy)
        }
        // A value this build cannot read is no Automatic, never a reason to fail the profile.
        let odd = #"{"geolocation":{"deny":{}},"webRTCPolicy":"disabled","webRTCAutomatic":"yes"}"#
        XCTAssertEqual(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(odd.utf8)).webRTCMode, .disabled)
    }

    func testTheLaunchPolicyOfAutomaticLetsWebRTCGoWhereTheConnectionGoes() {
        XCTAssertEqual(ProfileConfiguration(webRTCPolicy: .relayOnly, webRTCAutomatic: true).webRTCLaunchPolicy, .unrestricted)
        // No proxy: as Safari, over this Mac's own connection.
        XCTAssertEqual(ProfileConfiguration(webRTCPolicy: .relayOnly, webRTCAutomatic: true).webRTCRouting, .native(.unrestricted))
        // SOCKS5 with the relay the launch gave it: through the proxy.
        let relay = WebRTCRelay(urls: ["turn:127.0.0.1:50000?transport=udp"], username: "u", credential: "c")
        var proxied = ProfileConfiguration(proxy: socks, webRTCPolicy: .relayOnly, webRTCAutomatic: true)
        XCTAssertEqual(proxied.webRTCRouting, .off)
        proxied.webRTCRelay = relay
        XCTAssertEqual(proxied.webRTCRouting, .relay(relay))
        // The gate decides with the launch policy: Automatic through a SOCKS5 proxy wants the relay.
        XCTAssertTrue(WebRTCGate.wantsRelay(policy: proxied.webRTCLaunchPolicy, proxy: socks))
        XCTAssertTrue(WebRTCProtectionNotice.wants(proxyKind: .socks5, webRTC: proxied.webRTCLaunchPolicy))
        XCTAssertFalse(WebRTCGate.wantsRelay(policy: proxied.webRTCLaunchPolicy, proxy: http))
    }

    // MARK: Present, connecting nowhere

    func testSilentRoutingIsSetForOneLaunchAndNeverStored() throws {
        var configuration = ProfileConfiguration(proxy: http, webRTCPolicy: .unrestricted)
        XCTAssertEqual(configuration.webRTCRouting, .off)
        XCTAssertEqual(configuration.effectiveWebRTCPolicy, .disabled)
        configuration.webRTCSilent = true
        XCTAssertEqual(configuration.webRTCRouting, .silent)
        // The engine's WebRTC is on; the page's script holds it to relay-only with no server.
        XCTAssertEqual(configuration.effectiveWebRTCPolicy, .relayOnly)
        // Without a proxy, Disabled is present and connecting nowhere by itself, whoever made the session.
        XCTAssertEqual(ProfileConfiguration(webRTCPolicy: .disabled).webRTCRouting, .silent)
        XCTAssertEqual(ProfileConfiguration(webRTCPolicy: .disabled).effectiveWebRTCPolicy, .relayOnly)
        // With a proxy, only once the launch had the guard hold the process.
        var held = ProfileConfiguration(proxy: socks, webRTCPolicy: .disabled)
        XCTAssertEqual(held.webRTCRouting, .off)
        held.webRTCSilent = true
        XCTAssertEqual(held.webRTCRouting, .silent)
        // The relay wins where there is one; without a proxy a WebRTC that may connect is native.
        let relay = WebRTCRelay(urls: ["turn:127.0.0.1:50000?transport=udp"], username: "u", credential: "c")
        var both = ProfileConfiguration(proxy: socks, webRTCPolicy: .unrestricted)
        both.webRTCRelay = relay
        both.webRTCSilent = true
        XCTAssertEqual(both.webRTCRouting, .relay(relay))
        var native = ProfileConfiguration(webRTCPolicy: .unrestricted)
        native.webRTCSilent = true
        XCTAssertEqual(native.webRTCRouting, .native(.unrestricted))
        // Never written, never read back, and no change of settings.
        let json = String(decoding: try JSONCoding.encoder.encode(configuration), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("silent"), json)
        XCTAssertFalse(try JSONCoding.decoder.decode(ProfileConfiguration.self, from: Data(json.utf8)).webRTCSilent)
        XCTAssertTrue(configuration.hasSameSettings(as: ProfileConfiguration(proxy: http, webRTCPolicy: .unrestricted)))
    }

    func testSilenceOnlyWhereNothingCanGoAroundTheConnection() {
        for ownProcess in [false, true] {
            for state in NetworkGuardState.allCases {
                // No proxy: the engine's own WebRTC goes out as this Mac, as the pages do.
                XCTAssertEqual(WebRTCGate.silence(proxy: nil, ownProcess: ownProcess, guardState: state), .withoutHold)
                for proxy in [socks, http, socksBypassing] {
                    let expected: WebRTCSilence = ownProcess && state == .ready && proxy.excludedDomains.isEmpty ? .afterHold : .no
                    XCTAssertEqual(WebRTCGate.silence(proxy: proxy, ownProcess: ownProcess, guardState: state), expected,
                                   "\(proxy.kind) own \(ownProcess) \(state) bypass \(proxy.excludedDomains)")
                }
            }
        }
    }

    /// The launch as the manager makes it (`ProfileManager.decideWebRTC`), for every combination:
    /// whenever the engine's WebRTC is on in a proxied profile — the relay or silent — the network
    /// guard holds its process; and WebRTC is removed only where it could not be held.
    func testWithAProxyTheEnginesWebRTCIsOnOnlyWhileTheGuardHoldsTheProcess() {
        for mode in WebRTCMode.allCases {
            for proxy in [nil, socks, http, socksBypassing] {
                for ownProcess in [false, true] {
                    for state in NetworkGuardState.allCases {
                        for udp in ProxyUDPSupport.allCases {
                            for holdTaken in [false, true] {
                                var configuration = ProfileConfiguration(proxy: proxy)
                                configuration.webRTCMode = mode
                                let label = "\(mode) \(proxy?.kind.rawValue ?? "none") own \(ownProcess) \(state) \(udp) hold \(holdTaken)"
                                var held = false
                                let decision = WebRTCGate.decide(policy: configuration.webRTCLaunchPolicy, proxy: proxy,
                                                                 ownProcess: ownProcess, guardState: state, udp: udp)
                                if decision == .relay, holdTaken {
                                    held = true
                                    configuration.webRTCRelay = WebRTCRelay(urls: ["turn:127.0.0.1:1?transport=udp"], username: "u", credential: "c")
                                } else if case .off = decision {
                                    switch WebRTCGate.silence(proxy: proxy, ownProcess: ownProcess, guardState: state) {
                                    case .withoutHold: configuration.webRTCSilent = true
                                    case .afterHold:
                                        held = holdTaken
                                        configuration.webRTCSilent = holdTaken
                                    case .no: break
                                    }
                                }
                                let engineOn = configuration.effectiveWebRTCPolicy != .disabled
                                if proxy != nil, engineOn {
                                    XCTAssertTrue(held && ownProcess && state == .ready, label)
                                }
                                // Never simply removed where it can stay: without a proxy it is always there.
                                if proxy == nil { XCTAssertTrue(engineOn, label) }
                                // Silent is relay-only with no ICE server in the page: never `native` with a proxy.
                                if proxy != nil, case .native = configuration.webRTCRouting { XCTFail(label) }
                            }
                        }
                    }
                }
            }
        }
    }

    func testThePersonIsToldWhyExceptWhereThereIsNothingToDo() {
        XCTAssertFalse(WebRTCGate.tells(nil, automatic: false))
        XCTAssertFalse(WebRTCGate.tells(nil, automatic: true))
        XCTAssertFalse(WebRTCGate.tells(.httpProxy, automatic: true))
        XCTAssertTrue(WebRTCGate.tells(.httpProxy, automatic: false))
        for reason in WebRTCRefusal.allCases where reason != .httpProxy {
            XCTAssertTrue(WebRTCGate.tells(reason, automatic: true), reason.rawValue)
        }
    }

    func testTheGuardsReasonsAreTheGatesOwn() {
        for state in NetworkGuardState.allCases {
            let decision = WebRTCGate.decide(policy: .unrestricted, proxy: socks, ownProcess: true, guardState: state, udp: .supported)
            if let refusal = WebRTCGate.guardRefusal(state) {
                XCTAssertEqual(decision, .off(refusal), state.rawValue)
            } else {
                XCTAssertEqual(decision, .relay)
            }
        }
    }

    // MARK: What the editor says will happen

    func testTheOutlookSaysWhatTheNextLaunchDoes() {
        func outlook(_ mode: WebRTCMode, _ proxy: ProxySettings?, own: Bool = true, _ state: NetworkGuardState = .ready) -> WebRTCOutlook {
            WebRTCGate.outlook(mode: mode, proxy: proxy, ownProcess: own, guardState: state)
        }
        // No proxy.
        XCTAssertEqual(outlook(.automatic, nil, .notInstalled), .native(.unrestricted))
        XCTAssertEqual(outlook(.unrestricted, nil), .native(.unrestricted))
        XCTAssertEqual(outlook(.relayOnly, nil), .native(.relayOnly))
        XCTAssertEqual(outlook(.disabled, nil, own: false, .notInBuild), .silentByChoice)
        // SOCKS5.
        XCTAssertEqual(outlook(.automatic, socks), .throughProxy)
        XCTAssertEqual(outlook(.relayOnly, socks), .throughProxy)
        XCTAssertEqual(outlook(.disabled, socks), .silentByChoice)
        XCTAssertEqual(outlook(.automatic, socks, .notInstalled), .removed(.guardNotInstalled))
        XCTAssertEqual(outlook(.disabled, socks, .awaitingApproval), .removed(.guardAwaitingApproval))
        XCTAssertEqual(outlook(.automatic, socks, .notInBuild), .removed(.guardNotInBuild))
        XCTAssertEqual(outlook(.automatic, socks, own: false), .removed(.notOwnProcess))
        XCTAssertEqual(outlook(.automatic, socksBypassing), .throughProxy)
        XCTAssertEqual(outlook(.disabled, socksBypassing), .removedBypass)
        // HTTP: no UDP; present and connecting nowhere once the guard holds the process.
        XCTAssertEqual(outlook(.automatic, http), .silentHTTPProxy)
        XCTAssertEqual(outlook(.unrestricted, http), .silentHTTPProxy)
        XCTAssertEqual(outlook(.disabled, http), .silentByChoice)
        XCTAssertEqual(outlook(.automatic, http, .unproven), .removed(.guardUnproven))
        XCTAssertEqual(outlook(.automatic, http, own: false), .removed(.notOwnProcess))
        var bypassingHTTP = http
        bypassingHTTP.excludedDomains = ["bank.example"]
        XCTAssertEqual(outlook(.automatic, bypassingHTTP), .removedBypass)
        XCTAssertEqual(outlook(.automatic, bypassingHTTP, .notInstalled), .removed(.guardNotInstalled))
    }
}
