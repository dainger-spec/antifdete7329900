import Foundation

/// Parsing of `tart` command output.
public enum TartOutput {
    /// True iff a `tart list` table has a row whose Name column equals `name`.
    /// Avoids substring false positives (e.g. "safari-profile-2", the header).
    public static func vmListContains(_ output: String, name: String) -> Bool {
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Columns: Source Name Disk Size State → Name is index 1.
            guard fields.count >= 2, fields[0] != "Source" else { continue } // header row
            if fields[1] == name { return true }
        }
        return false
    }

    /// Names of VMs whose State column is "running", from `tart list` output.
    /// Pass `prefix` to count only this app's profile VMs (e.g. "pb-").
    public static func runningVMNames(_ output: String, prefix: String = "") -> [String] {
        var names: [String] = []
        for line in output.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Source Name Disk Size State → need Name (1) and State (last).
            guard fields.count >= 3, fields[0] != "Source", fields.last == "running" else { continue }
            if prefix.isEmpty || fields[1].hasPrefix(prefix) { names.append(fields[1]) }
        }
        return names
    }

    // "42%", "42.5%", "(42%)", "42 %"; not the tail of "1000%" or "v1.42%".
    private static let percentPattern = try! NSRegularExpression(pattern: #"(?<![\w.])(\d{1,3}(?:\.\d+)?)\s?%"#)

    /// The last percentage on a line of `tart pull`/`clone` progress, as 0…1.
    /// nil when the line carries none (e.g. "pulling manifest...").
    public static func percent(in line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = percentPattern.matches(in: line, range: range).last,
              let valueRange = Range(match.range(at: 1), in: line),
              let value = Double(line[valueRange]), value <= 100 else {
            return nil
        }
        return value / 100
    }

    /// The text of a progress line without its percentage, for display next to
    /// the bar ("pulling disk (24.3 GB compressed)..."). nil if nothing is left.
    public static func label(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        let stripped = percentPattern.stringByReplacingMatches(in: line, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? nil : stripped
    }
}
