const std = @import("std");

const HttpBackend = enum { std, curl };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const http_backend = b.option(
        HttpBackend,
        "http_backend",
        "Outbound HTTP for zag-ai (std.http or zig-curl)",
    ) orelse .std;

    const core_dep = b.dependency("zag_agent_core", .{
        .target = target,
        .optimize = optimize,
    });
    const core_mod = core_dep.module("zag-agent-core");

    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
    });
    const ai_mod = ai_dep.module("zag-ai");

    const mod = b.addModule("zag-coding-agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-agent-core", .module = core_mod },
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
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zag-coding-agent tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
