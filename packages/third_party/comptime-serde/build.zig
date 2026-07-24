const std = @import("std");

/// Library-only mirror of jiacai2050/comptime-serde v0.2.0 (no serde-gen / zigcli).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("comptime_serde", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run comptime-serde unit tests");
    test_step.dependOn(&run_tests.step);
}
