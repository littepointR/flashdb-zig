//! C<->Zig behavioural differential harness -- Zig side.
//!
//! Runs the deterministic KV operation script defined in bench/diff/README.md
//! on the Zig FlashDB implementation and prints the canonical DIFF output.
//! The C side (bench/diff/c/diff_bench.c) runs the same script on the C
//! reference; tools/diff_model.py diffs the two outputs.
//!
//! The script consumes one LCG so every op and value is deterministic.  The
//! main-script section must match the C output line for line; the crash section
//! deliberately depends on the on-flash format (the Zig format is new), so the
//! comparison tool validates the allowed post-crash outcome sets and reports
//! legitimate divergences instead of failing on them.

const std = @import("std");
const flashdb = @import("flashdb");

const Flash = flashdb.sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });
const Db = flashdb.Kvdb(Flash, .{ .sector_size = 4096, .sector_count = 4 });

// ---- protocol constants (must match bench/diff/c/diff_bench.c) ------------
const DIFF_VERSION: u32 = 1;
const LCG_SEED: u32 = 0xC0FFEE; // 12648430
const SCRIPT_OPS: u32 = 2000;
const CHECKPOINT_EVERY: u32 = 250;
const KEY_COUNT: u32 = 48;
const MISS_COUNT: u32 = 16;
const MAX_VALUE_LEN: u32 = 120;
const IO_BUF_LEN: usize = 128;
const MAX_ENTRIES: u32 = 64;
const DEFAULT_COUNT: u32 = 4;
const CRASH_WATCH_KEYS: u32 = 8;
const CRASH_CUT_LIMIT: u32 = 64;

const FNV_OFFSET: u32 = 0x811C9DC5;
const FNV_PRIME: u32 = 0x01000193;

// ---- state -----------------------------------------------------------------
var g_mem: [16 * 1024]u8 = undefined;
var g_db: Db = undefined;
var g_state: u32 = LCG_SEED;
var g_gen: [KEY_COUNT]u32 = @splat(0);
var g_roll: u32 = FNV_OFFSET;
var g_def_vals: [DEFAULT_COUNT][16]u8 = undefined;

const g_def_keys = [_][]const u8{ "d00", "d01", "d02", "d03" };

const Entry = struct {
    key: [80]u8 = undefined,
    klen: u32 = 0,
    vlen: u32 = 0,
    vfnv: u32 = 0,
};

var g_entries: [MAX_ENTRIES]Entry = undefined;

// Crash-phase expectations for the watched keys.
var g_crash_old_fnv: [CRASH_WATCH_KEYS]u32 = @splat(0);
var g_crash_old_val: [CRASH_WATCH_KEYS][16]u8 = @splat(@as([16]u8, @splat(0)));

// Buffered stdout writer.
var g_out_buf: [8192]u8 = undefined;
var g_fw: std.Io.File.Writer = undefined;
var g_out: *std.Io.Writer = undefined;

// ---- helpers ---------------------------------------------------------------

fn fatal(what: []const u8) noreturn {
    std.debug.print("diff_zig: FATAL: {s}\n", .{what});
    std.process.exit(3);
}

fn emit(comptime fmt: []const u8, args: anytype) void {
    g_out.print(fmt, args) catch fatal("stdout write failed");
}

fn lcgNext() u32 {
    // state = (state * 1103515245 + 12345) mod 2^31
    const s64: u64 = @as(u64, g_state) * 1103515245 + 12345;
    g_state = @intCast(s64 & 0x7FFF_FFFF);
    return g_state;
}

fn fnvBytes(h0: u32, data: []const u8) u32 {
    var h = h0;
    for (data) |b| {
        h ^= b;
        h *%= FNV_PRIME;
    }
    return h;
}

fn fnvU32(h0: u32, v: u32) u32 {
    var b: [4]u8 = undefined;
    b[0] = @truncate(v & 0xFF);
    b[1] = @truncate((v >> 8) & 0xFF);
    b[2] = @truncate((v >> 16) & 0xFF);
    b[3] = @truncate((v >> 24) & 0xFF);
    return fnvBytes(h0, &b);
}

/// kv_value(key_idx, gen, len)[j] = 0x5A + key_idx*31 + gen*17 + j*7 (mod 256)
fn makeValue(buf: []u8, key_idx: u32, gen: u32) void {
    for (buf, 0..) |*b, j| {
        b.* = @truncate(0x5A + key_idx * 31 + gen * 17 + @as(u32, @intCast(j)) * 7);
    }
}

