const std = @import("std");
const vaxis = @import("vaxis");

const default_system_prompt = "You are a helpful assistant integrated into a Telegram client. " ++
    "Answer in the same language the user is using or in the language the user requests. " ++
    "Be concise and helpful.";

pub const GoogleAiConfig = struct {
    api_key: []const u8,
    model: []const u8 = "gemini-3-flash-preview",
    system_prompt: []const u8 = default_system_prompt,
    allocated: bool = false,
    system_prompt_allocated: bool = false,

    pub fn deinit(self: *GoogleAiConfig, alloc: std.mem.Allocator) void {
        if (self.allocated) {
            alloc.free(self.api_key);
            alloc.free(self.model);
        }
        if (self.system_prompt_allocated) alloc.free(self.system_prompt);
    }
};

pub const Provider = enum {
    google_ai,
};

pub const Config = struct {
    provider: Provider,
    google_ai: ?GoogleAiConfig = null,

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        if (self.google_ai) |*google| {
            google.deinit(alloc);
        }
    }
};

pub fn loadConfig(alloc: std.mem.Allocator) !Config {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const config_path = try std.fs.path.join(alloc, &[_][]const u8{ home, ".config", "zigram", "zigram.json" });
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        return error.NoConfig;
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch |err| {
        std.log.err("Failed to parse config file: {s}", .{@errorName(err)});
        std.log.err("Please check ~/.config/zigram/zigram.json for JSON syntax errors", .{});
        return err;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root.object.get("ai")) |ai_obj| {
        const provider_str = ai_obj.object.get("provider") orelse return error.NoProvider;

        if (std.mem.eql(u8, provider_str.string, "google_ai")) {
            const google_config = ai_obj.object.get("google_ai") orelse return error.NoGoogleAiConfig;
            const api_key = google_config.object.get("api_key") orelse return error.NoApiKey;
            const model_name = if (google_config.object.get("model")) |m| m.string else "gemini-3-flash-preview";
            const has_custom_prompt = google_config.object.get("system_prompt") != null;
            const system_prompt = if (google_config.object.get("system_prompt")) |sp| try alloc.dupe(u8, sp.string) else default_system_prompt;

            return Config{
                .provider = .google_ai,
                .google_ai = GoogleAiConfig{
                    .api_key = try alloc.dupe(u8, api_key.string),
                    .model = try alloc.dupe(u8, model_name),
                    .system_prompt = system_prompt,
                    .allocated = true,
                    .system_prompt_allocated = has_custom_prompt,
                },
            };
        }
    }

    return error.NoAiConfig;
}

pub fn listModels(alloc: std.mem.Allocator, config: *const Config) ![]const u8 {
    return switch (config.provider) {
        .google_ai => try listGoogleAiModels(alloc, &config.google_ai.?),
    };
}

fn listGoogleAiModels(alloc: std.mem.Allocator, config: *const GoogleAiConfig) ![]const u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const url = "https://generativelanguage.googleapis.com/v1beta/models";
    const uri = try std.Uri.parse(url);

    var allocating_writer = std.Io.Writer.Allocating.init(alloc);
    defer allocating_writer.deinit();

    const req = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &allocating_writer.writer,
        .extra_headers = &.{
            .{ .name = "x-goog-api-key", .value = config.api_key },
        },
    });

    const response_body = try allocating_writer.toOwnedSlice();

    if (req.status != .ok) {
        std.log.err("ListModels API request failed with status: {}", .{req.status});
        std.log.err("Response body: {s}", .{response_body});
        alloc.free(response_body);
        return error.ApiRequestFailed;
    }

    return response_body;
}

pub fn sendMessageStreaming(alloc: std.mem.Allocator, config: *const Config, history: []const ConversationMessage, loop: anytype) ![]const u8 {
    return switch (config.provider) {
        .google_ai => try sendGoogleAiMessageStreaming(alloc, &config.google_ai.?, history, loop),
    };
}

