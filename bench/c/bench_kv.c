/*
 * KVDB scenarios from harness/SCENARIOS.md.
 *
 * Data generation (must match the Rust harness byte-for-byte):
 *   kv_value(seed, i, len): byte[j] = (seed + i*31 + j*7) & 0xFF
 *   seeds: kv_set_small=0x11, kv_update_1k=0x22, kv_get_hot/get_miss/
 *          kv_delete/kv_iterate/kv_mount=0x33 (delete re-sets with 0x33 too),
 *          kv_large=0x44
 *   keys:  "kv%u" for kv_set_small, "key%u" for the populated DB,
 *          "absent%u" for the miss scenario.
 *
 * Setup is always excluded from timing and flash counters. Finish-phase
 * checksums are computed after the timer stopped and after flash counters were
 * snapshotted.
 */

#include <stdio.h>
#include <string.h>

#include "bench.h"

#define KV_HOT_KEYS      32u
#define KV_GET_HOT_OPS   2000u
#define KV_SET_SMALL_OPS 64u
#define KV_UPDATE_OPS    1000u
#define KV_DELETE_REPS   3u

static fdb_kvdb_t kvdb(void)
{
    static struct fdb_kvdb db;

    return &db;
}

static fdb_err_t kv_put(fdb_kvdb_t db, const char *key, const uint8_t *val, size_t len)
{
    struct fdb_blob blob;

    return fdb_kv_set_blob(db, key, fdb_blob_make(&blob, val, len));
}

static void kv_put_or_die(fdb_kvdb_t db, const char *key, const uint8_t *val, size_t len)
{
    fdb_err_t rc = kv_put(db, key, val, len);

    if (rc != FDB_NO_ERR) {
        bench_fatal("setup set('%s') failed: %s", key, bench_err_name(rc));
    }
}

static size_t kv_get(fdb_kvdb_t db, const char *key, uint8_t *buf, size_t cap)
{
    struct fdb_blob blob;

    return fdb_kv_get_blob(db, key, fdb_blob_make(&blob, buf, cap));
}

/* ------------------------------------------------------------------ */
/* shared setups                                                       */
/* ------------------------------------------------------------------ */

void bench_kv_setup_format(fdb_kvdb_t db)
{
    fdb_err_t rc;

    memset(db, 0, sizeof(*db));
    sim_flash_erase_all();
    sim_nor_diag_reset();
    rc = fdb_kvdb_init(db, "kvdb", BENCH_KV_PART_NAME, NULL, NULL);
    if (rc != FDB_NO_ERR) {
        bench_fatal("kvdb format/init failed: %s", bench_err_name(rc));
    }
}

fdb_err_t bench_kv_setup_hot(fdb_kvdb_t db)
{
    char key[32];
    uint8_t val[32];
    uint8_t buf[64];
    uint32_t i;

    bench_kv_setup_format(db);

    for (i = 0; i < KV_HOT_KEYS; i++) {
        bench_key(key, sizeof(key), "key", i);
        bench_value(val, sizeof(val), BENCH_SEED_KV_HOT, i);
        kv_put_or_die(db, key, val, sizeof(val));
    }
    /* warmup 128 x get (protocol: part of setup, excluded from measurement) */
    for (i = 0; i < 128; i++) {
        bench_key(key, sizeof(key), "key", i % KV_HOT_KEYS);
        (void)kv_get(db, key, buf, sizeof(buf));
    }
    return FDB_NO_ERR;
}

/* ------------------------------------------------------------------ */
/* kv_set_small: 64 x set("kv{k%8}", kv_value(0x11, k, 8))             */
/* ------------------------------------------------------------------ */

static void kv_set_small_setup(void *ctx)
{
    (void)ctx;
    bench_kv_setup_format(kvdb());
}

static void kv_set_small_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t i;

    (void)ctx;
    for (i = 0; i < KV_SET_SMALL_OPS; i++) {
        char key[16];
        uint8_t val[8];

        bench_key(key, sizeof(key), "kv", i % 8u);
        bench_value(val, sizeof(val), BENCH_SEED_KV_SET_SMALL, i);
        bench_err_add(kv_put(db, key, val, sizeof(val)));
    }
}

/* ------------------------------------------------------------------ */
/* kv_update_1k: 1000 x set("counter", kv_value(0x22, k, 32))          */
/* ------------------------------------------------------------------ */

static void kv_update_setup(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint8_t val[32];

    (void)ctx;
    bench_kv_setup_format(db);
    bench_value(val, sizeof(val), BENCH_SEED_KV_UPDATE, 0);
    kv_put_or_die(db, "counter", val, sizeof(val));
}

