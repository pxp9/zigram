const std = @import("std");
const vaxis = @import("vaxis");
const acp_types = @import("acp_types.zig");
const acp_client = @import("acp_client.zig");
const utils = @import("../utils.zig");
const ai = @import("../ai.zig");
const telegram = @import("../telegram.zig");

const log = std.log.scoped(.claude_code);

// Re-export from acp_client for convenience
pub const AcpError = acp_client.AcpError;
pub const AcpConnection = acp_client.AcpConnection;
pub const AcpMessage = acp_client.AcpMessage;

/// Helper function to create a new session with MCP server registration
pub fn newSessionWithMcp(conn: *AcpConnection, cwd: []const u8, mcp_server_path: ?[]const u8, socket_path: ?[]const u8) AcpError![]const u8 {
    var mcp_servers_buf: [1]acp_types.McpServer = undefined;
    var mcp_servers: []const acp_types.McpServer = &.{};
    var env_buf: [1]acp_types.McpServerEnv = undefined;

    if (mcp_server_path) |path| {
        var env: []const acp_types.McpServerEnv = &.{};
        if (socket_path) |sock| {
            env_buf[0] = .{
                .name = "ZIGRAM_MCP_SOCKET",
                .value = sock,
            };
            env = env_buf[0..1];
        }
        mcp_servers_buf[0] = .{
            .name = "zigram",
            .command = path,
            .args = &.{},
            .env = env,
        };
        mcp_servers = mcp_servers_buf[0..1];
        log.info("Registering MCP server: {s} with socket: {?s}", .{ path, socket_path });
    }

    return conn.newSession(cwd, mcp_servers);
}

pub const SessionUpdate = struct {
    kind: acp_types.SessionUpdateKind,
    tool_call_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    tool_kind: ?acp_types.ToolCallKind = null,
    status: ?acp_types.ToolCallStatus = null,
    text: ?[]const u8 = null,
    content: ?[]const u8 = null,
};

pub fn parseSessionUpdate(alloc: std.mem.Allocator, params: std.json.Value) !SessionUpdate {
    const update_obj = params.object.get("update") orelse {
        log.err("parseSessionUpdate: missing 'update' field in params", .{});
        return error.InvalidResponse;
    };

    const kind_str = update_obj.object.get("sessionUpdate") orelse {
        log.debug("parseSessionUpdate: missing 'sessionUpdate' field", .{});
        return error.InvalidResponse;
    };
    const kind = acp_types.SessionUpdateKind.fromString(kind_str.string);
    if (kind == .unknown) {
        log.debug("parseSessionUpdate: ignoring unknown update kind: {s}", .{kind_str.string});
    }

    // Log the raw update for debugging
    const fmt = std.json.fmt(update_obj, .{});
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    fmt.format(&out.writer) catch {};
    const json_str = out.toOwnedSlice() catch "";
    defer if (json_str.len > 0) alloc.free(json_str);
    if (json_str.len > 0 and json_str.len < 1000) {
        log.info("Raw update ({s}): {s}", .{ kind_str.string, json_str });
    }

    var update = SessionUpdate{ .kind = kind };

    switch (kind) {
        .tool_call => {
            if (update_obj.object.get("toolCallId")) |v| update.tool_call_id = v.string;
            if (update_obj.object.get("title")) |v| update.title = v.string;
            if (update_obj.object.get("kind")) |v| update.tool_kind = acp_types.ToolCallKind.fromString(v.string);
            if (update_obj.object.get("status")) |v| update.status = acp_types.ToolCallStatus.fromString(v.string);
        },
        .tool_call_update => {
            if (update_obj.object.get("toolCallId")) |v| update.tool_call_id = v.string;
            if (update_obj.object.get("status")) |v| {
                update.status = acp_types.ToolCallStatus.fromString(v.string);
                log.info("tool_call_update status: {s}", .{v.string});
            }
            if (update_obj.object.get("content")) |content_arr| {
                log.info("tool_call_update has content array with {d} items", .{content_arr.array.items.len});
                if (content_arr.array.items.len > 0) {
                    const first = content_arr.array.items[0];
                    // Try direct text field first
                    if (first.object.get("text")) |text| {
                        update.content = text.string;
                        log.info("tool_call_update content (direct): {s}", .{text.string});
                    } else if (first.object.get("content")) |inner| {
                        if (inner.object.get("text")) |text| {
                            update.content = text.string;
                            log.info("tool_call_update content (nested): {s}", .{text.string});
                        }
                    }
                }
            } else {
                log.info("tool_call_update has NO content field", .{});
            }
        },
        .agent_message_chunk => {
            // Text is nested in content.text
            if (update_obj.object.get("content")) |content| {
                if (content.object.get("text")) |v| {
                    update.text = v.string;
                }
            }
        },
        else => {},
    }

    return update;
}

pub const PermissionRequest = struct {
    request_id: u32,
    session_id: []const u8,
    tool_call_id: []const u8,
    options: []const acp_types.PermissionOption,
};

