const std = @import("std");

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
};

pub const AgentInfo = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const FsCapabilities = struct {
    readTextFile: bool = true,
    writeTextFile: bool = true,
};

pub const ClientCapabilities = struct {
    fs: FsCapabilities = .{},
    terminal: bool = true,
};

pub const PromptCapabilities = struct {
    image: bool = false,
    audio: bool = false,
    embeddedContext: bool = false,
};

pub const AgentCapabilities = struct {
    loadSession: bool = false,
    promptCapabilities: PromptCapabilities = .{},
};

pub const InitializeParams = struct {
    protocolVersion: u32 = 1,
    clientCapabilities: ClientCapabilities = .{},
    clientInfo: ClientInfo,
};

pub const InitializeResult = struct {
    protocolVersion: u32,
    agentCapabilities: AgentCapabilities = .{},
    agentInfo: ?AgentInfo = null,
    authMethods: ?[]const AuthMethod = null,
};

pub const AuthMethod = struct {
    methodId: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
};

pub const NewSessionParams = struct {
    cwd: []const u8,
    mcpServers: []const McpServer = &.{},
};

pub const McpServerEnv = struct {
    name: []const u8,
    value: []const u8,
};

pub const McpServer = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    env: []const McpServerEnv = &.{},
};

pub const NewSessionResult = struct {
    sessionId: []const u8,
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    resource_link: ResourceLink,

    pub fn jsonStringify(self: ContentBlock, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .text => |t| {
                try jw.objectField("type");
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(t.text);
            },
            .resource_link => |r| {
                try jw.objectField("type");
                try jw.write("resource_link");
                try jw.objectField("uri");
                try jw.write(r.uri);
                try jw.objectField("name");
                try jw.write(r.name);
            },
        }
        try jw.endObject();
    }
};

pub const TextContent = struct {
    text: []const u8,
};

pub const ResourceLink = struct {
    uri: []const u8,
    name: []const u8,
    mimeType: ?[]const u8 = null,
    size: ?u64 = null,
};

pub const PromptParams = struct {
    sessionId: []const u8,
    prompt: []const ContentBlock,
};

pub const StopReason = enum {
    end_turn,
    max_tokens,
    tool_call,
    cancelled,
    refusal,

    pub fn fromString(s: []const u8) ?StopReason {
        const map = std.StaticStringMap(StopReason).initComptime(.{
            .{ "end_turn", .end_turn },
            .{ "max_tokens", .max_tokens },
            .{ "tool_call", .tool_call },
            .{ "cancelled", .cancelled },
            .{ "refusal", .refusal },
        });
        return map.get(s);
    }
};

pub const PromptResult = struct {
    stopReason: []const u8,
};

pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,
    cancelled,
    waiting_for_permission,

    pub fn fromString(s: []const u8) ?ToolCallStatus {
        const map = std.StaticStringMap(ToolCallStatus).initComptime(.{
            .{ "pending", .pending },
            .{ "in_progress", .in_progress },
            .{ "completed", .completed },
            .{ "failed", .failed },
            .{ "cancelled", .cancelled },
            .{ "waiting_for_permission", .waiting_for_permission },
        });
        return map.get(s);
    }
};

pub const ToolCallKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn fromString(s: []const u8) ToolCallKind {
        const map = std.StaticStringMap(ToolCallKind).initComptime(.{
            .{ "read", .read },
            .{ "edit", .edit },
            .{ "delete", .delete },
            .{ "move", .move },
            .{ "search", .search },
            .{ "execute", .execute },
            .{ "think", .think },
            .{ "fetch", .fetch },
            .{ "other", .other },
        });
        return map.get(s) orelse .other;
    }
};

pub const SessionUpdateKind = enum {
    tool_call,
    tool_call_update,
    agent_message_chunk,
    agent_turn_complete,
    plan,
    current_mode_update,
    config_option_update,
    session_info_update,
    available_commands_update,
    todo_list_update,
    usage_update,
    unknown,

    pub fn fromString(s: []const u8) SessionUpdateKind {
        const map = std.StaticStringMap(SessionUpdateKind).initComptime(.{
            .{ "tool_call", .tool_call },
            .{ "tool_call_update", .tool_call_update },
            .{ "agent_message_chunk", .agent_message_chunk },
            .{ "agent_turn_complete", .agent_turn_complete },
            .{ "plan", .plan },
            .{ "current_mode_update", .current_mode_update },
            .{ "config_option_update", .config_option_update },
            .{ "session_info_update", .session_info_update },
            .{ "available_commands_update", .available_commands_update },
            .{ "todo_list_update", .todo_list_update },
            .{ "usage_update", .usage_update },
        });
        return map.get(s) orelse .unknown;
    }
};

pub const PermissionOptionKind = enum {
    allow_once,
    allow_always,
    reject_once,
    reject_always,

    pub fn fromString(s: []const u8) ?PermissionOptionKind {
        const map = std.StaticStringMap(PermissionOptionKind).initComptime(.{
            .{ "allow_once", .allow_once },
            .{ "allow_always", .allow_always },
            .{ "reject_once", .reject_once },
            .{ "reject_always", .reject_always },
        });
        return map.get(s);
    }
};

pub const PermissionOption = struct {
    optionId: []const u8,
    name: []const u8,
    kind: []const u8,
};

pub const PermissionRequestParams = struct {
    sessionId: []const u8,
    toolCall: struct {
        toolCallId: []const u8,
    },
    options: []const PermissionOption,
};

pub const CancelParams = struct {
    sessionId: []const u8,
};
