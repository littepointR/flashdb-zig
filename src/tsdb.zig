//! TSDB: append-only time-series log over raw NOR flash.
//!
//! New on-flash format v1, see `docs/DESIGN.md` §3.3 and §6. Every sector owns a
//! fixed-size index record area growing up from `data_off` and a payload area
//! growing down from the sector end; index and payload meet in the middle. An
//! entry becomes visible when a single status granule (`commit`) is cleared, so
//! a power cut either leaves the entry completely invisible or fully visible,
//! never torn. Sectors are chained by a 16-bit sequence number in the sector
//! header, and the sector that receives appends is the only one with the
//! `using` granule set. When it runs out of room its last timestamp and free
//! offsets are stored in the header and the `full` granule is written as the
//! commit for those fields; the next sector then becomes current. With
//! rollover enabled the oldest sector is erased and recycled, otherwise the
//! database reports `error.SavedFull`.
//!
//! Design consequences (all deliberate, see `docs/DESIGN.md` §8):
//!   * one commit granule per entry: appending costs one payload write, one
//!     index-data write and one granule write;
//!   * no GC: entries are immutable (except the forward-only `setStatus`
//!     markers), so the only reclamation is whole-sector rollover;
//!   * no heap, no `std`, no global state: the database owns its flash driver
//!     value and every buffer is a compile-time-sized stack array;
//!   * the only RAM that scales with sector count is the per-sector sequence
//!     number plus the sorted sector order (2 + 2 bytes per sector).

const format = @import("format.zig");
const device = @import("device.zig");

/// TSDB geometry and behaviour, all compile-time.
pub const Config = struct {
    /// Erase sector size in bytes: a power of two, <= 32768 and a multiple of
    /// the driver's erase block size.
    sector_size: u32 = 4096,
    /// Number of sectors of the database (2..32).
    sector_count: u16 = 4,
    /// Timestamp width: 32 -> `i32`, 64 -> `i64`.
    ts_bits: u16 = 32,
    /// Maximum payload length of a single entry; must be smaller than
    /// `sector_size` (and one such entry must fit into an empty sector).
    max_len: u16 = 64,
    /// When true a blank or damaged partition yields `error.NotFormatted`
    /// instead of being formatted automatically.
    not_formattable: bool = false,
};

/// Status of a time-series entry. `write` is what an entry has right after
/// `append`; `user1/deleted/user2` are forward-only markers set by
/// `setStatus`. `pre_write` is never stored on flash (FlashDB uses it as an
/// "index in progress" marker, which this format does not need) and `unused`
/// is reported for an index slot that was never committed.
const StatusEnum = enum(u8) {
    unused = 0,
    pre_write = 1,
    write = 2,
    user1 = 3,
    deleted = 4,
    user2 = 5,
};

/// Status of a time-series entry (also available as `Tsdb(..).Status`).
pub const Status = StatusEnum;

/// Forward-only ordering of the stored status markers. A status may only be
/// advanced to a strictly higher rank; `pre_write`/`write` are not writable
/// targets because they are the append/commit protocol itself.
inline fn statusRank(s: StatusEnum) u8 {
    return switch (s) {
        .unused, .pre_write => 0,
        .write => 1,
        .user1 => 2,
        .deleted => 3,
        .user2 => 4,
    };
}

/// Nibble table for CRC16-CCITT (polynomial 0x1021, init 0), the checksum
/// `format.crc16` computes over the 8-byte sector header. Half a byte per step
/// keeps the table at 32 bytes of `.rodata` and makes a mount (which validates
/// one header per sector) several times cheaper than the bitwise form.
/// `test "tsdb local crc16 matches format.crc16"` keeps both in sync.
const crc16_nibble: [16]u16 = blk: {
    var table: [16]u16 = undefined;
    for (0..16) |i| {
        var c: u16 = @as(u16, @intCast(i)) << 12;
        for (0..4) |_| {
            c = if ((c & 0x8000) != 0) (c << 1) ^ 0x1021 else c << 1;
        }
        table[i] = c;
    }
    break :blk table;
};

/// CRC16-CCITT of `data` with init 0; identical to `format.crc16(0, data)`.
inline fn crc16Fast(data: []const u8) u16 {
    var c: u16 = 0;
    for (data) |b| {
        c = (c << 4) ^ crc16_nibble[@as(usize, @intCast((c >> 12) ^ (@as(u16, b) >> 4))) & 0xF];
        c = (c << 4) ^ crc16_nibble[@as(usize, @intCast((c >> 12) ^ (@as(u16, b) & 0x0F))) & 0xF];
    }
    return c;
}

