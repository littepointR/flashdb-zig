/*
 * FlashDB configuration for the C reference benchmark harness.
 *
 * Geometry / protocol are fixed by harness/SCENARIOS.md:
 *   4 sectors x 4096 B per DB partition, FAL mode, KVDB + TSDB,
 *   32-bit timestamps, default cache sizes, no debug logging.
 *
 * IMPORTANT: FDB_WRITE_GRAN is deliberately NOT defined here. It must be
 * supplied by the build (-DFDB_WRITE_GRAN=8 or -DFDB_WRITE_GRAN=1) so that the
 * same sources produce the two protocol variants. fdb_kvdb.c has an #error if
 * it is missing.
 */

#ifndef _FDB_CFG_H_
#define _FDB_CFG_H_

/* KVDB and TSDB features */
#define FDB_USING_KVDB
#define FDB_USING_TSDB

/* FAL storage mode (RAM-backed FAL simulator, see fal_cfg.h / sim_flash.c) */
#define FDB_USING_FAL_MODE

/* Keep the SCENARIOS.md cache configuration pinned (library defaults anyway). */
#define FDB_KV_CACHE_TABLE_SIZE        64
#define FDB_SECTOR_CACHE_TABLE_SIZE    8

/* NO FDB_KV_AUTO_UPDATE, NO FDB_DEBUG_ENABLE: logging disabled by protocol. */

/* Real asserts instead of the default "while (1);" so harness bugs abort loudly. */
#define FDB_USING_NATIVE_ASSERT

/*
 * Library logging is routed to stderr (see fdb_host_log in sim_flash.c) because
 * stdout is reserved for the JSON result document.
 */
void fdb_host_log(const char *fmt, ...);
#define FDB_PRINT(...)                 fdb_host_log(__VA_ARGS__)

#endif /* _FDB_CFG_H_ */
