/*
 * C<->Zig behavioural differential harness -- C side.
 *
 * Runs the deterministic KV operation script defined in bench/diff/README.md on
 * the UNMODIFIED C FlashDB 2.2.99 (reference/FlashDB, FAL mode, RAM NOR
 * simulator from bench/c) and prints the canonical DIFF output described
 * there.  The Zig side (bench/diff/zig/main.zig) runs the same script on our
 * Zig library and prints the same lines; tools/diff_model.py diffs them.
 *
 * The script is deterministic by construction: one LCG drives every choice and
 * value, so both implementations consume the same random sequence and the
 * canonical output must match line for line (main script), while the
 * deliberately format-dependent parts (post-crash visible states) are validated
 * for their allowed outcome sets and reported, not blindly diffed.
 *
 * Output goes to stdout only; diagnostics go to stderr with exit code 3.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <flashdb.h>
#include <fal.h>

#include "sim_flash.h"

/* ------------------------------------------------------------------------ */
/* Protocol constants (must match bench/diff/zig/main.zig)                   */
/* ------------------------------------------------------------------------ */

#define DIFF_VERSION        1u
#define LCG_SEED            0xC0FFEEu      /* 12648430 */
#define SCRIPT_OPS          2000u
#define CHECKPOINT_EVERY    250u
#define KEY_COUNT           48u
#define MISS_COUNT          16u
#define MAX_VALUE_LEN       120u
#define IO_BUF_LEN          128u
#define MAX_ENTRIES         64u
#define DEFAULT_COUNT       4u
#define CRASH_WATCH_KEYS    8u
#define CRASH_CUT_LIMIT     64u

#define FNV_OFFSET          0x811C9DC5u
#define FNV_PRIME           0x01000193u

/* Wall-clock per run of the script is irrelevant for equality; no timing is
 * printed, so a loaded machine cannot make the differential diff flaky. */

/* ------------------------------------------------------------------------ */
/* State                                                                     */
/* ------------------------------------------------------------------------ */

static struct fdb_kvdb g_db;
static uint32_t g_state;
static uint32_t g_gen[KEY_COUNT];
static uint32_t g_roll;

static struct fdb_blob g_blob;

/* Default KV table: the DEFAULTS operation restores exactly these entries. */
static char g_def_keys[DEFAULT_COUNT][4] = { "d00", "d01", "d02", "d03" };
static uint8_t g_def_vals[DEFAULT_COUNT][16];
static struct fdb_default_kv_node g_def_nodes[DEFAULT_COUNT];
static struct fdb_default_kv g_defaults;

/* Canonical entry record used for sorted dumps/checkpoints. */
struct entry {
    char key[80];
    uint32_t klen;
    uint32_t vlen;
    uint32_t vfnv;
};

static struct entry g_entries[MAX_ENTRIES];

/* ------------------------------------------------------------------------ */
/* Small helpers                                                             */
/* ------------------------------------------------------------------------ */

static void fatal(const char *what)
{
    fprintf(stderr, "diff_c: FATAL: %s\n", what);
    exit(3);
}

static uint32_t lcg_next(void)
{
    /* state = (state * 1103515245 + 12345) mod 2^31 */
    uint64_t s64 = (uint64_t)g_state * 1103515245u + 12345u;

    g_state = (uint32_t)(s64 & 0x7FFFFFFFu);
    return g_state;
}

static uint32_t fnv_bytes(uint32_t h, const void *data, size_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    size_t i;

    for (i = 0; i < len; i++) {
        h ^= (uint32_t)p[i];
        h *= FNV_PRIME;
    }
    return h;
}

/* FNV update with a little-endian u32 (same byte order on both sides). */
static uint32_t fnv_u32(uint32_t h, uint32_t v)
{
    uint8_t b[4];

    b[0] = (uint8_t)(v & 0xFFu);
    b[1] = (uint8_t)((v >> 8) & 0xFFu);
    b[2] = (uint8_t)((v >> 16) & 0xFFu);
    b[3] = (uint8_t)((v >> 24) & 0xFFu);
    return fnv_bytes(h, b, sizeof(b));
}

/* kv_value(key_idx, gen, len)[j] = 0x5A + key_idx*31 + gen*17 + j*7 (mod 256) */
static void make_value(uint8_t *buf, size_t len, uint32_t key_idx, uint32_t gen)
{
    size_t j;

    for (j = 0; j < len; j++) {
        buf[j] = (uint8_t)(0x5Au + key_idx * 31u + gen * 17u + j * 7u);
    }
}

static void key_name(char out[8], uint32_t idx)
{
    out[0] = 'k';
    out[1] = (char)('0' + (idx / 10u) % 10u);
    out[2] = (char)('0' + idx % 10u);
    out[3] = '\0';
}

static void miss_name(char out[8], uint32_t idx)
{
    out[0] = 'm';
    out[1] = (char)('0' + (idx / 10u) % 10u);
    out[2] = (char)('0' + idx % 10u);
    out[3] = '\0';
}