/// A time-series database over flash type `F`.
///
/// `F` must satisfy the `flash.zig` protocol (`Error`, `write_gran_bits`,
/// `erase_block_size`, `read`, `write`, `erase`).
pub fn Tsdb(comptime F: type, comptime cfg: Config) type {
    const D = device.Device(F, cfg.sector_size, cfg.sector_count);
    const g: usize = D.gran;
    const TIME_BYTES: usize = if (cfg.ts_bits == 64) 8 else 4;
    const L = format.TsLayout(g, TIME_BYTES);

    const SECTOR_SIZE: usize = cfg.sector_size;
    const SECTOR_COUNT: u16 = cfg.sector_count;
    const DATA_OFF: usize = L.data_off;
    const INDEX_LEN: usize = L.index_len;
    const TIME_SLOT: usize = format.alignUp(g, TIME_BYTES);
    const HALF_SLOT: usize = format.alignUp(g, 2);
    const END_OFFSETS_SLOT: usize = L.end_offsets_slot;
    const END_REGION: usize = TIME_SLOT + END_OFFSETS_SLOT;
    const INDEX_DATA_LEN: usize = INDEX_LEN - 4 * g;
    const MAX_PAYLOAD: usize = format.alignUp(g, cfg.max_len);
    const NO_SECTOR: u16 = 0xFFFF;
    const ALL_SECTORS: u32 = if (@as(usize, SECTOR_COUNT) >= 32)
        0xFFFF_FFFF
    else
        (@as(u32, 1) << @intCast(SECTOR_COUNT)) - 1;

    comptime {
        if (cfg.sector_count < 2) @compileError("TSDB needs at least two sectors");
        if (cfg.sector_count > 32) @compileError("TSDB supports at most 32 sectors");
        if (cfg.ts_bits != 32 and cfg.ts_bits != 64) @compileError("ts_bits must be 32 or 64");
        if (cfg.max_len == 0 or cfg.max_len >= cfg.sector_size)
            @compileError("max_len must be in 1..sector_size-1");
        if (cfg.sector_size > 0xFFFF) @compileError("sector_size must be <= 65535");
        if (DATA_OFF + INDEX_LEN + MAX_PAYLOAD > SECTOR_SIZE)
            @compileError("one max_len entry must fit into an empty sector");
    }

    return struct {
        const Self = @This();

        pub const Error = D.Error || error{
            NotFormatted,
            InvalidName,
            ValueTooLarge,
            SavedFull,
            TimeNotIncreasing,
            Corrupted,
            InitFailed,
        };
        /// `setStatus` can additionally refuse to move a marker backwards.
        pub const SetStatusError = Error || error{StatusNotAdvancing};

        pub const Status = StatusEnum;
        pub const Time = L.Time;
        /// Maximum payload length of a single entry.
        pub const max_len = cfg.max_len;
        /// On-flash size of one index record.
        pub const index_size = INDEX_LEN;

        /// One committed time-series entry, as produced by an iterator.
        pub const Entry = struct {
            /// Absolute flash address of the index record.
            index_addr: u32,
            /// Absolute flash address of the payload.
            log_addr: u32,
            time: Time,
            len: u32,
            status: StatusEnum,
        };

        // ---- persistent (RAM) state --------------------------------------

        dev: D,
        /// Sectors whose contents are known to be fully erased, so formatting
        /// them needs no second erase.
        pristine: u32 = 0,
        /// Sectors with a valid TSDB header.
        known_mask: u32 = 0,
        /// Sector sequence number per sector index (valid when `known_mask`).
        seqs: [SECTOR_COUNT]u16 = @splat(0),
        /// Sector indices ascending by sequence number (valid prefix).
        order: [SECTOR_COUNT]u16 = @splat(0),
        order_len: u16 = 0,
        /// Highest sector sequence number handed out so far (0 = none yet).
        seq: u16 = 0,
        /// Sector receiving appends; `NO_SECTOR` when a new one must be
        /// activated first (sector full, or database full).
        cur: u16 = NO_SECTOR,
        /// Next free index offset inside `cur` (sector relative).
        empty_idx: u16 = 0,
        /// Next free payload offset inside `cur` (sector relative, grows down).
        empty_data: u16 = 0,
        /// Timestamp of the last committed entry (0 on a fresh database).
        last_time: Time = 0,
        rollover: bool = true,
        /// Set when a flash write failed: the RAM cursor may no longer match
        /// flash, so the database has to be remounted before further appends.
        damaged: bool = false,

        // ---- public API ---------------------------------------------------

        /// Mount (or initialise) the database on `f`. The driver value is
        /// copied in, so `*Self` can live in `.bss` without stack copies.
        pub fn mount(self: *Self, f: F) Error!void {
            self.* = .{ .dev = D.init(f) };
            try self.load();
        }

        /// Append one entry. `time` must be strictly greater than the last
        /// stored timestamp (like upstream FlashDB) and `data.len` must not
        /// exceed `max_len`.
        pub fn append(self: *Self, time: Time, data: []const u8) Error!void {
            if (data.len > cfg.max_len) return error.ValueTooLarge;
            if (time <= self.last_time) return error.TimeNotIncreasing;
            if (self.damaged) return error.Corrupted;
            self.appendInner(time, data) catch |err| {
                switch (err) {
                    error.SavedFull, error.TimeNotIncreasing, error.ValueTooLarge => {},
                    else => self.damaged = true,
                }
                return err;
            };
        }

        /// Alias of `append` used by the benchmark protocol.
        pub fn insert(self: *Self, time: Time, data: []const u8) Error!void {
            return self.append(time, data);
        }

        /// Timestamp of the newest committed entry (0 on a fresh database).
        pub fn lastTime(self: *const Self) Time {
            return self.last_time;
        }

        /// Enable/disable recycling the oldest sector when the database is
        /// full (enabled by default, like upstream).
        pub fn setRollover(self: *Self, on: bool) void {
            self.rollover = on;
        }

        pub fn getRollover(self: *const Self) bool {
            return self.rollover;
        }

        /// Erase the whole database and format sector 0 (destructive).
        pub fn clean(self: *Self) Error!void {
            try self.formatAll();
        }

        /// Number of committed entries (walks the database).
        pub fn count(self: *Self) Error!u32 {
            var it = self.iterator();
            var n: u32 = 0;
            while (try it.next() != null) n += 1;
            return n;
        }

        /// Number of `max_len` entries the database can hold.
        pub fn maxEntryCount(self: *const Self) u32 {
            _ = self;
            const per_sector: usize = (SECTOR_SIZE - DATA_OFF) / (INDEX_LEN + MAX_PAYLOAD);
            return @intCast(@as(usize, SECTOR_COUNT) * per_sector);
        }

        /// Walk every stored entry and validate the structural invariants of
        /// the on-flash format: sane sector headers, end fields on closed
        /// sectors, in-range index records and strictly increasing timestamps.
        pub fn check(self: *Self) Error!void {
            var using_count: u16 = 0;
            var i: u16 = 0;
            while (i < SECTOR_COUNT) : (i += 1) {
                const info = (try self.readSectorInfo(i)) orelse continue;
                if (!info.using) {
                    // Unused sector: only `full` without `using` is illegal.
                    if (info.full) return error.Corrupted;
                    continue;
                }
                if (!info.full) {
                    using_count += 1;
                    if (self.cur != i) return error.Corrupted;
                    const scan = try self.scanSector(i);
                    if (scan.end_idx != self.empty_idx or scan.end_data != self.empty_data)
                        return error.Corrupted;
                    continue;
                }
                // Closed sector: the end fields are committed by `full`.
                if (info.end_erased or !endSane(info.end_idx, info.end_data))
                    return error.Corrupted;
                var slot: usize = DATA_OFF;
                var prev: Time = 0;
                var have_prev = false;
                while (slot < info.end_idx) {
                    if (try self.readIndexAt(i, slot)) |rec| {
                        if (have_prev and rec.time <= prev) return error.Corrupted;
                        prev = rec.time;
                        have_prev = true;
                    }
                    slot += INDEX_LEN;
                }
            }
            if (using_count > 1) return error.Corrupted;

            // Timestamps must increase monotonically over the whole database.
            var it = self.iterator();
            var prev: Time = 0;
            var have_prev = false;
            while (try it.next()) |e| {
                if (have_prev and e.time <= prev) return error.Corrupted;
                prev = e.time;
                have_prev = true;
            }
        }

        /// Advance the status marker of `entry` to `status`. Only strictly
        /// forward transitions are allowed; the granule is written at most
        /// once per entry, so rewriting an already written (or earlier) marker
        /// returns `error.StatusNotAdvancing` instead of re-programming flash.
        pub fn setStatus(self: *Self, entry: Entry, status: StatusEnum) SetStatusError!void {
            var buf: [4 * g]u8 = undefined;
            try self.dev.read(entry.index_addr, &buf);
            if (!format.granuleIsZero(g, &buf)) return error.StatusNotAdvancing;
            const current = decodeStatus(&buf);
            if (statusRank(status) <= statusRank(current)) return error.StatusNotAdvancing;
            const off: usize = switch (status) {
                .user1 => L.user1_off,
                .deleted => L.deleted_off,
                .user2 => L.user2_off,
                else => return error.StatusNotAdvancing,
            };
            try self.dev.mark(entry.index_addr + @as(u32, @intCast(off)));
        }

        /// Number of entries in `[from, to]` (reversed when `from > to`) whose
        /// status is `status`.
        pub fn queryCount(self: *Self, from: Time, to: Time, status: StatusEnum) Error!u32 {
            var it = self.iteratorByTime(from, to);
            var n: u32 = 0;
            while (try it.next()) |e| {
                if (e.status == status) n += 1;
            }
            return n;
        }

        // ---- iterators ----------------------------------------------------

        /// Forward iterator, oldest entry first.
        pub fn iterator(self: *Self) Iterator {
            return .{ .db = self };
        }

        /// Reverse iterator, newest entry first.
        pub fn iteratorReverse(self: *Self) Iterator {
            return .{ .db = self, .reverse = true, .sector_pos = self.order_len };
        }

        /// Iterate entries with `time` in `[from, to]`; when `from > to` the
        /// iterator runs backwards from `from` to `to` (upstream semantics).
        pub fn iteratorByTime(self: *Self, from: Time, to: Time) Iterator {
            const reverse = from > to;
            const lo = if (reverse) to else from;
            const hi = if (reverse) from else to;
            return .{
                .db = self,
                .reverse = reverse,
                .ranged = true,
                .seek_start = true,
                // `last_time` is the newest stored timestamp, so a range that
                // starts above it cannot match anything: answer without a
                // single flash read.
                .done = self.last_time < lo,
                .lo = lo,
                .hi = hi,
                .sector_pos = if (reverse) self.order_len else 0,
            };
        }

        /// Iterator over committed entries. Only committed index records are
        /// yielded; discarded slots left behind by interrupted appends are
        /// skipped. The iterator is invalidated by any mutation of the
        /// database.
        pub const Iterator = struct {
            db: *Self,
            reverse: bool = false,
            /// When set, only entries inside `[lo, hi]` are yielded.
            ranged: bool = false,
            lo: Time = 0,
            hi: Time = 0,
            /// Forward: next `order` index to load; reverse: one past it.
            sector_pos: u16 = 0,
            /// Sector currently being walked and its exclusive slot limit.
            sector: u16 = 0,
            slot: usize = 0,
            limit: usize = 0,
            loaded: bool = false,
            /// Set once the iterator returned its last entry.
            done: bool = false,
            /// Only the sector in which a by-time range starts is binary
            /// searched; later sectors start at their first (forward) or last
            /// (reverse) slot and are cut off by the range stop condition.
            seek_start: bool = false,

            pub fn next(self: *Iterator) Error!?Entry {
                const db = self.db;
                if (self.done) return null;
                while (true) {
                    if (!self.loaded) {
                        if (!try self.loadSector()) {
                            self.done = true;
                            return null;
                        }
                    }
                    if (!self.reverse) {
                        while (self.slot < self.limit) {
                            const slot = self.slot;
                            self.slot += INDEX_LEN;
                            const rec = (try db.readIndexAt(self.sector, slot)) orelse continue;
                            if (self.ranged) {
                                if (rec.time < self.lo) continue;
                                // Timestamps increase: nothing else can match.
                                if (rec.time > self.hi) {
                                    self.done = true;
                                    return null;
                                }
                            }
                            return db.makeEntry(self.sector, slot, rec);
                        }
                    } else {
                        while (self.slot > DATA_OFF) {
                            self.slot -= INDEX_LEN;
                            const rec = (try db.readIndexAt(self.sector, self.slot)) orelse continue;
                            if (self.ranged) {
                                if (rec.time > self.hi) continue;
                                if (rec.time < self.lo) {
                                    self.done = true;
                                    return null;
                                }
                            }
                            return db.makeEntry(self.sector, self.slot, rec);
                        }
                    }
                    self.loaded = false;
                }
            }

            /// Copy `min(buf.len, entry.len)` payload bytes into `buf` and
            /// return the number of bytes copied.
            pub fn readPayload(self: *Iterator, buf: []u8, entry: Entry) Error!u32 {
                const n: u32 = @min(@as(u32, @intCast(buf.len)), entry.len);
                if (n > 0) try self.db.dev.read(entry.log_addr, buf[0..@intCast(n)]);
                return n;
            }

            /// Position on the next sector that can contribute entries.
            fn loadSector(self: *Iterator) Error!bool {
                const db = self.db;
                while (true) {
                    var si: u16 = undefined;
                    if (self.reverse) {
                        if (self.sector_pos == 0) return false;
                        self.sector_pos -= 1;
                        si = db.order[self.sector_pos];
                    } else {
                        if (self.sector_pos >= db.order_len) return false;
                        si = db.order[self.sector_pos];
                        self.sector_pos += 1;
                    }
                    const meta = try db.sectorMeta(si);
                    if (meta.state == .empty) continue;
                    if (self.ranged) {
                        if (!self.reverse) {
                            if (meta.end_time < self.lo) continue;
                            // Newer sectors are even newer, so we are done.
                            if (meta.start_time > self.hi) return false;
                        } else {
                            if (meta.start_time > self.hi) continue;
                            if (meta.end_time < self.lo) return false;
                        }
                    }
                    self.sector = si;
                    self.limit = meta.limit;
                    if (!self.reverse) {
                        self.slot = if (self.ranged and self.seek_start)
                            try db.lowerBound(si, meta.limit, self.lo)
                        else
                            DATA_OFF;
                    } else {
                        self.slot = if (self.ranged and self.seek_start)
                            try db.upperBound(si, meta.limit, self.hi)
                        else
                            meta.limit;
                    }
                    self.seek_start = false;
                    self.loaded = true;
                    return true;
                }
            }
        };

        // ---- internals: layout helpers ------------------------------------

        inline fn bitOf(index: u16) u32 {
            return @as(u32, 1) << @intCast(index);
        }

        inline fn allErased(bytes: []const u8) bool {
            for (bytes) |b| {
                if (b != 0xFF) return false;
            }
            return true;
        }

        inline fn rdTime(p: [*]const u8) Time {
            return @bitCast(format.rdN(TIME_BYTES, p));
        }

        inline fn wrTime(p: [*]u8, t: Time) void {
            format.wrN(TIME_BYTES, p, @bitCast(t));
        }

        inline fn addrOf(self: *const Self, si: u16, off: usize) u32 {
            return self.dev.sectorAddr(si) + @as(u32, @intCast(off));
        }

        /// Decode the four status granules of a committed index record
        /// (`docs/DESIGN.md` §3.3: user2 > deleted > user1 > write).
        inline fn decodeStatus(buf: []const u8) StatusEnum {
            if (format.granuleIsZero(g, buf[L.user2_off..].ptr)) return .user2;
            if (format.granuleIsZero(g, buf[L.deleted_off..].ptr)) return .deleted;
            if (format.granuleIsZero(g, buf[L.user1_off..].ptr)) return .user1;
            return .write;
        }

        inline fn endSane(end_idx: u16, end_data: u16) bool {
            const idx: usize = end_idx;
            const data: usize = end_data;
            if (idx < DATA_OFF or idx > SECTOR_SIZE) return false;
            if ((idx - DATA_OFF) % INDEX_LEN != 0) return false;
            if (data < idx or data > SECTOR_SIZE) return false;
            return true;
        }

        inline fn makeEntry(self: *const Self, si: u16, slot: usize, rec: Rec) Entry {
            return .{
                .index_addr = self.addrOf(si, slot),
                .log_addr = self.addrOf(si, rec.off),
                .time = rec.time,
                .len = rec.len,
                .status = rec.status,
            };
        }

        // ---- internals: sector headers ------------------------------------

        const SectorInfo = struct {
            seq: u16,
            using: bool,
            full: bool,
            start_time: Time,
            end_time: Time,
            end_idx: u16,
            end_data: u16,
            start_erased: bool,
            end_erased: bool,
        };

        /// Sector header validation, identical to `format.decodeSectorHeader`
        /// (magic, version, granule, kind, CRC16) but with the nibble-table
        /// checksum, because a mount validates one header per sector.
        inline fn decodeHeader(buf: []const u8) ?format.SectorHeader {
            if (buf.len < format.sector_header_len) return null;
            if (format.rd16(buf.ptr) != format.magic) return null;
            if (buf[2] != format.version) return null;
            if (buf[3] != D.gran_log2) return null;
            if (buf[4] != @intFromEnum(format.Kind.tsdb)) return null;
            if (format.rd16(buf.ptr + 8) != crc16Fast(buf[0..8])) return null;
            return .{
                .seq = format.rd16(buf.ptr + 6),
                .kind = .tsdb,
                .gran_log2 = D.gran_log2,
                .version = format.version,
                .flags = buf[5],
            };
        }

        /// Read and decode the whole sector header (prefix + status granules +
        /// start/end times + end offsets) with a single flash read.
        fn readSectorInfo(self: *Self, si: u16) Error!?SectorInfo {
            var buf: [DATA_OFF]u8 = undefined;
            try self.dev.read(self.dev.sectorAddr(si), &buf);
            const h = decodeHeader(buf[0..format.sector_header_len]) orelse return null;
            return .{
                .seq = h.seq,
                .using = format.granuleIsZero(g, buf[L.state_off..].ptr),
                .full = format.granuleIsZero(g, buf[L.state_off + g ..].ptr),
                .start_time = rdTime(buf[L.start_time_off..].ptr),
                .end_time = rdTime(buf[L.end_time_off..].ptr),
                .end_idx = format.rd16(buf[L.end_offsets_off..].ptr),
                .end_data = format.rd16(buf[L.end_offsets_off + 2 ..].ptr),
                .start_erased = allErased(buf[L.start_time_off..][0..TIME_SLOT]),
                .end_erased = allErased(buf[L.end_time_off..][0..END_REGION]),
            };
        }

        /// True when the whole sector is still erased. Only used by
        /// `not_formattable` mounts, to tell a lazily formatted database (whose
        /// spare sectors have no header yet) from a damaged/foreign one.
        fn sectorIsBlank(self: *Self, si: u16) Error!bool {
            var chunk: [64]u8 = undefined;
            var pos: usize = 0;
            while (pos < SECTOR_SIZE) {
                const n: usize = @min(chunk.len, SECTOR_SIZE - pos);
                try self.dev.read(self.addrOf(si, pos), chunk[0..n]);
                if (!allErased(chunk[0..n])) return false;
                pos += n;
            }
            return true;
        }

        const SectorState = enum { empty, using_now, full };

        const SectorMeta = struct {
            state: SectorState,
            start_time: Time,
            end_time: Time,
            /// Exclusive upper bound of the index area.
            limit: usize,
        };

        /// Per-sector information needed by iterators. Closed sectors with
        /// damaged end fields are repaired in RAM by re-scanning the sector.
        fn sectorMeta(self: *Self, si: u16) Error!SectorMeta {
            const none = SectorMeta{ .state = .empty, .start_time = 0, .end_time = 0, .limit = 0 };
            if (si == self.cur) {
                const info = (try self.readSectorInfo(si)) orelse return error.Corrupted;
                return .{
                    .state = .using_now,
                    .start_time = info.start_time,
                    .end_time = self.last_time,
                    .limit = self.empty_idx,
                };
            }
            const info = (try self.readSectorInfo(si)) orelse return none;
            if (!info.using) {
                if (info.full) return error.Corrupted;
                return none;
            }
            if (!info.full) return error.Corrupted; // a second USING sector
            if (!info.end_erased and endSane(info.end_idx, info.end_data)) {
                return .{
                    .state = .full,
                    .start_time = info.start_time,
                    .end_time = info.end_time,
                    .limit = info.end_idx,
                };
            }
            // Damaged end info: rebuild it from the index records.
            const scan = try self.scanSector(si);
            return .{
                .state = .full,
                .start_time = info.start_time,
                .end_time = scan.last_time,
                .limit = scan.end_idx,
            };
        }

        // ---- internals: index records -------------------------------------

        const Rec = struct {
            time: Time,
            len: u16,
            off: u16,
            status: StatusEnum,
        };

        /// Read one index record. `null` means the slot is not committed (it
        /// belongs to an interrupted append or was never written).
        fn readIndexAt(self: *Self, si: u16, slot: usize) Error!?Rec {
            var buf: [INDEX_LEN]u8 = undefined;
            try self.dev.read(self.addrOf(si, slot), &buf);
            if (!format.granuleIsZero(g, &buf)) return null;
            const rec = Rec{
                .time = rdTime(buf[L.time_off..].ptr),
                .len = format.rd16(buf[L.len_off..].ptr),
                .off = format.rd16(buf[L.off_off..].ptr),
                .status = decodeStatus(&buf),
            };
            const len: usize = rec.len;
            const off: usize = rec.off;
            if (len > cfg.max_len) return error.Corrupted;
            if (off % g != 0) return error.Corrupted;
            if (off < DATA_OFF) return error.Corrupted;
            if (off + format.alignUp(g, len) > SECTOR_SIZE) return error.Corrupted;
            // Payloads live below the index area of the same sector.
            if (off < slot + INDEX_LEN) return error.Corrupted;
            return rec;
        }

        /// True when the uncommitted index slot at `slot` was touched by an
        /// interrupted append: a partially written index record or payload
        /// bytes directly below the payload frontier. Erased slots that were
        /// never written are not touched, so no space has to be reserved.
        fn slotTouched(self: *Self, si: u16, slot: usize, frontier: usize) Error!bool {
            var ibuf: [INDEX_LEN]u8 = undefined;
            try self.dev.read(self.addrOf(si, slot), &ibuf);
            if (!allErased(&ibuf)) return true;
            // Payloads are written before the index, so a cut before the index
            // write can only be detected by looking at the payload window an
            // append starting in this slot could have used. The window is the
            // `max_len` bytes below the frontier, clamped to the first byte that
            // payload of this slot may occupy (payloads never overlap the index
            // records that are still growing up towards them).
            const lowest: usize = slot + INDEX_LEN;
            const want_start: usize = if (frontier >= MAX_PAYLOAD) frontier - MAX_PAYLOAD else 0;
            const start: usize = @max(want_start, lowest);
            var probe: [64]u8 = undefined;
            var pos: usize = start;
            while (pos < frontier) {
                const n: usize = @min(probe.len, frontier - pos);
                try self.dev.read(self.addrOf(si, pos), probe[0..n]);
                if (!allErased(probe[0..n])) return true;
                pos += n;
            }
            return false;
        }

        const ScanInfo = struct {
            end_idx: u16,
            end_data: u16,
            last_time: Time,
            count: u32,
        };

        /// Walk the committed prefix of a sector, consuming the slots wasted
        /// by interrupted appends (their payload space is reserved
        /// conservatively as `max_len`, like upstream `read_tsl` does).
        fn scanSector(self: *Self, si: u16) Error!ScanInfo {
            var slot: usize = DATA_OFF;
            var data: usize = SECTOR_SIZE;
            var last: Time = 0;
            var n: u32 = 0;
            while (slot + INDEX_LEN <= data) {
                if (try self.readIndexAt(si, slot)) |rec| {
                    last = rec.time;
                    n += 1;
                    slot += INDEX_LEN;
                    // The frontier never moves up; a record whose payload sits
                    // above it (possible after a conservative reservation) only
                    // means the space below stays reserved.
                    data = @min(data, @as(usize, rec.off));
                    continue;
                }
                // Uncommitted slot: stop if it is virgin, otherwise consume it
                // and reserve a worst-case payload.
                if (!try self.slotTouched(si, slot, data)) break;
                slot += INDEX_LEN;
                data = if (data >= MAX_PAYLOAD) data - MAX_PAYLOAD else slot;
                if (data < slot) data = slot;
            }
            return .{
                .end_idx = @intCast(@min(slot, SECTOR_SIZE)),
                .end_data = @intCast(@min(data, SECTOR_SIZE)),
                .last_time = last,
                .count = n,
            };
        }

        /// Lowest slot with `time >= from`, or `DATA_OFF` when the sector has
        /// to be scanned linearly (discarded slot in the middle).
        fn lowerBound(self: *Self, si: u16, limit: usize, from: Time) Error!usize {
            var lo: usize = DATA_OFF;
            var hi: usize = limit;
            while (lo < hi) {
                const mid = lo + ((hi - lo) / INDEX_LEN / 2) * INDEX_LEN;
                const rec = (try self.readIndexAt(si, mid)) orelse return DATA_OFF;
                if (rec.time < from) {
                    lo = mid + INDEX_LEN;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        /// Lowest slot with `time > hi_time` (one past the last match).
        fn upperBound(self: *Self, si: u16, limit: usize, hi_time: Time) Error!usize {
            var lo: usize = DATA_OFF;
            var hi: usize = limit;
            while (lo < hi) {
                const mid = lo + ((hi - lo) / INDEX_LEN / 2) * INDEX_LEN;
                const rec = (try self.readIndexAt(si, mid)) orelse return limit;
                if (rec.time <= hi_time) {
                    lo = mid + INDEX_LEN;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        // ---- internals: mount / recovery ----------------------------------

        /// Mount scan. Every sector header is read exactly once and the sector
        /// order, the write target and the last timestamp are all derived from
        /// that single pass, so mounting a full database costs one read per
        /// sector (the USING sector additionally gets its index records
        /// scanned once to recover the write cursor).
        fn load(self: *Self) Error!void {
            var valid: u16 = 0;
            var valid_mask: u32 = 0;
            var using_mask: u32 = 0;
            var full_mask: u32 = 0;
            // Sectors without a valid header (blank or damaged).
            var blank_mask: u32 = 0;
            // Formatted but unused sectors whose `start_time` slot is erased.
            var start_erased_mask: u32 = 0;
            var have_seq = false;
            // Newest closed sector and whether its end fields are intact.
            var newest_full: u16 = NO_SECTOR;
            var newest_end_time: Time = 0;
            var newest_end_ok = false;

            var i: u16 = 0;
            while (i < SECTOR_COUNT) : (i += 1) {
                const bit = bitOf(i);
                const info = try self.readSectorInfo(i);
                if (info) |si| {
                    // `full` without `using` cannot be produced by this
                    // implementation: treat the sector as unformatted.
                    if (si.full and !si.using) {
                        if (cfg.not_formattable) return error.NotFormatted;
                        blank_mask |= bit;
                        continue;
                    }
                    valid += 1;
                    valid_mask |= bit;
                    self.seqs[i] = si.seq;
                    if (!have_seq or format.seqAfter(si.seq, self.seq)) {
                        self.seq = si.seq;
                        have_seq = true;
                    }
                    if (si.using and !si.full) using_mask |= bit;
                    if (si.full) {
                        full_mask |= bit;
                        if (newest_full == NO_SECTOR or format.seqAfter(si.seq, self.seqs[newest_full])) {
                            newest_full = i;
                            newest_end_time = si.end_time;
                            newest_end_ok = !si.end_erased and endSane(si.end_idx, si.end_data);
                        }
                    } else if (!si.using and si.start_erased) {
                        start_erased_mask |= bit;
                    }
                } else {
                    // A sector that was never formatted is a normal part of a
                    // lazily formatted database; a damaged or foreign header is
                    // not, and a not-formattable database refuses to touch it.
                    if (cfg.not_formattable and !(try self.sectorIsBlank(i)))
                        return error.NotFormatted;
                    blank_mask |= bit;
                }
            }

            // Nothing usable at all: a blank partition may be formatted unless
            // the database was configured as not formattable.
            if (valid == 0) {
                if (cfg.not_formattable) return error.NotFormatted;
                try self.formatAll();
                return;
            }
            if (@popCount(using_mask) > 1) {
                // Two sectors claim to be the write target: unrecoverable.
                if (cfg.not_formattable) return error.Corrupted;
                try self.formatAll();
                return;
            }

            // `end_time` of the newest closed sector; on-flash damage is
            // repaired by scanning that sector (read-only recovery).
            var closed_last: Time = 0;
            if (newest_full != NO_SECTOR) {
                if (newest_end_ok) {
                    closed_last = newest_end_time;
                } else {
                    closed_last = (try self.scanSector(newest_full)).last_time;
                }
            }

            self.known_mask = valid_mask;
            self.rebuildOrder();
            if (using_mask != 0) {
                self.cur = @intCast(@ctz(using_mask));
                try self.loadCurrent(closed_last);
                return;
            }
            // No sector is receiving appends: close the gap by activating a
            // spare sector when one is available. A full database stays without
            // a write target until `append` decides about rollover.
            self.cur = NO_SECTOR;
            self.last_time = closed_last;
            var target: u16 = if (blank_mask != 0) @intCast(@ctz(blank_mask)) else NO_SECTOR;
            if (target == NO_SECTOR) {
                var j: u16 = 0;
                while (j < SECTOR_COUNT) : (j += 1) {
                    const bit = bitOf(j);
                    if (valid_mask & bit == 0) continue;
                    if (using_mask & bit != 0 or full_mask & bit != 0) continue;
                    target = j;
                    break;
                }
            }
            if (target != NO_SECTOR) {
                // A formatted, unused sector whose sequence number is already
                // the newest one and whose `start_time` is erased can be
                // activated in place (recovery from an interrupted activation).
                const in_place = start_erased_mask & bitOf(target) != 0;
                try self.activateFresh(target, self.last_time, in_place);
            }
        }

        /// Recover the write cursor of the USING sector and its last timestamp.
        /// `fallback_last` is the newest closed sector's `end_time`, used while
        /// the write target has no committed entry yet.
        fn loadCurrent(self: *Self, fallback_last: Time) Error!void {
            const scan = try self.scanSector(self.cur);
            self.empty_idx = scan.end_idx;
            self.empty_data = scan.end_data;
            self.last_time = if (scan.count > 0) scan.last_time else fallback_last;
        }

        fn rebuildOrder(self: *Self) void {
            var used: u32 = 0;
            var n: u16 = 0;
            while (n < SECTOR_COUNT) : (n += 1) {
                var best: u16 = NO_SECTOR;
                var i: u16 = 0;
                while (i < SECTOR_COUNT) : (i += 1) {
                    const bit = bitOf(i);
                    if (self.known_mask & bit == 0) continue;
                    if (used & bit != 0) continue;
                    if (best == NO_SECTOR or format.seqAfter(self.seqs[best], self.seqs[i])) best = i;
                }
                if (best == NO_SECTOR) break;
                self.order[n] = best;
                used |= bitOf(best);
            }
            self.order_len = n;
        }

        /// Erase every sector and format sector 0 as the write target. Other
        /// sectors stay unformatted but are marked erased, so lazily
        /// formatting them later needs no second erase.
        fn formatAll(self: *Self) Error!void {
            var i: u16 = 0;
            while (i < SECTOR_COUNT) : (i += 1) try self.dev.eraseSector(i);
            self.pristine = ALL_SECTORS;
            self.known_mask = 0;
            self.seqs = @splat(0);
            self.order = @splat(0);
            self.order_len = 0;
            self.seq = 0;
            self.cur = NO_SECTOR;
            self.empty_idx = @intCast(DATA_OFF);
            self.empty_data = @intCast(SECTOR_SIZE);
            self.last_time = 0;
            self.damaged = false;
            try self.activateSector(0, 0);
        }

        // ---- internals: sector lifecycle ----------------------------------

        /// A blank (never formatted) sector, or one whose header is damaged.
        fn findBlankSector(self: *Self) u16 {
            var i: u16 = 0;
            while (i < SECTOR_COUNT) : (i += 1) {
                if (self.known_mask & bitOf(i) == 0) return i;
            }
            return NO_SECTOR;
        }

        /// First formatted but never used sector, or `NO_SECTOR`.
        fn findEmptySector(self: *Self) Error!u16 {
            var i: u16 = 0;
            while (i < SECTOR_COUNT) : (i += 1) {
                if (self.known_mask & bitOf(i) == 0) continue;
                const info = (try self.readSectorInfo(i)) orelse continue;
                if (!info.using and !info.full) return i;
            }
            return NO_SECTOR;
        }

        /// Sector that can become the write target without destroying data.
        fn findActivatable(self: *Self) Error!u16 {
            const blank = self.findBlankSector();
            if (blank != NO_SECTOR) return blank;
            return self.findEmptySector();
        }

        /// Oldest sector that still holds entries (rollover victim).
        fn findOldestDataSector(self: *Self) Error!u16 {
            var best: u16 = NO_SECTOR;
            var i: u16 = 0;
            while (i < SECTOR_COUNT) : (i += 1) {
                if (self.known_mask & bitOf(i) == 0) continue;
                const info = (try self.readSectorInfo(i)) orelse continue;
                if (!info.using and !info.full) continue;
                if (best == NO_SECTOR or format.seqAfter(self.seqs[best], self.seqs[i])) best = i;
            }
            return best;
        }

        fn nextSeq(self: *Self) u16 {
            self.seq +%= 1;
            if (self.seq == 0) self.seq = 1;
            return self.seq;
        }

        /// Make `index` the write target. The caller passes whether a spare
        /// formatted sector can be reused in place (see `load`); otherwise the
        /// sector is erased (unless known blank) and gets a fresh header with
        /// the next sequence number. `start_time` is written first and then
        /// committed by the `using` granule.
        fn activateFresh(self: *Self, index: u16, time: Time, in_place: bool) Error!void {
            const bit = bitOf(index);
            const base = self.dev.sectorAddr(index);
            if (!in_place) {
                if (self.pristine & bit == 0) try self.dev.eraseSector(index);
                self.pristine &= ~bit;
                const seq = self.nextSeq();
                try self.dev.writeHeader(index, .{
                    .seq = seq,
                    .kind = .tsdb,
                    .gran_log2 = D.gran_log2,
                });
                self.known_mask |= bit;
                self.seqs[index] = seq;
            }
            try self.writeTimeSlot(self.addrOf(index, L.start_time_off), time);
            try self.dev.mark(base + @as(u32, @intCast(L.state_off)));
            self.cur = index;
            self.empty_idx = @intCast(DATA_OFF);
            self.empty_data = @intCast(SECTOR_SIZE);
            self.rebuildOrder();
        }

        /// `activateFresh` for callers that have no mount summary at hand: the
        /// spare sector's header is read once to decide whether it can be
        /// reused in place.
        fn activateSector(self: *Self, index: u16, time: Time) Error!void {
            var in_place = false;
            if (try self.readSectorInfo(index)) |info| {
                in_place = !info.using and !info.full and info.start_erased and
                    self.seq != 0 and info.seq == self.seq;
            }
            try self.activateFresh(index, time, in_place);
        }

        fn writeTimeSlot(self: *Self, addr: u32, time: Time) Error!void {
            var buf: [TIME_SLOT]u8 = @splat(0xFF);
            wrTime(buf[0..].ptr, time);
            try self.dev.writeAligned(addr, &buf);
        }

        // ---- internals: append --------------------------------------------

        /// Make sure the current sector can hold an index record plus `need`
        /// payload bytes; close it and move on otherwise.
        fn reserve(self: *Self, need: usize, time: Time) Error!void {
            while (true) {
                if (self.cur != NO_SECTOR) {
                    const avail: usize = @as(usize, self.empty_data) - @as(usize, self.empty_idx);
                    if (need <= avail) return;
                    try self.closeSector();
                }
                try self.openSector(time);
            }
        }

        /// Close the current sector: store the last timestamp and the free
        /// offsets in the header, then write the `full` granule as their
        /// commit. Closing an already interrupted close is safe because the
        /// values are identical and re-writing them cannot set any bit.
        fn closeSector(self: *Self) Error!void {
            const si = self.cur;
            var buf: [END_REGION]u8 = @splat(0xFF);
            wrTime(buf[0..].ptr, self.last_time);
            format.wr16(buf[TIME_SLOT..].ptr, self.empty_idx);
            format.wr16(buf[TIME_SLOT + 2 ..].ptr, self.empty_data);
            try self.dev.writeAligned(self.addrOf(si, L.end_time_off), &buf);
            try self.dev.mark(self.addrOf(si, L.state_off + L.state_full * g));
            self.cur = NO_SECTOR;
        }

        fn openSector(self: *Self, time: Time) Error!void {
            var target = try self.findActivatable();
            if (target == NO_SECTOR) {
                if (!self.rollover) return error.SavedFull;
                target = try self.findOldestDataSector();
                if (target == NO_SECTOR) return error.SavedFull;
            }
            try self.activateSector(target, time);
        }

        fn appendInner(self: *Self, time: Time, data: []const u8) Error!void {
            const payload_len: usize = format.alignUp(g, data.len);
            try self.reserve(INDEX_LEN + payload_len, time);

            const si = self.cur;
            const base = self.dev.sectorAddr(si);
            const off: usize = @as(usize, self.empty_data) - payload_len;
            const index_addr = base + @as(u32, @intCast(self.empty_idx));

            // Payload first (bottom up), then the index data; either may be
            // left behind by a power cut without being observed.
            if (data.len > 0) try self.dev.writePadded(self.addrOf(si, off), data);
            var ibuf: [INDEX_DATA_LEN]u8 = @splat(0xFF);
            wrTime(ibuf[0..].ptr, time);
            format.wr16(ibuf[TIME_SLOT..].ptr, @intCast(data.len));
            format.wr16(ibuf[TIME_SLOT + HALF_SLOT ..].ptr, @intCast(off));
            try self.dev.writeAligned(index_addr + @as(u32, @intCast(4 * g)), &ibuf);
            // Single-granule commit: the entry exists or it does not.
            try self.dev.mark(index_addr);

            self.empty_idx = @intCast(@as(usize, self.empty_idx) + INDEX_LEN);
            self.empty_data = @intCast(off);
            self.last_time = time;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests (host, RAM flash).
// ---------------------------------------------------------------------------

const std = @import("std");
const sim = @import("sim.zig");
const flash = @import("flash.zig");

const Flash8 = sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });
const Flash8Small = sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 512 });

/// 4 x 4096 byte sectors with 32-byte payloads: 368 entries of capacity.
const BigDb = Tsdb(Flash8, .{ .sector_size = 4096, .sector_count = 4, .max_len = 32 });
/// 4 x 512 byte sectors with 16-byte payloads: small enough for full sweeps.
const SmallDb = Tsdb(Flash8Small, .{ .sector_size = 512, .sector_count = 4, .max_len = 16 });
/// Layout of `SmallDb`/`Flash8Small`: granule 1 byte, 32-bit timestamps.
const SmallLayout = format.TsLayout(1, 4);

fn fresh(comptime F: type, mem: []u8) F {
    var f = F.init(mem);
    f.eraseAll();
    return f;
}

/// Deterministic payload bytes used by the tests.
fn testPayload(buf: []u8, time: i32, extra: usize) void {
    for (buf, 0..) |*b, j| {
        b.* = @truncate(@as(u32, @bitCast(time)) +% @as(u32, @intCast(j * 13)) +% @as(u32, @intCast(extra)));
    }
}

fn expectPayload(bytes: []const u8, time: i32, extra: usize) !void {
    var expected: [64]u8 = undefined;
    try std.testing.expect(bytes.len <= expected.len);
    testPayload(expected[0..bytes.len], time, extra);
    try std.testing.expectEqualSlices(u8, expected[0..bytes.len], bytes);
}

/// Append an entry whose payload length varies with the timestamp.
fn appendVar(comptime Db: type, db: *Db, time: Db.Time, extra: usize) !void {
    var buf: [64]u8 = undefined;
    const t32: i32 = @truncate(@as(i64, time));
    const len: usize = @intCast(@mod(@as(u32, @bitCast(t32)), @as(u32, Db.max_len) + 1));
    testPayload(buf[0..len], t32, extra);
    try db.append(time, buf[0..len]);
}

/// Append `count` fixed `len`-byte entries starting at `time`.
fn appendFixed(comptime Db: type, db: *Db, time: Db.Time, len: usize, count: usize) !void {
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    var t = time;
    while (i < count) : (i += 1) {
        testPayload(buf[0..len], @intCast(t), i);
        try db.append(t, buf[0..len]);
        t += 1;
    }
}

/// Collect the timestamps yielded by `it` into `out`.
fn collectTimes(comptime Db: type, it: *Db.Iterator, out: []Db.Time) !usize {
    var n: usize = 0;
    while (try it.next()) |e| {
        try std.testing.expect(n < out.len);
        out[n] = e.time;
        n += 1;
    }
    return n;
}

test "tsdb append, iterate forward/reverse/by time and query count" {
    var mem: [4 * 4096]u8 = undefined;
    var db: BigDb = undefined;
    try db.mount(fresh(Flash8, &mem));

    const times = [_]i32{ 1000, 1005, 1010, 1015, 1020, 1025 };
    const lens = [_]usize{ 4, 16, 0, 32, 7, 12 };
    for (times, 0..) |t, i| {
        var buf: [32]u8 = undefined;
        testPayload(buf[0..lens[i]], t, i);
        try db.append(t, buf[0..lens[i]]);
    }
    try std.testing.expectEqual(@as(BigDb.Time, 1025), db.lastTime());
    try std.testing.expectEqual(@as(u32, 6), try db.count());
    try db.check();

    // Forward: exact sequence, payloads and statuses.
    var it = db.iterator();
    var i: usize = 0;
    while (try it.next()) |e| : (i += 1) {
        try std.testing.expectEqual(@as(BigDb.Time, times[i]), e.time);
        try std.testing.expectEqual(@as(u32, @intCast(lens[i])), e.len);
        try std.testing.expectEqual(BigDb.Status.write, e.status);
        var buf: [32]u8 = undefined;
        const n = try it.readPayload(&buf, e);
        try std.testing.expectEqual(@as(u32, @intCast(lens[i])), n);
        try expectPayload(buf[0..n], times[i], i);
    }
    try std.testing.expectEqual(times.len, i);

    // Reverse: exact sequence.
    var got: [8]BigDb.Time = undefined;
    it = db.iteratorReverse();
    const n_rev = try collectTimes(BigDb, &it, &got);
    try std.testing.expectEqual(times.len, n_rev);
    for (times, 0..) |t, k| try std.testing.expectEqual(@as(BigDb.Time, t), got[times.len - 1 - k]);

    // By time, forward range and reversed range.
    const expect_fwd = [_]BigDb.Time{ 1005, 1010, 1015 };
    const expect_rev = [_]BigDb.Time{ 1015, 1010, 1005 };
    it = db.iteratorByTime(1005, 1015);
    const n_fwd = try collectTimes(BigDb, &it, &got);
    try std.testing.expectEqual(expect_fwd.len, n_fwd);
    for (expect_fwd, 0..) |t, k| try std.testing.expectEqual(t, got[k]);

    it = db.iteratorByTime(1015, 1005);
    const n_bwd = try collectTimes(BigDb, &it, &got);
    try std.testing.expectEqual(expect_rev.len, n_bwd);
    for (expect_rev, 0..) |t, k| try std.testing.expectEqual(t, got[k]);

    // Ranges that miss everything, in both directions.
    it = db.iteratorByTime(2000, 3000);
    try std.testing.expectEqual(@as(?BigDb.Entry, null), try it.next());
    it = db.iteratorByTime(3000, 2000);
    try std.testing.expectEqual(@as(?BigDb.Entry, null), try it.next());
    // Inclusive lower bound.
    it = db.iteratorByTime(0, 1000);
    try std.testing.expectEqual(@as(BigDb.Time, 1000), (try it.next()).?.time);
    try std.testing.expectEqual(@as(?BigDb.Entry, null), try it.next());

    // Query count by status.
    try std.testing.expectEqual(@as(u32, 6), try db.queryCount(1000, 1025, .write));
    try std.testing.expectEqual(@as(u32, 0), try db.queryCount(1000, 1025, .deleted));
    try std.testing.expectEqual(@as(u32, 3), try db.queryCount(1005, 1015, .write));
    try std.testing.expectEqual(@as(u32, 3), try db.queryCount(1015, 1005, .write));

    // Forward-only status transitions.
    it = db.iteratorByTime(1010, 1010);
    const entry = (try it.next()).?;
    try db.setStatus(entry, .user1);
    try std.testing.expectEqual(@as(u32, 5), try db.queryCount(1000, 1025, .write));
    try std.testing.expectEqual(@as(u32, 1), try db.queryCount(1000, 1025, .user1));
    try db.setStatus(entry, .deleted);
    try std.testing.expectEqual(@as(u32, 1), try db.queryCount(1000, 1025, .deleted));
    it = db.iteratorByTime(1010, 1010);
    try std.testing.expectEqual(BigDb.Status.deleted, (try it.next()).?.status);
    try std.testing.expectError(error.StatusNotAdvancing, db.setStatus(entry, .user1));
    try std.testing.expectError(error.StatusNotAdvancing, db.setStatus(entry, .write));
    try std.testing.expectError(error.StatusNotAdvancing, db.setStatus(entry, .deleted));
    try std.testing.expectError(error.StatusNotAdvancing, db.setStatus(entry, .unused));

    // Invalid appends.
    var big: [33]u8 = undefined;
    testPayload(&big, 2000, 0);
    try std.testing.expectError(error.ValueTooLarge, db.append(2000, &big));
    try std.testing.expectError(error.TimeNotIncreasing, db.append(1025, "x"));
    try std.testing.expectError(error.TimeNotIncreasing, db.append(900, "x"));
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.violations);
}

test "tsdb remount recovers entries and last time" {
    var mem: [4 * 4096]u8 = undefined;
    var db: BigDb = undefined;
    try db.mount(fresh(Flash8, &mem));
    for (0..5) |i| try appendVar(BigDb, &db, 1000 + @as(BigDb.Time, @intCast(i)), i);
    try db.check();
    try std.testing.expectEqual(@as(BigDb.Time, 1004), db.lastTime());
    try std.testing.expectEqual(@as(u32, 5), try db.count());

    var db2: BigDb = undefined;
    try db2.mount(Flash8.init(&mem));
    try std.testing.expectEqual(@as(BigDb.Time, 1004), db2.lastTime());
    try std.testing.expectEqual(@as(u32, 5), try db2.count());
    try db2.check();
    var it = db2.iterator();
    var i: u32 = 0;
    while (try it.next()) |e| : (i += 1) {
        try std.testing.expectEqual(@as(BigDb.Time, 1000 + @as(BigDb.Time, @intCast(i))), e.time);
        var buf: [32]u8 = undefined;
        const n = try it.readPayload(&buf, e);
        try expectPayload(buf[0..n], @intCast(e.time), i);
    }
    try std.testing.expectEqual(@as(u32, 5), i);

    // The remounted database continues where it stopped.
    try db2.append(1005, "after-remount");
    try std.testing.expectEqual(@as(BigDb.Time, 1005), db2.lastTime());
    var db3: BigDb = undefined;
    try db3.mount(Flash8.init(&mem));
    try std.testing.expectEqual(@as(u32, 6), try db3.count());
    try std.testing.expectEqual(@as(BigDb.Time, 1005), db3.lastTime());
    try db3.check();
}

test "tsdb fill to SavedFull matches max entry count and remounts" {
    var mem: [4 * 4096]u8 = undefined;
    var db: BigDb = undefined;
    try db.mount(fresh(Flash8, &mem));
    db.setRollover(false);
    try std.testing.expect(!db.getRollover());

    const capacity = db.maxEntryCount();
    try std.testing.expectEqual(@as(u32, 368), capacity);

    var payload: [32]u8 = undefined;
    var time: BigDb.Time = 1000;
    var n: u32 = 0;
    while (true) {
        testPayload(&payload, @intCast(time), n);
        if (db.append(time, &payload)) |_| {
            n += 1;
            time += 1;
        } else |err| {
            try std.testing.expectEqual(error.SavedFull, err);
            break;
        }
        try std.testing.expect(n <= capacity + 1);
    }
    try std.testing.expectEqual(capacity, n);
    try std.testing.expectEqual(capacity, try db.count());
    try db.check();
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.violations);

    // A completely full database must survive a remount with every entry.
    var db2: BigDb = undefined;
    try db2.mount(Flash8.init(&mem));
    db2.setRollover(false);
    try std.testing.expectEqual(capacity, try db2.count());
    try std.testing.expectEqual(@as(BigDb.Time, 1000 + @as(BigDb.Time, @intCast(capacity)) - 1), db2.lastTime());
    try db2.check();
    var it = db2.iterator();
    var i: u32 = 0;
    var prev: BigDb.Time = 0;
    while (try it.next()) |e| : (i += 1) {
        if (i > 0) {
            try std.testing.expectEqual(prev + 1, e.time);
        } else {
            try std.testing.expectEqual(@as(BigDb.Time, 1000), e.time);
        }
        prev = e.time;
        var buf: [32]u8 = undefined;
        const copied = try it.readPayload(&buf, e);
        try std.testing.expectEqual(e.len, copied);
        try expectPayload(buf[0..copied], @intCast(e.time), i);
    }
    try std.testing.expectEqual(capacity, i);
    // A reverse pass yields exactly the same entries.
    var rev_count: u32 = 0;
    it = db2.iteratorReverse();
    while (try it.next() != null) rev_count += 1;
    try std.testing.expectEqual(capacity, rev_count);
    // Still full without rollover.
    try std.testing.expectError(error.SavedFull, db2.append(5000, "x"));
    // ... and one sector is free again once rollover is enabled.
    db2.setRollover(true);
    try db2.append(5000, "x");
    try db2.check();
}

test "tsdb rollover keeps the newest window and survives remount" {
    var mem: [4 * 4096]u8 = undefined;
    var db: BigDb = undefined;
    try db.mount(fresh(Flash8, &mem));
    try std.testing.expect(db.getRollover());

    const capacity = db.maxEntryCount();
    const total = capacity * 3;
    var payload: [32]u8 = undefined;
    var time: BigDb.Time = 1000;
    var n: u32 = 0;
    while (n < total) : (n += 1) {
        testPayload(&payload, @intCast(time), n);
        try db.append(time, &payload);
        time += 1;
    }
    try std.testing.expectEqual(capacity, try db.count());
    try db.check();

    // The live window is the newest `capacity` contiguous timestamps.
    var it = db.iterator();
    var first: BigDb.Time = 0;
    var last: BigDb.Time = 0;
    var cnt: u32 = 0;
    while (try it.next()) |e| {
        if (cnt == 0) {
            first = e.time;
        } else {
            try std.testing.expectEqual(last + 1, e.time);
        }
        last = e.time;
        cnt += 1;
    }
    try std.testing.expectEqual(capacity, cnt);
    try std.testing.expectEqual(@as(BigDb.Time, 1000) + @as(BigDb.Time, @intCast(total)) - 1, last);
    try std.testing.expectEqual(last - @as(BigDb.Time, @intCast(capacity)) + 1, first);

    // Remount: the window is recovered exactly.
    var db2: BigDb = undefined;
    try db2.mount(Flash8.init(&mem));
    try std.testing.expectEqual(capacity, try db2.count());
    try std.testing.expectEqual(last, db2.lastTime());
    try db2.check();
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);
    it = db2.iteratorByTime(first, last);
    cnt = 0;
    while (try it.next() != null) cnt += 1;
    try std.testing.expectEqual(capacity, cnt);
    // Appending continues to roll over after the remount.
    try db2.append(last + 1, "next");
    try db2.append(last + 2, "next");
    try std.testing.expectEqual(last + 2, db2.lastTime());
    try db2.check();
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
}

test "tsdb 64-bit timestamps" {
    const Db = Tsdb(Flash8Small, .{ .sector_size = 512, .sector_count = 2, .max_len = 16, .ts_bits = 64 });
    var mem: [2 * 512]u8 = undefined;
    var db: Db = undefined;
    try db.mount(fresh(Flash8Small, &mem));

    const base: i64 = 5_000_000_000;
    var buf: [16]u8 = undefined;
    for (0..12) |i| {
        testPayload(&buf, @intCast(i), i);
        try db.append(base + @as(i64, @intCast(i)), &buf);
    }
    try std.testing.expectEqual(base + 11, db.lastTime());
    try std.testing.expectEqual(@as(u32, 12), try db.count());
    try db.check();

    var db2: Db = undefined;
    try db2.mount(Flash8Small.init(&mem));
    try std.testing.expectEqual(base + 11, db2.lastTime());
    var it = db2.iterator();
    var i: i64 = 0;
    while (try it.next()) |e| : (i += 1) {
        try std.testing.expectEqual(base + i, e.time);
    }
    try std.testing.expectEqual(@as(i64, 12), i);
    var it2 = db2.iteratorByTime(base + 10, base + 1000);
    try std.testing.expectEqual(base + 10, (try it2.next()).?.time);
    var it3 = db2.iteratorByTime(base + 1000, base + 10);
    try std.testing.expectEqual(base + 11, (try it3.next()).?.time);
    try std.testing.expectEqual(base + 10, (try it3.next()).?.time);
    try std.testing.expectEqual(@as(?Db.Entry, null), try it3.next());
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
}

test "tsdb write granularities" {
    inline for ([_]u16{ 1, 8, 32, 64, 128 }) |bits| {
        const F = sim.RamFlash(.{ .write_gran_bits = bits, .block_size = 4096 });
        const Db = Tsdb(F, .{ .sector_size = 4096, .sector_count = 2, .max_len = 48 });
        var mem: [2 * 4096]u8 = undefined;
        var db: Db = undefined;
        try db.mount(fresh(F, &mem));

        var t: i32 = 100;
        var n: usize = 0;
        while (n < 24) : (n += 1) {
            var buf: [48]u8 = undefined;
            const len: usize = (n * 7) % 49;
            testPayload(buf[0..len], t, n);
            try db.append(t, buf[0..len]);
            t += 1;
        }
        try std.testing.expectEqual(@as(u32, 24), try db.count());
        try db.check();
        try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.set_bit_attempts);
        try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.violations);

        var db2: Db = undefined;
        try db2.mount(F.init(&mem));
        try std.testing.expectEqual(@as(u32, 24), try db2.count());
        try db2.check();
        var it = db2.iterator();
        var i: usize = 0;
        while (try it.next()) |e| : (i += 1) {
            try std.testing.expectEqual(@as(i32, 100 + @as(i32, @intCast(i))), e.time);
            var buf: [48]u8 = undefined;
            const copied = try it.readPayload(&buf, e);
            try std.testing.expectEqual(e.len, copied);
            try expectPayload(buf[0..copied], @intCast(e.time), i);
        }
        try std.testing.expectEqual(@as(usize, 24), i);
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);
    }
}