fn escapeJsonString(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(alloc, "\\\""),
            '\\' => try result.appendSlice(alloc, "\\\\"),
            '\n' => try result.appendSlice(alloc, "\\n"),
            '\r' => try result.appendSlice(alloc, "\\r"),
            '\t' => try result.appendSlice(alloc, "\\t"),
            '\x08' => try result.appendSlice(alloc, "\\b"),
            '\x0C' => try result.appendSlice(alloc, "\\f"),
            else => try result.append(alloc, c),
        }
    }

    return try result.toOwnedSlice(alloc);
}

fn buildContentsJson(alloc: std.mem.Allocator, history: []const ConversationMessage) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    for (history, 0..) |msg, i| {
        if (i > 0) try result.appendSlice(alloc, ",");

        const role = switch (msg.role) {
            .user, .tool => "user",
            .model => "model",
        };
        const escaped = try escapeJsonString(alloc, msg.content);
        defer alloc.free(escaped);

        const content = try std.fmt.allocPrint(alloc, "{{\"role\":\"{s}\",\"parts\":[{{\"text\":\"{s}\"}}]}}", .{ role, escaped });
        defer alloc.free(content);

        try result.appendSlice(alloc, content);
    }

    return try result.toOwnedSlice(alloc);
}

fn sendGoogleAiMessageStreaming(alloc: std.mem.Allocator, config: *const GoogleAiConfig, history: []const ConversationMessage, loop: anytype) ![]const u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const url = try std.fmt.allocPrint(alloc, "https://generativelanguage.googleapis.com/v1beta/models/{s}:streamGenerateContent?alt=sse", .{config.model});
    defer alloc.free(url);

    const contents_json = try buildContentsJson(alloc, history);
    defer alloc.free(contents_json);

    const escaped_system_prompt = try escapeJsonString(alloc, config.system_prompt);
    defer alloc.free(escaped_system_prompt);

    const request_body = try std.fmt.allocPrint(alloc,
        \\{{"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},"contents":[{s}],"tools":[{{"functionDeclarations":[{{"name":"send_telegram_message","description":"Send a message to a Telegram chat by chat name","parameters":{{"type":"object","properties":{{"chat_name":{{"type":"string","description":"The name/title of the chat to send the message to"}},"message_text":{{"type":"string","description":"The text content of the message to send"}}}},"required":["chat_name","message_text"]}}}}]}}]}}
    , .{ escaped_system_prompt, contents_json });
    defer alloc.free(request_body);

    const uri = try std.Uri.parse(url);

    var allocating_writer = std.Io.Writer.Allocating.init(alloc);
    defer allocating_writer.deinit();

    const req = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = request_body,
        .response_writer = &allocating_writer.writer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-goog-api-key", .value = config.api_key },
        },
    });

    const response_body = try allocating_writer.toOwnedSlice();
    defer alloc.free(response_body);

    if (req.status != .ok) {
        std.log.err("AI API request failed with status: {}", .{req.status});
        std.log.err("Response body: {s}", .{response_body});
        return error.ApiRequestFailed;
    }

    var full_response: std.ArrayList(u8) = .empty;
    errdefer full_response.deinit(alloc);

    var line_iter = std.mem.splitSequence(u8, response_body, "\n");
    while (line_iter.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const json_data = line[6..];

        if (std.mem.eql(u8, json_data, "[DONE]")) break;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_data, .{}) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        const candidates = root.object.get("candidates") orelse continue;
        if (candidates.array.items.len == 0) continue;

        const candidate = candidates.array.items[0];
        const content = candidate.object.get("content") orelse continue;
        const parts = content.object.get("parts") orelse continue;
        if (parts.array.items.len == 0) continue;

        const part = parts.array.items[0];

        if (part.object.get("functionCall")) |func_call| {
            const func_name = func_call.object.get("name") orelse continue;
            if (std.mem.eql(u8, func_name.string, "send_telegram_message")) {
                const args = func_call.object.get("args") orelse continue;
                const chat_name = args.object.get("chat_name") orelse continue;
                const message_text = args.object.get("message_text") orelse continue;

                const tool_call = ToolCall{
                    .tool_name = try alloc.dupe(u8, func_name.string),
                    .chat_name = try alloc.dupe(u8, chat_name.string),
                    .message_text = try alloc.dupe(u8, message_text.string),
                };

                const tool_response = try std.fmt.allocPrint(alloc, "[Tool call: {s}]", .{func_name.string});
                try full_response.appendSlice(alloc, tool_response);
                alloc.free(tool_response);

                loop.postEvent(.{
                    .ai_update = .{
                        .kind = .tool_call,
                        .data = try alloc.dupe(u8, ""),
                        .tool_call = tool_call,
                    },
                });
                break;
            }
            continue;
        }

        if (part.object.get("text")) |text| {
            try full_response.appendSlice(alloc, text.string);

            const chunk = try alloc.dupe(u8, text.string);
            loop.postEvent(.{
                .ai_update = .{
                    .kind = .message_chunk,
                    .data = chunk,
                },
            });
        }
    }

    return try full_response.toOwnedSlice(alloc);
}

