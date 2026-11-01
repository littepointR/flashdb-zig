/*
 * FlashDB firmware measurement harness -- stack painting / high-water scan.
 *
 * The reset handler (common/startup_armv7m.S) fills the whole stack region
 * [_stack_bottom, _estack) with the pattern 0xA5A5A5A5 immediately before
 * calling main().  Stack frames overwrite the pattern as they are used.
 * After the workload has returned to main() this module walks the region from
 * the bottom up and finds the lowest word that no longer holds the pattern;
 * the distance from that word to _estack is the worst-case stack usage of the
 * run.
 *
 * Caveats (also documented in harness/firmware/README.md):
 *   * A frame word whose stored value happens to be exactly 0xA5A5A5A5 is
 *     invisible to the scan (in practice irrelevant, and it can only make the
 *     reported number smaller, never larger).
 *   * The scan sees the stack as it is *after* the workload returned; the
 *     deepest frame is not popped, so the high-water mark is still visible.
 *   * Stack usage inside an interrupt handler that fires after the scan would
 *     not be measured.  The harness runs with interrupts masked/never fired.
 *   * 0xA5-painted region is 8 KiB; any usage beyond that overflows into
 *     whatever lives below _stack_bottom and would corrupt memory instead.
 */
#include "stack.h"

/* Linker symbols: byte arrays so pointer arithmetic is in bytes. */
extern uint8_t _stack_bottom[];
extern uint8_t _estack[];

#define STACK_PAINT_WORD 0xA5A5A5A5u

uint32_t stack_limit_bytes(void)
{
    return (uint32_t)(_estack - _stack_bottom);
}

#ifdef HARNESS_STACK_PHASES
/* No code path pushes more than this between reading SP and the paint loop. */
#define STACK_REPAINT_MARGIN 32u

void stack_repaint(void)
{
    uint32_t sp;
    uint32_t *p;
    uint32_t *end;

    __asm__ volatile("mov %0, sp" : "=r"(sp));
    p = (uint32_t *)_stack_bottom;
    end = (uint32_t *)(sp - STACK_REPAINT_MARGIN);
    while (p < end) {
        *p++ = STACK_PAINT_WORD;
    }
}
#endif /* HARNESS_STACK_PHASES */

uint32_t stack_high_water_bytes(void)
{
    const uint32_t *p = (const uint32_t *)_stack_bottom;
    const uint32_t *top = (const uint32_t *)_estack;
    uint32_t used;

    while (p < top && *p == STACK_PAINT_WORD) {
        p++;
    }

    used = (uint32_t)((const uint8_t *)_estack - (const uint8_t *)p);

    /* Report a conservative, ABI-aligned number: a real frame uses at least
     * these bytes even if the scan sees only the low end of it. */
    return (used + 7u) & ~7u;
}