fn keyName(out: *[8]u8, idx: u32) []const u8 {
    out[0] = 'k';
    out[1] = '0' + @as(u8, @intCast((idx / 10) % 10));
    out[2] = '0' + @as(u8, @intCast(idx % 10));
    out[3] = 0;
    return out[0..3];
}

fn missName(out: *[8]u8, idx: u32) []const u8 {
    out[0] = 'm';
    out[1] = '0' + @as(u8, @intCast((idx / 10) % 10));
    out[2] = '0' + @as(u8, @intCast(idx % 10));
    out[3] = 0;
    return out[0..3];
}

fn dbMount() void {
    g_db.mount(Flash.init(&g_mem)) catch fatal("kvdb mount failed");
}

fn dbRemount() void {
    dbMount();
}

/// Read the current value of `key`; returns the number of bytes copied (0 when
/// the key is absent).  Values in the script are always 1..120 bytes.
fn kvGetValue(key: []const u8, buf: []u8) usize {
    const got = g_db.get(key, buf) catch fatal("kv get failed");
    if (got) |n| return n;
    return 0;
}

fn collectAndDigest(out_count: *u32) u32 {
    var it = g_db.iterator();
    var n: u32 = 0;
    var h: u32 = FNV_OFFSET;

    while (true) {
        const entry_opt = it.next() catch fatal("kv iterator failed");
        const e = entry_opt orelse break;
        if (n >= MAX_ENTRIES) fatal("too many entries for the canonical dump");
        if (e.value_len > IO_BUF_LEN or e.name_len >= g_entries[0].key.len) {
            fatal("entry does not fit the canonical buffers");
        }
        var buf: [IO_BUF_LEN]u8 = undefined;
        const got = it.readValue(&buf, e) catch fatal("iterator value read failed");
        if (got != e.value_len) fatal("iterator value read length mismatch");
        @memcpy(g_entries[n].key[0..e.name_len], e.name);
        g_entries[n].key[e.name_len] = 0;
        g_entries[n].klen = e.name_len;
        g_entries[n].vlen = e.value_len;
        g_entries[n].vfnv = fnvBytes(FNV_OFFSET, buf[0..got]);
        n += 1;
    }

    // Sort by key bytes (same insertion sort / tie-break as the C side).
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var j: u32 = i + 1;
        while (j < n) : (j += 1) {
            const min_len = @min(g_entries[i].klen, g_entries[j].klen);
            const ord = std.mem.order(u8, g_entries[i].key[0..min_len], g_entries[j].key[0..min_len]);
            const swap = ord == .gt or (ord == .eq and g_entries[i].klen > g_entries[j].klen);
            if (swap) {
                const tmp = g_entries[i];
                g_entries[i] = g_entries[j];
                g_entries[j] = tmp;
            }
        }
    }

    i = 0;
    while (i < n) : (i += 1) {
        h = fnvU32(h, g_entries[i].klen);
        h = fnvBytes(h, g_entries[i].key[0..g_entries[i].klen]);
        h = fnvU32(h, g_entries[i].vlen);
        h = fnvU32(h, g_entries[i].vfnv);
    }
    out_count.* = n;
    return h;
}

fn printState(tag: []const u8, out_count: *u32, out_digest: *u32) void {
    const h = collectAndDigest(out_count);
    out_digest.* = h;
    emit("{s}STATE count={d} dump_fnv=0x{x:0>8}\n", .{ tag, out_count.*, h });
    var i: u32 = 0;
    while (i < out_count.*) : (i += 1) {
        emit("{s}ENTRY key={s} klen={d} vlen={d} vfnv=0x{x:0>8}\n", .{
            tag,
            g_entries[i].key[0..g_entries[i].klen],
            g_entries[i].klen,
            g_entries[i].vlen,
            g_entries[i].vfnv,
        });
    }
}

// ---- operations ------------------------------------------------------------

fn opSet(idx: u32) void {
    var key_buf: [8]u8 = undefined;
    var val: [MAX_VALUE_LEN]u8 = undefined;
    const key_idx = lcgNext() % KEY_COUNT;
    const len = 1 + lcgNext() % MAX_VALUE_LEN;

    g_gen[key_idx] += 1;
    makeValue(val[0..len], key_idx, g_gen[key_idx]);
    const key = keyName(&key_buf, key_idx);
    g_db.set(key, val[0..len]) catch fatal("kv set failed");
    emit("OP idx={d} kind=set key={s} len={d} vfnv=0x{x:0>8}\n", .{
        idx, key, len, fnvBytes(FNV_OFFSET, val[0..len]),
    });
}