pub const AiUpdateKind = enum {
    message_chunk,
    message_completed,
    error_occurred,
    tool_call,
};

pub const AiUpdateResult = union(enum) {
    none: void,
    append_chunk: struct { text: []const u8, is_first: bool },
    set_loading: bool,
    append_error: []const u8,
    append_tool_status: []const u8,
    send_telegram: struct { chat_id: i64, text: []const u8 },
    post_tool_result: struct { success: bool, message: []const u8 },
};

pub const ToolCall = struct {
    tool_name: []const u8,
    chat_name: []const u8,
    message_text: []const u8,
};

pub const AiUpdate = struct {
    kind: AiUpdateKind,
    data: []const u8,
    tool_call: ?ToolCall = null,
};

pub const AiRequestKind = enum {
    send_message,
    tool_result,
    shutdown,
};

pub const AiRequest = union(AiRequestKind) {
    send_message: struct { prompt: []const u8 },
    tool_result: struct { success: bool, message: []const u8 },
    shutdown: void,
};

pub const AiQueue = struct {
    mutex: std.Thread.Mutex = .{},
    requests: std.ArrayList(AiRequest),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) AiQueue {
        return .{
            .requests = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *AiQueue) void {
        self.requests.deinit(self.alloc);
    }

    pub fn postRequest(self: *AiQueue, request: AiRequest) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requests.append(self.alloc, request);
    }

    pub fn getRequest(self: *AiQueue) ?AiRequest {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.requests.items.len == 0) return null;
        const request = self.requests.items[0];
        _ = self.requests.orderedRemove(0);
        return request;
    }
};

pub const MessageRole = enum {
    user,
    model,
    tool,
};

pub const ConversationMessage = struct {
    role: MessageRole,
    content: []const u8,
};

pub fn AiThreadContext(comptime Event: type) type {
    return struct {
        config: *Config,
        loop: *vaxis.Loop(Event),
        request_queue: *AiQueue,
        alloc: std.mem.Allocator,
    };
}

