//! File-backed KVDB example: the same database over a regular file, so the data
//! survives process restarts (the equivalent of upstream FlashDB's file mode).
//!
//!   .tools\zig\zig.exe build example-file_backed
//!   .\zig-out\bin\example-file_backed.exe     # run twice: boot_count increments
//!
//! The image lives in `zig-out/file_flash_db.bin`; delete it to start over.

const std = @import("std");
const flashdb = @import("flashdb");
const host = @import("flashdb_host");

const file_size = 64 * 1024;

const FileFlash = host.FileFlash(.{
    .file_size = file_size,
    .block_size = 4096,
    .write_gran_bits = 8,
});

const Kv = flashdb.Kvdb(FileFlash, .{
    .sector_size = 4096,
    .sector_count = 4,
    .max_name_len = 32,
});

const db_path = "zig-out/file_flash_db.bin";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const dir = std.Io.Dir.cwd();

    var fl = try FileFlash.open(io, dir, db_path, .open_or_create);
    defer fl.close();

    var db: Kv = undefined;
    try db.mount(fl);

    // Defaults are only created when missing, so this is safe on every start.
    const defaults = [_]Kv.DefaultKv{
        .{ .key = "note", .value = "file-backed" },
    };
    _ = try db.applyDefaults(&defaults);

    var buf: [16]u8 = undefined;
    var boots: u32 = 0;
    if (try db.get("boot_count", &buf)) |len| {
        if (len == 4) boots = flashdb.format.rd32(&buf);
    }
    std.debug.print("previous boot_count = {d}\n", .{boots});

    boots += 1;
    var value: [4]u8 = undefined;
    flashdb.format.wr32(&value, boots);
    try db.set("boot_count", &value);
    try db.check();
    std.debug.print("stored boot_count = {d} ({d} live keys)\n", .{ boots, try db.count() });

    // A remount through a fresh driver value sees the same file contents.
    try fl.flush();
    var fl2 = try FileFlash.open(io, dir, db_path, .open);
    defer fl2.close();
    var db2: Kv = undefined;
    try db2.mount(fl2);
    if (try db2.get("boot_count", &buf)) |len| {
        std.debug.print("remount sees boot_count = {d}\n", .{flashdb.format.rd32(&buf)});
        _ = len;
    }
    std.debug.print("file: {s} ({d} bytes)\n", .{ db_path, file_size });
}
