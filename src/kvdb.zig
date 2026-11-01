//! KVDB: key-value database over raw NOR flash.
//!
//! New on-flash format (see `docs/DESIGN.md` §3.2): every record is committed by
//! clearing a single write-granule marker, so a power cut either keeps the old
//! value or exposes the new one, never a torn record. Superseded records get a
//! `pending` marker first (immediately invisible, recoverable) and a `deleted`
//! marker after the new value is durable. No global state, no heap, no locks:
//! the database owns its flash driver value.

const std = @import("std");
const format = @import("format.zig");
const crc = @import("crc.zig");
const device = @import("device.zig");

pub const Config = struct {
    /// Erase sector size in bytes (power of two, multiple of the driver's erase
    /// block size). Compile-time.
    sector_size: u32 = 4096,
    /// Number of sectors of the database (3..32). Compile-time.
    sector_count: u16 = 4,
    /// Maximum key length in bytes (1..255). Compile-time.
    max_name_len: u16 = 64,
    /// Name-cache entries; 0 disables the cache, otherwise even and <= 64
    /// (2-way set associative). Compile-time.
    cache_entries: u16 = 128,
    /// Bulk copy/verify chunk size in bytes (multiple of the granule, <= 64).
    chunk_size: u16 = 64,
    /// When true a blank or damaged partition yields `error.NotFormatted`
    /// instead of being formatted automatically.
    not_formattable: bool = false,
};

