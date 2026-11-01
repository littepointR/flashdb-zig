/*
 * FlashDB firmware measurement harness -- cycle counter (see cycles.h).
 */
#include "cycles.h"

/* Cortex-M3 debug / public registers (ARMv7-M ARM, no CMSIS headers). */
#define DEMCR      (*(volatile uint32_t *)0xE000EDFCu)
#define DWT_CTRL   (*(volatile uint32_t *)0xE0001000u)
#define DWT_CYCCNT (*(volatile uint32_t *)0xE0001004u)
/* DWT Lock Access Register.  Not implemented on every ARMv7-M part; a store
 * to an unimplemented address is ignored by the bus/emulator. */
#define DWT_LAR    (*(volatile uint32_t *)0xE0001FB0u)

#define SYST_CTRL  (*(volatile uint32_t *)0xE000E010u)
#define SYST_LOAD  (*(volatile uint32_t *)0xE000E014u)
#define SYST_VAL   (*(volatile uint32_t *)0xE000E018u)

#define SYSTICK_MASK 0x00FFFFFFu
/* ENABLE=1, TICKINT=0 (no exception), CLKSOURCE=1 (processor clock). */
#define SYSTICK_CTRL_FREE_RUNNING 0x5u
/* MPS2-AN385 (QEMU) drives SysTick from a 25 MHz clock; -icount shift=0 makes
 * one virtual nanosecond equal one instruction, so 1 tick = 40 instructions. */
#define SYSTICK_HZ 25000000u

/* Exactly 20000 retired instructions: 10000 iterations of (subs, bne). */
#define SPIN_ITERATIONS   10000u
#define SPIN_INSTRUCTIONS 20000u

static uint32_t g_source = CYCLES_SRC_NONE;
static uint32_t g_spin_ticks;

/* A known-instruction-count busy loop; volatile asm prevents removal. */
static void pseudo_spin(void)
{
    uint32_t n = SPIN_ITERATIONS;

    __asm__ volatile(
        "1:\n"
        "subs %0, %0, #1\n"
        "bne 1b\n"
        : "+r"(n)
        :
        : "cc");
}

static uint32_t systick_now(void)
{
    return SYST_VAL & SYSTICK_MASK;
}

static uint32_t systick_delta(uint32_t earlier, uint32_t later)
{
    /* Down-counter: earlier value is larger.  One wrap only. */
    return (earlier - later) & SYSTICK_MASK;
}

uint32_t cycles_init(void)
{
    uint32_t before;
    uint32_t after;
    uint32_t spin_a;
    uint32_t spin_b;

    /* ---- 1. real DWT cycle counter ---------------------------------- */
    DEMCR |= (1u << 24);          /* TRCENA: enable the trace/DWT block */
    DWT_LAR = 0xC5ACCE55u;        /* unlock DWT (harmless if absent)     */
    DWT_CYCCNT = 0u;
    DWT_CTRL |= 1u;               /* CYCCNTENA: start counting           */

    before = DWT_CYCCNT;
    pseudo_spin();
    after = DWT_CYCCNT;
    if (after != before) {
        g_source = CYCLES_SRC_DWT;
        g_spin_ticks = 0u;
        return g_source;
    }

    /* ---- 2. SysTick virtual-time proxy (QEMU, needs -icount shift=0) - */
    SYST_LOAD = SYSTICK_MASK;
    SYST_VAL = 0u;
    SYST_CTRL = SYSTICK_CTRL_FREE_RUNNING;

    spin_a = systick_now();
    pseudo_spin();
    spin_b = systick_now();
    g_spin_ticks = systick_delta(spin_a, spin_b);

    g_source = (g_spin_ticks != 0u) ? CYCLES_SRC_SYSTICK : CYCLES_SRC_NONE;
    return g_source;
}

uint32_t cycles_source(void)
{
    return g_source;
}

const char *cycles_source_name(void)
{
    if (g_source == CYCLES_SRC_DWT) {
        return "dwt";
    }
    if (g_source == CYCLES_SRC_SYSTICK) {
        return "systick";
    }
    return "none";
}

uint32_t cycles_now(void)
{
    if (g_source == CYCLES_SRC_DWT) {
        return DWT_CYCCNT;
    }
    if (g_source == CYCLES_SRC_SYSTICK) {
        return systick_now();
    }
    return 0u;
}

uint32_t cycles_delta(uint32_t earlier, uint32_t later)
{
    if (g_source == CYCLES_SRC_DWT) {
        return later - earlier;
    }
    if (g_source == CYCLES_SRC_SYSTICK) {
        return systick_delta(earlier, later);
    }
    return 0u;
}

uint32_t cycles_tick_hz(void)
{
    return (g_source == CYCLES_SRC_SYSTICK) ? SYSTICK_HZ : 0u;
}

uint32_t cycles_spin_insn(void)
{
    return (g_source == CYCLES_SRC_SYSTICK) ? SPIN_INSTRUCTIONS : 0u;
}

uint32_t cycles_spin_ticks(void)
{
    return g_spin_ticks;
}
