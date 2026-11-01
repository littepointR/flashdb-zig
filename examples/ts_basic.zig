//! TSDB example: append time-stamped logs, iterate forward, reverse and by
//! time range.
//!
//!   .tools\zig\zig.exe build examples
//!   .\zig-out\bin\example-ts_basic.exe

const std = @import("std");
const flashdb = @import("flashdb");

const NorFlash = struct {
    pub const Error = error{OutOfBounds};
    pub const write_gran_bits: u16 = 8;
    pub const erase_block_size: u32 = 4096;

    mem: []u8,

    pub fn read(self: *NorFlash, addr: u32, buf: []u8) Error!void {
        if (@as(u64, addr) + buf.len > self.mem.len) return error.OutOfBounds;
        @memcpy(buf, self.mem[addr..][0..buf.len]);
    }

    pub fn write(self: *NorFlash, addr: u32, data: []const u8) Error!void {
        if (@as(u64, addr) + data.len > self.mem.len) return error.OutOfBounds;
        for (data, 0..) |b, i| self.mem[addr + i] &= b;
    }

    pub fn erase(self: *NorFlash, addr: u32, len: u32) Error!void {
        if (@as(u64, addr) + len > self.mem.len) return error.OutOfBounds;
        @memset(self.mem[addr..][0..len], 0xFF);
    }
};

var flash_mem: [16 * 1024]u8 = @splat(0xFF);

pub fn main(init: std.process.Init) !void {
    _ = init;
    const flash = NorFlash{ .mem = &flash_mem };

    const Ts = flashdb.Tsdb(NorFlash, .{
        .sector_size = 4096,
        .sector_count = 4,
        .ts_bits = 32,
        .max_len = 32,
    });
    var db: Ts = undefined;
    try db.mount(flash);
    db.setRollover(true);

    // Append one entry per second; timestamps must be strictly increasing.
    var payload: [16]u8 = undefined;
    for (0..10) |i| {
        for (&payload, 0..) |*b, j| b.* = @truncate(i + j);
        try db.append(1000 + @as(i32, @intCast(i)), &payload);
    }
    std.debug.print("appended {d} entries, last_time={d}, capacity={d}\n", .{
        try db.count(), db.lastTime(), db.maxEntryCount(),
    });

    // Forward iteration.
    var it = db.iterator();
    var buf: [64]u8 = undefined;
    std.debug.print("forward:", .{});
    while (try it.next()) |entry| {
        const n = try it.readPayload(&buf, entry);
        std.debug.print(" t={d}({d}B)", .{ entry.time, n });
    }
    std.debug.print("\n", .{});

    // Reverse iteration.
    var rev = db.iteratorReverse();
    std.debug.print("reverse:", .{});
    while (try rev.next()) |entry| std.debug.print(" t={d}", .{entry.time});
    std.debug.print("\n", .{});

    // Range query [1003, 1006] and a count query.
    var range = db.iteratorByTime(1003, 1006);
    var count: u32 = 0;
    while (try range.next()) |_| count += 1;
    std.debug.print("range 1003..1006 = {d} entries, queryCount = {d}\n", .{
        count,
        try db.queryCount(1003, 1006, .write),
    });

    // Persistence: remount and verify the live window is intact.
    var db2: Ts = undefined;
    try db2.mount(flash);
    try db2.check();
    std.debug.print("remount ok, entries={d}, last_time={d}\n", .{ try db2.count(), db2.lastTime() });
}
