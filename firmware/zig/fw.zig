//! Zig firmware measurement image -- shared workload implementation.
//!
//! This is the Zig counterpart of `firmware/c/main.c`: it runs the identical
//! deterministic workload from `firmware/common/workload_spec.h` on the Zig
//! FlashDB implementation (`src/flashdb.zig`) and prints the identical
//! single semihosting `RESULT ...` line through the *unmodified* C harness
//! helpers in `firmware/common/` (startup vector table, semihosting console,
//! cycle counter, stack painting, linker script).
//!
//! Fairness: everything under `firmware/common/` (and `firmware/c/libc_stubs.c`
//! for the freestanding mem* baseline) is compiled from the same unmodified C
//! sources for both images; only the workload + database code is Zig.  The C
//! harness functions are reached through `extern` declarations that match
//! `firmware/common/*.h` byte for byte.
//!
//! The two root files `main.zig` (plain) and `main_instrumented.zig` /
//! `main_cycles.zig` / `main_phases.zig` (instrumented, mirroring the C
//! `-DFW_CYCLES=1 -DHARNESS_STACK_PHASES=1` variants) instantiate this module
//! with the matching `Options` and export `main`.

const std = @import("std");
const flashdb = @import("flashdb");

pub const Options = struct {
    /// `-DFW_CYCLES=1` on the C side (DWT / SysTick-proxy cycle counters).
    cycles: bool = false,
    /// `-DHARNESS_STACK_PHASES=1` on the C side (per-phase stack repaints and
    /// per-phase cycle deltas).
    phases: bool = false,
};

// ---------------------------------------------------------------------------
// Workload constants -- mirror firmware/common/workload_spec.h exactly.
// ---------------------------------------------------------------------------

/// Number of distinct keys initially written with set().
pub const HW_KV_KEYS: u32 = 64;
/// Of those, how many get a second (updated) value.
pub const HW_KV_UPDATES: u32 = 32;
/// Rewrites used to force sector GC churn; cycles over HW_KV_CHURN_KEYS keys.
pub const HW_KV_CHURN: u32 = 1500;
pub const HW_KV_CHURN_KEYS: u32 = 16;
/// String value length (excluding NUL) of every KV value.
pub const HW_KV_VALUE_LEN: u32 = 24;

pub const HW_TS_APPENDS: u32 = 200;
pub const HW_TS_PAYLOAD_LEN: u32 = 16;
pub const HW_TS_BASE_TIME: u32 = 1000;

pub const HW_SIM_FLASH_LEN: u32 = 32 * 1024;
pub const HW_SIM_FLASH_BLK_SIZE: u32 = 4 * 1024;
pub const HW_KVDB_PART_OFFSET: u32 = 0;
pub const HW_KVDB_PART_LEN: u32 = 16 * 1024;
pub const HW_TSDB_PART_OFFSET: u32 = 16 * 1024;
pub const HW_TSDB_PART_LEN: u32 = 16 * 1024;
pub const HW_TSDB_MAX_LEN: u32 = 64;

// ---------------------------------------------------------------------------
// C harness ABI (unmodified firmware/common/{semihost,stack,cycles}.{c,h}).
// ---------------------------------------------------------------------------

pub const c = struct {
    pub extern fn harness_fill_section_sizes(m: *anyopaque) void;
    pub extern fn harness_print_result(m: *const anyopaque) void;
    pub extern fn harness_fail(stage: [*:0]const u8, code: c_int) noreturn;
    pub extern fn harness_exit() noreturn;

    pub extern fn stack_limit_bytes() u32;
    pub extern fn stack_high_water_bytes() u32;
    /// Only present in the C link when HARNESS_STACK_PHASES is defined.
    pub extern fn stack_repaint() void;

    pub extern fn cycles_init() u32;
    pub extern fn cycles_now() u32;
    pub extern fn cycles_delta(earlier: u32, later: u32) u32;
    pub extern fn cycles_tick_hz() u32;
    pub extern fn cycles_spin_insn() u32;
    pub extern fn cycles_spin_ticks() u32;
};

// ---------------------------------------------------------------------------
// `struct harness_metrics` layouts, field for field from semihost.h.
// ---------------------------------------------------------------------------

