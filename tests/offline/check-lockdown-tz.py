#!/usr/bin/env python3
"""scripts/lockdown-tz.c's zone step (set_zone, refresh_clocks) against a fake lockdownd (smoke #58).

The fake applies a TimeZone write the way the guest does: lockdownd hands it to locationd/timed, and the
zone reads back a few reads later. Checked: a changed zone is written once, polled until it reads back,
and only then Uses24HourClock is written back with the value it held (true or false, never flipped),
which is what makes SpringBoard rebuild the lock screen's clock; a zone that already matches writes
nothing; a lockdownd without Uses24HourClock gets only the zone; a zone that never applies, or a refused
write, gets no refresh.
"""
from pathlib import Path
import os, subprocess, sys, tempfile
root = Path(__file__).resolve().parents[2]

harness = r'''
#define lockdownd_get_value fake_get
#define lockdownd_set_value fake_set
#define usleep fake_usleep
#define main helper_main
#include "SRC"
#undef main
#include <assert.h>

static plist_t values;
static char pending[64], log_[256];
static int lag, reads_after_set, refused;
int fake_usleep(useconds_t us) { (void)us; return 0; }
lockdownd_error_t fake_get(lockdownd_client_t c, const char *d, const char *key, plist_t *out)
{
    (void)c; (void)d;
    if (!strcmp(key, "TimeZone") && pending[0] && ++reads_after_set > lag) {   /* locationd relinked localtime */
        plist_dict_set_item(values, "TimeZone", plist_new_string(pending));
        pending[0] = 0;
    }
    plist_t v = plist_dict_get_item(values, key);
    *out = v ? plist_copy(v) : NULL;
    return v ? LOCKDOWN_E_SUCCESS : LOCKDOWN_E_UNKNOWN_ERROR;
}
lockdownd_error_t fake_set(lockdownd_client_t c, const char *d, const char *key, plist_t value)
{
    (void)c; (void)d;
    strcat(log_, key); strcat(log_, pending[0] ? "(before the zone read back) " : " ");
    if (refused) { plist_free(value); return LOCKDOWN_E_UNKNOWN_ERROR; }
    if (!strcmp(key, "TimeZone")) {
        char *s = NULL; plist_get_string_val(value, &s);
        snprintf(pending, sizeof(pending), "%s", s); free(s); plist_free(value);
        reads_after_set = 0;
        return LOCKDOWN_E_SUCCESS;
    }
    plist_dict_set_item(values, key, value);
    return LOCKDOWN_E_SUCCESS;
}
static void fixture(const char *zone, int h24, int lag_)
{
    if (values) plist_free(values);
    values = plist_new_dict();
    plist_dict_set_item(values, "TimeZone", plist_new_string(zone));
    if (h24 >= 0) plist_dict_set_item(values, "Uses24HourClock", plist_new_bool(h24));
    pending[0] = log_[0] = 0; lag = lag_; refused = 0;
}
static int is(const char *got, const char *want) { int ok = got && !strcmp(got, want); free((void *)got); return ok; }
int main(void)
{
    fixture("US/Pacific", 0, 3);
    assert(is(set_zone(NULL, "America/New_York"), "America/New_York"));
    printf("changed, 12-hour: %s\n", log_);
    assert(!strcmp(log_, "TimeZone Uses24HourClock "));
    assert(bool_value(NULL, "Uses24HourClock") == 0);

    fixture("US/Pacific", 1, 0);
    assert(is(set_zone(NULL, "Asia/Tokyo"), "Asia/Tokyo"));
    assert(!strcmp(log_, "TimeZone Uses24HourClock ") && bool_value(NULL, "Uses24HourClock") == 1);

    fixture("America/New_York", 0, 0);
    assert(is(set_zone(NULL, "America/New_York"), "America/New_York") && !log_[0]);

    fixture("US/Pacific", -1, 1);
    assert(is(set_zone(NULL, "Europe/Paris"), "Europe/Paris") && !strcmp(log_, "TimeZone "));

    fixture("US/Pacific", 0, 1000);
    assert(is(set_zone(NULL, "Europe/Paris"), "US/Pacific") && !strcmp(log_, "TimeZone "));

    fixture("US/Pacific", 0, 0); refused = 1;
    assert(set_zone(NULL, "Europe/Paris") == NULL && !strcmp(log_, "TimeZone "));
    plist_free(values);
    puts("PASS: lockdown-tz writes a changed zone, waits for it, then refreshes the lock clock (Uses24HourClock kept)");
}
'''

with tempfile.TemporaryDirectory() as work:
    c = Path(work, "zone.c")
    c.write_text(harness.replace("SRC", str(root / "scripts/lockdown-tz.c")))
    flags = subprocess.run(["/bin/sh", "-c", "PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; "
                            "pkg-config --cflags --libs libimobiledevice-1.0 libplist-2.0"],
                           capture_output=True, text=True).stdout.split()
    exe = Path(work, "zone")
    r = subprocess.run(["cc", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                        str(c), *flags, "-o", str(exe)], capture_output=True, text=True)
    if r.returncode:
        sys.exit("FAIL: building the lockdown-tz harness\n" + r.stderr)
    r = subprocess.run([str(exe)], capture_output=True, text=True,
                       env=dict(os.environ, ASAN_OPTIONS="abort_on_error=1", UBSAN_OPTIONS="halt_on_error=1"))
    sys.stdout.write(r.stdout)
    if r.returncode:
        sys.exit("FAIL: lockdown-tz zone step\n" + r.stderr[-2000:])
