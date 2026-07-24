//! Generated from OpenAPI — do not hand-edit core shapes.
//! Re-run: python3 tools/generate.py
const std = @import("std");

pub const FunctionParameters = union(enum) {
    schema: std.json.Value,
    raw: std.json.Value,

    pub fn forSchema(value: std.json.Value) FunctionParameters {
        return .{ .schema = value };
    }

    pub fn forRaw(value: std.json.Value) FunctionParameters {
        return .{ .raw = value };
    }

    pub fn asJson(self: FunctionParameters) std.json.Value {
        return switch (self) {
            .schema => |value| value,
            .raw => |value| value,
        };
    }

    pub fn jsonStringify(self: FunctionParameters, writer: anytype) !void {
        try writer.write(self.asJson());
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !FunctionParameters {
        const parsed = try std.json.Value.jsonParse(allocator, source, options);
        return jsonParseFromValue(allocator, parsed, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !FunctionParameters {
        _ = allocator;
        _ = options;
        return switch (source) {
            .object => .{ .schema = source },
            else => .{ .raw = source },
        };
    }
};

pub const ActiveStatus = struct {
    @"type": []const u8 = "",
};

pub const AddUploadPartRequest = struct {
    data: []const u8 = "",
};

pub const AdditionalTools = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    role: ?MessageRole = null,
    tools: []const Tool = &.{},
};

pub const AdditionalToolsItemParam = struct {
    id: ?std.json.Value = null,
    @"type": []const u8 = "",
    role: []const u8 = "",
    tools: []const Tool = &.{},
};

pub const AdminApiKey = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: ?std.json.Value = null,
    redacted_value: []const u8 = "",
    created_at: i64 = 0,
    expires_at: std.json.Value = .null,
    last_used_at: ?std.json.Value = null,
    owner: ?struct {
    @"type": ?[]const u8 = null,
    object: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    created_at: ?i64 = null,
    role: ?[]const u8 = null,
} = null,
};

pub const AdminApiKeyCreateResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: ?std.json.Value = null,
    redacted_value: []const u8 = "",
    created_at: i64 = 0,
    expires_at: std.json.Value = .null,
    last_used_at: ?std.json.Value = null,
    owner: ?struct {
    @"type": ?[]const u8 = null,
    object: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    created_at: ?i64 = null,
    role: ?[]const u8 = null,
} = null,
    value: []const u8 = "",
};

pub const Annotation = std.json.Value;

pub const ApiKeyList = struct {
    object: []const u8 = "",
    data: []const AdminApiKey = &.{},
    has_more: bool = false,
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
};

pub const ApplyPatchCallOutputStatus = []const u8;

pub const ApplyPatchCallOutputStatusParam = []const u8;

pub const ApplyPatchCallStatus = []const u8;

pub const ApplyPatchCallStatusParam = []const u8;

pub const ApplyPatchCreateFileOperation = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const ApplyPatchCreateFileOperationParam = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const ApplyPatchDeleteFileOperation = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
};

pub const ApplyPatchDeleteFileOperationParam = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
};

pub const ApplyPatchOperationParam = std.json.Value;

pub const ApplyPatchToolCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?ApplyPatchCallStatus = null,
    operation: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const ApplyPatchToolCallItemParam = struct {
    @"type": []const u8 = "",
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?ApplyPatchCallStatusParam = null,
    operation: ?ApplyPatchOperationParam = null,
};

pub const ApplyPatchToolCallOutput = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?ApplyPatchCallOutputStatus = null,
    output: ?std.json.Value = null,
    created_by: ?[]const u8 = null,
};

pub const ApplyPatchToolCallOutputItemParam = struct {
    @"type": []const u8 = "",
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?ApplyPatchCallOutputStatusParam = null,
    output: ?std.json.Value = null,
};

pub const ApplyPatchToolParam = struct {
    @"type": []const u8 = "",
    allowed_callers: ?std.json.Value = null,
};

pub const ApplyPatchUpdateFileOperation = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const ApplyPatchUpdateFileOperationParam = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const ApproximateLocation = struct {
    @"type": []const u8 = "",
    country: ?std.json.Value = null,
    region: ?std.json.Value = null,
    city: ?std.json.Value = null,
    timezone: ?std.json.Value = null,
};

pub const AssignedRoleDetails = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    permissions: []const []const u8 = &.{},
    resource_type: []const u8 = "",
    predefined_role: bool = false,
    description: std.json.Value = .null,
    created_at: std.json.Value = .null,
    updated_at: std.json.Value = .null,
    created_by: std.json.Value = .null,
    created_by_user_obj: std.json.Value = .null,
    metadata: std.json.Value = .null,
    assignment_sources: std.json.Value = .null,
};

pub const AssistantMessageItem = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    @"type": []const u8 = "",
    content: []const ResponseOutputText = &.{},
};

pub const AssistantObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    name: std.json.Value = .null,
    description: std.json.Value = .null,
    model: []const u8 = "",
    instructions: std.json.Value = .null,
    tools: []const AssistantToolsCode = &.{},
    tool_resources: ?std.json.Value = null,
    metadata: ?Metadata = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    response_format: ?std.json.Value = null,
};

pub const AssistantStreamEvent = std.json.Value;

pub const AssistantSupportedModels = []const u8;

pub const AssistantToolsCode = struct {
    @"type": []const u8 = "",
};

pub const AssistantToolsFileSearch = struct {
    @"type": []const u8 = "",
    file_search: ?struct {
    max_num_results: ?i64 = null,
    ranking_options: ?FileSearchRankingOptions = null,
} = null,
};

pub const AssistantToolsFileSearchTypeOnly = struct {
    @"type": []const u8 = "",
};

pub const AssistantToolsFunction = struct {
    @"type": []const u8 = "",
    function: ?FunctionObject = null,
};

pub const AssistantsApiResponseFormatOption = std.json.Value;

pub const AssistantsApiToolChoiceOption = std.json.Value;

pub const AssistantsNamedToolChoice = struct {
    @"type": []const u8 = "",
    function: ?struct {
    name: []const u8 = "",
} = null,
};

pub const Attachment = struct {
    @"type": ?AttachmentType = null,
    id: []const u8 = "",
    name: []const u8 = "",
    mime_type: []const u8 = "",
    preview_url: std.json.Value = .null,
};

pub const AttachmentType = []const u8;

pub const AudioResponseFormat = []const u8;

pub const AudioTranscription = struct {
    model: ?std.json.Value = null,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    delay: ?[]const u8 = null,
};

pub const AudioTranscriptionResponse = struct {
    model: ?std.json.Value = null,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
};

pub const AuditLog = struct {
    id: []const u8 = "",
    @"type": ?AuditLogEventType = null,
    effective_at: i64 = 0,
    project: ?struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
    actor: ?std.json.Value = null,
    api_key_created: ?struct {
    id: ?[]const u8 = null,
    data: ?struct {
    scopes: ?[]const []const u8 = null,
} = null,
} = null,
    api_key_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    scopes: ?[]const []const u8 = null,
} = null,
} = null,
    api_key_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    checkpoint_permission_created: ?struct {
    id: ?[]const u8 = null,
    data: ?struct {
    project_id: ?[]const u8 = null,
    fine_tuned_model_checkpoint: ?[]const u8 = null,
} = null,
} = null,
    checkpoint_permission_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    external_key_registered: ?struct {
    id: ?[]const u8 = null,
    data: ?std.json.Value = null,
} = null,
    external_key_removed: ?struct {
    id: ?[]const u8 = null,
} = null,
    group_created: ?struct {
    id: ?[]const u8 = null,
    data: ?struct {
    group_name: ?[]const u8 = null,
} = null,
} = null,
    group_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    group_name: ?[]const u8 = null,
} = null,
} = null,
    group_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    scim_enabled: ?struct {
    id: ?[]const u8 = null,
} = null,
    scim_disabled: ?struct {
    id: ?[]const u8 = null,
} = null,
    invite_sent: ?struct {
    id: ?[]const u8 = null,
    data: ?struct {
    email: ?[]const u8 = null,
    role: ?[]const u8 = null,
} = null,
} = null,
    invite_accepted: ?struct {
    id: ?[]const u8 = null,
} = null,
    invite_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    ip_allowlist_created: ?struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    allowed_ips: ?[]const []const u8 = null,
} = null,
    ip_allowlist_updated: ?struct {
    id: ?[]const u8 = null,
    allowed_ips: ?[]const []const u8 = null,
} = null,
    ip_allowlist_deleted: ?struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    allowed_ips: ?[]const []const u8 = null,
} = null,
    ip_allowlist_config_activated: ?struct {
    configs: ?[]const struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
} = null,
    ip_allowlist_config_deactivated: ?struct {
    configs: ?[]const struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
} = null,
    login_succeeded: ?std.json.Value = null,
    login_failed: ?struct {
    error_code: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
} = null,
    logout_succeeded: ?std.json.Value = null,
    logout_failed: ?struct {
    error_code: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
} = null,
    organization_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    name: ?[]const u8 = null,
    threads_ui_visibility: ?[]const u8 = null,
    usage_dashboard_visibility: ?[]const u8 = null,
    api_call_logging: ?[]const u8 = null,
    api_call_logging_project_ids: ?[]const u8 = null,
} = null,
} = null,
    project_created: ?struct {
    id: ?[]const u8 = null,
    data: ?struct {
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
} = null,
} = null,
    project_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    title: ?[]const u8 = null,
} = null,
} = null,
    project_archived: ?struct {
    id: ?[]const u8 = null,
} = null,
    project_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    rate_limit_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    max_requests_per_1_minute: ?i64 = null,
    max_tokens_per_1_minute: ?i64 = null,
    max_images_per_1_minute: ?i64 = null,
    max_audio_megabytes_per_1_minute: ?i64 = null,
    max_requests_per_1_day: ?i64 = null,
    batch_1_day_max_input_tokens: ?i64 = null,
} = null,
} = null,
    rate_limit_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    role_created: ?struct {
    id: ?[]const u8 = null,
    role_name: ?[]const u8 = null,
    permissions: ?[]const []const u8 = null,
    resource_type: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
} = null,
    role_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    role_name: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    permissions_added: ?[]const []const u8 = null,
    permissions_removed: ?[]const []const u8 = null,
    description: ?[]const u8 = null,
    metadata: ?std.json.Value = null,
} = null,
} = null,
    role_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    role_assignment_created: ?struct {
    id: ?[]const u8 = null,
    principal_id: ?[]const u8 = null,
    principal_type: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
} = null,
    role_assignment_deleted: ?struct {
    id: ?[]const u8 = null,
    principal_id: ?[]const u8 = null,
    principal_type: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
} = null,
    role_bound_to_resource: ?struct {
    id: ?[]const u8 = null,
    role_id: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    permissions: ?[]const []const u8 = null,
    workspace_id: ?[]const u8 = null,
    connector_id: ?[]const u8 = null,
    connector_name: ?[]const u8 = null,
    enabled: ?bool = null,
    source: ?[]const u8 = null,
} = null,
    role_unbound_from_resource: ?struct {
    id: ?[]const u8 = null,
    role_id: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    permissions: ?[]const []const u8 = null,
    workspace_id: ?[]const u8 = null,
    connector_id: ?[]const u8 = null,
    connector_name: ?[]const u8 = null,
    enabled: ?bool = null,
    source: ?[]const u8 = null,
} = null,
    service_account_created: ?struct {
    id: ?[]const u8 = null,
    data: ?struct {
    role: ?[]const u8 = null,
} = null,
} = null,
    service_account_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    role: ?[]const u8 = null,
} = null,
} = null,
    service_account_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    workload_identity_provider_created: ?struct {
    id: ?[]const u8 = null,
    data: ?std.json.Value = null,
} = null,
    workload_identity_provider_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?std.json.Value = null,
} = null,
    workload_identity_provider_deleted: ?struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
    workload_identity_provider_mapping_created: ?struct {
    id: ?[]const u8 = null,
    identity_provider_id: ?[]const u8 = null,
    data: ?std.json.Value = null,
} = null,
    workload_identity_provider_mapping_updated: ?struct {
    id: ?[]const u8 = null,
    identity_provider_id: ?[]const u8 = null,
    changes_requested: ?std.json.Value = null,
} = null,
    workload_identity_provider_mapping_deleted: ?struct {
    id: ?[]const u8 = null,
    identity_provider_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    service_account_id: ?[]const u8 = null,
} = null,
    user_added: ?struct {
    id: ?[]const u8 = null,
    data: ?struct {
    role: ?[]const u8 = null,
} = null,
} = null,
    user_updated: ?struct {
    id: ?[]const u8 = null,
    changes_requested: ?struct {
    role: ?[]const u8 = null,
} = null,
} = null,
    user_deleted: ?struct {
    id: ?[]const u8 = null,
} = null,
    certificate_created: ?struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
    certificate_updated: ?struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
    certificate_deleted: ?struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    certificate: ?[]const u8 = null,
} = null,
    certificates_activated: ?struct {
    certificates: ?[]const struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
} = null,
    certificates_deactivated: ?struct {
    certificates: ?[]const struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
} = null,
};

pub const AuditLogActor = struct {
    @"type": ?[]const u8 = null,
    session: ?AuditLogActorSession = null,
    api_key: ?AuditLogActorApiKey = null,
};

pub const AuditLogActorApiKey = struct {
    id: ?[]const u8 = null,
    @"type": ?[]const u8 = null,
    user: ?AuditLogActorUser = null,
    service_account: ?AuditLogActorServiceAccount = null,
};

pub const AuditLogActorServiceAccount = struct {
    id: ?[]const u8 = null,
};

pub const AuditLogActorSession = struct {
    user: ?AuditLogActorUser = null,
    ip_address: ?[]const u8 = null,
};

pub const AuditLogActorUser = struct {
    id: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const AuditLogEventType = []const u8;

pub const AutoChunkingStrategyRequestParam = struct {
    @"type": []const u8 = "",
};

pub const AutoCodeInterpreterToolParam = struct {
    @"type": []const u8 = "",
    file_ids: ?[]const []const u8 = null,
    memory_limit: ?std.json.Value = null,
    network_policy: ?std.json.Value = null,
};

pub const AutomaticThreadTitlingParam = struct {
    enabled: ?bool = null,
};

pub const Batch = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    endpoint: []const u8 = "",
    model: ?[]const u8 = null,
    errors: ?struct {
    object: ?[]const u8 = null,
    data: ?[]const BatchError = null,
} = null,
    input_file_id: []const u8 = "",
    completion_window: []const u8 = "",
    status: []const u8 = "",
    output_file_id: ?[]const u8 = null,
    error_file_id: ?[]const u8 = null,
    created_at: i64 = 0,
    in_progress_at: ?i64 = null,
    expires_at: ?i64 = null,
    finalizing_at: ?i64 = null,
    completed_at: ?i64 = null,
    failed_at: ?i64 = null,
    expired_at: ?i64 = null,
    cancelling_at: ?i64 = null,
    cancelled_at: ?i64 = null,
    request_counts: ?BatchRequestCounts = null,
    usage: ?struct {
    input_tokens: i64 = 0,
    input_tokens_details: ?struct {
    cached_tokens: i64 = 0,
} = null,
    output_tokens: i64 = 0,
    output_tokens_details: ?struct {
    reasoning_tokens: i64 = 0,
} = null,
    total_tokens: i64 = 0,
} = null,
    metadata: ?Metadata = null,
};

pub const BatchError = struct {
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    param: ?std.json.Value = null,
    line: ?std.json.Value = null,
};

pub const BatchFileExpirationAfter = struct {
    anchor: []const u8 = "",
    seconds: i64 = 0,
};

pub const BatchRequestCounts = struct {
    total: i64 = 0,
    completed: i64 = 0,
    failed: i64 = 0,
};

pub const BetaAdditionalTools = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    role: ?BetaMessageRole = null,
    tools: []const BetaTool = &.{},
};

pub const BetaAdditionalToolsItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    @"type": []const u8 = "",
    role: []const u8 = "",
    tools: []const BetaTool = &.{},
};

pub const BetaAgentMessage = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    author: []const u8 = "",
    recipient: []const u8 = "",
    content: []const BetaInputTextContent = &.{},
};

pub const BetaAgentMessageItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    @"type": []const u8 = "",
    author: []const u8 = "",
    recipient: []const u8 = "",
    content: []const BetaInputTextContentParam = &.{},
};

pub const BetaAgentTag = struct {
    agent_name: []const u8 = "",
};

pub const BetaAnnotation = std.json.Value;

pub const BetaApplyPatchCallOutputStatus = []const u8;

pub const BetaApplyPatchCallOutputStatusParam = []const u8;

pub const BetaApplyPatchCallStatus = []const u8;

pub const BetaApplyPatchCallStatusParam = []const u8;

pub const BetaApplyPatchCreateFileOperation = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const BetaApplyPatchCreateFileOperationParam = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const BetaApplyPatchDeleteFileOperation = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
};

pub const BetaApplyPatchDeleteFileOperationParam = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
};

pub const BetaApplyPatchOperationParam = std.json.Value;

pub const BetaApplyPatchToolCall = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?BetaApplyPatchCallStatus = null,
    operation: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const BetaApplyPatchToolCallItemParam = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?BetaApplyPatchCallStatusParam = null,
    operation: ?BetaApplyPatchOperationParam = null,
};

pub const BetaApplyPatchToolCallOutput = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?BetaApplyPatchCallOutputStatus = null,
    output: ?std.json.Value = null,
    created_by: ?[]const u8 = null,
};

pub const BetaApplyPatchToolCallOutputItemParam = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?BetaApplyPatchCallOutputStatusParam = null,
    output: ?std.json.Value = null,
};

pub const BetaApplyPatchToolParam = struct {
    @"type": []const u8 = "",
    allowed_callers: ?std.json.Value = null,
};

pub const BetaApplyPatchUpdateFileOperation = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const BetaApplyPatchUpdateFileOperationParam = struct {
    @"type": []const u8 = "",
    path: []const u8 = "",
    diff: []const u8 = "",
};

pub const BetaApproximateLocation = struct {
    @"type": []const u8 = "",
    country: ?std.json.Value = null,
    region: ?std.json.Value = null,
    city: ?std.json.Value = null,
    timezone: ?std.json.Value = null,
};

pub const BetaAutoCodeInterpreterToolParam = struct {
    @"type": []const u8 = "",
    file_ids: ?[]const []const u8 = null,
    memory_limit: ?std.json.Value = null,
    network_policy: ?std.json.Value = null,
};

pub const BetaCallableToolAllowedCaller = []const u8;

pub const BetaClickButtonType = []const u8;

pub const BetaClickParam = struct {
    @"type": []const u8 = "",
    button: ?BetaClickButtonType = null,
    x: i64 = 0,
    y: i64 = 0,
    keys: ?std.json.Value = null,
};

pub const BetaCodeInterpreterOutputImage = struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
};

pub const BetaCodeInterpreterOutputLogs = struct {
    @"type": []const u8 = "",
    logs: []const u8 = "",
};

pub const BetaCodeInterpreterTool = struct {
    @"type": []const u8 = "",
    container: std.json.Value = .null,
    allowed_callers: ?std.json.Value = null,
};

pub const BetaCodeInterpreterToolCall = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    status: []const u8 = "",
    container_id: []const u8 = "",
    code: std.json.Value = .null,
    outputs: std.json.Value = .null,
};

pub const BetaCompactResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    output: []const BetaItemField = &.{},
    created_at: i64 = 0,
    usage: ?BetaResponseUsage = null,
};

pub const BetaCompactResponseMethodPublicBody = struct {
    model: ?BetaModelIdsCompaction = null,
    input: ?std.json.Value = null,
    previous_response_id: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?std.json.Value = null,
    service_tier: ?std.json.Value = null,
};

pub const BetaCompactionBody = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    encrypted_content: []const u8 = "",
    created_by: ?[]const u8 = null,
};

pub const BetaCompactionSummaryItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    @"type": []const u8 = "",
    encrypted_content: []const u8 = "",
};

pub const BetaCompactionTriggerItemParam = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
};

pub const BetaComparisonFilter = struct {
    @"type": []const u8 = "",
    key: []const u8 = "",
    value: std.json.Value = .null,
};

pub const BetaCompoundFilter = struct {
    @"type": []const u8 = "",
    filters: []const BetaComparisonFilter = &.{},
};

pub const BetaComputerAction = std.json.Value;

pub const BetaComputerActionList = []const BetaComputerAction;

pub const BetaComputerCallOutputItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    @"type": []const u8 = "",
    output: ?BetaComputerScreenshotImage = null,
    acknowledged_safety_checks: ?std.json.Value = null,
    status: ?std.json.Value = null,
};

pub const BetaComputerCallOutputStatus = []const u8;

pub const BetaComputerCallSafetyCheckParam = struct {
    id: []const u8 = "",
    code: ?std.json.Value = null,
    message: ?std.json.Value = null,
};

pub const BetaComputerEnvironment = []const u8;

pub const BetaComputerScreenshotContent = struct {
    @"type": []const u8 = "",
    image_url: std.json.Value = .null,
    file_id: std.json.Value = .null,
    detail: ?BetaImageDetail = null,
    prompt_cache_breakpoint: ?BetaPromptCacheBreakpointConfig = null,
};

pub const BetaComputerScreenshotImage = struct {
    @"type": []const u8 = "",
    image_url: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
};

pub const BetaComputerTool = struct {
    @"type": []const u8 = "",
};

pub const BetaComputerToolCall = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    action: ?BetaComputerAction = null,
    actions: ?BetaComputerActionList = null,
    pending_safety_checks: []const BetaComputerCallSafetyCheckParam = &.{},
    status: []const u8 = "",
};

pub const BetaComputerToolCallOutput = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: ?[]const u8 = null,
    call_id: []const u8 = "",
    acknowledged_safety_checks: ?[]const BetaComputerCallSafetyCheckParam = null,
    output: ?BetaComputerScreenshotImage = null,
    status: ?[]const u8 = null,
};

pub const BetaComputerToolCallOutputResource = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    acknowledged_safety_checks: ?[]const BetaComputerCallSafetyCheckParam = null,
    output: ?BetaComputerScreenshotImage = null,
    status: ?BetaComputerCallOutputStatus = null,
    created_by: ?[]const u8 = null,
};

pub const BetaComputerUsePreviewTool = struct {
    @"type": []const u8 = "",
    environment: ?BetaComputerEnvironment = null,
    display_width: i64 = 0,
    display_height: i64 = 0,
};

pub const BetaContainerAutoParam = struct {
    @"type": []const u8 = "",
    file_ids: ?[]const []const u8 = null,
    memory_limit: ?std.json.Value = null,
    network_policy: ?std.json.Value = null,
    skills: ?[]const BetaSkillReferenceParam = null,
};

pub const BetaContainerFileCitationBody = struct {
    @"type": []const u8 = "",
    container_id: []const u8 = "",
    file_id: []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    filename: []const u8 = "",
};

pub const BetaContainerFileCitationParam = struct {
    @"type": []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    container_id: []const u8 = "",
    file_id: []const u8 = "",
    filename: []const u8 = "",
};

pub const BetaContainerMemoryLimit = []const u8;

pub const BetaContainerNetworkPolicyAllowlistParam = struct {
    @"type": []const u8 = "",
    allowed_domains: []const []const u8 = &.{},
    domain_secrets: ?[]const BetaContainerNetworkPolicyDomainSecretParam = null,
};

pub const BetaContainerNetworkPolicyDisabledParam = struct {
    @"type": []const u8 = "",
};

pub const BetaContainerNetworkPolicyDomainSecretParam = struct {
    domain: []const u8 = "",
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const BetaContainerReferenceParam = struct {
    @"type": []const u8 = "",
    container_id: []const u8 = "",
};

pub const BetaContainerReferenceResource = struct {
    @"type": []const u8 = "",
    container_id: []const u8 = "",
};

pub const BetaContent = std.json.Value;

pub const BetaContextManagementParam = struct {
    @"type": []const u8 = "",
    compact_threshold: ?std.json.Value = null,
};

pub const BetaConversation_2 = struct {
    id: []const u8 = "",
};

pub const BetaConversationParam = std.json.Value;

pub const BetaConversationParam_2 = struct {
    id: []const u8 = "",
};

pub const BetaCoordParam = struct {
    x: i64 = 0,
    y: i64 = 0,
};

pub const BetaCreateModelResponseProperties = struct {
    metadata: ?BetaMetadata = null,
    top_logprobs: ?i64 = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?BetaServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?BetaPromptCacheOptionsParam = null,
};

pub const BetaCreateResponse = struct {
    metadata: ?BetaMetadata = null,
    top_logprobs: ?i64 = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?BetaServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?BetaPromptCacheOptionsParam = null,
    previous_response_id: ?std.json.Value = null,
    model: ?BetaModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?BetaResponseTextParam = null,
    tools: ?BetaToolsArray = null,
    tool_choice: ?BetaToolChoiceParam = null,
    prompt: ?BetaPrompt = null,
    truncation: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    input: ?BetaInputParam = null,
    include: ?std.json.Value = null,
    parallel_tool_calls: ?std.json.Value = null,
    store: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    moderation: ?std.json.Value = null,
    stream: ?std.json.Value = null,
    stream_options: ?BetaResponseStreamOptions = null,
    conversation: ?std.json.Value = null,
    context_management: ?std.json.Value = null,
    max_output_tokens: ?std.json.Value = null,
    multi_agent: ?std.json.Value = null,
};

pub const BetaCustomGrammarFormatParam = struct {
    @"type": []const u8 = "",
    syntax: ?BetaGrammarSyntax1 = null,
    definition: []const u8 = "",
};

pub const BetaCustomTextFormatParam = struct {
    @"type": []const u8 = "",
};

pub const BetaCustomToolCall = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: ?[]const u8 = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    input: []const u8 = "",
};

pub const BetaCustomToolCallOutput = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: ?[]const u8 = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
};

pub const BetaCustomToolCallOutputResource = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
    status: ?BetaFunctionCallOutputStatusEnum = null,
    created_by: ?[]const u8 = null,
};

pub const BetaCustomToolCallResource = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    input: []const u8 = "",
    status: ?BetaFunctionCallStatus = null,
    created_by: ?[]const u8 = null,
};

pub const BetaCustomToolParam = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: ?[]const u8 = null,
    format: ?std.json.Value = null,
    defer_loading: ?bool = null,
    allowed_callers: ?std.json.Value = null,
};

pub const BetaDetailEnum = []const u8;

pub const BetaDirectToolCallCaller = struct {
    @"type": []const u8 = "",
};

pub const BetaDirectToolCallCallerParam = struct {
    @"type": []const u8 = "",
};

pub const BetaDoubleClickAction = struct {
    @"type": []const u8 = "",
    x: i64 = 0,
    y: i64 = 0,
    keys: std.json.Value = .null,
};

pub const BetaDragParam = struct {
    @"type": []const u8 = "",
    path: []const BetaCoordParam = &.{},
    keys: ?std.json.Value = null,
};

pub const BetaEasyInputMessage = struct {
    role: []const u8 = "",
    content: []const u8 = "",
    phase: ?std.json.Value = null,
    @"type": ?[]const u8 = null,
};

pub const BetaEmptyModelParam = std.json.Value;

pub const BetaEncryptedContent = struct {
    @"type": []const u8 = "",
    encrypted_content: []const u8 = "",
};

pub const BetaEncryptedContentParam = struct {
    @"type": []const u8 = "",
    encrypted_content: []const u8 = "",
};

pub const BetaError = struct {
    code: std.json.Value = .null,
    message: []const u8 = "",
    param: std.json.Value = .null,
    @"type": []const u8 = "",
};

pub const BetaFileCitationBody = struct {
    @"type": []const u8 = "",
    file_id: []const u8 = "",
    index: i64 = 0,
    filename: []const u8 = "",
};

pub const BetaFileCitationParam = struct {
    @"type": []const u8 = "",
    index: i64 = 0,
    file_id: []const u8 = "",
    filename: []const u8 = "",
};

pub const BetaFileDetailEnum = []const u8;

