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

    const provider_compat_mod = b.createModule(.{
        .root_source_file = b.path("examples/provider_compat.zig"),
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

    // Build examples with: zig build -Dexamples=true
    // Optional filter: -Dexamples_filter=chat_completion,models_list
    const build_examples = b.option(bool, "examples", "Build examples") orelse false;
    if (build_examples) {
        const examples_filter_csv = b.option([]const u8, "examples_filter", "Comma-separated example names") orelse "";
        const examples = [_]struct { name: []const u8, path: []const u8, needs_compat: bool }{
            .{ .name = "models_list", .path = "examples/models_list.zig", .needs_compat = false },
            .{ .name = "chat_completion", .path = "examples/chat_completion.zig", .needs_compat = false },
            .{ .name = "chat_completion_raw", .path = "examples/chat_completion_raw.zig", .needs_compat = false },
            .{ .name = "chat_completion_stream", .path = "examples/chat_completion_stream.zig", .needs_compat = true },
            .{ .name = "chat_multiturn", .path = "examples/chat_multiturn.zig", .needs_compat = false },
            .{ .name = "chat_prefix_completion", .path = "examples/chat_prefix_completion.zig", .needs_compat = false },
            .{ .name = "chat_thinking_mode", .path = "examples/chat_thinking_mode.zig", .needs_compat = true },
            .{ .name = "chat_tool_calls", .path = "examples/chat_tool_calls.zig", .needs_compat = false },
            .{ .name = "chat_json_extract", .path = "examples/chat_json_extract.zig", .needs_compat = false },
            .{ .name = "chat_json_mode", .path = "examples/chat_json_mode.zig", .needs_compat = true },
            .{ .name = "chat_list", .path = "examples/chat_list.zig", .needs_compat = true },
            .{ .name = "chat_debug", .path = "examples/chat_debug.zig", .needs_compat = false },
            .{ .name = "completions_basic", .path = "examples/completions_basic.zig", .needs_compat = false },
            .{ .name = "completions_stream", .path = "examples/completions_stream.zig", .needs_compat = true },
            .{ .name = "fim_completion", .path = "examples/fim_completion.zig", .needs_compat = false },
            .{ .name = "fim_completion_raw", .path = "examples/fim_completion_raw.zig", .needs_compat = false },
            .{ .name = "fim_completion_stream", .path = "examples/fim_completion_stream.zig", .needs_compat = true },
            .{ .name = "embeddings_and_moderations", .path = "examples/embeddings_and_moderations.zig", .needs_compat = true },
            .{ .name = "images_generation", .path = "examples/images_generation.zig", .needs_compat = true },
            .{ .name = "audio_speech", .path = "examples/audio_speech.zig", .needs_compat = true },
            .{ .name = "audio_transcription", .path = "examples/audio_transcription.zig", .needs_compat = true },
            .{ .name = "audio_translation", .path = "examples/audio_translation.zig", .needs_compat = true },
            .{ .name = "files_list", .path = "examples/files_list.zig", .needs_compat = true },
            .{ .name = "files_list_paged", .path = "examples/files_list_paged.zig", .needs_compat = true },
            .{ .name = "files_list_auto_paged", .path = "examples/files_list_auto_paged.zig", .needs_compat = true },
            .{ .name = "batch_basic", .path = "examples/batch_basic.zig", .needs_compat = true },
            .{ .name = "assistants_list", .path = "examples/assistants_list.zig", .needs_compat = true },
            .{ .name = "vector_stores_list", .path = "examples/vector_stores_list.zig", .needs_compat = true },
            .{ .name = "responses_basic", .path = "examples/responses_basic.zig", .needs_compat = true },
            .{ .name = "user_balance", .path = "examples/user_balance.zig", .needs_compat = true },
            .{ .name = "error_handling_and_options", .path = "examples/error_handling_and_options.zig", .needs_compat = false },
            .{ .name = "skills_list", .path = "examples/skills_list.zig", .needs_compat = true },
        };

        const examples_step = b.step("examples", "Build selected examples");
        for (examples) |ex| {
            if (!shouldRunExample(examples_filter_csv, ex.name)) continue;

            var imports_buf: [3]std.Build.Module.Import = undefined;
            var imports_len: usize = 0;
            imports_buf[imports_len] = .{ .name = "openai_zig", .module = mod };
            imports_len += 1;
            imports_buf[imports_len] = .{ .name = "config", .module = config_mod };
            imports_len += 1;
            if (ex.needs_compat) {
                imports_buf[imports_len] = .{ .name = "provider_compat", .module = provider_compat_mod };
                imports_len += 1;
            }

            const example_exe = b.addExecutable(.{
                .name = ex.name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(ex.path),
                    .target = target,
                    .optimize = optimize,
                    .imports = imports_buf[0..imports_len],
                }),
            });
            examples_step.dependOn(&b.addInstallArtifact(example_exe, .{}).step);

            const run_ex = b.step(
                b.fmt("run-{s}", .{ex.name}),
                b.fmt("Run example {s}", .{ex.name}),
            );
            const run_ex_cmd = b.addRunArtifact(example_exe);
            run_ex.dependOn(&run_ex_cmd.step);
        }
    }
}
