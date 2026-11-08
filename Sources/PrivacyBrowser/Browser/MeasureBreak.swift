import Foundation

/// Measurement only (claude/measure-disguise-red, never merged): breaks one part of an iPhone
/// view's full disguise, named by PB_MEASURE_BREAK, so the self-test's checks for it can be seen
/// to fail. A part whose text is not found stops the process: a break that did not happen would
/// make a green run look red-proof.
enum MeasureBreak {
    static let parts: [String: [(String, String)]] = [
        "screen": [("  const s = w.screen;\n  if (s) {", "  const s = null;\n  if (s) {")],
        "touchPoints": [("  if (nav) overrideGetter(nav, 'maxTouchPoints', phone.maxTouchPoints);\n", "\n")],
        "orientation": [("  try { patchOrientation(w); } catch (e) {}\n", "\n")],
        "pointer": [("  try { patchPointerQueries(w, phone); } catch (e) {}\n", "\n")],
        "touch": [("  try { patchTouch(w); } catch (e) {}\n", "\n")],
        "tapEvents": [("  w.addEventListener('pointerdown', (event) => {\n    if (!primary(event)",
                       "  w.addEventListener('pointerdown', (event) => { return;\n    if (!primary(event)")],
        "cancel": [("    if (started.defaultPrevented) { swallowMouse = true; swallowClick = true; }\n", "\n")],
        "workers": [("  if (nav) overrideGetter(nav, 'platform', phone.platform);\n  if (IS_WORKER) return;",
                     "  if (IS_WORKER) return;\n  if (nav) overrideGetter(nav, 'platform', phone.platform);")],
        // The whole set: patchPhone does nothing.
        "all": [("function patchPhone(w, phone) {\n", "function patchPhone(w, phone) { return;\n")],
    ]

    static func apply(_ body: String) -> String {
        guard let name = ProcessInfo.processInfo.environment["PB_MEASURE_BREAK"], !name.isEmpty, name != "none" else { return body }
        guard let replacements = parts[name] else { fatalError("MEASURE BREAK: no part named \(name)") }
        var out = body
        for (old, new) in replacements {
            guard out.contains(old) else { fatalError("MEASURE BREAK \(name): text not found") }
            out = out.replacingOccurrences(of: old, with: new)
        }
        return out
    }
}