pub fn aiAgentLoop(ctx: anytype) void {
    std.log.info("AI agent thread started", .{});

    var conversation_history: std.ArrayList(ConversationMessage) = .empty;
    defer {
        for (conversation_history.items) |item| {
            ctx.alloc.free(item.content);
        }
        conversation_history.deinit(ctx.alloc);
    }

    while (true) {
        const request = ctx.request_queue.getRequest();

        if (request) |req| {
            switch (req) {
                .shutdown => {
                    std.log.info("AI agent thread shutting down", .{});
                    break;
                },
                .tool_result => |result| {
                    const result_text = if (result.success)
                        std.fmt.allocPrint(ctx.alloc, "Tool execution successful: {s}", .{result.message}) catch {
                            std.log.err("Failed to format tool result", .{});
                            ctx.alloc.free(result.message);
                            continue;
                        }
                    else
                        std.fmt.allocPrint(ctx.alloc, "Tool execution failed: {s}", .{result.message}) catch {
                            std.log.err("Failed to format tool result", .{});
                            ctx.alloc.free(result.message);
                            continue;
                        };
                    ctx.alloc.free(result.message);

                    conversation_history.append(ctx.alloc, .{ .role = .tool, .content = result_text }) catch {
                        ctx.alloc.free(result_text);
                        continue;
                    };

                    const result_display = ctx.alloc.dupe(u8, result_text) catch continue;
                    ctx.loop.postEvent(.{
                        .ai_update = .{
                            .kind = .message_chunk,
                            .data = result_display,
                        },
                    });

                    const completed_msg = ctx.alloc.dupe(u8, "") catch continue;
                    ctx.loop.postEvent(.{
                        .ai_update = .{
                            .kind = .message_completed,
                            .data = completed_msg,
                        },
                    });

                    std.log.info("Tool result added to conversation history", .{});
                },
                .send_message => |msg| {
                    const prompt_copy = ctx.alloc.dupe(u8, msg.prompt) catch {
                        ctx.alloc.free(msg.prompt);
                        continue;
                    };
                    conversation_history.append(ctx.alloc, .{ .role = .user, .content = prompt_copy }) catch {
                        ctx.alloc.free(prompt_copy);
                        ctx.alloc.free(msg.prompt);
                        continue;
                    };

                    const ai_response = sendMessageStreaming(ctx.alloc, ctx.config, conversation_history.items, ctx.loop) catch |err| {
                        const error_msg = std.fmt.allocPrint(ctx.alloc, "Error - {any}", .{err}) catch {
                            std.log.err("Failed to allocate error message", .{});
                            ctx.alloc.free(msg.prompt);
                            continue;
                        };
                        ctx.loop.postEvent(.{
                            .ai_update = .{
                                .kind = .error_occurred,
                                .data = error_msg,
                            },
                        });
                        ctx.alloc.free(msg.prompt);
                        continue;
                    };

                    conversation_history.append(ctx.alloc, .{ .role = .model, .content = ai_response }) catch {
                        ctx.alloc.free(ai_response);
                    };

                    const completed_msg = ctx.alloc.dupe(u8, "") catch {
                        ctx.alloc.free(msg.prompt);
                        continue;
                    };
                    ctx.loop.postEvent(.{
                        .ai_update = .{
                            .kind = .message_completed,
                            .data = completed_msg,
                        },
                    });
                    ctx.alloc.free(msg.prompt);
                },
            }
        } else {
            std.Thread.yield() catch {};
        }
    }
}

pub const ChatInfo = struct {
    id: i64,
    title: []const u8,
};

pub fn handleAiUpdate(
    alloc: std.mem.Allocator,
    update: AiUpdate,
    llm_messages: []const []const u8,
    chats: []const ChatInfo,
) ![]AiUpdateResult {
    var results: std.ArrayList(AiUpdateResult) = .empty;
    errdefer results.deinit(alloc);

    switch (update.kind) {
        .message_chunk => {
            const is_first = llm_messages.len == 0 or
                (llm_messages.len > 0 and !std.mem.startsWith(u8, llm_messages[llm_messages.len - 1], "AI:"));
            try results.append(alloc, .{ .append_chunk = .{ .text = update.data, .is_first = is_first } });
        },
        .message_completed => {
            try results.append(alloc, .{ .set_loading = false });
        },
        .error_occurred => {
            try results.append(alloc, .{ .set_loading = false });
            try results.append(alloc, .{ .append_error = update.data });
        },
        .tool_call => {
            const tool = update.tool_call orelse return try results.toOwnedSlice(alloc);

            try results.append(alloc, .{ .append_tool_status = tool.chat_name });

            const found_chat_id = findChatByName(chats, tool.chat_name);

            if (found_chat_id) |chat_id| {
                try results.append(alloc, .{ .send_telegram = .{ .chat_id = chat_id, .text = tool.message_text } });
                try results.append(alloc, .{ .post_tool_result = .{ .success = true, .message = tool.chat_name } });
            } else {
                try results.append(alloc, .{ .post_tool_result = .{ .success = false, .message = tool.chat_name } });
            }
        },
    }

    return try results.toOwnedSlice(alloc);
}

fn findChatByName(chats: []const ChatInfo, name: []const u8) ?i64 {
    for (chats) |chat| {
        if (std.mem.eql(u8, chat.title, name)) return chat.id;
    }
    return null;
}
