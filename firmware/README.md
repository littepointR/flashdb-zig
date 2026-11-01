# C FlashDB firmware measurement harness (Cortex-M3 / QEMU MPS2-AN385)

Bare-metal measurement image for the FlashDB -> Zig comparison: the
**unmodified C FlashDB 2.2.99** from `reference/FlashDB/` plus the real
application-side workload, compiled for `thumb-freestanding-eabi`
(`-mcpu=cortex_m3`) at `-Os`, run under QEMU, and reported as a single
`RESULT ... rc=0` line containing

* `.text` / `.rodata` / `.data` / `.bss` sizes (ROM / static RAM footprint),
* worst-case **stack high-water** (0xA5-painted stack scan),
* per-phase stack peaks and **CPU cycle counts** (instrumented build),
* the deterministic workload checksums and result counts.

The Zig firmware must run the **identical workload with identical constants**
and print the same fields, so ROM, static RAM, stack, cycles and checksums can
be compared field by field.

Nothing under `reference/FlashDB/` is modified.

## Files

```
firmware/
  common/
    startup_armv7m.S    Cortex-M3 vectors + reset handler (paints the stack)
    mps2_an385.ld       linker script: 1 MiB code @0x00000000, 32 KiB NOR
                        simulator @0x00100000 (NOLOAD), 4 MiB RAM @0x20000000
                        with the top 8 KiB as the painted measurement stack
    semihost.c/.h       ARM semihosting output (BKPT 0xAB), RESULT formatter,
                        section-size helpers
    stack.c/.h          0xA5 stack paint scan + per-phase repaint
    cycles.c/.h         DWT cycle counter, SysTick virtual-time proxy fallback
    workload_spec.h     workload constants (shared contract with Zig)
  c/
    main.c              C FlashDB workload + RESULT fields
    fal_ram_sim.c       simulated external NOR (32 KiB, 4 KiB blocks, AND writes)
    libc_stubs.c        minimal mem*/str* + ARM EABI __aeabi_mem* helpers
    include/            fdb_cfg.h, fal_cfg.h and <stdio.h>/<stdlib.h>/... shims
```

## Commands

Run from the repository root:

```powershell
# Default: build + size + run BOTH variants twice, write bench/results/c_firmware.json
pwsh -NoProfile -File scripts/build_fw_c.ps1

# Build and print llvm-size only (no QEMU, no JSON)
pwsh -NoProfile -File scripts/build_fw_c.ps1 -BuildOnly

# Minimal (uninstrumented) image only:
pwsh -NoProfile -File scripts/build_fw_c.ps1 -Cycles:$false -Phases:$false

# Other write granularity
pwsh -NoProfile -File scripts/build_fw_c.ps1 -WriteGran 1

# The underlying compiler/linker command is (paths shortened):
.tools/zig/zig.exe cc -target thumb-freestanding-eabi -mcpu=cortex_m3 -Os `
    -std=gnu11 -w -ffunction-sections -fdata-sections -fno-common `
    -fno-builtin -fno-stack-protector -ffreestanding `
    -fno-asynchronous-unwind-tables -fno-unwind-tables -DFDB_WRITE_GRAN=8 `
    -I firmware/common -I firmware/c/include -I reference/FlashDB/inc `
    -I reference/FlashDB/port/fal/inc -nostdlib -Wl,--gc-sections `
    -Wl,-T,firmware/common/mps2_an385.ld -Wl,-e,Reset_Handler `
    <firmware + reference sources> -o build/fw/fw_c_plain.elf

# The QEMU run is:
qemu-system-arm -M mps2-an385 -cpu cortex-m3 -nographic -semihosting `
    -icount shift=0 -kernel build/fw/fw_c_<variant>.elf
```

`-WriteGran` changes `FDB_WRITE_GRAN` (status-table packing) for the simulated
NOR and the library.  The logical workload and therefore all checksums are
identical; only flash traffic and cycle counts change (WG=1: `plain` .text
+40 B, `cycles_total` 484721 vs 532601 for WG=8).  WG=8 is the acceptance
configuration.

The script's exit status is 0 only when both builds link, both QEMU runs
terminate with `rc=0`, two consecutive runs print an identical RESULT line,
the RESULT section sizes equal `llvm-size -A`, the workload counts/checksums
match the reference values, and (with cycles) the DWT/SysTick probe and
`-icount` calibration are valid.  A hang (hard fault, missing vector table),
a missing RESULT, `rc!=0` or any inconsistency fails loudly.

## Two variants

`scripts/build_fw_c.ps1` builds, runs and reports two images (both are stored
in `bench/results/c_firmware.json`):

