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
    /// Optional end-to-end timeout when loop did not set a deadline (ms).
    timeout_ms: ?u64 = null,
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

    /// Switch the active chat model on the underlying wire.
    pub fn setModel(self: *WireProvider, model: []const u8) ai.WireError!void {
        return self.wire.setModel(model);
    }

    /// Current model id (borrowed from wire).
    pub fn getModel(self: *const WireProvider) []const u8 {
        return self.wire.getModel();
    }

    /// Live model ids from the provider (arena-owned).
    pub fn listModels(self: *WireProvider, arena: std.mem.Allocator) ai.WireError![]const []const u8 {
        return self.wire.listModels(arena);
    }

    const vtable: provider_mod.VTable = .{
        .chat = chatImpl,
        .chat_stream = chatStreamImpl,
    };

    fn chatImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Definition,
        control: provider_mod.RequestControl,
        retry_after_out: ?*?u64,
    ) ChatError!message.AssistantTurn {
        const self: *WireProvider = @ptrCast(@alignCast(ptr));
        var opts = self.chat_options;
        // Merge loop control with optional WireProvider timeout. Loop deadline wins
        // when already set (end-to-end budget). Cancel flag is always from loop.
        var c = control;
        if (c.deadline_mono_ns == null) {
            if (self.timeout_ms) |ms| {
                c.deadline_mono_ns = ai.types.RequestControl.withTimeoutMs(
                    ai.types.monoNowNs(),
                    ms,
                ).deadline_mono_ns;
            }
        }
        opts.control = c;
        // Provider plane: definitions only — never Tool/descriptor/capabilities.
        // retry-after-wire-001: the out slot reaches the wire client; the
        // Anthropic vtable impl writes it, the OpenAI impl ignores it.
        if (self.stream) {
            return self.wire.chatStream(
                arena,
                messages,
                tools,
                self.on_event,
                self.on_event_ctx,
                opts,
                retry_after_out,
            );
        }
        return self.wire.chat(arena, messages, tools, opts, retry_after_out);
    }

    /// Streaming port (tui-streaming-001). The loop calls this slot whenever
    /// present, so it must work regardless of the config `stream` flag:
    /// `stream` false routes to the non-streaming `wire.chat` (no deltas —
    /// `--stream`/config semantics unchanged, headless-v1 byte-identical);
    /// `stream` true streams and forwards ONLY content deltas to the Core
    /// handler, while tool_call_delta / finish_reason / done stay inside the
    /// wire stream state machine (already accumulated into the returned turn).
    fn chatStreamImpl(
        ptr: *anyopaque,
        arena: std.mem.Allocator,
        messages: []const message.Message,
        tools: []const tool.Definition,
        control: provider_mod.RequestControl,
        handler: provider_mod.DeltaHandler,
        handler_ctx: *anyopaque,
        retry_after_out: ?*?u64,
    ) ChatError!message.AssistantTurn {
        const self: *WireProvider = @ptrCast(@alignCast(ptr));
        var opts = self.chat_options;
        // Merge loop control with optional WireProvider timeout (mirror chatImpl).
        var c = control;
        if (c.deadline_mono_ns == null) {
            if (self.timeout_ms) |ms| {
                c.deadline_mono_ns = ai.types.RequestControl.withTimeoutMs(
                    ai.types.monoNowNs(),
                    ms,
                ).deadline_mono_ns;
            }
        }
        opts.control = c;
        if (!self.stream) {
            return self.wire.chat(arena, messages, tools, opts, retry_after_out);
        }
        var shim = StreamShim{
            .core_handler = handler,
            .core_ctx = handler_ctx,
            .wire_handler = self.on_event,
            .wire_ctx = self.on_event_ctx,
        };
        return self.wire.chatStream(
            arena,
            messages,
            tools,
            StreamShim.onWireEvent,
            &shim,
            opts,
            retry_after_out,
        );
    }
};