pub const BetaFileInputDetail = []const u8;

pub const BetaFilePath = struct {
    @"type": []const u8 = "",
    file_id: []const u8 = "",
    index: i64 = 0,
};

pub const BetaFileSearchTool = struct {
    @"type": []const u8 = "",
    vector_store_ids: []const []const u8 = &.{},
    max_num_results: ?i64 = null,
    ranking_options: ?BetaRankingOptions = null,
    filters: ?std.json.Value = null,
};

pub const BetaFileSearchToolCall = struct {
    agent: ?std.json.Value = null,
    id: []const u8 = "",
    @"type": []const u8 = "",
    status: []const u8 = "",
    queries: []const []const u8 = &.{},
    results: ?std.json.Value = null,
};

pub const BetaFilters = std.json.Value;

pub const BetaFunctionAndCustomToolCallOutput = std.json.Value;

pub const BetaFunctionCallItemStatus = []const u8;

pub const BetaFunctionCallOutputItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    @"type": []const u8 = "",
    output: std.json.Value = .null,
    caller: ?std.json.Value = null,
    status: ?std.json.Value = null,
};

pub const BetaFunctionCallOutputStatusEnum = []const u8;

pub const BetaFunctionCallStatus = []const u8;

pub const BetaFunctionShellAction = struct {
    commands: []const []const u8 = &.{},
    timeout_ms: std.json.Value = .null,
    max_output_length: std.json.Value = .null,
};

pub const BetaFunctionShellActionParam = struct {
    commands: []const []const u8 = &.{},
    timeout_ms: ?std.json.Value = null,
    max_output_length: ?std.json.Value = null,
};

pub const BetaFunctionShellCall = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    action: ?BetaFunctionShellAction = null,
    status: ?BetaFunctionShellCallStatus = null,
    environment: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const BetaFunctionShellCallItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    @"type": []const u8 = "",
    action: ?BetaFunctionShellActionParam = null,
    status: ?std.json.Value = null,
    environment: ?std.json.Value = null,
};

pub const BetaFunctionShellCallItemStatus = []const u8;

pub const BetaFunctionShellCallOutput = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?BetaFunctionShellCallOutputStatusEnum = null,
    output: []const BetaFunctionShellCallOutputContent = &.{},
    max_output_length: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const BetaFunctionShellCallOutputContent = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    outcome: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const BetaFunctionShellCallOutputContentParam = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    outcome: ?BetaFunctionShellCallOutputOutcomeParam = null,
};

pub const BetaFunctionShellCallOutputExitOutcome = struct {
    @"type": []const u8 = "",
    exit_code: i64 = 0,
};

pub const BetaFunctionShellCallOutputExitOutcomeParam = struct {
    @"type": []const u8 = "",
    exit_code: i64 = 0,
};

pub const BetaFunctionShellCallOutputItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    @"type": []const u8 = "",
    output: []const BetaFunctionShellCallOutputContentParam = &.{},
    status: ?std.json.Value = null,
    max_output_length: ?std.json.Value = null,
};

pub const BetaFunctionShellCallOutputOutcomeParam = std.json.Value;

pub const BetaFunctionShellCallOutputStatusEnum = []const u8;

pub const BetaFunctionShellCallOutputTimeoutOutcome = struct {
    @"type": []const u8 = "",
};

pub const BetaFunctionShellCallOutputTimeoutOutcomeParam = struct {
    @"type": []const u8 = "",
};

pub const BetaFunctionShellCallStatus = []const u8;

pub const BetaFunctionShellToolParam = struct {
    @"type": []const u8 = "",
    environment: ?std.json.Value = null,
    allowed_callers: ?std.json.Value = null,
};

pub const BetaFunctionTool = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: ?std.json.Value = null,
    parameters: std.json.Value = .null,
    output_schema: ?std.json.Value = null,
    strict: std.json.Value = .null,
    defer_loading: ?bool = null,
    allowed_callers: ?std.json.Value = null,
};

pub const BetaFunctionToolCall = struct {
    agent: ?std.json.Value = null,
    id: ?[]const u8 = null,
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    arguments: []const u8 = "",
    status: ?[]const u8 = null,
};

pub const BetaFunctionToolCallOutput = struct {
    agent: ?std.json.Value = null,
    id: ?[]const u8 = null,
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
    status: ?[]const u8 = null,
};

pub const BetaFunctionToolCallOutputResource = struct {
    agent: ?std.json.Value = null,
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
    status: ?BetaFunctionCallOutputStatusEnum = null,
    created_by: ?[]const u8 = null,
};

pub const BetaFunctionToolCallResource = struct {
    agent: ?std.json.Value = null,
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    arguments: []const u8 = "",
    status: ?BetaFunctionCallStatus = null,
    created_by: ?[]const u8 = null,
};

pub const BetaFunctionToolParam = struct {
    name: []const u8 = "",
    description: ?std.json.Value = null,
    parameters: ?std.json.Value = null,
    strict: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_schema: ?std.json.Value = null,
    defer_loading: ?bool = null,
    allowed_callers: ?std.json.Value = null,
};

pub const BetaGrammarSyntax1 = []const u8;

pub const BetaHybridSearchOptions = struct {
    embedding_weight: f64 = 0,
    text_weight: f64 = 0,
};

pub const BetaImageDetail = []const u8;

pub const BetaImageGenActionEnum = []const u8;

pub const BetaImageGenTool = struct {
    @"type": []const u8 = "",
    model: ?std.json.Value = null,
    quality: ?[]const u8 = null,
    size: ?std.json.Value = null,
    output_format: ?[]const u8 = null,
    output_compression: ?i64 = null,
    moderation: ?[]const u8 = null,
    background: ?[]const u8 = null,
    input_fidelity: ?std.json.Value = null,
    input_image_mask: ?struct {
    image_url: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
} = null,
    partial_images: ?i64 = null,
    action: ?BetaImageGenActionEnum = null,
};

pub const BetaImageGenToolCall = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    status: []const u8 = "",
    result: std.json.Value = .null,
};

pub const BetaIncludeEnum = []const u8;

pub const BetaInlineSkillParam = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    source: ?BetaInlineSkillSourceParam = null,
};

pub const BetaInlineSkillSourceParam = struct {
    @"type": []const u8 = "",
    media_type: []const u8 = "",
    data: []const u8 = "",
};

pub const BetaInputAudio = struct {
    @"type": []const u8 = "",
    input_audio: ?struct {
    data: []const u8 = "",
    format: []const u8 = "",
} = null,
};

pub const BetaInputContent = std.json.Value;

pub const BetaInputFidelity = []const u8;

pub const BetaInputFileContent = struct {
    @"type": []const u8 = "",
    file_id: ?std.json.Value = null,
    filename: ?[]const u8 = null,
    file_data: ?[]const u8 = null,
    prompt_cache_breakpoint: ?BetaPromptCacheBreakpointConfig = null,
    file_url: ?[]const u8 = null,
    detail: ?BetaFileInputDetail = null,
};

pub const BetaInputFileContentParam = struct {
    @"type": []const u8 = "",
    file_id: ?std.json.Value = null,
    filename: ?std.json.Value = null,
    file_data: ?std.json.Value = null,
    file_url: ?std.json.Value = null,
    detail: ?BetaFileDetailEnum = null,
    prompt_cache_breakpoint: ?std.json.Value = null,
};

pub const BetaInputImageContent = struct {
    @"type": []const u8 = "",
    image_url: ?std.json.Value = null,
    file_id: ?std.json.Value = null,
    detail: ?BetaImageDetail = null,
    prompt_cache_breakpoint: ?BetaPromptCacheBreakpointConfig = null,
};

pub const BetaInputImageContentParamAutoParam = struct {
    @"type": []const u8 = "",
    image_url: ?std.json.Value = null,
    file_id: ?std.json.Value = null,
    detail: ?std.json.Value = null,
    prompt_cache_breakpoint: ?std.json.Value = null,
};

pub const BetaInputItem = std.json.Value;

pub const BetaInputMessage = struct {
    agent: ?std.json.Value = null,
    @"type": ?[]const u8 = null,
    role: []const u8 = "",
    status: ?[]const u8 = null,
    content: ?BetaInputMessageContentList = null,
};

pub const BetaInputMessageContentList = []const BetaInputContent;

pub const BetaInputMessageResource = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    role: []const u8 = "",
    status: ?[]const u8 = null,
    content: ?BetaInputMessageContentList = null,
    id: []const u8 = "",
};

pub const BetaInputParam = std.json.Value;

pub const BetaInputTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    prompt_cache_breakpoint: ?BetaPromptCacheBreakpointConfig = null,
};

pub const BetaInputTextContentParam = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    prompt_cache_breakpoint: ?std.json.Value = null,
};

pub const BetaItem = std.json.Value;

pub const BetaItemField = std.json.Value;

pub const BetaItemReferenceParam = struct {
    agent: ?std.json.Value = null,
    @"type": ?std.json.Value = null,
    id: []const u8 = "",
};

pub const BetaItemResource = std.json.Value;

pub const BetaKeyPressAction = struct {
    @"type": []const u8 = "",
    keys: []const []const u8 = &.{},
};

pub const BetaLocalEnvironmentParam = struct {
    @"type": []const u8 = "",
    skills: ?[]const BetaLocalSkillParam = null,
};

pub const BetaLocalEnvironmentResource = struct {
    @"type": []const u8 = "",
};

pub const BetaLocalShellExecAction = struct {
    @"type": []const u8 = "",
    command: []const []const u8 = &.{},
    timeout_ms: ?std.json.Value = null,
    working_directory: ?std.json.Value = null,
    env: std.json.Value = .null,
    user: ?std.json.Value = null,
};

pub const BetaLocalShellToolCall = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    action: ?BetaLocalShellExecAction = null,
    status: []const u8 = "",
};

pub const BetaLocalShellToolCallOutput = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    output: []const u8 = "",
    status: ?std.json.Value = null,
};

pub const BetaLocalShellToolParam = struct {
    @"type": []const u8 = "",
};

pub const BetaLocalSkillParam = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    path: []const u8 = "",
};

pub const BetaLogProb = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: []const i64 = &.{},
    top_logprobs: []const BetaTopLogProb = &.{},
};

pub const BetaMCPApprovalRequest = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};

pub const BetaMCPApprovalResponse = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: ?std.json.Value = null,
    approval_request_id: []const u8 = "",
    approve: bool = false,
    reason: ?std.json.Value = null,
};

pub const BetaMCPApprovalResponseResource = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    approval_request_id: []const u8 = "",
    approve: bool = false,
    reason: ?std.json.Value = null,
};

pub const BetaMCPListTools = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    tools: []const BetaMCPListToolsTool = &.{},
    @"error": ?std.json.Value = null,
};

pub const BetaMCPListToolsTool = struct {
    name: []const u8 = "",
    description: ?std.json.Value = null,
    input_schema: std.json.Value = .null,
    annotations: ?std.json.Value = null,
};

pub const BetaMCPTool = struct {
    @"type": []const u8 = "",
    server_label: []const u8 = "",
    server_url: ?[]const u8 = null,
    connector_id: ?[]const u8 = null,
    tunnel_id: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    server_description: ?[]const u8 = null,
    headers: ?std.json.Value = null,
    allowed_tools: ?std.json.Value = null,
    allowed_callers: ?std.json.Value = null,
    require_approval: ?std.json.Value = null,
    defer_loading: ?bool = null,
};

pub const BetaMCPToolCall = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
    output: ?std.json.Value = null,
    @"error": ?std.json.Value = null,
    status: ?BetaMCPToolCallStatus = null,
    approval_request_id: ?std.json.Value = null,
};

pub const BetaMCPToolCallStatus = []const u8;

pub const BetaMCPToolFilter = struct {
    tool_names: ?[]const []const u8 = null,
    read_only: ?bool = null,
};

pub const BetaMessage = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    status: ?BetaMessageStatus = null,
    role: ?BetaMessageRole = null,
    content: []const BetaInputTextContent = &.{},
    phase: ?std.json.Value = null,
};

pub const BetaMessagePhase = []const u8;

pub const BetaMessagePhase_2 = []const u8;

pub const BetaMessageRole = []const u8;

pub const BetaMessageStatus = []const u8;

pub const BetaMetadata = std.json.Value;

pub const BetaModelIdsCompaction = std.json.Value;

pub const BetaModelIdsResponses = std.json.Value;

pub const BetaModelIdsShared = std.json.Value;

pub const BetaModelResponseProperties = struct {
    metadata: ?BetaMetadata = null,
    top_logprobs: ?std.json.Value = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?BetaServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
};

pub const BetaModeration = struct {
    input: std.json.Value = .null,
    output: std.json.Value = .null,
};

pub const BetaModerationConfigParam = struct {
    mode: ?BetaModerationMode = null,
};

pub const BetaModerationErrorBody = struct {
    @"type": []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
};

pub const BetaModerationInputType = []const u8;

pub const BetaModerationMode = []const u8;

pub const BetaModerationParam = struct {
    model: []const u8 = "",
    policy: ?std.json.Value = null,
};

pub const BetaModerationPolicyParam = struct {
    input: ?std.json.Value = null,
    output: ?std.json.Value = null,
};

pub const BetaModerationResultBody = struct {
    @"type": []const u8 = "",
    model: []const u8 = "",
    flagged: bool = false,
    categories: std.json.Value = .null,
    category_scores: std.json.Value = .null,
    category_applied_input_types: std.json.Value = .null,
};

pub const BetaMoveParam = struct {
    @"type": []const u8 = "",
    x: i64 = 0,
    y: i64 = 0,
    keys: ?std.json.Value = null,
};

pub const BetaMultiAgentAction = []const u8;

pub const BetaMultiAgentAction1 = []const u8;

pub const BetaMultiAgentCall = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    action: ?BetaMultiAgentAction = null,
    arguments: []const u8 = "",
};

pub const BetaMultiAgentCallItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    @"type": []const u8 = "",
    action: ?BetaMultiAgentAction1 = null,
    arguments: []const u8 = "",
};

pub const BetaMultiAgentCallOutput = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    action: ?BetaMultiAgentAction = null,
    output: []const BetaOutputTextContent = &.{},
};

pub const BetaMultiAgentCallOutputItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    @"type": []const u8 = "",
    action: ?BetaMultiAgentAction1 = null,
    output: []const BetaOutputTextContentParam = &.{},
};

pub const BetaMultiAgentParam = struct {
    enabled: bool = false,
    max_concurrent_subagents: ?i64 = null,
};

pub const BetaNamespaceToolParam = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    tools: []const BetaFunctionToolParam = &.{},
};

pub const BetaOutputAudio = struct {
    @"type": []const u8 = "",
    data: []const u8 = "",
    transcript: []const u8 = "",
};

pub const BetaOutputContent = std.json.Value;

pub const BetaOutputItem = std.json.Value;

pub const BetaOutputMessage = struct {
    agent: ?std.json.Value = null,
    id: []const u8 = "",
    @"type": []const u8 = "",
    role: []const u8 = "",
    content: []const BetaOutputMessageContent = &.{},
    phase: ?std.json.Value = null,
    status: []const u8 = "",
};

pub const BetaOutputMessageContent = std.json.Value;

pub const BetaOutputTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    annotations: []const BetaAnnotation = &.{},
    logprobs: []const BetaLogProb = &.{},
};

pub const BetaOutputTextContentParam = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    annotations: ?[]const BetaFileCitationParam = null,
};

pub const BetaPersonalityEnum = std.json.Value;

pub const BetaProgram = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    code: []const u8 = "",
    fingerprint: []const u8 = "",
};

pub const BetaProgramItemParam = struct {
    agent: ?std.json.Value = null,
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    code: []const u8 = "",
    fingerprint: []const u8 = "",
};

pub const BetaProgramOutput = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    result: []const u8 = "",
    status: ?BetaProgramOutputStatus = null,
};

pub const BetaProgramOutputItemParam = struct {
    agent: ?std.json.Value = null,
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    result: []const u8 = "",
    status: ?BetaProgramOutputItemStatus = null,
};

pub const BetaProgramOutputItemStatus = []const u8;

pub const BetaProgramOutputStatus = []const u8;

pub const BetaProgramToolCallCaller = struct {
    @"type": []const u8 = "",
    caller_id: []const u8 = "",
};

pub const BetaProgramToolCallCallerParam = struct {
    @"type": []const u8 = "",
    caller_id: []const u8 = "",
};

pub const BetaProgrammaticToolCallingParam = struct {
    @"type": []const u8 = "",
};

pub const BetaPrompt = std.json.Value;

pub const BetaPromptCacheBreakpointConfig = struct {
    mode: []const u8 = "",
};

pub const BetaPromptCacheBreakpointParam = struct {
    mode: []const u8 = "",
};

pub const BetaPromptCacheModeEnum = []const u8;

pub const BetaPromptCacheOptions = struct {
    ttl: ?BetaPromptCacheTTLEnum = null,
    mode: ?BetaPromptCacheModeEnum = null,
};

pub const BetaPromptCacheOptionsParam = struct {
    ttl: ?BetaPromptCacheTTLEnum = null,
    mode: ?BetaPromptCacheModeEnum = null,
};

pub const BetaPromptCacheRetentionEnum = []const u8;

pub const BetaPromptCacheTTLEnum = []const u8;

pub const BetaRankerVersionType = []const u8;

pub const BetaRankingOptions = struct {
    ranker: ?BetaRankerVersionType = null,
    score_threshold: ?f64 = null,
    hybrid_search: ?BetaHybridSearchOptions = null,
};

pub const BetaReasoning = struct {
    mode: ?BetaReasoningModeEnum = null,
    effort: ?BetaReasoningEffort = null,
    summary: ?std.json.Value = null,
    context: ?std.json.Value = null,
    generate_summary: ?std.json.Value = null,
};

pub const BetaReasoningEffort = std.json.Value;

pub const BetaReasoningItem = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    encrypted_content: ?[]const u8 = null,
    summary: []const BetaSummaryTextContent = &.{},
    content: ?[]const BetaReasoningTextContent = null,
    status: ?[]const u8 = null,
};

pub const BetaReasoningModeEnum = std.json.Value;

pub const BetaReasoningTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const BetaRefusalContent = struct {
    @"type": []const u8 = "",
    refusal: []const u8 = "",
};

pub const BetaResponse = struct {
    metadata: ?BetaMetadata = null,
    top_logprobs: ?std.json.Value = null,
    temperature: std.json.Value = .null,
    top_p: std.json.Value = .null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?BetaServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    previous_response_id: ?std.json.Value = null,
    model: ?BetaModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?BetaResponseTextParam = null,
    tools: ?BetaToolsArray = null,
    tool_choice: ?BetaToolChoiceParam = null,
    prompt: ?BetaPrompt = null,
    truncation: ?std.json.Value = null,
    id: []const u8 = "",
    object: []const u8 = "",
    status: ?[]const u8 = null,
    created_at: f64 = 0,
    completed_at: ?std.json.Value = null,
    @"error": ?BetaResponseError = null,
    incomplete_details: std.json.Value = .null,
    output: []const BetaOutputItem = &.{},
    reasoning: ?std.json.Value = null,
    instructions: std.json.Value = .null,
    output_text: ?std.json.Value = null,
    usage: ?BetaResponseUsage = null,
    prompt_cache_options: ?BetaPromptCacheOptions = null,
    moderation: ?std.json.Value = null,
    parallel_tool_calls: bool = false,
    conversation: ?std.json.Value = null,
    max_output_tokens: ?std.json.Value = null,
};

pub const BetaResponseAudioDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    delta: []const u8 = "",
};

pub const BetaResponseAudioDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseAudioTranscriptDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseAudioTranscriptDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseCodeInterpreterCallCodeDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseCodeInterpreterCallCodeDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    code: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseCodeInterpreterCallCompletedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseCodeInterpreterCallInProgressEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseCodeInterpreterCallInterpretingEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseCompletedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    response: ?BetaResponse = null,
    sequence_number: i64 = 0,
};

pub const BetaResponseContentPartAddedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    part: ?BetaOutputContent = null,
    sequence_number: i64 = 0,
};

pub const BetaResponseContentPartDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    sequence_number: i64 = 0,
    part: ?BetaOutputContent = null,
};

pub const BetaResponseCreatedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    response: ?BetaResponse = null,
    sequence_number: i64 = 0,
};

pub const BetaResponseCustomToolCallInputDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    output_index: i64 = 0,
    item_id: []const u8 = "",
    delta: []const u8 = "",
};

pub const BetaResponseCustomToolCallInputDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    output_index: i64 = 0,
    item_id: []const u8 = "",
    input: []const u8 = "",
};

pub const BetaResponseError = std.json.Value;

pub const BetaResponseErrorCode = []const u8;

pub const BetaResponseErrorEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    code: std.json.Value = .null,
    message: []const u8 = "",
    param: std.json.Value = .null,
    sequence_number: i64 = 0,
};

pub const BetaResponseFailedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    response: ?BetaResponse = null,
};

pub const BetaResponseFileSearchCallCompletedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseFileSearchCallInProgressEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseFileSearchCallSearchingEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseFormatJsonObject = struct {
    @"type": []const u8 = "",
};

pub const BetaResponseFormatJsonSchemaSchema = std.json.Value;

pub const BetaResponseFormatText = struct {
    @"type": []const u8 = "",
};

pub const BetaResponseFunctionCallArgumentsDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    delta: []const u8 = "",
};

pub const BetaResponseFunctionCallArgumentsDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    name: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    arguments: []const u8 = "",
};

pub const BetaResponseImageGenCallCompletedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    item_id: []const u8 = "",
};

pub const BetaResponseImageGenCallGeneratingEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseImageGenCallInProgressEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseImageGenCallPartialImageEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
    partial_image_index: i64 = 0,
    partial_image_b64: []const u8 = "",
};

pub const BetaResponseInProgressEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    response: ?BetaResponse = null,
    sequence_number: i64 = 0,
};

pub const BetaResponseIncompleteEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    response: ?BetaResponse = null,
    sequence_number: i64 = 0,
};

pub const BetaResponseInjectCreatedEvent = struct {
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    sequence_number: i64 = 0,
    stream_id: ?[]const u8 = null,
};

pub const BetaResponseInjectEvent = struct {
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    input: []const BetaInputItem = &.{},
};

pub const BetaResponseInjectFailedEvent = struct {
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    input: []const BetaInputItem = &.{},
    @"error": ?struct {
    code: []const u8 = "",
    message: []const u8 = "",
} = null,
    sequence_number: i64 = 0,
    stream_id: ?[]const u8 = null,
};

pub const BetaResponseItemList = struct {
    object: []const u8 = "",
    data: []const BetaItemResource = &.{},
    has_more: bool = false,
    first_id: []const u8 = "",
    last_id: []const u8 = "",
};

pub const BetaResponseLogProb = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    top_logprobs: ?[]const struct {
    token: ?[]const u8 = null,
    logprob: ?f64 = null,
} = null,
};

pub const BetaResponseMCPCallArgumentsDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseMCPCallArgumentsDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    arguments: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseMCPCallCompletedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const BetaResponseMCPCallFailedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const BetaResponseMCPCallInProgressEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const BetaResponseMCPListToolsCompletedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const BetaResponseMCPListToolsFailedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const BetaResponseMCPListToolsInProgressEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const BetaResponseOutputItemAddedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    item: ?BetaOutputItem = null,
};

pub const BetaResponseOutputItemDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    item: ?BetaOutputItem = null,
};

pub const BetaResponseOutputTextAnnotationAddedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    annotation_index: i64 = 0,
    sequence_number: i64 = 0,
    annotation: std.json.Value = .null,
};

pub const BetaResponsePromptVariables = std.json.Value;

pub const BetaResponseProperties = struct {
    previous_response_id: ?std.json.Value = null,
    model: ?BetaModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?BetaResponseTextParam = null,
    tools: ?BetaToolsArray = null,
    tool_choice: ?BetaToolChoiceParam = null,
    prompt: ?BetaPrompt = null,
};

pub const BetaResponseQueuedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    response: ?BetaResponse = null,
    sequence_number: i64 = 0,
};

pub const BetaResponseReasoningSummaryPartAddedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    sequence_number: i64 = 0,
    part: ?struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
} = null,
};

pub const BetaResponseReasoningSummaryPartDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    status: ?[]const u8 = null,
    sequence_number: i64 = 0,
    part: ?struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
} = null,
};

pub const BetaResponseReasoningSummaryTextDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseReasoningSummaryTextDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    text: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseReasoningTextDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseReasoningTextDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    text: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseRefusalDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseRefusalDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    refusal: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseStreamEvent = std.json.Value;

pub const BetaResponseStreamOptions = std.json.Value;

pub const BetaResponseTextDeltaEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
    logprobs: []const BetaResponseLogProb = &.{},
};

pub const BetaResponseTextDoneEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    text: []const u8 = "",
    sequence_number: i64 = 0,
    logprobs: []const BetaResponseLogProb = &.{},
};

pub const BetaResponseTextParam = struct {
    format: ?BetaTextResponseFormatConfiguration = null,
    verbosity: ?BetaVerbosity = null,
};

pub const BetaResponseUsage = struct {
    input_tokens: i64 = 0,
    input_tokens_details: ?struct {
    cached_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
} = null,
    output_tokens: i64 = 0,
    output_tokens_details: ?struct {
    reasoning_tokens: i64 = 0,
} = null,
    total_tokens: i64 = 0,
};

pub const BetaResponseWebSearchCallCompletedEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseWebSearchCallInProgressEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponseWebSearchCallSearchingEvent = struct {
    agent: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const BetaResponsesClientEvent = std.json.Value;

pub const BetaResponsesClientEventResponseCreate = struct {
    @"type": []const u8 = "",
    metadata: ?BetaMetadata = null,
    top_logprobs: ?i64 = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?BetaServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?BetaPromptCacheOptionsParam = null,
    previous_response_id: ?std.json.Value = null,
    model: ?BetaModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?BetaResponseTextParam = null,
    tools: ?BetaToolsArray = null,
    tool_choice: ?BetaToolChoiceParam = null,
    prompt: ?BetaPrompt = null,
    truncation: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    input: ?BetaInputParam = null,
    include: ?std.json.Value = null,
    parallel_tool_calls: ?std.json.Value = null,
    store: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    moderation: ?std.json.Value = null,
    stream: ?std.json.Value = null,
    stream_options: ?BetaResponseStreamOptions = null,
    conversation: ?std.json.Value = null,
    context_management: ?std.json.Value = null,
    max_output_tokens: ?std.json.Value = null,
    multi_agent: ?std.json.Value = null,
};

pub const BetaResponsesServerEvent = std.json.Value;

pub const BetaScreenshotParam = struct {
    @"type": []const u8 = "",
};

pub const BetaScrollParam = struct {
    @"type": []const u8 = "",
    x: i64 = 0,
    y: i64 = 0,
    scroll_x: i64 = 0,
    scroll_y: i64 = 0,
    keys: ?std.json.Value = null,
};

pub const BetaSearchContentType = []const u8;

pub const BetaSearchContextSize = []const u8;

pub const BetaServiceTier = std.json.Value;

pub const BetaServiceTierEnum = []const u8;

pub const BetaSkillReferenceParam = struct {
    @"type": []const u8 = "",
    skill_id: []const u8 = "",
    version: ?[]const u8 = null,
};

pub const BetaSpecificApplyPatchParam = struct {
    @"type": []const u8 = "",
};

pub const BetaSpecificFunctionShellParam = struct {
    @"type": []const u8 = "",
};

pub const BetaSpecificProgrammaticToolCallingParam = struct {
    @"type": []const u8 = "",
};

pub const BetaSummaryTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const BetaTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const BetaTextResponseFormatConfiguration = std.json.Value;

pub const BetaTextResponseFormatJsonSchema = struct {
    @"type": []const u8 = "",
    description: ?[]const u8 = null,
    name: []const u8 = "",
    schema: ?BetaResponseFormatJsonSchemaSchema = null,
    strict: ?std.json.Value = null,
};

pub const BetaTokenCountsBody = struct {
    model: ?std.json.Value = null,
    input: ?std.json.Value = null,
    previous_response_id: ?std.json.Value = null,
    tools: ?std.json.Value = null,
    text: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    truncation: ?BetaTruncationEnum = null,
    instructions: ?std.json.Value = null,
    personality: ?BetaPersonalityEnum = null,
    conversation: ?std.json.Value = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?std.json.Value = null,
};

pub const BetaTokenCountsResource = struct {
    object: []const u8 = "",
    input_tokens: i64 = 0,
};

pub const BetaTool = std.json.Value;

pub const BetaToolCallCaller = std.json.Value;

pub const BetaToolCallCallerParam = std.json.Value;

pub const BetaToolChoiceAllowed = struct {
    @"type": []const u8 = "",
    mode: []const u8 = "",
    tools: []const std.json.Value = &.{},
};

pub const BetaToolChoiceCustom = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
};

