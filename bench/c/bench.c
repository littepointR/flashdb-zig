/*
 * Entry point of the C reference benchmark harness.
 *
 *   ./c_bench --mode bench [--runs N] [--out FILE]
 *   ./c_bench --mode check          # behavioural invariant checks
 *   ./c_bench --mode probe          # diagnostics (not part of the protocol)
 *
 * The JSON document goes to stdout and to --out (default
 * harness/results/c_wg<NN>_host.json). Library logs go to stderr.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bench.h"

extern void bench_set_filter(const char *name);

#define DEFAULT_RESULTS_DIR "harness/results"

static void usage(const char *argv0)
{
    fprintf(stderr,
            "usage: %s [--mode bench|check|probe] [--runs N] [--out FILE] [--impl NAME] [--only NAME]\n"
            "\n"
            "  --mode bench   run the SCENARIOS.md scenarios and emit JSON (default)\n"
            "  --mode check   run behavioural invariant checks (exit != 0 on failure)\n"
            "  --mode probe   print geometry / behaviour diagnostics\n"
            "  --runs N       measured repetitions per scenario (default 5)\n"
            "  --out FILE     JSON output path (default " DEFAULT_RESULTS_DIR "/c_wg<NN>_host.json)\n"
            "  --impl NAME    implementation name recorded in JSON (default \"c\")\n"
            "  --only NAME    run a single scenario\n",
            argv0);
}

/* ================================================================== */
/* check mode                                                          */
/* ================================================================== */

static int check_failures;

static void check_report(int ok, const char *name, const char *detail)
{
    printf("%s %-42s%s%s\n", ok ? "PASS" : "FAIL", name,
           detail && detail[0] ? ": " : "", detail ? detail : "");
    if (!ok) {
        check_failures++;
    }
}

static void check_u64(const char *name, uint64_t got, uint64_t want)
{
    char detail[160];

    if (got == want) {
        check_report(1, name, NULL);
    } else {
        snprintf(detail, sizeof(detail), "got %llu, want %llu",
                 (unsigned long long)got, (unsigned long long)want);
        check_report(0, name, detail);
    }
}

static void check_sim_semantics(void)
{
    const struct fal_flash_dev *dev = &nor_flash0;
    uint8_t data, buf[8];
    uint8_t *img;

    sim_flash_global_init();
    img = sim_flash_image();
    check_report(img[0] == 0xFF && img[SIM_FLASH_SIZE - 1] == 0xFF,
                 "sim: erased image is all 0xFF", NULL);

    sim_flash_stats_reset();
    sim_nor_diag_reset();

    data = 0xF0;
    check_u64("sim: write op returns size", (uint64_t)(dev->ops.write(0, &data, 1) == 1), 1);
    check_u64("sim: read op returns size", (uint64_t)(dev->ops.read(0, buf, 1) == 1), 1);
    check_u64("sim: read byte", buf[0], 0xF0);
    data = 0x0F;
    (void)dev->ops.write(0, &data, 1);
    check_u64("sim: write can only clear bits", img[0], 0x00);
    check_u64("sim: set-bit attempt counted", sim_nor_set_bit_attempts(), 1);
    check_u64("sim: stats reads", sim_flash_stats_get().reads, 1);
    check_u64("sim: stats read_bytes", sim_flash_stats_get().read_bytes, 1);
    check_u64("sim: stats writes", sim_flash_stats_get().writes, 2);
    check_u64("sim: stats write_bytes", sim_flash_stats_get().write_bytes, 2);

    check_u64("sim: unaligned erase fails", (uint64_t)(dev->ops.erase(1, 4096) < 0), 1);
    check_u64("sim: mis-sized erase fails", (uint64_t)(dev->ops.erase(0, 100) < 0), 1);
    check_u64("sim: aligned erase ok", (uint64_t)(dev->ops.erase(0, 4096) == 4096), 1);
    check_u64("sim: erase stats", sim_flash_stats_get().erases, 1);
    check_u64("sim: erase_bytes stats", sim_flash_stats_get().erase_bytes, 4096);
    check_u64("sim: erase sets 0xFF", img[0], 0xFF);
    check_u64("sim: bounds violations counted", sim_nor_bounds_violations(), 2);

    sim_fault_arm(2);
    check_u64("sim: fault injection allows op 1",
              (uint64_t)(dev->ops.read(0, buf, 1) == 1), 1);
    check_u64("sim: fault injection allows op 2",
              (uint64_t)(dev->ops.read(0, buf, 1) == 1), 1);
    check_u64("sim: fault injection rejects op 3",
              (uint64_t)(dev->ops.read(0, buf, 1) < 0), 1);
    check_u64("sim: fault injection rejects op 4",
              (uint64_t)(dev->ops.read(0, buf, 1) < 0), 1);
    sim_fault_clear();
    check_u64("sim: fault injection cleared",
              (uint64_t)(dev->ops.read(0, buf, 1) == 1), 1);
}

