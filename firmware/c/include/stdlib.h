/*
 * FlashDB firmware measurement harness -- minimal <stdlib.h> shim.
 *
 * The static FAL partition table configuration does not allocate; these
 * declarations only keep the upstream includes compiling.  If the FAL dynamic
 * table mode is ever enabled, real implementations would be required.
 */
#ifndef HARNESS_LIBC_SHIM_STDLIB_H
#define HARNESS_LIBC_SHIM_STDLIB_H

#include <stddef.h>

void *malloc(size_t size);
void *calloc(size_t n, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);

#endif /* HARNESS_LIBC_SHIM_STDLIB_H */
