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

/* patch out-struct: carrier_enabled/user_auth/conn_avail = YES, max_hosts = 5 */
static void force_status(void *status, const char *tag) {
    if (!status) { tu_log("%s: NULL out-struct", tag); return; }
    unsigned char *b = (unsigned char *)status;
    tu_log("%s: before carrier=%d auth=%d avail=%d max=%d",
           tag, b[0], b[1], b[2], *(int *)(b + 4));
    b[0] = 1; b[1] = 1; b[2] = 1;
    *(int *)(b + 4) = 5;
}

%hook misCTClientSharedInstance

- (void)getTetheringStatus:(void *)status :(id)arg {
    %orig;
    force_status(status, "getTetheringStatus");
}

- (void)convertConnectionStatus:(void *)out ctInterfaceConnStatus:(void *)in {
    %orig;
    force_status(out, "convertConnectionStatus");
}

- (void)convertTetheringStatus:(void *)out CTStatus:(void *)in {
    %orig;
    force_status(out, "convertTetheringStatus");
}

- (void)tetheringStatus:(void *)out connectionType:(long)t {
    %orig;
    force_status(out, "tetheringStatus");
    tu_log("tetheringStatus connectionType=%ld", t);
}

- (void)handleCTNotification:(id)name notificationInfo:(id)info {
    tu_log("handleCTNotification: %@ %@", name, info);
    %orig;
}

- (BOOL)isDataPlanEnabled:(id)arg {
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
    MSImageRef img = MSGetImageByName(
        "/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony");
    void *sym = img ? MSFindSymbol(img, "_CTServerConnectionTetheringAssertionCreate") : NULL;
    if (!sym) sym = MSFindSymbol(NULL, "_CTServerConnectionTetheringAssertionCreate");
    tu_log("CT image %p assertion sym %p", img, sym);
    if (sym) MSHookFunction(sym, (void *)hook_assertion, NULL);
    %init;
}
