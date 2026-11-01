//! Zig firmware measurement image -- phases-only variant (mirrors a C build
//! with `-DHARNESS_STACK_PHASES=1` but without `-DFW_CYCLES=1`).
const std = @import("std");
const fw = @import("fw.zig");

pub const panic = std.debug.no_panic;

export fn main() callconv(.c) noreturn {
    fw.run(.{ .phases = true });
}