pub const BetaToolChoiceFunction = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
};

pub const BetaToolChoiceMCP = struct {
    @"type": []const u8 = "",
    server_label: []const u8 = "",
    name: ?std.json.Value = null,
};

pub const BetaToolChoiceOptions = []const u8;

pub const BetaToolChoiceParam = std.json.Value;

pub const BetaToolChoiceTypes = struct {
    @"type": []const u8 = "",
};

pub const BetaToolSearchCall = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: std.json.Value = .null,
    execution: ?BetaToolSearchExecutionType = null,
    arguments: std.json.Value = .null,
    status: ?BetaFunctionCallStatus = null,
    created_by: ?[]const u8 = null,
};

pub const BetaToolSearchCallItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: ?std.json.Value = null,
    @"type": []const u8 = "",
    execution: ?BetaToolSearchExecutionType = null,
    arguments: ?BetaEmptyModelParam = null,
    status: ?std.json.Value = null,
};

pub const BetaToolSearchExecutionType = []const u8;

pub const BetaToolSearchOutput = struct {
    agent: ?BetaAgentTag = null,
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: std.json.Value = .null,
    execution: ?BetaToolSearchExecutionType = null,
    tools: []const BetaTool = &.{},
    status: ?BetaFunctionCallOutputStatusEnum = null,
    created_by: ?[]const u8 = null,
};

pub const BetaToolSearchOutputItemParam = struct {
    agent: ?std.json.Value = null,
    id: ?std.json.Value = null,
    call_id: ?std.json.Value = null,
    @"type": []const u8 = "",
    execution: ?BetaToolSearchExecutionType = null,
    tools: []const BetaTool = &.{},
    status: ?std.json.Value = null,
};

pub const BetaToolSearchToolParam = struct {
    @"type": []const u8 = "",
    execution: ?BetaToolSearchExecutionType = null,
    description: ?std.json.Value = null,
    parameters: ?std.json.Value = null,
};

pub const BetaToolsArray = []const BetaTool;

pub const BetaTopLogProb = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: []const i64 = &.{},
};

pub const BetaTruncationEnum = []const u8;

pub const BetaTypeParam = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const BetaUrlCitationBody = struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    title: []const u8 = "",
};

pub const BetaUrlCitationParam = struct {
    @"type": []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    url: []const u8 = "",
    title: []const u8 = "",
};

pub const BetaVectorStoreFileAttributes = std.json.Value;

pub const BetaVerbosity = std.json.Value;

pub const BetaWaitParam = struct {
    @"type": []const u8 = "",
};

pub const BetaWebSearchActionFind = struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
    pattern: []const u8 = "",
};

pub const BetaWebSearchActionOpenPage = struct {
    @"type": []const u8 = "",
    url: ?std.json.Value = null,
};

pub const BetaWebSearchActionSearch = struct {
    @"type": []const u8 = "",
    query: ?[]const u8 = null,
    queries: ?[]const []const u8 = null,
    sources: ?[]const struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
} = null,
};

pub const BetaWebSearchApproximateLocation = std.json.Value;

pub const BetaWebSearchPreviewTool = struct {
    @"type": []const u8 = "",
    user_location: ?std.json.Value = null,
    search_context_size: ?BetaSearchContextSize = null,
    search_content_types: ?[]const BetaSearchContentType = null,
};

pub const BetaWebSearchTool = struct {
    @"type": []const u8 = "",
    filters: ?std.json.Value = null,
    user_location: ?BetaWebSearchApproximateLocation = null,
    search_context_size: ?[]const u8 = null,
};

pub const BetaWebSearchToolCall = struct {
    agent: ?std.json.Value = null,
    id: []const u8 = "",
    @"type": []const u8 = "",
    status: []const u8 = "",
    action: std.json.Value = .null,
};

pub const Beta_AgentTagParam = struct {
    agent_name: []const u8 = "",
};

pub const CallableToolAllowedCaller = []const u8;

pub const Certificate = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: std.json.Value = .null,
    created_at: i64 = 0,
    certificate_details: ?struct {
    valid_at: ?i64 = null,
    expires_at: ?i64 = null,
    content: ?[]const u8 = null,
} = null,
    active: ?bool = null,
};

pub const ChatCompletionAllowedTools = struct {
    mode: []const u8 = "",
    tools: []const std.json.Value = &.{},
};

pub const ChatCompletionAllowedToolsChoice = struct {
    @"type": []const u8 = "",
    allowed_tools: ?ChatCompletionAllowedTools = null,
};

pub const ChatCompletionDeleted = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const ChatCompletionFunctionCallOption = struct {
    name: []const u8 = "",
};

pub const ChatCompletionFunctions = struct {
    description: ?[]const u8 = null,
    name: []const u8 = "",
    parameters: ?FunctionParameters = null,
};

pub const ChatCompletionList = struct {
    object: []const u8 = "",
    data: []const CreateChatCompletionResponse = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ChatCompletionMessageCustomToolCall = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    custom: ?struct {
    name: []const u8 = "",
    input: []const u8 = "",
} = null,
};

pub const ChatCompletionMessageList = struct {
    object: []const u8 = "",
    data: []const struct {
    content: []const u8 = "",
    refusal: std.json.Value = .null,
    tool_calls: ?ChatCompletionMessageToolCalls = null,
    annotations: ?[]const struct {
    @"type": []const u8 = "",
    url_citation: ?struct {
    end_index: i64 = 0,
    start_index: i64 = 0,
    url: []const u8 = "",
    title: []const u8 = "",
} = null,
} = null,
    role: []const u8 = "",
    function_call: ?struct {
    arguments: []const u8 = "",
    name: []const u8 = "",
} = null,
    audio: ?std.json.Value = null,
    id: []const u8 = "",
    content_parts: ?std.json.Value = null,
} = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ChatCompletionMessageToolCall = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    function: ?struct {
    name: []const u8 = "",
    arguments: []const u8 = "",
} = null,
};

pub const ChatCompletionMessageToolCallChunk = struct {
    index: i64 = 0,
    id: ?[]const u8 = null,
    @"type": ?[]const u8 = null,
    function: ?struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
} = null,
};

pub const ChatCompletionMessageToolCalls = []const ChatCompletionMessageToolCall;

pub const ChatCompletionModalities = std.json.Value;

pub const ChatCompletionModeration = struct {
    input: std.json.Value = .null,
    output: std.json.Value = .null,
};

pub const ChatCompletionModerationError = struct {
    @"type": []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
};

pub const ChatCompletionModerationResults = struct {
    @"type": []const u8 = "",
    model: []const u8 = "",
    results: []const ModerationResultBody = &.{},
};

pub const ChatCompletionNamedToolChoice = struct {
    @"type": []const u8 = "",
    function: ?struct {
    name: []const u8 = "",
} = null,
};

pub const ChatCompletionNamedToolChoiceCustom = struct {
    @"type": []const u8 = "",
    custom: ?struct {
    name: []const u8 = "",
} = null,
};

pub const ChatCompletionRequestAssistantMessage = struct {
    content: ?std.json.Value = null,
    refusal: ?std.json.Value = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    audio: ?std.json.Value = null,
    tool_calls: ?ChatCompletionMessageToolCalls = null,
    function_call: ?std.json.Value = null,
};

pub const ChatCompletionRequestAssistantMessageContentPart = std.json.Value;

pub const ChatCompletionRequestDeveloperMessage = struct {
    content: ?[]const u8 = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ChatCompletionRequestFunctionMessage = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ChatCompletionRequestMessage = std.json.Value;

pub const ChatCompletionRequestMessageContentPartAudio = struct {
    @"type": []const u8 = "",
    input_audio: ?struct {
    data: []const u8 = "",
    format: []const u8 = "",
} = null,
    prompt_cache_breakpoint: ?PromptCacheBreakpointParam = null,
};

pub const ChatCompletionRequestMessageContentPartFile = struct {
    @"type": []const u8 = "",
    file: ?struct {
    filename: ?[]const u8 = null,
    file_data: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
} = null,
    prompt_cache_breakpoint: ?PromptCacheBreakpointParam = null,
};

pub const ChatCompletionRequestMessageContentPartImage = struct {
    @"type": []const u8 = "",
    image_url: ?struct {
    url: []const u8 = "",
    detail: ?[]const u8 = null,
} = null,
    prompt_cache_breakpoint: ?PromptCacheBreakpointParam = null,
};

pub const ChatCompletionRequestMessageContentPartRefusal = struct {
    @"type": []const u8 = "",
    refusal: []const u8 = "",
};

pub const ChatCompletionRequestMessageContentPartText = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    prompt_cache_breakpoint: ?PromptCacheBreakpointParam = null,
};

pub const ChatCompletionRequestSystemMessage = struct {
    content: ?[]const u8 = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ChatCompletionRequestSystemMessageContentPart = std.json.Value;

pub const ChatCompletionRequestToolMessage = struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ChatCompletionRequestToolMessageContentPart = std.json.Value;

pub const ChatCompletionRequestUserMessage = struct {
    content: ?[]const u8 = null,
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ChatCompletionRequestUserMessageContentPart = std.json.Value;

pub const ChatCompletionResponseMessage = struct {
    content: ?[]const u8 = null,
    refusal: ?std.json.Value = null,
    tool_calls: ?ChatCompletionMessageToolCalls = null,
    annotations: ?[]const struct {
    @"type": []const u8 = "",
    url_citation: ?struct {
    end_index: i64 = 0,
    start_index: i64 = 0,
    url: []const u8 = "",
    title: []const u8 = "",
} = null,
} = null,
    role: ?[]const u8 = null,
    function_call: ?struct {
    arguments: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
    audio: ?std.json.Value = null,
};

pub const ChatCompletionRole = []const u8;

pub const ChatCompletionStreamOptions = std.json.Value;

pub const ChatCompletionStreamResponseDelta = struct {
    content: ?[]const u8 = null,
    function_call: ?struct {
    arguments: ?[]const u8 = null,
    name: ?[]const u8 = null,
} = null,
    tool_calls: ?[]const ChatCompletionMessageToolCallChunk = null,
    role: ?[]const u8 = null,
    refusal: ?std.json.Value = null,
};

pub const ChatCompletionTokenLogprob = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: std.json.Value = .null,
    top_logprobs: []const struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: std.json.Value = .null,
} = &.{},
};

pub const ChatCompletionTool = struct {
    @"type": []const u8 = "",
    function: ?FunctionObject = null,
};

pub const ChatCompletionToolChoiceOption = std.json.Value;

pub const ChatSessionAutomaticThreadTitling = struct {
    enabled: bool = false,
};

pub const ChatSessionChatkitConfiguration = struct {
    automatic_thread_titling: ?ChatSessionAutomaticThreadTitling = null,
    file_upload: ?ChatSessionFileUpload = null,
    history: ?ChatSessionHistory = null,
};

pub const ChatSessionFileUpload = struct {
    enabled: bool = false,
    max_file_size: std.json.Value = .null,
    max_files: std.json.Value = .null,
};

pub const ChatSessionHistory = struct {
    enabled: bool = false,
    recent_threads: std.json.Value = .null,
};

pub const ChatSessionRateLimits = struct {
    max_requests_per_1_minute: i64 = 0,
};

pub const ChatSessionResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    expires_at: i64 = 0,
    client_secret: []const u8 = "",
    workflow: ?ChatkitWorkflow = null,
    user: []const u8 = "",
    rate_limits: ?ChatSessionRateLimits = null,
    max_requests_per_1_minute: i64 = 0,
    status: ?ChatSessionStatus = null,
    chatkit_configuration: ?ChatSessionChatkitConfiguration = null,
};

pub const ChatSessionStatus = []const u8;

pub const ChatkitConfigurationParam = struct {
    automatic_thread_titling: ?AutomaticThreadTitlingParam = null,
    file_upload: ?FileUploadParam = null,
    history: ?HistoryParam = null,
};

pub const ChatkitWorkflow = struct {
    id: []const u8 = "",
    version: std.json.Value = .null,
    state_variables: std.json.Value = .null,
    tracing: ?ChatkitWorkflowTracing = null,
};

pub const ChatkitWorkflowTracing = struct {
    enabled: bool = false,
};

pub const ChunkingStrategyRequestParam = std.json.Value;

pub const ClickButtonType = []const u8;

pub const ClickParam = struct {
    @"type": []const u8 = "",
    button: ?ClickButtonType = null,
    x: i64 = 0,
    y: i64 = 0,
    keys: ?std.json.Value = null,
};

pub const ClientToolCallItem = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    @"type": []const u8 = "",
    status: ?ClientToolCallStatus = null,
    call_id: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
    output: std.json.Value = .null,
};

pub const ClientToolCallStatus = []const u8;

pub const ClosedStatus = struct {
    @"type": []const u8 = "",
    reason: std.json.Value = .null,
};

pub const CodeInterpreterFileOutput = struct {
    @"type": []const u8 = "",
    files: []const struct {
    mime_type: []const u8 = "",
    file_id: []const u8 = "",
} = &.{},
};

pub const CodeInterpreterOutputImage = struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
};

pub const CodeInterpreterOutputLogs = struct {
    @"type": []const u8 = "",
    logs: []const u8 = "",
};

pub const CodeInterpreterTextOutput = struct {
    @"type": []const u8 = "",
    logs: []const u8 = "",
};

pub const CodeInterpreterTool = struct {
    @"type": []const u8 = "",
    container: std.json.Value = .null,
    allowed_callers: ?std.json.Value = null,
};

pub const CodeInterpreterToolCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    status: []const u8 = "",
    container_id: []const u8 = "",
    code: std.json.Value = .null,
    outputs: std.json.Value = .null,
};

pub const CompactResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    output: []const ItemField = &.{},
    created_at: i64 = 0,
    usage: ?ResponseUsage = null,
};

pub const CompactResponseMethodPublicBody = struct {
    model: ?ModelIdsCompaction = null,
    input: ?std.json.Value = null,
    previous_response_id: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?std.json.Value = null,
    service_tier: ?std.json.Value = null,
};

pub const CompactionBody = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    encrypted_content: []const u8 = "",
    created_by: ?[]const u8 = null,
};

pub const CompactionSummaryItemParam = struct {
    id: ?std.json.Value = null,
    @"type": []const u8 = "",
    encrypted_content: []const u8 = "",
};

pub const CompactionTriggerItemParam = struct {
    @"type": []const u8 = "",
};

pub const ComparisonFilter = struct {
    @"type": []const u8 = "",
    key: []const u8 = "",
    value: std.json.Value = .null,
};

pub const CompleteUploadRequest = struct {
    part_ids: []const []const u8 = &.{},
    md5: ?[]const u8 = null,
};

pub const CompletionUsage = struct {
    completion_tokens: i64 = 0,
    prompt_tokens: i64 = 0,
    total_tokens: i64 = 0,
    completion_tokens_details: ?struct {
    accepted_prediction_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
    reasoning_tokens: ?i64 = null,
    rejected_prediction_tokens: ?i64 = null,
} = null,
    prompt_tokens_details: ?struct {
    audio_tokens: ?i64 = null,
    cached_tokens: ?i64 = null,
    cache_write_tokens: ?i64 = null,
} = null,
};

pub const CompoundFilter = struct {
    @"type": []const u8 = "",
    filters: []const ComparisonFilter = &.{},
};

pub const ComputerAction = std.json.Value;

pub const ComputerActionList = []const ComputerAction;

pub const ComputerCallOutputItemParam = struct {
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    @"type": []const u8 = "",
    output: ?ComputerScreenshotImage = null,
    acknowledged_safety_checks: ?std.json.Value = null,
    status: ?std.json.Value = null,
};

pub const ComputerCallOutputStatus = []const u8;

pub const ComputerCallSafetyCheckParam = struct {
    id: []const u8 = "",
    code: ?std.json.Value = null,
    message: ?std.json.Value = null,
};

pub const ComputerEnvironment = []const u8;

pub const ComputerScreenshotContent = struct {
    @"type": []const u8 = "",
    image_url: std.json.Value = .null,
    file_id: std.json.Value = .null,
    detail: ?ImageDetail = null,
    prompt_cache_breakpoint: ?PromptCacheBreakpointConfig = null,
};

pub const ComputerScreenshotImage = struct {
    @"type": []const u8 = "",
    image_url: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
};

pub const ComputerTool = struct {
    @"type": []const u8 = "",
};

pub const ComputerToolCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    action: ?ComputerAction = null,
    actions: ?ComputerActionList = null,
    pending_safety_checks: []const ComputerCallSafetyCheckParam = &.{},
    status: []const u8 = "",
};

pub const ComputerToolCallOutput = struct {
    @"type": []const u8 = "",
    id: ?[]const u8 = null,
    call_id: []const u8 = "",
    acknowledged_safety_checks: ?[]const ComputerCallSafetyCheckParam = null,
    output: ?ComputerScreenshotImage = null,
    status: ?[]const u8 = null,
};

pub const ComputerToolCallOutputResource = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    acknowledged_safety_checks: ?[]const ComputerCallSafetyCheckParam = null,
    output: ?ComputerScreenshotImage = null,
    status: ?ComputerCallOutputStatus = null,
    created_by: ?[]const u8 = null,
};

pub const ComputerUsePreviewTool = struct {
    @"type": []const u8 = "",
    environment: ?ComputerEnvironment = null,
    display_width: i64 = 0,
    display_height: i64 = 0,
};

pub const ContainerAutoParam = struct {
    @"type": []const u8 = "",
    file_ids: ?[]const []const u8 = null,
    memory_limit: ?std.json.Value = null,
    network_policy: ?std.json.Value = null,
    skills: ?[]const SkillReferenceParam = null,
};

pub const ContainerFileCitationBody = struct {
    @"type": []const u8 = "",
    container_id: []const u8 = "",
    file_id: []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    filename: []const u8 = "",
};

pub const ContainerFileCitationParam = struct {
    @"type": []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    container_id: []const u8 = "",
    file_id: []const u8 = "",
    filename: []const u8 = "",
};

pub const ContainerFileListResource = struct {
    object: []const u8 = "",
    data: []const ContainerFileResource = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ContainerFileResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    container_id: []const u8 = "",
    created_at: i64 = 0,
    bytes: i64 = 0,
    path: []const u8 = "",
    source: []const u8 = "",
};

pub const ContainerListResource = struct {
    object: []const u8 = "",
    data: []const ContainerResource = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ContainerMemoryLimit = []const u8;

pub const ContainerNetworkPolicyAllowlistParam = struct {
    @"type": []const u8 = "",
    allowed_domains: []const []const u8 = &.{},
    domain_secrets: ?[]const ContainerNetworkPolicyDomainSecretParam = null,
};

pub const ContainerNetworkPolicyDisabledParam = struct {
    @"type": []const u8 = "",
};

pub const ContainerNetworkPolicyDomainSecretParam = struct {
    domain: []const u8 = "",
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const ContainerReferenceParam = struct {
    @"type": []const u8 = "",
    container_id: []const u8 = "",
};

pub const ContainerReferenceResource = struct {
    @"type": []const u8 = "",
    container_id: []const u8 = "",
};

pub const ContainerResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    status: []const u8 = "",
    last_active_at: ?i64 = null,
    expires_after: ?struct {
    anchor: ?[]const u8 = null,
    minutes: ?i64 = null,
} = null,
    memory_limit: ?[]const u8 = null,
    network_policy: ?struct {
    @"type": []const u8 = "",
    allowed_domains: ?[]const []const u8 = null,
} = null,
};

pub const Content = std.json.Value;

pub const ContextManagementParam = struct {
    @"type": []const u8 = "",
    compact_threshold: ?std.json.Value = null,
};

pub const Conversation_2 = struct {
    id: []const u8 = "",
};

pub const ConversationItem = std.json.Value;

pub const ConversationItemList = struct {
    object: []const u8 = "",
    data: []const ConversationItem = &.{},
    has_more: bool = false,
    first_id: []const u8 = "",
    last_id: []const u8 = "",
};

pub const ConversationParam = std.json.Value;

pub const ConversationParam_2 = struct {
    id: []const u8 = "",
};

pub const ConversationResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    metadata: std.json.Value = .null,
    created_at: i64 = 0,
};

pub const CoordParam = struct {
    x: i64 = 0,
    y: i64 = 0,
};

pub const CostsResult = struct {
    object: []const u8 = "",
    amount: ?struct {
    value: ?f64 = null,
    currency: ?[]const u8 = null,
} = null,
    line_item: ?std.json.Value = null,
    project_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    quantity: ?std.json.Value = null,
};

pub const CreateAssistantRequest = struct {
    model: std.json.Value = .null,
    name: ?std.json.Value = null,
    description: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    reasoning_effort: ?ReasoningEffort = null,
    tools: ?[]const AssistantToolsCode = null,
    tool_resources: ?std.json.Value = null,
    metadata: ?Metadata = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    response_format: ?std.json.Value = null,
};

pub const CreateBatchRequest = struct {
    input_file_id: []const u8 = "",
    endpoint: []const u8 = "",
    completion_window: []const u8 = "",
    metadata: ?Metadata = null,
    output_expires_after: ?BatchFileExpirationAfter = null,
};

pub const CreateChatCompletionRequest = struct {
    metadata: ?Metadata = null,
    top_logprobs: ?i64 = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?ServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?PromptCacheOptionsParam = null,
    messages: []const ChatCompletionRequestMessage = &.{},
    model: ?ModelIdsShared = null,
    modalities: ?ResponseModalities = null,
    verbosity: ?Verbosity = null,
    reasoning_effort: ?ReasoningEffort = null,
    max_completion_tokens: ?i64 = null,
    frequency_penalty: ?f64 = null,
    presence_penalty: ?f64 = null,
    web_search_options: ?struct {
    user_location: ?struct {
    @"type": []const u8 = "",
    approximate: ?WebSearchLocation = null,
} = null,
    search_context_size: ?WebSearchContextSize = null,
} = null,
    response_format: ?std.json.Value = null,
    audio: ?struct {
    voice: ?VoiceIdsOrCustomVoice = null,
    format: []const u8 = "",
} = null,
    store: ?bool = null,
    moderation: ?std.json.Value = null,
    stream: ?bool = null,
    stop: ?StopConfiguration = null,
    logit_bias: ?std.json.Value = null,
    logprobs: ?bool = null,
    max_tokens: ?i64 = null,
    n: ?i64 = null,
    prediction: ?std.json.Value = null,
    seed: ?i64 = null,
    stream_options: ?ChatCompletionStreamOptions = null,
    tools: ?[]const ChatCompletionTool = null,
    tool_choice: ?ChatCompletionToolChoiceOption = null,
    parallel_tool_calls: ?ParallelToolCalls = null,
    function_call: ?std.json.Value = null,
    functions: ?[]const ChatCompletionFunctions = null,
};

pub const CreateChatCompletionResponse = struct {
    id: []const u8 = "",
    choices: []const struct {
    finish_reason: []const u8 = "",
    index: i64 = 0,
    message: ?ChatCompletionResponseMessage = null,
    logprobs: std.json.Value = .null,
} = &.{},
    created: i64 = 0,
    model: []const u8 = "",
    service_tier: ?ServiceTier = null,
    system_fingerprint: ?[]const u8 = null,
    object: []const u8 = "",
    usage: ?CompletionUsage = null,
    moderation: ?std.json.Value = null,
};

pub const CreateChatCompletionStreamResponse = struct {
    id: []const u8 = "",
    choices: []const struct {
    delta: ?ChatCompletionStreamResponseDelta = null,
    logprobs: ?struct {
    content: ?[]const ChatCompletionTokenLogprob = null,
    refusal: ?[]const ChatCompletionTokenLogprob = null,
} = null,
    finish_reason: ?[]const u8 = null,
    index: i64 = 0,
} = &.{},
    created: i64 = 0,
    model: []const u8 = "",
    service_tier: ?ServiceTier = null,
    system_fingerprint: ?[]const u8 = null,
    object: []const u8 = "",
    usage: ?CompletionUsage = null,
    moderation: ?std.json.Value = null,
};

pub const CreateChatSessionBody = struct {
    workflow: ?WorkflowParam = null,
    user: []const u8 = "",
    expires_after: ?ExpiresAfterParam = null,
    rate_limits: ?RateLimitsParam = null,
    chatkit_configuration: ?ChatkitConfigurationParam = null,
};

pub const CreateCompletionRequest = struct {
    model: std.json.Value = .null,
    prompt: ?std.json.Value = null,
    best_of: ?i64 = null,
    echo: ?bool = null,
    frequency_penalty: ?f64 = null,
    logit_bias: ?std.json.Value = null,
    logprobs: ?i64 = null,
    max_tokens: ?i64 = null,
    n: ?i64 = null,
    presence_penalty: ?f64 = null,
    seed: ?i64 = null,
    stop: ?StopConfiguration = null,
    stream: ?bool = null,
    stream_options: ?ChatCompletionStreamOptions = null,
    suffix: ?[]const u8 = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    user: ?[]const u8 = null,
};

pub const CreateCompletionResponse = struct {
    id: []const u8 = "",
    choices: []const struct {
    finish_reason: []const u8 = "",
    index: i64 = 0,
    logprobs: std.json.Value = .null,
    text: []const u8 = "",
} = &.{},
    created: i64 = 0,
    model: []const u8 = "",
    system_fingerprint: ?[]const u8 = null,
    object: []const u8 = "",
    usage: ?CompletionUsage = null,
};

pub const CreateContainerBody = struct {
    name: []const u8 = "",
    file_ids: ?[]const []const u8 = null,
    expires_after: ?struct {
    anchor: []const u8 = "",
    minutes: i64 = 0,
} = null,
    skills: ?[]const SkillReferenceParam = null,
    memory_limit: ?[]const u8 = null,
    network_policy: ?std.json.Value = null,
};

pub const CreateContainerFileBody = struct {
    file_id: ?[]const u8 = null,
    file: ?[]const u8 = null,
};

pub const CreateConversationBody = struct {
    metadata: ?std.json.Value = null,
    items: ?std.json.Value = null,
};

pub const CreateEmbeddingRequest = struct {
    input: std.json.Value = .null,
    model: std.json.Value = .null,
    encoding_format: ?[]const u8 = null,
    dimensions: ?i64 = null,
    user: ?[]const u8 = null,
};

pub const CreateEmbeddingResponse = struct {
    data: []const Embedding = &.{},
    model: []const u8 = "",
    object: []const u8 = "",
    usage: ?struct {
    prompt_tokens: i64 = 0,
    total_tokens: i64 = 0,
} = null,
};

pub const CreateEvalCompletionsRunDataSource = struct {
    @"type": []const u8 = "",
    input_messages: ?std.json.Value = null,
    sampling_params: ?struct {
    reasoning_effort: ?ReasoningEffort = null,
    temperature: ?f64 = null,
    max_completion_tokens: ?i64 = null,
    top_p: ?f64 = null,
    seed: ?i64 = null,
    response_format: ?std.json.Value = null,
    tools: ?[]const ChatCompletionTool = null,
} = null,
    model: ?[]const u8 = null,
    source: std.json.Value = .null,
};

pub const CreateEvalCustomDataSourceConfig = struct {
    @"type": []const u8 = "",
    item_schema: std.json.Value = .null,
    include_sample_schema: ?bool = null,
};

