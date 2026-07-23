//! Organization / project spend limits, spend alerts, data retention,
//! hosted tool permissions, and model permissions.

const std = @import("std");
const errors = @import("../errors.zig");
const transport_mod = @import("../transport/http.zig");
const gen = @import("../generated/types.zig");
const common = @import("common.zig");

pub const CreateSpendAlertRequest = gen.CreateSpendAlertBody;
pub const UpdateOrganizationSpendLimitRequest = gen.UpdateOrganizationSpendLimitBody;
pub const UpdateProjectSpendLimitRequest = gen.UpdateProjectSpendLimitBody;
pub const UpdateOrganizationDataRetentionRequest = gen.UpdateOrganizationDataRetentionBody;
pub const UpdateProjectDataRetentionRequest = gen.UpdateProjectDataRetentionBody;
pub const UpdateProjectHostedToolPermissionsRequest = gen.ProjectHostedToolPermissionsUpdateRequest;
pub const UpdateProjectModelPermissionsRequest = gen.ProjectModelPermissionsUpdateRequest;

pub const Resource = struct {
    transport: *transport_mod.Transport,

    pub fn init(transport: *transport_mod.Transport) Resource {
        return .{ .transport = transport };
    }

    // --- Organization spend limit ---

    /// GET /organization/spend_limit
    pub fn get_organization_spend_limit(
        self: *const Resource,
        allocator: std.mem.Allocator,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendLimitResource) {
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .GET,
            "/organization/spend_limit",
            gen.OrganizationSpendLimitResource,
        );
    }

    /// POST /organization/spend_limit
    pub fn update_organization_spend_limit(
        self: *const Resource,
        allocator: std.mem.Allocator,
        req: UpdateOrganizationSpendLimitRequest,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendLimitResource) {
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            "/organization/spend_limit",
            req,
            gen.OrganizationSpendLimitResource,
        );
    }

    /// DELETE /organization/spend_limit
    pub fn delete_organization_spend_limit(
        self: *const Resource,
        allocator: std.mem.Allocator,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendLimitDeletedResource) {
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .DELETE,
            "/organization/spend_limit",
            gen.OrganizationSpendLimitDeletedResource,
        );
    }

    // --- Project spend limit ---

    /// GET /organization/projects/{project_id}/spend_limit
    pub fn get_project_spend_limit(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendLimitResource) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/projects/{s}/spend_limit", .{project_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(self.transport, allocator, .GET, path, gen.ProjectSpendLimitResource);
    }

    /// POST /organization/projects/{project_id}/spend_limit
    pub fn update_project_spend_limit(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        req: UpdateProjectSpendLimitRequest,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendLimitResource) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/projects/{s}/spend_limit", .{project_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.ProjectSpendLimitResource,
        );
    }

    /// DELETE /organization/projects/{project_id}/spend_limit
    pub fn delete_project_spend_limit(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendLimitDeletedResource) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/projects/{s}/spend_limit", .{project_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .DELETE,
            path,
            gen.ProjectSpendLimitDeletedResource,
        );
    }

    // --- Organization spend alerts ---

    /// GET /organization/spend_alerts
    pub fn list_organization_spend_alerts(
        self: *const Resource,
        allocator: std.mem.Allocator,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendAlertListResource) {
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .GET,
            "/organization/spend_alerts",
            gen.OrganizationSpendAlertListResource,
        );
    }

    /// POST /organization/spend_alerts
    pub fn create_organization_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        req: CreateSpendAlertRequest,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendAlert) {
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            "/organization/spend_alerts",
            req,
            gen.OrganizationSpendAlert,
        );
    }

    /// GET /organization/spend_alerts/{alert_id}
    pub fn retrieve_organization_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        alert_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendAlert) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/spend_alerts/{s}", .{alert_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(self.transport, allocator, .GET, path, gen.OrganizationSpendAlert);
    }

    /// POST /organization/spend_alerts/{alert_id}
    pub fn update_organization_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        alert_id: []const u8,
        req: CreateSpendAlertRequest,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendAlert) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/spend_alerts/{s}", .{alert_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.OrganizationSpendAlert,
        );
    }

    /// DELETE /organization/spend_alerts/{alert_id}
    pub fn delete_organization_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        alert_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.OrganizationSpendAlertDeletedResource) {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/spend_alerts/{s}", .{alert_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .DELETE,
            path,
            gen.OrganizationSpendAlertDeletedResource,
        );
    }

    // --- Project spend alerts ---

    /// GET /organization/projects/{project_id}/spend_alerts
    pub fn list_project_spend_alerts(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendAlertListResource) {
        var path_buf: [280]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/projects/{s}/spend_alerts", .{project_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(self.transport, allocator, .GET, path, gen.ProjectSpendAlertListResource);
    }

    /// POST /organization/projects/{project_id}/spend_alerts
    pub fn create_project_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        req: CreateSpendAlertRequest,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendAlert) {
        var path_buf: [280]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/projects/{s}/spend_alerts", .{project_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.ProjectSpendAlert,
        );
    }

    /// GET /organization/projects/{project_id}/spend_alerts/{alert_id}
    pub fn retrieve_project_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        alert_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendAlert) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/spend_alerts/{s}",
            .{ project_id, alert_id },
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(self.transport, allocator, .GET, path, gen.ProjectSpendAlert);
    }

    /// POST /organization/projects/{project_id}/spend_alerts/{alert_id}
    pub fn update_project_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        alert_id: []const u8,
        req: CreateSpendAlertRequest,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendAlert) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/spend_alerts/{s}",
            .{ project_id, alert_id },
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.ProjectSpendAlert,
        );
    }

    /// DELETE /organization/projects/{project_id}/spend_alerts/{alert_id}
    pub fn delete_project_spend_alert(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        alert_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectSpendAlertDeletedResource) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/spend_alerts/{s}",
            .{ project_id, alert_id },
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .DELETE,
            path,
            gen.ProjectSpendAlertDeletedResource,
        );
    }

    // --- Data retention ---

    /// GET /organization/data_retention
    pub fn get_organization_data_retention(
        self: *const Resource,
        allocator: std.mem.Allocator,
    ) errors.Error!std.json.Parsed(gen.OrganizationDataRetention) {
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .GET,
            "/organization/data_retention",
            gen.OrganizationDataRetention,
        );
    }

    /// POST /organization/data_retention
    pub fn update_organization_data_retention(
        self: *const Resource,
        allocator: std.mem.Allocator,
        req: UpdateOrganizationDataRetentionRequest,
    ) errors.Error!std.json.Parsed(gen.OrganizationDataRetention) {
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            "/organization/data_retention",
            req,
            gen.OrganizationDataRetention,
        );
    }

    /// GET /organization/projects/{project_id}/data_retention
    pub fn get_project_data_retention(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectDataRetention) {
        var path_buf: [280]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/projects/{s}/data_retention", .{project_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(self.transport, allocator, .GET, path, gen.ProjectDataRetention);
    }

    /// POST /organization/projects/{project_id}/data_retention
    pub fn update_project_data_retention(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        req: UpdateProjectDataRetentionRequest,
    ) errors.Error!std.json.Parsed(gen.ProjectDataRetention) {
        var path_buf: [280]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/organization/projects/{s}/data_retention", .{project_id}) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.ProjectDataRetention,
        );
    }

    // --- Hosted tool permissions ---

    /// GET /organization/projects/{project_id}/hosted_tool_permissions
    pub fn get_project_hosted_tool_permissions(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectHostedToolPermissions) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/hosted_tool_permissions",
            .{project_id},
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(self.transport, allocator, .GET, path, gen.ProjectHostedToolPermissions);
    }

    /// POST /organization/projects/{project_id}/hosted_tool_permissions
    pub fn update_project_hosted_tool_permissions(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        req: UpdateProjectHostedToolPermissionsRequest,
    ) errors.Error!std.json.Parsed(gen.ProjectHostedToolPermissions) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/hosted_tool_permissions",
            .{project_id},
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.ProjectHostedToolPermissions,
        );
    }

    // --- Model permissions ---

    /// GET /organization/projects/{project_id}/model_permissions
    pub fn get_project_model_permissions(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectModelPermissions) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/model_permissions",
            .{project_id},
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(self.transport, allocator, .GET, path, gen.ProjectModelPermissions);
    }

    /// POST /organization/projects/{project_id}/model_permissions
    pub fn update_project_model_permissions(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
        req: UpdateProjectModelPermissionsRequest,
    ) errors.Error!std.json.Parsed(gen.ProjectModelPermissions) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/model_permissions",
            .{project_id},
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendJsonTyped(
            self.transport,
            allocator,
            .POST,
            path,
            req,
            gen.ProjectModelPermissions,
        );
    }

    /// DELETE /organization/projects/{project_id}/model_permissions
    pub fn delete_project_model_permissions(
        self: *const Resource,
        allocator: std.mem.Allocator,
        project_id: []const u8,
    ) errors.Error!std.json.Parsed(gen.ProjectModelPermissionsDeleteResponse) {
        var path_buf: [320]u8 = undefined;
        const path = std.fmt.bufPrint(
            &path_buf,
            "/organization/projects/{s}/model_permissions",
            .{project_id},
        ) catch {
            return errors.Error.SerializeError;
        };
        return common.sendNoBodyTyped(
            self.transport,
            allocator,
            .DELETE,
            path,
            gen.ProjectModelPermissionsDeleteResponse,
        );
    }
};

test "spend resource surface" {
    try std.testing.expect(@hasDecl(Resource, "list_organization_spend_alerts"));
    try std.testing.expect(@hasDecl(Resource, "get_project_model_permissions"));
}
