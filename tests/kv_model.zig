//! Model-based randomized differential tests for `flashdb.Kvdb`.
//!
//! Each configuration below gets its own comptime instantiation of the KVDB on a
//! RAM NOR simulator plus an independent in-memory reference model. Random
//! operation streams (set / delete / get / contains / count / iterate / check /
//! remount / formatAll / autoUpdate) keep flash and model in lock step, and the
//! model is bounded so it never exceeds the capacity of the configuration.
//!
//! The second half of the file replays single operations with a power cut after
//! every mutating flash access and checks the mount-time invariants: `check()`
//! passes, every key reads back either its pre-operation or its post-operation
//! value, unrelated keys are untouched, and the recovery path never programs a
//! non-erased granule.
//!
//! Run standalone (the `flashdb` module is the library root, `src/flashdb.zig`;
//! Zig 0.18 rejects `@import("../src/...")` because the module root of
//! `tests/kv_model.zig` is `tests/`):
//!
//!     .tools\zig\zig.exe test --dep flashdb -Mroot=tests\kv_model.zig -Mflashdb=src\flashdb.zig
//!
//! Inside `zig build test` the same `@import("flashdb")` resolves through the
//! module import table set up by `build.zig`.
//!
//! The configuration and seed are printed before every stream; every mismatch
//! prints config / seed / op index / key / expected / actual / flash image hash,
//! so a failure is reproducible by rerunning this file unchanged.

const std = @import("std");
const flashdb = @import("flashdb");
const format = flashdb.format;
const sim = flashdb.sim;

// ---------------------------------------------------------------------------
// Configurations under test.
//
// Write granularities 1/8/32/64/128/256 bit, sector sizes 1024 and 4096,
// sector counts 3/4/8 (plus one 80 KiB partition to exercise the u32 address
// path), cache sizes 0/8/64 and name limits 16/64.
// ---------------------------------------------------------------------------

const Spec = struct {
    wg_bits: u16,
    sector_size: u32,
    sector_count: u16,
    cache_entries: u16,
    max_name_len: u16,
    ops: u16,
    chunk_size: u16 = 64,
    seed: u64,
};

const specs = [_]Spec{
    // 1-byte granule, tiny sectors, cache disabled.
    .{ .wg_bits = 8, .sector_size = 1024, .sector_count = 3, .cache_entries = 0, .max_name_len = 16, .ops = 300, .seed = 0xA1A1_0001_0000_0001 },
    // 1-bit granule.
    .{ .wg_bits = 1, .sector_size = 4096, .sector_count = 4, .cache_entries = 8, .max_name_len = 16, .ops = 250, .seed = 0xA2A2_0002_0000_0002 },
    // 4-byte granule, tiny sectors.
    .{ .wg_bits = 32, .sector_size = 1024, .sector_count = 4, .cache_entries = 8, .max_name_len = 16, .ops = 300, .seed = 0xA3A3_0003_0000_0003 },
    // 8-byte granule, full name cache, long keys.
    .{ .wg_bits = 64, .sector_size = 4096, .sector_count = 4, .cache_entries = 64, .max_name_len = 64, .ops = 250, .seed = 0xA4A4_0004_0000_0004 },
    // 16-byte granule, eight tiny sectors.
    .{ .wg_bits = 128, .sector_size = 1024, .sector_count = 8, .cache_entries = 0, .max_name_len = 64, .ops = 300, .seed = 0xA5A5_0005_0000_0005 },
    // 32-byte granule, three sectors (GC pressure).
    .{ .wg_bits = 256, .sector_size = 4096, .sector_count = 3, .cache_entries = 8, .max_name_len = 16, .ops = 250, .seed = 0xA6A6_0006_0000_0006 },
    // 4-byte granule, eight sectors, long keys, full cache.
    .{ .wg_bits = 32, .sector_size = 4096, .sector_count = 8, .cache_entries = 64, .max_name_len = 64, .ops = 250, .seed = 0xA7A7_0007_0000_0007 },
    // 80 KiB partition: total_size > 0xFFFF -> u32 addresses.
    .{ .wg_bits = 8, .sector_size = 4096, .sector_count = 20, .cache_entries = 64, .max_name_len = 64, .ops = 1400, .seed = 0xA8A8_0008_0000_0008 },
    // 16-byte granule, three 4 KiB sectors (GC pressure, byte loop).
    .{ .wg_bits = 128, .sector_size = 4096, .sector_count = 3, .cache_entries = 0, .max_name_len = 16, .ops = 250, .seed = 0xA9A9_0009_0000_0009 },
    // 1-bit granule, tiny sectors, long keys.
    .{ .wg_bits = 1, .sector_size = 1024, .sector_count = 8, .cache_entries = 8, .max_name_len = 64, .ops = 300, .seed = 0xAAAA_000A_0000_000A },
};

fn FlashOf(comptime s: Spec) type {
    return sim.RamFlash(.{ .write_gran_bits = s.wg_bits, .block_size = s.sector_size });
}

/// Configuration of the > 64 KiB partition (u32 address) boundary test.
const u32_spec = Spec{
    .wg_bits = 8,
    .sector_size = 4096,
    .sector_count = 20,
    .cache_entries = 64,
    .max_name_len = 64,
    .ops = 0,
    .seed = 0,
};

fn DbOf(comptime s: Spec) type {
    return flashdb.Kvdb(FlashOf(s), .{
        .sector_size = s.sector_size,
        .sector_count = s.sector_count,
        .max_name_len = s.max_name_len,
        .cache_entries = s.cache_entries,
        .chunk_size = s.chunk_size,
    });
}

fn labelOf(comptime s: Spec) []const u8 {
    return std.fmt.comptimePrint(
        "wg{d}/sec{d}x{d}/cache{d}/name{d}",
        .{ s.wg_bits, s.sector_size, s.sector_count, s.cache_entries, s.max_name_len },
    );
}

// ---------------------------------------------------------------------------
// Reference model.
//
// A fixed table of key/value slots. Slot keys are unique across the table (a
// set always reuses the slot that already holds the key), so `find` addresses at
// most one slot. The model tracks the on-flash footprint of the live records and
// refuses to grow past half a sector of live data, which leaves the library
// enough room to move every live record during GC.
// ---------------------------------------------------------------------------

fn ModelOf(comptime s: Spec) type {
    const F = FlashOf(s);
    const g: usize = flashdb.flash.granBytes(F);
    const L = format.KvLayout(g, s.sector_size > 0xFFFF);
    const data_off: usize = L.data_off;
    const usable: usize = @as(usize, s.sector_size) - data_off;
    const mdl_budget: usize = usable / 2;
    const overhead: usize = L.valueOff(s.max_name_len);
    const mdl_max_keys: usize = @max(2, @min(8, mdl_budget / (overhead + 8)));
    const mdl_max_val: usize = @max(1, @min(160, (mdl_budget / mdl_max_keys) -| overhead));
    const mdl_max_name: usize = s.max_name_len;
    const mdl_flash_len: usize = @as(usize, s.sector_size) * s.sector_count;
    const max_rec: usize = @as(usize, s.sector_size) - data_off;

    comptime {
        if (L.recordLen(mdl_max_name, mdl_max_val) > max_rec)
            @compileError("kv_model: capped value does not fit in a sector record");
        if (mdl_max_val < 4)
            @compileError("kv_model: the model needs at least a 4-byte value to model __ver_num__");
        if (mdl_max_name < 11)
            @compileError("kv_model: max_name_len must hold \"__ver_num__\"");
    }

    return struct {
        const Self = @This();

        pub const max_name = mdl_max_name;
        pub const max_keys = mdl_max_keys;
        pub const max_val = mdl_max_val;
        pub const budget = mdl_budget;
        pub const flash_len = mdl_flash_len;

        pub fn recordLen(key_len: usize, val_len: usize) usize {
            return L.recordLen(key_len, val_len);
        }

        pub fn valueOff(key_len: usize) usize {
            return L.valueOff(key_len);
        }

        const Slot = struct {
            key: [max_name]u8 = undefined,
            key_len: usize = 0,
            val: [max_val]u8 = undefined,
            val_len: usize = 0,
            live: bool = false,
        };

        slots: [max_keys]Slot = undefined,
        count: usize = 0,
        footprint: usize = 0,

        fn init() Self {
            var m: Self = undefined;
            for (&m.slots) |*sl| {
                sl.key_len = 0;
                sl.val_len = 0;
                sl.live = false;
            }
            m.count = 0;
            m.footprint = 0;
            return m;
        }

        fn find(self: *const Self, key: []const u8) ?usize {
            for (&self.slots, 0..) |*sl, i| {
                if (sl.key_len == key.len and std.mem.eql(u8, sl.key[0..sl.key_len], key)) return i;
            }
            return null;
        }

        fn findLive(self: *const Self, key: []const u8) ?usize {
            const idx = self.find(key) orelse return null;
            return if (self.slots[idx].live) idx else null;
        }

        fn findFree(self: *const Self) ?usize {
            for (&self.slots, 0..) |*sl, i| {
                if (!sl.live) return i;
            }
            return null;
        }

        fn setSlot(self: *Self, idx: usize, key: []const u8, val: []const u8) void {
            std.debug.assert(key.len >= 1 and key.len <= max_name);
            std.debug.assert(val.len <= max_val);
            const sl = &self.slots[idx];
            const old: usize = if (sl.live) L.recordLen(sl.key_len, sl.val_len) else 0;
            @memcpy(sl.key[0..key.len], key);
            sl.key_len = key.len;
            @memcpy(sl.val[0..val.len], val);
            sl.val_len = val.len;
            if (!sl.live) {
                sl.live = true;
                self.count += 1;
            }
            self.footprint = self.footprint - old + L.recordLen(key.len, val.len);
        }

        fn removeSlot(self: *Self, idx: usize) void {
            const sl = &self.slots[idx];
            if (!sl.live) return;
            self.footprint -= L.recordLen(sl.key_len, sl.val_len);
            self.count -= 1;
            sl.live = false;
            sl.val_len = 0;
        }

        fn clear(self: *Self) void {
            for (&self.slots) |*sl| {
                sl.live = false;
                sl.key_len = 0;
                sl.val_len = 0;
            }
            self.count = 0;
            self.footprint = 0;
        }

        /// Insert-or-overwrite without capacity checks (used for the post-op model
        /// of a fault sweep, where the flash operation already succeeded).
        fn setKey(self: *Self, key: []const u8, val: []const u8) bool {
            if (self.find(key)) |idx| {
                self.setSlot(idx, key, val);
                return true;
            }
            const idx = self.findFree() orelse return false;
            self.setSlot(idx, key, val);
            return true;
        }

        fn storedVersion(self: *const Self) u32 {
            const idx = self.findLive("__ver_num__") orelse return 0;
            const sl = &self.slots[idx];
            if (sl.val_len != 4) return 0;
            return format.rd32(sl.val[0..].ptr);
        }

        /// Mirror of `Kvdb.autoUpdate`: create missing defaults, then store the
        /// version key. Returns false when the model would exceed its budget, in
        /// which case nothing should be issued to the database.
        fn applyAutoUpdate(
            self: *Self,
            version: u32,
            keys: []const []const u8,
            vals: []const []const u8,
        ) bool {
            if (self.storedVersion() == version) return true;
            for (keys, vals) |k, v| {
                if (self.findLive(k) != null) continue;
                // `setKey` reuses a tombstone slot with the same key, so a key can
                // never end up in two slots.
                if (!self.setKey(k, v)) return false;
                if (self.footprint > budget) return false;
            }
            var vb: [4]u8 = undefined;
            format.wr32(&vb, version);
            if (!self.setKey("__ver_num__", &vb)) return false;
            return self.footprint <= budget;
        }
    };
}

