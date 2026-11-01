# C<->Zig behavioural differential harness (KV, v1)

The Zig rewrite deliberately uses a **new on-flash format**, so byte-level
C<->Zig image parity is impossible.  What must still be proven is *logical*
parity: the same sequence of API calls must leave the same visible state and
return the same data, even though the bytes on flash differ.

This directory contains two programs that execute one deterministic operation
script -- one on the unmodified C FlashDB 2.2.99 (`reference/FlashDB`, via the
RAM FAL simulator from `bench/c`) and one on the Zig library (`src/`) -- and
print the same canonical `DIFF` output.  `tools/diff_model.py` runs both and
verifies the outputs.  `scripts/diff.ps1` builds both sides with the pinned Zig
nightly and runs the comparison.

Current status: **KV and TS both PASS**.  The KV script produces 2020 identical
canonical lines (2000 operations) and the TS script 1046 identical lines (1000
operations); every crash-recovery state validates and the completed post-crash
states have identical canonical dumps on both sides.  The only reported
divergences are the documented format-dependent ones (different mutation counts
per operation, C's `fdb_kvdb_check` flagging a torn KV tail, and the TS crash
probe being presence-based because C's TSDB iterator can expose a partially
written index slot at the sector tail after a cut - see the TS crash section).

## Files

| path | purpose |
|---|---|
| `c/diff_bench.c` | C side: unmodified upstream FlashDB + `bench/c/sim_flash.c`; runs the script and prints `DIFF` lines |
| `zig/main.zig` | Zig side: `@import("flashdb")` module, same script, same output |
| `../tools/diff_model.py` | runs both executables, compares/validates the output, exit non-zero on divergence |
| `../scripts/diff.ps1` | builds both executables with the pinned `<repo>/.tools/zig/zig.exe`, then runs the comparison |

No file under `reference/FlashDB/` is modified.  The C side reuses the existing
`bench/c/sim_flash.{c,h}` NOR simulator (extended with a mutation-indexed power
cut so the C and Zig fault models match; see below).

## Commands

Run from the repository root:

```powershell
# Build both sides and verify logical parity (single command, exit 0 = PASS)
pwsh -NoProfile -File scripts/diff.ps1

# Same, printing every compared line
pwsh -NoProfile -File scripts/diff.ps1 -Verbose

# Build only
pwsh -NoProfile -File scripts/diff.ps1 -BuildOnly

# Run an already-built comparison manually
python tools/diff_model.py build/diff/diff_c.exe build/diff/diff_zig.exe
python tools/diff_model.py build/diff/diff_c.exe build/diff/diff_zig.exe --save-dir build/diff
```

The script builds:

* `build/diff/diff_c.exe` with
  `zig cc -std=c99 -O2 -w -DFDB_WRITE_GRAN=8 -I bench/c -I reference/FlashDB/inc
  -I reference/FlashDB/port/fal/inc <bench/diff/c/diff_bench.c> <bench/c/sim_flash.c>
  <reference/FlashDB sources> -o build/diff/diff_c.exe`
* `build/diff/diff_zig.exe` with the pinned Zig nightly's module CLI:

  ```
  .tools/zig/zig.exe build-exe -O ReleaseSafe -femit-bin=build/diff/diff_zig `
      --dep flashdb -Mroot=<abs bench/diff/zig/main.zig> `
      -Mflashdb=<abs src/flashdb.zig>
  ```

  Pinned-0.18-dev quirks that the script works around (and that the Zig-side
  harness should follow): `-femit-bin` must not carry a `.exe` extension (the
  output is renamed afterwards), `--dep flashdb` must appear **before** the
  root `-Mroot=`, and relative `-Mroot=`/`-Mflashdb=` paths are misparsed, so
  absolute paths are used.  The program itself is plain `pub fn main() !void`;
  it needs no argv/timing, so no `std.process.Init` plumbing is required.  The
  canonical output is written to **stdout** through
  `std.Io.File.stdout().writer(io, &buf)` with `io = std.Options.debug_io`.

