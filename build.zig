const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- monorepo package: zag-ai ---
    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
    });
    const ai_mod = ai_dep.module("zag-ai");

    // Also expose a direct path module for in-tree imports if needed
    _ = b.addModule("zag-ai", .{
        .root_source_file = b.path("packages/zag-ai/src/root.zig"),
        .target = target,
    });

    const mod = b.addModule("zag", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zag",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag", .module = mod },
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests: zag-ai package + zag module + exe
    const ai_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-ai/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ai_tests = b.addRunArtifact(ai_tests);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_ai_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
