const std = @import("std");
const zigram = @import("zigram");
const vaxis = @import("vaxis");
const auth = @import("auth.zig");
const tdlib = @import("tdlib.zig");
const telegram = @import("telegram.zig");
const keybindings = @import("keybindings.zig");
const render = @import("render.zig");
const ai = @import("ai.zig");

const KeyAction = keybindings.KeyAction;
const KeyBindings = keybindings.KeyBindings;

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

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    telegram_update: telegram.TelegramUpdate,
    ai_update: ai.AiUpdate,
};

const InputMode = render.InputMode;
const AppState = render.AppState;
const MAX_MESSAGE_LENGTH = render.MAX_MESSAGE_LENGTH;

const TelegramThreadContext = struct {
    client: *tdlib.Client,
    loop: *vaxis.Loop(Event),
    request_queue: *telegram.TelegramQueue,
    alloc: std.mem.Allocator,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try tdlib.setLogVerbosityLevel(0);

    const client = try tdlib.Client.create();
    defer client.destroy();

    var user = try auth.authenticate(client, alloc);
    defer user.deinit(alloc);

    std.Thread.sleep(1 * std.time.ns_per_s); // Give user time to see auth message

    var kb = try keybindings.loadKeybindings(alloc);
    defer kb.deinit(alloc);

    var keymap = try keybindings.buildModeKeymap(alloc, kb);
    defer keymap.deinit();

    var app_config = try keybindings.loadAppConfig(alloc);
    defer app_config.deinit(alloc);

    var ai_config = ai.loadConfig(alloc) catch |err| blk: {
        std.log.warn("Failed to load AI config: {any}. AI assistant will be disabled.", .{err});
        break :blk ai.Config{
            .provider = .google_ai,
            .provider_config = .{
                .api_key = "",
                .model = "",
                .system_prompt = ai.default_system_prompt,
            },
        };
    };
    defer ai_config.deinit(alloc);

    var tty_buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    var llm_messages: std.ArrayList([]const u8) = .empty;
    defer {
        for (llm_messages.items) |msg| {
            alloc.free(msg);
        }
        llm_messages.deinit(alloc);
    }

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const log_dir = try std.fs.path.join(alloc, &[_][]const u8{ home, ".local", "share", "zigram" });
    defer alloc.free(log_dir);
    std.fs.makeDirAbsolute(log_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const log_file_path = try std.fs.path.join(alloc, &[_][]const u8{ log_dir, "zigram.log" });
    defer alloc.free(log_file_path);

    global_log_file = try std.fs.createFileAbsolute(log_file_path, .{ .truncate = false });
    defer global_log_file.close();
    try global_log_file.seekFromEnd(0); // Append to end

    std.log.info("Zigram started", .{});
    std.log.info("Log file: {s}", .{log_file_path});

    var telegram_queue = telegram.TelegramQueue.init(alloc);
    defer telegram_queue.deinit();

    const tg_ctx = TelegramThreadContext{
        .client = client,
        .loop = &loop,
        .request_queue = &telegram_queue,
        .alloc = alloc,
    };
    const tg_thread = try std.Thread.spawn(.{}, telegram.telegramUpdateLoop, .{tg_ctx});
    defer tg_thread.join();

    var ai_queue = ai.AiQueue.init(alloc);
    defer ai_queue.deinit();

    var chats: std.ArrayList(telegram.Chat) = .empty;
    defer {
        for (chats.items) |*chat| {
            chat.deinit(alloc);
        }
        chats.deinit(alloc);
    }

    std.log.info("Requesting chats from Telegram...", .{});
    try telegram_queue.postRequest(.{ .load_chats = .{ .count = 20 } });

    var selected_chat_idx: usize = 0;

    var chat_messages_cache = std.AutoHashMap(i64, std.ArrayList(telegram.Message)).init(alloc);
    defer {
        var iter = chat_messages_cache.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |*msg| {
                msg.deinit(alloc);
            }
            entry.value_ptr.deinit(alloc);
        }
        chat_messages_cache.deinit();
    }
    var loading_messages: bool = false;
    var llm_loading: bool = false;

    var active_mode: InputMode = .chat;

    var chat_text_view: vaxis.widgets.TextView = .{};
    var chat_text_buffer: vaxis.widgets.TextView.Buffer = .{};
    defer chat_text_buffer.deinit(alloc);

    var llm_text_view: vaxis.widgets.TextView = .{};
    var llm_text_buffer: vaxis.widgets.TextView.Buffer = .{};
    defer llm_text_buffer.deinit(alloc);

    var chat_input = vaxis.widgets.TextInput.init(alloc);
    defer chat_input.deinit();

    var llm_input = vaxis.widgets.TextInput.init(alloc);
    defer llm_input.deinit();

    const ai_ctx = ai.AiThreadContext(Event){
        .config = &ai_config,
        .loop = &loop,
        .request_queue = &ai_queue,
        .alloc = alloc,
    };
    const ai_thread = try std.Thread.spawn(.{}, ai.aiAgentLoop, .{ai_ctx});
    defer ai_thread.join();

    while (true) {
        const event = loop.nextEvent();

        var state = AppState{
            .vx = &vx,
            .tty = &tty,
            .user = &user,
            .chats = &chats,
            .selected_chat_idx = &selected_chat_idx,
            .chat_messages_cache = &chat_messages_cache,
            .loading_messages = &loading_messages,
            .active_mode = &active_mode,
            .llm_messages = &llm_messages,
            .llm_loading = &llm_loading,
            .keybindings = &kb,
            .keymap = &keymap,
            .telegram_queue = &telegram_queue,
            .ai_queue = &ai_queue,
            .chat_text_view = &chat_text_view,
            .chat_text_buffer = &chat_text_buffer,
            .chat_input = &chat_input,
            .llm_text_view = &llm_text_view,
            .llm_text_buffer = &llm_text_buffer,
            .llm_input = &llm_input,
            .ai_config = &ai_config,
            .app_config = &app_config,
        };

        const status = try handle_event(alloc, event, &state);

        if (status == 0) break;

        try render.render(alloc, &state);
    }
}