static void check_kv_basic(void)
{
    static struct fdb_kvdb db_obj;
    fdb_kvdb_t db = &db_obj;
    char key[32];
    uint8_t val[32], got[64];
    struct fdb_blob blob;
    uint32_t i, count;
    uint64_t value_bytes;
    uint32_t cs_deleted;
    size_t n;
    fdb_err_t rc;

    bench_kv_setup_format(db);
    for (i = 0; i < 4; i++) {
        bench_key(key, sizeof(key), "key", i);
        bench_value(val, sizeof(val), BENCH_SEED_KV_HOT, i);
        rc = fdb_kv_set_blob(db, key, fdb_blob_make(&blob, val, sizeof(val)));
        if (rc != FDB_NO_ERR) {
            break;
        }
    }
    check_u64("kv: 4 x set", (uint64_t)rc, (uint64_t)FDB_NO_ERR);

    for (i = 0; i < 4; i++) {
        bench_value(val, sizeof(val), BENCH_SEED_KV_HOT, i);
        bench_key(key, sizeof(key), "key", i);
        n = fdb_kv_get_blob(db, key, fdb_blob_make(&blob, got, sizeof(got)));
        check_u64("kv: get returns value_len", n, sizeof(val));
        check_u64("kv: get data matches stored value",
                  (uint64_t)(n == sizeof(val) && memcmp(got, val, sizeof(val)) == 0), 1);
    }

    (void)bench_kv_snapshot_checksum(db, &count, &value_bytes);
    check_u64("kv: iterate count", count, 4);
    check_u64("kv: iterate value bytes", value_bytes, 4u * 32u);

    bench_key(key, sizeof(key), "key", 0);
    rc = fdb_kv_del(db, key);
    check_u64("kv: delete existing", (uint64_t)rc, (uint64_t)FDB_NO_ERR);
    n = fdb_kv_get_blob(db, key, fdb_blob_make(&blob, got, sizeof(got)));
    check_u64("kv: get deleted key returns 0", n, 0);
    rc = fdb_kv_del(db, key);
    check_u64("kv: delete missing key returns FDB_KV_NAME_ERR", (uint64_t)rc,
              (uint64_t)FDB_KV_NAME_ERR);
    check_u64("kv: FDB_KV_NAME_ERR numeric code", (uint64_t)FDB_KV_NAME_ERR, 5);

    cs_deleted = bench_kv_snapshot_checksum(db, &count, &value_bytes);
    check_u64("kv: iterate count after delete", count, 3);

    fdb_kvdb_deinit(db);
    check_u64("kv: remount", (uint64_t)fdb_kvdb_init(db, "kvdb", BENCH_KV_PART_NAME, NULL, NULL),
              (uint64_t)FDB_NO_ERR);
    check_u64("kv: remount keeps count",
              (uint64_t)(bench_kv_snapshot_checksum(db, &count, &value_bytes) == cs_deleted), 1);
    check_u64("kv: remount count", count, 3);
    bench_value(val, sizeof(val), BENCH_SEED_KV_HOT, 1);
    n = fdb_kv_get_blob(db, "key1", fdb_blob_make(&blob, got, sizeof(got)));
    check_u64("kv: remount keeps value",
              (uint64_t)(n == sizeof(val) && memcmp(got, val, sizeof(val)) == 0), 1);

    check_u64("kv: no NOR set-bit attempts", sim_nor_set_bit_attempts(), 0);
    check_u64("kv: no out-of-bounds flash access", sim_nor_bounds_violations(), 0);
}