pub const CreateEvalItem = std.json.Value;

pub const CreateEvalJsonlRunDataSource = struct {
    @"type": []const u8 = "",
    source: std.json.Value = .null,
};

pub const CreateEvalLabelModelGrader = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    model: []const u8 = "",
    input: []const CreateEvalItem = &.{},
    labels: []const []const u8 = &.{},
    passing_labels: []const []const u8 = &.{},
};

pub const CreateEvalLogsDataSourceConfig = struct {
    @"type": []const u8 = "",
    metadata: ?std.json.Value = null,
};

pub const CreateEvalRequest = struct {
    name: ?[]const u8 = null,
    metadata: ?Metadata = null,
    data_source_config: std.json.Value = .null,
    testing_criteria: []const CreateEvalLabelModelGrader = &.{},
};

pub const CreateEvalResponsesRunDataSource = struct {
    @"type": []const u8 = "",
    input_messages: ?std.json.Value = null,
    sampling_params: ?struct {
    reasoning_effort: ?ReasoningEffort = null,
    temperature: ?f64 = null,
    max_completion_tokens: ?i64 = null,
    top_p: ?f64 = null,
    seed: ?i64 = null,
    tools: ?[]const Tool = null,
    text: ?struct {
    format: ?TextResponseFormatConfiguration = null,
} = null,
} = null,
    model: ?[]const u8 = null,
    source: std.json.Value = .null,
};

pub const CreateEvalRunRequest = struct {
    name: ?[]const u8 = null,
    metadata: ?Metadata = null,
    data_source: std.json.Value = .null,
};

pub const CreateEvalStoredCompletionsDataSourceConfig = struct {
    @"type": []const u8 = "",
    metadata: ?std.json.Value = null,
};

pub const CreateFileRequest = struct {
    file: []const u8 = "",
    purpose: []const u8 = "",
    expires_after: ?FileExpirationAfter = null,
};

pub const CreateFineTuningCheckpointPermissionRequest = struct {
    project_ids: []const []const u8 = &.{},
};

pub const CreateFineTuningJobRequest = struct {
    model: std.json.Value = .null,
    training_file: []const u8 = "",
    hyperparameters: ?struct {
    batch_size: ?std.json.Value = null,
    learning_rate_multiplier: ?std.json.Value = null,
    n_epochs: ?std.json.Value = null,
} = null,
    suffix: ?[]const u8 = null,
    validation_file: ?[]const u8 = null,
    integrations: ?[]const struct {
    @"type": []const u8 = "",
    wandb: ?struct {
    project: []const u8 = "",
    name: ?[]const u8 = null,
    entity: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
} = null,
} = null,
    seed: ?i64 = null,
    method: ?FineTuneMethod = null,
    metadata: ?Metadata = null,
};

pub const CreateGroupBody = struct {
    name: []const u8 = "",
};

pub const CreateGroupUserBody = struct {
    user_id: []const u8 = "",
};

pub const CreateImageEditRequest = struct {
    image: std.json.Value = .null,
    prompt: []const u8 = "",
    mask: ?[]const u8 = null,
    background: ?[]const u8 = null,
    model: ?std.json.Value = null,
    n: ?i64 = null,
    size: ?std.json.Value = null,
    response_format: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    output_compression: ?i64 = null,
    user: ?[]const u8 = null,
    input_fidelity: ?std.json.Value = null,
    stream: ?bool = null,
    partial_images: ?PartialImages = null,
    quality: ?[]const u8 = null,
};

pub const CreateImageRequest = struct {
    prompt: []const u8 = "",
    model: ?std.json.Value = null,
    n: ?i64 = null,
    quality: ?[]const u8 = null,
    response_format: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    output_compression: ?i64 = null,
    stream: ?bool = null,
    partial_images: ?PartialImages = null,
    size: ?std.json.Value = null,
    moderation: ?[]const u8 = null,
    background: ?[]const u8 = null,
    style: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

pub const CreateImageVariationRequest = struct {
    image: []const u8 = "",
    model: ?std.json.Value = null,
    n: ?i64 = null,
    response_format: ?[]const u8 = null,
    size: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

pub const CreateMessageRequest = struct {
    role: []const u8 = "",
    content: []const u8 = "",
    attachments: ?std.json.Value = null,
    metadata: ?Metadata = null,
};

pub const CreateModelResponseProperties = struct {
    metadata: ?Metadata = null,
    top_logprobs: ?i64 = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?ServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?PromptCacheOptionsParam = null,
};

pub const CreateModerationRequest = struct {
    input: std.json.Value = .null,
    model: ?std.json.Value = null,
};

pub const CreateModerationResponse = struct {
    id: []const u8 = "",
    model: []const u8 = "",
    results: []const struct {
    flagged: bool = false,
    categories: ?struct {
    hate: bool = false,
    hate_threatening: bool = false,
    harassment: bool = false,
    harassment_threatening: bool = false,
    illicit: std.json.Value = .null,
    illicit_violent: std.json.Value = .null,
    self_harm: bool = false,
    self_harm_intent: bool = false,
    self_harm_instructions: bool = false,
    sexual: bool = false,
    sexual_minors: bool = false,
    violence: bool = false,
    violence_graphic: bool = false,
} = null,
    category_scores: ?struct {
    hate: f64 = 0,
    hate_threatening: f64 = 0,
    harassment: f64 = 0,
    harassment_threatening: f64 = 0,
    illicit: f64 = 0,
    illicit_violent: f64 = 0,
    self_harm: f64 = 0,
    self_harm_intent: f64 = 0,
    self_harm_instructions: f64 = 0,
    sexual: f64 = 0,
    sexual_minors: f64 = 0,
    violence: f64 = 0,
    violence_graphic: f64 = 0,
} = null,
    category_applied_input_types: ?struct {
    hate: []const []const u8 = &.{},
    hate_threatening: []const []const u8 = &.{},
    harassment: []const []const u8 = &.{},
    harassment_threatening: []const []const u8 = &.{},
    illicit: []const []const u8 = &.{},
    illicit_violent: []const []const u8 = &.{},
    self_harm: []const []const u8 = &.{},
    self_harm_intent: []const []const u8 = &.{},
    self_harm_instructions: []const []const u8 = &.{},
    sexual: []const []const u8 = &.{},
    sexual_minors: []const []const u8 = &.{},
    violence: []const []const u8 = &.{},
    violence_graphic: []const []const u8 = &.{},
} = null,
} = &.{},
};

pub const CreateProjectServiceAccountApiKeyBody = struct {
    name: ?[]const u8 = null,
    scopes: ?[]const []const u8 = null,
};

pub const CreateResponse = struct {
    metadata: ?Metadata = null,
    top_logprobs: ?i64 = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?ServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?PromptCacheOptionsParam = null,
    previous_response_id: ?std.json.Value = null,
    model: ?ModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?ResponseTextParam = null,
    tools: ?ToolsArray = null,
    tool_choice: ?ToolChoiceParam = null,
    prompt: ?Prompt = null,
    truncation: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    input: ?InputParam = null,
    include: ?std.json.Value = null,
    parallel_tool_calls: ?std.json.Value = null,
    store: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    moderation: ?std.json.Value = null,
    stream: ?std.json.Value = null,
    stream_options: ?ResponseStreamOptions = null,
    conversation: ?std.json.Value = null,
    context_management: ?std.json.Value = null,
    max_output_tokens: ?std.json.Value = null,
};

pub const CreateRunRequest = struct {
    assistant_id: []const u8 = "",
    model: ?std.json.Value = null,
    reasoning_effort: ?ReasoningEffort = null,
    instructions: ?[]const u8 = null,
    additional_instructions: ?[]const u8 = null,
    additional_messages: ?[]const CreateMessageRequest = null,
    tools: ?[]const AssistantToolsCode = null,
    metadata: ?Metadata = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    stream: ?bool = null,
    max_prompt_tokens: ?i64 = null,
    max_completion_tokens: ?i64 = null,
    truncation_strategy: ?struct {
    @"type": []const u8 = "",
    last_messages: ?std.json.Value = null,
} = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?ParallelToolCalls = null,
    response_format: ?AssistantsApiResponseFormatOption = null,
};

pub const CreateSkillBody = struct {
    files: std.json.Value = .null,
};

pub const CreateSkillVersionBody = struct {
    files: std.json.Value = .null,
    default: ?bool = null,
};

pub const CreateSpeechRequest = struct {
    model: std.json.Value = .null,
    input: []const u8 = "",
    instructions: ?[]const u8 = null,
    voice: ?VoiceIdsOrCustomVoice = null,
    response_format: ?[]const u8 = null,
    speed: ?f64 = null,
    stream_format: ?[]const u8 = null,
};

pub const CreateSpeechResponseStreamEvent = std.json.Value;

pub const CreateSpendAlertBody = struct {
    threshold_amount: i64 = 0,
    currency: []const u8 = "",
    interval: []const u8 = "",
    notification_channel: ?SpendAlertNotificationChannel = null,
};

pub const CreateThreadAndRunRequest = struct {
    assistant_id: []const u8 = "",
    thread: ?CreateThreadRequest = null,
    model: ?std.json.Value = null,
    instructions: ?[]const u8 = null,
    tools: ?[]const AssistantToolsCode = null,
    tool_resources: ?struct {
    code_interpreter: ?struct {
    file_ids: ?[]const []const u8 = null,
} = null,
    file_search: ?struct {
    vector_store_ids: ?[]const []const u8 = null,
} = null,
} = null,
    metadata: ?Metadata = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    stream: ?bool = null,
    max_prompt_tokens: ?i64 = null,
    max_completion_tokens: ?i64 = null,
    truncation_strategy: ?struct {
    @"type": []const u8 = "",
    last_messages: ?std.json.Value = null,
} = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?ParallelToolCalls = null,
    response_format: ?AssistantsApiResponseFormatOption = null,
};

pub const CreateThreadRequest = struct {
    messages: ?[]const CreateMessageRequest = null,
    tool_resources: ?std.json.Value = null,
    metadata: ?Metadata = null,
};

pub const CreateTranscriptionRequest = struct {
    file: []const u8 = "",
    model: std.json.Value = .null,
    language: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    response_format: ?AudioResponseFormat = null,
    temperature: ?f64 = null,
    include: ?[]const TranscriptionInclude = null,
    timestamp_granularities: ?[]const []const u8 = null,
    stream: ?std.json.Value = null,
    chunking_strategy: ?std.json.Value = null,
    known_speaker_names: ?[]const []const u8 = null,
    known_speaker_references: ?[]const []const u8 = null,
};

pub const CreateTranscriptionResponseDiarizedJson = struct {
    task: []const u8 = "",
    duration: f64 = 0,
    text: []const u8 = "",
    segments: []const TranscriptionDiarizedSegment = &.{},
    usage: ?std.json.Value = null,
};

pub const CreateTranscriptionResponseJson = struct {
    text: []const u8 = "",
    logprobs: ?[]const struct {
    token: ?[]const u8 = null,
    logprob: ?f64 = null,
    bytes: ?[]const f64 = null,
} = null,
    usage: ?std.json.Value = null,
};

pub const CreateTranscriptionResponseStreamEvent = std.json.Value;

pub const CreateTranscriptionResponseVerboseJson = struct {
    language: []const u8 = "",
    duration: f64 = 0,
    text: []const u8 = "",
    words: ?[]const TranscriptionWord = null,
    segments: ?[]const TranscriptionSegment = null,
    usage: ?TranscriptTextUsageDuration = null,
};

pub const CreateTranslationRequest = struct {
    file: []const u8 = "",
    model: std.json.Value = .null,
    prompt: ?[]const u8 = null,
    response_format: ?[]const u8 = null,
    temperature: ?f64 = null,
};

pub const CreateTranslationResponseJson = struct {
    text: []const u8 = "",
};

pub const CreateTranslationResponseVerboseJson = struct {
    language: []const u8 = "",
    duration: f64 = 0,
    text: []const u8 = "",
    segments: ?[]const TranscriptionSegment = null,
};

pub const CreateUploadRequest = struct {
    filename: []const u8 = "",
    purpose: []const u8 = "",
    bytes: i64 = 0,
    mime_type: []const u8 = "",
    expires_after: ?FileExpirationAfter = null,
};

pub const CreateVectorStoreFileBatchRequest = std.json.Value;

pub const CreateVectorStoreFileRequest = struct {
    file_id: []const u8 = "",
    chunking_strategy: ?ChunkingStrategyRequestParam = null,
    attributes: ?VectorStoreFileAttributes = null,
};

pub const CreateVectorStoreRequest = struct {
    file_ids: ?[]const []const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    expires_after: ?VectorStoreExpirationAfter = null,
    chunking_strategy: ?std.json.Value = null,
    metadata: ?Metadata = null,
};

pub const CreateVideoCharacterBody = struct {
    video: []const u8 = "",
    name: []const u8 = "",
};

pub const CreateVideoEditJsonBody = struct {
    video: ?VideoReferenceInputParam = null,
    prompt: []const u8 = "",
};

pub const CreateVideoEditMultipartBody = struct {
    video: std.json.Value = .null,
    prompt: []const u8 = "",
};

pub const CreateVideoExtendJsonBody = struct {
    video: ?VideoReferenceInputParam = null,
    prompt: []const u8 = "",
    seconds: ?VideoSeconds = null,
};

pub const CreateVideoExtendMultipartBody = struct {
    video: std.json.Value = .null,
    prompt: []const u8 = "",
    seconds: ?VideoSeconds = null,
};

pub const CreateVideoJsonBody = struct {
    model: ?VideoModel = null,
    prompt: []const u8 = "",
    input_reference: ?ImageRefParam_2 = null,
    seconds: ?VideoSeconds = null,
    size: ?VideoSize = null,
};

pub const CreateVideoMultipartBody = struct {
    model: ?VideoModel = null,
    prompt: []const u8 = "",
    input_reference: ?std.json.Value = null,
    seconds: ?VideoSeconds = null,
    size: ?VideoSize = null,
};

pub const CreateVideoRemixBody = struct {
    prompt: []const u8 = "",
};

pub const CreateVoiceConsentRequest = struct {
    name: []const u8 = "",
    recording: []const u8 = "",
    language: []const u8 = "",
};

pub const CreateVoiceRequest = struct {
    name: []const u8 = "",
    audio_sample: []const u8 = "",
    consent: []const u8 = "",
};

pub const CustomGrammarFormatParam = struct {
    @"type": []const u8 = "",
    syntax: ?GrammarSyntax1 = null,
    definition: []const u8 = "",
};

pub const CustomTextFormatParam = struct {
    @"type": []const u8 = "",
};

pub const CustomToolCall = struct {
    @"type": []const u8 = "",
    id: ?[]const u8 = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    input: []const u8 = "",
};

pub const CustomToolCallOutput = struct {
    @"type": []const u8 = "",
    id: ?[]const u8 = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
};

pub const CustomToolCallOutputResource = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
    status: ?FunctionCallOutputStatusEnum = null,
    created_by: ?[]const u8 = null,
};

pub const CustomToolCallResource = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    input: []const u8 = "",
    status: ?FunctionCallStatus = null,
    created_by: ?[]const u8 = null,
};

pub const CustomToolChatCompletions = struct {
    @"type": []const u8 = "",
    custom: ?struct {
    name: []const u8 = "",
    description: ?[]const u8 = null,
    format: ?std.json.Value = null,
} = null,
};

pub const CustomToolParam = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: ?[]const u8 = null,
    format: ?std.json.Value = null,
    defer_loading: ?bool = null,
    allowed_callers: ?std.json.Value = null,
};

pub const DeleteAssistantResponse = struct {
    id: []const u8 = "",
    deleted: bool = false,
    object: []const u8 = "",
};

pub const DeleteCertificateResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
};

pub const DeleteFileResponse = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    deleted: bool = false,
};

pub const DeleteFineTuningCheckpointPermissionResponse = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    deleted: bool = false,
};

pub const DeleteMessageResponse = struct {
    id: []const u8 = "",
    deleted: bool = false,
    object: []const u8 = "",
};

pub const DeleteModelResponse = struct {
    id: []const u8 = "",
    deleted: bool = false,
    object: []const u8 = "",
};

pub const DeleteThreadResponse = struct {
    id: []const u8 = "",
    deleted: bool = false,
    object: []const u8 = "",
};

pub const DeleteVectorStoreFileResponse = struct {
    id: []const u8 = "",
    deleted: bool = false,
    object: []const u8 = "",
};

pub const DeleteVectorStoreResponse = struct {
    id: []const u8 = "",
    deleted: bool = false,
    object: []const u8 = "",
};

pub const DeletedConversation = struct {
    object: []const u8 = "",
    deleted: bool = false,
    id: []const u8 = "",
};

pub const DeletedConversationResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
    id: []const u8 = "",
};

pub const DeletedRoleAssignmentResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
};

pub const DeletedSkillResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
    id: []const u8 = "",
};

pub const DeletedSkillVersionResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
    id: []const u8 = "",
    version: []const u8 = "",
};

pub const DeletedThreadResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    deleted: bool = false,
};

pub const DeletedVideoResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
    id: []const u8 = "",
};

pub const DetailEnum = []const u8;

pub const DirectToolCallCaller = struct {
    @"type": []const u8 = "",
};

pub const DirectToolCallCallerParam = struct {
    @"type": []const u8 = "",
};

pub const DoneEvent = struct {
    event: []const u8 = "",
    data: []const u8 = "",
};

pub const DoubleClickAction = struct {
    @"type": []const u8 = "",
    x: i64 = 0,
    y: i64 = 0,
    keys: std.json.Value = .null,
};

pub const DragParam = struct {
    @"type": []const u8 = "",
    path: []const CoordParam = &.{},
    keys: ?std.json.Value = null,
};

pub const DragPoint = struct {
    x: i64 = 0,
    y: i64 = 0,
};

pub const EasyInputMessage = struct {
    role: []const u8 = "",
    content: []const u8 = "",
    phase: ?std.json.Value = null,
    @"type": ?[]const u8 = null,
};

pub const EditImageBodyJsonParam = struct {
    model: ?std.json.Value = null,
    images: []const ImageRefParam = &.{},
    mask: ?ImageRefParam = null,
    prompt: []const u8 = "",
    n: ?std.json.Value = null,
    quality: ?std.json.Value = null,
    input_fidelity: ?std.json.Value = null,
    size: ?std.json.Value = null,
    user: ?[]const u8 = null,
    output_format: ?std.json.Value = null,
    output_compression: ?std.json.Value = null,
    moderation: ?std.json.Value = null,
    background: ?std.json.Value = null,
    stream: ?std.json.Value = null,
    partial_images: ?PartialImages = null,
};

pub const Embedding = struct {
    index: i64 = 0,
    embedding: []const f64 = &.{},
    object: []const u8 = "",
};

pub const EmptyModelParam = std.json.Value;

pub const Error = struct {
    code: std.json.Value = .null,
    message: []const u8 = "",
    param: std.json.Value = .null,
    @"type": []const u8 = "",
};

pub const Error_2 = struct {
    code: []const u8 = "",
    message: []const u8 = "",
};

pub const ErrorEvent = struct {
    event: []const u8 = "",
    data: ?Error = null,
};

pub const ErrorResponse = struct {
    @"error": ?Error = null,
};

pub const Eval = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    data_source_config: std.json.Value = .null,
    testing_criteria: []const EvalGraderLabelModel = &.{},
    created_at: i64 = 0,
    metadata: ?Metadata = null,
};

pub const EvalApiError = struct {
    code: []const u8 = "",
    message: []const u8 = "",
};

pub const EvalCustomDataSourceConfig = struct {
    @"type": []const u8 = "",
    schema: std.json.Value = .null,
};

pub const EvalGraderLabelModel = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    model: []const u8 = "",
    input: []const EvalItem = &.{},
    labels: []const []const u8 = &.{},
    passing_labels: []const []const u8 = &.{},
};

pub const EvalGraderPython = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    source: []const u8 = "",
    image_tag: ?[]const u8 = null,
    pass_threshold: ?f64 = null,
};

pub const EvalGraderScoreModel = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    model: []const u8 = "",
    sampling_params: ?struct {
    seed: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    temperature: ?std.json.Value = null,
    max_completions_tokens: ?std.json.Value = null,
    reasoning_effort: ?ReasoningEffort = null,
} = null,
    input: []const EvalItem = &.{},
    range: ?[]const f64 = null,
    pass_threshold: ?f64 = null,
};

pub const EvalGraderStringCheck = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    input: []const u8 = "",
    reference: []const u8 = "",
    operation: []const u8 = "",
};

pub const EvalGraderTextSimilarity = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    input: []const u8 = "",
    reference: []const u8 = "",
    evaluation_metric: []const u8 = "",
    pass_threshold: f64 = 0,
};

pub const EvalItem = struct {
    role: []const u8 = "",
    content: ?EvalItemContent = null,
    @"type": ?[]const u8 = null,
};

pub const EvalItemContent = std.json.Value;

pub const EvalItemContentArray = []const EvalItemContentItem;

pub const EvalItemContentItem = std.json.Value;

pub const EvalItemContentOutputText = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const EvalItemContentText = []const u8;

pub const EvalItemInputImage = struct {
    @"type": []const u8 = "",
    image_url: []const u8 = "",
    detail: ?[]const u8 = null,
};

pub const EvalJsonlFileContentSource = struct {
    @"type": []const u8 = "",
    content: []const struct {
    item: std.json.Value = .null,
    sample: ?std.json.Value = null,
} = &.{},
};

pub const EvalJsonlFileIdSource = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
};

pub const EvalList = struct {
    object: []const u8 = "",
    data: []const Eval = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const EvalLogsDataSourceConfig = struct {
    @"type": []const u8 = "",
    metadata: ?Metadata = null,
    schema: std.json.Value = .null,
};

pub const EvalResponsesSource = struct {
    @"type": []const u8 = "",
    metadata: ?std.json.Value = null,
    model: ?std.json.Value = null,
    instructions_search: ?std.json.Value = null,
    created_after: ?std.json.Value = null,
    created_before: ?std.json.Value = null,
    reasoning_effort: ?std.json.Value = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    users: ?std.json.Value = null,
    tools: ?std.json.Value = null,
};

pub const EvalRun = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    eval_id: []const u8 = "",
    status: []const u8 = "",
    model: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    report_url: []const u8 = "",
    result_counts: ?struct {
    total: i64 = 0,
    errored: i64 = 0,
    failed: i64 = 0,
    passed: i64 = 0,
} = null,
    per_model_usage: []const struct {
    model_name: []const u8 = "",
    invocation_count: i64 = 0,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    total_tokens: i64 = 0,
    cached_tokens: i64 = 0,
} = &.{},
    per_testing_criteria_results: []const struct {
    testing_criteria: []const u8 = "",
    passed: i64 = 0,
    failed: i64 = 0,
} = &.{},
    data_source: std.json.Value = .null,
    metadata: ?Metadata = null,
    @"error": ?EvalApiError = null,
};

pub const EvalRunList = struct {
    object: []const u8 = "",
    data: []const EvalRun = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const EvalRunOutputItem = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    run_id: []const u8 = "",
    eval_id: []const u8 = "",
    created_at: i64 = 0,
    status: []const u8 = "",
    datasource_item_id: i64 = 0,
    datasource_item: std.json.Value = .null,
    results: []const EvalRunOutputItemResult = &.{},
    sample: ?struct {
    input: []const struct {
    role: []const u8 = "",
    content: []const u8 = "",
} = &.{},
    output: []const struct {
    role: ?[]const u8 = null,
    content: ?[]const u8 = null,
} = &.{},
    finish_reason: []const u8 = "",
    model: []const u8 = "",
    usage: ?struct {
    total_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    prompt_tokens: i64 = 0,
    cached_tokens: i64 = 0,
} = null,
    @"error": ?EvalApiError = null,
    temperature: f64 = 0,
    max_completion_tokens: i64 = 0,
    top_p: f64 = 0,
    seed: i64 = 0,
} = null,
};

pub const EvalRunOutputItemList = struct {
    object: []const u8 = "",
    data: []const EvalRunOutputItem = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const EvalRunOutputItemResult = struct {
    name: []const u8 = "",
    @"type": ?[]const u8 = null,
    score: f64 = 0,
    passed: bool = false,
    sample: ?std.json.Value = null,
};

pub const EvalStoredCompletionsDataSourceConfig = struct {
    @"type": []const u8 = "",
    metadata: ?Metadata = null,
    schema: std.json.Value = .null,
};

pub const EvalStoredCompletionsSource = struct {
    @"type": []const u8 = "",
    metadata: ?Metadata = null,
    model: ?std.json.Value = null,
    created_after: ?std.json.Value = null,
    created_before: ?std.json.Value = null,
    limit: ?std.json.Value = null,
};

pub const ExpiresAfterParam = struct {
    anchor: []const u8 = "",
    seconds: i64 = 0,
};

pub const FileAnnotation = struct {
    @"type": []const u8 = "",
    source: ?FileAnnotationSource = null,
};

pub const FileAnnotationSource = struct {
    @"type": []const u8 = "",
    filename: []const u8 = "",
};

pub const FileCitationBody = struct {
    @"type": []const u8 = "",
    file_id: []const u8 = "",
    index: i64 = 0,
    filename: []const u8 = "",
};

pub const FileCitationParam = struct {
    @"type": []const u8 = "",
    index: i64 = 0,
    file_id: []const u8 = "",
    filename: []const u8 = "",
};

pub const FileDetailEnum = []const u8;

pub const FileExpirationAfter = struct {
    anchor: []const u8 = "",
    seconds: i64 = 0,
};

pub const FileInputDetail = []const u8;

pub const FilePath = struct {
    @"type": []const u8 = "",
    file_id: []const u8 = "",
    index: i64 = 0,
};

pub const FileSearchRanker = []const u8;

pub const FileSearchRankingOptions = struct {
    ranker: ?FileSearchRanker = null,
    score_threshold: f64 = 0,
};

pub const FileSearchTool = struct {
    @"type": []const u8 = "",
    vector_store_ids: []const []const u8 = &.{},
    max_num_results: ?i64 = null,
    ranking_options: ?RankingOptions = null,
    filters: ?std.json.Value = null,
};

pub const FileSearchToolCall = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    status: []const u8 = "",
    queries: []const []const u8 = &.{},
    results: ?std.json.Value = null,
};

pub const FileUploadParam = struct {
    enabled: ?bool = null,
    max_file_size: ?i64 = null,
    max_files: ?i64 = null,
};

pub const Filters = std.json.Value;

pub const FineTuneChatCompletionRequestAssistantMessage = struct {
    weight: ?[]const u8 = null,
    content: ?std.json.Value = null,
    refusal: ?std.json.Value = null,
    role: []const u8 = "",
    name: ?[]const u8 = null,
    audio: ?std.json.Value = null,
    tool_calls: ?ChatCompletionMessageToolCalls = null,
    function_call: ?std.json.Value = null,
};

pub const FineTuneDPOHyperparameters = struct {
    beta: ?std.json.Value = null,
    batch_size: ?std.json.Value = null,
    learning_rate_multiplier: ?std.json.Value = null,
    n_epochs: ?std.json.Value = null,
};

pub const FineTuneDPOMethod = struct {
    hyperparameters: ?FineTuneDPOHyperparameters = null,
};

pub const FineTuneMethod = struct {
    @"type": []const u8 = "",
    supervised: ?FineTuneSupervisedMethod = null,
    dpo: ?FineTuneDPOMethod = null,
    reinforcement: ?FineTuneReinforcementMethod = null,
};

pub const FineTuneReinforcementHyperparameters = struct {
    batch_size: ?std.json.Value = null,
    learning_rate_multiplier: ?std.json.Value = null,
    n_epochs: ?std.json.Value = null,
    reasoning_effort: ?[]const u8 = null,
    compute_multiplier: ?std.json.Value = null,
    eval_interval: ?std.json.Value = null,
    eval_samples: ?std.json.Value = null,
};