static void kv_update_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t i;

    (void)ctx;
    for (i = 0; i < KV_UPDATE_OPS; i++) {
        uint8_t val[32];

        bench_value(val, sizeof(val), BENCH_SEED_KV_UPDATE, i);
        bench_err_add(kv_put(db, "counter", val, sizeof(val)));
    }
}

/* ------------------------------------------------------------------ */
/* kv_get_hot / kv_get_miss: shared populated setup                    */
/* ------------------------------------------------------------------ */

static void kv_hot_setup(void *ctx)
{
    (void)ctx;
    (void)bench_kv_setup_hot(kvdb());
}

static uint64_t hot_sum_bytes;
static uint64_t hot_hits;

static void kv_get_hot_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t i;

    (void)ctx;
    hot_sum_bytes = 0;
    hot_hits = 0;
    for (i = 0; i < KV_GET_HOT_OPS; i++) {
        char key[32];
        uint8_t buf[64];
        size_t n;

        bench_key(key, sizeof(key), "key", i % KV_HOT_KEYS);
        n = kv_get(db, key, buf, sizeof(buf));
        if (n > 0) {
            hot_hits++;
        }
        hot_sum_bytes += (uint64_t)n;
    }
}

static uint64_t miss_hits;
static uint64_t miss_sum_bytes;

static void kv_get_miss_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t i;

    (void)ctx;
    miss_hits = 0;
    miss_sum_bytes = 0;
    for (i = 0; i < 500; i++) {
        char key[32];
        uint8_t buf[64];
        size_t n;

        bench_key(key, sizeof(key), "absent", i);
        n = kv_get(db, key, buf, sizeof(buf));
        if (n > 0) {
            miss_hits++;
        }
        miss_sum_bytes += (uint64_t)n;
    }
}

/* ------------------------------------------------------------------ */
/* kv_delete: 3 x 32 x {delete(key_i); set(key_i, kv_value(0x33,i,32))} */
/* ------------------------------------------------------------------ */

static uint64_t delete_del_calls;
static uint64_t delete_set_calls;

static void kv_delete_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t rep, i;

    (void)ctx;
    delete_del_calls = 0;
    delete_set_calls = 0;
    for (rep = 0; rep < KV_DELETE_REPS; rep++) {
        for (i = 0; i < KV_HOT_KEYS; i++) {
            char key[32];
            uint8_t val[32];

            bench_key(key, sizeof(key), "key", i);
            bench_err_add(fdb_kv_del(db, key));
            delete_del_calls++;
            bench_value(val, sizeof(val), BENCH_SEED_KV_HOT, i);
            bench_err_add(kv_put(db, key, val, sizeof(val)));
            delete_set_calls++;
        }
    }
}

/* ------------------------------------------------------------------ */
/* kv_iterate: 100 x full iteration (count + sum value_len only)       */
/* ------------------------------------------------------------------ */

static uint32_t iterate_last_count;
static uint64_t iterate_last_sum;

static void kv_iterate_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t t;

    (void)ctx;
    iterate_last_count = 0;
    iterate_last_sum = 0;
    for (t = 0; t < 100; t++) {
        struct fdb_kv_iterator itr;
        uint32_t cnt = 0;
        uint64_t sum = 0;

        fdb_kv_iterator_init(db, &itr);
        while (fdb_kv_iterate(db, &itr)) {
            cnt++;
            sum += (uint64_t)itr.curr_kv.value_len;
        }
        iterate_last_count = cnt;
        iterate_last_sum = sum;
    }
}

/* ------------------------------------------------------------------ */
/* kv_mount: 100 x (deinit + mount)                                    */
/* ------------------------------------------------------------------ */

static uint32_t kv_mount_ok;

static void kv_mount_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t i;

    (void)ctx;
    kv_mount_ok = 0;
    for (i = 0; i < 100; i++) {
        fdb_err_t rc;

        (void)fdb_kvdb_deinit(db);
        rc = fdb_kvdb_init(db, "kvdb", BENCH_KV_PART_NAME, NULL, NULL);
        bench_err_add(rc);
        if (rc == FDB_NO_ERR) {
            kv_mount_ok++;
        }
    }
}

/* ------------------------------------------------------------------ */
/* kv_large: 50 x set("big", kv_value(0x44, k, 1024))                  */
/* ------------------------------------------------------------------ */

static void kv_large_setup(void *ctx)
{
    (void)ctx;
    bench_kv_setup_format(kvdb());
}

