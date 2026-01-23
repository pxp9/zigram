const std = @import("std");
const tdlib = @import("tdlib.zig");
const vaxis = @import("vaxis");
const utils = @import("utils.zig");

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
    timestamp: i64,

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

pub fn getUserName(
    client: *tdlib.Client,
    allocator: std.mem.Allocator,
    user_id: i64,
) ![]const u8 {
    const request = try formatRequestZ(
        allocator,
        "{{\"@type\":\"getUser\",\"user_id\":{d}}}",
        .{user_id},
    );
    defer allocator.free(request);
    client.send(request);

    var attempts: u32 = 0;
    while (attempts < 20) : (attempts += 1) {
        const response_opt = client.receive(0.05);
        if (response_opt) |response| {
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            ) catch continue;
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse continue;

            if (std.mem.eql(u8, update_type.string, "user")) {
                const first_name = value.object.get("first_name") orelse continue;
                const last_name_opt = value.object.get("last_name");

                if (last_name_opt) |last_name| {
                    if (last_name.string.len > 0) {
                        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ first_name.string, last_name.string });
                    }
                }
                return try allocator.dupe(u8, first_name.string);
            }
        }
    }

    return try allocator.dupe(u8, "Unknown");
}

pub fn getChats(client: *tdlib.Client, allocator: std.mem.Allocator, limit: i32) !std.ArrayList(Chat) {
    var chats: std.ArrayList(Chat) = .empty;
    errdefer {
        for (chats.items) |*chat| {
            chat.deinit(allocator);
        }
        chats.deinit(allocator);
    }

    const load_request = try formatRequestZ(
        allocator,
        "{{\"@type\":\"loadChats\",\"chat_list\":{{\"@type\":\"chatListMain\"}},\"limit\":{d}}}",
        .{limit},
    );
    defer allocator.free(load_request);
    std.log.info("Sending loadChats request: {s}", .{load_request});
    client.send(load_request);

    var load_attempts: u32 = 0;
    while (load_attempts < 30) : (load_attempts += 1) {
        const load_response_opt = client.receive(0.1);
        if (load_response_opt) |load_response| {
            std.log.info("loadChats response: {s}", .{load_response[0..@min(load_response.len, 300)]});
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                load_response,
                .{},
            ) catch continue;
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse continue;

            if (std.mem.eql(u8, update_type.string, "ok")) {
                std.log.info("loadChats succeeded", .{});
                break;
            }
        }
    }

    const request = try formatRequestZ(
        allocator,
        "{{\"@type\":\"getChats\",\"chat_list\":{{\"@type\":\"chatListMain\"}},\"limit\":{d}}}",
        .{limit},
    );
    defer allocator.free(request);
    std.log.info("Sending getChats request: {s}", .{request});
    client.send(request);

    var attempts: u32 = 0;
    var got_chats = false;
    std.log.info("Waiting for getChats response...", .{});
    while (attempts < 100) : (attempts += 1) { // 10 seconds timeout
        const response_opt = client.receive(0.1);
        if (response_opt) |response| {
            if (attempts < 5 or attempts % 10 == 0) {
                std.log.info("Received response (attempt {d}): {s}", .{ attempts, response });
            }
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            ) catch |err| {
                std.log.info("JSON parse error: {any}", .{err});
                continue;
            };
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse {
                std.log.info("No @type field in response", .{});
                continue;
            };

            std.log.info("Update type: {s}", .{update_type.string});
            if (!std.mem.eql(u8, update_type.string, "chats") and
                !std.mem.eql(u8, update_type.string, "chat"))
            {
                std.log.info("Skipping update type: {s}", .{update_type.string});
                continue;
            }

            if (std.mem.eql(u8, update_type.string, "chats")) {
                got_chats = true;
                std.log.info("Got chats response!", .{});
                const chat_ids = value.object.get("chat_ids") orelse {
                    std.log.info("No chat_ids field in chats response", .{});
                    continue;
                };

                std.log.info("Found {d} chat IDs", .{chat_ids.array.items.len});
                for (chat_ids.array.items) |chat_id_value| {
                    const chat_id = chat_id_value.integer;
                    std.log.info("Requesting details for chat ID: {d}", .{chat_id});
                    const chat_request = try formatRequestZ(
                        allocator,
                        "{{\"@type\":\"getChat\",\"chat_id\":{d}}}",
                        .{chat_id},
                    );
                    defer allocator.free(chat_request);
                    client.send(chat_request);
                }

                var chat_attempts: u32 = 0;
                const expected_chats = chat_ids.array.items.len;
                std.log.info("Collecting details for {d} chats...", .{expected_chats});
                while (chat_attempts < 50 and chats.items.len < expected_chats) : (chat_attempts += 1) {
                    const chat_response_opt = client.receive(0.1);
                    if (chat_response_opt) |chat_response| {
                        std.log.info("Got chat detail response (attempt {d}/{d} collected): {s}", .{ chat_attempts, chats.items.len, chat_response });
                        const chat_parsed = std.json.parseFromSlice(
                            std.json.Value,
                            allocator,
                            chat_response,
                            .{},
                        ) catch continue;
                        defer chat_parsed.deinit();

                        const chat_value = chat_parsed.value;
                        const chat_type = chat_value.object.get("@type") orelse continue;

                        std.log.info("Chat detail update type: {s}", .{chat_type.string});
                        if (!std.mem.eql(u8, chat_type.string, "chat")) {
                            std.log.info("Skipping non-chat update: {s}", .{chat_type.string});
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

                            std.log.info("Adding chat: {s} (ID: {d})", .{ title, id });
                            try chats.append(allocator, Chat{
                                .id = id,
                                .title = try allocator.dupe(u8, title),
                                .last_message = last_message,
                            });
                        }
                    }
                }

                std.log.info("Collected {d} chats out of {d} expected", .{ chats.items.len, expected_chats });
                if (chats.items.len > 0 or got_chats) {
                    std.log.info("Returning {d} chats", .{chats.items.len});
                    return chats;
                }
            }
        }
    }

    std.log.info("Timeout reached after {d} attempts", .{attempts});
    if (chats.items.len > 0) {
        std.log.info("Returning {d} incomplete chats", .{chats.items.len});
        return chats;
    }

    std.log.info("No chats received, returning timeout error", .{});
    return error.Timeout;
}

