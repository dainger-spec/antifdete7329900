#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Safari's browser window, reached through Safari.framework's private classes
/// (docs/SAFARI_FRAMEWORK_PATH.md). Every call into Safari's code runs inside @try here:
/// Safari's classes raise NSExceptions in a process that is not Safari, and an exception must
/// neither take the app down nor unwind through Swift frames. Errors carry the reason
/// (the exception's name and reason, or what was missing) in their localized description.
@interface PBSafariBridge : NSObject

/// Loads Safari.framework by its install name (once per process).
+ (BOOL)loadFramework:(NSError **)error NS_SWIFT_NAME(loadFramework());

/// A new Safari BrowserWindowController with its window loaded (Safari may have shown it already): through
/// -[AppController _newWindowWithFrontmostProfile:], else -[BrowserWindowController init].
+ (nullable NSWindowController *)makeWindowController:(NSError **)error NS_SWIFT_NAME(makeWindowController());

/// `object.setValue(value, forKey: key)`, with an unknown key (NSUnknownKeyException) as an error.
+ (BOOL)setValue:(nullable id)value forKey:(NSString *)key of:(id)object error:(NSError **)error
    NS_SWIFT_NAME(set(_:forKey:of:));

/// Shows a window controller's window, with an exception from Safari's code as an error.
+ (BOOL)show:(NSWindowController *)controller error:(NSError **)error NS_SWIFT_NAME(show(_:));

/// Closes a window controller, with an exception from Safari's code as an error.
+ (BOOL)close:(NSWindowController *)controller error:(NSError **)error NS_SWIFT_NAME(close(_:));

@end

NS_ASSUME_NONNULL_END
