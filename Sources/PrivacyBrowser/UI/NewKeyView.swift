import AppKit
import BrowserCore
import SwiftUI

/// A new key, shown once after a replacement (`key.replaced`, the server's `docs/CONTRACT.md` §11.1):
/// monospaced, selectable, with "Copy" — as the site shows a key after a payment. The one place in the
/// interface where a key's text is shown (scripts/check_account_key.py): only the key the server has
/// just given, only while its sheet is open. Copied only at the person's click, and marked as
/// concealed (`org.nspasteboard.ConcealedType`), so that clipboard managers that honour the mark do
/// not keep it in their history.
struct NewKeyView: View {
    let key: AccountKey
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: key.unredacted())
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 8)
            Button(copied ? L("license.copied") : L("license.copy"), action: copy)
                .buttonStyle(.lumenSecondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func copy() {
        let item = NSPasteboardItem()
        _ = item.setString(key.unredacted(), forType: .string)
        _ = item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.writeObjects([item])
        copied = true
    }
}
