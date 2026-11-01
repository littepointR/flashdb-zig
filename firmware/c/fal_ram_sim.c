/*
 * FlashDB firmware measurement harness -- simulated external NOR flash.
 *
 * Models a 32 KiB NOR part with 4 KiB erase blocks, backed by the .sim_flash
 * NOLOAD memory region declared in common/mps2_an385.ld (placed in a separate
 * SRAM bank from .data/.bss, so the isolated storage is not counted as MCU
 * static RAM).
 *
 * Semantics implemented (byte-writable NOR, the FDB_WRITE_GRAN configured for
 * the build -- 8 = byte programmable by default):
 *   read  : plain byte copy.
 *   write : bitwise AND (programming can only clear bits: 1 -> 0), so writing
 *           0xFF is a no-op and re-programming a cleared bit is impossible,
 *           exactly like real NOR.  FlashDB's status-table updates rely on this.
 *   erase : whole 4 KiB blocks are set to 0xFF.
 *   init  : the whole device starts erased (0xFF), like a factory-fresh part.
 *
 * Note: this is a *simulator*, not a benchmark of the flash driver; the FAL
 * driver overhead is identical for the C and Zig builds and is not part of
 * the library footprint being compared.
 */
#include <fal.h>
#include <fdb_cfg.h>
#include <string.h>
#include <stddef.h>

#include "workload_spec.h"

extern uint8_t __sim_flash_start[];

/* Backing store: KEEP(*(.sim_flash)) in the linker script places this array in
 * the detached SIMFLASH memory region (not .bss). */
__attribute__((section(".sim_flash"), used, aligned(4096)))
static uint8_t g_sim_flash[HW_SIM_FLASH_LEN];

static int sim_flash_init(void)
{
    memset(__sim_flash_start, 0xFF, HW_SIM_FLASH_LEN);
    return 0;
}

static int sim_flash_read(long offset, uint8_t *buf, size_t size)
{
    if (offset < 0 || (size_t)offset + size > HW_SIM_FLASH_LEN) {
        return -1;
    }
    memcpy(buf, __sim_flash_start + offset, size);
    return (int)size;
}

static int sim_flash_write(long offset, const uint8_t *buf, size_t size)
{
    size_t i;

    if (offset < 0 || (size_t)offset + size > HW_SIM_FLASH_LEN) {
        return -1;
    }
    for (i = 0; i < size; i++) {
        uint8_t old = __sim_flash_start[offset + i];
        uint8_t new = (uint8_t)(old & buf[i]);

        __sim_flash_start[offset + i] = new;
    }
    return (int)size;
}

static int sim_flash_erase(long offset, size_t size)
{
    if (offset < 0 || (size_t)offset + size > HW_SIM_FLASH_LEN) {
        return -1;
    }
    if (((unsigned long)offset % HW_SIM_FLASH_BLK_SIZE) != 0 ||
        (size % HW_SIM_FLASH_BLK_SIZE) != 0) {
        return -1;
    }
    memset(__sim_flash_start + offset, 0xFF, size);
    return (int)size;
}

struct fal_flash_dev nor_flash0 = {
    .name = NOR_FLASH_DEV_NAME,
    .addr = 0x00100000u,        /* informative only; FAL uses offsets */
    .len = HW_SIM_FLASH_LEN,
    .blk_size = HW_SIM_FLASH_BLK_SIZE,
    .ops = {
        .init = sim_flash_init,
        .read = sim_flash_read,
        .write = sim_flash_write,
        .erase = sim_flash_erase,
    },
    .write_gran = FDB_WRITE_GRAN,
};