static void check_kv_gc(void)
{
    static struct fdb_kvdb db_obj;
    fdb_kvdb_t db = &db_obj;
    uint8_t val[32], got[32];
    struct fdb_blob blob;
    uint32_t i;
    size_t n;

    bench_kv_setup_format(db);
    bench_value(val, sizeof(val), BENCH_SEED_KV_UPDATE, 0);
    (void)fdb_kv_set_blob(db, "counter", fdb_blob_make(&blob, val, sizeof(val)));
    sim_flash_stats_reset();
    for (i = 0; i < 1000; i++) {
        bench_value(val, sizeof(val), BENCH_SEED_KV_UPDATE, i);
        (void)fdb_kv_set_blob(db, "counter", fdb_blob_make(&blob, val, sizeof(val)));
    }
    check_report(sim_flash_stats_get().erases > 0,
                 "kv: 1000 updates trigger GC sector erases", NULL);
    n = fdb_kv_get_blob(db, "counter", fdb_blob_make(&blob, got, sizeof(got)));
    check_u64("kv: last value readable after GC", n, sizeof(got));
    check_u64("kv: last value matches after GC",
              (uint64_t)(memcmp(got, val, sizeof(got)) == 0), 1);
    check_u64("kv: no NOR set-bit attempts during GC", sim_nor_set_bit_attempts(), 0);
    check_u64("kv: no out-of-bounds access during GC", sim_nor_bounds_violations(), 0);

    fdb_kvdb_deinit(db);
    check_u64("kv: remount after GC",
              (uint64_t)fdb_kvdb_init(db, "kvdb", BENCH_KV_PART_NAME, NULL, NULL),
              (uint64_t)FDB_NO_ERR);
    n = fdb_kv_get_blob(db, "counter", fdb_blob_make(&blob, got, sizeof(got)));
    check_u64("kv: value survives remount after GC",
              (uint64_t)(n == sizeof(val) && memcmp(got, val, sizeof(val)) == 0), 1);
}

struct ts_check_ctx {
    uint32_t count;
    uint64_t sum_len;
    fdb_time_t min_time;
    fdb_time_t max_time;
    fdb_time_t prev;
    int first;
    int ordered;
    int reverse;
};

static bool ts_check_cb(fdb_tsl_t tsl, void *arg)
{
    struct ts_check_ctx *c = (struct ts_check_ctx *)arg;

    if (!c->first &&
        (c->reverse ? (tsl->time >= c->prev) : (tsl->time <= c->prev))) {
        c->ordered = 0;
    }
    if (c->first || tsl->time < c->min_time) {
        c->min_time = tsl->time;
    }
    if (c->first || tsl->time > c->max_time) {
        c->max_time = tsl->time;
    }
    c->prev = tsl->time;
    c->first = 0;
    c->count++;
    c->sum_len += (uint64_t)tsl->log_len;
    return false;
}

static void ts_collect(fdb_tsdb_t db, int reverse, struct ts_check_ctx *out)
{
    memset(out, 0, sizeof(*out));
    out->ordered = 1;
    out->first = 1;
    out->reverse = reverse;
    if (reverse) {
        fdb_tsl_iter_reverse(db, ts_check_cb, out);
    } else {
        fdb_tsl_iter(db, ts_check_cb, out);
    }
}

