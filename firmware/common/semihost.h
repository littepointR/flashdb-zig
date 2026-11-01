/*
 * FlashDB firmware measurement harness -- ARM semihosting output.
 *
 * Uses the QEMU "semihosting" interface (BKPT 0xAB on Cortex-M) so the
 * firmware needs no UART driver and no libc.  Operation numbers are the ARM
 * semihosting spec values:
 *   SYS_WRITE0 (0x04): r1 = pointer to NUL-terminated string
 *   SYS_EXIT   (0x18): r1 = ADP_Stopped_ApplicationExit (0x20026)
 *
 * QEMU must be started with `-semihosting` (or `-semihosting-config`).
 * Without it the BKPT traps to the hard-fault handler and the run hangs until
 * the host timeout fires.
 *
 * Everything printed here happens AFTER the final stack high-water scan, so
 * the formatters' own stack usage is never charged to the measured workload.
 * The decimal formatter avoids division (no __aeabi_uidiv pull-in), keeping
 * the harness's own footprint negligible and identical to the Zig harness.
 */
#ifndef HARNESS_SEMIHOST_H
#define HARNESS_SEMIHOST_H

#include <stdint.h>

#define SEMIHOST_SYS_WRITE0 0x04u
#define SEMIHOST_SYS_EXIT   0x18u
#define SEMIHOST_ADP_STOPPED_APP_EXIT 0x20026u

/* Write a NUL-terminated string to the host console. */
void sh_write0(const char *s);

/* Write an unsigned 32-bit value in decimal. */
void sh_write_u32(uint32_t value);

/* Write a 32-bit value as 0xXXXXXXXX. */
void sh_write_hex32(uint32_t value);

/*
 * Everything the firmware reports in its single RESULT line.
 *
 * Section sizes are derived from linker symbols (common/mps2_an385.ld) and
 * cross-check the host-side `llvm-size -A` numbers.
 */
struct harness_metrics {
    /* Section sizes in bytes (.text/.rodata/.data/.bss), from linker symbols. */
    uint32_t text;
    uint32_t rodata;
    uint32_t data;
    uint32_t bss;
    uint32_t sim_flash;    /* NOLOAD simulated-NOR region (not MCU RAM/ROM) */

    /* Stack measurement in bytes.  stack_limit is the painted region size. */
    uint32_t stack;        /* high-water of the whole run (init + workload)   */
    uint32_t stack_init;   /* high-water right after database init            */
    uint32_t stack_limit;  /* painted stack region (8 KiB)                    */

#ifdef HARNESS_STACK_PHASES
    /* Isolated per-phase peaks from common/stack.c stack_repaint() scans.
     * Diagnostic build only (-DHARNESS_STACK_PHASES=1). */
    uint32_t st_set;
    uint32_t st_get;
    uint32_t st_iter;
    uint32_t st_gc;
    uint32_t st_ts_append;
    uint32_t st_ts_iter;
#endif

    /* Workload results (must match the Zig firmware exactly). */
    uint32_t kv_writes;
    uint32_t kv_gets;
    uint32_t kv_iterated;
    uint32_t kv_checksum;       /* FNV-1a over the 64 values in key-index order */
    uint32_t kv_iter_checksum;  /* FNV-1a over (name, value) in iteration order */
    uint32_t ts_appends;
    uint32_t ts_iterated;
    uint32_t ts_checksum;       /* FNV-1a over the payloads in forward order   */

#ifdef FW_CYCLES
    /* Cycle measurement (common/cycles.c).  See cycles.h for the DWT /
     * SysTick-proxy source selection and the calibration fields. */
    uint32_t cycles_src;        /* CYCLES_SRC_* (1 = DWT, 2 = SysTick proxy)   */
    uint32_t cycles_total;      /* mount + kv + ts (sum of the phase deltas)   */
    uint32_t cycles_mount;      /* databases_init()                            */
    uint32_t cycles_kv;         /* kvdb_phase()                                */
    uint32_t cycles_ts;         /* tsdb_phase()                                */
    uint32_t cycles_tick_hz;    /* SysTick clock in Hz (0 for DWT)             */
    uint32_t cycles_spin_insn;  /* calibration: instructions in the probe spin */
    uint32_t cycles_spin_ticks; /* calibration: ticks measured for that spin   */
#ifdef HARNESS_STACK_PHASES
    /* Cycle deltas of the diagnostic phases (repainted stack per phase). */
    uint32_t cyc_st_set;
    uint32_t cyc_st_get;
    uint32_t cyc_st_iter;
    uint32_t cyc_st_gc;
    uint32_t cyc_st_ts_append;
    uint32_t cyc_st_ts_iter;
#endif
#endif /* FW_CYCLES */
};

/* Print the RESULT line. */
void harness_print_result(const struct harness_metrics *m);

/* Fill the static-size fields from the linker symbols. */
void harness_fill_section_sizes(struct harness_metrics *m);

/* Print "ERROR stage=<stage> code=<code>", then "RESULT rc=1" and terminate. */
void harness_fail(const char *stage, int code) __attribute__((noreturn));

/* Terminate the emulator through semihosting.  Never returns. */
void harness_exit(void) __attribute__((noreturn));

#endif /* HARNESS_SEMIHOST_H */
