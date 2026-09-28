// C glue for the app <-> LightTouchDevice link (docs/multi-device-plan.md, section A):
// atomics on the shared status block (Swift cannot put an atomic at an arbitrary
// address), the Mach rendezvous that moves IOSurface ports, and posix_spawn with
// the link socket as fd 3 (Foundation's Process cannot pass an extra descriptor).
#ifndef LTM_LINK_H
#define LTM_LINK_H

#include <stdint.h>
#include <mach/mach.h>
#include <sys/types.h>

static inline uint64_t ltm_load(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void ltm_store(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
// Seq-cst pair for the frame handshake (writer: store serial, load held; reader:
// store held, load serial). Acquire/release alone would let both sides miss.
static inline uint64_t ltm_load_seq(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
static inline void ltm_store_seq(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); }
static inline uint64_t ltm_add(volatile uint64_t *p, uint64_t v) { return __atomic_add_fetch(p, v, __ATOMIC_RELEASE); }

#define LTM_MAX_PORTS 4           // status block + 3-surface frame ring
#define LTM_HELLO_ID 0x4C544D48   // 'LTMH'

typedef struct {
    char token[64];               // the one-time token from argv, NUL-terminated
    uint32_t protocol_version;
    uint64_t generation;          // ring generation; 0 = status block only
    int nports;                   // -1: malformed message (ports already destroyed)
    mach_port_t ports[LTM_MAX_PORTS];
    audit_token_t audit;          // the sender, from the kernel's audit trailer
    pid_t pid;                    // the audit token's pid
} ltm_hello;

// App: check the per-process name in with launchd. (A dynamic NSXPCListener is refused.)
kern_return_t ltm_check_in(const char *name, mach_port_t *rx);
// Helper: look the name up and send the token + surface ports (IOSurfaceCreateMachPort; moved).
kern_return_t ltm_send_hello(const char *name, const char *token, uint32_t protocol_version,
                             uint64_t generation, const mach_port_t *ports, int n);
// App: receive one hello; timeout_ms < 0 waits forever.
kern_return_t ltm_recv_hello(mach_port_t rx, int timeout_ms, ltm_hello *out);
// Spawn with stdin /dev/null, stdout+stderr on out_fd, the link socket on fd 3 and
// nothing else inherited (POSIX_SPAWN_CLOEXEC_DEFAULT), default signal dispositions.
// Returns the pid, or -errno.
pid_t ltm_spawn(const char *path, char *const argv[], char *const envp[], int out_fd, int link_fd);

#endif
