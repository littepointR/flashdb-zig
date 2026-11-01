# C reference benchmark harness (host)

Baseline implementation for the FlashDB -> Zig comparison protocol in
[`../SCENARIOS.md`](../SCENARIOS.md).  This directory builds the **unmodified
upstream FlashDB 2.2.99 sources** from `reference/FlashDB/` against a RAM-backed
NOR simulator and runs every scenario, emitting one JSON document per
(`FDB_WRITE_GRAN`, optimization) pair.

Nothing under `reference/FlashDB/` is modified; the harness supplies the two
missing configuration headers (`fdb_cfg.h`, `fal_cfg.h`), the FAL flash device /
partition tables and the simulator (`sim_flash.c`).

The Zig rewrite is compared against these numbers with
[`tools/compare_bench.py`](../../tools/compare_bench.py).

## Toolchain

The C compiler is the **pinned Zig nightly** used as a C compiler (`zig cc`):

```
.tools/zig/zig.exe        # 0.18.0-dev.753+1420479be, recorded in toolchain.lock.json
```

No system C compiler, make, or POSIX layer is needed on Windows: `zig cc`
bundles Clang + MinGW headers and `clock_gettime(CLOCK_MONOTONIC)` works.  The
build scripts use the absolute path `<repo>/.tools/zig/zig.exe`.

## Files

| file | purpose |
|---|---|
| `fdb_cfg.h` | FAL mode, KVDB+TSDB, caches pinned to 64/8, no `FDB_DEBUG_ENABLE`, `FDB_WRITE_GRAN` supplied by `-D` |
| `fal_cfg.h` | one 32 KiB NOR device `norflash0`, partitions `fdb_kvdb1` (offset 0, 16 KiB) and `fdb_tsdb1` (offset 16 KiB, 16 KiB) |
| `sim_flash.h/.c` | RAM NOR simulator + FAL device ops, op/byte accounting, fault-injection hook, library log routing |
| `bench.h` / `bench_common.c` | timing (`CLOCK_MONOTONIC`), FNV-1a-32 checksums, snapshot helpers, measured-phase accounting, JSON writer |
| `bench_kv.c` | KV scenarios |
| `bench_ts.c` | TS scenarios |
| `bench.c` | entry point, `--mode bench|check|probe` |

## Commands

All commands are run from the repository root (`D:\...\flashdb-zig`).

```powershell
# Build + run the four host variants, print the summary table, write JSON.
#   build/c/c_bench_wg{8,1}_{O2,Os}.exe
#   bench/results/c_wg{8,1}_host.json       (-O2)
#   bench/results/c_wg{8,1}_host_os.json    (-Os)
pwsh -NoProfile -File scripts/build_bench_c.ps1

# Behavioural self-checks (simulator, KVDB, TSDB, rollover, determinism).
pwsh -NoProfile -File scripts/check_bench_c.ps1

# Single variant by hand (what the scripts do):
.tools/zig/zig.exe cc -std=c99 -O2 -w `
    -DFDB_WRITE_GRAN=8 -DBENCH_OPT=O2 `
    -DBENCH_HOST='"zig-cc-0.18.0-dev.753-windows-x86_64"' `
    -I bench/c -I reference/FlashDB/inc -I reference/FlashDB/port/fal/inc `
    bench/c/bench.c bench/c/bench_common.c bench/c/bench_kv.c bench/c/bench_ts.c `
    bench/c/sim_flash.c `
    reference/FlashDB/src/fdb.c reference/FlashDB/src/fdb_kvdb.c `
    reference/FlashDB/src/fdb_tsdb.c reference/FlashDB/src/fdb_utils.c `
    reference/FlashDB/port/fal/src/fal.c `
    reference/FlashDB/port/fal/src/fal_flash.c `
    reference/FlashDB/port/fal/src/fal_partition.c `
    -o build/c/c_bench_wg8_O2.exe

