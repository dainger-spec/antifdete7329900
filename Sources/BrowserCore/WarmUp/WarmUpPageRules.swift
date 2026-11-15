import Foundation

/// What the robot's reader reports of a page it has just come to, for the rules below. Read in
/// the robot's own content world (`WarmUpPageScripts.signals`); the rules are here, where they
/// are tested.
public struct WarmUpPageSignals: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    /// Characters of visible text.
    public var textLength: Double
    /// Marks of a check or a block the reader found, by name (`WarmUpBlockPage.marks`).
    public var marks: [String]
    /// The page has a password field in view, or a card number's.
    public var hasPasswordField: Bool
    public var hasCardField: Bool

    public init(url: String, title: String = "", textLength: Double = 0, marks: [String] = [],
                hasPasswordField: Bool = false, hasCardField: Bool = false) {
        self.url = url
        self.title = title
        self.textLength = textLength
        self.marks = marks
        self.hasPasswordField = hasPasswordField
        self.hasCardField = hasCardField
    }
}

/// A page that asks whether the visitor is a robot, or refuses them: the robot answers nothing
/// and leaves at once — and says so in the run's report, since that is the one thing a warm-up
/// learns about a proxy's address.
public enum WarmUpBlockPage {
    /// What the reader looks for, by name: an element the check's own page has (a selector), or
    /// words of its title. A small "protected by reCAPTCHA" badge on an ordinary page is no check:
    /// the widgets count only on a page with next to no text of its own (`wallTextLimit`).
    public static let marks: [(name: String, selector: String)] = [
        ("cloudflare", "#challenge-form, #challenge-running, #cf-challenge-running, .cf-turnstile-wrapper, #cf-please-wait, script[src*=\"/cdn-cgi/challenge-platform/\"]"),
        ("google", "form#captcha-form, #recaptcha[data-sitekey], form[action*=\"/sorry/\"]"),
        ("perimeterx", "#px-captcha, .px-captcha-container"),
        ("datadome", "iframe[src*=\"captcha-delivery.com\"], script[src*=\"captcha-delivery.com\"]"),
        ("recaptcha", "iframe[src*=\"recaptcha/api2/bframe\"], iframe[src*=\"recaptcha/enterprise/bframe\"], .g-recaptcha"),
        ("hcaptcha", "iframe[src*=\"hcaptcha.com/captcha\"], .h-captcha"),
        ("yandex", "form[action*=\"/checkcaptcha\"], .CheckboxCaptcha, .AdvancedCaptcha"),
        ("amazon", "form[action*=\"/errors/validateCaptcha\"]"),
        ("akamai", "#sec-cpt-if, #sec-container"),
    ]

    /// Titles of pages that are a check or a refusal whatever else they hold (lower case).
    static let titles: [(name: String, words: String)] = [
        ("cloudflare", "just a moment"), ("cloudflare", "attention required"), ("blocked", "access denied"), ("blocked", "access to this page has been denied"),
        ("blocked", "403 forbidden"), ("blocked", "pardon our interruption"), ("blocked", "are you a robot"), ("blocked", "are you a human"),
        ("google", "unusual traffic"), ("yandex", "ой!"), ("blocked", "robot check"),
    ]

    /// Marks that are a check by themselves; the others are widgets a page may also carry in a form
    /// of its own, and count only on a page with little text.
    static let wallsAlone: Set<String> = ["cloudflare", "google", "perimeterx", "datadome", "yandex", "amazon", "akamai"]
    public static let wallTextLimit = 600.0

    /// The name of the check the page is ("cloudflare", "google", "blocked"…), or nil for a page to read.
    public static func kind(_ signals: WarmUpPageSignals) -> String? {
        if let url = URL(string: signals.url) {
            let path = url.path.lowercased()
            if path.hasPrefix("/sorry/") || path.contains("/showcaptcha") || path.contains("/checkcaptcha") { return (url.host ?? "").contains("yandex") || (url.host ?? "").hasSuffix("ya.ru") ? "yandex" : "google" }
            if path.contains("/cdn-cgi/challenge-platform") { return "cloudflare" }
        }
        let title = signals.title.lowercased()
        if let match = titles.first(where: { title.contains($0.words) }) { return match.name }
        if let alone = signals.marks.first(where: { wallsAlone.contains($0) }) { return alone }
        if signals.textLength < wallTextLimit, let widget = signals.marks.first { return widget }
        return nil
    }
}