pub fn Kvdb(comptime F: type, comptime cfg: Config) type {
    comptime {
        if (cfg.sector_count < 3) @compileError("KVDB needs at least 3 sectors");
        if (cfg.sector_count > 32) @compileError("KVDB supports at most 32 sectors");
        if (cfg.max_name_len < 1 or cfg.max_name_len > 255) @compileError("max_name_len must be 1..255");
        if (cfg.cache_entries != 0 and (cfg.cache_entries < 4 or cfg.cache_entries > 128 or cfg.cache_entries % 4 != 0))
            @compileError("cache_entries must be 0 or a multiple of 4, <= 128");
        if (cfg.sector_size > 0xFFFF) @compileError("sector_size must be <= 65535");
        if (cfg.chunk_size == 0 or cfg.chunk_size > 64 or
            cfg.chunk_size % device.Device(F, cfg.sector_size, cfg.sector_count).gran != 0)
            @compileError("chunk_size must be a multiple of the write granule and <= 64");
    }

    const D = device.Device(F, cfg.sector_size, cfg.sector_count);
    const g = D.gran;
    const L = format.KvLayout(g, cfg.sector_size > 0xFFFF);
    const VW = L.value_len_bytes;
    const Addr = if (D.total_size <= 0xFFFF) u16 else u32;
    const NO_SECTOR: u16 = 0xFFFF;

    // Layout constants in the address integer type used by the hot paths.
    const data_off: u32 = @intCast(L.data_off);
    const name_off: u32 = @intCast(L.name_off);
    const pending_off: u32 = @intCast(L.pending_off);
    const deleted_off: u32 = @intCast(L.deleted_off);
    const status_len: u32 = @intCast(3 * g);
    const gu: u32 = @intCast(g);
    const hdr_name_max: usize = L.hdrNameLen(cfg.max_name_len);
    const max_rec_len: u32 = cfg.sector_size - data_off;
    const ver_num_key = "__ver_num__";

    return struct {
        const Self = @This();

        pub const Error = D.Error || error{
            NotFormatted,
            InvalidName,
            SavedFull,
            Corrupted,
            InitFailed,
        };

        /// Largest value length that always fits, i.e. with a key of
        /// `max_name_len` bytes. Shorter keys can store more; use
        /// `maxValueLenFor(key_len)` for the exact per-key limit.
        pub const max_value_len: u32 = max_rec_len - @as(u32, @intCast(L.valueOff(cfg.max_name_len)));

        /// Largest value that fits together with a key of `key_len` bytes.
        pub inline fn maxValueLenFor(key_len: usize) u32 {
            return max_rec_len - @as(u32, @intCast(L.valueOff(key_len)));
        }

        const Record = struct {
            addr: u32,
            name_len: u16,
            value_len: u32,
            crc: u32,
            len: u32,
        };

        const Header = struct {
            committed: bool,
            pending: bool,
            deleted: bool,
            blank: bool,
            sane: bool,
            name_len: u16,
            value_len: u32,
            crc: u32,
            len: u32,
        };

        const CacheEntry = struct {
            tag: u16 = 0,
            addr: Addr = 0,
        };
        const cache_ways = 4;
        const cache_way_bits = 2;
        const cache_sets: u16 = if (cfg.cache_entries == 0) 1 else cfg.cache_entries / cache_ways;

        // ---- state -------------------------------------------------------
        dev: D,
        /// Highest sector sequence handed out so far.
        seq: u16 = 0,
        /// Sector currently receiving records (highest sequence); NO_SECTOR if a
        /// new one must be formatted first.
        cur: u16 = NO_SECTOR,
        /// Per-sector next free offset (sector-relative, 0 = unknown).
        empty_off: [cfg.sector_count]u16 = @splat(0),
        /// Per-sector sector header sequence.
        seqs: [cfg.sector_count]u16 = @splat(0),
        /// Sectors ascending by sequence (valid prefix of `order_len`).
        order: [cfg.sector_count]u16 = @splat(0),
        order_len: u16 = 0,
        known_mask: u32 = 0,
        dirty_mask: u32 = 0,
        /// Sectors whose contents are known to be fully erased (skip the erase
        /// before formatting them).
        pristine: u32 = 0,
        cache: [cfg.cache_entries]CacheEntry = @splat(CacheEntry{}),
        /// Next way to replace per cache set (2 bits each, round-robin).
        cache_rr: u64 = 0,

        // ---- public API --------------------------------------------------

        /// Mount (or initialise) the database on `f`. The database takes a copy
        /// of the driver value, so `*Self` can live in `.bss` without copying the
        /// whole database through the stack.
        pub fn mount(self: *Self, f: F) Error!void {
            self.* = .{ .dev = D.init(f) };
            try self.load();
        }

        /// Reformat every sector and reset the database (destructive).
        pub fn formatAll(self: *Self) Error!void {
            try self.formatBlank();
        }

        /// Erase and pre-format every sector: the whole partition is claimed up
        /// front (same initial cost as FlashDB's first mount), later sector reuse
        /// skips the erase because the sector is tracked as pristine, and the
        /// sequence numbers make physical order == logical order.
        fn formatBlank(self: *Self) Error!void {
            var i: u16 = 0;
            while (i < cfg.sector_count) : (i += 1) {
                try self.dev.eraseSector(i);
                const bit = sectorBitOfIndex(i);
                self.pristine |= bit;
                self.known_mask &= ~bit;
                self.dirty_mask &= ~bit;
                self.empty_off[i] = 0;
            }
            self.cacheClear();
            self.seq = 0;
            self.cur = NO_SECTOR;
            // Only the first sector is pre-formatted; the others stay erased and
            // unformatted so claiming them later needs no second erase.
            try self.formatAsCurrent(0);
            self.rebuildOrder();
        }
        /// Store `value` under `key`, overwriting any previous value.
        pub fn set(self: *Self, key: []const u8, value: []const u8) Error!void {
            try self.checkKey(key);
            // Reject impossible records *before* touching the flash: otherwise
            // allocation would keep formatting fresh sectors looking for space
            // that can never exist. The limit depends on the key length (shorter
            // keys leave room for larger values), so it is checked on the exact
            // record length rather than on `max_value_len`.
            const rec_len_usize = L.recordLen(key.len, value.len);
            if (rec_len_usize > max_rec_len) return error.SavedFull;
            const rec_len: u32 = @intCast(rec_len_usize);

            // Reserve space first: allocation may run GC, which can move records
            // (including the previous value of `key`), so the old record must be
            // looked up *after* the allocation.
            const addr = try self.allocRec(rec_len);

            var old: Record = undefined;
            const has_old = try self.findVisible(key, &old);

            if (has_old) {
                try self.dev.mark(old.addr + pending_off);
                self.dirty_mask |= sectorBitOfAddr(old.addr);
            }
            try self.writeRecordData(addr, key, value);
            if (has_old) {
                try self.dev.mark(old.addr + deleted_off);
            }
            self.cacheInsert(key, addr);
        }

        /// Delete `key`. Returns false when the key does not exist.
        pub fn delete(self: *Self, key: []const u8) Error!bool {
            try self.checkKey(key);
            var old: Record = undefined;
            if (!try self.findVisible(key, &old)) return false;
            // A single-granule `deleted` write is atomic: a torn write leaves the
            // granule non-zero, which still reads as "not deleted".
            try self.dev.mark(old.addr + deleted_off);
            self.dirty_mask |= sectorBitOfAddr(old.addr);
            self.cacheInvalidate(key);
            return true;
        }

        /// Read the value of `key`. Copies `min(buf.len, value.len)` bytes into
        /// `buf` and returns the total value length, or null when not found.
        /// The CRC32 of the whole record is verified in the same pass.
        pub fn get(self: *Self, key: []const u8, buf: []u8) Error!?u32 {
            try self.checkKey(key);
            var rec: Record = undefined;
            if (!try self.findVisible(key, &rec)) return null;
            _ = try self.readValue(rec.addr + valueOff(rec.name_len), rec, key, buf);
            return rec.value_len;
        }

        /// True when `key` currently has a value.
        pub fn contains(self: *Self, key: []const u8) Error!bool {
            var rec: Record = undefined;
            return self.findVisible(key, &rec);
        }

        /// Number of live records (walks the database; O(records)).
        pub fn count(self: *Self) Error!u32 {
            var it = self.iterator();
            var n: u32 = 0;
            while (try it.next() != null) n += 1;
            return n;
        }

        /// Iterate over live records in sector sequence order.
        pub fn iterator(self: *Self) Iterator {
            return .{ .db = self };
        }

        /// Verify the CRC32 of every live record (equivalent to
        /// `fdb_kvdb_check`). Returns error.Corrupted on the first bad record.
        pub fn check(self: *Self) Error!void {
            var it = self.iterator();
            var dummy: [0]u8 = .{};
            while (try it.next()) |entry| {
                _ = try it.readValue(&dummy, entry);
            }
        }

        /// Default key/value pair used by `autoUpdate`.
        pub const DefaultKv = struct {
            key: []const u8,
            value: []const u8,
        };

        /// Schema-migration helper equivalent to `FDB_KV_AUTO_UPDATE`: when the
        /// stored `__ver_num__` differs from `version`, every missing default key
        /// is created and the new version is stored.
        pub fn autoUpdate(self: *Self, version: u32, defaults: []const DefaultKv) Error!void {
            var vbuf: [4]u8 = undefined;
            var stored: u32 = 0;
            if (try self.get(ver_num_key, &vbuf)) |n| {
                if (n == 4) stored = format.rd32(&vbuf);
            }
            if (stored == version) return;
            for (defaults) |kv| {
                var rec: Record = undefined;
                if (!try self.findVisible(kv.key, &rec)) try self.set(kv.key, kv.value);
            }
            format.wr32(&vbuf, version);
            try self.set(ver_num_key, &vbuf);
        }

        // ---- iterator -----------------------------------------------------

        pub const Entry = struct {
            addr: u32,
            name_len: u16,
            value_len: u32,
            crc: u32,
            /// Points into the iterator's internal buffer; valid until the next
            /// call to `next`.
            name: []const u8,
        };

        pub const Iterator = struct {
            db: *Self,
            sector_pos: u16 = 0,
            pos: u32 = 0,
            name_buf: [cfg.max_name_len]u8 = undefined,

            pub fn next(self: *Iterator) Error!?Entry {
                const db = self.db;
                while (self.sector_pos < db.order_len) {
                    const si = db.order[self.sector_pos];
                    const base = db.dev.sectorAddr(si);
                    const limit: u32 = db.empty_off[si];
                    if (self.pos == 0) self.pos = data_off;
                    while (self.pos + name_off <= limit) {
                        const h = try db.readRecordHeader(base + self.pos);
                        if (h.blank) {
                            self.pos = limit;
                            break;
                        }
                        if (!h.sane) {
                            // A torn/foreign header can sit between records; the
                            // mount scan already resynced past it, so readers must
                            // do the same instead of ending the sector early.
                            if (try db.resync(base, self.pos + gu)) |next_pos| {
                                self.pos = next_pos;
                                continue;
                            }
                            self.pos = limit;
                            break;
                        }
                        const addr = base + self.pos;
                        self.pos += h.len;
                        if (h.committed and !h.pending and !h.deleted) {
                            try db.dev.read(addr + name_off, self.name_buf[0..h.name_len]);
                            return .{
                                .addr = addr,
                                .name_len = h.name_len,
                                .value_len = h.value_len,
                                .crc = h.crc,
                                .name = self.name_buf[0..h.name_len],
                            };
                        }
                    }
                    self.sector_pos += 1;
                    self.pos = 0;
                }
                return null;
            }

            /// Read the value of `entry`, verifying the record CRC32 in the same
            /// pass. Copies `min(buf.len, entry.value_len)` bytes.
            pub fn readValue(self: *Iterator, buf: []u8, entry: Entry) Error!u32 {
                const db = self.db;
                const rec = Record{
                    .addr = entry.addr,
                    .name_len = entry.name_len,
                    .value_len = entry.value_len,
                    .crc = entry.crc,
                    .len = @intCast(L.recordLen(entry.name_len, entry.value_len)),
                };
                return db.readValue(entry.addr + valueOff(rec.name_len), rec, entry.name, buf);
            }
        };

        // ---- internals ----------------------------------------------------

        inline fn valueOff(name_len: usize) u32 {
            return @intCast(L.valueOff(name_len));
        }

        inline fn sectorBitOfIndex(index: u16) u32 {
            return @as(u32, 1) << @intCast(index);
        }

        inline fn sectorBitOfAddr(addr: u32) u32 {
            return @as(u32, 1) << @intCast(addr / cfg.sector_size);
        }

        fn checkKey(self: *const Self, key: []const u8) Error!void {
            _ = self;
            if (key.len == 0 or key.len > cfg.max_name_len) return error.InvalidName;
        }

        /// Read and decode a record header (one flash read).
        fn readRecordHeader(self: *Self, addr: u32) Error!Header {
            var buf: [name_off]u8 = undefined;
            try self.dev.read(addr, &buf);

            var all_erased = true;
            for (&buf) |b| {
                if (b != 0xFF) {
                    all_erased = false;
                    break;
                }
            }
            const commit = format.granuleIsZero(g, &buf);
            const pending = format.granuleIsZero(g, buf[L.pending_off..].ptr);
            const deleted = format.granuleIsZero(g, buf[L.deleted_off..].ptr);
            const name_len: u16 = buf[L.name_len_off];
            const value_len: u32 = format.rdN(VW, buf[L.value_len_off..].ptr);
            const rec_crc = format.rd32(buf[L.crc_off..].ptr);
            // The per-record limit depends on the key length, so it is checked
            // against the header's own name_len (a 1-byte key can carry a larger
            // value than a max-length key).
            var len: u32 = 0;
            var sane = false;
            if (!all_erased and name_len >= 1 and name_len <= cfg.max_name_len) {
                const max_value = max_rec_len - @as(u32, @intCast(L.valueOff(name_len)));
                if (value_len <= max_value) {
                    const l: u32 = @intCast(L.recordLen(name_len, value_len));
                    if (l <= max_rec_len and (commit or (!pending and !deleted))) {
                        len = l;
                        sane = true;
                    }
                }
            }
            return .{
                .committed = commit,
                .pending = pending,
                .deleted = deleted,
                .blank = all_erased,
                .sane = sane,
                .name_len = name_len,
                .value_len = value_len,
                .crc = rec_crc,
                .len = len,
            };
        }

        /// Advance to the first granule-aligned offset >= `from` whose granule is
        /// still erased. Used to skip the remnants of an interrupted write.
        fn findFreeOffset(self: *Self, base: u32, from: u32) Error!u32 {
            var pos: u32 = @intCast(format.alignUp(g, from));
            while (pos < cfg.sector_size) {
                const want: u32 = @min(32, cfg.sector_size - pos);
                var chunk: [32]u8 = undefined;
                try self.dev.read(base + pos, chunk[0..want]);
                var all_ff = true;
                for (chunk[0..want]) |b| {
                    if (b != 0xFF) {
                        all_ff = false;
                        break;
                    }
                }
                if (all_ff) return pos;
                var off: u32 = 0;
                while (off + gu <= want) : (off += gu) {
                    if (format.granuleIsErased(g, chunk[off..].ptr)) return pos + off;
                }
                pos += want;
            }
            return cfg.sector_size;
        }

        /// Find the next committed record at or after `from` (recovery resync).
        fn resync(self: *Self, base: u32, from: u32) Error!?u32 {
            var pos: u32 = @intCast(format.alignUp(g, from));
            while (pos < cfg.sector_size) {
                const want: u32 = @min(32, cfg.sector_size - pos);
                var chunk: [32]u8 = undefined;
                try self.dev.read(base + pos, chunk[0..want]);
                var off: u32 = 0;
                while (off + gu <= want) : (off += gu) {
                    if (format.granuleIsZero(g, chunk[off..].ptr)) return pos + off;
                }
                pos += want;
            }
            return null;
        }

        const ScanFlags = struct { dirty: bool = false, pending: bool = false };

        /// Walk one sector, computing its next free offset and flagging garbage.
        fn scanSector(self: *Self, index: u16) Error!ScanFlags {
            const base = self.dev.sectorAddr(index);
            var pos: u32 = data_off;
            var flags: ScanFlags = .{};
            while (pos + name_off <= cfg.sector_size) {
                const h = try self.readRecordHeader(base + pos);
                if (h.blank) {
                    pos = try self.findFreeOffset(base, pos);
                    break;
                }
                if (!h.sane) {
                    flags.dirty = true;
                    if (try self.resync(base, pos + gu)) |next_pos| {
                        pos = next_pos;
                        continue;
                    }
                    pos = try self.findFreeOffset(base, pos + gu);
                    break;
                }
                if (!h.committed) {
                    // Interrupted write: the space is consumed but the record is
                    // invisible. Count it as garbage so GC reclaims it.
                    flags.dirty = true;
                    pos += h.len;
                    continue;
                }
                if (h.pending) {
                    flags.pending = true;
                    flags.dirty = true;
                }
                if (h.deleted) flags.dirty = true;
                pos += h.len;
            }
            self.empty_off[index] = @intCast(pos);
            return flags;
        }

        fn load(self: *Self) Error!void {
            var unknown: u16 = 0;
            var valid: u16 = 0;
            var have_seq = false;

            var i: u16 = 0;
            while (i < cfg.sector_count) : (i += 1) {
                const h = try self.dev.readHeader(i, .kvdb);
                if (h) |hh| {
                    valid += 1;
                    self.known_mask |= sectorBitOfIndex(i);
                    self.seqs[i] = hh.seq;
                    if (!have_seq or format.seqAfter(hh.seq, self.seq)) {
                        self.seq = hh.seq;
                        have_seq = true;
                    }
                } else {
                    unknown += 1;
                }
            }

            if (cfg.not_formattable and unknown > 0) return error.NotFormatted;
            if (valid == 0) {
                if (cfg.not_formattable) return error.NotFormatted;
                try self.formatBlank();
                return;
            }

            var pending_mask: u32 = 0;
            i = 0;
            while (i < cfg.sector_count) : (i += 1) {
                if (self.known_mask & sectorBitOfIndex(i) == 0) continue;
                const flags = try self.scanSector(i);
                if (flags.dirty) self.dirty_mask |= sectorBitOfIndex(i);
                if (flags.pending) pending_mask |= sectorBitOfIndex(i);
            }

            self.rebuildOrder();
            self.cur = self.findCurrentSector();

            if (pending_mask != 0) {
                try self.recoverPending(pending_mask);
                self.rebuildOrder();
                self.cur = self.findCurrentSector();
            }
        }

        fn findCurrentSector(self: *Self) u16 {
            var best: u16 = NO_SECTOR;
            var i: u16 = 0;
            while (i < cfg.sector_count) : (i += 1) {
                if (self.known_mask & sectorBitOfIndex(i) == 0) continue;
                if (best == NO_SECTOR or format.seqAfter(self.seqs[i], self.seqs[best])) best = i;
            }
            if (best == NO_SECTOR) return NO_SECTOR;
            const min_rec: u32 = @intCast(L.recordLen(1, 0));
            if (@as(u32, self.empty_off[best]) + min_rec <= cfg.sector_size) return best;
            return NO_SECTOR;
        }

        fn rebuildOrder(self: *Self) void {
            var used: u32 = 0;
            var n: u16 = 0;
            while (n < cfg.sector_count) : (n += 1) {
                var best: u16 = NO_SECTOR;
                var i: u16 = 0;
                while (i < cfg.sector_count) : (i += 1) {
                    if (self.known_mask & sectorBitOfIndex(i) == 0) continue;
                    if (used & sectorBitOfIndex(i) != 0) continue;
                    if (best == NO_SECTOR or format.seqAfter(self.seqs[best], self.seqs[i])) best = i;
                }
                if (best == NO_SECTOR) break;
                self.order[n] = best;
                used |= sectorBitOfIndex(best);
            }
            self.order_len = n;
        }

        fn formatAsCurrent(self: *Self, index: u16) Error!void {
            const bit = sectorBitOfIndex(index);
            if (self.pristine & bit == 0) try self.dev.eraseSector(index);
            self.pristine &= ~bit;
            self.seq +%= 1;
            if (self.seq == 0) self.seq = 1;
            try self.dev.writeHeader(index, .{
                .seq = self.seq,
                .kind = .kvdb,
                .gran_log2 = D.gran_log2,
            });
            self.known_mask |= bit;
            self.dirty_mask &= ~bit;
            self.seqs[index] = self.seq;
            self.empty_off[index] = @intCast(data_off);
            self.cur = index;
            self.cacheInvalidateSector(index);
        }

        /// Count recyclable sectors (unknown or formatted-but-empty) and dirty
        /// sectors; return the preferred sector to format into.
        fn pickFresh(self: *Self, avail: *u16, dirty_cnt: *u16) u16 {
            var best_unknown: u16 = NO_SECTOR;
            var best_empty: u16 = NO_SECTOR;
            avail.* = 0;
            dirty_cnt.* = 0;
            var i: u16 = 0;
            while (i < cfg.sector_count) : (i += 1) {
                const bit = sectorBitOfIndex(i);
                if (self.dirty_mask & bit != 0) dirty_cnt.* += 1;
                if (self.known_mask & bit == 0) {
                    avail.* += 1;
                    if (best_unknown == NO_SECTOR) best_unknown = i;
                } else if (self.empty_off[i] == data_off) {
                    avail.* += 1;
                    if (best_empty == NO_SECTOR or format.seqAfter(self.seqs[best_empty], self.seqs[i]))
                        best_empty = i;
                }
            }
            return if (best_unknown != NO_SECTOR) best_unknown else best_empty;
        }

        fn newCurrent(self: *Self) Error!void {
            var avail: u16 = 0;
            var dirty_cnt: u16 = 0;
            const fresh = self.pickFresh(&avail, &dirty_cnt);
            if (fresh == NO_SECTOR) return error.SavedFull;
            if (avail <= 1) {
                // The last spare sector is GC's only possible destination: never
                // put user data there. Compact instead (same reserve as FlashDB-C,
                // which also refuses to allocate the last empty sector).
                if (dirty_cnt == 0) return error.SavedFull;
                try self.formatAsCurrent(fresh);
                self.rebuildOrder();
                try self.collectOldest();
                self.rebuildOrder();
                return;
            }
            try self.formatAsCurrent(fresh);
            self.rebuildOrder();
        }

        fn allocRec(self: *Self, rec_len: u32) Error!u32 {
            var attempts: u16 = 0;
            while (true) {
                if (self.cur != NO_SECTOR) {
                    const ci = self.cur;
                    const off: u32 = self.empty_off[ci];
                    if (off + rec_len <= cfg.sector_size) {
                        self.empty_off[ci] = @intCast(off + rec_len);
                        return self.dev.sectorAddr(ci) + off;
                    }
                }
                if (attempts >= cfg.sector_count * 2 + 4) return error.SavedFull;
                attempts += 1;
                try self.newCurrent();
            }
        }

        /// Append the data part of a record (header fields + name + value) and
        /// then commit it.
        fn writeRecordData(self: *Self, addr: u32, key: []const u8, value: []const u8) Error!void {
            var header: [hdr_name_max]u8 = @splat(0xFF);
            header[0] = @intCast(key.len);
            format.wrN(VW, header[1..].ptr, @intCast(value.len));
            format.wr32(header[1 + VW ..].ptr, self.recordCrc(key, value));
            @memcpy(header[1 + VW + 4 ..][0..key.len], key);
            const hdr_len = L.hdrNameLen(key.len);
            try self.dev.writeAligned(addr + status_len, header[0..hdr_len]);
            if (value.len > 0) {
                try self.dev.writePadded(addr + valueOff(key.len), value);
            }
            try self.dev.mark(addr);
        }

        fn recordCrc(self: *Self, key: []const u8, value: []const u8) u32 {
            _ = self;
            var head: [1 + VW]u8 = undefined;
            head[0] = @intCast(key.len);
            format.wrN(VW, head[1..].ptr, @intCast(value.len));
            var c = crc.crc32(0, &head);
            c = crc.crc32(c, key);
            return crc.crc32(c, value);
        }

        fn recordCrcHeader(name_len: u16, value_len: u32) u32 {
            var head: [1 + VW]u8 = undefined;
            head[0] = @intCast(name_len);
            format.wrN(VW, head[1..].ptr, @intCast(value_len));
            return crc.crc32(0, &head);
        }

        /// Copy the data part (header fields + name + value) of a record.
        fn copyRecordData(self: *Self, src: u32, dst: u32, rec_len: u32) Error!void {
            var off: u32 = status_len;
            while (off < rec_len) {
                const n: u32 = @min(cfg.chunk_size, rec_len - off);
                var chunk: [cfg.chunk_size]u8 = undefined;
                try self.dev.read(src + off, chunk[0..n]);
                try self.dev.writeAligned(dst + off, chunk[0..n]);
                off += n;
            }
        }

        /// Move one live record to the current sector with the crash-safe
        /// pending -> copy -> commit -> deleted sequence.
        fn moveRecord(self: *Self, src: u32, rec_len: u32, already_pending: bool) Error!void {
            if (!already_pending) try self.dev.mark(src + pending_off);
            const dst = try self.allocRec(rec_len);
            try self.copyRecordData(src, dst, rec_len);
            try self.dev.mark(dst);
            try self.dev.mark(src + deleted_off);
            self.cacheReplaceAddr(src, dst);
        }

        fn collectOldest(self: *Self) Error!void {
            var target: u16 = NO_SECTOR;
            var i: u16 = 0;
            while (i < cfg.sector_count) : (i += 1) {
                if (self.dirty_mask & sectorBitOfIndex(i) == 0) continue;
                if (i == self.cur) continue;
                if (target == NO_SECTOR or format.seqAfter(self.seqs[target], self.seqs[i])) target = i;
            }
            if (target == NO_SECTOR) return;
            const base = self.dev.sectorAddr(target);

            var pos: u32 = data_off;
            while (pos + name_off <= cfg.sector_size) {
                const h = try self.readRecordHeader(base + pos);
                if (h.blank) break;
                if (!h.sane) {
                    // Skip the damaged region; records after it are still live
                    // and must be moved before this sector is erased.
                    if (try self.resync(base, pos + gu)) |next_pos| {
                        pos = next_pos;
                        continue;
                    }
                    break;
                }
                if (h.committed and !h.pending and !h.deleted) {
                    try self.moveRecord(base + pos, h.len, false);
                }
                pos += h.len;
            }

            try self.dev.eraseSector(target);
            const bit = sectorBitOfIndex(target);
            self.pristine |= bit;
            self.known_mask &= ~bit;
            self.dirty_mask &= ~bit;
            self.cacheInvalidateSector(target);
        }

        fn recoverPending(self: *Self, mask: u32) Error!void {
            var i: u16 = 0;
            while (i < cfg.sector_count) : (i += 1) {
                if (mask & sectorBitOfIndex(i) == 0) continue;
                const base = self.dev.sectorAddr(i);
                var pos: u32 = data_off;
                while (pos + name_off <= cfg.sector_size) {
                    const h = try self.readRecordHeader(base + pos);
                    if (h.blank) break;
                    if (!h.sane) {
                        if (try self.resync(base, pos + gu)) |next_pos| {
                            pos = next_pos;
                            continue;
                        }
                        break;
                    }
                    if (h.committed and h.pending and !h.deleted) {
                        var name_buf: [cfg.max_name_len]u8 = undefined;
                        try self.dev.read(base + pos + name_off, name_buf[0..h.name_len]);
                        var newer: Record = undefined;
                        if (try self.findVisible(name_buf[0..h.name_len], &newer)) {
                            // The update/GC already committed the successor.
                            try self.dev.mark(base + pos + deleted_off);
                        } else {
                            // No successor: restore the old value by moving it.
                            try self.moveRecord(base + pos, h.len, true);
                        }
                    }
                    pos += h.len;
                }
            }
        }

        fn findVisible(self: *Self, key: []const u8, out: *Record) Error!bool {
            const hash = crc.hashName(key);

            if (cfg.cache_entries > 0) {
                if (self.cacheProbe(hash)) |addr| {
                    const rh = try self.readRecordHeader(addr);
                    if (rh.committed and !rh.pending and !rh.deleted and rh.sane and rh.name_len == key.len) {
                        var nb: [cfg.max_name_len]u8 = undefined;
                        try self.dev.read(addr + name_off, nb[0..key.len]);
                        if (std.mem.eql(u8, nb[0..key.len], key)) {
                            out.* = .{
                                .addr = addr,
                                .name_len = rh.name_len,
                                .value_len = rh.value_len,
                                .crc = rh.crc,
                                .len = rh.len,
                            };
                            return true;
                        }
                    }
                    // Stale entry: drop it and fall through to the scan.
                    self.cacheInvalidate(key);
                }
            }

            var r: usize = self.order_len;
            while (r > 0) {
                r -= 1;
                const si = self.order[r];
                const base = self.dev.sectorAddr(si);
                const limit: u32 = self.empty_off[si];
                var pos: u32 = data_off;
                while (pos + name_off <= limit) {
                    const rh = try self.readRecordHeader(base + pos);
                    if (rh.blank) break;
                    if (!rh.sane) {
                        if (try self.resync(base, pos + gu)) |next_pos| {
                            pos = next_pos;
                            continue;
                        }
                        break;
                    }
                    const addr = base + pos;
                    pos += rh.len;
                    if (!rh.committed) continue;
                    if (rh.pending or rh.deleted) continue;
                    if (rh.name_len != key.len) continue;
                    var nb: [cfg.max_name_len]u8 = undefined;
                    try self.dev.read(addr + name_off, nb[0..key.len]);
                    if (!std.mem.eql(u8, nb[0..key.len], key)) continue;
                    out.* = .{
                        .addr = addr,
                        .name_len = rh.name_len,
                        .value_len = rh.value_len,
                        .crc = rh.crc,
                        .len = rh.len,
                    };
                    self.cacheInsert(key, addr);
                    return true;
                }
            }
            return false;
        }

        /// Stream a record value out, verifying the record CRC32 over the whole
        /// value in the same pass.
        fn readValue(self: *Self, value_addr: u32, rec: Record, name: []const u8, buf: []u8) Error!u32 {
            var c = recordCrcHeader(rec.name_len, rec.value_len);
            c = crc.crc32(c, name);
            var copied: usize = 0;
            if (buf.len >= rec.value_len) {
                if (rec.value_len > 0) {
                    try self.dev.read(value_addr, buf[0..rec.value_len]);
                    c = crc.crc32(c, buf[0..rec.value_len]);
                }
                copied = rec.value_len;
            } else {
                var off: u32 = 0;
                var tmp: [cfg.chunk_size]u8 = undefined;
                while (off < rec.value_len) {
                    const n: u32 = @min(cfg.chunk_size, rec.value_len - off);
                    try self.dev.read(value_addr + off, tmp[0..n]);
                    c = crc.crc32(c, tmp[0..n]);
                    const room = buf.len - copied;
                    const take: usize = @min(@as(usize, n), room);
                    if (take > 0) {
                        @memcpy(buf[copied..][0..take], tmp[0..take]);
                        copied += take;
                    }
                    off += n;
                }
            }
            if (c != rec.crc) {
                self.cacheInvalidateSector(@intCast(rec.addr / cfg.sector_size));
                return error.Corrupted;
            }
            return @intCast(copied);
        }

        // ---- cache --------------------------------------------------------

        inline fn cacheSetOf(hash: u32) u16 {
            return @intCast(hash & (cache_sets - 1));
        }

        inline fn cacheTagOf(hash: u32) u16 {
            return @truncate(hash >> 16);
        }

        fn cacheProbe(self: *Self, hash: u32) ?u32 {
            const set_idx = cacheSetOf(hash);
            const tag = cacheTagOf(hash);
            const base: usize = @as(usize, set_idx) * cache_ways;
            inline for (0..cache_ways) |way| {
                const e = self.cache[base + way];
                if (e.addr != 0 and e.tag == tag) return @as(u32, e.addr);
            }
            return null;
        }

        inline fn cacheVictimShift(set_idx: u16) u6 {
            return @intCast(@as(u32, set_idx) * cache_way_bits);
        }

        fn cacheVictim(self: *Self, set_idx: u16) usize {
            return @intCast((self.cache_rr >> cacheVictimShift(set_idx)) & (cache_ways - 1));
        }

        fn cacheInsert(self: *Self, key: []const u8, addr: u32) void {
            if (cfg.cache_entries == 0) return;
            const hash = crc.hashName(key);
            const set_idx = cacheSetOf(hash);
            const tag = cacheTagOf(hash);
            const base: usize = @as(usize, set_idx) * cache_ways;
            // Update the existing entry for this key in place; a second entry for
            // the same key would go stale and turn every probe into a full scan.
            inline for (0..cache_ways) |way| {
                const e = &self.cache[base + way];
                if (e.addr != 0 and e.tag == tag) {
                    e.addr = @intCast(addr);
                    return;
                }
            }
            const way = self.cacheVictim(set_idx);
            self.cache[base + way] = .{ .tag = tag, .addr = @intCast(addr) };
            // Round-robin replacement keeps the four ways of a set in rotation.
            const shift = cacheVictimShift(set_idx);
            const next: u64 = @as(u64, (way + 1) & (cache_ways - 1));
            self.cache_rr = (self.cache_rr & ~(@as(u64, cache_ways - 1) << shift)) | (next << shift);
        }

        fn cacheInvalidate(self: *Self, key: []const u8) void {
            if (cfg.cache_entries == 0) return;
            const hash = crc.hashName(key);
            const set_idx = cacheSetOf(hash);
            const tag = cacheTagOf(hash);
            const base: usize = @as(usize, set_idx) * cache_ways;
            inline for (0..cache_ways) |way| {
                if (self.cache[base + way].tag == tag) self.cache[base + way].addr = 0;
            }
        }
        fn cacheClear(self: *Self) void {
            self.cache = @splat(CacheEntry{});
            self.cache_rr = 0;
        }

        fn cacheReplaceAddr(self: *Self, old_addr: u32, new_addr: u32) void {
            if (cfg.cache_entries == 0) return;
            for (&self.cache) |*e| {
                if (e.addr != 0 and @as(u32, e.addr) == old_addr) e.addr = @intCast(new_addr);
            }
        }

        fn cacheInvalidateSector(self: *Self, index: u16) void {
            if (cfg.cache_entries == 0) return;
            const base = self.dev.sectorAddr(index);
            const end = base + cfg.sector_size;
            for (&self.cache) |*e| {
                if (e.addr == 0) continue;
                const a: u32 = e.addr;
                if (a >= base and a < end) e.addr = 0;
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests (host, RAM flash).
// ---------------------------------------------------------------------------

const sim = @import("sim.zig");

const TestFlash = sim.RamFlash(.{ .write_gran_bits = 8, .block_size = 4096 });
const TestDb = Kvdb(TestFlash, .{ .sector_size = 4096, .sector_count = 4 });

fn freshFlash(mem: []u8) TestFlash {
    var f = TestFlash.init(mem);
    f.eraseAll();
    return f;
}

test "kvdb basic crud and remount" {
    var mem: [16 * 1024]u8 = undefined;
    var db: TestDb = undefined;
    try db.mount(freshFlash(&mem));

    try std.testing.expectEqual(@as(?u32, null), try db.get("missing", &[_]u8{}));

    try db.set("boot_count", &[_]u8{ 1, 0, 0, 0 });
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, 4), try db.get("boot_count", &buf));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 0, 0 }, buf[0..4]);

    try db.set("boot_count", &[_]u8{ 9, 8, 7, 6 });
    try std.testing.expectEqual(@as(?u32, 4), try db.get("boot_count", &buf));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 6 }, buf[0..4]);

    var short: [2]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, 4), try db.get("boot_count", &short));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8 }, &short);

    var db2: TestDb = undefined;
    try db2.mount(TestFlash.init(&mem));
    try std.testing.expectEqual(@as(?u32, 4), try db2.get("boot_count", &buf));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 6 }, buf[0..4]);

    try std.testing.expect(try db2.delete("boot_count"));
    try std.testing.expect(!try db2.delete("boot_count"));
    var db3: TestDb = undefined;
    try db3.mount(TestFlash.init(&mem));
    try std.testing.expectEqual(@as(?u32, null), try db3.get("boot_count", &buf));
    try db3.check();
}

