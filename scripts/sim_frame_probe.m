// Measurement (claude/measure-ios-sim, never merged): can a process of ours get a booted simulated
// device's screen — not Simulator.app — and is there a way in for touches?
//
//     clang -fobjc-arc -framework Foundation -framework IOSurface -framework CoreImage \
//         -framework CoreGraphics -framework ImageIO scripts/sim_frame_probe.m -o sim_frame_probe
//     ./sim_frame_probe <UDID> <developer dir> <out.png>
//
// It loads Apple's private CoreSimulator and SimulatorKit frameworks (what Simulator.app, simctl and
// tools such as idb use), lists the classes that name displays, surfaces and HID input, finds the
// device, walks its I/O ports and, where a port's descriptor hands out an IOSurface, writes that
// surface to a PNG and says how often it changes. Nothing here sends input to the device.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void listClasses(const char *image, NSArray<NSString *> *words) {
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(image, &count);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = @(names[i]);
        for (NSString *word in words) {
            if ([name rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) { [hits addObject:name]; break; }
        }
    }
    free(names);
    [hits sortUsingSelector:@selector(compare:)];
    printf("FRAME classes in %s: %u in all, %lu named after %s\n", image, count, (unsigned long)hits.count,
           [[words componentsJoinedByString:@"/"] UTF8String]);
    for (NSString *hit in hits) printf("FRAME   %s\n", hit.UTF8String);
}

static void listMethods(id object, NSString *word) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList([object class], &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (!word || [name rangeOfString:word options:NSCaseInsensitiveSearch].location != NSNotFound) [names addObject:name];
    }
    free(methods);
    unsigned int pcount = 0;
    Protocol * __unsafe_unretained *protocols = class_copyProtocolList([object class], &pcount);
    NSMutableArray *pnames = [NSMutableArray array];
    for (unsigned int i = 0; i < pcount; i++) [pnames addObject:@(protocol_getName(protocols[i]))];
    free(protocols);
    printf("FRAME   %s: protocols [%s]; methods%s [%s]\n", class_getName([object class]),
           [[pnames componentsJoinedByString:@", "] UTF8String], word ? [[@" with " stringByAppendingString:word] UTF8String] : "",
           [[names componentsJoinedByString:@", "] UTF8String]);
}

static id call(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(target, sel); } @catch (NSException *e) {
        printf("FRAME   %s threw %s\n", selector.UTF8String, e.reason.UTF8String);
        return nil;
    }
}

static BOOL writePNG(IOSurfaceRef surface, NSString *path) {
    CIImage *image = [CIImage imageWithIOSurface:surface];
    if (!image) return NO;
    CIContext *context = [CIContext contextWithOptions:nil];
    CGImageRef cg = [context createCGImage:image fromRect:image.extent];
    if (!cg) return NO;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                        CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(destination, cg, NULL);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(cg);
    return ok;
}

