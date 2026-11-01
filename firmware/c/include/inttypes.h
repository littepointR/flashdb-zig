/*
 * FlashDB firmware measurement harness -- minimal <inttypes.h> shim.
 *
 * Only the PRI* format macros used by FlashDB's (compiled-out) log statements
 * are needed; the types come from GCC's freestanding <stdint.h>.
 */
#ifndef HARNESS_LIBC_SHIM_INTTYPES_H
#define HARNESS_LIBC_SHIM_INTTYPES_H

#include <stdint.h>

#define PRId8 "d"
#define PRIi8 "i"
#define PRIu8 "u"
#define PRIx8 "x"
#define PRIX8 "X"

#define PRId16 "d"
#define PRIi16 "i"
#define PRIu16 "u"
#define PRIx16 "x"
#define PRIX16 "X"

#define PRId32 "d"
#define PRIi32 "i"
#define PRIu32 "u"
#define PRIx32 "x"
#define PRIX32 "X"

#define PRId64 "lld"
#define PRIi64 "lli"
#define PRIu64 "llu"
#define PRIx64 "llx"
#define PRIX64 "llX"

#define PRIdLEAST8 "d"
#define PRIiLEAST8 "i"
#define PRIuLEAST8 "u"
#define PRIxLEAST8 "x"
#define PRIXLEAST8 "X"

#define PRIdLEAST16 "d"
#define PRIiLEAST16 "i"
#define PRIuLEAST16 "u"
#define PRIxLEAST16 "x"
#define PRIXLEAST16 "X"

#define PRIdLEAST32 "d"
#define PRIiLEAST32 "i"
#define PRIuLEAST32 "u"
#define PRIxLEAST32 "x"
#define PRIXLEAST32 "X"

#define PRIdMAX "lld"
#define PRIiMAX "lli"
#define PRIuMAX "llu"
#define PRIxMAX "llx"
#define PRIXMAX "llX"

#endif /* HARNESS_LIBC_SHIM_INTTYPES_H */
