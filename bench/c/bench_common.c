/*
 * Common benchmark machinery: timing, FNV-1a-32 checksums, snapshot helpers,
 * measured-phase flash/error accounting, scenario list and JSON emission.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "bench.h"

#ifndef BENCH_OPT
#define BENCH_OPT unknown
#endif
#ifndef BENCH_BUILD_FLAGS
#define BENCH_BUILD_FLAGS "unknown"
#endif
#ifndef BENCH_HOST
#define BENCH_HOST "unknown"
#endif

#define BENCH_STR2(x) #x
#define BENCH_STR(x) BENCH_STR2(x)

int bench_runs = 5;
struct err_counts bench_errs;

static struct scenario_result results[BENCH_MAX_SCENARIOS];
static int result_count;
static const char *scenario_filter;

/* ------------------------------------------------------------------ */
/* data generation                                                     */
/* ------------------------------------------------------------------ */

void bench_value(uint8_t *buf, size_t len, uint32_t pattern_seed, uint32_t i)
{
    size_t j;

    for (j = 0; j < len; j++) {
        buf[j] = (uint8_t)(pattern_seed + i * 31u + j * 7u);
    }
}

void bench_ts_payload(uint8_t *buf, size_t len, uint32_t i)
{
    size_t j;

    for (j = 0; j < len; j++) {
        buf[j] = (uint8_t)(BENCH_TS_SEED + i * 13u + j * 5u);
    }
}

const char *bench_key(char *out, size_t cap, const char *prefix, uint32_t i)
{
    snprintf(out, cap, "%s%u", prefix, (unsigned)i);
    return out;
}

/* ------------------------------------------------------------------ */
/* checksums (FNV-1a 32)                                               */
/* ------------------------------------------------------------------ */

uint32_t bench_cs_bytes(uint32_t h, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t i;

    for (i = 0; i < len; i++) {
        h ^= (uint32_t)p[i];
        h *= BENCH_FNV32_PRIME;
    }
    return h;
}

uint32_t bench_cs_u32(uint32_t h, uint32_t v)
{
    uint8_t b[4];

    b[0] = (uint8_t)(v & 0xFF);
    b[1] = (uint8_t)((v >> 8) & 0xFF);
    b[2] = (uint8_t)((v >> 16) & 0xFF);
    b[3] = (uint8_t)((v >> 24) & 0xFF);
    return bench_cs_bytes(h, b, sizeof(b));
}

struct kv_entry {
    char key[FDB_KV_NAME_MAX + 1];
    uint8_t *val;
    size_t vlen;
};

static int kv_entry_cmp(const void *a, const void *b)
{
    const struct kv_entry *ea = (const struct kv_entry *)a;
    const struct kv_entry *eb = (const struct kv_entry *)b;

    return strcmp(ea->key, eb->key);
}

uint32_t bench_kv_snapshot_checksum(fdb_kvdb_t db, uint32_t *out_count,
                                    uint64_t *out_value_bytes)
{
    struct fdb_kv_iterator itr;
    struct kv_entry *ents = NULL;
    uint32_t count = 0, i;
    uint64_t value_bytes = 0;
    uint32_t h = BENCH_FNV32_OFFSET;

    fdb_kv_iterator_init(db, &itr);
    while (fdb_kv_iterate(db, &itr)) {
        count++;
        value_bytes += itr.curr_kv.value_len;
    }

    if (count > 0) {
        ents = (struct kv_entry *)calloc(count, sizeof(*ents));
        if (ents == NULL) {
            bench_fatal("out of memory in kv snapshot");
        }
    }

    i = 0;
    fdb_kv_iterator_init(db, &itr);
    while (fdb_kv_iterate(db, &itr) && i < count) {
        struct fdb_blob blob;
        size_t vlen = itr.curr_kv.value_len;
        size_t got;

        memcpy(ents[i].key, itr.curr_kv.name, sizeof(ents[i].key));
        ents[i].key[FDB_KV_NAME_MAX] = '\0';
        ents[i].vlen = vlen;
        ents[i].val = vlen ? (uint8_t *)malloc(vlen) : NULL;
        if (vlen && ents[i].val == NULL) {
            bench_fatal("out of memory in kv snapshot value");
        }
        fdb_blob_make(&blob, ents[i].val, vlen);
        got = fdb_kv_get_blob(db, ents[i].key, &blob);
        if (got != vlen) {
            bench_fatal("kv snapshot: get('%s') returned %zu, expected %zu",
                        ents[i].key, got, vlen);
        }
        i++;
    }

    if (i != count) {
        bench_fatal("kv snapshot: iterator count changed (%u vs %u)", i, count);
    }

    if (count > 1) {
        qsort(ents, count, sizeof(*ents), kv_entry_cmp);
    }

    h = bench_cs_u32(h, count);
    for (i = 0; i < count; i++) {
        h = bench_cs_u32(h, (uint32_t)strlen(ents[i].key));
        h = bench_cs_bytes(h, ents[i].key, strlen(ents[i].key));
        h = bench_cs_u32(h, (uint32_t)ents[i].vlen);
        h = bench_cs_bytes(h, ents[i].val, ents[i].vlen);
    }

    for (i = 0; i < count; i++) {
        free(ents[i].val);
    }
    free(ents);

    if (out_count) {
        *out_count = count;
    }
    if (out_value_bytes) {
        *out_value_bytes = value_bytes;
    }
    return h;
}

