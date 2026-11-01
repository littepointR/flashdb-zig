#!/usr/bin/env python3
"""C<->Zig behavioural differential harness runner (KV + TS).

Runs the C reference program (bench/diff/c/diff_bench.c) and the Zig program
(bench/diff/zig/main.zig), which execute the identical deterministic KV and
TSDB operation scripts, then compares their canonical `DIFF` output.

Two kinds of comparison:

* the **main script** sections (KV header/CONFIG/OP/checkpoints/STATE/SUMMARY
  and the TS `TS-DIFF` block) must match the C output line for line.  This
  proves logical parity of every operation of the scripts even though the
  on-flash formats differ.
* the **crash-recovery** sections are format dependent by design: the number of
  flash mutations per operation differs between the C format and the new Zig
  format, so cut indexes do not line up.  The tool validates the semantics:
    - KV: every post-crash visible state must be an allowed outcome (set: old
      or new value; delete: old value or absent; untouched keys keep the old
      value), the last cut must show the completed state and both
      implementations must produce the same canonical dump digest for it;
    - TS: every cut must keep all pre-crash committed entries visible
      (`base_mask=0xff`) and the new entry must be either fully present or
      absent (`new_present` 0/1); the last cut must show it present and both
      implementations must agree on the canonical completed dump digest.
  Differences caused by the formats (mutation counts, C's `fdb_kvdb_check`
  flagging a torn tail) are reported as allowed and do not fail the run.

Exit status: 0 = logical parity verified, 1 = difference / run failure,
2 = usage error.

Usage:
    python tools/diff_model.py build/diff/diff_c.exe build/diff/diff_zig.exe
    python tools/diff_model.py ... --save-dir build/diff --verbose
"""

import argparse
import re
import subprocess
import sys

CRASH_RE = re.compile(
    r"^CRASH phase=(\w+) cut=(\d+) outcome=(\w+) check=(\d+) count=(\d+) "
    r"dump_fnv=0x([0-9a-fA-F]{8}) states=(.*)$")
CRASH_BEGIN_RE = re.compile(
    r"^CRASH-BEGIN phase=(\w+) target=(\w+) old_fnv=0x([0-9a-fA-F]{8}) "
    r"new_fnv=0x([0-9a-fA-F]{8})$")
CRASH_END_RE = re.compile(r"^CRASH-END phase=(\w+) cuts=(\d+)$")

TS_CRASH_RE = re.compile(
    r"^TS-CRASH cut=(\d+) outcome=(\w+) last_time=(-?\d+) base_mask=0x([0-9a-fA-F]{2}) "
    r"new_present=(\d) dump_fnv=0x([0-9a-fA-F]{8})$")
TS_CRASH_BEGIN_RE = re.compile(
    r"^TS-CRASH-BEGIN base_dump=0x([0-9a-fA-F]{8}) new_dump=0x([0-9a-fA-F]{8})$")
TS_CRASH_END_RE = re.compile(r"^TS-CRASH-END cuts=(\d+)$")

# Per-phase semantics used by the KV crash validation.
PHASE_RULES = {
    "set": {
        "target": "k03",
        "target_allowed": ("old", "new"),
        "target_final": "new",
        "count_allowed": (8,),
        "new_value": True,
    },
    "del": {
        "target": "k01",
        "target_allowed": ("old", "absent"),
        "target_final": "absent",
        "count_allowed": (7, 8),
        "new_value": False,
    },
}