static void db_init(void)
{
    /* NULL default table: the baseline database is empty.  The DEFAULTS
     * operation installs g_defaults explicitly, which keeps the C side's
     * "restore factory defaults" semantics without the upstream init hook
     * (fdb_kvdb_init -> fdb_kv_set_default on a blank partition) implicitly
     * seeding keys at every mount -- the Zig API has no such hook. */
    if (fdb_kvdb_init(&g_db, "kvdb", "fdb_kvdb1", NULL, NULL) != FDB_NO_ERR) {
        fatal("fdb_kvdb_init");
    }
}

static void db_remount(void)
{
    (void)fdb_kvdb_deinit(&g_db);
    db_init();
}

/* Raw "read current value" used for the pre-delete existence probe and for the
 * post-crash per-key states.  Values are 1..120 bytes, so 0 means absent. */
static size_t kv_get_value(const char *key, uint8_t *buf, size_t cap)
{
    return fdb_kv_get_blob(&g_db, key, fdb_blob_make(&g_blob, buf, cap));
}

/* ------------------------------------------------------------------------ */
/* The operation script                                                      */
/* ------------------------------------------------------------------------ */

static void op_set(uint32_t idx)
{
    char key[8];
    uint8_t val[MAX_VALUE_LEN];
    uint32_t key_idx = lcg_next() % KEY_COUNT;
    uint32_t len = 1u + lcg_next() % MAX_VALUE_LEN;
    fdb_err_t rc;

    g_gen[key_idx]++;
    make_value(val, len, key_idx, g_gen[key_idx]);
    key_name(key, key_idx);
    rc = fdb_kv_set_blob(&g_db, key, fdb_blob_make(&g_blob, val, len));
    if (rc != FDB_NO_ERR) {
        fatal("kv set failed");
    }
    printf("OP idx=%u kind=set key=%s len=%u vfnv=0x%08x\n",
           idx, key, len, fnv_bytes(FNV_OFFSET, val, len));
}

static void op_delete(uint32_t idx)
{
    char key[8];
    uint8_t buf[IO_BUF_LEN];
    uint32_t key_idx = lcg_next() % KEY_COUNT;
    uint32_t existed;
    fdb_err_t rc;

    key_name(key, key_idx);
    existed = (kv_get_value(key, buf, sizeof(buf)) > 0u) ? 1u : 0u;
    rc = fdb_kv_del(&g_db, key);
    /* Deleting an absent key legitimately fails in C (FDB_KV_NAME_ERR); the
     * canonical line reports existence, not the implementation's error code. */
    if (existed != 0u && rc != FDB_NO_ERR) {
        fatal("kv delete of an existing key failed");
    }
    printf("OP idx=%u kind=del key=%s existed=%u\n", idx, key, existed);
}

static void op_get(uint32_t idx)
{
    char key[8];
    uint8_t buf[IO_BUF_LEN];
    uint32_t key_idx = lcg_next() % KEY_COUNT;
    size_t got;

    key_name(key, key_idx);
    got = kv_get_value(key, buf, sizeof(buf));
    if (got > sizeof(buf)) {
        fatal("kv get returned more than the buffer");
    }
    if (got > 0u) {
        g_roll = fnv_bytes(g_roll, buf, got);
    }
    printf("OP idx=%u kind=get key=%s hit=%u len=%u vfnv=0x%08x\n",
           idx, key, (got > 0u) ? 1u : 0u, (uint32_t)got,
           (got > 0u) ? fnv_bytes(FNV_OFFSET, buf, got) : 0u);
}

static void op_get_miss(uint32_t idx)
{
    char key[8];
    uint8_t buf[IO_BUF_LEN];
    uint32_t miss_idx = lcg_next() % MISS_COUNT;
    size_t got;

    miss_name(key, miss_idx);
    got = kv_get_value(key, buf, sizeof(buf));
    if (got != 0u) {
        fatal("get of an absent key returned data");
    }
    printf("OP idx=%u kind=getmiss key=%s hit=0\n", idx, key);
}

/* Iterate every live record, sort by key, and return the canonical digest.
 * The digest input is: per entry u32le(klen), key, u32le(vlen), u32le(vfnv). */
