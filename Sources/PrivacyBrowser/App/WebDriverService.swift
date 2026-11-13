import BrowserCore
import Foundation
import os

/// The WebDriver's sessions (docs/AUTOMATION.md, "WebDriver"): a client — Selenium, or anything
/// that speaks the W3C protocol — is given a profile's address, `…/wd/<token>/<profile>`; a new
/// session starts the profile if it is stopped and opens the window its commands act in; the
/// commands go to the process that has that window (`ProfileManager.webDriver`); ending the
/// session closes the window, and stops the profile when the session started it.
///
/// One session a profile at a time. Part of the plan's automation, like the rest of the API.
@MainActor
final class WebDriverService {
    private struct Session {
        let profileID: UUID
        /// The session started the profile: ending it stops the profile again.
        let startedProfile: Bool
    }

    private var sessions: [String: Session] = [:]
    private let manager: ProfileManager
    private let repository: ProfileRepository
    /// Starts a stopped profile as the API's `start` does; an error's text when it did not start.
    var launch: (UUID) async -> String? = { _ in "not available" }
    var stop: (UUID) async -> Void = { _ in }
    var allowsAutomation: () -> Bool = { false }
    /// Something changed that the Profiles list shows.
    var onChange: () -> Void = {}
    private let log = Logger(subsystem: "PrivacyBrowser", category: "WebDriver")

    init(manager: ProfileManager, repository: ProfileRepository) {
        self.manager = manager
        self.repository = repository
    }

    /// The request answered: the HTTP status and the JSON body.
    func handle(_ request: WebDriverRequest, body: Data) async -> (status: Int, body: Data) {
        func fail(_ error: WebDriverError) -> (Int, Data) { (error.status, error.body) }
        func ok(_ json: String) -> (Int, Data) { (200, Data("{\"value\":\(json)}".utf8)) }
        guard allowsAutomation() else {
            return fail(.unsupported("WebDriver is part of the Professional and Team plans; this license's plan does not include it."))
        }
        let profile: ProfileSummary
        switch AutomationProfiles.find(request.profile, in: repository.list()) {
        case .success(let found): profile = found
        case .failure: return fail(WebDriverError("unknown error", 404, "The address names no profile of this vault (its id, or its exact name)."))
        }
        // A session whose profile was stopped under it is over: a client that ended without
        // quitting must not keep the profile from its next session.
        if !manager.isRunning(profile.id) {
            for (id, session) in sessions where session.profileID == profile.id { sessions[id] = nil }
        }
        switch request.command {
        case "status":
            let free = !sessions.values.contains { $0.profileID == profile.id }
            return ok(WebDriverExecutor.json(["ready": free, "message": free ? "Lumen" : "This profile has a session already."]))
        case "newSession":
            guard !sessions.values.contains(where: { $0.profileID == profile.id }) else {
                return fail(.sessionNotCreated("This profile has a WebDriver session already: end it (quit) before a new one."))
            }
            let wasRunning = manager.isRunning(profile.id)
            if !wasRunning {
                if let problem = await launch(profile.id) { return fail(.sessionNotCreated("The profile did not start: \(problem)")) }
                onChange()
            }
            let opened = await manager.webDriver(profile.id, WebDriverCall(id: UUID(), command: "open", element: nil, name: nil, body: "{}"))
            if let error = opened.error {
                if !wasRunning { await stop(profile.id) }
                return fail(.sessionNotCreated("The profile gave no window to act in: \(error.message)"))
            }
            let id = UUID().uuidString.lowercased()
            sessions[id] = Session(profileID: profile.id, startedProfile: !wasRunning)
            log.notice("A WebDriver session began")
            let capabilities: [String: Any] = [
                "browserName": "safari", "browserVersion": HostSafari.version, "platformName": "mac",
                "acceptInsecureCerts": false, "pageLoadStrategy": "normal", "setWindowRect": true,
                "timeouts": ["script": 30_000, "pageLoad": 300_000, "implicit": 0],
                "lumen:profile": profile.name, "lumen:profileID": profile.id.uuidString,
            ]
            return ok(WebDriverExecutor.json(["sessionId": id, "capabilities": capabilities]))
        default:
            guard let id = request.session, let session = sessions[id], session.profileID == profile.id else {
                return fail(.noSuchSession("There is no such session of this profile."))
            }
            if request.command == "deleteSession" || request.command == "closeWindow" {
                await end(id, session)
                return ok(request.command == "closeWindow" ? "[]" : "null")
            }
            let text = body.isEmpty ? "{}" : String(decoding: body, as: UTF8.self)
            let answer = await manager.webDriver(profile.id, WebDriverCall(id: UUID(), command: request.command, element: request.element,
                                                                           name: request.name, body: text))
            if let error = answer.error {
                // The profile was stopped under the session: the session is over.
                if !manager.isRunning(profile.id) { sessions[id] = nil }
                return fail(error)
            }
            return ok(answer.value ?? "null")
        }
    }

    private func end(_ id: String, _ session: Session) async {
        sessions[id] = nil
        _ = await manager.webDriver(session.profileID, WebDriverCall(id: UUID(), command: "close", element: nil, name: nil, body: "{}"))
        if session.startedProfile, manager.isRunning(session.profileID) {
            await stop(session.profileID)
            onChange()
        }
        log.notice("A WebDriver session ended")
    }

    /// At lock, or when the API is turned off: no session is left behind.
    func endAll() async {
        for (id, session) in sessions { await end(id, session) }
    }
}