test "kvdb iteration, count and default update" {
    var mem: [16 * 1024]u8 = undefined;
    var db: TestDb = undefined;
    try db.mount(freshFlash(&mem));

    try db.set("b", "2");
    try db.set("a", "1");
    try db.set("c", "3");
    try std.testing.expectEqual(@as(u32, 3), try db.count());

    var seen = [_]bool{ false, false, false };
    var it = db.iterator();
    var total: u32 = 0;
    while (try it.next()) |e| {
        total += e.value_len;
        try std.testing.expectEqual(@as(u32, 1), e.value_len);
        if (std.mem.eql(u8, e.name, "a")) seen[0] = true;
        if (std.mem.eql(u8, e.name, "b")) seen[1] = true;
        if (std.mem.eql(u8, e.name, "c")) seen[2] = true;
        var vbuf: [4]u8 = undefined;
        _ = try it.readValue(&vbuf, e);
    }
    try std.testing.expectEqual(@as(u32, 3), total);
    try std.testing.expect(seen[0] and seen[1] and seen[2]);

    const defaults = [_]TestDb.DefaultKv{
        .{ .key = "a", .value = "1" },
        .{ .key = "d", .value = "4" },
    };
    try db.autoUpdate(2, &defaults);
    try std.testing.expectEqual(@as(u32, 5), try db.count());
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, 1), try db.get("d", &buf));
    try db.autoUpdate(2, &defaults);
    try std.testing.expectEqual(@as(u32, 5), try db.count());
    try db.check();
}

