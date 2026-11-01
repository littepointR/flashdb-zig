//! RAM-backed NOR flash simulator used by the host tests, the benchmark and the
//! Cortex-M3 firmware harness.
//!
//! It models the semantics the library depends on:
//!   * reads copy bytes,
//!   * writes may only clear bits (stored = old AND new); attempts to set a bit
//!     are counted, exactly like real NOR,
//!   * erases must be block aligned and sized, and fill the range with 0xFF,
//!   * every operation is counted (calls and bytes),
//!   * a power-cut hook can fail every operation from a chosen point onward.
//!
//! The simulator is `no_std`-friendly: it only uses `@memcpy`/loops and a
//! caller-provided byte buffer.

const std = @import("std");

pub const Stats = struct {
    reads: u64 = 0,
    read_bytes: u64 = 0,
    writes: u64 = 0,
    write_bytes: u64 = 0,
    erases: u64 = 0,
    erase_bytes: u64 = 0,
    set_bit_attempts: u64 = 0,
    violations: u64 = 0,

    pub fn reset(self: *Stats) void {
        self.* = .{};
    }
};

pub const Options = struct {
    /// Write granularity in bits (1, 8, 32, 64, 128, 256).
    write_gran_bits: u16 = 8,
    /// Erase block size in bytes.
    block_size: u32 = 4096,
};

pub fn RamFlash(comptime opts: Options) type {
    return struct {
        const Self = @This();

        pub const Error = error{ SimulatedFault, OutOfBounds, Misaligned };
        pub const write_gran_bits = opts.write_gran_bits;
        pub const erase_block_size = opts.block_size;

        const g: usize = if (write_gran_bits == 1) 1 else write_gran_bits / 8;

        mem: []u8,
        stats: Stats = .{},
        ops: u64 = 0,
        /// Mutating operations (writes + erases) seen so far.
        mutations: u64 = 0,
        fail_from: ?u64 = null,

        pub fn init(mem: []u8) Self {
            return .{ .mem = mem };
        }

        /// Fill the whole device with the erased value without touching stats.
        pub fn eraseAll(self: *Self) void {
            @memset(self.mem, 0xFF);
        }

        pub fn resetStats(self: *Self) void {
            self.stats.reset();
        }

        pub fn image(self: *const Self) []const u8 {
            return self.mem;
        }

        /// Fail every write/erase starting mutations_before_failure mutating
        /// operations from now (0 = the very next one). Reads never fail: a power
        /// cut cannot make a read return an error. Failed operations do not mutate.
        pub fn armFault(self: *Self, mutations_before_failure: u64) void {
            self.fail_from = self.mutations + mutations_before_failure;
        }

        pub fn clearFault(self: *Self) void {
            self.fail_from = null;
        }

        inline fn tickRead(self: *Self) void {
            self.ops += 1;
        }

        inline fn tickMutate(self: *Self) Error!void {
            self.ops += 1;
            const m = self.mutations;
            self.mutations = m + 1;
            if (self.fail_from) |limit| {
                if (m >= limit) return error.SimulatedFault;
            }
        }

        pub fn read(self: *Self, addr: u32, buf: []u8) Error!void {
            self.tickRead();
            if (@as(u64, addr) + buf.len > self.mem.len) {
                self.stats.violations += 1;
                return error.OutOfBounds;
            }
            @memcpy(buf, self.mem[@intCast(addr)..][0..buf.len]);
            self.stats.reads += 1;
            self.stats.read_bytes += buf.len;
        }

        pub fn write(self: *Self, addr: u32, data: []const u8) Error!void {
            try self.tickMutate();
            if (addr % g != 0 or data.len % g != 0) {
                self.stats.violations += 1;
                return error.Misaligned;
            }
            if (@as(u64, addr) + data.len > self.mem.len) {
                self.stats.violations += 1;
                return error.OutOfBounds;
            }
            const base: usize = @intCast(addr);
            for (data, 0..) |new, i| {
                const old = self.mem[base + i];
                const merged = old & new;
                if (merged != new) self.stats.set_bit_attempts += 1;
                self.mem[base + i] = merged;
            }
            self.stats.writes += 1;
            self.stats.write_bytes += data.len;
        }

        pub fn erase(self: *Self, addr: u32, len: u32) Error!void {
            try self.tickMutate();
            if (addr % erase_block_size != 0 or len % erase_block_size != 0) {
                self.stats.violations += 1;
                return error.Misaligned;
            }
            if (@as(u64, addr) + len > self.mem.len) {
                self.stats.violations += 1;
                return error.OutOfBounds;
            }
            @memset(self.mem[@intCast(addr)..][0..len], 0xFF);
            self.stats.erases += 1;
            self.stats.erase_bytes += len;
        }
    };
}

test "ram flash NOR semantics" {
    var buf: [8192]u8 = undefined;
    var fl = RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 }).init(&buf);
    fl.eraseAll();

    var one = [_]u8{0xF0};
    try fl.write(0, &one);
    var back = [_]u8{0};
    try fl.read(0, &back);
    try std.testing.expectEqual(@as(u8, 0xF0), back[0]);

    // Writing 0x0F can only clear bits -> 0x00, and the attempt is counted.
    var two = [_]u8{0x0F};
    try fl.write(0, &two);
    try fl.read(0, &back);
    try std.testing.expectEqual(@as(u8, 0x00), back[0]);
    try std.testing.expectEqual(@as(u64, 1), fl.stats.set_bit_attempts);

    try fl.erase(0, 4096);
    try fl.read(0, &back);
    try std.testing.expectEqual(@as(u8, 0xFF), back[0]);
    try std.testing.expectEqual(@as(u64, 1), fl.stats.erases);

    // Unaligned erase must be rejected without mutating; byte-granular flash
    // accepts any address/length for writes.
    try std.testing.expectError(error.Misaligned, fl.erase(1, 4096));
    try fl.write(1, &one);
}

test "ram flash fault injection" {
    var buf: [8192]u8 = undefined;
    var fl = RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 }).init(&buf);
    fl.eraseAll();
    fl.resetStats();

    fl.armFault(1);
    var one = [_]u8{0x12};
    try fl.write(0, &one);
    try std.testing.expectError(error.SimulatedFault, fl.write(1, &one));
    try std.testing.expectError(error.SimulatedFault, fl.erase(0, 4096));
    // The failed operation must not have changed flash.
    var back = [_]u8{0};
    try fl.read(1, &back);
    try std.testing.expectEqual(@as(u8, 0xFF), back[0]);
    fl.clearFault();
    try fl.write(2, &one);
}
