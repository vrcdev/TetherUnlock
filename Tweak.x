#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <substrate.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>

static void tu_log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    char buf[512]; vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    FILE *f = fopen("/var/mobile/tetherunlock.log", "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
}

/*
 * misd's CoreTelephony client singleton. getTetheringStatus fills:
 *   struct mis_ctinterface_tethering_status {
 *       BOOL carrier_enabled;   // +0
 *       BOOL user_auth;         // +1
 *       BOOL conn_avail;        // +2
 *       int  max_hosts;         // +4
 *       struct { int; int; char ifname[16]; } conn_status; // +8
 *   }
 */
%hook misCTClientSharedInstance

- (void)getTetheringStatus:(void *)status :(id)arg {
    %orig;
    if (status) {
        unsigned char *b = (unsigned char *)status;
        b[0] = 1; b[1] = 1; b[2] = 1;
        *(int *)(b + 4) = 5;
    }
    tu_log("getTetheringStatus -> forced carrier/user_auth/conn_avail YES");
}

- (BOOL)isDataPlanEnabled:(id)arg {
    tu_log("isDataPlanEnabled -> YES");
    return YES;
}

- (void)activateTethering:(long)active {
    tu_log("activateTethering(%ld)", active);
    %orig;
}

- (void)setTetheringActive:(long)active {
    tu_log("setTetheringActive(%ld)", active);
    %orig;
}

%end

/*
 * The carrier gate: misd calls _CTServerConnectionTetheringAssertionCreate and
 * treats NULL as denial ("error creating tethering assertion"). We never ask
 * CommCenter — hand back a retained CF object so any later CFRelease is safe
 * and the assertion always "succeeds".
 */
static CFTypeRef fakeAssertion;
static CFTypeRef hook_assertion(void) {
    if (!fakeAssertion)
        fakeAssertion = CFStringCreateCopy(kCFAllocatorDefault, CFSTR("tetherunlock"));
    tu_log("TetheringAssertionCreate -> fake assertion");
    return fakeAssertion;
}

%ctor {
    tu_log("=== TetherUnlock injected into %s ===", getprogname());
    void *sym = MSFindSymbol(NULL, "_CTServerConnectionTetheringAssertionCreate");
    tu_log("assertion symbol @ %p", sym);
    if (sym)
        MSHookFunction(sym, (void *)hook_assertion, NULL);
    %init;
}