Exit status of `scripts/diff.ps1`: 0 only when both builds succeed, both
programs exit 0, the main-script section is identical line for line, and every
crash-recovery state passes validation.  Any divergence prints the first
differing line and exits non-zero.

## Geometry and API surface

* Flash: 32 KiB RAM NOR, 4 KiB erase blocks (`RamFlash(.{ .write_gran_bits = 8,
  .block_size = 4096 })`), KVDB partition 16 KiB = 4 sectors of 4096 bytes
  (`FdbKvdb(... sector_size=4096, sector_count=4)`); only KVDB is exercised in
  v1.  The TSDB partition (16 KiB at offset 16 KiB) is reserved for v2.
* C: `fdb_kvdb_init/fdb_kvdb_deinit`, `fdb_kv_set_blob`,
  `fdb_kv_get_blob`, `fdb_kv_del`, `fdb_kv_iterator_init/fdb_kv_iterate`,
  `fdb_blob_read`, `fdb_kvdb_check`, `fdb_kv_set_default`.
* Zig: `db.mount/formatAll/set/get/delete/check/iterator/count`, iterator
  `next/readValue`.
* Column limits: 48 keys `k00..k47` (3-byte names), values 1..120 bytes,
  get buffer 128 bytes, 4 default keys `d00..d03` of 16 bytes.  Value length
  starts at 1 (not 0) because C's `fdb_kv_get_blob` cannot distinguish a
  missing key from an empty value, which would make the hit/miss canonical
  line ambiguous.

## Deterministic operation script

```
LCG: state = 0xC0FFEE
     next(): state = (state * 1103515245 + 12345) mod 2^31
             (32-bit wrapping multiply, then & 0x7FFFFFFF)
per op: state = next(); bucket = state % 100; then extra draws in the fixed
        order documented per operation below.
```

| bucket `state % 100` | operation | draws / effect |
|---|---|---|
| 0..54 (55 %) | `set` | key = next()%48; `gen[key]++`; len = 1 + next()%120; value bytes |
| 55..69 (15 %) | `delete` | key = next()%48; pre-read logs `existed` (C returns an error for absent keys, the canonical line reports existence instead) |
| 70..79 (10 %) | `get` | key = next()%48; read into 128-byte buffer; logs hit, len and value FNV; rolls the returned bytes |
| 80..84 (5 %) | `iterate` | iterate all live records, sort by key, canonical digest |
| 85..89 (5 %) | `remount` | deinit + mount (C) / `mount(Flash.init(&mem))` (Zig); then digest |
| 90..94 (5 %) | `get-miss` | key = `"m%02u"` with next()%16; must miss |
| 95..99 (5 %) | `defaults` | restore the 4 default keys: C `fdb_kv_set_default`, Zig `formatAll()` + `set` each default |

Values (`buf[j]`, `j = 0..len-1`):

```
value[j] = (u8)(0x5A + key_idx * 31 + gen * 17 + j * 7)
```

`gen` is a per-key counter maintained by the harness (not by the library) and
incremented before every set of that key.  Default values:
`default[i][j] = (u8)(0xD0 + i*3 + j)`, `i = 0..3`, `j = 0..15`.

Script length: **2000 operations**, checkpoint every **250** operations, seed
`0xC0FFEE` (12648430).

### Checksums

All hashes are **FNV-1a-32**: `h = 0x811C9DC5; for each byte: h ^= b;
h *= 0x01000193 (wrapping)`.  `u32` fields are serialised little-endian:

* `vfnv` = FNV of the value bytes (or of the bytes returned by a get).
* canonical entry = `u32(klen), key, u32(vlen), u32(vfnv)`.
* `digest` = FNV over the sorted-by-key canonical entries.
* `roll` (rolling hash over returned data, updated by `get`, `iterate`,
  `remount`, `defaults`):
  * get hit: `roll = FNV(roll, returned value bytes)`;
  * iterate/remount/defaults: `roll = FNV(FNV(roll, u32(count)), u32(digest))`.

