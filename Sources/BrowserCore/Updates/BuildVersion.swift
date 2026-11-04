import Foundation

/// A build number as updates compare it (`CFBundleVersion`, and the macOS a release needs):
/// dot-separated whole numbers, compared component by component, a missing component counting as 0
/// — "1.10" is newer than "1.9", and "2" is "2.0". Anything else is not a build number: an appcast
/// or a bundle that carries one is refused rather than put in an order by a guess.
public struct BuildVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let components: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else {
                return nil
            }
            components.append(value)
        }
        self.components = components
    }

    /// The macOS a process runs on, as a build number to compare with a release's minimum.
    public init(_ system: OperatingSystemVersion) {
        components = [system.majorVersion, system.minorVersion, system.patchVersion]
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Without the trailing zeros: what equality and hashing look at.
    private var significant: ArraySlice<Int> {
        var end = components.count
        while end > 0, components[end - 1] == 0 { end -= 1 }
        return components[..<end]
    }

    public static func < (lhs: BuildVersion, rhs: BuildVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: BuildVersion, rhs: BuildVersion) -> Bool {
        lhs.significant == rhs.significant
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(significant))
    }
}
