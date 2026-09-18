#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/stat.h>
#import <pthread.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <string.h>
#import <dlfcn.h>
#if __arm64e__
#include <ptrauth.h>
#endif

#if __has_include(<xpc/xpc.h>)
#include <xpc/xpc.h>
#else
typedef void *xpc_object_t;
typedef void *xpc_type_t;
typedef void *xpc_connection_t;
extern const xpc_type_t _xpc_type_dictionary;
#define XPC_TYPE_DICTIONARY _xpc_type_dictionary
xpc_type_t xpc_get_type(xpc_object_t);
#endif

static void tu_log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[512]; vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    FILE *f = fopen("/var/mobile/tetherunlock.log", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

static void force_status(void *status, const char *tag) {
    if (!status) { tu_log("%s: NULL out-struct", tag); return; }
    unsigned char *b = (unsigned char *)status;
    tu_log("%s: before carrier=%d auth=%d avail=%d max=%d",
           tag, b[0], b[1], b[2], *(int *)(b + 4));
    b[0] = 1; b[1] = 1; b[2] = 1;
    *(int *)(b + 4) = 5;
}

static void log_ifaddrs(const char *tag) {
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0 || !ifa) { tu_log("%s: getifaddrs failed", tag); return; }
    char line[1024] = {0}; size_t off = 0;
    for (struct ifaddrs *p = ifa; p && off < sizeof(line) - 24; p = p->ifa_next) {
        int n = snprintf(line + off, sizeof(line) - off, "%s ", p->ifa_name);
        if (n > 0) off += (size_t)n;
    }
    freeifaddrs(ifa);
    tu_log("%s: ifaces: %s", tag, line);
}

static id g_inst;   /* captured misCTClientSharedInstance */
static int g_fired; /* activation already fired */

@interface TUCTClient : NSObject
- (void)activateTethering:(long)active;
@end

%hook misCTClientSharedInstance

- (void)getTetheringStatus:(void *)status :(id)arg {
    g_inst = self;
    %orig;
    force_status(status, "getTetheringStatus");
}

- (void)convertConnectionStatus:(void *)out ctInterfaceConnStatus:(void *)in {
    g_inst = self;
    %orig;
    force_status(out, "convertConnectionStatus");
}

- (void)convertTetheringStatus:(void *)out CTStatus:(void *)in {
    g_inst = self;
    %orig;
    force_status(out, "convertTetheringStatus");
}

- (void)tetheringStatus:(void *)out connectionType:(long)t {
    g_inst = self;
    %orig;
    force_status(out, "tetheringStatus");
}

- (void)handleCTNotification:(id)name notificationInfo:(id)info {
    tu_log("handleCTNotification: %@", name);
    g_inst = self;
    %orig;
}

- (BOOL)isDataPlanEnabled:(id)arg {
    g_inst = self;
    return YES;
}

- (void)activateTethering:(long)active {
    g_inst = self;
    tu_log("activateTethering(%ld)", active);
    %orig;
}

%end

/* misd's internal setTetheringActive IMP — VA 0x10001c128.
   Signature: int fn(id self, SEL _cmd, BOOL active)
   Requires ivar+8 (CTServerConnection) to be non-NULL. */
static int call_setTetheringActive(id inst, BOOL active) {
    const char *hdr = NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, "/usr/libexec/misd") == 0) {
            hdr = (const char *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!hdr) { tu_log("misd image not found in %u images", n); return -1; }
    void *raw = (void *)(hdr + 0x1c128);
#if __arm64e__
    int (*imp)(id, SEL, BOOL) = (int (*)(id, SEL, BOOL))
        ptrauth_sign_unauthenticated(raw, ptrauth_key_function_pointer, 0);
#else
    int (*imp)(id, SEL, BOOL) = raw;
#endif
    return imp(inst, NULL, active);
}

/* trigger: /var/mobile/tether_on exists -> call the real activation IMP */
static void *trigger_thread(void *arg) {
    log_ifaddrs("startup");
    for (;;) {
        struct stat st;
        if (stat("/var/mobile/tether_on", &st) == 0) {
            if (!g_fired) {
                g_fired = 1;
                if (g_inst) {
                    tu_log("trigger: calling setTetheringActive IMP(%p, YES)", g_inst);
                    @autoreleasepool {
                        int r = call_setTetheringActive(g_inst, YES);
                        tu_log("setTetheringActive IMP returned %d", r);
                        usleep(500000);
                        log_ifaddrs("after-active");
                    }
                } else {
                    tu_log("trigger: no instance captured yet");
                    g_fired = 0;
                }
            }
        } else {
            g_fired = 0;
        }
        usleep(500000);
    }
    return NULL;
}

/* --- protocol discovery: log every xpc dict key misd reads --- */
static uint64_t (*orig_xdg_u64)(xpc_object_t, const char *, uint64_t);
static uint64_t hook_xdg_u64(xpc_object_t d, const char *k, uint64_t def) {
    uint64_t r = orig_xdg_u64(d, k, def);
    tu_log("xpc_get_uint64(\"%s\") = %llu", k ? k : "?", r);
    return r;
}

static int64_t (*orig_xdg_i64)(xpc_object_t, const char *, int64_t);
static int64_t hook_xdg_i64(xpc_object_t d, const char *k, int64_t def) {
    int64_t r = orig_xdg_i64(d, k, def);
    tu_log("xpc_get_int64(\"%s\") = %lld", k ? k : "?", r);
    return r;
}