pub const FineTuneReinforcementMethod = struct {
    grader: std.json.Value = .null,
    hyperparameters: ?FineTuneReinforcementHyperparameters = null,
};

pub const FineTuneSupervisedHyperparameters = struct {
    batch_size: ?std.json.Value = null,
    learning_rate_multiplier: ?std.json.Value = null,
    n_epochs: ?std.json.Value = null,
};

pub const FineTuneSupervisedMethod = struct {
    hyperparameters: ?FineTuneSupervisedHyperparameters = null,
};

pub const FineTuningCheckpointPermission = struct {
    id: []const u8 = "",
    created_at: i64 = 0,
    project_id: []const u8 = "",
    object: []const u8 = "",
};

pub const FineTuningIntegration = struct {
    @"type": []const u8 = "",
    wandb: ?struct {
    project: []const u8 = "",
    name: ?std.json.Value = null,
    entity: ?std.json.Value = null,
    tags: ?[]const []const u8 = null,
} = null,
};

pub const FineTuningJob = struct {
    id: []const u8 = "",
    created_at: i64 = 0,
    @"error": std.json.Value = .null,
    fine_tuned_model: std.json.Value = .null,
    finished_at: std.json.Value = .null,
    hyperparameters: ?struct {
    batch_size: ?std.json.Value = null,
    learning_rate_multiplier: ?std.json.Value = null,
    n_epochs: ?std.json.Value = null,
} = null,
    model: []const u8 = "",
    object: []const u8 = "",
    organization_id: []const u8 = "",
    result_files: []const []const u8 = &.{},
    status: []const u8 = "",
    trained_tokens: std.json.Value = .null,
    training_file: []const u8 = "",
    validation_file: std.json.Value = .null,
    integrations: ?std.json.Value = null,
    seed: i64 = 0,
    estimated_finish: ?std.json.Value = null,
    method: ?FineTuneMethod = null,
    metadata: ?Metadata = null,
};

pub const FineTuningJobCheckpoint = struct {
    id: []const u8 = "",
    created_at: i64 = 0,
    fine_tuned_model_checkpoint: []const u8 = "",
    step_number: i64 = 0,
    metrics: ?struct {
    step: ?f64 = null,
    train_loss: ?f64 = null,
    train_mean_token_accuracy: ?f64 = null,
    valid_loss: ?f64 = null,
    valid_mean_token_accuracy: ?f64 = null,
    full_valid_loss: ?f64 = null,
    full_valid_mean_token_accuracy: ?f64 = null,
} = null,
    fine_tuning_job_id: []const u8 = "",
    object: []const u8 = "",
};

pub const FineTuningJobEvent = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    created_at: i64 = 0,
    level: []const u8 = "",
    message: []const u8 = "",
    @"type": ?[]const u8 = null,
    data: ?std.json.Value = null,
};

pub const FunctionAndCustomToolCallOutput = std.json.Value;

pub const FunctionCallItemStatus = []const u8;

pub const FunctionCallOutputItemParam = struct {
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    @"type": []const u8 = "",
    output: std.json.Value = .null,
    caller: ?std.json.Value = null,
    status: ?std.json.Value = null,
};

pub const FunctionCallOutputStatusEnum = []const u8;

pub const FunctionCallStatus = []const u8;

pub const FunctionObject = struct {
    description: ?[]const u8 = null,
    name: []const u8 = "",
    parameters: ?FunctionParameters = null,
    strict: ?std.json.Value = null,
};

pub const FunctionShellAction = struct {
    commands: []const []const u8 = &.{},
    timeout_ms: std.json.Value = .null,
    max_output_length: std.json.Value = .null,
};

pub const FunctionShellActionParam = struct {
    commands: []const []const u8 = &.{},
    timeout_ms: ?std.json.Value = null,
    max_output_length: ?std.json.Value = null,
};

pub const FunctionShellCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    action: ?FunctionShellAction = null,
    status: ?FunctionShellCallStatus = null,
    environment: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const FunctionShellCallItemParam = struct {
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    @"type": []const u8 = "",
    action: ?FunctionShellActionParam = null,
    status: ?std.json.Value = null,
    environment: ?std.json.Value = null,
};

pub const FunctionShellCallItemStatus = []const u8;

pub const FunctionShellCallOutput = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    status: ?FunctionShellCallOutputStatusEnum = null,
    output: []const FunctionShellCallOutputContent = &.{},
    max_output_length: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const FunctionShellCallOutputContent = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    outcome: std.json.Value = .null,
    created_by: ?[]const u8 = null,
};

pub const FunctionShellCallOutputContentParam = struct {
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    outcome: ?FunctionShellCallOutputOutcomeParam = null,
};

pub const FunctionShellCallOutputExitOutcome = struct {
    @"type": []const u8 = "",
    exit_code: i64 = 0,
};

pub const FunctionShellCallOutputExitOutcomeParam = struct {
    @"type": []const u8 = "",
    exit_code: i64 = 0,
};

pub const FunctionShellCallOutputItemParam = struct {
    id: ?std.json.Value = null,
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    @"type": []const u8 = "",
    output: []const FunctionShellCallOutputContentParam = &.{},
    status: ?std.json.Value = null,
    max_output_length: ?std.json.Value = null,
};

pub const FunctionShellCallOutputOutcomeParam = std.json.Value;

pub const FunctionShellCallOutputStatusEnum = []const u8;

pub const FunctionShellCallOutputTimeoutOutcome = struct {
    @"type": []const u8 = "",
};

pub const FunctionShellCallOutputTimeoutOutcomeParam = struct {
    @"type": []const u8 = "",
};

pub const FunctionShellCallStatus = []const u8;

pub const FunctionShellToolParam = struct {
    @"type": []const u8 = "",
    environment: ?std.json.Value = null,
    allowed_callers: ?std.json.Value = null,
};

pub const FunctionTool = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: ?std.json.Value = null,
    parameters: std.json.Value = .null,
    output_schema: ?std.json.Value = null,
    strict: std.json.Value = .null,
    defer_loading: ?bool = null,
    allowed_callers: ?std.json.Value = null,
};

pub const FunctionToolCall = struct {
    id: ?[]const u8 = null,
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    arguments: []const u8 = "",
    status: ?[]const u8 = null,
};

pub const FunctionToolCallOutput = struct {
    id: ?[]const u8 = null,
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
    status: ?[]const u8 = null,
};

pub const FunctionToolCallOutputResource = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    output: std.json.Value = .null,
    status: ?FunctionCallOutputStatusEnum = null,
    created_by: ?[]const u8 = null,
};

pub const FunctionToolCallResource = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    caller: ?std.json.Value = null,
    namespace: ?[]const u8 = null,
    name: []const u8 = "",
    arguments: []const u8 = "",
    status: ?FunctionCallStatus = null,
    created_by: ?[]const u8 = null,
};

pub const FunctionToolParam = struct {
    name: []const u8 = "",
    description: ?std.json.Value = null,
    parameters: ?std.json.Value = null,
    strict: ?std.json.Value = null,
    @"type": []const u8 = "",
    output_schema: ?std.json.Value = null,
    defer_loading: ?bool = null,
    allowed_callers: ?std.json.Value = null,
};

pub const GraderLabelModel = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    model: []const u8 = "",
    input: []const EvalItem = &.{},
    labels: []const []const u8 = &.{},
    passing_labels: []const []const u8 = &.{},
};

pub const GraderMulti = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    graders: std.json.Value = .null,
    calculate_output: []const u8 = "",
};

pub const GraderPython = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    source: []const u8 = "",
    image_tag: ?[]const u8 = null,
};

pub const GraderScoreModel = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    model: []const u8 = "",
    sampling_params: ?struct {
    seed: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    temperature: ?std.json.Value = null,
    max_completions_tokens: ?std.json.Value = null,
    reasoning_effort: ?ReasoningEffort = null,
} = null,
    input: []const EvalItem = &.{},
    range: ?[]const f64 = null,
};

pub const GraderStringCheck = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    input: []const u8 = "",
    reference: []const u8 = "",
    operation: []const u8 = "",
};

pub const GraderTextSimilarity = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    input: []const u8 = "",
    reference: []const u8 = "",
    evaluation_metric: []const u8 = "",
};

pub const GrammarSyntax1 = []const u8;

pub const Group = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    scim_managed: bool = false,
};

pub const GroupDeletedResource = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const GroupListResource = struct {
    object: []const u8 = "",
    data: []const GroupResponse = &.{},
    has_more: bool = false,
    next: std.json.Value = .null,
};

pub const GroupMemberUser = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    email: std.json.Value = .null,
    picture: std.json.Value = .null,
    is_service_account: std.json.Value = .null,
    user_type: []const u8 = "",
};

pub const GroupResourceWithSuccess = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    is_scim_managed: bool = false,
};

pub const GroupResponse = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    is_scim_managed: bool = false,
    group_type: []const u8 = "",
};

pub const GroupRoleAssignment = struct {
    object: []const u8 = "",
    group: ?Group = null,
    role: ?Role = null,
};

pub const GroupUser = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    email: std.json.Value = .null,
};

pub const GroupUserAssignment = struct {
    object: []const u8 = "",
    user_id: []const u8 = "",
    group_id: []const u8 = "",
};

pub const GroupUserDeletedResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
};

pub const HistoryParam = struct {
    enabled: ?bool = null,
    recent_threads: ?i64 = null,
};

pub const HostedToolPermission = struct {
    enabled: bool = false,
};

pub const HostedToolPermissionUpdate = struct {
    enabled: bool = false,
};

pub const HybridSearchOptions = struct {
    embedding_weight: f64 = 0,
    text_weight: f64 = 0,
};

pub const Image = struct {
    b64_json: ?[]const u8 = null,
    url: ?[]const u8 = null,
    revised_prompt: ?[]const u8 = null,
};

pub const ImageDetail = []const u8;

pub const ImageEditCompletedEvent = struct {
    @"type": []const u8 = "",
    b64_json: []const u8 = "",
    created_at: i64 = 0,
    size: []const u8 = "",
    quality: []const u8 = "",
    background: []const u8 = "",
    output_format: []const u8 = "",
    usage: ?ImagesUsage = null,
};

pub const ImageEditPartialImageEvent = struct {
    @"type": []const u8 = "",
    b64_json: []const u8 = "",
    created_at: i64 = 0,
    size: []const u8 = "",
    quality: []const u8 = "",
    background: []const u8 = "",
    output_format: []const u8 = "",
    partial_image_index: i64 = 0,
};

pub const ImageEditStreamEvent = std.json.Value;

pub const ImageGenActionEnum = []const u8;

pub const ImageGenCompletedEvent = struct {
    @"type": []const u8 = "",
    b64_json: []const u8 = "",
    created_at: i64 = 0,
    size: []const u8 = "",
    quality: []const u8 = "",
    background: []const u8 = "",
    output_format: []const u8 = "",
    usage: ?ImagesUsage = null,
};

pub const ImageGenInputUsageDetails = struct {
    text_tokens: i64 = 0,
    image_tokens: i64 = 0,
};

pub const ImageGenOutputTokensDetails = struct {
    image_tokens: i64 = 0,
    text_tokens: i64 = 0,
};

pub const ImageGenPartialImageEvent = struct {
    @"type": []const u8 = "",
    b64_json: []const u8 = "",
    created_at: i64 = 0,
    size: []const u8 = "",
    quality: []const u8 = "",
    background: []const u8 = "",
    output_format: []const u8 = "",
    partial_image_index: i64 = 0,
};

pub const ImageGenStreamEvent = std.json.Value;

pub const ImageGenTool = struct {
    @"type": []const u8 = "",
    model: ?std.json.Value = null,
    quality: ?[]const u8 = null,
    size: ?std.json.Value = null,
    output_format: ?[]const u8 = null,
    output_compression: ?i64 = null,
    moderation: ?[]const u8 = null,
    background: ?[]const u8 = null,
    input_fidelity: ?std.json.Value = null,
    input_image_mask: ?struct {
    image_url: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
} = null,
    partial_images: ?i64 = null,
    action: ?ImageGenActionEnum = null,
};

pub const ImageGenToolCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    status: []const u8 = "",
    result: std.json.Value = .null,
};

pub const ImageGenUsage = struct {
    input_tokens: i64 = 0,
    total_tokens: i64 = 0,
    output_tokens: i64 = 0,
    output_tokens_details: ?ImageGenOutputTokensDetails = null,
    input_tokens_details: ?ImageGenInputUsageDetails = null,
};

pub const ImageRefParam = std.json.Value;

pub const ImageRefParam_2 = struct {
    image_url: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
};

pub const ImagesResponse = struct {
    created: i64 = 0,
    data: ?[]const Image = null,
    background: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    size: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    usage: ?ImageGenUsage = null,
};

pub const ImagesUsage = struct {
    total_tokens: i64 = 0,
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    input_tokens_details: ?struct {
    text_tokens: i64 = 0,
    image_tokens: i64 = 0,
} = null,
};

pub const IncludeEnum = []const u8;

pub const InferenceOptions = struct {
    tool_choice: std.json.Value = .null,
    model: std.json.Value = .null,
};

pub const InlineSkillParam = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    source: ?InlineSkillSourceParam = null,
};

pub const InlineSkillSourceParam = struct {
    @"type": []const u8 = "",
    media_type: []const u8 = "",
    data: []const u8 = "",
};

pub const InputAudio = struct {
    @"type": []const u8 = "",
    input_audio: ?struct {
    data: []const u8 = "",
    format: []const u8 = "",
} = null,
};

pub const InputContent = std.json.Value;

pub const InputFidelity = []const u8;

pub const InputFileContent = struct {
    @"type": []const u8 = "",
    file_id: ?std.json.Value = null,
    filename: ?[]const u8 = null,
    file_data: ?[]const u8 = null,
    prompt_cache_breakpoint: ?PromptCacheBreakpointConfig = null,
    file_url: ?[]const u8 = null,
    detail: ?FileInputDetail = null,
};

pub const InputFileContentParam = struct {
    @"type": []const u8 = "",
    file_id: ?std.json.Value = null,
    filename: ?std.json.Value = null,
    file_data: ?std.json.Value = null,
    file_url: ?std.json.Value = null,
    detail: ?FileDetailEnum = null,
    prompt_cache_breakpoint: ?std.json.Value = null,
};

pub const InputImageContent = struct {
    @"type": []const u8 = "",
    image_url: ?std.json.Value = null,
    file_id: ?std.json.Value = null,
    detail: ?ImageDetail = null,
    prompt_cache_breakpoint: ?PromptCacheBreakpointConfig = null,
};

pub const InputImageContentParamAutoParam = struct {
    @"type": []const u8 = "",
    image_url: ?std.json.Value = null,
    file_id: ?std.json.Value = null,
    detail: ?std.json.Value = null,
    prompt_cache_breakpoint: ?std.json.Value = null,
};

pub const InputItem = std.json.Value;

pub const InputMessage = struct {
    @"type": ?[]const u8 = null,
    role: []const u8 = "",
    status: ?[]const u8 = null,
    content: ?InputMessageContentList = null,
};

pub const InputMessageContentList = []const InputContent;

pub const InputMessageResource = struct {
    @"type": []const u8 = "",
    role: []const u8 = "",
    status: ?[]const u8 = null,
    content: ?InputMessageContentList = null,
    id: []const u8 = "",
};

pub const InputParam = std.json.Value;

pub const InputTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    prompt_cache_breakpoint: ?PromptCacheBreakpointConfig = null,
};

pub const InputTextContentParam = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    prompt_cache_breakpoint: ?std.json.Value = null,
};

pub const Invite = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    email: []const u8 = "",
    role: []const u8 = "",
    status: []const u8 = "",
    created_at: i64 = 0,
    expires_at: ?std.json.Value = null,
    accepted_at: ?std.json.Value = null,
    projects: []const struct {
    id: []const u8 = "",
    role: []const u8 = "",
} = &.{},
};

pub const InviteDeleteResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const InviteListResponse = struct {
    object: []const u8 = "",
    data: []const Invite = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const InviteProjectGroupBody = struct {
    group_id: []const u8 = "",
    role: []const u8 = "",
};

pub const InviteRequest = struct {
    email: []const u8 = "",
    role: []const u8 = "",
    projects: ?[]const struct {
    id: []const u8 = "",
    role: []const u8 = "",
} = null,
};

pub const Item = std.json.Value;

pub const ItemField = std.json.Value;

pub const ItemReferenceParam = struct {
    @"type": ?std.json.Value = null,
    id: []const u8 = "",
};

pub const ItemResource = std.json.Value;

pub const KeyPressAction = struct {
    @"type": []const u8 = "",
    keys: []const []const u8 = &.{},
};

pub const ListAssistantsResponse = struct {
    object: []const u8 = "",
    data: []const AssistantObject = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ListAuditLogsResponse = struct {
    object: []const u8 = "",
    data: []const AuditLog = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ListBatchesResponse = struct {
    data: []const Batch = &.{},
    first_id: ?[]const u8 = null,
    last_id: ?[]const u8 = null,
    has_more: bool = false,
    object: []const u8 = "",
};

pub const ListCertificatesResponse = struct {
    data: []const OrganizationCertificate = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
    object: []const u8 = "",
};

pub const ListFilesResponse = struct {
    object: []const u8 = "",
    data: []const OpenAIFile = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ListFineTuningCheckpointPermissionResponse = struct {
    data: []const FineTuningCheckpointPermission = &.{},
    object: []const u8 = "",
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ListFineTuningJobCheckpointsResponse = struct {
    data: []const FineTuningJobCheckpoint = &.{},
    object: []const u8 = "",
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ListFineTuningJobEventsResponse = struct {
    data: []const FineTuningJobEvent = &.{},
    object: []const u8 = "",
    has_more: bool = false,
};

pub const ListMessagesResponse = struct {
    object: []const u8 = "",
    data: []const MessageObject = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ListModelsResponse = struct {
    object: []const u8 = "",
    data: []const Model = &.{},
};

pub const ListPaginatedFineTuningJobsResponse = struct {
    data: []const FineTuningJob = &.{},
    has_more: bool = false,
    object: []const u8 = "",
};

pub const ListProjectCertificatesResponse = struct {
    data: []const OrganizationProjectCertificate = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
    object: []const u8 = "",
};

pub const ListRunStepsResponse = struct {
    object: []const u8 = "",
    data: []const RunStepObject = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ListRunsResponse = struct {
    object: []const u8 = "",
    data: []const RunObject = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ListVectorStoreFilesResponse = struct {
    object: []const u8 = "",
    data: []const VectorStoreFileObject = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const ListVectorStoresResponse = struct {
    object: []const u8 = "",
    data: []const VectorStoreObject = &.{},
    first_id: []const u8 = "",
    last_id: []const u8 = "",
    has_more: bool = false,
};

pub const LocalEnvironmentParam = struct {
    @"type": []const u8 = "",
    skills: ?[]const LocalSkillParam = null,
};

pub const LocalEnvironmentResource = struct {
    @"type": []const u8 = "",
};

pub const LocalShellExecAction = struct {
    @"type": []const u8 = "",
    command: []const []const u8 = &.{},
    timeout_ms: ?std.json.Value = null,
    working_directory: ?std.json.Value = null,
    env: std.json.Value = .null,
    user: ?std.json.Value = null,
};

pub const LocalShellToolCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    action: ?LocalShellExecAction = null,
    status: []const u8 = "",
};

pub const LocalShellToolCallOutput = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    output: []const u8 = "",
    status: ?std.json.Value = null,
};

pub const LocalShellToolParam = struct {
    @"type": []const u8 = "",
};

pub const LocalSkillParam = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    path: []const u8 = "",
};

pub const LockedStatus = struct {
    @"type": []const u8 = "",
    reason: std.json.Value = .null,
};

pub const LogProb = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: []const i64 = &.{},
    top_logprobs: []const TopLogProb = &.{},
};

pub const LogProbProperties = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: []const i64 = &.{},
};

pub const MCPApprovalRequest = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};

pub const MCPApprovalResponse = struct {
    @"type": []const u8 = "",
    id: ?std.json.Value = null,
    approval_request_id: []const u8 = "",
    approve: bool = false,
    reason: ?std.json.Value = null,
};

pub const MCPApprovalResponseResource = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    approval_request_id: []const u8 = "",
    approve: bool = false,
    reason: ?std.json.Value = null,
};

pub const MCPListTools = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    tools: []const MCPListToolsTool = &.{},
    @"error": ?std.json.Value = null,
};

pub const MCPListToolsTool = struct {
    name: []const u8 = "",
    description: ?std.json.Value = null,
    input_schema: std.json.Value = .null,
    annotations: ?std.json.Value = null,
};

pub const MCPTool = struct {
    @"type": []const u8 = "",
    server_label: []const u8 = "",
    server_url: ?[]const u8 = null,
    connector_id: ?[]const u8 = null,
    tunnel_id: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    server_description: ?[]const u8 = null,
    headers: ?std.json.Value = null,
    allowed_tools: ?std.json.Value = null,
    allowed_callers: ?std.json.Value = null,
    require_approval: ?std.json.Value = null,
    defer_loading: ?bool = null,
};

pub const MCPToolCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
    output: ?std.json.Value = null,
    @"error": ?std.json.Value = null,
    status: ?MCPToolCallStatus = null,
    approval_request_id: ?std.json.Value = null,
};

pub const MCPToolCallStatus = []const u8;

pub const MCPToolFilter = struct {
    tool_names: ?[]const []const u8 = null,
    read_only: ?bool = null,
};

pub const Message = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    status: ?MessageStatus = null,
    role: ?MessageRole = null,
    content: []const InputTextContent = &.{},
    phase: ?std.json.Value = null,
};

pub const MessageContentImageFileObject = struct {
    @"type": []const u8 = "",
    image_file: ?struct {
    file_id: []const u8 = "",
    detail: ?[]const u8 = null,
} = null,
};

pub const MessageContentImageUrlObject = struct {
    @"type": []const u8 = "",
    image_url: ?struct {
    url: []const u8 = "",
    detail: ?[]const u8 = null,
} = null,
};

pub const MessageContentRefusalObject = struct {
    @"type": []const u8 = "",
    refusal: []const u8 = "",
};

pub const MessageContentTextAnnotationsFileCitationObject = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    file_citation: ?struct {
    file_id: []const u8 = "",
} = null,
    start_index: i64 = 0,
    end_index: i64 = 0,
};

pub const MessageContentTextAnnotationsFilePathObject = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    file_path: ?struct {
    file_id: []const u8 = "",
} = null,
    start_index: i64 = 0,
    end_index: i64 = 0,
};

pub const MessageContentTextObject = struct {
    @"type": []const u8 = "",
    text: ?struct {
    value: []const u8 = "",
    annotations: []const MessageContentTextAnnotationsFileCitationObject = &.{},
} = null,
};

pub const MessageDeltaContentImageFileObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    image_file: ?struct {
    file_id: ?[]const u8 = null,
    detail: ?[]const u8 = null,
} = null,
};

pub const MessageDeltaContentImageUrlObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    image_url: ?struct {
    url: ?[]const u8 = null,
    detail: ?[]const u8 = null,
} = null,
};

pub const MessageDeltaContentRefusalObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    refusal: ?[]const u8 = null,
};

pub const MessageDeltaContentTextAnnotationsFileCitationObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    text: ?[]const u8 = null,
    file_citation: ?struct {
    file_id: ?[]const u8 = null,
    quote: ?[]const u8 = null,
} = null,
    start_index: ?i64 = null,
    end_index: ?i64 = null,
};

pub const MessageDeltaContentTextAnnotationsFilePathObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    text: ?[]const u8 = null,
    file_path: ?struct {
    file_id: ?[]const u8 = null,
} = null,
    start_index: ?i64 = null,
    end_index: ?i64 = null,
};

pub const MessageDeltaContentTextObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    text: ?struct {
    value: ?[]const u8 = null,
    annotations: ?[]const MessageDeltaContentTextAnnotationsFileCitationObject = null,
} = null,
};

pub const MessageDeltaObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    delta: ?struct {
    role: ?[]const u8 = null,
    content: ?[]const MessageDeltaContentImageFileObject = null,
} = null,
};

pub const MessageObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    status: []const u8 = "",
    incomplete_details: std.json.Value = .null,
    completed_at: std.json.Value = .null,
    incomplete_at: std.json.Value = .null,
    role: []const u8 = "",
    content: []const MessageContentImageFileObject = &.{},
    assistant_id: std.json.Value = .null,
    run_id: std.json.Value = .null,
    attachments: std.json.Value = .null,
    metadata: ?Metadata = null,
};

pub const MessagePhase = []const u8;

pub const MessagePhase_2 = []const u8;

pub const MessageRequestContentTextObject = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const MessageRole = []const u8;

pub const MessageStatus = []const u8;

pub const MessageStreamEvent = std.json.Value;

pub const Metadata = std.json.Value;

pub const Model = struct {
    id: []const u8 = "",
    created: i64 = 0,
    object: []const u8 = "",
    owned_by: []const u8 = "",
};

pub const ModelIds = std.json.Value;

pub const ModelIdsCompaction = std.json.Value;

pub const ModelIdsResponses = std.json.Value;

pub const ModelIdsShared = std.json.Value;

pub const ModelResponseProperties = struct {
    metadata: ?Metadata = null,
    top_logprobs: ?std.json.Value = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?ServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
};

pub const Moderation = struct {
    input: std.json.Value = .null,
    output: std.json.Value = .null,
};

pub const ModerationConfigParam = struct {
    mode: ?ModerationMode = null,
};

pub const ModerationErrorBody = struct {
    @"type": []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
};

pub const ModerationInputType = []const u8;

pub const ModerationMode = []const u8;

pub const ModerationParam = struct {
    model: []const u8 = "",
    policy: ?std.json.Value = null,
};

pub const ModerationPolicyParam = struct {
    input: ?std.json.Value = null,
    output: ?std.json.Value = null,
};

pub const ModerationResultBody = struct {
    @"type": []const u8 = "",
    model: []const u8 = "",
    flagged: bool = false,
    categories: std.json.Value = .null,
    category_scores: std.json.Value = .null,
    category_applied_input_types: std.json.Value = .null,
};

pub const ModifyAssistantRequest = struct {
    model: ?std.json.Value = null,
    reasoning_effort: ?ReasoningEffort = null,
    name: ?std.json.Value = null,
    description: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    tools: ?[]const AssistantToolsCode = null,
    tool_resources: ?std.json.Value = null,
    metadata: ?Metadata = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    response_format: ?std.json.Value = null,
};

pub const ModifyCertificateRequest = struct {
    name: ?[]const u8 = null,
};

pub const ModifyMessageRequest = struct {
    metadata: ?Metadata = null,
};

pub const ModifyRunRequest = struct {
    metadata: ?Metadata = null,
};

pub const ModifyThreadRequest = struct {
    tool_resources: ?std.json.Value = null,
    metadata: ?Metadata = null,
};

pub const MoveParam = struct {
    @"type": []const u8 = "",
    x: i64 = 0,
    y: i64 = 0,
    keys: ?std.json.Value = null,
};

pub const NamespaceToolParam = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    tools: []const FunctionToolParam = &.{},
};

pub const NoiseReductionType = []const u8;

pub const OpenAIFile = struct {
    id: []const u8 = "",
    bytes: i64 = 0,
    created_at: i64 = 0,
    expires_at: ?i64 = null,
    filename: []const u8 = "",
    object: []const u8 = "",
    purpose: []const u8 = "",
    status: []const u8 = "",
    status_details: ?[]const u8 = null,
};

pub const OrderEnum = []const u8;

pub const OrganizationCertificate = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: std.json.Value = .null,
    created_at: i64 = 0,
    certificate_details: ?struct {
    valid_at: ?i64 = null,
    expires_at: ?i64 = null,
} = null,
    active: bool = false,
};

pub const OrganizationCertificateActivationResponse = struct {
    object: []const u8 = "",
    data: []const OrganizationCertificate = &.{},
};

pub const OrganizationCertificateDeactivationResponse = struct {
    object: []const u8 = "",
    data: []const OrganizationCertificate = &.{},
};