fn opDelete(idx: u32) void {
    var key_buf: [8]u8 = undefined;
    var buf: [IO_BUF_LEN]u8 = undefined;
    const key_idx = lcgNext() % KEY_COUNT;
    const key = keyName(&key_buf, key_idx);
    const existed: u32 = if (kvGetValue(key, &buf) > 0) 1 else 0;

    _ = g_db.delete(key) catch blk: {
        if (existed != 0) fatal("kv delete of an existing key failed");
        break :blk false;
    };
    emit("OP idx={d} kind=del key={s} existed={d}\n", .{ idx, key, existed });
}

fn opGet(idx: u32) void {
    var key_buf: [8]u8 = undefined;
    var buf: [IO_BUF_LEN]u8 = undefined;
    const key_idx = lcgNext() % KEY_COUNT;
    const key = keyName(&key_buf, key_idx);
    const got = kvGetValue(key, &buf);

    if (got > 0) g_roll = fnvBytes(g_roll, buf[0..got]);
    emit("OP idx={d} kind=get key={s} hit={d} len={d} vfnv=0x{x:0>8}\n", .{
        idx, key, @intFromBool(got > 0), got,
        if (got > 0) fnvBytes(FNV_OFFSET, buf[0..got]) else @as(u32, 0),
    });
}

fn opGetMiss(idx: u32) void {
    var key_buf: [8]u8 = undefined;
    var buf: [IO_BUF_LEN]u8 = undefined;
    const miss_idx = lcgNext() % MISS_COUNT;
    const key = missName(&key_buf, miss_idx);
    const got = kvGetValue(key, &buf);

    if (got != 0) fatal("get of an absent key returned data");
    emit("OP idx={d} kind=getmiss key={s} hit=0\n", .{ idx, key });
}

fn opIterate(idx: u32) void {
    var n: u32 = 0;
    const h = collectAndDigest(&n);

    g_roll = fnvU32(fnvU32(g_roll, n), h);
    emit("OP idx={d} kind=iter count={d} digest=0x{x:0>8}\n", .{ idx, n, h });
}

fn opRemount(idx: u32) void {
    dbRemount();
    var n: u32 = 0;
    const h = collectAndDigest(&n);

    g_roll = fnvU32(fnvU32(g_roll, n), h);
    emit("OP idx={d} kind=remount count={d} digest=0x{x:0>8}\n", .{ idx, n, h });
}

fn opDefaults(idx: u32) void {
    g_db.formatAll() catch fatal("formatAll failed");
    var i: u32 = 0;
    while (i < DEFAULT_COUNT) : (i += 1) {
        g_db.set(g_def_keys[i], &g_def_vals[i]) catch fatal("default set failed");
    }
    var n: u32 = 0;
    const h = collectAndDigest(&n);

    g_roll = fnvU32(fnvU32(g_roll, n), h);
    emit("OP idx={d} kind=defaults count={d} digest=0x{x:0>8}\n", .{ idx, n, h });
}

fn runScript() void {
    var idx: u32 = 0;
    while (idx < SCRIPT_OPS) : (idx += 1) {
        g_state = lcgNext();
        const bucket = g_state % 100;
        if (bucket < 55) {
            opSet(idx);
        } else if (bucket < 70) {
            opDelete(idx);
        } else if (bucket < 80) {
            opGet(idx);
        } else if (bucket < 85) {
            opIterate(idx);
        } else if (bucket < 90) {
            opRemount(idx);
        } else if (bucket < 95) {
            opGetMiss(idx);
        } else {
            opDefaults(idx);
        }

        if ((idx + 1) % CHECKPOINT_EVERY == 0) {
            var n: u32 = 0;
            const h = collectAndDigest(&n);
            emit("CHECKPOINT idx={d} count={d} digest=0x{x:0>8} roll=0x{x:0>8}\n", .{
                idx + 1, n, h, g_roll,
            });
        }
    }
}

// ---- crash-recovery comparison --------------------------------------------