build/c/c_bench_wg8_O2.exe --mode bench --runs 5 --out bench/results/c_wg8_host.json
build/c/c_bench_wg8_O2.exe --mode check
build/c/c_bench_wg8_O2.exe --mode probe
```

`--mode check` exits non-zero on the first failed invariant (it prints one
`PASS <check>` line per invariant and `== OK: 0 check(s) failed ==`).

### Compile flags

```
-std=c99 -O2|-Os -w
-DFDB_WRITE_GRAN=8|1
-DBENCH_OPT=O2|Os          # recorded in the JSON ("opt")
-DBENCH_HOST="zig-cc-<version>-windows-x86_64"   # recorded in the JSON
-I bench/c -I reference/FlashDB/inc -I reference/FlashDB/port/fal/inc
```

`-w` suppresses the large number of upstream `pointer-to-int-cast` warnings
(FlashDB is written for 32-bit MCUs); they are not actionable for the host
measurement and would drown the build output.

Library logging is **off by default** (`FDB_DEBUG_ENABLE` undefined and
`FDB_PRINT`/`FAL_PRINTF` are routed to a disabled stderr logger); set
`C_HARNESS_VERBOSE=1` to see upstream logs.  stdout is reserved for the JSON
document.

## Flash simulator semantics and accounting

* 32 KiB RAM device, 4096-byte erase blocks, starts fully erased (0xFF).
* **write** = bitwise AND with the new data (only 1 -> 0; attempts to set a
  bit are counted and do not fail, like real NOR).
* **erase** must be 4096-byte aligned and sized; sets the range to 0xFF.
* Counters `reads, read_bytes, writes, write_bytes, erases, erase_bytes` are
  incremented per successful FAL op; `erase_bytes` counts erased bytes (not
  blocks).  Counters are reset after each scenario's setup and snapshotted
  immediately after the timed phase; a checksum/verification afterwards does
  not pollute them.
* Fault injection: `sim_fault_arm(n)` lets n ops succeed, then fails every op
  with `-1` without touching memory (power-cut hook for the equivalence tests).

## Scenario definitions

All values are produced by:

```
kv_value(seed, i, len):  buf[j] = (uint8_t)(seed + i*31 + j*7)
ts_payload(i):           buf[j] = (uint8_t)(0x5A + i*13 + j*5)   (32 bytes)
TS timestamps:           t_i = 1000 + i (strictly increasing)
```

| scenario | ops | setup (excluded) | measured phase |
|---|---|---|---|
| `kv_set_small` | 64 | format | k=0..63: set `"kv{k%8}"` = `kv_value(0x11,k,8)` |
| `kv_update_1k` | 1000 | format, set `counter`=`kv_value(0x22,0,32)` | k=0..999: set `counter`=`kv_value(0x22,k,32)` |
| `kv_get_hot` | 2000 | 32 keys `"key{i}"`=`kv_value(0x33,i,32)` + 128 warmup gets | 2000 gets `key{k%32}` into 64 B buf; hits = returned>0 |
| `kv_get_miss` | 500 | same populated DB | 500 gets `"absent{i}"`, i=0..499 |
| `kv_delete` | 192 | same populated DB | 3 rounds x 32 keys x {delete(key_i); set(key_i, kv_value(0x33,i,32))} = 96 del + 96 set |
| `kv_iterate` | 100 | same populated DB | 100 x full iterate, count entries + sum `value_len` (values not read) |
| `kv_mount` | 100 | same populated DB | 100 x (deinit + init), count successes |
| `kv_large` | 50 | format | k=0..49: set `"big"`=`kv_value(0x44,k,1024)` |
| `tsl_append` | successes | format, rollover off | append t=1000+i until `FDB_SAVED_FULL` or 4000; calls include the full-detection call |
| `tsl_append_rollover` | 3xcapacity | format, rollover on | 3 x capacity appends, t=1000+i |
| `tsl_iter_fwd` | 20 | populate to full | 20 x forward iterate, count + sum payload len |
| `tsl_iter_rev` | 20 | populate to full | 20 x reverse iterate |
| `tsl_by_time` | 500 | populate to full | 500 x `iter_by_time(from,to)` with the protocol LCG ranges |
| `tsl_query_count` | 500 | populate to full | 500 x `query_count(from,to,WRITE)`, same ranges |
| `tsl_mount` | 50 | populate to full | 50 x (deinit + init) |
| `tsl_clean` | 20 | populate to full | 20 x (clean + repopulate to full) |

"Populate to full" = append with increasing timestamps until the DB reports
`FDB_SAVED_FULL` (rollover disabled).  The `tsl_append_rollover` capacity is
measured once in a setup-phase probe (append-to-full count, reported as
`extra.capacity`); the measured phase issues exactly `3*capacity` appends.

LCG for the ranged queries:

```
state = 12345
next(): state = (state * 1103515245 + 12345) mod 2^31
per query: off = next() % 3000; len = 50 + next() % 451
           from = 1000 + off; to = from + len   (inclusive)
