#!/usr/bin/env python3
"""Fetch the upstream FlashDB C sources used only as the differential reference.

The Zig library in `src/` does not depend on the C implementation. The C
sources are needed for:

  * `bench/c/`          the C reference benchmark (host),
  * `bench/diff/`       the C<->Zig behavioural differential harness,
  * `firmware/`         the C firmware baseline for the Cortex-M3 comparison.

They are cloned from <https://github.com/armink/FlashDB> at the exact commit
recorded in `toolchain.lock.json` into `reference/FlashDB/` (git-ignored — the
upstream tree is never modified by this project).

Usage:
    python tools/fetch_reference.py           # fetch if missing
    python tools/fetch_reference.py --force   # re-fetch from scratch
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK = os.path.join(ROOT, "toolchain.lock.json")
DEST = os.path.join(ROOT, "reference", "FlashDB")
# Upstream directories that are not needed for the comparison harness
# (the board demos and the Zephyr module are several MB of vendor code).
PRUNE = ("demos", "zephyr", "docs", ".github")


def load_lock() -> dict:
    with open(LOCK, encoding="utf-8") as f:
        return json.load(f)


def run(args: list[str], cwd: str | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true", help="delete and re-fetch the reference tree")
    args = ap.parse_args()

    ref = load_lock()["reference"]
    url, commit = ref["url"], ref["commit"]
    if not shutil.which("git"):
        raise SystemExit("git is required to fetch the reference sources")

    if args.force and os.path.isdir(DEST):
        shutil.rmtree(DEST)
    if os.path.isfile(os.path.join(DEST, "inc", "fdb_def.h")):
        print(f"reference sources already present at {DEST} (commit {commit})")
        return 0

    os.makedirs(DEST, exist_ok=True)
    print(f"fetching {url} @ {commit}")
    run(["git", "init", "-q"], cwd=DEST)
    run(["git", "remote", "add", "origin", url], cwd=DEST)
    run(["git", "fetch", "-q", "--depth", "1", "origin", commit], cwd=DEST)
    run(["git", "checkout", "-q", "--detach", "FETCH_HEAD"], cwd=DEST)

    for name in PRUNE:
        path = os.path.join(DEST, name)
        if os.path.isdir(path):
            shutil.rmtree(path)
    # Keep the tree but drop the VCS metadata: it is a read-only vendored snapshot.
    shutil.rmtree(os.path.join(DEST, ".git"), ignore_errors=True)

    required = [
        os.path.join("inc", "fdb_def.h"),
        os.path.join("src", "fdb_kvdb.c"),
        os.path.join("src", "fdb_tsdb.c"),
        os.path.join("port", "fal", "src", "fal.c"),
    ]
    missing = [p for p in required if not os.path.isfile(os.path.join(DEST, p))]
    if missing:
        raise SystemExit(f"reference checkout is incomplete, missing: {', '.join(missing)}")
    print(f"reference FlashDB {ref['version']} ready at {DEST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
