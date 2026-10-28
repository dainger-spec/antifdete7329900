/// Which of this Mac's fonts a page in an iPhone or iPad profile may find: the ones Safari on the
/// device has too.
///
/// WebKit can restrict the fonts a page looks up by name to an allowlist of family names (and
/// PostScript names, which it also accepts in `font-family`), per process pool; the app hands it
/// this list (`DeviceFontRestriction`). A family is kept when at least one of its faces is not one
/// iOS lacks (`IOSFonts.macOnlyFaces`, from Apple's list of the fonts each system ships), so a
/// family Apple does not list stays visible. What the list cannot express: a kept family keeps all
/// of its faces on the Mac, including weights iOS lacks; fonts iOS has and the Mac lacks (none, by
/// Apple's list) cannot be added; text in a script no named font covers falls back to the Mac's
/// fonts, as WebKit's fallback is not filtered.
public enum DeviceFonts {
    /// A face of this Mac.
    public struct Face: Equatable, Sendable {
        public var family: String
        public var postScriptName: String
        /// The full name (as Apple's list names faces), e.g. "Menlo Regular".
        public var fullName: String

        public init(family: String, postScriptName: String, fullName: String) {
            self.family = family
            self.postScriptName = postScriptName
            self.fullName = fullName
        }
    }

    /// The allowlist for a page on an iPhone or iPad: every family with a face iOS does not lack,
    /// then those faces' PostScript names. Empty when `faces` is (WebKit then allows every font).
    public static func iOSAllowlist(_ faces: [Face], macOnly: Set<String> = IOSFonts.macOnlyFaces) -> [String] {
        let kept = faces.filter { !macOnly.contains($0.fullName) }
        var names: [String] = [], seen = Set<String>()
        // WebKit compares the names ignoring ASCII case.
        for name in kept.map(\.family) + kept.map(\.postScriptName) where seen.insert(name.lowercased()).inserted {
            names.append(name)
        }
        return names
    }

    /// The families of `faces` a page on an iPhone or iPad does not find: all of their faces are
    /// ones iOS lacks.
    public static func hiddenFamilies(_ faces: [Face], macOnly: Set<String> = IOSFonts.macOnlyFaces) -> [String] {
        let kept = Set(faces.filter { !macOnly.contains($0.fullName) }.map { $0.family.lowercased() })
        var hidden: [String] = [], seen = Set<String>()
        for face in faces where !kept.contains(face.family.lowercased()) && seen.insert(face.family.lowercased()).inserted {
            hidden.append(face.family)
        }
        return hidden
    }
}
