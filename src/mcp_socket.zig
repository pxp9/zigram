const std = @import("std");
const telegram = @import("telegram.zig");
const utils = @import("utils.zig");

const log = std.log.scoped(.mcp_socket);

pub const McpSocketServer = struct {
    socket: std.posix.socket_t,
    path: []const u8,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !McpSocketServer {
        // Remove existing socket file
        std.fs.deleteFileAbsolute(path) catch {};

        // Create Unix socket
        const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(socket);

        // Bind to path
        var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
        const path_len = @min(path.len, addr.path.len - 1);
        @memcpy(addr.path[0..path_len], path[0..path_len]);
        addr.path[path_len] = 0;

        try std.posix.bind(socket, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(socket, 5);

        log.info("MCP socket listening on {s}", .{path});

        return .{
            .socket = socket,
            .path = path,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *McpSocketServer) void {
        std.posix.close(self.socket);
        std.fs.deleteFileAbsolute(self.path) catch {};
    }

    pub fn accept(self: *McpSocketServer) !std.posix.socket_t {
        return try std.posix.accept(self.socket, null, null, 0);
    }
};

pub const McpSocketContext = struct {
    server: *McpSocketServer,
    telegram_queue: *utils.TelegramQueue,
    chats: *std.ArrayList(telegram.Chat),
    alloc: std.mem.Allocator,
    running: *bool,
};

pub fn mcpSocketThread(ctx: McpSocketContext) void {
    log.info("MCP socket thread started", .{});

    while (ctx.running.*) {
        // Accept connection with timeout check
        const client = ctx.server.accept() catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.yield() catch {};
                continue;
            }
            log.err("Accept failed: {any}", .{err});
            continue;
        };
        defer std.posix.close(client);

        handleClient(ctx, client) catch |err| {
            log.err("Client handling failed: {any}", .{err});
        };
    }

    log.info("MCP socket thread shutting down", .{});
}

fn handleClient(ctx: McpSocketContext, client: std.posix.socket_t) !void {
    log.info("MCP socket: client connected", .{});
    var buf: [65536]u8 = undefined;
    var total: usize = 0;

    // Read request
    while (total < buf.len) {
        const n = std.posix.read(client, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, buf[0..total], '\n')) |_| break;
    }

    if (total == 0) {
        log.info("MCP socket: client disconnected without sending data", .{});
        return;
    }

    // Trim newline
    var end = total;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) {
        end -= 1;
    }

    const request = buf[0..end];
    log.info("MCP socket: received request: {s}", .{request});

    // Parse JSON request
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.alloc, request, .{}) catch |err| {
        log.err("JSON parse error: {any}", .{err});
        _ = std.posix.write(client, "Error: Invalid JSON\n") catch {};
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const tool_val = obj.get("tool") orelse {
        _ = std.posix.write(client, "Error: Missing tool\n") catch {};
        return;
    };
    const tool = tool_val.string;
    const arguments = obj.get("arguments");

    // Execute tool
    const result = executeTool(ctx, tool, arguments);

    // Send response
    _ = std.posix.write(client, result) catch {};
    _ = std.posix.write(client, "\n") catch {};
}

fn executeTool(ctx: McpSocketContext, tool: []const u8, arguments: ?std.json.Value) []const u8 {
    if (std.mem.eql(u8, tool, "send_telegram_message")) {
        return executeSendMessage(ctx, arguments);
    } else if (std.mem.eql(u8, tool, "list_telegram_chats")) {
        return executeListChats(ctx);
    } else {
        return "Error: Unknown tool";
    }
}

fn executeSendMessage(ctx: McpSocketContext, arguments: ?std.json.Value) []const u8 {
    const args = arguments orelse {
        return "Error: Missing arguments";
    };

    const chat_id_val = args.object.get("chat_id") orelse {
        return "Error: Missing chat_id";
    };
    const message_val = args.object.get("message") orelse {
        return "Error: Missing message";
    };

    const chat_id: i64 = @intCast(chat_id_val.integer);
    const message = message_val.string;

    const msg_copy = ctx.alloc.dupe(u8, message) catch {
        return "Error: Out of memory";
    };

    ctx.telegram_queue.post(.{
        .send_message = .{
            .chat_id = chat_id,
            .text = msg_copy,
        },
    }) catch {
        ctx.alloc.free(msg_copy);
        return "Error: Failed to queue message";
    };

    log.info("Queued message to chat {d}", .{chat_id});
    return "Message sent successfully";
}

fn executeListChats(ctx: McpSocketContext) []const u8 {
    if (ctx.chats.items.len == 0) {
        return "No chats loaded";
    }

    var result: std.ArrayList(u8) = .empty;
    const w = result.writer(ctx.alloc);

    w.writeAll("Chats:\n") catch return "Error: Out of memory";

    for (ctx.chats.items) |chat| {
        w.print("- {s} (ID: {d})\n", .{ chat.title, chat.id }) catch {
            result.deinit(ctx.alloc);
            return "Error: Out of memory";
        };
    }

    // Note: This leaks, but acceptable for short-lived responses
    return result.toOwnedSlice(ctx.alloc) catch "Error: Out of memory";
}

pub const default_socket_path = "/tmp/zigram-mcp.sock";
