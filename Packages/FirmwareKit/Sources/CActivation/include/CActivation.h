#ifndef LT_CACTIVATION_H
#define LT_CACTIVATION_H
#include <stdint.h>
#include <stddef.h>
// Returns 1 after patching, or 0 with a static error string and the buffer unchanged.
int lt_activate(uint8_t *bytes, size_t size, const char **error);
#endif
