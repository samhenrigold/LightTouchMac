#include "shim.h"
#include <servers/bootstrap.h>
#include <bsm/libbsm.h>
#include <spawn.h>
#include <string.h>
#include <unistd.h>
extern char **environ;
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t ports[LTM_MAX_PORTS];
    int nports;
    char token[64];
} hello_msg;

typedef struct { hello_msg m; mach_msg_audit_trailer_t trailer; } hello_rcv;

kern_return_t ltm_check_in(const char *name, mach_port_t *rx) {
    return bootstrap_check_in(bootstrap_port, name, rx);
}

kern_return_t ltm_send_hello(const char *name, const char *token, const mach_port_t *ports, int n) {
    mach_port_t dest;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &dest);
    if (kr) return kr;
    hello_msg m;
    memset(&m, 0, sizeof m);
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    m.h.msgh_size = sizeof m;
    m.h.msgh_remote_port = dest;
    m.h.msgh_id = 0x4C544D;
    m.body.msgh_descriptor_count = LTM_MAX_PORTS;
    for (int i = 0; i < LTM_MAX_PORTS; i++) {
        m.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
        m.ports[i].name = i < n ? ports[i] : MACH_PORT_NULL;
        m.ports[i].disposition = MACH_MSG_TYPE_MOVE_SEND;
    }
    m.nports = n;
    strlcpy(m.token, token, sizeof m.token);
    kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 2000, 0);
    mach_port_deallocate(mach_task_self(), dest);
    return kr;
}

kern_return_t ltm_recv_hello(mach_port_t rx, int timeout_ms, ltm_hello *out) {
    hello_rcv r;
    memset(&r, 0, sizeof r);
    mach_msg_option_t opt = MACH_RCV_MSG | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                            MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    if (timeout_ms >= 0) opt |= MACH_RCV_TIMEOUT;
    kern_return_t kr = mach_msg(&r.m.h, opt, 0, sizeof r, rx, timeout_ms < 0 ? 0 : timeout_ms, 0);
    if (kr) return kr;
    mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)((uint8_t *)&r.m + r.m.h.msgh_size);
    out->audit = t->msgh_audit;
    out->pid = audit_token_to_pid(t->msgh_audit);
    if (!(r.m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) || r.m.h.msgh_size != sizeof(hello_msg)) {
        mach_msg_destroy(&r.m.h);
        out->nports = -1;
        return KERN_SUCCESS;
    }
    out->nports = r.m.nports > LTM_MAX_PORTS ? LTM_MAX_PORTS : r.m.nports;
    for (int i = 0; i < LTM_MAX_PORTS; i++) out->ports[i] = r.m.ports[i].name;
    memcpy(out->token, r.m.token, sizeof out->token);
    out->token[63] = 0;
    return KERN_SUCCESS;
}

pid_t ltm_spawn(const char *path, char *const argv[], int fd3) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", 0, 0);
    if (fd3 >= 0) posix_spawn_file_actions_adddup2(&fa, fd3, 3);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    return rc ? -rc : pid;
}