static void check_ts_basic(void)
{
    static struct fdb_tsdb db_obj;
    fdb_tsdb_t db = &db_obj;
    struct ts_check_ctx fwd, rev;
    fdb_err_t rc;
    uint32_t i, count;
    uint64_t payload_bytes;

    (void)bench_ts_setup_format(db);
    for (i = 0; i < 10; i++) {
        rc = bench_ts_append(db, i, (fdb_time_t)(1000 + i));
        if (rc != FDB_NO_ERR) {
            break;
        }
    }
    check_u64("ts: 10 appends", (uint64_t)rc, (uint64_t)FDB_NO_ERR);

    ts_collect(db, 0, &fwd);
    check_u64("ts: forward iterate count", fwd.count, 10);
    check_u64("ts: forward payload bytes", fwd.sum_len, 10u * 32u);
    check_u64("ts: forward timestamps increase", (uint64_t)fwd.ordered, 1);
    check_u64("ts: first timestamp", fwd.min_time, 1000);
    check_u64("ts: last timestamp", fwd.max_time, 1009);

    ts_collect(db, 1, &rev);
    check_u64("ts: reverse iterate count", rev.count, 10);
    check_u64("ts: reverse timestamps increase", (uint64_t)rev.ordered, 1);

    check_u64("ts: query_count(1000,1009,WRITE)",
              (uint64_t)fdb_tsl_query_count(db, 1000, 1009, FDB_TSL_WRITE), 10);
    check_u64("ts: query_count(1000,1004,WRITE)",
              (uint64_t)fdb_tsl_query_count(db, 1000, 1004, FDB_TSL_WRITE), 5);

    ts_collect(db, 0, &fwd);
    check_u64("ts: snapshot count", fwd.count, 10);
    (void)bench_ts_snapshot_checksum(db, &count, &payload_bytes);
    check_u64("ts: snapshot count matches", count, 10);
    check_u64("ts: snapshot payload bytes", payload_bytes, 10u * 32u);

    /* timestamps must strictly increase */
    rc = bench_ts_append(db, 11, 1009);
    check_u64("ts: non-increasing timestamp rejected", (uint64_t)rc, (uint64_t)FDB_WRITE_ERR);
    ts_collect(db, 0, &fwd);
    check_u64("ts: rejected append not stored", fwd.count, 10);

    fdb_tsl_clean(db);
    ts_collect(db, 0, &fwd);
    check_u64("ts: clean empties DB", fwd.count, 0);

    for (i = 0; i < 3; i++) {
        rc = bench_ts_append(db, i, (fdb_time_t)(2000 + i));
        if (rc != FDB_NO_ERR) {
            break;
        }
    }
    check_u64("ts: append after clean", (uint64_t)rc, (uint64_t)FDB_NO_ERR);
    fdb_tsdb_deinit(db);
    check_u64("ts: remount", (uint64_t)fdb_tsdb_init(db, "tsdb", BENCH_TS_PART_NAME,
                                                     bench_ts_dummy_time, BENCH_TS_MAX_LOG_LEN, NULL),
              (uint64_t)FDB_NO_ERR);
    ts_collect(db, 0, &fwd);
    check_u64("ts: remount keeps entries", fwd.count, 3);
    check_u64("ts: no NOR set-bit attempts", sim_nor_set_bit_attempts(), 0);
    check_u64("ts: no out-of-bounds flash access", sim_nor_bounds_violations(), 0);
}

static void check_ts_full(void)
{
    static struct fdb_tsdb db_obj;
    fdb_tsdb_t db = &db_obj;
    struct ts_check_ctx fwd, rev;
    uint32_t count, max_count;
    uint64_t payload_bytes;
    uint32_t cs1, cs2;
    fdb_err_t rc;
    uint64_t appended;
    char detail[200];

    (void)bench_ts_setup_format(db);
    max_count = bench_ts_max_blob_count(db);
    check_report(max_count > 0, "ts: fdb_tsl_max_blob_count positive", NULL);

    sim_flash_stats_reset();
    appended = bench_ts_populate_full(db, 4000, &rc);
    check_u64("ts: populate reaches SavedFull", (uint64_t)rc, (uint64_t)FDB_SAVED_FULL);
    check_report(appended > 0, "ts: populated entries > 0", NULL);
    check_u64("ts: populated count matches max_blob_count", appended, max_count);
    sprintf(detail, "populated=%llu max_blob_count=%u writes=%llu erases=%llu",
            (unsigned long long)appended, (unsigned)max_count,
            (unsigned long long)sim_flash_stats_get().writes,
            (unsigned long long)sim_flash_stats_get().erases);
    check_report(1, "ts: populate diagnostics", detail);

    cs1 = bench_ts_snapshot_checksum(db, &count, &payload_bytes);
    check_u64("ts: full DB forward count", count, appended);
    check_u64("ts: full DB payload bytes", payload_bytes, appended * 32u);

    ts_collect(db, 1, &rev);
    check_u64("ts: full DB reverse count", rev.count, appended);

    fdb_tsdb_deinit(db);
    check_u64("ts: remount full DB", (uint64_t)fdb_tsdb_init(db, "tsdb", BENCH_TS_PART_NAME,
                                                            bench_ts_dummy_time, BENCH_TS_MAX_LOG_LEN, NULL),
              (uint64_t)FDB_NO_ERR);
    ts_collect(db, 0, &fwd);
    sprintf(detail, "after remount: fwd=%u oldest=0x%x cur_sec=0x%x (upstream quirk: full no-rollover image)",
            (unsigned)fwd.count, (unsigned)db->parent.oldest_addr, (unsigned)db->cur_sec.addr);
    check_report(1, "ts: remount full-DB diagnostics", detail);

    cs2 = bench_ts_snapshot_checksum(db, &count, &payload_bytes);
    sprintf(detail, "pre=0x%08x post=0x%08x post_count=%u",
            (unsigned)cs1, (unsigned)cs2, (unsigned)count);
    check_report(1, "ts: remount checksum diagnostics", detail);
    check_u64("ts: no NOR set-bit attempts (full DB)", sim_nor_set_bit_attempts(), 0);
    check_u64("ts: no out-of-bounds access (full DB)", sim_nor_bounds_violations(), 0);
}

