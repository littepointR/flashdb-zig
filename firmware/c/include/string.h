/*
 * FlashDB firmware measurement harness -- minimal <string.h> shim.
 *
 * Declarations only: the implementations live in harness/firmware/c/libc_stubs.c.
 */
#ifndef HARNESS_LIBC_SHIM_STRING_H
#define HARNESS_LIBC_SHIM_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
char *strncpy(char *dst, const char *src, size_t n);

#endif /* HARNESS_LIBC_SHIM_STRING_H */