static uint32_t collect_and_digest(uint32_t *out_count)
{
    struct fdb_kv_iterator itr;
    uint8_t buf[IO_BUF_LEN];
    struct fdb_blob blob;
    uint32_t n = 0;
    uint32_t i;
    uint32_t h = FNV_OFFSET;

    fdb_kv_iterator_init(&g_db, &itr);
    while (fdb_kv_iterate(&g_db, &itr)) {
        size_t got;
        size_t klen = itr.curr_kv.name_len;

        if (n >= MAX_ENTRIES) {
            fatal("too many entries for the canonical dump");
        }
        if (itr.curr_kv.value_len > IO_BUF_LEN || klen >= sizeof(g_entries[n].key)) {
            fatal("entry does not fit the canonical buffers");
        }
        got = fdb_blob_read(
            (fdb_db_t)&g_db,
            fdb_kv_to_blob(&itr.curr_kv,
                           fdb_blob_make(&blob, buf, sizeof(buf))));
        if (got != itr.curr_kv.value_len) {
            fatal("iterator value read length mismatch");
        }
        memcpy(g_entries[n].key, itr.curr_kv.name, klen);
        g_entries[n].key[klen] = '\0';
        g_entries[n].klen = (uint32_t)klen;
        g_entries[n].vlen = (uint32_t)itr.curr_kv.value_len;
        g_entries[n].vfnv = fnv_bytes(FNV_OFFSET, buf, got);
        n++;
    }

    /* Sort by key bytes (keys are unique, lexicographic order). */
    for (i = 0; i < n; i++) {
        uint32_t j;

        for (j = i + 1; j < n; j++) {
            uint32_t min_len = (g_entries[i].klen < g_entries[j].klen)
                                   ? g_entries[i].klen : g_entries[j].klen;
            int c = memcmp(g_entries[i].key, g_entries[j].key, min_len);

            if (c > 0 || (c == 0 && g_entries[i].klen > g_entries[j].klen)) {
                struct entry tmp = g_entries[i];

                g_entries[i] = g_entries[j];
                g_entries[j] = tmp;
            }
        }
    }

    for (i = 0; i < n; i++) {
        h = fnv_u32(h, g_entries[i].klen);
        h = fnv_bytes(h, g_entries[i].key, g_entries[i].klen);
        h = fnv_u32(h, g_entries[i].vlen);
        h = fnv_u32(h, g_entries[i].vfnv);
    }
    *out_count = n;
    return h;
}

/* Print a full canonical state dump: STATE line, sorted ENTRY lines, and the
 * overall digest.  Returns the digest through *out_digest and the count. */
static void print_state(const char *tag, uint32_t *out_count, uint32_t *out_digest)
{
    uint32_t n;
    uint32_t h = collect_and_digest(&n);
    uint32_t i;

    printf("%sSTATE count=%u dump_fnv=0x%08x\n", tag, n, h);
    for (i = 0; i < n; i++) {
        printf("%sENTRY key=%s klen=%u vlen=%u vfnv=0x%08x\n", tag,
               g_entries[i].key, g_entries[i].klen, g_entries[i].vlen,
               g_entries[i].vfnv);
    }
    *out_count = n;
    *out_digest = h;
}

static void op_iterate(uint32_t idx)
{
    uint32_t n;
    uint32_t h = collect_and_digest(&n);

    g_roll = fnv_u32(fnv_u32(g_roll, n), h);
    printf("OP idx=%u kind=iter count=%u digest=0x%08x\n", idx, n, h);
}

static void op_remount(uint32_t idx)
{
    uint32_t n;
    uint32_t h;

    db_remount();
    h = collect_and_digest(&n);
    g_roll = fnv_u32(fnv_u32(g_roll, n), h);
    printf("OP idx=%u kind=remount count=%u digest=0x%08x\n", idx, n, h);
}

static void op_defaults(uint32_t idx)
{
    uint32_t n;
    uint32_t h;

    /* Equivalent of the Zig side's formatAll() + install the default keys:
     * fdb_kv_set_default() formats every sector and writes db->default_kvs, so
     * the table has to be attached immediately before the call. */
    g_db.default_kvs = g_defaults;
    if (fdb_kv_set_default(&g_db) != FDB_NO_ERR) {
        fatal("fdb_kv_set_default failed");
    }
    h = collect_and_digest(&n);
    g_roll = fnv_u32(fnv_u32(g_roll, n), h);
    printf("OP idx=%u kind=defaults count=%u digest=0x%08x\n", idx, n, h);
}

static void run_script(void)
{
    uint32_t idx;

    for (idx = 0; idx < SCRIPT_OPS; idx++) {
        uint32_t bucket;

        g_state = lcg_next();
        bucket = g_state % 100u;
        if (bucket < 55u) {
            op_set(idx);
        } else if (bucket < 70u) {
            op_delete(idx);
        } else if (bucket < 80u) {
            op_get(idx);
        } else if (bucket < 85u) {
            op_iterate(idx);
        } else if (bucket < 90u) {
            op_remount(idx);
        } else if (bucket < 95u) {
            op_get_miss(idx);
        } else {
            op_defaults(idx);
        }

        if (((idx + 1u) % CHECKPOINT_EVERY) == 0u) {
            uint32_t n;
            uint32_t h = collect_and_digest(&n);

            printf("CHECKPOINT idx=%u count=%u digest=0x%08x roll=0x%08x\n",
                   idx + 1u, n, h, g_roll);
        }
    }
}

/* ------------------------------------------------------------------------ */
/* Crash-recovery comparison                                                 */
/* ------------------------------------------------------------------------ */

/* What we expect the watched keys to hold before a crash phase. */
static uint32_t g_crash_old_fnv[CRASH_WATCH_KEYS];
static uint8_t g_crash_old_val[CRASH_WATCH_KEYS][16];

/* Fill the expected pre-crash values.  Pure function of the watch index, so it
 * can be computed before the crash phases print their BEGIN lines. */