fn crashFillExpectations() void {
    var val: [16]u8 = undefined;
    var i: u32 = 0;
    while (i < CRASH_WATCH_KEYS) : (i += 1) {
        makeValue(&val, i, 0);
        @memcpy(&g_crash_old_val[i], &val);
        g_crash_old_fnv[i] = fnvBytes(FNV_OFFSET, &val);
    }
}

fn crashResetBase() void {
    @memset(&g_mem, 0xFF);
    dbMount(); // blank partition -> formats

    var i: u32 = 0;
    while (i < CRASH_WATCH_KEYS) : (i += 1) {
        var key_buf: [8]u8 = undefined;
        const key = keyName(&key_buf, i);
        g_db.set(key, &g_crash_old_val[i]) catch fatal("crash base: set failed");
    }
    dbMount();
}

fn crashKeyState(key_idx: u32, new_fnv: u32, new_is_set_phase: bool) []const u8 {
    var key_buf: [8]u8 = undefined;
    var buf: [IO_BUF_LEN]u8 = undefined;
    const key = keyName(&key_buf, key_idx);
    const got = kvGetValue(key, &buf);

    if (got == 0) return "absent";
    if (got != 16 and !(new_is_set_phase and key_idx == 3 and got == 24)) return "other";
    if (got == 16 and fnvBytes(FNV_OFFSET, buf[0..got]) == g_crash_old_fnv[key_idx]) return "old";
    if (new_is_set_phase and key_idx == 3 and got == 24 and
        fnvBytes(FNV_OFFSET, buf[0..got]) == new_fnv) return "new";
    return "other";
}

fn crashDump(phase: []const u8, cut: u32, outcome: []const u8, new_fnv: u32, new_is_set_phase: bool) void {
    const check_ok: u32 = blk: {
        g_db.check() catch break :blk 0;
        break :blk 1;
    };
    var n: u32 = 0;
    const h = collectAndDigest(&n);

    emit("CRASH phase={s} cut={d} outcome={s} check={d} count={d} dump_fnv=0x{x:0>8} states=", .{
        phase, cut, outcome, check_ok, n, h,
    });
    var i: u32 = 0;
    while (i < CRASH_WATCH_KEYS) : (i += 1) {
        if (i > 0) emit(",", .{});
        emit("k{x:0>2}={s}", .{ i, crashKeyState(i, new_fnv, new_is_set_phase) });
    }
    emit("\n", .{});
}

fn crashPhaseSet() void {
    var newv: [24]u8 = undefined;
    makeValue(&newv, 3, 77);
    const new_fnv = fnvBytes(FNV_OFFSET, &newv);
    emit("CRASH-BEGIN phase=set target=k03 old_fnv=0x{x:0>8} new_fnv=0x{x:0>8}\n", .{
        g_crash_old_fnv[3], new_fnv,
    });

    var cut: u32 = 0;
    while (cut < CRASH_CUT_LIMIT) : (cut += 1) {
        crashResetBase();
        g_db.dev.flash.armFault(cut);
        var ok = true;
        g_db.set("k03", &newv) catch {
            ok = false;
        };
        g_db.dev.flash.clearFault();
        dbRemount();
        crashDump("set", cut, if (ok) "ok" else "fault", new_fnv, true);
        if (ok) break;
    }
    if (cut == CRASH_CUT_LIMIT) fatal("crash phase set never completed");
    emit("CRASH-END phase=set cuts={d}\n", .{cut + 1});
}

fn crashPhaseDelete() void {
    emit("CRASH-BEGIN phase=del target=k01 old_fnv=0x{x:0>8} new_fnv=0x00000000\n", .{
        g_crash_old_fnv[1],
    });

    var cut: u32 = 0;
    while (cut < CRASH_CUT_LIMIT) : (cut += 1) {
        crashResetBase();
        g_db.dev.flash.armFault(cut);
        var ok = true;
        _ = g_db.delete("k01") catch {
            ok = false;
        };
        g_db.dev.flash.clearFault();
        dbRemount();
        crashDump("del", cut, if (ok) "ok" else "fault", 0, false);
        if (ok) break;
    }
    if (cut == CRASH_CUT_LIMIT) fatal("crash phase del never completed");
    emit("CRASH-END phase=del cuts={d}\n", .{cut + 1});
}

// ---- TSDB differential (v2) -------------------------------------------------

const Ts = flashdb.Tsdb(Flash, .{
    .sector_size = 4096,
    .sector_count = 4,
    .ts_bits = 32,
    .max_len = 64,
});

