/*
 * Shared declarations for the C reference benchmark harness.
 *
 * The measurement protocol lives in harness/SCENARIOS.md. Everything that the
 * Rust rewrite must reproduce byte-for-byte (data generation, checksum
 * definitions, LCG ranges) is documented in harness/c/README.md and exposed
 * through the helpers below.
 */

#ifndef BENCH_H
#define BENCH_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>

#include <flashdb.h>
#include <fdb_low_lvl.h>

#include "sim_flash.h"

/* ---------- fixed geometry (harness/SCENARIOS.md) ---------- */
#define BENCH_SECTOR_SIZE      4096u
#define BENCH_PARTITION_SIZE   16384u
#define BENCH_PARTITION_COUNT  4u
#define BENCH_KV_PART_NAME     "fdb_kvdb1"
#define BENCH_TS_PART_NAME     "fdb_tsdb1"
#define BENCH_TS_MAX_LOG_LEN   32u
#define BENCH_TS_PAYLOAD_LEN   32u
#define BENCH_TS_SEED          0x5Au
#define BENCH_TS_START_TIME    1000

/* ---------- data generation (must match the Rust harness) ---------- */
/* kv_value(seed, i, len): byte[j] = (seed + i*31 + j*7) & 0xFF */
void bench_value(uint8_t *buf, size_t len, uint32_t pattern_seed, uint32_t i);
/* ts_payload(i): byte[j] = (0x5A + i*13 + j*5) & 0xFF */
void bench_ts_payload(uint8_t *buf, size_t len, uint32_t i);

/* Scenario-specific value seeds (documented in README.md). */
#define BENCH_SEED_KV_SET_SMALL  0x11u
#define BENCH_SEED_KV_UPDATE     0x22u
#define BENCH_SEED_KV_HOT        0x33u
#define BENCH_SEED_KV_LARGE      0x44u

/* "kv%u" / "key%u" style key formatting (returns out). */
const char *bench_key(char *out, size_t cap, const char *prefix, uint32_t i);

/* ---------- checksums: FNV-1a 32 (offset 0x811C9DC5, prime 0x01000193) ---- */
#define BENCH_FNV32_OFFSET 0x811C9DC5u
#define BENCH_FNV32_PRIME  0x01000193u

uint32_t bench_cs_bytes(uint32_t h, const void *buf, size_t len);
uint32_t bench_cs_u32(uint32_t h, uint32_t v);

/*
 * KV snapshot checksum: FNV-1a-32 over u32(entry_count) followed by entries
 * sorted by key name (byte-wise strcmp): u32(key_len), key bytes,
 * u32(value_len), value bytes.
 */
uint32_t bench_kv_snapshot_checksum(fdb_kvdb_t db, uint32_t *out_count,
                                    uint64_t *out_value_bytes);
/*
 * TS snapshot checksum: FNV-1a-32 over forward-iteration records
 * u32(status), u32(timestamp), u32(log_len), payload[log_len], followed by
 * u32(entry_count) at the end.
 */
uint32_t bench_ts_snapshot_checksum(fdb_tsdb_t db, uint32_t *out_count,
                                    uint64_t *out_payload_bytes);

/* ---------- timing ---------- */
int64_t bench_now_ns(void);

/* ---------- measured-phase error accounting ---------- */
#define BENCH_ERR_CODE_NUM 9
struct err_counts {
    uint64_t codes[BENCH_ERR_CODE_NUM]; /* indexed by fdb_err_t */
};

const char *bench_err_name(int code);

/* ---------- extra metadata attached to every scenario ---------- */
#define BENCH_EXTRA_MAX 24

struct extra_item {
    const char *key;
    char type;              /* 'i','u','d','s','b' scalar; 'a' u64 array; 'A' i64 array */
    int64_t i;
    double d;
    const char *s;
    const uint64_t *arr;
    const int64_t *iarr;
    size_t n;
};

struct extra_list {
    struct extra_item items[BENCH_EXTRA_MAX];
    size_t n;
};

void extra_i(struct extra_list *l, const char *key, int64_t v);
void extra_u(struct extra_list *l, const char *key, uint64_t v);
void extra_d(struct extra_list *l, const char *key, double v);
void extra_s(struct extra_list *l, const char *key, const char *v);
void extra_b(struct extra_list *l, const char *key, int v);
void extra_arr(struct extra_list *l, const char *key, const uint64_t *arr, size_t n);
void extra_arr_i64(struct extra_list *l, const char *key, const int64_t *arr, size_t n);

/* ---------- scenario results ---------- */
#define BENCH_MAX_RUNS        64
#define BENCH_MAX_SCENARIOS   64

struct scenario_result {
    const char *name;
    uint64_t ops;
    uint64_t hits;
    int runs;
    int64_t samples_ns[BENCH_MAX_RUNS];
    int64_t total_ns_median;
    double ns_per_op;
    uint32_t checksum;
    struct flash_stats flash;
    struct err_counts errs;
    struct extra_list extra;
    int flash_consistent;   /* identical flash counters over all runs */
    int errs_consistent;    /* identical error counts over all runs */
};

/* Currently measured phase error counters (body functions update these). */
extern struct err_counts bench_errs;

void bench_err_add(fdb_err_t rc);

typedef void (*bench_fn)(void *ctx);

/*
 * Runs the protocol's timed loop: for every repetition, run setup (excluded
 * from timing and counters), reset counters, run body between two
 * CLOCK_MONOTONIC reads, snapshot flash counters. Fills median into r.
 */
void bench_measure(struct scenario_result *r, const char *name, int runs,
                   bench_fn setup, bench_fn body, void *ctx);
/*
 * Same, with an optional after_setup hook that runs after setup and before the
 * counters/timer are reset (used when the scenario checksum must be taken on
 * the prepared state, e.g. tsl_mount).
 */
void bench_measure_ex(struct scenario_result *r, const char *name, int runs,
                      bench_fn setup, bench_fn after_setup, bench_fn body, void *ctx);
/* Sets ops + ns_per_op (call after the checksum is known if ops depends on data). */
void bench_finish(struct scenario_result *r, uint64_t ops);

/* Global result list / scenario filter / JSON emission. */
extern int bench_runs;
struct scenario_result *bench_new_result(void);   /* append a result slot */
void bench_set_filter(const char *name);
int bench_want(const char *name);
struct scenario_result *bench_results(void);
int bench_result_count(void);
void bench_json_write(FILE *f, const char *impl, const char *version);

/* Fatal harness error (setup failure, impossible invariant). */
void bench_fatal(const char *fmt, ...);

/* KV / TS scenario groups. */
void bench_kv_run_all(int runs);
void bench_ts_run_all(int runs);

/* Setup helpers shared with the check mode in bench.c and with image_tool.c. */
void bench_kv_setup_format(fdb_kvdb_t db);
fdb_err_t bench_kv_setup_hot(fdb_kvdb_t db);      /* format + key0..key31 */
fdb_err_t bench_ts_setup_format(fdb_tsdb_t db);   /* wipe + init TSDB, rollover off */
uint64_t bench_ts_populate_full(fdb_tsdb_t db, uint64_t max_appends, fdb_err_t *out_rc);
uint32_t bench_ts_max_blob_count(fdb_tsdb_t db);
fdb_time_t bench_ts_dummy_time(void);
fdb_err_t bench_ts_append(fdb_tsdb_t db, uint32_t i, fdb_time_t t);

#endif /* BENCH_H */
