/*
 * lockdown-tz <olson zone>
 *
 * Point the device's lockdown TimeZone at the given zone — the same call
 * iTunes used; the guest's lockdownd rewrites /var/db/timezone/localtime and
 * SpringBoard follows live.
 *
 * A separate process ON PURPOSE, not a call inside LightTouchMac:
 * lockdownd_set_value invoked in-process against iOS 3.1.3's lockdownd
 * corrupts the heap — the app died ~20 s later in unrelated Swift runtime
 * code, reproducibly, three runs out of three — while this identical
 * sequence in a child process runs clean every time. Whatever the library
 * does there, its blast radius now ends at this process's exit.
 *
 * Reads before writing, so a matching zone costs no set. Prints the zone in
 * effect; exits 0 only when it matches the request. Finds the device via
 * USBMUXD_SOCKET_ADDRESS, like every other bundled tool.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>

static char *current_zone(lockdownd_client_t cli)
{
    plist_t v = NULL;
    char *s = NULL;
    if (lockdownd_get_value(cli, NULL, "TimeZone", &v) == LOCKDOWN_E_SUCCESS && v) {
        plist_get_string_val(v, &s);
        plist_free(v);
    }
    return s;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: lockdown-tz <olson zone>\n");
        return 2;
    }
    idevice_t dev = NULL;
    lockdownd_client_t cli = NULL;
    if (idevice_new(&dev, NULL) != IDEVICE_E_SUCCESS) {
        fprintf(stderr, "no device\n");
        return 1;
    }
    if (lockdownd_client_new_with_handshake(dev, &cli, "LightTouchMac") != LOCKDOWN_E_SUCCESS) {
        fprintf(stderr, "no lockdown\n");
        idevice_free(dev);
        return 1;
    }

    char *zone = current_zone(cli);
    if (!zone || strcmp(zone, argv[1]) != 0) {
        /* set_value takes ownership of the plist and frees it; freeing it
         * here too is the double-free that first exposed all of this. */
        lockdownd_error_t e = lockdownd_set_value(cli, NULL, "TimeZone",
                                                  plist_new_string(argv[1]));
        if (e != LOCKDOWN_E_SUCCESS) {
            fprintf(stderr, "SetValue failed: %d\n", e);
            free(zone);
            lockdownd_client_free(cli);
            idevice_free(dev);
            return 1;
        }
        free(zone);
        zone = current_zone(cli);
    }

    printf("%s\n", zone ? zone : "(unset)");
    int ok = zone && strcmp(zone, argv[1]) == 0;
    free(zone);
    lockdownd_client_free(cli);
    idevice_free(dev);
    return ok ? 0 : 1;
}