pub fn getChatHistory(
    client: *tdlib.Client,
    allocator: std.mem.Allocator,
    chat_id: i64,
    limit: i32,
) !std.ArrayList(Message) {
    var messages: std.ArrayList(Message) = .empty;
    errdefer {
        for (messages.items) |*msg| {
            msg.deinit(allocator);
        }
        messages.deinit(allocator);
    }

    std.log.info("Draining pending updates before getChatHistory...", .{});
    var drain_count: u32 = 0;
    while (drain_count < 100) : (drain_count += 1) {
        const drain_response = client.receive(0.01); // Very short timeout
        if (drain_response == null) {
            break; // No more pending updates
        }
    }
    std.log.info("Drained {d} pending updates", .{drain_count});

    const request = try formatRequestZ(
        allocator,
        "{{\"@type\":\"getChatHistory\",\"chat_id\":{d},\"from_message_id\":0,\"offset\":0,\"limit\":{d}}}",
        .{ chat_id, limit },
    );
    defer allocator.free(request);
    std.log.info("Sending getChatHistory request for chat {d}: {s}", .{ chat_id, request });
    client.send(request);

    var attempts: u32 = 0;
    std.log.info("Waiting for getChatHistory response...", .{});
    while (attempts < 100) : (attempts += 1) { // 10 seconds timeout
        const response_opt = client.receive(0.1);
        if (response_opt) |response| {
            std.log.info("Received getChatHistory response (attempt {d}): {s}", .{ attempts, response });
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            ) catch |err| {
                std.log.info("getChatHistory JSON parse error: {any}", .{err});
                continue;
            };
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse {
                std.log.info("getChatHistory: No @type field", .{});
                continue;
            };

            std.log.info("getChatHistory update type: {s}", .{update_type.string});
            if (!std.mem.eql(u8, update_type.string, "messages")) {
                std.log.info("Skipping non-messages update: {s}", .{update_type.string});
                continue;
            }

            if (std.mem.eql(u8, update_type.string, "messages")) {
                std.log.info("Got messages response!", .{});
                const msgs = value.object.get("messages") orelse {
                    std.log.info("No messages field in messages response", .{});
                    continue;
                };

                std.log.info("Found {d} messages", .{msgs.array.items.len});

                if (msgs.array.items.len == 0) {
                    std.log.info("Got 0 messages, TDLib may be loading from server. Retrying once...", .{});

                    var retry_drain: u32 = 0;
                    while (retry_drain < 50) : (retry_drain += 1) {
                        const drain_resp = client.receive(0.05);
                        if (drain_resp == null) break;
                    }

                    client.send(request);

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
                                std.log.info("Retry found {d} messages", .{retry_msgs.array.items.len});

                                for (retry_msgs.array.items) |msg_value| {
                                    const msg_id = msg_value.object.get("id").?.integer;
                                    const is_outgoing = msg_value.object.get("is_outgoing").?.bool;
                                    const date = msg_value.object.get("date").?.integer;

                                    var sender_name: []const u8 = "Unknown";
                                    var sender_name_owned = false;
                                    if (is_outgoing) {
                                        sender_name = "You";
                                    } else if (msg_value.object.get("sender_id")) |sender| {
                                        if (sender.object.get("user_id")) |user_id_val| {
                                            const user_id = user_id_val.integer;
                                            sender_name = getUserName(client, allocator, user_id) catch "Unknown";
                                            sender_name_owned = true;
                                        }
                                    }
                                    defer if (sender_name_owned) allocator.free(sender_name);

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
                                        .timestamp = date,
                                    });
                                }

                                std.log.info("Returning {d} messages after retry", .{messages.items.len});
                                std.mem.reverse(Message, messages.items);
                                return messages;
                            }
                        }
                    }

                    std.log.info("Retry also returned 0 messages, chat may be empty", .{});
                    return messages;
                }

                for (msgs.array.items) |msg_value| {
                    const msg_id = msg_value.object.get("id").?.integer;
                    const is_outgoing = msg_value.object.get("is_outgoing").?.bool;
                    const date = msg_value.object.get("date").?.integer;
                    std.log.info("Processing message ID: {d}", .{msg_id});

                    var sender_name: []const u8 = "Unknown";
                    var sender_name_owned = false;
                    if (is_outgoing) {
                        sender_name = "You";
                    } else if (msg_value.object.get("sender_id")) |sender| {
                        if (sender.object.get("user_id")) |user_id_val| {
                            const user_id = user_id_val.integer;
                            sender_name = getUserName(client, allocator, user_id) catch "Unknown";
                            sender_name_owned = true;
                        }
                    }
                    defer if (sender_name_owned) allocator.free(sender_name);

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
                        .timestamp = date,
                    });
                }

                std.log.info("Returning {d} messages", .{messages.items.len});
                std.mem.reverse(Message, messages.items);
                return messages;
            }
        }
    }

    std.log.info("getChatHistory timeout after {d} attempts", .{attempts});
    return error.Timeout;
}

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