const MetricsPlain = extern struct {
    text: u32,
    rodata: u32,
    data: u32,
    bss: u32,
    sim_flash: u32,
    stack: u32,
    stack_init: u32,
    stack_limit: u32,
    kv_writes: u32,
    kv_gets: u32,
    kv_iterated: u32,
    kv_checksum: u32,
    kv_iter_checksum: u32,
    ts_appends: u32,
    ts_iterated: u32,
    ts_checksum: u32,
};

const MetricsPhases = extern struct {
    text: u32,
    rodata: u32,
    data: u32,
    bss: u32,
    sim_flash: u32,
    stack: u32,
    stack_init: u32,
    stack_limit: u32,
    st_set: u32,
    st_get: u32,
    st_iter: u32,
    st_gc: u32,
    st_ts_append: u32,
    st_ts_iter: u32,
    kv_writes: u32,
    kv_gets: u32,
    kv_iterated: u32,
    kv_checksum: u32,
    kv_iter_checksum: u32,
    ts_appends: u32,
    ts_iterated: u32,
    ts_checksum: u32,
};

const MetricsCycles = extern struct {
    text: u32,
    rodata: u32,
    data: u32,
    bss: u32,
    sim_flash: u32,
    stack: u32,
    stack_init: u32,
    stack_limit: u32,
    kv_writes: u32,
    kv_gets: u32,
    kv_iterated: u32,
    kv_checksum: u32,
    kv_iter_checksum: u32,
    ts_appends: u32,
    ts_iterated: u32,
    ts_checksum: u32,
    cycles_src: u32,
    cycles_total: u32,
    cycles_mount: u32,
    cycles_kv: u32,
    cycles_ts: u32,
    cycles_tick_hz: u32,
    cycles_spin_insn: u32,
    cycles_spin_ticks: u32,
};

const MetricsFull = extern struct {
    text: u32,
    rodata: u32,
    data: u32,
    bss: u32,
    sim_flash: u32,
    stack: u32,
    stack_init: u32,
    stack_limit: u32,
    st_set: u32,
    st_get: u32,
    st_iter: u32,
    st_gc: u32,
    st_ts_append: u32,
    st_ts_iter: u32,
    kv_writes: u32,
    kv_gets: u32,
    kv_iterated: u32,
    kv_checksum: u32,
    kv_iter_checksum: u32,
    ts_appends: u32,
    ts_iterated: u32,
    ts_checksum: u32,
    cycles_src: u32,
    cycles_total: u32,
    cycles_mount: u32,
    cycles_kv: u32,
    cycles_ts: u32,
    cycles_tick_hz: u32,
    cycles_spin_insn: u32,
    cycles_spin_ticks: u32,
    cyc_st_set: u32,
    cyc_st_get: u32,
    cyc_st_iter: u32,
    cyc_st_gc: u32,
    cyc_st_ts_append: u32,
    cyc_st_ts_iter: u32,
};

fn MetricsType(comptime opts: Options) type {
    if (opts.cycles and opts.phases) return MetricsFull;
    if (opts.cycles) return MetricsCycles;
    if (opts.phases) return MetricsPhases;
    return MetricsPlain;
}

fn hasCycles(comptime M: type) bool {
    return @hasField(M, "cycles_src");
}

fn hasPhases(comptime M: type) bool {
    return @hasField(M, "st_set");
}

// ---------------------------------------------------------------------------
// Deterministic data generation (byte-for-byte identical to firmware/c/main.c).
// ---------------------------------------------------------------------------

const k_hex = "0123456789abcdef";

fn makeKvKey(out: *[8]u8, idx: u32) void {
    out[0] = 'k';
    out[1] = 'v';
    out[2] = '.';
    out[3] = k_hex[@intCast((idx >> 4) & 0xf)];
    out[4] = k_hex[@intCast(idx & 0xf)];
    out[5] = 0;
}

fn makeKvValue(out: *[HW_KV_VALUE_LEN + 1]u8, idx: u32, gen: u32) void {
    out[0] = 'v';
    out[1] = k_hex[@intCast((gen >> 12) & 0xf)];
    out[2] = k_hex[@intCast((gen >> 8) & 0xf)];
    out[3] = k_hex[@intCast((gen >> 4) & 0xf)];
    out[4] = k_hex[@intCast(gen & 0xf)];
    out[5] = '-';
    out[6] = k_hex[@intCast((idx >> 4) & 0xf)];
    out[7] = k_hex[@intCast(idx & 0xf)];
    out[8] = '-';
    var k: u32 = 9;
    while (k < HW_KV_VALUE_LEN) : (k += 1) {
        out[k] = k_hex[@intCast((idx * 7 + gen * 13 + k) & 0xf)];
    }
    out[HW_KV_VALUE_LEN] = 0;
}