// A tap at the centre of the screen through the device's HID port, the way idb does it
// (SimulatorKit's SimDeviceLegacyHIDClient and IndigoHIDMessageForMouseNSEvent; the signature is
// idb's, for Xcode 11 and later — an assumption this run tests). Run as its own process: a wrong
// signature crashes only this.
typedef void *IndigoMessageRef;
static int tap(id device, NSString *simulatorKit) {
    void *sk = dlopen(simulatorKit.UTF8String, RTLD_NOW);
    if (!sk) { printf("TAP NO: SimulatorKit did not load: %s\n", dlerror()); return 1; }
    listClasses(simulatorKit.UTF8String, @[@"HID", @"Indigo", @"Touch", @"Display", @"Screen"]);
    IndigoMessageRef (*message)(CGPoint *, CGPoint *, uint32_t, NSEventType, BOOL) = dlsym(sk, "IndigoHIDMessageForMouseNSEvent");
    Class clientClass = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient") ?: NSClassFromString(@"SimDeviceLegacyHIDClient");
    printf("TAP IndigoHIDMessageForMouseNSEvent %s, HID client class %s\n", message ? "found" : "missing", clientClass ? class_getName(clientClass) : "missing");
    if (!message || !clientClass) return 1;
    NSError *error = nil;
    id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([clientClass alloc], NSSelectorFromString(@"initWithDevice:error:"), device, &error);
    if (!client) { printf("TAP NO: the HID client did not start: %s\n", error.description.UTF8String); return 1; }
    listMethods(client, @"send");
    SEL send = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:");
    if (![client respondsToSelector:send]) { printf("TAP NO: no sendWithMessage:freeWhenDone:completionQueue:completion:\n"); return 1; }
    dispatch_queue_t queue = dispatch_queue_create("tap", DISPATCH_QUEUE_SERIAL);
    __block int answered = 0;
    for (NSNumber *type in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
        CGPoint point = CGPointMake(0.5, 0.5);
        IndigoMessageRef m = message(&point, NULL, 0x32, (NSEventType)type.unsignedIntegerValue, NO);
        if (!m) { printf("TAP NO: no message built\n"); return 1; }
        ((void (*)(id, SEL, IndigoMessageRef, BOOL, dispatch_queue_t, void (^)(NSError *)))objc_msgSend)(
            client, send, m, YES, queue, ^(NSError *sendError) {
                printf("TAP sent %s: %s\n", type.unsignedIntegerValue == NSEventTypeLeftMouseDown ? "down" : "up",
                       sendError ? sendError.description.UTF8String : "ok");
                answered++;
            });
        usleep(80000);
    }
    for (int i = 0; i < 50 && answered < 2; i++) usleep(100000);
    printf("TAP %d of 2 messages answered\n", answered);
    return answered == 2 ? 0 : 1;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: sim_frame_probe UDID DEVELOPER_DIR OUT.png [--tap SIMULATORKIT]\n"); return 2; }
        NSString *udid = @(argv[1]), *developer = @(argv[2]), *out = @(argv[3]);
        NSString *tapKit = (argc >= 6 && strcmp(argv[4], "--tap") == 0) ? @(argv[5]) : nil;
        const char *coreSimulator = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
        NSString *simulatorKit = [developer stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"];
        void *cs = dlopen(coreSimulator, RTLD_NOW);
        void *sk = dlopen(simulatorKit.UTF8String, RTLD_NOW);
        printf("FRAME CoreSimulator %s, SimulatorKit %s\n", cs ? "loaded" : dlerror(), sk ? "loaded" : dlerror());
        NSArray *words = @[@"Display", @"Surface", @"Framebuffer", @"HID", @"Indigo", @"Touch", @"IOClient", @"IOPort", @"Screen", @"Digitizer"];
        if (cs) listClasses(coreSimulator, words);
        if (sk) listClasses(simulatorKit.UTF8String, words);

        Class contextClass = NSClassFromString(@"SimServiceContext");
        if (!contextClass) { printf("FRAME NO: no SimServiceContext\n"); return 1; }
        NSError *error = nil;
        id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(contextClass, NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), developer, &error);
        id set = context ? ((id (*)(id, SEL, NSError **))objc_msgSend)(context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &error) : nil;
        id device = nil;
        for (id candidate in (NSArray *)call(set, @"devices") ?: @[]) {
            if ([[(NSUUID *)call(candidate, @"UDID") UUIDString] isEqualToString:udid]) device = candidate;
        }
        if (!device) { printf("FRAME NO: device %s not found (%s)\n", udid.UTF8String, error.description.UTF8String ?: ""); return 1; }
        printf("FRAME device %s: %s\n", udid.UTF8String, [[call(device, @"stateString") description] UTF8String] ?: "?");
        if (tapKit) return tap(device, tapKit);
        id io = call(device, @"io");
        if (!io) { printf("FRAME NO: the device has no io client\n"); return 1; }
        listMethods(io, nil);
        NSArray *ports = call(io, @"ioPorts");
        printf("FRAME %lu I/O port(s)\n", (unsigned long)ports.count);
        IOSurfaceRef found = NULL;
        for (id port in ports) {
            id descriptor = call(port, @"descriptor");
            printf("FRAME port %s, descriptor %s\n", class_getName([port class]), descriptor ? class_getName([descriptor class]) : "none");
            if (!descriptor) continue;
            listMethods(descriptor, nil);
            for (NSString *name in @[@"framebufferSurface", @"ioSurface", @"surface"]) {
                id value = call(descriptor, name);
                if (value && !found && CFGetTypeID((__bridge CFTypeRef)value) == IOSurfaceGetTypeID()) {
                    found = (IOSurfaceRef)CFBridgingRetain(value);
                    printf("FRAME   %s gives an IOSurface %zux%zu, %zu bytes per row\n", name.UTF8String,
                           IOSurfaceGetWidth(found), IOSurfaceGetHeight(found), IOSurfaceGetBytesPerRow(found));
                }
            }
        }
        if (!found) { printf("FRAME NO SURFACE: no port handed out an IOSurface (see the methods above)\n"); return 1; }
        // How often the device redraws into it: the surface's seed changes with every frame.
        uint32_t seed = IOSurfaceGetSeed(found), changes = 0;
        NSDate *start = [NSDate date];
        while ([[NSDate date] timeIntervalSinceDate:start] < 3) {
            uint32_t now = IOSurfaceGetSeed(found);
            if (now != seed) { changes++; seed = now; }
            usleep(2000);
        }
        printf("FRAME seed changed %u times in 3 s (%.1f frames a second)\n", changes, changes / 3.0);
        // The surface fetched again, 12 times 0.3 s apart, while the page moves: does each fetch
        // carry the screen as it is now (polling works), or one picture (a callback is needed)?
        NSMutableSet *hashes = [NSMutableSet set];
        id displayDescriptor = nil;
        for (id port in ports) {
            id d = call(port, @"descriptor");
            if (d && [d respondsToSelector:NSSelectorFromString(@"framebufferSurface")]) { displayDescriptor = d; break; }
        }
        NSDate *pollStart = [NSDate date];
        for (int i = 0; i < 12 && displayDescriptor; i++) {
            IOSurfaceRef s = (__bridge IOSurfaceRef)call(displayDescriptor, @"framebufferSurface");
            if (!s) continue;
            IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
            const uint8_t *base = IOSurfaceGetBaseAddress(s);
            size_t rows = IOSurfaceGetHeight(s), stride = IOSurfaceGetBytesPerRow(s);
            uint64_t h = 1469598103934665603ULL;
            for (size_t y = rows / 4; y < rows * 3 / 4 && base; y += 7) {
                for (size_t x = 0; x < stride; x += 64) { h ^= base[y * stride + x]; h *= 1099511628211ULL; }
            }
            IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
            [hashes addObject:@(h)];
            usleep(300000);
        }
        printf("FRAME polling: %lu different pictures in 12 fetches over %.1f s\n", (unsigned long)hashes.count,
               [[NSDate date] timeIntervalSinceDate:pollStart]);
        BOOL wrote = writePNG(found, out);
        printf("FRAME %s %s\n", wrote ? "YES: a frame written to" : "NO: could not write", out.UTF8String);
        CFRelease(found);
        return wrote ? 0 : 1;
    }
}
