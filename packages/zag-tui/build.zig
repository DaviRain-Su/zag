const std = @import("std");

const HttpBackend = enum { std, curl };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const http_backend = b.option(
        HttpBackend,
        "http_backend",
        "Outbound HTTP for zag-coding-agent / zag-ai (std.http or zig-curl)",
    ) orelse .std;

    const coding_dep = b.dependency("zag_coding_agent", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
    });
    const coding_mod = coding_dep.module("zag-coding-agent");

    // Core public types (StopReason / cancel) via product path; explicit import
    // keeps layer law visible. No CLI / sigint dependency.
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

    // Quarantined terminal backend (tui-vaxis-001): vaxis is visible only to
    // terminal.zig / keys.zig / render.zig. zigimg/uucode resolve from the
    // local zig cache (offline).
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    // Markdown parser (tui-markdown-001): vendored koino (stock, MIT). Its
    // own deps (libpcre/htmlentities/uucode/clap) fetch into the zig cache on
    // the first build; only the parse + AST path is consumed.
    const koino_dep = b.dependency("koino", .{
        .target = target,
        .optimize = optimize,
    });
    const koino_mod = koino_dep.module("koino");

    const mod = b.addModule("zag-tui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-coding-agent", .module = coding_mod },
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-types", .module = types_mod },
            .{ .name = "vaxis", .module = vaxis_mod },
            .{ .name = "koino", .module = koino_mod },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-coding-agent", .module = coding_mod },
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-types", .module = types_mod },
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "koino", .module = koino_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zag-tui tests");
    test_step.dependOn(&run_tests.step);

    _ = mod;
}
