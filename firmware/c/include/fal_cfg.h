/*
 * FlashDB firmware measurement harness -- FAL (Flash Abstraction Layer)
 * configuration for the Cortex-M3 measurement firmware.
 *
 * Found through `-I firmware/c/include`; included by <fal.h>.
 * Upstream sources under reference/FlashDB are NOT modified.
 */
#ifndef _FAL_CFG_H_
#define _FAL_CFG_H_

#include "workload_spec.h"

/* Static partition table compiled into the firmware (no table-in-flash). */
#define FAL_PART_HAS_TABLE_CFG

/* FAL_PART_MAGIC_WORD is defined by reference/FlashDB/port/fal/src/fal_partition.c
 * itself before it expands FAL_PART_TABLE, so it must not be redefined here. */

/*
 * Compile out FAL logging: FAL_PRINTF defaults to printf(), which would pull
 * in a full libc.  See fdb_cfg.h for the same decision on the FlashDB side.
 */
#define FAL_PRINTF(...) ((void)0)

/* NOR-flash simulator implemented in firmware/c/fal_ram_sim.c.
 * Backed by the .sim_flash NOLOAD region of the linker script. */
#define NOR_FLASH_DEV_NAME "norflash0"

extern struct fal_flash_dev nor_flash0;

/* Flash device table (FAL_FLASH_DEV_TABLE is consumed by fal_flash.c). */
#define FAL_FLASH_DEV_TABLE { &nor_flash0, }

/*
 * Partition table.  Layout matches workload_spec.h:
 *   fdb_kvdb1 : 16 KiB at offset 0      (KVDB: 4 sectors of 4 KiB)
 *   fdb_tsdb1 : 16 KiB at offset 16 KiB (TSDB: 4 sectors of 4 KiB)
 * Offsets are block aligned, as FAL requires.
 */
#define FAL_PART_TABLE                                                                     \
{                                                                                          \
    { FAL_PART_MAGIC_WORD, "fdb_kvdb1", NOR_FLASH_DEV_NAME, HW_KVDB_PART_OFFSET, HW_KVDB_PART_LEN, 0 }, \
    { FAL_PART_MAGIC_WORD, "fdb_tsdb1", NOR_FLASH_DEV_NAME, HW_TSDB_PART_OFFSET, HW_TSDB_PART_LEN, 0 }, \
}

#endif /* _FAL_CFG_H_ */