struct ts_snap {
    fdb_tsdb_t db;
    uint32_t h;
    uint32_t count;
    uint64_t payload_bytes;
    uint8_t buf[512];
};

static bool ts_snap_cb(fdb_tsl_t tsl, void *arg)
{
    struct ts_snap *s = (struct ts_snap *)arg;
    struct fdb_blob blob;
    size_t len = tsl->log_len;

    if (len > sizeof(s->buf)) {
        bench_fatal("ts snapshot: log_len %zu exceeds snapshot buffer", len);
    }
    fdb_blob_make(&blob, s->buf, len);
    fdb_tsl_to_blob(tsl, &blob);
    if (fdb_blob_read((fdb_db_t)s->db, &blob) != len) {
        bench_fatal("ts snapshot: short read of log payload");
    }
    s->h = bench_cs_u32(s->h, (uint32_t)tsl->status);
    s->h = bench_cs_u32(s->h, (uint32_t)tsl->time);
    s->h = bench_cs_u32(s->h, (uint32_t)len);
    s->h = bench_cs_bytes(s->h, s->buf, len);
    s->count++;
    s->payload_bytes += len;
    return false;
}

uint32_t bench_ts_snapshot_checksum(fdb_tsdb_t db, uint32_t *out_count,
                                    uint64_t *out_payload_bytes)
{
    struct ts_snap s;

    memset(&s, 0, sizeof(s));
    s.db = db;
    s.h = BENCH_FNV32_OFFSET;
    fdb_tsl_iter(db, ts_snap_cb, &s);
    s.h = bench_cs_u32(s.h, s.count);
    if (out_count) {
        *out_count = s.count;
    }
    if (out_payload_bytes) {
        *out_payload_bytes = s.payload_bytes;
    }
    return s.h;
}

/* ------------------------------------------------------------------ */
/* timing / measuring                                                  */
/* ------------------------------------------------------------------ */

int64_t bench_now_ns(void)
{
    struct timespec ts;

    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        bench_fatal("clock_gettime(CLOCK_MONOTONIC) failed");
    }
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

static int64_t median_of(int64_t *values, int n)
{
    int64_t tmp[BENCH_MAX_RUNS];
    int i, j;

    memcpy(tmp, values, (size_t)n * sizeof(tmp[0]));
    for (i = 1; i < n; i++) {
        int64_t v = tmp[i];
        for (j = i - 1; j >= 0 && tmp[j] > v; j--) {
            tmp[j + 1] = tmp[j];
        }
        tmp[j + 1] = v;
    }
    if (n % 2 == 1) {
        return tmp[n / 2];
    }
    return (tmp[n / 2 - 1] + tmp[n / 2]) / 2;
}

