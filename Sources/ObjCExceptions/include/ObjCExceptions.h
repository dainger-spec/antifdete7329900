#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil when it raised none.
///
/// Safari's code throws Objective-C exceptions; one that unwinds out of Safari's code through a
/// Swift task leaves the Swift runtime's record of the running job pointing into a stack that is
/// gone, and the next check of the main actor ends the process (docs/SAFARI_MENU.md). Swift cannot
/// catch them: this `@try` around the call can, before they reach a Swift async frame.
FOUNDATION_EXPORT NSException *_Nullable PBCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