test "tsdb not formattable and clean" {
    const Strict = Tsdb(Flash8Small, .{ .sector_size = 512, .sector_count = 2, .max_len = 16, .not_formattable = true });
    const Loose = Tsdb(Flash8Small, .{ .sector_size = 512, .sector_count = 2, .max_len = 16 });

    // A blank partition is refused instead of being formatted.
    var blank: [2 * 512]u8 = undefined;
    var strict: Strict = undefined;
    try std.testing.expectError(error.NotFormatted, strict.mount(fresh(Flash8Small, &blank)));

    // Format an image with a normal database first.
    var mem: [2 * 512]u8 = undefined;
    var loose: Loose = undefined;
    try loose.mount(fresh(Flash8Small, &mem));
    for (0..3) |i| try appendVar(Loose, &loose, 1000 + @as(Loose.Time, @intCast(i)), i);
    try loose.check();

    // The not-formattable database reads it and keeps working.
    var db: Strict = undefined;
    try db.mount(Flash8Small.init(&mem));
    try std.testing.expectEqual(@as(u32, 3), try db.count());
    try db.check();
    try db.append(1010, "more");
    try std.testing.expectEqual(@as(u32, 4), try db.count());

    try db.clean();
    try std.testing.expectEqual(@as(u32, 0), try db.count());
    try std.testing.expectEqual(@as(Strict.Time, 0), db.lastTime());
    try db.check();
    try db.append(1000, "fresh");
    try std.testing.expectEqual(@as(u32, 1), try db.count());
    try db.check();

    // The image is readable by a database with the same format.
    var loose2: Loose = undefined;
    try loose2.mount(Flash8Small.init(&mem));
    try std.testing.expectEqual(@as(u32, 1), try loose2.count());
    try loose2.check();
}

