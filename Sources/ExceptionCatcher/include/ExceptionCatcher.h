#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and hands back the Objective-C exception it raised, or nil when it returned.
///
/// Swift has no way to catch an `NSException`: one raised under Swift code unwinds straight
/// through it, skipping its cleanups, until something written in Objective-C catches it. The
/// framework window path calls into code built for another application, where a raised exception
/// is the ordinary way to fail, so each of those calls goes through here. Keep the Swift inside
/// `block` to the call itself: a `defer` or an exclusive access in a frame that is unwound never
/// finishes.
///
/// Deliberately not `NS_NOESCAPE`. For a non-escaping block Swift checks, once the call returns,
/// that nothing kept a reference to it; an exception unwinding through the block's own frame can
/// skip the release that frame owed, and that check would then end the process over an escape
/// that never happened. An escaping block is not checked, and the most an unwind costs it is a
/// leaked reference.
NSException *_Nullable PBCatchException(void (^block)(void));

/// Called with an exception raised on the main thread, at the moment it is raised and whoever
/// goes on to catch it, with the stack it was raised from.
typedef void (^PBRaisedExceptionObserver)(NSException *exception, NSArray<NSString *> *callStack);

/// Starts reporting exceptions to `observer` as they are raised, or stops with nil, and returns
/// the observer it replaced so the caller can put it back.
///
/// This sees what `PBCatchException` cannot. AppKit catches an exception raised during layout
/// itself, before it reaches any caller, and then either logs it and carries on or ends the
/// process; either way nothing outside AppKit gets to catch it.
PBRaisedExceptionObserver _Nullable PBObserveRaisedExceptions(PBRaisedExceptionObserver _Nullable observer);

NS_ASSUME_NONNULL_END
