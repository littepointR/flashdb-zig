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
