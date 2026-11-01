#!/usr/bin/env python3
"""Side-by-side comparison of the C reference and Zig host benchmark JSONs.

Both documents come from the same protocol (bench/SCENARIOS.md): one scenario
array with `ops`, `ns_per_op`, `checksum` and a `flash` counter object per
scenario.  The C harness is bench/c (unmodified upstream FlashDB), the Zig
harness is the rewrite.

Checksum policy (`--checksum-scope`, default `kv`):

* KV scenarios are a strict gate: the logical database content must match, so
  every `kv_*` checksum must be equal.
* TS scenarios are capacity-dependent *by design*: the new format stores more
  `max_len` entries in the same partition (e.g. 368 vs 308 at max_len=32), so
  "append until full" leaves different amounts of data and the raw snapshot
  checksums legitimately differ.  Under the default scope a TS checksum
  mismatch is informational (`capacity-dependent: zig=368 entries vs c=308`)
  and fails only when the entry counts are equal yet the checksums differ.
  Zig documents may also carry verification extras produced by bench/zig:
  `c_ref_prefix_checksum` / `c_ref_checksum` are the C checksum recomputed over
  the C-sized prefix / C timestamp window; when present they must equal the C
  document's checksum (that is the real logical-parity check).
  `--checksum-scope all` restores strict equality for TS as well.

Flash traffic is reported as information (the Zig version uses its own
on-flash format); weighted cost is `read_bytes + 10*write_bytes +
100*erase_bytes`.

`--normalize-ts` adds a TS normalization table with per-entry / per-query units
(entries for fill/iteration scenarios, queries for ranged queries and mounts,
appends for clean cycles), reporting ns, reads and bytes per unit for C and Zig
side by side, so the different capacities can be compared fairly.

Usage:
    python tools/compare_bench.py bench/results/c_wg8_host.json \\
                                bench/results/zig_wg8_host.json
    python tools/compare_bench.py c.json zig.json --require-zig-le --normalize-ts
    python tools/compare_bench.py c.json zig.json --checksum-scope all

With `--require-zig-le` (acceptance mode) the script exits non-zero when a
checksum gate fails, when a scenario is missing, or when the Zig `ns_per_op` or
weighted flash cost exceeds the C value by more than `--tolerance-pct`
(default 2.0 percent).  `--metric min` compares the fastest measured-phase
sample per scenario instead of the median (less sensitive to host noise).

Exit codes: 0 = pass (or informational run), 1 = failure, 2 = usage error.
"""

import argparse
import json
import sys

READ_WEIGHT = 1
WRITE_WEIGHT = 10
ERASE_WEIGHT = 100

TS_NAMES = ("tsl_append", "tsl_append_rollover", "tsl_iter_fwd", "tsl_iter_rev",
            "tsl_by_time", "tsl_query_count", "tsl_mount", "tsl_clean")


def is_kv(name):
    return name.startswith("kv_")


def is_ts(name):
    return name.startswith("tsl_")


