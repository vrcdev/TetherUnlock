/* usbeth — send the USBDeviceConfig MIG rpc that adds/removes an
 * AppleUSBEthernet function to the iPhone USB gadget.
 * Replicates USBEthernetSharing.plugin's call:
 *   bootstrap_look_up("com.apple.SystemConfiguration.USBDeviceConfig")
 *   mach_msg(msgh_id=30050 add / 30051 remove?, body = NDR + {0,len} + name)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/message.h>

/* trimmed SDK lacks servers/bootstrap.h */
kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);

/* NDR_record_t + NDR_record come from mach/ndr.h via mach/mach.h */

struct req {
    mach_msg_header_t hdr;   /* 24 bytes */
    NDR_record_t      ndr;   /* 8  */
    int32_t           pad;   /* 4  — always 0 */
    int32_t           len;   /* 4  — strlen(name) */
    char              name[256];
};

struct rep {
    mach_msg_header_t hdr;
    NDR_record_t      ndr;
    int32_t           ret;
    int32_t           pad;
    mach_msg_trailer_t trailer;
};

int main(int argc, char **argv) {
    const char *name = argc > 1 ? argv[1] : "AppleUSBEthernet";
    uint32_t msgh_id = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 30050;

    mach_port_t svc = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port,
        "com.apple.SystemConfiguration.USBDeviceConfig", &svc);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "bootstrap_look_up failed: %x\n", kr);
        return 1;
    }
    fprintf(stderr, "service port = %u\n", svc);

    mach_port_t reply = mig_get_reply_port();

    struct req q;
    memset(&q, 0, sizeof q);
    q.hdr.msgh_bits        = 0x1513;                  /* as emitted by plugin */
    q.hdr.msgh_remote_port = svc;
    q.hdr.msgh_local_port  = reply;
    q.hdr.msgh_voucher_port = 0;
    q.hdr.msgh_id          = msgh_id;
    q.ndr  = NDR_record;
    q.pad  = 0;
    q.len  = (int32_t)strlen(name);
    strncpy(q.name, name, sizeof(q.name) - 1);

    mach_msg_size_t ssize = 0x28 + ((q.len + 3) & ~3);
    q.hdr.msgh_size = ssize;

    struct rep r;
    memset(&r, 0, sizeof r);
    kr = mach_msg(&q.hdr, MACH_SEND_MSG | MACH_RCV_MSG, ssize,
                  sizeof(r), reply, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    fprintf(stderr, "mach_msg -> %x\n", kr);
    if (kr == MACH_MSG_SUCCESS) {
        fprintf(stderr, "reply id=%u ret=%d\n", r.hdr.msgh_id, r.ret);
    }
    return kr == MACH_MSG_SUCCESS ? (r.ret ? 2 : 0) : 1;
}