static void kv_large_body(void *ctx)
{
    fdb_kvdb_t db = kvdb();
    uint32_t i;

    (void)ctx;
    for (i = 0; i < 50; i++) {
        uint8_t val[1024];

        bench_value(val, sizeof(val), BENCH_SEED_KV_LARGE, i);
        bench_err_add(kv_put(db, "big", val, sizeof(val)));
    }
}

/* ------------------------------------------------------------------ */
/* scenario runners                                                    */
/* ------------------------------------------------------------------ */

static void kv_finish_state(struct scenario_result *r, const char *counter_key)
{
    uint32_t count = 0;
    uint64_t value_bytes = 0;

    r->checksum = bench_kv_snapshot_checksum(kvdb(), &count, &value_bytes);
    extra_u(&r->extra, "entries", count);
    extra_u(&r->extra, "value_bytes", value_bytes);
    if (counter_key) {
        uint8_t expect[32], got[32];
        size_t n = kv_get(kvdb(), counter_key, got, sizeof(got));

        bench_value(expect, sizeof(expect), BENCH_SEED_KV_UPDATE, KV_UPDATE_OPS - 1);
        extra_b(&r->extra, "final_value_len_ok", n == sizeof(got));
        extra_b(&r->extra, "final_value_matches", n == sizeof(got) && memcmp(got, expect, sizeof(got)) == 0);
    }
}

void bench_kv_run_all(int runs)
{
    struct scenario_result *r;

    if (bench_want("kv_set_small")) {
        r = bench_new_result();
        bench_measure(r, "kv_set_small", runs, kv_set_small_setup, kv_set_small_body, NULL);
        kv_finish_state(r, NULL);
        r->hits = 0;
        bench_finish(r, KV_SET_SMALL_OPS);
    }

    if (bench_want("kv_update_1k")) {
        r = bench_new_result();
        bench_measure(r, "kv_update_1k", runs, kv_update_setup, kv_update_body, NULL);
        kv_finish_state(r, "counter");
        extra_u(&r->extra, "gc_sector_erases", r->flash.erases);
        r->hits = 0;
        bench_finish(r, KV_UPDATE_OPS);
    }

    if (bench_want("kv_get_hot")) {
        r = bench_new_result();
        bench_measure(r, "kv_get_hot", runs, kv_hot_setup, kv_get_hot_body, NULL);
        kv_finish_state(r, NULL);
        extra_u(&r->extra, "sum_returned_bytes", hot_sum_bytes);
        r->hits = hot_hits;
        bench_finish(r, KV_GET_HOT_OPS);
    }

    if (bench_want("kv_get_miss")) {
        r = bench_new_result();
        bench_measure(r, "kv_get_miss", runs, kv_hot_setup, kv_get_miss_body, NULL);
        kv_finish_state(r, NULL);
        extra_u(&r->extra, "sum_returned_bytes", miss_sum_bytes);
        r->hits = miss_hits;
        bench_finish(r, 500);
    }

    if (bench_want("kv_delete")) {
        r = bench_new_result();
        bench_measure(r, "kv_delete", runs, kv_hot_setup, kv_delete_body, NULL);
        kv_finish_state(r, NULL);
        extra_u(&r->extra, "del_calls", delete_del_calls);
        extra_u(&r->extra, "set_calls", delete_set_calls);
        r->hits = 0;
        bench_finish(r, delete_del_calls + delete_set_calls);
    }

    if (bench_want("kv_iterate")) {
        r = bench_new_result();
        bench_measure(r, "kv_iterate", runs, kv_hot_setup, kv_iterate_body, NULL);
        kv_finish_state(r, NULL);
        extra_u(&r->extra, "entries_per_iter", iterate_last_count);
        extra_u(&r->extra, "sum_value_len_per_iter", iterate_last_sum);
        r->hits = 0;
        bench_finish(r, 100);
    }

    if (bench_want("kv_mount")) {
        r = bench_new_result();
        bench_measure(r, "kv_mount", runs, kv_hot_setup, kv_mount_body, NULL);
        kv_finish_state(r, NULL);
        extra_u(&r->extra, "mount_ok", kv_mount_ok);
        r->hits = 0;
        bench_finish(r, 100);
    }

    if (bench_want("kv_large")) {
        r = bench_new_result();
        bench_measure(r, "kv_large", runs, kv_large_setup, kv_large_body, NULL);
        kv_finish_state(r, NULL);
        r->hits = 0;
        bench_finish(r, 50);
    }
}