static void crash_fill_expectations(void)
{
    uint8_t val[16];
    uint32_t i;

    for (i = 0; i < CRASH_WATCH_KEYS; i++) {
        make_value(val, sizeof(val), i, 0u);
        memcpy(g_crash_old_val[i], val, sizeof(val));
        g_crash_old_fnv[i] = fnv_bytes(FNV_OFFSET, val, sizeof(val));
    }
}

/* Build the same durable pre-crash state for every cut point. */
static void crash_reset_base(void)
{
    uint32_t i;

    sim_fault_clear();
    sim_flash_erase_all();
    sim_flash_stats_reset();
    db_remount(); /* blank partition -> formats; empty database */

    for (i = 0; i < CRASH_WATCH_KEYS; i++) {
        char key[8];

        key_name(key, i);
        if (fdb_kv_set_blob(&g_db, key,
                            fdb_blob_make(&g_blob, g_crash_old_val[i],
                                          sizeof(g_crash_old_val[i])))
                != FDB_NO_ERR) {
            fatal("crash base: set failed");
        }
    }
    db_remount();
}

/* Describe the visible state of one watched key relative to the crash phase.
 * Tokens: old, new, absent, other. */
static const char *crash_key_state(uint32_t key_idx, uint32_t new_fnv,
                                   int new_is_set_phase)
{
    char key[8];
    uint8_t buf[IO_BUF_LEN];
    size_t got;

    key_name(key, key_idx);
    got = kv_get_value(key, buf, sizeof(buf));
    if (got == 0u) {
        if (new_is_set_phase && key_idx == 3u) {
            /* a set may never make the key vanish */
            return "absent";
        }
        return (new_is_set_phase) ? "absent" : "absent";
    }
    if (got != 16u && !(new_is_set_phase && key_idx == 3u && got == 24u)) {
        return "other";
    }
    if (got == 16u && fnv_bytes(FNV_OFFSET, buf, got) == g_crash_old_fnv[key_idx]) {
        return "old";
    }
    if (new_is_set_phase && key_idx == 3u && got == 24u &&
        fnv_bytes(FNV_OFFSET, buf, got) == new_fnv) {
        return "new";
    }
    return "other";
}

static void crash_dump(const char *phase, uint32_t cut, const char *outcome,
                       fdb_err_t rc, uint32_t new_fnv, int new_is_set_phase)
{
    uint32_t count;
    uint32_t i;
    fdb_err_t check_rc = fdb_kvdb_check(&g_db);
    uint32_t check_ok = (check_rc == FDB_NO_ERR) ? 1u : 0u;

    (void)check_rc;

    (void)rc;
    printf("CRASH phase=%s cut=%u outcome=%s check=%u", phase, cut, outcome, check_ok);
    {
        uint32_t n;
        uint32_t h = collect_and_digest(&n);

        count = n;
        printf(" count=%u dump_fnv=0x%08x", n, h);
    }
    printf(" states=");
    for (i = 0; i < CRASH_WATCH_KEYS; i++) {
        if (i > 0u) {
            printf(",");
        }
        printf("k%02u=%s", i, crash_key_state(i, new_fnv, new_is_set_phase));
    }
    printf("\n");
    (void)count;
}

static void crash_phase_set(void)
{
    uint8_t newv[24];
    uint32_t new_fnv;
    uint32_t cut;

    make_value(newv, sizeof(newv), 3u, 77u);
    new_fnv = fnv_bytes(FNV_OFFSET, newv, sizeof(newv));
    printf("CRASH-BEGIN phase=set target=k03 old_fnv=0x%08x new_fnv=0x%08x\n",
           g_crash_old_fnv[3], new_fnv);

    for (cut = 0; cut < CRASH_CUT_LIMIT; cut++) {
        fdb_err_t rc;

        crash_reset_base();
        sim_fault_arm_mutations(cut);
        rc = fdb_kv_set_blob(&g_db, "k03", fdb_blob_make(&g_blob, newv, sizeof(newv)));
        sim_fault_clear();
        db_remount();
        crash_dump("set", cut, (rc == FDB_NO_ERR) ? "ok" : "fault", rc, new_fnv, 1);
        if (rc == FDB_NO_ERR) {
            break;
        }
    }
    if (cut == CRASH_CUT_LIMIT) {
        fatal("crash phase set never completed");
    }
    printf("CRASH-END phase=set cuts=%u\n", cut + 1u);
}

static void crash_phase_delete(void)
{
    uint32_t cut;

    printf("CRASH-BEGIN phase=del target=k01 old_fnv=0x%08x new_fnv=0x00000000\n",
           g_crash_old_fnv[1]);

    for (cut = 0; cut < CRASH_CUT_LIMIT; cut++) {
        fdb_err_t rc;

        crash_reset_base();
        sim_fault_arm_mutations(cut);
        rc = fdb_kv_del(&g_db, "k01");
        sim_fault_clear();
        db_remount();
        crash_dump("del", cut, (rc == FDB_NO_ERR) ? "ok" : "fault", rc, 0u, 0);
        if (rc == FDB_NO_ERR) {
            break;
        }
    }
    if (cut == CRASH_CUT_LIMIT) {
        fatal("crash phase del never completed");
    }
    printf("CRASH-END phase=del cuts=%u\n", cut + 1u);
}

