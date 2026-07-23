const std = @import("std");

fn shouldRunExample(filter_csv: []const u8, example_name: []const u8) bool {
    if (filter_csv.len == 0) return true;
    var it = std.mem.splitScalar(u8, filter_csv, ',');
    while (it.next()) |raw| {
        const token = std.mem.trim(u8, raw, " \t\r\n");
        if (token.len == 0) continue;
        if (std.mem.eql(u8, token, example_name)) return true;
    }
    return false;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("openai_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "openai_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openai_zig", .module = mod },
                .{ .name = "config", .module = config_mod },
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

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const build_examples = b.option(bool, "examples", "Build examples") orelse false;
    if (build_examples) {
        const examples_filter_csv = b.option([]const u8, "examples_filter", "Comma-separated example names") orelse "";
        const examples = [_]struct { name: []const u8, path: []const u8 }{
            .{ .name = "models_list", .path = "examples/models_list.zig" },
            .{ .name = "chat_completion", .path = "examples/chat_completion.zig" },
            .{ .name = "chat_completion_stream", .path = "examples/chat_completion_stream.zig" },
            .{ .name = "chat_tool_calls", .path = "examples/chat_tool_calls.zig" },
            .{ .name = "provider_compat", .path = "examples/provider_compat.zig" },
        };

        const examples_step = b.step("examples", "Build selected examples");
        for (examples) |ex| {
            if (!shouldRunExample(examples_filter_csv, ex.name)) continue;
            const example_exe = b.addExecutable(.{
                .name = ex.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(ex.path),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "openai_zig", .module = mod },
                        .{ .name = "config", .module = config_mod },
                    },
                }),
            });
            examples_step.dependOn(&b.addInstallArtifact(example_exe, .{}).step);
        }
    }
}
