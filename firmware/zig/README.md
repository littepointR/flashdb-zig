# Zig firmware measurement image (Cortex-M3 / QEMU MPS2-AN385)

The Zig counterpart of `firmware/c/main.c`: a freestanding Zig firmware for
`thumb-freestanding-eabi` (`cortex_m3`, `-O ReleaseSmall`) that runs the
**identical** deterministic workload from `firmware/common/workload_spec.h` on
the Zig FlashDB implementation (`src/flashdb.zig`) and prints the **identical**
single semihosting `RESULT ... rc=0` line, so ROM (`.text+.rodata+.data`),
static RAM (`.data+.bss`), stack high-water, cycle proxy and workload checksums
can be compared field by field against `bench/results/c_firmware.json`.

Status: **phase 2 complete** -- KVDB + TSDB workload, same checksums as C:

```
kv_writes=1596 kv_gets=64 kv_iterated=64
kv_checksum=0x4b3486a4 kv_iter_checksum=0x0e250daa
ts_appends=200 ts_iterated=200 ts_checksum=0x10d90680
rc=0
```

`firmware/zig/build.ps1` verifies the full RESULT line, cross-checks the
section sizes against `llvm-size -A`, runs every variant twice, writes
`bench/results/zig_firmware.json` and exits non-zero on any failure.

Phase 1 (KVDB only, TSDB not exported yet) was an intermediate snapshot
(`ts_appends=0 ts_iterated=0 ts_checksum=0`): those numbers are superseded by
the KV+TS numbers below and are not apples-to-apples with the C reference
(which always ran KV+TS). The JSON records the scope explicitly:
`"workload_scope": "kv+ts"` and `"workload": {"includes": ["kvdb","tsdb"]}`
(it was `"kv-only"` / `["kvdb"]` during phase 1).

## Files

```
firmware/zig/
  fw.zig                  shared workload: statics, data generation, KVDB/TSDB
                          phases, harness ABI (extern struct + extern fns)
  main.zig                root: plain build (no instrumentation)
  main_instrumented.zig   root: cycles + phases (== C -DFW_CYCLES=1 -DHARNESS_STACK_PHASES=1)
  main_cycles.zig         root: cycles only      (== C -DFW_CYCLES=1)
  main_phases.zig         root: phases only      (== C -DHARNESS_STACK_PHASES=1)
  build.ps1               build -> size -> run QEMU x2 -> validate -> JSON
  README.md               this file
```

Generated artefacts: `build/fw/zig_<variant>.o`, `build/fw/fw_zig_<variant>.elf`,
`build/fw/qemu_zig_<variant>.log`, `bench/results/zig_firmware.json`.

## Commands

Run from the repository root:

```powershell
# Default: build + size + run BOTH variants (plain, instrumented) twice,
# validate, write bench/results/zig_firmware.json.
pwsh -NoProfile -File firmware/zig/build.ps1

# Build and print llvm-size only (no QEMU, no JSON)
pwsh -NoProfile -File firmware/zig/build.ps1 -BuildOnly

# Plain image only (no instrumented variant at all):
pwsh -NoProfile -File firmware/zig/build.ps1 -Cycles:$false -Phases:$false

# Other instrumentation combinations (mirror the C script's -Cycles/-Phases):
pwsh -NoProfile -File firmware/zig/build.ps1 -Cycles:$false            # phases only
pwsh -NoProfile -File firmware/zig/build.ps1 -Phases:$false            # cycles only

# Report to another JSON path (does not clobber the committed result):
pwsh -NoProfile -File firmware/zig/build.ps1 -OutJson build/fw/zig_tmp.json
```

The script's exit status is 0 only when both builds link, both QEMU runs print
exactly one `RESULT ... rc=0` line, the RESULT section sizes equal
`llvm-size -A`, the workload counts/checksums match the C reference, the stack
high-water fits the 8 KiB stack, the DWT/SysTick probe and `-icount`
calibration are valid, and two consecutive runs print an identical RESULT line.
A hang (hard fault, missing vector table), a missing RESULT, `rc!=0` or any
inconsistency fails loudly and exits non-zero.

## Exact build pipeline