fn handle_event(alloc: std.mem.Allocator, event: Event, state: *AppState) !i32 {
    switch (event) {
        .key_press => |key| return try handle_key_press(alloc, state, key),
        .winsize => |ws| {
            try state.vx.resize(alloc, state.tty.writer(), ws);
        },
        .telegram_update => |update| {
            defer alloc.free(update.data);

            switch (update.kind) {
                .chats_loaded => {
                    const parsed = std.json.parseFromSlice(
                        std.json.Value,
                        alloc,
                        update.data,
                        .{},
                    ) catch {
                        std.log.err("Failed to parse chats data", .{});
                        return 1;
                    };
                    defer parsed.deinit();

                    for (state.chats.items) |*chat| {
                        chat.deinit(alloc);
                    }
                    state.chats.clearRetainingCapacity();

                    if (parsed.value != .array) {
                        std.log.err("Expected chats JSON to be an array", .{});
                        return 1;
                    }

                    for (parsed.value.array.items) |chat_value| {
                        if (chat_value != .object) continue;

                        const id = chat_value.object.get("id") orelse continue;
                        const title = chat_value.object.get("title") orelse continue;
                        const last_message = chat_value.object.get("last_message");

                        const chat = telegram.Chat{
                            .id = id.integer,
                            .title = try alloc.dupe(u8, title.string),
                            .last_message = if (last_message) |lm|
                                if (lm == .string) try alloc.dupe(u8, lm.string) else null
                            else
                                null,
                        };

                        try state.chats.append(alloc, chat);
                    }

                    std.log.info("Loaded {d} chats into UI", .{state.chats.items.len});

                    if (state.chats.items.len > 0) {
                        const first_chat = state.chats.items[0];
                        try state.telegram_queue.postRequest(.{
                            .load_chat_history = .{
                                .chat_id = first_chat.id,
                                .limit = 10,
                            },
                        });
                    }
                },
                .chat_history_loaded => {
                    const parsed = std.json.parseFromSlice(
                        std.json.Value,
                        alloc,
                        update.data,
                        .{},
                    ) catch {
                        std.log.err("Failed to parse chat history data", .{});
                        return 1;
                    };
                    defer parsed.deinit();

                    state.loading_messages.* = false;

                    if (parsed.value != .array) {
                        std.log.err("Expected messages JSON to be an array", .{});
                        return 1;
                    }

                    var messages: std.ArrayList(telegram.Message) = .empty;
                    errdefer {
                        for (messages.items) |*msg| {
                            msg.deinit(alloc);
                        }
                        messages.deinit(alloc);
                    }

                    for (parsed.value.array.items) |msg_value| {
                        if (msg_value != .object) continue;

                        const id = msg_value.object.get("id") orelse continue;
                        const sender_name = msg_value.object.get("sender_name") orelse continue;
                        const content = msg_value.object.get("content") orelse continue;
                        const is_outgoing = msg_value.object.get("is_outgoing") orelse continue;
                        const timestamp = msg_value.object.get("timestamp") orelse continue;

                        const message = telegram.Message{
                            .id = id.integer,
                            .sender_name = try alloc.dupe(u8, sender_name.string),
                            .content = try alloc.dupe(u8, content.string),
                            .is_outgoing = is_outgoing.bool,
                            .timestamp = timestamp.integer,
                        };

                        try messages.append(alloc, message);
                    }

                    try state.chat_messages_cache.put(update.chat_id, messages);
                    std.log.info("Loaded {d} messages for chat {d}", .{ messages.items.len, update.chat_id });
                },
                .new_message => {
                    const parsed = std.json.parseFromSlice(
                        std.json.Value,
                        alloc,
                        update.data,
                        .{},
                    ) catch return 1;
                    defer parsed.deinit();

                    const msg_obj = parsed.value.object.get("message") orelse return 1;
                    const cached_messages = state.chat_messages_cache.getPtr(update.chat_id) orelse return 1;

                    const msg_id = msg_obj.object.get("id") orelse return 1;
                    const is_outgoing = msg_obj.object.get("is_outgoing") orelse return 1;
                    const date = msg_obj.object.get("date") orelse return 1;

                    const sender_name = extractSenderName(msg_obj, is_outgoing.bool, update.chat_id, state.chats.items);
                    const content = extractMessageContent(msg_obj);

                    const win_height = state.vx.window().height;
                    const panel_height = if (win_height > 4) win_height - 2 else 2;
                    const messages_height = if (panel_height > 6) panel_height - 8 else 1;
                    const buffer_rows = state.chat_text_buffer.rows;
                    const max_scroll = buffer_rows -| messages_height;
                    const current_scroll = state.chat_text_view.scroll_view.scroll.y;
                    const threshold: usize = 3;
                    const is_at_bottom = (current_scroll +| threshold >= max_scroll) or buffer_rows <= messages_height;

                    cached_messages.append(alloc, telegram.Message{
                        .id = msg_id.integer,
                        .sender_name = try alloc.dupe(u8, sender_name),
                        .content = try alloc.dupe(u8, content),
                        .is_outgoing = is_outgoing.bool,
                        .timestamp = date.integer,
                    }) catch return 1;

                    if (is_at_bottom) {
                        const message_lines = 1 + std.mem.count(u8, content, "\n");
                        state.chat_text_view.scroll_view.scroll.y +|= message_lines;
                    }

                    std.log.info("Added new message to chat {d}: {s}", .{ update.chat_id, content });
                },
                .message_edited, .message_deleted, .chat_updated => {
                    std.log.info("Received {s} update for chat {d}", .{ @tagName(update.kind), update.chat_id });
                },
                .thread_shutdown => {
                    std.log.info("Telegram thread has shut down", .{});
                },
                .unknown => {},
            }
        },
        .ai_update => |update| {
            defer alloc.free(update.data);
            defer if (update.tool_call) |tool| {
                alloc.free(tool.tool_name);
                alloc.free(tool.chat_name);
                alloc.free(tool.message_text);
            };

            const is_at_bottom = isLlmViewAtBottom(state);
            const chat_infos = buildChatInfoList(alloc, state.chats.items) catch return 1;
            defer alloc.free(chat_infos);

            const results = ai.handleAiUpdate(alloc, update, state.llm_messages.items, chat_infos) catch return 1;
            defer alloc.free(results);

            for (results) |result| {
                try applyAiUpdateResult(alloc, state, result, is_at_bottom);
            }
        },
    }

    return 1;
}

