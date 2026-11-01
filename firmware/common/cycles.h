/*
 * FlashDB firmware measurement harness -- cycle counter.
 *
 * The acceptance metric is "CPU cycles of the identical workload".  On real
 * Cortex-M3 silicon that is the DWT cycle counter (DEMCR.TRCENA + DWT.CYCCNT).
 * QEMU's mps2-an385 machine does NOT model the DWT (probe: DEMCR/DWT_CTRL
 * read 0 and CYCCNT never advances), so this module probes the DWT once and,
 * when it is absent, falls back to the SysTick 24-bit down-counter running
 * free from the processor clock.  Under `qemu-system-arm -icount shift=0` one
 * emulated instruction consumes exactly one virtual nanosecond, so a SysTick
 * tick is a fixed, deterministic number of instructions (MPS2-AN385
 * SysTick = 25 MHz -> 1 tick = 40 ns = 40 instructions).  The calibration
 * spin below measures that ratio in the firmware itself and prints it, so the
 * reported numbers are self-describing.  Both the C and the Zig firmware use
 * this same module, so their cycle numbers are directly comparable.
 *
 * Reading the counter costs one load (possibly plus the SysTick mask).  The
 * calibration spin is executed once, before the first measured phase.
 */
#ifndef HARNESS_CYCLES_H
#define HARNESS_CYCLES_H

#include <stdint.h>

/* Reported as `cycles_src=` in the RESULT line. */
#define CYCLES_SRC_NONE    0u  /* neither source advances: no cycle numbers */
#define CYCLES_SRC_DWT     1u  /* real DWT CYCCNT (CPU cycles, silicon)     */
#define CYCLES_SRC_SYSTICK 2u  /* SysTick virtual-time proxy (QEMU -icount) */

/* Probe for a working cycle counter and start it.  Returns CYCLES_SRC_*. */
uint32_t cycles_init(void);

/* The source selected by cycles_init(). */
uint32_t cycles_source(void);

/* Human-readable source name: "dwt", "systick" or "none". */
const char *cycles_source_name(void);

/* Current counter value (free-running, unsigned).  Do not compare values of
 * different sources; use cycles_delta(). */
uint32_t cycles_now(void);

/* Counter units elapsed between two cycles_now() samples.  Handles the 24-bit
 * SysTick down-counter (one wrap) and the 32-bit DWT up-counter (one wrap). */
uint32_t cycles_delta(uint32_t earlier, uint32_t later);

/* SysTick proxy clock in Hz (25 MHz on MPS2-AN385), 0 for the DWT source. */
uint32_t cycles_tick_hz(void);

/* Calibration of the SysTick proxy, measured by cycles_init():
 * `cycles_spin_insn` instructions took `cycles_spin_ticks` ticks.  Both are 0
 * when the DWT source is active (no calibration needed).  Instructions can be
 * estimated as ticks * cycles_spin_insn / cycles_spin_ticks. */
uint32_t cycles_spin_insn(void);
uint32_t cycles_spin_ticks(void);

#endif /* HARNESS_CYCLES_H */
