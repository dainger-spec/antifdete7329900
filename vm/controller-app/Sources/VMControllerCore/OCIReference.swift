import Foundation

/// A parsed OCI image reference like
/// "ghcr.io/cirruslabs/macos-sonoma-base:latest" — enough to query the registry
/// for the tag's current digest, so we can tell whether a newer base exists.
public struct OCIReference: Equatable, Sendable {
    public let registry: String
    public let repository: String
    public let tag: String

    public init?(_ raw: String) {
        var ref = raw.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return nil }

        var tag = "latest"
        if let at = ref.range(of: "@") {               // name@sha256:… (digest ref)
            tag = String(ref[at.upperBound...])
            ref = String(ref[..<at.lowerBound])
        } else if let colon = ref.lastIndex(of: ":"),
                  !ref[ref.index(after: colon)...].contains("/") {   // :tag, not a host:port
            tag = String(ref[ref.index(after: colon)...])
            ref = String(ref[..<colon])
        }

        let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
        let registry: String
        let repository: String
        if parts.count == 2, parts[0].contains(".") || parts[0].contains(":") {
            registry = parts[0]
            repository = parts[1]
        } else {
            registry = "docker.io"
            repository = ref
        }
        guard !repository.isEmpty, !tag.isEmpty else { return nil }

        self.registry = registry
        self.repository = repository
        self.tag = tag
    }

    public var manifestURL: URL? {
        URL(string: "https://\(registry)/v2/\(repository)/manifests/\(tag)")
    }

    /// Standard Docker-registry anonymous token endpoint (ghcr.io and others).
    public var tokenURL: URL? {
        URL(string: "https://\(registry)/token?service=\(registry)&scope=repository:\(repository):pull")
    }
}
