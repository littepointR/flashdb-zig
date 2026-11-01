//! Host benchmark driver for the Zig rewrite of FlashDB.
//!
//! This is the Zig side of the measurement protocol in `bench/SCENARIOS.md` and
//! the C reference harness in `bench/c/`: identical flash geometry (one 32 KiB
//! RAM NOR device, two 16 KiB / 4 x 4096-byte partitions), identical workload
//! data (`kv_value`, `ts_payload`, timestamps), identical measured-phase
//! accounting (setup excluded from timing *and* from the flash counters,
//! counters reset immediately before each timed body) and identical
//! FNV-1a-32 checksums over the same serialisation, so that
//! `tools/compare_bench.py bench/results/c_wg8_host.json
//! bench/results/zig_wg8_host.json` can compare the two implementations.
//!
//! The Zig library uses a new on-flash format, so per-scenario flash traffic
//! legitimately differs from the C numbers; only the logical checksums (and the
//! operation counts) must match.
//!
//! ```
//! zig build -Doptimize=ReleaseFast
//! ./zig-out/bin/flashdb-bench.exe --wg 8 --runs 5 --out bench/results/zig_wg8_host.json
//! ./zig-out/bin/flashdb-bench.exe --wg 1 --runs 5 --out bench/results/zig_wg1_host.json
//! ./zig-out/bin/flashdb-bench.exe --mode check
//! ```
//!
//! Output layout: the JSON document goes to **stdout** and to `--out`; the
//! compact human-readable table goes to **stderr**, so stdout stays
//! machine-readable. `--mode check` prints `PASS`/`FAIL` lines to stdout and
//! exits non-zero when an invariant fails.

const std = @import("std");
const builtin = @import("builtin");
const flashdb = @import("flashdb");

/// Version tag recorded in the JSON document.
const version = "flashdb-zig-0.1.0";

// ---------------------------------------------------------------------------
// Protocol constants: bench/SCENARIOS.md + bench/c/README.md (normative).
// ---------------------------------------------------------------------------

/// Erase block (and database sector) size.
const sector_size: u32 = 4096;
/// Sectors per partition: 16 KiB partition = 4 x 4096 B.
const sectors_per_db: u16 = 4;
/// Partition size in bytes.
const partition_size: u32 = sector_size * sectors_per_db;
/// Whole simulated device: KV partition [0, 16 KiB) + TS partition [16 KiB, 32 KiB).
const device_size: u32 = 2 * partition_size;
const kv_part_offset: u32 = 0;
const ts_part_offset: u32 = partition_size;

const kv_hot_keys: u32 = 32;
const kv_warmup_gets: u32 = 128;
const kv_get_hot_ops: u64 = 2000;
const kv_get_miss_ops: u64 = 500;
const kv_set_small_ops: u64 = 64;
const kv_update_ops: u64 = 1000;
const kv_delete_reps: u32 = 3;
const kv_large_ops: u64 = 50;
const kv_large_value_len: usize = 1024;
const kv_iterate_ops: u64 = 100;
const kv_mount_ops: u64 = 100;

const seed_set_small: u32 = 0x11;
const seed_update: u32 = 0x22;
const seed_hot: u32 = 0x33;
const seed_large: u32 = 0x44;

const ts_payload_len = 32;
const ts_max_log_len = 32;
const ts_seed: u32 = 0x5A;
const ts_start_time: i32 = 1000;
const ts_append_max_calls = 4000;
const ts_range_queries = 500;
const ts_lcg_seed: u32 = 12345;

const fnv_offset: u32 = 0x811C9DC5;
const fnv_prime: u32 = 0x01000193;

const max_runs: usize = 64;
const max_scenarios: usize = 64;
const max_extras: usize = 32;
const json_buf_size: usize = 128 * 1024;

/// `src/tsdb.zig` is owned by another teammate; the TS scenarios are compiled in
/// automatically as soon as the module exports `Tsdb` (see the "TS scenarios"
/// section at the bottom of this file).
const ts_available: bool = @hasDecl(flashdb, "Tsdb");

// ---------------------------------------------------------------------------
// CLI options
// ---------------------------------------------------------------------------

const Mode = enum { bench, check };

const Options = struct {
    write_gran: u16 = 8,
    runs: usize = 5,
    out_path: []const u8 = "",
    impl: []const u8 = "zig",
    only: ?[]const u8 = null,
    mode: Mode = .bench,
};

var default_out_buf: [128]u8 = undefined;
var g_main_io: std.Io = undefined;

// ---------------------------------------------------------------------------
// Error-code accounting (JSON keys shared with the C harness)
// ---------------------------------------------------------------------------

const ErrKind = enum(u8) {
    ok,
    erase_err,
    read_err,
    write_err,
    part_not_found,
    name_err,
    name_exist,
    saved_full,
    init_failed,
};

const err_json_keys = [_][]const u8{
    "ok",         "erase_err",      "read_err",
    "write_err",  "part_not_found", "name_err",
    "name_exist", "saved_full",     "init_failed",
};

const err_kind_count = err_json_keys.len;

const ErrCounts = struct {
    codes: [err_kind_count]u64 = @splat(0),

    fn eq(a: ErrCounts, b: ErrCounts) bool {
        for (a.codes, b.codes) |x, y| {
            if (x != y) return false;
        }
        return true;
    }
};

const FlashStats = flashdb.sim.Stats;

fn flashStatsEq(a: FlashStats, b: FlashStats) bool {
    return a.reads == b.reads and a.read_bytes == b.read_bytes and
        a.writes == b.writes and a.write_bytes == b.write_bytes and
        a.erases == b.erases and a.erase_bytes == b.erase_bytes and
        a.set_bit_attempts == b.set_bit_attempts and a.violations == b.violations;
}

/// Maps a Zig error to the closest C `fdb_err_t` JSON key, so the `errcodes`
/// objects of the two harnesses stay comparable.
fn errKindOf(err: anyerror) ErrKind {
    if (err == error.InvalidName) return .name_err;
    if (err == error.NameTooLong) return .name_err;
    if (err == error.SavedFull) return .saved_full;
    if (err == error.InitFailed) return .init_failed;
    if (err == error.NotFormatted) return .init_failed;
    if (err == error.Corrupted) return .read_err;
    // Device-level failures (Misaligned, OutOfBounds, SimulatedFault): the
    // closest C equivalents are the write/read/erase error codes.
    return .write_err;
}

// ---------------------------------------------------------------------------
// Scenario results and JSON extras
// ---------------------------------------------------------------------------

const Extra = union(enum) {
    int: i64,
    uint: u64,
    float: f64,
    string: []const u8,
    boolean: bool,
    arr_u64: []const u64,
    arr_i64: []const i64,
};

const ExtraList = struct {
    keys: [max_extras][]const u8 = undefined,
    vals: [max_extras]Extra = undefined,
    n: usize = 0,

    fn add(self: *ExtraList, key: []const u8, val: Extra) void {
        if (self.n >= max_extras) @panic("flashdb-bench: extra list overflow");
        self.keys[self.n] = key;
        self.vals[self.n] = val;
        self.n += 1;
    }
};

const ScenarioResult = struct {
    name: []const u8 = "",
    ops: u64 = 0,
    hits: u64 = 0,
    runs: usize = 0,
    samples_ns: [max_runs]i64 = @splat(0),
    total_ns_median: i64 = 0,
    ns_per_op: f64 = 0.0,
    checksum: u32 = 0,
    flash: FlashStats = .{},
    errs: ErrCounts = .{},
    extra: ExtraList = .{},
    flash_consistent: bool = true,
    errs_consistent: bool = true,
};

// ---------------------------------------------------------------------------
// Data generation (must match the C harness byte for byte)
// ---------------------------------------------------------------------------

/// `kv_value(seed, i, len)`: `buf[j] = (seed + i*31 + j*7) & 0xFF`.
fn kvValue(buf: []u8, seed: u32, i: u32) void {
    for (buf, 0..) |*b, j| {
        b.* = @truncate(seed +% i *% 31 +% @as(u32, @intCast(j)) *% 7);
    }
}

/// `ts_payload(i)`: `buf[j] = (0x5A + i*13 + j*5) & 0xFF`.
fn tsPayload(buf: []u8, i: u32) void {
    for (buf, 0..) |*b, j| {
        b.* = @truncate(ts_seed +% i *% 13 +% @as(u32, @intCast(j)) *% 5);
    }
}

/// `"%s%u"` key formatting, e.g. `key12`, `kv3`, `absent499`.
fn keyOf(buf: []u8, prefix: []const u8, i: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, i }) catch
        @panic("flashdb-bench: key buffer too small");
}

// ---------------------------------------------------------------------------
// FNV-1a 32 (offset 0x811C9DC5, prime 0x01000193), little-endian u32 fields
// ---------------------------------------------------------------------------

fn fnvBytes(h_in: u32, bytes: []const u8) u32 {
    var h = h_in;
    for (bytes) |b| {
        h ^= b;
        h *%= fnv_prime;
    }
    return h;
}

fn fnvU32(h_in: u32, v: u32) u32 {
    var b: [4]u8 = undefined;
    b[0] = @truncate(v);
    b[1] = @truncate(v >> 8);
    b[2] = @truncate(v >> 16);
    b[3] = @truncate(v >> 24);
    return fnvBytes(h_in, &b);
}

/// Byte-wise key order, identical to C `strcmp` for the ASCII keys used here.
fn nameLessThan(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x != y) return x < y;
    }
    return a.len < b.len;
}

/// Protocol LCG for the ranged TS queries:
///   state = 12345; next: state = (state*1103515245 + 12345) mod 2^31
///   per query: off = next % 3000; len = 50 + next % 451
///              from = 1000 + off; to = from + len (inclusive)
const Lcg = struct {
    state: u32 = ts_lcg_seed,

    fn next(self: *Lcg) u32 {
        self.state = (self.state *% 1103515245 +% 12345) & 0x7FFFFFFF;
        return self.state;
    }

    const Range = struct { from: i32, to: i32 };

    fn range(self: *Lcg) Range {
        const off = self.next() % 3000;
        const len = 50 + self.next() % 451;
        const from: i32 = ts_start_time + @as(i32, @intCast(off));
        return .{ .from = from, .to = from + @as(i32, @intCast(len)) };
    }
};

