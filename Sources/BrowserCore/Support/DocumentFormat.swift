import Foundation

/// The format a file of the vault declares, and the two rules every reader and writer of it keeps
/// (docs/UPDATES.md §4).
///
/// A document's JSON may carry a top-level `"format"` number. Without one — every file this
/// version writes, and the files whose JSON is an array or a map of their own — it is format 1:
/// a later version that changes a file's format writes the key, and this one has nothing to add.
///
/// - **R2, read:** a reader that knows up to format `n` refuses a newer one before it decodes
///   anything (`check`): a newer version wrote the file, and fields this one does not know would be
///   lost the moment it wrote the rest back.
/// - **R2, write:** a writer never writes over a file that declares a newer format than it knows
///   (`guardOverwrite`). That holds for every caller, including one that fell back to defaults
///   after a failed read and is now saving them.
public enum DocumentFormat {
    /// What `json` declares: its top-level `format`, or 1 when there is none (or the top level is
    /// not an object). Nil when there is a `format` that is not a whole number: refused like a
    /// newer one.
    public static func declared(in json: Data) -> Int? {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: json) else { return 1 }
        switch probe.format {
        case nil: return 1
        case .number(let number)?: return number
        case .other?: return nil
        }
    }

    /// Throws `CoreError.newerFormat` when `json` declares a format newer than `supported`.
    public static func check(_ json: Data, supported: Int, what: String) throws {
        let found = declared(in: json)
        guard let found, found <= supported else {
            throw CoreError.newerFormat(what: what, found: found, supported: supported)
        }
    }

    /// Throws `CoreError.newerFormat` when the file at `url` declares a newer format than
    /// `supported` — opened with `open` (its decryption). A file that is not there, or that does
    /// not open (another key, damage), is left to the writer as before: this guards against
    /// losing what a newer version wrote, not against writing at all.
    static func guardOverwrite(of url: URL, supported: Int, what: String, open: (Data) throws -> Data) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let sealed = try? SecureFile.read(url), let json = try? open(sealed) else { return }
        try check(json, supported: supported, what: what)
    }

    private struct Probe: Decodable {
        let format: Value?

        enum Value: Decodable {
            case number(Int)
            case other

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) {
                    self = .number(number)
                } else {
                    self = .other
                }
            }
        }
    }
}