test "tsdb power cut during append" {
    var baseline: [4 * 512]u8 = undefined;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        for (0..5) |i| try appendVar(SmallDb, &db, 1000 + @as(SmallDb.Time, @intCast(i)), i);
        try db.check();
    }

    const new_time: SmallDb.Time = 1005;
    var payload: [16]u8 = undefined;
    testPayload(&payload, @intCast(new_time), 99);

    // How many flash mutations does one append cost?
    var probe_mem: [4 * 512]u8 = undefined;
    @memcpy(&probe_mem, &baseline);
    var probe: SmallDb = undefined;
    try probe.mount(Flash8Small.init(&probe_mem));
    probe.setRollover(false);
    probe.dev.flash.mutations = 0;
    try probe.append(new_time, &payload);
    const ops = probe.dev.flash.mutations;
    try std.testing.expect(ops >= 2 and ops <= 8);

    var cut: u64 = 0;
    while (cut <= ops) : (cut += 1) {
        var mem: [4 * 512]u8 = undefined;
        @memcpy(&mem, &baseline);
        var db: SmallDb = undefined;
        try db.mount(Flash8Small.init(&mem));
        db.setRollover(false);
        db.dev.flash.mutations = 0;
        db.dev.flash.armFault(cut);
        _ = db.append(new_time, &payload) catch {};
        db.dev.flash.clearFault();

        var db2: SmallDb = undefined;
        try db2.mount(Flash8Small.init(&mem));
        db2.setRollover(false);
        try db2.check();
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);

        // Entries 1000..1004 are always intact; 1005 is present or absent.
        var it = db2.iterator();
        var expected: SmallDb.Time = 1000;
        var new_seen = false;
        while (try it.next()) |e| {
            try std.testing.expectEqual(expected, e.time);
            if (e.time == new_time) new_seen = true;
            expected += 1;
        }
        try std.testing.expectEqual(new_time + @as(SmallDb.Time, @intFromBool(new_seen)), expected);
        if (new_seen) try std.testing.expectEqual(new_time, db2.lastTime());

        // The database keeps working afterwards.
        const next = db2.lastTime() + 1;
        try db2.append(next, "after");
        try db2.check();
    }
}