void bench_measure_ex(struct scenario_result *r, const char *name, int runs,
                      bench_fn setup, bench_fn after_setup, bench_fn body, void *ctx)
{
    struct flash_stats first_flash, last_flash;
    struct err_counts first_errs, last_errs;
    int i;

    if (runs < 1) {
        runs = 1;
    }
    if (runs > BENCH_MAX_RUNS) {
        runs = BENCH_MAX_RUNS;
    }
    memset(r, 0, sizeof(*r));
    r->name = name;
    r->runs = runs;
    r->flash_consistent = 1;
    r->errs_consistent = 1;

    for (i = 0; i < runs; i++) {
        int64_t t0, t1;

        if (setup) {
            setup(ctx);
        }
        if (after_setup) {
            after_setup(ctx);
        }
        memset(&bench_errs, 0, sizeof(bench_errs));
        sim_flash_stats_reset();

        t0 = bench_now_ns();
        body(ctx);
        t1 = bench_now_ns();

        r->samples_ns[i] = t1 - t0;
        last_flash = sim_flash_stats_get();
        last_errs = bench_errs;
        if (i == 0) {
            first_flash = last_flash;
            first_errs = last_errs;
        } else {
            if (memcmp(&first_flash, &last_flash, sizeof(first_flash)) != 0) {
                r->flash_consistent = 0;
            }
            if (memcmp(&first_errs, &last_errs, sizeof(first_errs)) != 0) {
                r->errs_consistent = 0;
            }
        }
    }

    r->flash = last_flash;
    r->errs = last_errs;
    r->total_ns_median = median_of(r->samples_ns, runs);
}

void bench_measure(struct scenario_result *r, const char *name, int runs,
                   bench_fn setup, bench_fn body, void *ctx)
{
    bench_measure_ex(r, name, runs, setup, NULL, body, ctx);
}

void bench_finish(struct scenario_result *r, uint64_t ops)
{
    int64_t min_ns = r->samples_ns[0], max_ns = r->samples_ns[0];
    int i;

    r->ops = ops;
    r->ns_per_op = ops > 0 ? (double)r->total_ns_median / (double)ops : 0.0;

    for (i = 1; i < r->runs; i++) {
        if (r->samples_ns[i] < min_ns) {
            min_ns = r->samples_ns[i];
        }
        if (r->samples_ns[i] > max_ns) {
            max_ns = r->samples_ns[i];
        }
    }
    extra_arr_i64(&r->extra, "samples_ns", r->samples_ns, (size_t)r->runs);
    extra_i(&r->extra, "total_ns_min", min_ns);
    extra_i(&r->extra, "total_ns_max", max_ns);
    extra_b(&r->extra, "flash_consistent", r->flash_consistent);
    extra_b(&r->extra, "errs_consistent", r->errs_consistent);
}

/* ------------------------------------------------------------------ */
/* error accounting                                                    */
/* ------------------------------------------------------------------ */

static const char *const err_names[BENCH_ERR_CODE_NUM] = {
    "FDB_NO_ERR",         "FDB_ERASE_ERR",      "FDB_READ_ERR",
    "FDB_WRITE_ERR",      "FDB_PART_NOT_FOUND", "FDB_KV_NAME_ERR",
    "FDB_KV_NAME_EXIST",  "FDB_SAVED_FULL",     "FDB_INIT_FAILED",
};

/* JSON keys of the shared JSON contract (errcodes object). */
static const char *const err_json_keys[BENCH_ERR_CODE_NUM] = {
    "ok",         "erase_err",      "read_err",
    "write_err",  "part_not_found", "name_err",
    "name_exist", "saved_full",     "init_failed",
};

const char *bench_err_name(int code)
{
    if (code < 0 || code >= BENCH_ERR_CODE_NUM) {
        return "FDB_UNKNOWN";
    }
    return err_names[code];
}

void bench_err_add(fdb_err_t rc)
{
    if ((int)rc >= 0 && (int)rc < BENCH_ERR_CODE_NUM) {
        bench_errs.codes[(int)rc]++;
    }
}

/* ------------------------------------------------------------------ */
/* extras                                                              */
/* ------------------------------------------------------------------ */

static struct extra_item *extra_push(struct extra_list *l, const char *key, char type)
{
    struct extra_item *it;

