// SAFARI_GRAPH spike v2 — attempt to reach a Safari window without SafariMain().
// Off by default. Set GRAPH_V2=1 to run the path below.
//
// Build: clang -fobjc-arc -mmacosx-version-min=14.0 -o probe_v2 probe_v2.m \
//            -framework Foundation -framework AppKit -framework WebKit
// Run:   GRAPH_V2=1 ./probe_v2
//
// Does not call SafariMain(). Loads Safari.framework, swizzles the selector that
// aborted v1, then tries to instantiate BrowserWindowController. Records whether
// a window appears and whether a WKWebView is present. Does not claim success.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static void emit(NSString *key, NSString *value) {
    fprintf(stdout, "GRAPH_V2 %s=%s\n", key.UTF8String, (value ?: @"").UTF8String);
    fflush(stdout);
}

// No-op replacement for the private selector that aborts Safari's AppController.
static void swizzled_setShouldRelaxThirdPartyCookieBlocking(id self, SEL _cmd, BOOL value) {
    emit(@"swizzle_called", [NSString stringWithFormat:@"_setShouldRelaxThirdPartyCookieBlocking: value=%d", value]);
    // Intentionally do nothing. The original raises.
}

static void installSwizzle(void) {
    Class cls = NSClassFromString(@"WKWebViewConfiguration");
    if (!cls) { emit(@"swizzle", @"WKWebViewConfiguration not found"); return; }
    SEL sel = @selector(_setShouldRelaxThirdPartyCookieBlocking:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { emit(@"swizzle", @"selector not found on WKWebViewConfiguration"); return; }
    IMP imp = (IMP)swizzled_setShouldRelaxThirdPartyCookieBlocking;
    const char *types = method_getTypeEncoding(m);
    class_replaceMethod(cls, sel, imp, types);
    emit(@"swizzle", @"installed on WKWebViewConfiguration");
}

static BOOL loadSafariFramework(void) {
    const char *path = "/System/Library/PrivateFrameworks/Safari.framework/Safari";
    dlerror();
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        emit(@"dlopen", [NSString stringWithUTF8String:dlerror() ?: "unknown"]);
        return NO;
    }
    emit(@"dlopen", @"Safari.framework ok");
    return YES;
}

static void tryBrowserWindowController(void) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];

    Class ctrl = objc_getClass("BrowserWindowController");
    if (!ctrl) { emit(@"controller", @"BrowserWindowController absent"); return; }
    emit(@"controller", @"class present");

    @try {
        id obj = [[ctrl alloc] init];
        emit(@"controller_init", obj ? @"non-nil" : @"nil");
        if ([obj isKindOfClass:NSWindowController.class]) {
            NSWindowController *wc = (NSWindowController *)obj;
            [wc showWindow:nil];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
            emit(@"window", wc.window ? @"present" : @"absent");
            if (wc.window) {
                __block BOOL found = NO;
                void (^scan)(NSView *) = ^(NSView *v) {
                    if ([v isKindOfClass:WKWebView.class]) { found = YES; }
                    for (NSView *sub in v.subviews) { scan(sub); }
                };
                scan(wc.window.contentView);
                emit(@"wkwebview_in_window", found ? @"yes" : @"no");
            }
        } else {
            emit(@"controller_init", @"not a NSWindowController");
        }
    } @catch (NSException *e) {
        emit(@"controller_exception", [NSString stringWithFormat:@"%@: %@", e.name, e.reason]);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (!getenv("GRAPH_V2")) {
            fprintf(stderr, "Set GRAPH_V2=1 to run. Off by default.\n");
            return 1;
        }
        emit(@"start", @"probe_v2");
        if (!loadSafariFramework()) { return 0; }
        installSwizzle();
        tryBrowserWindowController();
        emit(@"done", @"probe_v2");
    }
    return 0;
}
