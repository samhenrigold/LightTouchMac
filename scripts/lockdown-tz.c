/*
 * lockdown-tz <olson zone> [epoch | keep]
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
 * Also sets TimeIntervalSince1970 to the Mac's clock, as iTunes did on every
 * connect. Besides syncing the clock, this is what clears lockdownd's
 * BrickState on an iPod: on iOS 2.x lockdownd enables it at first boot, and
 * activation clears it only on devices that report themselves as an iPhone.
 * Until a paired host sets the time or iTunesHasConnected, SpringBoard stays
 * on Connect to iTunes. The time is best effort: a failure is logged, but the
 * exit status follows the zone. A second argument replaces the Mac's clock:
 * seconds since 1970 (a catalog entry's pinned `clock`, for developer builds
 * that refuse to run past their expiry) or `keep`, which leaves the time alone
 * (the zone re-sync after a pin must not jump the guest back).
 *
 * Reads before writing, so a matching zone costs no set. Prints the zone in
 * effect; exits 0 only when it matches the request. Finds the device via
 * USBMUXD_SOCKET_ADDRESS, like every other bundled tool.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>

/* Match the type the device reports (uint on old lockdownd, real on newer),
 * like idevicedate. */
static void set_time(lockdownd_client_t cli, time_t now)
{
    plist_t v = NULL;
    plist_t node = plist_new_uint((uint64_t)now);
    if (lockdownd_get_value(cli, NULL, "TimeIntervalSince1970", &v) == LOCKDOWN_E_SUCCESS && v) {
        if (plist_get_node_type(v) == PLIST_REAL) {
            plist_free(node);
            node = plist_new_real((double)now);
        }
        plist_free(v);
    }
    lockdownd_error_t e = lockdownd_set_value(cli, NULL, "TimeIntervalSince1970", node);
    if (e != LOCKDOWN_E_SUCCESS)
        fprintf(stderr, "set time failed: %d\n", e);
}

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
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: lockdown-tz <olson zone> [epoch | keep]\n");
        return 2;
    }
    time_t now = time(NULL);
    int keep = 0;
    if (argc == 3) {
        if (strcmp(argv[2], "keep") == 0)
            keep = 1;
        else if ((now = (time_t)strtoll(argv[2], NULL, 10)) <= 0) {
            fprintf(stderr, "bad epoch: %s\n", argv[2]);
            return 2;
        }
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

    if (!keep)
        set_time(cli, now);

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