fn isLlmViewAtBottom(state: *AppState) bool {
    const win_height = state.vx.window().height;
    const panel_height = if (win_height > 4) win_height - 2 else 2;
    const messages_height = if (panel_height > 6) panel_height - 8 else 1;
    const buffer_rows = state.llm_text_buffer.rows;
    const max_scroll = buffer_rows -| messages_height;
    const current_scroll = state.llm_text_view.scroll_view.scroll.y;
    const threshold: usize = 3;
    return (current_scroll +| threshold >= max_scroll) or buffer_rows <= messages_height;
}

fn buildChatInfoList(alloc: std.mem.Allocator, chats: []telegram.Chat) ![]ai.ChatInfo {
    var infos: std.ArrayList(ai.ChatInfo) = .empty;
    errdefer infos.deinit(alloc);
    for (chats) |chat| {
        try infos.append(alloc, .{ .id = chat.id, .title = chat.title });
    }
    return try infos.toOwnedSlice(alloc);
}

fn applyAiUpdateResult(alloc: std.mem.Allocator, state: *AppState, result: ai.AiUpdateResult, is_at_bottom: bool) !void {
    switch (result) {
        .none => {},
        .append_chunk => |chunk| {
            if (chunk.is_first) {
                const msg = try std.fmt.allocPrint(alloc, "AI: {s}", .{chunk.text});
                try state.llm_messages.append(alloc, msg);
            } else {
                const last_idx = state.llm_messages.items.len - 1;
                const old_msg = state.llm_messages.items[last_idx];
                const new_msg = try std.fmt.allocPrint(alloc, "{s}{s}", .{ old_msg, chunk.text });
                alloc.free(old_msg);
                state.llm_messages.items[last_idx] = new_msg;
            }
            if (is_at_bottom) {
                const chunk_lines = 1 + std.mem.count(u8, chunk.text, "\n");
                state.llm_text_view.scroll_view.scroll.y +|= chunk_lines;
            }
            std.log.info("AI chunk received", .{});
        },
        .set_loading => |loading| {
            state.llm_loading.* = loading;
            std.log.info("AI message completed", .{});
        },
        .append_error => |err_text| {
            const error_msg = try std.fmt.allocPrint(alloc, "AI: {s}", .{err_text});
            try state.llm_messages.append(alloc, error_msg);
            std.log.err("AI error: {s}", .{err_text});
        },
        .append_tool_status => |chat_name| {
            const tool_msg = try std.fmt.allocPrint(alloc, "AI: [Sending message to '{s}'...]", .{chat_name});
            try state.llm_messages.append(alloc, tool_msg);
            std.log.info("AI requested tool call for chat '{s}'", .{chat_name});
        },
        .send_telegram => |msg| {
            const text_copy = try alloc.dupe(u8, msg.text);
            try state.telegram_queue.postRequest(.{
                .send_message = .{ .chat_id = msg.chat_id, .text = text_copy },
            });
        },
        .post_tool_result => |res| {
            const message = if (res.success)
                try std.fmt.allocPrint(alloc, "Message sent successfully to chat '{s}'", .{res.message})
            else
                try std.fmt.allocPrint(alloc, "Chat '{s}' not found in your conversations", .{res.message});
            try state.ai_queue.postRequest(.{ .tool_result = .{ .success = res.success, .message = message } });
        },
    }
}