    if (l->n >= BENCH_EXTRA_MAX) {
        bench_fatal("extra list overflow for '%s'", key);
    }
    it = &l->items[l->n++];
    memset(it, 0, sizeof(*it));
    it->key = key;
    it->type = type;
    return it;
}

void extra_i(struct extra_list *l, const char *key, int64_t v)
{
    struct extra_item *it = extra_push(l, key, 'i');
    it->i = v;
}

void extra_u(struct extra_list *l, const char *key, uint64_t v)
{
    struct extra_item *it = extra_push(l, key, 'u');
    it->i = (int64_t)v;
}

void extra_d(struct extra_list *l, const char *key, double v)
{
    struct extra_item *it = extra_push(l, key, 'd');
    it->d = v;
}

void extra_s(struct extra_list *l, const char *key, const char *v)
{
    struct extra_item *it = extra_push(l, key, 's');
    it->s = v;
}

void extra_b(struct extra_list *l, const char *key, int v)
{
    struct extra_item *it = extra_push(l, key, 'b');
    it->i = v ? 1 : 0;
}

void extra_arr(struct extra_list *l, const char *key, const uint64_t *arr, size_t n)
{
    struct extra_item *it = extra_push(l, key, 'a');
    it->arr = arr;
    it->n = n;
}

void extra_arr_i64(struct extra_list *l, const char *key, const int64_t *arr, size_t n)
{
    struct extra_item *it = extra_push(l, key, 'A');
    it->iarr = arr;
    it->n = n;
}

/* ------------------------------------------------------------------ */
/* result list                                                         */
/* ------------------------------------------------------------------ */

struct scenario_result *bench_new_result(void)
{
    if (result_count >= BENCH_MAX_SCENARIOS) {
        bench_fatal("too many scenario results");
    }
    memset(&results[result_count], 0, sizeof(results[result_count]));
    return &results[result_count++];
}

int bench_want(const char *name)
{
    return scenario_filter == NULL || strcmp(scenario_filter, name) == 0;
}

void bench_set_filter(const char *name)
{
    scenario_filter = name;
}

struct scenario_result *bench_results(void)
{
    return results;
}

int bench_result_count(void)
{
    return result_count;
}

/* ------------------------------------------------------------------ */
/* JSON                                                                */
/* ------------------------------------------------------------------ */

static void json_escape(FILE *f, const char *s)
{
    const unsigned char *p = (const unsigned char *)s;

    fputc('"', f);
    while (*p) {
        switch (*p) {
        case '"':
            fputs("\\\"", f);
            break;
        case '\\':
            fputs("\\\\", f);
            break;
        case '\n':
            fputs("\\n", f);
            break;
        case '\r':
            fputs("\\r", f);
            break;
        case '\t':
            fputs("\\t", f);
            break;
        default:
            if (*p < 0x20) {
                fprintf(f, "\\u%04x", (unsigned)*p);
            } else {
                fputc(*p, f);
            }
            break;
        }
        p++;
    }
    fputc('"', f);
}

static void json_err_codes(FILE *f, const struct err_counts *e)
{
    int i;
    int first = 1;

    fputc('{', f);
    for (i = 0; i < BENCH_ERR_CODE_NUM; i++) {
        if (e->codes[i] == 0) {
            continue;
        }
        if (!first) {
            fputc(',', f);
        }
        first = 0;
        json_escape(f, err_json_keys[i]);
        fprintf(f, ":%llu", (unsigned long long)e->codes[i]);
    }
    fputc('}', f);
}

static void json_extra(FILE *f, const struct extra_list *l)
{
    size_t i, j;

    fputs("{", f);
    for (i = 0; i < l->n; i++) {
        const struct extra_item *it = &l->items[i];

        if (i > 0) {
            fputs(",", f);
        }
        json_escape(f, it->key);
        fputc(':', f);
        switch (it->type) {
        case 'i':
            fprintf(f, "%lld", (long long)it->i);
            break;
        case 'u':
            fprintf(f, "%llu", (unsigned long long)it->i);
            break;
        case 'd':
            fprintf(f, "%.6f", it->d);
            break;
        case 's':
            json_escape(f, it->s);
            break;
        case 'b':
            fputs(it->i ? "true" : "false", f);
            break;
        case 'a':
            fputc('[', f);
            for (j = 0; j < it->n; j++) {
                fprintf(f, "%s%llu", j ? "," : "", (unsigned long long)it->arr[j]);
            }
            fputc(']', f);
            break;
        case 'A':
            fputc('[', f);
            for (j = 0; j < it->n; j++) {
                fprintf(f, "%s%lld", j ? "," : "", (long long)it->iarr[j]);
            }
            fputc(']', f);
            break;
        default:
            fputs("null", f);
            break;
        }
    }
    fputc('}', f);
}