/// Compile-time optimization mode name recorded as `opt`.
fn optName() []const u8 {
    return switch (builtin.mode) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

// ---------------------------------------------------------------------------
// The harness, instantiated once per write granularity (1 or 8 bits).
// ---------------------------------------------------------------------------

fn Harness(comptime write_gran: u16) type {
    return struct {
        const Self = @This();

        const Sim = flashdb.sim.RamFlash(.{
            .write_gran_bits = write_gran,
            .block_size = sector_size,
        });
        const Part = flashdb.flash.Partition(Sim);

        /// Library defaults for everything the protocol does not pin (the name
        /// cache size in particular) so the bench measures the shipped
        /// configuration; only geometry is fixed by the protocol.
        const kv_config: flashdb.KvdbConfig = .{
            .sector_size = sector_size,
            .sector_count = sectors_per_db,
        };
        const Kv = flashdb.Kvdb(Part, kv_config);
        /// Same geometry without the name cache: `sizeof` difference = cache bytes.
        const KvNoCache = flashdb.Kvdb(Part, .{
            .sector_size = sector_size,
            .sector_count = sectors_per_db,
            .cache_entries = 0,
        });

        // ---- device + databases ------------------------------------------
        var device_mem: [device_size]u8 = undefined;
        var flash: Sim = undefined;
        var kv_partition: Part = undefined;
        var ts_partition: Part = undefined;
        var kv: Kv = undefined;

        // ---- harness state -----------------------------------------------
        var g_io: std.Io = undefined;
        var g_alloc: std.mem.Allocator = undefined;
        var g_opts: Options = .{};
        var json_buf: [json_buf_size]u8 = undefined;

        var results: [max_scenarios]ScenarioResult = undefined;
        var result_count: usize = 0;
        var cur_errs: ErrCounts = .{};
        var check_failures: usize = 0;

        // Per-body counters (values from the last measured run, like the C
        // harness file-scope globals).
        var hot_hits: u64 = 0;
        var hot_sum_bytes: u64 = 0;
        var miss_hits: u64 = 0;
        var miss_sum_bytes: u64 = 0;
        var del_calls: u64 = 0;
        var set_calls: u64 = 0;
        var iterate_count: u32 = 0;
        var iterate_sum: u64 = 0;
        var mount_ok: u64 = 0;

        // =================================================================
        // Output helpers
        // =================================================================

        fn writeOut(bytes: []const u8) void {
            std.Io.File.stdout().writeStreamingAll(g_io, bytes) catch {};
        }

        fn writeErr(bytes: []const u8) void {
            std.Io.File.stderr().writeStreamingAll(g_io, bytes) catch {};
        }

        fn outPrint(comptime fmt: []const u8, args: anytype) void {
            var buf: [1024]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
            writeOut(s);
        }

        fn errPrint(comptime fmt: []const u8, args: anytype) void {
            var buf: [1024]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
            writeErr(s);
        }

        fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
            errPrint("flashdb-bench: FATAL: " ++ fmt ++ "\n", args);
            std.process.exit(3);
        }

        fn fatalErr(err: anyerror) u8 {
            errPrint("flashdb-bench: FATAL: {t}\n", .{err});
            return 3;
        }

        /// Simple fixed-buffer text appender (avoids the writer API entirely).
        const Out = struct {
            buf: []u8,
            len: usize = 0,

            fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
                const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch return;
                self.len += s.len;
            }

            fn slice(self: *const Out) []const u8 {
                return self.buf[0..self.len];
            }
        };

        // =================================================================
        // Device setup
        // =================================================================

        fn initDevice() void {
            flash = Sim.init(&device_mem);
            flash.eraseAll();
            flash.clearFault();
            flash.resetStats();
            kv_partition = .{ .dev = &flash, .offset = kv_part_offset, .len = partition_size };
            ts_partition = .{ .dev = &flash, .offset = ts_part_offset, .len = partition_size };
        }

        /// Whole-device erase + diagnostics reset (C: `sim_flash_erase_all()` +
        /// `sim_nor_diag_reset()`), used by every setup hook.
        fn deviceErase() void {
            flash.eraseAll();
            flash.resetStats();
        }

        // =================================================================
        // Scenario registry / measured-phase machinery
        // =================================================================

        fn want(name: []const u8) bool {
            if (g_opts.only) |only| return std.mem.eql(u8, only, name);
            return true;
        }

        fn newResult() *ScenarioResult {
            if (result_count >= max_scenarios) fatal("too many scenario results", .{});
            const r = &results[result_count];
            result_count += 1;
            r.* = .{};
            return r;
        }

        fn recordOk() void {
            cur_errs.codes[@intFromEnum(ErrKind.ok)] += 1;
        }

        fn recordErr(err: anyerror) void {
            cur_errs.codes[@intFromEnum(errKindOf(err))] += 1;
        }

        fn recordErrKind(kind: ErrKind) void {
            cur_errs.codes[@intFromEnum(kind)] += 1;
        }

        const Hooks = struct {
            setup: *const fn () anyerror!void,
            after_setup: ?*const fn () anyerror!void = null,
            body: *const fn () anyerror!void,
        };

        fn nowNs() i64 {
            return @intCast(std.Io.Clock.now(.awake, g_io).nanoseconds);
        }

        fn medianOf(values: []const i64) i64 {
            var tmp: [max_runs]i64 = undefined;
            const n = values.len;
            @memcpy(tmp[0..n], values);
            // Insertion sort (runs <= 64).
            var i: usize = 1;
            while (i < n) : (i += 1) {
                const v = tmp[i];
                var j = i;
                while (j > 0 and tmp[j - 1] > v) : (j -= 1) tmp[j] = tmp[j - 1];
                tmp[j] = v;
            }
            if (n % 2 == 1) return tmp[n / 2];
            return @divTrunc(tmp[n / 2 - 1] + tmp[n / 2], 2);
        }

        /// Protocol loop: for every repetition run `setup` (excluded from the
        /// timer and from the flash counters), reset the counters, run `body`
        /// between two monotonic clock reads, snapshot the flash counters.
        fn measure(r: *ScenarioResult, name: []const u8, runs_in: usize, hooks: Hooks) anyerror!void {
            const runs = @max(1, @min(runs_in, max_runs));
            r.name = name;
            r.runs = runs;

            var first_flash: FlashStats = undefined;
            var first_errs: ErrCounts = undefined;
            for (0..runs) |i| {
                try hooks.setup();
                if (hooks.after_setup) |after| try after();

                cur_errs = .{};
                flash.resetStats();

                const t0 = nowNs();
                try hooks.body();
                const t1 = nowNs();

                r.samples_ns[i] = t1 - t0;
                r.flash = flash.stats;
                if (i == 0) {
                    first_flash = r.flash;
                    first_errs = cur_errs;
                } else {
                    if (!flashStatsEq(first_flash, r.flash)) r.flash_consistent = false;
                    if (!ErrCounts.eq(first_errs, cur_errs)) r.errs_consistent = false;
                }
            }
            r.errs = cur_errs;
            r.total_ns_median = medianOf(r.samples_ns[0..runs]);
        }

        /// Fill `ops`/`ns_per_op` and the `extra` tail shared by every scenario.
        fn finish(r: *ScenarioResult, ops: u64) void {
            r.ops = ops;
            r.ns_per_op = if (ops > 0)
                @as(f64, @floatFromInt(r.total_ns_median)) / @as(f64, @floatFromInt(ops))
            else
                0.0;

            var min_ns = r.samples_ns[0];
            var max_ns = r.samples_ns[0];
            for (r.samples_ns[1..r.runs]) |s| {
                if (s < min_ns) min_ns = s;
                if (s > max_ns) max_ns = s;
            }
            r.extra.add("samples_ns", .{ .arr_i64 = r.samples_ns[0..r.runs] });
            r.extra.add("total_ns_min", .{ .int = min_ns });
            r.extra.add("total_ns_max", .{ .int = max_ns });
            r.extra.add("flash_consistent", .{ .boolean = r.flash_consistent });
            r.extra.add("errs_consistent", .{ .boolean = r.errs_consistent });
            // Extensions (not in the C document): simulator invariants.
            r.extra.add("set_bit_attempts", .{ .uint = r.flash.set_bit_attempts });
            r.extra.add("nor_violations", .{ .uint = r.flash.violations });
        }

        // =================================================================
        // KV snapshot + finish-phase state
        // =================================================================

        const KVSnapshot = struct {
            checksum: u32,
            count: u32,
            value_bytes: u64,
        };

        const SnapshotEntry = struct {
            name: []const u8,
            value: []const u8,
        };

        /// KV snapshot checksum, exactly like `bench_kv_snapshot_checksum`:
        /// FNV-1a-32 over `u32(entry_count)` then, entries sorted by key,
        /// `u32(key_len)`, key, `u32(value_len)`, value.
        fn kvSnapshot() anyerror!KVSnapshot {
            var count: u32 = 0;
            var value_bytes: u64 = 0;
            var it = kv.iterator();
            while (try it.next()) |entry| {
                count += 1;
                value_bytes += entry.value_len;
            }

            const ents = try g_alloc.alloc(SnapshotEntry, count);
            var i: usize = 0;
            var it2 = kv.iterator();
            while (try it2.next()) |entry| {
                if (i >= ents.len) return error.SnapshotCountChanged;
                const name = try g_alloc.dupe(u8, entry.name);
                const val = try g_alloc.alloc(u8, entry.value_len);
                const got = try it2.readValue(val, entry);
                if (got != entry.value_len) return error.SnapshotShortRead;
                ents[i] = .{ .name = name, .value = val };
                i += 1;
            }
            if (i != count) return error.SnapshotCountChanged;

            sortEntries(ents);

            var h = fnv_offset;
            h = fnvU32(h, count);
            for (ents) |entry| {
                h = fnvU32(h, @intCast(entry.name.len));
                h = fnvBytes(h, entry.name);
                h = fnvU32(h, @intCast(entry.value.len));
                h = fnvBytes(h, entry.value);
            }
            return .{ .checksum = h, .count = count, .value_bytes = value_bytes };
        }

        fn sortEntries(ents: []SnapshotEntry) void {
            var i: usize = 1;
            while (i < ents.len) : (i += 1) {
                const v = ents[i];
                var j = i;
                while (j > 0 and nameLessThan(v.name, ents[j - 1].name)) : (j -= 1) {
                    ents[j] = ents[j - 1];
                }
                ents[j] = v;
            }
        }

        /// Post-timing state capture shared by the KV scenarios.
        fn kvFinishState(r: *ScenarioResult, check_counter: bool) anyerror!void {
            const snap = try kvSnapshot();
            r.checksum = snap.checksum;
            r.extra.add("entries", .{ .uint = snap.count });
            r.extra.add("value_bytes", .{ .uint = snap.value_bytes });
            if (check_counter) {
                var got: [32]u8 = undefined;
                const n = (try kv.get("counter", &got)) orelse 0;
                const len_ok = n == 32;
                var expect: [32]u8 = undefined;
                kvValue(&expect, seed_update, @intCast(kv_update_ops - 1));
                r.extra.add("final_value_len_ok", .{ .boolean = len_ok });
                r.extra.add("final_value_matches", .{
                    .boolean = len_ok and std.mem.eql(u8, got[0..32], expect[0..]),
                });
            }
        }

        // =================================================================
        // KVDB setups (excluded from timing and counters)
        // =================================================================

        /// `bench_kv_setup_format`: erase the device, then mount (which formats).
        fn kvSetupFormat() anyerror!void {
            deviceErase();
            try kv.mount(kv_partition);
        }

        /// `bench_kv_setup_hot`: 32 keys `key{i}` = kv_value(0x33, i, 32) plus
        /// the 128-get warmup.
        fn kvSetupHot() anyerror!void {
            try kvSetupFormat();
            var kb: [32]u8 = undefined;
            var val: [32]u8 = undefined;
            for (0..kv_hot_keys) |i| {
                kvValue(&val, seed_hot, @intCast(i));
                try kv.set(keyOf(&kb, "key", @intCast(i)), &val);
            }
            var buf: [64]u8 = undefined;
            for (0..kv_warmup_gets) |i| {
                _ = try kv.get(keyOf(&kb, "key", @intCast(i % kv_hot_keys)), &buf);
            }
        }

        fn kvSetupCounter() anyerror!void {
            try kvSetupFormat();
            var val: [32]u8 = undefined;
            kvValue(&val, seed_update, 0);
            try kv.set("counter", &val);
        }

        // =================================================================
        // KV measured bodies
        // =================================================================

        fn bodySetSmall() anyerror!void {
            var kb: [16]u8 = undefined;
            var val: [8]u8 = undefined;
            for (0..kv_set_small_ops) |i| {
                kvValue(&val, seed_set_small, @intCast(i));
                kv.set(keyOf(&kb, "kv", @intCast(i % 8)), &val) catch |err| {
                    recordErr(err);
                    continue;
                };
                recordOk();
            }
        }

        fn bodyUpdate() anyerror!void {
            var val: [32]u8 = undefined;
            for (0..kv_update_ops) |i| {
                kvValue(&val, seed_update, @intCast(i));
                kv.set("counter", &val) catch |err| {
                    recordErr(err);
                    continue;
                };
                recordOk();
            }
        }

        fn bodyGetHot() anyerror!void {
            hot_hits = 0;
            hot_sum_bytes = 0;
            var kb: [32]u8 = undefined;
            var buf: [64]u8 = undefined;
            for (0..kv_get_hot_ops) |i| {
                const key = keyOf(&kb, "key", @intCast(i % kv_hot_keys));
                const res = kv.get(key, &buf) catch |err| {
                    recordErr(err);
                    continue;
                };
                const n = res orelse 0;
                if (n > 0) hot_hits += 1;
                hot_sum_bytes += n;
            }
        }

        fn bodyGetMiss() anyerror!void {
            miss_hits = 0;
            miss_sum_bytes = 0;
            var kb: [32]u8 = undefined;
            var buf: [64]u8 = undefined;
            for (0..kv_get_miss_ops) |i| {
                const key = keyOf(&kb, "absent", @intCast(i));
                const res = kv.get(key, &buf) catch |err| {
                    recordErr(err);
                    continue;
                };
                const n = res orelse 0;
                if (n > 0) miss_hits += 1;
                miss_sum_bytes += n;
            }
        }

        fn bodyDelete() anyerror!void {
            del_calls = 0;
            set_calls = 0;
            var kb: [32]u8 = undefined;
            var val: [32]u8 = undefined;
            for (0..kv_delete_reps) |_| {
                for (0..kv_hot_keys) |i| {
                    const key = keyOf(&kb, "key", @intCast(i));
                    const existed = kv.delete(key) catch |err| {
                        recordErr(err);
                        del_calls += 1;
                        continue;
                    };
                    // The C harness records FDB_KV_NAME_ERR for a missing key.
                    if (existed) recordOk() else recordErrKind(.name_err);
                    del_calls += 1;

                    kvValue(&val, seed_hot, @intCast(i));
                    kv.set(key, &val) catch |err| {
                        recordErr(err);
                        set_calls += 1;
                        continue;
                    };
                    recordOk();
                    set_calls += 1;
                }
            }
        }

        fn bodyIterate() anyerror!void {
            iterate_count = 0;
            iterate_sum = 0;
            for (0..kv_iterate_ops) |_| {
                var it = kv.iterator();
                var count: u32 = 0;
                var sum: u64 = 0;
                while (try it.next()) |entry| {
                    count += 1;
                    sum += entry.value_len;
                }
                iterate_count = count;
                iterate_sum = sum;
            }
        }

        fn bodyMount() anyerror!void {
            mount_ok = 0;
            for (0..kv_mount_ops) |_| {
                kv.mount(kv_partition) catch |err| {
                    recordErr(err);
                    continue;
                };
                recordOk();
                mount_ok += 1;
            }
        }

        fn bodyLarge() anyerror!void {
            var val: [kv_large_value_len]u8 = undefined;
            for (0..kv_large_ops) |i| {
                kvValue(&val, seed_large, @intCast(i));
                kv.set("big", &val) catch |err| {
                    recordErr(err);
                    continue;
                };
                recordOk();
            }
        }

        // =================================================================
        // KV scenario runners (same order as bench_kv.c)
        // =================================================================

        fn runKv(runs: usize) anyerror!void {
            if (want("kv_set_small")) {
                const r = newResult();
                try measure(r, "kv_set_small", runs, .{
                    .setup = kvSetupFormat,
                    .body = bodySetSmall,
                });
                try kvFinishState(r, false);
                finish(r, kv_set_small_ops);
            }

            if (want("kv_update_1k")) {
                const r = newResult();
                try measure(r, "kv_update_1k", runs, .{
                    .setup = kvSetupCounter,
                    .body = bodyUpdate,
                });
                try kvFinishState(r, true);
                r.extra.add("gc_sector_erases", .{ .uint = r.flash.erases });
                finish(r, kv_update_ops);
            }

            if (want("kv_get_hot")) {
                const r = newResult();
                try measure(r, "kv_get_hot", runs, .{
                    .setup = kvSetupHot,
                    .body = bodyGetHot,
                });
                try kvFinishState(r, false);
                r.extra.add("sum_returned_bytes", .{ .uint = hot_sum_bytes });
                r.hits = hot_hits;
                finish(r, kv_get_hot_ops);
            }

            if (want("kv_get_miss")) {
                const r = newResult();
                try measure(r, "kv_get_miss", runs, .{
                    .setup = kvSetupHot,
                    .body = bodyGetMiss,
                });
                try kvFinishState(r, false);
                r.extra.add("sum_returned_bytes", .{ .uint = miss_sum_bytes });
                r.hits = miss_hits;
                finish(r, kv_get_miss_ops);
            }

            if (want("kv_delete")) {
                const r = newResult();
                try measure(r, "kv_delete", runs, .{
                    .setup = kvSetupHot,
                    .body = bodyDelete,
                });
                try kvFinishState(r, false);
                r.extra.add("del_calls", .{ .uint = del_calls });
                r.extra.add("set_calls", .{ .uint = set_calls });
                finish(r, del_calls + set_calls);
            }

            if (want("kv_iterate")) {
                const r = newResult();
                try measure(r, "kv_iterate", runs, .{
                    .setup = kvSetupHot,
                    .body = bodyIterate,
                });
                try kvFinishState(r, false);
                r.extra.add("entries_per_iter", .{ .uint = iterate_count });
                r.extra.add("sum_value_len_per_iter", .{ .uint = iterate_sum });
                finish(r, kv_iterate_ops);
            }

            if (want("kv_mount")) {
                const r = newResult();
                try measure(r, "kv_mount", runs, .{
                    .setup = kvSetupHot,
                    .body = bodyMount,
                });
                try kvFinishState(r, false);
                r.extra.add("mount_ok", .{ .uint = mount_ok });
                finish(r, kv_mount_ops);
            }

            if (want("kv_large")) {
                const r = newResult();
                try measure(r, "kv_large", runs, .{
                    .setup = kvSetupFormat,
                    .body = bodyLarge,
                });
                try kvFinishState(r, false);
                finish(r, kv_large_ops);
            }
        }

        // =================================================================
        // Bench mode entry point
        // =================================================================

        fn benchMain() anyerror!void {
            try runKv(g_opts.runs);
            try runTs(g_opts.runs);

            if (g_opts.only != null and result_count == 0) {
                errPrint("flashdb-bench: no scenario named '{s}'\n", .{g_opts.only.?});
            }

            var jw = Jw{ .buf = &json_buf };
            emitJson(&jw);
            const doc = jw.buf[0..jw.len];

            std.Io.File.stdout().writeStreamingAll(g_io, doc) catch
                fatal("cannot write JSON to stdout", .{});
            std.Io.Dir.cwd().writeFile(g_io, .{
                .sub_path = g_opts.out_path,
                .data = doc,
            }) catch fatal("cannot write JSON to '{s}'", .{g_opts.out_path});

            printTable();
        }

        fn run(init: std.process.Init, opts: Options) u8 {
            g_io = init.io;
            g_alloc = init.arena.allocator();
            g_opts = opts;
            initDevice();

            return switch (opts.mode) {
                .bench => blk: {
                    benchMain() catch |err| break :blk fatalErr(err);
                    break :blk 0;
                },
                .check => checkMain() catch |err| fatalErr(err),
            };
        }

        // =================================================================
        // JSON document (same shape/field names as the C harness)
        // =================================================================

        const Jw = struct {
            buf: []u8,
            len: usize = 0,

            fn raw(self: *Jw, s: []const u8) void {
                @memcpy(self.buf[self.len..][0..s.len], s);
                self.len += s.len;
            }

            fn print(self: *Jw, comptime fmt: []const u8, args: anytype) void {
                const s = std.fmt.bufPrint(self.buf[self.len..], fmt, args) catch
                    @panic("flashdb-bench: JSON buffer overflow");
                self.len += s.len;
            }

            fn str(self: *Jw, s: []const u8) void {
                self.raw("\"");
                for (s) |c| {
                    switch (c) {
                        '"' => self.raw("\\\""),
                        '\\' => self.raw("\\\\"),
                        '\n' => self.raw("\\n"),
                        '\r' => self.raw("\\r"),
                        '\t' => self.raw("\\t"),
                        else => {
                            if (c < 0x20) {
                                self.print("\\u{x:0>4}", .{c});
                            } else {
                                self.buf[self.len] = c;
                                self.len += 1;
                            }
                        },
                    }
                }
                self.raw("\"");
            }

            fn extra(self: *Jw, list: *const ExtraList) void {
                self.raw("{");
                for (0..list.n) |i| {
                    if (i > 0) self.raw(",");
                    self.str(list.keys[i]);
                    self.raw(":");
                    switch (list.vals[i]) {
                        .int => |v| self.print("{d}", .{v}),
                        .uint => |v| self.print("{d}", .{v}),
                        .float => |v| self.print("{d:.6}", .{v}),
                        .string => |v| self.str(v),
                        .boolean => |v| self.raw(if (v) "true" else "false"),
                        .arr_u64 => |arr| {
                            self.raw("[");
                            for (arr, 0..) |v, j| {
                                if (j > 0) self.raw(",");
                                self.print("{d}", .{v});
                            }
                            self.raw("]");
                        },
                        .arr_i64 => |arr| {
                            self.raw("[");
                            for (arr, 0..) |v, j| {
                                if (j > 0) self.raw(",");
                                self.print("{d}", .{v});
                            }
                            self.raw("]");
                        },
                    }
                }
                self.raw("}");
            }

            fn errCodes(self: *Jw, errs: ErrCounts) void {
                self.raw("{");
                var first = true;
                for (errs.codes, 0..) |count, i| {
                    if (count == 0) continue;
                    if (!first) self.raw(",");
                    first = false;
                    self.str(err_json_keys[i]);
                    self.print(":{d}", .{count});
                }
                self.raw("}");
            }
        };

        fn emitConfig(w: *Jw) void {
            w.raw("{\n");
            w.print("    \"write_gran\": {d},\n", .{write_gran});
            w.print("    \"write_gran_bytes\": {d},\n", .{if (write_gran == 1) @as(u16, 1) else write_gran / 8});
            w.print("    \"sector_size\": {d},\n", .{sector_size});
            w.print("    \"sectors_per_db\": {d},\n", .{sectors_per_db});
            w.print("    \"partition_size\": {d},\n", .{partition_size});
            // The Zig library has plain partition values instead of FAL names;
            // these are the names the C reference uses for the same ranges.
            w.print("    \"partitions\": [\"kvdb\", \"tsdb\"],\n", .{});
            w.print("    \"partition_offsets\": [{d}, {d}],\n", .{ kv_part_offset, ts_part_offset });
            w.print("    \"kv_cache_table_size\": {d},\n", .{kv_config.cache_entries});
            w.print("    \"kv_cache_bytes\": {d},\n", .{@sizeOf(Kv) - @sizeOf(KvNoCache)});
            // The Zig design keeps per-sector state instead of a sector cache.
            w.raw("    \"sector_cache_table_size\": 0,\n");
            w.raw("    \"debug_log\": false,\n");
            w.raw("    \"ts_timestamp_bits\": 32,\n");
            w.print("    \"ts_max_log_len\": {d},\n", .{ts_max_log_len});
            if (comptime ts_available) {
                w.print("    \"ts_max_entry_count\": {d},\n", .{TsSection.ts_db.maxEntryCount()});
                w.print("    \"ts_index_size\": {d},\n", .{TsSection.Ts.index_size});
                w.print("    \"ts_bytes_per_entry\": {d},\n", .{TsSection.entry_bytes});
            } else {
                w.raw("    \"ts_max_entry_count\": 0,\n");
                w.raw("    \"ts_index_size\": 0,\n");
                w.raw("    \"ts_bytes_per_entry\": 0,\n");
            }
            w.print("    \"runs\": {d},\n", .{g_opts.runs});
            w.raw("    \"opt\": ");
            w.str(optName());
            w.raw(",\n    \"compiler\": ");
            w.str(builtin.zig_version_string);
            w.raw(",\n    \"host\": ");
            var host_buf: [128]u8 = undefined;
            const host = std.fmt.bufPrint(&host_buf, "zig-{s}-{s}-{s}", .{
                builtin.zig_version_string,
                @tagName(builtin.os.tag),
                @tagName(builtin.cpu.arch),
            }) catch "zig";
            w.str(host);
            w.raw(",\n    \"cflags\": ");
            var flags_buf: [96]u8 = undefined;
            const flags = std.fmt.bufPrint(&flags_buf, "zig build -Doptimize={s}", .{optName()}) catch "zig build";
            w.str(flags);
            // Zig-specific knobs (the C document stops at cflags).
            w.print(",\n    \"kv_max_name_len\": {d}", .{kv_config.max_name_len});
            w.print(",\n    \"kv_chunk_size\": {d}", .{kv_config.chunk_size});
            w.print(",\n    \"timer_resolution_ns\": {d}", .{timerResolutionNs()});
            w.raw("\n  }");
        }

        fn emitFootprint(w: *Jw) void {
            w.raw("{\n");
            w.print("    \"sizeof_kvdb\": {d},\n", .{@sizeOf(Kv)});
            w.print("    \"sizeof_tsdb\": {d},\n", .{if (comptime ts_available) TsSize() else 0});
            w.print("    \"sizeof_kv_iterator\": {d},\n", .{@sizeOf(Kv.Iterator)});
            w.print("    \"sizeof_partition\": {d},\n", .{@sizeOf(Part)});
            var note_buf: [512]u8 = undefined;
            const note = std.fmt.bufPrint(
                &note_buf,
                "sizeof_kvdb includes the {d}-entry name cache, the per-sector state arrays and the embedded flash driver value (sizeof_partition); partition/geometry not counted" ++
                    (if (ts_available) "" else "; sizeof_tsdb is 0 while src/tsdb.zig is not exported"),
                .{kv_config.cache_entries},
            ) catch "";
            w.raw("    \"note\": ");
            w.str(note);
            w.raw("\n  }");
        }

        fn emitSemantics(w: *Jw) void {
            w.raw("{\n");
            w.raw("    \"checksum_fn\": \"FNV-1a 32: hash=0x811C9DC5; per byte: hash^=b; hash*=0x01000193 (wrapping); decimal u32\",\n");
            w.raw("    \"kv_value_formula\": \"byte[j] = (seed + i*31 + j*7) & 0xFF\",\n");
            w.raw("    \"kv_seeds\": {\"kv_set_small\": 17, \"kv_update_1k_initial\": 34, \"kv_get_hot\": 51, \"kv_delete_set\": 51, \"kv_large\": 68},\n");
            w.raw("    \"ts_payload_formula\": \"byte[j] = (0x5A + i*13 + j*5) & 0xFF\",\n");
            w.raw("    \"ts_timestamp_formula\": \"t_i = 1000 + i\",\n");
            w.raw("    \"delete_missing_key\": \"Kvdb.delete returns false (the Zig API has no FDB_KV_NAME_ERR); the errcodes object counts it as name_err for C compatibility\",\n");
            w.raw("    \"delete_missing_key_code\": 5,\n");
            w.raw("    \"get_missing_returns\": 0,\n");
            w.raw("    \"kv_checksum\": \"FNV-1a-32 over u32(entry_count), then entries sorted by key: u32(key_len), key, u32(value_len), value\",\n");
            w.raw("    \"ts_checksum\": \"FNV-1a-32 over forward-iteration records: u32(status), u32(time), u32(log_len), payload[log_len]; then u32(entry_count)\",\n");
            w.raw("    \"range_checksum\": \"tsl_by_time/tsl_query_count: FNV-1a-32 over u32(500), then u32(count) per query\",\n");
            w.raw("    \"lcg\": \"state=12345; next: state=(state*1103515245+12345) mod 2^31; per query: off=next()%3000, len=50+next()%451; from=1000+off; to=from+len\",\n");
            w.raw("    \"timing\": \"std.Io.Clock.awake (monotonic; QueryPerformanceCounter on Windows), median of runs; setup excluded from timing and flash counters\",\n");
            w.raw("    \"flash_cost\": \"read_bytes*1 + write_bytes*10 + erase_bytes*100\",\n");
            w.raw("    \"errcode_mapping\": \"InvalidName->name_err; SavedFull->saved_full; InitFailed|NotFormatted->init_failed; Corrupted->read_err; device errors->write_err; delete()==false->name_err\",\n");
            w.raw("    \"get_length_semantics\": \"Kvdb.get returns the total value length (copied length = min(buf.len, len)); every get here passes a buffer >= the value, so hits and byte sums match the C harness\",\n");
            w.raw("    \"ts_capacity_note\": \"the Zig TSDB layout (fixed 12-byte index + payload area) holds 368 max_len entries in 4x4096 sectors, while upstream FlashDB stops at 308 (write_gran 8) / 336 (write_gran 1); 'populate to full' therefore yields a different entry count and the tsl_* checksums cover a different amount of data, so they are not byte-comparable with the C document\",\n");
            w.raw("    \"ts_parity_extras\": \"tsl_append/tsl_iter_fwd/tsl_iter_rev/tsl_mount/tsl_clean carry c_ref_capacity + c_ref_prefix_checksum (the same FNV serialisation over only the first c_ref_capacity entries, expected to equal the C document checksum); tsl_by_time/tsl_query_count carry c_ref_last_time + c_ref_sum + c_ref_checksum (the same LCG range loop clamped to the C timestamp window, expected to equal the C sum_*/checksum)\",\n");
            w.raw("    \"write_gran_note\": \"write_gran 1 and 8 currently share the same byte-granule status representation, so their flash traffic is identical\"\n");
            w.raw("  }");
        }

        fn emitScenarios(w: *Jw) void {
            w.raw("[");
            for (results[0..result_count], 0..) |*r, i| {
                if (i > 0) w.raw(",");
                w.raw("\n    {\n      \"name\": ");
                w.str(r.name);
                w.print(",\n      \"ops\": {d},", .{r.ops});
                w.print("\n      \"hits\": {d},", .{r.hits});
                w.print("\n      \"total_ns_median\": {d},", .{r.total_ns_median});
                w.print("\n      \"ns_per_op\": {d:.3},", .{r.ns_per_op});
                w.print("\n      \"runs\": {d},", .{r.runs});
                w.print("\n      \"checksum\": {d},", .{r.checksum});
                w.raw("\n      \"errcodes\": ");
                w.errCodes(r.errs);
                w.print(
                    ",\n      \"flash\": {{\"reads\": {d}, \"read_bytes\": {d}, \"writes\": {d}, \"write_bytes\": {d}, \"erases\": {d}, \"erase_bytes\": {d}}}",
                    .{ r.flash.reads, r.flash.read_bytes, r.flash.writes, r.flash.write_bytes, r.flash.erases, r.flash.erase_bytes },
                );
                w.raw(",\n      \"extra\": ");
                w.extra(&r.extra);
                w.raw("\n    }");
            }
            w.raw("\n  ]");
        }

        fn emitJson(w: *Jw) void {
            w.raw("{\n  \"impl\": ");
            w.str(g_opts.impl);
            w.raw(",\n  \"version\": ");
            w.str(version);
            w.raw(",\n  \"opt\": ");
            w.str(optName());
            w.print(",\n  \"write_gran\": {d}", .{write_gran});
            w.raw(",\n  \"config\": ");
            emitConfig(w);
            w.raw(",\n  \"footprint\": ");
            emitFootprint(w);
            w.raw(",\n  \"semantics\": ");
            emitSemantics(w);
            w.raw(",\n  \"scenarios\": ");
            emitScenarios(w);
            w.raw("\n}\n");
        }

        // =================================================================
        // Human-readable summary (stderr)
        // =================================================================

        fn printTable() void {
            var buf: [8 * 1024]u8 = undefined;
            var out = Out{ .buf = &buf };
            out.print("== zig host benchmark: impl={s} opt={s} write_gran={d} runs={d} ==\n", .{
                g_opts.impl, optName(), write_gran, g_opts.runs,
            });
            out.print("{s: <22} {s: >6} {s: >10} {s: >7} {s: >10} {s: >7} {s: >9} {s: >4} {s: >9} {s: >12} {s: >10}\n", .{
                "scenario", "ops", "ns/op", "reads", "read_bytes", "writes", "write_bytes", "er", "erase_bytes", "weighted", "checksum",
            });
            for (results[0..result_count]) |*r| {
                const weighted = r.flash.read_bytes + 10 * r.flash.write_bytes + 100 * r.flash.erase_bytes;
                out.print("{s: <22} {d: >6} {d: >10.2} {d: >7} {d: >10} {d: >7} {d: >9} {d: >4} {d: >9} {d: >12} {d: >10}\n", .{
                    r.name, r.ops, r.ns_per_op, r.flash.reads, r.flash.read_bytes, r.flash.writes, r.flash.write_bytes, r.flash.erases, r.flash.erase_bytes, weighted, r.checksum,
                });
            }
            writeErr(out.slice());
        }

        /// Smallest non-zero delta between two consecutive monotonic clock reads,
        /// reported as `config.timer_resolution_ns`.
        fn timerResolutionNs() u64 {
            var best: i64 = std.math.maxInt(i64);
            var prev = std.Io.Clock.now(.awake, g_io).nanoseconds;
            for (0..256) |_| {
                const now = std.Io.Clock.now(.awake, g_io).nanoseconds;
                const d = now - prev;
                if (d > 0 and d < best) best = @intCast(d);
                prev = now;
            }
            if (best == std.math.maxInt(i64)) return 0;
            return @intCast(best);
        }

        // =================================================================
        // Self-checks (`--mode check`)
        // =================================================================

        fn checkReport(ok: bool, name: []const u8) void {
            outPrint("{s} {s}\n", .{ if (ok) "PASS" else "FAIL", name });
            if (!ok) check_failures += 1;
        }

        fn checkU64(name: []const u8, got: u64, expected: u64) void {
            if (got == expected) {
                checkReport(true, name);
            } else {
                outPrint("FAIL {s}: got {d}, want {d}\n", .{ name, got, expected });
                check_failures += 1;
            }
        }

        fn checkI64(name: []const u8, got: i64, expected: i64) void {
            if (got == expected) {
                checkReport(true, name);
            } else {
                outPrint("FAIL {s}: got {d}, want {d}\n", .{ name, got, expected });
                check_failures += 1;
            }
        }

        fn isOk(res: anytype) bool {
            res catch return false;
            return true;
        }

        fn checkSim() void {
            initDevice();
            deviceErase();

            var all_ff = true;
            for (flash.image()) |b| {
                if (b != 0xFF) {
                    all_ff = false;
                    break;
                }
            }
            checkReport(all_ff, "sim: erased image is all 0xFF");
            checkU64("sim: device size", flash.image().len, device_size);

            flash.resetStats();
            var data = [_]u8{0xF0};
            checkReport(isOk(flash.write(0, &data)), "sim: write op accepts a byte");
            var back: [4]u8 = @splat(0);
            checkReport(isOk(flash.read(0, back[0..1])), "sim: read op accepts a byte");
            checkU64("sim: read returns the written byte", back[0], 0xF0);

            var clear = [_]u8{0x0F};
            checkReport(isOk(flash.write(0, &clear)), "sim: second write accepted");
            flash.read(0, back[0..1]) catch {};
            checkU64("sim: write can only clear bits", back[0], 0x00);
            checkU64("sim: set-bit attempt counted", flash.stats.set_bit_attempts, 1);

            const st = flash.stats;
            checkU64("sim: stats reads", st.reads, 2);
            checkU64("sim: stats read_bytes", st.read_bytes, 2);
            checkU64("sim: stats writes", st.writes, 2);
            checkU64("sim: stats write_bytes", st.write_bytes, 2);

            checkReport(!isOk(flash.erase(1, sector_size)), "sim: unaligned erase rejected");
            checkReport(!isOk(flash.erase(0, 100)), "sim: mis-sized erase rejected");
            checkReport(isOk(flash.erase(0, sector_size)), "sim: aligned erase ok");
            checkU64("sim: erase stats", flash.stats.erases, 1);
            checkU64("sim: erase_bytes stats", flash.stats.erase_bytes, sector_size);
            flash.read(0, back[0..1]) catch {};
            checkU64("sim: erase sets 0xFF", back[0], 0xFF);
            checkU64("sim: bounds violations counted", flash.stats.violations, 2);

            // Fault injection (power-cut hook): mutations fail from the chosen
            // point on and leave flash untouched; reads keep working.
            flash.armFault(1);
            var marker = [_]u8{0xAA};
            const first_ok = isOk(flash.write(16, &marker));
            const second_failed = !isOk(flash.write(17, &marker));
            const erase_failed = !isOk(flash.erase(0, sector_size));
            flash.read(17, back[0..1]) catch {};
            flash.clearFault();
            checkReport(first_ok, "sim: fault injection allows the first mutation");
            checkReport(second_failed, "sim: fault injection rejects the next write");
            checkReport(erase_failed, "sim: fault injection rejects an erase");
            checkU64("sim: failed write leaves flash unchanged", back[0], 0xFF);
            checkReport(isOk(flash.write(17, &marker)), "sim: fault injection cleared");
        }

        fn checkPrimitives() void {
            checkU64("fnv: empty string", fnvBytes(fnv_offset, ""), 2166136261);
            checkU64("fnv: \"a\"", fnvBytes(fnv_offset, "a"), 3826002220);
            checkU64("fnv: \"abc\"", fnvBytes(fnv_offset, "abc"), 440920331);
            checkU64("fnv: u32(1) little-endian", fnvU32(fnv_offset, 1), 4218009092);

            var val: [32]u8 = undefined;
            kvValue(&val, seed_hot, 0);
            checkU64("data: kv_value(0x33,0,32)[0]", val[0], 0x33);
            checkU64("data: kv_value(0x33,0,32)[31]", val[31], 0x0C);

            var payload: [ts_payload_len]u8 = undefined;
            tsPayload(&payload, 0);
            checkU64("data: ts_payload(0)[0]", payload[0], 0x5A);
            checkU64("data: ts_payload(0)[31]", payload[31], 0xF5);

            var lcg = Lcg{};
            const r0 = lcg.range();
            checkI64("lcg: range[0].from", r0.from, 2606);
            checkI64("lcg: range[0].to", r0.to, 2776);
            const r1 = lcg.range();
            checkI64("lcg: range[1].from", r1.from, 2924);
            checkI64("lcg: range[1].to", r1.to, 3108);

            checkReport(Kv.max_value_len >= kv_large_value_len, "kv: max_value_len >= 1024");
        }

        fn checkPartitions() void {
            checkU64("part: kv partition offset", kv_partition.offset, kv_part_offset);
            checkU64("part: kv partition size", kv_partition.len, partition_size);
            checkU64("part: ts partition offset", ts_partition.offset, ts_part_offset);
            checkU64("part: ts partition size", ts_partition.len, partition_size);
            checkU64("part: partitions tile the device", ts_partition.offset + ts_partition.len, device_size);
        }

        fn checkKvBasic() anyerror!void {
            var kb: [32]u8 = undefined;
            var val: [32]u8 = undefined;
            var got: [64]u8 = undefined;

            try kvSetupFormat();
            var sets_ok = true;
            for (0..4) |i| {
                kvValue(&val, seed_hot, @intCast(i));
                kv.set(keyOf(&kb, "key", @intCast(i)), &val) catch {
                    sets_ok = false;
                };
            }
            checkReport(sets_ok, "kv: 4 x set");

            var gets_ok = true;
            var data_ok = true;
            for (0..4) |i| {
                kvValue(&val, seed_hot, @intCast(i));
                const n = (kv.get(keyOf(&kb, "key", @intCast(i)), &got) catch null) orelse 0;
                if (n != 32) gets_ok = false;
                if (!std.mem.eql(u8, got[0..32], val[0..])) data_ok = false;
            }
            checkReport(gets_ok, "kv: get returns value_len");
            checkReport(data_ok, "kv: get data matches stored value");

            const snap = try kvSnapshot();
            checkU64("kv: iterate count", snap.count, 4);
            checkU64("kv: iterate value bytes", snap.value_bytes, 4 * 32);

            const existed = try kv.delete("key0");
            checkReport(existed, "kv: delete existing");
            checkU64("kv: get deleted key returns 0", (try kv.get("key0", &got)) orelse 0, 0);
            const again = try kv.delete("key0");
            checkReport(!again, "kv: delete missing key returns false");

            const snap_after = try kvSnapshot();
            checkU64("kv: iterate count after delete", snap_after.count, 3);

            try kv.mount(kv_partition);
            const snap_remount = try kvSnapshot();
            checkReport(snap_remount.checksum == snap_after.checksum, "kv: remount keeps checksum");
            checkU64("kv: remount count", snap_remount.count, 3);
            kvValue(&val, seed_hot, 1);
            const n = (try kv.get("key1", &got)) orelse 0;
            checkReport(n == 32 and std.mem.eql(u8, got[0..32], val[0..]), "kv: remount keeps value");

            checkU64("kv: no NOR set-bit attempts", flash.stats.set_bit_attempts, 0);
            checkU64("kv: no out-of-bounds flash access", flash.stats.violations, 0);
        }

        fn checkKvGc() anyerror!void {
            var val: [32]u8 = undefined;
            var got: [32]u8 = undefined;

            try kvSetupFormat();
            kvValue(&val, seed_update, 0);
            try kv.set("counter", &val);

            flash.resetStats();
            var ok = true;
            for (0..kv_update_ops) |i| {
                kvValue(&val, seed_update, @intCast(i));
                kv.set("counter", &val) catch {
                    ok = false;
                };
            }
            checkReport(ok, "kv: 1000 counter updates");
            checkReport(flash.stats.erases > 0, "kv: 1000 updates trigger GC sector erases");

            const n = (try kv.get("counter", &got)) orelse 0;
            checkU64("kv: last value readable after GC", n, 32);
            checkReport(n == 32 and std.mem.eql(u8, got[0..32], val[0..]), "kv: last value matches after GC");
            checkU64("kv: no NOR set-bit attempts during GC", flash.stats.set_bit_attempts, 0);
            checkU64("kv: no out-of-bounds access during GC", flash.stats.violations, 0);

            try kv.mount(kv_partition);
            const n2 = (try kv.get("counter", &got)) orelse 0;
            checkReport(n2 == 32 and std.mem.eql(u8, got[0..32], val[0..]), "kv: value survives remount after GC");
        }

        fn setSmallWorkload() anyerror!void {
            try kvSetupFormat();
            var kb: [16]u8 = undefined;
            var val: [8]u8 = undefined;
            for (0..kv_set_small_ops) |i| {
                kvValue(&val, seed_set_small, @intCast(i));
                try kv.set(keyOf(&kb, "kv", @intCast(i % 8)), &val);
            }
        }

        fn checkDeterminism() anyerror!void {
            try setSmallWorkload();
            const cs1 = (try kvSnapshot()).checksum;
            const flash1 = flash.stats;
            try setSmallWorkload();
            const cs2 = (try kvSnapshot()).checksum;
            const flash2 = flash.stats;
            checkReport(cs1 == cs2, "det: kv_set_small checksum stable");
            checkReport(flashStatsEq(flash1, flash2), "det: kv_set_small flash counters stable");
            // The protocol's expected value, computed independently in Python.
            checkU64("det: kv_set_small checksum matches the protocol", cs1, 411068509);
        }

        fn checkMain() anyerror!u8 {
            outPrint("== Zig harness self-check (write_gran={d}, opt={s}) ==\n", .{ write_gran, optName() });
            check_failures = 0;
            checkSim();
            checkPartitions();
            checkPrimitives();
            try checkKvBasic();
            try checkKvGc();
            try checkDeterminism();
            checkTs();
            outPrint("== {s}: {d} check(s) failed ==\n", .{
                if (check_failures == 0) "OK" else "FAIL",
                check_failures,
            });
            return if (check_failures == 0) 0 else 1;
        }

        // =================================================================
        // TS scenarios
        //
        // `src/tsdb.zig` is owned by another teammate. Everything below is
        // compiled only when `flashdb` exports `Tsdb`; until then the bench
        // document simply has no `tsl_*` scenarios and both bench and check
        // print a note. The scenario bodies mirror `bench/c/bench_ts.c` one to
        // one and are enabled by the `ts_available` flag above.
        // =================================================================

        /// `@sizeOf` of the TS database (0 while `flashdb.Tsdb` is not exported).
        fn TsSize() comptime_int {
            return @sizeOf(TsSection.Ts);
        }

        fn runTs(runs: usize) anyerror!void {
            if (comptime ts_available) {
                try TsSection.runAll(runs);
            } else {
                errPrint("flashdb-bench: note: src/tsdb.zig is not exported yet, TS scenarios skipped ({d} runs planned)\n", .{runs});
            }
        }

        fn checkTs() void {
            if (comptime ts_available) {
                TsSection.runChecks() catch |err| {
                    errPrint("FAIL ts: checks failed: {t}\n", .{err});
                    check_failures += 1;
                };
            } else {
                checkReport(true, "ts: SKIPPED (src/tsdb.zig not exported yet)");
            }
        }

        // ---- TS scenario implementation (bench_ts.c equivalents) ----------
        //
        // Nothing in this container is referenced while `ts_available` is
        // false, so the harness builds against a tree without `src/tsdb.zig`
        // being exported. Everything mirrors `bench/c/bench_ts.c` one to one:
        // same payload formula, timestamps `1000 + i`, the same setup/measured
        // split, the same FNV-1a-32 snapshot/range serialisation and the same
        // LCG ranges.
        const TsSection = struct {
            const Ts = flashdb.Tsdb(Part, .{
                .sector_size = sector_size,
                .sector_count = sectors_per_db,
                .ts_bits = 32,
                .max_len = ts_max_log_len,
            });

            var ts_db: Ts = undefined;

            // State of the last measured run (like the C harness file globals).
            var ts_append_count: u64 = 0;
            var ts_append_calls: u64 = 0;
            var ts_saved_full: bool = false;
            var ts_capacity: u32 = 0;
            var ts_rollover_ok: u64 = 0;
            var ts_rollover_calls: u64 = 0;
            var ts_populated: u32 = 0;
            var ts_iter_count: u32 = 0;
            var ts_iter_sum: u64 = 0;
            var ts_range_counts: [ts_range_queries]u32 = @splat(0);
            var ts_range_total: u64 = 0;
            var ts_range_payload: u64 = 0;
            var ts_mount_ok: u64 = 0;
            var ts_mount_checksum: u32 = 0;
            var ts_mount_prefix_checksum: u32 = 0;
            var ts_clean_appends: u64 = 0;

            // ---- helpers -------------------------------------------------

            fn tsTime(i: u64) Ts.Time {
                return ts_start_time + @as(Ts.Time, @intCast(i));
            }

            fn appendOne(i: u64) anyerror!void {
                var payload: [ts_payload_len]u8 = undefined;
                tsPayload(&payload, @intCast(i));
                try ts_db.append(tsTime(i), &payload);
            }

            /// `ts_setup`: whole-device erase, mount (formats sector 0), then
            /// set the rollover mode explicitly (the C harness always does).
            fn setupFormat(rollover: bool) anyerror!void {
                deviceErase();
                try ts_db.mount(ts_partition);
                ts_db.setRollover(rollover);
            }

            const Populate = struct {
                appended: u64,
                /// Error that stopped the loop (null = the call limit was hit).
                rc: ?anyerror,
            };

            /// `bench_ts_populate_full`: append t=1000+i until the database
            /// reports an error (`SavedFull` with rollover disabled).
            fn populateFull(max_appends: u64) Populate {
                var i: u64 = 0;
                var rc: ?anyerror = null;
                while (i < max_appends) : (i += 1) {
                    appendOne(i) catch |err| {
                        rc = err;
                        break;
                    };
                }
                return .{ .appended = i, .rc = rc };
            }

            fn requireSavedFull(p: Populate, comptime what: []const u8) void {
                if (p.rc == null) {
                    fatal(what ++ ": no error raised (appended {d})", .{p.appended});
                }
                if (p.rc.? != error.SavedFull) {
                    fatal(what ++ ": stopped with {t} instead of SavedFull (appended {d})", .{ p.rc.?, p.appended });
                }
            }

            const IterResult = struct {
                count: u32 = 0,
                sum_len: u64 = 0,
            };

            const TSSnapshot = struct {
                checksum: u32,
                count: u32,
                payload_bytes: u64,
            };

            /// TS snapshot checksum, exactly like `bench_ts_snapshot_checksum`:
            /// forward iteration over `u32(status)`, `u32(time)`,
            /// `u32(log_len)`, payload bytes; then `u32(entry_count)`.
            fn snapshot() anyerror!TSSnapshot {
                var h = fnv_offset;
                var count: u32 = 0;
                var payload_bytes: u64 = 0;
                var buf: [ts_max_log_len]u8 = undefined;
                var it = ts_db.iterator();
                while (try it.next()) |entry| {
                    const n = try it.readPayload(&buf, entry);
                    if (n != entry.len) return error.SnapshotShortRead;
                    h = fnvU32(h, @intFromEnum(entry.status));
                    h = fnvU32(h, @bitCast(entry.time));
                    h = fnvU32(h, entry.len);
                    h = fnvBytes(h, buf[0..n]);
                    count += 1;
                    payload_bytes += n;
                }
                h = fnvU32(h, count);
                return .{ .checksum = h, .count = count, .payload_bytes = payload_bytes };
            }

            /// `ts_finish_snapshot`: checksum + the post-phase state extras.
            /// Returns the snapshot so scenario runners can normalise by count.
            fn finishSnapshot(r: *ScenarioResult) anyerror!TSSnapshot {
                const snap = try snapshot();
                r.checksum = snap.checksum;
                r.extra.add("entries_after", .{ .uint = snap.count });
                r.extra.add("payload_bytes_after", .{ .uint = snap.payload_bytes });
                return snap;
            }

            /// On-flash bytes one `max_len` entry costs in this layout.
            const entry_bytes: u32 = Ts.index_size +
                @as(u32, @intCast(flashdb.format.alignUp(flashdb.flash.granBytes(Part), ts_max_log_len)));

            /// Additive normalisation block for the TS scenarios (the C document
            /// has nothing equivalent): the Zig format stores more entries in the
            /// same partition (368 vs the C 308/336), so per-fill-to-capacity
            /// totals are not directly comparable.  These fields divide traffic
            /// and time by the number of stored entries.
            fn addTsNormalization(r: *ScenarioResult, entries: u64, add_capacity: bool) void {
                const n: f64 = if (entries == 0) 1.0 else @floatFromInt(entries);
                r.extra.add("entries", .{ .uint = entries });
                if (add_capacity) r.extra.add("capacity", .{ .uint = ts_db.maxEntryCount() });
                r.extra.add("max_entry_count", .{ .uint = ts_db.maxEntryCount() });
                r.extra.add("bytes_per_entry", .{ .uint = entry_bytes });
                r.extra.add("normalized_ns_per_entry", .{ .float = @as(f64, @floatFromInt(r.total_ns_median)) / n });
                r.extra.add("normalized_read_bytes_per_entry", .{ .float = @as(f64, @floatFromInt(r.flash.read_bytes)) / n });
                r.extra.add("normalized_write_bytes_per_entry", .{ .float = @as(f64, @floatFromInt(r.flash.write_bytes)) / n });
                r.extra.add("normalized_erase_bytes_per_entry", .{ .float = @as(f64, @floatFromInt(r.flash.erase_bytes)) / n });
                r.extra.add("normalized_writes_per_entry", .{ .float = @as(f64, @floatFromInt(r.flash.writes)) / n });
                r.extra.add("normalized_erases_per_entry", .{ .float = @as(f64, @floatFromInt(r.flash.erases)) / n });
            }

            fn rangeChecksum() u32 {
                var h = fnv_offset;
                h = fnvU32(h, ts_range_queries);
                for (ts_range_counts) |count| h = fnvU32(h, count);
                return h;
            }

            // ---- cross-implementation parity probes -----------------------
            //
            // The Zig TSDB layout holds more `max_len` entries per sector than
            // upstream FlashDB (fixed 12-byte index + payload area vs the
            // variable-length FDB log index), so "populate to full" stops at a
            // different entry count (368 here vs 308/336 for the C harness).
            // The protocol checksums cover the *whole* resulting state, so they
            // are not comparable between the two formats.  These extras fold the
            // same FNV-1a-32 serialisation over only the part of the Zig state
            // that the C document also holds, which makes the logical content
            // provably identical (the values are expected to equal the C
            // document's `checksum`/`sum_count`/`sum_matches` fields verbatim).
            //
            // `bench/c/README.md`: `tsl_append` reports 308 appends at write_gran
            // 8 and 336 at write_gran 1, i.e. those are the C capacities.
            const c_ref_capacity: u32 = if (write_gran == 1) 336 else 308;
            const c_ref_last_time: Ts.Time = ts_start_time + @as(Ts.Time, @intCast(c_ref_capacity - 1));

            /// Snapshot checksum over the first `limit` entries, closed with
            /// `u32(limit)`: identical to the C snapshot checksum when the C
            /// database holds exactly `limit` entries.
            fn snapshotPrefixChecksum(limit: u32) anyerror!u32 {
                var h = fnv_offset;
                var count: u32 = 0;
                var buf: [ts_max_log_len]u8 = undefined;
                var it = ts_db.iterator();
                while (count < limit) {
                    const entry = (try it.next()) orelse break;
                    const got = try it.readPayload(&buf, entry);
                    if (got != entry.len) return error.SnapshotShortRead;
                    h = fnvU32(h, @intFromEnum(entry.status));
                    h = fnvU32(h, @bitCast(entry.time));
                    h = fnvU32(h, entry.len);
                    h = fnvBytes(h, buf[0..got]);
                    count += 1;
                }
                h = fnvU32(h, count);
                return h;
            }

            const RangeParity = struct { total: u64, checksum: u32 };

            /// The `tsl_by_time`/`tsl_query_count` range loop restricted to the
            /// timestamp window the C database can hold: the LCG is replayed
            /// exactly, but ranges are clamped to `c_ref_last_time`.  For the C
            /// state this is a no-op (its last timestamp is exactly that), so
            /// `total`/`checksum` equal the C document's `sum_*`/`checksum`.
            fn rangeParity() anyerror!RangeParity {
                var counts: [ts_range_queries]u32 = undefined;
                var total: u64 = 0;
                var lcg = Lcg{};
                for (0..ts_range_queries) |q| {
                    const range = lcg.range();
                    const to = @min(range.to, c_ref_last_time);
                    var n: u32 = 0;
                    if (to >= range.from) {
                        var it = ts_db.iteratorByTime(range.from, to);
                        while (try it.next()) |_| n += 1;
                    }
                    counts[q] = n;
                    total += n;
                }
                var h = fnv_offset;
                h = fnvU32(h, ts_range_queries);
                for (counts) |count| h = fnvU32(h, count);
                return .{ .total = total, .checksum = h };
            }

            /// Attach the snapshot parity probe (call after `finish`).
            fn addSnapshotParity(r: *ScenarioResult) anyerror!void {
                addSnapshotParityWith(r, try snapshotPrefixChecksum(c_ref_capacity));
            }

            fn addSnapshotParityWith(r: *ScenarioResult, prefix_checksum: u32) void {
                r.extra.add("c_ref_capacity", .{ .uint = c_ref_capacity });
                r.extra.add("c_ref_prefix_checksum", .{ .uint = prefix_checksum });
            }

            /// Attach the ranged-query parity probe (call after `finish`).
            fn addRangeParity(r: *ScenarioResult) anyerror!void {
                const parity = try rangeParity();
                r.extra.add("c_ref_last_time", .{ .uint = @intCast(c_ref_last_time) });
                r.extra.add("c_ref_sum", .{ .uint = parity.total });
                r.extra.add("c_ref_checksum", .{ .uint = parity.checksum });
            }

            // ---- setups (excluded from timing and from the counters) ------

            fn setupAppend() anyerror!void {
                try setupFormat(false);
            }

            fn setupRollover() anyerror!void {
                try setupFormat(true);
            }

            fn setupPopulate() anyerror!void {
                try setupFormat(false);
                const p = populateFull(ts_append_max_calls);
                requireSavedFull(p, "ts populate-to-full");
                ts_populated = @intCast(p.appended);
            }

            /// `tsl_mount_after_setup`: the comparable state is the populated
            /// database, captured before the measured mount loop.
            fn afterSetupMount() anyerror!void {
                ts_mount_checksum = (try snapshot()).checksum;
                ts_mount_prefix_checksum = try snapshotPrefixChecksum(c_ref_capacity);
            }

            // ---- measured bodies ------------------------------------------

            fn bodyAppend() anyerror!void {
                ts_append_count = 0;
                ts_append_calls = 0;
                ts_saved_full = false;
                var i: u64 = 0;
                while (i < ts_append_max_calls) : (i += 1) {
                    appendOne(i) catch |err| {
                        ts_append_calls += 1;
                        recordErr(err);
                        if (err == error.SavedFull) ts_saved_full = true;
                        break;
                    };
                    ts_append_calls += 1;
                    recordOk();
                    ts_append_count += 1;
                }
            }

            fn bodyRollover() anyerror!void {
                const n: u64 = @as(u64, ts_capacity) * 3;
                ts_rollover_ok = 0;
                ts_rollover_calls = 0;
                for (0..n) |i| {
                    appendOne(i) catch |err| {
                        ts_rollover_calls += 1;
                        recordErr(err);
                        continue;
                    };
                    ts_rollover_calls += 1;
                    recordOk();
                    ts_rollover_ok += 1;
                }
            }

            fn iterateForward(res: *IterResult) anyerror!void {
                res.* = .{};
                var it = ts_db.iterator();
                while (try it.next()) |entry| {
                    res.count += 1;
                    res.sum_len += entry.len;
                }
            }

            fn iterateReverse(res: *IterResult) anyerror!void {
                res.* = .{};
                var it = ts_db.iteratorReverse();
                while (try it.next()) |entry| {
                    res.count += 1;
                    res.sum_len += entry.len;
                }
            }

            fn bodyIterFwd() anyerror!void {
                for (0..20) |_| {
                    var res = IterResult{};
                    try iterateForward(&res);
                    ts_iter_count = res.count;
                    ts_iter_sum = res.sum_len;
                }
            }

            fn bodyIterRev() anyerror!void {
                for (0..20) |_| {
                    var res = IterResult{};
                    try iterateReverse(&res);
                    ts_iter_count = res.count;
                    ts_iter_sum = res.sum_len;
                }
            }

            fn bodyByTime() anyerror!void {
                ts_range_total = 0;
                ts_range_payload = 0;
                var lcg = Lcg{};
                for (0..ts_range_queries) |q| {
                    const range = lcg.range();
                    var res = IterResult{};
                    var it = ts_db.iteratorByTime(range.from, range.to);
                    while (try it.next()) |entry| {
                        res.count += 1;
                        res.sum_len += entry.len;
                    }
                    ts_range_counts[q] = res.count;
                    ts_range_total += res.count;
                    ts_range_payload += res.sum_len;
                }
            }

            fn bodyQueryCount() anyerror!void {
                ts_range_total = 0;
                var lcg = Lcg{};
                for (0..ts_range_queries) |q| {
                    const range = lcg.range();
                    const count = try ts_db.queryCount(range.from, range.to, .write);
                    ts_range_counts[q] = count;
                    ts_range_total += count;
                }
            }

            fn bodyMountTs() anyerror!void {
                ts_mount_ok = 0;
                for (0..50) |_| {
                    ts_db.mount(ts_partition) catch |err| {
                        recordErr(err);
                        continue;
                    };
                    recordOk();
                    ts_mount_ok += 1;
                }
            }

            fn bodyClean() anyerror!void {
                ts_clean_appends = 0;
                for (0..20) |_| {
                    try ts_db.clean();
                    const p = populateFull(ts_append_max_calls);
                    requireSavedFull(p, "tsl_clean repopulate");
                    ts_clean_appends = p.appended;
                }
            }

            // ---- scenario runner (same order as bench_ts.c) --------------

            fn runAll(runs: usize) anyerror!void {
                if (want("tsl_append")) {
                    const r = newResult();
                    try measure(r, "tsl_append", runs, .{
                        .setup = setupAppend,
                        .body = bodyAppend,
                    });
                    const snap = try finishSnapshot(r);
                    r.extra.add("appended", .{ .uint = ts_append_count });
                    r.extra.add("append_calls", .{ .uint = ts_append_calls });
                    r.extra.add("saved_full", .{ .boolean = ts_saved_full });
                    finish(r, ts_append_count);
                    addTsNormalization(r, snap.count, true);
                    try addSnapshotParity(r);
                }

                if (want("tsl_append_rollover")) {
                    // Capacity probe: fill a scratch instance with rollover
                    // disabled and count the entries; the protocol defines the
                    // measured phase as 3 x that capacity (setup, untimed).
                    try setupFormat(false);
                    const probe = populateFull(ts_append_max_calls);
                    requireSavedFull(probe, "tsl_append_rollover capacity probe");
                    ts_capacity = @intCast(probe.appended);

                    const r = newResult();
                    try measure(r, "tsl_append_rollover", runs, .{
                        .setup = setupRollover,
                        .body = bodyRollover,
                    });
                    const snap = try finishSnapshot(r);
                    r.extra.add("capacity", .{ .uint = ts_capacity });
                    r.extra.add("appends_ok", .{ .uint = ts_rollover_ok });
                    r.extra.add("append_calls", .{ .uint = ts_rollover_calls });
                    finish(r, ts_rollover_calls);
                    addTsNormalization(r, snap.count, false);
                }

                if (want("tsl_iter_fwd")) {
                    const r = newResult();
                    try measure(r, "tsl_iter_fwd", runs, .{
                        .setup = setupPopulate,
                        .body = bodyIterFwd,
                    });
                    const snap = try finishSnapshot(r);
                    r.extra.add("entries_per_iter", .{ .uint = ts_iter_count });
                    r.extra.add("sum_payload_len_per_iter", .{ .uint = ts_iter_sum });
                    r.extra.add("populated", .{ .uint = ts_populated });
                    finish(r, 20);
                    addTsNormalization(r, snap.count, true);
                    try addSnapshotParity(r);
                }

                if (want("tsl_iter_rev")) {
                    const r = newResult();
                    try measure(r, "tsl_iter_rev", runs, .{
                        .setup = setupPopulate,
                        .body = bodyIterRev,
                    });
                    const snap = try finishSnapshot(r);
                    r.extra.add("entries_per_iter", .{ .uint = ts_iter_count });
                    r.extra.add("sum_payload_len_per_iter", .{ .uint = ts_iter_sum });
                    r.extra.add("populated", .{ .uint = ts_populated });
                    finish(r, 20);
                    addTsNormalization(r, snap.count, true);
                    try addSnapshotParity(r);
                }

                if (want("tsl_by_time")) {
                    const r = newResult();
                    try measure(r, "tsl_by_time", runs, .{
                        .setup = setupPopulate,
                        .body = bodyByTime,
                    });
                    r.checksum = rangeChecksum();
                    r.extra.add("queries", .{ .uint = ts_range_queries });
                    r.extra.add("sum_matches", .{ .uint = ts_range_total });
                    r.extra.add("sum_payload_len", .{ .uint = ts_range_payload });
                    r.extra.add("populated", .{ .uint = ts_populated });
                    r.extra.add("total_matches", .{ .uint = ts_range_total });
                    finish(r, ts_range_queries);
                    addTsNormalization(r, ts_populated, true);
                    try addRangeParity(r);
                }

                if (want("tsl_query_count")) {
                    const r = newResult();
                    try measure(r, "tsl_query_count", runs, .{
                        .setup = setupPopulate,
                        .body = bodyQueryCount,
                    });
                    r.checksum = rangeChecksum();
                    r.extra.add("queries", .{ .uint = ts_range_queries });
                    r.extra.add("sum_count", .{ .uint = ts_range_total });
                    r.extra.add("populated", .{ .uint = ts_populated });
                    r.extra.add("total_matches", .{ .uint = ts_range_total });
                    finish(r, ts_range_queries);
                    addTsNormalization(r, ts_populated, true);
                    try addRangeParity(r);
                }

                if (want("tsl_mount")) {
                    const r = newResult();
                    try measure(r, "tsl_mount", runs, .{
                        .setup = setupPopulate,
                        .after_setup = afterSetupMount,
                        .body = bodyMountTs,
                    });
                    r.checksum = ts_mount_checksum;
                    r.extra.add("mount_ok", .{ .uint = ts_mount_ok });
                    r.extra.add("populated", .{ .uint = ts_populated });
                    r.extra.add("checksum_from_pre_mount_state", .{ .boolean = true });
                    finish(r, 50);
                    addTsNormalization(r, ts_populated, true);
                    addSnapshotParityWith(r, ts_mount_prefix_checksum);
                }

                if (want("tsl_clean")) {
                    const r = newResult();
                    try measure(r, "tsl_clean", runs, .{
                        .setup = setupPopulate,
                        .body = bodyClean,
                    });
                    const snap = try finishSnapshot(r);
                    r.extra.add("cycles", .{ .uint = 20 });
                    r.extra.add("appends_per_cycle", .{ .uint = ts_clean_appends });
                    r.extra.add("populated", .{ .uint = ts_populated });
                    finish(r, 20);
                    addTsNormalization(r, snap.count, true);
                    try addSnapshotParity(r);
                }
            }

            // ---- self-checks (--mode check) ------------------------------

            fn runChecks() anyerror!void {
                try checkBasic();
                try checkFull();
                try checkRollover();
            }

            fn checkBasic() anyerror!void {
                try setupFormat(false);
                checkReport(!ts_db.getRollover(), "ts: rollover starts disabled (explicit)");

                var ok = true;
                for (0..10) |i| {
                    appendOne(i) catch {
                        ok = false;
                    };
                }
                checkReport(ok, "ts: 10 appends");
                checkU64("ts: lastTime after 10 appends", @intCast(ts_db.lastTime()), 1009);

                var prev: Ts.Time = 0;
                var have_prev = false;
                var ordered = true;
                var first: Ts.Time = 0;
                var last: Ts.Time = 0;
                var count: u32 = 0;
                var sum: u64 = 0;
                var it = ts_db.iterator();
                while (try it.next()) |entry| {
                    if (!have_prev) {
                        first = entry.time;
                    } else if (entry.time <= prev) {
                        ordered = false;
                    }
                    prev = entry.time;
                    have_prev = true;
                    last = entry.time;
                    count += 1;
                    sum += entry.len;
                }
                checkU64("ts: forward iterate count", count, 10);
                checkU64("ts: forward payload bytes", sum, 10 * ts_payload_len);
                checkReport(ordered, "ts: forward timestamps increase");
                checkU64("ts: first timestamp", @intCast(first), 1000);
                checkU64("ts: last timestamp", @intCast(last), 1009);

                var rev_ordered = true;
                var rev_prev: Ts.Time = 0;
                var rev_first = true;
                var rev_count: u32 = 0;
                var rit = ts_db.iteratorReverse();
                while (try rit.next()) |entry| {
                    if (!rev_first and entry.time >= rev_prev) rev_ordered = false;
                    rev_prev = entry.time;
                    rev_first = false;
                    rev_count += 1;
                }
                checkU64("ts: reverse iterate count", rev_count, 10);
                checkReport(rev_ordered, "ts: reverse timestamps decrease");

                checkU64("ts: queryCount(1000,1009,WRITE)", try ts_db.queryCount(1000, 1009, .write), 10);
                checkU64("ts: queryCount(1000,1004,WRITE)", try ts_db.queryCount(1000, 1004, .write), 5);

                const snap = try snapshot();
                checkU64("ts: snapshot count", snap.count, 10);
                checkU64("ts: snapshot payload bytes", snap.payload_bytes, 10 * ts_payload_len);

                var payload: [ts_payload_len]u8 = undefined;
                tsPayload(&payload, 11);
                const rejected = ts_db.append(1009, &payload);
                checkReport(rejected == error.TimeNotIncreasing, "ts: non-increasing timestamp rejected");
                checkU64("ts: rejected append not stored", try ts_db.count(), 10);

                try ts_db.clean();
                checkU64("ts: clean empties DB", try ts_db.count(), 0);
                for (0..3) |i| {
                    tsPayload(&payload, @intCast(i));
                    try ts_db.append(2000 + @as(Ts.Time, @intCast(i)), &payload);
                }
                checkU64("ts: append after clean", try ts_db.count(), 3);

                try ts_db.mount(ts_partition);
                checkU64("ts: remount keeps entries", try ts_db.count(), 3);
                try ts_db.check();
                checkReport(true, "ts: check() passes after remount");
                checkU64("ts: no NOR set-bit attempts", flash.stats.set_bit_attempts, 0);
                checkU64("ts: no out-of-bounds flash access", flash.stats.violations, 0);
            }

            fn checkFull() anyerror!void {
                try setupFormat(false);
                const max_count = ts_db.maxEntryCount();
                checkReport(max_count > 0, "ts: maxEntryCount positive");

                flash.resetStats();
                const p = populateFull(ts_append_max_calls);
                requireSavedFull(p, "ts: populate-to-full");
                checkReport(p.appended > 0, "ts: populated entries > 0");
                checkU64("ts: populated count matches maxEntryCount", p.appended, max_count);

                try ts_db.check();
                checkReport(true, "ts: check() passes on a full DB");

                const snap = try snapshot();
                checkU64("ts: full DB forward count", snap.count, p.appended);
                checkU64("ts: full DB payload bytes", snap.payload_bytes, p.appended * ts_payload_len);

                var rev_count: u32 = 0;
                var rit = ts_db.iteratorReverse();
                while (try rit.next()) |_| rev_count += 1;
                checkU64("ts: full DB reverse count", rev_count, p.appended);

                try ts_db.mount(ts_partition);
                checkU64("ts: remount keeps entries (full DB)", try ts_db.count(), p.appended);
                checkU64("ts: no NOR set-bit attempts (full DB)", flash.stats.set_bit_attempts, 0);
                checkU64("ts: no out-of-bounds access (full DB)", flash.stats.violations, 0);
            }

            fn checkRollover() anyerror!void {
                try setupFormat(true);
                checkReport(ts_db.getRollover(), "rollover: enabled");
                const cap = ts_db.maxEntryCount();
                checkReport(cap > 0, "rollover: capacity positive");

                flash.resetStats();
                const n: u64 = @as(u64, cap) * 2;
                var appended: u64 = 0;
                var ok = true;
                while (appended < n) : (appended += 1) {
                    appendOne(appended) catch {
                        ok = false;
                        break;
                    };
                }
                checkReport(ok and appended == n, "rollover: 2 x capacity appends succeed");
                checkReport(flash.stats.erases > 0, "rollover: full sectors erased while rolling");
                checkU64("rollover: entry count stays at capacity", try ts_db.count(), cap);
                try ts_db.check();
                checkReport(true, "rollover: check() passes after rollover");

                try ts_db.mount(ts_partition);
                checkU64("rollover: remount keeps capacity entries", try ts_db.count(), cap);
                checkU64("rollover: no NOR set-bit attempts", flash.stats.set_bit_attempts, 0);
                checkU64("rollover: no out-of-bounds access", flash.stats.violations, 0);
            }
        };
    };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