| variant | defines | purpose |
|---|---|---|
| `plain` | none | pure library + harness footprint; compares to a plain Zig image |
| `instrumented` | `-DFW_CYCLES=1 -DHARNESS_STACK_PHASES=1` | adds cycle counters, per-phase stack repaints and per-phase cycle deltas |

The instrumentation is harness code only (a few hundred bytes of ROM); the
library under measurement is identical in both images.  Compare like with
like: a Zig image must use the same variant/instrumentation for footprint
comparisons, and use the `instrumented` variants for stack/cycle comparisons.
The per-phase stack numbers are diagnostic: repainting erases the marks of the
earlier phases, so they are measured in a separate pass after the headline scan
and are not directly comparable to the headline `stack` value.

## RESULT line reference

```
RESULT text=.. rodata=.. data=.. bss=.. sim_flash=.. stack=.. stack_init=..
       stack_limit=.. [st_set=.. st_get=.. st_iter=.. st_gc=..
       st_ts_append=.. st_ts_iter=..] kv_writes=.. kv_gets=.. kv_iterated=..
       kv_checksum=0x........ kv_iter_checksum=0x........ ts_appends=..
       ts_iterated=.. ts_checksum=0x........ [cycles_src=dwt|systick
       cycles_tick_hz=.. cycles_calib_insn=.. cycles_calib_ticks=..
       cycles_mount=.. cycles_kv=.. cycles_ts=.. cycles_total=..
       [cyc_st_set=.. ...]] rc=0
```

| field | meaning |
|---|---|
| `text`, `rodata`, `data`, `bss` | section sizes from linker symbols; cross-checked against `llvm-size -A` |
| `sim_flash` | size of the NOLOAD simulated-NOR region: **not** MCU ROM or RAM |
| `stack` | worst-case stack high-water of the whole run (init + workload), from the 0xA5 paint scan, 8-byte rounded |
| `stack_init` | high-water right after database init (= mount/init phase alone) |
| `stack_limit` | size of the painted stack region (8 KiB) |
| `st_*` | isolated per-phase peaks (diagnostic build only) |
| `kv_writes` | KV sets issued by the workload: 64 + 32 + 1500 = 1596 |
| `kv_gets` | KV gets, each verified against the expected value: 64 |
| `kv_iterated` | entries seen by the full KV iteration: 64 |
| `kv_checksum` | FNV-1a-32 over the 64 values in key-index order |
| `kv_iter_checksum` | FNV-1a-32 over (name, value) in iteration order |
| `ts_appends` | TS appends: 200 |
| `ts_iterated` | entries seen by the full TS iteration: 200 |
| `ts_checksum` | FNV-1a-32 over the 200 payloads in forward iteration order |
| `cycles_src` | `dwt` (real silicon), `systick` (QEMU proxy) or `none` |
| `cycles_tick_hz` | SysTick clock of the proxy: 25000000 (0 for DWT) |
| `cycles_calib_insn` / `cycles_calib_ticks` | calibration spin: exactly 20000 instructions took N SysTick ticks (500 under `-icount shift=0`) |
| `cycles_mount` | cycle/tick delta of `databases_init()` (FAL init + KVDB/TSDB mount) |
| `cycles_kv` | delta of the whole KV phase (set/update/churn/get/iterate) |
| `cycles_ts` | delta of the whole TS phase (200 appends + iterate) |
| `cycles_total` | `cycles_mount + cycles_kv + cycles_ts` |
| `cyc_st_*` | cycle deltas of the diagnostic per-phase loops |
| `rc` | 0 = workload completed; 1 = a harness stage failed (an `ERROR` line says which) |

## What the numbers mean

* **ROM** = `.text` + `.rodata` + `.data` (the `.data` initialiser image is
  loaded from ROM).  The 32 KiB `.sim_flash` NOLOAD region is excluded: it
  models an external NOR chip, not on-chip flash.
* **static RAM** = `.data` + `.bss`.  The 8 KiB painted stack is *not* part of
  the static footprint; it is measured separately as `stack`.
* ROM/static RAM are taken from `llvm-size -A` on the ELF **and** from the
  linker symbols inside the firmware; the script requires both to agree.
* **stack** is the low-water mark of the 0xA5 pattern painted over
  `[_stack_bottom, _estack)` by the reset handler before `main()`.  The
  headline scan runs after the workload has returned to `main`, so the deepest
  frame is still visible.  Caveats: a word that happens to hold 0xA5A5A5A5 is
  invisible (can only under-report), interrupts are never enabled, and usage
  beyond the 8 KiB region would corrupt memory instead of being measured.
