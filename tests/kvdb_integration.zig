//! KVDB integration tests on top of the public module API.

const std = @import("std");
const flashdb = @import("flashdb");

const Flash = flashdb.sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });
const Db = flashdb.Kvdb(Flash, .{ .sector_size = 4096, .sector_count = 4 });

fn fresh(mem: []u8) Flash {
    var f = Flash.init(mem);
    f.eraseAll();
    return f;
}

test "prepare/commit/abort semantics through the public API" {
    var mem: [16 * 1024]u8 = undefined;
    var db: Db = undefined;
    try db.mount(fresh(&mem));

    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    for (keys, 0..) |k, i| {
        var v: [64]u8 = undefined;
        for (&v, 0..) |*b, j| b.* = @truncate(i * 10 + j);
        try db.set(k, &v);
    }
    try std.testing.expectEqual(@as(u32, 4), try db.count());

    // Delete one, rewrite it, then verify the whole set after a remount.
    try std.testing.expect(try db.delete("beta"));
    try db.set("beta", "reborn");
    var db2: Db = undefined;
    try db2.mount(Flash.init(&mem));
    try db2.check();
    try std.testing.expectEqual(@as(u32, 4), try db2.count());
    var buf: [64]u8 = undefined;
    const n = (try db2.get("beta", &buf)).?;
    try std.testing.expectEqualSlices(u8, "reborn", buf[0..n]);
    try std.testing.expectEqual(@as(u32, 0), db2.dev.flash.stats.violations);
}

test "Partition adapter slices one device into independent KV and TS databases" {
    const Part = flashdb.flash.Partition(Flash);
    var mem: [32 * 1024]u8 = undefined;
    @memset(&mem, 0xFF);
    var fl = Flash.init(&mem);

    var kv_part: Part = .{ .dev = &fl, .offset = 0, .len = 16 * 1024 };
    var ts_part: Part = .{ .dev = &fl, .offset = 16 * 1024, .len = 16 * 1024 };

    var kv: flashdb.Kvdb(Part, .{ .sector_size = 4096, .sector_count = 4 }) = undefined;
    try kv.mount(kv_part);
    try kv.set("name", "partitioned");
    var buf: [16]u8 = undefined;
    const n = (try kv.get("name", &buf)).?;
    try std.testing.expectEqualSlices(u8, "partitioned", buf[0..n]);

    var ts: flashdb.Tsdb(Part, .{ .sector_size = 4096, .sector_count = 4, .max_len = 16 }) = undefined;
    try ts.mount(ts_part);
    try ts.append(1000, "first");
    try ts.append(1001, "second");
    var it = ts.iterator();
    var count: u32 = 0;
    while (try it.next()) |entry| {
        count += 1;
        try std.testing.expectEqual(@as(u32, 1000 + count - 1), @as(u32, @intCast(entry.time)));
    }
    try std.testing.expectEqual(@as(u32, 2), count);

    // The two partitions did not overlap: the KV partition was only touched by KV.
    try std.testing.expect(fl.stats.writes > 0);
    try std.testing.expectEqual(@as(u64, 0), fl.stats.violations);

    // A partition is bounds checked: accesses beyond its length are rejected.
    try std.testing.expectError(error.OutOfBounds, kv_part.read(16 * 1024, &buf));
    try std.testing.expectError(error.OutOfBounds, kv_part.write(16 * 1024 - 2, &[_]u8{ 0, 0, 0, 0 }));
    try std.testing.expectError(error.OutOfBounds, ts_part.erase(16 * 1024, 4096));
}

test "driver protocol helpers and simulator image" {
    const Sim = flashdb.sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });
    const Wide = flashdb.sim.RamFlash(.{ .write_gran_bits = 32, .block_size = 4096 });
    try std.testing.expectEqual(@as(usize, 1), flashdb.flash.granBytes(Sim));
    try std.testing.expectEqual(@as(u8, 0), flashdb.flash.granLog2(Sim));
    try std.testing.expectEqual(@as(usize, 4), flashdb.flash.granBytes(Wide));
    try std.testing.expectEqual(@as(u8, 2), flashdb.flash.granLog2(Wide));

    var mem: [8192]u8 = undefined;
    var fl = Sim.init(&mem);
    fl.eraseAll();
    try std.testing.expectEqual(mem.len, fl.image().len);
    try std.testing.expectEqual(@as(u8, 0xFF), fl.image()[0]);
}

test "tsdb insert alias and user status transitions" {
    const Sim = flashdb.sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });
    const Ts = flashdb.Tsdb(Sim, .{ .sector_size = 4096, .sector_count = 4, .max_len = 16 });
    var mem: [16 * 1024]u8 = undefined;
    @memset(&mem, 0xFF);
    const fl = Sim.init(&mem);
    var ts: Ts = undefined;
    try ts.mount(fl);

    try ts.insert(7, "abc");
    try ts.append(8, "de");
    var it = ts.iterator();
    const first = (try it.next()).?;
    try std.testing.expectEqual(@as(i32, 7), first.time);
    try std.testing.expectEqual(@as(u32, 3), first.len);
    try std.testing.expectEqual(Ts.Status.write, first.status);

    // Forward-only status migration marks the entry as consumed.
    try ts.setStatus(first, .user1);
    var again = ts.iterator();
    const updated = (try again.next()).?;
    try std.testing.expectEqual(Ts.Status.user1, updated.status);
    try std.testing.expectEqual(@as(u32, 1), try ts.queryCount(7, 7, .user1));
    try std.testing.expectEqual(@as(u32, 1), try ts.queryCount(8, 8, .write));
}
test "format granule helpers" {
    try std.testing.expect(flashdb.format.granuleIsErased(1, &[_]u8{0xFF}));
    try std.testing.expect(!flashdb.format.granuleIsErased(1, &[_]u8{0x00}));
    try std.testing.expect(flashdb.format.granuleIsZero(4, &[_]u8{ 0, 0, 0, 0 }));
    try std.testing.expect(!flashdb.format.granuleIsZero(4, &[_]u8{ 0, 0, 0, 1 }));
}