const TS_SEED: u32 = 0x33557711;
const TS_OPS: u32 = 1000;
const TS_CHECKPOINT_EVERY: u32 = 250;
const TS_APPEND_LIMIT: u32 = 40;
const TS_REPOPULATE: u32 = 24;
const TS_MAX_LEN: u32 = 64;
const TS_BASE_TIME: i32 = 1000;
const TS_ENTRIES_MAX: u32 = 128;
const TS_CRASH_WATCH: u32 = 8;
const TS_CRASH_CUT_LIMIT: u32 = 64;
const TS_QUERY_COUNT: u32 = 8;

const TsEntry = struct {
    time: i32,
    status: u32,
    len: u32,
    pfnv: u32,
};

var g_ts_mem: [16 * 1024]u8 = undefined;
var g_tsdb: Ts = undefined;
var g_ts_state: u32 = TS_SEED;
var g_ts_seq: i32 = 0;
var g_ts_appended: u32 = 0;
var g_ts_roll: u32 = FNV_OFFSET;
var g_ts_payload: [TS_MAX_LEN]u8 = undefined;
var g_ts_entries: [TS_ENTRIES_MAX]TsEntry = undefined;
var g_ts_entry_count: u32 = 0;

// Fixed ranges for the final TS-QUERY section; the sixth range is reversed
// (from > to) to exercise the reverse-range semantics.
const g_ts_ranges = [_][2]i32{
    .{ 1000, 1100 }, .{ 1050, 1150 }, .{ 0, 1000 }, .{ 1200, 1400 },
    .{ 1000, 1000 }, .{ 1100, 1000 }, .{ 0, 4000 }, .{ 1500, 1600 },
};

fn tsLcgNext() u32 {
    const s64: u64 = @as(u64, g_ts_state) * 1103515245 + 12345;
    g_ts_state = @intCast(s64 & 0x7FFF_FFFF);
    return g_ts_state;
}

/// ts_payload(seq)[j] = 0x3C + seq*13 + j*5 (mod 256)
fn tsMakePayload(buf: []u8, seq: u32) void {
    for (buf, 0..) |*b, j| {
        b.* = @truncate(0x3C + seq * 13 + @as(u32, @intCast(j)) * 5);
    }
}

fn tsMount() void {
    g_tsdb.mount(Flash.init(&g_ts_mem)) catch fatal("tsdb mount failed");
}

fn tsRemount() void {
    tsMount();
}

fn tsLastTime() i32 {
    return g_tsdb.lastTime();
}

fn tsSerializeEntry(h0: u32, e: *const TsEntry) u32 {
    var h = h0;
    h = fnvU32(h, @bitCast(e.time));
    h = fnvU32(h, e.status);
    h = fnvU32(h, e.len);
    h = fnvU32(h, e.pfnv);
    return h;
}

fn tsWalkForward(out_count: *u32, out_last: *i32) u32 {
    var it = g_tsdb.iterator();
    var n: u32 = 0;
    var h: u32 = FNV_OFFSET;

    while (true) {
        const entry_opt = it.next() catch fatal("ts iterator failed");
        const e = entry_opt orelse break;
        if (n >= TS_ENTRIES_MAX) fatal("too many TS entries for the canonical dump");
        var buf: [TS_MAX_LEN]u8 = undefined;
        const got = it.readPayload(&buf, e) catch fatal("ts readPayload failed");
        if (got != e.len) fatal("ts payload length mismatch");
        g_ts_entries[n] = .{
            .time = e.time,
            .status = @intFromEnum(e.status),
            .len = got,
            .pfnv = fnvBytes(FNV_OFFSET, buf[0..got]),
        };
        h = tsSerializeEntry(h, &g_ts_entries[n]);
        n += 1;
    }
    g_ts_entry_count = n;
    out_count.* = n;
    out_last.* = g_tsdb.lastTime();
    return h;
}