* **cycles** are CPU cycles on real silicon (DWT.CYCCNT).  **QEMU 8.2 does
  not model the DWT** on mps2-an385 (probe: DEMCR and DWT_CTRL read 0 and
  CYCCNT never advances), so `firmware/common/cycles.c` probes the DWT once
  and falls back to the SysTick 24-bit down-counter.  Under
  `qemu-system-arm -icount shift=0` one emulated instruction consumes one
  virtual nanosecond and SysTick (25 MHz) ticks every 40 instructions, which
  makes the phase deltas deterministic.  Read QEMU numbers as a
  **deterministic instruction-count proxy** (use ratios C vs Zig, not
  absolute "cycles"); the same module on real Cortex-M3 hardware reports true
  DWT cycles with `cycles_src=dwt`.
* The cycle counter is free-running and read around each phase; phases must
  stay below 2^24 SysTick ticks (~670M instructions) for a delta to be
  unambiguous, which the workload does by a wide margin.  `cycles_total` is
  the sum of the phase deltas, not a raw counter snapshot, so boot and RESULT
  printing are excluded.

## Workload (identical in C and Zig)

`firmware/common/workload_spec.h` is the shared contract:

| phase | operation |
|---|---|
| KVDB | 64 x `fdb_kv_set` (`kv.XX` = 24-byte value), 32 x update, 1500 x churn over 16 keys (forces GC), 64 x get + full value verification, full iteration + checksum |
| TSDB | 200 x `fdb_tsl_append_with_ts` (16-byte payload, fake clock 1000+i), full forward iteration + checksum |
| geometry | 32 KiB simulated NOR, 4 KiB erase blocks; KVDB partition 16 KiB @ 0, TSDB partition 16 KiB @ 16 KiB; TSDB `max_len` = 64 |

Data generation is deterministic and pure (no RNG/clock):

```
kv key  : "kv." + 2 hex digits of the key index (6 chars + NUL)
kv value: "v" + 4 hex digits of generation + "-" + 2 hex digits of index + "-"
          + (24-9) hex digits derived from index/generation  (24 bytes)
ts payload: u32 LE index, u32 LE timestamp, bytes 8..15 = (idx*31 + k*7) & 0xFF
```

Checksums are FNV-1a-32 (`h = 0x811C9DC5; h = (h ^ byte) * 0x01000193`).

## Baseline numbers (pinned toolchain, this machine)

`pwsh -NoProfile -File scripts/build_fw_c.ps1`, `zig cc 0.18.0-dev.753+1420479be`,
`-target thumb-freestanding-eabi -mcpu=cortex_m3 -Os`, QEMU 8.2.0
(`-M mps2-an385 -cpu cortex-m3 -semihosting -icount shift=0`):

| variant | .text | .rodata | .data | .bss | ROM | static RAM |
|---|---|---|---|---|---|---|
| `plain` | 11032 | 1612 | 56 | 1088 | 12700 | 1144 |
| `instrumented` | 12596 | 1964 | 56 | 1096 | 14616 | 1152 |

| variant | stack | stack_init | limit |
|---|---|---|---|
| `plain` | 1208 | 472 | 8192 |
| `instrumented` | 1288 | 552 | 8192 |

Instrumented variant, per-phase stack peaks / cycle deltas:

| phase | stack peak | cycles (SysTick ticks) |
|---|---|---|
| single set | 752 | 508 |
| single get | 792 | 366 |
| full KV iteration | 616 | 6025 |
| GC churn (1500 sets) | 1328 | 436914 |
| one TS append | 584 | 350 |
| full TS iteration | 656 | 2719 |

Headline cycles: `cycles_mount=6589`, `cycles_kv=520236`, `cycles_ts=5776`,
`cycles_total=532601` ticks with `cycles_src=systick`,
`cycles_calib_insn=20000`, `cycles_calib_ticks=500`
(40 instructions/tick, so `cycles_kv` ~ 20.8M instructions).

Checksums (both variants, both runs):
`kv_checksum=0x4b3486a4`, `kv_iter_checksum=0x0e250daa`,
`ts_checksum=0x10d90680`.
Counts: `kv_writes=1596`, `kv_gets=64`, `kv_iterated=64`, `ts_appends=200`,
`ts_iterated=200`, `rc=0`.

Runs are bit-identical under `-icount shift=0` (the script runs every variant
twice and requires an identical RESULT line).

## JSON document (`bench/results/c_firmware.json`)

