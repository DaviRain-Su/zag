//! Skills API — create/list/get/delete skills and versions.
//! Spec paths: /skills, /skills/{id}, /skills/{id}/versions, ...

const std = @import("std");
const errors = @import("../errors.zig");
const transport_mod = @import("../transport/http.zig");
const gen = @import("../generated/types.zig");
const common = @import("common.zig");

pub const CreateSkillRequest = gen.CreateSkillBody;
pub const CreateSkillVersionRequest = gen.CreateSkillVersionBody;
pub const SetDefaultSkillVersionRequest = gen.SetDefaultSkillVersionBody;

pub const ListSkillsParams = struct {
    limit: ?u32 = null,
    order: ?[]const u8 = null,
    after: ?[]const u8 = null,
};

pub const ListSkillVersionsParams = struct {
    limit: ?u32 = null,
    order: ?[]const u8 = null,
    after: ?[]const u8 = null,
};

pub const BinaryResponse = struct {
    allocator: std.mem.Allocator,
    data: []u8,

    pub fn deinit(self: *BinaryResponse) void {
        self.allocator.free(self.data);
    }
};

pub const Resource = struct {
    transport: *transport_mod.Transport,

    pub fn init(transport: *transport_mod.Transport) Resource {
        return .{ .transport = transport };
    }

    fn appendListParams(writer: anytype, params: anytype, first: *bool) !void {
        if (@hasField(@TypeOf(params), "limit")) {
            if (params.limit) |limit| {
                try common.appendOptionalQueryParamU64(writer, first, "limit", @as(u64, limit));
            }
        }
        if (@hasField(@TypeOf(params), "order")) {
            try common.appendOptionalQueryParam(writer, first, "order", params.order);
        }
        if (@hasField(@TypeOf(params), "after")) {
            try common.appendOptionalQueryParam(writer, first, "after", params.after);
        }
    }

    /// GET /skills
    pub fn list(
        self: *const Resource,
        allocator: std.mem.Allocator,
        params: ListSkillsParams,
    ) errors.Error!std.json.Parsed(gen.SkillListResource) {
        return self.list_with_options(allocator, params, null);
    }

    pub fn list_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        params: ListSkillsParams,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.SkillListResource) {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.writeAll("/skills") catch return errors.Error.SerializeError;
        var first = true;
        appendListParams(&w, params, &first) catch return errors.Error.SerializeError;
        return common.sendNoBodyTypedWithOptions(
            self.transport,
            allocator,
            .GET,
            w.buffered(),
            gen.SkillListResource,
            request_opts,
        );
    }

    /// POST /skills
    pub fn create(
        self: *const Resource,
        allocator: std.mem.Allocator,
        req: CreateSkillRequest,
    ) errors.Error!std.json.Parsed(gen.SkillResource) {
        return self.create_with_options(allocator, req, null);
    }

    pub fn create_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        req: CreateSkillRequest,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.SkillResource) {
        return common.sendJsonTypedWithOptions(
            self.transport,
            allocator,
            .POST,
            "/skills",
            req,
            gen.SkillResource,
            request_opts,
        );
    }

    /// GET /skills/{skill_id}
    pub fn retrieve(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.SkillResource) {
        return self.retrieve_with_options(allocator, skill_id, null);
    }

    pub fn retrieve_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.SkillResource) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}", .{skill_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTypedWithOptions(
            self.transport,
            allocator,
            .GET,
            path,
            gen.SkillResource,
            request_opts,
        );
    }

    /// DELETE /skills/{skill_id}
    pub fn delete(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.DeletedSkillResource) {
        return self.delete_with_options(allocator, skill_id, null);
    }

    pub fn delete_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.DeletedSkillResource) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}", .{skill_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTypedWithOptions(
            self.transport,
            allocator,
            .DELETE,
            path,
            gen.DeletedSkillResource,
            request_opts,
        );
    }

    /// POST /skills/{skill_id} — set default version
    pub fn set_default_version(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        req: SetDefaultSkillVersionRequest,
    ) errors.Error!std.json.Parsed(gen.SkillResource) {
        return self.set_default_version_with_options(allocator, skill_id, req, null);
    }

    pub fn set_default_version_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        req: SetDefaultSkillVersionRequest,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.SkillResource) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}", .{skill_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTypedWithOptions(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.SkillResource,
            request_opts,
        );
    }

    /// GET /skills/{skill_id}/content (binary or text body)
    pub fn get_content(
        self: *const Resource,
        skill_id: []const u8,
    ) errors.Error!BinaryResponse {
        return self.get_content_with_options(skill_id, null);
    }

    pub fn get_content_with_options(
        self: *const Resource,
        skill_id: []const u8,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!BinaryResponse {
        var path_buf: [280]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}/content", .{skill_id}) catch {
            return errors.Error.SerializeError;
        };
        const body = try common.sendBinaryWithOptions(
            self.transport,
            .GET,
            path,
            &.{},
            null,
            request_opts,
        );
        return .{ .allocator = self.transport.allocator, .data = body };
    }

    /// GET /skills/{skill_id}/versions
    pub fn list_versions(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        params: ListSkillVersionsParams,
    ) errors.Error!std.json.Parsed(gen.SkillVersionListResource) {
        return self.list_versions_with_options(allocator, skill_id, params, null);
    }

    pub fn list_versions_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        params: ListSkillVersionsParams,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.SkillVersionListResource) {
        var buf: [320]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        w.print("/skills/{s}/versions", .{skill_id}) catch return errors.Error.SerializeError;
        var first = true;
        appendListParams(&w, params, &first) catch return errors.Error.SerializeError;
        return common.sendNoBodyTypedWithOptions(
            self.transport,
            allocator,
            .GET,
            w.buffered(),
            gen.SkillVersionListResource,
            request_opts,
        );
    }

    /// POST /skills/{skill_id}/versions
    pub fn create_version(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        req: CreateSkillVersionRequest,
    ) errors.Error!std.json.Parsed(gen.SkillVersionResource) {
        return self.create_version_with_options(allocator, skill_id, req, null);
    }

    pub fn create_version_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        req: CreateSkillVersionRequest,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.SkillVersionResource) {
        var path_buf: [280]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}/versions", .{skill_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTypedWithOptions(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.SkillVersionResource,
            request_opts,
        );
    }

    /// GET /skills/{skill_id}/versions/{version}
    pub fn retrieve_version(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        version: []const u8,
    ) errors.Error!std.json.Parsed(gen.SkillVersionResource) {
        return self.retrieve_version_with_options(allocator, skill_id, version, null);
    }

    pub fn retrieve_version_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        version: []const u8,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.SkillVersionResource) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}/versions/{s}", .{ skill_id, version }) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTypedWithOptions(
            self.transport,
            allocator,
            .GET,
            path,
            gen.SkillVersionResource,
            request_opts,
        );
    }

    /// DELETE /skills/{skill_id}/versions/{version}
    pub fn delete_version(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        version: []const u8,
    ) errors.Error!std.json.Parsed(gen.DeletedSkillVersionResource) {
        return self.delete_version_with_options(allocator, skill_id, version, null);
    }

    pub fn delete_version_with_options(
        self: *const Resource,
        allocator: std.mem.Allocator,
        skill_id: []const u8,
        version: []const u8,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!std.json.Parsed(gen.DeletedSkillVersionResource) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}/versions/{s}", .{ skill_id, version }) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTypedWithOptions(
            self.transport,
            allocator,
            .DELETE,
            path,
            gen.DeletedSkillVersionResource,
            request_opts,
        );
    }

    /// GET /skills/{skill_id}/versions/{version}/content
    pub fn get_version_content(
        self: *const Resource,
        skill_id: []const u8,
        version: []const u8,
    ) errors.Error!BinaryResponse {
        return self.get_version_content_with_options(skill_id, version, null);
    }

    pub fn get_version_content_with_options(
        self: *const Resource,
        skill_id: []const u8,
        version: []const u8,
        request_opts: ?transport_mod.Transport.RequestOptions,
    ) errors.Error!BinaryResponse {
        var path_buf: [360]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/skills/{s}/versions/{s}/content", .{ skill_id, version }) catch {
            return errors.Error.SerializeError;
        };
        const body = try common.sendBinaryWithOptions(
            self.transport,
            .GET,
            path,
            &.{},
            null,
            request_opts,
        );
        return .{ .allocator = self.transport.allocator, .data = body };
    }
};

test "skills list path encoding" {
    // Smoke: type names resolve at compile time.
    _ = @TypeOf(@as(gen.SkillResource, undefined));
    _ = @TypeOf(@as(gen.SkillListResource, undefined));
    try std.testing.expect(@hasDecl(Resource, "list"));
    try std.testing.expect(@hasDecl(Resource, "create_version"));
}