```

## Checksums

FNV-1a **32-bit**, reported as a decimal number:
`hash = 0x811C9DC5; for each byte: hash = (hash ^ b) * 0x01000193 (wrapping)`.

Per scenario:

| scenarios | checksum input |
|---|---|
| `kv_*` | KV snapshot: `u32(entry_count)` then entries **sorted by key**: `u32(key_len)`, key bytes, `u32(value_len)`, value bytes.  For `kv_get_hot/miss` this checks the stored state (unchanged by reads); `kv_delete`/`kv_iterate`/`kv_mount` check the final state. |
| `tsl_append`, `tsl_append_rollover`, `tsl_iter_fwd`, `tsl_iter_rev`, `tsl_clean` | TS snapshot: forward-iteration records `u32(status)`, `u32(time)`, `u32(log_len)`, payload bytes; then `u32(entry_count)`. |
| `tsl_by_time`, `tsl_query_count` | `u32(500)`, then `u32(count_of_query_q)` for q=0..499. |
| `tsl_mount` | TS snapshot taken **immediately before** the mount phase, plus `extra.mount_ok`. |

The u32 serialisation is little-endian (`b0 = v & 0xFF`, ...).

## JSON document

One object per build/variant (stdout **and** the `--out` file):

```json
{
  "impl": "c",
  "version": "fdb-2.2.99",
  "opt": "O2",
  "write_gran": 8,
  "config": {
    "write_gran": 8, "write_gran_bytes": 1, "sector_size": 4096,
    "sectors_per_db": 4, "partition_size": 16384,
    "partitions": ["fdb_kvdb1", "fdb_tsdb1"],
    "kv_cache_table_size": 64, "sector_cache_table_size": 8,
    "debug_log": false, "ts_timestamp_bits": 32, "ts_max_log_len": 32,
    "runs": 5, "opt": "O2", "compiler": "...", "host": "...", "cflags": "..."
  },
  "footprint": {"sizeof_kvdb": 1064, "sizeof_tsdb": 160, "...": "..."},
  "semantics": { "...machine-readable notes about formulas/checksums..." },
  "scenarios": [
    {
      "name": "kv_update_1k",
      "ops": 1000,
      "hits": 0,
      "total_ns_median": 361000,
      "ns_per_op": 361.0,
      "runs": 5,
      "checksum": 2676218997,
      "errcodes": {"ok": 1000},
      "flash": {"reads": 7823, "read_bytes": 231708, "writes": 7089,
                "write_bytes": 63243, "erases": 14, "erase_bytes": 57344},
      "extra": {"samples_ns": ["..."], "total_ns_min": 0, "total_ns_max": 0,
                "flash_consistent": true, "errs_consistent": true}
    }
  ]
}
```

* `total_ns_median` is the median of the `runs` measured-phase wall-clock
  durations in ns; `ns_per_op = total_ns_median / ops`.
* `errcodes` counts the `fdb_err_t` return codes observed **during the measured
  phase**, only for non-zero codes, with the shared key names
  `ok, read_err, write_err, erase_err, name_err, saved_full, init_failed`.
  `fdb_kv_get_blob` returns a length rather than an error code; those calls are
  counted in `hits` instead.
* `hits` is non-zero only for `kv_get_hot` (2000) / `kv_get_miss` (0).
* `extra` is the extension point: per-run samples, min/max, consistency flags,
  entry counts, capacities, sum of returned bytes, GC erases, etc.
* `flash` is the measured-phase delta; `erase_bytes` is the sum of erased
  sector bytes (4 KiB per erase).  Derived weighted cost (documented, not
  hardware truth): `read_bytes + 10*write_bytes + 100*erase_bytes`.

## Baseline numbers (pinned toolchain, this machine)

`scripts/build_bench_c.ps1`, 5 runs, median per scenario, `-O2`.  Full tables
(including `-Os`) are in `bench/results/c_wg{8,1}_host{_os}.json`.

`FDB_WRITE_GRAN=8` (`c_wg8_host.json`):

| scenario | ops | ns/op | read_bytes | write_bytes | erase_bytes | checksum |
|---|---|---|---|---|---|---|
| kv_set_small | 64 | 215.62 | 8140 | 2226 | 0 | 411068509 |
| kv_update_1k | 1000 | 327.70 | 231708 | 63243 | 57344 | 2676218997 |
| kv_get_hot | 2000 | 120.25 | 330740 | 0 | 0 | 3293967273 |
| kv_get_miss | 500 | 2959.60 | 1606000 | 0 | 0 | 3293967273 |
| kv_delete | 192 | 3711.98 | 780822 | 5734 | 0 | 3293967273 |
| kv_iterate | 100 | 2961.00 | 321200 | 0 | 0 | 3293967273 |
| kv_mount | 100 | 4194.00 | 553200 | 0 | 0 | 3293967273 |
| kv_large | 50 | 4606.00 | 101224 | 52792 | 57344 | 853666419 |
| tsl_append | 308 | 37.34 | 132 | 14232 | 0 | 841992802 |
| tsl_append_rollover | 924 | 37.77 | 836 | 42725 | 32768 | 188742130 |
| tsl_iter_fwd | 20 | 2190.00 | 126720 | 0 | 0 | 841992802 |
| tsl_iter_rev | 20 | 2185.00 | 126720 | 0 | 0 | 841992802 |
| tsl_by_time | 500 | 158.60 | 249188 | 0 | 0 | 1612847090 |
| tsl_query_count | 500 | 160.00 | 249188 | 0 | 0 | 1612847090 |
| tsl_mount | 50 | 130.00 | 17600 | 0 | 0 | 841992802 |
| tsl_clean | 20 | 11695.00 | 7040 | 285040 | 327680 | 841992802 |

`FDB_WRITE_GRAN=1` (`c_wg1_host.json`); same logical checksums, different flash
accounting/capacity because the status table is bit-packed:

| scenario | ops | ns/op | read_bytes | write_bytes | erase_bytes | checksum |
|---|---|---|---|---|---|---|
| kv_set_small | 64 | 218.75 | 7576 | 2226 | 0 | 411068509 |
| kv_update_1k | 1000 | 332.60 | 219570 | 63252 | 53248 | 2676218997 |
| kv_get_hot | 2000 | 119.15 | 322740 | 0 | 0 | 3293967273 |
| kv_get_miss | 500 | 2915.60 | 1542000 | 0 | 0 | 3293967273 |
| kv_delete | 192 | 3685.94 | 749982 | 5733 | 0 | 3293967273 |
| kv_iterate | 100 | 2937.00 | 308400 | 0 | 0 | 3293967273 |
| kv_mount | 100 | 4190.00 | 554800 | 0 | 0 | 3293967273 |
| kv_large | 50 | 4710.00 | 100540 | 52820 | 57344 | 853666419 |
| tsl_append | 336 | 39.88 | 96 | 15520 | 0 | 4179764274 |
| tsl_append_rollover | 1008 | 41.27 | 608 | 46589 | 32768 | 3740598066 |
| tsl_iter_fwd | 20 | 2310.00 | 110080 | 0 | 0 | 4179764274 |
| tsl_iter_rev | 20 | 2295.00 | 110080 | 0 | 0 | 4179764274 |
| tsl_by_time | 500 | 177.60 | 213248 | 0 | 0 | 4064088662 |
| tsl_query_count | 500 | 173.40 | 213248 | 0 | 0 | 4064088662 |
| tsl_mount | 50 | 118.00 | 12800 | 0 | 0 | 4179764274 |
| tsl_clean | 20 | 13325.00 | 5120 | 310800 | 327680 | 4179764274 |

Flash counters and checksums are deterministic and must not change.  Wall-clock
`ns/op` is host timing and *does* vary between invocations -- occasionally by a
factor of ~2 on the very short scenarios (20-64 ops) when the machine is busy.
For that reason `tools/compare_bench.py` also supports `--metric min` (fastest
measured-phase sample per scenario, from `extra.samples_ns`), which is the
recommended metric for acceptance runs on a shared Windows host; compare C and
Zig back-to-back and consider `--tolerance-pct 5` for the short scenarios.

## Comparing against the Zig rewrite

```powershell
python tools/compare_bench.py bench/results/c_wg8_host.json bench/results/zig_wg8_host.json
python tools/compare_bench.py bench/results/c_wg8_host.json bench/results/zig_wg8_host.json --require-zig-le
python tools/compare_bench.py bench/results/c_wg8_host.json bench/results/zig_wg8_host.json `
    --require-zig-le --metric min --tolerance-pct 5     # noise-resistant acceptance
```