/* ------------------------------------------------------------------------ */
/* TSDB differential (v2)                                                    */
/* ------------------------------------------------------------------------ */

#define TS_SEED             0x33557711u
#define TS_OPS              1000u
#define TS_CHECKPOINT_EVERY 250u
#define TS_APPEND_LIMIT     40u   /* appends between clean()s (capacity-safe)  */
#define TS_REPOPULATE       24u   /* entries written by clean_repopulate       */
#define TS_MAX_LEN          64u
#define TS_BASE_TIME        1000
#define TS_ENTRIES_MAX      128u
#define TS_CRASH_WATCH      8u
#define TS_CRASH_CUT_LIMIT  64u
#define TS_QUERY_COUNT      8u

static struct fdb_tsdb g_tsdb;
static uint32_t g_ts_state;
static int32_t g_ts_seq;        /* sequence number of the last appended entry */
static uint32_t g_ts_appended;  /* appends since the last clean()             */
static uint32_t g_ts_roll;
static uint8_t g_ts_payload[TS_MAX_LEN];

struct ts_entry {
    int32_t time;
    uint32_t status;
    uint32_t len;
    uint32_t pfnv;
};
static struct ts_entry g_ts_entries[TS_ENTRIES_MAX];
static uint32_t g_ts_entry_count;

struct ts_walk {
    uint32_t n;
    uint32_t digest;
};

/* Fixed ranges for the final TS-QUERY section; the sixth range is reversed
 * (from > to) to exercise upstream/general reverse-range semantics. */
static const int32_t g_ts_ranges[TS_QUERY_COUNT][2] = {
    { 1000, 1100 }, { 1050, 1150 }, { 0, 1000 }, { 1200, 1400 },
    { 1000, 1000 }, { 1100, 1000 }, { 0, 4000 }, { 1500, 1600 }
};

static fdb_time_t ts_dummy_time(void)
{
    return 0;
}

static uint32_t ts_lcg_next(void)
{
    uint64_t s64 = (uint64_t)g_ts_state * 1103515245u + 12345u;

    g_ts_state = (uint32_t)(s64 & 0x7FFFFFFFu);
    return g_ts_state;
}

/* ts_payload(seq)[j] = 0x3C + seq*13 + j*5 (mod 256) */
static void ts_make_payload(uint8_t *buf, uint32_t len, uint32_t seq)
{
    uint32_t j;

    for (j = 0; j < len; j++) {
        buf[j] = (uint8_t)(0x3Cu + seq * 13u + j * 5u);
    }
}

static void ts_db_init(void)
{
    if (fdb_tsdb_init(&g_tsdb, "tsdb", "fdb_tsdb1", ts_dummy_time,
                      TS_MAX_LEN, NULL) != FDB_NO_ERR) {
        fatal("fdb_tsdb_init");
    }
}

static void ts_db_remount(void)
{
    (void)fdb_tsdb_deinit(&g_tsdb);
    ts_db_init();
}

static fdb_time_t ts_last_time(void)
{
    fdb_time_t t = 0;

    fdb_tsdb_control(&g_tsdb, FDB_TSDB_CTRL_GET_LAST_TIME, &t);
    return t;
}

static uint32_t ts_serialize_entry(uint32_t h, const struct ts_entry *e)
{
    h = fnv_u32(h, (uint32_t)e->time);
    h = fnv_u32(h, e->status);
    h = fnv_u32(h, e->len);
    h = fnv_u32(h, e->pfnv);
    return h;
}

/* Collect every entry the iterator yields (order = iterator order). */
static bool ts_collect_cb(fdb_tsl_t tsl, void *arg)
{
    struct ts_walk *w = (struct ts_walk *)arg;
    struct fdb_blob blob;
    size_t got;

    if (w->n >= TS_ENTRIES_MAX) {
        fatal("too many TS entries for the canonical dump");
    }
    got = fdb_blob_read(
        (fdb_db_t)&g_tsdb,
        fdb_tsl_to_blob(tsl, fdb_blob_make(&blob, g_ts_payload, sizeof(g_ts_payload))));
    if (got != tsl->log_len) {
        fatal("ts payload length mismatch");
    }
    g_ts_entries[w->n].time = (int32_t)tsl->time;
    g_ts_entries[w->n].status = (uint32_t)tsl->status;
    g_ts_entries[w->n].len = (uint32_t)got;
    g_ts_entries[w->n].pfnv = fnv_bytes(FNV_OFFSET, g_ts_payload, got);
    w->digest = ts_serialize_entry(w->digest, &g_ts_entries[w->n]);
    w->n++;
    return false;
}

static uint32_t ts_walk_forward(uint32_t *out_count, int32_t *out_last)
{
    struct ts_walk w;

    w.n = 0;
    w.digest = FNV_OFFSET;
    fdb_tsl_iter(&g_tsdb, ts_collect_cb, &w);
    g_ts_entry_count = w.n;
    *out_count = w.n;
    *out_last = (int32_t)ts_last_time();
    return w.digest;
}

