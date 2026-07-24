//! Live HTTP backend bake-off (D-005 Phase 3).
//!
//! Compares the active `-Dhttp_backend` against a public echo host.
//! Network required. Not part of `zig build test`.
//!
//! Cases:
//! - `post_ok` — POST JSON, expect 2xx
//! - `timeout` — POST to `/delay/5` with `timeout_ms=1500`; curl should abort early;
//!   std currently stores timeout but does not enforce it (known gap)

const std = @import("std");
const Io = std.Io;
const zag_ai = @import("zag-ai");

const http = zag_ai.http;

const default_base = "https://httpbingo.org";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const base_url = if (args.len > 1)
        args[1]
    else
        init.environ_map.get("ZAG_BAKEOFF_BASE_URL") orelse default_base;

    const backend = http.backendName();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    try out.print("BACKEND={s}\n", .{backend});
    // h-redact-001: never print caller/env base_url (userinfo/query may hold secrets).
    try out.print("{s}\n", .{http.formatConfiguredBaseUrlStatus(base_url)});

    try runCase(gpa, io, out, "post_ok", base_url, "/post", null, 8_000);
    try runCase(gpa, io, out, "timeout", base_url, "/delay/5", 1_500, 20_000);

    try out.flush();
}

fn elapsedMs(io: Io, t0: Io.Clock.Timestamp) u64 {
    const dur = t0.untilNow(io);
    const ms = dur.raw.toMilliseconds();
    return if (ms < 0) 0 else @intCast(ms);
}

fn runCase(
    gpa: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    name: []const u8,
    base_url: []const u8,
    path: []const u8,
    timeout_ms: ?u64,
    wall_limit_ms: u64,
) !void {
    const t0 = Io.Clock.Timestamp.now(io, .real);

    var timeout_label_buf: [32]u8 = undefined;
    const timeout_label: []const u8 = if (timeout_ms) |t|
        std.fmt.bufPrint(&timeout_label_buf, "{d}", .{t}) catch "?"
    else
        "none";

    var client = http.Client.initBearer(gpa, io, .{
        .base_url = base_url,
        .api_key = "bakeoff",
        .model = "n/a",
        .max_retries = 0,
        .timeout_ms = timeout_ms,
    }) catch |err| {
        try out.print(
            "CASE={s} RESULT=init_fail ERR={s} MS={d} LIMIT_MS={d}\n",
            .{ name, @errorName(err), elapsedMs(io, t0), wall_limit_ms },
        );
        return;
    };
    defer client.deinit();

    const resp_or_err = client.postJson(path, "{}");
    const elapsed = elapsedMs(io, t0);

    if (resp_or_err) |resp| {
        defer if (resp.body.len > 0) gpa.free(resp.body);
        const ok = resp.status >= 200 and resp.status < 300;
        const result: []const u8 = if (timeout_ms != null and elapsed > timeout_ms.? + 500)
            "timeout_ignored"
        else if (ok)
            "ok"
        else
            "bad_status";
        try out.print(
            "CASE={s} RESULT={s} STATUS={d} MS={d} LIMIT_MS={d} TIMEOUT_MS={s}\n",
            .{ name, result, resp.status, elapsed, wall_limit_ms, timeout_label },
        );
    } else |err| {
        const result: []const u8 = if (err == error.Timeout)
            "timeout"
        else if (timeout_ms != null and elapsed <= timeout_ms.? + 800)
            "early_fail"
        else
            "fail";
        try out.print(
            "CASE={s} RESULT={s} ERR={s} MS={d} LIMIT_MS={d} TIMEOUT_MS={s}\n",
            .{ name, result, @errorName(err), elapsed, wall_limit_ms, timeout_label },
        );
    }

    if (elapsed > wall_limit_ms) {
        try out.print("CASE={s} NOTE=exceeded_wall_limit\n", .{name});
    }
}