fn errPrintMain(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stderr().writeStreamingAll(g_main_io, s) catch {};
}

fn usage(argv0: []const u8) void {
    errPrintMain(
        \\usage: {s} [--mode bench|check] [--wg 8|1] [--runs N] [--out FILE] [--impl NAME] [--only NAME]
        \\
        \\  --mode bench   run the SCENARIOS.md scenarios and emit JSON (default)
        \\  --mode check   run behavioural invariant checks (exit != 0 on failure)
        \\  --wg 8|1       flash write granularity in bits (default 8)
        \\  --runs N       measured repetitions per scenario (default 5)
        \\  --out FILE     JSON output path (default bench/results/zig_wg<WG>_host.json)
        \\  --impl NAME    implementation name recorded in JSON (default "zig")
        \\  --only NAME    run a single scenario
        \\
    , .{argv0});
}

fn parseArgs(argv: []const [:0]const u8) !Options {
    var opts = Options{};
    var i: usize = 1; // argv[0] is the program name
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--wg")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.write_gran = std.fmt.parseInt(u16, argv[i], 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--runs")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.runs = std.fmt.parseInt(usize, argv[i], 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.out_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--impl")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.impl = argv[i];
        } else if (std.mem.eql(u8, arg, "--only")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            opts.only = argv[i];
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            if (std.mem.eql(u8, argv[i], "bench")) {
                opts.mode = .bench;
            } else if (std.mem.eql(u8, argv[i], "check")) {
                opts.mode = .check;
            } else {
                return error.BadValue;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownArgument;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) u8 {
    g_main_io = init.io;
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch {
        errPrintMain("flashdb-bench: cannot read the command line\n", .{});
        return 3;
    };
    const argv0: []const u8 = if (argv.len > 0) argv[0] else "flashdb-bench";

    var opts = parseArgs(argv) catch |err| switch (err) {
        error.HelpRequested => {
            usage(argv0);
            return 0;
        },
        else => {
            errPrintMain("flashdb-bench: bad command line ({t})\n", .{err});
            usage(argv0);
            return 2;
        },
    };

    if (opts.write_gran != 1 and opts.write_gran != 8) {
        errPrintMain("flashdb-bench: --wg must be 1 or 8 (got {d})\n", .{opts.write_gran});
        return 2;
    }
    if (opts.out_path.len == 0) {
        opts.out_path = std.fmt.bufPrint(&default_out_buf, "bench/results/zig_wg{d}_host.json", .{
            opts.write_gran,
        }) catch {
            errPrintMain("flashdb-bench: cannot build the default output path\n", .{});
            return 3;
        };
    }

    return switch (opts.write_gran) {
        1 => Harness(1).run(init, opts),
        8 => Harness(8).run(init, opts),
        else => unreachable,
    };
}