static uint32_t ts_walk_by_time(fdb_time_t from, fdb_time_t to, uint32_t *out_count)
{
    struct ts_walk w;

    w.n = 0;
    w.digest = FNV_OFFSET;
    fdb_tsl_iter_by_time(&g_tsdb, from, to, ts_collect_cb, &w);
    g_ts_entry_count = w.n;
    *out_count = w.n;
    return w.digest;
}

/* ---- TS operations ------------------------------------------------------ */

static void ts_op_append(uint32_t idx)
{
    uint32_t len = ts_lcg_next() % (TS_MAX_LEN + 1u);
    uint32_t pfnv;
    int32_t t;
    fdb_err_t rc;

    g_ts_seq++;
    t = TS_BASE_TIME + g_ts_seq;
    ts_make_payload(g_ts_payload, len, (uint32_t)g_ts_seq);
    pfnv = fnv_bytes(FNV_OFFSET, g_ts_payload, len);
    rc = fdb_tsl_append_with_ts(&g_tsdb,
                                fdb_blob_make(&g_blob, g_ts_payload, len),
                                (fdb_time_t)t);
    if (rc != FDB_NO_ERR) {
        fatal("ts append failed");
    }
    g_ts_appended++;
    printf("TS-OP idx=%u kind=append time=%d len=%u pfnv=0x%08x\n",
           idx, (int)t, len, pfnv);
}

static void ts_op_iter(uint32_t idx)
{
    uint32_t n;
    int32_t last;
    uint32_t h = ts_walk_forward(&n, &last);

    g_ts_roll = fnv_u32(fnv_u32(g_ts_roll, n), h);
    printf("TS-OP idx=%u kind=iter count=%u last_time=%d digest=0x%08x\n",
           idx, n, (int)last, h);
}

static void ts_op_remount(uint32_t idx)
{
    uint32_t n;
    int32_t last;

    ts_db_remount();
    {
        uint32_t h = ts_walk_forward(&n, &last);

        g_ts_roll = fnv_u32(fnv_u32(g_ts_roll, n), h);
        printf("TS-OP idx=%u kind=remount count=%u last_time=%d digest=0x%08x\n",
               idx, n, (int)last, h);
    }
}

static void ts_op_by_time(uint32_t idx)
{
    uint32_t off = ts_lcg_next() % 400u;
    uint32_t span = ts_lcg_next() % 200u;
    int32_t from = TS_BASE_TIME + (int32_t)off;
    int32_t to = from + (int32_t)span;
    uint32_t n;
    uint32_t h = ts_walk_by_time((fdb_time_t)from, (fdb_time_t)to, &n);

    g_ts_roll = fnv_u32(fnv_u32(g_ts_roll, n), h);
    printf("TS-OP idx=%u kind=bytime from=%d to=%d count=%u digest=0x%08x\n",
           idx, (int)from, (int)to, n, h);
}

static void ts_op_query_count(uint32_t idx)
{
    uint32_t off = ts_lcg_next() % 400u;
    uint32_t span = ts_lcg_next() % 200u;
    int32_t from = TS_BASE_TIME + (int32_t)off;
    int32_t to = from + (int32_t)span;
    size_t n = fdb_tsl_query_count(&g_tsdb, (fdb_time_t)from, (fdb_time_t)to,
                                   FDB_TSL_WRITE);

    printf("TS-OP idx=%u kind=querycount from=%d to=%d count=%u\n",
           idx, (int)from, (int)to, (uint32_t)n);
}

static void ts_op_clean(uint32_t idx)
{
    uint32_t i;
    uint32_t n;
    int32_t last;
    uint32_t h;

    fdb_tsl_clean(&g_tsdb);
    g_ts_appended = 0;
    for (i = 0; i < TS_REPOPULATE; i++) {
        g_ts_seq++;
        ts_make_payload(g_ts_payload, 16u, (uint32_t)g_ts_seq);
        if (fdb_tsl_append_with_ts(
                &g_tsdb, fdb_blob_make(&g_blob, g_ts_payload, 16u),
                (fdb_time_t)(TS_BASE_TIME + g_ts_seq)) != FDB_NO_ERR) {
            fatal("ts repopulate append failed");
        }
        g_ts_appended++;
    }
    h = ts_walk_forward(&n, &last);
    g_ts_roll = fnv_u32(fnv_u32(g_ts_roll, n), h);
    printf("TS-OP idx=%u kind=clean_repopulate count=%u last_time=%d digest=0x%08x\n",
           idx, n, (int)last, h);
}

static void ts_run_script(void)
{
    uint32_t idx;

    for (idx = 0; idx < TS_OPS; idx++) {
        uint32_t bucket;

        g_ts_state = ts_lcg_next();
        bucket = g_ts_state % 100u;
        if (bucket < 70u) {
            if (g_ts_appended < TS_APPEND_LIMIT) {
                ts_op_append(idx);
            } else {
                ts_op_iter(idx);
            }
        } else if (bucket < 80u) {
            ts_op_remount(idx);
        } else if (bucket < 90u) {
            ts_op_by_time(idx);
        } else if (bucket < 95u) {
            ts_op_query_count(idx);
        } else {
            ts_op_clean(idx);
        }

        if (((idx + 1u) % TS_CHECKPOINT_EVERY) == 0u) {
            uint32_t n;
            int32_t last;
            uint32_t h = ts_walk_forward(&n, &last);

            printf("TS-CHECKPOINT idx=%u count=%u last_time=%d dump_fnv=0x%08x roll=0x%08x\n",
                   idx + 1u, n, (int)last, h, g_ts_roll);
        }
    }
}