test "kvdb gc under churn keeps every value" {
    var mem: [16 * 1024]u8 = undefined;
    var db: TestDb = undefined;
    try db.mount(freshFlash(&mem));

    var value: [96]u8 = undefined;
    for (0..400) |i| {
        for (&value, 0..) |*b, j| b.* = @truncate(i *% 31 +% j *% 7);
        try db.set("churn", &value);
        if (i % 37 == 0) {
            var buf: [128]u8 = undefined;
            const n = (try db.get("churn", &buf)).?;
            try std.testing.expectEqual(@as(u32, value.len), n);
            try std.testing.expectEqualSlices(u8, &value, buf[0..n]);
        }
    }
    for (0..16) |i| {
        var kbuf: [8]u8 = undefined;
        const k = std.fmt.bufPrint(&kbuf, "k{d}", .{i}) catch unreachable;
        try db.set(k, &value);
    }
    try db.check();
    var db2: TestDb = undefined;
    try db2.mount(TestFlash.init(&mem));
    try db2.check();
    try std.testing.expectEqual(@as(u32, 17), try db2.count());
    var buf: [128]u8 = undefined;
    _ = (try db2.get("churn", &buf)).?;
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db2.dev.flash.stats.violations);
}

test "kvdb power-cut at every flash op during set" {
    var baseline: [16 * 1024]u8 = undefined;
    {
        var db: TestDb = undefined;
        try db.mount(freshFlash(&baseline));
        try db.set("k", "old-value");
        try db.set("other", "keep-me");
        try db.check();
    }

    var probe_mem: [16 * 1024]u8 = undefined;
    @memcpy(&probe_mem, &baseline);
    var probe: TestDb = undefined;
    try probe.mount(TestFlash.init(&probe_mem));
    probe.dev.flash.mutations = 0;
    try probe.set("k", "new-value");
    const op_count = probe.dev.flash.mutations;
    try std.testing.expect(op_count > 0 and op_count < 64);

    var cut: u64 = 0;
    while (cut <= op_count) : (cut += 1) {
        var mem: [16 * 1024]u8 = undefined;
        @memcpy(&mem, &baseline);
        var db: TestDb = undefined;
        try db.mount(TestFlash.init(&mem));
        db.dev.flash.mutations = 0;
        db.dev.flash.armFault(cut);
        _ = db.set("k", "new-value") catch {};
        db.dev.flash.clearFault();

        var db2: TestDb = undefined;
        try db2.mount(TestFlash.init(&mem));
        db2.check() catch |err| {
            std.debug.print("cut={d} check failed: {s}\n", .{ cut, @errorName(err) });
            return err;
        };
        var buf: [16]u8 = undefined;
        const n = (try db2.get("k", &buf)).?;
        const got = buf[0..n];
        const ok = std.mem.eql(u8, got, "old-value") or std.mem.eql(u8, got, "new-value");
        if (!ok) std.debug.print("cut={d} got '{s}'\n", .{ cut, got });
        try std.testing.expect(ok);
        const n2 = (try db2.get("other", &buf)).?;
        try std.testing.expectEqualSlices(u8, "keep-me", buf[0..n2]);
    }
}

