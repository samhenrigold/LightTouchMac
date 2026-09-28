// Spike-only C glue: atomics on raw shared memory (Swift has no portable way to
// put an atomic at an arbitrary address) and the Mach rendezvous (fallback (a)).
#include <stdint.h>
#include <mach/mach.h>
#include <sys/types.h>
static inline uint64_t ltm_load(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void ltm_store(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
// Seq-cst pair for the reader/writer handshake (writer: store serial, load held;
// reader: store held, load serial) -- acquire/release alone allows both to miss.
static inline uint64_t ltm_load_seq(const volatile uint64_t *p) { return __atomic_load_n(p, __ATOMIC_SEQ_CST); }
static inline void ltm_store_seq(volatile uint64_t *p, uint64_t v) { __atomic_store_n(p, v, __ATOMIC_SEQ_CST); }

#define LTM_MAX_PORTS 8
typedef struct {
    char token[64];                 // the one-time token from argv (NUL-terminated)
    int nports;
    mach_port_t ports[LTM_MAX_PORTS];
    audit_token_t audit;            // sender, from the kernel's audit trailer
    pid_t pid;                      // audit_token_to_pid(audit)
} ltm_hello;

// Parent: check a name in with launchd (works for a plain process, unlike an XPC listener).
kern_return_t ltm_check_in(const char *name, mach_port_t *rx);
// Child: look the name up and send token + surface ports (IOSurfaceCreateMachPort, moved).
kern_return_t ltm_send_hello(const char *name, const char *token, const mach_port_t *ports, int n);
// Parent: receive one hello (timeout_ms < 0: forever).
kern_return_t ltm_recv_hello(mach_port_t rx, int timeout_ms, ltm_hello *out);
// Spawn with the socketpair end as fd 3 (Process can't pass extra fds).
pid_t ltm_spawn(const char *path, char *const argv[], int fd3);
