# Benchmark & equivalence protocol (shared by C reference and Rust rewrite)

This document is the **contract** between the C reference harness
(`harness/c/`) and the Rust harness (`crates/flashdb-bench/`). Both must run
exactly these scenarios with identical flash geometry and identical data, so
that results are directly comparable. Do not change one side without changing
the other and re-running both.

## Fixed geometry

| item | value |
|---|---|
| partition size | `16384` bytes (4 sectors) |
| sector (erase block) size | `4096` bytes |
| write granularity (primary) | `FDB_WRITE_GRAN = 8` (byte writes, status per byte) |
| write granularity (secondary) | `FDB_WRITE_GRAN = 1` (bit-packed status) |
| TSDB timestamp | `int32_t` / `i32` (FlashDB default) |
| KV cache | FlashDB defaults for C (`FDB_KV_CACHE_TABLE_SIZE=64`, `FDB_SECTOR_CACHE_TABLE_SIZE=8`); Rust default (`KV_CACHE_ENTRIES=64`) |
| logs | disabled in both (`FDB_DEBUG_ENABLE` not defined / no-op) |
| flash | RAM-backed simulator with per-operation accounting; **no** artificial delays |

Each DB gets its own 16 KiB partition (KV and TS are independent scenarios).

## Metrics

For every scenario report, taken **after resetting counters at the start of the
measured phase**:

* wall-clock time: `runs` repetitions of the measured phase, report median
  total nanoseconds and derived `ns_per_op`.
* flash traffic: `reads`, `read_bytes`, `writes`, `write_bytes`, `erases`,
  `erase_bytes` (delta over one measured phase).
* a checksum of the result data so the two implementations can be compared
  functionally (e.g. FNV-1a over values/timestamps).

A *weighted flash cost* is derived by the reporting tool:
`read_bytes*1 + write_bytes*10 + erase_bytes*100` (approximate NOR word-line
cost model, documented so it is not mistaken for hardware truth).

JSON output is one object per implementation with a `scenarios` array; see
`harness/SCENARIOS.json.schema.md` for the exact field list (writer owns it).

## Setup vs measured phase

Some scenarios need pre-populated flash. Setup is always excluded from both
timing and flash counters: build the pre-populated state, `reset_stats()`,
reset the timer, then run the measured phase. Setup itself must be identical
between implementations.

## KV scenarios

Values are fixed byte arrays (not NUL-terminated); keys are ASCII.
`value(pattern_seed, i, len)` = `byte[j] = (pattern_seed + i*31 + j*7) & 0xFF`.

| id | setup | measured phase |
|---|---|---|
| `kv_set_small` | format | 64 × `set("kv{i%8}", 8-byte value)` |
| `kv_update_1k` | format, set `counter`=32 B | 1000 × `set("counter", 32-byte value)` (triggers GC/wear levelling) |
| `kv_get_hot` | format, set `key{i}` (i<32) 32 B values | warmup 128 × get, then 2000 × `get("key{i%32}")` into 64 B buf, sum returned bytes |
| `kv_get_miss` | same as kv_get_hot | 500 × `get("absent{i}")`, count hits |
| `kv_delete` | same as kv_get_hot | for i<32: `delete(key{i})`, then `set(key{i}, 32 B)`; repeat 3× (192 del + 192 set) |
| `kv_iterate` | same as kv_get_hot | 100 × full iteration; count entries and sum value_len |
| `kv_mount` | same as kv_get_hot | 100 × (deinit + mount); count successes |
| `kv_large` | format | 50 × `set("big", 1024-byte value)` |

Semantics: `get` returns the number of bytes copied (min(buf_len, value_len));
`delete` returns success even if the key is absent?  **No**: FlashDB returns
`FDB_KV_NAME_ERR` for a missing key; record exact return codes in `errcodes`.

## TS scenarios

Log payload: 32 bytes, `byte[j] = (seed + i*13 + j*5) & 0xFF`, `seed = 0x5A`.
Timestamps: `t_i = 1000 + i` (strictly increasing).

