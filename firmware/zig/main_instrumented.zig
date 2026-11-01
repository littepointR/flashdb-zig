//! Zig firmware measurement image -- instrumented variant (mirrors
//! `fw_c_instrumented.elf`: `-DFW_CYCLES=1 -DHARNESS_STACK_PHASES=1`).
//!
//! Same workload as `main.zig`, plus the C harness's cycle counters and the
//! per-phase stack repaints / cycle deltas.
const std = @import("std");
const fw = @import("fw.zig");

pub const panic = std.debug.no_panic;

export fn main() callconv(.c) noreturn {
    fw.run(.{ .cycles = true, .phases = true });
}
