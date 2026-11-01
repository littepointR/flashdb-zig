/*
 * FAL configuration for the C reference benchmark harness.
 *
 * One simulated NOR device ("norflash0", 32 KiB, 4096-byte erase blocks) split
 * into the two 16 KiB partitions required by harness/SCENARIOS.md:
 *
 *   fdb_kvdb1 : offset 0      len 16384
 *   fdb_tsdb1 : offset 16384  len 16384
 *
 * The device object and its ops live in sim_flash.c.
 */

#ifndef _FAL_CFG_H_
#define _FAL_CFG_H_

#include <stdint.h>

#define NOR_FLASH_DEV_NAME             "norflash0"

/* Partition table is compiled in (do not search flash for it). */
#define FAL_PART_HAS_TABLE_CFG

/* Flash device table */
extern const struct fal_flash_dev nor_flash0;

#define FAL_FLASH_DEV_TABLE                                          \
{                                                                    \
    &nor_flash0,                                                     \
}

/* Partition table (FAL_PART_MAGIC_WORD is defined by fal_partition.c). */
#define FAL_PART_TABLE                                                       \
{                                                                            \
    {FAL_PART_MAGIC_WORD, "fdb_kvdb1", NOR_FLASH_DEV_NAME,      0, 16*1024, 0}, \
    {FAL_PART_MAGIC_WORD, "fdb_tsdb1", NOR_FLASH_DEV_NAME, 16*1024, 16*1024, 0}, \
}

/* Route FAL logging to stderr as well (stdout is the JSON document). */
void fdb_host_log(const char *fmt, ...);
#define FAL_PRINTF(...)                fdb_host_log(__VA_ARGS__)

#endif /* _FAL_CFG_H_ */
