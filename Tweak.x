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
    int (*imp)(id, SEL, BOOL) = (void *)(hdr + 0x1c128);
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

%ctor {
    tu_log("=== TetherUnlock injected into %s ===", getprogname());
    %init;
    pthread_t t;
    if (pthread_create(&t, NULL, trigger_thread, NULL) == 0)
        pthread_detach(t);
}