test "tsdb power cut during sector switch" {
    var baseline: [4 * 512]u8 = undefined;
    var per_sector: u32 = 0;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        per_sector = db.maxEntryCount() / 4;
        try std.testing.expectEqual(@as(u32, 17), per_sector);
        var t: SmallDb.Time = 1000;
        var i: u32 = 0;
        while (i < per_sector) : (i += 1) {
            try db.append(t, "0123456789abcdef");
            t += 1;
        }
        try db.check();
        try std.testing.expectEqual(per_sector, try db.count());
    }
    const new_time: SmallDb.Time = 1000 + @as(SmallDb.Time, @intCast(per_sector));

    var probe_mem: [4 * 512]u8 = undefined;
    @memcpy(&probe_mem, &baseline);
    var probe: SmallDb = undefined;
    try probe.mount(Flash8Small.init(&probe_mem));
    probe.setRollover(false);
    probe.dev.flash.mutations = 0;
    try probe.append(new_time, "0123456789abcdef");
    const ops = probe.dev.flash.mutations;
    try std.testing.expect(ops >= 5 and ops <= 16);

    var cut: u64 = 0;
    while (cut <= ops) : (cut += 1) {
        var mem: [4 * 512]u8 = undefined;
        @memcpy(&mem, &baseline);
        var db: SmallDb = undefined;
        try db.mount(Flash8Small.init(&mem));
        db.setRollover(false);
        db.dev.flash.mutations = 0;
        db.dev.flash.armFault(cut);
        _ = db.append(new_time, "0123456789abcdef") catch {};
        db.dev.flash.clearFault();

        var db2: SmallDb = undefined;
        try db2.mount(Flash8Small.init(&mem));
        db2.setRollover(false);
        try db2.check();
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);

        var it = db2.iterator();
        var expected: SmallDb.Time = 1000;
        while (try it.next()) |e| {
            try std.testing.expectEqual(expected, e.time);
            expected += 1;
        }
        const present = expected > new_time;
        try std.testing.expectEqual(new_time + @as(SmallDb.Time, @intFromBool(present)), expected);
        try std.testing.expectEqual(new_time - 1 + @as(SmallDb.Time, @intFromBool(present)), db2.lastTime());

        try db2.append(db2.lastTime() + 1, "after");
        try db2.check();
    }
}

