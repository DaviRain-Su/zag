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
    const live = b.option(
        bool,
        "live",
        "Enable the live policy layer (lazy zag-live dep; default false; package acceptance tests run with -Dlive)",
    ) orelse false;

    const core_dep = b.dependency("zag_agent_core", .{
        .target = target,
        .optimize = optimize,
    });
    const core_mod = core_dep.module("zag-agent-core");

    const types_dep = b.dependency("zag_types", .{
        .target = target,
        .optimize = optimize,
    });
    const types_mod = types_dep.module("zag-types");

    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
    });
    const ai_mod = ai_dep.module("zag-ai");

    var live_mod: ?*std.Build.Module = null;
    if (live) {
        const live_dep = b.lazyDependency("zag_live", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        live_mod = live_dep.module("zag-live");
    }
    const coding_opts = b.addOptions();
    coding_opts.addOption(bool, "live_enabled", live);

    const mod = b.addModule("zag-coding-agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-types", .module = types_mod },
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });
    mod.addOptions("build_options", coding_opts);
    if (live_mod) |lm| mod.addImport("zag-live", lm);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-types", .module = types_mod },
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    tests.root_module.addOptions("build_options", coding_opts);
    if (live_mod) |lm| tests.root_module.addImport("zag-live", lm);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zag-coding-agent tests");
    test_step.dependOn(&run_tests.step);

    _ = &mod;
}
