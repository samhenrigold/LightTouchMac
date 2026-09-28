#include "ltm_link.h"
#include <servers/bootstrap.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <unistd.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // bootstrap_check_in

typedef struct {
    mach_msg_header_t h;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t ports[LTM_MAX_PORTS];
    uint32_t protocol_version;
    int32_t nports;
    uint64_t generation;
    char token[64];
} hello_msg;

typedef struct { hello_msg m; mach_msg_audit_trailer_t trailer; } hello_rcv;

kern_return_t ltm_check_in(const char *name, mach_port_t *rx) {
    return bootstrap_check_in(bootstrap_port, name, rx);
}

kern_return_t ltm_send_hello(const char *name, const char *token, uint32_t protocol_version,
                             uint64_t generation, const mach_port_t *ports, int n) {
    if (n < 0 || n > LTM_MAX_PORTS) return KERN_INVALID_ARGUMENT;
    mach_port_t dest;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &dest);
    if (kr) return kr;
    hello_msg m;
    memset(&m, 0, sizeof m);
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    m.h.msgh_size = sizeof m;
    m.h.msgh_remote_port = dest;
    m.h.msgh_id = LTM_HELLO_ID;
    m.body.msgh_descriptor_count = LTM_MAX_PORTS;
    for (int i = 0; i < LTM_MAX_PORTS; i++) {
        m.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
        m.ports[i].name = i < n ? ports[i] : MACH_PORT_NULL;
        m.ports[i].disposition = MACH_MSG_TYPE_MOVE_SEND;
    }
    m.protocol_version = protocol_version;
    m.nports = n;
    m.generation = generation;
    strlcpy(m.token, token, sizeof m.token);
    kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 2000, 0);
    if (kr) {   // the rights were not moved: release them here
        for (int i = 0; i < n; i++) if (ports[i]) mach_port_deallocate(mach_task_self(), ports[i]);
    }
    mach_port_deallocate(mach_task_self(), dest);
    return kr;
}

kern_return_t ltm_recv_hello(mach_port_t rx, int timeout_ms, ltm_hello *out) {
    hello_rcv r;
    memset(&r, 0, sizeof r);
    memset(out, 0, sizeof *out);
    mach_msg_option_t opt = MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                            MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    if (timeout_ms >= 0) opt |= MACH_RCV_TIMEOUT;
    kern_return_t kr = mach_msg(&r.m.h, opt, 0, sizeof r, rx, timeout_ms < 0 ? 0 : (mach_msg_timeout_t)timeout_ms, 0);
    if (kr == MACH_RCV_TOO_LARGE) {
        // Oversized junk from someone who looked the name up: drop it.
        mach_msg(&r.m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 0, rx, 0, 0);
        out->nports = -1;
        return KERN_SUCCESS;
    }
    if (kr) return kr;
    mach_msg_audit_trailer_t *t = (mach_msg_audit_trailer_t *)((uint8_t *)&r.m + r.m.h.msgh_size);
    out->audit = t->msgh_audit;
    out->pid = (pid_t)t->msgh_audit.val[5];   // audit_token_to_pid(), without linking libbsm
    if (!(r.m.h.msgh_bits & MACH_MSGH_BITS_COMPLEX) || r.m.h.msgh_size != sizeof(hello_msg) ||
        r.m.h.msgh_id != LTM_HELLO_ID || r.m.body.msgh_descriptor_count != LTM_MAX_PORTS ||
        r.m.nports < 0 || r.m.nports > LTM_MAX_PORTS) {
        mach_msg_destroy(&r.m.h);
        out->nports = -1;
        return KERN_SUCCESS;
    }
    out->nports = r.m.nports;
    for (int i = 0; i < LTM_MAX_PORTS; i++) {
        if (i < r.m.nports) out->ports[i] = r.m.ports[i].name;
        else if (r.m.ports[i].name) mach_port_deallocate(mach_task_self(), r.m.ports[i].name);
    }
    out->protocol_version = r.m.protocol_version;
    out->generation = r.m.generation;
    memcpy(out->token, r.m.token, sizeof out->token);
    out->token[63] = 0;
    return KERN_SUCCESS;
}

pid_t ltm_spawn(const char *path, char *const argv[], char *const envp[], int out_fd, int link_fd) {
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&fa);
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    if (out_fd >= 0) {
        posix_spawn_file_actions_adddup2(&fa, out_fd, 1);
        posix_spawn_file_actions_adddup2(&fa, out_fd, 2);
    } else {
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    }
    if (link_fd >= 0) posix_spawn_file_actions_adddup2(&fa, link_fd, 3);
    sigset_t all, none;
    sigfillset(&all);
    sigemptyset(&none);
    posix_spawnattr_setsigdefault(&attr, &all);
    posix_spawnattr_setsigmask(&attr, &none);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, &fa, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    return rc ? -rc : pid;
}