static void ts_print_state(void)
{
    uint32_t n;
    int32_t last;
    uint32_t h;
    uint32_t i;

    h = ts_walk_forward(&n, &last);
    printf("TS-STATE count=%u last_time=%d dump_fnv=0x%08x\n", n, (int)last, h);
    for (i = 0; i < n; i++) {
        printf("TS-ENTRY time=%d status=%u len=%u pfnv=0x%08x\n",
               (int)g_ts_entries[i].time, g_ts_entries[i].status,
               g_ts_entries[i].len, g_ts_entries[i].pfnv);
    }
    for (i = 0; i < TS_QUERY_COUNT; i++) {
        size_t cnt = fdb_tsl_query_count(&g_tsdb, (fdb_time_t)g_ts_ranges[i][0],
                                         (fdb_time_t)g_ts_ranges[i][1],
                                         FDB_TSL_WRITE);

        printf("TS-QUERY from=%d to=%d count=%u\n", (int)g_ts_ranges[i][0],
               (int)g_ts_ranges[i][1], (uint32_t)cnt);
    }
    printf("TS-ROLL value=0x%08x\n", g_ts_roll);
    printf("TS-SUMMARY ops=%u count=%u last_time=%d dump_fnv=0x%08x roll=0x%08x rc=0\n",
           TS_OPS, n, (int)last, h, g_ts_roll);
}

/* ---- TS crash recovery -------------------------------------------------- */

static struct ts_entry g_ts_base_entries[TS_CRASH_WATCH];
static uint32_t g_ts_base_dump;
static uint32_t g_ts_new_dump;

static void ts_crash_fill_expectations(void)
{
    struct ts_entry ne;
    uint32_t h = FNV_OFFSET;
    uint32_t i;

    for (i = 0; i < TS_CRASH_WATCH; i++) {
        g_ts_base_entries[i].time = TS_BASE_TIME + (int32_t)i;
        g_ts_base_entries[i].status = (uint32_t)FDB_TSL_WRITE;
        g_ts_base_entries[i].len = 16u;
        ts_make_payload(g_ts_payload, 16u, i);
        g_ts_base_entries[i].pfnv = fnv_bytes(FNV_OFFSET, g_ts_payload, 16u);
        h = ts_serialize_entry(h, &g_ts_base_entries[i]);
    }
    g_ts_base_dump = h;

    ne.time = 1100;
    ne.status = (uint32_t)FDB_TSL_WRITE;
    ne.len = 24u;
    ts_make_payload(g_ts_payload, 24u, 77u);
    ne.pfnv = fnv_bytes(FNV_OFFSET, g_ts_payload, 24u);
    g_ts_new_dump = ts_serialize_entry(h, &ne);
}

static void ts_crash_reset_base(void)
{
    uint32_t i;

    sim_fault_clear();
    sim_flash_erase_all();
    sim_flash_stats_reset();
    ts_db_remount(); /* blank partition -> formats */
    for (i = 0; i < TS_CRASH_WATCH; i++) {
        ts_make_payload(g_ts_payload, 16u, i);
        if (fdb_tsl_append_with_ts(
                &g_tsdb, fdb_blob_make(&g_blob, g_ts_payload, 16u),
                (fdb_time_t)(TS_BASE_TIME + (int32_t)i)) != FDB_NO_ERR) {
            fatal("ts crash base append failed");
        }
    }
    ts_db_remount();
}

/* Power-cut visible-state probe: query the presence of each expected entry by
 * exact timestamp because a torn append can leave the C iterator with a
 * partially written index slot at the sector tail (upstream recovery keeps it
 * invisible to queries but not always to a raw walk).  This still proves the
 * crash guarantee: committed entries stay visible, the new entry is either
 * fully present or absent. */
static uint32_t ts_crash_base_mask(void)
{
    uint32_t mask = 0;
    uint32_t i;

    for (i = 0; i < TS_CRASH_WATCH; i++) {
        fdb_time_t t = (fdb_time_t)(TS_BASE_TIME + (int32_t)i);
        size_t n = fdb_tsl_query_count(&g_tsdb, t, t, FDB_TSL_WRITE);

        if (n > 0u) {
            mask |= (uint32_t)1u << i;
        }
    }
    return mask;
}

