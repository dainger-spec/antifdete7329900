// SAFARI_GRAPH spike — Safari.framework in-process load probe (docs/SAFARI_GRAPH_SPIKE.md).
//
// Measures, on the Mac it runs on, whether the system Safari UI frameworks can be loaded into a
// third-party process and used instead of a WKWebView chrome. It changes nothing on the system: it
// only dlopen()s frameworks and reports what happened.
//
// Build:  clang -fobjc-arc -mmacosx-version-min=14.0 -o probe probe.m \
//             -framework Foundation -framework AppKit -framework Security
// Run:    GRAPH_VARIANT=base ./probe                # facts + the dlopen matrix
//         GRAPH_VARIANT=all ./probe --try-window    # also tries to bring up Safari's window
//         ./probe --json out.json                   # also a small JSON record
//         ./probe --safari-main page.html           # also call Safari's own entry point (UI in this process)
//
// Exit 0 whenever the probe measured, even when nothing loaded. A crash inside a framework ends the
// process; the caller (measure.sh) records the signal, which is itself a result.
//
// Every machine-readable fact is a line `GRAPH key=value`, read by measure.sh, CI and the manual check.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <unistd.h>

static void emit(NSString *key, NSString *value) {
    NSString *flat = [[(value ?: @"<nil>") stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
                      stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    fprintf(stdout, "GRAPH %s=%s\n", (key ?: @"?").UTF8String, flat.UTF8String ?: "");
    fflush(stdout);
}

static NSString *runTool(NSString *path, NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return [NSString stringWithFormat:@"<could not run %@: %@>", path, error.localizedDescription];
    }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *out = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *selfExecutablePath(void) {
    char buf[4096];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) == 0) {
        return [[NSString stringWithUTF8String:buf] stringByStandardizingPath];
    }
    return NSProcessInfo.processInfo.arguments.firstObject ?: @"";
}

// The frameworks behind Safari's UI, in the order least likely to take the process down first: the
// public controls a third party may load (WebKit, SafariServices), Safari's private support
// frameworks, then Safari.framework itself (staged; in the app cryptex since macOS 13), then a copy
// nested in Safari.app. If loading one crashes the probe, everything before it is already reported.
static NSArray<NSDictionary *> *frameworkCandidates(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    [out addObject:@{@"name": @"WebKit", @"dir": @"/System/Library/Frameworks/WebKit.framework", @"kind": @"public"}];
    [out addObject:@{@"name": @"SafariServices", @"dir": @"/System/Library/Frameworks/SafariServices.framework", @"kind": @"public"}];

    for (NSString *name in @[@"SafariFoundation", @"SafariShared", @"SafariSafeBrowsing", @"WebInspectorUI"]) {
        for (NSString *base in @[@"/System/Library/PrivateFrameworks",
                                 @"/System/Cryptexes/App/System/Library/PrivateFrameworks"]) {
            [out addObject:@{@"name": name, @"dir": [NSString stringWithFormat:@"%@/%@.framework", base, name], @"kind": @"private"}];
        }
    }

    // Safari.framework's own install name (what Safari's executable links); dyld maps it to the cryptex
    // only when told to prefer the staged frameworks (Safari's LC_DYLD_ENVIRONMENT).
    [out addObject:@{@"name": @"Safari", @"dir": @"/System/Library/PrivateFrameworks/Safari.framework", @"kind": @"canonical"}];

    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *root in @[@"/System/Library/StagedFrameworks/Safari",
                             @"/System/Cryptexes/App/System/Library/StagedFrameworks/Safari"]) {
        NSArray *entries = [fm contentsOfDirectoryAtPath:root error:NULL];
        emit(@"staged_root", [NSString stringWithFormat:@"%@ entries=%@", root,
                              entries ? [entries componentsJoinedByString:@","] : @"<absent>"]);
        for (NSString *entry in entries) {
            if (![entry hasSuffix:@".framework"]) { continue; }
            NSString *dir = [root stringByAppendingPathComponent:entry];
            [out addObject:@{@"name": [entry stringByDeletingPathExtension], @"dir": dir, @"kind": @"staged"}];
            [seen addObject:dir];
        }
    }
    // The canonical staged path even if the directory listing is empty: dyld can serve it from a cache.
    for (NSString *dir in @[@"/System/Library/StagedFrameworks/Safari/Safari.framework",
                            @"/System/Cryptexes/App/System/Library/StagedFrameworks/Safari/Safari.framework"]) {
        if (![seen containsObject:dir]) {
            [out addObject:@{@"name": @"Safari", @"dir": dir, @"kind": @"staged"}];
        }
    }

    NSURL *safariApp = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Safari"];
    if (safariApp) {
        emit(@"safari_app_path", safariApp.path);
        NSString *nested = [safariApp.path stringByAppendingPathComponent:@"Contents/Frameworks/Safari.framework"];
        [out addObject:@{@"name": @"Safari", @"dir": nested, @"kind": @"app-nested"}];
    }
    return out;
}