```
{
  "impl": "c", "version": "fdb-2.2.99",
  "target": "thumb-freestanding-eabi", "cpu": "cortex_m3",
  "machine": "mps2-an385", "opt": "Os", "write_gran": 8,
  "compiler": "zig cc 0.18.0-dev.753+1420479be",
  "toolchain": { zig, zig_version, size_tool, qemu },
  "flags": { cycles, phases, cflags[], cycles_define, phases_define,
             qemu[], cycle_note },
  "workload": { ...constants from workload_spec.h... },
  "variants": {
    "plain":        { elf, sections{text,rodata,data,bss}, rom, static_ram,
                      stack, stack_init, stack_limit, results{...},
                      result_line, qemu{exit_code,log}, repeatable },
    "instrumented": { ...same..., stack_phases{...}, cycles{source, tick_hz,
                      calib_insn, calib_ticks, mount, kv, ts, total,
                      phases{...}} }
  }
}
```

The `plain` variant has no `cycles` key.  `-Cycles:$false -Phases:$false`
builds only `plain`.

## Comparing with the Zig firmware

The Zig firmware should print the same RESULT fields (at least `stack`,
`kv_checksum`, `kv_iter_checksum`, `ts_checksum`, `cycles_total` and the four
section sizes) and be built/run with the same QEMU flags.  Compare:

* checksums and result counts must be **identical**;
* `.text`/`.rodata`/`.data`/`.bss`, ROM and static RAM should be **<=** the C
  values for the same variant/instrumentation;
* `stack` and `stack_init` should be **<=** the C values;
* `cycles_total` (and per-phase deltas) should be **<=** the C values for the
  same QEMU configuration (`-icount shift=0` is required for determinism).

Because `-icount shift=0` maps one instruction to one virtual nanosecond, the
QEMU cycle numbers are a deterministic instruction-count proxy; always compare
ratios on the same QEMU/toolchain, never against silicon cycle expectations.

## Portability notes (pinned Zig nightly + Windows)

1. **Compiler**: `zig cc -target thumb-freestanding-eabi -mcpu=cortex_m3`.
   No `-mthumb`/`-mfloat-abi=soft` flags are needed or accepted as on GCC: the
   target triple implies Thumb + soft-float.  The CPU name is Zig-style
   (`cortex_m3`, underscore) and follows `-mcpu=` with an equals sign.
2. **Entry point**: `-Wl,-e,Reset_Handler` is passed explicitly.  Without it
   zig's linker warns `cannot find entry symbol _start` and leaves the ELF
   entry unset; QEMU still boots through the vector table at address 0, but the
   explicit entry keeps the ELF correct.
3. **No libgcc/compiler_rt on the C side**: Clang lowers `memset`/`memcpy`
   calls on ARM to the EABI entry points `__aeabi_memclr4`, `__aeabi_memcpy`,
   ... which normally come from libgcc.  `firmware/c/libc_stubs.c` provides
   them (they forward to the tiny local `memset`/`memcpy`), keeping the image
   `-nostdlib` and self-contained.  The Zig firmware gets the equivalent
   helpers from Zig's compiler_rt/freestanding-libc surface, so both carry a
   comparable baseline.
4. **No linker map**: zig's linker-arg parser rejects `-Wl,-Map`, so the
   scripts do not emit a map file; size attribution comes from `llvm-size -A`
   and the linker symbols printed in RESULT.  The linked ELF also has no
   symbol table, so `llvm-nm` cannot be used on it (not needed).
5. **DWT not modelled by QEMU 8.2**: `cycles.c` keeps the real DWT path for
   silicon and uses the SysTick proxy under QEMU; see above.
6. **Linker script**: `ENTRY(Reset_Handler)` plus `.vectors` KEEP ensures the
   vector table is at address 0 (QEMU takes the initial MSP from 0x00000000
   and the reset PC from 0x00000004).  The 8 KiB stack is the top of SRAM and
   is painted twice by the startup code (boot then immediately before `main`)
   so boot code is not charged to the workload.
7. **`.sim_flash` is NOLOAD**: the 32 KiB NOR simulator backing store lives in
   a separate SRAM bank at `0x00100000`, so it never inflates static RAM or
   the ELF image.
8. **Adaptation from the sibling Rust project's harness**: the C workload,
   startup, linker script, semihosting and stack modules were taken from the
   flashdb-rs firmware harness and adapted: board-specific code
   (`FDB_BOARD_U545`, DWT-on-silicon result buffer, rollover phase) removed,
   `cycles.c/.h` added, RESULT extended with cycle/phase fields, and the
   simulated NOR partitioned 16 KiB + 16 KiB inside the 32 KiB device.  The
   workload constants and data generation are unchanged, and the checksums
   match the sibling project's C firmware exactly
   (`0x4b3486a4 / 0x0e250daa / 0x10d90680`).