There is **no timing** in the output: the differential evidence is fully
deterministic and cannot flake on a loaded host.

## Canonical output format (exact)

Both programs print to stdout.  The first line differs only in the `impl=`
token; `tools/diff_model.py` normalises that token and requires every
main-script line to match byte for byte.

```
DIFF version=1 impl=<c|zig>
CONFIG wg=8 kv_part=16384 sector=4096 sectors=4 keys=48 miss_keys=16 max_value=120 seed=12648430 ops=2000 checkpoint=250 crash_watch=8
OP idx=<n> kind=set key=<kNN> len=<n> vfnv=0x%08x
OP idx=<n> kind=del key=<kNN> existed=<0|1>
OP idx=<n> kind=get key=<kNN> hit=<0|1> len=<n> vfnv=0x%08x
OP idx=<n> kind=getmiss key=<mNN> hit=0
OP idx=<n> kind=iter count=<n> digest=0x%08x
OP idx=<n> kind=remount count=<n> digest=0x%08x
OP idx=<n> kind=defaults count=<n> digest=0x%08x
CHECKPOINT idx=<n> count=<n> digest=0x%08x roll=0x%08x
STATE count=<n> dump_fnv=0x%08x
ENTRY key=<kNN> klen=<n> vlen=<n> vfnv=0x%08x          (sorted by key)
CHECK ok=1
ROLL value=0x%08x
SUMMARY ops=2000 count=<n> dump_fnv=0x%08x roll=0x%08x rc=0
```

`%08x` = 8 lowercase hex digits.  `STATE`/`ENTRY` describe the final sorted
database contents; `SUMMARY` closes the main section.  Any unexpected library
error on either side is a harness failure (stderr + exit 3), never a silently
different line.

## Crash-recovery comparison

After the main script both programs run the same two crash phases on a fresh,
durable pre-crash state, using a **mutation-indexed power cut**:

* pre-crash base (rebuilt for every cut point): erase the whole flash, mount
  (formats), set `k00..k07` to 16-byte values (`gen=0`), remount.  Base state
  is therefore exactly those 8 keys.
* `set` phase: cut power at the k-th mutating flash operation of
  `set("k03", 24-byte value gen=77)` and enumerate `k = 0, 1, ...` until the
  operation completes without a fault.
* `del` phase: same for `delete("k01")`, `k = 0, 1, ...`.
* Cutting power means: the next `k` mutating ops (writes/erases) succeed, every
  later mutating op fails without changing flash; reads never fail.  The C RAM
  simulator was extended with `sim_fault_arm_mutations()` to match Zig's
  `RamFlash.armFault()` exactly (`tests/...` and the benchmark keep using the
  old op-indexed `sim_fault_arm()` unchanged).
* After the cut the fault is cleared, the database is remounted and the visible
  state of `k00..k07` is dumped.

Per cut point the canonical line is:

```
CRASH-BEGIN phase=<set|del> target=<k03|k01> old_fnv=0x%08x new_fnv=0x%08x
CRASH phase=<set|del> cut=<n> outcome=<fault|ok> check=<0|1> count=<n> dump_fnv=0x%08x states=k00=<old|new|absent|other>,...,k07=<...>
CRASH-END phase=<set|del> cuts=<n>
```

`tools/diff_model.py` validates, instead of blind-diffing, because the number
of mutations per operation legitimately differs between the C format and the
new Zig format (so cut indexes do not line up):

1. every `CRASH` line: for `set`, `k03` must be `old` or `new` and all other
   watched keys must be `old`; for `del`, `k01` must be `old` or `absent` and
   all others `old`; `other` (corruption) is a failure; `count` must be 8 for
   `set`, 7 or 8 for `del`;
2. cut indexes must be contiguous `0..N-1`, every cut before the last must be
   `fault`, and the last must be `ok`;
3. the last cut must show the completed state (`k03=new` / `k01=absent`);
4. both implementations must produce the **same canonical `dump_fnv` for the
   completed state** (the logical state after the op is format-independent);
