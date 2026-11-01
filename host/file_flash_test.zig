//! Tests for the host-only file-backed flash driver (`zig build test` runs them
//! too, so the file mode is exercised on both CI platforms).

const std = @import("std");
const flashdb = @import("flashdb");
const host = @import("flashdb_host");

const io = std.testing.io;

const FileFlash = host.FileFlash(.{
    .file_size = 32 * 1024,
    .block_size = 4096,
    .write_gran_bits = 8,
});
const Kv = flashdb.Kvdb(FileFlash, .{
    .sector_size = 4096,
    .sector_count = 4,
    .max_name_len = 32,
});

test "file-backed flash: create, erase semantics, bounds and alignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fl = try FileFlash.open(io, tmp.dir, "flash.bin", .create);
    defer fl.close();

    // A freshly created image starts in the erased state.
    var buf: [16]u8 = undefined;
    try fl.read(0, &buf);
    const erased: [16]u8 = @splat(0xFF);
    try std.testing.expectEqualSlices(u8, &erased, &buf);

    try fl.write(0, "hello");
    try fl.read(0, &buf);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..5]);

    // Erasing restores whole blocks to the erased byte.
    try fl.erase(0, 4096);
    try fl.read(0, &buf);
    try std.testing.expectEqualSlices(u8, &erased, &buf);

    // Out-of-range and unaligned accesses are rejected by the driver.
    try std.testing.expectError(error.OutOfBounds, fl.read(32 * 1024 - 1, &buf));
    try std.testing.expectError(error.OutOfBounds, fl.write(32 * 1024, "x"));
    try std.testing.expectError(error.UnalignedErase, fl.erase(1, 4096));
    try std.testing.expectError(error.UnalignedErase, fl.erase(0, 100));
}

test "file-backed flash: a KVDB image survives driver instances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var fl = try FileFlash.open(io, tmp.dir, "kv.bin", .create);
        defer fl.close();
        var db: Kv = undefined;
        try db.mount(fl);
        try db.set("boot", "1");
        try db.set("name", "file");
        try db.check();
        try fl.flush();
    }

    // Reopen the same file through a new driver value: identical contents.
    {
        var fl = try FileFlash.open(io, tmp.dir, "kv.bin", .open);
        defer fl.close();
        var db: Kv = undefined;
        try db.mount(fl);
        var buf: [16]u8 = undefined;
        const str = (try db.getString("name", &buf)).?;
        try std.testing.expectEqualSlices(u8, "file", str);
        try std.testing.expectEqual(@as(u32, 2), try db.count());
    }

    // `open_or_create` keeps an existing image intact and creates missing ones.
    {
        var fl = try FileFlash.open(io, tmp.dir, "kv.bin", .open_or_create);
        defer fl.close();
        var db: Kv = undefined;
        try db.mount(fl);
        try std.testing.expectEqual(@as(u32, 2), try db.count());
    }
    {
        var fl = try FileFlash.open(io, tmp.dir, "auto.bin", .open_or_create);
        fl.close();
    }

    // A file of the wrong size is refused instead of being silently resized.
    {
        const wrong = try tmp.dir.createFile(io, "wrong.bin", .{ .read = true, .truncate = true });
        defer wrong.close(io);
        try wrong.setLength(io, 4096);
    }
    try std.testing.expectError(error.SizeMismatch, FileFlash.open(io, tmp.dir, "wrong.bin", .open));
    try std.testing.expectError(error.FileNotFound, FileFlash.open(io, tmp.dir, "missing.bin", .open));
}
