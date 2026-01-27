const std = @import("std");
const vaxis = @import("vaxis");
const acp_types = @import("acp_types.zig");
const utils = @import("../utils.zig");
const ai = @import("../ai.zig");
const telegram = @import("../telegram.zig");

const log = std.log.scoped(.acp);

pub const AcpError = error{
    ProcessSpawnFailed,
    InitializeFailed,
    SessionCreateFailed,
    PromptFailed,
    InvalidResponse,
    ConnectionClosed,
    ProtocolError,
    OutOfMemory,
    Overflow,
    EndOfStream,
    StreamTooLong,
    InvalidCharacter,
    UnexpectedCharacter,
    UnknownFormat,
    InvalidNumber,
    SyntaxError,
    LengthMismatch,
    DuplicateField,
    MissingField,
};

pub const AcpConnection = struct {
    process: std.process.Child,
    stdin: std.fs.File,
    stdout: std.fs.File,
    read_buffer: [8192]u8,
    read_pos: usize,
    read_end: usize,
    session_id: ?[]const u8,
    request_id: u32,
    alloc: std.mem.Allocator,
    initialized: bool,

    pub fn spawn(alloc: std.mem.Allocator, command: []const u8, args: []const []const u8, cwd: ?[]const u8) AcpError!*AcpConnection {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);

        argv.append(alloc, command) catch return AcpError.OutOfMemory;
        for (args) |arg| {
            argv.append(alloc, arg) catch return AcpError.OutOfMemory;
        }

        var child = std.process.Child.init(argv.items, alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        // Make the child its own process group leader so we can kill the entire group
        child.pgid = 0;

        if (cwd) |dir| {
            child.cwd = dir;
        }

        child.spawn() catch {
            log.err("Failed to spawn ACP process: {s}", .{command});
            return AcpError.ProcessSpawnFailed;
        };

        const stdin_file = child.stdin orelse return AcpError.ProcessSpawnFailed;
        const stdout_file = child.stdout orelse return AcpError.ProcessSpawnFailed;

        const conn = alloc.create(AcpConnection) catch return AcpError.OutOfMemory;
        conn.* = .{
            .process = child,
            .stdin = stdin_file,
            .stdout = stdout_file,
            .read_buffer = undefined,
            .read_pos = 0,
            .read_end = 0,
            .session_id = null,
            .request_id = 0,
            .alloc = alloc,
            .initialized = false,
        };

        return conn;
    }

    pub fn deinit(self: *AcpConnection) void {
        if (self.session_id) |sid| {
            self.alloc.free(sid);
        }
        // Kill the entire process group to ensure child processes (MCP servers) are also killed
        if (self.process.id) |pid| {
            // Negative PID kills the process group
            std.posix.kill(-@as(i32, @intCast(pid)), std.posix.SIG.KILL) catch {
                // Fallback to killing just the process
                _ = self.process.kill() catch {};
            };
        } else {
            _ = self.process.kill() catch {};
        }
        _ = self.process.wait() catch {};
        self.alloc.destroy(self);
    }

    pub fn initialize(self: *AcpConnection) AcpError!acp_types.InitializeResult {
        const params = acp_types.InitializeParams{
            .protocolVersion = 1,
            .clientCapabilities = .{
                .fs = .{ .readTextFile = true, .writeTextFile = true },
                .terminal = true,
            },
            .clientInfo = .{
                .name = "zigram",
                .version = "0.1.0",
                .title = "Zigram Telegram Client",
            },
        };

        try self.sendRequest("initialize", params);
        const response = try self.readResponse();
        defer response.deinit();

        if (response.value.object.get("error")) |err_val| {
            if (err_val.object.get("message")) |msg| {
                log.err("Initialize error: {s}", .{msg.string});
            }
            return AcpError.InitializeFailed;
        }

        const result_val = response.value.object.get("result") orelse return AcpError.InvalidResponse;

        var result = acp_types.InitializeResult{
            .protocolVersion = 1,
        };

        if (result_val.object.get("protocolVersion")) |pv| {
            result.protocolVersion = @intCast(pv.integer);
        }

        self.initialized = true;
        return result;
    }

    pub fn newSession(self: *AcpConnection, cwd: []const u8) AcpError![]const u8 {
        return self.newSessionWithMcp(cwd, null, null);
    }

    pub fn newSessionWithMcp(self: *AcpConnection, cwd: []const u8, mcp_server_path: ?[]const u8, socket_path: ?[]const u8) AcpError![]const u8 {
        // Build MCP servers array
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

        const params = acp_types.NewSessionParams{
            .cwd = cwd,
            .mcpServers = mcp_servers,
        };

        try self.sendRequest("session/new", params);
        const response = try self.readResponse();
        defer response.deinit();

        if (response.value.object.get("error")) |err_val| {
            if (err_val.object.get("message")) |msg| {
                log.err("Session create error: {s}", .{msg.string});
            }
            return AcpError.SessionCreateFailed;
        }

        const result = response.value.object.get("result") orelse return AcpError.InvalidResponse;
        const session_id_val = result.object.get("sessionId") orelse return AcpError.InvalidResponse;

        const session_id = self.alloc.dupe(u8, session_id_val.string) catch return AcpError.OutOfMemory;
        self.session_id = session_id;
        return session_id;
    }

    pub fn sendPrompt(self: *AcpConnection, session_id: []const u8, content: []const u8) AcpError!void {
        var prompt_array: [1]acp_types.ContentBlock = .{
            .{ .text = .{ .text = content } },
        };

        const params = acp_types.PromptParams{
            .sessionId = session_id,
            .prompt = &prompt_array,
        };

        try self.sendRequest("session/prompt", params);
    }

    pub fn cancel(self: *AcpConnection, session_id: []const u8) AcpError!void {
        const params = acp_types.CancelParams{
            .sessionId = session_id,
        };

        try self.sendNotification("session/cancel", params);
    }

    pub fn respondPermission(self: *AcpConnection, request_id: u32, option_id: []const u8) AcpError!void {
        var buf: [1024]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"outcome\":{{\"outcome\":\"selected\",\"optionId\":\"{s}\"}}}}}}\n", .{ request_id, option_id }) catch return AcpError.Overflow;

        log.info("Sending permission response: {s}", .{json[0 .. json.len - 1]}); // -1 to skip newline
        self.stdin.writeAll(json) catch return AcpError.ConnectionClosed;
    }

    fn sendRequest(self: *AcpConnection, method: []const u8, params: anytype) AcpError!void {
        self.request_id += 1;

        const fmt = std.json.fmt(params, .{});
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        fmt.format(&out.writer) catch return AcpError.OutOfMemory;
        const params_json = out.toOwnedSlice() catch return AcpError.OutOfMemory;
        defer self.alloc.free(params_json);

        const json = std.fmt.allocPrint(self.alloc, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}\n", .{ self.request_id, method, params_json }) catch return AcpError.OutOfMemory;
        defer self.alloc.free(json);

        log.debug("Sending: {s}", .{json});
        self.stdin.writeAll(json) catch return AcpError.ConnectionClosed;
    }

    fn sendNotification(self: *AcpConnection, method: []const u8, params: anytype) AcpError!void {
        const fmt = std.json.fmt(params, .{});
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        fmt.format(&out.writer) catch return AcpError.OutOfMemory;
        const params_json = out.toOwnedSlice() catch return AcpError.OutOfMemory;
        defer self.alloc.free(params_json);

        const json = std.fmt.allocPrint(self.alloc, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, params_json }) catch return AcpError.OutOfMemory;
        defer self.alloc.free(json);

        self.stdin.writeAll(json) catch return AcpError.ConnectionClosed;
    }

    fn readLine(self: *AcpConnection) AcpError!?[]const u8 {
        return self.readLineWithTimeout(null);
    }

    fn readLineWithTimeout(self: *AcpConnection, timeout_ms: ?i32) AcpError!?[]const u8 {
        var line_buf: std.ArrayList(u8) = .empty;
        errdefer line_buf.deinit(self.alloc);

        while (true) {
            var i: usize = self.read_pos;
            while (i < self.read_end) : (i += 1) {
                if (self.read_buffer[i] == '\n') {
                    line_buf.appendSlice(self.alloc, self.read_buffer[self.read_pos..i]) catch return AcpError.OutOfMemory;
                    self.read_pos = i + 1;
                    return line_buf.toOwnedSlice(self.alloc) catch return AcpError.OutOfMemory;
                }
            }

            if (self.read_pos < self.read_end) {
                line_buf.appendSlice(self.alloc, self.read_buffer[self.read_pos..self.read_end]) catch return AcpError.OutOfMemory;
            }
            self.read_pos = 0;
            self.read_end = 0;

            // Use poll to check if data is available (with timeout)
            if (timeout_ms) |t| {
                var fds = [_]std.posix.pollfd{.{
                    .fd = self.stdout.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const poll_result = std.posix.poll(&fds, t) catch {
                    if (line_buf.items.len > 0) {
                        return line_buf.toOwnedSlice(self.alloc) catch return AcpError.OutOfMemory;
                    }
                    return null;
                };
                if (poll_result == 0) {
                    // Timeout - no data available
                    if (line_buf.items.len > 0) {
                        // Return partial line (shouldn't happen normally)
                        return line_buf.toOwnedSlice(self.alloc) catch return AcpError.OutOfMemory;
                    }
                    return null;
                }
            }

            const bytes_read = self.stdout.read(&self.read_buffer) catch {
                if (line_buf.items.len > 0) {
                    return line_buf.toOwnedSlice(self.alloc) catch return AcpError.OutOfMemory;
                }
                return null;
            };

            if (bytes_read == 0) {
                if (line_buf.items.len > 0) {
                    return line_buf.toOwnedSlice(self.alloc) catch return AcpError.OutOfMemory;
                }
                return null;
            }

            self.read_end = bytes_read;
        }
    }

    fn readResponse(self: *AcpConnection) AcpError!std.json.Parsed(std.json.Value) {
        const line = self.readLine() catch |err| {
            log.err("Failed to read response: {any}", .{err});
            return AcpError.ConnectionClosed;
        } orelse {
            log.err("Unexpected end of stream", .{});
            return AcpError.ConnectionClosed;
        };
        defer self.alloc.free(line);

        log.debug("Received: {s}", .{line});

        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch {
            return AcpError.InvalidResponse;
        };

        return parsed;
    }

    pub fn readMessage(self: *AcpConnection) AcpError!?AcpMessage {
        return self.readMessageWithTimeout(null);
    }

    pub fn readMessageWithTimeout(self: *AcpConnection, timeout_ms: ?i32) AcpError!?AcpMessage {
        const line = self.readLineWithTimeout(timeout_ms) catch |err| {
            log.err("Failed to read message: {any}", .{err});
            return AcpError.ConnectionClosed;
        } orelse return null;
        defer self.alloc.free(line);

        if (line.len == 0) return null;

        log.debug("Received message: {s}", .{line});

        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, line, .{}) catch {
            return AcpError.InvalidResponse;
        };

        return AcpMessage{
            .parsed = parsed,
            .alloc = self.alloc,
        };
    }
};

