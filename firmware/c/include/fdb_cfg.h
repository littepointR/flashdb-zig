/*
 * FlashDB firmware measurement harness -- FlashDB compile-time configuration
 * for the Cortex-M3 measurement firmware.
 *
 * This file is found through `-I firmware/c/include` and is included
 * by FlashDB's public header (<fdb_cfg.h>).  Upstream sources under
 * reference/FlashDB are NOT modified.
 */
#ifndef _FDB_CFG_H_
#define _FDB_CFG_H_

/* Both databases are measured together (KVDB + TSDB). */
#define FDB_USING_KVDB
#define FDB_USING_TSDB

/* FAL (Flash Abstraction Layer) storage mode: no file system, no libc file
 * APIs.  The FAL port below is backed by a RAM array that models NOR. */
#define FDB_USING_FAL_MODE

#ifdef FDB_USING_FAL_MODE
/* NOR flash: 1 bit = 1 byte programmable granularity.  Overridable with
 * -DFDB_WRITE_GRAN=... from scripts/build_fw_c.ps1 (kept at 8 for the
 * baseline). */
#ifndef FDB_WRITE_GRAN
#define FDB_WRITE_GRAN 8
#endif
#endif

/*
 * Compile out library logging.  FDB_PRINT defaults to printf(), which would
 * pull in a full libc; a production firmware with logging disabled is the
 * honest baseline for footprint comparison.  The harness reports failures
 * through its own semihosting channel instead.
 */
#define FDB_PRINT(...) ((void)0)

/* Do not enable FDB_DEBUG_ENABLE / FDB_KV_AUTO_UPDATE; keep the default
 * feature set of fdb_cfg_template.h (minus logging). */

#endif /* _FDB_CFG_H_ */