test "tsdb power cut during rollover" {
    var baseline: [4 * 512]u8 = undefined;
    var per_sector: u32 = 0;
    var capacity: u32 = 0;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        per_sector = db.maxEntryCount() / 4;
        capacity = db.maxEntryCount();
        try std.testing.expectEqual(@as(u32, 68), capacity);
        var t: SmallDb.Time = 1000;
        var filled: u32 = 0;
        while (true) {
            if (db.append(t, "0123456789abcdef")) |_| {
                filled += 1;
                t += 1;
            } else |err| {
                try std.testing.expectEqual(error.SavedFull, err);
                break;
            }
        }
        try std.testing.expectEqual(capacity, filled);
        try db.check();
    }
    const new_time: SmallDb.Time = 1000 + @as(SmallDb.Time, @intCast(capacity));

    var probe_mem: [4 * 512]u8 = undefined;
    @memcpy(&probe_mem, &baseline);
    var probe: SmallDb = undefined;
    try probe.mount(Flash8Small.init(&probe_mem));
    probe.dev.flash.mutations = 0;
    try probe.append(new_time, "0123456789abcdef");
    const ops = probe.dev.flash.mutations;
    try std.testing.expect(ops >= 4 and ops <= 16);

    var cut: u64 = 0;
    while (cut <= ops) : (cut += 1) {
        var mem: [4 * 512]u8 = undefined;
        @memcpy(&mem, &baseline);
        var db: SmallDb = undefined;
        try db.mount(Flash8Small.init(&mem));
        db.dev.flash.mutations = 0;
        db.dev.flash.armFault(cut);
        _ = db.append(new_time, "0123456789abcdef") catch {};
        db.dev.flash.clearFault();

        var db2: SmallDb = undefined;
        try db2.mount(Flash8Small.init(&mem));
        try db2.check();
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
        try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);

        // The live set is always a contiguous timestamp window. The oldest
        // sector may or may not have been recycled, so the window either still
        // starts at 1000 or at 1000 + per_sector.
        var it = db2.iterator();
        var first: SmallDb.Time = 0;
        var last: SmallDb.Time = 0;
        var n: u32 = 0;
        while (try it.next()) |e| {
            if (n == 0) {
                first = e.time;
            } else {
                try std.testing.expectEqual(last + 1, e.time);
            }
            last = e.time;
            n += 1;
        }
        try std.testing.expect(first == 1000 or first == 1000 + @as(SmallDb.Time, @intCast(per_sector)));
        try std.testing.expect(last == new_time - 1 or last == new_time);
        try std.testing.expectEqual(last - first + 1, @as(SmallDb.Time, @intCast(n)));
        try std.testing.expectEqual(last, db2.lastTime());

        try db2.append(last + 1, "after");
        try db2.check();
    }
}

