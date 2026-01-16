const std = @import("std");
const tdlib = @import("tdlib.zig");
const log = @import("log.zig");
const addLog = log.addLog;

pub const Chat = struct {
    id: i64,
    title: []const u8,
    last_message: ?[]const u8,

    pub fn deinit(self: *Chat, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.last_message) |msg| {
            allocator.free(msg);
        }
    }
};

pub const Message = struct {
    id: i64,
    sender_name: []const u8,
    content: []const u8,
    is_outgoing: bool,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.sender_name);
        allocator.free(self.content);
    }
};

fn formatRequestZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const str = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(str);
    return try allocator.dupeZ(u8, str);
}

/// Fetch the list of chats from Telegram
pub fn getChats(client: *tdlib.Client, allocator: std.mem.Allocator, limit: i32, log_messages: *std.ArrayList([]const u8), log_file: std.fs.File) !std.ArrayList(Chat) {
    var chats: std.ArrayList(Chat) = .empty;
    errdefer {
        for (chats.items) |*chat| {
            chat.deinit(allocator);
        }
        chats.deinit(allocator);
    }

    // First, load chats into TDLib's cache
    const load_request = try formatRequestZ(
        allocator,
        "{{\"@type\":\"loadChats\",\"chat_list\":{{\"@type\":\"chatListMain\"}},\"limit\":{d}}}",
        .{limit},
    );
    defer allocator.free(load_request);
    try addLog(log_messages, allocator, log_file, "Sending loadChats request: {s}", .{load_request});
    client.send(load_request);

    // Wait a bit for loadChats to process
    var load_attempts: u32 = 0;
    while (load_attempts < 30) : (load_attempts += 1) {
        const load_response_opt = client.receive(0.1);
        if (load_response_opt) |load_response| {
            try addLog(log_messages, allocator, log_file, "loadChats response: {s}", .{load_response[0..@min(load_response.len, 300)]});
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                load_response,
                .{},
            ) catch continue;
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse continue;

            // Look for ok response or updateChatLastMessage
            if (std.mem.eql(u8, update_type.string, "ok")) {
                try addLog(log_messages, allocator, log_file, "loadChats succeeded", .{});
                break;
            }
        }
    }

    // Now request chat list
    const request = try formatRequestZ(
        allocator,
        "{{\"@type\":\"getChats\",\"chat_list\":{{\"@type\":\"chatListMain\"}},\"limit\":{d}}}",
        .{limit},
    );
    defer allocator.free(request);
    try addLog(log_messages, allocator, log_file, "Sending getChats request: {s}", .{request});
    client.send(request);

    // Wait for response with longer timeout
    var attempts: u32 = 0;
    var got_chats = false;
    try addLog(log_messages, allocator, log_file, "Waiting for getChats response...", .{});
    while (attempts < 100) : (attempts += 1) { // 10 seconds timeout
        const response_opt = client.receive(0.1);
        if (response_opt) |response| {
            // Log to stderr for debugging
            if (attempts < 5 or attempts % 10 == 0) {
                try addLog(log_messages, allocator, log_file, "Received response (attempt {d}): {s}", .{ attempts, response });
            }
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            ) catch |err| {
                try addLog(log_messages, allocator, log_file, "JSON parse error: {any}", .{err});
                continue;
            };
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse {
                try addLog(log_messages, allocator, log_file, "No @type field in response", .{});
                continue;
            };

            // Skip other updates
            try addLog(log_messages, allocator, log_file, "Update type: {s}", .{update_type.string});
            if (!std.mem.eql(u8, update_type.string, "chats") and
                !std.mem.eql(u8, update_type.string, "chat")) {
                try addLog(log_messages, allocator, log_file, "Skipping update type: {s}", .{update_type.string});
                continue;
            }

            if (std.mem.eql(u8, update_type.string, "chats")) {
                got_chats = true;
                try addLog(log_messages, allocator, log_file, "Got chats response!", .{});
                const chat_ids = value.object.get("chat_ids") orelse {
                    try addLog(log_messages, allocator, log_file, "No chat_ids field in chats response", .{});
                    continue;
                };

                // Now get details for each chat
                try addLog(log_messages, allocator, log_file, "Found {d} chat IDs", .{chat_ids.array.items.len});
                for (chat_ids.array.items) |chat_id_value| {
                    const chat_id = chat_id_value.integer;
                    try addLog(log_messages, allocator, log_file, "Requesting details for chat ID: {d}", .{chat_id});
                    const chat_request = try formatRequestZ(
                        allocator,
                        "{{\"@type\":\"getChat\",\"chat_id\":{d}}}",
                        .{chat_id},
                    );
                    defer allocator.free(chat_request);
                    client.send(chat_request);
                }

                // Collect chat details
                var chat_attempts: u32 = 0;
                const expected_chats = chat_ids.array.items.len;
                try addLog(log_messages, allocator, log_file, "Collecting details for {d} chats...", .{expected_chats});
                while (chat_attempts < 50 and chats.items.len < expected_chats) : (chat_attempts += 1) {
                    const chat_response_opt = client.receive(0.1);
                    if (chat_response_opt) |chat_response| {
                        try addLog(log_messages, allocator, log_file, "Got chat detail response (attempt {d}/{d} collected): {s}", .{ chat_attempts, chats.items.len, chat_response });
                        const chat_parsed = std.json.parseFromSlice(
                            std.json.Value,
                            allocator,
                            chat_response,
                            .{},
                        ) catch continue;
                        defer chat_parsed.deinit();

                        const chat_value = chat_parsed.value;
                        const chat_type = chat_value.object.get("@type") orelse continue;

                        // Skip non-chat updates
                        try addLog(log_messages, allocator, log_file, "Chat detail update type: {s}", .{chat_type.string});
                        if (!std.mem.eql(u8, chat_type.string, "chat")) {
                            try addLog(log_messages, allocator, log_file, "Skipping non-chat update: {s}", .{chat_type.string});
                            continue;
                        }

                        if (std.mem.eql(u8, chat_type.string, "chat")) {
                            const id = chat_value.object.get("id").?.integer;
                            const title = chat_value.object.get("title").?.string;

                            var last_message: ?[]const u8 = null;
                            if (chat_value.object.get("last_message")) |lm| {
                                if (lm.object.get("content")) |content| {
                                    if (content.object.get("text")) |text_obj| {
                                        if (text_obj.object.get("text")) |text| {
                                            last_message = try allocator.dupe(u8, text.string);
                                        }
                                    }
                                }
                            }

                            try addLog(log_messages, allocator, log_file, "Adding chat: {s} (ID: {d})", .{ title, id });
                            try chats.append(allocator, Chat{
                                .id = id,
                                .title = try allocator.dupe(u8, title),
                                .last_message = last_message,
                            });
                        }
                    }
                }

                // Return whatever chats we got, even if not all
                try addLog(log_messages, allocator, log_file, "Collected {d} chats out of {d} expected", .{ chats.items.len, expected_chats });
                if (chats.items.len > 0 or got_chats) {
                    try addLog(log_messages, allocator, log_file, "Returning {d} chats", .{chats.items.len});
                    return chats;
                }
            }
        }
    }

    // If we got chats but they're incomplete, return what we have
    try addLog(log_messages, allocator, log_file, "Timeout reached after {d} attempts", .{attempts});
    if (chats.items.len > 0) {
        try addLog(log_messages, allocator, log_file, "Returning {d} incomplete chats", .{chats.items.len});
        return chats;
    }

    try addLog(log_messages, allocator, log_file, "No chats received, returning timeout error", .{});
    return error.Timeout;
}