static void json_config(FILE *f)
{
    fputs("{\n", f);
    fprintf(f, "    \"write_gran\": %d,\n", (int)FDB_WRITE_GRAN);
    fprintf(f, "    \"write_gran_bytes\": %d,\n", (int)((FDB_WRITE_GRAN + 7) / 8));
    fprintf(f, "    \"sector_size\": %u,\n", (unsigned)BENCH_SECTOR_SIZE);
    fprintf(f, "    \"sectors_per_db\": %u,\n", (unsigned)BENCH_PARTITION_COUNT);
    fprintf(f, "    \"partition_size\": %u,\n", (unsigned)BENCH_PARTITION_SIZE);
    fprintf(f, "    \"partitions\": [\"%s\", \"%s\"],\n", BENCH_KV_PART_NAME, BENCH_TS_PART_NAME);
    fprintf(f, "    \"kv_cache_table_size\": %d,\n", (int)FDB_KV_CACHE_TABLE_SIZE);
    fprintf(f, "    \"sector_cache_table_size\": %d,\n", (int)FDB_SECTOR_CACHE_TABLE_SIZE);
    fprintf(f, "    \"debug_log\": false,\n");
    fprintf(f, "    \"ts_timestamp_bits\": %d,\n",
#if defined(FDB_USING_TIMESTAMP_64BIT)
            64
#else
            32
#endif
    );
    fprintf(f, "    \"ts_max_log_len\": %u,\n", (unsigned)BENCH_TS_MAX_LOG_LEN);
    fprintf(f, "    \"runs\": %d,\n", bench_runs);
    fputs("    \"opt\": ", f);
    json_escape(f, BENCH_STR(BENCH_OPT));
    fputs(",\n    \"compiler\": ", f);
    json_escape(f, __VERSION__);
    fputs(",\n    \"host\": ", f);
    json_escape(f, BENCH_HOST);
    fputs(",\n    \"cflags\": ", f);
    json_escape(f, BENCH_BUILD_FLAGS);
    fputs("\n  }", f);
}

static void json_footprint(FILE *f)
{
    fprintf(f,
            "{\n"
            "    \"sizeof_kvdb\": %zu,\n"
            "    \"sizeof_tsdb\": %zu,\n"
            "    \"sizeof_fdb_db\": %zu,\n"
            "    \"sizeof_fdb_kv\": %zu,\n"
            "    \"sizeof_kv_cache_node\": %zu,\n"
            "    \"sizeof_kvdb_sec_info\": %zu,\n"
            "    \"sizeof_tsdb_sec_info\": %zu,\n"
            "    \"note\": \"sizeof(struct fdb_kvdb) includes the %d-entry KV cache and %d-entry sector cache; partition/geometry not counted\"\n"
            "  }",
            sizeof(struct fdb_kvdb), sizeof(struct fdb_tsdb), sizeof(struct fdb_db),
            sizeof(struct fdb_kv), sizeof(struct kv_cache_node), sizeof(struct kvdb_sec_info),
            sizeof(struct tsdb_sec_info), (int)FDB_KV_CACHE_TABLE_SIZE,
            (int)FDB_SECTOR_CACHE_TABLE_SIZE);
}

