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
/// * While its window is the key window, it scrolls with wheel events sent to the web view, as
///   a mouse with smooth scrolling would, and clicks with mouse events at the link, after a
///   trusted pointer move was seen to reach that very link (by a listener of its own world). Otherwise (another app in
///   front, or the events did not reach the page) it scrolls with `scrollBy` from its world —
///   pages then see the scrolling but no wheel — and clicks with the link's `click()`, an
///   untrusted click. Which way it last went is reported (`scrollInput`, `clickInput`).
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
        return WarmUpStatus(phase: phase, visited: visited, total: pageCount, failed: failed,
                            cookies: cookiesCollected, secondsRemaining: secondsRemaining,
                            currentHost: isRunning ? visits.last?.url.host : nil,
                            sites: isRunning ? nil : cookieSites)
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
        let pages = plan.pages().pages
        guard !pages.isEmpty else { return false }
        let controller = session.openOffscreenWindow()
        guard let tab = controller.tabs.first else {
            log.error("Warm-up could not open its own window")
            return false
        }
        offscreenWindow = controller
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
            guard let outcome = await load(page.url, in: tab, run: run), isCurrent(run) else { return }
            update(index, run: run) {
                $0.outcome = outcome
                if outcome == .loaded { $0.loadedAt = Date() }
                $0.title = tab.webView.title ?? ""
            }
            // A page that did not load is left at once (its error page is no visit).
            if !isFailure(outcome) {
                let dwell = dwellTime(plan, using: &generator)
                update(index, run: run) { $0.dwell = dwell }
                guard await stay(dwell, scroll: plan.scroll, visit: index, run: run, using: &generator) else { return }
                if plan.followLinks {
                    guard await follow(on: page, visit: index, plan: plan, run: run, using: &generator) else { return }
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
        if scroll {
            for gesture in WarmUpTiming.gestures(over: dwell, using: &generator) {
                guard await wait(gesture.at - Date().timeIntervalSince(begun), run: run), let tab = liveTab(run) else { return false }
                // A tab the user put aside (another tab selected) has no window to scroll in.
                guard tab.isSelected else { continue }
                if await self.scroll(gesture, in: tab, run: run) { update(visit, run: run) { $0.scrolls += 1 } }
            }
        }
        return await wait(dwell - Date().timeIntervalSince(begun), run: run)
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
        if tab.webView.window?.isKeyWindow == true {
            for delta in gesture.deltas {
                guard sendWheel(delta, to: tab.webView), await wait(gesture.interval, run: run) else { break }
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

    /// A wheel event of `delta` points (positive: down) at the middle of the web view, as a
    /// mouse with smooth scrolling sends it.
    private func sendWheel(_ delta: Double, to webView: WKWebView) -> Bool {
        guard let window = webView.window,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(-delta.rounded()), wheel2: 0, wheel3: 0) else { return false }
        let inWindow = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        // Quartz puts the origin at the top left of the main screen.
        let mainHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        event.location = CGPoint(x: onScreen.x, y: mainHeight - onScreen.y)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let wheel = NSEvent(cgEvent: event) else { return false }
        webView.scrollWheel(with: wheel)
        return true
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
    /// half as long; false when the run ended meanwhile.
    private func follow(on page: WarmUpPlan.Page, visit: Int, plan: WarmUpPlan, run: Int,
                        using generator: inout some RandomNumberGenerator) async -> Bool {
        guard let tab = liveTab(run) else { return false }
        guard tab.isSelected, let pageURL = tab.url else { return true }
        let found = await links(in: tab)
        guard liveTab(run) != nil else { return false }
        guard let found else { return true }
        // Each link judged by itself: the same address may also be on a link that opens a new
        // window or downloads.
        let viewport = (width: found.width, height: found.height)
        let allowed = found.links.filter { WarmUpLinkPolicy.allows($0.link, on: pageURL, kind: page.kind, viewport: viewport) }
        guard let choice = allowed.randomElement(using: &generator) else { return true }
        let failures = tab.failedNavigations
        let before = tab.url
        // A point inside the link, not always its middle.
        let point = CGPoint(x: choice.link.x + choice.link.width * Double.random(in: 0.3...0.7, using: &generator),
                            y: choice.link.y + choice.link.height * Double.random(in: 0.35...0.65, using: &generator))
        guard await click(choice, at: point, in: tab, run: run, using: &generator) else { return liveTab(run) != nil }
        update(visit, run: run) { $0.followed = URL(string: choice.link.href, relativeTo: pageURL)?.absoluteURL }
        guard let outcome = await waitForPage(in: tab, failuresBefore: failures, urlBefore: before, run: run, startTimeout: 5) else {
            return false
        }
        update(visit, run: run) { $0.followedOutcome = outcome }
        if isFailure(outcome) { return true }
        let dwell = dwellTime(plan, using: &generator) / 2
        update(visit, run: run) { $0.dwell += dwell }
        return await stay(dwell, scroll: plan.scroll, visit: visit, run: run, using: &generator)
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

    /// How mouse events are handed to the web view: made from Quartz events (as the wheel's) and
    /// given to the view, made by AppKit and given to the view, or to its window (which passes
    /// them on as it does the system's).
    private enum Route: CaseIterable {
        case quartz
        case view
        case window
    }

    /// Clicks the link: with mouse events when a trusted pointer move is seen to reach that very
    /// link, else with its `click()`. The move is watched by a one-shot listener of the robot's
    /// world, which the page cannot see.
    private func click(_ choice: PageLinks.Link, at point: CGPoint, in tab: BrowserTab, run: Int,
                       using generator: inout some RandomNumberGenerator) async -> Bool {
        let webView = tab.webView
        let arguments: [String: Any] = ["index": choice.index, "href": choice.link.href]
        let find = "const a = document.querySelectorAll('a[href]')[index]; if (!a || a.href !== href) return false;"
        if webView.window?.isKeyWindow == true, let location = windowLocation(of: point, in: webView) {
            for route in Route.allCases {
                _ = await script("""
                    const seen = globalThis.warmUpPointer = {target: null, trusted: false};
                    document.addEventListener('mousemove', (e) => { seen.target = e.target; seen.trusted = e.isTrusted; },
                                              {capture: true, once: true});
                    return true;
                    """, [:], in: tab)
                guard liveTab(run) != nil else { return false }
                send(.mouseMoved, at: location, to: webView, via: route)
                guard await wait(Double.random(in: 0.15...0.4, using: &generator), run: run) else { return false }
                let reached = await script(find + """
                     const seen = globalThis.warmUpPointer;
                     return !!seen && seen.trusted && !!seen.target && (seen.target === a || a.contains(seen.target));
                    """, arguments, in: tab) as? Bool
                guard liveTab(run) != nil else { return false }
                if reached == true {
                    send(.leftMouseDown, at: location, to: webView, via: route)
                    // The button always comes up again, even when the run ends meanwhile.
                    let held = await wait(Double.random(in: 0.06...0.14, using: &generator), run: run)
                    send(.leftMouseUp, at: location, to: webView, via: route)
                    guard held else { return false }
                    clickInput = .native
                    return true
                }
            }
            log.notice("The pointer's events did not reach the link; clicking from the robot's script world")
        }
        guard liveTab(run) != nil else { return false }
        let clicked = await script(find + " a.click(); return true;", arguments, in: tab) as? Bool
        guard liveTab(run) != nil else { return false }
        if clicked == true { clickInput = .script }
        return clicked == true
    }

    /// Where the viewport point `point` (CSS pixels) is in the web view's window.
    private func windowLocation(of point: CGPoint, in webView: WKWebView) -> NSPoint? {
        guard webView.window != nil else { return nil }
        let scale = webView.pageZoom * webView.magnification
        let x = point.x * scale, y = point.y * scale
        let inView = NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y)
        return webView.convert(inView, to: nil)
    }

    private func send(_ type: NSEvent.EventType, at location: NSPoint, to webView: WKWebView, via route: Route) {
        guard let window = webView.window, let event = mouseEvent(type, at: location, in: window, quartz: route == .quartz) else { return }
        if route == .window {
            window.sendEvent(event)
            return
        }
        switch type {
        case .mouseMoved: webView.mouseMoved(with: event)
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        default: break
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at location: NSPoint, in window: NSWindow, quartz: Bool) -> NSEvent? {
        guard quartz else {
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                                      pressure: type == .leftMouseDown ? 1 : 0)
        }
        let quartzType: CGEventType
        switch type {
        case .leftMouseDown: quartzType = .leftMouseDown
        case .leftMouseUp: quartzType = .leftMouseUp
        default: quartzType = .mouseMoved
        }
        let onScreen = window.convertPoint(toScreen: location)
        // Quartz puts the origin at the top left of the main screen.
        let mainHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        guard let event = CGEvent(mouseEventSource: nil, mouseType: quartzType,
                                  mouseCursorPosition: CGPoint(x: onScreen.x, y: mainHeight - onScreen.y), mouseButton: .left) else { return nil }
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        if quartzType != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        return NSEvent(cgEvent: event)
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
