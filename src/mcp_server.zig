const std = @import("std");

const Tool = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
};

const tools = [_]Tool{
    .{
        .name = "send_telegram_message",
        .description = "Send a message to a Telegram chat",
        .schema =
        \\{"type":"object","properties":{"chat_id":{"type":"integer","description":"The numeric ID of the Telegram chat"},"message":{"type":"string","description":"The text message to send"}},"required":["chat_id","message"]}
        ,
    },
    .{
        .name = "list_telegram_chats",
        .description = "List available Telegram chats with their IDs and names",
        .schema =
        \\{"type":"object","properties":{},"required":[]}
        ,
    },
};

var global_log_file: std.fs.File = undefined;

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logToFile,
};

fn logToFile(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime level.asText();
    const scope_txt = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    const timestamp = std.time.timestamp();

    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}] {s} {s}", .{ timestamp, level_txt, scope_txt }) catch return;
    global_log_file.writeAll(msg) catch return;

    const formatted = std.fmt.bufPrint(&buf, format, args) catch return;
    global_log_file.writeAll(formatted) catch return;
    global_log_file.writeAll("\n") catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Setup log file
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const log_dir = try std.fs.path.join(alloc, &[_][]const u8{ home, ".local", "share", "zigram" });
    defer alloc.free(log_dir);
    std.fs.makeDirAbsolute(log_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const log_file_path = try std.fs.path.join(alloc, &[_][]const u8{ log_dir, "mcp-server.log" });
    defer alloc.free(log_file_path);

    global_log_file = try std.fs.createFileAbsolute(log_file_path, .{ .truncate = false });
    defer global_log_file.close();
    try global_log_file.seekFromEnd(0); // Append to end

    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    const socket_path = std.posix.getenv("ZIGRAM_MCP_SOCKET") orelse "/tmp/zigram-mcp.sock";

    std.log.info("MCP server starting, socket: {s}", .{socket_path});

    var read_buf: [65536]u8 = undefined;
    var line_start: usize = 0;
    var line_end: usize = 0;

    while (true) {
        var found_newline = false;
        var newline_pos: usize = 0;
        for (line_start..line_end) |i| {
            if (read_buf[i] == '\n') {
                found_newline = true;
                newline_pos = i;
                break;
            }
        }

        if (found_newline) {
            const line = read_buf[line_start..newline_pos];
            line_start = newline_pos + 1;

            if (line.len > 0) {
                handleMessage(alloc, line, stdout, socket_path) catch |err| {
                    std.debug.print("[mcp] error: {any}\n", .{err});
                };
            }
        } else {
            if (line_start > 0) {
                std.mem.copyForwards(u8, &read_buf, read_buf[line_start..line_end]);
                line_end -= line_start;
                line_start = 0;
            }

            const bytes_read = stdin.read(read_buf[line_end..]) catch |err| {
                std.debug.print("[mcp] read error: {any}\n", .{err});
                break;
            };

            if (bytes_read == 0) {
                std.debug.print("[mcp] EOF, shutting down\n", .{});
                break;
            }

            line_end += bytes_read;
        }
    }
}

fn handleMessage(alloc: std.mem.Allocator, line: []const u8, stdout: std.fs.File, socket_path: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch {
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const method_val = obj.get("method") orelse return;
    const method = method_val.string;
    const id = obj.get("id");
    const params = obj.get("params");

    std.debug.print("[mcp] method: {s}\n", .{method});

    if (std.mem.eql(u8, method, "initialize")) {
        try handleInitialize(alloc, id, stdout);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        try handleToolsList(alloc, id, stdout);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        try handleToolsCall(alloc, id, params, stdout, socket_path);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        std.debug.print("[mcp] client initialized\n", .{});
    } else {
        std.debug.print("[mcp] unknown method: {s}\n", .{method});
        try sendError(alloc, id, -32601, "Method not found", stdout);
    }
}

fn handleInitialize(alloc: std.mem.Allocator, id: ?std.json.Value, stdout: std.fs.File) !void {
    var buf: [64]u8 = undefined;
    const id_str = formatId(id, &buf);

    const response = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"zigram-mcp\",\"version\":\"0.1.0\"}}}}}}\n",
        .{id_str},
    );
    defer alloc.free(response);

    _ = try stdout.write(response);
}

