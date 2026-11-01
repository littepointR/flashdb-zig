/*
 * TSDB scenarios from harness/SCENARIOS.md.
 *
 * Data generation (must match the Rust harness byte-for-byte):
 *   payload i: byte[j] = (0x5A + i*13 + j*5) & 0xFF, 32 bytes
 *   timestamp i: t_i = 1000 + i (strictly increasing)
 *   "populate to full": append until FDB_SAVED_FULL with rollover disabled.
 *
 * tsl_by_time / tsl_query_count ranges come from the protocol LCG:
 *   state = 12345
 *   next(): state = (state * 1103515245 + 12345) mod 2^31
 *   per query: off = next() % 3000; len = 50 + next() % 451
 *              from = 1000 + off; to = from + len (inclusive)
 */

#include <stdio.h>
#include <string.h>

#include "bench.h"

#define TS_APPEND_MAX_CALLS   4000u
#define TS_RANGE_QUERIES      500u
#define TS_LCG_SEED           12345u

static fdb_tsdb_t tsdb(void)
{
    static struct fdb_tsdb db;

    return &db;
}

fdb_time_t bench_ts_dummy_time(void)
{
    /* All benchmark appends use fdb_tsl_append_with_ts(); this is only needed
     * because fdb_tsdb_init() asserts get_time != NULL. */
    return 0;
}

static void ts_setup(fdb_tsdb_t db, int rollover)
{
    fdb_err_t rc;
    bool ro = rollover ? true : false;

    memset(db, 0, sizeof(*db));
    sim_flash_erase_all();
    sim_nor_diag_reset();
    rc = fdb_tsdb_init(db, "tsdb", BENCH_TS_PART_NAME, bench_ts_dummy_time,
                       BENCH_TS_MAX_LOG_LEN, NULL);
    if (rc != FDB_NO_ERR) {
        bench_fatal("tsdb format/init failed: %s", bench_err_name(rc));
    }
    /* control requires init_ok == true, so it must be set after init */
    fdb_tsdb_control(db, FDB_TSDB_CTRL_SET_ROLLOVER, &ro);
}

fdb_err_t bench_ts_setup_format(fdb_tsdb_t db)
{
    ts_setup(db, 0);
    return FDB_NO_ERR;
}

fdb_err_t bench_ts_append(fdb_tsdb_t db, uint32_t i, fdb_time_t t)
{
    uint8_t payload[BENCH_TS_PAYLOAD_LEN];
    struct fdb_blob blob;

    bench_ts_payload(payload, sizeof(payload), i);
    return fdb_tsl_append_with_ts(db, fdb_blob_make(&blob, payload, sizeof(payload)), t);
}

uint32_t bench_ts_max_blob_count(fdb_tsdb_t db)
{
    return (uint32_t)fdb_tsl_max_blob_count(db);
}

uint64_t bench_ts_populate_full(fdb_tsdb_t db, uint64_t max_appends, fdb_err_t *out_rc)
{
    uint64_t i;
    fdb_err_t rc = FDB_NO_ERR;

    for (i = 0; i < max_appends; i++) {
        rc = bench_ts_append(db, (uint32_t)i, (fdb_time_t)(BENCH_TS_START_TIME + (int)i));
        if (rc != FDB_NO_ERR) {
            break;
        }
    }
    if (out_rc) {
        *out_rc = rc;
    }
    return i;
}

/* Protocol LCG: state is kept modulo 2^31. */
static uint32_t ts_lcg_next(uint32_t *s)
{
    *s = (uint32_t)((*s * 1103515245u + 12345u) & 0x7FFFFFFFu);
    return *s;
}

/* ------------------------------------------------------------------ */
/* tsl_append: append until SavedFull (rollover disabled)              */
/* ------------------------------------------------------------------ */

static uint64_t tsl_append_count;
static uint64_t tsl_append_calls;
static int tsl_append_saved_full;

static void tsl_append_setup(void *ctx)
{
    (void)ctx;
    (void)bench_ts_setup_format(tsdb());
}

