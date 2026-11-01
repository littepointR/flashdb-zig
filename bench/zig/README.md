# Zig host benchmark driver

The Zig side of the benchmark protocol in [`../SCENARIOS.md`](../SCENARIOS.md)
and the C reference harness in [`../c/`](../c/). It runs every scenario against
the same simulated flash geometry and emits a JSON document with the **same
shape and field names** as `bench/results/c_wg8_host.json`, so the two can be
compared directly:

```powershell
python tools/compare_bench.py bench/results/c_wg8_host.json bench/results/zig_wg8_host.json
python tools/compare_bench.py bench/results/c_wg8_host.json bench/results/zig_wg8_host.json `
    --require-zig-le --metric min --tolerance-pct 5      # acceptance gate
python tools/bench_summary.py bench/results/zig_wg8_host.json
```

## Quick start

All commands run from the repository root with the pinned toolchain.

```powershell
# Honest acceptance build: the benchmark *and* the library must be optimized.
.tools\zig\zig.exe build -Doptimize=ReleaseFast

# JSON to stdout + --out, human table to stderr (stdout stays machine readable).
.\zig-out\bin\flashdb-bench.exe --wg 8 --runs 5 --out bench/results/zig_wg8_host.json
.\zig-out\bin\flashdb-bench.exe --wg 1 --runs 5 --out bench/results/zig_wg1_host.json

# Behavioural self-checks (exit != 0 on the first failed invariant class).
.\zig-out\bin\flashdb-bench.exe --mode check            # write_gran 8
.\zig-out\bin\flashdb-bench.exe --mode check --wg 1     # write_gran 1

