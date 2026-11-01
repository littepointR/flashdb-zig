/*
 * FlashDB firmware measurement harness -- workload specification.
 *
 * The SAME workload shape must run in the C firmware (real FlashDB) and in the
 * Zig firmware.  The values below are mirrored by the Zig firmware's
 * constants; keep them in sync.  They match the host benchmark's logical
 * workload shape (bench/SCENARIOS.md) scaled down to what fits a Cortex-M3
 * measurement image.
 *
 * Deterministic by construction: every value is a pure function of the loop
 * index, there is no real clock and no RNG, so checksums are stable across
 * runs and can be compared between the C and Zig builds.
 */
#ifndef HARNESS_WORKLOAD_SPEC_H
#define HARNESS_WORKLOAD_SPEC_H

/* ---- KVDB phase ------------------------------------------------------- */
/* Number of distinct keys initially written with fdb_kv_set(). */
#define HW_KV_KEYS             64
/* Of those, how many get a second (updated) value. */
#define HW_KV_UPDATES          32
/* Rewrites used to force sector GC churn; cycles over HW_KV_CHURN_KEYS keys. */
#define HW_KV_CHURN            1500
#define HW_KV_CHURN_KEYS       16
/* String value length (excluding NUL) of every KV value. */
#define HW_KV_VALUE_LEN        24

/* ---- TSDB phase ------------------------------------------------------- */
/* Number of time-series log entries appended. */
#define HW_TS_APPENDS          200
/* Payload bytes appended per log entry. */
#define HW_TS_PAYLOAD_LEN      16
/* Fake clock origin; harness_get_time() returns base + append index. */
#define HW_TS_BASE_TIME        1000

/* ---- Database geometry ------------------------------------------------ */
/* FAL flash device: 32 KiB simulated NOR, 4 KiB erase blocks.
 * One 16 KiB KV partition + one 16 KiB TS partition (a single RAM array in
 * .sim_flash on the C side; two arrays on the Zig side). */
#define HW_SIM_FLASH_LEN       (32u * 1024u)
#define HW_SIM_FLASH_BLK_SIZE  (4u * 1024u)
/* KVDB partition: 16 KiB = 4 sectors of 4 KiB. */
#define HW_KVDB_PART_OFFSET    (0u)
#define HW_KVDB_PART_LEN       (16u * 1024u)
/* TSDB partition: 16 KiB = 4 sectors of 4 KiB. */
#define HW_TSDB_PART_OFFSET    (16u * 1024u)
#define HW_TSDB_PART_LEN       (16u * 1024u)
/* TSDB max_len argument: upper bound for one log blob. */
#define HW_TSDB_MAX_LEN        64u

#endif /* HARNESS_WORKLOAD_SPEC_H */