static void tsl_append_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint32_t i;

    (void)ctx;
    tsl_append_count = 0;
    tsl_append_calls = 0;
    tsl_append_saved_full = 0;
    for (i = 0; i < TS_APPEND_MAX_CALLS; i++) {
        fdb_err_t rc = bench_ts_append(db, i, (fdb_time_t)(BENCH_TS_START_TIME + (int)i));

        tsl_append_calls++;
        bench_err_add(rc);
        if (rc == FDB_SAVED_FULL) {
            tsl_append_saved_full = 1;
            break;
        }
        if (rc != FDB_NO_ERR) {
            break;
        }
        tsl_append_count++;
    }
}

/* ------------------------------------------------------------------ */
/* tsl_append_rollover: 3 x capacity appends with rollover enabled     */
/* ------------------------------------------------------------------ */

static uint32_t ts_rollover_capacity;
static uint64_t ts_rollover_ok;
static uint64_t ts_rollover_calls;

static void tsl_rollover_setup(void *ctx)
{
    (void)ctx;
    ts_setup(tsdb(), 1);
}

static void tsl_rollover_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint64_t n = (uint64_t)ts_rollover_capacity * 3u;
    uint64_t i;

    (void)ctx;
    ts_rollover_ok = 0;
    ts_rollover_calls = 0;
    for (i = 0; i < n; i++) {
        fdb_err_t rc = bench_ts_append(db, (uint32_t)i,
                                      (fdb_time_t)(BENCH_TS_START_TIME + (int)i));

        ts_rollover_calls++;
        bench_err_add(rc);
        if (rc == FDB_NO_ERR) {
            ts_rollover_ok++;
        }
    }
}

/* ------------------------------------------------------------------ */
/* tsl_iter_fwd / tsl_iter_rev: 20 x full iteration                    */
/* ------------------------------------------------------------------ */

struct ts_iter_result {
    uint32_t count;
    uint64_t sum_len;
};

static bool ts_count_cb(fdb_tsl_t tsl, void *arg)
{
    struct ts_iter_result *res = (struct ts_iter_result *)arg;

    res->count++;
    res->sum_len += (uint64_t)tsl->log_len;
    return false;
}

static struct ts_iter_result iter_last;
static uint32_t ts_populated_count;

static void ts_iter_setup(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    fdb_err_t rc;

    (void)ctx;
    ts_setup(db, 0);
    ts_populated_count = (uint32_t)bench_ts_populate_full(db, TS_APPEND_MAX_CALLS, &rc);
    if (rc != FDB_SAVED_FULL) {
        bench_fatal("populate-to-full did not reach SavedFull (rc=%s, count=%u)",
                    bench_err_name(rc), ts_populated_count);
    }
}

static void tsl_iter_fwd_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint32_t t;

    (void)ctx;
    for (t = 0; t < 20; t++) {
        memset(&iter_last, 0, sizeof(iter_last));
        fdb_tsl_iter(db, ts_count_cb, &iter_last);
    }
}

static void tsl_iter_rev_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint32_t t;

    (void)ctx;
    for (t = 0; t < 20; t++) {
        memset(&iter_last, 0, sizeof(iter_last));
        fdb_tsl_iter_reverse(db, ts_count_cb, &iter_last);
    }
}

/* ------------------------------------------------------------------ */
/* tsl_by_time / tsl_query_count: 500 deterministically ranged queries */
/* ------------------------------------------------------------------ */

static uint32_t ts_range_counts[TS_RANGE_QUERIES];
static uint64_t ts_range_total;
static uint64_t ts_range_payload;

static void ts_range_generate(uint32_t *state, fdb_time_t *from, fdb_time_t *to)
{
    uint32_t off, len;

    *state = ts_lcg_next(state);
    off = *state % 3000u;
    *state = ts_lcg_next(state);
    len = 50u + (*state % 451u);
    *from = (fdb_time_t)(BENCH_TS_START_TIME + (int)off);
    *to = *from + (fdb_time_t)len;
}

static void ts_by_time_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint32_t q, s = TS_LCG_SEED;

    (void)ctx;
    ts_range_total = 0;
    ts_range_payload = 0;
    for (q = 0; q < TS_RANGE_QUERIES; q++) {
        fdb_time_t from, to;
        struct ts_iter_result res;

        ts_range_generate(&s, &from, &to);
        memset(&res, 0, sizeof(res));
        fdb_tsl_iter_by_time(db, from, to, ts_count_cb, &res);
        ts_range_counts[q] = res.count;
        ts_range_total += res.count;
        ts_range_payload += res.sum_len;
    }
}