/// A page the robot does nothing on: where a person signs in or pays. It never types a password or
/// a card, and it does not stay to scroll and click where one is asked for either.
public enum WarmUpSensitivePage {
    static let pathWords = ["checkout", "check-out", "payment", "billing", "/pay/", "/cart", "/basket", "kasse", "warenkorb", "paiement", "panier",
                            "koszyk", "zamowienie", "login", "log-in", "signin", "sign-in", "sign_in", "signup", "sign-up", "register", "anmelden", "connexion", "logowanie"]

    public static func isSensitive(_ signals: WarmUpPageSignals) -> Bool {
        if signals.hasPasswordField || signals.hasCardField { return true }
        guard let url = URL(string: signals.url) else { return false }
        let path = (url.path + "/").lowercased()
        return pathWords.contains(where: path.contains)
    }
}

/// The "accept" buttons of the consent tools sites use, by the tools' own names for them, and the
/// strict rule for a banner of no tool the robot knows.
public enum WarmUpConsent {
    /// A tool's buttons: accepting everything, and — where the tool has one in its first layer —
    /// keeping only what is necessary.
    public struct Tool: Equatable, Sendable {
        public var name: String
        public var accept: [String]
        public var reject: [String]
    }

    public static let tools: [Tool] = [
        Tool(name: "onetrust", accept: ["#onetrust-accept-btn-handler"], reject: ["#onetrust-reject-all-handler"]),
        Tool(name: "didomi", accept: ["#didomi-notice-agree-button"], reject: ["#didomi-notice-disagree-button"]),
        Tool(name: "quantcast", accept: [".qc-cmp2-summary-buttons button[mode=\"primary\"]"], reject: [".qc-cmp2-summary-buttons button[mode=\"secondary\"]"]),
        Tool(name: "cookiebot", accept: ["#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll", "#CybotCookiebotDialogBodyButtonAccept"], reject: ["#CybotCookiebotDialogBodyButtonDecline"]),
        Tool(name: "usercentrics", accept: ["button[data-testid=\"uc-accept-all-button\"]"], reject: ["button[data-testid=\"uc-deny-all-button\"]"]),
        Tool(name: "trustarc", accept: ["#truste-consent-button"], reject: ["#truste-consent-required"]),
        Tool(name: "funding-choices", accept: [".fc-cta-consent"], reject: [".fc-cta-do-not-consent"]),
        Tool(name: "google", accept: ["button#L2AGLb"], reject: ["button#W0wltc"]),
        Tool(name: "cookieyes", accept: [".cky-btn-accept"], reject: [".cky-btn-reject"]),
        Tool(name: "complianz", accept: [".cmplz-btn.cmplz-accept"], reject: [".cmplz-btn.cmplz-deny"]),
        Tool(name: "borlabs", accept: ["#BorlabsCookieBox a[data-cookie-accept-all]", "#BorlabsCookieBox ._brlbs-btn-accept-all"], reject: ["#BorlabsCookieBox a[data-cookie-refuse]"]),
        Tool(name: "osano", accept: [".osano-cm-accept-all"], reject: [".osano-cm-denyAll"]),
        Tool(name: "klaro", accept: [".klaro .cm-btn-accept-all", ".klaro .cm-btn-success"], reject: [".klaro .cm-btn-decline"]),
        Tool(name: "iubenda", accept: [".iubenda-cs-accept-btn"], reject: [".iubenda-cs-reject-btn"]),
        Tool(name: "termly", accept: ["[data-tid=\"banner-accept\"]"], reject: ["[data-tid=\"banner-decline\"]"]),
        Tool(name: "consentmanager", accept: [".cmpboxbtnyes"], reject: [".cmpboxbtnno"]),
        Tool(name: "cookie-script", accept: ["#cookiescript_accept"], reject: ["#cookiescript_reject"]),
        Tool(name: "hubspot", accept: ["#hs-eu-confirmation-button"], reject: ["#hs-eu-decline-button"]),
        Tool(name: "axeptio", accept: ["#axeptio_btn_acceptAll"], reject: ["#axeptio_btn_dismiss"]),
        Tool(name: "tarteaucitron", accept: ["#tarteaucitronPersonalize2", "#tarteaucitronAllAllowed"], reject: ["#tarteaucitronAllDenied2"]),
        Tool(name: "civic", accept: ["#ccc-notify-accept", "#ccc-recommended-settings"], reject: ["#ccc-notify-reject"]),
        Tool(name: "cookie-notice", accept: ["#cn-accept-cookie"], reject: ["#cn-refuse-cookie"]),
        Tool(name: "cookie-law-info", accept: ["#wt-cli-accept-all-btn", "#cookie_action_close_header"], reject: ["#wt-cli-reject-btn"]),
        Tool(name: "amazon", accept: ["#sp-cc-accept"], reject: ["#sp-cc-rejectall-link"]),
        Tool(name: "ebay", accept: ["#gdpr-banner-accept"], reject: ["#gdpr-banner-decline"]),
        Tool(name: "bing", accept: ["#bnp_btn_accept"], reject: ["#bnp_btn_reject"]),
    ]