fn tsWalkByTime(from: i32, to: i32, out_count: *u32) u32 {
    var it = g_tsdb.iteratorByTime(from, to);
    var n: u32 = 0;
    var h: u32 = FNV_OFFSET;

    while (true) {
        const entry_opt = it.next() catch fatal("ts by-time iterator failed");
        const e = entry_opt orelse break;
        if (n >= TS_ENTRIES_MAX) fatal("too many TS entries for the canonical dump");
        var buf: [TS_MAX_LEN]u8 = undefined;
        const got = it.readPayload(&buf, e) catch fatal("ts readPayload failed");
        if (got != e.len) fatal("ts payload length mismatch");
        g_ts_entries[n] = .{
            .time = e.time,
            .status = @intFromEnum(e.status),
            .len = got,
            .pfnv = fnvBytes(FNV_OFFSET, buf[0..got]),
        };
        h = tsSerializeEntry(h, &g_ts_entries[n]);
        n += 1;
    }
    g_ts_entry_count = n;
    out_count.* = n;
    return h;
}

// ---- TS operations ---------------------------------------------------------

fn tsOpAppend(idx: u32) void {
    const len = tsLcgNext() % (TS_MAX_LEN + 1);
    g_ts_seq += 1;
    const t = TS_BASE_TIME + g_ts_seq;
    tsMakePayload(g_ts_payload[0..len], @intCast(g_ts_seq));
    const pfnv = fnvBytes(FNV_OFFSET, g_ts_payload[0..len]);
    g_tsdb.append(t, g_ts_payload[0..len]) catch fatal("ts append failed");
    g_ts_appended += 1;
    emit("TS-OP idx={d} kind=append time={d} len={d} pfnv=0x{x:0>8}\n", .{
        idx, t, len, pfnv,
    });
}

fn tsOpIter(idx: u32) void {
    var n: u32 = 0;
    var last: i32 = 0;
    const h = tsWalkForward(&n, &last);

    g_ts_roll = fnvU32(fnvU32(g_ts_roll, n), h);
    emit("TS-OP idx={d} kind=iter count={d} last_time={d} digest=0x{x:0>8}\n", .{
        idx, n, last, h,
    });
}

fn tsOpRemount(idx: u32) void {
    tsRemount();
    var n: u32 = 0;
    var last: i32 = 0;
    const h = tsWalkForward(&n, &last);

    g_ts_roll = fnvU32(fnvU32(g_ts_roll, n), h);
    emit("TS-OP idx={d} kind=remount count={d} last_time={d} digest=0x{x:0>8}\n", .{
        idx, n, last, h,
    });
}

fn tsOpByTime(idx: u32) void {
    const off = tsLcgNext() % 400;
    const span = tsLcgNext() % 200;
    const from: i32 = TS_BASE_TIME + @as(i32, @intCast(off));
    const to: i32 = from + @as(i32, @intCast(span));
    var n: u32 = 0;
    const h = tsWalkByTime(from, to, &n);

    g_ts_roll = fnvU32(fnvU32(g_ts_roll, n), h);
    emit("TS-OP idx={d} kind=bytime from={d} to={d} count={d} digest=0x{x:0>8}\n", .{
        idx, from, to, n, h,
    });
}

fn tsOpQueryCount(idx: u32) void {
    const off = tsLcgNext() % 400;
    const span = tsLcgNext() % 200;
    const from: i32 = TS_BASE_TIME + @as(i32, @intCast(off));
    const to: i32 = from + @as(i32, @intCast(span));
    const n = g_tsdb.queryCount(from, to, .write) catch fatal("ts queryCount failed");

    emit("TS-OP idx={d} kind=querycount from={d} to={d} count={d}\n", .{
        idx, from, to, n,
    });
}

fn tsOpClean(idx: u32) void {
    g_tsdb.clean() catch fatal("ts clean failed");
    g_ts_appended = 0;
    var i: u32 = 0;
    while (i < TS_REPOPULATE) : (i += 1) {
        g_ts_seq += 1;
        tsMakePayload(g_ts_payload[0..16], @intCast(g_ts_seq));
        const t = TS_BASE_TIME + g_ts_seq;
        g_tsdb.append(t, g_ts_payload[0..16]) catch fatal("ts repopulate append failed");
        g_ts_appended += 1;
    }
    var n: u32 = 0;
    var last: i32 = 0;
    const h = tsWalkForward(&n, &last);

    g_ts_roll = fnvU32(fnvU32(g_ts_roll, n), h);
    emit("TS-OP idx={d} kind=clean_repopulate count={d} last_time={d} digest=0x{x:0>8}\n", .{
        idx, n, last, h,
    });
}