static void check_ts_rollover(void)
{
    static struct fdb_tsdb db_obj;
    fdb_tsdb_t db = &db_obj;
    struct ts_check_ctx fwd;
    bool ro = true;
    uint64_t cap, n;
    fdb_err_t rc = FDB_NO_ERR;
    uint64_t i;

    (void)bench_ts_setup_format(db);
    cap = bench_ts_max_blob_count(db);
    check_report(cap > 0, "rollover: capacity positive", NULL);

    /* Rollover must be enabled before the DB is full: a full no-rollover DB
     * leaves cur_sector FULL and the next append is rejected by upstream. */
    fdb_tsdb_control(db, FDB_TSDB_CTRL_SET_ROLLOVER, &ro);
    sim_flash_stats_reset();
    n = cap * 2u;
    for (i = 0; i < n; i++) {
        rc = bench_ts_append(db, (uint32_t)i, (fdb_time_t)(100000 + (int)i));
        if (rc != FDB_NO_ERR) {
            break;
        }
    }
    check_u64("rollover: 2 x capacity appends succeed", (uint64_t)rc, (uint64_t)FDB_NO_ERR);
    check_u64("rollover: all appends accepted", i, n);
    check_report(sim_flash_stats_get().erases > 0,
                 "rollover: full sectors erased while rolling", NULL);
    ts_collect(db, 0, &fwd);
    check_u64("rollover: entry count stays at capacity", fwd.count, cap);
    check_u64("rollover: no NOR set-bit attempts", sim_nor_set_bit_attempts(), 0);
    check_u64("rollover: no out-of-bounds access", sim_nor_bounds_violations(), 0);

    fdb_tsdb_deinit(db);
    check_u64("rollover: remount after rollover",
              (uint64_t)fdb_tsdb_init(db, "tsdb", BENCH_TS_PART_NAME, bench_ts_dummy_time,
                                       BENCH_TS_MAX_LOG_LEN, NULL),
              (uint64_t)FDB_NO_ERR);
}

static void check_determinism(void)
{
    static struct fdb_kvdb kv_obj;
    static struct fdb_tsdb ts_obj;
    uint32_t kv_cs1, kv_cs2, ts_cs1, ts_cs2;
    uint32_t count;
    uint64_t bytes;
    uint32_t i;
    struct fdb_blob blob;
    uint8_t val[32];

    bench_kv_setup_format(&kv_obj);
    for (i = 0; i < 64; i++) {
        char key[16];

        bench_key(key, sizeof(key), "kv", i % 8);
        bench_value(val, sizeof(val), BENCH_SEED_KV_SET_SMALL, i);
        (void)fdb_kv_set_blob(&kv_obj, key, fdb_blob_make(&blob, val, sizeof(val)));
    }
    kv_cs1 = bench_kv_snapshot_checksum(&kv_obj, &count, &bytes);
    bench_kv_setup_format(&kv_obj);
    for (i = 0; i < 64; i++) {
        char key[16];

        bench_key(key, sizeof(key), "kv", i % 8);
        bench_value(val, sizeof(val), BENCH_SEED_KV_SET_SMALL, i);
        (void)fdb_kv_set_blob(&kv_obj, key, fdb_blob_make(&blob, val, sizeof(val)));
    }
    kv_cs2 = bench_kv_snapshot_checksum(&kv_obj, &count, &bytes);
    check_u64("det: kv_set_small checksum stable", (uint64_t)(kv_cs1 == kv_cs2), 1);

    (void)bench_ts_setup_format(&ts_obj);
    for (i = 0; i < 100; i++) {
        (void)bench_ts_append(&ts_obj, i, (fdb_time_t)(1000 + i));
    }
    ts_cs1 = bench_ts_snapshot_checksum(&ts_obj, &count, &bytes);
    (void)bench_ts_setup_format(&ts_obj);
    for (i = 0; i < 100; i++) {
        (void)bench_ts_append(&ts_obj, i, (fdb_time_t)(1000 + i));
    }
    ts_cs2 = bench_ts_snapshot_checksum(&ts_obj, &count, &bytes);
    check_u64("det: ts populate checksum stable", (uint64_t)(ts_cs1 == ts_cs2), 1);
}