pub const TelegramUpdateKind = enum {
    new_message,
    message_edited,
    message_deleted,
    chat_updated,
    chats_loaded,
    chat_history_loaded,
    thread_shutdown,
    unknown,
};

pub const TelegramUpdate = struct {
    kind: TelegramUpdateKind,
    chat_id: i64,
    data: []const u8, // JSON string
};

pub const TelegramRequestKind = enum {
    load_chats,
    load_chat_history,
    send_message,
    shutdown,
};

pub const TelegramRequest = union(TelegramRequestKind) {
    load_chats: struct { count: usize },
    load_chat_history: struct { chat_id: i64, limit: usize },
    send_message: struct { chat_id: i64, text: []const u8 },
    shutdown: void,
};

pub const TelegramQueue = utils.TelegramQueue;

pub fn telegramUpdateLoop(ctx: utils.TelegramThreadContext) void {
    while (true) {
        while (ctx.request_queue.next()) |request| {
            switch (request) {
                .load_chats => |req| {
                    std.log.info("Processing load_chats request, count={d}", .{req.count});
                    var chats = getChats(ctx.client, ctx.alloc, @intCast(req.count)) catch |err| {
                        std.log.err("Failed to load chats: {any}", .{err});
                        continue;
                    };

                    const chats_json = std.fmt.allocPrint(ctx.alloc, "{f}", .{std.json.fmt(chats.items, .{})}) catch continue;
                    const data_copy = chats_json;

                    ctx.loop.postEvent(.{
                        .telegram_update = .{
                            .kind = .chats_loaded,
                            .chat_id = 0,
                            .data = data_copy,
                        },
                    });

                    for (chats.items) |*chat| {
                        chat.deinit(ctx.alloc);
                    }
                    chats.deinit(ctx.alloc);
                },
                .load_chat_history => |req| {
                    std.log.info("Processing load_chat_history request, chat_id={d}, limit={d}", .{ req.chat_id, req.limit });
                    var messages = getChatHistory(ctx.client, ctx.alloc, req.chat_id, @intCast(req.limit)) catch |err| {
                        std.log.err("Failed to load chat history: {any}", .{err});
                        continue;
                    };

                    const messages_json = std.fmt.allocPrint(ctx.alloc, "{f}", .{std.json.fmt(messages.items, .{})}) catch continue;
                    const data_copy = messages_json;

                    ctx.loop.postEvent(.{
                        .telegram_update = .{
                            .kind = .chat_history_loaded,
                            .chat_id = req.chat_id,
                            .data = data_copy,
                        },
                    });

                    for (messages.items) |*msg| {
                        msg.deinit(ctx.alloc);
                    }
                    messages.deinit(ctx.alloc);
                },
                .send_message => |req| {
                    std.log.info("Processing send_message request, chat_id={d}", .{req.chat_id});
                    sendMessage(ctx.client, ctx.alloc, req.chat_id, req.text) catch |err| {
                        std.log.err("Failed to send message: {any}", .{err});
                    };
                    ctx.alloc.free(req.text);
                },
                .shutdown => {
                    std.log.info("Telegram thread shutting down", .{});

                    const shutdown_msg = ctx.alloc.dupe(u8, "shutdown") catch return;
                    ctx.loop.postEvent(.{
                        .telegram_update = .{
                            .kind = .thread_shutdown,
                            .chat_id = 0,
                            .data = shutdown_msg,
                        },
                    });

                    return;
                },
            }
        }

        const response = ctx.client.receive(0.1) orelse continue;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            ctx.alloc,
            response,
            .{},
        ) catch continue;
        defer parsed.deinit();

        const value = parsed.value;
        const update_type = value.object.get("@type") orelse continue;

        var kind: TelegramUpdateKind = .unknown;
        var chat_id: i64 = 0;

        if (std.mem.eql(u8, update_type.string, "updateNewMessage")) {
            kind = .new_message;
            if (value.object.get("message")) |msg_obj| {
                if (msg_obj.object.get("chat_id")) |cid| {
                    chat_id = cid.integer;
                }
            }
        } else if (std.mem.eql(u8, update_type.string, "updateMessageEdited")) {
            kind = .message_edited;
            if (value.object.get("chat_id")) |cid| {
                chat_id = cid.integer;
            }
        } else if (std.mem.eql(u8, update_type.string, "updateDeleteMessages")) {
            kind = .message_deleted;
            if (value.object.get("chat_id")) |cid| {
                chat_id = cid.integer;
            }
        } else if (std.mem.eql(u8, update_type.string, "updateChatTitle") or
            std.mem.eql(u8, update_type.string, "updateChatPhoto"))
        {
            kind = .chat_updated;
            if (value.object.get("chat_id")) |cid| {
                chat_id = cid.integer;
            }
        }

        if (kind != .unknown) {
            const data_copy = ctx.alloc.dupe(u8, response) catch continue;

            ctx.loop.postEvent(.{
                .telegram_update = .{
                    .kind = kind,
                    .chat_id = chat_id,
                    .data = data_copy,
                },
            });
        }
    }
}