fn tsRunScript() void {
    var idx: u32 = 0;
    while (idx < TS_OPS) : (idx += 1) {
        g_ts_state = tsLcgNext();
        const bucket = g_ts_state % 100;
        if (bucket < 70) {
            if (g_ts_appended < TS_APPEND_LIMIT) {
                tsOpAppend(idx);
            } else {
                tsOpIter(idx);
            }
        } else if (bucket < 80) {
            tsOpRemount(idx);
        } else if (bucket < 90) {
            tsOpByTime(idx);
        } else if (bucket < 95) {
            tsOpQueryCount(idx);
        } else {
            tsOpClean(idx);
        }

        if ((idx + 1) % TS_CHECKPOINT_EVERY == 0) {
            var n: u32 = 0;
            var last: i32 = 0;
            const h = tsWalkForward(&n, &last);
            emit("TS-CHECKPOINT idx={d} count={d} last_time={d} dump_fnv=0x{x:0>8} roll=0x{x:0>8}\n", .{
                idx + 1, n, last, h, g_ts_roll,
            });
        }
    }
}

fn tsPrintState() void {
    var n: u32 = 0;
    var last: i32 = 0;
    const h = tsWalkForward(&n, &last);

    emit("TS-STATE count={d} last_time={d} dump_fnv=0x{x:0>8}\n", .{ n, last, h });
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        emit("TS-ENTRY time={d} status={d} len={d} pfnv=0x{x:0>8}\n", .{
            g_ts_entries[i].time, g_ts_entries[i].status,
            g_ts_entries[i].len, g_ts_entries[i].pfnv,
        });
    }
    i = 0;
    while (i < TS_QUERY_COUNT) : (i += 1) {
        const from = g_ts_ranges[i][0];
        const to = g_ts_ranges[i][1];
        const cnt = g_tsdb.queryCount(from, to, .write) catch fatal("ts queryCount failed");
        emit("TS-QUERY from={d} to={d} count={d}\n", .{ from, to, cnt });
    }
    emit("TS-ROLL value=0x{x:0>8}\n", .{g_ts_roll});
    emit("TS-SUMMARY ops={d} count={d} last_time={d} dump_fnv=0x{x:0>8} roll=0x{x:0>8} rc=0\n", .{
        TS_OPS, n, last, h, g_ts_roll,
    });
}

// ---- TS crash recovery -----------------------------------------------------

var g_ts_base_entries: [TS_CRASH_WATCH]TsEntry = undefined;
var g_ts_base_dump: u32 = 0;
var g_ts_new_dump: u32 = 0;

fn tsCrashFillExpectations() void {
    var h: u32 = FNV_OFFSET;
    var i: u32 = 0;
    while (i < TS_CRASH_WATCH) : (i += 1) {
        const t: i32 = TS_BASE_TIME + @as(i32, @intCast(i));
        tsMakePayload(g_ts_payload[0..16], i);
        g_ts_base_entries[i] = .{
            .time = t,
            .status = @intFromEnum(Ts.Status.write),
            .len = 16,
            .pfnv = fnvBytes(FNV_OFFSET, g_ts_payload[0..16]),
        };
        h = tsSerializeEntry(h, &g_ts_base_entries[i]);
    }
    g_ts_base_dump = h;

    tsMakePayload(g_ts_payload[0..24], 77);
    const ne = TsEntry{
        .time = 1100,
        .status = @intFromEnum(Ts.Status.write),
        .len = 24,
        .pfnv = fnvBytes(FNV_OFFSET, g_ts_payload[0..24]),
    };
    g_ts_new_dump = tsSerializeEntry(h, &ne);
}

fn tsCrashResetBase() void {
    @memset(&g_ts_mem, 0xFF);
    tsMount();
    var i: u32 = 0;
    while (i < TS_CRASH_WATCH) : (i += 1) {
        tsMakePayload(g_ts_payload[0..16], i);
        const t: i32 = TS_BASE_TIME + @as(i32, @intCast(i));
        g_tsdb.append(t, g_ts_payload[0..16]) catch fatal("ts crash base append failed");
    }
    tsMount();
}

fn tsCrashBaseMask() u32 {
    var mask: u32 = 0;
    var i: u32 = 0;
    while (i < TS_CRASH_WATCH) : (i += 1) {
        const t: i32 = TS_BASE_TIME + @as(i32, @intCast(i));
        const n = g_tsdb.queryCount(t, t, .write) catch fatal("ts crash queryCount failed");
        if (n > 0) mask |= @as(u32, 1) << @intCast(i);
    }
    return mask;
}