def weighted_cost(flash):
    return (READ_WEIGHT * flash["read_bytes"]
            + WRITE_WEIGHT * flash["write_bytes"]
            + ERASE_WEIGHT * flash["erase_bytes"])


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except OSError as exc:
        raise SystemExit(f"compare_bench: cannot read '{path}': {exc}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"compare_bench: '{path}' is not valid JSON: {exc}")


def ratio(new, base):
    if base == 0:
        return float("inf") if new != 0 else 1.0
    return new / base


def fmt_ratio(r):
    if r == float("inf"):
        return "inf"
    return f"{r:.3f}"


def scenario_map(doc):
    return {s["name"]: s for s in doc.get("scenarios", [])}


def header_line(doc, label):
    return (f"{label:4s} {doc.get('impl'):4s} opt={doc.get('opt')} "
            f"wg={doc.get('write_gran')} runs={doc.get('config', {}).get('runs')} "
            f"compiler={doc.get('config', {}).get('compiler')}")


def scenario_ns_per_op(scenario, metric):
    ops = scenario["ops"]
    if metric == "min" and ops:
        samples = scenario.get("extra", {}).get("samples_ns") or []
        if samples:
            return min(samples) / ops
    return scenario["ns_per_op"]


def extra_int(scenario, *keys):
    extra = scenario.get("extra", {}) or {}
    for key in keys:
        value = extra.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return int(value)
    return None


def units_per_op(scenario):
    """How many logical units one measured op processes.

    * iter_fwd / iter_rev: one full iteration -> entries_per_iter
    * clean: one cycle -> appends_per_cycle
    * everything else: one unit per op (append/mount/query)
    """
    name = scenario["name"]
    if name in ("tsl_iter_fwd", "tsl_iter_rev"):
        n = extra_int(scenario, "entries_per_iter", "populated", "entries")
        return n if n else 1
    if name == "tsl_clean":
        n = extra_int(scenario, "appends_per_cycle", "entries")
        return n if n else 1
    return 1


def ts_entry_count(scenario):
    """Number of stored TS entries covered by the scenario (capacity proxy).

    Used for the capacity-dependent checksum policy: two implementations may
    legitimately store a different number of entries in the same partition.
    """
    n = extra_int(scenario, "populated", "entries_after", "entries_per_iter",
                  "entries", "appended")
    return n if n else int(scenario["ops"])


def ts_unit_count(scenario):
    return max(1, int(scenario["ops"]) * max(1, units_per_op(scenario)))


def unit_label(scenario):
    name = scenario["name"]
    if name in ("tsl_by_time", "tsl_query_count"):
        return "query"
    if name == "tsl_mount":
        return "mount"
    if name == "tsl_clean":
        return "append"
    return "entry"


def print_timing_table(rows, normalize_ts):
    if normalize_ts:
        print("-- timing and weighted flash cost (lower is better; TS rows also "
              "per unit below) --")
    else:
        print("-- timing and weighted flash cost (lower is better) --")
    print(f"{'scenario':22s} {'ops':>6s} {'C ns/op':>10s} {'Zig ns/op':>10s} "
          f"{'ratio':>6s} {'C weighted':>12s} {'Zig weighted':>12s} {'ratio':>6s} "
          f"{'checksum':>10s}")
    for r in rows:
        print(f"{r['name']:22s} {r['ops']:6d} {r['c_ns']:10.2f} {r['zig_ns']:10.2f} "
              f"{fmt_ratio(r['ns_ratio']):>6s} {r['c_cost']:12d} {r['zig_cost']:12d} "
              f"{fmt_ratio(r['cost_ratio']):>6s} {r['cs_label']:>10s}")


def print_flash_table(rows):
    print()
    print("-- flash traffic per scenario: C / Zig / (Zig - C) --")
    print(f"{'scenario':22s} {'reads':>22s} {'read_bytes':>24s} {'writes':>22s} "
          f"{'write_bytes':>24s} {'erases':>18s} {'erase_bytes':>22s}")
    for r in rows:
        cf = r["c_flash"]
        zf = r["zig_flash"]
        cells = []
        for key in ("reads", "read_bytes", "writes", "write_bytes", "erases",
                    "erase_bytes"):
            c = cf[key]
            z = zf[key]
            cells.append(f"{c}/{z} ({z - c:+d})")
        print(f"{r['name']:22s} {cells[0]:>22s} {cells[1]:>24s} {cells[2]:>22s} "
              f"{cells[3]:>24s} {cells[4]:>18s} {cells[5]:>22s}")


def print_ts_normalized(c_map, z_map):
    print()
    print("-- TS normalization (per unit; entries for fill/iteration scenarios, "
          "queries for ranged queries, appends for clean, mounts for mount) --")
    print(f"{'scenario':22s} {'unit':>6s} {'C units':>8s} {'Zig units':>9s} "
          f"{'C ns/u':>9s} {'Zig ns/u':>9s} {'ratio':>6s} "
          f"{'C rd/u':>8s} {'Zig rd/u':>9s} {'C wrB/u':>9s} {'Zig wrB/u':>9s} "
          f"{'C erB/u':>9s}")
    for name in TS_NAMES:
        if name not in c_map or name not in z_map:
            continue
        c = c_map[name]
        z = z_map[name]
        c_units = ts_unit_count(c)
        z_units = ts_unit_count(z)
        c_ns = (c["ns_per_op"] * c["ops"]) / c_units
        z_ns = (z["ns_per_op"] * z["ops"]) / z_units
        c_reads = c["flash"]["reads"] / c_units
        z_reads = z["flash"]["reads"] / z_units
        c_wb = c["flash"]["write_bytes"] / c_units
        z_wb = z["flash"]["write_bytes"] / z_units
        c_eb = c["flash"]["erase_bytes"] / c_units
        label = unit_label(c)
        print(f"{name:22s} {label:>6s} {c_units:8d} {z_units:9d} "
              f"{c_ns:9.2f} {z_ns:9.2f} {fmt_ratio(ratio(z_ns, c_ns)):>6s} "
              f"{c_reads:8.2f} {z_reads:9.2f} {c_wb:9.2f} {z_wb:9.2f} "
              f"{c_eb:9.2f}")


def main(argv):
    ap = argparse.ArgumentParser(
        description="Compare a C reference and a Zig benchmark JSON document.",
        epilog="KV checksums are a strict gate; TS checksums are capacity-"
               "dependent by design (use --checksum-scope all to force strict). "
               "Flash traffic differences are informational.")
    ap.add_argument("c_json", help="C reference JSON (bench/results/c_wg*_host.json)")
    ap.add_argument("zig_json", help="Zig JSON (bench/results/zig_wg*_host.json)")
    ap.add_argument("--require-zig-le", action="store_true",
                    help="acceptance mode: fail if Zig ns/op or weighted cost "
                         "exceeds C by more than --tolerance-pct")
    ap.add_argument("--tolerance-pct", type=float, default=2.0,
                    help="allowed Zig slowdown in percent (default 2.0)")
    ap.add_argument("--metric", choices=("median", "min"), default="median",
                    help="timing metric: 'median' = ns_per_op as reported by "
                         "the harness (protocol default), 'min' = fastest "
                         "measured-phase sample / ops (less sensitive to host "
                         "noise; falls back to ns_per_op when a document has "
                         "no per-run samples)")
    ap.add_argument("--checksum-scope", choices=("kv", "all"), default="kv",
                    help="'kv' (default): strict KV checksums, TS checksum "
                         "differences reported as capacity-dependent; 'all': "
                         "strict checksums for KV and TS")
    ap.add_argument("--normalize-ts", action="store_true",
                    help="print the TS per-entry/per-query normalization table")
    args = ap.parse_args(argv)

    c_doc = load_json(args.c_json)
    z_doc = load_json(args.zig_json)
    c_map = scenario_map(c_doc)
    z_map = scenario_map(z_doc)

    print("== C reference vs Zig host benchmark ==")
    print(header_line(c_doc, "C  "))
    print(header_line(z_doc, "Zig"))
    metric_note = ("per-run minimum sample / ops (host-noise resistant)"
                   if args.metric == "min"
                   else "median of the measured-phase samples (protocol default)")
    print(f"     timing metric: {args.metric} ({metric_note})")
    print(f"     checksum scope: {args.checksum_scope} "
          f"({'strict KV, capacity-dependent TS' if args.checksum_scope == 'kv' else 'strict all'})")
    c_cfg = c_doc.get("config", {})
    if c_cfg:
        print(f"     geometry: partition={c_cfg.get('partition_size')} "
              f"sector={c_cfg.get('sector_size')} "
              f"kv_cache={c_cfg.get('kv_cache_table_size')} "
              f"ts_max_log_len={c_cfg.get('ts_max_log_len')}")

    problems = []
    warnings = []
    if c_doc.get("impl") != "c":
        warnings.append(f"C document impl is '{c_doc.get('impl')}', expected 'c'")
    if z_doc.get("impl") != "zig":
        warnings.append(f"Zig document impl is '{z_doc.get('impl')}', expected 'zig'")
    if c_doc.get("write_gran") != z_doc.get("write_gran"):
        warnings.append(
            f"write_gran differs: C={c_doc.get('write_gran')} "
            f"Zig={z_doc.get('write_gran')}")
    if c_doc.get("opt") != z_doc.get("opt"):
        warnings.append(
            f"optimization differs: C={c_doc.get('opt')} Zig={z_doc.get('opt')}")

    names = [s["name"] for s in c_doc.get("scenarios", [])]
    missing = [n for n in names if n not in z_map]
    extra = [n for n in z_map if n not in c_map]
    if missing:
        problems.append(f"Zig document is missing scenarios: {', '.join(missing)}")
    if extra:
        warnings.append(f"Zig document has scenarios not in C: {', '.join(extra)}")

    rows = []
    checksum_failures = []
    ts_notes = []
    ts_prefix_verified = 0
    for name in names:
        if name not in z_map:
            continue
        c = c_map[name]
        z = z_map[name]
        c_flash = c["flash"]
        z_flash = z["flash"]
        c_cost = weighted_cost(c_flash)
        z_cost = weighted_cost(z_flash)
        c_ns = scenario_ns_per_op(c, args.metric)
        z_ns = scenario_ns_per_op(z, args.metric)
        cs_ok = c["checksum"] == z["checksum"]
        row = {
            "name": name,
            "ops": c["ops"],
            "c_ns": c_ns,
            "zig_ns": z_ns,
            "ns_ratio": ratio(z_ns, c_ns),
            "c_cost": c_cost,
            "zig_cost": z_cost,
            "cost_ratio": ratio(z_cost, c_cost),
            "cs_label": "match" if cs_ok else ("cap-dep" if is_ts(name) else "MISMATCH"),
            "c_flash": c_flash,
            "zig_flash": z_flash,
            "c_extra": c.get("extra", {}),
            "z_extra": z.get("extra", {}),
            "c_scenario": c,
            "z_scenario": z,
        }
        if is_ts(name):
            # The new TS format stores a different number of entries in the
            # same partition, so raw per-op costs are not comparable: the
            # acceptance gate compares cost per logical unit instead.
            c_units = max(1, ts_unit_count(c))
            z_units = max(1, ts_unit_count(z))
            row["c_units"] = c_units
            row["z_units"] = z_units
            row["gate_ns_ratio"] = ratio(
                (z_ns * z["ops"]) / z_units, (c_ns * c["ops"]) / c_units)
            row["gate_cost_ratio"] = ratio(z_cost / z_units, c_cost / c_units)
        else:
            row["gate_ns_ratio"] = row["ns_ratio"]
            row["gate_cost_ratio"] = row["cost_ratio"]
        rows.append(row)
        if c["ops"] != z["ops"]:
            warnings.append(f"{name}: op count differs: C={c['ops']} Zig={z['ops']}")

        if cs_ok:
            continue

        # ---- checksum gate -------------------------------------------------
        if is_kv(name) or args.checksum_scope == "all":
            checksum_failures.append(f"{name}: C={c['checksum']} Zig={z['checksum']}")
            continue

        # TS with the default capacity-dependent policy.
        c_entries = ts_entry_count(c)
        z_entries = ts_entry_count(z)
        z_extra = z.get("extra", {}) or {}
        verified = None
        if "c_ref_prefix_checksum" in z_extra:
            if int(z_extra["c_ref_prefix_checksum"]) == int(c["checksum"]):
                verified = "prefix-verified"
                ts_prefix_verified += 1
            else:
                checksum_failures.append(
                    f"{name}: Zig c_ref_prefix_checksum="
                    f"{z_extra['c_ref_prefix_checksum']} != C checksum {c['checksum']}")
                continue
        elif "c_ref_checksum" in z_extra:
            if int(z_extra["c_ref_checksum"]) == int(c["checksum"]):
                verified = "window-verified"
                ts_prefix_verified += 1
            else:
                checksum_failures.append(
                    f"{name}: Zig c_ref_checksum={z_extra['c_ref_checksum']} "
                    f"!= C checksum {c['checksum']}")
                continue
        if c_entries == z_entries:
            # Same amount of stored data but a different checksum would be a
            # real logical mismatch, not a capacity effect.
            checksum_failures.append(
                f"{name}: equal entry counts ({c_entries}) but checksums differ: "
                f"C={c['checksum']} Zig={z['checksum']}")
            continue
        ts_notes.append(
            f"{name}: capacity-dependent: zig={z_entries} entries vs c={c_entries}"
            + (f" ({verified})" if verified else " (no c_ref verification field)"))

    if not rows:
        print("\nFAIL: no common scenarios to compare", file=sys.stderr)
        return 1

    print()
    print_timing_table(rows, args.normalize_ts)
    print_flash_table(rows)
    if args.normalize_ts:
        print_ts_normalized(c_map, z_map)

    total_ns_c = sum(r["c_ns"] * r["ops"] for r in rows)
    total_ns_z = sum(r["zig_ns"] * r["ops"] for r in rows)
    total_cost_c = sum(r["c_cost"] for r in rows)
    total_cost_z = sum(r["zig_cost"] for r in rows)
    print()
    print(f"totals over {len(rows)} scenarios:")
    print(f"  wall time        C={total_ns_c / 1e6:10.3f} ms  "
          f"Zig={total_ns_z / 1e6:10.3f} ms  "
          f"ratio={fmt_ratio(ratio(total_ns_z, total_ns_c))}")
    print(f"  weighted flash   C={total_cost_c:12d}  Zig={total_cost_z:12d}  "
          f"ratio={fmt_ratio(ratio(total_cost_z, total_cost_c))}")

    print()
    kv_rows = [r for r in rows if is_kv(r["name"])]
    ts_rows = [r for r in rows if is_ts(r["name"])]
    kv_mismatch = [r["name"] for r in kv_rows if r["cs_label"] != "match"]
    ts_mismatch = [r["name"] for r in ts_rows if r["cs_label"] != "match"]
    print("-- checksums --")
    if kv_mismatch:
        print(f"  KV : FAIL ({len(kv_mismatch)}/{len(kv_rows)} differ)")
    else:
        print(f"  KV : PASS ({len(kv_rows)}/{len(kv_rows)} strict match)")
    if ts_mismatch:
        if args.checksum_scope == "kv":
            print(f"  TS : capacity-dependent ({len(ts_mismatch)}/{len(ts_rows)} raw "
                  f"checksums differ; semantics covered by bench/diff)")
            if ts_prefix_verified:
                print(f"       {ts_prefix_verified}/{len(ts_mismatch)} "
                      f"capacity-independent checks verified against C via "
                      f"c_ref_* fields")
            for note in ts_notes:
                print(f"       {note}")
        else:
            print(f"  TS : FAIL ({len(ts_mismatch)}/{len(ts_rows)} differ; "
                  f"strict --checksum-scope all)")
    else:
        print(f"  TS : PASS ({len(ts_rows)}/{len(ts_rows)} strict match)")

    tol = max(0.0, args.tolerance_pct) / 100.0
    slow = [r for r in rows
            if r["gate_ns_ratio"] > 1.0 + tol or r["gate_cost_ratio"] > 1.0 + tol]
    worst_ns = max(rows, key=lambda r: r["gate_ns_ratio"])
    worst_cost = max(rows, key=lambda r: r["gate_cost_ratio"])
    print(f"-- worst gate ns ratio  : {fmt_ratio(worst_ns['gate_ns_ratio'])} "
          f"({worst_ns['name']}"
          f"{', per ' + unit_label(worst_ns['c_scenario']) if is_ts(worst_ns['name']) else ''})")
    print(f"-- worst gate cost ratio: {fmt_ratio(worst_cost['gate_cost_ratio'])} "
          f"({worst_cost['name']}"
          f"{', per ' + unit_label(worst_cost['c_scenario']) if is_ts(worst_cost['name']) else ''})")

    if args.require_zig_le and slow:
        for r in slow:
            unit = (f" per {unit_label(r['c_scenario'])}" if is_ts(r["name"]) else "")
            problems.append(
                f"{r['name']}: Zig is slower than C{unit} (ns ratio "
                f"{fmt_ratio(r['gate_ns_ratio'])}, weighted ratio "
                f"{fmt_ratio(r['gate_cost_ratio'])}, tolerance "
                f"{args.tolerance_pct:.1f}%)")

    for w in warnings:
        print(f"WARNING: {w}")

    print()
    if problems or checksum_failures:
        for p in problems:
            print(f"FAIL: {p}", file=sys.stderr)
        for p in checksum_failures:
            print(f"FAIL: checksum: {p}", file=sys.stderr)
        print("FAIL: comparison did not meet the acceptance criteria", file=sys.stderr)
        return 1

    if args.require_zig_le:
        print(f"PASS: Zig is at least as good as C on all {len(rows)} scenarios "
              f"(ns/op and weighted cost within +{args.tolerance_pct:.1f}% "
              f"tolerance); KV checksums strict, TS capacity-dependent")
    else:
        print(f"PASS: {len(rows)} scenarios compared; KV checksums strict, "
              f"TS checksums capacity-dependent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