static void ts_query_count_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint32_t q, s = TS_LCG_SEED;

    (void)ctx;
    ts_range_total = 0;
    ts_range_payload = 0;
    for (q = 0; q < TS_RANGE_QUERIES; q++) {
        fdb_time_t from, to;
        size_t count;

        ts_range_generate(&s, &from, &to);
        count = fdb_tsl_query_count(db, from, to, FDB_TSL_WRITE);
        ts_range_counts[q] = (uint32_t)count;
        ts_range_total += count;
    }
}

/* ------------------------------------------------------------------ */
/* tsl_mount: 50 x (deinit + mount)                                    */
/* ------------------------------------------------------------------ */

static uint32_t ts_mount_ok;
static uint32_t ts_mount_checksum;

static void tsl_mount_setup(void *ctx)
{
    ts_iter_setup(ctx);
}

/* The populated DB is the functional result to compare; upstream FlashDB
 * cannot iterate a full no-rollover DB after a remount (oldest_addr ends up
 * 0xFFF and cur_sec 0xFFFFFFFF), so the snapshot is taken right before the
 * measured mount phase. */
static void tsl_mount_after_setup(void *ctx)
{
    (void)ctx;
    ts_mount_checksum = bench_ts_snapshot_checksum(tsdb(), NULL, NULL);
}

static void tsl_mount_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint32_t i;

    (void)ctx;
    ts_mount_ok = 0;
    for (i = 0; i < 50; i++) {
        fdb_err_t rc;

        (void)fdb_tsdb_deinit(db);
        rc = fdb_tsdb_init(db, "tsdb", BENCH_TS_PART_NAME, bench_ts_dummy_time,
                           BENCH_TS_MAX_LOG_LEN, NULL);
        bench_err_add(rc);
        if (rc == FDB_NO_ERR) {
            ts_mount_ok++;
        }
    }
}

/* ------------------------------------------------------------------ */
/* tsl_clean: 20 x (clean + repopulate to full)                        */
/* ------------------------------------------------------------------ */

static uint64_t ts_clean_appends;

static void tsl_clean_body(void *ctx)
{
    fdb_tsdb_t db = tsdb();
    uint32_t c;

    (void)ctx;
    ts_clean_appends = 0;
    for (c = 0; c < 20; c++) {
        fdb_err_t rc;

        fdb_tsl_clean(db);
        ts_clean_appends = bench_ts_populate_full(db, TS_APPEND_MAX_CALLS, &rc);
        if (rc != FDB_SAVED_FULL) {
            bench_fatal("tsl_clean: repopulate did not reach SavedFull (rc=%s, count=%llu)",
                        bench_err_name(rc), (unsigned long long)ts_clean_appends);
        }
    }
}

/* ------------------------------------------------------------------ */
/* scenario runners                                                    */
/* ------------------------------------------------------------------ */

static void ts_finish_snapshot(struct scenario_result *r)
{
    uint32_t count = 0;
    uint64_t payload_bytes = 0;

    r->checksum = bench_ts_snapshot_checksum(tsdb(), &count, &payload_bytes);
    extra_u(&r->extra, "entries_after", count);
    extra_u(&r->extra, "payload_bytes_after", payload_bytes);
}

static uint32_t ts_range_checksum(void)
{
    uint32_t h = BENCH_FNV32_OFFSET;
    uint32_t q;

    h = bench_cs_u32(h, TS_RANGE_QUERIES);
    for (q = 0; q < TS_RANGE_QUERIES; q++) {
        h = bench_cs_u32(h, ts_range_counts[q]);
    }
    return h;
}

