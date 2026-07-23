const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const openai_dep = b.dependency("openai_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const openai_mod = openai_dep.module("openai_zig");

    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
    });
    const ai_mod = ai_dep.module("zag-ai");

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

    _ = b.addModule("openai_zig", .{
        .root_source_file = b.path("packages/openai-zig/src/root.zig"),
        .target = target,
    });
    _ = b.addModule("zag-ai", .{
        .root_source_file = b.path("packages/zag-ai/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "openai_zig", .module = openai_mod },
        },
    });
    _ = b.addModule("zag-agent-core", .{
        .root_source_file = b.path("packages/zag-agent-core/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });
    _ = b.addModule("zag-coding-agent", .{
        .root_source_file = b.path("packages/zag-coding-agent/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });

    const mod = b.addModule("zag", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-ai", .module = ai_mod },
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-coding-agent", .module = coding_mod },
            .{ .name = "openai_zig", .module = openai_mod },
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
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-coding-agent", .module = coding_mod },
                .{ .name = "openai_zig", .module = openai_mod },
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

    const openai_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/openai-zig/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_openai_tests = b.addRunArtifact(openai_tests);

    const ai_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-ai/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openai_zig", .module = openai_mod },
            },
        }),
    });
    const run_ai_tests = b.addRunArtifact(ai_tests);

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-agent-core/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const coding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-coding-agent/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    const run_coding_tests = b.addRunArtifact(coding_tests);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const openai_coverage = b.addSystemCommand(&.{
        "python3",
        "scripts/check-path-coverage.py",
    });
    openai_coverage.setCwd(b.path("packages/openai-zig"));
    const openai_coverage_step = b.step(
        "openai-coverage",
        "Check openai-zig OpenAPI path coverage vs resources",
    );
    openai_coverage_step.dependOn(&openai_coverage.step);

    const test_step = b.step("test", "Run all tests + openai path coverage");
    test_step.dependOn(&run_openai_tests.step);
    test_step.dependOn(&run_ai_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_coding_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(openai_coverage_step);
}
