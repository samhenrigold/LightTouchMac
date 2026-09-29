/* Synthetic instruction fixtures: no Apple firmware. GPL-3.0-or-later,
 * matching the vendored iBoot32Patcher code exercised by this test. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <include/functions.h>
#include <include/rsa_result.h>

static void half(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void bl(unsigned char *p, unsigned char *target) {
    unsigned v = (unsigned)(target - p - 4) & 0x1ffffff;
    unsigned s = v >> 24, j1 = !(((v >> 23) & 1) ^ s), j2 = !(((v >> 22) & 1) ^ s);
    half(p, 0xf000 | s << 10 | (v >> 12 & 1023));
    half(p + 2, 0xd000 | j1 << 13 | j2 << 11 | (v >> 1 & 2047));
}
int main(void) {
    unsigned char b[2048] = {0};
    struct iboot_img img = {b, sizeof(b), 1219};
    unsigned char *call = b + 64, *data = b + 256, *target = b + 1024;
    half(call - 6, 0xab0d); half(call - 4, 0x4630); half(call - 2, 0x4621);
    assert(rsa_stack_result(&img, call));
    half(call - 6, 0x2300); /* MOVS R3,#0 must not authorize STR [R3]. */
    assert(!rsa_stack_result(&img, call));
    assert(!rsa_stack_result(&img, b));
    assert(!rsa_stack_result(&img, b + sizeof(b) - 2));
    bl(call, target);
    unsigned char frame[] = {0xf0,0xb5,0x03,0xaf,0x2d,0xe9,0x00,0x0d};
    unsigned char flags[] = {0x41,0x68,0x11,0xf0,0x02,0x0f};
    memcpy(target, frame, sizeof(frame)); memcpy(target + 18, flags, sizeof(flags));
    unsigned tail[] = {0x2500,0x950a,0xb1b8,0xf04f,0x35ff,0x2801};
    for (unsigned i = 0; i < sizeof(tail)/sizeof(*tail); i++) half(call + 4 + 2*i, tail[i]);
    unsigned body[] = {0x2500,0xf245,0x4141,0x950d,0xf2c4,0x4141,0x9500,0xf04f,0x35ff,0x980f,0xaa0e,0xab0d,0,0,0x2800,0xf040};
    for (unsigned i = 0; i < sizeof(body)/sizeof(*body); i++) half(data + 2*i, body[i]);
    bl(data + 24, target + 64);
    assert(rsa_legacy_data_block(&img, call) == data);
    unsigned char copy[sizeof(b)]; memcpy(copy, b, sizeof(b));
    /* Lost initialization, wrong tag, aliased result, invalid callee ABI. */
    unsigned corrupt[] = {68,71,73,1024,1042,258,260,277,278};
    for (unsigned i = 0; i < sizeof(corrupt)/sizeof(*corrupt); i++) {
        b[corrupt[i]] ^= 0x80;
        assert(!rsa_legacy_data_block(&img, call));
        memcpy(b, copy, sizeof(b));
    }
    half(data + 20, 0xaa0a); assert(!rsa_legacy_data_block(&img, call));
    memcpy(b, copy, sizeof(b));
    memcpy(data + 128, data, 32); bl(data + 128 + 24, target + 64);
    assert(!rsa_legacy_data_block(&img, call)); /* ambiguous destination */
    memcpy(b, copy, sizeof(b));
    bl(call, b + sizeof(b)); assert(!rsa_legacy_data_block(&img, call));
    memcpy(b, copy, sizeof(b));
    /* Every possible short image length must be safely rejected. */
    for (unsigned n = 0; n < 1048; n++) {
        unsigned char *shortbuf = malloc(n ? n : 1); memcpy(shortbuf, b, n);
        struct iboot_img shortimg = {shortbuf, n, 1219};
        if (n >= 64) assert(!rsa_legacy_data_block(&shortimg, shortbuf + 64));
        free(shortbuf);
    }
    puts("iBoot RSA ABI guards: passed");
}