// The Mach-O inside a .framework directory, in the layouts macOS uses.
static NSArray<NSString *> *binaryPathsFor(NSString *dir, NSString *name) {
    return @[[NSString stringWithFormat:@"%@/%@", dir, name],
             [NSString stringWithFormat:@"%@/Versions/Current/%@", dir, name],
             [NSString stringWithFormat:@"%@/Versions/A/%@", dir, name]];
}

// Tries every layout; returns YES once one loads. dyld keeps system frameworks in the shared cache, so
// a canonical path can load even when the on-disk file is absent; the log says which was the case.
static BOOL probeOneFramework(NSDictionary *candidate) {
    NSString *name = candidate[@"name"];
    NSString *dir = candidate[@"dir"];
    NSFileManager *fm = NSFileManager.defaultManager;
    int dirExists = [fm fileExistsAtPath:dir] ? 1 : 0;
    for (NSString *bin in binaryPathsFor(dir, name)) {
        int fileOnDisk = [fm fileExistsAtPath:bin] ? 1 : 0;
        dlerror();
        void *handle = dlopen(bin.UTF8String, RTLD_NOW | RTLD_LOCAL);
        const char *err = handle ? NULL : dlerror();
        NSString *errText = err ? [NSString stringWithUTF8String:err] : @"";
        emit(@"dlopen", [NSString stringWithFormat:@"name=%@ kind=%@ dir_exists=%d file_on_disk=%d bin=%@ result=%@ err=\"%@\"",
                         name, candidate[@"kind"], dirExists, fileOnDisk, bin, handle ? @"ok" : @"fail", errText]);
        if (handle) {
            return YES;
        }
    }
    return NO;
}

// Which copies of the WebKit/Safari stack dyld actually mapped: the base system's or Safari's staged ones.
static void reportImages(void) {
    NSArray *needles = @[@"/WebKit.framework/", @"/JavaScriptCore.framework/", @"/WebCore.framework/",
                         @"/SafariShared.framework/", @"/SafariCore.framework/", @"/Safari.framework/"];
    NSMutableArray *hits = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) { continue; }
        NSString *path = [NSString stringWithUTF8String:name];
        for (NSString *needle in needles) {
            if ([path containsString:needle]) { [hits addObject:path]; break; }
        }
    }
    emit(@"images", hits.count ? [hits componentsJoinedByString:@","] : @"<none>");
}

// The DYLD variables as this process sees them: dyld prunes them for a hardened-runtime process
// that lacks com.apple.security.cs.allow-dyld-environment-variables.
static void reportEnvironment(void) {
    for (NSString *name in @[@"DYLD_VERSIONED_FRAMEWORK_PATH", @"DYLD_FRAMEWORK_PATH", @"CFFIXED_USER_HOME", @"HOME"]) {
        const char *value = getenv(name.UTF8String);
        emit([@"env_" stringByAppendingString:name], value ? [NSString stringWithUTF8String:value] : @"<unset>");
    }
}

// Safari's browser-UI classes across releases: present after a load means the ABI is there.
static NSArray<NSString *> *knownSafariClasses(void) {
    return @[@"BrowserWindowController", @"BrowserController", @"BrowserWindow", @"TabContentView",
             @"SFBrowserWindowController", @"WBSApplicationController", @"AppController",
             @"BrowserDocument", @"TabController", @"SafariApplication"];
}