fn handleToolsList(alloc: std.mem.Allocator, id: ?std.json.Value, stdout: std.fs.File) !void {
    var buf: [64]u8 = undefined;
    const id_str = formatId(id, &buf);

    var response_buf: std.ArrayList(u8) = .empty;
    defer response_buf.deinit(alloc);

    try response_buf.appendSlice(alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
    try response_buf.appendSlice(alloc, id_str);
    try response_buf.appendSlice(alloc, ",\"result\":{\"tools\":[");

    for (tools, 0..) |tool, i| {
        if (i > 0) try response_buf.appendSlice(alloc, ",");
        const tool_json = try std.fmt.allocPrint(alloc, "{{\"name\":\"{s}\",\"description\":\"{s}\",\"inputSchema\":{s}}}", .{
            tool.name,
            tool.description,
            tool.schema,
        });
        defer alloc.free(tool_json);
        try response_buf.appendSlice(alloc, tool_json);
    }

    try response_buf.appendSlice(alloc, "]}}\n");
    _ = try stdout.write(response_buf.items);
}

fn handleToolsCall(alloc: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value, stdout: std.fs.File, socket_path: []const u8) !void {
    const p = params orelse {
        try sendError(alloc, id, -32602, "Missing params", stdout);
        return;
    };

    const name_val = p.object.get("name") orelse {
        try sendError(alloc, id, -32602, "Missing tool name", stdout);
        return;
    };
    const name = name_val.string;
    const arguments = p.object.get("arguments");

    std.debug.print("[mcp] tool call: {s}\n", .{name});

    const result = executeToolViaSocket(alloc, name, arguments, socket_path) catch {
        try sendToolResult(alloc, id, false, "Failed to connect to Zigram", stdout);
        return;
    };
    defer alloc.free(result);

    try sendToolResult(alloc, id, true, result, stdout);
}

fn executeToolViaSocket(alloc: std.mem.Allocator, tool_name: []const u8, arguments: ?std.json.Value, socket_path: []const u8) ![]const u8 {
    std.debug.print("[mcp] connecting to {s}\n", .{socket_path});

    const socket = std.net.connectUnixSocket(socket_path) catch {
        return error.ConnectionFailed;
    };
    defer socket.close();

    // Build request
    var request_buf: std.ArrayList(u8) = .empty;
    defer request_buf.deinit(alloc);

    try request_buf.appendSlice(alloc, "{\"tool\":\"");
    try request_buf.appendSlice(alloc, tool_name);
    try request_buf.appendSlice(alloc, "\"");

    if (arguments) |args| {
        try request_buf.appendSlice(alloc, ",\"arguments\":");
        // Serialize arguments using std.json.fmt
        const fmt = std.json.fmt(args, .{});
        var args_out: std.Io.Writer.Allocating = .init(alloc);
        defer args_out.deinit();
        try fmt.format(&args_out.writer);
        const args_json = try args_out.toOwnedSlice();
        defer alloc.free(args_json);
        try request_buf.appendSlice(alloc, args_json);
    }

    try request_buf.appendSlice(alloc, "}\n");

    _ = try socket.write(request_buf.items);

    // Read response
    var response_buf: [65536]u8 = undefined;
    var total: usize = 0;

    while (total < response_buf.len) {
        const n = socket.read(response_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, response_buf[0..total], '\n')) |_| break;
    }

    if (total == 0) return error.EmptyResponse;

    var end = total;
    while (end > 0 and (response_buf[end - 1] == '\n' or response_buf[end - 1] == '\r')) {
        end -= 1;
    }

    return try alloc.dupe(u8, response_buf[0..end]);
}

fn sendError(alloc: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8, stdout: std.fs.File) !void {
    var buf: [64]u8 = undefined;
    const id_str = formatId(id, &buf);

    const response = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}\n",
        .{ id_str, code, message },
    );
    defer alloc.free(response);

    _ = try stdout.write(response);
}

fn sendToolResult(alloc: std.mem.Allocator, id: ?std.json.Value, success: bool, text: []const u8, stdout: std.fs.File) !void {
    var buf: [64]u8 = undefined;
    const id_str = formatId(id, &buf);

    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(alloc);

    for (text) |c| {
        switch (c) {
            '"' => try escaped.appendSlice(alloc, "\\\""),
            '\\' => try escaped.appendSlice(alloc, "\\\\"),
            '\n' => try escaped.appendSlice(alloc, "\\n"),
            '\r' => try escaped.appendSlice(alloc, "\\r"),
            '\t' => try escaped.appendSlice(alloc, "\\t"),
            else => try escaped.append(alloc, c),
        }
    }

    const is_error = if (success) "false" else "true";

    const response = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}],\"isError\":{s}}}}}\n",
        .{ id_str, escaped.items, is_error },
    );
    defer alloc.free(response);

    _ = try stdout.write(response);
}

fn formatId(id: ?std.json.Value, buf: []u8) []const u8 {
    if (id) |i| {
        if (i == .integer) {
            return std.fmt.bufPrint(buf, "{d}", .{i.integer}) catch "null";
        } else if (i == .string) {
            return std.fmt.bufPrint(buf, "\"{s}\"", .{i.string}) catch "null";
        }
    }
    return "null";
}
