// Measurement only, never merged: every keychain call and every Mach service asked for by name in
// this process, with the code that made it. Loaded with DYLD_INSERT_LIBRARIES into a build whose
// entitlements allow it; written to the file PB_TRACE_FILE names, one line per event. Nothing
// secret is written: an item's data is never read, an account or a comment only by its length.
//
//   clang -dynamiclib -O1 -o pbtrace.dylib pbtrace.c -framework Security -framework CoreFoundation
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <crt_externs.h>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// dyld's interposing: calls from every other image go to the replacement; this image's own calls
// to the replaced function go to the original.
#define INTERPOSE(replacement, replacee)                                                              \
    static __typeof__(&replacee) check_##replacee __attribute__((unused)) = &replacement;            \
    __attribute__((used)) static const struct { const void *r; const void *e; } interpose_##replacee \
        __attribute__((section("__DATA,__interpose"))) = {(const void *)&replacement, (const void *)&replacee}

static int traceFD = -1;
static __thread int busy;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    char *buffer;
    size_t length, capacity;
} Out;

static void put(Out *out, const char *text) {
    size_t count = strlen(text);
    if (out->length + count >= out->capacity) count = out->capacity - out->length - 1;
    memcpy(out->buffer + out->length, text, count);
    out->length += count;
    out->buffer[out->length] = 0;
}

static void putf(Out *out, const char *format, ...) {
    char text[2048];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(text, sizeof text, format, arguments);
    va_end(arguments);
    put(out, text);
}

static void emit(const char *line) {
    if (traceFD < 0) return;
    pthread_mutex_lock(&lock);
    write(traceFD, line, strlen(line));
    pthread_mutex_unlock(&lock);
}

// "12  SafariShared   0x000000019c0f1234 -[WBSFoo bar] + 52" → "SafariShared -[WBSFoo bar] + 52"
static void putStack(Out *out, int skip, int depth) {
    void *frames[64];
    int count = backtrace(frames, 64);
    char **symbols = backtrace_symbols(frames, count);
    if (!symbols) return;
    int shown = 0;
    for (int index = skip; index < count && shown < depth; index++, shown++) {
        const char *cursor = symbols[index];
        while (*cursor && *cursor != ' ') cursor++;
        while (*cursor == ' ') cursor++;
        char image[128];
        int length = 0;
        while (*cursor && *cursor != ' ' && length < 127) image[length++] = *cursor++;
        image[length] = 0;
        while (*cursor == ' ') cursor++;
        while (*cursor && *cursor != ' ') cursor++;
        while (*cursor == ' ') cursor++;
        putf(out, "%s%s %s", shown ? " < " : "", image, cursor);
    }
    free(symbols);
}

static void putString(Out *out, CFStringRef string, size_t limit) {
    char text[256];
    if (!CFStringGetCString(string, text, sizeof text, kCFStringEncodingUTF8)) {
        putf(out, "string(%ld)", (long)CFStringGetLength(string));
        return;
    }
    if (strlen(text) > limit) text[limit] = 0;
    putf(out, "\"%s\"", text);
}

static void putDictionary(Out *out, CFDictionaryRef dictionary, int depth);

static void putValue(Out *out, CFTypeRef value, int depth) {
    if (!value) {
        put(out, "nil");
        return;
    }
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        putString(out, value, 120);
    } else if (type == CFBooleanGetTypeID()) {
        put(out, CFBooleanGetValue(value) ? "true" : "false");
    } else if (type == CFNumberGetTypeID()) {
        long long number = 0;
        CFNumberGetValue(value, kCFNumberLongLongType, &number);
        putf(out, "%lld", number);
    } else if (type == CFDataGetTypeID()) {
        putf(out, "data(%ld)", (long)CFDataGetLength(value));
    } else if (type == CFDictionaryGetTypeID() && depth < 2) {
        putDictionary(out, value, depth + 1);
    } else if (type == CFArrayGetTypeID()) {
        putf(out, "array(%ld)", (long)CFArrayGetCount(value));
    } else {
        CFStringRef name = CFCopyTypeIDDescription(type);
        char text[64] = "?";
        if (name) {
            CFStringGetCString(name, text, sizeof text, kCFStringEncodingUTF8);
            CFRelease(name);
        }
        putf(out, "<%s>", text);
    }
}

