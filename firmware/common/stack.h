/*
 * FlashDB firmware measurement harness -- stack painting / high-water scan.
 */
#ifndef HARNESS_STACK_H
#define HARNESS_STACK_H

#include <stdint.h>

/* Size in bytes of the painted stack region (8 KiB, see the linker script). */
uint32_t stack_limit_bytes(void);

/*
 * Worst-case stack usage in bytes, measured by scanning the 0xA5-painted
 * region for the lowest modified word.  Call AFTER the workload has returned
 * to the top-level frame.
 */
uint32_t stack_high_water_bytes(void);

#ifdef HARNESS_STACK_PHASES
/*
 * Repaint the unused part of the stack below the current SP with 0xA5.
 * Lets the harness measure each workload phase in isolation: call it, run the
 * phase, then call stack_high_water_bytes().  Only memory below SP is touched,
 * so live caller frames are preserved.
 */
void stack_repaint(void);
#endif

#endif /* HARNESS_STACK_H */