pub const OrganizationDataRetention = struct {
    object: []const u8 = "",
    @"type": []const u8 = "",
};

pub const OrganizationProjectCertificate = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: std.json.Value = .null,
    created_at: i64 = 0,
    certificate_details: ?struct {
    valid_at: ?i64 = null,
    expires_at: ?i64 = null,
} = null,
    active: bool = false,
};

pub const OrganizationProjectCertificateActivationResponse = struct {
    object: []const u8 = "",
    data: []const OrganizationProjectCertificate = &.{},
};

pub const OrganizationProjectCertificateDeactivationResponse = struct {
    object: []const u8 = "",
    data: []const OrganizationProjectCertificate = &.{},
};

pub const OrganizationSpendAlert = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    threshold_amount: i64 = 0,
    currency: []const u8 = "",
    interval: []const u8 = "",
    notification_channel: ?SpendAlertNotificationChannel = null,
};

pub const OrganizationSpendAlertDeletedResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    deleted: bool = false,
};

pub const OrganizationSpendAlertListResource = struct {
    object: []const u8 = "",
    data: []const OrganizationSpendAlert = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
};

pub const OrganizationSpendLimitDeletedResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
};

pub const OrganizationSpendLimitResource = struct {
    object: []const u8 = "",
    threshold_amount: i64 = 0,
    currency: ?SpendLimitCurrency = null,
    interval: ?SpendLimitInterval = null,
    enforcement: ?SpendLimitEnforcement = null,
};

pub const OtherChunkingStrategyResponseParam = struct {
    @"type": []const u8 = "",
};

pub const OutputAudio = struct {
    @"type": []const u8 = "",
    data: []const u8 = "",
    transcript: []const u8 = "",
};

pub const OutputContent = std.json.Value;

pub const OutputItem = std.json.Value;

pub const OutputMessage = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    role: []const u8 = "",
    content: []const OutputMessageContent = &.{},
    phase: ?std.json.Value = null,
    status: []const u8 = "",
};

pub const OutputMessageContent = std.json.Value;

pub const OutputTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    annotations: []const Annotation = &.{},
    logprobs: []const LogProb = &.{},
};

pub const ParallelToolCalls = bool;

pub const PartialImages = std.json.Value;

pub const PersonalityEnum = std.json.Value;

pub const PredictionContent = struct {
    @"type": []const u8 = "",
    content: []const u8 = "",
};

pub const Program = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    code: []const u8 = "",
    fingerprint: []const u8 = "",
};

pub const ProgramItemParam = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    code: []const u8 = "",
    fingerprint: []const u8 = "",
};

pub const ProgramOutput = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: []const u8 = "",
    result: []const u8 = "",
    status: ?ProgramOutputStatus = null,
};

pub const ProgramOutputItemParam = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    call_id: []const u8 = "",
    result: []const u8 = "",
    status: ?ProgramOutputItemStatus = null,
};

pub const ProgramOutputItemStatus = []const u8;

pub const ProgramOutputStatus = []const u8;

pub const ProgramToolCallCaller = struct {
    @"type": []const u8 = "",
    caller_id: []const u8 = "",
};

pub const ProgramToolCallCallerParam = struct {
    @"type": []const u8 = "",
    caller_id: []const u8 = "",
};

pub const ProgrammaticToolCallingParam = struct {
    @"type": []const u8 = "",
};

pub const Project = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    name: ?std.json.Value = null,
    created_at: i64 = 0,
    archived_at: ?std.json.Value = null,
    status: ?std.json.Value = null,
    external_key_id: ?std.json.Value = null,
};

pub const ProjectApiKey = struct {
    object: []const u8 = "",
    redacted_value: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    last_used_at: std.json.Value = .null,
    id: []const u8 = "",
    owner_project_access: []const u8 = "",
    owner: ?struct {
    @"type": ?[]const u8 = null,
    user: ?ProjectApiKeyOwnerUser = null,
    service_account: ?ProjectApiKeyOwnerServiceAccount = null,
} = null,
};

pub const ProjectApiKeyDeleteResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const ProjectApiKeyListResponse = struct {
    object: []const u8 = "",
    data: []const ProjectApiKey = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ProjectApiKeyOwnerServiceAccount = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    role: []const u8 = "",
};

pub const ProjectApiKeyOwnerUser = struct {
    id: []const u8 = "",
    email: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    role: []const u8 = "",
};

pub const ProjectCreateRequest = struct {
    name: []const u8 = "",
    geography: ?std.json.Value = null,
    external_key_id: ?std.json.Value = null,
};

pub const ProjectDataRetention = struct {
    object: []const u8 = "",
    @"type": []const u8 = "",
};

pub const ProjectGroup = struct {
    object: []const u8 = "",
    project_id: []const u8 = "",
    group_id: []const u8 = "",
    group_name: []const u8 = "",
    group_type: []const u8 = "",
    created_at: i64 = 0,
};

pub const ProjectGroupDeletedResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
};

pub const ProjectGroupListResource = struct {
    object: []const u8 = "",
    data: []const ProjectGroup = &.{},
    has_more: bool = false,
    next: std.json.Value = .null,
};

pub const ProjectHostedToolPermissions = struct {
    file_search: ?HostedToolPermission = null,
    web_search: ?HostedToolPermission = null,
    image_generation: ?HostedToolPermission = null,
    mcp: ?HostedToolPermission = null,
    code_interpreter: ?HostedToolPermission = null,
};

pub const ProjectHostedToolPermissionsUpdateRequest = struct {
    file_search: ?std.json.Value = null,
    web_search: ?std.json.Value = null,
    image_generation: ?std.json.Value = null,
    mcp: ?std.json.Value = null,
    code_interpreter: ?std.json.Value = null,
};

pub const ProjectListResponse = struct {
    object: []const u8 = "",
    data: []const Project = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ProjectModelPermissions = struct {
    object: []const u8 = "",
    mode: []const u8 = "",
    model_ids: []const []const u8 = &.{},
};

pub const ProjectModelPermissionsDeleteResponse = struct {
    object: []const u8 = "",
    deleted: bool = false,
};

pub const ProjectModelPermissionsUpdateRequest = struct {
    mode: []const u8 = "",
    model_ids: []const []const u8 = &.{},
};

pub const ProjectRateLimit = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    model: []const u8 = "",
    max_requests_per_1_minute: i64 = 0,
    max_tokens_per_1_minute: i64 = 0,
    max_images_per_1_minute: ?i64 = null,
    max_audio_megabytes_per_1_minute: ?i64 = null,
    max_requests_per_1_day: ?i64 = null,
    batch_1_day_max_input_tokens: ?i64 = null,
};

pub const ProjectRateLimitListResponse = struct {
    object: []const u8 = "",
    data: []const ProjectRateLimit = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ProjectRateLimitUpdateRequest = struct {
    max_requests_per_1_minute: ?i64 = null,
    max_tokens_per_1_minute: ?i64 = null,
    max_images_per_1_minute: ?i64 = null,
    max_audio_megabytes_per_1_minute: ?i64 = null,
    max_requests_per_1_day: ?i64 = null,
    batch_1_day_max_input_tokens: ?i64 = null,
};

pub const ProjectServiceAccount = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    role: []const u8 = "",
    created_at: i64 = 0,
};

pub const ProjectServiceAccountApiKey = struct {
    object: []const u8 = "",
    value: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    id: []const u8 = "",
};

pub const ProjectServiceAccountCreateRequest = struct {
    name: []const u8 = "",
    create_service_account_only: ?std.json.Value = null,
};

pub const ProjectServiceAccountCreateResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    role: []const u8 = "",
    created_at: i64 = 0,
    api_key: std.json.Value = .null,
};

pub const ProjectServiceAccountDeleteResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const ProjectServiceAccountListResponse = struct {
    object: []const u8 = "",
    data: []const ProjectServiceAccount = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ProjectSpendAlert = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    threshold_amount: i64 = 0,
    currency: []const u8 = "",
    interval: []const u8 = "",
    notification_channel: ?SpendAlertNotificationChannel = null,
};

pub const ProjectSpendAlertDeletedResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    deleted: bool = false,
};

pub const ProjectSpendAlertListResource = struct {
    object: []const u8 = "",
    data: []const ProjectSpendAlert = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
};

pub const ProjectSpendLimitDeletedResource = struct {
    object: []const u8 = "",
    deleted: bool = false,
};

pub const ProjectSpendLimitResource = struct {
    object: []const u8 = "",
    threshold_amount: i64 = 0,
    currency: ?SpendLimitCurrency = null,
    interval: ?SpendLimitInterval = null,
    enforcement: ?SpendLimitEnforcement = null,
};

pub const ProjectUpdateRequest = struct {
    name: ?std.json.Value = null,
    external_key_id: ?std.json.Value = null,
    geography: ?std.json.Value = null,
};

pub const ProjectUser = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: ?std.json.Value = null,
    email: ?std.json.Value = null,
    role: []const u8 = "",
    added_at: i64 = 0,
};

pub const ProjectUserCreateRequest = struct {
    user_id: ?std.json.Value = null,
    email: ?std.json.Value = null,
    role: []const u8 = "",
};

pub const ProjectUserDeleteResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const ProjectUserListResponse = struct {
    object: []const u8 = "",
    data: []const ProjectUser = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const ProjectUserUpdateRequest = struct {
    role: ?std.json.Value = null,
};

pub const Prompt = std.json.Value;

pub const PromptCacheBreakpointConfig = struct {
    mode: []const u8 = "",
};

pub const PromptCacheBreakpointParam = struct {
    mode: []const u8 = "",
};

pub const PromptCacheModeEnum = []const u8;

pub const PromptCacheOptions = struct {
    ttl: ?PromptCacheTTLEnum = null,
    mode: ?PromptCacheModeEnum = null,
};

pub const PromptCacheOptionsParam = struct {
    ttl: ?PromptCacheTTLEnum = null,
    mode: ?PromptCacheModeEnum = null,
};

pub const PromptCacheRetentionEnum = []const u8;

pub const PromptCacheTTLEnum = []const u8;

pub const PublicAssignOrganizationGroupRoleBody = struct {
    role_id: []const u8 = "",
};

pub const PublicCreateOrganizationRoleBody = struct {
    role_name: []const u8 = "",
    permissions: []const []const u8 = &.{},
    description: ?std.json.Value = null,
};

pub const PublicRoleListResource = struct {
    object: []const u8 = "",
    data: []const Role = &.{},
    has_more: bool = false,
    next: std.json.Value = .null,
};

pub const PublicUpdateOrganizationRoleBody = struct {
    permissions: ?std.json.Value = null,
    description: ?std.json.Value = null,
    role_name: ?std.json.Value = null,
};

pub const RankerVersionType = []const u8;

pub const RankingOptions = struct {
    ranker: ?RankerVersionType = null,
    score_threshold: ?f64 = null,
    hybrid_search: ?HybridSearchOptions = null,
};

pub const RateLimitsParam = struct {
    max_requests_per_1_minute: ?i64 = null,
};

pub const RealtimeAudioFormats = std.json.Value;

pub const RealtimeBetaClientEventConversationItemCreate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    previous_item_id: ?[]const u8 = null,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeBetaClientEventConversationItemDelete = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeBetaClientEventConversationItemRetrieve = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeBetaClientEventConversationItemTruncate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    audio_end_ms: i64 = 0,
};

pub const RealtimeBetaClientEventInputAudioBufferAppend = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    audio: []const u8 = "",
};

pub const RealtimeBetaClientEventInputAudioBufferClear = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const RealtimeBetaClientEventInputAudioBufferCommit = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const RealtimeBetaClientEventOutputAudioBufferClear = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const RealtimeBetaClientEventResponseCancel = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    response_id: ?[]const u8 = null,
};

pub const RealtimeBetaClientEventResponseCreate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    response: ?RealtimeBetaResponseCreateParams = null,
};

pub const RealtimeBetaClientEventSessionUpdate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    session: ?RealtimeSessionCreateRequest = null,
};

pub const RealtimeBetaClientEventTranscriptionSessionUpdate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    session: ?RealtimeTranscriptionSessionCreateRequest = null,
};

pub const RealtimeBetaResponse = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    status: ?[]const u8 = null,
    status_details: ?struct {
    @"type": ?[]const u8 = null,
    reason: ?[]const u8 = null,
    @"error": ?struct {
    @"type": ?[]const u8 = null,
    code: ?[]const u8 = null,
} = null,
} = null,
    output: ?[]const RealtimeConversationItem = null,
    metadata: ?Metadata = null,
    usage: ?struct {
    total_tokens: ?i64 = null,
    input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    input_token_details: ?struct {
    cached_tokens: ?i64 = null,
    text_tokens: ?i64 = null,
    image_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
    cached_tokens_details: ?struct {
    text_tokens: ?i64 = null,
    image_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
} = null,
} = null,
    output_token_details: ?struct {
    text_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
} = null,
} = null,
    conversation_id: ?[]const u8 = null,
    voice: ?VoiceIdsShared = null,
    modalities: ?[]const []const u8 = null,
    output_audio_format: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_output_tokens: ?std.json.Value = null,
};

pub const RealtimeBetaResponseCreateParams = struct {
    modalities: ?[]const []const u8 = null,
    instructions: ?[]const u8 = null,
    voice: ?VoiceIdsOrCustomVoice = null,
    output_audio_format: ?[]const u8 = null,
    tools: ?[]const struct {
    @"type": ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
} = null,
    tool_choice: ?std.json.Value = null,
    temperature: ?f64 = null,
    max_output_tokens: ?std.json.Value = null,
    conversation: ?std.json.Value = null,
    metadata: ?Metadata = null,
    prompt: ?Prompt = null,
    input: ?[]const RealtimeConversationItem = null,
};

pub const RealtimeBetaServerEventConversationItemCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    previous_item_id: ?std.json.Value = null,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeBetaServerEventConversationItemDeleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventConversationItemInputAudioTranscriptionCompleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    transcript: []const u8 = "",
    logprobs: ?std.json.Value = null,
    usage: std.json.Value = .null,
};

pub const RealtimeBetaServerEventConversationItemInputAudioTranscriptionDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: ?i64 = null,
    delta: ?[]const u8 = null,
    logprobs: ?std.json.Value = null,
};

pub const RealtimeBetaServerEventConversationItemInputAudioTranscriptionFailed = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    @"error": ?struct {
    @"type": ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    param: ?[]const u8 = null,
} = null,
};

pub const RealtimeBetaServerEventConversationItemInputAudioTranscriptionSegment = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    text: []const u8 = "",
    id: []const u8 = "",
    speaker: []const u8 = "",
    start: f64 = 0,
    end: f64 = 0,
};

pub const RealtimeBetaServerEventConversationItemRetrieved = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeBetaServerEventConversationItemTruncated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    audio_end_ms: i64 = 0,
};

pub const RealtimeBetaServerEventError = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    @"error": ?struct {
    @"type": []const u8 = "",
    code: ?std.json.Value = null,
    message: []const u8 = "",
    param: ?std.json.Value = null,
    event_id: ?std.json.Value = null,
} = null,
};

pub const RealtimeBetaServerEventInputAudioBufferCleared = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
};

pub const RealtimeBetaServerEventInputAudioBufferCommitted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    previous_item_id: ?std.json.Value = null,
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventInputAudioBufferSpeechStarted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    audio_start_ms: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventInputAudioBufferSpeechStopped = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    audio_end_ms: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventMCPListToolsCompleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventMCPListToolsFailed = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventMCPListToolsInProgress = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventRateLimitsUpdated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    rate_limits: []const struct {
    name: ?[]const u8 = null,
    limit: ?i64 = null,
    remaining: ?i64 = null,
    reset_seconds: ?f64 = null,
} = &.{},
};

pub const RealtimeBetaServerEventResponseAudioDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseAudioDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
};

pub const RealtimeBetaServerEventResponseAudioTranscriptDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseAudioTranscriptDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    transcript: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseContentPartAdded = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    part: ?struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
} = null,
};

pub const RealtimeBetaServerEventResponseContentPartDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    part: ?struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
} = null,
};

pub const RealtimeBetaServerEventResponseCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response: ?RealtimeBetaResponse = null,
};

pub const RealtimeBetaServerEventResponseDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response: ?RealtimeBetaResponse = null,
};

pub const RealtimeBetaServerEventResponseFunctionCallArgumentsDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    call_id: []const u8 = "",
    delta: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseFunctionCallArgumentsDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    call_id: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseMCPCallArgumentsDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    delta: []const u8 = "",
    obfuscation: ?std.json.Value = null,
};

pub const RealtimeBetaServerEventResponseMCPCallArgumentsDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    arguments: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseMCPCallCompleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseMCPCallFailed = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseMCPCallInProgress = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseOutputItemAdded = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    output_index: i64 = 0,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeBetaServerEventResponseOutputItemDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    output_index: i64 = 0,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeBetaServerEventResponseTextDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
};

pub const RealtimeBetaServerEventResponseTextDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    text: []const u8 = "",
};

pub const RealtimeBetaServerEventSessionCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: ?RealtimeSession = null,
};

pub const RealtimeBetaServerEventSessionUpdated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: ?RealtimeSession = null,
};

pub const RealtimeBetaServerEventTranscriptionSessionCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: ?RealtimeTranscriptionSessionCreateResponse = null,
};

pub const RealtimeBetaServerEventTranscriptionSessionUpdated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: ?RealtimeTranscriptionSessionCreateResponse = null,
};

pub const RealtimeCallCreateRequest = struct {
    sdp: []const u8 = "",
    session: ?struct {
    @"type": []const u8 = "",
    output_modalities: ?[]const []const u8 = null,
    model: ?std.json.Value = null,
    instructions: ?[]const u8 = null,
    audio: ?struct {
    input: ?struct {
    format: ?RealtimeAudioFormats = null,
    transcription: ?AudioTranscription = null,
    noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    turn_detection: ?RealtimeTurnDetection = null,
} = null,
    output: ?struct {
    format: ?RealtimeAudioFormats = null,
    voice: ?VoiceIdsOrCustomVoice = null,
    speed: ?f64 = null,
} = null,
} = null,
    include: ?[]const []const u8 = null,
    tracing: ?std.json.Value = null,
    tools: ?[]const RealtimeFunctionTool = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    reasoning: ?RealtimeReasoning = null,
    max_output_tokens: ?std.json.Value = null,
    truncation: ?RealtimeTruncation = null,
    prompt: ?Prompt = null,
} = null,
};

pub const RealtimeCallReferRequest = struct {
    target_uri: []const u8 = "",
};

pub const RealtimeCallRejectRequest = struct {
    status_code: ?i64 = null,
};

pub const RealtimeClientEvent = std.json.Value;

pub const RealtimeClientEventConversationItemCreate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    previous_item_id: ?[]const u8 = null,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeClientEventConversationItemDelete = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeClientEventConversationItemRetrieve = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeClientEventConversationItemTruncate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    audio_end_ms: i64 = 0,
};

pub const RealtimeClientEventInputAudioBufferAppend = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    audio: []const u8 = "",
};

pub const RealtimeClientEventInputAudioBufferClear = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const RealtimeClientEventInputAudioBufferCommit = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const RealtimeClientEventOutputAudioBufferClear = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const RealtimeClientEventResponseCancel = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    response_id: ?[]const u8 = null,
};

pub const RealtimeClientEventResponseCreate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    response: ?RealtimeResponseCreateParams = null,
};

pub const RealtimeClientEventSessionUpdate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    session: std.json.Value = .null,
};

pub const RealtimeClientEventTranscriptionSessionUpdate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    session: ?RealtimeTranscriptionSessionCreateRequest = null,
};

pub const RealtimeConversationItem = std.json.Value;

pub const RealtimeConversationItemFunctionCall = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
    status: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    name: []const u8 = "",
    arguments: []const u8 = "",
};

pub const RealtimeConversationItemFunctionCallOutput = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
    status: ?[]const u8 = null,
    call_id: []const u8 = "",
    output: []const u8 = "",
};

pub const RealtimeConversationItemMessageAssistant = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
    status: ?[]const u8 = null,
    role: []const u8 = "",
    content: []const struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
} = &.{},
};

pub const RealtimeConversationItemMessageSystem = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
    status: ?[]const u8 = null,
    role: []const u8 = "",
    content: []const struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
} = &.{},
};

pub const RealtimeConversationItemMessageUser = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
    status: ?[]const u8 = null,
    role: []const u8 = "",
    content: []const struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    image_url: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
} = &.{},
};

pub const RealtimeConversationItemWithReference = struct {
    id: ?[]const u8 = null,
    @"type": ?[]const u8 = null,
    object: ?[]const u8 = null,
    status: ?[]const u8 = null,
    role: ?[]const u8 = null,
    content: ?[]const struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
} = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub const RealtimeCreateClientSecretRequest = struct {
    expires_after: ?struct {
    anchor: ?[]const u8 = null,
    seconds: ?i64 = null,
} = null,
    session: ?std.json.Value = null,
};

pub const RealtimeCreateClientSecretResponse = struct {
    value: []const u8 = "",
    expires_at: i64 = 0,
    session: std.json.Value = .null,
};

pub const RealtimeFunctionTool = struct {
    @"type": ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
};

pub const RealtimeMCPApprovalRequest = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};

pub const RealtimeMCPApprovalResponse = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    approval_request_id: []const u8 = "",
    approve: bool = false,
    reason: ?std.json.Value = null,
};

pub const RealtimeMCPHTTPError = struct {
    @"type": []const u8 = "",
    code: i64 = 0,
    message: []const u8 = "",
};

pub const RealtimeMCPListTools = struct {
    @"type": []const u8 = "",
    id: ?[]const u8 = null,
    server_label: []const u8 = "",
    tools: []const MCPListToolsTool = &.{},
};

pub const RealtimeMCPProtocolError = struct {
    @"type": []const u8 = "",
    code: i64 = 0,
    message: []const u8 = "",
};

pub const RealtimeMCPToolCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    server_label: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
    approval_request_id: ?std.json.Value = null,
    output: ?std.json.Value = null,
    @"error": ?std.json.Value = null,
};

pub const RealtimeMCPToolExecutionError = struct {
    @"type": []const u8 = "",
    message: []const u8 = "",
};

pub const RealtimeReasoning = struct {
    effort: ?RealtimeReasoningEffort = null,
};

pub const RealtimeReasoningEffort = []const u8;

pub const RealtimeResponse = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    status: ?[]const u8 = null,
    status_details: ?struct {
    @"type": ?[]const u8 = null,
    reason: ?[]const u8 = null,
    @"error": ?struct {
    @"type": ?[]const u8 = null,
    code: ?[]const u8 = null,
} = null,
} = null,
    output: ?[]const RealtimeConversationItem = null,
    metadata: ?Metadata = null,
    audio: ?struct {
    output: ?struct {
    format: ?RealtimeAudioFormats = null,
    voice: ?VoiceIdsShared = null,
} = null,
} = null,
    usage: ?struct {
    total_tokens: ?i64 = null,
    input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    input_token_details: ?struct {
    cached_tokens: ?i64 = null,
    text_tokens: ?i64 = null,
    image_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
    cached_tokens_details: ?struct {
    text_tokens: ?i64 = null,
    image_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
} = null,
} = null,
    output_token_details: ?struct {
    text_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
} = null,
} = null,
    conversation_id: ?[]const u8 = null,
    output_modalities: ?[]const []const u8 = null,
    max_output_tokens: ?std.json.Value = null,
};

pub const RealtimeResponseCreateParams = struct {
    output_modalities: ?[]const []const u8 = null,
    instructions: ?[]const u8 = null,
    audio: ?struct {
    output: ?struct {
    format: ?RealtimeAudioFormats = null,
    voice: ?VoiceIdsOrCustomVoice = null,
} = null,
} = null,
    tools: ?[]const RealtimeFunctionTool = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    reasoning: ?RealtimeReasoning = null,
    max_output_tokens: ?std.json.Value = null,
    conversation: ?std.json.Value = null,
    metadata: ?Metadata = null,
    prompt: ?Prompt = null,
    input: ?[]const RealtimeConversationItem = null,
};

pub const RealtimeServerEvent = std.json.Value;

pub const RealtimeServerEventConversationCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    conversation: ?struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
} = null,
};

pub const RealtimeServerEventConversationItemAdded = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    previous_item_id: ?std.json.Value = null,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeServerEventConversationItemCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    previous_item_id: ?std.json.Value = null,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeServerEventConversationItemDeleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeServerEventConversationItemDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    previous_item_id: ?std.json.Value = null,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeServerEventConversationItemInputAudioTranscriptionCompleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    transcript: []const u8 = "",
    logprobs: ?std.json.Value = null,
    usage: std.json.Value = .null,
};

pub const RealtimeServerEventConversationItemInputAudioTranscriptionDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: ?i64 = null,
    delta: ?[]const u8 = null,
    logprobs: ?std.json.Value = null,
};

pub const RealtimeServerEventConversationItemInputAudioTranscriptionFailed = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    @"error": ?struct {
    @"type": ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    param: ?[]const u8 = null,
} = null,
};

pub const RealtimeServerEventConversationItemInputAudioTranscriptionSegment = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    text: []const u8 = "",
    id: []const u8 = "",
    speaker: []const u8 = "",
    start: f64 = 0,
    end: f64 = 0,
};

pub const RealtimeServerEventConversationItemRetrieved = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeServerEventConversationItemTruncated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    content_index: i64 = 0,
    audio_end_ms: i64 = 0,
};

pub const RealtimeServerEventError = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    @"error": ?struct {
    @"type": []const u8 = "",
    code: ?std.json.Value = null,
    message: []const u8 = "",
    param: ?std.json.Value = null,
    event_id: ?std.json.Value = null,
} = null,
};

pub const RealtimeServerEventInputAudioBufferCleared = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
};

pub const RealtimeServerEventInputAudioBufferCommitted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    previous_item_id: ?std.json.Value = null,
    item_id: []const u8 = "",
};

pub const RealtimeServerEventInputAudioBufferDtmfEventReceived = struct {
    @"type": []const u8 = "",
    event: []const u8 = "",
    received_at: i64 = 0,
};

pub const RealtimeServerEventInputAudioBufferSpeechStarted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    audio_start_ms: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeServerEventInputAudioBufferSpeechStopped = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    audio_end_ms: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeServerEventInputAudioBufferTimeoutTriggered = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    audio_start_ms: i64 = 0,
    audio_end_ms: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeServerEventMCPListToolsCompleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeServerEventMCPListToolsFailed = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeServerEventMCPListToolsInProgress = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    item_id: []const u8 = "",
};

pub const RealtimeServerEventOutputAudioBufferCleared = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
};

pub const RealtimeServerEventOutputAudioBufferStarted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
};

pub const RealtimeServerEventOutputAudioBufferStopped = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
};

pub const RealtimeServerEventRateLimitsUpdated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    rate_limits: []const struct {
    name: ?[]const u8 = null,
    limit: ?i64 = null,
    remaining: ?i64 = null,
    reset_seconds: ?f64 = null,
} = &.{},
};

pub const RealtimeServerEventResponseAudioDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
};

pub const RealtimeServerEventResponseAudioDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
};

pub const RealtimeServerEventResponseAudioTranscriptDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
};

pub const RealtimeServerEventResponseAudioTranscriptDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    transcript: []const u8 = "",
};

pub const RealtimeServerEventResponseContentPartAdded = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    part: ?struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
} = null,
};

pub const RealtimeServerEventResponseContentPartDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    part: ?struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
    audio: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
} = null,
};

pub const RealtimeServerEventResponseCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response: ?RealtimeResponse = null,
};

pub const RealtimeServerEventResponseDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response: ?RealtimeResponse = null,
};

pub const RealtimeServerEventResponseFunctionCallArgumentsDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    call_id: []const u8 = "",
    delta: []const u8 = "",
};

pub const RealtimeServerEventResponseFunctionCallArgumentsDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    call_id: []const u8 = "",
    name: []const u8 = "",
    arguments: []const u8 = "",
};

pub const RealtimeServerEventResponseMCPCallArgumentsDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    delta: []const u8 = "",
    obfuscation: ?std.json.Value = null,
};