| id | setup | measured phase |
|---|---|---|
| `tsl_append` | format | append logs with increasing timestamps until the DB reports full (rollover disabled) or 4000 appends; report count and per-op time |
| `tsl_append_rollover` | format, rollover enabled | 3× capacity appends (~3×400) with increasing timestamps |
| `tsl_iter_fwd` | populate to full | 20 × forward iterate all entries; count + sum payload len |
| `tsl_iter_rev` | populate to full | 20 × reverse iterate all entries |
| `tsl_by_time` | populate to full | 500 × `iter_by_time(t_from, t_to)` with a deterministic pseudo-random range (LCG seed 12345, range len 50..500) |
| `tsl_query_count` | populate to full | 500 × `query_count(from,to,Write)` same ranges as by_time; sum counts |
| `tsl_mount` | populate to full | 50 × (deinit + mount); count successes |
| `tsl_clean` | populate to full | 20 × (`clean` + repopulate to full) |

"Populate to full" = append with increasing timestamps until `SavedFull`
(rollover disabled), expected ≈ 400 entries.

## Equivalence tests (separate from benchmarks)

Besides the benchmark, both implementations must agree on **on-flash
compatibility**:

1. C writes a DB (KV + TS, populated + GC churn), then the Rust build mounts it
   with the same geometry and must read exactly the same keys/values/logs.
2. Rust writes a DB with the same workload, then the C build must mount and
   read it.
3. Byte-for-byte: for the deterministic `kv_set_small` workload on a freshly
   formatted partition, the final 16 KiB flash images produced by C and Rust
   should be identical (same sectors, same addresses, same padding). If they are
   not byte-identical, the diff must be understood and documented (allowed only
   for padding bytes that are erased in both).
4. Interrupted operations (fault injection): power-cut at every flash op during
   a set/append, remount, verify invariants (old value visible or new value
   visible, never corrupt; TS append either present or absent).

## Footprint

* static RAM: `sizeof(fdb_kvdb)` / `sizeof(fdb_tsdb)` + cache tables for C;
  `core::mem::size_of::<Kvdb<..>>()` / `Tsdb<..>` for Rust. Partition/geometry
  is not counted (identical for both).
* firmware: thumbv7m-none-eabi, `-Os` (C) vs `opt-level="s"` (Rust):
  `.text`, `.rodata`, `.data`, `.bss`, stack high-water (QEMU semihosting
  harness), running the identical scenario driver.

## Appendix: exact data generation (normative)

The following formulas are normative for both harnesses; both `scripts/c_bench.sh`
and `cargo run -p flashdb-bench --release` must use them verbatim so the reported
`checksum` values are comparable.

```
fnv1a32(bytes) = { h=0x811C9DC5; for b in bytes { h ^= b; h = h*0x01000193 mod 2^32 } }
kv_value(seed, i, len)[j] = (u8)(seed + i*31 + j*7)
ts_payload(i)[j]          = (u8)(0x5A + i*13 + j*5)
```

| scenario | data |
|---|---|
| kv_set_small | k=0..63: key=`"kv{k%8}"`, value=`kv_value(0x11,k,8)` |
| kv_update_1k | setup `"counter"=kv_value(0x22,0,32)`; k=0..999 set `"counter"`=`kv_value(0x22,k,32)` |
| kv_get_hot | setup i=0..31: key=`"key{i}"`, value=`kv_value(0x33,i,32)`; warmup 128 gets `key{i%32}`; measured 2000 gets `key{k%32}` into 64-byte buffer |
| kv_get_miss | same setup as kv_get_hot; 500 gets `"absent{k}"` |
| kv_delete | setup 32 keys as kv_get_hot; 3 rounds × 32 × { delete key_i; set key_i = kv_value(0x33,i,32) } |
| kv_iterate | setup 32 keys as kv_get_hot; 100 × iterate, sum `value_len`, count entries, do not read values |
| kv_mount | setup 32 keys as kv_get_hot; 100 × (deinit + mount) over unchanged flash |
| kv_large | k=0..49 set `"big"` = `kv_value(0x44,k,1024)` |
| tsl_append | rollover off; append payload(i) with `t=1000+i` until `SavedFull` or 4000 appends |
| tsl_append_rollover | rollover on; `3 * max_blob_count` appends |
| tsl_iter_fwd / tsl_iter_rev | populate to full (rollover off), then 20 × full iterate (sum log_len, count) |
| tsl_by_time | populate to full; 500 × by-time iterate with LCG ranges below |
| tsl_query_count | populate to full; 500 × query_count(range, Write) |
| tsl_mount | populate to full; 50 × (deinit + mount) |
| tsl_clean | populate to full; 20 × (clean + repopulate to full) |

By-time LCG: `state=12345`; per query do two steps
`state = (state*1103515245 + 12345) mod 2^31`;
`off = state % 3000`; `len = 50 + next % 451`; `from = 1000 + off`; `to = from + len`.
