//! Binds `zag-ai.WireAdapter` to Agent Core's pure `Provider` port.
//!
//! Lives in coding-agent (assembly), not in agent-core.
//! Receives only model-visible `ToolDefinition` slices from the loop.

const std = @import("std");
const ai = @import("zag-ai");
const core = @import("zag-agent-core");

const message = core.message;
const tool = core.tool;
const provider_mod = core.provider;

pub const ChatError = provider_mod.ChatError;
pub const Provider = provider_mod.Provider;

/// Stateful bridge: WireAdapter + stream flags + chat options.
pub const WireProvider = struct {
    wire: ai.WireAdapter,
    /// When true, `deinit` calls `wire.deinit()`.
    owns_wire: bool = false,
    stream: bool = false,
    chat_options: ai.ChatOptions = .{},
    on_event: ?ai.types.StreamHandler = null,
    on_event_ctx: ?*anyopaque = null,

    pub fn init(w: ai.WireAdapter, stream_mode: bool, owns: bool) WireProvider {
        return .{
            .wire = w,
            .owns_wire = owns,
            .stream = stream_mode,
        };
    }

    pub fn deinit(self: *WireProvider) void {
        if (self.owns_wire) self.wire.deinit();
        self.* = undefined;
    }

    /// Expose core Provider port for the loop / Agent facade.
    pub fn asProvider(self: *WireProvider) Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Alias for asProvider (historical name).
    pub fn provider(self: *WireProvider) Provider {
        return self.asProvider();
    }

    const vtable: provider_mod.VTable = .{ .chat = chatImpl };

    fn chatImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Definition,
    ) ChatError!message.AssistantTurn {
        const self: *WireProvider = @ptrCast(@alignCast(ptr));
        // Provider plane: definitions only — never Tool/descriptor/capabilities.
        if (self.stream) {
            return self.wire.chatStream(
                arena,
                messages,
                tools,
                self.on_event,
                self.on_event_ctx,
                self.chat_options,
            );
        }
        return self.wire.chat(arena, messages, tools, self.chat_options);
    }
};

/// Back-compat name used by older docs / main.
pub const Adapter = WireProvider;

test "loop via WireProvider forwards only ToolDefinition to WireAdapter" {
    // Composition fixture: loop.run → WireProvider → fake WireAdapter.
    // Wire receives []ToolDefinition; capability tokens cannot appear.
    const gpa = std.testing.allocator;
    const loop = core.loop;
    const transcript_mod = core.transcript;

    const FakeWire = struct {
        saw: bool = false,
        tool_count: usize = 0,
        name_ok: bool = false,
        clean_payload: bool = false,

        fn apiStyle(_: *anyopaque) ai.wire.ApiStyle {
            return .openai_compat;
        }
        fn name(_: *anyopaque) []const u8 {
            return "fake";
        }
        fn deinitFn(_: *anyopaque) void {}
        fn embed(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const []const u8,
            _: ai.EmbedOptions,
        ) ai.wire.Error!ai.EmbeddingResult {
            return error.NotSupported;
        }
        fn chatStream(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            messages: []const ai.types.Message,
            tools: []const ai.ToolDefinition,
            _: ?ai.types.StreamHandler,
            _: ?*anyopaque,
            opts: ai.ChatOptions,
        ) ai.wire.Error!ai.types.AssistantTurn {
            return chat(ptr, arena, messages, tools, opts);
        }
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const ai.types.Message,
            tools: []const ai.ToolDefinition,
            _: ai.ChatOptions,
        ) ai.wire.Error!ai.types.AssistantTurn {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.saw = true;
            self.tool_count = tools.len;
            if (tools.len != 1) return error.InvalidResponse;
            self.name_ok = std.mem.eql(u8, tools[0].name, "secret_write");

            var out: std.Io.Writer.Allocating = .init(arena);
            var s: std.json.Stringify = .{ .writer = &out.writer };
            s.write(.{
                .name = tools[0].name,
                .description = tools[0].description,
                .parameters_json = tools[0].parameters_json,
            }) catch return error.InvalidResponse;
            const body = out.written();
            self.clean_payload = std.mem.indexOf(u8, body, "\"risk\"") == null and
                std.mem.indexOf(u8, body, "capabilities") == null and
                std.mem.indexOf(u8, body, "cooperative") == null and
                std.mem.indexOf(u8, body, "path_field") == null and
                std.mem.indexOf(u8, body, "command_argument") == null;
            if (!self.clean_payload) return error.InvalidResponse;

            return .{
                .content = try arena.dupe(u8, "wire-ok"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }

        const vtable: ai.wire.VTable = .{
            .api_style = apiStyle,
            .name = name,
            .deinit = deinitFn,
            .chat = chat,
            .chat_stream = chatStream,
            .embed = embed,
        };

        fn asWire(self: *@This()) ai.WireAdapter {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    var fake: FakeWire = .{};
    var wire_prov = WireProvider.init(fake.asWire(), false, false);
    defer wire_prov.deinit();

    const t = try tool.buildTool(gpa, .{
        .definition = .{
            .name = "secret_write",
            .description = "d",
            .parameters_json = "{\"type\":\"object\"}",
        },
        .capabilities = .{
            .risk = .write,
            .workspace = .{ .path_field = "path" },
            .cancellation = .cooperative,
            .shell = .none,
        },
        .handler = struct {
            fn h(_: tool.Context, _: ?*anyopaque, _: []const u8) tool.HandlerError![]u8 {
                return error.ToolFailed;
            }
        }.h,
    });
    const tools = [_]tool.Tool{t};

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    const result = try loop.run(.{
        .gpa = gpa,
        .provider = wire_prov.asProvider(),
        .toolset = .{ .tools = &tools },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .options = .{ .permission_gate = .yolo() },
    }, &transcript);

    try std.testing.expect(fake.saw);
    try std.testing.expect(fake.name_ok);
    try std.testing.expect(fake.clean_payload);
    try std.testing.expectEqual(@as(usize, 1), fake.tool_count);
    try std.testing.expectEqualStrings("wire-ok", result.final_text);
}