static void reportClassPresence(void) {
    NSMutableArray *present = [NSMutableArray array];
    for (NSString *cls in knownSafariClasses()) {
        if (objc_getClass(cls.UTF8String) != Nil) { [present addObject:cls]; }
    }
    emit(@"safari_classes_present", present.count ? [present componentsJoinedByString:@","] : @"<none>");
}

// A --try-window attempt that hangs must not stall CI.
static void *watchdog(void *arg) {
    unsigned seconds = (unsigned)(uintptr_t)arg;
    sleep(seconds);
    fprintf(stdout, "GRAPH window_attempt=watchdog_timeout_%us\n", seconds);
    fflush(stdout);
    _exit(42);
    return NULL;
}

// How far Safari's own window controller gets in our process. Objective-C exceptions are caught; an
// abort from an entitlement or assertion check ends the process, which the caller records.
static void tryWindow(void) {
    pthread_t thread;
    pthread_create(&thread, NULL, watchdog, (void *)(uintptr_t)25);
    pthread_detach(thread);

    reportClassPresence();
    @try {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];

        Class controllerClass = Nil;
        for (NSString *name in @[@"BrowserWindowController", @"BrowserController", @"SFBrowserWindowController"]) {
            controllerClass = objc_getClass(name.UTF8String);
            if (controllerClass != Nil) { emit(@"window_controller_class", name); break; }
        }
        if (controllerClass == Nil) {
            emit(@"window_attempt", @"no_controller_class");
            return;
        }
        emit(@"window_attempt", @"init_start");
        id controller = [[controllerClass alloc] init];
        emit(@"window_attempt", controller ? @"init_ok" : @"init_nil");
        if ([controller isKindOfClass:NSWindowController.class]) {
            NSWindowController *windowController = (NSWindowController *)controller;
            [windowController showWindow:nil];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
            emit(@"window_attempt", windowController.window ? @"window_shown" : @"no_window");
        } else {
            emit(@"window_attempt", @"not_a_window_controller");
        }
    } @catch (NSException *exception) {
        emit(@"window_attempt", [NSString stringWithFormat:@"objc_exception:%@:%@", exception.name, exception.reason]);
    }
}

// After Safari's own entry point has had `seconds` to bring its UI up in this process: what is on
// screen, read on the main thread (where AppKit lives), then the process ends.
static void *uiWatchdog(void *arg) {
    unsigned seconds = (unsigned)(uintptr_t)arg;
    sleep(seconds);
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        emit(@"safari_main_app_class", NSApp ? NSStringFromClass([NSApp class]) : @"<no NSApp>");
        NSMutableArray *windows = [NSMutableArray array];
        for (NSWindow *window in (NSApp ? NSApp.windows : @[])) {
            [windows addObject:[NSString stringWithFormat:@"%@ [%@, %@]", window.title ?: @"",
                                NSStringFromClass(window.class), window.isVisible ? @"visible" : @"hidden"]];
        }
        emit(@"safari_main_windows", windows.count ? [windows componentsJoinedByString:@" | "] : @"<none>");
        dispatch_semaphore_signal(answered);
    });
    if (dispatch_semaphore_wait(answered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))) != 0) {
        emit(@"safari_main_windows", @"<the main thread did not answer in 5 s>");
    }
    emit(@"safari_main", [NSString stringWithFormat:@"stopped by the probe after %us", seconds]);
    _exit(43);
    return NULL;
}

