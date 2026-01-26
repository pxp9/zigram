const std = @import("std");
const acp_types = @import("acp_types.zig");

const log = std.log.scoped(.acp_client);

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
        _ = self.process.kill() catch {};
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

    pub fn newSession(self: *AcpConnection, cwd: []const u8, mcp_servers: []const acp_types.McpServer) AcpError![]const u8 {
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
