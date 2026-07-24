const std = @import("std");

const HttpBackend = enum { std, curl };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const http_backend = b.option(
        HttpBackend,
        "http_backend",
        "Outbound HTTP backend (std.http or zig-curl) for zag-ai + openai-zig",
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

    const ai_dep = b.dependency("zag_ai", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
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
        .http_backend = http_backend,
    });
    const coding_mod = coding_dep.module("zag-coding-agent");

    const cli_dep = b.dependency("zag_cli", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
    });
    const cli_mod = cli_dep.module("zag-cli");

    const http_opts = b.addOptions();
    http_opts.addOption(HttpBackend, "http_backend", http_backend);
    http_opts.addOption([]const u8, "package", "zag_root");

    const openai_opts = b.addOptions();
    openai_opts.addOption(HttpBackend, "http_backend", http_backend);
    openai_opts.addOption([]const u8, "package", "openai_zig");

    const openai_named = b.addModule("openai_zig", .{
        .root_source_file = b.path("packages/openai-zig/src/root.zig"),
        .target = target,
    });
    openai_named.addOptions("openai_build_options", openai_opts);
    var root_curl_dep: ?*std.Build.Dependency = null;
    if (http_backend == .curl) {
        root_curl_dep = b.lazyDependency("curl", .{
            .target = target,
            .optimize = optimize,
            .link_vendor = false,
        }) orelse return;
        attachCurl(openai_named, root_curl_dep.?);
    }
    _ = b.addModule("zag-types", .{
        .root_source_file = b.path("packages/zag-types/src/root.zig"),
        .target = target,
    });
    const zag_ai_named = b.addModule("zag-ai", .{
        .root_source_file = b.path("packages/zag-ai/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "openai_zig", .module = openai_mod },
            .{ .name = "zag-types", .module = types_mod },
            .{ .name = "comptime_serde", .module = serde_mod },
        },
    });
    zag_ai_named.addOptions("build_options", http_opts);
    if (root_curl_dep) |dep| {
        attachCurl(zag_ai_named, dep);
    }
    _ = b.addModule("zag-agent-core", .{
        .root_source_file = b.path("packages/zag-agent-core/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-types", .module = types_mod },
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
    _ = b.addModule("zag-cli", .{
        .root_source_file = b.path("packages/zag-cli/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-coding-agent", .module = coding_mod },
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });

    const mod = b.addModule("zag", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-types", .module = types_mod },
            .{ .name = "zag-ai", .module = ai_mod },
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-coding-agent", .module = coding_mod },
            .{ .name = "zag-cli", .module = cli_mod },
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
                .{ .name = "zag-cli", .module = cli_mod },
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
    openai_tests.root_module.addOptions("openai_build_options", openai_opts);
    if (root_curl_dep) |dep| {
        attachCurl(openai_tests.root_module, dep);
    }
    const run_openai_tests = b.addRunArtifact(openai_tests);

    const ai_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-ai/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "openai_zig", .module = openai_mod },
                .{ .name = "zag-types", .module = types_mod },
                .{ .name = "comptime_serde", .module = serde_mod },
            },
        }),
    });
    ai_tests.root_module.addOptions("build_options", http_opts);
    if (root_curl_dep) |dep| {
        attachCurl(ai_tests.root_module, dep);
    }
    const run_ai_tests = b.addRunArtifact(ai_tests);

    const types_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-types/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_types_tests = b.addRunArtifact(types_tests);

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-agent-core/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-types", .module = types_mod },
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

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-coding-agent", .module = coding_mod },
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

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

    const catalog_check = b.addSystemCommand(&.{
        "python3",
        "packages/zag-ai/scripts/generate_catalog.py",
        "--check",
    });
    const catalog_check_step = b.step(
        "catalog-check",
        "Verify catalog_data.zig matches data/models/*.json",
    );
    catalog_check_step.dependOn(&catalog_check.step);

    const docs_score = b.addSystemCommand(&.{
        "python3",
        "scripts/score_docs.py",
        "--check",
    });
    const docs_lint = b.addSystemCommand(&.{
        "python3",
        "scripts/lint_docs.py",
    });
    docs_lint.step.dependOn(&docs_score.step);
    const docs_lint_step = b.step(
        "docs-lint",
        "Score docs (readability/security) then lint XPlan layout",
    );
    docs_lint_step.dependOn(&docs_lint.step);

    // D-005 Phase 3: live std vs curl bake-off (network; not in `test`).
    const bakeoff_exe = b.addExecutable(.{
        .name = "http-bakeoff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-ai/src/bin/http_bakeoff.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    if (root_curl_dep) |dep| {
        attachCurl(bakeoff_exe.root_module, dep);
    }
    const run_bakeoff = b.addRunArtifact(bakeoff_exe);
    if (b.args) |args| {
        run_bakeoff.addArgs(args);
    }
    const bakeoff_step = b.step(
        "http-bakeoff",
        "Live HTTP backend bake-off (needs network; -Dhttp_backend=std|curl)",
    );
    bakeoff_step.dependOn(&run_bakeoff.step);

    // h-doctor-001: process-level `--doctor` fixture (real zag binary, empty env).
    // Proves no provider/API-key work, no session/trace file creation; invalid
    // session paths fail closed without path leak. Runs under both std and curl
    // backends because the product exe is rebuilt with the selected backend.
    const doctor_fixture_opts = b.addOptions();
    doctor_fixture_opts.addOptionPath("zag_bin", exe.getEmittedBin());
    const doctor_process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/doctor_process_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "doctor_fixture_options", .module = doctor_fixture_opts.createModule() },
            },
        }),
    });
    const run_doctor_process_tests = b.addRunArtifact(doctor_process_tests);
    const doctor_fixture_step = b.step(
        "doctor-process-fixture",
        "Process-level zag --doctor no-key / session-validation fixture",
    );
    doctor_fixture_step.dependOn(&run_doctor_process_tests.step);

    const test_step = b.step("test", "Run all tests + openai coverage + catalog + docs lint");
    test_step.dependOn(&run_openai_tests.step);
    test_step.dependOn(&run_types_tests.step);
    test_step.dependOn(&run_ai_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_coding_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_doctor_process_tests.step);
    test_step.dependOn(openai_coverage_step);
    test_step.dependOn(catalog_check_step);
    test_step.dependOn(docs_lint_step);
}

fn attachCurl(mod: *std.Build.Module, curl_dep: *std.Build.Dependency) void {
    mod.addImport("curl", curl_dep.module("curl"));
    mod.link_libc = true;
    mod.linkSystemLibrary("curl", .{});
}
