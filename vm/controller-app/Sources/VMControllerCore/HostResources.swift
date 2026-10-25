import Foundation

/// Host resource readings for the UI: disk a profile's VM takes, and free RAM
/// (so we can warn when it's tight). The pure parts — summing a directory and
/// parsing `vm_stat` — are unit-tested; the live `vm_stat` read is macOS-only
/// and returns nil elsewhere.
public enum HostResources {
    /// Warn below this much free RAM (the task's "< 2 GB free").
    public static let lowRAMThreshold: Int64 = 2 * 1024 * 1024 * 1024

    public static func isLowRAM(_ freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes < lowRAMThreshold
    }

    /// Total size of regular files under `url` (recursive). 0 if it doesn't exist.
    public static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                             options: [], errorHandler: nil) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Combined size of all the profiles' VM directories under `vmsDirectory`.
    public static func profilesDiskBytes(_ profiles: [Profile], vmsDirectory: URL) -> Int64 {
        profiles.reduce(0) { $0 + directorySize(at: vmsDirectory.appendingPathComponent($1.vmName)) }
    }

    /// Parse `vm_stat` output into bytes of available RAM (free + inactive +
    /// speculative — the reclaimable pages), or nil if it doesn't look like
    /// vm_stat output.
    public static func parseFreeRAM(_ output: String) -> Int64? {
        guard let pageSize = firstInt(output, #"page size of (\d+) bytes"#) else { return nil }
        func pages(_ label: String) -> Int64 {
            Int64(firstInt(output, "\(label):\\s+(\\d+)") ?? 0)
        }
        let available = (pages("Pages free") + pages("Pages inactive") + pages("Pages speculative")) * Int64(pageSize)
        return available > 0 ? available : nil
    }

    /// Live free-RAM reading via `vm_stat` (macOS). nil off a Mac or on error.
    public static func freeRAMBytes(environment: [String: String]) async -> Int64? {
        guard let result = try? await GroupProcess.run("/usr/bin/vm_stat", [], environment: environment, timeout: 10),
              result.code == 0 else {
            return nil
        }
        return parseFreeRAM(result.lines.joined(separator: "\n"))
    }

    private static func firstInt(_ text: String, _ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
              let group = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[group])
    }
}