5. `CRASH-BEGIN` old/new hashes must agree between C and Zig.

Legitimate divergences (reported, not failed):

* different cut counts / different intermediate cut indexes (C needs more
  mutations per set than the Zig format; e.g. C set 9 cuts vs Zig 6);
* `check=0` on some C cuts: upstream `fdb_kvdb_check` walks the sector tail and
  returns `FDB_READ_ERR` when it finds the uncommitted remains of a torn write
  (it also stamps `FDB_KV_ERR_HDR`); the visible key/value state is still the
  valid old value.  The Zig `check()` validates live records only, so it
  reports `check=1`.  The visible-state invariants (1) still hold, so this is a
  documented API-strictness difference, not a data divergence.

## TSDB part (v2)

After the KV crash phases both programs run the TSDB script on a fresh, erased
32 KiB device (the TSDB partition is 16 KiB at offset 16 KiB, `max_len=64`,
32-bit timestamps, rollover enabled by default - the bounded appends below never
fill the database, so rollover never triggers).

### TS script

* seed `0x33557711`, 1000 operations, checkpoint every 250;
* per op: `state = next(); bucket = state % 100;`
  * 0..69 (70 %) **append**: if fewer than 40 entries were appended since the
    last `clean()`, `seq++`, `time = 1000 + seq`,
    `len = next() % 65` (0..64), payload
    `payload[j] = 0x3C + seq*13 + j*5 (mod 256)`, then `append(time, payload)`;
    otherwise fall back to a full forward iteration (`kind=iter`).
    **The 40-entry cap is deliberate**: C and Zig capacities differ (the new
    format is denser), and appending past a format's capacity would legitimately
    produce different ring contents.  With <= 40 entries per epoch both
    implementations store the same, complete logical database;
  * 70..79 (10 %) **remount**: deinit+init (C) / `mount` (Zig), then walk;
  * 80..89 (10 %) **by-time iteration**: `off = next()%400`,
    `span = next()%200`, `from = 1000+off`, `to = from+span` (always a forward
    range here), walk and digest/roll;
  * 90..94 (5 %) **query_count**: same range draws, status `write`;
  * 95..99 (5 %) **clean+repopulate**: `clean()`, then append 24 fixed 16-byte
    entries (`seq++`, same payload formula), walk and digest/roll.
* the final state is dumped in forward order and queried for 8 fixed ranges
  (`1000..1100`, `1050..1150`, `0..1000`, `1200..1400`, `1000..1000`,
  `1100..1000` (reversed range - count only), `0..4000`, `1500..1600`).

TS canonical output (in the main section, compared line for line):

```
TS-DIFF version=1 impl=<c|zig>
TS-CONFIG max_len=64 base_time=1000 ops=1000 checkpoint=250 append_limit=40 repopulate=24 seed=861239057 query_count=8
TS-OP idx=<n> kind=append time=<t> len=<n> pfnv=0x%08x
TS-OP idx=<n> kind=iter count=<n> last_time=<t> digest=0x%08x
TS-OP idx=<n> kind=remount count=<n> last_time=<t> digest=0x%08x
TS-OP idx=<n> kind=bytime from=<t> to=<t> count=<n> digest=0x%08x
TS-OP idx=<n> kind=querycount from=<t> to=<t> count=<n>
TS-OP idx=<n> kind=clean_repopulate count=<n> last_time=<t> digest=0x%08x
TS-CHECKPOINT idx=<n> count=<n> last_time=<t> dump_fnv=0x%08x roll=0x%08x
TS-STATE count=<n> last_time=<t> dump_fnv=0x%08x
TS-ENTRY time=<t> status=<n> len=<n> pfnv=0x%08x          (forward order)
TS-QUERY from=<t> to=<t> count=<n>                       (8 fixed ranges)
TS-ROLL value=0x%08x
TS-SUMMARY ops=1000 count=<n> last_time=<t> dump_fnv=0x%08x roll=0x%08x rc=0
```

