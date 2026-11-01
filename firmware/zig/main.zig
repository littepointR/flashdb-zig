//! Zig firmware measurement image -- plain variant (mirrors `fw_c_plain.elf`).
//!
//! Root file of the `thumb-freestanding-eabi` build: the shared Reset_Handler
//! in `firmware/common/startup_armv7m.S` calls `main` (C ABI), which runs the
//! workload in `fw.zig` with no cycle/phase instrumentation.
const std = @import("std");
const fw = @import("fw.zig");

/// Freestanding panic handler: a panic is a harness failure, so trap (the
/// startup code's Default_Handler stays put and the host timeout fires).
pub const panic = std.debug.no_panic;

export fn main() callconv(.c) noreturn {
    fw.run(.{});
}