/// Little-endian encoding, mirrored byte-for-byte by firmware/c/main.c.
fn makeTsPayload(out: *[HW_TS_PAYLOAD_LEN]u8, idx: u32) void {
    const tick = HW_TS_BASE_TIME + idx;
    out[0] = @truncate(idx);
    out[1] = @truncate(idx >> 8);
    out[2] = @truncate(idx >> 16);
    out[3] = @truncate(idx >> 24);
    out[4] = @truncate(tick);
    out[5] = @truncate(tick >> 8);
    out[6] = @truncate(tick >> 16);
    out[7] = @truncate(tick >> 24);
    var k: u32 = 8;
    while (k < HW_TS_PAYLOAD_LEN) : (k += 1) {
        out[k] = @truncate(idx * 31 + k * 7);
    }
}

fn fnv1a(h0: u32, data: []const u8) u32 {
    var h = h0;
    for (data) |b| {
        h ^= b;
        h *%= 16777619;
    }
    return h;
}

fn fail(stage: [*:0]const u8) noreturn {
    c.harness_fail(stage, -1);
}

fn failCode(stage: [*:0]const u8, code: u32) noreturn {
    c.harness_fail(stage, @intCast(code & 0x7fff));
}

// ---------------------------------------------------------------------------
// Static storage: one simulated NOR device, two partitions (KV @ 0, TS @ 16K).
// The 32 KiB backing store lives in the NOLOAD .sim_flash region defined by the
// shared linker script, exactly like firmware/c/fal_ram_sim.c, so it is not
// counted as MCU static RAM.
// ---------------------------------------------------------------------------

const Flash = flashdb.sim.RamFlash(.{ .write_gran_bits = 8, .block_size = HW_SIM_FLASH_BLK_SIZE });
const Part = flashdb.flash.Partition(Flash);
const Kv = flashdb.Kvdb(Part, .{ .sector_size = HW_SIM_FLASH_BLK_SIZE, .sector_count = 4 });

/// The TSDB workload is enabled as soon as the library exports `flashdb.Tsdb`.
/// Until then (phase 1) the firmware reports an empty TS database and the
/// root files/scripts expect `ts_appends=0 ts_iterated=0 ts_checksum=0`.
const ts_ready = @hasDecl(flashdb, "Tsdb");
const Ts = if (ts_ready)
    flashdb.Tsdb(Part, .{
        .sector_size = HW_SIM_FLASH_BLK_SIZE,
        .sector_count = 4,
        .ts_bits = 32,
        .max_len = @intCast(HW_TSDB_MAX_LEN),
    })
else
    TsStub;

var g_sim_flash: [HW_SIM_FLASH_LEN]u8 align(HW_SIM_FLASH_BLK_SIZE) linksection(".sim_flash") = undefined;
var g_flash: Flash = undefined;
var g_kvdb: Kv = undefined;
var g_tsdb: Ts = undefined;

/// Cycle-counter snapshot shared between measured phases (C uses a local in
/// main(); a global keeps the two instrumentation variants comptime-clean).
var g_cyc_t0: u32 = 0;

/// Placeholder for `flashdb.Tsdb` until the TSDB is exported by the library:
/// phase 1 reports the TS fields as 0, i.e. an empty database.
const TsStub = struct {};

// ---------------------------------------------------------------------------
// Database initialisation
// ---------------------------------------------------------------------------

fn databasesInit() void {
    g_flash = Flash.init(&g_sim_flash);
    // Factory-fresh NOR: the whole device starts erased (like fal_init()).
    g_flash.eraseAll();

    const kv_part = Part{
        .dev = &g_flash,
        .offset = HW_KVDB_PART_OFFSET,
        .len = HW_KVDB_PART_LEN,
    };
    g_kvdb.mount(kv_part) catch fail("kvdb_init");

    if (comptime ts_ready) {
        const ts_part = Part{
            .dev = &g_flash,
            .offset = HW_TSDB_PART_OFFSET,
            .len = HW_TSDB_PART_LEN,
        };
        g_tsdb.mount(ts_part) catch fail("tsdb_init");
    }
}