pub fn parsePermissionRequest(alloc: std.mem.Allocator, request_id: u32, params: std.json.Value) !PermissionRequest {
    const session_id = params.object.get("sessionId") orelse return error.InvalidResponse;
    const tool_call = params.object.get("toolCall") orelse return error.InvalidResponse;
    const tool_call_id = tool_call.object.get("toolCallId") orelse return error.InvalidResponse;
    const options_arr = params.object.get("options") orelse return error.InvalidResponse;

    var options: std.ArrayList(acp_types.PermissionOption) = .empty;
    errdefer options.deinit(alloc);

    for (options_arr.array.items) |opt| {
        const option_id = opt.object.get("optionId") orelse continue;
        const name = opt.object.get("name") orelse continue;
        const kind = opt.object.get("kind") orelse continue;

        try options.append(alloc, .{
            .optionId = option_id.string,
            .name = name.string,
            .kind = kind.string,
        });
    }

    return PermissionRequest{
        .request_id = request_id,
        .session_id = session_id.string,
        .tool_call_id = tool_call_id.string,
        .options = try options.toOwnedSlice(alloc),
    };
}

pub fn acpAgentLoop(ctx: AcpThreadContext) void {
    log.info("ACP agent thread started", .{});

    var conn = AcpConnection.spawn(
        ctx.alloc,
        default_command,
        default_args,
        default_cwd,
    ) catch |err| {
        log.err("Failed to spawn ACP process: {any}", .{err});
        postError(ctx, "Failed to start Claude Code process");
        return;
    };
    defer conn.deinit();

    _ = conn.initialize() catch |err| {
        log.err("Failed to initialize ACP: {any}", .{err});
        postError(ctx, "Failed to initialize Claude Code");
        return;
    };

    const cwd = ".";
    const session_id = newSessionWithMcp(conn, cwd, ctx.mcp_server_path, ctx.mcp_socket_path) catch |err| {
        log.err("Failed to create session: {any}", .{err});
        postError(ctx, "Failed to create Claude Code session");
        return;
    };

    log.info("ACP session created: {s}", .{session_id});

    while (true) {
        if (ctx.request_queue.next()) |req| {
            switch (req) {
                .shutdown => {
                    log.info("ACP agent thread shutting down", .{});
                    break;
                },
                .send_message => |msg| {
                    handleSendMessage(ctx, conn, session_id, msg);
                },
                .tool_result => |result| {
                    ctx.alloc.free(result.message);
                },
            }
        } else {
            std.Thread.yield() catch {};
        }
    }
}

fn handleSendMessage(ctx: AcpThreadContext, conn: *AcpConnection, session_id: []const u8, msg: anytype) void {
    defer ctx.alloc.free(msg.prompt);

    conn.sendPrompt(session_id, msg.prompt) catch |err| {
        log.err("Failed to send prompt: {any}", .{err});
        postError(ctx, "Failed to send message to Claude Code");
        return;
    };

    var agent_turn_complete = false;

    while (!agent_turn_complete) {
        // Check for shutdown request
        if (ctx.request_queue.peek()) |req| {
            if (req == .shutdown) {
                log.info("Shutdown requested during message handling", .{});
                return;
            }
        }

        // Use timeout so we can periodically check for shutdown
        var message = conn.readMessageWithTimeout(100) catch |err| {
            log.err("Failed to read message: {any}", .{err});
            postError(ctx, "Connection to Claude Code lost");
            return;
        } orelse {
            // Timeout or end of stream - continue to check shutdown
            continue;
        };
        defer message.deinit();

        if (message.isNotification()) {
            const method = message.getMethod() orelse continue;
            log.info("Received notification: {s}", .{method});

            if (std.mem.eql(u8, method, "session/update")) {
                const params = message.getParams() orelse {
                    log.err("session/update: missing params", .{});
                    continue;
                };
                const update = parseSessionUpdate(ctx.alloc, params) catch |err| {
                    log.err("Failed to parse session update: {any}", .{err});
                    continue;
                };
                log.info("Parsed session update: kind={s}", .{@tagName(update.kind)});
                handleSessionUpdate(ctx, update);

                // Check if this update signals the end of the agent's turn
                if (update.kind == .agent_turn_complete) {
                    log.info("Agent turn complete received", .{});
                    agent_turn_complete = true;
                }
            }
        } else if (message.isRequest()) {
            const method = message.getMethod() orelse continue;
            const request_id = message.getId() orelse continue;

            // Log raw request for debugging
            const req_fmt = std.json.fmt(message.parsed.value, .{});
            var req_out: std.Io.Writer.Allocating = .init(ctx.alloc);
            defer req_out.deinit();
            req_fmt.format(&req_out.writer) catch {};
            const req_json = req_out.toOwnedSlice() catch "";
            defer if (req_json.len > 0) ctx.alloc.free(req_json);
            if (req_json.len > 0 and req_json.len < 2000) {
                log.info("Raw request: {s}", .{req_json});
            }

            log.info("Received request: {s} (id: {d})", .{ method, request_id });

            if (std.mem.eql(u8, method, "session/request_permission")) {
                const params = message.getParams() orelse continue;
                log.info("Permission request received", .{});
                const perm_req = parsePermissionRequest(ctx.alloc, request_id, params) catch |err| {
                    log.err("Failed to parse permission request: {any}", .{err});
                    continue;
                };
                defer ctx.alloc.free(perm_req.options);

                log.info("Permission request for tool_call_id: {s}, options: {d}", .{ perm_req.tool_call_id, perm_req.options.len });

                // Prefer allow_always for MCP tools (our own tools), fallback to allow_once
                var allow_option: ?[]const u8 = null;
                var allow_once_option: ?[]const u8 = null;
                for (perm_req.options) |opt| {
                    log.info("  Option: {s} (kind: {s}, id: {s})", .{ opt.name, opt.kind, opt.optionId });
                    const kind = acp_types.PermissionOptionKind.fromString(opt.kind);
                    if (kind == .allow_always) {
                        allow_option = opt.optionId;
                        break;
                    } else if (kind == .allow_once) {
                        allow_once_option = opt.optionId;
                    }
                }
                if (allow_option == null) {
                    allow_option = allow_once_option;
                }

                if (allow_option) |opt_id| {
                    log.info("Responding with option: {s}", .{opt_id});
                    conn.respondPermission(request_id, opt_id) catch |err| {
                        log.err("Failed to respond to permission request: {any}", .{err});
                    };
                } else {
                    log.err("No allow option found in permission request", .{});
                }
            }
        } else if (message.isResponse()) {
            log.info("Received response", .{});
            if (message.getError()) |err| {
                if (err.object.get("message")) |msg_val| {
                    log.err("Response error: {s}", .{msg_val.string});
                    const error_text = ctx.alloc.dupe(u8, msg_val.string) catch continue;
                    ctx.loop.postEvent(.{
                        .ai_update = .{
                            .kind = .error_occurred,
                            .data = error_text,
                        },
                    });
                }
                agent_turn_complete = true;
            } else {
                // The response to session/prompt indicates the turn is complete
                // (the result contains the stop reason)
                log.info("Prompt response received, turn complete", .{});
                agent_turn_complete = true;
            }
        }
    }

    log.info("Posting message_completed event", .{});
    const completed_msg = ctx.alloc.dupe(u8, "") catch return;
    ctx.loop.postEvent(.{
        .ai_update = .{
            .kind = .message_completed,
            .data = completed_msg,
        },
    });
}

