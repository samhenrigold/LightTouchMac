/* Synthetic fixtures only: no Apple firmware is included in these tests. */
#define main activation_main
#include "activation.c"
#undef main
#include <assert.h>
#include <sys/wait.h>
static void put32(uint8_t *p, uint32_t x) {
    for (int i = 0; i < 4; i++)
        p[i] = (uint8_t)(x >> (8 * i));
}
static void put16(uint8_t *p, uint16_t x) {
    p[0] = (uint8_t)x;
    p[1] = (uint8_t)(x >> 8);
}
static void block(uint8_t *d, unsigned at, int isa) {
    unsigned pool = at + 0x90;
    if (isa == 0) {
        put32(d + at, 0xe3570000); /* deliberately not r4 */
        put32(d + at + 4, 0x0a000010);
        put32(d + at + 8, 0xe59f0000 | (pool - at - 16));
        put32(d + at + 12, 0xe59f1000 | (pool - at - 16));
        put32(d + at + 16, 0xeb00000a);
        put32(d + pool, 0x1560);
        put32(d + pool + 4, 0x1500);
    } else {
        put16(d + at, 0x2b00);
        put16(d + at + 2, 0xd020); /* cmp r3 */
        put16(d + at + 4, (uint16_t)(0x4800 | ((pool - at - 8) / 4)));
        put16(d + at + 6, (uint16_t)(0x4900 | ((pool + 4 - at - 8) / 4)));
        unsigned call = at + 8;
        if (isa == 2) {
            put16(d + at + 8, 0x4478);
            put16(d + at + 10, 0x4479);
            call += 4;
            put32(d + pool, 0x1560 - (0x1000 + at + 12));
            put32(d + pool + 4, 0x1580 - (0x1000 + at + 14));
        } else {
            put32(d + pool, 0x1560);
            put32(d + pool + 4, 0x1500);
        }
        put16(d + call, 0xf000);
        put16(d + call + 2, 0xf81a);
    }
}
static void fixture(uint8_t *d, int isa) {
    memset(d, 0, 2048);
    put32(d, 0xfeedface);
    put32(d + 4, 12);
    put32(d + 8, 6);
    put32(d + 12, 2);
    put32(d + 16, 1);
    put32(d + 20, 124);
    put32(d + 28, 1);
    put32(d + 32, 124);
    memcpy(d + 36, "__TEXT", 6);
    put32(d + 52, 0x1000);
    put32(d + 56, 2048);
    put32(d + 60, 0);
    put32(d + 64, 2048);
    put32(d + 76, 1);
    memcpy(d + 84, "__text", 6);
    memcpy(d + 100, "__TEXT", 6);
    put32(d + 116, 0x1100);
    put32(d + 120, 0x300);
    put32(d + 124, 0x100);
    memcpy(d + 0x500, message, sizeof(message));
    memcpy(d + 0x560, function, sizeof(function));
    put32(d + 0x584, 0x7c8);
    put32(d + 0x588, 0x1500);
    put32(d + 0x58c, sizeof(message) - 1);
    block(d, 0x100, isa);
}
static void save(const char *p, const uint8_t *d, size_t n) {
    FILE *f = fopen(p, "wb");
    assert(f);
    assert(fwrite(d, 1, n, f) == n);
    assert(!fclose(f));
    assert(!chmod(p, 0751));
}
static int runx(const char *p, bool probe, bool experimental) {
    pid_t pid = fork();
    assert(pid >= 0);
    if (!pid) {
        int f = open("/dev/null", O_WRONLY);
        dup2(f, 1);
        dup2(f, 2);
        close(f);
        char *a[] = {"lt-activation", NULL, NULL, NULL, NULL};
        int n = 1;
        if (probe)
            a[n++] = "--probe";
        if (experimental)
            a[n++] = "--experimental-legacy";
        a[n++] = (char *)p;
        exit(activation_main(n, a));
    }
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status));
    return WEXITSTATUS(status);
}
static int run(const char *p, bool probe) { return runx(p, probe, false); }
static void same(const char *p, const uint8_t *d, size_t n) {
    uint8_t got[2048];
    FILE *f = fopen(p, "rb");
    assert(f);
    assert(fread(got, 1, sizeof(got), f) == n);
    fclose(f);
    assert(!memcmp(d, got, n));
}
static void movwide(uint8_t *d, unsigned reg, uint16_t imm, bool top) {
    put16(d, (uint16_t)((top ? 0xf2c0 : 0xf240) | ((imm >> 12) & 15) | (((imm >> 11) & 1) << 10)));
    put16(d + 2, (uint16_t)((((imm >> 8) & 7) << 12) | (reg << 8) | (imm & 255)));
}
static void laterlog(uint8_t *d, unsigned at) {
    movwide(d + at, 1, 0x1560, false);
    put16(d + at + 4, 0x2000);
    movwide(d + at + 6, 1, 0, true);
    movwide(d + at + 10, 2, 0x1580, false);
    movwide(d + at + 14, 2, 0, true);
    put16(d + at + 18, 0xf000);
    put16(d + at + 20, 0xf81a);
}
static void cf(uint8_t *d, unsigned at, unsigned str, const char *value) {
    put32(d + at + 4, 0x7c8);
    put32(d + at + 8, 0x1000 + str);
    put32(d + at + 12, (uint32_t)strlen(value));
    strcpy((char *)d + str, value);
}
static void oldfixture(uint8_t *d, bool second) {
    fixture(d, 0);
    memset(d + 0x100, 0, 0x300);
    memset(d + 0x500, 0, sizeof(message));
    cf(d, 0x600, 0x620, "Unactivated");
    cf(d, 0x680, 0x6a0, "Activated");
    cf(d, 0x6e0, 0x720, "FactoryActivated");
    strcpy((char *)d + 0x6c0, "determine_activation_state");
    put32(d + 0x100, 0xe59f0098);
    put32(d + 0x1a0, 0x16c0);
    put32(d + 0x290, 0x1600);
    put32(d + 0x294, 0x1680);
    if (!second) {
        put32(d + 0x1f8, 0xe3540000);
        put32(d + 0x1fc, 0x1a000005);
        put32(d + 0x200, 0xe59f2088);
        put32(d + 0x204, 0xe58d4010);
        put32(d + 0x208, 0xe58d4014);
        put32(d + 0x20c, 0xe2844001);
        put32(d + 0x210, 0xe58d2004);
        put32(d + 0x214, 0xea00004d);
    } else {
        strcpy((char *)d + 0x740, "There is no activation record?");
        put32(d + 0x298, 0x1740);
        put32(d + 0x1dc, 0xe3560000); // NULL record
        put32(d + 0x1e0, 0x1a000040);
        put32(d + 0x1e4, 0xe51f004c); // function name at 0x1a0
        put32(d + 0x1e8, 0xe59f10a8); // no-record diagnostic
        put32(d + 0x1ec, 0xeb000040);
        put32(d + 0x1f0, 0xe1a00008);
        put32(d + 0x1f4, 0xeb000040);
        put32(d + 0x1f8, 0xe3500000);
        put32(d + 0x1fc, 0x1a000020);
        put32(d + 0x200, 0xe59f2088);
        put32(d + 0x204, 0xe58d6010);
        put32(d + 0x208, 0xe58d6014);
        put32(d + 0x20c, 0xe2866001);
        put32(d + 0x210, 0xea00003a); // shared store at 0x300
        put32(d + 0x300, 0xe58d2004);

    }
}
int main(void) {
    char dir[] = "/tmp/lt-activation-test.XXXXXX";
    assert(mkdtemp(dir));
    char p[256], link[256];
    snprintf(p, sizeof(p), "%s/binary", dir);
    snprintf(link, sizeof(link), "%s/link", dir);
    uint8_t d[2048];
    for (int isa = 0; isa < 3; isa++) {
        fixture(d, isa);
        save(p, d, sizeof(d));
        assert(!run(p, true));
        same(p, d, sizeof(d));
        assert(!run(p, false));
        if (isa == 0)
            put32(d + 0x104, 0xe1a00000);
        else
            put16(d + 0x102, 0xbf00);
        same(p, d, sizeof(d));
        struct stat st;
        assert(!stat(p, &st));
        assert((st.st_mode & 0777) == 0751);
        assert(run(p, false));
        same(p, d, sizeof(d));
    }
    /* Wide backwards skip (5.x) and wide conditional take (6.x). */
    for (int kind = 0; kind < 2; kind++) {
        fixture(d, 0);
        memset(d + 0x100, 0, 0x300);
        unsigned at = kind ? 0x100 : 0x180;
        put16(d + at, (uint16_t)(kind ? 0x2801 : 0x2f00));
        put16(d + at + 2, (uint16_t)(kind ? 0xf000 : 0xf43f));
        put16(d + at + 4, (uint16_t)(kind ? 0x807d : 0xafbd));
        laterlog(d, kind ? 0x200 : 0x186);
        save(p, d, sizeof(d));
        assert(!run(p, true));
        same(p, d, sizeof(d));
        assert(!run(p, false));
        if (kind) {
            put16(d + at + 2, 0xf000);
            put16(d + at + 4, 0xb87d);
        } else {
            put16(d + at + 2, 0xbf00);
            put16(d + at + 4, 0xbf00);
        }
        same(p, d, sizeof(d));
        assert(run(p, false));
        same(p, d, sizeof(d));
    }
    for (int kind = 0; kind < 2; kind++) {
        oldfixture(d, kind);
        save(p, d, sizeof(d));
        assert(!run(p, true));
        same(p, d, sizeof(d));
        assert(!run(p, false));
        put32(d + 0x200, 0xe59f208c);
        put32(d + 0x20c, kind ? 0xe3a06000 : 0xe3a04000);
        same(p, d, sizeof(d));
        assert(runx(p, false, true));
        same(p, d, sizeof(d));
    }
    // Early 1.x stores the state and brick boolean directly in distinct slots.
    for (int bad = 0; bad < 4; bad++) {
        oldfixture(d, false);
        put32(d + 0x1f4, 0xe3540000);
        put32(d + 0x1f8, 0xe1a08000);
        put32(d + 0x1fc, 0x1a000004);
        put32(d + 0x204, 0xe3a01001);
        put32(d + 0x208, 0xe58d100c);
        put32(d + 0x20c, 0xe58d2004);
        put32(d + 0x210, 0xea00004e);
        if (bad == 1) put32(d + 0x1fc, 0x1a000003);
        if (bad == 2) put32(d + 0x20c, 0xe58d200c);
        if (bad == 3) put32(d + 0x204, 0xe3a02001);
        save(p, d, sizeof(d));
        if (bad) { assert(run(p, false)); same(p, d, sizeof(d)); }
        else {
            assert(!run(p, true)); same(p, d, sizeof(d));
            assert(!run(p, false));
            put32(d + 0x200, 0xe59f208c);
            put32(d + 0x204, 0xe3a01000);
            same(p, d, sizeof(d));
            assert(run(p, false)); same(p, d, sizeof(d));
        }
    }
    // The shared-store strategy must prove the no-record guard, diagnostic, and store.
    for (int kind = 0; kind < 3; kind++) {
        oldfixture(d, true);
        if (kind == 0) put32(d + 0x1dc, 0xe3550000);
        if (kind == 1) d[0x740] = 'X';
        if (kind == 2) put32(d + 0x300, 0xe58d3004);
        save(p, d, sizeof(d));
        assert(run(p, false));
        same(p, d, sizeof(d));
    }
    fixture(d, 0);
    block(d, 0x200, 0);
    save(p, d, sizeof(d));
    assert(run(p, false));
    same(p, d, sizeof(d));
    fixture(d, 2);
    d[0x560] = 'X';
    save(p, d, sizeof(d));
    assert(run(p, false));
    same(p, d, sizeof(d));
    fixture(d, 2);
    put32(d + 0x58c, 1);
    save(p, d, sizeof(d));
    assert(run(p, false));
    same(p, d, sizeof(d));
    fixture(d, 0);
    put32(d + 0x104, 0x0affffff);
    save(p, d, sizeof(d));
    assert(run(p, false));
    same(p, d, sizeof(d));
    fixture(d, 0);
    put32(d + 32, 0xffffffff);
    save(p, d, sizeof(d));
    assert(run(p, false));
    same(p, d, sizeof(d));
    fixture(d, 0);
    put32(d + 120, 0xffffffff);
    save(p, d, sizeof(d));
    assert(run(p, false));
    same(p, d, sizeof(d));
    fixture(d, 0);
    save(p, d, 40);
    assert(run(p, false));
    same(p, d, 40);
    fixture(d, 0);
    save(p, d, sizeof(d));
    assert(!symlink(p, link));
    assert(run(link, false));
    same(p, d, sizeof(d));
    unlink(link);
    /* Exercise malformed/truncated headers under sanitizers, without changing source files. */
    for (unsigned i = 0; i < 128; i++) {
        fixture(d, i % 3);
        unsigned at = (i * 37) % 152;
        d[at] ^= (uint8_t)(1 + (i % 255));
        save(p, d, sizeof(d));
        (void)run(p, true);
        same(p, d, sizeof(d));
    }
    unlink(p);
    rmdir(dir);
    puts("PASS: ARM, Thumb, PIC/CFString, probe/apply, register variation, repeat/ambiguity "
         "refusal, malformed inputs, symlink refusal, and mode preservation");
    return 0;
}