pub const RealtimeServerEventResponseMCPCallArgumentsDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    arguments: []const u8 = "",
};

pub const RealtimeServerEventResponseMCPCallCompleted = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeServerEventResponseMCPCallFailed = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeServerEventResponseMCPCallInProgress = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const RealtimeServerEventResponseOutputItemAdded = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    output_index: i64 = 0,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeServerEventResponseOutputItemDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    output_index: i64 = 0,
    item: ?RealtimeConversationItem = null,
};

pub const RealtimeServerEventResponseTextDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
};

pub const RealtimeServerEventResponseTextDone = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    response_id: []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    text: []const u8 = "",
};

pub const RealtimeServerEventSessionCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: std.json.Value = .null,
};

pub const RealtimeServerEventSessionUpdated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: std.json.Value = .null,
};

pub const RealtimeServerEventTranscriptionSessionUpdated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: ?RealtimeTranscriptionSessionCreateResponse = null,
};

pub const RealtimeSession = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    modalities: ?std.json.Value = null,
    model: ?std.json.Value = null,
    instructions: ?[]const u8 = null,
    voice: ?VoiceIdsShared = null,
    input_audio_format: ?[]const u8 = null,
    output_audio_format: ?[]const u8 = null,
    input_audio_transcription: ?std.json.Value = null,
    turn_detection: ?RealtimeTurnDetection = null,
    input_audio_noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    speed: ?f64 = null,
    tracing: ?std.json.Value = null,
    tools: ?[]const RealtimeFunctionTool = null,
    tool_choice: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_response_output_tokens: ?std.json.Value = null,
    expires_at: ?i64 = null,
    prompt: ?std.json.Value = null,
    include: ?std.json.Value = null,
};

pub const RealtimeSessionCreateRequest = struct {
    client_secret: ?struct {
    value: []const u8 = "",
    expires_at: i64 = 0,
} = null,
    modalities: ?std.json.Value = null,
    instructions: ?[]const u8 = null,
    voice: ?VoiceIdsOrCustomVoice = null,
    input_audio_format: ?[]const u8 = null,
    output_audio_format: ?[]const u8 = null,
    input_audio_transcription: ?struct {
    model: ?[]const u8 = null,
} = null,
    speed: ?f64 = null,
    tracing: ?std.json.Value = null,
    turn_detection: ?struct {
    @"type": ?[]const u8 = null,
    threshold: ?f64 = null,
    prefix_padding_ms: ?i64 = null,
    silence_duration_ms: ?i64 = null,
} = null,
    tools: ?[]const struct {
    @"type": ?[]const u8 = null,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    parameters: ?std.json.Value = null,
} = null,
    tool_choice: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_response_output_tokens: ?std.json.Value = null,
    truncation: ?RealtimeTruncation = null,
    prompt: ?Prompt = null,
};

pub const RealtimeSessionCreateRequestGA = struct {
    @"type": []const u8 = "",
    output_modalities: ?[]const []const u8 = null,
    model: ?std.json.Value = null,
    instructions: ?[]const u8 = null,
    audio: ?struct {
    input: ?struct {
    format: ?RealtimeAudioFormats = null,
    transcription: ?AudioTranscription = null,
    noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    turn_detection: ?RealtimeTurnDetection = null,
} = null,
    output: ?struct {
    format: ?RealtimeAudioFormats = null,
    voice: ?VoiceIdsOrCustomVoice = null,
    speed: ?f64 = null,
} = null,
} = null,
    include: ?[]const []const u8 = null,
    tracing: ?std.json.Value = null,
    tools: ?[]const RealtimeFunctionTool = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?bool = null,
    reasoning: ?RealtimeReasoning = null,
    max_output_tokens: ?std.json.Value = null,
    truncation: ?RealtimeTruncation = null,
    prompt: ?Prompt = null,
};

pub const RealtimeSessionCreateResponse = struct {
    id: ?[]const u8 = null,
    object: ?[]const u8 = null,
    expires_at: ?i64 = null,
    include: ?[]const []const u8 = null,
    model: ?[]const u8 = null,
    output_modalities: ?std.json.Value = null,
    instructions: ?[]const u8 = null,
    audio: ?struct {
    input: ?struct {
    format: ?RealtimeAudioFormats = null,
    transcription: ?AudioTranscriptionResponse = null,
    noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    turn_detection: ?struct {
    @"type": ?[]const u8 = null,
    threshold: ?f64 = null,
    prefix_padding_ms: ?i64 = null,
    silence_duration_ms: ?i64 = null,
} = null,
} = null,
    output: ?struct {
    format: ?RealtimeAudioFormats = null,
    voice: ?VoiceIdsShared = null,
    speed: ?f64 = null,
} = null,
} = null,
    tracing: ?std.json.Value = null,
    turn_detection: ?struct {
    @"type": ?[]const u8 = null,
    threshold: ?f64 = null,
    prefix_padding_ms: ?i64 = null,
    silence_duration_ms: ?i64 = null,
} = null,
    tools: ?[]const RealtimeFunctionTool = null,
    tool_choice: ?[]const u8 = null,
    max_output_tokens: ?std.json.Value = null,
};

pub const RealtimeSessionCreateResponseGA = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    object: []const u8 = "",
    expires_at: ?i64 = null,
    output_modalities: ?[]const []const u8 = null,
    model: ?std.json.Value = null,
    instructions: ?[]const u8 = null,
    audio: ?struct {
    input: ?struct {
    format: ?RealtimeAudioFormats = null,
    transcription: ?AudioTranscriptionResponse = null,
    noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    turn_detection: ?RealtimeTurnDetection = null,
} = null,
    output: ?struct {
    format: ?RealtimeAudioFormats = null,
    voice: ?VoiceIdsShared = null,
    speed: ?f64 = null,
} = null,
} = null,
    include: ?[]const []const u8 = null,
    tracing: ?std.json.Value = null,
    tools: ?[]const RealtimeFunctionTool = null,
    tool_choice: ?std.json.Value = null,
    reasoning: ?RealtimeReasoning = null,
    max_output_tokens: ?std.json.Value = null,
    truncation: ?RealtimeTruncation = null,
    prompt: ?Prompt = null,
};

pub const RealtimeTranscriptionSessionCreateRequest = struct {
    turn_detection: ?struct {
    @"type": ?[]const u8 = null,
    threshold: ?f64 = null,
    prefix_padding_ms: ?i64 = null,
    silence_duration_ms: ?i64 = null,
} = null,
    input_audio_noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    input_audio_format: ?[]const u8 = null,
    input_audio_transcription: ?AudioTranscription = null,
    include: ?[]const []const u8 = null,
};

pub const RealtimeTranscriptionSessionCreateRequestGA = struct {
    @"type": []const u8 = "",
    audio: ?struct {
    input: ?struct {
    format: ?RealtimeAudioFormats = null,
    transcription: ?AudioTranscription = null,
    noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    turn_detection: ?RealtimeTurnDetection = null,
} = null,
} = null,
    include: ?[]const []const u8 = null,
};

pub const RealtimeTranscriptionSessionCreateResponse = struct {
    client_secret: ?struct {
    value: []const u8 = "",
    expires_at: i64 = 0,
} = null,
    modalities: ?std.json.Value = null,
    input_audio_format: ?[]const u8 = null,
    input_audio_transcription: ?AudioTranscriptionResponse = null,
    turn_detection: ?struct {
    @"type": ?[]const u8 = null,
    threshold: ?f64 = null,
    prefix_padding_ms: ?i64 = null,
    silence_duration_ms: ?i64 = null,
} = null,
};

pub const RealtimeTranscriptionSessionCreateResponseGA = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    object: []const u8 = "",
    expires_at: ?i64 = null,
    include: ?[]const []const u8 = null,
    audio: ?struct {
    input: ?struct {
    format: ?RealtimeAudioFormats = null,
    transcription: ?AudioTranscriptionResponse = null,
    noise_reduction: ?struct {
    @"type": ?NoiseReductionType = null,
} = null,
    turn_detection: ?std.json.Value = null,
} = null,
} = null,
};

pub const RealtimeTranslationClientEvent = std.json.Value;

pub const RealtimeTranslationClientEventInputAudioBufferAppend = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    audio: []const u8 = "",
};

pub const RealtimeTranslationClientEventSessionClose = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const RealtimeTranslationClientEventSessionUpdate = struct {
    event_id: ?[]const u8 = null,
    @"type": []const u8 = "",
    session: ?RealtimeTranslationSessionUpdateRequest = null,
};

pub const RealtimeTranslationClientSecretCreateRequest = struct {
    expires_after: ?struct {
    anchor: ?[]const u8 = null,
    seconds: ?i64 = null,
} = null,
    session: ?RealtimeTranslationSessionCreateRequest = null,
};

pub const RealtimeTranslationClientSecretCreateResponse = struct {
    value: []const u8 = "",
    expires_at: i64 = 0,
    session: ?RealtimeTranslationSession = null,
};

pub const RealtimeTranslationServerEvent = std.json.Value;

pub const RealtimeTranslationServerEventSessionClosed = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
};

pub const RealtimeTranslationServerEventSessionCreated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: ?RealtimeTranslationSession = null,
};

pub const RealtimeTranslationServerEventSessionInputTranscriptDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    delta: []const u8 = "",
    elapsed_ms: ?std.json.Value = null,
};

pub const RealtimeTranslationServerEventSessionOutputAudioDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    delta: []const u8 = "",
    sample_rate: ?i64 = null,
    channels: ?i64 = null,
    format: ?[]const u8 = null,
    elapsed_ms: ?std.json.Value = null,
};

pub const RealtimeTranslationServerEventSessionOutputTranscriptDelta = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    delta: []const u8 = "",
    elapsed_ms: ?std.json.Value = null,
};

pub const RealtimeTranslationServerEventSessionUpdated = struct {
    event_id: []const u8 = "",
    @"type": []const u8 = "",
    session: ?RealtimeTranslationSession = null,
};

pub const RealtimeTranslationSession = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    expires_at: i64 = 0,
    model: []const u8 = "",
    audio: ?struct {
    input: ?struct {
    transcription: ?std.json.Value = null,
    noise_reduction: ?std.json.Value = null,
} = null,
    output: ?struct {
    language: ?[]const u8 = null,
} = null,
} = null,
};

pub const RealtimeTranslationSessionCreateRequest = struct {
    model: []const u8 = "",
    audio: ?struct {
    input: ?struct {
    transcription: ?std.json.Value = null,
    noise_reduction: ?std.json.Value = null,
} = null,
    output: ?struct {
    language: ?[]const u8 = null,
} = null,
} = null,
};

pub const RealtimeTranslationSessionUpdateRequest = struct {
    audio: ?struct {
    input: ?struct {
    transcription: ?std.json.Value = null,
    noise_reduction: ?std.json.Value = null,
} = null,
    output: ?struct {
    language: ?[]const u8 = null,
} = null,
} = null,
};

pub const RealtimeTruncation = std.json.Value;

pub const RealtimeTurnDetection = std.json.Value;

pub const Reasoning = struct {
    mode: ?ReasoningModeEnum = null,
    effort: ?ReasoningEffort = null,
    summary: ?std.json.Value = null,
    context: ?std.json.Value = null,
    generate_summary: ?std.json.Value = null,
};

pub const ReasoningEffort = std.json.Value;

pub const ReasoningItem = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    encrypted_content: ?[]const u8 = null,
    summary: []const SummaryTextContent = &.{},
    content: ?[]const ReasoningTextContent = null,
    status: ?[]const u8 = null,
};

pub const ReasoningModeEnum = std.json.Value;

pub const ReasoningTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const RefusalContent = struct {
    @"type": []const u8 = "",
    refusal: []const u8 = "",
};

pub const Response = struct {
    metadata: ?Metadata = null,
    top_logprobs: ?std.json.Value = null,
    temperature: std.json.Value = .null,
    top_p: std.json.Value = .null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?ServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    previous_response_id: ?std.json.Value = null,
    model: ?ModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?ResponseTextParam = null,
    tools: ?ToolsArray = null,
    tool_choice: ?ToolChoiceParam = null,
    prompt: ?Prompt = null,
    truncation: ?std.json.Value = null,
    id: []const u8 = "",
    object: []const u8 = "",
    status: ?[]const u8 = null,
    created_at: f64 = 0,
    completed_at: ?std.json.Value = null,
    @"error": ?ResponseError = null,
    incomplete_details: std.json.Value = .null,
    output: []const OutputItem = &.{},
    reasoning: ?std.json.Value = null,
    instructions: std.json.Value = .null,
    output_text: ?std.json.Value = null,
    usage: ?ResponseUsage = null,
    prompt_cache_options: ?PromptCacheOptions = null,
    moderation: ?std.json.Value = null,
    parallel_tool_calls: bool = false,
    conversation: ?std.json.Value = null,
    max_output_tokens: ?std.json.Value = null,
};

pub const ResponseAudioDeltaEvent = struct {
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    delta: []const u8 = "",
};

pub const ResponseAudioDoneEvent = struct {
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseAudioTranscriptDeltaEvent = struct {
    @"type": []const u8 = "",
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseAudioTranscriptDoneEvent = struct {
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseCodeInterpreterCallCodeDeltaEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseCodeInterpreterCallCodeDoneEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    code: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseCodeInterpreterCallCompletedEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseCodeInterpreterCallInProgressEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseCodeInterpreterCallInterpretingEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseCompletedEvent = struct {
    @"type": []const u8 = "",
    response: ?Response = null,
    sequence_number: i64 = 0,
};

pub const ResponseContentPartAddedEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    part: ?OutputContent = null,
    sequence_number: i64 = 0,
};

pub const ResponseContentPartDoneEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    sequence_number: i64 = 0,
    part: ?OutputContent = null,
};

pub const ResponseCreatedEvent = struct {
    @"type": []const u8 = "",
    response: ?Response = null,
    sequence_number: i64 = 0,
};

pub const ResponseCustomToolCallInputDeltaEvent = struct {
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    output_index: i64 = 0,
    item_id: []const u8 = "",
    delta: []const u8 = "",
};

pub const ResponseCustomToolCallInputDoneEvent = struct {
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    output_index: i64 = 0,
    item_id: []const u8 = "",
    input: []const u8 = "",
};

pub const ResponseError = std.json.Value;

pub const ResponseErrorCode = []const u8;

pub const ResponseErrorEvent = struct {
    @"type": []const u8 = "",
    code: std.json.Value = .null,
    message: []const u8 = "",
    param: std.json.Value = .null,
    sequence_number: i64 = 0,
};

pub const ResponseFailedEvent = struct {
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    response: ?Response = null,
};

pub const ResponseFileSearchCallCompletedEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseFileSearchCallInProgressEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseFileSearchCallSearchingEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseFormatJsonObject = struct {
    @"type": []const u8 = "",
};

pub const ResponseFormatJsonSchema = struct {
    @"type": []const u8 = "",
    json_schema: ?struct {
    description: ?[]const u8 = null,
    name: []const u8 = "",
    schema: ?ResponseFormatJsonSchemaSchema = null,
    strict: ?std.json.Value = null,
} = null,
};

pub const ResponseFormatJsonSchemaSchema = std.json.Value;

pub const ResponseFormatText = struct {
    @"type": []const u8 = "",
};

pub const ResponseFormatTextGrammar = struct {
    @"type": []const u8 = "",
    grammar: []const u8 = "",
};

pub const ResponseFormatTextPython = struct {
    @"type": []const u8 = "",
};

pub const ResponseFunctionCallArgumentsDeltaEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    delta: []const u8 = "",
};

pub const ResponseFunctionCallArgumentsDoneEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    name: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    arguments: []const u8 = "",
};

pub const ResponseImageGenCallCompletedEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    item_id: []const u8 = "",
};

pub const ResponseImageGenCallGeneratingEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseImageGenCallInProgressEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseImageGenCallPartialImageEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
    partial_image_index: i64 = 0,
    partial_image_b64: []const u8 = "",
};

pub const ResponseInProgressEvent = struct {
    @"type": []const u8 = "",
    response: ?Response = null,
    sequence_number: i64 = 0,
};

pub const ResponseIncompleteEvent = struct {
    @"type": []const u8 = "",
    response: ?Response = null,
    sequence_number: i64 = 0,
};

pub const ResponseItemList = struct {
    object: []const u8 = "",
    data: []const ItemResource = &.{},
    has_more: bool = false,
    first_id: []const u8 = "",
    last_id: []const u8 = "",
};

pub const ResponseLogProb = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    top_logprobs: ?[]const struct {
    token: ?[]const u8 = null,
    logprob: ?f64 = null,
} = null,
};

pub const ResponseMCPCallArgumentsDeltaEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseMCPCallArgumentsDoneEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    arguments: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseMCPCallCompletedEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const ResponseMCPCallFailedEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const ResponseMCPCallInProgressEvent = struct {
    @"type": []const u8 = "",
    sequence_number: i64 = 0,
    output_index: i64 = 0,
    item_id: []const u8 = "",
};

pub const ResponseMCPListToolsCompletedEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const ResponseMCPListToolsFailedEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const ResponseMCPListToolsInProgressEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
};

pub const ResponseModalities = std.json.Value;

pub const ResponseOutputItemAddedEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    item: ?OutputItem = null,
};

pub const ResponseOutputItemDoneEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    sequence_number: i64 = 0,
    item: ?OutputItem = null,
};

pub const ResponseOutputText = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    annotations: []const FileAnnotation = &.{},
};

pub const ResponseOutputTextAnnotationAddedEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    annotation_index: i64 = 0,
    sequence_number: i64 = 0,
    annotation: std.json.Value = .null,
};

pub const ResponsePromptVariables = std.json.Value;

pub const ResponseProperties = struct {
    previous_response_id: ?std.json.Value = null,
    model: ?ModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?ResponseTextParam = null,
    tools: ?ToolsArray = null,
    tool_choice: ?ToolChoiceParam = null,
    prompt: ?Prompt = null,
};

pub const ResponseQueuedEvent = struct {
    @"type": []const u8 = "",
    response: ?Response = null,
    sequence_number: i64 = 0,
};

pub const ResponseReasoningSummaryPartAddedEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    sequence_number: i64 = 0,
    part: ?struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
} = null,
};

pub const ResponseReasoningSummaryPartDoneEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    status: ?[]const u8 = null,
    sequence_number: i64 = 0,
    part: ?struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
} = null,
};

pub const ResponseReasoningSummaryTextDeltaEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseReasoningSummaryTextDoneEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    summary_index: i64 = 0,
    text: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseReasoningTextDeltaEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseReasoningTextDoneEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    text: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseRefusalDeltaEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseRefusalDoneEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    refusal: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseStreamEvent = std.json.Value;

pub const ResponseStreamOptions = std.json.Value;

pub const ResponseTextDeltaEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    delta: []const u8 = "",
    sequence_number: i64 = 0,
    logprobs: []const ResponseLogProb = &.{},
};

pub const ResponseTextDoneEvent = struct {
    @"type": []const u8 = "",
    item_id: []const u8 = "",
    output_index: i64 = 0,
    content_index: i64 = 0,
    text: []const u8 = "",
    sequence_number: i64 = 0,
    logprobs: []const ResponseLogProb = &.{},
};

pub const ResponseTextParam = struct {
    format: ?TextResponseFormatConfiguration = null,
    verbosity: ?Verbosity = null,
};

pub const ResponseUsage = struct {
    input_tokens: i64 = 0,
    input_tokens_details: ?struct {
    cached_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
} = null,
    output_tokens: i64 = 0,
    output_tokens_details: ?struct {
    reasoning_tokens: i64 = 0,
} = null,
    total_tokens: i64 = 0,
};

pub const ResponseWebSearchCallCompletedEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseWebSearchCallInProgressEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponseWebSearchCallSearchingEvent = struct {
    @"type": []const u8 = "",
    output_index: i64 = 0,
    item_id: []const u8 = "",
    sequence_number: i64 = 0,
};

pub const ResponsesClientEvent = std.json.Value;

pub const ResponsesClientEventResponseCreate = struct {
    @"type": []const u8 = "",
    metadata: ?Metadata = null,
    top_logprobs: ?i64 = null,
    temperature: ?std.json.Value = null,
    top_p: ?std.json.Value = null,
    user: ?[]const u8 = null,
    safety_identifier: ?std.json.Value = null,
    prompt_cache_key: ?std.json.Value = null,
    service_tier: ?ServiceTier = null,
    prompt_cache_retention: ?std.json.Value = null,
    prompt_cache_options: ?PromptCacheOptionsParam = null,
    previous_response_id: ?std.json.Value = null,
    model: ?ModelIdsResponses = null,
    background: ?std.json.Value = null,
    max_tool_calls: ?std.json.Value = null,
    text: ?ResponseTextParam = null,
    tools: ?ToolsArray = null,
    tool_choice: ?ToolChoiceParam = null,
    prompt: ?Prompt = null,
    truncation: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    input: ?InputParam = null,
    include: ?std.json.Value = null,
    parallel_tool_calls: ?std.json.Value = null,
    store: ?std.json.Value = null,
    instructions: ?std.json.Value = null,
    moderation: ?std.json.Value = null,
    stream: ?std.json.Value = null,
    stream_options: ?ResponseStreamOptions = null,
    conversation: ?std.json.Value = null,
    context_management: ?std.json.Value = null,
    max_output_tokens: ?std.json.Value = null,
};

pub const ResponsesServerEvent = std.json.Value;

pub const Role = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    description: std.json.Value = .null,
    permissions: []const []const u8 = &.{},
    resource_type: []const u8 = "",
    predefined_role: bool = false,
};

pub const RoleDeletedResource = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const RoleListResource = struct {
    object: []const u8 = "",
    data: []const AssignedRoleDetails = &.{},
    has_more: bool = false,
    next: std.json.Value = .null,
};

pub const RunCompletionUsage = std.json.Value;

pub const RunGraderRequest = struct {
    grader: std.json.Value = .null,
    item: ?std.json.Value = null,
    model_sample: []const u8 = "",
};

pub const RunGraderResponse = struct {
    reward: f64 = 0,
    metadata: ?struct {
    name: []const u8 = "",
    @"type": []const u8 = "",
    errors: ?struct {
    formula_parse_error: bool = false,
    sample_parse_error: bool = false,
    truncated_observation_error: bool = false,
    unresponsive_reward_error: bool = false,
    invalid_variable_error: bool = false,
    other_error: bool = false,
    python_grader_server_error: bool = false,
    python_grader_server_error_type: std.json.Value = .null,
    python_grader_runtime_error: bool = false,
    python_grader_runtime_error_details: std.json.Value = .null,
    model_grader_server_error: bool = false,
    model_grader_refusal_error: bool = false,
    model_grader_parse_error: bool = false,
    model_grader_server_error_details: std.json.Value = .null,
} = null,
    execution_time: f64 = 0,
    scores: std.json.Value = .null,
    token_usage: std.json.Value = .null,
    sampled_model_name: std.json.Value = .null,
} = null,
    sub_rewards: std.json.Value = .null,
    model_grader_token_usage_per_model: std.json.Value = .null,
};

pub const RunObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    assistant_id: []const u8 = "",
    status: []const u8 = "",
    required_action: ?struct {
    @"type": []const u8 = "",
    submit_tool_outputs: ?struct {
    tool_calls: []const RunToolCallObject = &.{},
} = null,
} = null,
    last_error: ?struct {
    code: []const u8 = "",
    message: []const u8 = "",
} = null,
    expires_at: ?i64 = null,
    started_at: ?i64 = null,
    cancelled_at: ?i64 = null,
    failed_at: ?i64 = null,
    completed_at: ?i64 = null,
    incomplete_details: ?struct {
    reason: ?[]const u8 = null,
} = null,
    model: []const u8 = "",
    instructions: []const u8 = "",
    tools: []const AssistantToolsCode = &.{},
    metadata: ?Metadata = null,
    usage: ?RunCompletionUsage = null,
    temperature: ?f64 = null,
    top_p: ?f64 = null,
    max_prompt_tokens: ?i64 = null,
    max_completion_tokens: ?i64 = null,
    truncation_strategy: ?struct {
    @"type": []const u8 = "",
    last_messages: ?std.json.Value = null,
} = null,
    tool_choice: std.json.Value = .null,
    parallel_tool_calls: ?ParallelToolCalls = null,
    response_format: ?AssistantsApiResponseFormatOption = null,
};

pub const RunStepCompletionUsage = std.json.Value;

pub const RunStepDeltaObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    delta: ?struct {
    step_details: ?std.json.Value = null,
} = null,
};

pub const RunStepDeltaStepDetailsMessageCreationObject = struct {
    @"type": []const u8 = "",
    message_creation: ?struct {
    message_id: ?[]const u8 = null,
} = null,
};

pub const RunStepDeltaStepDetailsToolCallsCodeObject = struct {
    index: i64 = 0,
    id: ?[]const u8 = null,
    @"type": []const u8 = "",
    code_interpreter: ?struct {
    input: ?[]const u8 = null,
    outputs: ?[]const RunStepDeltaStepDetailsToolCallsCodeOutputLogsObject = null,
} = null,
};

pub const RunStepDeltaStepDetailsToolCallsCodeOutputImageObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    image: ?struct {
    file_id: ?[]const u8 = null,
} = null,
};

pub const RunStepDeltaStepDetailsToolCallsCodeOutputLogsObject = struct {
    index: i64 = 0,
    @"type": []const u8 = "",
    logs: ?[]const u8 = null,
};

pub const RunStepDeltaStepDetailsToolCallsFileSearchObject = struct {
    index: i64 = 0,
    id: ?[]const u8 = null,
    @"type": []const u8 = "",
    file_search: std.json.Value = .null,
};

pub const RunStepDeltaStepDetailsToolCallsFunctionObject = struct {
    index: i64 = 0,
    id: ?[]const u8 = null,
    @"type": []const u8 = "",
    function: ?struct {
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?std.json.Value = null,
} = null,
};

pub const RunStepDeltaStepDetailsToolCallsObject = struct {
    @"type": []const u8 = "",
    tool_calls: ?[]const RunStepDeltaStepDetailsToolCallsCodeObject = null,
};

pub const RunStepDetailsMessageCreationObject = struct {
    @"type": []const u8 = "",
    message_creation: ?struct {
    message_id: []const u8 = "",
} = null,
};

pub const RunStepDetailsToolCallsCodeObject = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    code_interpreter: ?struct {
    input: []const u8 = "",
    outputs: []const RunStepDetailsToolCallsCodeOutputLogsObject = &.{},
} = null,
};

pub const RunStepDetailsToolCallsCodeOutputImageObject = struct {
    @"type": []const u8 = "",
    image: ?struct {
    file_id: []const u8 = "",
} = null,
};

pub const RunStepDetailsToolCallsCodeOutputLogsObject = struct {
    @"type": []const u8 = "",
    logs: []const u8 = "",
};

pub const RunStepDetailsToolCallsFileSearchObject = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    file_search: ?struct {
    ranking_options: ?RunStepDetailsToolCallsFileSearchRankingOptionsObject = null,
    results: ?[]const RunStepDetailsToolCallsFileSearchResultObject = null,
} = null,
};

pub const RunStepDetailsToolCallsFileSearchRankingOptionsObject = struct {
    ranker: ?FileSearchRanker = null,
    score_threshold: f64 = 0,
};

pub const RunStepDetailsToolCallsFileSearchResultObject = struct {
    file_id: []const u8 = "",
    file_name: []const u8 = "",
    score: f64 = 0,
    content: ?[]const struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
} = null,
};

pub const RunStepDetailsToolCallsFunctionObject = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    function: ?struct {
    name: []const u8 = "",
    arguments: []const u8 = "",
    output: std.json.Value = .null,
} = null,
};

pub const RunStepDetailsToolCallsObject = struct {
    @"type": []const u8 = "",
    tool_calls: []const RunStepDetailsToolCallsCodeObject = &.{},
};

