//! Host-only, file-backed flash driver (the equivalent of upstream FlashDB's
//! "file mode": keep a database in a regular file instead of a real flash chip).
//!
//! The library itself stays `no_std`: this is the only module that imports
//! `std`, and `flashdb.zig` never imports it. Use it from host tools and tests
//! that need the database to persist between process runs:
//!
//! ```zig
//! const host = @import("flashdb_host");
//! const FileFlash = host.FileFlash(.{ .file_size = 64 * 1024, .block_size = 4096 });
//!
//! var fl = try FileFlash.open(io, std.Io.Dir.cwd(), "db.bin", .open_or_create);
//! defer fl.close();
//!
//! var db: flashdb.Kvdb(FileFlash, .{ .sector_size = 4096, .sector_count = 4 }) = undefined;
//! try db.mount(fl);
//! ```
//!
//! Semantics: the file is a raw NOR image. `read`/`write` are positional I/O at
//! the byte offsets the library passes (already granule aligned), and `erase`
//! fills whole erase blocks with the erased byte (0xFF). Unlike a memory-mapped
//! NOR there is no bit-clearing enforcement, which matches upstream's file mode
//! (it writes raw bytes as well); the library never relies on the hardware to
//! reject a `0 -> 1` write.

const std = @import("std");

pub const Options = struct {
    /// Total size of the emulated device in bytes; a multiple of `block_size`.
    file_size: u32,
    /// Erase block size in bytes.
    block_size: u32 = 4096,
    /// Write granularity exposed to the library: 1, 8, 32, 64, 128 or 256 bits.
    write_gran_bits: u16 = 8,
    /// Byte value written by `erase` (NOR erased state).
    erased_byte: u8 = 0xFF,
};

/// How the backing file is obtained.
pub const Mode = enum {
    /// Fail with `error.FileNotFound` when the file does not exist.
    open,
    /// Truncate (or create) the file and pre-fill it with the erased byte.
    create,
    /// Open when present, otherwise create. This is the usual choice.
    open_or_create,
};

/// Build a flash driver type of `Options` size over a regular file.
pub fn FileFlash(comptime opts: Options) type {
    comptime {
        if (opts.file_size == 0) @compileError("file_size must be > 0");
        if (opts.block_size == 0 or opts.file_size % opts.block_size != 0)
            @compileError("file_size must be a multiple of block_size");
        switch (opts.write_gran_bits) {
            1, 8, 32, 64, 128, 256 => {},
            else => @compileError("write_gran_bits must be 1, 8, 32, 64, 128 or 256"),
        }
    }

    return struct {
        const Self = @This();

        /// Host driver: `anyerror` keeps the positional-I/O error set simple; the
        /// library unions it with its own errors.
        pub const Error = anyerror;
        pub const write_gran_bits = opts.write_gran_bits;
        pub const erase_block_size = opts.block_size;

        io: std.Io,
        file: std.Io.File,

        /// Open (or create) the backing file and return a driver over it.
        pub fn open(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, mode: Mode) !Self {
            const file = switch (mode) {
                .create => try create(io, dir, sub_path),
                .open => try dir.openFile(io, sub_path, .{ .mode = .read_write }),
                .open_or_create => dir.openFile(io, sub_path, .{ .mode = .read_write }) catch |err| switch (err) {
                    error.FileNotFound => try create(io, dir, sub_path),
                    else => return err,
                },
            };
            errdefer file.close(io);

            const size = try file.length(io);
            if (size != opts.file_size) return error.SizeMismatch;
            try file.sync(io);
            return .{ .io = io, .file = file };
        }

        fn create(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !std.Io.File {
            const file = try dir.createFile(io, sub_path, .{ .read = true, .truncate = true });
            errdefer file.close(io);

            try file.setLength(io, opts.file_size);
            // `setLength` zero-fills; a NOR image must start fully erased.
            var filler: [256]u8 = @splat(opts.erased_byte);
            var off: u32 = 0;
            while (off < opts.file_size) {
                const n = @min(@as(u32, filler.len), opts.file_size - off);
                try file.writePositionalAll(io, filler[0..n], off);
                off += n;
            }
            return file;
        }

        /// Release the file handle. The database must not be used afterwards.
        pub fn close(self: *Self) void {
            self.file.close(self.io);
        }

        /// Flush the OS cache to disk (the library never calls this itself).
        pub fn flush(self: *const Self) !void {
            try self.file.sync(self.io);
        }

        pub fn read(self: *Self, addr: u32, buf: []u8) Error!void {
            if (@as(u64, addr) + buf.len > opts.file_size) return error.OutOfBounds;
            const got = try self.file.readPositionalAll(self.io, buf, addr);
            if (got != buf.len) return error.ShortRead;
        }

        pub fn write(self: *Self, addr: u32, data: []const u8) Error!void {
            if (@as(u64, addr) + data.len > opts.file_size) return error.OutOfBounds;
            try self.file.writePositionalAll(self.io, data, addr);
        }

        pub fn erase(self: *Self, addr: u32, len: u32) Error!void {
            if (@as(u64, addr) + len > opts.file_size) return error.OutOfBounds;
            if (addr % opts.block_size != 0 or len % opts.block_size != 0) return error.UnalignedErase;
            var filler: [256]u8 = @splat(opts.erased_byte);
            var off = addr;
            while (off < addr + len) {
                const n = @min(@as(u32, filler.len), addr + len - off);
                try self.file.writePositionalAll(self.io, filler[0..n], off);
                off += n;
            }
        }
    };
}