# `zig build bench` builds *and* runs the driver with default options.
.tools\zig\zig.exe build bench
```

> **Build mode.** `build.zig` pins the benchmark *module* to `.ReleaseFast`, but
> the `flashdb` library module still follows `-Doptimize` (Debug by default).
> Unoptimized library code changes the measured `ns/op` by up to ~2.4x, so
> **acceptance runs must pass `-Doptimize=ReleaseFast`**. The JSON `opt` field
> reports the benchmark module's mode (always `ReleaseFast`).

## CLI

| flag | meaning |
|---|---|
| `--mode bench\|check` | `bench` (default) emits JSON; `check` runs the self-checks |
| `--wg 8\|1` | flash write granularity in bits, default `8` |
| `--runs N` | measured repetitions per scenario, default `5` (clamped to 1..64) |
| `--out FILE` | JSON path, default `bench/results/zig_wg<WG>_host.json` |
| `--impl NAME` | `impl` field, default `zig` |
| `--only NAME` | run one scenario (e.g. `--only kv_get_hot`) |
| `--help`, `-h` | usage |

Exit codes: `0` success, `1` check-mode failures, `2` bad command line,
`3` fatal harness/library error.

## Output layout

* **stdout** – the JSON document (and nothing else), so it can be piped.
* **`--out`** – the same JSON document.
* **stderr** – a compact table (columns: `scenario ops ns/op reads read_bytes
  writes write_bytes er erase_bytes weighted checksum`) plus notes.

## Protocol fidelity

* One 32 KiB RAM NOR device (`flashdb.sim.RamFlash`, `write_gran_bits = --wg`,
  `block_size = 4096`), partitioned `[0, 16 KiB)` = KVDB, `[16 KiB, 32 KiB)` =
  TSDB, each with 4 x 4096-byte sectors.
* Data generation is verbatim: `kv_value(seed,i,len)[j] = (seed + i*31 + j*7) &
  0xFF`, `ts_payload(i)[j] = (0x5A + i*13 + j*5) & 0xFF`, `t_i = 1000 + i`, and
  the ranged-query LCG (`state=12345`, `state = (state*1103515245 + 12345) mod
  2^31`, `off = state % 3000`, `len = 50 + state % 451`).
* Setup is excluded from both the timer and the flash counters: for every run
  the setup hook rebuilds the state, then the counters are reset and only the
  measured body runs between two monotonic clock reads (`std.Io.Clock.awake` =
  `QueryPerformanceCounter` on Windows, the same source the C harness gets from
  `clock_gettime(CLOCK_MONOTONIC)`). The reported `flash` block is the last
  run's delta; `extra.flash_consistent` / `extra.errs_consistent` assert every
  run produced identical counters.
* `total_ns_median` is the median of the `runs` samples, `ns_per_op` the median
  divided by `ops`; `extra.samples_ns` carries the raw samples for
  `compare_bench.py --metric min`.
* Checksums are FNV-1a-32 over the exact C serialisation:
  * KV: `u32(entry_count)`, then entries sorted by key: `u32(key_len)`, key,
    `u32(value_len)`, value.
  * TS snapshot: forward iteration `u32(status)`, `u32(time)`, `u32(len)`,
    payload; then `u32(entry_count)`.
  * TS ranged: `u32(500)`, then `u32(count)` per query.
* `errcodes` uses the C JSON keys (`ok`, `name_err`, `saved_full`,
  `init_failed`, ...). The Zig API returns `error` values and `bool` instead of
  `fdb_err_t`; the mapping is documented in `semantics.errcode_mapping`
  (`InvalidName -> name_err`, `delete() == false -> name_err`, ...).
* No allocator is used inside a measured phase (the arena is only touched by the
  post-phase snapshot).

## JSON extensions (fields the C document does not have)

The document is a superset of the C one: same keys and order for everything the
C harness emits, plus additions that describe the Zig build truthfully. All
additions live in `config`, `footprint`, `semantics` or `scenario.extra`, so
existing readers keep working.

`config` (Zig truth): `write_gran_bytes`, `partition_offsets`,
`kv_cache_table_size` (library default, currently 128 entries),
`kv_cache_bytes`, `sector_cache_table_size` (0 - the Zig design keeps per-sector
state instead of a sector cache), `ts_max_entry_count`, `ts_index_size`,
`ts_bytes_per_entry`, `kv_max_name_len`, `kv_chunk_size`,
`timer_resolution_ns`.

`extra` (per scenario): `set_bit_attempts` and `nor_violations` prove the
simulator invariants hold (no `1 -> 0` reversal, no out-of-bounds access).

TS scenarios additionally carry a normalisation block, because the Zig TSDB
layout stores more entries in the same partition than upstream FlashDB:

| extra | meaning |
|---|---|
| `entries` | number of stored entries the checksum/phase covers |
| `capacity` | fill-to-full capacity (measured; `tsl_append_rollover` uses the probe count) |
| `max_entry_count` | `Tsdb.maxEntryCount()` of this geometry |
| `bytes_per_entry` | on-flash bytes one `max_len` entry costs (index + padded payload) |
| `total_matches` | `tsl_by_time`/`tsl_query_count`: sum of the 500 per-query counts |
| `normalized_*_per_entry` | `ns`, `read_bytes`, `write_bytes`, `erase_bytes`, `writes`, `erases` divided by `entries` |
| `c_ref_capacity`, `c_ref_prefix_checksum` | parity probe: the same snapshot FNV over only the first `c_ref_capacity` entries (C's capacity) |
| `c_ref_last_time`, `c_ref_sum`, `c_ref_checksum` | parity probe: the same LCG range loop clamped to the C timestamp window |

## TS capacity and the checksum gate

The Zig format (fixed 12-byte index + payload growing down) holds **368**
32-byte entries in a 16 KiB partition, while the C format holds **308**
(`write_gran = 8`) or **336** (`write_gran = 1`). "Populate to full" therefore
stops at a different entry count, the two databases legitimately hold different
logical content, and the raw `tsl_*` checksums **cannot** match - the protocol
checksums cover the whole resulting state. Do not force a match by truncating
the workload.

Instead, expect `tools/compare_bench.py` to report these eight scenarios as
capacity-dependent, and verify equivalence with the parity extras (both are
expected to equal the C document value verbatim):

* `extra.c_ref_prefix_checksum == c_json.checksum` for `tsl_append`,
  `tsl_iter_fwd`, `tsl_iter_rev`, `tsl_mount`, `tsl_clean`;
* `extra.c_ref_checksum == c_json.checksum` and `extra.c_ref_sum ==
  c_json.extra.sum_count/sum_matches` for `tsl_by_time`, `tsl_query_count`.

`tsl_append_rollover` has no comparable prefix (the two ring buffers cover
different timestamp windows); compare it per stored entry instead.

## `--mode check`

Self-checks with `PASS`/`FAIL` lines on stdout, grouped as:

* `sim:` NOR semantics - erased image, AND-only writes, set-bit attempts,
  read/write/erase counters, erase alignment, bounds violations, power-cut
  fault injection (mutations fail, flash untouched, reads still work).
* `part:` the two partitions tile the 32 KiB device.
* `fnv:`/`data:`/`lcg:` the checksum, data-generation and range-LCG constants
  against independently computed values (including the protocol's expected
  `kv_set_small` checksum `411068509`).
* `kv:` record CRUD, GC over 1000 updates, remount persistence, no NOR
  set-bit attempts / out-of-bounds accesses.
* `det:` two identical workloads produce identical checksums *and* identical
  flash counters.
* `ts:` append/iterate/query/clean/remount on a small DB, a full DB (`check()`
  structural validation, `populated == maxEntryCount`), and a rollover ring.

## Documented deviations from the C harness

1. `write_gran` 1 and 8 currently share the same byte-granule status
   representation, so their flash traffic/capacities are identical (the C builds
   differ: bit-packed status in `wg1`).
2. No sector cache (`sector_cache_table_size: 0`); the KVDB keeps per-sector
   state instead. `kv_cache_table_size` is the library default (128 entries,
   512 B) rather than C's 64 x 8 B, i.e. the same cache bytes.
3. `Kvdb.get` returns the *total* value length (copy length = `min(buf.len,
   len)`); every benchmarked `get` passes a buffer >= the value, so hits/byte
   sums match C. `delete` returns `bool`; a missing key is counted as `name_err`.
4. TS capacities and checksums differ by construction (see above).
5. The human table goes to stderr (the C harness prints JSON to stdout and no
   table).
6. `kv_iterate` intentionally does not read values (only `value_len` sums), like
   the C harness; values are read only by the post-phase checksum snapshot.