fn tsCrashPhase() void {
    var newp: [24]u8 = undefined;
    tsMakePayload(&newp, 77);
    emit("TS-CRASH-BEGIN base_dump=0x{x:0>8} new_dump=0x{x:0>8}\n", .{
        g_ts_base_dump, g_ts_new_dump,
    });

    var cut: u32 = 0;
    while (cut < TS_CRASH_CUT_LIMIT) : (cut += 1) {
        tsCrashResetBase();
        g_tsdb.dev.flash.armFault(cut);
        var ok = true;
        g_tsdb.append(1100, &newp) catch {
            ok = false;
        };
        g_tsdb.dev.flash.clearFault();
        tsRemount();
        const mask = tsCrashBaseMask();
        const new_n = g_tsdb.queryCount(1100, 1100, .write) catch fatal("ts crash queryCount failed");
        const new_present: u32 = if (new_n > 0) 1 else 0;
        var last: i32 = g_tsdb.lastTime();
        var h: u32 = 0;
        if (ok) {
            var n: u32 = 0;
            h = tsWalkForward(&n, &last);
        }
        emit("TS-CRASH cut={d} outcome={s} last_time={d} base_mask=0x{x:0>2} " ++
            "new_present={d} dump_fnv=0x{x:0>8}\n", .{
            cut, if (ok) "ok" else "fault", last, mask, new_present, h,
        });
        if (ok) break;
    }
    if (cut == TS_CRASH_CUT_LIMIT) fatal("TS crash phase never completed");
    emit("TS-CRASH-END cuts={d}\n", .{cut + 1});
}

// ---- entry point -----------------------------------------------------------

pub fn main() !void {
    const io = std.Options.debug_io;
    g_fw = std.Io.File.stdout().writer(io, &g_out_buf);
    g_out = &g_fw.interface;

    // Erased NOR: the first mount formats the database.
    @memset(&g_mem, 0xFF);

    var i: u32 = 0;
    while (i < DEFAULT_COUNT) : (i += 1) {
        var j: u32 = 0;
        while (j < 16) : (j += 1) {
            g_def_vals[i][j] = @truncate(0xD0 + i * 3 + j);
        }
    }

    g_state = LCG_SEED;
    g_roll = FNV_OFFSET;
    g_gen = @splat(0);

    dbMount();

    emit("DIFF version={d} impl=zig\n", .{DIFF_VERSION});
    emit("CONFIG wg=8 kv_part=16384 sector=4096 sectors=4 keys={d} " ++
        "miss_keys={d} max_value={d} seed={d} ops={d} checkpoint={d} crash_watch={d}\n", .{
        KEY_COUNT, MISS_COUNT, MAX_VALUE_LEN, LCG_SEED, SCRIPT_OPS,
        CHECKPOINT_EVERY, CRASH_WATCH_KEYS,
    });

    runScript();

    var count: u32 = 0;
    var digest: u32 = 0;
    printState("", &count, &digest);
    emit("CHECK ok=1\n", .{});
    emit("ROLL value=0x{x:0>8}\n", .{g_roll});
    emit("SUMMARY ops={d} count={d} dump_fnv=0x{x:0>8} roll=0x{x:0>8} rc=0\n", .{
        SCRIPT_OPS, count, digest, g_roll,
    });

    crashFillExpectations();
    crashPhaseSet();
    crashPhaseDelete();

    // ---- TSDB differential (v2) -----------------------------------------
    @memset(&g_ts_mem, 0xFF);
    g_ts_state = TS_SEED;
    g_ts_seq = 0;
    g_ts_appended = 0;
    g_ts_roll = FNV_OFFSET;
    g_ts_entry_count = 0;
    tsMount(); // blank TS partition -> format

    emit("TS-DIFF version={d} impl=zig\n", .{DIFF_VERSION});
    emit("TS-CONFIG max_len={d} base_time={d} ops={d} checkpoint={d} " ++
        "append_limit={d} repopulate={d} seed={d} query_count={d}\n", .{
        TS_MAX_LEN, TS_BASE_TIME, TS_OPS, TS_CHECKPOINT_EVERY,
        TS_APPEND_LIMIT, TS_REPOPULATE, TS_SEED, TS_QUERY_COUNT,
    });

    tsRunScript();
    tsPrintState();

    tsCrashFillExpectations();
    tsCrashPhase();

    try g_fw.flush();
}
