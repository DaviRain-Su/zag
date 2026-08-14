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
    const tui = b.option(
        bool,
        "tui",
        "Enable zag-tui product shell (default true; pass -Dtui=false for a lean graph)",
    ) orelse true;
    const live = b.option(
        bool,
        "live",
        "Enable the live policy layer (default false; forwarded to zag-coding-agent)",
    ) orelse false;

    const core_dep = b.dependency("zag_agent_core", .{
        .target = target,
        .optimize = optimize,
    });
    const core_mod = core_dep.module("zag-agent-core");

    const coding_dep = b.dependency("zag_coding_agent", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
        .live = live,
    });
    const coding_mod = coding_dep.module("zag-coding-agent");

    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
    });
    const ai_mod = ai_dep.module("zag-ai");

    const cli_opts = b.addOptions();
    cli_opts.addOption(bool, "tui_enabled", tui);
    cli_opts.addOption(bool, "live_enabled", live);

    const mod = b.addModule("zag-cli", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-coding-agent", .module = coding_mod },
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });
    mod.addOptions("build_options", cli_opts);

    if (tui) {
        const tui_dep = b.lazyDependency("zag_tui", .{
            .target = target,
            .optimize = optimize,
            .http_backend = http_backend,
            .live = live,
        }) orelse return;
        mod.addImport("zag-tui", tui_dep.module("zag-tui"));
    }

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zag-cli tests");
    test_step.dependOn(&run_tests.step);
}