// ---------------------------------------------------------------------------
// KVDB phase (identical operation sequence to firmware/c/main.c)
// ---------------------------------------------------------------------------

fn kvdbPhase(m: anytype) void {
    var key: [8]u8 = undefined;
    var value: [HW_KV_VALUE_LEN + 1]u8 = undefined;
    var read_buf: [HW_KV_VALUE_LEN + 1]u8 = undefined;
    var iter_buf: [HW_KV_VALUE_LEN + 1]u8 = undefined;

    // 1. initial set of all keys
    var i: u32 = 0;
    while (i < HW_KV_KEYS) : (i += 1) {
        makeKvKey(&key, i);
        makeKvValue(&value, i, 0);
        g_kvdb.set(key[0..5], value[0..HW_KV_VALUE_LEN]) catch fail("kv_set");
        m.kv_writes += 1;
    }

    // 2. update half of them
    i = 0;
    while (i < HW_KV_UPDATES) : (i += 1) {
        makeKvKey(&key, i);
        makeKvValue(&value, i, 1);
        g_kvdb.set(key[0..5], value[0..HW_KV_VALUE_LEN]) catch fail("kv_update");
        m.kv_writes += 1;
    }

    // 3. GC churn: rewrite a small key set many times so the KVDB has to erase
    //    and migrate sectors (forces several GC cycles).
    var n: u32 = 0;
    while (n < HW_KV_CHURN) : (n += 1) {
        const idx = n % HW_KV_CHURN_KEYS;
        makeKvKey(&key, idx);
        makeKvValue(&value, idx, 2 + n);
        g_kvdb.set(key[0..5], value[0..HW_KV_VALUE_LEN]) catch fail("kv_churn");
        m.kv_writes += 1;
    }

    // 4. get every key and verify its final content
    i = 0;
    while (i < HW_KV_KEYS) : (i += 1) {
        const expect_gen: u32 = blk: {
            if (i < HW_KV_CHURN_KEYS) {
                // Last churn iteration that touched key i: n = i + 16 * k with
                // n the largest value < HW_KV_CHURN (HW_KV_CHURN is not assumed
                // to be a multiple of HW_KV_CHURN_KEYS).
                const last_n = (HW_KV_CHURN - 1) - ((HW_KV_CHURN - 1 - i) % HW_KV_CHURN_KEYS);
                break :blk 2 + last_n;
            } else if (i < HW_KV_UPDATES) {
                break :blk 1;
            } else {
                break :blk 0;
            }
        };
        makeKvKey(&key, i);
        makeKvValue(&value, i, expect_gen);

        const got = g_kvdb.get(key[0..5], read_buf[0..HW_KV_VALUE_LEN]) catch fail("kv_get");
        const n_got = got orelse failCode("kv_get_missing", i);
        if (n_got != HW_KV_VALUE_LEN) failCode("kv_get_len", n_got);
        if (!std.mem.eql(u8, read_buf[0..HW_KV_VALUE_LEN], value[0..HW_KV_VALUE_LEN]))
            failCode("kv_get_data", i);
        m.kv_gets += 1;
        m.kv_checksum = fnv1a(m.kv_checksum, read_buf[0..n_got]);
    }

    // 5. iterate the whole database (walks sector metadata, not point lookups)
    var it = g_kvdb.iterator();
    while (true) {
        const maybe = it.next() catch fail("kv_iter");
        const entry = maybe orelse break;
        const got = it.readValue(iter_buf[0..(HW_KV_VALUE_LEN + 1)], entry) catch fail("kv_iter_read");
        if (got > (HW_KV_VALUE_LEN + 1)) failCode("kv_iter_len", got);
        m.kv_iterated += 1;
        m.kv_iter_checksum = fnv1a(m.kv_iter_checksum, entry.name);
        m.kv_iter_checksum = fnv1a(m.kv_iter_checksum, iter_buf[0..got]);
    }

    if (m.kv_iterated != HW_KV_KEYS) failCode("kv_iter_count", m.kv_iterated);
}

