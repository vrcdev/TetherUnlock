#import <Foundation/Foundation.h>
#if __has_include(<xpc/xpc.h>)
#include <xpc/xpc.h>
#else
/* trimmed SDK: declare the stable XPC C API */
typedef void *xpc_object_t;
typedef void *xpc_connection_t;
typedef void *xpc_type_t;
typedef void (^xpc_handler_t)(xpc_object_t);
extern const xpc_type_t _xpc_type_dictionary;
#define XPC_TYPE_DICTIONARY _xpc_type_dictionary
xpc_connection_t xpc_connection_create_mach_service(const char *, dispatch_queue_t, uint64_t);
void xpc_connection_set_event_handler(xpc_connection_t, xpc_handler_t);
void xpc_connection_resume(xpc_connection_t);
void xpc_connection_send_message_with_reply(xpc_connection_t, xpc_object_t, dispatch_queue_t, xpc_handler_t);
xpc_object_t xpc_dictionary_create(const char *const *, const xpc_object_t *, size_t);
void xpc_dictionary_set_uint64(xpc_object_t, const char *, uint64_t);
void xpc_dictionary_set_int64(xpc_object_t, const char *, int64_t);
void xpc_dictionary_set_bool(xpc_object_t, const char *, bool);
void xpc_dictionary_set_string(xpc_object_t, const char *, const char *);
xpc_type_t xpc_get_type(xpc_object_t);
char *xpc_copy_description(xpc_object_t);
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void dump(xpc_object_t o, const char *tag) {
    char *d = xpc_copy_description(o);
    fprintf(stderr, "%s: %s\n", tag, d);
    free(d);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        uint64_t cmd = argc > 1 ? strtoull(argv[1], NULL, 0) : 1000;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block int got_reply = 0;

        xpc_connection_t c = xpc_connection_create_mach_service(
            "com.apple.MobileInternetSharing", NULL, 0);
        xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
            if (xpc_get_type(e) == XPC_TYPE_DICTIONARY) {
                dump(e, "evt-dict");
            } else {
                dump(e, "evt");
            }
        });
        xpc_connection_resume(c);

        xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_uint64(m, "xpcKey", cmd);

        /* extra args: key=value (int, bool, or string) */
        for (int i = 2; i < argc; i++) {
            char *eq = strchr(argv[i], '=');
            if (!eq) continue;
            *eq = 0;
            char *v = eq + 1, *end;
            long long n = strtoll(v, &end, 0);
            if (*v && !*end) {
                xpc_dictionary_set_int64(m, argv[i], n);
            } else if (strcmp(v, "true") == 0) {
                xpc_dictionary_set_bool(m, argv[i], true);
            } else {
                xpc_dictionary_set_string(m, argv[i], v);
            }
        }

        xpc_connection_send_message_with_reply(c, m, NULL, ^(xpc_object_t r) {
            dump(r, "reply");
            got_reply = 1;
            dispatch_semaphore_signal(sem);
        });

        dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, 8LL * NSEC_PER_SEC);
        if (dispatch_semaphore_wait(sem, t) != 0)
            fprintf(stderr, "timeout waiting for reply (sent cmd %llu)\n", cmd);
        return got_reply ? 0 : 2;
    }
}
