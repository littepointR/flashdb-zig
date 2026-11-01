#!/usr/bin/env python3
"""Report per-function ARM stack frame sizes from compiled objects.

The firmware comparison measures *peak* stack usage by painting the stack (see
`firmware/common/stack.c`), which tells you how much is used but not why. This
tool attributes the peak to individual functions: it disassembles the objects
with `llvm-objdump` and derives each function's frame from its prologue
(callee-saved registers pushed + immediate `sub sp`). The peak of a call chain is
the sum along the chain, so comparing the GC chains of the C and Zig images
explains the difference.

Usage:
    python tools/stack_frames.py --compile-c      # build the C DB objects first
    python tools/stack_frames.py                  # default objects, top frames
    python tools/stack_frames.py --top 40 --object build/stack/fdb_kvdb.o
    python tools/stack_frames.py --grep kvdb      # filter function names

Only objects for the same firmware build are comparable: `zig_plain.o` comes from
`firmware/zig/build.ps1`, the C objects are rebuilt here with the flags of
`scripts/build_fw_c.ps1` (cortex-m3, -Os, FAL config includes).
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZIG = os.path.join(ROOT, ".tools", "zig", "zig.exe" if os.name == "nt" else "zig")
C_DIR = os.path.join(ROOT, "build", "stack")

C_FLAGS = [
    "-target", "thumb-freestanding-eabi",
    "-mcpu=cortex_m3",
    "-Os",
    "-std=gnu11",
    "-w",
    "-ffunction-sections",
    "-fdata-sections",
    "-fno-common",
    "-fno-builtin",
    "-fno-stack-protector",
    "-ffreestanding",
    "-fno-asynchronous-unwind-tables",
    "-fno-unwind-tables",
    "-DFDB_WRITE_GRAN=8",
    "-I", os.path.join(ROOT, "firmware", "common"),
    "-I", os.path.join(ROOT, "firmware", "c", "include"),
    "-I", os.path.join(ROOT, "reference", "FlashDB", "inc"),
    "-I", os.path.join(ROOT, "reference", "FlashDB", "port", "fal", "inc"),
]


def compile_c() -> list[str]:
    if not os.path.exists(ZIG):
        raise SystemExit(f"pinned zig not found: {ZIG} (run tools/bootstrap.py)")
    os.makedirs(C_DIR, exist_ok=True)
    objects = []
    for name in ("fdb", "fdb_kvdb", "fdb_tsdb", "fdb_utils"):
        src = os.path.join(ROOT, "reference", "FlashDB", "src", name + ".c")
        if not os.path.exists(src):
            raise SystemExit(f"missing {src}; run tools/fetch_reference.py")
        out = os.path.join(C_DIR, name + ".o")
        subprocess.run([ZIG, "cc", *C_FLAGS, "-c", src, "-o", out], check=True, cwd=ROOT)
        objects.append(out)
    print(f"compiled {len(objects)} C objects into {os.path.relpath(C_DIR, ROOT)}")
    return objects


def frames(obj: str) -> dict[str, int]:
    out = subprocess.run(
        ["llvm-objdump", "-d", "--no-show-raw-insn", obj],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    ).stdout
    result: dict[str, int] = {}
    name: str | None = None
    prologue: list[str] = []

    def parse(fn: str, lines: list[str]) -> None:
        pushed = 0
        sub = 0
        for line in lines[:12]:
            if re.search(r"\bpush(\.w)?\b", line):
                m = re.search(r"\{([^}]*)\}", line)
                if m:
                    regs = [r.strip() for r in m.group(1).split(",") if r.strip()]
                    pushed = max(pushed, len(regs) * 4)
            m = re.search(r"\bsub(\.w)?\s+sp,\s*(?:sp,\s*)?#?(0x[0-9a-fA-F]+|\d+)", line)
            if m:
                sub = max(sub, int(m.group(2), 0))
        result[fn] = pushed + sub

    for line in out.splitlines():
        m = re.match(r"\s*[0-9a-f]+ <([^>]+)>:", line)
        if m:
            if name is not None:
                parse(name, prologue)
            name = m.group(1)
            prologue = []
        elif name is not None:
            prologue.append(line)
    if name is not None:
        parse(name, prologue)
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--compile-c", action="store_true", help="(re)build the C database objects with the firmware flags")
    ap.add_argument("--object", action="append", default=None, help="object to inspect (repeatable)")
    ap.add_argument("--top", type=int, default=15, help="how many largest frames to print per object")
    ap.add_argument("--grep", default="", help="only show functions whose name matches this substring")
    args = ap.parse_args()

    objects = args.object
    if objects is None:
        objects = [
            os.path.join(C_DIR, "fdb_kvdb.o"),
            os.path.join(C_DIR, "fdb_tsdb.o"),
            os.path.join(ROOT, "build", "fw", "zig_plain.o"),
        ]
        if args.compile_c or not all(os.path.exists(o) for o in objects):
            objects = compile_c() + [os.path.join(ROOT, "build", "fw", "zig_plain.o")]

    for obj in objects:
        if not os.path.exists(obj):
            print(f"missing object: {obj}", file=sys.stderr)
            continue
        frame_map = frames(obj)
        if args.grep:
            frame_map = {k: v for k, v in frame_map.items() if args.grep in k}
        print(f"\n== {os.path.relpath(obj, ROOT)}: {len(frame_map)} functions ==")
        for fn, size in sorted(frame_map.items(), key=lambda kv: -kv[1])[: args.top]:
            short = fn.replace(".Lkvdb.Kvdb(", "kvdb.Kvdb(").replace(".Ltsdb.Tsdb(", "tsdb.Tsdb(")
            print(f"{size:5d} B  {short}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