test "kvdb power-cut at every flash op during delete" {
    var baseline: [16 * 1024]u8 = undefined;
    {
        var db: TestDb = undefined;
        try db.mount(freshFlash(&baseline));
        try db.set("k", "value");
        try db.set("other", "keep-me");
    }
    var probe_mem: [16 * 1024]u8 = undefined;
    @memcpy(&probe_mem, &baseline);
    var probe: TestDb = undefined;
    try probe.mount(TestFlash.init(&probe_mem));
    probe.dev.flash.mutations = 0;
    _ = try probe.delete("k");
    const op_count = probe.dev.flash.mutations;

    var cut: u64 = 0;
    while (cut <= op_count) : (cut += 1) {
        var mem: [16 * 1024]u8 = undefined;
        @memcpy(&mem, &baseline);
        var db: TestDb = undefined;
        try db.mount(TestFlash.init(&mem));
        db.dev.flash.mutations = 0;
        db.dev.flash.armFault(cut);
        _ = db.delete("k") catch {};
        db.dev.flash.clearFault();
        var db2: TestDb = undefined;
        try db2.mount(TestFlash.init(&mem));
        try db2.check();
        var buf: [16]u8 = undefined;
        const got = try db2.get("k", &buf);
        try std.testing.expect(got == null or got.? == "value".len);
        const n2 = (try db2.get("other", &buf)).?;
        try std.testing.expectEqualSlices(u8, "keep-me", buf[0..n2]);
    }
}