// ---------------------------------------------------------------------------
// Random differential runner.
// ---------------------------------------------------------------------------

fn Runner(comptime s: Spec) type {
    const F = FlashOf(s);
    const Db = DbOf(s);
    const M = ModelOf(s);

    return struct {
        const Self = @This();

        label: []const u8,
        seed: u64,
        mem: []u8,
        db: Db,
        model: M,
        prng: std.Random.DefaultPrng,
        op_index: usize = 0,
        op_name: []const u8 = "init",

        // Scratch buffers. `gotbuf` is deliberately larger than `max_val` so that
        // reads can detect writes past `min(buf.len, value_len)`.
        keybuf: [M.max_name]u8 = undefined,
        valbuf: [M.max_val]u8 = undefined,
        gotbuf: [M.max_val + 8]u8 = undefined,
        probebuf: [M.max_val + 8]u8 = undefined,
        // Last successful `set`, replayed by the fault-injection sweeps.
        last_key: [M.max_name]u8 = undefined,
        last_key_len: usize = 0,
        last_val: [M.max_val]u8 = undefined,
        last_val_len: usize = 0,
        last_set_valid: bool = false,
        /// Per-operation-kind execution counters, for coverage reporting.
        op_counts: [11]u64 = @splat(0),
        /// Highest record address seen by the iterator (u32 address path check).
        max_addr: u32 = 0,

        fn create(mem: []u8, seed: u64) Self {
            return .{
                .label = labelOf(s),
                .seed = seed,
                .mem = mem,
                .db = undefined,
                .model = M.init(),
                .prng = std.Random.DefaultPrng.init(seed),
            };
        }

        fn rnd(self: *Self) std.Random {
            return self.prng.random();
        }

        fn backend(self: *Self) FlashOf(s) {
            return F.init(self.mem);
        }

        fn mountFresh(self: *Self) !void {
            @memset(self.mem, 0xFF);
            try self.db.mount(self.backend());
            self.model = M.init();
        }

        fn remount(self: *Self) !void {
            try self.db.mount(self.backend());
        }

        // -- diagnostics ----------------------------------------------------

        fn diag(self: *const Self, comptime fmt: []const u8, args: anytype) void {
            std.debug.print(
                "[kv_model] FAIL config={s} seed=0x{x} op_index={d} op={s} image_hash=0x{x}\n",
                .{ self.label, self.seed, self.op_index, self.op_name, std.hash.Wyhash.hash(0, self.mem) },
            );
            std.debug.print("  " ++ fmt ++ "\n", args);
        }

        fn fail(self: *const Self, comptime fmt: []const u8, args: anytype) error{ModelMismatch} {
            self.diag(fmt, args);
            return error.ModelMismatch;
        }

        fn check(self: *const Self, cond: bool, comptime fmt: []const u8, args: anytype) !void {
            if (!cond) return self.fail(fmt, args);
        }

        fn checkStats(self: *const Self) !void {
            const st = &self.db.dev.flash.stats;
            try self.check(st.set_bit_attempts == 0, "flash set_bit_attempts={d}: a write targeted a non-erased granule", .{st.set_bit_attempts});
            try self.check(st.violations == 0, "flash violations={d}", .{st.violations});
        }

        // -- key generation -------------------------------------------------

        fn drawKey(self: *Self, buf: []u8) []const u8 {
            const r = self.rnd();
            var len = r.intRangeAtMost(usize, 1, M.max_name);
            if (r.uintLessThan(u8, 8) == 0) len = M.max_name; // keys at the limit
            buf[0] = 'k'; // never collides with the internal "__ver_num__"
            if (len > 1) r.bytes(buf[1..len]);
            return buf[0..len];
        }

        /// Draw a key that is not present in the model (live or tombstones).
        fn drawUniqueKey(self: *Self) ?usize {
            var attempt: usize = 0;
            while (attempt < 32) : (attempt += 1) {
                const k = self.drawKey(self.keybuf[0..]);
                if (self.model.find(k) == null) return k.len;
            }
            return null;
        }

        fn pickLiveSlot(self: *Self) usize {
            const r = self.rnd();
            var target = r.uintLessThan(usize, self.model.count);
            for (&self.model.slots, 0..) |*sl, i| {
                if (!sl.live) continue;
                if (target == 0) return i;
                target -= 1;
            }
            unreachable;
        }

        fn pickDeadSlot(self: *Self) ?usize {
            for (&self.model.slots, 0..) |*sl, i| {
                if (!sl.live and sl.key_len > 0) return i;
            }
            return null;
        }

        // -- random operations ----------------------------------------------

        const Target = struct { idx: usize, is_new: bool, key_len: usize };

        fn chooseSetTarget(self: *Self) ?Target {
            const free = self.model.findFree();
            const want_new = self.rnLess(45);
            if (want_new and free != null) {
                if (self.drawUniqueKey()) |klen| {
                    return .{ .idx = free.?, .is_new = true, .key_len = klen };
                }
            }
            if (self.model.count > 0) {
                const idx = self.pickLiveSlot();
                const sl = &self.model.slots[idx];
                @memcpy(self.keybuf[0..sl.key_len], sl.key[0..sl.key_len]);
                return .{ .idx = idx, .is_new = false, .key_len = sl.key_len };
            }
            if (free) |f| {
                if (self.drawUniqueKey()) |klen| {
                    return .{ .idx = f, .is_new = true, .key_len = klen };
                }
            }
            return null;
        }

        fn rnLess(self: *Self, comptime percent: u8) bool {
            return self.rnd().uintLessThan(u8, 100) < percent;
        }

        fn opSet(self: *Self) !void {
            self.last_set_valid = false;
            const target = self.chooseSetTarget() orelse return self.opGet();
            const key = self.keybuf[0..target.key_len];

            // Pick a value length that keeps the live footprint inside the budget.
            const old_len: usize = if (target.is_new)
                0
            else
                M.recordLen(self.model.slots[target.idx].key_len, self.model.slots[target.idx].val_len);
            const base = self.model.footprint - old_len;
            const room = M.budget - @min(base, M.budget);
            const fixed = M.valueOff(key.len);
            if (room < fixed) return self.opDelete();
            const max_v = @min(M.max_val, room - fixed);
            const roll = self.rnd().uintLessThan(u8, 100);
            var vlen: usize = 0;
            if (roll < 12) {
                vlen = 0;
            } else if (roll < 22) {
                vlen = max_v;
            } else if (roll < 34) {
                vlen = @min(max_v, 1);
            } else {
                vlen = self.rnd().intRangeAtMost(usize, 0, max_v);
            }
            if (vlen > 0) self.rnd().bytes(self.valbuf[0..vlen]);

            self.db.set(key, self.valbuf[0..vlen]) catch |err| {
                return self.fail(
                    "set('{x}', {d} bytes) failed: {s} (model footprint {d}/{d})",
                    .{ key, vlen, @errorName(err), self.model.footprint, M.budget },
                );
            };
            self.model.setSlot(target.idx, key, self.valbuf[0..vlen]);

            @memcpy(self.last_key[0..key.len], key);
            self.last_key_len = key.len;
            @memcpy(self.last_val[0..vlen], self.valbuf[0..vlen]);
            self.last_val_len = vlen;
            self.last_set_valid = true;
        }

        fn absentKey(self: *Self) ?[]const u8 {
            if (self.pickDeadSlot()) |idx| {
                const sl = &self.model.slots[idx];
                @memcpy(self.keybuf[0..sl.key_len], sl.key[0..sl.key_len]);
                return self.keybuf[0..sl.key_len];
            }
            const klen = self.drawUniqueKey() orelse return null;
            return self.keybuf[0..klen];
        }

        fn opDelete(self: *Self) !void {
            var want_live = false;
            var key: []const u8 = undefined;
            if (self.model.count > 0 and self.rnLess(75)) {
                const idx = self.pickLiveSlot();
                const sl = &self.model.slots[idx];
                @memcpy(self.keybuf[0..sl.key_len], sl.key[0..sl.key_len]);
                key = self.keybuf[0..sl.key_len];
                want_live = true;
            } else {
                key = self.absentKey() orelse return self.opGet();
                want_live = false;
            }
            const existed = self.db.delete(key) catch |err| {
                return self.fail("delete('{x}') failed: {s}", .{ key, @errorName(err) });
            };
            try self.check(
                existed == want_live,
                "delete('{x}') returned {any}, model says live={any}",
                .{ key, existed, want_live },
            );
            if (existed) {
                const idx = self.model.findLive(key).?;
                self.model.removeSlot(idx);
            }
        }

        fn opGet(self: *Self) !void {
            if (self.model.count > 0 and self.rnLess(80)) {
                const idx = self.pickLiveSlot();
                const sl = &self.model.slots[idx];
                @memcpy(self.keybuf[0..sl.key_len], sl.key[0..sl.key_len]);
                const key = self.keybuf[0..sl.key_len];
                const want = sl.val[0..sl.val_len];
                const want_len: u32 = @intCast(sl.val_len);
                const sizes = [_]usize{ sl.val_len, sl.val_len / 2, 0, 1, M.max_val + 8 };
                const buf_len = sizes[self.rnd().uintLessThan(usize, sizes.len)];
                @memset(&self.gotbuf, 0xAA);
                const n = (try self.db.get(key, self.gotbuf[0..buf_len])) orelse
                    return self.fail("get('{x}') = null, model has a {d}-byte value", .{ key, sl.val_len });
                if (n != want_len) {
                    return self.fail("get('{x}') length: expected {d}, got {d}", .{ key, want_len, n });
                }
                const copied = @min(buf_len, sl.val_len);
                if (!std.mem.eql(u8, want[0..copied], self.gotbuf[0..copied])) {
                    return self.fail(
                        "get('{x}') prefix mismatch: expected {x}, got {x}",
                        .{ key, want[0..copied], self.gotbuf[0..copied] },
                    );
                }
                for (self.gotbuf[copied..buf_len]) |b| {
                    if (b != 0xAA) {
                        return self.fail(
                            "get('{x}') wrote past min(buf.len, value_len) = {d} (buf was {d} bytes)",
                            .{ key, copied, buf_len },
                        );
                    }
                }
            } else {
                const key = self.absentKey() orelse return;
                @memset(&self.gotbuf, 0xAA);
                if ((try self.db.get(key, &self.gotbuf)) != null) {
                    return self.fail("get('{x}') returned a value, model says absent", .{key});
                }
            }
        }

        fn opContains(self: *Self) !void {
            var want = false;
            var key: []const u8 = undefined;
            if (self.model.count > 0 and self.rnLess(70)) {
                const idx = self.pickLiveSlot();
                const sl = &self.model.slots[idx];
                @memcpy(self.keybuf[0..sl.key_len], sl.key[0..sl.key_len]);
                key = self.keybuf[0..sl.key_len];
                want = true;
            } else {
                key = self.absentKey() orelse return self.opGet();
                want = false;
            }
            const got = try self.db.contains(key);
            try self.check(got == want, "contains('{x}') = {any}, model says {any}", .{ key, got, want });
        }

        fn opCount(self: *Self) !void {
            const got = try self.db.count();
            try self.check(got == self.model.count, "count() = {d}, model has {d} live keys", .{ got, self.model.count });
        }

        fn opCheck(self: *Self) !void {
            self.db.check() catch |err| {
                return self.fail("check() failed: {s}", .{@errorName(err)});
            };
            try self.checkStats();
        }

        fn opRemount(self: *Self) !void {
            try self.checkStats();
            self.remount() catch |err| {
                return self.fail("remount failed: {s}", .{@errorName(err)});
            };
            try self.verifyAll();
        }

        fn opFormatAll(self: *Self) !void {
            self.db.formatAll() catch |err| {
                return self.fail("formatAll failed: {s}", .{@errorName(err)});
            };
            self.model.clear();
            try self.verifyAll();
        }

        fn opAutoUpdate(self: *Self) !void {
            const r = self.rnd();
            const version: u32 = r.uintLessThan(u32, 3);
            var dkeys_buf: [2][M.max_name]u8 = undefined;
            var dvals_buf: [2][8]u8 = undefined;
            var dkeys: [2][]const u8 = undefined;
            var dvals: [2][]const u8 = undefined;
            var n: usize = 0;

            if (self.model.count > 0 and r.boolean()) {
                const idx = self.pickLiveSlot();
                const sl = &self.model.slots[idx];
                @memcpy(dkeys_buf[n][0..sl.key_len], sl.key[0..sl.key_len]);
                dkeys[n] = dkeys_buf[n][0..sl.key_len];
                const vl = r.uintLessThan(usize, 6);
                if (vl > 0) r.bytes(dvals_buf[n][0..vl]);
                dvals[n] = dvals_buf[n][0..vl];
                n += 1;
            }
            if (self.drawUniqueKey()) |klen| {
                @memcpy(dkeys_buf[n][0..klen], self.keybuf[0..klen]);
                dkeys[n] = dkeys_buf[n][0..klen];
                const vl = r.uintLessThan(usize, 6);
                if (vl > 0) r.bytes(dvals_buf[n][0..vl]);
                dvals[n] = dvals_buf[n][0..vl];
                n += 1;
            }
            if (n == 0) return self.opGet();

            // Only issue the call when the reference model can absorb it.
            var trial = self.model;
            if (!trial.applyAutoUpdate(version, dkeys[0..n], dvals[0..n])) return self.opGet();

            var defaults: [2]Db.DefaultKv = undefined;
            for (0..n) |i| defaults[i] = .{ .key = dkeys[i], .value = dvals[i] };
            self.db.autoUpdate(version, defaults[0..n]) catch |err| {
                return self.fail(
                    "autoUpdate(version={d}, {d} defaults) failed: {s} (model footprint {d}/{d})",
                    .{ version, n, @errorName(err), self.model.footprint, M.budget },
                );
            };
            if (!self.model.applyAutoUpdate(version, dkeys[0..n], dvals[0..n])) {
                return self.fail("autoUpdate succeeded but exceeded the model budget", .{});
            }
        }

        // -- full verification ----------------------------------------------

        fn verifyAll(self: *Self) !void {
            // Model sanity first: a key must live in exactly one slot, otherwise
            // every later lookup is ambiguous.
            for (&self.model.slots, 0..) |*a, ai| {
                if (a.key_len == 0) continue;
                for (self.model.slots[ai + 1 ..]) |*b| {
                    if (b.key_len == 0) continue;
                    if (std.mem.eql(u8, a.key[0..a.key_len], b.key[0..b.key_len])) {
                        return self.fail(
                            "model slots {d} and a later slot both hold key '{x}'",
                            .{ ai, a.key[0..a.key_len] },
                        );
                    }
                }
            }

            const got_count = try self.db.count();
            try self.check(got_count == self.model.count, "count() = {d}, model has {d}", .{ got_count, self.model.count });

            for (&self.model.slots) |*sl| {
                if (!sl.live) continue;
                const key = sl.key[0..sl.key_len];
                const want = sl.val[0..sl.val_len];
                const want_len: u32 = @intCast(sl.val_len);

                @memset(&self.gotbuf, 0xAA);
                const n = (try self.db.get(key, &self.gotbuf)) orelse
                    return self.fail("get('{x}') = null, model has a {d}-byte value", .{ key, sl.val_len });
                if (n != want_len) {
                    return self.fail("get('{x}') length: expected {d}, got {d}", .{ key, want_len, n });
                }
                if (!std.mem.eql(u8, want, self.gotbuf[0..sl.val_len])) {
                    return self.fail(
                        "get('{x}') value mismatch: expected {x}, got {x}",
                        .{ key, want, self.gotbuf[0..sl.val_len] },
                    );
                }
                for (self.gotbuf[sl.val_len..]) |b| {
                    if (b != 0xAA) return self.fail("get('{x}') wrote past value_len = {d}", .{ key, sl.val_len });
                }

                if (sl.val_len > 0) {
                    const take = sl.val_len / 2;
                    @memset(self.probebuf[0..take], 0xAA);
                    const pn = (try self.db.get(key, self.probebuf[0..take])) orelse
                        return self.fail("prefix get('{x}') = null", .{key});
                    if (pn != want_len) {
                        return self.fail("prefix get('{x}') length: expected {d}, got {d}", .{ key, want_len, pn });
                    }
                    if (!std.mem.eql(u8, want[0..take], self.probebuf[0..take])) {
                        return self.fail(
                            "prefix get('{x}') mismatch: expected {x}, got {x}",
                            .{ key, want[0..take], self.probebuf[0..take] },
                        );
                    }
                }
                const zn = (try self.db.get(key, &[_]u8{})) orelse
                    return self.fail("zero-buffer get('{x}') = null", .{key});
                if (zn != want_len) {
                    return self.fail("zero-buffer get('{x}') length: expected {d}, got {d}", .{ key, want_len, zn });
                }
                if (!try self.db.contains(key)) return self.fail("contains('{x}') = false for a live model key", .{key});
            }

            for (&self.model.slots) |*sl| {
                if (sl.live or sl.key_len == 0) continue;
                const key = sl.key[0..sl.key_len];
                if ((try self.db.get(key, &self.gotbuf)) != null) {
                    return self.fail("deleted key '{x}' is still readable", .{key});
                }
                if (try self.db.contains(key)) return self.fail("deleted key '{x}' reported by contains", .{key});
            }

            var it = self.db.iterator();
            var seen: [M.max_keys]bool = @splat(false);
            var entries: usize = 0;
            while (true) {
                const e = (try it.next()) orelse break;
                entries += 1;
                if (entries > M.max_keys) {
                    return self.fail("iteration produced more than {d} entries", .{M.max_keys});
                }
                const idx = self.model.findLive(e.name) orelse
                    return self.fail("iteration produced unknown key '{x}'", .{e.name});
                if (e.addr > self.max_addr) self.max_addr = e.addr;
                if (seen[idx]) return self.fail("iteration produced duplicate key '{x}'", .{e.name});
                seen[idx] = true;
                const sl = &self.model.slots[idx];
                if (@as(usize, e.name_len) != sl.key_len) {
                    return self.fail("iteration name_len for '{x}': expected {d}, got {d}", .{ e.name, sl.key_len, e.name_len });
                }
                if (e.value_len != @as(u32, @intCast(sl.val_len))) {
                    return self.fail(
                        "iteration value_len for '{x}': expected {d}, got {d}",
                        .{ e.name, sl.val_len, e.value_len },
                    );
                }
                @memset(&self.gotbuf, 0xAA);
                const rv = try it.readValue(&self.gotbuf, e);
                if (rv != e.value_len) {
                    return self.fail("readValue('{x}') copied {d} of {d} bytes", .{ e.name, rv, e.value_len });
                }
                if (!std.mem.eql(u8, sl.val[0..sl.val_len], self.gotbuf[0..sl.val_len])) {
                    return self.fail(
                        "readValue('{x}') mismatch: expected {x}, got {x}",
                        .{ e.name, sl.val[0..sl.val_len], self.gotbuf[0..sl.val_len] },
                    );
                }
                for (self.gotbuf[sl.val_len..]) |b| {
                    if (b != 0xAA) return self.fail("readValue('{x}') wrote past value_len", .{e.name});
                }
                if (sl.val_len > 1) {
                    const rv1 = try it.readValue(self.probebuf[0..1], e);
                    if (rv1 != 1) return self.fail("readValue('{x}') into 1 byte copied {d}", .{ e.name, rv1 });
                    if (self.probebuf[0] != sl.val[0]) {
                        return self.fail("readValue('{x}') 1-byte prefix mismatch", .{e.name});
                    }
                }
            }
            if (entries != self.model.count) {
                return self.fail("iteration saw {d} entries, model has {d}", .{ entries, self.model.count });
            }

            self.db.check() catch |err| {
                return self.fail("check() failed: {s}", .{@errorName(err)});
            };
            try self.checkStats();
        }

        // -- driver ---------------------------------------------------------

        fn step(self: *Self, i: usize) !void {
            self.op_index = i;
            const r = self.rnd().uintLessThan(u16, 1000);
            if (r < 380) {
                self.op_name = "set";
                self.op_counts[0] += 1;
                try self.opSet();
            } else if (r < 500) {
                self.op_name = "delete";
                self.op_counts[1] += 1;
                try self.opDelete();
            } else if (r < 640) {
                self.op_name = "get";
                self.op_counts[2] += 1;
                try self.opGet();
            } else if (r < 700) {
                self.op_name = "contains";
                self.op_counts[3] += 1;
                try self.opContains();
            } else if (r < 730) {
                self.op_name = "count";
                self.op_counts[4] += 1;
                try self.opCount();
            } else if (r < 790) {
                self.op_name = "iterate";
                self.op_counts[5] += 1;
                try self.verifyAll();
            } else if (r < 820) {
                self.op_name = "check";
                self.op_counts[6] += 1;
                try self.opCheck();
            } else if (r < 860) {
                self.op_name = "remount";
                self.op_counts[7] += 1;
                try self.opRemount();
            } else if (r < 875) {
                self.op_name = "formatAll";
                self.op_counts[8] += 1;
                try self.opFormatAll();
            } else if (r < 920) {
                self.op_name = "autoUpdate";
                self.op_counts[9] += 1;
                try self.opAutoUpdate();
            } else {
                self.op_name = "get+contains";
                self.op_counts[10] += 1;
                try self.opGet();
                try self.opContains();
            }
            if (i % 10 == 9) {
                self.op_name = "verify";
                self.op_index = i;
                try self.verifyAll();
            }
        }
    };
}

