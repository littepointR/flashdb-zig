/*
 * FlashDB firmware measurement harness -- linker script for the
 * ARM MPS2-AN385 board (Cortex-M3) emulated by qemu-system-arm.
 *
 * Memory map (as modelled by QEMU's mps2-an385 machine, verified on this host):
 *   0x00000000..0x000FFFFF  first 1 MiB of ZBT SSRAM1  -> code / rodata
 *   0x00100000..0x00107FFF  next 32 KiB of SSRAM1      -> detached NOR-flash
 *                                                         simulator backing
 *                                                         store (NOLOAD)
 *   0x20000000..0x203FFFFF  4 MiB SRAM                 -> .data / .bss / stack
 *
 * The flash simulator lives in its own memory region so that it is NOT counted
 * as MCU static RAM: it models an external NOR chip, not on-chip state.  It is
 * NOLOAD so the ELF does not carry 64 KiB of constant data; the firmware's
 * flash driver erases it to 0xFF at boot, exactly like a factory-fresh NOR.
 *
 * The stack is the top 8 KiB of SRAM.  The reset handler paints it with
 * 0xA5A5A5A5 before entering main(); after the workload the lowest non-0xA5
 * word gives the worst-case stack high-water mark.  See common/stack.c.
 *
 * The file is shared by the C firmware (scripts/fw_c.sh) and the Rust
 * firmware (scripts/fw_rust.sh); both link with arm-none-eabi-ld via
 * arm-none-eabi-gcc because the host Apple linker lacks --gc-sections.
 */

ENTRY(Reset_Handler)

MEMORY
{
  CODE     (rx) : ORIGIN = 0x00000000, LENGTH = 0x00100000  /* 1 MiB SSRAM1: code + rodata */
  SIMFLASH (rw) : ORIGIN = 0x00100000, LENGTH = 0x00008000  /* 32 KiB SSRAM1: NOR simulator   */
  RAM      (rwx): ORIGIN = 0x20000000, LENGTH = 0x00400000  /* 4 MiB SRAM: data+bss+stack     */
}

SECTIONS
{
  /* Vector table must be the first thing at address 0: QEMU loads the
     initial MSP from 0x00000000 and the reset PC from 0x00000004. */
  .text :
  {
    __text_start = .;
    KEEP(*(.vectors))
    *(.text*)
    *(.glue_7) *(.glue_7t) *(.vfp11_veneer) *(.v4_bx)
    . = ALIGN(4);
    __text_end = .;
  } > CODE

  .rodata :
  {
    . = ALIGN(4);
    __rodata_start = .;
    *(.rodata*)
    . = ALIGN(4);
    __rodata_end = .;
  } > CODE

  .data :
  {
    . = ALIGN(8);
    __data_start = .;
    *(.data*)
    *(.got) *(.got.plt)
    . = ALIGN(8);
    __data_end = .;
  } > RAM AT > CODE
  _sidata = LOADADDR(.data);

  .bss (NOLOAD) :
  {
    . = ALIGN(8);
    __bss_start = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(8);
    __bss_end = .;
  } > RAM

  /* Backing store of the simulated external NOR flash (see c/fal_ram_sim.c).
     KEEP() keeps the 32 KiB definition even with --gc-sections. */
  .sim_flash (NOLOAD) :
  {
    . = ALIGN(4);
    __sim_flash_start = .;
    KEEP(*(.sim_flash))
    . = ALIGN(4);
    __sim_flash_end = .;
  } > SIMFLASH

  /* Absolute symbols consumed by common/stack.c and the startup code.
     _estack is the initial MSP; the stack grows down from there. */
  _stack_size   = 0x2000;                       /* 8 KiB */
  _estack       = ORIGIN(RAM) + LENGTH(RAM);
  _stack_bottom = _estack - _stack_size;

  /* Aliases expected by the shared startup assembly (which also works with
     the conventional newlib names), kept identical to the section markers. */
  _sdata = __data_start;
  _edata = __data_end;
  _sbss  = __bss_start;
  _ebss  = __bss_end;

  /* Keep the ELF free of host-only metadata that would confuse size -A. */
  /DISCARD/ :
  {
    *(.ARM.exidx*)
    *(.ARM.extab*)
    *(.note*)
    *(.comment)
  }
}
