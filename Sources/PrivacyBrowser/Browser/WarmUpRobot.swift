import AppKit
import BrowserCore
import Foundation
import os
import WebKit

/// The session warm-up robot of one profile ("cookie robot"): it opens the pages of a
/// `WarmUpPlan` one after the other in a tab of the running profile — its data store, proxy,
/// User-Agent and scripts, as when the user browses — stays on each for a random time, scrolls
/// now and then, and, when asked, follows one plain link (`WarmUpLinkPolicy`) before going on.
/// Nothing is typed or submitted.
///
/// How it acts on a page, so that pages see a visitor and not a script:
/// * It reads pages (scroll position, links) in a content world of its own, invisible to the
///   page's scripts, as Password AutoFill does.
/// * It scrolls with wheel events, as a mouse with smooth scrolling would, and moves the pointer
///   to a link and clicks it with mouse events once a trusted move was seen to reach that very
///   link (by a listener of its own world) — all through `PageInput`, which keeps its window's
///   page focused for the run though the window is never in front, and gives the page what a
///   person's mouse gives it. When the events did not reach the page, it scrolls with
///   `scrollBy` from its world — pages then see the scrolling but no wheel — and clicks with the
///   link's `click()`, an untrusted click. Which way it last went is reported (`scrollInput`,
///   `clickInput`).
/// * It loads a page only while its tab is the one shown: a page loading in a tab out of sight
///   has no window (outer size 0×0), which a visitor's never has.
///
/// It stops by itself when its tab is closed, when the profile stops (`ProfileManager.stop`
/// cancels it first, before the store is released: the robot holds its tab and session only
/// weakly) and when a page waits for an answer to a dialog.
@MainActor
final class WarmUpRobot: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case finished
        case stopped(StopReason)
    }

    enum StopReason: Equatable {
        case byUser
        case profileStopped
        case tabClosed
        /// A page of the robot's tab shows a dialog (alert, sign-in…) that waits for the user.
        case pageNeedsAttention
    }

    enum Input: String, Equatable {
        /// Events sent to the web view, as from the mouse or trackpad.
        case native
        /// From the robot's script world (`scrollBy`, `click()`).
        case script
    }

    /// Waits: these for the app; the self-test makes them shorter.
    struct Limits {
        /// A page still loading after this is left as it is (`WarmUpVisit.Outcome.timedOut`).
        var loadTimeout: TimeInterval = 30
        /// A load that has not even started after this has failed.
        var startTimeout: TimeInterval = 10
        /// A script of the robot that has not answered after this is given up.
        var scriptTimeout: TimeInterval = 5
        /// The plan's times are kept to `WarmUpPlan.dwellLimits`, and the pause between pages
        /// is `WarmUpTiming.pause`, unless set here (self-test).
        var dwellOverride: ClosedRange<TimeInterval>?
        var pauseOverride: ClosedRange<TimeInterval>?
    }

    let profileID: UUID
    @Published private(set) var state: State = .idle
    @Published private(set) var visits: [WarmUpVisit] = []
    @Published private(set) var pageCount = 0
    /// The run's pointer, wheel and keyboard on its tab's page.
    private var input: PageInput?
    /// What the robot's world saw of its last pointer moves (self-test notes).
    private(set) var clickDiagnosis: String?
    @Published private(set) var scrollInput: Input?
    @Published private(set) var clickInput: Input?
    /// Its tab is not the one shown (the user selected another): the next page waits for it, as a
    /// page loading out of sight sees no window.
    @Published private(set) var waitingForTab = false
    var limits = Limits()
    /// Told when the state changes or the next page begins (the profile list shows the run).
    var onProgress: (() -> Void)?

    var isRunning: Bool { state == .running }

    /// The run as the screens show it — the same value a profile in its own process sends back
    /// over the channel, so that both ways of running look alike to the UI.
    var status: WarmUpStatus {
        let visited = visits.filter { $0.outcome != nil }.count
        let failed = visits.filter { if case .failed? = $0.outcome { return true } else { return false } }.count
        let phase: WarmUpStatus.Phase
        switch state {
        case .running: phase = .running
        case .finished: phase = .finished
        case .idle, .stopped: phase = .stopped
        }
        var reason: String?
        if case .stopped(let why) = state {
            switch why {
            case .byUser: reason = "byUser"
            case .profileStopped: reason = "profileStopped"
            case .tabClosed: reason = "tabClosed"
            case .pageNeedsAttention: reason = "pageNeedsAttention"
            }
        } else if isRunning, waitingForTab {
            reason = "waitingForTab"
        }
        return WarmUpStatus(phase: phase, visited: visited, total: pageCount, failed: failed,
                            cookies: cookiesCollected, secondsRemaining: secondsRemaining,
                            currentHost: isRunning ? visits.last?.url.host : nil,
                            sites: isRunning ? nil : cookieSites, stopReason: reason)
    }

    /// Roughly how much of the run is left: from what its pages have actually taken so far, and
    /// before the first one is over, from the plan. Nil once the run is over.
    var secondsRemaining: TimeInterval? {
        guard isRunning, pageCount > 0 else { return nil }
        let done = visits.filter { $0.outcome != nil }.count
        let left = max(0, pageCount - done)
        guard left > 0 else { return 0 }
        let perPage: TimeInterval
        if done > 0, let startedAt {
            perPage = max(1, Date().timeIntervalSince(startedAt) / Double(done))
        } else {
            perPage = plannedSecondsPerPage
        }
        return Double(left) * perPage
    }

    /// The robot's tab, while it runs (self-test hook).
    var currentTab: BrowserTab? { isRunning ? tab : nil }

    static let world = WKContentWorld.world(name: "PrivacyBrowser.WarmUp")
    private weak var session: BrowserSession?
    private weak var tab: BrowserTab?
    /// The window this run browses in, off every screen (`BrowserSession.openOffscreenWindow`).
    private var offscreenWindow: BrowserWindowController?
    /// The profile's cookies when the run began (`WarmUpCookieCount.Cookie`: one per name, domain
    /// and path); nil until the store has answered.
    private var cookiesBefore: Set<WarmUpCookieCount.Cookie>?
    /// Cookies the profile has gained since this run began: the store is read before the first
    /// page and again after each one, and a cookie counts when it was not there at the start —
    /// which is what "collected" means on the warm-up screen.
    @Published private(set) var cookiesCollected = 0
    /// Once the run is over: the profile's cookies per site and how many of them the run added —
    /// the report the warm-up screen shows (`WarmUpStatus.sites`). Taken from the same reads of
    /// the store, in the process the profile runs in, so it crosses to the manager in the status.
    private(set) var cookieSites: [WarmUpCookieSite]?
    /// When the run began, and what one of its pages was expected to cost: together they say how
    /// much of the run is left.
    private var startedAt: Date?
    private var plannedSecondsPerPage: TimeInterval = 20
    private var task: Task<Void, Never>?
    private var run = 0
    private let log = Logger(subsystem: "PrivacyBrowser", category: "WarmUp")

    init(profileID: UUID) {
        self.profileID = profileID
    }

    // MARK: Start and stop

    /// Starts a run of `plan` for `session`, in a window of its own that is placed off every
    /// screen: the user keeps browsing, or keeps doing something else entirely, while the profile
    /// is warmed. False when it is already running or the plan has no page.
    @discardableResult
    func start(_ plan: WarmUpPlan, in session: BrowserSession) -> Bool {
        guard !isRunning, session.dataStore != nil else { return false }
        let pages = plan.pages(searchEngine: session.configuration.searchEngine ?? .standard).pages
        guard !pages.isEmpty else { return false }
        let controller = session.openOffscreenWindow()
        guard let tab = controller.tabs.first else {
            log.error("Warm-up could not open its own window")
            return false
        }
        offscreenWindow = controller
        // Its window is never in front; its page keeps the focus of a page someone is using.
        let input = PageInput(webView: tab.webView)
        input.holdFocus()
        self.input = input
        cookiesBefore = nil
        cookiesCollected = 0
        cookieSites = nil
        startedAt = Date()
        plannedSecondsPerPage = plan.secondsPerPage
        tab.refusesDownloads = true
        run += 1
        let current = run
        self.session = session
        self.tab = tab
        visits = []
        pageCount = pages.count
        scrollInput = nil
        clickInput = nil
        setState(.running)
        log.notice("Warm-up of \(pages.count) pages started, out of sight")
        task = Task { [weak self] in
            await self?.perform(plan.normalized, pages, run: current)
        }
        return true
    }

    /// Stops the run (at once: its waits end, and nothing more is done in its tab).
    func stop(_ reason: StopReason = .byUser) {
        guard isRunning else { return }
        task?.cancel()
        task = nil
        release()
        setState(.stopped(reason))
        log.notice("Warm-up stopped: \(String(describing: reason), privacy: .private)")
    }

    /// Closes the warm-up's own window and lets go of everything it held.
    private func release() {
        input?.releaseFocus()
        input = nil
        tab?.refusesDownloads = false
        countCookiesSoFar()
        startedAt = nil
        tab = nil
        offscreenWindow?.tearDown()
        offscreenWindow?.close()
        offscreenWindow = nil
        session = nil
    }

    /// Counts the profile's cookies and reports how many the run has added so far. Called after
    /// each page, so the screen can show the count growing rather than only a total at the end.
    /// The count a stop asks for (`release()`) comes back once the run is over: it brings the
    /// report of a run that was stopped part-way.
    private func countCookiesSoFar() {
        countCookies { [weak self] cookies in
            guard let self else { return }
            guard let before = self.cookiesBefore else {
                // The first count has not come back yet: take this one as the run's starting point.
                self.cookiesBefore = Set(cookies)
                return
            }
            let collected = WarmUpCookieCount.added(before: before, after: cookies)
            let sites = self.isRunning ? nil : WarmUpCookieCount.sites(before: before, after: cookies)
            guard collected != self.cookiesCollected || (sites != nil && sites != self.cookieSites) else { return }
            self.cookiesCollected = collected
            if let sites { self.cookieSites = sites }
            self.onProgress?()
        }
    }

    /// The same, waited for: used once, at the end of a run, so that the run is reported as over
    /// with its whole count and its report, not before the last page's cookies are in.
    private func countCookiesAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let store = session?.dataStore else {
                continuation.resume()
                return
            }
            store.httpCookieStore.getAllCookies { cookies in
                MainActor.assumeIsolated {
                    if let before = self.cookiesBefore {
                        let after = cookies.map { Self.identity($0) }
                        self.cookiesCollected = WarmUpCookieCount.added(before: before, after: after)
                        self.cookieSites = WarmUpCookieCount.sites(before: before, after: after)
                    }
                    continuation.resume()
                }
            }
        }
    }

    /// The profile's cookies before the run's first page, waited for.
    private func takeStartingPoint() async {
        guard cookiesBefore == nil, let store = session?.dataStore else { return }
        let cookies = await store.httpCookieStore.allCookies()
        if cookiesBefore == nil { cookiesBefore = Set(cookies.map { Self.identity($0) }) }
    }

    /// The cookies the profile holds right now, as `WarmUpCookieCount` tells them apart.
    private func countCookies(_ answer: @escaping @MainActor ([WarmUpCookieCount.Cookie]) -> Void) {
        guard let store = session?.dataStore else { return }
        store.httpCookieStore.getAllCookies { cookies in
            MainActor.assumeIsolated { answer(cookies.map { Self.identity($0) }) }
        }
    }

    /// A cookie of the store, by what tells it apart from the others (name, domain, path).
    nonisolated private static func identity(_ cookie: HTTPCookie) -> WarmUpCookieCount.Cookie {
        WarmUpCookieCount.Cookie(name: cookie.name, domain: cookie.domain, path: cookie.path)
    }

    /// Changes visit `index` of run `run`; nothing once that run has ended (its last awaits can
    /// still come back after a Stop, when `visits` may already be the next run's).
    private func update(_ index: Int, run: Int, _ change: (inout WarmUpVisit) -> Void) {
        guard isCurrent(run), visits.indices.contains(index) else { return }
        change(&visits[index])
    }

    private func setState(_ state: State) {
        self.state = state
        onProgress?()
    }

    // MARK: The run

    private func perform(_ plan: WarmUpPlan, _ pages: [WarmUpPlan.Page], run: Int) async {
        // The run's starting point, read before its first page: a cookie that page sets is the
        // run's, not one the profile had (read before the session was set, it never came back,
        // and the store as it was after the first page became the starting point).
        await takeStartingPoint()
        guard isCurrent(run) else { return }
        var generator = SystemRandomNumberGenerator()
        for (index, page) in pages.enumerated() {
            guard await waitUntilShown(run) else { return }
            visits.append(WarmUpVisit(id: index, url: page.url, kind: page.kind))
            onProgress?()
            guard let tab = liveTab(run) else { return }
            var typed: WarmUpVisit.Outcome?
            // A search, most times typed on the engine's own page as a person does; else (and when
            // that cannot be done as a person would) its results opened by their address, as
            // Safari's address bar does with words typed into it.
            if page.kind == .search, let query = page.query,
               Double.random(in: 0..<1, using: &generator) < WarmUpTiming.typedSearchShare {
                switch await typeSearch(query, for: page, in: tab, run: run, using: &generator) {
                case .typed(let outcome):
                    typed = outcome
                    update(index, run: run) {
                        $0.typedSearch = true
                        if let at = tab.url { $0.url = at }
                    }
                case .notTyped: break
                case .ended: return
                }
            }
            let loaded: WarmUpVisit.Outcome?
            if let typed { loaded = typed } else { loaded = await load(page.url, in: tab, run: run) }
            guard let outcome = loaded, isCurrent(run) else { return }
            update(index, run: run) {
                $0.outcome = outcome
                if outcome == .loaded { $0.loadedAt = Date() }
                $0.title = tab.webView.title ?? ""
            }
            // A page that did not load is left at once (its error page is no visit).
            if !isFailure(outcome) {
                // A cookie banner, answered as most people answer it: "accept" (the well-known
                // consent tools' own button only — nothing else on the page is pressed).
                if await acceptConsent(in: tab, run: run) { update(index, run: run) { $0.consentsAccepted += 1 } }
                guard isCurrent(run) else { return }
                let dwell = dwellTime(plan, using: &generator)
                update(index, run: run) { $0.dwell = dwell }
                guard await stay(dwell, scroll: plan.scroll, visit: index, run: run, using: &generator) else { return }
                // Links one after the other (`plan.hops`, 1–3 by depth): from a search's results to a
                // site, then on within that site, as a person reads on.
                var current = page
                for hop in 0..<plan.hops {
                    guard let followed = await follow(on: current, visit: index, hop: hop, plan: plan, run: run,
                                                      using: &generator) else { return }
                    guard followed, let at = liveTab(run)?.url else { break }
                    current = WarmUpPlan.Page(url: at, kind: .address)
                }
            }
            countCookiesSoFar()
            if index < pages.count - 1 {
                let pause = limits.pauseOverride.map { Double.random(in: $0, using: &generator) } ?? WarmUpTiming.pause(using: &generator)
                guard await wait(pause, run: run) else { return }
            }
        }
        guard isCurrent(run) else { return }
        // The count the screen is left with is the whole run's, so the last page's cookies are
        // waited for rather than arriving after the run is reported as over.
        await countCookiesAndWait()
        guard isCurrent(run) else { return }
        task = nil
        release()
        setState(.finished)
        let sitesAdded = cookieSites?.filter { $0.added > 0 }.count ?? 0
        log.notice("Warm-up finished: \(self.cookiesCollected, privacy: .public) cookies collected on \(sitesAdded, privacy: .public) sites")
    }

    private func isFailure(_ outcome: WarmUpVisit.Outcome) -> Bool {
        if case .failed = outcome { return true }
        return false
    }

    private func dwellTime(_ plan: WarmUpPlan, using generator: inout some RandomNumberGenerator) -> TimeInterval {
        if let range = limits.dwellOverride { return Double.random(in: range, using: &generator) }
        return WarmUpTiming.dwell(plan, using: &generator)
    }

    private func isCurrent(_ run: Int) -> Bool {
        !Task.isCancelled && isRunning && run == self.run
    }

    /// The robot's tab while this run goes on; otherwise nil, and the run is stopped with the
    /// reason (the tab closed, the profile stopped, a dialog waiting).
    private func liveTab(_ run: Int) -> BrowserTab? {
        guard isCurrent(run) else { return nil }
        guard let session, session.dataStore != nil else {
            stop(.profileStopped)
            return nil
        }
        guard let tab, tab.host != nil else {
            stop(.tabClosed)
            return nil
        }
        if tab.hasPendingSheet {
            stop(.pageNeedsAttention)
            return nil
        }
        return tab
    }

    /// Sleeps, looking at the tab every quarter second; false as soon as the run ends (stopped,
    /// tab closed, profile stopped, a dialog waiting).
    private func wait(_ seconds: TimeInterval, run: Int) async -> Bool {
        let end = Date().addingTimeInterval(max(seconds, 0))
        repeat {
            let left = end.timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(nanoseconds: UInt64(min(left, 0.25) * 1_000_000_000)) }
            guard liveTab(run) != nil else { return false }
        } while end.timeIntervalSinceNow > 0
        return true
    }

    /// Waits while the robot's tab is not the one its window shows.
    private func waitUntilShown(_ run: Int) async -> Bool {
        while let tab = liveTab(run), !tab.isSelected {
            if !waitingForTab { waitingForTab = true }
            guard await wait(0.25, run: run) else { break }
        }
        if waitingForTab { waitingForTab = false }
        return liveTab(run) != nil
    }

    // MARK: Loading

    /// Loads `url` and waits for the page: nil when the run ended meanwhile.
    private func load(_ url: URL, in tab: BrowserTab, run: Int) async -> WarmUpVisit.Outcome? {
        let failures = tab.failedNavigations
        let before = tab.url
        let navigation = tab.load(url)
        // The tab shows a load it is asked for at once, as WebKit writes the address. WebKit only
        // jumps within the page shown, with no new page to come, for another fragment of that page.
        let jump = tab.url.flatMap { asked in
            asked.fragment != nil && asked != before && WebAddress.isSameDocument(asked, before) ? asked : nil
        }
        return await waitForPage(in: tab, failuresBefore: failures, urlBefore: before,
                                 own: navigation.map { (navigation: $0, jump: jump) }, run: run)
    }

    /// Waits for a navigation of `tab` to start and its page to load (or fail, or take longer
    /// than `limits.loadTimeout`). For a load the robot started (`own`) only that load counts, not
    /// a changed address with nothing loading: the run's first page is asked for while its new
    /// tab's blank load is still being decided, and WebKit drops the pending address when it decides
    /// on that load, which can leave the tab with no address and nothing loading until the page's
    /// own load starts. Taken for the page, that moment is the likely reason a run's first page was
    /// at times never scrolled.
    private func waitForPage(in tab: BrowserTab, failuresBefore: Int, urlBefore: URL?,
                             own: (navigation: WKNavigation, jump: URL?)? = nil,
                             run: Int, startTimeout: TimeInterval? = nil) async -> WarmUpVisit.Outcome? {
        let begun = Date()
        var started = false
        while true {
            guard await wait(0.1, run: run), let tab = liveTab(run) else { return nil }
            if tab.failedNavigations != failuresBefore {
                // The error page loads in its place: wait for it, the message is already known.
                guard await waitWhileLoading(tab, run: run, limit: 3) else { return nil }
                return .failed(tab.lastNavigationError ?? "")
            }
            if let own {
                // Its page committed; or the load ended without one (it failed — the error page is
                // counted above — or another load took its place); or, a jump within the page shown
                // (no new page commits for it), the tab shows that page, whatever the fragment became.
                let ended = tab.hasCommitted(own.navigation) || tab.hasAbandoned(own.navigation)
                let jumped = own.jump.map { WebAddress.isSameDocument(tab.url, $0) } ?? false
                started = started || ended || tab.isLoading
                if ended || jumped, !tab.isLoading { return .loaded }
            } else {
                // A link the page followed: the URL changes when its load starts.
                started = started || tab.isLoading || tab.url != urlBefore
                if started, !tab.isLoading { return .loaded }
            }
            let elapsed = Date().timeIntervalSince(begun)
            if !started, elapsed > (startTimeout ?? limits.startTimeout) {
                return .failed(L("warmup.visit.notStarted"))
            }
            if elapsed > limits.loadTimeout { return .timedOut }
        }
    }

    private func waitWhileLoading(_ tab: BrowserTab, run: Int, limit: TimeInterval) async -> Bool {
        let begun = Date()
        while tab.isLoading, Date().timeIntervalSince(begun) < limit {
            guard await wait(0.1, run: run) else { return false }
        }
        return true
    }

    // MARK: Staying on a page

    /// Stays `dwell` seconds, scrolling now and then; false when the run ended meanwhile.
    private func stay(_ dwell: TimeInterval, scroll: Bool, visit: Int, run: Int,
                      using generator: inout some RandomNumberGenerator) async -> Bool {
        let begun = Date()
        let gestures = scroll ? WarmUpTiming.gestures(over: dwell, using: &generator) : []
        // The pointer drifts while the page is read, as a hand resting on a mouse does — never
        // during a gesture (the wheel scrolls where the pointer is).
        let drifts = WarmUpTiming.pointerMoves(over: dwell, avoiding: gestures, using: &generator)
        enum Event { case gesture(WarmUpTiming.Gesture), drift }
        let events = (gestures.map { (at: $0.at, event: Event.gesture($0)) } + drifts.map { (at: $0, event: Event.drift) })
            .sorted { $0.at < $1.at }
        for item in events {
            guard await wait(item.at - Date().timeIntervalSince(begun), run: run), let tab = liveTab(run) else { return false }
            // A tab the user put aside (another tab selected) has no window to scroll or point in.
            guard tab.isSelected else { continue }
            switch item.event {
            case .gesture(let gesture):
                if await self.scroll(gesture, in: tab, run: run) { update(visit, run: run) { $0.scrolls += 1 } }
            case .drift:
                await drift(in: tab, using: &generator)
            }
        }
        return await wait(dwell - Date().timeIntervalSince(begun), run: run)
    }

    /// A small move of the pointer to somewhere near where a person reads, on a curved path with a
    /// hand's tremor (`WarmUpPointerPath`). Only where trusted pointer events reach the page.
    private func drift(in tab: BrowserTab, using generator: inout some RandomNumberGenerator) async {
        guard let input, input.webView === tab.webView, tab.webView.window != nil else { return }
        let size = tab.webView.bounds.size
        guard size.width > 40, size.height > 40 else { return }
        let from = input.pointerViewportPoint()
            ?? CGPoint(x: size.width * Double.random(in: 0.3...0.7, using: &generator), y: size.height * 0.5)
        let to = CGPoint(x: min(max(from.x + Double.random(in: -220...220, using: &generator), 12), size.width - 12),
                         y: min(max(from.y + Double.random(in: -140...140, using: &generator), 12), size.height - 12))
        let distance = hypot(to.x - from.x, to.y - from.y)
        let steps = max(5, min(30, Int(distance / Double.random(in: 10...16, using: &generator))))
        let path = WarmUpPointerPath.path(from: WarmUpPoint(x: from.x, y: from.y), to: WarmUpPoint(x: to.x, y: to.y),
                                          steps: steps, using: &generator)
            .map { CGPoint(x: $0.x, y: $0.y) }
        _ = await input.move(along: path, interval: Double.random(in: 0.012...0.022, using: &generator))
    }

    private struct ScrollPosition: Equatable {
        var y: Double
        var room: Double
    }

    /// One gesture; true when the page scrolled (its position moved: a page growing as it loads
    /// is no scroll).
    private func scroll(_ gesture: WarmUpTiming.Gesture, in tab: BrowserTab, run: Int) async -> Bool {
        guard let before = await position(in: tab), liveTab(run) != nil else { return false }
        let down = gesture.deltas.reduce(0, +) > 0
        // Nothing to scroll that way (a short page, or already at the end).
        if down ? before.room < 4 : before.y < 4 { return false }
        if let input, input.webView === tab.webView, tab.webView.window != nil {
            for delta in gesture.deltas {
                guard input.wheel(delta), await wait(gesture.interval, run: run) else { break }
            }
            // The wheel's scrolling may still be running: give it a moment.
            guard await wait(0.25, run: run) else { return false }
            let after = await position(in: tab)
            guard liveTab(run) != nil else { return false }
            if let after, after.y != before.y {
                scrollInput = .native
                return true
            }
            log.notice("Wheel events did not scroll the page; scrolling from the robot's script world")
        }
        scrollInput = .script
        for delta in gesture.deltas {
            guard liveTab(run) != nil else { return false }
            _ = await script("window.scrollBy(0, delta); return true;", ["delta": delta], in: tab)
            guard await wait(gesture.interval, run: run) else { return false }
        }
        let after = await position(in: tab)
        return liveTab(run) != nil && after.map { $0.y != before.y } == true
    }

    private func position(in tab: BrowserTab) async -> ScrollPosition? {
        let value = await script("""
            const height = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
            return [window.scrollY, height - window.scrollY - window.innerHeight];
            """, [:], in: tab) as? [Double]
        guard let value, value.count == 2 else { return nil }
        return ScrollPosition(y: value[0], room: value[1])
    }

    // MARK: Cookie banners

    /// The "accept" buttons of the consent tools most sites use, by their own ids — OneTrust,
    /// Didomi, Quantcast, Cookiebot, Usercentrics (in its shadow root), TrustArc, Google's Funding
    /// Choices and Google's own consent page — and nothing else.
    private static let consentButtons = [
        "#onetrust-accept-btn-handler", "#didomi-notice-agree-button", ".qc-cmp2-summary-buttons button[mode=\"primary\"]",
        "#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll", "#CybotCookiebotDialogBodyButtonAccept",
        "button[data-testid=\"uc-accept-all-button\"]", "#truste-consent-button", ".fc-cta-consent", "button#L2AGLb",
    ]

    /// Presses a consent tool's "accept" once the banner is up (it often comes a moment after the
    /// page); true when one was pressed.
    private func acceptConsent(in tab: BrowserTab, run: Int) async -> Bool {
        guard await wait(Double.random(in: 1.2...2.2), run: run), liveTab(run) != nil else { return false }
        let pressed = await script("""
            const roots = [document];
            const uc = document.querySelector('#usercentrics-root');
            if (uc && uc.shadowRoot) roots.push(uc.shadowRoot);
            for (const root of roots) {
              for (const selector of selectors) {
                const button = root.querySelector(selector);
                if (!button) continue;
                const r = button.getBoundingClientRect();
                if (r.width < 1 || r.height < 1) continue;
                button.click();
                return true;
              }
            }
            return false;
            """, ["selectors": Self.consentButtons], in: tab) as? Bool
        guard pressed == true, liveTab(run) != nil else { return false }
        log.notice("A cookie banner was accepted")
        // The banner goes, and the page may reload part of itself.
        return await wait(Double.random(in: 0.8...1.6), run: run)
    }

    // MARK: Following a link

    private struct PageLinks: Decodable {
        struct Link: Decodable {
            var index: Int
            var link: WarmUpLink
        }

        var links: [Link]
        var width: Double
        var height: Double
    }

    /// Follows one link the policy allows, if the page has one in view, and stays on its page
    /// half as long: true then, false when there was nothing to follow (or its page did not load),
    /// nil when the run ended meanwhile. `hop` counts the links followed from the plan's page.
    private func follow(on page: WarmUpPlan.Page, visit: Int, hop: Int, plan: WarmUpPlan, run: Int,
                        using generator: inout some RandomNumberGenerator) async -> Bool? {
        guard let tab = liveTab(run) else { return nil }
        guard tab.isSelected, let pageURL = tab.url else { return false }
        let found = await links(in: tab)
        guard liveTab(run) != nil else { return nil }
        guard let found else { return false }
        // Each link judged by itself: the same address may also be on a link that opens a new
        // window or downloads.
        let viewport = (width: found.width, height: found.height)
        let allowed = found.links.filter { WarmUpLinkPolicy.allows($0.link, on: pageURL, kind: page.kind, viewport: viewport) }
        guard let choice = allowed.randomElement(using: &generator) else { return false }
        let failures = tab.failedNavigations
        let before = tab.url
        // A point inside the link, not always its middle.
        let point = CGPoint(x: choice.link.x + choice.link.width * Double.random(in: 0.3...0.7, using: &generator),
                            y: choice.link.y + choice.link.height * Double.random(in: 0.35...0.65, using: &generator))
        guard await click(choice, at: point, in: tab, run: run, using: &generator) else { return liveTab(run) == nil ? nil : false }
        let target = URL(string: choice.link.href, relativeTo: pageURL)?.absoluteURL
        update(visit, run: run) {
            if hop == 0 { $0.followed = target }
            if let target { $0.hops.append(target) }
        }
        guard let outcome = await waitForPage(in: tab, failuresBefore: failures, urlBefore: before, run: run, startTimeout: 5) else {
            return nil
        }
        if hop == 0 { update(visit, run: run) { $0.followedOutcome = outcome } }
        if isFailure(outcome) { return false }
        let dwell = dwellTime(plan, using: &generator) / 2
        update(visit, run: run) { $0.dwell += dwell }
        return await stay(dwell, scroll: plan.scroll, visit: visit, run: run, using: &generator) ? true : nil
    }

    /// The links in view, read in the robot's world (only those the pointer could reach: the
    /// link itself is what is under its middle).
    private func links(in tab: BrowserTab) async -> PageLinks? {
        let value = await script("""
            const out = [];
            const width = window.innerWidth, height = window.innerHeight;
            const anchors = document.querySelectorAll('a[href]');
            for (let index = 0; index < anchors.length && out.length < 300; index++) {
              const a = anchors[index];
              if (typeof a.href !== 'string') continue;
              const r = a.getBoundingClientRect();
              if (r.width < 1 || r.height < 1 || r.bottom <= 0 || r.top >= height || r.right <= 0 || r.left >= width) continue;
              const style = getComputedStyle(a);
              if (style.visibility !== 'visible' || style.pointerEvents === 'none') continue;
              // Hidden by an ancestor too (opacity is not inherited; a link no one can see is a trap).
              if (a.checkVisibility ? !a.checkVisibility({opacityProperty: true, visibilityProperty: true})
                                    : (() => { for (let e = a; e; e = e.parentElement) if (Number(getComputedStyle(e).opacity) < 0.1) return true; return false; })()) continue;
              const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
              if (!top || (top !== a && !a.contains(top))) continue;
              const text = (a.innerText || a.getAttribute('aria-label') || a.title || '').replace(/\\s+/g, ' ').trim().slice(0, 120);
              // The window it opens in: its own target, else the page's <base target>.
              const target = a.hasAttribute('target') ? a.target : ((document.querySelector('base[target]') || {}).target || '');
              out.push({index, link: {href: a.href, text, target, download: a.hasAttribute('download'),
                                      x: r.left, y: r.top, width: r.width, height: r.height}});
            }
            return JSON.stringify({links: out, width, height});
            """, [:], in: tab) as? String
        guard let data = value?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PageLinks.self, from: data)
    }

    /// Clicks the link: with mouse events when a trusted pointer move is seen to reach that very
    /// link, else with its `click()`. The moves are watched by a listener of the robot's world,
    /// which the page cannot see.
    private func click(_ choice: PageLinks.Link, at point: CGPoint, in tab: BrowserTab, run: Int,
                       using generator: inout some RandomNumberGenerator) async -> Bool {
        let arguments: [String: Any] = ["index": choice.index, "href": choice.link.href]
        let find = "const a = document.querySelectorAll('a[href]')[index]; if (!a || a.href !== href) return false;"
        switch await pointerClick(at: point, find: find, arguments: arguments, in: tab, run: run, using: &generator) {
        case true?:
            clickInput = .native
            return true
        case nil:
            return false
        case false?:
            break
        }
        guard liveTab(run) != nil else { return false }
        let clicked = await script(find + " a.click(); return true;", arguments, in: tab) as? Bool
        guard liveTab(run) != nil else { return false }
        if clicked == true { clickInput = .script }
        return clicked == true
    }

    /// Takes the pointer to `point` on a curved path, as a hand does, and clicks there when its
    /// trusted moves are seen to reach the element `find` names (as `a`; its script returns false
    /// when there is none): true then. False when they did not, or there is no window to point
    /// in; nil when the run ended meanwhile. The moves are watched by a listener of the robot's
    /// world, which the page cannot see.
    private func pointerClick(at point: CGPoint, find: String, arguments: [String: Any], in tab: BrowserTab, run: Int,
                              using generator: inout some RandomNumberGenerator) async -> Bool? {
        let webView = tab.webView
        guard let input, input.webView === webView, webView.window != nil else { return false }
        _ = await script("""
            const seen = globalThis.warmUpPointer = {target: null, trusted: false, moves: 0};
            seen.listener = (e) => { seen.target = e.target; seen.trusted = e.isTrusted; seen.moves++; };
            document.addEventListener('mousemove', seen.listener, {capture: true});
            return true;
            """, [:], in: tab)
        guard liveTab(run) != nil else { return nil }
        // From where the pointer was (somewhere on the page the first time), as a hand moves it.
        let size = webView.bounds.size
        let start = CGPoint(x: Double.random(in: 0.2...0.8, using: &generator) * size.width,
                            y: Double.random(in: 0.3...0.9, using: &generator) * size.height)
        let from = input.pointerViewportPoint() ?? start
        let distance = hypot(point.x - from.x, point.y - from.y)
        let steps = max(6, min(45, Int(distance / Double.random(in: 9...15, using: &generator))))
        let curve = WarmUpPointerPath.path(from: WarmUpPoint(x: from.x, y: from.y), to: WarmUpPoint(x: point.x, y: point.y),
                                           steps: steps, using: &generator).map { CGPoint(x: $0.x, y: $0.y) }
        let moved = await input.move(along: curve, interval: Double.random(in: 0.012...0.02, using: &generator))
        guard await wait(Double.random(in: 0.12...0.3, using: &generator), run: run) else { return nil }
        guard moved else { return false }
        let answer = await script(find + """
             const seen = globalThis.warmUpPointer;
             if (seen && seen.listener) document.removeEventListener('mousemove', seen.listener, {capture: true});
             const t = seen && seen.target;
             return [!!seen && seen.trusted && !!t && (t === a || a.contains(t)),
                     `${seen ? seen.moves : -1} moves, last on ${t ? (t.id || t.nodeName) : 'nothing'}, trusted ${!!seen && seen.trusted}`];
            """, arguments, in: tab) as? [Any]
        guard liveTab(run) != nil else { return nil }
        clickDiagnosis = "\(steps) moves sent to (\(Int(point.x)), \(Int(point.y))); the page's world saw \(answer?.last as? String ?? "no answer")"
        guard answer?.first as? Bool == true else {
            log.notice("The pointer's events did not reach the element; not clicked with them")
            return false
        }
        // The button always comes up again, even when the run ends meanwhile.
        await input.click(hold: Double.random(in: 0.06...0.14, using: &generator))
        return liveTab(run) == nil ? nil : true
    }

    // MARK: Typing a search

    private enum TypedSearch {
        /// Typed and sent: the results page's outcome.
        case typed(WarmUpVisit.Outcome)
        /// Not done as a person would do it: the results are to be opened by their address.
        case notTyped
        /// The run ended meanwhile.
        case ended
    }

    /// The search boxes of the engines' own pages, by their own names, then any search field.
    private static let searchBoxes = [
        "textarea[name=\"q\"]", "input[name=\"q\"]", "input[name=\"p\"]", "input[name=\"text\"]", "input[type=\"search\"]",
    ]

    /// Opens the engine's own page, clicks in its search box with the pointer, types `query` key
    /// by key on this Mac's keyboard layout with a person's pauses (`WarmUpTiming.keyGaps`), and
    /// presses Return. `.notTyped` — before anything is typed, or once the box does not hold
    /// exactly what was typed — whenever it cannot be done that way: a character no key of the
    /// layout types, the engine's page not loading, no box in view, the pointer's events not
    /// reaching it, nothing loading after Return. Never a script's click, focus or value.
    private func typeSearch(_ query: String, for page: WarmUpPlan.Page, in tab: BrowserTab, run: Int,
                            using generator: inout some RandomNumberGenerator) async -> TypedSearch {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine = SearchEngine(resultsURL: page.url), !text.isEmpty else { return .notTyped }
        // Every key on this layout, before anything is opened.
        let keys = text.compactMap { PageInput.key(typing: $0) }
        guard keys.count == text.count, let enter = PageInput.named["Enter"] else { return .notTyped }
        guard let input, input.webView === tab.webView, tab.webView.window != nil else { return .notTyped }
        guard let home = await load(engine.homeURL, in: tab, run: run) else { return .ended }
        guard home == .loaded else { return .notTyped }
        // Google's consent page, say, stands between the page and its box.
        _ = await acceptConsent(in: tab, run: run)
        guard liveTab(run) != nil else { return .ended }
        let found = await script("""
            const width = window.innerWidth, height = window.innerHeight;
            for (const selector of selectors) {
              const all = Array.from(document.querySelectorAll(selector));
              for (let index = 0; index < all.length; index++) {
                const e = all[index];
                if (e.disabled || e.readOnly) continue;
                const r = e.getBoundingClientRect();
                if (r.width < 40 || r.height < 12 || r.bottom <= 0 || r.top >= height || r.right <= 0 || r.left >= width) continue;
                const style = getComputedStyle(e);
                if (style.visibility !== 'visible' || style.pointerEvents === 'none') continue;
                const top = document.elementFromPoint(r.left + Math.min(r.width * 0.3, 120), r.top + r.height / 2);
                if (!top || (top !== e && !e.contains(top))) continue;
                return [selector, index, r.left, r.top, r.width, r.height];
              }
            }
            return null;
            """, ["selectors": Self.searchBoxes], in: tab) as? [Any]
        guard liveTab(run) != nil else { return .ended }
        let box = found.map { $0.dropFirst(2).compactMap { ($0 as? NSNumber)?.doubleValue } } ?? []
        guard let found, found.count == 6, let selector = found[0] as? String, let index = (found[1] as? NSNumber)?.intValue,
              box.count == 4 else {
            log.notice("No search box in view on the engine's page; its results are opened by their address")
            return .notTyped
        }
        // A person looks at the page a moment before reaching for the box, and clicks in its left part.
        guard await wait(Double.random(in: 0.4...1.2, using: &generator), run: run) else { return .ended }
        let point = CGPoint(x: box[0] + min(box[2] * Double.random(in: 0.12...0.4, using: &generator), 160),
                            y: box[1] + box[3] * Double.random(in: 0.35...0.65, using: &generator))
        let arguments: [String: Any] = ["selector": selector, "index": index]
        let find = "const a = document.querySelectorAll(selector)[index]; if (!a) return false;"
        switch await pointerClick(at: point, find: find, arguments: arguments, in: tab, run: run, using: &generator) {
        case nil: return .ended
        case false?: return .notTyped
        case true?: break
        }
        guard await wait(0.15, run: run) else { return .ended }
        let focused = await script(find + " return document.activeElement === a;", arguments, in: tab) as? Bool
        guard liveTab(run) != nil else { return .ended }
        guard focused == true else {
            log.notice("The click did not put the search box in focus; its results are opened by their address")
            return .notTyped
        }
        for (key, gap) in zip(keys, WarmUpTiming.keyGaps(for: text, using: &generator)) {
            guard await wait(gap, run: run), liveTab(run) != nil else { return .ended }
            await input.press(key, hold: Double.random(in: 0.04...0.11, using: &generator))
        }
        // What the box holds is what was typed (a layout that types otherwise, an input method):
        // else nothing is sent.
        guard await wait(Double.random(in: 0.3...0.9, using: &generator), run: run) else { return .ended }
        let value = await script(find + " return typeof a.value === 'string' ? a.value : null;", arguments, in: tab) as? String
        guard let tab = liveTab(run) else { return .ended }
        guard value?.trimmingCharacters(in: .whitespacesAndNewlines) == text else {
            log.notice("The search box does not hold what was typed; its results are opened by their address")
            return .notTyped
        }
        let failures = tab.failedNavigations
        let before = tab.url
        await input.press(enter, hold: Double.random(in: 0.05...0.12, using: &generator))
        guard let outcome = await waitForPage(in: tab, failuresBefore: failures, urlBefore: before, run: run, startTimeout: 6) else {
            return .ended
        }
        guard let after = liveTab(run)?.url, after != before else { return .notTyped }
        log.notice("A search was typed on the engine's page")
        return .typed(outcome)
    }

    // MARK: Scripts in the robot's world

    /// Runs `body` in the robot's content world of the tab's main frame; nil when it fails, does
    /// not answer within `limits.scriptTimeout` (a page busy, or gone) or the run is stopped
    /// meanwhile (the answer is not waited for).
    private func script(_ body: String, _ arguments: [String: Any], in tab: BrowserTab) async -> Any? {
        let timeout = limits.scriptTimeout
        let answer = OneAnswer()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
                answer.wait(continuation)
                tab.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Self.world) { result in
                    answer.give(try? result.get())
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { answer.give(nil) }
            }
        } onCancel: {
            answer.give(nil)
        }
    }
}

/// The first answer of a script, from whichever comes first: the page, the timeout, a Stop.
private final class OneAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Any?, Never>?
    private var given = false
    private var early: Any?

    func wait(_ continuation: CheckedContinuation<Any?, Never>) {
        lock.lock()
        guard !given else {
            let value = early
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func give(_ value: Any?) {
        lock.lock()
        guard !given else {
            lock.unlock()
            return
        }
        given = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { early = value }
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
