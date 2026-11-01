/*
 * FlashDB firmware measurement harness -- minimal libc replacements (C side).
 *
 * The firmware is linked with -nostdlib, so the few libc functions used by
 * FlashDB/FAL and by the harness are provided here.  They are intentionally
 * simple and small: they exist so the measurement does not include a full
 * libc.  The Zig firmware provides the same baseline (its compiler_rt +
 * freestanding libc surface).
 *
 * The __aeabi_* entries are the ARM EABI runtime ABI: clang lowers calls to
 * memcpy/memset/memmove into the corresponding __aeabi_mem* entry point, so
 * without them the link would need libgcc/compiler_rt.  Providing them here
 * keeps the image self-contained and tiny.
 */
#include <stddef.h>
#include <stdint.h>

void *memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;

    while (n--) {
        *d++ = *s++;
    }
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;

    if (d < s) {
        while (n--) {
            *d++ = *s++;
        }
    } else if (d > s) {
        d += n;
        s += n;
        while (n--) {
            *--d = *--s;
        }
    }
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    uint8_t *d = (uint8_t *)dst;

    while (n--) {
        *d++ = (uint8_t)c;
    }
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;

    while (n--) {
        if (*pa != *pb) {
            return (int)*pa - (int)*pb;
        }
        pa++;
        pb++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;

    while (*p) {
        p++;
    }
    return (size_t)(p - s);
}

int strcmp(const char *a, const char *b)
{
    while (*a && (*a == *b)) {
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && (*a == *b)) {
        a++;
        b++;
        n--;
    }
    if (n == 0) {
        return 0;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

char *strncpy(char *dst, const char *src, size_t n)
{
    char *d = dst;

    while (n && *src) {
        *d++ = *src++;
        n--;
    }
    while (n--) {
        *d++ = '\0';
    }
    return dst;
}

/* ------------------------------------------------------------------------ */
/* ARM EABI runtime entry points (see file comment)                          */
/* ------------------------------------------------------------------------ */

void *__aeabi_memcpy(void *dst, const void *src, size_t n)
{
    return memcpy(dst, src, n);
}

void *__aeabi_memcpy4(void *dst, const void *src, size_t n)
{
    return memcpy(dst, src, n);
}

void *__aeabi_memcpy8(void *dst, const void *src, size_t n)
{
    return memcpy(dst, src, n);
}

void *__aeabi_memmove(void *dst, const void *src, size_t n)
{
    return memmove(dst, src, n);
}

void *__aeabi_memmove4(void *dst, const void *src, size_t n)
{
    return memmove(dst, src, n);
}

void *__aeabi_memmove8(void *dst, const void *src, size_t n)
{
    return memmove(dst, src, n);
}

/* EABI order: (dest, n, c) -- deliberately different from memset(dest,c,n). */
void __aeabi_memset(void *dst, size_t n, int c)
{
    (void)memset(dst, c, n);
}

void __aeabi_memset4(void *dst, size_t n, int c)
{
    (void)memset(dst, c, n);
}

void __aeabi_memset8(void *dst, size_t n, int c)
{
    (void)memset(dst, c, n);
}

void __aeabi_memclr(void *dst, size_t n)
{
    (void)memset(dst, 0, n);
}

void __aeabi_memclr4(void *dst, size_t n)
{
    (void)memset(dst, 0, n);
}

void __aeabi_memclr8(void *dst, size_t n)
{
    (void)memset(dst, 0, n);
}
