/*
 * FlashDB firmware measurement harness -- ARM semihosting output.
 *
 * No libc, no printf: a handful of tiny formatters keep the harness footprint
 * negligible compared to the library under measurement and keep the C and the
 * Zig firmware output identical in shape.
 *
 * The formatters deliberately avoid integer division (which would pull in
 * __aeabi_uidiv) so the harness itself never changes the measured link set;
 * FlashDB's own code decides whether those helpers are needed.
 */
#include "semihost.h"
#ifdef FW_CYCLES
#include "cycles.h"
#endif

static void sh_call(uint32_t op, const void *arg)
{
    register uint32_t r0 __asm__("r0") = op;
    register const void *r1 __asm__("r1") = arg;

    __asm__ volatile("bkpt 0xab" : "+r"(r0) : "r"(r1) : "memory");
    (void)r0;
}

void sh_write0(const char *s)
{
    sh_call(SEMIHOST_SYS_WRITE0, (const void *)s);
}

void sh_write_u32(uint32_t value)
{
    /* Powers of ten that fit in 32 bits; emit digits by repeated subtraction. */
    static const uint32_t pow10[] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    char buf[11];
    int i;
    int started = 0;

    for (i = 0; i < 10; i++) {
        uint32_t digit = 0;
        while (value >= pow10[i]) {
            value -= pow10[i];
            digit++;
        }
        if (digit != 0u || started || pow10[i] == 1u) {
            buf[i] = (char)('0' + (int)digit);
            started = 1;
        } else {
            buf[i] = ' ';
        }
    }
    buf[10] = '\0';

    {
        const char *p = buf;
        while (*p == ' ') {
            p++;
        }
        sh_write0(p);
    }
}

void sh_write_hex32(uint32_t value)
{
    static const char hex[] = "0123456789abcdef";
    char buf[11];
    int i;

    buf[0] = '0';
    buf[1] = 'x';
    for (i = 0; i < 8; i++) {
        buf[2 + i] = hex[(value >> (28 - 4 * i)) & 0xfu];
    }
    buf[10] = '\0';
    sh_write0(buf);
}

void harness_fill_section_sizes(struct harness_metrics *m)
{
    /* Linker-defined symbols (common/mps2_an385.ld).  Declared as byte arrays
     * so `__text_end - __text_start` is a plain byte difference. */
    extern uint8_t __text_start[];
    extern uint8_t __text_end[];
    extern uint8_t __rodata_start[];
    extern uint8_t __rodata_end[];
    extern uint8_t __data_start[];
    extern uint8_t __data_end[];
    extern uint8_t __bss_start[];
    extern uint8_t __bss_end[];
    extern uint8_t __sim_flash_start[];
    extern uint8_t __sim_flash_end[];

    m->text      = (uint32_t)(__text_end - __text_start);
    m->rodata    = (uint32_t)(__rodata_end - __rodata_start);
    m->data      = (uint32_t)(__data_end - __data_start);
    m->bss       = (uint32_t)(__bss_end - __bss_start);
    m->sim_flash = (uint32_t)(__sim_flash_end - __sim_flash_start);
}

void harness_print_result(const struct harness_metrics *m)
{
    sh_write0("RESULT text=");
    sh_write_u32(m->text);
    sh_write0(" rodata=");
    sh_write_u32(m->rodata);
    sh_write0(" data=");
    sh_write_u32(m->data);
    sh_write0(" bss=");
    sh_write_u32(m->bss);
    sh_write0(" sim_flash=");
    sh_write_u32(m->sim_flash);
    sh_write0(" stack=");
    sh_write_u32(m->stack);
    sh_write0(" stack_init=");
    sh_write_u32(m->stack_init);
    sh_write0(" stack_limit=");
    sh_write_u32(m->stack_limit);
#ifdef HARNESS_STACK_PHASES
    sh_write0(" st_set=");
    sh_write_u32(m->st_set);
    sh_write0(" st_get=");
    sh_write_u32(m->st_get);
    sh_write0(" st_iter=");
    sh_write_u32(m->st_iter);
    sh_write0(" st_gc=");
    sh_write_u32(m->st_gc);
    sh_write0(" st_ts_append=");
    sh_write_u32(m->st_ts_append);
    sh_write0(" st_ts_iter=");
    sh_write_u32(m->st_ts_iter);
#endif
    sh_write0(" kv_writes=");
    sh_write_u32(m->kv_writes);
    sh_write0(" kv_gets=");
    sh_write_u32(m->kv_gets);
    sh_write0(" kv_iterated=");
    sh_write_u32(m->kv_iterated);
    sh_write0(" kv_checksum=");
    sh_write_hex32(m->kv_checksum);
    sh_write0(" kv_iter_checksum=");
    sh_write_hex32(m->kv_iter_checksum);
    sh_write0(" ts_appends=");
    sh_write_u32(m->ts_appends);
    sh_write0(" ts_iterated=");
    sh_write_u32(m->ts_iterated);
    sh_write0(" ts_checksum=");
    sh_write_hex32(m->ts_checksum);
#ifdef FW_CYCLES
    sh_write0(" cycles_src=");
    sh_write0(cycles_source_name());
    sh_write0(" cycles_tick_hz=");
    sh_write_u32(m->cycles_tick_hz);
    sh_write0(" cycles_calib_insn=");
    sh_write_u32(m->cycles_spin_insn);
    sh_write0(" cycles_calib_ticks=");
    sh_write_u32(m->cycles_spin_ticks);
    sh_write0(" cycles_mount=");
    sh_write_u32(m->cycles_mount);
    sh_write0(" cycles_kv=");
    sh_write_u32(m->cycles_kv);
    sh_write0(" cycles_ts=");
    sh_write_u32(m->cycles_ts);
    sh_write0(" cycles_total=");
    sh_write_u32(m->cycles_total);
#ifdef HARNESS_STACK_PHASES
    sh_write0(" cyc_st_set=");
    sh_write_u32(m->cyc_st_set);
    sh_write0(" cyc_st_get=");
    sh_write_u32(m->cyc_st_get);
    sh_write0(" cyc_st_iter=");
    sh_write_u32(m->cyc_st_iter);
    sh_write0(" cyc_st_gc=");
    sh_write_u32(m->cyc_st_gc);
    sh_write0(" cyc_st_ts_append=");
    sh_write_u32(m->cyc_st_ts_append);
    sh_write0(" cyc_st_ts_iter=");
    sh_write_u32(m->cyc_st_ts_iter);
#endif
#endif /* FW_CYCLES */
    sh_write0(" rc=0\n");
}

void harness_fail(const char *stage, int code)
{
    sh_write0("ERROR stage=");
    sh_write0(stage);
    sh_write0(" code=");
    sh_write_u32((uint32_t)code);
    sh_write0("\n");
    sh_write0("RESULT rc=1\n");
    harness_exit();
}

void harness_exit(void)
{
    sh_call(SEMIHOST_SYS_EXIT, (const void *)(uintptr_t)SEMIHOST_ADP_STOPPED_APP_EXIT);
    for (;;) {
        /* QEMU should have terminated already; spin if semihosting is absent. */
    }
}
