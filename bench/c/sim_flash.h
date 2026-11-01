/*
 * RAM-backed NOR flash simulator for the C reference benchmark harness.
 *
 * Semantics (see harness/SCENARIOS.md and harness/c/README.md):
 *   - 32 KiB of simulated NOR, 4096-byte erase blocks.
 *   - Reads copy bytes.
 *   - Writes can only clear bits (1 -> 0). If a write tries to set a bit
 *     (0 -> 1) the stored byte is the AND of old and new data, exactly like
 *     real NOR, and the attempt is counted in sim_nor_set_bit_attempts().
 *   - Erases must be block aligned / block sized and set the range to 0xFF.
 *   - Every successful read/write/erase op is counted, plus the byte volume,
 *     so benchmark phases can report flash traffic exactly as the protocol
 *     requires: reads, read_bytes, writes, write_bytes, erases, erase_bytes.
 *
 * Fault injection: sim_fault_arm(n) lets the next n flash ops succeed and makes
 * every following op fail (-1, no state change) until sim_fault_clear(). This
 * is the power-cut hook used by the interrupted-operation equivalence tests.
 */

#ifndef SIM_FLASH_H
#define SIM_FLASH_H

#include <stdint.h>
#include <stddef.h>

#define SIM_FLASH_SIZE      (32u * 1024u)
#define SIM_FLASH_BLK_SIZE  4096u
#define SIM_FLASH_BLK_COUNT (SIM_FLASH_SIZE / SIM_FLASH_BLK_SIZE)

struct flash_stats {
    uint64_t reads;
    uint64_t read_bytes;
    uint64_t writes;
    uint64_t write_bytes;
    uint64_t erases;
    uint64_t erase_bytes;
};

/* Whole simulated device. */
void sim_flash_global_init(void);          /* fill with 0xFF (erased state) */
void sim_flash_erase_all(void);            /* erase every block, reset stats untouched */
uint8_t *sim_flash_image(void);            /* raw 32 KiB image, for equivalence dumps */
size_t sim_flash_image_size(void);

/* Accounting of the successful ops since the last reset. */
struct flash_stats sim_flash_stats_get(void);
void sim_flash_stats_reset(void);

/* Diagnostics. */
uint64_t sim_nor_set_bit_attempts(void);   /* writes that tried to set 0 -> 1 */
uint64_t sim_nor_bounds_violations(void);  /* OOB / unaligned erase attempts */
void sim_nor_diag_reset(void);

/* Fault injection (power-cut simulation). */
void sim_fault_arm(uint64_t ops_before_failure); /* 0 = fail from the next op */
void sim_fault_clear(void);
uint64_t sim_fault_ops_attempted(void);    /* ops seen since the last arm/clear */

/*
 * Mutation-indexed power cut (used by the C<->Zig differential harness, and
 * matching Zig's `RamFlash.armFault`): only mutating operations (writes and
 * erases) consume the budget; reads never fail.  The next `mutations` mutating
 * operations succeed, then every following one fails without changing flash.
 * The mutation counter counts every mutating *attempt* (including failed ones),
 * exactly like the Zig simulator.
 */
void sim_fault_arm_mutations(uint64_t mutations_before_failure);
uint64_t sim_nor_mutations(void);          /* mutating attempts since boot */
int sim_fault_mutation_mode(void);         /* true while a mutation cut is armed */

/* Implemented for fdb_cfg.h / fal_cfg.h: library logs go to stderr only and
 * are disabled by default (C_HARNESS_VERBOSE=1 enables them) so logging can
 * never pollute the JSON or the measured phases. */
extern int fdb_host_log_enabled;
void fdb_host_log(const char *fmt, ...);

#endif /* SIM_FLASH_H */