test "kvdb 32-bit write granularity" {
    const F = sim.RamFlash(.{ .write_gran_bits = 32, .block_size = 4096 });
    const Db = Kvdb(F, .{ .sector_size = 4096, .sector_count = 4, .max_name_len = 32 });
    var mem: [16 * 1024]u8 = undefined;
    var fl = F.init(&mem);
    fl.eraseAll();
    var db: Db = undefined;
    try db.mount(fl);

    var value: [40]u8 = undefined;
    for (&value, 0..) |*b, i| b.* = @truncate(i);
    for (0..120) |i| {
        value[0] = @truncate(i);
        try db.set("counter", &value);
    }
    try db.check();
    var buf: [64]u8 = undefined;
    const n = (try db.get("counter", &buf)).?;
    try std.testing.expectEqual(@as(u32, 40), n);
    try std.testing.expectEqualSlices(u8, &value, buf[0..n]);
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.set_bit_attempts);
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.violations);
}

test "kvdb format all and not formattable" {
    var mem: [16 * 1024]u8 = undefined;
    var db: TestDb = undefined;
    try db.mount(freshFlash(&mem));
    try db.set("a", "1");
    try db.formatAll();
    try std.testing.expectEqual(@as(u32, 0), try db.count());

    const Strict = Kvdb(TestFlash, .{ .sector_size = 4096, .sector_count = 4, .not_formattable = true });
    var blank: [16 * 1024]u8 = undefined;
    var strict: Strict = undefined;
    try std.testing.expectError(error.NotFormatted, strict.mount(freshFlash(&blank)));
}

