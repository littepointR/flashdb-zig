#!/usr/bin/env python3
"""Generate the markdown tables of docs/BENCHMARKS.md from the result JSONs.

Usage:
    python tools/report_tables.py
    python tools/report_tables.py --wg 8 --results bench/results
"""
from __future__ import annotations

import argparse
import json
import os

KV_SCENARIOS = (
    "kv_set_small", "kv_update_1k", "kv_get_hot", "kv_get_miss",
    "kv_delete", "kv_iterate", "kv_mount", "kv_large",
)
TS_SCENARIOS = (
    "tsl_append", "tsl_append_rollover", "tsl_iter_fwd", "tsl_iter_rev",
    "tsl_by_time", "tsl_query_count", "tsl_mount", "tsl_clean",
)


def load(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def weighted(flash: dict) -> int:
    return flash["read_bytes"] + 10 * flash["write_bytes"] + 100 * flash["erase_bytes"]


def scenario_index(doc: dict) -> dict:
    return {s["name"]: s for s in doc["scenarios"]}


def ts_units_per_op(name: str, extra: dict, ops: int) -> float:
    """How many 'units' (entries/queries/mounts/appends) one measured op covers."""
    if name in ("tsl_append", "tsl_append_rollover"):
        return 1.0  # one append == one entry
    if name in ("tsl_iter_fwd", "tsl_iter_rev"):
        entries = extra.get("populated") or extra.get("entries_per_iter") or extra.get("entries") or 1
        return float(entries)
    if name in ("tsl_by_time", "tsl_query_count"):
        return 1.0  # one query
    if name == "tsl_mount":
        return 1.0  # one mount
    if name == "tsl_clean":
        per_cycle = extra.get("appends_per_cycle") or extra.get("entries_after") or 1
        return float(per_cycle)
    return 1.0


def host_table(c: dict, z: dict, wg: int) -> str:
    cs, zs = scenario_index(c), scenario_index(z)
    lines = []
    lines.append(f"#### 写粒度 {wg} bit（C `-O2` vs Zig `ReleaseFast`，7 次运行取最小样本，Flash 计数确定性）")
    lines.append("")
    lines.append("| 场景 | ops | C ns/op | Zig ns/op | 时间比 | C 加权流量 | Zig 加权流量 | 流量比 | 读次数 C/Zig | 写字节 C/Zig | 擦除 C/Zig | 逻辑校验和 |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    total_c = total_z = 0
    total_tc = total_tz = 0
    for name in KV_SCENARIOS:
        sc, sz = cs[name], zs[name]
        cu, zu = weighted(sc["flash"]), weighted(sz["flash"])
        total_c += cu
        total_z += zu
        total_tc += sc["total_ns_median"]
        total_tz += sz["total_ns_median"]
        ok = "一致" if sc["checksum"] == sz["checksum"] else "**不一致**"
        ratio = zu / cu if cu else 1.0
        tr = sz["ns_per_op"] / sc["ns_per_op"] if sc["ns_per_op"] else 1.0
        lines.append(
            f"| `{name}` | {sc['ops']} | {sc['ns_per_op']:.1f} | {sz['ns_per_op']:.1f} | {tr:.2f}× | "
            f"{cu:,} | {zu:,} | {ratio:.2f}× | {sc['flash']['reads']}/{sz['flash']['reads']} | "
            f"{sc['flash']['write_bytes']}/{sz['flash']['write_bytes']} | "
            f"{sc['flash']['erases']}/{sz['flash']['erases']} | {ok} |"
        )
    lines.append(
        f"| **KV 小计** | | | | {total_tz / total_tc:.2f}× | {total_c:,} | {total_z:,} | "
        f"{total_z / total_c:.2f}× | | | | |"
    )
    lines.append("")
    lines.append("TS 场景（新格式更紧凑：同一分区容纳更多条目，所以整库逻辑内容按容量而定；"
                 "Zig 侧用地 `c_ref_prefix_checksum` / `c_ref_checksum` 复算 C 参考数据的前缀/窗口校验和，"
                 "逐项与 C 完全一致；语义对等另由 `bench/diff` 逐行对拍证明）：")
    lines.append("")
    lines.append("| 场景 | C 条目 | Zig 条目 | 单位 | C ns/单位 | Zig ns/单位 | 比值 | Zig 读字节/单位 | C 读字节/单位 | 比值 | C 参照校验和 |")
    lines.append("|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---|")
    for name in TS_SCENARIOS:
        sc, sz = cs[name], zs[name]
        sce, sze = sc.get("extra", {}), sz.get("extra", {})
        ec = sce.get("entries_after", sce.get("populated"))
        ez = sze.get("entries_after", sze.get("populated"))
        uc = ts_units_per_op(name, sce, sc["ops"])
        uz = ts_units_per_op(name, sze, sz["ops"])
        nsu_c = sc["ns_per_op"] / uc
        nsu_z = sz["ns_per_op"] / uz
        rbu_c = sc["flash"]["read_bytes"] / (sc["ops"] * uc)
        rbu_z = sz["flash"]["read_bytes"] / (sz["ops"] * uz)
        tr = nsu_z / nsu_c if nsu_c else 1.0
        unit_name = {"tsl_append": "条目", "tsl_append_rollover": "条目",
                     "tsl_iter_fwd": "条目", "tsl_iter_rev": "条目",
                     "tsl_by_time": "查询", "tsl_query_count": "查询",
                     "tsl_mount": "挂载", "tsl_clean": "追加"}[name]
        ck = "容量相关"
        if sze.get("c_ref_prefix_checksum") is not None:
            ck = "一致（前缀）" if sze["c_ref_prefix_checksum"] == sc["checksum"] else "**不一致**"
        elif sze.get("c_ref_checksum") is not None:
            c_sum = sce.get("sum_matches", sce.get("sum_count", sce.get("sum")))
            same = (sze["c_ref_checksum"] == sc["checksum"] and sze.get("c_ref_sum") == c_sum)
            ck = "一致（窗口）" if same else "**不一致**"
        def fmt(v):
            return "-" if v is None else (f"{v:,}" if isinstance(v, int) else f"{v:.1f}")
        lines.append(
            f"| `{name}` | {fmt(ec)} | {fmt(ez)} | {unit_name} | {nsu_c:.1f} | {nsu_z:.1f} | {tr:.2f}× | "
            f"{rbu_z:.1f} | {rbu_c:.1f} | {(rbu_z / rbu_c if rbu_c else 1.0):.2f}× | {ck} |"
        )
    lines.append("")
    return "\n".join(lines)


def firmware_table(c: dict, z: dict) -> str:
    lines = []
    lines.append("| 指标 | C `-Os` | Zig `ReleaseSmall` | 比值 |")
    lines.append("|---|---:|---:|---:|")
    cp = c["variants"]["plain"]
    zp = z["variants"]["plain"]
    ci = c["variants"].get("instrumented")
    zi = z["variants"].get("instrumented")

    def row(label, cv, zv):
        lines.append(f"| {label} | {cv:,} | {zv:,} | {zv / cv:.2f}× |")

    row(".text", cp["sections"]["text"], zp["sections"]["text"])
    row(".rodata", cp["sections"]["rodata"], zp["sections"]["rodata"])
    row(".data", cp["sections"]["data"], zp["sections"]["data"])
    row("**ROM 合计**", cp["rom"], zp["rom"])
    row(".bss", cp["sections"]["bss"], zp["sections"]["bss"])
    row("**静态 RAM**", cp["static_ram"], zp["static_ram"])
    row("**峰值栈**", cp["stack"], zp["stack"])
    if ci and zi and "cycles" in ci and "cycles" in zi:
        row("**CPU 周期（instrumented）**", ci["cycles"]["total"], zi["cycles"]["total"])
        for key, label in (("mount", "mount"), ("kv", "kv 阶段"), ("ts", "ts 阶段")):
            ck = ci["cycles"].get(key)
            zk = zi["cycles"].get(key)
            if ck is not None and zk is not None:
                row(f"　cycles.{label}", ck, zk)
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="bench/results")
    ap.add_argument("--out", default="build/bench_tables.md")
    args = ap.parse_args()
    res = args.results

    out = []
    for wg in (8, 1):
        c = load(os.path.join(res, f"c_wg{wg}_host.json"))
        z = load(os.path.join(res, f"zig_wg{wg}_host.json"))
        out.append(host_table(c, z, wg))
    cf = os.path.join(res, "c_firmware.json")
    zf = os.path.join(res, "zig_firmware.json")
    if os.path.exists(cf) and os.path.exists(zf):
        out.append("### Cortex-M3 / QEMU 固件（同一工作负载与测量脚手架）\n")
        out.append(firmware_table(load(cf), load(zf)))
    text = "\n".join(out)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text + "\n")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
