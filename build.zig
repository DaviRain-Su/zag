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

    const tui = b.option(
        bool,
        "tui",
        "Enable TUI product shell (default false; lazy zag-tui)",
    ) orelse false;

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

    // Lazy: only resolve/build zag-tui when -Dtui=true.
    var tui_mod: ?*std.Build.Module = null;
    var vaxis_mod: ?*std.Build.Module = null;
    var koino_mod: ?*std.Build.Module = null;
    if (tui) {
        const tui_dep = b.lazyDependency("zag_tui", .{
            .target = target,
            .optimize = optimize,
            .http_backend = http_backend,
        }) orelse return;
        tui_mod = tui_dep.module("zag-tui");
        // Quarantined backend dep (tui-vaxis-001): vaxis resolves lazily with
        // the zag-tui graph (zigimg/uucode from the local zig cache).
        const vaxis_dep = b.lazyDependency("vaxis", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        vaxis_mod = vaxis_dep.module("vaxis");
        // Markdown parser dep (tui-markdown-001): koino resolves lazily with
        // the zag-tui graph; its own deps (libpcre/htmlentities/uucode/clap)
        // fetch into the zig cache on the first -Dtui=true build.
        const koino_dep = b.lazyDependency("koino", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        koino_mod = koino_dep.module("koino");
    }

    const cli_dep = b.dependency("zag_cli", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
        .tui = tui,
    });
    const cli_mod = cli_dep.module("zag-cli");

    const fixture_dep = b.dependency("sdk_consumer_fixture", .{
        .target = target,
        .optimize = optimize,
        .http_backend = http_backend,
    });
    const fixture_mod = fixture_dep.module("sdk-consumer-fixture");

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
            .{ .name = "zag-types", .module = types_mod },
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });
    const cli_named = b.addModule("zag-cli", .{
        .root_source_file = b.path("packages/zag-cli/src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zag-agent-core", .module = core_mod },
            .{ .name = "zag-coding-agent", .module = coding_mod },
            .{ .name = "zag-ai", .module = ai_mod },
        },
    });
    // Named module uses same build_options as package dependency graph.
    {
        const named_opts = b.addOptions();
        named_opts.addOption(bool, "tui_enabled", tui);
        cli_named.addOptions("build_options", named_opts);
        if (tui_mod) |tm| cli_named.addImport("zag-tui", tm);
    }
    if (tui_mod) |tm| {
        _ = b.addModule("zag-tui", .{
            .root_source_file = b.path("packages/zag-tui/src/root.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "zag-coding-agent", .module = coding_mod },
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-types", .module = types_mod },
                .{ .name = "vaxis", .module = vaxis_mod.? },
                .{ .name = "koino", .module = koino_mod.? },
            },
        });
        _ = tm;
    }

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
    // cli-sigint-001-style note: core tests use std.Thread.spawn + std.c.nanosleep
    // (cancel-during-backoff fixtures, retry-after-wire-001); nanosleep is an
    // extern "c" symbol so the test artifact needs libc (test artifact only).
    core_tests.root_module.link_libc = true;
    const run_core_tests = b.addRunArtifact(core_tests);

    const coding_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-coding-agent/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag-agent-core", .module = core_mod },
                .{ .name = "zag-types", .module = types_mod },
                .{ .name = "zag-ai", .module = ai_mod },
            },
        }),
    });
    const run_coding_tests = b.addRunArtifact(coding_tests);

    const fixture_tests = b.addTest(.{
        .root_module = fixture_mod,
    });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);

    const cli_test_opts = b.addOptions();
    cli_test_opts.addOption(bool, "tui_enabled", tui);
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
    cli_tests.root_module.addOptions("build_options", cli_test_opts);
    if (tui_mod) |tm| cli_tests.root_module.addImport("zag-tui", tm);
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // zag-tui package tests only when -Dtui=true (lazy package not resolved otherwise).
    var run_tui_tests: ?*std.Build.Step.Run = null;
    if (tui_mod) |tm| {
        const tui_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("packages/zag-tui/src/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zag-coding-agent", .module = coding_mod },
                    .{ .name = "zag-agent-core", .module = core_mod },
                    .{ .name = "zag-types", .module = types_mod },
                    .{ .name = "vaxis", .module = vaxis_mod.? },
                    .{ .name = "koino", .module = koino_mod.? },
                },
            }),
        });
        _ = tm;
        run_tui_tests = b.addRunArtifact(tui_tests);
    }

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

    // headless-001: process-level `--json` / `--json-stream` fixture (real zag
    // binary, empty env, isolated cwd, built-in mock provider). Runs under
    // both std and curl backends.
    const headless_mock_server_exe = b.addExecutable(.{
        .name = "headless-mock-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/headless_mock_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const headless_fixture_opts = b.addOptions();
    headless_fixture_opts.addOptionPath("zag_bin", exe.getEmittedBin());
    headless_fixture_opts.addOptionPath("mock_server_bin", headless_mock_server_exe.getEmittedBin());
    const headless_process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/headless_process_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "headless_fixture_options", .module = headless_fixture_opts.createModule() },
            },
        }),
    });
    const run_headless_process_tests = b.addRunArtifact(headless_process_tests);
    const headless_fixture_step = b.step(
        "headless-process-fixture",
        "Process-level headless JSON/stream end-to-end fixture",
    );
    headless_fixture_step.dependOn(&run_headless_process_tests.step);

    // cli-sigint-001: process-level SIGINT lifecycle fixture (real direct `zag`
    // binary, isolated cwd, synthetic env, deterministic slow mock provider).
    // Exercises idle first-SIGINT clean exit 0 and active second-SIGINT hard
    // exit 130. Uses a separate slow mock binary so its stall runs in its own
    // process. Runs under both std and curl backends (the active case is an
    // std-backend honest expectation; curl would actively cancel).
    const sigint_slow_mock_exe = b.addExecutable(.{
        .name = "sigint-slow-mock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/sigint_slow_mock.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const sigint_fixture_opts = b.addOptions();
    sigint_fixture_opts.addOptionPath("zag_bin", exe.getEmittedBin());
    sigint_fixture_opts.addOptionPath("slow_mock_bin", sigint_slow_mock_exe.getEmittedBin());
    sigint_fixture_opts.addOption(HttpBackend, "http_backend", http_backend);
    const sigint_process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/sigint_process_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sigint_fixture_options", .module = sigint_fixture_opts.createModule() },
            },
        }),
    });
    // cli-sigint-001 review item 1: the fixture uses libc process-control
    // primitives (waitpid/kill/W macros) which are only available with libc.
    // This is scoped to the TEST ARTIFACT only (never the product exe) and the
    // fixture only ever runs on the host-native target where libc is present.
    // The product `sigint.zig` module itself carries NO libc dependency on
    // Linux (it uses raw std.posix.system / std.os.linux syscalls).
    sigint_process_tests.root_module.link_libc = true;
    const run_sigint_process_tests = b.addRunArtifact(sigint_process_tests);
    const sigint_fixture_step = b.step(
        "sigint-process-fixture",
        "Process-level SIGINT lifecycle (idle exit 0 / active hard exit 130)",
    );
    sigint_fixture_step.dependOn(&run_sigint_process_tests.step);

    // tui-minimal-001: process-level --tui mode matrix / non-TTY / PTY Gates
    // (only when -Dtui=true). Reuses sigint-slow-mock for blocked-provider evidence.
    var run_tui_process_tests: ?*std.Build.Step.Run = null;
    if (tui) {
        const tui_fixture_opts = b.addOptions();
        tui_fixture_opts.addOptionPath("zag_bin", exe.getEmittedBin());
        tui_fixture_opts.addOptionPath("slow_mock_bin", sigint_slow_mock_exe.getEmittedBin());
        tui_fixture_opts.addOptionPath("headless_mock_bin", headless_mock_server_exe.getEmittedBin());
        tui_fixture_opts.addOption(HttpBackend, "http_backend", http_backend);
        tui_fixture_opts.addOption(bool, "tui_enabled", true);
        const tui_process_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("packages/zag-cli/src/tui_process_fixture.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "tui_fixture_options", .module = tui_fixture_opts.createModule() },
                },
            }),
        });
        // PTY harness uses openpty/fork/waitpid (libc); test artifact only.
        tui_process_tests.root_module.link_libc = true;
        run_tui_process_tests = b.addRunArtifact(tui_process_tests);
    }

    // rpc-v1-001: process-level --rpc fixture (real zag binary, pipes/PTY,
    // headless mock provider over loopback). Runs under both std and curl
    // backends; libc on the test artifact only (PTY + process control).
    const rpc_fixture_opts = b.addOptions();
    rpc_fixture_opts.addOptionPath("zag_bin", exe.getEmittedBin());
    rpc_fixture_opts.addOptionPath("headless_mock_bin", headless_mock_server_exe.getEmittedBin());
    rpc_fixture_opts.addOption(HttpBackend, "http_backend", http_backend);
    const rpc_process_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("packages/zag-cli/src/rpc_process_fixture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rpc_fixture_options", .module = rpc_fixture_opts.createModule() },
            },
        }),
    });
    rpc_process_tests.root_module.link_libc = true;
    const run_rpc_process_tests = b.addRunArtifact(rpc_process_tests);
    const rpc_fixture_step = b.step(
        "rpc-process-fixture",
        "Process-level zag --rpc NDJSON fixture (pipes + PTY gates)",
    );
    rpc_fixture_step.dependOn(&run_rpc_process_tests.step);

    const test_step = b.step("test", "Run all tests + openai coverage + catalog + docs lint");
    test_step.dependOn(&run_openai_tests.step);
    test_step.dependOn(&run_types_tests.step);
    test_step.dependOn(&run_ai_tests.step);
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_coding_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_doctor_process_tests.step);
    test_step.dependOn(&run_headless_process_tests.step);
    test_step.dependOn(&run_sigint_process_tests.step);
    test_step.dependOn(&run_rpc_process_tests.step);
    if (run_tui_tests) |rt| test_step.dependOn(&rt.step);
    if (run_tui_process_tests) |rt| test_step.dependOn(&rt.step);
    test_step.dependOn(openai_coverage_step);
    test_step.dependOn(catalog_check_step);
    test_step.dependOn(docs_lint_step);
}

fn attachCurl(mod: *std.Build.Module, curl_dep: *std.Build.Dependency) void {
    mod.addImport("curl", curl_dep.module("curl"));
    mod.link_libc = true;
    mod.linkSystemLibrary("curl", .{});
}