/// Operation-kind names, matching `Runner.op_counts` indices.
const op_names = [_][]const u8{
    "set", "delete", "get", "contains", "count", "iterate", "check", "remount", "formatAll", "autoUpdate", "get+contains",
};

fn runStream(comptime s: Spec) !void {
    const M = ModelOf(s);
    const alloc = std.heap.page_allocator;
    const mem = try alloc.alloc(u8, M.flash_len);
    defer alloc.free(mem);

    var runner = Runner(s).create(mem, s.seed);
    try runner.mountFresh();
    std.debug.print(
        "[kv_model] stream config={s} seed=0x{x} ops={d} flash={d}B keys={d} max_val={d}\n",
        .{ runner.label, s.seed, s.ops, M.flash_len, M.max_keys, M.max_val },
    );

    // Deterministic coverage: autoUpdate on the empty database, a formatAll in
    // the middle (model cleared) and a forced remount two thirds through.
    try runner.opAutoUpdate();
    runner.op_counts[9] += 1;

    var i: usize = 0;
    while (i < s.ops) : (i += 1) {
        if (i == s.ops / 3) {
            runner.op_index = i;
            runner.op_name = "formatAll(forced)";
            try runner.opFormatAll();
            runner.op_counts[8] += 1;
        } else if (i == (2 * s.ops) / 3) {
            runner.op_index = i;
            runner.op_name = "remount(forced)";
            try runner.opRemount();
            runner.op_counts[7] += 1;
        } else {
            try runner.step(i);
        }
    }

    runner.op_index = s.ops;
    runner.op_name = "final-verify";
    try runner.verifyAll();
    try runner.opRemount();

    std.debug.print(
        "[kv_model] stream done config={s} seed=0x{x} live={d} max_addr=0x{x} ops=",
        .{ runner.label, s.seed, runner.model.count, runner.max_addr },
    );
    for (op_names, 0..) |nm, k| {
        std.debug.print("{s}{s}={d}", .{ if (k == 0) "" else " ", nm, runner.op_counts[k] });
    }
    std.debug.print("\n", .{});

    // Every operation kind that the stream claims to cover must actually have
    // executed at least once (count/check/iterate depend on the seeded draw but
    // the seeds are fixed, so this is stable).
    const required = [_]usize{ 0, 1, 2, 3, 5, 6, 7, 8, 9 };
    for (required) |k| {
        if (runner.op_counts[k] == 0) {
            return runner.fail("operation kind '{s}' never executed", .{op_names[k]});
        }
    }
}