void bench_ts_run_all(int runs)
{
    struct scenario_result *r;

    if (bench_want("tsl_append")) {
        r = bench_new_result();
        bench_measure(r, "tsl_append", runs, tsl_append_setup, tsl_append_body, NULL);
        ts_finish_snapshot(r);
        extra_u(&r->extra, "appended", tsl_append_count);
        extra_u(&r->extra, "append_calls", tsl_append_calls);
        extra_b(&r->extra, "saved_full", tsl_append_saved_full);
        r->hits = 0;
        bench_finish(r, tsl_append_count);
    }

    if (bench_want("tsl_append_rollover")) {
        fdb_err_t probe_rc = FDB_NO_ERR;

        /* Capacity probe (setup, excluded from measurement): fill a scratch
         * instance with rollover disabled and count the entries. The protocol
         * defines the measured phase as 3 x that capacity. */
        ts_setup(tsdb(), 0);
        ts_rollover_capacity = (uint32_t)bench_ts_populate_full(tsdb(), TS_APPEND_MAX_CALLS, &probe_rc);
        if (probe_rc != FDB_SAVED_FULL) {
            bench_fatal("rollover capacity probe did not reach SavedFull");
        }

        r = bench_new_result();
        bench_measure(r, "tsl_append_rollover", runs, tsl_rollover_setup, tsl_rollover_body, NULL);
        ts_finish_snapshot(r);
        extra_u(&r->extra, "capacity", ts_rollover_capacity);
        extra_u(&r->extra, "appends_ok", ts_rollover_ok);
        extra_u(&r->extra, "append_calls", ts_rollover_calls);
        r->hits = 0;
        bench_finish(r, ts_rollover_calls);
    }

    if (bench_want("tsl_iter_fwd")) {
        r = bench_new_result();
        bench_measure(r, "tsl_iter_fwd", runs, ts_iter_setup, tsl_iter_fwd_body, NULL);
        ts_finish_snapshot(r);
        extra_u(&r->extra, "entries_per_iter", iter_last.count);
        extra_u(&r->extra, "sum_payload_len_per_iter", iter_last.sum_len);
        extra_u(&r->extra, "populated", ts_populated_count);
        r->hits = 0;
        bench_finish(r, 20);
    }

    if (bench_want("tsl_iter_rev")) {
        r = bench_new_result();
        bench_measure(r, "tsl_iter_rev", runs, ts_iter_setup, tsl_iter_rev_body, NULL);
        ts_finish_snapshot(r);
        extra_u(&r->extra, "entries_per_iter", iter_last.count);
        extra_u(&r->extra, "sum_payload_len_per_iter", iter_last.sum_len);
        extra_u(&r->extra, "populated", ts_populated_count);
        r->hits = 0;
        bench_finish(r, 20);
    }

    if (bench_want("tsl_by_time")) {
        r = bench_new_result();
        bench_measure(r, "tsl_by_time", runs, ts_iter_setup, ts_by_time_body, NULL);
        r->checksum = ts_range_checksum();
        extra_u(&r->extra, "queries", TS_RANGE_QUERIES);
        extra_u(&r->extra, "sum_matches", ts_range_total);
        extra_u(&r->extra, "sum_payload_len", ts_range_payload);
        extra_u(&r->extra, "populated", ts_populated_count);
        r->hits = 0;
        bench_finish(r, TS_RANGE_QUERIES);
    }

    if (bench_want("tsl_query_count")) {
        r = bench_new_result();
        bench_measure(r, "tsl_query_count", runs, ts_iter_setup, ts_query_count_body, NULL);
        r->checksum = ts_range_checksum();
        extra_u(&r->extra, "queries", TS_RANGE_QUERIES);
        extra_u(&r->extra, "sum_count", ts_range_total);
        extra_u(&r->extra, "populated", ts_populated_count);
        r->hits = 0;
        bench_finish(r, TS_RANGE_QUERIES);
    }

    if (bench_want("tsl_mount")) {
        r = bench_new_result();
        bench_measure_ex(r, "tsl_mount", runs, tsl_mount_setup,
                         tsl_mount_after_setup, tsl_mount_body, NULL);
        r->checksum = ts_mount_checksum;
        extra_u(&r->extra, "mount_ok", ts_mount_ok);
        extra_u(&r->extra, "populated", ts_populated_count);
        extra_b(&r->extra, "checksum_from_pre_mount_state", 1);
        r->hits = 0;
        bench_finish(r, 50);
    }

    if (bench_want("tsl_clean")) {
        r = bench_new_result();
        bench_measure(r, "tsl_clean", runs, ts_iter_setup, tsl_clean_body, NULL);
        ts_finish_snapshot(r);
        extra_u(&r->extra, "cycles", 20);
        extra_u(&r->extra, "appends_per_cycle", ts_clean_appends);
        extra_u(&r->extra, "populated", ts_populated_count);
        r->hits = 0;
        bench_finish(r, 20);
    }
}