Two stages, exactly the split the C image uses (the C script compiles the
harness C and the library in one `zig cc` invocation; here the workload/DB must
be a separate Zig object because it is Zig, not C):

```powershell
# 1. Zig workload + database -> relocatable object
.tools\zig\zig.exe build-obj -target thumb-freestanding-eabi -mcpu=cortex_m3 `
    -O ReleaseSmall --dep flashdb `
    -Mroot=firmware/zig/main.zig -Mflashdb=src/flashdb.zig `
    -femit-bin=build/fw/zig_plain.o

# 2. C harness (unmodified) + Zig object -> final ELF
.tools\zig\zig.exe cc -target thumb-freestanding-eabi -mcpu=cortex_m3 -Os `
    -std=gnu11 -w -ffunction-sections -fdata-sections -fno-common `
    -fno-builtin -fno-stack-protector -ffreestanding `
    -fno-asynchronous-unwind-tables -fno-unwind-tables `
    -Wl,--gc-sections `
    -Wl,-T,firmware/common/mps2_an385.ld -Wl,-e,Reset_Handler `
    firmware/common/startup_armv7m.S firmware/common/semihost.c `
    firmware/common/cycles.c firmware/common/stack.c `
    build/fw/zig_plain.o -o build/fw/fw_zig_plain.elf
```

The instrumented variant is the same two commands with
`main_instrumented.zig` as the root (or `main_cycles.zig` / `main_phases.zig`)
and `-DFW_CYCLES=1 -DHARNESS_STACK_PHASES=1` (or the matching subset) on the C
harness sources.

The reset handler's `bl main` is satisfied by `export fn main() callconv(.c)
noreturn` in the Zig root file; no C shim is needed. `firmware/common`
(vectors, reset handler, semihosting, cycle counter, stack painting, linker
script) is used **unmodified**; the only Zig-side additions are the workload,
the extern declarations and the `metrics` struct layout (see below).

## QEMU run

```powershell
& 'D:\Program Files\qemu\qemu-system-arm.exe' -M mps2-an385 -cpu cortex-m3 `
    -nographic -semihosting -icount shift=0 -kernel build/fw/fw_zig_plain.elf
```

`-icount shift=0` is required: it makes the SysTick virtual-time proxy
deterministic (1 instruction = 1 virtual ns, 25 MHz SysTick = 40
instructions/tick), so two runs print a bit-identical RESULT line.
`-semihosting` is required or `bkpt 0xab` traps to the hard-fault handler.

Sizes: `llvm-size -A build/fw/fw_zig_plain.elf` (the script cross-checks these
against the linker-symbol sizes printed in RESULT, exactly like the C script).

## Fairness / harness reuse

* `firmware/common/{startup_armv7m.S,semihost.c,cycles.c,stack.c}` and
  `firmware/common/mps2_an385.ld` are compiled **unmodified** into both the C
  and the Zig image; the harness overhead (vector table, reset/paint code,
  semihosting formatters, cycle counter, stack scan, memory map) is byte
  identical on both sides.
* The Zig image calls those helpers through `extern` declarations mirroring
  `firmware/common/*.h` one-for-one (`struct harness_metrics` is declared as
  four `extern struct`s, one per `FW_CYCLES` x `HARNESS_STACK_PHASES`
  combination, with fields in the C declaration order).
* The C image links `-nostdlib` plus `firmware/c/libc_stubs.c` (EABI
  `mem*` helpers). The Zig image links Zig's `compiler_rt`/freestanding libc
  surface instead (`zig cc` default) -- the same "comparable baseline"
  documented in `firmware/README.md` portability note 3. This is also
  *required*: the Zig library lowers 64-bit shifts to
  `__aeabi_llsl`/`__aeabi_llsr`, which `libc_stubs.c` does not provide.
  (Keeping `-nostdlib` + `libc_stubs.c` and adding the two 64-bit helpers
  manually was measured ~60 B larger `.text` and is not used.)
* Everything else that differs between the images is the workload plus the
  database itself, which is the point of the measurement.

## Measurement definitions (identical to `firmware/README.md`)