// ---------------------------------------------------------------------------
// Fault-injection sweeps.
// ---------------------------------------------------------------------------

const SweepKind = enum { set, delete, format_all };

const SweepOp = struct {
    kind: SweepKind,
    key: []const u8 = &.{},
    val: []const u8 = &.{},
};

fn kindName(k: SweepKind) []const u8 {
    return switch (k) {
        .set => "set",
        .delete => "delete",
        .format_all => "formatAll",
    };
}

fn keyInList(keys: []const []const u8, key: []const u8) bool {
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

fn indexOfKey(keys: []const []const u8, key: []const u8) ?usize {
    for (keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return i;
    return null;
}

const SweepCtx = struct {
    const Self = @This();
    label: []const u8,
    seed: u64,
    kind: []const u8,
    cut: u64 = 0,
    op_count: u64 = 0,
    image: []const u8,

    fn fail(self: Self, comptime fmt: []const u8, args: anytype) error{ModelMismatch} {
        std.debug.print(
            "[kv_model] FAIL sweep config={s} seed=0x{x} op={s} cut={d}/{d} image_hash=0x{x}\n",
            .{ self.label, self.seed, self.kind, self.cut, self.op_count, std.hash.Wyhash.hash(0, self.image) },
        );
        std.debug.print("  " ++ fmt ++ "\n", args);
        return error.ModelMismatch;
    }
};

fn runOp(comptime s: Spec, db: *DbOf(s), op: SweepOp, ok: *bool, deleted: *bool) void {
    ok.* = true;
    deleted.* = false;
    switch (op.kind) {
        .set => db.set(op.key, op.val) catch {
            ok.* = false;
        },
        .delete => deleted.* = db.delete(op.key) catch {
            ok.* = false;
            return;
        },
        .format_all => db.formatAll() catch {
            ok.* = false;
        },
    }
}

fn postModelOf(comptime s: Spec, pre: *const ModelOf(s), op: SweepOp, ok: bool, deleted: bool) ModelOf(s) {
    var post = pre.*;
    if (!ok) return post;
    switch (op.kind) {
        .set => {
            _ = post.setKey(op.key, op.val);
        },
        .delete => {
            if (deleted) {
                if (post.findLive(op.key)) |idx| post.removeSlot(idx);
            }
        },
        .format_all => post.clear(),
    }
    return post;
}

/// Verify a mounted database against the model exactly (used on the clean replay
/// that produced the expected post-operation state).
fn verifyExact(comptime s: Spec, db: *DbOf(s), keys: []const []const u8, model: *const ModelOf(s), ctx: SweepCtx) !void {
    const M = ModelOf(s);
    const got_count = db.count() catch |err| return ctx.fail("count failed: {s}", .{@errorName(err)});
    if (got_count != model.count) return ctx.fail("count() = {d}, model has {d}", .{ got_count, model.count });

    var buf: [M.max_val + 8]u8 = undefined;
    var present: [2 * M.max_keys + 1]bool = @splat(false);
    for (keys, 0..) |key, i| {
        @memset(&buf, 0xAA);
        const got = db.get(key, &buf) catch |err| return ctx.fail("get('{x}') failed: {s}", .{ key, @errorName(err) });
        if (model.findLive(key)) |mi| {
            const want = model.slots[mi].val[0..model.slots[mi].val_len];
            const n = got orelse return ctx.fail("key '{x}' missing (expected {d} bytes)", .{ key, want.len });
            if (n != want.len or !std.mem.eql(u8, buf[0..want.len], want)) {
                return ctx.fail("key '{x}': expected {d} bytes {x}, got {x}", .{ key, want.len, want, buf[0..n] });
            }
            present[i] = true;
        } else if (got != null) {
            return ctx.fail("key '{x}' readable but model says absent", .{key});
        }
    }

    var it = db.iterator();
    var seen: [2 * M.max_keys + 1]bool = @splat(false);
    var iterated: usize = 0;
    while (true) {
        const e = (it.next() catch |err| return ctx.fail("iteration failed: {s}", .{@errorName(err)})) orelse break;
        iterated += 1;
        if (iterated > keys.len) return ctx.fail("iteration produced more entries than the key union", .{});
        const ki = indexOfKey(keys, e.name) orelse
            return ctx.fail("iteration produced unexpected key '{x}'", .{e.name});
        if (seen[ki]) return ctx.fail("iteration produced duplicate key '{x}'", .{e.name});
        seen[ki] = true;
        if (!present[ki]) return ctx.fail("iteration has key '{x}' that get() reported absent", .{e.name});
    }
    if (iterated != model.count) return ctx.fail("iteration saw {d} entries, model has {d}", .{ iterated, model.count });

    db.check() catch |err| return ctx.fail("check() failed: {s}", .{@errorName(err)});
}

fn runSweep(
    comptime s: Spec,
    label: []const u8,
    base_image: []const u8,
    op: SweepOp,
    pre_in: *const ModelOf(s),
    mem: []u8,
    probe: []u8,
    seed: u64,
) !void {
    const F = FlashOf(s);
    const Db = DbOf(s);
    const M = ModelOf(s);
    const union_max = 2 * M.max_keys + 1;

    const pre = pre_in.*;
    var ctx = SweepCtx{ .label = label, .seed = seed, .kind = kindName(op.kind), .image = base_image };

    // 1. Clean replay on a fresh mount: count the mutations, snapshot the post
    //    state, and check that a clean run never programs a non-erased granule.
    @memcpy(probe, base_image);
    var pdb: Db = undefined;
    pdb.mount(F.init(probe)) catch |err| return ctx.fail("clean mount failed: {s}", .{@errorName(err)});
    {
        const st = &pdb.dev.flash.stats;
        if (st.set_bit_attempts != 0) return ctx.fail("clean mount wrote {d} non-erased bytes", .{st.set_bit_attempts});
        if (st.violations != 0) return ctx.fail("clean mount violations={d}", .{st.violations});
    }
    pdb.dev.flash.mutations = 0;
    var clean_ok = true;
    var clean_deleted = false;
    runOp(s, &pdb, op, &clean_ok, &clean_deleted);
    ctx.op_count = pdb.dev.flash.mutations;
    {
        const st = &pdb.dev.flash.stats;
        if (st.set_bit_attempts != 0) {
            return ctx.fail("clean replay wrote {d} non-erased bytes", .{st.set_bit_attempts});
        }
        if (st.violations != 0) return ctx.fail("clean replay violations={d}", .{st.violations});
    }
    if (op.kind == .delete and pre.findLive(op.key) != null and clean_ok and !clean_deleted) {
        return ctx.fail("delete('{x}') returned false for a live key", .{op.key});
    }
    const post = postModelOf(s, &pre, op, clean_ok, clean_deleted);

    // 2. Key union: everything that could legally be visible afterwards.
    var keys: [union_max][]const u8 = undefined;
    var nk: usize = 0;
    for (&pre.slots) |*sl| {
        if (!sl.live) continue;
        keys[nk] = sl.key[0..sl.key_len];
        nk += 1;
    }
    for (&post.slots) |*sl| {
        if (!sl.live) continue;
        if (keyInList(keys[0..nk], sl.key[0..sl.key_len])) continue;
        keys[nk] = sl.key[0..sl.key_len];
        nk += 1;
    }
    if (op.key.len > 0 and !keyInList(keys[0..nk], op.key) and nk < union_max) {
        keys[nk] = op.key;
        nk += 1;
    }

    // 3. The clean replay must match the post-operation model exactly.
    try verifyExact(s, &pdb, keys[0..nk], &post, ctx);

    // 4. Power cut after every mutating flash access of the operation.
    var cut: u64 = 0;
    while (cut <= ctx.op_count) : (cut += 1) {
        ctx.cut = cut;
        ctx.image = mem;

        @memcpy(mem, base_image);
        var db: Db = undefined;
        db.mount(F.init(mem)) catch |err| return ctx.fail("mount before cut failed: {s}", .{@errorName(err)});
        db.dev.flash.mutations = 0;
        db.dev.flash.armFault(cut);
        var ok = true;
        var deleted = false;
        runOp(s, &db, op, &ok, &deleted);
        {
            const st = &db.dev.flash.stats;
            if (st.set_bit_attempts != 0) {
                return ctx.fail("interrupted operation wrote {d} non-erased bytes", .{st.set_bit_attempts});
            }
            if (st.violations != 0) return ctx.fail("interrupted operation violations={d}", .{st.violations});
        }
        db.dev.flash.clearFault();

        // Remount from the same bytes: this is the recovery path under test.
        db.mount(F.init(mem)) catch |err| return ctx.fail("remount failed: {s}", .{@errorName(err)});
        db.check() catch |err| return ctx.fail("check() failed: {s}", .{@errorName(err)});

        // Read back every key that could be affected.
        var recovered_len: [union_max]usize = @splat(0);
        var recovered_present: [union_max]bool = @splat(false);
        var recovered_val: [union_max][M.max_val + 8]u8 = undefined;
        var buf: [M.max_val + 8]u8 = undefined;
        for (keys[0..nk], 0..) |key, i| {
            @memset(&buf, 0xAA);
            const got = db.get(key, &buf) catch |err| return ctx.fail("get('{x}') failed: {s}", .{ key, @errorName(err) });
            if (got) |n| {
                if (n > M.max_val + 8) {
                    return ctx.fail("value of '{x}' is {d} bytes, above the model cap", .{ key, n });
                }
                recovered_present[i] = true;
                recovered_len[i] = n;
                @memcpy(recovered_val[i][0..n], buf[0..n]);
            }
        }

        // Each key must read its pre or its post value; unchanged keys exactly.
        for (keys[0..nk], 0..) |key, i| {
            const present = recovered_present[i];
            const glen = recovered_len[i];
            const gval = recovered_val[i][0..glen];
            const pre_idx = pre.findLive(key);
            const post_idx = post.findLive(key);
            if (pre_idx) |pi| {
                const pv = pre.slots[pi].val[0..pre.slots[pi].val_len];
                if (post_idx) |qi| {
                    const nv = post.slots[qi].val[0..post.slots[qi].val_len];
                    if (std.mem.eql(u8, pv, nv)) {
                        if (!present or glen != pv.len or !std.mem.eql(u8, gval, pv)) {
                            return ctx.fail(
                                "key '{x}' (unchanged by the operation): expected {d} bytes {x}, got {any} {x}",
                                .{ key, pv.len, pv, present, gval },
                            );
                        }
                    } else {
                        const is_old = present and glen == pv.len and std.mem.eql(u8, gval, pv);
                        const is_new = present and glen == nv.len and std.mem.eql(u8, gval, nv);
                        if (!is_old and !is_new) {
                            return ctx.fail(
                                "key '{x}' is neither the old value {x} nor the new value {x}: got {any} {x}",
                                .{ key, pv, nv, present, gval },
                            );
                        }
                    }
                } else {
                    // Deleted by the operation: either gone or still the old value.
                    const is_old = present and glen == pv.len and std.mem.eql(u8, gval, pv);
                    if (present and !is_old) {
                        return ctx.fail(
                            "deleted key '{x}': expected absent or old value {x}, got {any} {x}",
                            .{ key, pv, present, gval },
                        );
                    }
                }
            } else if (post_idx) |qi| {
                const nv = post.slots[qi].val[0..post.slots[qi].val_len];
                const is_new = present and glen == nv.len and std.mem.eql(u8, gval, nv);
                if (present and !is_new) {
                    return ctx.fail(
                        "created key '{x}': expected absent or new value {x}, got {any} {x}",
                        .{ key, nv, present, gval },
                    );
                }
            } else if (present) {
                return ctx.fail("key '{x}' is visible although neither model has it: {x}", .{ key, gval });
            }
        }

        // count() and iteration must agree with the recovered values, with no
        // duplicates and no extra keys.
        var present_count: usize = 0;
        for (recovered_present[0..nk]) |p| {
            if (p) present_count += 1;
        }
        const got_count = db.count() catch |err| return ctx.fail("count() failed: {s}", .{@errorName(err)});
        if (got_count != present_count) {
            return ctx.fail("count() = {d} but {d} keys read back", .{ got_count, present_count });
        }
        var it = db.iterator();
        var seen: [union_max]bool = @splat(false);
        var iterated: usize = 0;
        while (true) {
            const e = (it.next() catch |err| return ctx.fail("iteration failed: {s}", .{@errorName(err)})) orelse break;
            iterated += 1;
            if (iterated > nk) return ctx.fail("iteration produced more entries than the key union", .{});
            const ki = indexOfKey(keys[0..nk], e.name) orelse
                return ctx.fail("iteration produced key '{x}' outside the pre/post union", .{e.name});
            if (seen[ki]) return ctx.fail("iteration produced duplicate key '{x}'", .{e.name});
            seen[ki] = true;
            if (!recovered_present[ki]) return ctx.fail("iteration has key '{x}' that get() reported absent", .{e.name});
            if (@as(usize, e.value_len) != recovered_len[ki]) {
                return ctx.fail(
                    "iteration value_len for '{x}': get() said {d}, iterator said {d}",
                    .{ e.name, recovered_len[ki], e.value_len },
                );
            }
            var vbuf: [M.max_val + 8]u8 = undefined;
            const rn = it.readValue(&vbuf, e) catch |err| return ctx.fail("readValue('{x}') failed: {s}", .{ e.name, @errorName(err) });
            if (rn != e.value_len or !std.mem.eql(u8, vbuf[0..rn], recovered_val[ki][0..recovered_len[ki]])) {
                return ctx.fail("readValue('{x}') disagrees with get()", .{e.name});
            }
        }
        if (iterated != present_count) {
            return ctx.fail("iteration saw {d} entries, {d} keys read back", .{ iterated, present_count });
        }

        const st = &db.dev.flash.stats;
        if (st.set_bit_attempts != 0) {
            return ctx.fail("recovery wrote {d} non-erased bytes", .{st.set_bit_attempts});
        }
        if (st.violations != 0) return ctx.fail("recovery violations={d}", .{st.violations});
    }

    std.debug.print(
        "[kv_model] sweep config={s} op={s} cuts={d} clean_op_mutations={d}\n",
        .{ label, kindName(op.kind), ctx.op_count + 1, ctx.op_count },
    );
}

fn runFaultSweeps(comptime s: Spec) !void {
    const M = ModelOf(s);
    const alloc = std.heap.page_allocator;
    const mem = try alloc.alloc(u8, M.flash_len);
    defer alloc.free(mem);
    const probe = try alloc.alloc(u8, M.flash_len);
    defer alloc.free(probe);
    const base = try alloc.alloc(u8, M.flash_len);
    defer alloc.free(base);
    const gc_base = try alloc.alloc(u8, M.flash_len);
    defer alloc.free(gc_base);

    const seed = s.seed ^ 0x5EED_0000_0000_0005;
    var runner = Runner(s).create(mem, seed);
    try runner.mountFresh();
    std.debug.print("[kv_model] fault-sweeps config={s} seed=0x{x}\n", .{ runner.label, seed });

    // Baseline database: a few live keys, some of them overwritten.
    const live_target: usize = @max(2, @min(M.max_keys - 1, 5));
    var i: usize = 0;
    while (i < live_target) : (i += 1) {
        runner.op_name = "baseline-set";
        try runner.opSet();
    }
    i = 0;
    while (i < live_target) : (i += 1) {
        runner.op_name = "baseline-churn";
        try runner.opSet();
    }
    if (runner.model.count == 0) return error.ModelMismatch;
    @memcpy(base, runner.mem);
    const base_model = runner.model;

    // Sweep 1: overwrite an existing key with a value of a different length.
    {
        const idx = runner.pickLiveSlot();
        const sl = &runner.model.slots[idx];
        @memcpy(runner.keybuf[0..sl.key_len], sl.key[0..sl.key_len]);
        const key = runner.keybuf[0..sl.key_len];
        var val: [M.max_val]u8 = undefined;
        const vlen: usize = if (sl.val_len == 0) @min(1, M.max_val) else 0;
        if (vlen > 0) val[0] = sl.val[0] ^ 0xFF;
        try runSweep(s, "set-existing", base, .{ .kind = .set, .key = key, .val = val[0..vlen] }, &base_model, mem, probe, seed);
    }

    // Sweep 2: delete an existing key.
    {
        const idx = runner.pickLiveSlot();
        const sl = &runner.model.slots[idx];
        @memcpy(runner.keybuf[0..sl.key_len], sl.key[0..sl.key_len]);
        const key = runner.keybuf[0..sl.key_len];
        try runSweep(s, "delete-existing", base, .{ .kind = .delete, .key = key }, &base_model, mem, probe, seed);
    }

    // Sweep 3: create a brand-new key.
    if (runner.model.findFree() != null) {
        if (runner.drawUniqueKey()) |klen| {
            var val: [M.max_val]u8 = undefined;
            const vlen = 1 + seed % 5;
            var j: usize = 0;
            while (j < vlen) : (j += 1) val[j] = @truncate(seed >> @intCast((j % 8) * 8));
            const key = runner.keybuf[0..klen];
            try runSweep(s, "set-new", base, .{ .kind = .set, .key = key, .val = val[0..vlen] }, &base_model, mem, probe, seed);
        }
    }

    // Sweep 4: formatAll (destructive; every value may only disappear).
    try runSweep(s, "format-all", base, .{ .kind = .format_all }, &base_model, mem, probe, seed);

    // Sweep 5: a set that triggers a GC which actually *moves live records*.
    //
    // Anchors are written first and never overwritten, so their records live in
    // the oldest sector. Churning one key fills that sector with garbage and then
    // moves on; when the last spare sector is used up, allocation collects the
    // oldest dirty sector, which still holds the live anchors, i.e. the GC move
    // path (pending -> copy -> commit -> deleted) runs inside this single set.
    {
        try runner.mountFresh();
        const anchor_count: usize = @max(2, @min(M.max_keys - 1, 4));
        var j: usize = 0;
        while (j < anchor_count) : (j += 1) {
            var kbuf: [M.max_name]u8 = undefined;
            var nbuf: [8]u8 = undefined;
            const suffix = std.fmt.bufPrint(&nbuf, "{d}", .{j}) catch unreachable;
            @memcpy(kbuf[0..3], "anc");
            @memcpy(kbuf[3..][0..suffix.len], suffix);
            const klen = 3 + suffix.len;
            const key = kbuf[0..klen];
            var val: [M.max_val]u8 = undefined;
            @memset(val[0..], @truncate(0x40 + j));
            runner.db.set(key, &val) catch |err| {
                return runner.fail("anchor set failed: {s}", .{@errorName(err)});
            };
            if (!runner.model.setKey(key, &val)) {
                return runner.fail("anchor key does not fit in the model", .{});
            }
        }
        const churn_key: []const u8 = "churn";

        var saved_pre = runner.model;
        var have_gc = false;
        var iterations: usize = 0;
        const max_iterations: usize = 4000;
        while (iterations < max_iterations) : (iterations += 1) {
            @memcpy(gc_base, runner.mem);
            saved_pre = runner.model;
            const erases_before = runner.db.dev.flash.stats.erases;
            const mutations_before = runner.db.dev.flash.mutations;
            var val: [M.max_val]u8 = undefined;
            for (&val, 0..) |*b, bi| b.* = @truncate(iterations *% 31 +% bi);
            runner.db.set(churn_key, &val) catch |err| switch (err) {
                error.SavedFull => break,
                else => return runner.fail("gc churn set failed: {s}", .{@errorName(err)}),
            };
            if (!runner.model.setKey(churn_key, &val)) {
                return runner.fail("gc churn key does not fit in the model", .{});
            }
            @memcpy(runner.last_key[0..churn_key.len], churn_key);
            runner.last_key_len = churn_key.len;
            @memcpy(runner.last_val[0..val.len], &val);
            runner.last_val_len = val.len;
            runner.last_set_valid = true;

            const op_mutations = runner.db.dev.flash.mutations - mutations_before;
            // A set that only switches sectors costs ~6 mutations. A set that also
            // runs GC moves every live record of the collected sector (~5 each),
            // so it stands out clearly.
            if (runner.db.dev.flash.stats.erases != erases_before and op_mutations >= 12) {
                have_gc = true;
                break;
            }
        }
        if (have_gc and runner.last_set_valid) {
            var key: [M.max_name]u8 = undefined;
            @memcpy(key[0..runner.last_key_len], runner.last_key[0..runner.last_key_len]);
            var val: [M.max_val]u8 = undefined;
            @memcpy(val[0..runner.last_val_len], runner.last_val[0..runner.last_val_len]);
            try runSweep(
                s,
                "set-gc",
                gc_base,
                .{ .kind = .set, .key = key[0..runner.last_key_len], .val = val[0..runner.last_val_len] },
                &saved_pre,
                mem,
                probe,
                seed,
            );
        } else {
            std.debug.print(
                "[kv_model] sweep config={s} op=set-gc skipped (no GC with record moves within {d} churn ops)\n",
                .{ runner.label, max_iterations },
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Entry points.
// ---------------------------------------------------------------------------

test "kv_model: randomized differential streams across configurations" {
    @setEvalBranchQuota(1_000_000);
    inline for (specs) |s| {
        try runStream(s);
    }
}

/// All configurations plus the > 64 KiB partition, whose u32 address path also
/// has to survive power cuts.
const sweep_specs = specs ++ [_]Spec{u32_spec};

test "kv_model: power-cut sweep at every mutation of single operations" {
    @setEvalBranchQuota(1_000_000);
    inline for (sweep_specs) |s| {
        try runFaultSweeps(s);
    }
}

// ---------------------------------------------------------------------------
// Deterministic boundary tests: invalid names, the documented maximum value
// length, a database that fills up, and a reset through formatAll.
// ---------------------------------------------------------------------------

test "kv_model: invalid names and maximum value length" {
    const s = Spec{
        .wg_bits = 8,
        .sector_size = 4096,
        .sector_count = 3,
        .cache_entries = 8,
        .max_name_len = 16,
        .ops = 0,
        .seed = 0,
    };
    const F = FlashOf(s);
    const Db = DbOf(s);

    var mem: [4096 * 3]u8 = undefined;
    @memset(&mem, 0xFF);
    var db: Db = undefined;
    try db.mount(F.init(&mem));

    try std.testing.expectError(error.InvalidName, db.set("", "x"));
    var long_key: [17]u8 = @splat('k');
    try std.testing.expectError(error.InvalidName, db.set(&long_key, "x"));
    try std.testing.expectError(error.InvalidName, db.get("", &[_]u8{}));
    try std.testing.expectError(error.InvalidName, db.get(&long_key, &[_]u8{}));
    try std.testing.expectError(error.InvalidName, db.delete(""));

    const alloc = std.heap.page_allocator;
    // The per-key limit is exact: a shorter key leaves room for a larger value,
    // while `max_value_len` is the conservative bound that always fits (i.e. the
    // limit for a max-length key).
    try std.testing.expectEqual(Db.maxValueLenFor(s.max_name_len), Db.max_value_len);
    const big_limit = Db.maxValueLenFor("big".len);
    const too_big = try alloc.alloc(u8, @as(usize, big_limit) + 1);
    defer alloc.free(too_big);
    @memset(too_big, 0x5A);
    try std.testing.expectError(error.SavedFull, db.set("big", too_big));

    // A record that exactly fills a sector must be storable under a short key and
    // read back byte-identically.
    const f_limit = Db.maxValueLenFor("f".len);
    const full = try alloc.alloc(u8, @as(usize, f_limit));
    defer alloc.free(full);
    for (full, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
    try db.set("f", full);

    const got = try alloc.alloc(u8, @as(usize, f_limit));
    defer alloc.free(got);
    const n = (try db.get("f", got)).?;
    try std.testing.expectEqual(@as(u32, @intCast(full.len)), n);
    try std.testing.expectEqualSlices(u8, full, got[0..n]);
    try db.check();

    // A couple of max-size overwrites exercise sector switching plus GC.
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        full[0] = @truncate(round);
        full[full.len - 1] = @truncate(round + 1);
        try db.set("f", full);
        const nn = (try db.get("f", got)).?;
        try std.testing.expectEqualSlices(u8, full, got[0..nn]);
        try db.check();
    }
    try std.testing.expectEqual(@as(u32, 1), try db.count());
    var db2: Db = undefined;
    try db2.mount(F.init(&mem));
    try db2.check();
    const nn2 = (try db2.get("f", got)).?;
    try std.testing.expectEqualSlices(u8, full, got[0..nn2]);
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);
}

test "kv_model: filling a database returns SavedFull without losing keys" {
    const s = Spec{
        .wg_bits = 8,
        .sector_size = 4096,
        .sector_count = 3,
        .cache_entries = 0,
        .max_name_len = 16,
        .ops = 0,
        .seed = 0,
    };
    const F = FlashOf(s);
    const Db = DbOf(s);
    const M = ModelOf(s);

    var mem: [4096 * 3]u8 = undefined;
    @memset(&mem, 0xFF);
    var db: Db = undefined;
    try db.mount(F.init(&mem));

    const alloc = std.heap.page_allocator;
    const key_storage = try alloc.alloc([16]u8, M.max_keys * 64);
    defer alloc.free(key_storage);
    const key_lens = try alloc.alloc(usize, M.max_keys * 64);
    defer alloc.free(key_lens);

    var value: [24]u8 = undefined;
    for (&value, 0..) |*b, i| b.* = @truncate(i);
    value[0] = 0xA5;

    var accepted: usize = 0;
    const capacity = M.max_keys * 64;
    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        var kbuf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "k{d}", .{i}) catch unreachable;
        db.set(key, &value) catch |err| {
            try std.testing.expectEqual(error.SavedFull, err);
            break;
        };
        @memcpy(key_storage[accepted][0..key.len], key);
        key_lens[accepted] = key.len;
        accepted += 1;
        if (accepted == capacity) break;
    }
    try std.testing.expect(accepted > 0 and accepted < 4000);
    // The database must be bounded by the capacity computed by the model.
    try std.testing.expect(accepted <= capacity);

    var buf: [24]u8 = undefined;
    var j: usize = 0;
    while (j < accepted) : (j += 1) {
        const n = (try db.get(key_storage[j][0..key_lens[j]], &buf)) orelse {
            std.debug.print("[kv_model] FAIL full-db: key {d}/'{s}' missing\n", .{ j, key_storage[j][0..key_lens[j]] });
            return error.ModelMismatch;
        };
        try std.testing.expectEqual(@as(u32, 24), n);
        try std.testing.expectEqualSlices(u8, &value, buf[0..n]);
    }
    try std.testing.expectEqual(@as(u32, @intCast(accepted)), try db.count());
    try db.check();
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.violations);

    // Deleting while full only writes markers, and the remaining keys stay intact.
    var k: usize = 0;
    while (k < accepted) : (k += 2) {
        try std.testing.expect(try db.delete(key_storage[k][0..key_lens[k]]));
    }
    try std.testing.expectEqual(@as(u32, @intCast(accepted - accepted / 2 -% accepted % 2)), try db.count());
    try db.check();

    // A remount must agree with the live view.
    var db2: Db = undefined;
    try db2.mount(F.init(&mem));
    try db2.check();
    try std.testing.expectEqual(try db.count(), try db2.count());
    k = 0;
    while (k < accepted) : (k += 1) {
        const got = try db2.get(key_storage[k][0..key_lens[k]], &buf);
        if (k % 2 == 0) {
            try std.testing.expectEqual(@as(?u32, null), got);
        } else {
            try std.testing.expectEqual(@as(?u32, 24), got);
            try std.testing.expectEqualSlices(u8, &value, buf[0..24]);
        }
    }
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);
}

// ---------------------------------------------------------------------------
// 64 KiB+ partition: the KVDB switches `Addr` from u16 to u32 when the partition
// is larger than 0xFFFF bytes (record addresses, name-cache entries, sector
// bits). A mixed random stream cannot guarantee this - `formatAll` resets the
// ring to sector 0 - so the two tests below drive the high addresses on purpose:
// one fills the partition until `SavedFull`, the other forces GC to move live
// records above 0xFFFF.
// ---------------------------------------------------------------------------

fn patternByte(i: usize, j: usize) u8 {
    return @truncate(i *% 37 +% j *% 11 +% 5);
}

fn fillPattern(buf: []u8, i: usize) void {
    for (buf, 0..) |*b, j| b.* = patternByte(i, j);
}

/// Key `i` of the > 64 KiB tests: "kv/u32/<i>" written into `store`.
fn makeU32Key(store: *[32]u8, i: usize) []const u8 {
    var nbuf: [12]u8 = undefined;
    const digits = std.fmt.bufPrint(&nbuf, "{d}", .{i}) catch unreachable;
    @memcpy(store[0..7], "kv/u32/");
    @memcpy(store[7..][0..digits.len], digits);
    return store[0 .. 7 + digits.len];
}

fn parseU32Index(name: []const u8) ?usize {
    if (name.len <= 7 or !std.mem.startsWith(u8, name, "kv/u32/")) return null;
    var v: usize = 0;
    for (name[7..]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

const u32_max_entries = 900;

const U32Entries = struct {
    store: [u32_max_entries][32]u8 = undefined,
    key_len: [u32_max_entries]usize = @splat(0),
    val_len: [u32_max_entries]usize = @splat(0),
    count: usize = 0,
    saw_saved_full: bool = false,
};

/// Verify a mounted database against the expectation table: count, a complete
/// iteration (name, length, value bytes, no duplicates) and point lookups.
fn verifyU32State(db: *DbOf(u32_spec), e: *const U32Entries, full_gets: bool) !void {
    const got_count = try db.count();
    if (got_count != e.count) {
        std.debug.print("[kv_model] FAIL u32: count {d} != {d}\n", .{ got_count, e.count });
        return error.ModelMismatch;
    }

    var seen: [u32_max_entries]bool = @splat(false);
    var vbuf: [256]u8 = undefined;
    var expect: [256]u8 = undefined;
    var it = db.iterator();
    var entries: usize = 0;
    while (try it.next()) |entry| {
        entries += 1;
        if (entries > e.count) {
            std.debug.print("[kv_model] FAIL u32: iteration produced more than {d} entries\n", .{e.count});
            return error.ModelMismatch;
        }
        const idx = parseU32Index(entry.name) orelse {
            std.debug.print("[kv_model] FAIL u32: unexpected key '{x}'\n", .{entry.name});
            return error.ModelMismatch;
        };
        if (idx >= e.count) {
            std.debug.print("[kv_model] FAIL u32: key index {d} out of range\n", .{idx});
            return error.ModelMismatch;
        }
        if (seen[idx]) {
            std.debug.print("[kv_model] FAIL u32: duplicate key index {d} in iteration\n", .{idx});
            return error.ModelMismatch;
        }
        seen[idx] = true;
        if (entry.value_len != e.val_len[idx]) {
            std.debug.print("[kv_model] FAIL u32: key {d} value_len {d} != {d}\n", .{ idx, entry.value_len, e.val_len[idx] });
            return error.ModelMismatch;
        }
        const got = try it.readValue(&vbuf, entry);
        if (got != e.val_len[idx]) {
            std.debug.print("[kv_model] FAIL u32: readValue key {d} copied {d} != {d}\n", .{ idx, got, e.val_len[idx] });
            return error.ModelMismatch;
        }
        fillPattern(expect[0..e.val_len[idx]], idx);
        if (!std.mem.eql(u8, expect[0..e.val_len[idx]], vbuf[0..got])) {
            std.debug.print("[kv_model] FAIL u32: key {d} value mismatch (iteration)\n", .{idx});
            return error.ModelMismatch;
        }
    }
    if (entries != e.count) {
        std.debug.print("[kv_model] FAIL u32: iteration saw {d} entries, expected {d}\n", .{ entries, e.count });
        return error.ModelMismatch;
    }

    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < e.count) : (i += 1) {
        if (!full_gets and i % 37 != 0) continue;
        const key = e.store[i][0..e.key_len[i]];
        const got = (try db.get(key, &buf)) orelse {
            std.debug.print("[kv_model] FAIL u32: key {d} '{s}' missing\n", .{ i, key });
            return error.ModelMismatch;
        };
        if (got != e.val_len[i]) {
            std.debug.print("[kv_model] FAIL u32: key {d} '{s}' length {d} != {d}\n", .{ i, key, got, e.val_len[i] });
            return error.ModelMismatch;
        }
        fillPattern(expect[0..e.val_len[i]], i);
        if (!std.mem.eql(u8, expect[0..e.val_len[i]], buf[0..got])) {
            std.debug.print("[kv_model] FAIL u32: key {d} '{s}' value mismatch\n", .{ i, key });
            return error.ModelMismatch;
        }
    }
    try db.check();
}

fn expectCleanFlash(comptime s: Spec, db: *DbOf(s)) !void {
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.violations);
}

// 900 x 100-byte keys on a 20 x 4096 byte partition; the write that hits the
// end of the partition reports `SavedFull` and every key written before it must
// still read back, including records above 0xFFFF.
test "kv_model: u32 address path fills a > 64 KiB partition until SavedFull" {
    const s = u32_spec;
    const F = FlashOf(s);
    const total: usize = 4096 * 20;
    try std.testing.expect(total > 0x10000);

    const alloc = std.heap.page_allocator;
    const mem = try alloc.alloc(u8, total);
    defer alloc.free(mem);
    @memset(mem, 0xFF);
    const entries = try alloc.create(U32Entries);
    defer alloc.destroy(entries);
    entries.* = .{};

    var db: DbOf(s) = undefined;
    try db.mount(F.init(mem));

    var value: [100]u8 = undefined;
    var i: usize = 0;
    while (i < u32_max_entries) : (i += 1) {
        const slot = entries.count;
        const key = makeU32Key(&entries.store[slot], i);
        fillPattern(&value, i);
        db.set(key, &value) catch |err| {
            try std.testing.expectEqual(error.SavedFull, err);
            entries.saw_saved_full = true;
            break;
        };
        entries.key_len[slot] = key.len;
        entries.val_len[slot] = value.len;
        entries.count += 1;
    }
    // The partition must have filled up well above 0xFFFF of payload.
    try std.testing.expect(entries.saw_saved_full);
    try std.testing.expect(entries.count >= 560);

    // At least one live record must sit above 0xFFFF.
    var max_addr: u32 = 0;
    {
        var it = db.iterator();
        while (try it.next()) |entry| {
            if (entry.addr > max_addr) max_addr = entry.addr;
        }
    }
    try std.testing.expect(max_addr > 0xFFFF);

    try verifyU32State(&db, entries, true);
    try expectCleanFlash(s, &db);

    // Remount and verify every key from flash.
    var db2: DbOf(s) = undefined;
    try db2.mount(F.init(mem));
    try db2.check();
    try std.testing.expectEqual(@as(u32, @intCast(entries.count)), try db2.count());
    try verifyU32State(&db2, entries, true);
    try expectCleanFlash(s, &db2);

    // Deleting keys that live above 0xFFFF works exactly like in the low range.
    var k: usize = 0;
    while (k < entries.count) : (k += 3) {
        try std.testing.expect(try db2.delete(entries.store[k][0..entries.key_len[k]]));
    }
    try db2.check();
    const expected_live: u32 = @intCast(entries.count - (entries.count + 2) / 3);
    try std.testing.expectEqual(expected_live, try db2.count());
    var buf: [256]u8 = undefined;
    var expect: [256]u8 = undefined;
    k = 0;
    while (k < entries.count) : (k += 1) {
        const got = try db2.get(entries.store[k][0..entries.key_len[k]], &buf);
        if (k % 3 == 0) {
            try std.testing.expectEqual(@as(?u32, null), got);
        } else {
            try std.testing.expectEqual(@as(?u32, @intCast(entries.val_len[k])), got);
            fillPattern(expect[0..entries.val_len[k]], k);
            if (!std.mem.eql(u8, expect[0..entries.val_len[k]], buf[0..entries.val_len[k]])) {
                std.debug.print("[kv_model] FAIL u32: key {d} mismatch after delete\n", .{k});
                return error.ModelMismatch;
            }
        }
    }
    var db3: DbOf(s) = undefined;
    try db3.mount(F.init(mem));
    try db3.check();
    try std.testing.expectEqual(try db2.count(), try db3.count());
    try expectCleanFlash(s, &db3);
}

// Prefill the partition past 0xFFFF, then overwrite only a few keys of the
// oldest sector so the GC that reclaims the last spare sector really has live
// records to move - at u32 addresses.
test "kv_model: u32 address path survives GC moving live records above 64 KiB" {
    const s = u32_spec;
    const F = FlashOf(s);
    const total: usize = 4096 * 20;

    const alloc = std.heap.page_allocator;
    const mem = try alloc.alloc(u8, total);
    defer alloc.free(mem);
    @memset(mem, 0xFF);
    const entries = try alloc.create(U32Entries);
    defer alloc.destroy(entries);
    entries.* = .{};

    var db: DbOf(s) = undefined;
    try db.mount(F.init(mem));

    var value: [100]u8 = undefined;
    var i: usize = 0;
    while (i < 560) : (i += 1) {
        const key = makeU32Key(&entries.store[i], i);
        fillPattern(&value, i);
        try db.set(key, &value);
        entries.key_len[i] = key.len;
        entries.val_len[i] = value.len;
        entries.count += 1;
    }
    try verifyU32State(&db, entries, false);
    var max_addr: u32 = 0;
    {
        var it = db.iterator();
        while (try it.next()) |entry| {
            if (entry.addr > max_addr) max_addr = entry.addr;
        }
    }
    try std.testing.expect(max_addr > 0xFFFF);

    // Keys 0..19 are the beginning of the oldest sector; overwriting only them
    // leaves the rest of that sector live, so collecting it moves records.
    var saw_gc = false;
    var round: usize = 0;
    while (round < 12) : (round += 1) {
        var k: usize = 0;
        while (k < 20) : (k += 1) {
            const new_len: usize = switch (round % 3) {
                0 => 40,
                1 => 0,
                else => 100,
            };
            fillPattern(&value, k);
            const erases_before = db.dev.flash.stats.erases;
            const mutations_before = db.dev.flash.mutations;
            db.set(entries.store[k][0..entries.key_len[k]], value[0..new_len]) catch |err| {
                try std.testing.expectEqual(error.SavedFull, err);
                continue;
            };
            entries.val_len[k] = new_len;
            if (db.dev.flash.stats.erases != erases_before and
                db.dev.flash.mutations - mutations_before >= 12)
            {
                saw_gc = true;
            }
        }
        try verifyU32State(&db, entries, false);
    }
    try std.testing.expect(saw_gc);
    try verifyU32State(&db, entries, true);
    try expectCleanFlash(s, &db);

    var db2: DbOf(s) = undefined;
    try db2.mount(F.init(mem));
    try db2.check();
    try verifyU32State(&db2, entries, true);
    try expectCleanFlash(s, &db2);
}
