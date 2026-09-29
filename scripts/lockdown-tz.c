/*
 * lockdown-tz <olson zone> [epoch | keep]
 * lockdown-tz --finish-activation
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
#include <unistd.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>

/* Match the type the device reports (uint on old lockdownd, real on newer),
 * like idevicedate. */
static double get_time(lockdownd_client_t cli, int *is_real)
{
    plist_t v = NULL;
    double t = -1;
    if (lockdownd_get_value(cli, NULL, "TimeIntervalSince1970", &v) == LOCKDOWN_E_SUCCESS && v) {
        if (plist_get_node_type(v) == PLIST_REAL) {
            *is_real = 1;
            plist_get_real_val(v, &t);
        } else {
            uint64_t u = 0;
            plist_get_uint_val(v, &u);
            t = (double)u;
        }
        plist_free(v);
    }
    return t;
}

/* Returns the time the device holds afterwards (-1 if unreadable). */
static double set_time(lockdownd_client_t cli, time_t now)
{
    int is_real = 0;
    get_time(cli, &is_real);
    plist_t node = is_real ? plist_new_real((double)now) : plist_new_uint((uint64_t)now);
    lockdownd_error_t e = lockdownd_set_value(cli, NULL, "TimeIntervalSince1970", node);
    if (e != LOCKDOWN_E_SUCCESS)
        fprintf(stderr, "set time failed: %d\n", e);
    /* lockdownd applies the time asynchronously (iOS 4: the read right after
     * the set still shows the old clock while the lock screen already moved);
     * give it a few seconds before judging. */
    double held = -1;
    for (int i = 0; i < 4; i++) {
        sleep(1);
        held = get_time(cli, &is_real);
        if (held >= 0 && held - (double)now < 300 && (double)now - held < 300)
            break;
    }
    return held;
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

/* Finish local preparation through the guest's own protocol. This never sends
 * identities or activation requests to an external service. Kept in the child
 * process for the same SetValue isolation as clock synchronization. */
static char *string_value(lockdownd_client_t cli, const char *key)
{
    plist_t value = NULL;
    char *s = NULL;
    if (lockdownd_get_value(cli, NULL, key, &value) == LOCKDOWN_E_SUCCESS && value) {
        if (plist_get_node_type(value) == PLIST_STRING) plist_get_string_val(value, &s);
        plist_free(value);
    }
    return s;
}

static int bool_value(lockdownd_client_t cli, const char *key)
{
    plist_t value = NULL;
    int result = -1;
    if (lockdownd_get_value(cli, NULL, key, &value) == LOCKDOWN_E_SUCCESS && value) {
        if (plist_get_node_type(value) == PLIST_BOOLEAN) {
            uint8_t b = 0;
            plist_get_bool_val(value, &b);
            result = b != 0;
        }
        plist_free(value);
    }
    return result;
}

static int activated(const char *state)
{
    return state && (!strcmp(state, "Activated") || !strcmp(state, "FactoryActivated") ||
                     !strcmp(state, "WildcardActivated"));
}

static int ensure_true(lockdownd_client_t cli, const char *key)
{
    if (bool_value(cli, key) == 1) return 1;
    if (lockdownd_set_value(cli, NULL, key, plist_new_bool(1)) != LOCKDOWN_E_SUCCESS) return 0;
    return bool_value(cli, key) == 1;
}

static int finish_activation(lockdownd_client_t cli)
{
    char *state = string_value(cli, "ActivationState");
    if (!activated(state)) {
        fprintf(stderr, "activation state: %s\n", state ? state : "unavailable");
        free(state);
        return 4;
    }
    free(state);
    char *product = string_value(cli, "ProductType");
    char *version = string_value(cli, "ProductVersion");
    unsigned major = 0;
    int legacy_ipod = product && !strncmp(product, "iPod", 4) && version &&
        sscanf(version, "%u.", &major) == 1 && major >= 1 && major <= 3;
    free(product);
    free(version);
    if (legacy_ipod && (!ensure_true(cli, "iTunesHasConnected") || bool_value(cli, "BrickState") == 1)) {
        fprintf(stderr, "first iTunes connection has not completed\n");
        return 5;
    }
    // Old releases need the first-connection state but may not expose this
    // newer acknowledgement key. Do not invent a persistent cache entry.
    if (!legacy_ipod && !ensure_true(cli, "ActivationStateAcknowledged")) {
        fprintf(stderr, "activation acknowledgement has not completed\n");
        return 6;
    }
    state = string_value(cli, "ActivationState");
    int ok = activated(state);
    printf("%s\n", state ? state : "unavailable");
    free(state);
    return ok ? 0 : 4;
}

int main(int argc, char **argv)
{
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: lockdown-tz <olson zone> [epoch | keep]\n");
        return 2;
    }
    int finishing = argc == 2 && !strcmp(argv[1], "--finish-activation");
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

    if (finishing) {
        int result = finish_activation(cli);
        lockdownd_client_free(cli);
        idevice_free(dev);
        return result;
    }

    if (!keep) {
        double held = set_time(cli, now);
        /* A pinned clock is the point of the call: say so when the device did not take it. */
        if (argc == 3 && (held < 0 || held - (double)now > 300 || (double)now - held > 300)) {
            fprintf(stderr, "clock not applied: device holds %.0f, wanted %lld\n", held, (long long)now);
            lockdownd_client_free(cli);
            idevice_free(dev);
            return 3;
        }
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