TS digest = FNV over `u32(time), u32(status), u32(len), u32(pfnv)` per entry in
forward order; `pfnv` = FNV of the payload bytes; TS `roll` is updated by every
walking operation as `FNV(FNV(roll, count), digest)`.

### TS crash recovery

Base state: erase, mount (formats), append 8 entries (`t=1000..1007`, 16-byte
payloads `seq=0..7`), remount.  Then cut power at the k-th mutating flash
operation of `append(1100, 24-byte payload seq=77)` and enumerate `k` until the
append completes.  After clearing the fault and remounting, the canonical line
is:

```
TS-CRASH-BEGIN base_dump=0x%08x new_dump=0x%08x
TS-CRASH cut=<n> outcome=<fault|ok> last_time=<t> base_mask=0x%02x new_present=<0|1> dump_fnv=0x%08x
TS-CRASH-END cuts=<n>
```

Validation rules (`tools/diff_model.py`):

1. `base_mask` must be `0xff` on every cut: all 8 pre-crash committed entries
   stay visible - a cut must never lose or corrupt committed data;
2. `new_present` is 0 or 1 only: the new entry is either fully present or
   absent, never partial (`dump_fnv` is only computed for the completed cut;
   on fault cuts it is 0);
3. cuts are contiguous `0..N-1`, only the last one may be `ok`;
4. the completed cut must have `new_present=1`, `last_time=1100`,
   `dump_fnv == new_dump`, and C and Zig must agree on `base_dump`, `new_dump`
   and the completed `dump_fnv`;
5. the number of cuts differs legitimately (C needs 5 mutations for one append,
   the Zig format 4).

Why presence queries instead of a raw walk for fault cuts: upstream C TSDB can
leave a partially written index slot at the sector tail after a power cut; its
iterator may then expose that torn slot (garbage `log_len`) even though the
committed entries and by-time queries are intact.  The Zig format commits an
entry with a single granule and skips uncommitted slots, so it never exposes a
torn entry.  The probe therefore compares the semantics that must agree (all
committed entries visible, new entry present or absent, `last_time`) instead of
diffing the raw iterator.  For the completed cut the fault is cleared and the
full canonical walk must match between C and Zig.

### Intentional TS differences from C (allowed, documented)

* **no per-entry CRC** in the new format (same guarantee level as C: the
  single-granule commit makes a torn entry invisible), so TS parity compares
  status/time/len/payload bytes - not CRCs beyond the KV ones;
* Zig `check()` validates structural invariants (sector headers, end fields,
  in-range indices, strictly increasing timestamps) instead of CRCs; C 2.2.99
  has no `fdb_tsdb_check()` at all, so `TS-CHECK` is not part of the canonical
  output;
* `clean()` = format all sectors (C `fdb_tsl_clean()`), rollover recycles the
  oldest sector (never triggered by the bounded script);
* capacity differs (e.g. 368 vs 308 entries for `max_len=32` in the host
  benchmark), which is why the TS script bounds per-epoch appends and why
  `tools/compare_bench.py` treats TS checksums as capacity-dependent.

## Notes / deviations

* Value lengths are 1..120 (not 0..120): C's `fdb_kv_get_blob` returns 0 both
  for a missing key and for an empty value, which would make the hit/miss
  canonical line ambiguous.  Both sides use the same 1..120 formula, so this
  only affects coverage, not comparability.
* `delete` of an absent key is normalised to `existed=` because C returns
  `FDB_KV_NAME_ERR` while Zig's `delete` returns `false`; both mean "no value
  existed", and the canonical line logs the pre-read existence instead of the
  raw error code.
* C `fdb_kv_set_default` formats every sector and then writes `db->default_kvs`;
  the C harness attaches the default table immediately before the call and
  initialises databases with a NULL default table so upstream's
  "format-on-init creates defaults" hook does not seed keys implicitly (the
  Zig API has no such hook).
* The C crash pre-state is built with `sim_flash_erase_all()` + remount; the
  Zig side uses `@memset(&mem, 0xFF)` + mount.  Both therefore start from a
  factory-fresh erased NOR image for every cut point.