static const char *(*orig_xdg_str)(xpc_object_t, const char *);
static const char *hook_xdg_str(xpc_object_t d, const char *k) {
    const char *r = orig_xdg_str(d, k);
    tu_log("xpc_get_string(\"%s\") = %s", k ? k : "?", r ? r : "(null)");
    return r;
}

static _Bool (*orig_xdg_bool)(xpc_object_t, const char *);
static _Bool hook_xdg_bool(xpc_object_t d, const char *k) {
    _Bool r = orig_xdg_bool(d, k);
    tu_log("xpc_get_bool(\"%s\") = %d", k ? k : "?", r);
    return r;
}

static xpc_object_t (*orig_xdg_dict)(xpc_object_t, const char *);
static xpc_object_t hook_xdg_dict(xpc_object_t d, const char *k) {
    xpc_object_t r = orig_xdg_dict(d, k);
    tu_log("xpc_get_dictionary(\"%s\") = %p", k ? k : "?", r);
    return r;
}

static xpc_object_t (*orig_xdg_val)(xpc_object_t, const char *);
static xpc_object_t hook_xdg_val(xpc_object_t d, const char *k) {
    xpc_object_t r = orig_xdg_val(d, k);
    if (r)
        tu_log("xpc_get_value(\"%s\") = %p type=%p", k ? k : "?", r, xpc_get_type(r));
    return r;
}

static void (*orig_xdg_uuid)(xpc_object_t, const char *, unsigned char *);
static void hook_xdg_uuid(xpc_object_t d, const char *k, unsigned char *out) {
    orig_xdg_uuid(d, k, out);
    tu_log("xpc_get_uuid(\"%s\") = %02x%02x%02x%02x...", k ? k : "?",
           out[0], out[1], out[2], out[3]);
}

static const void *(*orig_xdg_data)(xpc_object_t, const char *, size_t *);
static const void *hook_xdg_data(xpc_object_t d, const char *k, size_t *len) {
    const void *r = orig_xdg_data(d, k, len);
    tu_log("xpc_get_data(\"%s\") = %p len=%zu", k ? k : "?", r, len ? *len : 0);
    return r;
}

static xpc_object_t (*orig_xdg_arr)(xpc_object_t, const char *);
static xpc_object_t hook_xdg_arr(xpc_object_t d, const char *k) {
    xpc_object_t r = orig_xdg_arr(d, k);
    tu_log("xpc_get_array(\"%s\") = %p", k ? k : "?", r);
    return r;
}

static double (*orig_xdg_dbl)(xpc_object_t, const char *, double);
static double hook_xdg_dbl(xpc_object_t d, const char *k, double def) {
    double r = orig_xdg_dbl(d, k, def);
    tu_log("xpc_get_double(\"%s\") = %f", k ? k : "?", r);
    return r;
}

static xpc_connection_t (*orig_xdg_conn)(xpc_object_t, const char *);
static xpc_connection_t hook_xdg_conn(xpc_object_t d, const char *k) {
    xpc_connection_t r = orig_xdg_conn(d, k);
    tu_log("xpc_get_connection(\"%s\") = %p", k ? k : "?", r);
    return r;
}

static void hook_xpc_getters(void) {
    void *lib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW);
    if (!lib) lib = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_NOW);
    struct { const char *n; void *h; void **o; } hooks[] = {
        { "xpc_dictionary_get_uint64", (void *)hook_xdg_u64, (void **)&orig_xdg_u64 },
        { "xpc_dictionary_get_int64",  (void *)hook_xdg_i64, (void **)&orig_xdg_i64 },
        { "xpc_dictionary_get_string", (void *)hook_xdg_str, (void **)&orig_xdg_str },
        { "xpc_dictionary_get_bool",   (void *)hook_xdg_bool,(void **)&orig_xdg_bool },
        { "xpc_dictionary_get_dictionary", (void *)hook_xdg_dict, (void **)&orig_xdg_dict },
        { "xpc_dictionary_get_value",  (void *)hook_xdg_val, (void **)&orig_xdg_val },
        { "xpc_dictionary_get_uuid",   (void *)hook_xdg_uuid,(void **)&orig_xdg_uuid },
        { "xpc_dictionary_get_data",   (void *)hook_xdg_data,(void **)&orig_xdg_data },
        { "xpc_dictionary_get_array",  (void *)hook_xdg_arr, (void **)&orig_xdg_arr },
        { "xpc_dictionary_get_double", (void *)hook_xdg_dbl, (void **)&orig_xdg_dbl },
        { "xpc_dictionary_get_connection", (void *)hook_xdg_conn, (void **)&orig_xdg_conn },
    };
    for (int i = 0; i < 11; i++) {
        void *sym = lib ? dlsym(lib, hooks[i].n) : NULL;
        if (!sym) sym = dlsym(RTLD_DEFAULT, hooks[i].n);
        if (sym) {
            MSHookFunction(sym, hooks[i].h, hooks[i].o);
            tu_log("hooked %s @ %p", hooks[i].n, sym);
        } else {
            tu_log("FAILED to find %s", hooks[i].n);
        }
    }
}

%ctor {
    tu_log("=== TetherUnlock injected into %s ===", getprogname());
    %init;
    hook_xpc_getters();
    pthread_t t;
    if (pthread_create(&t, NULL, trigger_thread, NULL) == 0)
        pthread_detach(t);
}
