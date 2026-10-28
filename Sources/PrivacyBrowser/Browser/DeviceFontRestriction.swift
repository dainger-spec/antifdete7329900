import AppKit
import BrowserCore
import CoreText
import Darwin
import WebKit

/// The fonts of an iPhone or iPad profile: its pages find only the families Safari on the device
/// has (`DeviceFonts`), and `cursive` is the device's.
///
/// WebKit keeps a font allowlist per process pool and hands it to every web content process the
/// pool launches, which then looks a `font-family` up only among those names
/// (`WebProcessPool::setFontAllowList` → `WebProcessCreationParameters.fontAllowList` →
/// `FontCache::setFontAllowlist`, macOS only; system UI fonts always pass). A profile has a pool of
/// its own (`ProfileProcessPool`), so the list reaches its pages, frames and workers and no other
/// profile's. A family the list leaves out is not found, as on the device; WebKit then tries its
/// alternate name as it does there (Times → Times New Roman, Courier → Courier New).
///
/// PLATFORM LIMITATION: private API. These are WebKit's C SPI (`WKContextSetFontAllowList`,
/// `WKPreferencesSetCursiveFontFamily`), looked up at run time and used only when this WebKit
/// exports them; on Cocoa a WebKit C API reference is the Objective-C object itself. Without them
/// a profile sees this Mac's fonts (the self-test reports which applies).
@MainActor
enum DeviceFontRestriction {
    private typealias SetFontAllowList = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias SetFamily = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    private typealias ArrayCreate = @convention(c) (UnsafeMutablePointer<UnsafeRawPointer?>?, Int) -> UnsafeRawPointer?
    private typealias StringCreate = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
    private typealias Release = @convention(c) (UnsafeRawPointer) -> Void

    private static func function<T>(_ name: String, _ type: T.Type) -> T? {
        // RTLD_DEFAULT: every image loaded, WebKit among them.
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    private static let setFontAllowList = function("WKContextSetFontAllowList", SetFontAllowList.self)
    private static let setCursiveFontFamily = function("WKPreferencesSetCursiveFontFamily", SetFamily.self)
    private static let arrayCreate = function("WKArrayCreate", ArrayCreate.self)
    private static let stringCreate = function("WKStringCreateWithUTF8CString", StringCreate.self)
    private static let release = function("WKRelease", Release.self)

    /// The cursive family of Safari on iOS (WebKit's default there; a Mac's is Apple Chancery,
    /// which iOS lacks).
    static let cursiveFamily = "Snell Roundhand"

    /// Which of the private pieces this WebKit has (self-test information).
    static var availability: String {
        let pieces: [(String, Bool)] = [
            ("WKContextSetFontAllowList", setFontAllowList != nil), ("WKPreferencesSetCursiveFontFamily", setCursiveFontFamily != nil),
            ("WKArrayCreate", arrayCreate != nil), ("WKStringCreateWithUTF8CString", stringCreate != nil), ("WKRelease", release != nil),
        ]
        return pieces.map { "\($0.0) \($0.1 ? "yes" : "no")" }.joined(separator: ", ")
    }

    /// This Mac's faces, read once per run.
    static let macFaces: [DeviceFonts.Face] = {
        let manager = NSFontManager.shared
        var faces: [DeviceFonts.Face] = []
        for family in manager.availableFontFamilies {
            for member in manager.availableMembers(ofFontFamily: family) ?? [] {
                guard let postScriptName = member.first as? String else { continue }
                let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
                guard let fullName = CTFontCopyName(font, kCTFontFullNameKey) else { continue }
                faces.append(DeviceFonts.Face(family: family, postScriptName: postScriptName, fullName: fullName as String))
            }
        }
        return faces
    }()

    /// The names handed to WebKit; empty when this Mac's fonts could not be read.
    static let allowlist = DeviceFonts.iOSAllowlist(macFaces)

    /// Pages of `pool`'s web processes find only the fonts of `allowlist`. Call before the pool
    /// launches a process: WebKit hands the list over when it starts one. False when this WebKit
    /// lacks the SPI or no font was read (the pool then keeps every font).
    @discardableResult
    static func restrict(_ pool: NSObject) -> Bool {
        guard !allowlist.isEmpty, let setFontAllowList, let array = makeArray(allowlist) else { return false }
        defer { release?(array) }
        setFontAllowList(UnsafeRawPointer(Unmanaged.passUnretained(pool).toOpaque()), array)
        return true
    }

    /// `cursive` in pages of web views made with `preferences` is Safari on iOS's.
    @discardableResult
    static func setCursiveFamily(of preferences: WKPreferences) -> Bool {
        guard let setCursiveFontFamily, let stringCreate, let release,
              let family = cursiveFamily.withCString({ stringCreate($0) }) else { return false }
        defer { release(family) }
        setCursiveFontFamily(UnsafeRawPointer(Unmanaged.passUnretained(preferences).toOpaque()), family)
        return true
    }

    /// A WebKit array of strings (+1; the caller releases it), nil without the SPI.
    private static func makeArray(_ names: [String]) -> UnsafeRawPointer? {
        guard let arrayCreate, let stringCreate, let release else { return nil }
        var strings: [UnsafeRawPointer?] = names.map { name in name.withCString { stringCreate($0) } }
        // The array holds its own references to the strings.
        defer { for case let string? in strings { release(string) } }
        guard !strings.contains(where: { $0 == nil }) else { return nil }
        return strings.withUnsafeMutableBufferPointer { arrayCreate($0.baseAddress, $0.count) }
    }
}
