const std = @import("std");
const vaxis = @import("vaxis");
const google = @import("ai/google.zig");
const acp = @import("ai/acp.zig");
const utils = @import("utils.zig");

pub const default_system_prompt = "You are a helpful assistant integrated into a Telegram client. " ++
    "Answer in the same language the user is using or in the language the user requests. " ++
    "Be concise and helpful.";

pub const GoogleAiConfig = struct {
    api_key: []const u8,
    model: []const u8,
    system_prompt: []const u8,
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

pub const ClaudeCodeConfig = acp.ClaudeCodeConfig;

pub const ProviderConfig = union(enum) {
    google_ai: GoogleAiConfig,
    claude_code: ClaudeCodeConfig,

    pub fn deinit(self: *ProviderConfig, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .google_ai => |*cfg| cfg.deinit(alloc),
            .claude_code => |*cfg| cfg.deinit(alloc),
        }
    }
};

pub fn loadConfig(alloc: std.mem.Allocator) !ProviderConfig {
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
            const provider_config_json = ai_obj.object.get("google_ai") orelse return error.NoGoogleAiConfig;
            return ProviderConfig{ .google_ai = try loadGoogleAiConfig(alloc, provider_config_json) };
        } else if (std.mem.eql(u8, provider_str.string, "claude_code")) {
            const provider_config_json = ai_obj.object.get("claude_code") orelse return error.NoClaudeCodeConfig;
            return ProviderConfig{ .claude_code = try loadClaudeCodeConfig(alloc, provider_config_json) };
        }
    }

    return error.NoAiConfig;
}

fn loadGoogleAiConfig(alloc: std.mem.Allocator, config_json: std.json.Value) !GoogleAiConfig {
    const api_key = config_json.object.get("api_key") orelse return error.NoApiKey;
    const model_name = if (config_json.object.get("model")) |m| m.string else google.default_model;
    const has_custom_prompt = config_json.object.get("system_prompt") != null;
    const system_prompt = if (config_json.object.get("system_prompt")) |sp| try alloc.dupe(u8, sp.string) else default_system_prompt;

    return GoogleAiConfig{
        .api_key = try alloc.dupe(u8, api_key.string),
        .model = try alloc.dupe(u8, model_name),
        .system_prompt = system_prompt,
        .allocated = true,
        .system_prompt_allocated = has_custom_prompt,
    };
}

fn loadClaudeCodeConfig(alloc: std.mem.Allocator, config_json: std.json.Value) !ClaudeCodeConfig {
    const command = config_json.object.get("command") orelse return error.NoCommand;
    const args_json = config_json.object.get("args");
    const cwd_json = config_json.object.get("cwd");

    var args: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| alloc.free(arg);
        args.deinit(alloc);
    }

    if (args_json) |arr| {
        for (arr.array.items) |item| {
            try args.append(alloc, try alloc.dupe(u8, item.string));
        }
    }

    const cwd: ?[]const u8 = if (cwd_json) |c| try alloc.dupe(u8, c.string) else null;

    return ClaudeCodeConfig{
        .command = try alloc.dupe(u8, command.string),
        .args = try args.toOwnedSlice(alloc),
        .cwd = cwd,
        .allocated = true,
    };
}

pub fn listModels(alloc: std.mem.Allocator, config: *const ProviderConfig) ![]const u8 {
    return switch (config.*) {
        .google_ai => |*cfg| try google.listModels(alloc, cfg),
        .claude_code => try alloc.dupe(u8, "Claude Code does not support model listing. Models are configured in Claude Code itself."),
    };
}

