/*
 * FlashDB firmware measurement harness -- minimal <stdio.h> shim.
 *
 * The Homebrew arm-none-eabi-gcc toolchain ships only GCC's freestanding
 * headers (stdint.h/stddef.h/stdbool.h) and no newlib, so the few C standard
 * headers that FlashDB's public headers include unconditionally must be
 * provided here.  There is no stdio in the measurement firmware: FlashDB and
 * FAL logging are compiled out (FDB_PRINT/FAL_PRINTF -> no-op) and the
 * harness prints through ARM semihosting (common/semihost.c).
 *
 * Keep this file tiny: it is a header-compatibility shim, not a libc.
 */
#ifndef HARNESS_LIBC_SHIM_STDIO_H
#define HARNESS_LIBC_SHIM_STDIO_H

#include <stddef.h>

/* FlashDB references FILE only in file mode, which is not enabled. */
typedef struct harness_dummy_FILE FILE;

#endif /* HARNESS_LIBC_SHIM_STDIO_H */
