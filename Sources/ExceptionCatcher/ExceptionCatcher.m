#import "ExceptionCatcher.h"
#import <objc/objc-exception.h>

NSException *PBCatchException(void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
#if __has_feature(objc_arc)
        return exception;
#else
        return [[exception retain] autorelease];
#endif
    } @catch (id other) {
        // Anything can be thrown; only NSException is expected, so wrap what else arrives.
        return [NSException exceptionWithName:@"PBNonExceptionObject" reason:[other description] userInfo:nil];
    }
    return nil;
}

static objc_exception_preprocessor previousPreprocessor;
static PBRaisedExceptionObserver currentObserver;
/// Set while the observer runs, so an exception it raises itself is not reported into it again.
static BOOL reporting;

/// The runtime calls this for every exception, before any handler sees it.
static id PBPreprocessException(id exception) {
    // The one installed before runs first: CoreFoundation's records the stack the exception was
    // raised from, which is what the observer is handed.
    id result = previousPreprocessor ? previousPreprocessor(exception) : exception;
    PBRaisedExceptionObserver observer = currentObserver;
    if (observer != nil && !reporting && [NSThread isMainThread] && [result isKindOfClass:[NSException class]]) {
        reporting = YES;
        NSException *raised = result;
        NSArray<NSString *> *stack = raised.callStackSymbols.count > 0 ? raised.callStackSymbols : [NSThread callStackSymbols];
        observer(raised, stack);
        reporting = NO;
    }
    return result;
}

PBRaisedExceptionObserver PBObserveRaisedExceptions(PBRaisedExceptionObserver observer) {
    // Installed once and left in place; with no observer it only passes the exception on.
    static dispatch_once_t installed;
    dispatch_once(&installed, ^{
        previousPreprocessor = objc_setExceptionPreprocessor(PBPreprocessException);
    });
    PBRaisedExceptionObserver previous = currentObserver;
    currentObserver = [observer copy];
#if __has_feature(objc_arc)
    return previous;
#else
    return [previous autorelease];
#endif
}