pub fn sendMessageStreaming(alloc: std.mem.Allocator, config: *const ProviderConfig, history: []const ConversationMessage, loop: *vaxis.Loop(utils.Event)) ![]const u8 {
    return switch (config.*) {
        .google_ai => |*cfg| try google.sendMessageStreaming(alloc, cfg, history, loop),
        .claude_code => error.UseAcpAgentLoop,
    };
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

pub const AiQueue = utils.AiQueue;

pub const MessageRole = enum {
    user,
    model,
    tool,
};

pub const ConversationMessage = struct {
    role: MessageRole,
    content: []const u8,
};

pub fn aiAgentLoop(ctx: utils.AiThreadContext) void {
    std.log.info("AI agent thread started", .{});

    var conversation_history: std.ArrayList(ConversationMessage) = .empty;
    defer {
        for (conversation_history.items) |item| {
            ctx.alloc.free(item.content);
        }
        conversation_history.deinit(ctx.alloc);
    }

    while (true) {
        const req = ctx.request_queue.next() orelse {
            std.Thread.yield() catch {};
            continue;
        };

        switch (req) {
            .shutdown => {
                std.log.info("AI agent thread shutting down", .{});
                break;
            },
            .tool_result => |result| handleToolResult(ctx, &conversation_history, result),
            .send_message => |msg| handleSendMessage(ctx, &conversation_history, msg),
        }
    }
}

pub const acpAgentLoop = acp.acpAgentLoop;
pub const AcpThreadContext = acp.AcpThreadContext;

fn handleToolResult(ctx: utils.AiThreadContext, conversation_history: *std.ArrayList(ConversationMessage), result: @FieldType(AiRequest, "tool_result")) void {
    const result_text = if (result.success)
        std.fmt.allocPrint(ctx.alloc, "Tool execution successful: {s}", .{result.message}) catch {
            std.log.err("Failed to format tool result", .{});
            ctx.alloc.free(result.message);
            return;
        }
    else
        std.fmt.allocPrint(ctx.alloc, "Tool execution failed: {s}", .{result.message}) catch {
            std.log.err("Failed to format tool result", .{});
            ctx.alloc.free(result.message);
            return;
        };
    ctx.alloc.free(result.message);

    conversation_history.append(ctx.alloc, .{ .role = .tool, .content = result_text }) catch {
        ctx.alloc.free(result_text);
        return;
    };

    const result_display = ctx.alloc.dupe(u8, result_text) catch return;
    ctx.loop.postEvent(.{
        .ai_update = .{
            .kind = .message_chunk,
            .data = result_display,
        },
    });

    const completed_msg = ctx.alloc.dupe(u8, "") catch return;
    ctx.loop.postEvent(.{
        .ai_update = .{
            .kind = .message_completed,
            .data = completed_msg,
        },
    });

    std.log.info("Tool result added to conversation history", .{});
}

fn handleSendMessage(ctx: utils.AiThreadContext, conversation_history: *std.ArrayList(ConversationMessage), msg: @FieldType(AiRequest, "send_message")) void {
    const prompt_copy = ctx.alloc.dupe(u8, msg.prompt) catch {
        ctx.alloc.free(msg.prompt);
        return;
    };
    conversation_history.append(ctx.alloc, .{ .role = .user, .content = prompt_copy }) catch {
        ctx.alloc.free(prompt_copy);
        ctx.alloc.free(msg.prompt);
        return;
    };

    const ai_response = sendMessageStreaming(ctx.alloc, ctx.config, conversation_history.items, ctx.loop) catch |err| {
        const error_msg = std.fmt.allocPrint(ctx.alloc, "Error - {any}", .{err}) catch {
            std.log.err("Failed to allocate error message", .{});
            ctx.alloc.free(msg.prompt);
            return;
        };
        ctx.loop.postEvent(.{
            .ai_update = .{
                .kind = .error_occurred,
                .data = error_msg,
            },
        });
        ctx.alloc.free(msg.prompt);
        return;
    };

    conversation_history.append(ctx.alloc, .{ .role = .model, .content = ai_response }) catch {
        ctx.alloc.free(ai_response);
    };

    const completed_msg = ctx.alloc.dupe(u8, "") catch {
        ctx.alloc.free(msg.prompt);
        return;
    };
    ctx.loop.postEvent(.{
        .ai_update = .{
            .kind = .message_completed,
            .data = completed_msg,
        },
    });
    ctx.alloc.free(msg.prompt);
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