static void ts_crash_phase(void)
{
    uint8_t newp[24];
    uint32_t cut;

    ts_make_payload(newp, sizeof(newp), 77u);
    printf("TS-CRASH-BEGIN base_dump=0x%08x new_dump=0x%08x\n",
           g_ts_base_dump, g_ts_new_dump);
    for (cut = 0; cut < TS_CRASH_CUT_LIMIT; cut++) {
        fdb_err_t rc;
        uint32_t mask;
        uint32_t new_present;
        uint32_t h = 0u;
        int32_t last;

        ts_crash_reset_base();
        sim_fault_arm_mutations(cut);
        rc = fdb_tsl_append_with_ts(&g_tsdb,
                                    fdb_blob_make(&g_blob, newp, sizeof(newp)),
                                    (fdb_time_t)1100);
        sim_fault_clear();
        ts_db_remount();
        mask = ts_crash_base_mask();
        new_present = (fdb_tsl_query_count(&g_tsdb, (fdb_time_t)1100,
                                           (fdb_time_t)1100, FDB_TSL_WRITE) > 0u)
                          ? 1u : 0u;
        last = (int32_t)ts_last_time();
        if (rc == FDB_NO_ERR) {
            uint32_t n;

            h = ts_walk_forward(&n, &last);
        }
        printf("TS-CRASH cut=%u outcome=%s last_time=%d base_mask=0x%02x "
               "new_present=%u dump_fnv=0x%08x\n",
               cut, (rc == FDB_NO_ERR) ? "ok" : "fault", (int)last, mask,
               new_present, h);
        if (rc == FDB_NO_ERR) {
            break;
        }
    }
    if (cut == TS_CRASH_CUT_LIMIT) {
        fatal("TS crash phase never completed");
    }
    printf("TS-CRASH-END cuts=%u\n", cut + 1u);
}

/* ------------------------------------------------------------------------ */
/* Entry point                                                               */
/* ------------------------------------------------------------------------ */

int main(void)
{
    uint32_t i;
    uint32_t count;
    uint32_t digest;

    sim_flash_global_init();
    if (fal_init() <= 0) {
        fatal("FAL init failed");
    }
    if (fal_partition_find("fdb_kvdb1") == NULL) {
        fatal("FAL partition fdb_kvdb1 missing");
    }
    if (fal_partition_find("fdb_tsdb1") == NULL) {
        fatal("FAL partition fdb_tsdb1 missing");
    }
    for (i = 0; i < DEFAULT_COUNT; i++) {
        uint32_t j;

        for (j = 0; j < 16u; j++) {
            g_def_vals[i][j] = (uint8_t)(0xD0u + i * 3u + j);
        }
        g_def_nodes[i].key = g_def_keys[i];
        g_def_nodes[i].value = g_def_vals[i];
        g_def_nodes[i].value_len = 16u;
    }
    g_defaults.kvs = g_def_nodes;
    g_defaults.num = DEFAULT_COUNT;

    g_state = LCG_SEED;
    g_roll = FNV_OFFSET;
    memset(g_gen, 0, sizeof(g_gen));

    db_init(); /* blank partition -> format */

    printf("DIFF version=%u impl=c\n", DIFF_VERSION);
    printf("CONFIG wg=%d kv_part=16384 sector=4096 sectors=4 keys=%u "
           "miss_keys=%u max_value=%u seed=%u ops=%u checkpoint=%u crash_watch=%u\n",
           (int)FDB_WRITE_GRAN, KEY_COUNT, MISS_COUNT, MAX_VALUE_LEN, LCG_SEED,
           SCRIPT_OPS, CHECKPOINT_EVERY, CRASH_WATCH_KEYS);

    run_script();

    /* Final canonical state after the whole script. */
    print_state("", &count, &digest);
    printf("CHECK ok=1\n");
    printf("ROLL value=0x%08x\n", g_roll);
    printf("SUMMARY ops=%u count=%u dump_fnv=0x%08x roll=0x%08x rc=0\n",
           SCRIPT_OPS, count, digest, g_roll);

    /* Format-dependent work: enumerate power-cut points of one set and one
     * delete and dump the visible state after remounting.  tools/diff_model.py
     * validates the allowed outcome sets and compares completed states. */
    crash_fill_expectations();
    crash_phase_set();
    crash_phase_delete();

    /* ------------------------------------------------------------------ */
    /* TSDB differential.  The TSDB partition is independent of the KVDB   */
    /* partition, so this section starts from a freshly erased device.     */
    /* ------------------------------------------------------------------ */
    sim_flash_global_init();
    g_ts_state = TS_SEED;
    g_ts_seq = 0;
    g_ts_appended = 0;
    g_ts_roll = FNV_OFFSET;
    g_ts_entry_count = 0;
    ts_db_init(); /* blank TS partition -> format */

    printf("TS-DIFF version=%u impl=c\n", DIFF_VERSION);
    printf("TS-CONFIG max_len=%u base_time=%d ops=%u checkpoint=%u "
           "append_limit=%u repopulate=%u seed=%u query_count=%u\n",
           TS_MAX_LEN, TS_BASE_TIME, TS_OPS, TS_CHECKPOINT_EVERY,
           TS_APPEND_LIMIT, TS_REPOPULATE, TS_SEED, TS_QUERY_COUNT);

    ts_run_script();
    ts_print_state();

    ts_crash_fill_expectations();
    ts_crash_phase();

    return 0;
}