pub const AcpMessage = struct {
    parsed: std.json.Parsed(std.json.Value),
    alloc: std.mem.Allocator,

    pub fn deinit(self: *AcpMessage) void {
        self.parsed.deinit();
    }

    pub fn isResponse(self: *const AcpMessage) bool {
        return self.parsed.value.object.get("id") != null and
            (self.parsed.value.object.get("result") != null or self.parsed.value.object.get("error") != null);
    }

    pub fn isNotification(self: *const AcpMessage) bool {
        return self.parsed.value.object.get("method") != null and
            self.parsed.value.object.get("id") == null;
    }

    pub fn isRequest(self: *const AcpMessage) bool {
        return self.parsed.value.object.get("method") != null and
            self.parsed.value.object.get("id") != null;
    }

    pub fn getMethod(self: *const AcpMessage) ?[]const u8 {
        const method = self.parsed.value.object.get("method") orelse return null;
        return method.string;
    }

    pub fn getId(self: *const AcpMessage) ?u32 {
        const id = self.parsed.value.object.get("id") orelse return null;
        return @intCast(id.integer);
    }

    pub fn getParams(self: *const AcpMessage) ?std.json.Value {
        return self.parsed.value.object.get("params");
    }

    pub fn getResult(self: *const AcpMessage) ?std.json.Value {
        return self.parsed.value.object.get("result");
    }

    pub fn getError(self: *const AcpMessage) ?std.json.Value {
        return self.parsed.value.object.get("error");
    }
};

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
        ctx.config.command,
        ctx.config.args,
        ctx.config.cwd,
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

    const cwd = ctx.config.cwd orelse ".";
    const session_id = conn.newSessionWithMcp(cwd, ctx.mcp_server_path, ctx.mcp_socket_path) catch |err| {
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

pub const ClaudeCodeConfig = struct {
    command: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8,
    allocated: bool = false,

    pub fn deinit(self: *ClaudeCodeConfig, alloc: std.mem.Allocator) void {
        if (self.allocated) {
            alloc.free(self.command);
            for (self.args) |arg| {
                alloc.free(arg);
            }
            alloc.free(self.args);
            if (self.cwd) |cwd| {
                alloc.free(cwd);
            }
        }
    }
};

// Default command to run Claude Code ACP
// Users should install: npm install -g @zed-industries/claude-code-acp
// Or use bunx/npx: bunx @zed-industries/claude-code-acp