fn handle_scroll_input(state: *AppState, action: keybindings.KeyAction) bool {
    const scroll_view = switch (state.active_mode.*) {
        .chat => &state.chat_text_view.scroll_view,
        .llm => &state.llm_text_view.scroll_view,
        .chat_list => return false,
    };

    switch (action) {
        .scroll_up => scroll_view.scroll.y -|= 1,
        .scroll_down => scroll_view.scroll.y +|= 1,
        else => return false,
    }

    return true;
}

fn handle_text_input(state: *AppState, key: vaxis.Key, action: keybindings.KeyAction) bool {
    const should_handle = switch (action) {
        .none => true,
        .delete_char => state.active_mode.* == .chat or state.active_mode.* == .llm,
        else => false,
    };

    if (should_handle) {
        switch (state.active_mode.*) {
            .chat => state.chat_input.update(.{ .key_press = key }) catch {},
            .llm => state.llm_input.update(.{ .key_press = key }) catch {},
            .chat_list => {},
        }
    }

    return should_handle;
}

fn handle_select_action(alloc: std.mem.Allocator, state: *AppState) !void {
    switch (state.active_mode.*) {
        .chat_list => {
            if (state.chats.items.len == 0) return;
            const selected_chat = state.chats.items[state.selected_chat_idx.*];
            if (!state.chat_messages_cache.contains(selected_chat.id)) {
                std.log.info("Requesting messages for chat: {s}", .{selected_chat.title});
                state.loading_messages.* = true;
                try state.telegram_queue.postRequest(.{
                    .load_chat_history = .{ .chat_id = selected_chat.id, .limit = 10 },
                });
            }
            state.chat_input.reset();
            state.active_mode.* = .chat;
        },
        .chat => {
            if (state.chat_input.buf.realLength() == 0) return;
            const selected_chat = state.chats.items[state.selected_chat_idx.*];
            const message_text = try state.chat_input.toOwnedSlice();
            std.log.info("Sending message to chat {d}", .{selected_chat.id});
            try state.telegram_queue.postRequest(.{
                .send_message = .{ .chat_id = selected_chat.id, .text = message_text },
            });
        },
        .llm => {
            if (state.llm_input.buf.realLength() == 0) return;
            const input_text = try state.llm_input.toOwnedSlice();
            const user_msg = try std.fmt.allocPrint(alloc, "You: {s}", .{input_text});
            try state.llm_messages.append(alloc, user_msg);

            if (state.ai_config.provider_config.api_key.len == 0) {
                const error_msg = try alloc.dupe(u8, "AI: Error - No API key configured");
                try state.llm_messages.append(alloc, error_msg);
                alloc.free(input_text);
                return;
            }

            // Handle /model command
            if (std.mem.eql(u8, input_text, "/model")) {
                alloc.free(input_text);
                const models_json = ai.listModels(alloc, state.ai_config) catch |err| {
                    const error_msg = try std.fmt.allocPrint(alloc, "AI: Error listing models - {any}", .{err});
                    try state.llm_messages.append(alloc, error_msg);
                    return;
                };
                defer alloc.free(models_json);

                const parsed = std.json.parseFromSlice(std.json.Value, alloc, models_json, .{}) catch {
                    const error_msg = try alloc.dupe(u8, "AI: Error parsing models response");
                    try state.llm_messages.append(alloc, error_msg);
                    return;
                };
                defer parsed.deinit();

                const models_array = parsed.value.object.get("models") orelse {
                    const error_msg = try alloc.dupe(u8, "AI: No models found in response");
                    try state.llm_messages.append(alloc, error_msg);
                    return;
                };

                var result: std.ArrayList(u8) = .empty;
                defer result.deinit(alloc);

                try result.appendSlice(alloc, "AI: Available models:\n");
                for (models_array.array.items) |model| {
                    if (model.object.get("name")) |name| {
                        const model_name = name.string;
                        // Extract just the model ID from "models/model-name"
                        var parts = std.mem.splitSequence(u8, model_name, "/");
                        _ = parts.next(); // Skip "models"
                        if (parts.next()) |model_id| {
                            try result.appendSlice(alloc, "  - ");
                            try result.appendSlice(alloc, model_id);
                            try result.appendSlice(alloc, "\n");
                        }
                    }
                }

                const models_msg = try result.toOwnedSlice(alloc);
                try state.llm_messages.append(alloc, models_msg);
                return;
            }

            // Build chat list context
            var chat_list: std.ArrayList(u8) = .empty;
            defer chat_list.deinit(alloc);

            try chat_list.appendSlice(alloc, "Available chats: ");
            for (state.chats.items, 0..) |chat, i| {
                if (i > 0) try chat_list.appendSlice(alloc, ", ");
                try chat_list.appendSlice(alloc, "\"");
                try chat_list.appendSlice(alloc, chat.title);
                try chat_list.appendSlice(alloc, "\"");
            }
            try chat_list.appendSlice(alloc, "\n\n");
            try chat_list.appendSlice(alloc, input_text);

            const enhanced_prompt = try chat_list.toOwnedSlice(alloc);

            state.llm_loading.* = true;
            try state.ai_queue.postRequest(.{ .send_message = .{ .prompt = enhanced_prompt } });
        },
    }
}

