import Foundation

/// One session: its own WebKit data store (cookies, storage, cache), tabs, history, proxy and
/// settings. The store is `WKWebsiteDataStore(forIdentifier: storeID)` (iOS 17).
public struct Session: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var storeID: UUID
    public var name: String
    public var notes: String
    public var tags: [String]
    public var proxyID: UUID?
    public var settings: SessionSettings
    public var createdAt: Date
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(), storeID: UUID = UUID(), name: String, notes: String = "", tags: [String] = [],
                proxyID: UUID? = nil, settings: SessionSettings = SessionSettings(), createdAt: Date = Date(),
                lastOpenedAt: Date? = nil) {
        self.id = id
        self.storeID = storeID
        self.name = name
        self.notes = notes
        self.tags = tags
        self.proxyID = proxyID
        self.settings = settings
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
    }
}

/// What a session's pages see and how its address bar searches.
public struct SessionSettings: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngine
    public var userAgent: UserAgentChoice
    /// Time zone and language follow the proxy's exit country unless set by hand.
    public var locale: LocaleChoice
    public var canvas: FingerprintMode
    public var webGL: FingerprintMode
    public var audio: FingerprintMode
    /// The noise seed: stable for the session's whole life, different between sessions.
    public var noiseSeed: String

    public init(searchEngine: SearchEngine = .google, userAgent: UserAgentChoice = .thisDevice,
                locale: LocaleChoice = .proxyCountry, canvas: FingerprintMode = .real, webGL: FingerprintMode = .real,
                audio: FingerprintMode = .real, noiseSeed: String = UUID().uuidString) {
        self.searchEngine = searchEngine
        self.userAgent = userAgent
        self.locale = locale
        self.canvas = canvas
        self.webGL = webGL
        self.audio = audio
        self.noiseSeed = noiseSeed
    }
}

public enum FingerprintMode: String, Codable, CaseIterable, Sendable {
    case off, real, noise
}

public enum LocaleChoice: Codable, Equatable, Sendable {
    /// From the proxy's exit country (its check); the device's own when there is no proxy or check.
    case proxyCountry
    /// Set by hand.
    case manual(timeZone: String, language: String)
    /// The device's own: nothing is changed.
    case device
}

public enum UserAgentChoice: Codable, Equatable, Sendable {
    /// What Safari on this iPhone sends: WebKit's own string with Safari's application name.
    case thisDevice
    case preset(String)
    case custom(String)
}

public enum ProxyKind: String, Codable, CaseIterable, Sendable {
    case http, socks5
}

/// An entry of the proxy list. The password is kept in the Keychain, not here.
public struct ProxyEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var host: String
    public var port: Int
    public var username: String
    public var hasPassword: Bool
    public var check: ProxyCheck?

    public init(id: UUID = UUID(), name: String = "", kind: ProxyKind, host: String, port: Int, username: String = "",
                hasPassword: Bool = false, check: ProxyCheck? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.hasPassword = hasPassword
        self.check = check
    }

    /// What the list shows when the entry has no name of its own.
    public var displayName: String { name.isEmpty ? "\(host):\(port)" : name }
}

/// What the last check of a proxy found.
public struct ProxyCheck: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var alive: Bool
    public var exitIP: String?
    /// ISO 3166-1 alpha-2, upper case.
    public var country: String?
    public var timeZone: String?
    public var udp: UDPSupport
    public var error: String?

    public init(checkedAt: Date = Date(), alive: Bool, exitIP: String? = nil, country: String? = nil, timeZone: String? = nil,
                udp: UDPSupport = .unchecked, error: String? = nil) {
        self.checkedAt = checkedAt
        self.alive = alive
        self.exitIP = exitIP
        self.country = country
        self.timeZone = timeZone
        self.udp = udp
        self.error = error
    }
}

public enum UDPSupport: String, Codable, Sendable {
    case supported, unsupported, unchecked
}

/// One open tab, as kept between launches.
public struct TabRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var url: String?
    public var title: String
    /// WKWebView.interactionState (its back/forward list), archived.
    public var interactionState: Data?

    public init(id: UUID = UUID(), url: String? = nil, title: String = "", interactionState: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.interactionState = interactionState
    }
}

public struct SessionTabs: Codable, Equatable, Sendable {
    public var tabs: [TabRecord]
    public var selected: UUID?

    public init(tabs: [TabRecord] = [], selected: UUID? = nil) {
        self.tabs = tabs
        self.selected = selected
    }
}

public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var visitedAt: Date

    public init(id: UUID = UUID(), url: String, title: String, visitedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
    }
}