* **ROM** = `.text` + `.rodata` + `.data`; **static RAM** = `.data` + `.bss`.
  The 32 KiB `.sim_flash` region is `NOLOAD` in the shared linker script (the
  backing store of the simulated external NOR) and is *not* counted; the Zig
  image places its 32 KiB array there with
  `linksection(".sim_flash") align(4096)`, so `sim_flash=32768` matches C.
* **stack** / `stack_init` = 0xA5-painted stack high-water of the whole run /
  after database init; `stack_limit=8192` is the painted region.
* **cycles** = QEMU SysTick virtual-time proxy ticks (C's `cycles.c` probes DWT,
  falls back to SysTick on QEMU); `cycles_src=systick`,
  `cycles_tick_hz=25000000`, `cycles_calib_insn=20000`,
  `cycles_calib_ticks=500`, `cycles_total = mount + kv + ts`.
* `st_*` / `cyc_st_*` per-phase numbers are diagnostic only (repainting erases
  earlier marks); the headline `stack` scan runs before the diagnostics, so
  they never affect it. A per-phase peak can therefore exceed the headline
  `stack` value (same caveat as C).

## Final results (KVDB + TSDB, apples-to-apples with C)

Measured with the pinned toolchain
(`zig 0.18.0-dev.753+1420479be`, `-O ReleaseSmall` workload + `-Os` C harness,
QEMU 8.2 `-M mps2-an385 -cpu cortex-m3 -semihosting -icount shift=0`) on
2026-11-01 with a dirty `src/**` working tree; the exact revision of a given
run is recorded in `bench/results/zig_firmware.json`
(`toolchain.git_revision` / `toolchain.git_dirty`). Numbers depend on the
current `src/` revision: `build.ps1` re-measures and rewrites that JSON.

C baseline from `bench/results/c_firmware.json` (identical workload):

| variant | .text | .rodata | .data | .bss | ROM | static RAM | stack | stack_init |
|---|---|---|---|---|---|---|---|---|
| C plain | 11032 | 1612 | 56 | 1088 | 12700 | 1144 | 1208 | 472 |
| **Zig plain** | **10140** | **1568** | **24** | **736** | **11732** | **760** | **800** | **416** |
| C instrumented | 12596 | 1964 | 56 | 1096 | 14616 | 1152 | 1288 | 552 |
| **Zig instrumented** | **12444** | **1956** | **32** | **752** | **14432** | **784** | **880** | **512** |

Deltas (Zig vs C): plain ROM **-968 B (-7.6%)**, static RAM **-384 B
(-33.6%)**, stack **-408 B (-33.8%)**, `stack_init` -56 B; instrumented ROM
**-184 B (-1.3%)**, static RAM **-368 B (-32.0%)**, stack **-408 B (-31.7%)**,
`stack_init` -40 B.

Instrumented per-phase stack peaks / cycle deltas:

| phase | Zig stack | C stack | Zig cycles | C cycles |
|---|---|---|---|---|
| single set | 976 | 752 | 373 | 508 |
| single get | 904 | 792 | 352 | 366 |
| full KV iteration | 752 | 616 | 3219 | 6025 |
| GC churn (1500 sets) | 976 | 1328 | 120882 | 436914 |
| one TS append | 648 | 584 | 346 | 350 |
| full TS iteration | 824 | 656 | 2602 | 2719 |

Headline instrumented cycles: `cycles_mount=5147` (C 6589), `cycles_kv=161802`
(C 520236), `cycles_ts=5768` (C 5776), **`cycles_total=172717`** (C 532601,
**-67.6%**). All cycle numbers are SysTick proxy ticks under
`-icount shift=0`, exactly as on the C side.

Headline stack: `stack=880` (C 1288), `stack_init=512` (C 552). The KV/TS
per-phase peaks are diagnostic and measured in the second (repaint) pass;
they are slightly above the headline for the KV phases (+11..+30%) and below
for the GC phase (-27%), but the headline whole-run high-water is well under
C's.

## Reproducibility

* Every variant is run **twice** and the script requires the two RESULT lines
  to be identical (hard fail otherwise).
* Two full `build.ps1` runs produce a byte-identical
  `bench/results/zig_firmware.json` (checked on this machine).
