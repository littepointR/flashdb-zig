//! Allocation-free output sink used by the `dump` debug helpers.
//!
//! The library has no `std`/`fmt` dependency: a caller supplies a `write`
//! callback (UART, RTT, ring buffer, file, ...) and the database formats its
//! listing through it. The helpers cover exactly what the dumps need: decimal
//! numbers, quoted text and hex bytes.

/// Destination for formatted bytes.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    writeFn: *const fn (ctx: ?*anyopaque, bytes: []const u8) void,

    pub fn write(self: Sink, bytes: []const u8) void {
        self.writeFn(self.ctx, bytes);
    }

    pub fn writeByte(self: Sink, byte: u8) void {
        const one = [1]u8{byte};
        self.writeFn(self.ctx, &one);
    }

    /// Unsigned decimal, no padding.
    pub fn writeDec(self: Sink, value: u64) void {
        if (value == 0) {
            self.writeByte('0');
            return;
        }
        var buf: [20]u8 = undefined;
        var i: usize = buf.len;
        var v = value;
        while (v != 0) {
            i -= 1;
            buf[i] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
        }
        self.write(buf[i..]);
    }

    /// Signed decimal (timestamps are signed).
    pub fn writeSigned(self: Sink, value: i64) void {
        if (value < 0) {
            self.writeByte('-');
            // Avoid overflowing on i64 min.
            const mag: u64 = if (value == -9223372036854775808)
                9223372036854775808
            else
                @intCast(-value);
            self.writeDec(mag);
        } else {
            self.writeDec(@intCast(value));
        }
    }

    /// Two lowercase hex digits with no prefix.
    pub fn writeHexByte(self: Sink, byte: u8) void {
        const digits = "0123456789abcdef";
        const pair = [2]u8{ digits[byte >> 4], digits[byte & 0x0F] };
        self.write(&pair);
    }

    /// Lowercase hex, no prefix.
    pub fn writeHexBytes(self: Sink, bytes: []const u8) void {
        for (bytes) |b| self.writeHexByte(b);
    }

    /// `"text"` with no escaping (the dump helpers only call this for printable
    /// ASCII values).
    pub fn writeQuoted(self: Sink, bytes: []const u8) void {
        self.writeByte('"');
        self.write(bytes);
        self.writeByte('"');
    }
};

/// True when every byte is printable ASCII (space through `~`).
pub fn isPrintable(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b < 0x20 or b > 0x7E) return false;
    }
    return true;
}

test "sink formats decimal, signed and hex" {
    const std = @import("std");
    const Capture = struct {
        buf: [128]u8 = undefined,
        len: usize = 0,

        fn write(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.buf[self.len..][0..bytes.len], bytes);
            self.len += bytes.len;
        }

        fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };

    var cap: Capture = .{};
    const s: Sink = .{ .ctx = &cap, .writeFn = Capture.write };

    s.writeDec(0);
    s.writeByte(' ');
    s.writeDec(7);
    s.writeByte(' ');
    s.writeDec(1234567890);
    s.writeByte(' ');
    s.writeSigned(-42);
    s.writeByte(' ');
    s.writeSigned(-9223372036854775808);
    s.writeByte(' ');
    s.writeHexByte(0x0A);
    s.writeHexByte(0xFF);
    s.writeByte(' ');
    s.writeHexBytes(&[_]u8{ 0x00, 0x7F, 0xAB });
    s.writeByte(' ');
    s.writeQuoted("ok");

    try std.testing.expectEqualStrings("0 7 1234567890 -42 -9223372036854775808 0aff 007fab \"ok\"", cap.slice());
    try std.testing.expect(isPrintable(cap.slice()));
    try std.testing.expect(!isPrintable("a\x01b"));
    try std.testing.expect(isPrintable(""));
}