/// Wire-level handler shim for the streaming port: forwards content deltas and
/// reasoning deltas to the Core delta handler, and preserves the pre-existing
/// direct wire `on_event` consumer (CLI verbose diagnostics) unchanged for ALL
/// events. `tool_call_delta` / `finish_reason` / `done` never reach the Core
/// handler (tui-streaming-001 delta scope; tui-thinking-streaming-001 adds
/// reasoning_delta to the forwarded set).
const StreamShim = struct {
    core_handler: provider_mod.DeltaHandler,
    core_ctx: *anyopaque,
    wire_handler: ?ai.types.StreamHandler,
    wire_ctx: ?*anyopaque,

    fn onWireEvent(ctx: ?*anyopaque, event: ai.types.StreamEvent) anyerror!void {
        const self: *StreamShim = @ptrCast(@alignCast(ctx.?));
        // Wire consumer first: its error semantics (fail the stream) are
        // unchanged from the pre-streaming path.
        if (self.wire_handler) |h| try h(self.wire_ctx, event);
        switch (event) {
            .content_delta => |delta| self.core_handler(self.core_ctx, delta, null),
            // Reasoning-only chunk: empty content, non-null reasoning slot.
            .reasoning_delta => |delta| self.core_handler(self.core_ctx, "", delta),
            else => {},
        }
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
            _: ?*?u64,
        ) ai.wire.Error!ai.types.AssistantTurn {
            return chat(ptr, arena, messages, tools, opts, null);
        }
        fn chat(
            ptr: *anyopaque,
            arena: std.mem.Allocator,
            _: []const ai.types.Message,
            tools: []const ai.ToolDefinition,
            _: ai.ChatOptions,
            _: ?*?u64,
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
                std.mem.indexOf(u8, body, "path_field_default") == null and
                std.mem.indexOf(u8, body, "default_path") == null and
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
        .tool_policy = loop.ToolPolicy.allowAllForTrustedHost(),
        .jail = loop.Jail.allowAllForTrustedHost(),
        .shell_policy = loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = loop.ContextView.identity(),
        .event_sink = loop.LoopEventSink.discard(),
        .control_input = loop.ControlInput.none(),
    }, &transcript);

    try std.testing.expect(fake.saw);
    try std.testing.expect(fake.name_ok);
    try std.testing.expect(fake.clean_payload);
    try std.testing.expectEqual(@as(usize, 1), fake.tool_count);
    try std.testing.expectEqualStrings("wire-ok", result.final_text);
}