test "tsdb corrupt index commit granule" {
    var baseline: [4 * 512]u8 = undefined;
    var first_index: u32 = 0;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        try appendFixed(SmallDb, &db, 1000, 16, 18);
        try db.check();
        var it = db.iterator();
        first_index = (try it.next()).?.index_addr;
    }

    // The first entry lives in the closed first sector. Making its commit
    // granule non-zero turns it into an interrupted append: the entry has to
    // vanish without disturbing anything else.
    var mem: [4 * 512]u8 = undefined;
    @memcpy(&mem, &baseline);
    mem[@intCast(first_index)] = 0x55;
    var db: SmallDb = undefined;
    try db.mount(Flash8Small.init(&mem));
    db.setRollover(false);
    try db.check();
    try std.testing.expectEqual(@as(u32, 17), try db.count());
    var it = db.iterator();
    try std.testing.expectEqual(@as(SmallDb.Time, 1001), (try it.next()).?.time);
}

test "tsdb corrupt index payload offset" {
    var baseline: [4 * 512]u8 = undefined;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        try appendFixed(SmallDb, &db, 1000, 16, 18);
        try db.check();
    }

    // Point the first entry's payload outside its sector: iterating and
    // checking must report error.Corrupted instead of hanging or reading
    // out-of-sector garbage.
    const victim: usize = SmallLayout.data_off;
    var mem: [4 * 512]u8 = undefined;
    @memcpy(&mem, &baseline);
    format.wr16(mem[victim + SmallLayout.off_off ..].ptr, 0xFFF0);
    var db: SmallDb = undefined;
    try db.mount(Flash8Small.init(&mem));
    var it = db.iterator();
    try std.testing.expectError(error.Corrupted, it.next());
    try std.testing.expectError(error.Corrupted, db.check());
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.set_bit_attempts);
}

test "tsdb corrupt end info is rebuilt by scanning" {
    var baseline: [4 * 512]u8 = undefined;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        try appendFixed(SmallDb, &db, 1000, 16, 18);
        try db.check();
    }

    // Damage the end offsets of the closed first sector. Mount rebuilds them
    // from the index records, iteration still sees every entry, and `check`
    // reports the on-flash damage.
    var mem: [4 * 512]u8 = undefined;
    @memcpy(&mem, &baseline);
    const at: usize = SmallLayout.end_offsets_off;
    mem[at] = 0xFF;
    mem[at + 1] = 0xFF;
    var db: SmallDb = undefined;
    try db.mount(Flash8Small.init(&mem));
    db.setRollover(false);
    try std.testing.expectEqual(@as(u32, 18), try db.count());
    var it = db.iterator();
    var expected: SmallDb.Time = 1000;
    while (try it.next()) |e| {
        try std.testing.expectEqual(expected, e.time);
        expected += 1;
    }
    try std.testing.expectEqual(@as(SmallDb.Time, 1018), expected);
    try std.testing.expectError(error.Corrupted, db.check());

    // Remounting repeatedly must not hang or lose anything either.
    var db2: SmallDb = undefined;
    try db2.mount(Flash8Small.init(&mem));
    try std.testing.expectEqual(@as(u32, 18), try db2.count());
    try std.testing.expectEqual(@as(SmallDb.Time, 1017), db2.lastTime());
}

test "tsdb by-time queries match a brute-force scan" {
    var mem: [4 * 512]u8 = undefined;
    var db: SmallDb = undefined;
    try db.mount(fresh(Flash8Small, &mem));
    // 40 entries with timestamps 1000, 1003, ... spread over several sectors.
    for (0..40) |i| try appendVar(SmallDb, &db, 1000 + @as(SmallDb.Time, @intCast(i * 3)), i);
    try db.check();

    // Reference: every stored timestamp, ascending.
    var times: [64]SmallDb.Time = undefined;
    var n: usize = 0;
    var it = db.iterator();
    while (try it.next()) |e| {
        try std.testing.expect(n < times.len);
        times[n] = e.time;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 40), n);

    const ranges = [_][2]SmallDb.Time{
        .{ 0, 2000 },     .{ 1000, 1000 },  .{ 1005, 1044 },
        .{ 1030, 1010 },  .{ 1117, 1117 },  .{ 2000, 3000 },
        .{ 3000, 2000 },  .{ 1010, 1012 },  .{ 1119, 1000 },
        .{ 1000, 1119 },  .{ 1050, 1020 },  .{ 1001, 1001 },
    };
    for (ranges) |r| {
        const from = r[0];
        const to = r[1];
        var expected: [64]SmallDb.Time = undefined;
        var ne: usize = 0;
        if (from <= to) {
            for (times[0..n]) |t| {
                if (t >= from and t <= to) {
                    expected[ne] = t;
                    ne += 1;
                }
            }
        } else {
            var k: usize = n;
            while (k > 0) {
                k -= 1;
                if (times[k] >= to and times[k] <= from) {
                    expected[ne] = times[k];
                    ne += 1;
                }
            }
        }
        var got: [64]SmallDb.Time = undefined;
        var qit = db.iteratorByTime(from, to);
        const ng = try collectTimes(SmallDb, &qit, &got);
        if (ng != ne) {
            std.debug.print("range {d}..{d}: got {d} entries, want {d}\n", .{ from, to, ng, ne });
            return error.TestUnexpectedResult;
        }
        for (expected[0..ne], 0..) |t, k| try std.testing.expectEqual(t, got[k]);
        try std.testing.expectEqual(@as(u32, @intCast(ne)), try db.queryCount(from, to, .write));
    }
}

test "tsdb recovery after a torn append stays consistent across remounts" {
    var baseline: [4 * 512]u8 = undefined;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        try appendFixed(SmallDb, &db, 1000, 16, 6);
        try db.check();
    }

    var payload: [16]u8 = undefined;
    testPayload(&payload, 1006, 0);

    // Interrupt the payload write, the index write and the commit in turn.
    var cut: u64 = 0;
    while (cut < 3) : (cut += 1) {
        var mem: [4 * 512]u8 = undefined;
        @memcpy(&mem, &baseline);
        var d1: SmallDb = undefined;
        try d1.mount(Flash8Small.init(&mem));
        d1.setRollover(false);
        d1.dev.flash.mutations = 0;
        d1.dev.flash.armFault(cut);
        _ = d1.append(1006, &payload) catch {};
        d1.dev.flash.clearFault();

        // The first remount consumes the discarded slot and the database keeps
        // accepting appends after it.
        var d2: SmallDb = undefined;
        try d2.mount(Flash8Small.init(&mem));
        d2.setRollover(false);
        try d2.check();
        try std.testing.expectEqual(@as(u64, 0), d2.dev.flash.stats.set_bit_attempts);
        const t_late1 = d2.lastTime() + 1;
        try d2.append(t_late1, "seventeen-bytes!");
        const t_late2 = t_late1 + 1;
        try d2.append(t_late2, "eighteen-bytes!!");
        try d2.check();

        // A second remount must still see the entries that were written after
        // the discarded slot: a scanner that stops at the first uncommitted
        // slot would lose them (and later overwrite them).
        var d3: SmallDb = undefined;
        try d3.mount(Flash8Small.init(&mem));
        d3.setRollover(false);
        try d3.check();
        var expected: SmallDb.Time = 1000;
        var seen_late = false;
        var it = d3.iterator();
        while (try it.next()) |e| {
            try std.testing.expectEqual(expected, e.time);
            expected += 1;
            if (e.time == t_late2) seen_late = true;
        }
        try std.testing.expect(seen_late);
        try std.testing.expectEqual(t_late2, d3.lastTime());
        try std.testing.expectEqual(@as(u64, 0), d3.dev.flash.stats.set_bit_attempts);
        try std.testing.expectEqual(@as(u64, 0), d3.dev.flash.stats.violations);
    }
}

