const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("zag_agent_core", .{
        .target = target,
        .optimize = optimize,
    });
    const core_mod = core_dep.module("zag-agent-core");

    const coding_dep = b.dependency("zag_coding_agent", .{
        .target = target,
        .optimize = optimize,
    });
    const coding_mod = coding_dep.module("zag-coding-agent");

    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
    });
    const ai_mod = ai_dep.module("zag-ai");

    const mod = b.addModule("zag-cli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-coding-agent", .module = coding_mod },
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-coding-agent", .module = coding_mod },
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zag-cli tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
