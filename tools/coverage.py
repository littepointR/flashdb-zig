#!/usr/bin/env python3
"""Measure function-level test coverage of the Zig library.

Zig 0.18 does not expose LLVM's source-based coverage instrumentation
(`-fprofile-instr-generate` / `-fcoverage-mapping` are not part of the CLI and
`lib/compiler_rt` has no profiling runtime), so line coverage cannot be produced
with the stock toolchain. This script therefore measures **function coverage**,
which is toolchain independent and reproducible:

  1. copies `src/` and the integration/model tests into `build/coverage/gen/`,
  2. instruments every function body in `src/` with a one-shot "hit" probe
     (test blocks are left untouched),
  3. builds a single test root that runs the unit tests of every source file
     plus the integration and randomized model suites,
  4. collects the probes and reports per-file / overall function coverage.

The instrumentation only modifies the generated copies under `build/`, never
the repository sources. Exit code is non-zero when coverage is below
`--min-functions` (default 0, i.e. report only).

Usage:
    python tools/coverage.py
    python tools/coverage.py --min-functions 90
    python tools/coverage.py --json build/coverage/report.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "build", "coverage", "gen")
ZIG = os.path.join(ROOT, ".tools", "zig", "zig.exe" if os.name == "nt" else "zig")

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
BODY_SKIP_WORDS = {"error", "struct", "union", "enum", "opaque", "packed"}


def strip_noise(text: str) -> str:
    """Blank out comments and string/char literals so the scanner sees code only."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "\\" and i + 1 < n and text[i + 1] == "\\":
            # Zig multiline string line: `\\...` up to and including the newline.
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
        elif c == '"':
            out[i] = " "
            i += 1
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                ch = text[i]
                out[i] = " "
                i += 1
                if ch == '"':
                    break
        elif c == "'":
            out[i] = " "
            i += 1
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    out[i] = out[i + 1] = " "
                    i += 2
                    continue
                ch = text[i]
                out[i] = " "
                i += 1
                if ch == "'":
                    break
        else:
            i += 1
    return "".join(out)


