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
xpc_connection_t xpc_connection_create(const char *, dispatch_queue_t);
void xpc_connection_set_event_handler(xpc_connection_t, xpc_handler_t);
void xpc_connection_resume(xpc_connection_t);
void xpc_connection_send_message_with_reply(xpc_connection_t, xpc_object_t, dispatch_queue_t, xpc_handler_t);
xpc_object_t xpc_dictionary_create(const char *const *, const xpc_object_t *, size_t);
void xpc_dictionary_set_uint64(xpc_object_t, const char *, uint64_t);
void xpc_dictionary_set_int64(xpc_object_t, const char *, int64_t);
void xpc_dictionary_set_bool(xpc_object_t, const char *, bool);
void xpc_dictionary_set_string(xpc_object_t, const char *, const char *);
void xpc_dictionary_set_connection(xpc_object_t, const char *, xpc_connection_t);
const char *xpc_dictionary_get_string(xpc_object_t, const char *);
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

static void set_param(xpc_object_t m, char *arg) {
    char *eq = strchr(arg, '=');
    if (!eq) return;
    *eq = 0;
    char *v = eq + 1, *end;
    long long n = strtoll(v, &end, 0);
    if (*v && !*end) {
        xpc_dictionary_set_int64(m, arg, n);
    } else if (!strcmp(v, "true")) {
        xpc_dictionary_set_bool(m, arg, true);
    } else {
        xpc_dictionary_set_string(m, arg, v);
    }
}

static int send_cmd(xpc_connection_t c, uint64_t cmd, int nparams, char **params) {
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(m, "xpcKey", cmd);
    for (int i = 0; i < nparams; i++)
        set_param(m, params[i]);

    __block int got = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(c, m, NULL, ^(xpc_object_t r) {
        dump(r, "reply");
        got = 1;
        dispatch_semaphore_signal(sem);
    });
    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, 6LL * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(sem, t) != 0)
        fprintf(stderr, "timeout (cmd %llu)\n", cmd);
    return got;
}

/* usage: tetherctl <cmd> [k=v ...]            — single command
   or:    tetherctl seq <cmd1> <cmd2> ...      — commands on one connection
   or:    tetherctl link [k=v ...]             — create-client with a
                                                clientCommunication push conn,
                                                stay alive, print all pushes  */
int main(int argc, char **argv) {
    @autoreleasepool {
        int seq = argc > 1 && !strcmp(argv[1], "seq");
        int link = argc > 1 && !strcmp(argv[1], "link");

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
        usleep(200000);

        if (link) {
            /* anonymous peer connection handed to misd as the async channel */
            xpc_connection_t comm = xpc_connection_create(NULL, NULL);
            xpc_connection_set_event_handler(comm, ^(xpc_object_t e) {
                dump(e, "comm-push");
            });
            xpc_connection_resume(comm);

            xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_uint64(m, "xpcKey", 1000);
            xpc_dictionary_set_connection(m, "clientCommunication", comm);

            __block char *clientid = NULL;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            xpc_connection_send_message_with_reply(c, m, NULL, ^(xpc_object_t r) {
                dump(r, "reply");
                const char *cid = xpc_dictionary_get_string(r, "clientid");
                if (cid) clientid = strdup(cid);
                dispatch_semaphore_signal(sem);
            });
            dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, 6LL * NSEC_PER_SEC);
            dispatch_semaphore_wait(sem, t);
            fprintf(stderr, "clientid = %s\n", clientid ? clientid : "(none)");

            /* remaining args = follow-up commands, sent with the clientid */
            for (int i = 2; i < argc; i++) {
                uint64_t cmd = strtoull(argv[i], NULL, 0);
                if (!cmd) continue;
                fprintf(stderr, ">>> cmd %llu (clientid)\n", cmd);
                xpc_object_t f = xpc_dictionary_create(NULL, NULL, 0);
                xpc_dictionary_set_uint64(f, "xpcKey", cmd);
                if (clientid)
                    xpc_dictionary_set_string(f, "clientid", clientid);
                /* optional k=v after the command, until the next bare number */
                while (i + 1 < argc && strchr(argv[i + 1], '='))
                    set_param(f, argv[++i]);
                xpc_connection_send_message_with_reply(c, f, NULL, ^(xpc_object_t r) {
                    dump(r, "reply");
                });
                usleep(300000);
            }
            fprintf(stderr, "link up, listening for pushes...\n");
            sleep(8);
            return 0;
        }

        if (seq) {
            for (int i = 2; i < argc; i++) {
                uint64_t cmd = strtoull(argv[i], NULL, 0);
                fprintf(stderr, ">>> cmd %llu\n", cmd);
                send_cmd(c, cmd, 0, NULL);
            }
        } else {
            uint64_t cmd = argc > 1 ? strtoull(argv[1], NULL, 0) : 1000;
            send_cmd(c, cmd, argc - 2, argv + 2);
        }
        usleep(500000);
        return 0;
    }
}
