import SwiftUI

/// A diagnostic of the session list's large title (DEBUG builds only; DesignShotTests' "diag-title-*"
/// shots): with rows the title came collapsed into the bar, even pulled down. Run 114: the search
/// does it (without it the title stands; without the zoom, the header or the menus it does not).
/// LUMEN_DIAG_TITLE: "nosearch" leaves the search out, "searchauto" puts it in the bar's drawer shown
/// at the top only, "searchplain" where the system puts it. In a release build: the drawer, always.
enum TitleProbe {
    #if DEBUG
    static let off = ProcessInfo.processInfo.environment["LUMEN_DIAG_TITLE"] ?? ""
    #else
    static let off = ""
    #endif

    static var searchPlacement: SearchFieldPlacement {
        switch off {
        case "searchauto": return .navigationBarDrawer(displayMode: .automatic)
        case "searchplain": return .automatic
        default: return .navigationBarDrawer(displayMode: .always)
        }
    }
}

extension View {
    /// `apply` to the view unless the title's diagnostic leaves this part out.
    @ViewBuilder func unlessProbe(_ part: String, _ apply: (Self) -> some View) -> some View {
        if TitleProbe.off == part { self } else { apply(self) }
    }
}