* QEMU wall time per run is ~0.15-0.25 s, so the whole script (2 variants x
  2 runs + builds) finishes in a few seconds.

## JSON document

`bench/results/zig_firmware.json` mirrors `bench/results/c_firmware.json`
(`impl="zig"`, `version="flashdb-zig"`, `workload_scope`, `target`, `cpu`,
`machine`, `opt`, `write_gran`, `compiler`,
`toolchain{zig,zig_version,size_tool,qemu,c_harness_compiler,git_revision,
git_dirty}`, `flags{cycles,phases,zig_obj_cflags,cflags,zig_runtime,
harness_sources,zig_sources,cycles_define,phases_define,qemu,cycle_note,
fairness_note}`, `workload{includes,...}`, `variants{plain,instrumented}` with
`sections`, `rom`, `static_ram`, `stack`, `stack_init`, `stack_limit`,
`results`, `result_line`, `qemu{exit_code,log}`, `repeatable`, and for the
instrumented variant `stack_phases` and `cycles{source,mount,kv,ts,total,
tick_hz,calib_insn,calib_ticks,phases{...}}`).

## Zig 0.18 / freestanding notes (things that needed adapting)

1. **Module imports**: Zig forbids `@import("../../src/flashdb.zig")` ("import
   of file outside module path"). The workload root is therefore compiled with
   the module CLI:
   `--dep flashdb -Mroot=firmware/zig/main.zig -Mflashdb=src/flashdb.zig`,
   and `fw.zig` imports `@import("flashdb")`.
2. **Entry point**: `export fn main() callconv(.c) noreturn`; the shared
   `Reset_Handler` calls `bl main`. (Plain `export fn main() noreturn` also
   works and implies the C calling convention.)
3. **Panic handler**: each root declares `pub const panic = std.debug.no_panic;`
   (a `@trap()` stub). `ReleaseSmall` disables safety checks, so in practice no
   panic path is emitted and no extra ROM is spent; the declaration keeps the
   compile clean and traps instead of pulling in a formatter if one ever
   appears.
4. **Runtime helpers**: Zig emits `__aeabi_mem*` for `@memcpy`/`@memset` and
   `__aeabi_llsl/llsr` for 64-bit shifts; they come from Zig's `compiler_rt`
   (do not pass `-nostdlib` to the link step, unlike the pure-C image).
5. **`.sim_flash` placement**: `var g_sim_flash: [32768]u8 align(4096)
   linksection(".sim_flash") = undefined;` puts the NOR backing store in the
   shared linker script's `NOLOAD` region, so it is excluded from ROM and static
   RAM exactly like `firmware/c/fal_ram_sim.c`.
6. **No `std.fmt` / allocators / `std.io`** in the firmware: the workload only
   uses `std.mem.eql`, `std.mem.zeroes` and `std.debug.no_panic`; the
   freestanding image stays self-contained.
7. **`-ffunction-sections` is a C-side flag here**: passing it to `zig
   build-obj` in this nightly trips the CLI ("found another zig file ..."); the
   Zig object does not need it because Zig only emits referenced declarations
   and `--gc-sections` runs at link time anyway.
8. **Adding a module twice is rejected**: `src/tsdb.zig` cannot be compiled as
   a second module next to `src/flashdb.zig` because both claim
   `src/format.zig` ("file exists in modules ..."). The firmware therefore
   imports only `flashdb` and gets `Tsdb` from there; the phase-2 workload is
   gated at comptime by `@hasDecl(flashdb, "Tsdb")`.

## Relation to the C harness

Both images are built/run with the same QEMU flags and report the same RESULT
fields. Compare:

* checksums and result counts must be identical (they are);
* `.text/.rodata/.data/.bss`, ROM, static RAM, `stack`, `stack_init` should be
  **<=** the C values for the same variant/instrumentation (they are);
* `cycles_total` and the per-phase deltas should be **<=** the C values for the
  same QEMU configuration (they are, except the per-phase diagnostics noted
  above which are not directly comparable to the headline scan).

C reference: `bench/results/c_firmware.json`; harness contract:
`firmware/README.md` and `firmware/common/workload_spec.h`.