The Zig implementation has a **new on-flash format**, so flash traffic may
differ legitimately: the tool reports the per-scenario traffic deltas as
information and only *fails* on checksum mismatches, missing scenarios, and
(with `--require-zig-le`) on Zig being more than `--tolerance-pct` (default 2%)
slower in ns/op or weighted flash cost.

## Deviations from `bench/SCENARIOS.md` (reported to the Lead)

1. **Checksum is FNV-1a 32, decimal**, per the measured-data contract for
   comparable JSON; `SCENARIOS.md` only gave FNV-1a as an example.
2. **`tsl_append` full count is 308 (WG=8) / 336 (WG=1)**, not "~400": with
   4x4096 sectors, a 32-byte payload and the FDB log-index header, capacity is
   fixed.  The harness reports the measured count and `FDB_SAVED_FULL`.
3. **`tsl_mount` checksum is taken from the pre-mount populated state.** After
   remounting a *full, no-rollover* DB, upstream FlashDB leaves
   `oldest_addr=0xFFF` and `cur_sec.addr=0xFFFFFFFF`, so a post-mount iteration
   yields 0 entries.  The mount itself succeeds and is counted.
4. **`kv_delete` = 3 rounds x 32 x (delete+set) = 96 deletes + 96 sets = 192
   ops** (Lead confirmed this loop interpretation).
