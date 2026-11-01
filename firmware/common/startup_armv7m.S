@ FlashDB firmware measurement harness -- Cortex-M3 startup for MPS2-AN385.
@
@ Single source file used by BOTH firmware builds:
@   * C firmware   : assembled by `zig cc` (see scripts/build_fw_c.ps1)
@   * Zig firmware : the Zig build assembles the same file / mirrors it
@                    (firmware/common/README notes the contract)
@
@ Therefore it must be plain assembler: no C preprocessor directives, no
@ <#include>, no '#' comments.  Only GNU-syntax ARM assembly that is also
@ understood by LLVM's integrated assembler.  '#' is used only for immediates.
@
@ Boot sequence:
@   1. set MSP to _estack
@   2. paint the whole stack region with 0xA5A5A5A5 (register-only loop, no
@      stack traffic, so the paint itself leaves no marks)
@   3. copy .data from its load address in CODE memory to RAM
@   4. zero .bss
@   5. paint the stack a second time, immediately before the call to main(),
@      so that the boot code's own stack usage is not attributed to the
@      workload
@   6. bl main
@
@ A trap (Default_Handler) catches unexpected exceptions; spin there with an
@ infinite branch so QEMU stays wedged until the host timeout fires.

    .syntax unified
    .cpu cortex-m3
    .thumb

    .equ STACK_PAINT_WORD, 0xA5A5A5A5

    .section .vectors, "a", %progbits
    .global g_vectors
    .type g_vectors, %object
g_vectors:
    .word _estack                 @ 0x00 initial MSP
    .word Reset_Handler           @ 0x04 reset
    .word Default_Handler         @ 0x08 NMI
    .word Default_Handler         @ 0x0c HardFault
    .word Default_Handler         @ 0x10 MemManage
    .word Default_Handler         @ 0x14 BusFault
    .word Default_Handler         @ 0x18 UsageFault
    .word 0                       @ 0x1c reserved
    .word 0                       @ 0x20 reserved
    .word 0                       @ 0x24 reserved
    .word 0                       @ 0x28 reserved
    .word Default_Handler         @ 0x2c SVCall
    .word Default_Handler         @ 0x30 DebugMonitor
    .word 0                       @ 0x34 reserved
    .word Default_Handler         @ 0x38 PendSV
    .word Default_Handler         @ 0x3c SysTick
    .size g_vectors, . - g_vectors

    .section .text.Reset_Handler, "ax", %progbits
    .global Reset_Handler
    .type Reset_Handler, %function
    .thumb_func
Reset_Handler:
    @ 1. initial stack pointer (also supplied through vector[0] for QEMU)
    ldr   r0, =_estack
    mov   sp, r0

    @ 2. paint stack: [ _stack_bottom, _estack )  (register-only, no pushes)
    ldr   r1, =_stack_bottom
    ldr   r2, =STACK_PAINT_WORD
1:
    subs  r0, r0, #4
    str   r2, [r0]
    cmp   r0, r1
    bhi   1b

    @ 3. relocate .data (load address _sidata, run address [_sdata, _edata))
    ldr   r0, =_sdata
    ldr   r1, =_edata
    ldr   r2, =_sidata
2:
    cmp   r0, r1
    bhs   3f
    ldr   r3, [r2], #4
    str   r3, [r0], #4
    b     2b
3:
    @ 4. zero .bss
    ldr   r0, =_sbss
    ldr   r1, =_ebss
    movs  r2, #0
4:
    cmp   r0, r1
    bhs   5f
    str   r2, [r0], #4
    b     4b
5:
    @ 5. repaint stack immediately before main(): boot code (data/bss init)
    @    must not inflate the measured workload high-water mark.
    ldr   r0, =_estack
    ldr   r1, =_stack_bottom
    ldr   r2, =STACK_PAINT_WORD
6:
    subs  r0, r0, #4
    str   r2, [r0]
    cmp   r0, r1
    bhi   6b

    @ 6. run the workload.  main() is provided by C or by Rust (#[no_mangle]).
    bl    main
    b     Default_Handler
    .ltorg
    .size Reset_Handler, . - Reset_Handler

    .section .text.Default_Handler, "ax", %progbits
    .global Default_Handler
    .type Default_Handler, %function
    .thumb_func
Default_Handler:
    b Default_Handler
    .size Default_Handler, . - Default_Handler
