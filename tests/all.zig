//! Integration tests: everything imported here runs under `zig build test`.

const std = @import("std");
const flashdb = @import("flashdb");

test {
    _ = flashdb;
    _ = @import("kvdb_integration.zig");
    _ = @import("kv_model.zig");
}