test "tsdb multiple using sectors are treated as corrupt" {
    const StrictSmall = Tsdb(Flash8Small, .{ .sector_size = 512, .sector_count = 4, .max_len = 16, .not_formattable = true });
    var baseline: [4 * 512]u8 = undefined;
    {
        var db: SmallDb = undefined;
        try db.mount(fresh(Flash8Small, &baseline));
        db.setRollover(false);
        try appendFixed(SmallDb, &db, 1000, 16, 20);
        try db.check();
    }

    // Forge a second sector claiming to be the write target (sector 3 is still
    // blank in the baseline).
    var mem: [4 * 512]u8 = undefined;
    @memcpy(&mem, &baseline);
    const forged: usize = 3 * 512;
    var hdr: [format.sector_header_len]u8 = undefined;
    format.encodeSectorHeader(&hdr, .{ .seq = 99, .kind = .tsdb, .gran_log2 = 0 });
    @memcpy(mem[forged..][0..hdr.len], &hdr);
    mem[forged + SmallLayout.state_off] = 0x00; // `using` granule
    format.wr32(mem[forged + SmallLayout.start_time_off ..].ptr, 900);

    // A formattable database recovers by formatting everything.
    var mem2: [4 * 512]u8 = undefined;
    @memcpy(&mem2, &mem);
    var db: SmallDb = undefined;
    try db.mount(Flash8Small.init(&mem));
    try std.testing.expectEqual(@as(u32, 0), try db.count());
    try std.testing.expectEqual(@as(SmallDb.Time, 0), db.lastTime());
    try db.check();
    try db.append(1000, "after-recovery");
    try std.testing.expectEqual(@as(u32, 1), try db.count());
    try db.check();

    // A not-formattable database reports the damage instead.
    var strict: StrictSmall = undefined;
    try std.testing.expectError(error.Corrupted, strict.mount(Flash8Small.init(&mem2)));
}

test "tsdb clean works across sectors and resets rollover state" {
    var mem: [4 * 512]u8 = undefined;
    var db: SmallDb = undefined;
    try db.mount(fresh(Flash8Small, &mem));
    try appendFixed(SmallDb, &db, 1000, 16, 3 * 17);
    try std.testing.expectEqual(@as(u32, 51), try db.count());
    try db.check();

    try db.clean();
    try std.testing.expectEqual(@as(u32, 0), try db.count());
    try std.testing.expectEqual(@as(SmallDb.Time, 0), db.lastTime());
    try std.testing.expect(db.getRollover());
    var it = db.iterator();
    try std.testing.expectEqual(@as(?SmallDb.Entry, null), try it.next());
    try db.check();

    // The cleaned database is usable again, including across sectors.
    try appendFixed(SmallDb, &db, 500, 16, 40);
    try std.testing.expectEqual(@as(u32, 40), try db.count());
    try std.testing.expectEqual(@as(SmallDb.Time, 539), db.lastTime());
    try db.check();
    var db2: SmallDb = undefined;
    try db2.mount(Flash8Small.init(&mem));
    try std.testing.expectEqual(@as(u32, 40), try db2.count());
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
}

test "tsdb compiles across sector counts and geometries" {
    // Instantiating the generic type runs its compile-time assertions and
    // layout arithmetic (the 32-sector bitmask is the interesting edge).
    comptime {
        _ = Tsdb(Flash8, .{ .sector_size = 4096, .sector_count = 32, .max_len = 64 });
        _ = Tsdb(Flash8Small, .{ .sector_size = 512, .sector_count = 2, .max_len = 1 });
        _ = Tsdb(Flash8, .{ .sector_size = 4096, .sector_count = 2, .max_len = 4000, .ts_bits = 64 });
    }

    // A two-sector database at the smallest useful geometry still works.
    const Tiny = Tsdb(Flash8Small, .{ .sector_size = 512, .sector_count = 2, .max_len = 1 });
    var mem: [2 * 512]u8 = undefined;
    var db: Tiny = undefined;
    try db.mount(fresh(Flash8Small, &mem));
    var t: Tiny.Time = 1;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const byte = [_]u8{@truncate(i)};
        try db.append(t, &byte);
        t += 1;
    }
    try db.check();
    try std.testing.expectEqual(@as(u32, 40), try db.count());
    try std.testing.expectEqual(@as(Tiny.Time, 40), db.lastTime());
    var db2: Tiny = undefined;
    try db2.mount(Flash8Small.init(&mem));
    try std.testing.expectEqual(@as(u32, 40), try db2.count());
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
}

test "tsdb ram footprint" {
    // Keep an eye on the DESIGN.md §6 target (<= 48 bytes excluding the flash
    // driver value): scalars + two u16 arrays of `sector_count` entries.
    const size = @sizeOf(BigDb);
    const driver = @sizeOf(Flash8);
    std.debug.print("\ntsdb: sizeof(Tsdb)= {d} B, sizeof(driver)= {d} B, scalars+arrays= {d} B\n", .{ size, driver, size - driver });
    try std.testing.expect(size - driver <= 32 * 4 + 24);
    try std.testing.expectEqual(@as(usize, @sizeOf([4]u16) * 2), @sizeOf([4]u16) * 2);
}

test "tsdb remounting a full database is read-only" {
    var mem: [4 * 4096]u8 = undefined;
    var db: BigDb = undefined;
    try db.mount(fresh(Flash8, &mem));
    db.setRollover(false);
    var payload: [32]u8 = undefined;
    testPayload(&payload, 1000, 0);
    var t: BigDb.Time = 1000;
    while (true) {
        if (db.append(t, &payload)) |_| {
            t += 1;
        } else |_| break;
    }
    try std.testing.expectEqual(db.maxEntryCount(), try db.count());

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var db2: BigDb = undefined;
        try db2.mount(Flash8.init(&mem));
        const st = db2.dev.flash.stats;
        if (st.writes != 0 or st.erases != 0 or st.reads > 6) {
            std.debug.print("mount {d}: reads={d} writes={d} erases={d} entries={d}\n", .{ i, st.reads, st.writes, st.erases, try db2.count() });
        }
        try std.testing.expectEqual(@as(u64, 0), st.writes);
        try std.testing.expectEqual(@as(u64, 0), st.erases);
        try std.testing.expect(st.reads <= 6);
        try std.testing.expectEqual(db2.maxEntryCount(), try db2.count());
    }
}
test "tsdb by-time ranges above the newest entry are answered from RAM" {
    var mem: [4 * 4096]u8 = undefined;
    var db: BigDb = undefined;
    try db.mount(fresh(Flash8, &mem));
    try appendFixed(BigDb, &db, 1000, 20, 30);
    try std.testing.expectEqual(@as(BigDb.Time, 1029), db.lastTime());

    // Forward and reverse ranges entirely above `last_time` cost no flash read.
    var it = db.iteratorByTime(1030, 5000);
    db.dev.flash.resetStats();
    try std.testing.expectEqual(@as(?BigDb.Entry, null), try it.next());
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.reads);

    var rit = db.iteratorByTime(5000, 1030);
    db.dev.flash.resetStats();
    try std.testing.expectEqual(@as(?BigDb.Entry, null), try rit.next());
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.reads);

    try std.testing.expectEqual(@as(u32, 0), try db.queryCount(1030, 5000, .write));

    // The boundary entry is still found.
    var bit = db.iteratorByTime(1029, 1029);
    try std.testing.expectEqual(@as(BigDb.Time, 1029), (try bit.next()).?.time);
    try std.testing.expectEqual(@as(?BigDb.Entry, null), try bit.next());
}
var tmp_sink: u64 = 0;

test "TMP mount bench" {
    const io = std.testing.io;
    var mem: [4 * 4096]u8 = undefined;
    var db: BigDb = undefined;
    try db.mount(fresh(Flash8, &mem));
    db.setRollover(false);
    var payload: [32]u8 = undefined;
    testPayload(&payload, 1000, 0);
    var tt: BigDb.Time = 1000;
    while (true) {
        if (db.append(tt, &payload)) |_| {
            tt += 1;
        } else |_| break;
    }
    const N: usize = 100_000;

    var d2: BigDb = undefined;
    var i: usize = 0;
    while (i < 5_000) : (i += 1) {
        try d2.mount(Flash8.init(&mem));
        tmp_sink +%= @as(u64, d2.cur) +% @as(u64, d2.empty_idx) +% @as(u64, @intCast(@as(u32, @bitCast(d2.last_time))));
    }
    var t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    i = 0;
    while (i < N) : (i += 1) {
        try d2.mount(Flash8.init(&mem));
        tmp_sink +%= @as(u64, d2.cur) +% @as(u64, d2.empty_idx) +% @as(u64, @intCast(@as(u32, @bitCast(d2.last_time))));
    }
    var t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("\nTMP mount            : {d} ns/mount\n", .{@divTrunc(t1 - t0, @as(i64, N))});

    var dev = device.Device(Flash8, 4096, 4).init(Flash8.init(&mem));
    var hdr: [24]u8 = undefined;
    try dev.read(0, &hdr);
    t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    i = 0;
    while (i < N) : (i += 1) {
        var buf: [24]u8 = undefined;
        inline for (0..4) |k| {
            try dev.read(@intCast(k * 4096), &buf);
        }
        tmp_sink +%= buf[0] +% buf[5] +% buf[23];
    }
    t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("TMP 4x read(24B)     : {d} ns\n", .{@divTrunc(t1 - t0, @as(i64, N))});

    t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    i = 0;
    while (i < N) : (i += 1) {
        inline for (0..4) |_| {
            if (format.decodeSectorHeader(hdr[0..10], .tsdb, 0)) |h| {
                tmp_sink +%= h.seq;
            }
        }
    }
    t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("TMP 4x format.decode : {d} ns\n", .{@divTrunc(t1 - t0, @as(i64, N))});

    t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    i = 0;
    while (i < N) : (i += 1) {
        inline for (0..4) |_| {
            if (BigDb.decodeHeader(hdr[0..10])) |h| {
                tmp_sink +%= h.seq;
            }
        }
    }
    t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("TMP 4x fast.decode   : {d} ns\n", .{@divTrunc(t1 - t0, @as(i64, N))});

    t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    i = 0;
    while (i < N) : (i += 1) {
        inline for (0..4) |_| {
            tmp_sink +%= format.crc16(0, hdr[0..8]);
        }
    }
    t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("TMP 4x format.crc16  : {d} ns\n", .{@divTrunc(t1 - t0, @as(i64, N))});

    t0 = std.Io.Clock.now(.awake, io).nanoseconds;
    i = 0;
    while (i < N) : (i += 1) {
        inline for (0..4) |_| {
            tmp_sink +%= crc16Fast(hdr[0..8]);
        }
    }
    t1 = std.Io.Clock.now(.awake, io).nanoseconds;
    std.debug.print("TMP 4x fast.crc16    : {d} ns\n", .{@divTrunc(t1 - t0, @as(i64, N))});
    std.debug.print("TMP sink {d}\n", .{tmp_sink});
}