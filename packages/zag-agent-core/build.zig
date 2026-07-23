const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
    });
    const ai_mod = ai_dep.module("zag-ai");

    const mod = b.addModule("zag-agent-core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zag-agent-core tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
