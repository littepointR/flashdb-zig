//! Zig firmware measurement image -- cycles-only variant (mirrors a C build
//! with `-DFW_CYCLES=1` but without `-DHARNESS_STACK_PHASES=1`).
const std = @import("std");
const fw = @import("fw.zig");

pub const panic = std.debug.no_panic;

export fn main() callconv(.c) noreturn {
    fw.run(.{ .cycles = true });
}