// Data that names something (an application tag): its text when it is printable, else its length.
static void putTag(Out *out, CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFDataGetTypeID()) {
        putValue(out, value, 2);
        return;
    }
    CFIndex length = CFDataGetLength(value);
    const UInt8 *bytes = CFDataGetBytePtr(value);
    int printable = length > 0 && length <= 120;
    for (CFIndex index = 0; printable && index < length; index++) printable = bytes[index] >= 0x20 && bytes[index] < 0x7f;
    if (printable) {
        put(out, "tag\"");
        char text[128];
        memcpy(text, bytes, (size_t)length);
        text[length] = 0;
        put(out, text);
        put(out, "\"");
    } else {
        putf(out, "data(%ld)", (long)length);
    }
}

static void putDictionary(Out *out, CFDictionaryRef dictionary, int depth) {
    CFIndex total = CFDictionaryGetCount(dictionary);
    const void **keys = calloc((size_t)total + 1, sizeof(void *)), **values = calloc((size_t)total + 1, sizeof(void *));
    if (!keys || !values) {
        free(keys);
        free(values);
        put(out, "{?}");
        return;
    }
    CFDictionaryGetKeysAndValues(dictionary, keys, values);
    CFIndex count = total > 64 ? 64 : total;
    put(out, "{");
    for (CFIndex index = 0; index < count; index++) {
        CFTypeRef key = keys[index], value = values[index];
        if (index) put(out, " ");
        if (key && CFGetTypeID(key) == CFStringGetTypeID()) {
            char name[64];
            if (!CFStringGetCString(key, name, sizeof name, kCFStringEncodingUTF8)) strcpy(name, "?");
            put(out, name);
        } else {
            put(out, "?");
        }
        put(out, "=");
        if (CFEqual(key, kSecValueData)) {
            put(out, "<secret, not read>");
        } else if (CFEqual(key, kSecValueRef) || CFEqual(key, kSecValuePersistentRef)) {
            put(out, "<ref>");
        } else if (CFEqual(key, kSecAttrAccount) || CFEqual(key, kSecAttrComment)) {
            if (value && CFGetTypeID(value) == CFStringGetTypeID()) putf(out, "len%ld", (long)CFStringGetLength(value));
            else if (value && CFGetTypeID(value) == CFDataGetTypeID()) putf(out, "data(%ld)", (long)CFDataGetLength(value));
            else putValue(out, value, depth);
        } else if (CFEqual(key, kSecAttrApplicationTag) || CFEqual(key, kSecAttrGeneric)) {
            putTag(out, value);
        } else {
            putValue(out, value, depth);
        }
    }
    put(out, "}");
    free(keys);
    free(values);
}

static void keychain(const char *function, long status, CFDictionaryRef first, const char *secondName, CFDictionaryRef second,
                     const char *extra) {
    if (traceFD < 0 || busy) return;
    busy++;
    char buffer[16384];
    Out out = {buffer, 0, sizeof buffer};
    buffer[0] = 0;
    putf(&out, "PBTRACE %d KEYCHAIN %s status=%ld ", getpid(), function, status);
    if (extra) put(&out, extra);
    if (first) putDictionary(&out, first, 0);
    if (second) {
        putf(&out, " %s=", secondName);
        putDictionary(&out, second, 0);
    }
    put(&out, " | ");
    putStack(&out, 2, 24);
    put(&out, "\n");
    emit(buffer);
    busy--;
}

// MARK: SecItem

static OSStatus pb_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus status = SecItemAdd(attributes, result);
    keychain("SecItemAdd", status, attributes, NULL, NULL, NULL);
    return status;
}
INTERPOSE(pb_SecItemAdd, SecItemAdd);

static OSStatus pb_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus status = SecItemUpdate(query, attributesToUpdate);
    keychain("SecItemUpdate", status, query, "update", attributesToUpdate, NULL);
    return status;
}
INTERPOSE(pb_SecItemUpdate, SecItemUpdate);

static OSStatus pb_SecItemDelete(CFDictionaryRef query) {
    OSStatus status = SecItemDelete(query);
    keychain("SecItemDelete", status, query, NULL, NULL, NULL);
    return status;
}
INTERPOSE(pb_SecItemDelete, SecItemDelete);

static OSStatus pb_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus status = SecItemCopyMatching(query, result);
    keychain("SecItemCopyMatching", status, query, NULL, NULL, NULL);
    return status;
}
INTERPOSE(pb_SecItemCopyMatching, SecItemCopyMatching);

