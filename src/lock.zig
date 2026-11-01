//! Optional thread/ISR lock hooks shared by the databases.
//!
//! Both callbacks run around every public database operation. When `Config.lock`
//! is null (the default) the hooks compile out completely, so single-threaded
//! users pay neither code space nor cycles.

/// A pair of callbacks plus an opaque context pointer.
///
/// `acquire`/`release` must not be re-entrant: the database never nests public
/// operations (internal helpers are called without taking the lock again).
pub const Lock = struct {
    acquire: *const fn (ctx: ?*anyopaque) void,
    release: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
};