fn handleSessionUpdate(ctx: AcpThreadContext, update: SessionUpdate) void {
    log.debug("handleSessionUpdate: kind={any}", .{update.kind});
    switch (update.kind) {
        .agent_message_chunk => {
            log.debug("agent_message_chunk: text={?s}", .{update.text});
            if (update.text) |text| {
                const text_copy = ctx.alloc.dupe(u8, text) catch return;
                log.debug("Posting message_chunk event: {s}", .{text_copy});
                ctx.loop.postEvent(.{
                    .ai_update = .{
                        .kind = .message_chunk,
                        .data = text_copy,
                    },
                });
            }
        },
        .tool_call => {
            if (update.title) |title| {
                const status_text = std.fmt.allocPrint(ctx.alloc, "[Tool: {s}]", .{title}) catch return;
                ctx.loop.postEvent(.{
                    .ai_update = .{
                        .kind = .message_chunk,
                        .data = status_text,
                    },
                });
            }
        },
        .tool_call_update => {
            if (update.content) |content| {
                const content_copy = ctx.alloc.dupe(u8, content) catch return;
                ctx.loop.postEvent(.{
                    .ai_update = .{
                        .kind = .message_chunk,
                        .data = content_copy,
                    },
                });
            }
        },
        else => {},
    }
}

fn postError(ctx: AcpThreadContext, message: []const u8) void {
    const error_msg = ctx.alloc.dupe(u8, message) catch return;
    ctx.loop.postEvent(.{
        .ai_update = .{
            .kind = .error_occurred,
            .data = error_msg,
        },
    });
}

pub const AcpThreadContext = struct {
    config: *const ClaudeCodeConfig,
    loop: *vaxis.Loop(utils.Event),
    request_queue: *utils.AiQueue,
    telegram_queue: *utils.TelegramQueue,
    chats: *std.ArrayList(telegram.Chat),
    mcp_server_path: []const u8,
    mcp_socket_path: []const u8,
    alloc: std.mem.Allocator,
};

// Default command to run Claude Code ACP via bunx
// This command is hardcoded and not user-configurable
const default_command = "bunx";
const default_args = &[_][]const u8{"@zed-industries/claude-code-acp"};
const default_cwd: ?[]const u8 = null;

pub const ClaudeCodeConfig = struct {
    model: []const u8,
    allocated: bool = false,

    pub fn deinit(self: *ClaudeCodeConfig, alloc: std.mem.Allocator) void {
        if (self.allocated) {
            alloc.free(self.model);
        }
    }
};