static int run_checks(void)
{
    printf("== C harness self-check (FDB_WRITE_GRAN=%d, -O2/-Os build as compiled) ==\n",
           (int)FDB_WRITE_GRAN);
    check_failures = 0;
    check_sim_semantics();
    check_kv_basic();
    check_kv_gc();
    check_ts_basic();
    check_ts_full();
    check_ts_rollover();
    check_determinism();
    printf("== %s: %d check(s) failed ==\n", check_failures ? "FAIL" : "OK", check_failures);
    return check_failures ? 1 : 0;
}

/* ================================================================== */
/* probe mode (diagnostics only, not part of the measurement protocol) */
/* ================================================================== */

struct ts_probe_ctx {
    uint32_t count;
    uint64_t bytes;
};

static bool ts_probe_cb(fdb_tsl_t tsl, void *arg)
{
    struct ts_probe_ctx *c = (struct ts_probe_ctx *)arg;

    c->count++;
    c->bytes += (uint64_t)tsl->log_len;
    return false;
}

static void probe_ts(void)
{
    static struct fdb_tsdb db_obj;
    fdb_tsdb_t db = &db_obj;
    struct ts_probe_ctx c;
    struct flash_stats st;
    fdb_err_t rc;
    uint64_t appended;
    uint32_t count, max_count;
    uint64_t payload_bytes, cs;

    printf("\n== TS probe ==\n");
    (void)bench_ts_setup_format(db);
    max_count = bench_ts_max_blob_count(db);
    printf("max_blob_count after format          : %u\n", (unsigned)max_count);

    sim_flash_stats_reset();
    appended = bench_ts_populate_full(db, 4000, &rc);
    st = sim_flash_stats_get();
    printf("populate_to_full                     : appended=%llu rc=%s\n",
           (unsigned long long)appended, bench_err_name(rc));
    printf("  flash writes=%llu write_bytes=%llu erases=%llu erase_bytes=%llu\n",
           (unsigned long long)st.writes, (unsigned long long)st.write_bytes,
           (unsigned long long)st.erases, (unsigned long long)st.erase_bytes);
    printf("  oldest_addr=0x%08x cur_sec=0x%08x last_time=%d\n",
           (unsigned)db->parent.oldest_addr, (unsigned)db->cur_sec.addr, (int)db->last_time);

    cs = bench_ts_snapshot_checksum(db, &count, &payload_bytes);
    printf("  snapshot fwd: count=%u payload_bytes=%llu checksum=0x%016llx\n",
           (unsigned)count, (unsigned long long)payload_bytes,
           (unsigned long long)cs);

    memset(&c, 0, sizeof(c));
    fdb_tsl_iter_reverse(db, ts_probe_cb, &c);
    printf("  snapshot rev: count=%u payload_bytes=%llu\n", (unsigned)c.count,
           (unsigned long long)c.bytes);

    fdb_tsdb_deinit(db);
    rc = fdb_tsdb_init(db, "tsdb", BENCH_TS_PART_NAME, bench_ts_dummy_time,
                       BENCH_TS_MAX_LOG_LEN, NULL);
    printf("remount                              : rc=%s oldest=0x%08x cur_sec=0x%08x last_time=%d\n",
           bench_err_name(rc), (unsigned)db->parent.oldest_addr,
           (unsigned)db->cur_sec.addr, (int)db->last_time);

    cs = bench_ts_snapshot_checksum(db, &count, &payload_bytes);
    printf("  after remount fwd: count=%u payload_bytes=%llu checksum=0x%016llx\n",
           (unsigned)count, (unsigned long long)payload_bytes,
           (unsigned long long)cs);
    memset(&c, 0, sizeof(c));
    fdb_tsl_iter_reverse(db, ts_probe_cb, &c);
    printf("  after remount rev: count=%u payload_bytes=%llu\n", (unsigned)c.count,
           (unsigned long long)c.bytes);

    printf("  query_count(1000,1200,WRITE)=%u\n",
           (unsigned)fdb_tsl_query_count(db, 1000, 1200, FDB_TSL_WRITE));
}

