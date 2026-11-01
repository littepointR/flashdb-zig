#!/usr/bin/env python3
"""Print a compact table from a benchmark JSON document (C or Zig)."""
import json
import sys


def main(path):
    with open(path) as f:
        doc = json.load(f)
    print(f"{path}: impl={doc.get('impl')} opt={doc.get('opt')} wg={doc.get('write_gran')}")
    fp = doc.get("footprint")
    if fp:
        print("footprint:", json.dumps(fp, sort_keys=True))
    hdr = f"{'scenario':22s} {'ops':>6s} {'ns/op':>10s} {'reads':>7s} {'rb':>9s} {'writes':>7s} {'wb':>8s} {'er':>4s} {'eb':>8s} {'weighted':>12s} {'cs':>10s}"
    print(hdr)
    for s in doc.get("scenarios", []):
        fl = s["flash"]
        weighted = fl["read_bytes"] + 10 * fl["write_bytes"] + 100 * fl["erase_bytes"]
        print(f"{s['name']:22s} {s['ops']:6d} {s['ns_per_op']:10.2f} "
              f"{fl['reads']:7d} {fl['read_bytes']:9d} {fl['writes']:7d} "
              f"{fl['write_bytes']:8d} {fl['erases']:4d} {fl['erase_bytes']:8d} "
              f"{weighted:12d} {s['checksum']:10d}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: bench_summary.py <json> [json...]")
    for p in sys.argv[1:]:
        main(p)