// ---------------------------------------------------------------------------
// TSDB phase (identical operation sequence to firmware/c/main.c)
// ---------------------------------------------------------------------------

fn tsdbPhase(m: anytype) void {
    if (comptime !ts_ready) {
        // Phase 1: the library does not export `flashdb.Tsdb` yet, so the TS
        // database is empty and the reported fields stay 0.
        return;
    }

    var payload: [HW_TS_PAYLOAD_LEN]u8 = undefined;
    var i: u32 = 0;
    while (i < HW_TS_APPENDS) : (i += 1) {
        makeTsPayload(&payload, i);
        g_tsdb.append(@intCast(HW_TS_BASE_TIME + i), payload[0..HW_TS_PAYLOAD_LEN]) catch fail("ts_append");
        m.ts_appends += 1;
    }

    // Iterate every log entry and checksum the payloads (forward order).
    var buf: [HW_TS_PAYLOAD_LEN]u8 = @splat(0);
    var count: u32 = 0;
    var checksum: u32 = 0;
    var bad: u32 = 0;
    var it = g_tsdb.iterator();
    while (true) {
        const maybe = it.next() catch fail("ts_iter");
        const entry = maybe orelse break;
        const got = it.readPayload(&buf, entry) catch {
            bad += 1;
            continue;
        };
        if (got != HW_TS_PAYLOAD_LEN) {
            bad += 1;
            continue;
        }
        count += 1;
        checksum = fnv1a(checksum, buf[0..got]);
    }

    if (bad != 0) failCode("ts_iter_read", bad);
    if (count != HW_TS_APPENDS) failCode("ts_iter_count", count);
    m.ts_iterated = count;
    m.ts_checksum = checksum;
}

// ---------------------------------------------------------------------------
// Per-phase stack/cycle attribution (instrumented variant only)
// ---------------------------------------------------------------------------

fn stackDiagnostics(m: anytype) void {
    const M = @TypeOf(m.*);
    var key: [8]u8 = undefined;
    var value: [HW_KV_VALUE_LEN + 1]u8 = undefined;
    var read_buf: [HW_KV_VALUE_LEN + 1]u8 = undefined;
    var iter_buf: [HW_KV_VALUE_LEN + 1]u8 = undefined;
    var c0: u32 = 0;

    // (b) one set
    c.stack_repaint();
    if (comptime hasCycles(M)) c0 = c.cycles_now();
    makeKvKey(&key, 0);
    makeKvValue(&value, 0, 0x3000);
    g_kvdb.set(key[0..5], value[0..HW_KV_VALUE_LEN]) catch fail("st_set");
    m.st_set = c.stack_high_water_bytes();
    if (comptime hasCycles(M)) m.cyc_st_set = c.cycles_delta(c0, c.cycles_now());

    // (c) one get
    c.stack_repaint();
    if (comptime hasCycles(M)) c0 = c.cycles_now();
    _ = (g_kvdb.get(key[0..5], read_buf[0..HW_KV_VALUE_LEN]) catch fail("st_get")) orelse fail("st_get_missing");
    m.st_get = c.stack_high_water_bytes();
    if (comptime hasCycles(M)) m.cyc_st_get = c.cycles_delta(c0, c.cycles_now());

    // (d) full iteration
    c.stack_repaint();
    if (comptime hasCycles(M)) c0 = c.cycles_now();
    var it = g_kvdb.iterator();
    var n: u32 = 0;
    while (true) {
        const maybe = it.next() catch fail("st_iter");
        const entry = maybe orelse break;
        const got = it.readValue(iter_buf[0..(HW_KV_VALUE_LEN + 1)], entry) catch fail("st_iter_read");
        if (got > (HW_KV_VALUE_LEN + 1)) failCode("st_iter_len", got);
        n += 1;
    }
    if (n != HW_KV_KEYS) failCode("st_iter_count", n);
    m.st_iter = c.stack_high_water_bytes();
    if (comptime hasCycles(M)) m.cyc_st_iter = c.cycles_delta(c0, c.cycles_now());

    // (e) GC churn (same write pattern as the measured workload)
    c.stack_repaint();
    if (comptime hasCycles(M)) c0 = c.cycles_now();
    n = 0;
    while (n < HW_KV_CHURN) : (n += 1) {
        const idx = n % HW_KV_CHURN_KEYS;
        makeKvKey(&key, idx);
        makeKvValue(&value, idx, 0x4000 + n);
        g_kvdb.set(key[0..5], value[0..HW_KV_VALUE_LEN]) catch fail("st_gc");
    }
    m.st_gc = c.stack_high_water_bytes();
    if (comptime hasCycles(M)) m.cyc_st_gc = c.cycles_delta(c0, c.cycles_now());

    // (f) one TSDB append, (g) full TSDB iteration.  The TS database already
    //     holds the 200 workload records; the diagnostic append uses the next
    //     timestamp, so the iteration sees 201 entries.
    if (comptime ts_ready) {
        var ts_payload: [HW_TS_PAYLOAD_LEN]u8 = undefined;
        var ts_buf: [HW_TS_PAYLOAD_LEN]u8 = @splat(0);
        var ts_count: u32 = 0;
        var ts_bad: u32 = 0;

        c.stack_repaint();
        if (comptime hasCycles(M)) c0 = c.cycles_now();
        makeTsPayload(&ts_payload, HW_TS_APPENDS);
        g_tsdb.append(@intCast(HW_TS_BASE_TIME + HW_TS_APPENDS), ts_payload[0..HW_TS_PAYLOAD_LEN]) catch fail("st_ts_append");
        m.st_ts_append = c.stack_high_water_bytes();
        if (comptime hasCycles(M)) m.cyc_st_ts_append = c.cycles_delta(c0, c.cycles_now());

        c.stack_repaint();
        if (comptime hasCycles(M)) c0 = c.cycles_now();
        var ts_it = g_tsdb.iterator();
        while (true) {
            const maybe = ts_it.next() catch fail("st_ts_iter");
            const entry = maybe orelse break;
            const got = ts_it.readPayload(&ts_buf, entry) catch {
                ts_bad += 1;
                continue;
            };
            if (got != HW_TS_PAYLOAD_LEN) {
                ts_bad += 1;
                continue;
            }
            ts_count += 1;
        }
        if (ts_bad != 0) failCode("st_ts_iter_read", ts_bad);
        if (ts_count != HW_TS_APPENDS + 1) failCode("st_ts_iter_count", ts_count);
        m.st_ts_iter = c.stack_high_water_bytes();
        if (comptime hasCycles(M)) m.cyc_st_ts_iter = c.cycles_delta(c0, c.cycles_now());
    }
}

