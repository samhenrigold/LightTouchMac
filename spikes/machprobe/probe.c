// Which Mach rendezvous works for an app spawning a helper (no launchd plist)?
//   probe            parent: tries bootstrap_check_in, bootstrap_register, mach_ports_register,
//                    posix_spawn special port; spawns "probe child" and waits for its messages.
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
extern char **environ;
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

typedef struct { mach_msg_header_t h; int tag; mach_msg_trailer_t t; } msg_t;

static void say(mach_port_t port, int tag, const char *how) {
    msg_t m = {0};
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    m.h.msgh_size = sizeof(m) - sizeof(m.t);
    m.h.msgh_remote_port = port;
    m.tag = tag;
    kern_return_t kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, m.h.msgh_size, 0, 0, 1000, 0);
    printf("  child: send via %s -> %s\n", how, kr ? mach_error_string(kr) : "ok");
}

int main(int argc, char **argv) {
    char name[128];
    if (argc > 2 && !strcmp(argv[1], "child")) {
        snprintf(name, sizeof name, "%s", argv[2]);
        mach_port_t p = 0;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &p);
        printf("  child: bootstrap_look_up(%s) -> %s\n", name, kr ? bootstrap_strerror(kr) : "ok");
        if (!kr) say(p, 1, "bootstrap_look_up");
        mach_port_array_t ports; mach_msg_type_number_t n = 0;
        kr = mach_ports_lookup(mach_task_self(), &ports, &n);
        printf("  child: mach_ports_lookup -> %s, %u slots, slot0=%u\n", kr ? mach_error_string(kr) : "ok", n, n ? ports[0] : 0);
        if (!kr && n && MACH_PORT_VALID(ports[0])) say(ports[0], 2, "mach_ports_register slot");
        return 0;
    }
    snprintf(name, sizeof name, "gold.samhenri.LightTouchMac.devices.%d", getpid());
    {   // What NSXPCListener(machServiceName:) does underneath.
        char xname[160]; snprintf(xname, sizeof xname, "%s.xpc", name);
        xpc_connection_t l = xpc_connection_create_mach_service(xname, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block int invalid = 0;
        xpc_connection_set_event_handler(l, ^(xpc_object_t e) { if (e == XPC_ERROR_CONNECTION_INVALID) invalid = 1; dispatch_semaphore_signal(sem); });
        xpc_connection_resume(l);
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC));
        printf("parent: xpc mach-service listener(%s) -> %s\n", xname, invalid ? "INVALID (check-in refused)" : "no error within 300 ms");
    }
    mach_port_t rx = 0;
    kern_return_t kr = bootstrap_check_in(bootstrap_port, name, &rx);
    printf("parent: bootstrap_check_in(%s) -> %d %s\n", name, kr, kr ? bootstrap_strerror(kr) : "ok");
    if (kr) {
        mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &rx);
        mach_port_insert_right(mach_task_self(), rx, rx, MACH_MSG_TYPE_MAKE_SEND);
        kr = bootstrap_register(bootstrap_port, name, rx);
        printf("parent: bootstrap_register -> %d %s\n", kr, kr ? bootstrap_strerror(kr) : "ok");
    }
    mach_port_t slots[1] = { rx };
    kr = mach_ports_register(mach_task_self(), slots, 1);
    printf("parent: mach_ports_register -> %s\n", kr ? mach_error_string(kr) : "ok");
    pid_t pid;
    char *cargv[] = { argv[0], "child", name, NULL };
    int rc = posix_spawn(&pid, argv[0], NULL, NULL, cargv, environ);
    printf("parent: spawned child %d (rc %d)\n", pid, rc);
    for (int i = 0; i < 2; i++) {
        msg_t m = {0};
        kr = mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, rx, 2000, 0);
        if (kr) { printf("parent: receive -> %s\n", mach_error_string(kr)); break; }
        printf("parent: received tag %d (%s)\n", m.tag, m.tag == 1 ? "bootstrap name" : "registered port slot");
    }
    waitpid(pid, NULL, 0);
    return 0;
}