static void probe_kv(void)
{
    static struct fdb_kvdb db_obj;
    fdb_kvdb_t db = &db_obj;
    uint8_t val[32];
    struct fdb_blob blob;
    struct flash_stats st;
    uint32_t i, count;
    uint64_t bytes, cs;
    fdb_err_t rc;

    printf("\n== KV probe ==\n");
    bench_kv_setup_format(db);
    sim_flash_stats_reset();
    for (i = 0; i < 32; i++) {
        char key[32];
        uint64_t vbytes;

        bench_key(key, sizeof(key), "key", i);
        bench_value(val, sizeof(val), BENCH_SEED_KV_HOT, i);
        (void)fdb_kv_set_blob(db, key, fdb_blob_make(&blob, val, sizeof(val)));
        (void)vbytes;
    }
    st = sim_flash_stats_get();
    cs = bench_kv_snapshot_checksum(db, &count, &bytes);
    printf("32 x 32-byte set                     : writes=%llu write_bytes=%llu erases=%llu\n",
           (unsigned long long)st.writes, (unsigned long long)st.write_bytes,
           (unsigned long long)st.erases);
    printf("  snapshot count=%u value_bytes=%llu checksum=0x%016llx\n", (unsigned)count,
           (unsigned long long)bytes, (unsigned long long)cs);

    sim_flash_stats_reset();
    for (i = 0; i < 1000; i++) {
        bench_value(val, sizeof(val), BENCH_SEED_KV_UPDATE, i);
        (void)fdb_kv_set_blob(db, "counter", fdb_blob_make(&blob, val, sizeof(val)));
    }
    st = sim_flash_stats_get();
    printf("1000 x 32-byte counter updates       : writes=%llu write_bytes=%llu erases=%llu erase_bytes=%llu\n",
           (unsigned long long)st.writes, (unsigned long long)st.write_bytes,
           (unsigned long long)st.erases, (unsigned long long)st.erase_bytes);

    rc = fdb_kv_del(db, "does-not-exist");
    printf("delete missing key                   : rc=%s (%d)\n", bench_err_name(rc), (int)rc);
}

/* ================================================================== */
/* main                                                                */
/* ================================================================== */

int main(int argc, char **argv)
{
    const char *mode = "bench";
    const char *out = NULL;
    const char *impl = "c";
    const char *only = NULL;
    int runs = 5;
    int i;
    char version[32];

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            mode = argv[++i];
        } else if (strcmp(argv[i], "--runs") == 0 && i + 1 < argc) {
            runs = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc) {
            out = argv[++i];
        } else if (strcmp(argv[i], "--impl") == 0 && i + 1 < argc) {
            impl = argv[++i];
        } else if (strcmp(argv[i], "--only") == 0 && i + 1 < argc) {
            only = argv[++i];
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (getenv("C_HARNESS_VERBOSE") != NULL) {
        fdb_host_log_enabled = 1;
    }
    sim_flash_global_init();
    if (fal_init() <= 0) {
        bench_fatal("FAL initialization failed (partition table)");
    }
    if (fal_partition_find(BENCH_KV_PART_NAME) == NULL ||
        fal_partition_find(BENCH_TS_PART_NAME) == NULL) {
        bench_fatal("required FAL partitions not found");
    }

    if (strcmp(mode, "check") == 0) {
        return run_checks();
    }
    if (strcmp(mode, "probe") == 0) {
        probe_kv();
        probe_ts();
        return 0;
    }
    if (strcmp(mode, "bench") != 0) {
        fprintf(stderr, "unknown mode '%s'\n", mode);
        usage(argv[0]);
        return 2;
    }

    bench_runs = runs;
    if (only) {
        bench_set_filter(only);
    }

    bench_kv_run_all(runs);
    bench_ts_run_all(runs);

    snprintf(version, sizeof(version), "fdb-%s", FDB_SW_VERSION);
    bench_json_write(stdout, impl, version);

    {
        char path[512];
        FILE *f;

        if (out == NULL) {
            snprintf(path, sizeof(path), DEFAULT_RESULTS_DIR "/c_wg%d_host.json",
                     (int)FDB_WRITE_GRAN);
            out = path;
        }
        f = fopen(out, "w");
        if (f == NULL) {
            fprintf(stderr, "c_harness: cannot open '%s' for writing\n", out);
            return 2;
        }
        bench_json_write(f, impl, version);
        fclose(f);
    }

    return 0;
}
