const std = @import("std");

pub const HttpBackend = enum { std, curl };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const http_backend = b.option(
        HttpBackend,
        "http_backend",
        "Outbound HTTP for zag-ai (std.http or zig-curl)",
    ) orelse .std;

    const openai_dep = b.dependency("openai_zig", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
    });
    const openai_mod = openai_dep.module("openai_zig");

    const types_dep = b.dependency("zag_types", .{
        .target = target,
        .optimize = optimize,
    });
    const types_mod = types_dep.module("zag-types");

    const serde_dep = b.dependency("comptime_serde", .{
        .target = target,
        .optimize = optimize,
    });
    const serde_mod = serde_dep.module("comptime_serde");

    const opts = b.addOptions();
    opts.addOption(HttpBackend, "http_backend", http_backend);
    opts.addOption([]const u8, "package", "zag_ai");

    var curl_dep: ?*std.Build.Dependency = null;
    if (http_backend == .curl) {
        curl_dep = b.lazyDependency("curl", .{
            .target = target,
            .optimize = optimize,
            .link_vendor = false,
        }) orelse return;
    }

    const mod = b.addModule("zag-ai", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "openai_zig", .module = openai_mod },
            .{ .name = "zag-types", .module = types_mod },
            .{ .name = "comptime_serde", .module = serde_mod },
        },
    });
    mod.addOptions("build_options", opts);
    if (curl_dep) |dep| {
        attachCurl(mod, dep);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openai_zig", .module = openai_mod },
                .{ .name = "zag-types", .module = types_mod },
                .{ .name = "comptime_serde", .module = serde_mod },
            },
        }),
    });
    tests.root_module.addOptions("build_options", opts);
    if (curl_dep) |dep| {
        attachCurl(tests.root_module, dep);
    }
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zag-ai unit tests");
    test_step.dependOn(&run_tests.step);

    // Keep module registered for dependents (`b.dependency("zag_ai").module("zag-ai")`).
    _ = .{mod};
}

fn attachCurl(mod: *std.Build.Module, curl_dep: *std.Build.Dependency) void {
    mod.addImport("curl", curl_dep.module("curl"));
    mod.link_libc = true;
    mod.linkSystemLibrary("curl", .{});
}