test "kvdb max value length is exact for every key length" {
    var mem: [16 * 1024]u8 = undefined;
    var db: TestDb = undefined;
    try db.mount(freshFlash(&mem));

    var value: [4200]u8 = @splat(0x5A);
    var key_buf: [64]u8 = @splat('k');
    var got: [4200]u8 = undefined;

    inline for ([_]usize{ 1, 6, 32, 64 }) |klen| {
        try db.formatAll();
        const limit = TestDb.maxValueLenFor(klen);
        db.dev.flash.resetStats();
        try db.set(key_buf[0..klen], value[0..limit]);
        try std.testing.expectEqual(@as(?u32, @intCast(limit)), try db.get(key_buf[0..klen], &got));
        try std.testing.expectEqualSlices(u8, value[0..limit], got[0..limit]);

        // One byte over the per-key limit is rejected before any flash write.
        db.dev.flash.resetStats();
        try std.testing.expectError(error.SavedFull, db.set(key_buf[0..klen], value[0..limit + 1]));
        try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.erases);
        try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.writes);
    }

    // The conservative public bound is safe for any key length and rejects
    // oversized values without touching the flash.
    db.dev.flash.resetStats();
    try std.testing.expectError(error.SavedFull, db.set(key_buf[0..], value[0 .. TestDb.max_value_len + 1]));
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.writes);
    try std.testing.expectEqual(@as(u64, 0), db.dev.flash.stats.erases);
}
test "kvdb readers and GC resync over a corrupted record header" {
    var mem: [16 * 1024]u8 = undefined;
    var db: TestDb = undefined;
    try db.mount(freshFlash(&mem));
    try db.set("aa", "1111");
    try db.set("bb", "2222");
    try db.set("cc", "3333");

    // Clear the middle record's name_len byte (3 status granules precede it at
    // 1-byte granularity), which makes its header unparsable.
    var addrs: [3]u32 = undefined;
    var n: usize = 0;
    var it = db.iterator();
    while (try it.next()) |e| : (n += 1) addrs[n] = e.addr;
    try std.testing.expectEqual(@as(usize, 3), n);
    try db.dev.writeAligned(addrs[1] + 3, &[_]u8{0});

    // Remount: the scan resyncs past the damaged header.
    var db2: TestDb = undefined;
    try db2.mount(TestFlash.init(&mem));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?u32, 4), try db2.get("aa", &buf));
    try std.testing.expectEqual(@as(?u32, null), try db2.get("bb", &buf));
    try std.testing.expectEqual(@as(?u32, 4), try db2.get("cc", &buf));
    try std.testing.expectEqual(@as(u32, 2), try db2.count());
    try db2.check();

    // GC must resync as well: the churn forces this sector to be collected and
    // the records behind the damaged header have to survive the move.
    var value: [48]u8 = undefined;
    for (0..400) |i| {
        for (&value, 0..) |*b, j| b.* = @truncate(i *% 17 +% j);
        try db2.set("churn", &value);
    }
    try db2.check();
    var db3: TestDb = undefined;
    try db3.mount(TestFlash.init(&mem));
    try std.testing.expectEqual(@as(?u32, 4), try db3.get("aa", &buf));
    try std.testing.expectEqual(@as(?u32, 4), try db3.get("cc", &buf));
    try std.testing.expectEqual(@as(u64, 0), db3.dev.flash.stats.set_bit_attempts);
}