static SecKeyRef pb_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef key = SecKeyCreateRandomKey(parameters, error);
    keychain("SecKeyCreateRandomKey", key ? 0 : -1, parameters, NULL, NULL, NULL);
    return key;
}
INTERPOSE(pb_SecKeyCreateRandomKey, SecKeyCreateRandomKey);

// MARK: The file-based keychain's older calls

static void legacy(const char *function, long status, const char *what, UInt32 whatLength, UInt32 accountLength) {
    char extra[300];
    char name[200] = "";
    if (what && whatLength) {
        UInt32 length = whatLength < sizeof name - 1 ? whatLength : (UInt32)sizeof name - 1;
        memcpy(name, what, length);
        name[length] = 0;
    }
    snprintf(extra, sizeof extra, "name=\"%s\" account=len%u ", name, (unsigned)accountLength);
    keychain(function, status, NULL, NULL, NULL, extra);
}

static OSStatus pb_SecKeychainAddGenericPassword(SecKeychainRef keychainRef, UInt32 serviceNameLength, const char *serviceName,
                                                 UInt32 accountNameLength, const char *accountName, UInt32 passwordLength,
                                                 const void *passwordData, SecKeychainItemRef *itemRef) {
    OSStatus status = SecKeychainAddGenericPassword(keychainRef, serviceNameLength, serviceName, accountNameLength, accountName,
                                                    passwordLength, passwordData, itemRef);
    legacy("SecKeychainAddGenericPassword", status, serviceName, serviceNameLength, accountNameLength);
    return status;
}
INTERPOSE(pb_SecKeychainAddGenericPassword, SecKeychainAddGenericPassword);

static OSStatus pb_SecKeychainFindGenericPassword(CFTypeRef keychainOrArray, UInt32 serviceNameLength, const char *serviceName,
                                                  UInt32 accountNameLength, const char *accountName, UInt32 *passwordLength,
                                                  void **passwordData, SecKeychainItemRef *itemRef) {
    OSStatus status = SecKeychainFindGenericPassword(keychainOrArray, serviceNameLength, serviceName, accountNameLength, accountName,
                                                     passwordLength, passwordData, itemRef);
    legacy("SecKeychainFindGenericPassword", status, serviceName, serviceNameLength, accountNameLength);
    return status;
}
INTERPOSE(pb_SecKeychainFindGenericPassword, SecKeychainFindGenericPassword);

static OSStatus pb_SecKeychainAddInternetPassword(SecKeychainRef keychainRef, UInt32 serverNameLength, const char *serverName,
                                                  UInt32 securityDomainLength, const char *securityDomain, UInt32 accountNameLength,
                                                  const char *accountName, UInt32 pathLength, const char *path, UInt16 port,
                                                  SecProtocolType protocol, SecAuthenticationType authenticationType,
                                                  UInt32 passwordLength, const void *passwordData, SecKeychainItemRef *itemRef) {
    OSStatus status = SecKeychainAddInternetPassword(keychainRef, serverNameLength, serverName, securityDomainLength, securityDomain,
                                                     accountNameLength, accountName, pathLength, path, port, protocol,
                                                     authenticationType, passwordLength, passwordData, itemRef);
    legacy("SecKeychainAddInternetPassword", status, serverName, serverNameLength, accountNameLength);
    return status;
}
INTERPOSE(pb_SecKeychainAddInternetPassword, SecKeychainAddInternetPassword);

static OSStatus pb_SecKeychainFindInternetPassword(CFTypeRef keychainOrArray, UInt32 serverNameLength, const char *serverName,
                                                   UInt32 securityDomainLength, const char *securityDomain, UInt32 accountNameLength,
                                                   const char *accountName, UInt32 pathLength, const char *path, UInt16 port,
                                                   SecProtocolType protocol, SecAuthenticationType authenticationType,
                                                   UInt32 *passwordLength, void **passwordData, SecKeychainItemRef *itemRef) {
    OSStatus status = SecKeychainFindInternetPassword(keychainOrArray, serverNameLength, serverName, securityDomainLength,
                                                      securityDomain, accountNameLength, accountName, pathLength, path, port,
                                                      protocol, authenticationType, passwordLength, passwordData, itemRef);
    legacy("SecKeychainFindInternetPassword", status, serverName, serverNameLength, accountNameLength);
    return status;
}
INTERPOSE(pb_SecKeychainFindInternetPassword, SecKeychainFindInternetPassword);