    /// For a banner of no known tool: what its container's id or class must speak of, and what its
    /// button must say — exactly, in whole (lower case, trimmed) — to be pressed. The banner must
    /// also be fixed or sticky on the page and the button no part of a form with fields: a
    /// "Buy — accept the terms" button is never a cookie banner's.
    public static let containerWords = ["cookie", "consent", "gdpr", "privacy-banner", "cmp"]
    public static let acceptWords: Set<String> = [
        "accept", "accept all", "accept all cookies", "accept cookies", "allow all", "allow all cookies", "allow cookies", "agree", "i agree", "i accept", "got it", "ok",
        "alle akzeptieren", "akzeptieren", "alle cookies akzeptieren", "zustimmen", "einverstanden", "alles akzeptieren",
        "tout accepter", "accepter", "j'accepte", "accepter et fermer", "accepter tout",
        "aceptar", "aceptar todo", "aceptar todas", "aceptar cookies", "acepto",
        "accetta", "accetta tutto", "accetta tutti", "accetto",
        "akceptuję", "zaakceptuj", "zaakceptuj wszystkie", "akceptuj wszystkie", "zgadzam się",
        "aceitar", "aceitar tudo", "aceitar todos", "aceito",
        "accepteren", "alles accepteren", "akkoord", "alle cookies accepteren",
        "принять", "принять все", "принять всё", "согласен", "хорошо", "понятно",
        "kabul et", "tümünü kabul et", "godkänn alla", "acceptera alla", "godta alle", "accepter alle", "hyväksy kaikki", "souhlasím", "přijmout vše", "elfogadom", "accept toate", "αποδοχή όλων",
    ]

    /// Whether a generic banner's button may be pressed.
    public static func allowsGeneric(buttonText: String, containerName: String, isFixed: Bool, insideFormWithFields: Bool) -> Bool {
        guard isFixed, !insideFormWithFields else { return false }
        let name = containerName.lowercased()
        guard containerWords.contains(where: name.contains) else { return false }
        let text = buttonText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return acceptWords.contains(text)
    }

    /// What is done with the banner of this page of the run: `accept` always accepts, `leave`
    /// never touches it, and `asPeople` accepts about nine times in ten and otherwise keeps only
    /// what is necessary where the banner offers that.
    public enum Action: Equatable, Sendable { case accept, reject, leave }

    public static func action(_ choice: WarmUpConsentChoice, using generator: inout some RandomNumberGenerator) -> Action {
        switch choice {
        case .accept: return .accept
        case .leave: return .leave
        case .asPeople: return Double.random(in: 0..<1, using: &generator) < 0.88 ? .accept : .reject
        }
    }
}