/// Fetch messages from a specific chat
pub fn getChatHistory(
    client: *tdlib.Client,
    allocator: std.mem.Allocator,
    chat_id: i64,
    limit: i32,
    log_messages: *std.ArrayList([]const u8),
    log_file: std.fs.File,
) !std.ArrayList(Message) {
    var messages: std.ArrayList(Message) = .empty;
    errdefer {
        for (messages.items) |*msg| {
            msg.deinit(allocator);
        }
        messages.deinit(allocator);
    }

    // First, drain pending updates from TDLib's queue
    // This ensures our getChatHistory request gets processed quickly
    try addLog(log_messages, allocator, log_file, "Draining pending updates before getChatHistory...", .{});
    var drain_count: u32 = 0;
    while (drain_count < 100) : (drain_count += 1) {
        const drain_response = client.receive(0.01); // Very short timeout
        if (drain_response == null) {
            break; // No more pending updates
        }
    }
    try addLog(log_messages, allocator, log_file, "Drained {d} pending updates", .{drain_count});

    // Request chat history
    const request = try formatRequestZ(
        allocator,
        "{{\"@type\":\"getChatHistory\",\"chat_id\":{d},\"from_message_id\":0,\"offset\":0,\"limit\":{d}}}",
        .{ chat_id, limit },
    );
    defer allocator.free(request);
    try addLog(log_messages, allocator, log_file, "Sending getChatHistory request for chat {d}: {s}", .{ chat_id, request });
    client.send(request);

    // Wait for response with reasonable timeout (should be quick after draining updates)
    var attempts: u32 = 0;
    try addLog(log_messages, allocator, log_file, "Waiting for getChatHistory response...", .{});
    while (attempts < 100) : (attempts += 1) { // 10 seconds timeout
        const response_opt = client.receive(0.1);
        if (response_opt) |response| {
            try addLog(log_messages, allocator, log_file, "Received getChatHistory response (attempt {d}): {s}", .{ attempts, response });
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            ) catch |err| {
                try addLog(log_messages, allocator, log_file, "getChatHistory JSON parse error: {any}", .{err});
                continue;
            };
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse {
                try addLog(log_messages, allocator, log_file, "getChatHistory: No @type field", .{});
                continue;
            };

            // Skip non-message updates
            try addLog(log_messages, allocator, log_file, "getChatHistory update type: {s}", .{update_type.string});
            if (!std.mem.eql(u8, update_type.string, "messages")) {
                try addLog(log_messages, allocator, log_file, "Skipping non-messages update: {s}", .{update_type.string});
                continue;
            }

            if (std.mem.eql(u8, update_type.string, "messages")) {
                try addLog(log_messages, allocator, log_file, "Got messages response!", .{});
                const msgs = value.object.get("messages") orelse {
                    try addLog(log_messages, allocator, log_file, "No messages field in messages response", .{});
                    continue;
                };

                try addLog(log_messages, allocator, log_file, "Found {d} messages", .{msgs.array.items.len});

                // If we got 0 messages, TDLib might still be loading from server
                // Try one more time after a short delay
                if (msgs.array.items.len == 0) {
                    try addLog(log_messages, allocator, log_file, "Got 0 messages, TDLib may be loading from server. Retrying once...", .{});

                    // Drain any pending updates
                    var retry_drain: u32 = 0;
                    while (retry_drain < 50) : (retry_drain += 1) {
                        const drain_resp = client.receive(0.05);
                        if (drain_resp == null) break;
                    }

                    // Send request again
                    client.send(request);

                    // Wait for retry response
                    var retry_attempts: u32 = 0;
                    while (retry_attempts < 50) : (retry_attempts += 1) {
                        const retry_response = client.receive(0.1);
                        if (retry_response) |retry_resp| {
                            const retry_parsed = std.json.parseFromSlice(
                                std.json.Value,
                                allocator,
                                retry_resp,
                                .{},
                            ) catch continue;
                            defer retry_parsed.deinit();

                            const retry_value = retry_parsed.value;
                            const retry_type = retry_value.object.get("@type") orelse continue;

                            if (std.mem.eql(u8, retry_type.string, "messages")) {
                                const retry_msgs = retry_value.object.get("messages") orelse continue;
                                try addLog(log_messages, allocator, log_file, "Retry found {d} messages", .{retry_msgs.array.items.len});

                                for (retry_msgs.array.items) |msg_value| {
                                    const msg_id = msg_value.object.get("id").?.integer;
                                    const is_outgoing = msg_value.object.get("is_outgoing").?.bool;

                                    var sender_name: []const u8 = "Unknown";
                                    if (msg_value.object.get("sender_id")) |sender| {
                                        if (sender.object.get("user_id")) |_| {
                                            sender_name = if (is_outgoing) "You" else "Contact";
                                        }
                                    }

                                    var content: []const u8 = "";
                                    if (msg_value.object.get("content")) |msg_content| {
                                        if (msg_content.object.get("text")) |text_obj| {
                                            if (text_obj.object.get("text")) |text| {
                                                content = text.string;
                                            }
                                        } else if (msg_content.object.get("@type")) |_| {
                                            content = "[Media]";
                                        }
                                    }

                                    try messages.append(allocator, Message{
                                        .id = msg_id,
                                        .sender_name = try allocator.dupe(u8, sender_name),
                                        .content = try allocator.dupe(u8, content),
                                        .is_outgoing = is_outgoing,
                                    });
                                }

                                try addLog(log_messages, allocator, log_file, "Returning {d} messages after retry", .{messages.items.len});
                                return messages;
                            }
                        }
                    }

                    // If retry also failed, return empty
                    try addLog(log_messages, allocator, log_file, "Retry also returned 0 messages, chat may be empty", .{});
                    return messages;
                }

                // Process messages from first successful response
                for (msgs.array.items) |msg_value| {
                    const msg_id = msg_value.object.get("id").?.integer;
                    const is_outgoing = msg_value.object.get("is_outgoing").?.bool;
                    try addLog(log_messages, allocator, log_file, "Processing message ID: {d}", .{msg_id});

                    // Get sender name
                    var sender_name: []const u8 = "Unknown";
                    if (msg_value.object.get("sender_id")) |sender| {
                        if (sender.object.get("user_id")) |_| {
                            // For now, just show "You" for outgoing messages
                            sender_name = if (is_outgoing) "You" else "Contact";
                        }
                    }

                    // Get message content
                    var content: []const u8 = "";
                    if (msg_value.object.get("content")) |msg_content| {
                        if (msg_content.object.get("text")) |text_obj| {
                            if (text_obj.object.get("text")) |text| {
                                content = text.string;
                            }
                        } else if (msg_content.object.get("@type")) |_| {
                            // Handle other message types
                            content = "[Media]";
                        }
                    }

                    try messages.append(allocator, Message{
                        .id = msg_id,
                        .sender_name = try allocator.dupe(u8, sender_name),
                        .content = try allocator.dupe(u8, content),
                        .is_outgoing = is_outgoing,
                    });
                }

                try addLog(log_messages, allocator, log_file, "Returning {d} messages", .{messages.items.len});
                return messages;
            }
        }
    }

    try addLog(log_messages, allocator, log_file, "getChatHistory timeout after {d} attempts", .{attempts});
    return error.Timeout;
}

/// Send a message to a chat
pub fn sendMessage(
    client: *tdlib.Client,
    allocator: std.mem.Allocator,
    chat_id: i64,
    text: []const u8,
) !void {
    const request = try formatRequestZ(
        allocator,
        \\{{"@type":"sendMessage","chat_id":{d},"input_message_content":{{"@type":"inputMessageText","text":{{"@type":"formattedText","text":"{s}"}}}}}}
        ,
        .{ chat_id, text },
    );
    defer allocator.free(request);
    client.send(request);
}
