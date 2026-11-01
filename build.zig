const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("flashdb", .{
        .root_source_file = b.path("src/flashdb.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- unit tests -------------------------------------------------------
    const test_step = b.step("test", "Run unit and integration tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flashdb.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit.step);

    const integ_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flashdb", .module = mod }},
        }),
    });
    const run_integ = b.addRunArtifact(integ_tests);
    test_step.dependOn(&run_integ.step);

    // ---- examples ---------------------------------------------------------
    const example_step = b.step("examples", "Build the examples");
    const example_names = [_][]const u8{ "kv_basic", "ts_basic" };
    inline for (example_names) |name| {
        const ex = b.addExecutable(.{
            .name = "example-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "flashdb", .module = mod }},
            }),
        });
        example_step.dependOn(&ex.step);
        b.installArtifact(ex);
    }

    // ---- benchmark binary -------------------------------------------------
    // A benchmark must never be built unoptimized: pin both the driver *and*
    // the library module to ReleaseFast. Otherwise `zig build bench` (default
    // Debug) would measure a Debug library inside a release driver.
    const bench_step = b.step("bench", "Run the host benchmark");
    const bench_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/flashdb.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/zig/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "flashdb", .module = bench_lib_mod }},
    });
    const bench_exe = b.addExecutable(.{ .name = "flashdb-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);
    b.installArtifact(bench_exe);
}