extension WarmUpLinkPolicy {
    /// Words of a link or its address that take a visitor to signing in or to an account: nothing
    /// to read there, and where robots are looked for.
    static let accountWords = [
        "login", "log-in", "log in", "signin", "sign-in", "sign in", "signup", "sign-up", "sign up", "register", "registration", "my account", "account",
        "anmelden", "einloggen", "registrieren", "konto", "connexion", "se connecter", "s'inscrire", "iniciar sesión", "registrarse", "accedi", "registrati",
        "zaloguj", "zarejestruj", "entrar", "cadastre", "inloggen", "войти", "вход", "регистрация", "личный кабинет", "giriş",
    ]
    /// Pages nobody goes to in order to read.
    static let legalWords = [
        "impressum", "datenschutz", "privacy", "terms", "agb", "cookie", "legal", "imprint", "mentions légales", "aviso legal", "polityka prywatności",
        "regulamin", "conditions", "nutzungsbedingungen", "contact", "kontakt", "about us", "über uns", "careers", "jobs", "press", "advertis", "sitemap", "help", "hilfe", "faq",
        "конфиденциальност", "условия", "о компании", "реклама",
    ]

    /// Where a link is on its page, as the reader reports it.
    public struct Placement: Equatable, Sendable {
        /// Inside the page's main part (`main`, `article`, a heading) rather than its navigation,
        /// header, footer or a side column.
        public var inContent: Bool
        public var inChrome: Bool

        public init(inContent: Bool, inChrome: Bool) {
            self.inContent = inContent
            self.inChrome = inChrome
        }
    }

    /// Whether the robot may click the link, sign-in and account links refused too.
    public static func allowsReading(_ link: WarmUpLink, on page: URL, kind: WarmUpPlan.Page.Kind,
                                     viewport: (width: Double, height: Double)) -> Bool {
        guard allows(link, on: page, kind: kind, viewport: viewport) else { return false }
        let url = URL(string: link.href, relativeTo: page)?.absoluteURL
        let words = (link.text + " " + (url?.path ?? "")).lowercased()
        return !accountWords.contains(where: words.contains)
    }

    /// How likely a visitor is to follow the link, as a weight (0: never): a headline in the
    /// page's main part first — words enough to be one, a size to be seen — the navigation's and
    /// the footer's links seldom, the legal pages hardly ever.
    public static func weight(_ link: WarmUpLink, placement: Placement) -> Double {
        let text = link.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var weight = 1.0
        if placement.inContent { weight *= 4 }
        if placement.inChrome { weight *= 0.2 }
        let count = text.count
        if count >= 25 { weight *= 2.5 } else if count >= 12 { weight *= 1.5 } else if count < 5 { weight *= 0.4 }
        if link.height >= 18, link.width >= 120 { weight *= 1.3 }
        let lower = (text + " " + link.href).lowercased()
        if legalWords.contains(where: lower.contains) { weight *= 0.03 }
        return weight
    }

    /// One of `links` by their weights (`weights[i]` for `links[i]`); nil when none has any.
    public static func pick<Link>(_ links: [Link], weights: [Double], using generator: inout some RandomNumberGenerator) -> Link? {
        let total = zip(links, weights).reduce(0.0) { $0 + max(0, $1.1) }
        guard total > 0 else { return nil }
        var at = Double.random(in: 0..<total, using: &generator)
        for (link, weight) in zip(links, weights) where weight > 0 {
            if at < weight { return link }
            at -= weight
        }
        return links.last
    }

    /// The search result that is `site`'s own, among the links of a results page: the first whose
    /// address is on that site (its registrable domain).
    public static func result<Link>(for site: String, among links: [Link], href: (Link) -> String, on page: URL) -> Link? {
        let wanted = site.lowercased()
        return links.first { link in
            guard let url = URL(string: href(link), relativeTo: page)?.absoluteURL else { return false }
            return WarmUpLinkPolicy.site(of: url) == wanted
        }
    }

    /// What a person types to find a site: its name without the ending ("spiegel" for spiegel.de,
    /// "bbc" for bbc.co.uk), the whole host for a name too short to find anything by.
    public static func searchWords(forSite address: String) -> String {
        guard let url = WarmUpPlan.webURL(address), let host = url.host?.lowercased() else { return address }
        let site = PublicSuffixList.registrableDomain(of: host) ?? host
        let name = site.split(separator: ".").first.map(String.init) ?? site
        return name.count >= 4 ? name : site
    }
}
