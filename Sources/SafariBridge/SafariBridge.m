#import "SafariBridge.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSString *const PBSafariBridgeErrorDomain = @"PBSafariBridge";

/// The framework's install name: on macOS 26 it exists only in the dyld shared cache, where the
/// bundle's `Safari` symlink has no file of its own.
static const char *const PBSafariFrameworkBinary = "/System/Library/PrivateFrameworks/Safari.framework/Versions/A/Safari";

static NSError *PBError(NSString *reason) {
    return [NSError errorWithDomain:PBSafariBridgeErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
}

static NSString *PBDescribe(NSException *exception) {
    return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"(no reason)"];
}

static BOOL PBFail(NSError **error, NSString *reason) {
    if (error) *error = PBError(reason);
    return NO;
}

/// An AppController made here is no NSApplication delegate and nothing else owns it; it lives as
/// long as the windows it made.
static id PBAppController;

@implementation PBSafariBridge

+ (BOOL)loadFramework:(NSError **)error {
    static void *handle;
    static NSString *failure;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen(PBSafariFrameworkBinary, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char *reason = dlerror();
            failure = [NSString stringWithFormat:@"dlopen failed: %s", reason ? reason : "unknown error"];
        }
    });
    return handle ? YES : PBFail(error, failure);
}

+ (nullable NSWindowController *)makeWindowController:(NSError **)error {
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    Class windowControllerClass = NSClassFromString(@"BrowserWindowController");
    if (!windowControllerClass || ![windowControllerClass isSubclassOfClass:[NSWindowController class]]) {
        PBFail(error, @"Safari.framework has no BrowserWindowController (an NSWindowController)");
        return nil;
    }

    // The path Safari's own File > New Window takes.
    NSWindowController *controller = nil;
    Class appControllerClass = NSClassFromString(@"AppController");
    SEL newWindow = NSSelectorFromString(@"_newWindowWithFrontmostProfile:");
    if (!appControllerClass) {
        [reasons addObject:@"no AppController class"];
    } else if (![appControllerClass instancesRespondToSelector:newWindow]) {
        [reasons addObject:@"AppController has no _newWindowWithFrontmostProfile:"];
    } else {
        @try {
            id appController = [NSApp.delegate isKindOfClass:appControllerClass] ? NSApp.delegate : PBAppController;
            if (!appController) {
                appController = [[appControllerClass alloc] init];
                PBAppController = appController;
            }
            id made = ((id (*)(id, SEL, id))objc_msgSend)(appController, newWindow, nil);
            if ([made isKindOfClass:windowControllerClass]) {
                controller = made;
                [controller window];
            } else {
                [reasons addObject:[NSString stringWithFormat:@"_newWindowWithFrontmostProfile: returned %@",
                                    made ? NSStringFromClass([made class]) : @"nil"]];
                controller = nil;
            }
        } @catch (NSException *exception) {
            [reasons addObject:[NSString stringWithFormat:@"AppController: %@", PBDescribe(exception)]];
            controller = nil;
        }
    }
    if (controller) return controller;

    @try {
        controller = [[windowControllerClass alloc] init];
        if (controller.window) return controller;
        [reasons addObject:@"BrowserWindowController init: no window"];
    } @catch (NSException *exception) {
        [reasons addObject:[NSString stringWithFormat:@"BrowserWindowController init: %@", PBDescribe(exception)]];
    }
    PBFail(error, [reasons componentsJoinedByString:@"; "]);
    return nil;
}

+ (BOOL)setValue:(nullable id)value forKey:(NSString *)key of:(id)object error:(NSError **)error {
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (NSException *exception) {
        return PBFail(error, [NSString stringWithFormat:@"%@.%@: %@", NSStringFromClass([object class]), key, PBDescribe(exception)]);
    }
}

+ (BOOL)show:(NSWindowController *)controller error:(NSError **)error {
    @try {
        [controller showWindow:nil];
        return YES;
    } @catch (NSException *exception) {
        return PBFail(error, PBDescribe(exception));
    }
}

+ (BOOL)close:(NSWindowController *)controller error:(NSError **)error {
    @try {
        [controller close];
        return YES;
    } @catch (NSException *exception) {
        return PBFail(error, PBDescribe(exception));
    }
}

@end