static OSStatus pb_SecKeychainItemModifyAttributesAndData(SecKeychainItemRef itemRef, const SecKeychainAttributeList *attrList,
                                                          UInt32 length, const void *data) {
    OSStatus status = SecKeychainItemModifyAttributesAndData(itemRef, attrList, length, data);
    char extra[64];
    snprintf(extra, sizeof extra, "attributes=%u data=%s ", attrList ? (unsigned)attrList->count : 0, data ? "yes" : "no");
    keychain("SecKeychainItemModifyAttributesAndData", status, NULL, NULL, NULL, extra);
    return status;
}
INTERPOSE(pb_SecKeychainItemModifyAttributesAndData, SecKeychainItemModifyAttributesAndData);

static OSStatus pb_SecKeychainItemDelete(SecKeychainItemRef itemRef) {
    OSStatus status = SecKeychainItemDelete(itemRef);
    keychain("SecKeychainItemDelete", status, NULL, NULL, NULL, NULL);
    return status;
}
INTERPOSE(pb_SecKeychainItemDelete, SecKeychainItemDelete);

// MARK: Mach services asked for by name

#define SEEN_MAX 2048
static char *seenNames[SEEN_MAX];
static unsigned seenCounts[SEEN_MAX];
static unsigned seenTotal;

static void lookup(const char *function, const char *name, long result) {
    if (traceFD < 0 || busy || !name) return;
    busy++;
    char key[300];
    snprintf(key, sizeof key, "%s %s", function, name);
    int first = 0;
    pthread_mutex_lock(&lock);
    unsigned index = 0;
    for (; index < seenTotal; index++)
        if (strcmp(seenNames[index], key) == 0) break;
    if (index == seenTotal && seenTotal < SEEN_MAX) {
        seenNames[seenTotal] = strdup(key);
        seenCounts[seenTotal++] = 1;
        first = 1;
    } else if (index < seenTotal) {
        seenCounts[index]++;
    }
    pthread_mutex_unlock(&lock);
    if (first) {
        char buffer[8192];
        Out out = {buffer, 0, sizeof buffer};
        buffer[0] = 0;
        putf(&out, "PBTRACE %d LOOKUP %s name=%s result=%ld | ", getpid(), function, name, result);
        putStack(&out, 2, 14);
        put(&out, "\n");
        emit(buffer);
    }
    busy--;
}

static kern_return_t pb_bootstrap_look_up(mach_port_t bootstrapPort, const char *name, mach_port_t *servicePort) {
    kern_return_t result = bootstrap_look_up(bootstrapPort, name, servicePort);
    lookup("bootstrap_look_up", name, result);
    return result;
}
INTERPOSE(pb_bootstrap_look_up, bootstrap_look_up);

static xpc_connection_t pb_xpc_connection_create_mach_service(const char *name, dispatch_queue_t queue, uint64_t flags) {
    xpc_connection_t connection = xpc_connection_create_mach_service(name, queue, flags);
    lookup("xpc_connection_create_mach_service", name, (long)flags);
    return connection;
}
INTERPOSE(pb_xpc_connection_create_mach_service, xpc_connection_create_mach_service);

static xpc_connection_t pb_xpc_connection_create(const char *name, dispatch_queue_t queue) {
    xpc_connection_t connection = xpc_connection_create(name, queue);
    if (name) lookup("xpc_connection_create", name, 0);
    return connection;
}
INTERPOSE(pb_xpc_connection_create, xpc_connection_create);

// MARK: Start and end

static void counts(void) {
    if (traceFD < 0) return;
    busy++;
    pthread_mutex_lock(&lock);
    for (unsigned index = 0; index < seenTotal; index++) {
        char line[400];
        snprintf(line, sizeof line, "PBTRACE %d LOOKUPCOUNT %u %s\n", getpid(), seenCounts[index], seenNames[index]);
        write(traceFD, line, strlen(line));
    }
    pthread_mutex_unlock(&lock);
    busy--;
}

__attribute__((constructor)) static void start(void) {
    const char *path = getenv("PB_TRACE_FILE");
    if (!path || !*path) return;
    traceFD = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (traceFD < 0) return;
    char line[2048];
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    snprintf(line, sizeof line, "PBTRACE %d PROC ppid=%d argv=%s %s %s\n", getpid(), getppid(), argc > 0 ? argv[0] : "",
             argc > 1 ? argv[1] : "", argc > 2 ? argv[2] : "");
    emit(line);
    atexit(counts);
}
