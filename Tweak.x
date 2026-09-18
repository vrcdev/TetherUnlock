#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <substrate.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/stat.h>
#import <pthread.h>

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

static id g_inst;   /* captured misCTClientSharedInstance */
static int g_fired; /* activation already fired */

@interface TUCTClient : NSObject
- (void)activateTethering:(long)active;
- (void)setTetheringActive:(long)active;
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

- (void)setTetheringActive:(long)active {
    g_inst = self;
    tu_log("setTetheringActive(%ld)", active);
    %orig;
}

%end

/* trigger: /var/mobile/tether_on exists -> force activation from inside misd */
static void *trigger_thread(void *arg) {
    for (;;) {
        struct stat st;
        if (stat("/var/mobile/tether_on", &st) == 0) {
            if (!g_fired) {
                g_fired = 1;
                if (g_inst) {
                    tu_log("trigger: forcing setTetheringActive(1) + activateTethering(1)");
                    @autoreleasepool {
                        @try {
                            [(TUCTClient *)g_inst setTetheringActive:1];
                        } @catch (id e) { tu_log("setTetheringActive threw"); }
                        @try {
                            [(TUCTClient *)g_inst activateTethering:1];
                        } @catch (id e) { tu_log("activateTethering threw"); }
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

/* fake the CommCenter tethering assertion — misd treats NULL as denial */
static CFTypeRef fakeAssertion;
static CFTypeRef hook_assertion(void) {
    if (!fakeAssertion)
        fakeAssertion = CFStringCreateCopy(kCFAllocatorDefault, CFSTR("tetherunlock"));
    tu_log("TetheringAssertionCreate -> fake");
    return fakeAssertion;
}

%ctor {
    tu_log("=== TetherUnlock injected into %s ===", getprogname());
    MSHookFunction((void *)"_CTServerConnectionTetheringAssertionCreate",
                   (void *)hook_assertion, NULL);
    %init;
    pthread_t t;
    if (pthread_create(&t, NULL, trigger_thread, NULL) == 0)
        pthread_detach(t);
}