pub const RunStepObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    assistant_id: []const u8 = "",
    thread_id: []const u8 = "",
    run_id: []const u8 = "",
    @"type": []const u8 = "",
    status: []const u8 = "",
    step_details: std.json.Value = .null,
    last_error: std.json.Value = .null,
    expired_at: std.json.Value = .null,
    cancelled_at: std.json.Value = .null,
    failed_at: std.json.Value = .null,
    completed_at: std.json.Value = .null,
    metadata: ?Metadata = null,
    usage: ?RunStepCompletionUsage = null,
};

pub const RunStepStreamEvent = std.json.Value;

pub const RunStreamEvent = std.json.Value;

pub const RunToolCallObject = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    function: ?struct {
    name: []const u8 = "",
    arguments: []const u8 = "",
} = null,
};

pub const ScreenshotParam = struct {
    @"type": []const u8 = "",
};

pub const ScrollParam = struct {
    @"type": []const u8 = "",
    x: i64 = 0,
    y: i64 = 0,
    scroll_x: i64 = 0,
    scroll_y: i64 = 0,
    keys: ?std.json.Value = null,
};

pub const SearchContentType = []const u8;

pub const SearchContextSize = []const u8;

pub const ServiceAccountApiKeyBody = struct {
    object: []const u8 = "",
    value: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
    id: []const u8 = "",
};

pub const ServiceTier = std.json.Value;

pub const ServiceTierEnum = []const u8;

pub const SetDefaultSkillVersionBody = struct {
    default_version: []const u8 = "",
};

pub const SkillListResource = struct {
    object: []const u8 = "",
    data: []const SkillResource = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
};

pub const SkillReferenceParam = struct {
    @"type": []const u8 = "",
    skill_id: []const u8 = "",
    version: ?[]const u8 = null,
};

pub const SkillResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    name: []const u8 = "",
    description: []const u8 = "",
    created_at: i64 = 0,
    default_version: []const u8 = "",
    latest_version: []const u8 = "",
};

pub const SkillVersionListResource = struct {
    object: []const u8 = "",
    data: []const SkillVersionResource = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
};

pub const SkillVersionResource = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    skill_id: []const u8 = "",
    version: []const u8 = "",
    created_at: i64 = 0,
    name: []const u8 = "",
    description: []const u8 = "",
};

pub const SpecificApplyPatchParam = struct {
    @"type": []const u8 = "",
};

pub const SpecificFunctionShellParam = struct {
    @"type": []const u8 = "",
};

pub const SpecificProgrammaticToolCallingParam = struct {
    @"type": []const u8 = "",
};

pub const SpeechAudioDeltaEvent = struct {
    @"type": []const u8 = "",
    audio: []const u8 = "",
};

pub const SpeechAudioDoneEvent = struct {
    @"type": []const u8 = "",
    usage: ?struct {
    input_tokens: i64 = 0,
    output_tokens: i64 = 0,
    total_tokens: i64 = 0,
} = null,
};

pub const SpendAlertNotificationChannel = struct {
    @"type": []const u8 = "",
    recipients: []const []const u8 = &.{},
    subject_prefix: ?std.json.Value = null,
};

pub const SpendLimitCurrency = std.json.Value;

pub const SpendLimitEnforcement = struct {
    status: ?SpendLimitEnforcementStatus = null,
};

pub const SpendLimitEnforcementStatus = std.json.Value;

pub const SpendLimitInterval = std.json.Value;

pub const StaticChunkingStrategy = struct {
    max_chunk_size_tokens: i64 = 0,
    chunk_overlap_tokens: i64 = 0,
};

pub const StaticChunkingStrategyRequestParam = struct {
    @"type": []const u8 = "",
    static: ?StaticChunkingStrategy = null,
};

pub const StaticChunkingStrategyResponseParam = struct {
    @"type": []const u8 = "",
    static: ?StaticChunkingStrategy = null,
};

pub const StopConfiguration = std.json.Value;

pub const SubmitToolOutputsRunRequest = struct {
    tool_outputs: []const struct {
    tool_call_id: ?[]const u8 = null,
    output: ?[]const u8 = null,
} = &.{},
    stream: ?std.json.Value = null,
};

pub const SummaryTextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const TaskGroupItem = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    @"type": []const u8 = "",
    tasks: []const TaskGroupTask = &.{},
};

pub const TaskGroupTask = struct {
    @"type": ?TaskType = null,
    heading: std.json.Value = .null,
    summary: std.json.Value = .null,
};

pub const TaskItem = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    @"type": []const u8 = "",
    task_type: ?TaskType = null,
    heading: std.json.Value = .null,
    summary: std.json.Value = .null,
};

pub const TaskType = []const u8;

pub const TextContent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const TextResponseFormatConfiguration = std.json.Value;

pub const TextResponseFormatJsonSchema = struct {
    @"type": []const u8 = "",
    description: ?[]const u8 = null,
    name: []const u8 = "",
    schema: ?ResponseFormatJsonSchemaSchema = null,
    strict: ?std.json.Value = null,
};

pub const ThreadItem = std.json.Value;

pub const ThreadItemListResource = struct {
    object: []const u8 = "",
    data: []const ThreadItem = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
};

pub const ThreadListResource = struct {
    object: []const u8 = "",
    data: []const ThreadResource = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
};

pub const ThreadObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    tool_resources: std.json.Value = .null,
    metadata: ?Metadata = null,
};

pub const ThreadResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    title: std.json.Value = .null,
    status: std.json.Value = .null,
    user: []const u8 = "",
};

pub const ThreadStreamEvent = std.json.Value;

pub const ToggleCertificatesRequest = struct {
    certificate_ids: []const []const u8 = &.{},
};

pub const TokenCountsBody = struct {
    model: ?std.json.Value = null,
    input: ?std.json.Value = null,
    previous_response_id: ?std.json.Value = null,
    tools: ?std.json.Value = null,
    text: ?std.json.Value = null,
    reasoning: ?std.json.Value = null,
    truncation: ?TruncationEnum = null,
    instructions: ?std.json.Value = null,
    personality: ?PersonalityEnum = null,
    conversation: ?std.json.Value = null,
    tool_choice: ?std.json.Value = null,
    parallel_tool_calls: ?std.json.Value = null,
};

pub const TokenCountsResource = struct {
    object: []const u8 = "",
    input_tokens: i64 = 0,
};

pub const Tool = std.json.Value;

pub const ToolCallCaller = std.json.Value;

pub const ToolCallCallerParam = std.json.Value;

pub const ToolChoice = struct {
    id: []const u8 = "",
};

pub const ToolChoiceAllowed = struct {
    @"type": []const u8 = "",
    mode: []const u8 = "",
    tools: []const std.json.Value = &.{},
};

pub const ToolChoiceCustom = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
};

pub const ToolChoiceFunction = struct {
    @"type": []const u8 = "",
    name: []const u8 = "",
};

pub const ToolChoiceMCP = struct {
    @"type": []const u8 = "",
    server_label: []const u8 = "",
    name: ?std.json.Value = null,
};

pub const ToolChoiceOptions = []const u8;

pub const ToolChoiceParam = std.json.Value;

pub const ToolChoiceTypes = struct {
    @"type": []const u8 = "",
};

pub const ToolSearchCall = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: std.json.Value = .null,
    execution: ?ToolSearchExecutionType = null,
    arguments: std.json.Value = .null,
    status: ?FunctionCallStatus = null,
    created_by: ?[]const u8 = null,
};

pub const ToolSearchCallItemParam = struct {
    id: ?std.json.Value = null,
    call_id: ?std.json.Value = null,
    @"type": []const u8 = "",
    execution: ?ToolSearchExecutionType = null,
    arguments: ?EmptyModelParam = null,
    status: ?std.json.Value = null,
};

pub const ToolSearchExecutionType = []const u8;

pub const ToolSearchOutput = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    call_id: std.json.Value = .null,
    execution: ?ToolSearchExecutionType = null,
    tools: []const Tool = &.{},
    status: ?FunctionCallOutputStatusEnum = null,
    created_by: ?[]const u8 = null,
};

pub const ToolSearchOutputItemParam = struct {
    id: ?std.json.Value = null,
    call_id: ?std.json.Value = null,
    @"type": []const u8 = "",
    execution: ?ToolSearchExecutionType = null,
    tools: []const Tool = &.{},
    status: ?std.json.Value = null,
};

pub const ToolSearchToolParam = struct {
    @"type": []const u8 = "",
    execution: ?ToolSearchExecutionType = null,
    description: ?std.json.Value = null,
    parameters: ?std.json.Value = null,
};

pub const ToolsArray = []const Tool;

pub const TopLogProb = struct {
    token: []const u8 = "",
    logprob: f64 = 0,
    bytes: []const i64 = &.{},
};

pub const TranscriptTextDeltaEvent = struct {
    @"type": []const u8 = "",
    delta: []const u8 = "",
    logprobs: ?[]const struct {
    token: ?[]const u8 = null,
    logprob: ?f64 = null,
    bytes: ?[]const i64 = null,
} = null,
    segment_id: ?[]const u8 = null,
};

pub const TranscriptTextDoneEvent = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
    logprobs: ?[]const struct {
    token: ?[]const u8 = null,
    logprob: ?f64 = null,
    bytes: ?[]const i64 = null,
} = null,
    usage: ?TranscriptTextUsageTokens = null,
};

pub const TranscriptTextSegmentEvent = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    start: f64 = 0,
    end: f64 = 0,
    text: []const u8 = "",
    speaker: []const u8 = "",
};

pub const TranscriptTextUsageDuration = struct {
    @"type": []const u8 = "",
    seconds: f64 = 0,
};

pub const TranscriptTextUsageTokens = struct {
    @"type": []const u8 = "",
    input_tokens: i64 = 0,
    input_token_details: ?struct {
    text_tokens: ?i64 = null,
    audio_tokens: ?i64 = null,
} = null,
    output_tokens: i64 = 0,
    total_tokens: i64 = 0,
};

pub const TranscriptionChunkingStrategy = std.json.Value;

pub const TranscriptionDiarizedSegment = struct {
    @"type": []const u8 = "",
    id: []const u8 = "",
    start: f64 = 0,
    end: f64 = 0,
    text: []const u8 = "",
    speaker: []const u8 = "",
};

pub const TranscriptionInclude = []const u8;

pub const TranscriptionSegment = struct {
    id: i64 = 0,
    seek: i64 = 0,
    start: f64 = 0,
    end: f64 = 0,
    text: []const u8 = "",
    tokens: []const i64 = &.{},
    temperature: f64 = 0,
    avg_logprob: f64 = 0,
    compression_ratio: f64 = 0,
    no_speech_prob: f64 = 0,
};

pub const TranscriptionWord = struct {
    word: []const u8 = "",
    start: f64 = 0,
    end: f64 = 0,
};

pub const TruncationEnum = []const u8;

pub const TruncationObject = struct {
    @"type": []const u8 = "",
    last_messages: ?std.json.Value = null,
};

pub const TypeParam = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const UpdateConversationBody = struct {
    metadata: ?Metadata = null,
};

pub const UpdateGroupBody = struct {
    name: []const u8 = "",
};

pub const UpdateOrganizationDataRetentionBody = struct {
    retention_type: []const u8 = "",
};

pub const UpdateOrganizationSpendLimitBody = struct {
    threshold_amount: i64 = 0,
    currency: []const u8 = "",
    interval: []const u8 = "",
};

pub const UpdateProjectDataRetentionBody = struct {
    retention_type: []const u8 = "",
};

pub const UpdateProjectServiceAccountBody = struct {
    name: ?[]const u8 = null,
    role: ?[]const u8 = null,
};

pub const UpdateProjectSpendLimitBody = struct {
    threshold_amount: i64 = 0,
    currency: []const u8 = "",
    interval: []const u8 = "",
};

pub const UpdateVectorStoreFileAttributesRequest = struct {
    attributes: ?VectorStoreFileAttributes = null,
};

pub const UpdateVectorStoreRequest = struct {
    name: ?[]const u8 = null,
    expires_after: ?struct {
    anchor: []const u8 = "",
    days: i64 = 0,
} = null,
    metadata: ?Metadata = null,
};

pub const UpdateVoiceConsentRequest = struct {
    name: []const u8 = "",
};

pub const Upload = struct {
    id: []const u8 = "",
    created_at: i64 = 0,
    filename: []const u8 = "",
    bytes: i64 = 0,
    purpose: []const u8 = "",
    status: []const u8 = "",
    expires_at: i64 = 0,
    object: ?[]const u8 = null,
    file: ?struct {
    id: []const u8 = "",
    bytes: i64 = 0,
    created_at: i64 = 0,
    expires_at: ?i64 = null,
    filename: []const u8 = "",
    object: []const u8 = "",
    purpose: []const u8 = "",
    status: []const u8 = "",
    status_details: ?[]const u8 = null,
} = null,
};

pub const UploadCertificateRequest = struct {
    name: ?[]const u8 = null,
    certificate: []const u8 = "",
};

pub const UploadPart = struct {
    id: []const u8 = "",
    created_at: i64 = 0,
    upload_id: []const u8 = "",
    object: []const u8 = "",
};

pub const UrlAnnotation = struct {
    @"type": []const u8 = "",
    source: ?UrlAnnotationSource = null,
};

pub const UrlAnnotationSource = struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
};

pub const UrlCitationBody = struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    title: []const u8 = "",
};

pub const UrlCitationParam = struct {
    @"type": []const u8 = "",
    start_index: i64 = 0,
    end_index: i64 = 0,
    url: []const u8 = "",
    title: []const u8 = "",
};

pub const UsageAudioSpeechesResult = struct {
    object: []const u8 = "",
    characters: i64 = 0,
    num_model_requests: i64 = 0,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    model: ?std.json.Value = null,
};

pub const UsageAudioTranscriptionsResult = struct {
    object: []const u8 = "",
    seconds: i64 = 0,
    num_model_requests: i64 = 0,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    model: ?std.json.Value = null,
};

pub const UsageCodeInterpreterSessionsResult = struct {
    object: []const u8 = "",
    num_sessions: i64 = 0,
    project_id: ?std.json.Value = null,
};

pub const UsageCompletionsResult = struct {
    object: []const u8 = "",
    input_tokens: i64 = 0,
    input_cached_tokens: ?i64 = null,
    input_cache_write_tokens: ?i64 = null,
    input_uncached_tokens: ?i64 = null,
    output_tokens: i64 = 0,
    input_text_tokens: ?i64 = null,
    output_text_tokens: ?i64 = null,
    input_cached_text_tokens: ?i64 = null,
    input_audio_tokens: ?i64 = null,
    input_cached_audio_tokens: ?i64 = null,
    output_audio_tokens: ?i64 = null,
    input_image_tokens: ?i64 = null,
    input_cached_image_tokens: ?i64 = null,
    output_image_tokens: ?i64 = null,
    num_model_requests: i64 = 0,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    model: ?std.json.Value = null,
    batch: ?std.json.Value = null,
    service_tier: ?std.json.Value = null,
};

pub const UsageEmbeddingsResult = struct {
    object: []const u8 = "",
    input_tokens: i64 = 0,
    num_model_requests: i64 = 0,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    model: ?std.json.Value = null,
};

pub const UsageFileSearchCallsResult = struct {
    object: []const u8 = "",
    num_requests: i64 = 0,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    vector_store_id: ?std.json.Value = null,
};

pub const UsageImagesResult = struct {
    object: []const u8 = "",
    images: i64 = 0,
    num_model_requests: i64 = 0,
    source: ?std.json.Value = null,
    size: ?std.json.Value = null,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    model: ?std.json.Value = null,
};

pub const UsageModerationsResult = struct {
    object: []const u8 = "",
    input_tokens: i64 = 0,
    num_model_requests: i64 = 0,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    model: ?std.json.Value = null,
};

pub const UsageResponse = struct {
    object: []const u8 = "",
    data: []const UsageTimeBucket = &.{},
    has_more: bool = false,
    next_page: std.json.Value = .null,
};

pub const UsageTimeBucket = struct {
    object: []const u8 = "",
    start_time: i64 = 0,
    end_time: i64 = 0,
    results: []const UsageCompletionsResult = &.{},
};

pub const UsageVectorStoresResult = struct {
    object: []const u8 = "",
    usage_bytes: i64 = 0,
    project_id: ?std.json.Value = null,
};

pub const UsageWebSearchCallsResult = struct {
    object: []const u8 = "",
    num_model_requests: i64 = 0,
    num_requests: i64 = 0,
    project_id: ?std.json.Value = null,
    user_id: ?std.json.Value = null,
    api_key_id: ?std.json.Value = null,
    model: ?std.json.Value = null,
    context_level: ?std.json.Value = null,
};

pub const User = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: ?std.json.Value = null,
    email: ?std.json.Value = null,
    role: ?std.json.Value = null,
    added_at: i64 = 0,
    is_default: ?bool = null,
    created: ?i64 = null,
    user: ?struct {
    object: []const u8 = "",
    id: []const u8 = "",
    email: ?std.json.Value = null,
    name: ?std.json.Value = null,
    picture: ?std.json.Value = null,
    enabled: ?std.json.Value = null,
    banned: ?std.json.Value = null,
    banned_at: ?std.json.Value = null,
} = null,
    is_service_account: ?bool = null,
    is_scale_tier_authorized_purchaser: ?std.json.Value = null,
    is_scim_managed: ?bool = null,
    api_key_last_used_at: ?std.json.Value = null,
    technical_level: ?std.json.Value = null,
    developer_persona: ?std.json.Value = null,
    projects: ?std.json.Value = null,
};

pub const UserDeleteResponse = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    deleted: bool = false,
};

pub const UserListResource = struct {
    object: []const u8 = "",
    data: []const GroupUser = &.{},
    has_more: bool = false,
    next: std.json.Value = .null,
};

pub const UserListResponse = struct {
    object: []const u8 = "",
    data: []const User = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const UserMessageInputText = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const UserMessageItem = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    @"type": []const u8 = "",
    content: []const UserMessageInputText = &.{},
    attachments: []const Attachment = &.{},
    inference_options: std.json.Value = .null,
};

pub const UserMessageQuotedText = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const UserRoleAssignment = struct {
    object: []const u8 = "",
    user: ?User = null,
    role: ?Role = null,
};

pub const UserRoleUpdateRequest = struct {
    role: ?std.json.Value = null,
    role_id: ?std.json.Value = null,
    technical_level: ?std.json.Value = null,
    developer_persona: ?std.json.Value = null,
};

pub const VadConfig = struct {
    @"type": []const u8 = "",
    prefix_padding_ms: ?i64 = null,
    silence_duration_ms: ?i64 = null,
    threshold: ?f64 = null,
};

pub const ValidateGraderRequest = struct {
    grader: std.json.Value = .null,
};

pub const ValidateGraderResponse = struct {
    grader: ?std.json.Value = null,
};

pub const VectorStoreExpirationAfter = struct {
    anchor: []const u8 = "",
    days: i64 = 0,
};

pub const VectorStoreFileAttributes = std.json.Value;

pub const VectorStoreFileBatchObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    vector_store_id: []const u8 = "",
    status: []const u8 = "",
    file_counts: ?struct {
    in_progress: i64 = 0,
    completed: i64 = 0,
    failed: i64 = 0,
    cancelled: i64 = 0,
    total: i64 = 0,
} = null,
};

pub const VectorStoreFileContentResponse = struct {
    object: []const u8 = "",
    data: []const struct {
    @"type": ?[]const u8 = null,
    text: ?[]const u8 = null,
} = &.{},
    has_more: bool = false,
    next_page: std.json.Value = .null,
};

pub const VectorStoreFileObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    usage_bytes: i64 = 0,
    created_at: i64 = 0,
    vector_store_id: []const u8 = "",
    status: []const u8 = "",
    last_error: std.json.Value = .null,
    chunking_strategy: ?std.json.Value = null,
    attributes: ?VectorStoreFileAttributes = null,
};

pub const VectorStoreObject = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    name: []const u8 = "",
    usage_bytes: i64 = 0,
    file_counts: ?struct {
    in_progress: i64 = 0,
    completed: i64 = 0,
    failed: i64 = 0,
    cancelled: i64 = 0,
    total: i64 = 0,
} = null,
    status: []const u8 = "",
    expires_after: ?VectorStoreExpirationAfter = null,
    expires_at: ?std.json.Value = null,
    last_active_at: std.json.Value = .null,
    metadata: ?Metadata = null,
};

pub const VectorStoreSearchRequest = struct {
    query: std.json.Value = .null,
    rewrite_query: ?bool = null,
    max_num_results: ?i64 = null,
    filters: ?std.json.Value = null,
    ranking_options: ?struct {
    ranker: ?[]const u8 = null,
    score_threshold: ?f64 = null,
} = null,
};

pub const VectorStoreSearchResultContentObject = struct {
    @"type": []const u8 = "",
    text: []const u8 = "",
};

pub const VectorStoreSearchResultItem = struct {
    file_id: []const u8 = "",
    filename: []const u8 = "",
    score: f64 = 0,
    attributes: ?VectorStoreFileAttributes = null,
    content: []const VectorStoreSearchResultContentObject = &.{},
};

pub const VectorStoreSearchResultsPage = struct {
    object: []const u8 = "",
    search_query: []const []const u8 = &.{},
    data: []const VectorStoreSearchResultItem = &.{},
    has_more: bool = false,
    next_page: std.json.Value = .null,
};

pub const Verbosity = std.json.Value;

pub const VideoCharacterResource = struct {
    id: std.json.Value = .null,
    name: std.json.Value = .null,
    created_at: i64 = 0,
};

pub const VideoContentVariant = []const u8;

pub const VideoListResource = struct {
    object: []const u8 = "",
    data: []const VideoResource = &.{},
    first_id: std.json.Value = .null,
    last_id: std.json.Value = .null,
    has_more: bool = false,
};

pub const VideoModel = std.json.Value;

pub const VideoReferenceInputParam = struct {
    id: []const u8 = "",
};

pub const VideoResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    model: ?VideoModel = null,
    status: ?VideoStatus = null,
    progress: i64 = 0,
    created_at: i64 = 0,
    completed_at: std.json.Value = .null,
    expires_at: std.json.Value = .null,
    prompt: std.json.Value = .null,
    size: ?VideoSize = null,
    seconds: []const u8 = "",
    remixed_from_video_id: std.json.Value = .null,
    @"error": std.json.Value = .null,
};

pub const VideoSeconds = []const u8;

pub const VideoSize = []const u8;

pub const VideoStatus = []const u8;

pub const VoiceConsentDeletedResource = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    deleted: bool = false,
};

pub const VoiceConsentListResource = struct {
    object: []const u8 = "",
    data: []const VoiceConsentResource = &.{},
    first_id: ?std.json.Value = null,
    last_id: ?std.json.Value = null,
    has_more: bool = false,
};

pub const VoiceConsentResource = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    language: []const u8 = "",
    created_at: i64 = 0,
};

pub const VoiceIdsOrCustomVoice = std.json.Value;

pub const VoiceIdsShared = std.json.Value;

pub const VoiceResource = struct {
    object: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    created_at: i64 = 0,
};

pub const WaitParam = struct {
    @"type": []const u8 = "",
};

pub const WebSearchActionFind = struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
    pattern: []const u8 = "",
};

pub const WebSearchActionOpenPage = struct {
    @"type": []const u8 = "",
    url: ?std.json.Value = null,
};

pub const WebSearchActionSearch = struct {
    @"type": []const u8 = "",
    query: ?[]const u8 = null,
    queries: ?[]const []const u8 = null,
    sources: ?[]const struct {
    @"type": []const u8 = "",
    url: []const u8 = "",
} = null,
};

pub const WebSearchApproximateLocation = std.json.Value;

pub const WebSearchContextSize = []const u8;

pub const WebSearchLocation = struct {
    country: ?[]const u8 = null,
    region: ?[]const u8 = null,
    city: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
};

pub const WebSearchPreviewTool = struct {
    @"type": []const u8 = "",
    user_location: ?std.json.Value = null,
    search_context_size: ?SearchContextSize = null,
    search_content_types: ?[]const SearchContentType = null,
};

pub const WebSearchTool = struct {
    @"type": []const u8 = "",
    filters: ?std.json.Value = null,
    user_location: ?WebSearchApproximateLocation = null,
    search_context_size: ?[]const u8 = null,
};

pub const WebSearchToolCall = struct {
    id: []const u8 = "",
    @"type": []const u8 = "",
    status: []const u8 = "",
    action: std.json.Value = .null,
};

pub const WebhookBatchCancelled = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookBatchCompleted = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookBatchExpired = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookBatchFailed = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookEvalRunCanceled = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookEvalRunFailed = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookEvalRunSucceeded = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookFineTuningJobCancelled = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookFineTuningJobFailed = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookFineTuningJobSucceeded = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookRealtimeCallIncoming = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    call_id: []const u8 = "",
    sip_headers: []const struct {
    name: []const u8 = "",
    value: []const u8 = "",
} = &.{},
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookResponseCancelled = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookResponseCompleted = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookResponseFailed = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WebhookResponseIncomplete = struct {
    created_at: i64 = 0,
    id: []const u8 = "",
    data: ?struct {
    id: []const u8 = "",
} = null,
    object: ?[]const u8 = null,
    @"type": []const u8 = "",
};

pub const WidgetMessageItem = struct {
    id: []const u8 = "",
    object: []const u8 = "",
    created_at: i64 = 0,
    thread_id: []const u8 = "",
    @"type": []const u8 = "",
    widget: []const u8 = "",
};

pub const WorkflowParam = struct {
    id: []const u8 = "",
    version: ?[]const u8 = null,
    state_variables: ?std.json.Value = null,
    tracing: ?WorkflowTracingParam = null,
};

pub const WorkflowTracingParam = struct {
    enabled: ?bool = null,
};

// --- Compatibility aliases (resources + older names) ---

pub const EvalObject = Eval;

pub const SubmitToolOutputsRequest = SubmitToolOutputsRunRequest;

pub const UpdateUserRoleRequest = UserRoleUpdateRequest;

pub const UpdateVectorStoreFileRequest = UpdateVectorStoreFileAttributesRequest;

pub const CreateVideoBody = CreateVideoJsonBody;

pub const ChatCompletionRequestAssistantMessageContent = std.json.Value;

pub const ChatCompletionRequestDeveloperMessageContent = std.json.Value;

pub const ChatCompletionRequestSystemMessageContent = std.json.Value;

pub const ChatCompletionRequestToolMessageContent = std.json.Value;

pub const CreateMessageRequestContent = std.json.Value;

pub const CreateMessageRequestContentPart = std.json.Value;

pub const CreateModerationRequestInput = std.json.Value;

pub const CreateEmbeddingRequestInput = std.json.Value;

pub const ChunkingStrategyResponse = std.json.Value;

pub const EvalDataSourceConfig = std.json.Value;

pub const EvalGraderConfig = std.json.Value;

pub const EvalRunDataSource = std.json.Value;

pub const GenericContent = std.json.Value;

pub const MessageContent = std.json.Value;

pub const MessageContentDelta = std.json.Value;

pub const UserMessageItemContent = std.json.Value;

pub const FineTuneChatRequestInput = std.json.Value;

pub const FineTunePreferenceRequestInput = std.json.Value;

pub const FineTuneReinforcementRequestInput = std.json.Value;

pub const CreateCompletionLogitBias = std.json.Value;

pub const ChatCompletionRequestFunctionCall = struct {
    arguments: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const ChatCompletionRequestAssistantMessageAudio = struct {
    id: ?[]const u8 = null,
};

pub const ChatCompletionResponseMessageAudio = struct {
    id: ?[]const u8 = null,
    expires_at: ?i64 = null,
    data: ?[]const u8 = null,
    transcript: ?[]const u8 = null,
};

pub const CreateCompletionLogitBiasEntry = struct {
    token: ?[]const u8 = null,
    bias: ?i64 = null,
};

pub const ChatCompletionChoice = struct {
    index: ?i64 = null,
    message: ?ChatCompletionResponseMessage = null,
    logprobs: ?std.json.Value = null,
    finish_reason: ?[]const u8 = null,
};