5. `kv_iterate`'s measured loop intentionally does not read values (only
   `value_len` sums); values are read only by the post-phase snapshot used for
   the checksum.
6. `kv_get_hot` / `kv_get_miss` have no `fdb_err_t` calls, so their
   `errcodes` are empty; hits are reported in `hits`.
7. Ranged-query ranges may extend past the last populated timestamp (by
   design: `from = 1000 + state % 3000`).
8. `tsl_append_rollover` sizes itself from the measured capacity
   (append-to-full probe) rather than a hard-coded ~400.

## Portability notes (Windows + pinned Zig nightly)

* `zig cc` is used as the C compiler; no other compiler/make/WSL is required.
  `clock_gettime(CLOCK_MONOTONIC)` is available through Zig's bundled MinGW
  headers and links without extra libraries.
* `-w` is required in practice: upstream FlashDB/FAL throws many
  `pointer-to-int-cast` / `int-to-pointer-cast` warnings on a 64-bit host.
* `-DBENCH_OPT=...` and `-DBENCH_HOST="..."` are compile-time definitions
  recorded in the JSON; the values contain no spaces so they survive the
  compiler command line unchanged.
* No source changes were needed to `bench/c/*.c` or to `reference/FlashDB/`
  for the Zig toolchain: the harness was written portably (C99 +
  `clock_gettime` + `stdint.h`) in the sibling project and compiles unchanged.
* Byte-level C<->Zig on-flash image compatibility is not a goal: the Zig
  rewrite deliberately uses a new on-flash format. Logical parity is verified
  at the behavioural level instead, by `bench/diff/` (`scripts/diff.ps1`),
  which replays the same operation script through both implementations and
  diffs every canonical output line (including per-mutation power cuts).
