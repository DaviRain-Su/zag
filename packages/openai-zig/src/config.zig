//! Lightweight config loader for demos/examples (env map + optional simple key=value file).
//! Library consumers should construct `Client.Options` directly.

const std = @import("std");

pub const Config = struct {
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    organization: ?[]const u8,
    project: ?[]const u8,
    timeout_ms: ?u64,
    max_retries: u8,
    retry_base_delay_ms: u64,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.api_key);
        allocator.free(self.base_url);
        allocator.free(self.model);
        if (self.organization) |v| allocator.free(v);
        if (self.project) |v| allocator.free(v);
    }
};

const defaults = struct {
    const api_key: []const u8 = "";
    const base_url: []const u8 = "https://api.deepseek.com/v1";
    const model: []const u8 = "deepseek-chat";
    const max_retries: u8 = 2;
    const retry_base_delay_ms: u64 = 500;
};

/// Load config from optional file only (no process env). Prefer `loadFromEnvMap`.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    return loadFromEnvMap(allocator, io, path, null);
}

/// Load config: optional simple key=value file overlaid with env map keys.
pub fn loadFromEnvMap(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    env: ?*const std.process.Environ.Map,
) !Config {
    var api_key: ?[]const u8 = null;
    var base_url: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var organization: ?[]const u8 = null;
    var project: ?[]const u8 = null;
    var timeout_ms: ?u64 = null;
    var max_retries: ?u8 = null;
    var retry_base_delay_ms: ?u64 = null;
    errdefer if (api_key) |val| allocator.free(val);
    errdefer if (base_url) |val| allocator.free(val);
    errdefer if (model) |val| allocator.free(val);
    errdefer if (organization) |val| allocator.free(val);
    errdefer if (project) |val| allocator.free(val);

    const env_api_key = try readOptionalEnvFrom(allocator, env, &.{ "OPENAI_API_KEY", "DEEPSEEK_API_KEY" });
    defer if (env_api_key) |val| allocator.free(val);
    const env_base_url = try readOptionalEnvFrom(allocator, env, &.{ "OPENAI_BASE_URL", "DEEPSEEK_BASE_URL" });
    defer if (env_base_url) |val| allocator.free(val);
    const env_model = try readOptionalEnvFrom(allocator, env, &.{ "OPENAI_MODEL", "DEEPSEEK_MODEL" });
    defer if (env_model) |val| allocator.free(val);
    const env_organization = try readOptionalEnvFrom(allocator, env, &.{"OPENAI_ORGANIZATION"});
    defer if (env_organization) |val| allocator.free(val);
    const env_project = try readOptionalEnvFrom(allocator, env, &.{"OPENAI_PROJECT"});
    defer if (env_project) |val| allocator.free(val);
    const env_timeout_ms = try readOptionalEnvIntFrom(allocator, env, &.{ "OPENAI_TIMEOUT_MS", "DEEPSEEK_TIMEOUT_MS" });
    const env_max_retries = try readOptionalEnvIntFrom(allocator, env, &.{ "OPENAI_MAX_RETRIES", "DEEPSEEK_MAX_RETRIES" });
    const env_retry_base_delay_ms = try readOptionalEnvIntFrom(
        allocator,
        env,
        &.{ "OPENAI_RETRY_BASE_DELAY_MS", "DEEPSEEK_RETRY_BASE_DELAY_MS" },
    );

    var file_api_key: ?[]const u8 = null;
    var file_base_url: ?[]const u8 = null;
    var file_model: ?[]const u8 = null;
    var file_organization: ?[]const u8 = null;
    var file_project: ?[]const u8 = null;
    var file_timeout_ms: ?u64 = null;
    var file_max_retries: ?u8 = null;
    var file_retry_base_delay_ms: ?u64 = null;
    defer if (file_api_key) |v| allocator.free(v);
    defer if (file_base_url) |v| allocator.free(v);
    defer if (file_model) |v| allocator.free(v);
    defer if (file_organization) |v| allocator.free(v);
    defer if (file_project) |v| allocator.free(v);

    if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024))) |contents| {
        defer allocator.free(contents);
        try parseSimpleConfig(
            allocator,
            contents,
            &file_api_key,
            &file_base_url,
            &file_model,
            &file_organization,
            &file_project,
            &file_timeout_ms,
            &file_max_retries,
            &file_retry_base_delay_ms,
        );
    } else |_| {}

    api_key = try allocator.dupe(u8, file_api_key orelse env_api_key orelse defaults.api_key);
    base_url = try allocator.dupe(u8, file_base_url orelse env_base_url orelse defaults.base_url);
    model = try allocator.dupe(u8, file_model orelse env_model orelse defaults.model);
    organization = if (file_organization orelse env_organization) |v| try allocator.dupe(u8, v) else null;
    project = if (file_project orelse env_project) |v| try allocator.dupe(u8, v) else null;
    timeout_ms = file_timeout_ms orelse env_timeout_ms;
    max_retries = file_max_retries orelse if (env_max_retries) |value|
        if (value <= std.math.maxInt(u8)) @as(u8, @intCast(value)) else defaults.max_retries
    else
        defaults.max_retries;
    retry_base_delay_ms = file_retry_base_delay_ms orelse env_retry_base_delay_ms orelse defaults.retry_base_delay_ms;

    return Config{
        .api_key = api_key.?,
        .base_url = base_url.?,
        .model = model.?,
        .organization = organization,
        .project = project,
        .timeout_ms = timeout_ms,
        .max_retries = max_retries.?,
        .retry_base_delay_ms = retry_base_delay_ms.?,
    };
}

fn parseSimpleConfig(
    allocator: std.mem.Allocator,
    contents: []const u8,
    api_key: *?[]const u8,
    base_url: *?[]const u8,
    model: *?[]const u8,
    organization: *?[]const u8,
    project: *?[]const u8,
    timeout_ms: *?u64,
    max_retries: *?u8,
    retry_base_delay_ms: *?u64,
) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }

        if (std.mem.eql(u8, key, "api_key")) {
            api_key.* = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "base_url")) {
            base_url.* = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "model")) {
            model.* = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "organization")) {
            organization.* = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "project")) {
            project.* = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "timeout_ms")) {
            timeout_ms.* = std.fmt.parseInt(u64, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "max_retries")) {
            max_retries.* = std.fmt.parseInt(u8, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "retry_base_delay_ms")) {
            retry_base_delay_ms.* = std.fmt.parseInt(u64, value, 10) catch null;
        }
    }
}

fn readOptionalEnvFrom(
    allocator: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
    keys: []const []const u8,
) !?[]const u8 {
    for (keys) |key| {
        if (try readOptionalEnv(allocator, env, key)) |value| return value;
    }
    return null;
}

fn readOptionalEnv(
    allocator: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
    key: []const u8,
) !?[]const u8 {
    const map = env orelse return null;
    if (map.get(key)) |value| {
        if (value.len == 0) return null;
        return try allocator.dupe(u8, value);
    }
    return null;
}

fn readOptionalEnvIntFrom(
    allocator: std.mem.Allocator,
    env: ?*const std.process.Environ.Map,
    keys: []const []const u8,
) !?u64 {
    for (keys) |key| {
        const raw = try readOptionalEnv(allocator, env, key);
        if (raw) |value| {
            defer allocator.free(value);
            return std.fmt.parseInt(u64, std.mem.trim(u8, value, " \t"), 10) catch null;
        }
    }
    return null;
}