// Safari's executable is a stub whose main() hands over to Safari.framework. Call that entry point
// here, with a page to open, and let the watchdog report what came up.
static void trySafariMain(NSString *pagePath) {
    NSArray<NSString *> *names = @[@"SafariMain", @"_SafariMain"];
    void *entry = NULL;
    for (NSString *name in names) {
        entry = dlsym(RTLD_DEFAULT, name.UTF8String);
        if (entry) { emit(@"safari_main_symbol", name); break; }
    }
    if (!entry) {
        emit(@"safari_main_symbol", @"<absent>");
        return;
    }
    pthread_t thread;
    pthread_create(&thread, NULL, uiWatchdog, (void *)(uintptr_t)20);
    pthread_detach(thread);
    const char *args[] = {"Safari", pagePath ? pagePath.UTF8String : NULL, NULL};
    int count = pagePath ? 2 : 1;
    emit(@"safari_main", @"calling");
    int (*safariMain)(int, const char **) = (int (*)(int, const char **))entry;
    int result = safariMain(count, args);
    emit(@"safari_main", [NSString stringWithFormat:@"returned %d", result]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL tryWindowFlag = NO;
        NSString *jsonPath = nil;
        NSString *safariMainPage = nil;
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--try-window"]) {
                tryWindowFlag = YES;
            } else if ([arg isEqualToString:@"--json"] && i + 1 < argc) {
                jsonPath = [NSString stringWithUTF8String:argv[++i]];
            } else if ([arg isEqualToString:@"--safari-main"] && i + 1 < argc) {
                safariMainPage = [NSString stringWithUTF8String:argv[++i]];
            }
        }

        NSString *variant = NSProcessInfo.processInfo.environment[@"GRAPH_VARIANT"] ?: @"base";
        emit(@"variant", variant);
        emit(@"macos", NSProcessInfo.processInfo.operatingSystemVersionString);

        NSURL *safariApp = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.Safari"]
            ?: [NSURL fileURLWithPath:@"/Applications/Safari.app"];
        NSString *safariVersion = [[NSBundle bundleWithURL:safariApp] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
        emit(@"safari_version", safariVersion);
        emit(@"sip", runTool(@"/usr/bin/csrutil", @[@"status"]));

        // Our own signature: the hardened runtime and the exception keys this variant carries.
        NSString *me = selfExecutablePath();
        emit(@"self_path", me);
        emit(@"self_entitlements", runTool(@"/usr/bin/codesign", @[@"-d", @"--entitlements", @"-", @"--xml", me]));
        emit(@"self_signature", runTool(@"/usr/bin/codesign", @[@"-dvv", me]));
        reportEnvironment();

        BOOL safariLoaded = NO;
        NSMutableArray *stagedOK = [NSMutableArray array], *stagedFailed = [NSMutableArray array];
        for (NSDictionary *candidate in frameworkCandidates()) {
            BOOL loaded = probeOneFramework(candidate);
            if (loaded && [candidate[@"name"] isEqualToString:@"Safari"]) { safariLoaded = YES; }
            if ([candidate[@"kind"] isEqualToString:@"staged"] && [candidate[@"dir"] hasPrefix:@"/System/Cryptexes/"]) {
                [(loaded ? stagedOK : stagedFailed) addObject:candidate[@"name"]];
            }
        }
        emit(@"safari_framework_loaded", safariLoaded ? @"yes" : @"no");
        emit(@"staged_loaded", stagedOK.count ? [stagedOK componentsJoinedByString:@","] : @"<none>");
        emit(@"staged_failed", stagedFailed.count ? [stagedFailed componentsJoinedByString:@","] : @"<none>");
        reportImages();
        if (safariLoaded) { reportClassPresence(); }

        if (jsonPath) {
            NSDictionary *record = @{@"variant": variant,
                                     @"macos": NSProcessInfo.processInfo.operatingSystemVersionString,
                                     @"safari_version": safariVersion,
                                     @"safari_framework_loaded": safariLoaded ? @"yes" : @"no",
                                     @"staged_loaded": stagedOK,
                                     @"staged_failed": stagedFailed};
            NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
            [data writeToFile:jsonPath atomically:YES];
        }

        if (tryWindowFlag) {
            if (safariLoaded) {
                tryWindow();
            } else {
                emit(@"window_attempt", @"skipped_safari_framework_not_loaded");
            }
        }
        if (safariMainPage) {
            if (safariLoaded) {
                trySafariMain(safariMainPage);
            } else {
                emit(@"safari_main", @"skipped_safari_framework_not_loaded");
            }
        }
        emit(@"done", @"ok");
        return 0;
    }
}