def load_output(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as exc:
        raise SystemExit(f"diff_model: cannot read '{path}': {exc}")


def run_program(path):
    try:
        proc = subprocess.run([path], capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=300)
    except OSError as exc:
        raise SystemExit(f"diff_model: cannot run '{path}': {exc}")
    except subprocess.TimeoutExpired:
        raise SystemExit(f"diff_model: '{path}' timed out")
    return proc


def split_lines(text):
    return [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]


def normalize_main_line(line):
    """Normalise the intentional impl= difference in DIFF / TS-DIFF headers."""
    if line.startswith("DIFF ") or line.startswith("TS-DIFF "):
        return line.split(" impl=")[0]
    return line


def find_line(lines, prefix):
    return next((i for i, line in enumerate(lines) if line.startswith(prefix)), None)


# ---------------------------------------------------------------------------
# KV crash section
# ---------------------------------------------------------------------------

def parse_crash(lines):
    """Parse the KV crash section into {phase: {begin, cuts[], end}}."""
    phases = {}
    for line in lines:
        m = CRASH_BEGIN_RE.match(line)
        if m:
            phase, target, old_fnv, new_fnv = m.groups()
            phases[phase] = {
                "target": target,
                "old_fnv": old_fnv.lower(),
                "new_fnv": new_fnv.lower(),
                "cuts": [],
                "end": None,
            }
            continue
        m = CRASH_END_RE.match(line)
        if m:
            phase, cuts = m.groups()
            if phase not in phases:
                phases[phase] = {"cuts": [], "end": None}
            phases[phase]["end"] = int(cuts)
            continue
        m = CRASH_RE.match(line)
        if m:
            phase, cut, outcome, check, count, dump_fnv, states = m.groups()
            state_map = {}
            for tok in states.split(","):
                key, value = tok.split("=")
                state_map[key] = value
            if phase not in phases:
                phases[phase] = {"cuts": [], "end": None}
            phases[phase]["cuts"].append({
                "cut": int(cut),
                "outcome": outcome,
                "check": int(check),
                "count": int(count),
                "dump_fnv": dump_fnv.lower(),
                "states": state_map,
            })
            continue
        if line:
            raise ValueError(f"unexpected line in KV crash section: {line!r}")
    return phases


def validate_kv_phase(name, info, side):
    problems = []
    rule = PHASE_RULES[name]
    cuts = info["cuts"]
    if not cuts:
        return [f"{side}: KV phase {name}: no cut lines"]

    if [c["cut"] for c in cuts] != list(range(len(cuts))):
        problems.append(f"{side}: KV phase {name}: cut indexes are not 0..{len(cuts) - 1}")
    if info["end"] != len(cuts):
        problems.append(f"{side}: KV phase {name}: CRASH-END cuts={info['end']} "
                        f"does not match {len(cuts)} parsed cuts")

    for idx, c in enumerate(cuts):
        states = c["states"]
        if set(states.keys()) != {f"k{i:02d}" for i in range(8)}:
            problems.append(f"{side}: KV phase {name} cut {c['cut']}: unexpected state keys")
            continue
        target = rule["target"]
        if states[target] not in rule["target_allowed"]:
            problems.append(
                f"{side}: KV phase {name} cut {c['cut']}: target {target}="
                f"{states[target]} (allowed {rule['target_allowed']})")
        for key, value in states.items():
            if key == target:
                continue
            if value != "old":
                problems.append(
                    f"{side}: KV phase {name} cut {c['cut']}: untouched {key}={value}")
        if c["count"] not in rule["count_allowed"]:
            problems.append(f"{side}: KV phase {name} cut {c['cut']}: count={c['count']}")
        is_last = idx == len(cuts) - 1
        if is_last:
            if c["outcome"] != "ok":
                problems.append(f"{side}: KV phase {name}: last cut did not complete")
            if states[target] != rule["target_final"]:
                problems.append(
                    f"{side}: KV phase {name}: completed state has {target}="
                    f"{states[target]}, expected {rule['target_final']}")
        elif c["outcome"] != "fault":
            problems.append(
                f"{side}: KV phase {name} cut {c['cut']}: outcome={c['outcome']} "
                f"before the last cut")
    return problems


# ---------------------------------------------------------------------------
# TS crash section
# ---------------------------------------------------------------------------

def parse_ts_crash(lines):
    """Parse the TS crash section into {begin, cuts[], end}."""
    info = {"base_dump": None, "new_dump": None, "cuts": [], "end": None}
    for line in lines:
        m = TS_CRASH_BEGIN_RE.match(line)
        if m:
            info["base_dump"], info["new_dump"] = (g.lower() for g in m.groups())
            continue
        m = TS_CRASH_END_RE.match(line)
        if m:
            info["end"] = int(m.group(1))
            continue
        m = TS_CRASH_RE.match(line)
        if m:
            cut, outcome, last_time, base_mask, new_present, dump_fnv = m.groups()
            info["cuts"].append({
                "cut": int(cut),
                "outcome": outcome,
                "last_time": int(last_time),
                "base_mask": int(base_mask, 16),
                "new_present": int(new_present),
                "dump_fnv": dump_fnv.lower(),
            })
            continue
        if line:
            raise ValueError(f"unexpected line in TS crash section: {line!r}")
    return info


def validate_ts_crash(info, side):
    problems = []
    cuts = info["cuts"]
    if not cuts:
        return [f"{side}: TS crash: no cut lines"]
    if [c["cut"] for c in cuts] != list(range(len(cuts))):
        problems.append(f"{side}: TS crash: cut indexes are not 0..{len(cuts) - 1}")
    if info["end"] != len(cuts):
        problems.append(f"{side}: TS crash: TS-CRASH-END cuts={info['end']} "
                        f"does not match {len(cuts)} parsed cuts")
    for idx, c in enumerate(cuts):
        is_last = idx == len(cuts) - 1
        if c["base_mask"] != 0xFF:
            problems.append(
                f"{side}: TS crash cut {c['cut']}: base_mask=0x{c['base_mask']:02x} "
                f"(pre-crash entries must stay visible)")
        if c["new_present"] not in (0, 1):
            problems.append(f"{side}: TS crash cut {c['cut']}: new_present not 0/1")
        if is_last:
            if c["outcome"] != "ok":
                problems.append(f"{side}: TS crash: last cut did not complete")
            if c["new_present"] != 1:
                problems.append(f"{side}: TS crash: completed cut is missing the new entry")
            if c["last_time"] != 1100:
                problems.append(
                    f"{side}: TS crash: completed cut last_time={c['last_time']}, expected 1100")
            if info["new_dump"] is None or c["dump_fnv"] != info["new_dump"]:
                problems.append(
                    f"{side}: TS crash: completed cut dump 0x{c['dump_fnv']} != "
                    f"new_dump {info['new_dump']}")
        else:
            if c["outcome"] != "fault":
                problems.append(
                    f"{side}: TS crash cut {c['cut']}: outcome={c['outcome']} "
                    f"before the last cut")
            if c["last_time"] not in (1007, 1100):
                problems.append(
                    f"{side}: TS crash cut {c['cut']}: last_time={c['last_time']}")
    return problems


# ---------------------------------------------------------------------------

def compare_main_section(label, c_main, z_main, verbose, failures):
    print()
    print(f"-- {label} --")
    if len(c_main) != len(z_main):
        failures.append(f"{label}: line count differs: C={len(c_main)} Zig={len(z_main)}")
    common = min(len(c_main), len(z_main))
    first_diff = None
    for i in range(common):
        a = normalize_main_line(c_main[i])
        b = normalize_main_line(z_main[i])
        if verbose:
            print(f"  {i + 1:5d} {'OK ' if a == b else 'DIFF'} {a[:110]}")
        if a != b and first_diff is None:
            first_diff = (i, c_main[i], z_main[i])
    if first_diff is not None:
        i, c_line, z_line = first_diff
        failures.append(f"{label} differs at line {i + 1}:\n"
                        f"    C  : {c_line}\n    Zig: {z_line}")
        for ctx in range(max(0, i - 2), i):
            print(f"  context C  : {c_main[ctx]}")
            print(f"  context Zig: {z_main[ctx]}")
    if first_diff is None and len(c_main) == len(z_main):
        ops = len([l for l in c_main if l.startswith("OP ") or l.startswith("TS-OP ")])
        checkpoints = len([l for l in c_main if l.startswith("CHECKPOINT ") or
                           l.startswith("TS-CHECKPOINT ")])
        print(f"  IDENTICAL: {len(c_main)} canonical lines "
              f"({ops} OP lines, {checkpoints} checkpoints, final state/roll/summary)")
    return first_diff is None and len(c_main) == len(z_main)


def main(argv):
    ap = argparse.ArgumentParser(
        description="Run the C and Zig behavioural differential harnesses and "
                    "compare their canonical DIFF output (KV + TS).")
    ap.add_argument("c_exe", help="C differential executable")
    ap.add_argument("zig_exe", help="Zig differential executable")
    ap.add_argument("--save-dir", default=None,
                    help="write the captured outputs to this directory")
    ap.add_argument("--verbose", action="store_true", help="print every line comparison")
    args = ap.parse_args(argv)

    print("== C<->Zig behavioural differential (KV + TS) ==")
    print(f"C   : {args.c_exe}")
    print(f"Zig : {args.zig_exe}")

    c_proc = run_program(args.c_exe)
    z_proc = run_program(args.zig_exe)

    if args.save_dir:
        import os
        os.makedirs(args.save_dir, exist_ok=True)
        for name, proc in (("diff_c.out.txt", c_proc), ("diff_zig.out.txt", z_proc),
                           ("diff_c.err.txt", c_proc), ("diff_zig.err.txt", z_proc)):
            with open(f"{args.save_dir}/{name}", "w", encoding="ascii",
                      errors="replace") as f:
                f.write(proc.stdout if name.startswith("diff_c.out") or
                        name.startswith("diff_zig.out") else proc.stderr)

    failures = []
    for name, proc in (("C", c_proc), ("Zig", z_proc)):
        print(f"{name:3s}: exit={proc.returncode} "
              f"stdout={len(proc.stdout.splitlines())} lines")
        if proc.returncode != 0:
            failures.append(f"{name} program exited with {proc.returncode}")
            if proc.stderr.strip():
                print(f"  stderr: {proc.stderr.strip()[:2000]}")
        elif proc.stderr.strip():
            print(f"  stderr (diagnostics): {proc.stderr.strip()[:1000]}")

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1

    c_lines = split_lines(c_proc.stdout)
    z_lines = split_lines(z_proc.stdout)

    # Section boundaries: KV main, KV crash, TS main, TS crash.
    c_kv_crash = find_line(c_lines, "CRASH-BEGIN")
    c_ts_hdr = find_line(c_lines, "TS-DIFF ")
    c_ts_crash = find_line(c_lines, "TS-CRASH-BEGIN")
    z_kv_crash = find_line(z_lines, "CRASH-BEGIN")
    z_ts_hdr = find_line(z_lines, "TS-DIFF ")
    z_ts_crash = find_line(z_lines, "TS-CRASH-BEGIN")
    if None in (c_kv_crash, c_ts_hdr, c_ts_crash, z_kv_crash, z_ts_hdr, z_ts_crash):
        print("FAIL: a program is missing the KV/TS section markers", file=sys.stderr)
        return 1
    if not (c_kv_crash < c_ts_hdr < c_ts_crash) or not (z_kv_crash < z_ts_hdr < z_ts_crash):
        print("FAIL: section markers are out of order", file=sys.stderr)
        return 1

    compare_main_section("KV main script", c_lines[:c_kv_crash],
                         z_lines[:z_kv_crash], args.verbose, failures)

    print()
    print("-- KV crash recovery (format dependent; validated, not diffed) --")
    try:
        c_crash = parse_crash(c_lines[c_kv_crash:c_ts_hdr])
        z_crash = parse_crash(z_lines[z_kv_crash:z_ts_hdr])
    except ValueError as exc:
        failures.append(str(exc))
        c_crash = {}
        z_crash = {}

    all_phases = sorted(set(c_crash) | set(z_crash))
    if not all_phases:
        failures.append("no KV crash phases parsed")
    for phase in all_phases:
        if phase not in PHASE_RULES:
            failures.append(f"unknown KV crash phase '{phase}'")
            continue
        rule = PHASE_RULES[phase]
        if phase not in c_crash or phase not in z_crash:
            failures.append(f"KV phase '{phase}' missing on one side")
            continue
        failures.extend(validate_kv_phase(phase, c_crash[phase], "C"))
        failures.extend(validate_kv_phase(phase, z_crash[phase], "Zig"))

        c_info = c_crash[phase]
        z_info = z_crash[phase]
        if (c_info["old_fnv"], c_info["new_fnv"]) != (z_info["old_fnv"], z_info["new_fnv"]):
            failures.append(
                f"KV phase '{phase}': CRASH-BEGIN old/new fnv differ: "
                f"C=({c_info['old_fnv']},{c_info['new_fnv']}) "
                f"Zig=({z_info['old_fnv']},{z_info['new_fnv']})")
        if c_info["target"] != rule["target"] or z_info["target"] != rule["target"]:
            failures.append(f"KV phase '{phase}': unexpected target key")

        c_cuts = c_info["cuts"]
        z_cuts = z_info["cuts"]
        if not c_cuts or not z_cuts:
            continue
        c_final = c_cuts[-1]
        z_final = z_cuts[-1]
        if c_final["dump_fnv"] != z_final["dump_fnv"]:
            failures.append(
                f"KV phase '{phase}': completed post-crash dump differs: "
                f"C=0x{c_final['dump_fnv']} Zig=0x{z_final['dump_fnv']}")

        c_targets = {c["states"][rule["target"]] for c in c_cuts}
        z_targets = {c["states"][rule["target"]] for c in z_cuts}
        c_checks = sorted({c["cut"] for c in c_cuts if c["check"] == 0})
        z_checks = sorted({c["cut"] for c in z_cuts if c["check"] == 0})
        print(f"  {phase:4s}: C {len(c_cuts):2d} cuts, Zig {len(z_cuts):2d} cuts "
              f"(format-dependent, allowed)")
        print(f"        observed target states C={sorted(c_targets)} Zig={sorted(z_targets)}")
        print(f"        completed dump_fnv C=0x{c_final['dump_fnv']} "
              f"Zig=0x{z_final['dump_fnv']} "
              f"{'MATCH' if c_final['dump_fnv'] == z_final['dump_fnv'] else 'DIFFER'}")
        if c_targets != z_targets:
            print("        INFO: outcome set differs (allowed by the new format)")
        if c_checks != z_checks:
            print(f"        INFO: fdb_kvdb_check flagged cuts C={c_checks} Zig={z_checks} "
                  f"(C's check reports a torn tail as FDB_READ_ERR until GC; "
                  f"visible state is still valid)")

    compare_main_section("TS main script", c_lines[c_ts_hdr:c_ts_crash],
                         z_lines[z_ts_hdr:z_ts_crash], args.verbose, failures)

    print()
    print("-- TS crash recovery (format dependent; validated, not diffed) --")
    try:
        c_ts_crash_info = parse_ts_crash(c_lines[c_ts_crash:])
        z_ts_crash_info = parse_ts_crash(z_lines[z_ts_crash:])
    except ValueError as exc:
        failures.append(str(exc))
        c_ts_crash_info = {"cuts": [], "end": None, "base_dump": None, "new_dump": None}
        z_ts_crash_info = dict(c_ts_crash_info)

    failures.extend(validate_ts_crash(c_ts_crash_info, "C"))
    failures.extend(validate_ts_crash(z_ts_crash_info, "Zig"))
    if (c_ts_crash_info["base_dump"] != z_ts_crash_info["base_dump"] or
            c_ts_crash_info["new_dump"] != z_ts_crash_info["new_dump"]):
        failures.append(
            "TS crash: expected dumps differ: "
            f"C=(0x{c_ts_crash_info['base_dump']},0x{c_ts_crash_info['new_dump']}) "
            f"Zig=(0x{z_ts_crash_info['base_dump']},0x{z_ts_crash_info['new_dump']})")
    c_cuts = c_ts_crash_info["cuts"]
    z_cuts = z_ts_crash_info["cuts"]
    if c_cuts and z_cuts:
        c_final = c_cuts[-1]
        z_final = z_cuts[-1]
        if c_final["dump_fnv"] != z_final["dump_fnv"]:
            failures.append(
                "TS crash: completed post-crash dump differs: "
                f"C=0x{c_final['dump_fnv']} Zig=0x{z_final['dump_fnv']}")
        c_new = {c["new_present"] for c in c_cuts}
        z_new = {c["new_present"] for c in z_cuts}
        print(f"  set : C {len(c_cuts):2d} cuts, Zig {len(z_cuts):2d} cuts "
              f"(format-dependent, allowed)")
        print(f"        new entry observed C={sorted(c_new)} Zig={sorted(z_new)}")
        print(f"        completed dump_fnv C=0x{c_final['dump_fnv']} "
              f"Zig=0x{z_final['dump_fnv']} "
              f"{'MATCH' if c_final['dump_fnv'] == z_final['dump_fnv'] else 'DIFFER'}")
        if c_new != z_new:
            print("        INFO: new-entry outcome set differs (allowed: commit is a "
                  "single granule in both formats)")

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        print("FAIL: differential did not verify logical parity", file=sys.stderr)
        return 1

    print("PASS: KV+TS logical parity verified (main scripts identical; every crash "
          "state valid; completed states identical)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