fn extractSenderName(msg_obj: std.json.Value, is_outgoing: bool, chat_id: i64, chats: []const telegram.Chat) []const u8 {
    if (is_outgoing) return "You";

    const sender_id_obj = msg_obj.object.get("sender_id") orelse return "Unknown";
    const type_val = sender_id_obj.object.get("@type") orelse return "Unknown";

    const is_valid_sender = std.mem.eql(u8, type_val.string, "messageSenderUser") or
        std.mem.eql(u8, type_val.string, "messageSenderChat");
    if (!is_valid_sender) return "Unknown";

    for (chats) |chat| {
        if (chat.id == chat_id) {
            return chat.title;
        }
    }

    return "Unknown";
}

fn extractMessageContent(msg_obj: std.json.Value) []const u8 {
    const msg_content = msg_obj.object.get("content") orelse return "";

    if (msg_content.object.get("text")) |text_obj| {
        if (text_obj.object.get("text")) |text| {
            return text.string;
        }
    }

    if (msg_content.object.get("@type")) |_| {
        return "[Media]";
    }

    return "";
}

fn handle_reload_config(alloc: std.mem.Allocator, state: *AppState) !void {
    var new_keybindings = keybindings.loadKeybindings(alloc) catch |err| {
        std.log.err("Failed to reload keybindings: {any}", .{err});
        return err;
    };

    var new_keymap = keybindings.buildModeKeymap(alloc, new_keybindings) catch |err| {
        std.log.err("Failed to build keymap: {any}", .{err});
        new_keybindings.deinit(alloc);
        return err;
    };

    var new_ai_config = ai.loadConfig(alloc) catch |err| {
        std.log.err("Failed to reload AI config: {any}", .{err});
        new_keybindings.deinit(alloc);
        new_keymap.deinit();
        return err;
    };

    const new_app_config = keybindings.loadAppConfig(alloc) catch |err| {
        std.log.err("Failed to reload app config: {any}", .{err});
        new_keybindings.deinit(alloc);
        new_keymap.deinit();
        new_ai_config.deinit(alloc);
        return err;
    };

    state.keybindings.*.deinit(alloc);
    state.keymap.*.deinit();
    state.ai_config.*.deinit(alloc);
    state.app_config.*.deinit(alloc);

    state.keybindings.* = new_keybindings;
    state.keymap.* = new_keymap;
    state.ai_config.* = new_ai_config;
    state.app_config.* = new_app_config;

    std.log.info("Config reloaded (keybindings, AI settings, and datetime format)", .{});
}

