//! Zag CLI — thin product shell. Business lives in `agent/`.

const std = @import("std");
const Io = std.Io;
const zag = @import("zag");

const default_system =
    \\You are Zag, a coding agent. You explore codebases using tools.
    \\Rules:
    \\- Prefer tools over guessing about files on disk.
    \\- Use list_dir and read_file to inspect the working directory.
    \\- Paths are relative to the process working directory.
    \\- Be concise. When finished, answer the user without further tool calls.
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var prompt_parts: std.ArrayList([]const u8) = .empty;
    var verbose = false;
    var show_help = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try prompt_parts.append(arena, args[i]);
            }
            break;
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.log.err("unknown flag: {s}", .{a});
            try printUsage();
            std.process.exit(2);
        } else {
            try prompt_parts.append(arena, a);
        }
    }

    if (show_help) {
        try printUsage();
        return;
    }

    const resolved = zag.provider_config.resolve(init.environ_map) catch |err| {
        switch (err) {
            error.MissingApiKey => {
                std.log.err(
                    \\missing API key. Set one of:
                    \\  ZAG_API_KEY
                    \\  DEEPSEEK_API_KEY
                    \\  XAI_API_KEY
                    \\  OPENAI_API_KEY
                , .{});
                std.process.exit(1);
            },
        }
    };

    if (verbose) {
        std.log.info("provider preset={s} base_url={s} model={s}", .{
            resolved.preset.name(),
            resolved.config.base_url,
            resolved.config.model,
        });
    }

    var client = zag.openai.Client.init(gpa, io, resolved.config);
    defer client.deinit();

    var agent = zag.agent.Agent.initPhase0(gpa, io, client.provider(), .{
        .verbose = verbose,
    });

    if (prompt_parts.items.len > 0) {
        const prompt = try std.mem.join(arena, " ", prompt_parts.items);
        try runOneShot(&agent, prompt, verbose);
        return;
    }

    try runRepl(&agent, io, verbose);
}

fn runOneShot(agent: *zag.agent.Agent, prompt: []const u8, verbose: bool) !void {
    const result = agent.complete(default_system, prompt) catch |err| {
        std.log.err("agent failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer result.deinit(agent.gpa);

    if (verbose) {
        std.log.info("completed in {d} turn(s)", .{result.turns});
    }

    try writeStdout(agent.io, result.final_text);
    if (result.final_text.len == 0 or result.final_text[result.final_text.len - 1] != '\n') {
        try writeStdout(agent.io, "\n");
    }
}

fn runRepl(agent: *zag.agent.Agent, io: Io, verbose: bool) !void {
    _ = verbose;
    try writeStdout(io, "zag phase-0 (read-only tools). Empty line or Ctrl-D to exit.\n");

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    const reader = &stdin_reader.interface;

    var session = zag.agent.Session.start(agent.gpa, default_system) catch |err| {
        std.log.err("session failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session.deinit();

    while (true) {
        try writeStdout(io, "you> ");
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try writeStdout(io, "\n");
                break;
            },
            else => return err,
        };

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) break;

        const result = agent.reply(&session, trimmed) catch |err| {
            std.log.err("agent failed: {s}", .{@errorName(err)});
            continue;
        };

        try writeStdout(io, "zag> ");
        try writeStdout(io, result.final_text);
        if (result.final_text.len == 0 or result.final_text[result.final_text.len - 1] != '\n') {
            try writeStdout(io, "\n");
        }
    }
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn printUsage() !void {
    const usage =
        \\zag — Zig coding agent (Phase 0: read-only loop)
        \\
        \\Usage:
        \\  zag [flags] <prompt...>     one-shot
        \\  zag [flags]                 interactive REPL
        \\
        \\Flags:
        \\  -h, --help       show help
        \\  -v, --verbose    log tool calls to stderr
        \\
        \\Environment (first matching key wins):
        \\  ZAG_API_KEY        explicit key (+ ZAG_BASE_URL / ZAG_MODEL)
        \\  DEEPSEEK_API_KEY   DeepSeek  (api.deepseek.com, deepseek-v4-flash)
        \\  XAI_API_KEY        xAI       (api.x.ai, grok-4-latest)
        \\  OPENAI_API_KEY     OpenAI    (api.openai.com, gpt-4o-mini)
        \\  ZAG_BASE_URL       override API base for any preset
        \\  ZAG_MODEL          override model for any preset
        \\
        \\Tools (Phase 0): list_dir, read_file
        \\
    ;
    const io = std.Io.Threaded.global_single_threaded.io();
    try writeStdout(io, usage);
}