test "loop chat_stream forwards only content_delta (stream=true)" {
    // Streaming fake wire emits content_delta + tool_call_delta + finish_reason
    // + done. The Core loop must observe ONLY the content deltas (in order,
    // before the complete assistant_message); tool deltas/finish stay inside
    // the wire state machine.
    const gpa = std.testing.allocator;
    const loop = core.loop;
    const transcript_mod = core.transcript;

    const FakeWire = struct {
        fn apiStyle(_: *anyopaque) ai.wire.ApiStyle {
            return .openai_compat;
        }
        fn name(_: *anyopaque) []const u8 {
            return "fake-stream";
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
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const ai.types.Message,
            _: []const ai.ToolDefinition,
            handler: ?ai.types.StreamHandler,
            handler_ctx: ?*anyopaque,
            _: ai.ChatOptions,
            _: ?*?u64,
        ) ai.wire.Error!ai.types.AssistantTurn {
            const events = [_]ai.types.StreamEvent{
                .{ .content_delta = "Hel" },
                .{ .tool_call_delta = .{ .index = 0, .arguments_delta = "{}" } },
                .{ .content_delta = "lo " },
                .{ .finish_reason = "stop" },
                .{ .done = {} },
            };
            for (events) |ev| {
                if (handler) |h| h(handler_ctx, ev) catch return error.StreamFailed;
            }
            return .{
                .content = try arena.dupe(u8, "Hello "),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
        fn chat(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const ai.types.Message,
            _: []const ai.ToolDefinition,
            _: ai.ChatOptions,
            _: ?*?u64,
        ) ai.wire.Error!ai.types.AssistantTurn {
            return error.NotSupported;
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

    const DeltaSink = struct {
        deltas: u32 = 0,
        clears: u32 = 0,
        text: [64]u8 = undefined,
        text_len: usize = 0,
        fn emit(ptr: ?*anyopaque, event: loop.LoopEvent) core.loop_event.SinkError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .assistant_delta => |d| {
                    self.deltas += 1;
                    const cap = @min(d.len, self.text.len - self.text_len);
                    @memcpy(self.text[self.text_len..][0..cap], d[0..cap]);
                    self.text_len += cap;
                },
                .assistant_delta_clear => self.clears += 1,
                else => {},
            }
        }
    };
    const delta_vtable: core.loop_event.LoopEventSinkVTable = .{ .emit = DeltaSink.emit };

    var fake: FakeWire = .{};
    var wire_prov = WireProvider.init(fake.asWire(), true, false);
    defer wire_prov.deinit();

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var sink: DeltaSink = .{};
    const result = try loop.run(.{
        .gpa = gpa,
        .provider = wire_prov.asProvider(),
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .tool_policy = loop.ToolPolicy.allowAllForTrustedHost(),
        .jail = loop.Jail.allowAllForTrustedHost(),
        .shell_policy = loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = loop.ContextView.identity(),
        .event_sink = .{ .ptr = &sink, .vtable = &delta_vtable },
        .control_input = loop.ControlInput.none(),
    }, &transcript);

    try std.testing.expectEqualStrings("Hello ", result.final_text);
    // Only the two content_delta chunks reached the loop; tool_call_delta /
    // finish_reason / done were absorbed by the wire state machine.
    try std.testing.expectEqual(@as(u32, 2), sink.deltas);
    try std.testing.expectEqual(@as(u32, 0), sink.clears);
    try std.testing.expectEqualStrings("Hello ", sink.text[0..sink.text_len]);
}

test "chat_stream chains wire on_event: both consumers receive deltas" {
    // tui-streaming-001 B8: with wire_prov.on_event set (CLI --stream --verbose
    // diagnostics), the pre-existing wire consumer keeps receiving ALL wire
    // events while the Core handler receives only content deltas.
    const gpa = std.testing.allocator;
    const loop = core.loop;
    const transcript_mod = core.transcript;

    const FakeWire = struct {
        fn apiStyle(_: *anyopaque) ai.wire.ApiStyle {
            return .openai_compat;
        }
        fn name(_: *anyopaque) []const u8 {
            return "fake-chain";
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
            _: *anyopaque,
            arena: std.mem.Allocator,
            _: []const ai.types.Message,
            _: []const ai.ToolDefinition,
            handler: ?ai.types.StreamHandler,
            handler_ctx: ?*anyopaque,
            _: ai.ChatOptions,
            _: ?*?u64,
        ) ai.wire.Error!ai.types.AssistantTurn {
            const events = [_]ai.types.StreamEvent{
                .{ .content_delta = "Hel" },
                .{ .tool_call_delta = .{ .index = 0, .arguments_delta = "{}" } },
                .{ .content_delta = "lo" },
                .{ .finish_reason = "stop" },
                .{ .done = {} },
            };
            for (events) |ev| {
                if (handler) |h| h(handler_ctx, ev) catch return error.StreamFailed;
            }
            return .{
                .content = try arena.dupe(u8, "Hello"),
                .tool_calls = &.{},
                .finish_reason = "stop",
            };
        }
        fn chat(
            _: *anyopaque,
            _: std.mem.Allocator,
            _: []const ai.types.Message,
            _: []const ai.ToolDefinition,
            _: ai.ChatOptions,
            _: ?*?u64,
        ) ai.wire.Error!ai.types.AssistantTurn {
            return error.NotSupported;
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

    const WireDiag = struct {
        events: u32 = 0,
        fn onEvent(ctx: ?*anyopaque, _: ai.types.StreamEvent) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.events += 1;
        }
    };

    const DeltaSink = struct {
        deltas: u32 = 0,
        fn emit(ptr: ?*anyopaque, event: loop.LoopEvent) core.loop_event.SinkError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            switch (event) {
                .assistant_delta => self.deltas += 1,
                else => {},
            }
        }
    };
    const delta_vtable: core.loop_event.LoopEventSinkVTable = .{ .emit = DeltaSink.emit };

    var fake: FakeWire = .{};
    var wire_prov = WireProvider.init(fake.asWire(), true, false);
    defer wire_prov.deinit();
    var diag: WireDiag = .{};
    wire_prov.on_event = WireDiag.onEvent;
    wire_prov.on_event_ctx = &diag;

    var arena_impl: std.heap.ArenaAllocator = .init(gpa);
    defer arena_impl.deinit();
    var transcript = transcript_mod.Transcript.init(arena_impl.allocator());
    try transcript.appendUser("hi");

    var sink: DeltaSink = .{};
    const result = try loop.run(.{
        .gpa = gpa,
        .provider = wire_prov.asProvider(),
        .toolset = .{ .tools = &.{} },
        .tool_ctx = .{
            .allocator = gpa,
            .io = std.testing.io,
            .cwd = std.Io.Dir.cwd(),
        },
        .tool_policy = loop.ToolPolicy.allowAllForTrustedHost(),
        .jail = loop.Jail.allowAllForTrustedHost(),
        .shell_policy = loop.ShellPolicy.allowAllForTrustedHost(),
        .context_view = loop.ContextView.identity(),
        .event_sink = .{ .ptr = &sink, .vtable = &delta_vtable },
        .control_input = loop.ControlInput.none(),
    }, &transcript);

    try std.testing.expectEqualStrings("Hello", result.final_text);
    // Wire diagnostics consumer saw ALL five wire events (chained first);
    // the Core handler saw only the two content deltas.
    try std.testing.expectEqual(@as(u32, 5), diag.events);
    try std.testing.expectEqual(@as(u32, 2), sink.deltas);
}