def match_brace(code: str, start: int) -> int:
    """Index of the `}` matching the `{` at `start` (code already stripped)."""
    depth = 0
    i = start
    while i < len(code):
        if code[i] == "{":
            depth += 1
        elif code[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def skip_balanced(code: str, start: int, open_ch: str, close_ch: str) -> int:
    depth = 0
    i = start
    while i < len(code):
        if code[i] == open_ch:
            depth += 1
        elif code[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(code) - 1


def first_test_offset(code: str) -> int:
    m = re.search(r"(?m)^\s*test\b", code)
    return m.start() if m else len(code)


def test_block_ranges(code: str) -> list[tuple[int, int]]:
    ranges = []
    for m in re.finditer(r"(?m)^\s*test\b", code):
        brace = code.find("{", m.end())
        if brace < 0:
            continue
        end = match_brace(code, brace)
        if end > 0:
            ranges.append((m.start(), end))
    return ranges


def find_functions(text: str) -> list[dict]:
    """Return {name, line, insert_at, is_pub} for every function body in `text`."""
    code = strip_noise(text)
    tests = test_block_ranges(code)

    first_test = first_test_offset(code)

    def in_test(pos: int) -> bool:
        # Test blocks themselves plus any helper defined after the first test
        # declaration (e.g. `fn freshFlash(...)` between tests) are scaffolding,
        # not library coverage units.
        return pos >= first_test or any(start <= pos <= end for start, end in tests)

    funcs: list[dict] = []
    pos = 0
    while True:
        m = re.compile(r"\bfn\b").search(code, pos)
        if not m:
            break
        pos = m.end()
        if in_test(m.start()):
            continue
        # Function name: identifier or @"quoted".
        i = pos
        while i < len(code) and code[i] in " \t\r\n":
            i += 1
        if i < len(code) and code[i] == "@":
            i = code.find('"', i)
            if i < 0:
                continue
            i = code.find('"', i + 1) + 1
            name = "<quoted>"
        else:
            nm = IDENT.match(code, i)
            if not nm:
                continue
            name = nm.group(0)
            i = nm.end()
        # Parameters.
        while i < len(code) and code[i] in " \t\r\n":
            i += 1
        if i >= len(code) or code[i] != "(":
            continue
        i = skip_balanced(code, i, "(", ")") + 1
        # Return type / body: the first `{` that is not an inline type/error set.
        while i < len(code):
            ch = code[i]
            if ch == ";":
                break
            if ch == "(":
                i = skip_balanced(code, i, "(", ")") + 1
                continue
            if ch == "{":
                before = code[:i].rstrip()
                word = IDENT.search(before[::-1])
                last_word = word.group(0)[::-1] if word else ""
                if last_word in BODY_SKIP_WORDS:
                    i = match_brace(code, i) + 1
                    continue
                # Body found.
                line = text.count("\n", 0, i) + 1
                prefix = code[: m.start()].rstrip()
                prev = IDENT.search(prefix[::-1])
                is_pub = bool(prev and prev.group(0)[::-1] == "pub")
                # `fn Foo(...) type { ... }` factories only run at comptime, so
                # they are not runtime coverage units (their returned struct's
                # methods are still instrumented below).
                if last_word != "type":
                    funcs.append(
                        {"name": name, "line": line, "insert_at": i + 1, "pub": is_pub}
                    )
                pos = i + 1
                break
            i += 1
    funcs.sort(key=lambda f: f["insert_at"])
    return funcs


def instrument(text: str, funcs: list[dict], first_id: int) -> tuple[str, list[dict]]:
    entries = []
    for offset, f in enumerate(funcs):
        entries.append(
            {"id": first_id + offset, "name": f["name"], "line": f["line"], "pub": f["pub"]}
        )
    # Insert from the end so earlier offsets stay valid.
    out = text
    for entry, f in reversed(list(zip(entries, funcs))):
        probe = f'@import("cover.zig").hit({entry["id"]});'
        out = out[: f["insert_at"]] + probe + out[f["insert_at"]:]
    return out, entries


def is_comptime_context(code: str, pos: int) -> bool:
    """True when the token at `pos` is evaluated at compile time.

    Two forms are recognised: a reference inside a `comptime { ... }` block and
    a reference prefixed by the `comptime` keyword (`comptime f(x)`). Such code
    runs while the test binary is compiled, so a function whose every reference
    is of this form is exercised by the suite at build time even though no probe
    can fire at runtime.
    """
    stack: list[bool] = []
    i = 0
    while i < pos:
        if code[i] == "{":
            j = i - 1
            while j >= 0 and code[j] in " \t\r\n":
                j -= 1
            k = j
            while k >= 0 and (code[k].isalnum() or code[k] == "_"):
                k -= 1
            stack.append(code[k + 1 : j + 1] == "comptime")
        elif code[i] == "}":
            if stack:
                stack.pop()
        i += 1
    if stack and stack[-1]:
        return True
    j = pos - 1
    while j >= 0 and code[j] in " \t\r\n":
        j -= 1
    k = j
    while k >= 0 and (code[k].isalnum() or code[k] == "_"):
        k -= 1
    return code[k + 1 : j + 1] == "comptime"


def comptime_only_names(path: str, funcs: list[dict]) -> set[str]:
    """Names of functions in `path` that are only ever evaluated at compile time."""
    with open(path, encoding="utf-8") as f:
        code = strip_noise(f.read())
    out: set[str] = set()
    for fn in funcs:
        pat = re.compile(r"\b" + re.escape(fn["name"]) + r"\b\s*\(")
        refs = []
        for m in pat.finditer(code):
            if re.search(r"fn\s+$", code[: m.start()]):
                continue  # the definition itself
            refs.append(m.start())
        if refs and all(is_comptime_context(code, p) for p in refs):
            out.add(fn["name"])
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--min-functions", type=float, default=0.0, help="fail below this function coverage percentage")
    ap.add_argument("--json", default="build/coverage/report.json", help="write a JSON report here")
    ap.add_argument("--keep", action="store_true", help="keep the generated instrumented tree")
    args = ap.parse_args()

    if not os.path.exists(ZIG):
        raise SystemExit(f"pinned zig not found: {ZIG} (run tools/bootstrap.py)")

    if os.path.isdir(GEN):
        shutil.rmtree(GEN)
    os.makedirs(os.path.join(GEN, "src"), exist_ok=True)
    os.makedirs(os.path.join(GEN, "tests"), exist_ok=True)

    manifest: list[dict] = []
    next_id = 0
    src_dir = os.path.join(ROOT, "src")
    for name in sorted(os.listdir(src_dir)):
        if not name.endswith(".zig"):
            continue
        with open(os.path.join(src_dir, name), encoding="utf-8") as f:
            text = f.read()
        funcs = find_functions(text)
        instrumented, entries = instrument(text, funcs, next_id)
        next_id += len(entries)
        for entry in entries:
            entry["file"] = f"src/{name}"
        manifest.extend(entries)
        with open(os.path.join(GEN, "src", name), "w", encoding="utf-8", newline="\n") as f:
            f.write(instrumented)

    with open(os.path.join(GEN, "src", "cover.zig"), "w", encoding="utf-8") as f:
        f.write(
            "//! Generated coverage probes (see tools/coverage.py).\n"
            "const std = @import(\"std\");\n\n"
            f"pub var seen: [{max(next_id, 1)}]bool = @splat(false);\n\n"
            "pub fn hit(comptime id: usize) void {\n"
            "    if (@inComptime()) return;\n"
            "    if (seen[id]) return;\n"
            "    seen[id] = true;\n"
            "    std.debug.print(\"COVHIT {d}\\n\", .{id});\n"
            "}\n"
        )

    # Integration and model tests, rewired from the `flashdb` module import to
    # the instrumented sources in this generated tree.
    test_copies = []
    for name in ("kvdb_integration.zig", "kv_model.zig"):
        with open(os.path.join(ROOT, "tests", name), encoding="utf-8") as f:
            text = f.read()
        text = text.replace('@import("flashdb")', '@import("../src/flashdb.zig")')
        with open(os.path.join(GEN, "tests", name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        test_copies.append(name)

    src_files = sorted(
        "src/" + n for n in os.listdir(src_dir) if n.endswith(".zig")
    )
    root_lines = ["//! Generated coverage test root (tools/coverage.py).", "test {"]
    for path in src_files:
        root_lines.append(f'    _ = @import("{path}");')
    for name in test_copies:
        root_lines.append(f'    _ = @import("tests/{name}");')
    root_lines.append("}")
    root_path = os.path.join(GEN, "all_tests.zig")
    with open(root_path, "w", encoding="utf-8") as f:
        f.write("\n".join(root_lines) + "\n")

    print(f"instrumented {next_id} functions in {len(src_files)} source files")
    print(f"building and running: {os.path.relpath(root_path, ROOT)}")
    proc = subprocess.run(
        [ZIG, "test", root_path, "-O", "Debug", "--cache-dir", os.path.join(ROOT, ".zig-cache")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        print(proc.stdout[-4000:])
        print(proc.stderr[-4000:], file=sys.stderr)
        raise SystemExit(f"test run failed with exit code {proc.returncode}")

    # std.debug.print output can be appended to the test runner's progress line
    # (which does not end with a newline), so search anywhere in the stream.
    hit_ids = {int(m.group(1)) for m in re.finditer(r"COVHIT (\d+)", proc.stderr)}

    by_file: dict[str, list[dict]] = {}
    for entry in manifest:
        entry["hit"] = entry["id"] in hit_ids
        by_file.setdefault(entry["file"], []).append(entry)

    # A function that is only referenced from comptime contexts runs while the
    # test binary is built, so no runtime probe can ever fire for it. Classify
    # those statically (from the untouched sources) and count them separately.
    for path, entries in by_file.items():
        unhit = [e for e in entries if not e["hit"]]
        if not unhit:
            continue
        names = comptime_only_names(os.path.join(ROOT, path), unhit)
        for entry in unhit:
            entry["comptime"] = entry["name"] in names

    total = len(manifest)
    runtime_covered = sum(1 for e in manifest if e["hit"])
    compile_time_covered = sum(1 for e in manifest if e.get("comptime") and not e["hit"])
    covered = runtime_covered + compile_time_covered
    pub_total = sum(1 for e in manifest if e["pub"])
    pub_covered = sum(1 for e in manifest if e["pub"] and (e["hit"] or e.get("comptime")))

    print()
    print(f"{'file':22s} {'functions':>9s} {'runtime':>8s} {'comptime':>9s} {'coverage':>9s}   uncovered")
    print("-" * 92)
    for path in sorted(by_file):
        entries = by_file[path]
        n = len(entries)
        rt = sum(1 for e in entries if e["hit"])
        ct = sum(1 for e in entries if e.get("comptime") and not e["hit"])
        unhit = ", ".join(e["name"] for e in entries if not (e["hit"] or e.get("comptime")))
        print(f"{path:22s} {n:9d} {rt:8d} {ct:9d} {100.0 * (rt + ct) / n:8.1f}%   {unhit}")
    print("-" * 92)
    print(
        f"{'total':22s} {total:9d} {runtime_covered:8d} {compile_time_covered:9d} "
        f"{100.0 * covered / total:8.1f}%"
    )
    print(
        f"public API functions   {pub_total:9d} {pub_covered:8d}"
        f"{'':9s} {100.0 * pub_covered / max(pub_total, 1):8.1f}%"
    )

    report = {
        "kind": "function-coverage",
        "note": (
            "Zig 0.18 has no LLVM source-based coverage, so this is function coverage from generated one-shot probes. "
            "Functions whose every reference is in a comptime context are counted as compile-time covered: they are "
            "executed while the test binary is built and cannot fire a runtime probe."
        ),
        "total_functions": total,
        "runtime_covered_functions": runtime_covered,
        "compile_time_covered_functions": compile_time_covered,
        "covered_functions": covered,
        "function_coverage_pct": round(100.0 * covered / total, 2) if total else 0.0,
        "compile_time_only": sorted(e["name"] for e in manifest if e.get("comptime") and not e["hit"]),
        "public_functions": pub_total,
        "covered_public_functions": pub_covered,
        "files": {
            path: {
                "functions": len(entries),
                "runtime_covered": sum(1 for e in entries if e["hit"]),
                "compile_time_covered": sum(
                    1 for e in entries if e.get("comptime") and not e["hit"]
                ),
                "uncovered": [
                    e["name"] for e in entries if not (e["hit"] or e.get("comptime"))
                ],
            }
            for path, entries in sorted(by_file.items())
        },
    }
    out_path = os.path.join(ROOT, args.json)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    print(f"report: {os.path.relpath(out_path, ROOT)}")

    if not args.keep:
        shutil.rmtree(GEN, ignore_errors=True)
    if args.min_functions and report["function_coverage_pct"] < args.min_functions:
        print(f"FAIL: function coverage {report['function_coverage_pct']}% < {args.min_functions}%")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