fn handle_key_action(alloc: std.mem.Allocator, state: *AppState, action: keybindings.KeyAction) !i32 {
    switch (action) {
        .quit => {
            std.log.info("Quit requested, shutting down threads", .{});
            state.telegram_queue.postRequest(.{ .shutdown = {} }) catch {};
            state.ai_queue.postRequest(.{ .shutdown = {} }) catch {};
            return 0;
        },
        .switch_mode => state.active_mode.* = switch (state.active_mode.*) {
            .chat => .llm,
            .llm => .chat_list,
            .chat_list => .chat,
        },
        .navigate_up => {
            if (state.active_mode.* == .chat_list) {
                state.selected_chat_idx.* = (state.selected_chat_idx.* + state.chats.items.len - 1) % state.chats.items.len;
            }
        },
        .navigate_down => {
            if (state.active_mode.* == .chat_list) {
                state.selected_chat_idx.* = (state.selected_chat_idx.* + 1) % state.chats.items.len;
            }
        },
        .select => try handle_select_action(alloc, state),
        .reload_config => try handle_reload_config(alloc, state),
        .scroll_up, .scroll_down, .delete_char, .send_message, .none => {},
    }
    return 1;
}

fn handle_key_press(alloc: std.mem.Allocator, state: *AppState, key: vaxis.Key) !i32 {
    const action = keybindings.getKeyAction(state.keymap, state.active_mode.*, key);

    if (handle_scroll_input(state, action)) return 1;

    if (handle_text_input(state, key, action)) return 1;

    return try handle_key_action(alloc, state, action);
}