static void json_semantics(FILE *f)
{
    fputs(
        "{\n"
        "    \"checksum_fn\": \"FNV-1a 32: hash=0x811C9DC5; per byte: hash^=b; hash*=0x01000193 (wrapping); decimal u32\",\n"
        "    \"kv_value_formula\": \"byte[j] = (seed + i*31 + j*7) & 0xFF\",\n"
        "    \"kv_seeds\": {\"kv_set_small\": 17, \"kv_update_1k_initial\": 34, \"kv_get_hot\": 51, \"kv_delete_set\": 51, \"kv_large\": 68},\n"
        "    \"ts_payload_formula\": \"byte[j] = (0x5A + i*13 + j*5) & 0xFF\",\n"
        "    \"ts_timestamp_formula\": \"t_i = 1000 + i\",\n"
        "    \"delete_missing_key\": \"FDB_KV_NAME_ERR\",\n"
        "    \"delete_missing_key_code\": 5,\n"
        "    \"get_missing_returns\": 0,\n"
        "    \"kv_checksum\": \"FNV-1a-32 over u32(entry_count), then entries sorted by key: u32(key_len), key, u32(value_len), value\",\n"
        "    \"ts_checksum\": \"FNV-1a-32 over forward-iteration records: u32(status), u32(time), u32(log_len), payload[log_len]; then u32(entry_count)\",\n"
        "    \"range_checksum\": \"tsl_by_time/tsl_query_count: FNV-1a-32 over u32(500), then u32(count) per query\",\n"
        "    \"lcg\": \"state=12345; next: state=(state*1103515245+12345) mod 2^31; per query: off=next()%3000, len=50+next()%451; from=1000+off; to=from+len\",\n"
        "    \"timing\": \"clock_gettime(CLOCK_MONOTONIC), median of runs; setup excluded from timing and flash counters\",\n"
        "    \"flash_cost\": \"read_bytes*1 + write_bytes*10 + erase_bytes*100\"\n"
        "  }",
        f);
}

void bench_json_write(FILE *f, const char *impl, const char *version)
{
    int i;

    fprintf(f, "{\n  \"impl\": ");
    json_escape(f, impl);
    fputs(",\n  \"version\": ", f);
    json_escape(f, version);
    fputs(",\n  \"opt\": ", f);
    json_escape(f, BENCH_STR(BENCH_OPT));
    fprintf(f, ",\n  \"write_gran\": %d", (int)FDB_WRITE_GRAN);
    fputs(",\n  \"config\": ", f);
    json_config(f);
    fputs(",\n  \"footprint\": ", f);
    json_footprint(f);
    fputs(",\n  \"semantics\": ", f);
    json_semantics(f);
    fputs(",\n  \"scenarios\": [", f);
    for (i = 0; i < result_count; i++) {
        const struct scenario_result *r = &results[i];

        fputs(i ? ",\n    {\n      " : "\n    {\n      ", f);
        fputs("\"name\": ", f);
        json_escape(f, r->name);
        fprintf(f, ",\n      \"ops\": %llu,", (unsigned long long)r->ops);
        fprintf(f, "\n      \"hits\": %llu,", (unsigned long long)r->hits);
        fprintf(f, "\n      \"total_ns_median\": %lld,", (long long)r->total_ns_median);
        fprintf(f, "\n      \"ns_per_op\": %.3f,", r->ns_per_op);
        fprintf(f, "\n      \"runs\": %d,", r->runs);
        fprintf(f, "\n      \"checksum\": %u,", (unsigned)r->checksum);
        fputs("\n      \"errcodes\": ", f);
        json_err_codes(f, &r->errs);
        fprintf(f,
                ",\n      \"flash\": {\"reads\": %llu, \"read_bytes\": %llu, \"writes\": %llu, "
                "\"write_bytes\": %llu, \"erases\": %llu, \"erase_bytes\": %llu}",
                (unsigned long long)r->flash.reads, (unsigned long long)r->flash.read_bytes,
                (unsigned long long)r->flash.writes, (unsigned long long)r->flash.write_bytes,
                (unsigned long long)r->flash.erases, (unsigned long long)r->flash.erase_bytes);
        fputs(",\n      \"extra\": ", f);
        json_extra(f, &r->extra);
        fputs("\n    }", f);
    }
    fputs("\n  ]\n}\n", f);
}

/* ------------------------------------------------------------------ */

void bench_fatal(const char *fmt, ...)
{
    va_list ap;

    fprintf(stderr, "c_harness: FATAL: ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    exit(3);
}