// ---------------------------------------------------------------------------
// Entry point (called by the shared Reset_Handler via `bl main`)
// ---------------------------------------------------------------------------

pub fn run(comptime opts: Options) noreturn {
    const M = MetricsType(opts);
    var m: M = std.mem.zeroes(M);
    c.harness_fill_section_sizes(&m);
    m.stack_limit = c.stack_limit_bytes();

    if (comptime opts.cycles) {
        // Probe DWT / fall back to the SysTick proxy BEFORE the first phase so
        // the probe's own instructions are not charged to the workload.
        m.cycles_src = c.cycles_init();
        m.cycles_tick_hz = c.cycles_tick_hz();
        m.cycles_spin_insn = c.cycles_spin_insn();
        m.cycles_spin_ticks = c.cycles_spin_ticks();
        g_cyc_t0 = c.cycles_now();
    }

    databasesInit();

    if (comptime opts.cycles) {
        m.cycles_mount = c.cycles_delta(g_cyc_t0, c.cycles_now());
        g_cyc_t0 = c.cycles_now();
    }

    // High-water reached by database init, before the workload starts.
    m.stack_init = c.stack_high_water_bytes();

    kvdbPhase(&m);

    if (comptime opts.cycles) {
        m.cycles_kv = c.cycles_delta(g_cyc_t0, c.cycles_now());
        g_cyc_t0 = c.cycles_now();
    }

    tsdbPhase(&m);

    if (comptime opts.cycles) {
        m.cycles_ts = c.cycles_delta(g_cyc_t0, c.cycles_now());
        m.cycles_total = m.cycles_mount + m.cycles_kv + m.cycles_ts;
    }

    // Final scan after both phases have returned to this shallow frame.
    m.stack = c.stack_high_water_bytes();

    if (comptime opts.phases) stackDiagnostics(&m);

    c.harness_print_result(&m);
    c.harness_exit();
}
