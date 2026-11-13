import SwiftUI

/// A diagnostic of the session list's large title (DEBUG builds only; DesignShotTests' "diag-title-*"
/// shots): with rows the title came collapsed into the bar, even pulled down. LUMEN_DIAG_TITLE names
/// one part of the list to leave out — "nozoom", "nosearch", "noheader", "nomenu" — to see which one
/// does it. In a release build nothing is left out.
enum TitleProbe {
    #if DEBUG
    static let off = ProcessInfo.processInfo.environment["LUMEN_DIAG_TITLE"] ?? ""
    #else
    static let off = ""
    #endif
}

extension View {
    /// `apply` to the view unless the title's diagnostic leaves this part out.
    @ViewBuilder func unlessProbe(_ part: String, _ apply: (Self) -> some View) -> some View {
        if TitleProbe.off == part { self } else { apply(self) }
    }
}
