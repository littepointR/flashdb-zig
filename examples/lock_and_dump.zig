//! Lock hooks and `dump` example: a shared KVDB with a counting lock and a
//! formatted listing through a custom sink (no `std` needed in the library).
//!
//!   .tools\zig\zig.exe build example-lock_and_dump
//!   .\zig-out\bin\example-lock_and_dump.exe

const std = @import("std");
const flashdb = @import("flashdb");

const Flash = flashdb.sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });

/// Stand-in for a mutex/ISR guard: it counts calls and asserts that the library
/// never re-enters an already held lock.
const LockCtx = struct {
    acquires: u32 = 0,
    releases: u32 = 0,
    depth: u32 = 0,

    fn acquire(ctx: ?*anyopaque) void {
        const self: *LockCtx = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(self.depth == 0);
        self.depth += 1;
        self.acquires += 1;
    }

    fn release(ctx: ?*anyopaque) void {
        const self: *LockCtx = @ptrCast(@alignCast(ctx.?));
        self.depth -= 1;
        self.releases += 1;
    }

    /// Sink callback: print each formatted chunk as-is.
    fn writeOut(ctx: ?*anyopaque, bytes: []const u8) void {
        _ = ctx;
        std.debug.print("{s}", .{bytes});
    }
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    var lock: LockCtx = .{};

    const Kv = flashdb.Kvdb(Flash, .{
        .sector_size = 4096,
        .sector_count = 4,
        .max_name_len = 32,
    });

    var mem: [16 * 1024]u8 = undefined;
    @memset(&mem, 0xFF);
    const fl = Flash.init(&mem);

    var db: Kv = undefined;
    try db.mount(fl);
    db.setLock(.{
        .acquire = LockCtx.acquire,
        .release = LockCtx.release,
        .ctx = &lock,
    });
    try db.set("boot", "7");
    try db.set("name", "flashdb");
    try db.set("blob", &[_]u8{ 0x01, 0xFE, 0x7F });
    _ = try db.delete("missing");

    std.debug.print("dump:\n", .{});
    try db.dump(.{ .ctx = &lock, .writeFn = LockCtx.writeOut });
    std.debug.print("lock: acquires={d} releases={d} depth={d}\n", .{ lock.acquires, lock.releases, lock.depth });
}
