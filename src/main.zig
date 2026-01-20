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
var global_log_messages: ?*std.ArrayList([]const u8) = null;
var global_allocator: ?std.mem.Allocator = null;

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

    if (global_log_messages) |log_msgs| {
        if (global_allocator) |alloc| {
            const full_msg = std.fmt.allocPrint(alloc, "{s}{s}", .{ msg, formatted }) catch return;
            log_msgs.append(alloc, full_msg) catch {
                alloc.free(full_msg);
            };
        }
    }
}

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    telegram_update: telegram.TelegramUpdate,
    ai_update: ai.AiUpdate,
};

const InputMode = render.InputMode;
const RightPanelMode = render.RightPanelMode;
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

    var keymap = try keybindings.buildKeymap(alloc, kb);
    defer keymap.deinit();

    var ai_config = ai.loadConfig(alloc) catch |err| blk: {
        std.log.warn("Failed to load AI config: {any}. AI assistant will be disabled.", .{err});
        break :blk ai.Config{ .provider = .google_ai };
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

    var log_messages: std.ArrayList([]const u8) = .empty;
    defer {
        for (log_messages.items) |msg| {
            alloc.free(msg);
        }
        log_messages.deinit(alloc);
    }

    global_log_messages = &log_messages;
    global_allocator = alloc;

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
    var right_panel_mode: RightPanelMode = .llm;

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
            .right_panel_mode = &right_panel_mode,
            .llm_messages = &llm_messages,
            .llm_loading = &llm_loading,
            .log_messages = &log_messages,
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

            switch (update.kind) {
                .message_chunk => {
                    const win_height = state.vx.window().height;
                    const panel_height = if (win_height > 4) win_height - 2 else 2;
                    const messages_height = if (panel_height > 6) panel_height - 8 else 1;
                    const buffer_rows = state.llm_text_buffer.rows;
                    const max_scroll = buffer_rows -| messages_height;
                    const current_scroll = state.llm_text_view.scroll_view.scroll.y;
                    const threshold: usize = 3;
                    const is_at_bottom = (current_scroll +| threshold >= max_scroll) or buffer_rows <= messages_height;

                    // Check if this is the first chunk (need to create initial message)
                    const is_first_chunk = state.llm_messages.items.len == 0 or
                        (state.llm_messages.items.len > 0 and
                        !std.mem.startsWith(u8, state.llm_messages.items[state.llm_messages.items.len - 1], "AI:"));

                    if (is_first_chunk) {
                        const initial_msg = try std.fmt.allocPrint(alloc, "AI: {s}", .{update.data});
                        try state.llm_messages.append(alloc, initial_msg);
                    } else {
                        const last_idx = state.llm_messages.items.len - 1;
                        const old_msg = state.llm_messages.items[last_idx];
                        const new_msg = try std.fmt.allocPrint(alloc, "{s}{s}", .{ old_msg, update.data });
                        alloc.free(old_msg);
                        state.llm_messages.items[last_idx] = new_msg;
                    }

                    if (is_at_bottom) {
                        const chunk_lines = 1 + std.mem.count(u8, update.data, "\n");
                        state.llm_text_view.scroll_view.scroll.y +|= chunk_lines;
                    }

                    std.log.info("AI chunk received", .{});
                },
                .message_completed => {
                    state.llm_loading.* = false;
                    std.log.info("AI message completed", .{});
                },
                .error_occurred => {
                    state.llm_loading.* = false;
                    const error_msg = try std.fmt.allocPrint(alloc, "AI: {s}", .{update.data});
                    try state.llm_messages.append(alloc, error_msg);
                    std.log.err("AI error: {s}", .{update.data});
                },
                .tool_call => {
                    if (update.tool_call) |tool| {
                        defer {
                            alloc.free(tool.tool_name);
                            alloc.free(tool.chat_name);
                            alloc.free(tool.message_text);
                        }

                        std.log.info("AI requested tool call: {s} for chat '{s}'", .{ tool.tool_name, tool.chat_name });

                        const tool_msg = try std.fmt.allocPrint(alloc, "AI: [Sending message to '{s}'...]", .{tool.chat_name});
                        try state.llm_messages.append(alloc, tool_msg);

                        // Find chat by name
                        var found_chat_id: ?i64 = null;
                        for (state.chats.items) |chat| {
                            if (std.mem.eql(u8, chat.title, tool.chat_name)) {
                                found_chat_id = chat.id;
                                break;
                            }
                        }

                        if (found_chat_id) |chat_id| {
                            // Send message via Telegram
                            const msg_copy = try alloc.dupe(u8, tool.message_text);
                            try state.telegram_queue.postRequest(.{
                                .send_message = .{
                                    .chat_id = chat_id,
                                    .text = msg_copy,
                                },
                            });

                            // Report success back to AI
                            const success_msg = try std.fmt.allocPrint(alloc, "Message sent successfully to chat '{s}'", .{tool.chat_name});
                            try state.ai_queue.postRequest(.{
                                .tool_result = .{
                                    .success = true,
                                    .message = success_msg,
                                },
                            });
                        } else {
                            // Chat not found
                            const error_msg = try std.fmt.allocPrint(alloc, "Chat '{s}' not found in your conversations", .{tool.chat_name});
                            try state.ai_queue.postRequest(.{
                                .tool_result = .{
                                    .success = false,
                                    .message = error_msg,
                                },
                            });
                        }
                    }
                },
            }
        },
    }

    return 1;
}

fn handle_scroll_input(state: *AppState, key: vaxis.Key) bool {
    const is_scroll_key = key.codepoint == vaxis.Key.up or key.codepoint == vaxis.Key.down;
    const can_scroll_chat = state.active_mode.* == .chat and state.chat_input.buf.realLength() == 0 and is_scroll_key;
    const can_scroll_llm = state.active_mode.* == .llm and state.llm_input.buf.realLength() == 0 and is_scroll_key;

    if (can_scroll_chat) {
        state.chat_text_view.input(key);
        return true;
    }

    if (can_scroll_llm) {
        state.llm_text_view.input(key);
        return true;
    }

    return false;
}

fn handle_text_input(state: *AppState, key: vaxis.Key, action: keybindings.KeyAction) bool {
    const should_handle = switch (action) {
        .none => true,
        .delete_char => state.active_mode.* == .chat or state.active_mode.* == .llm,
        .navigate_up, .navigate_down => state.active_mode.* == .chat or state.active_mode.* == .llm,
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

            if (state.ai_config.google_ai == null) {
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

    var new_keymap = keybindings.buildKeymap(alloc, new_keybindings) catch |err| {
        std.log.err("Failed to build keymap: {any}", .{err});
        new_keybindings.deinit(alloc);
        return err;
    };

    const new_ai_config = ai.loadConfig(alloc) catch |err| {
        std.log.err("Failed to reload AI config: {any}", .{err});
        new_keybindings.deinit(alloc);
        new_keymap.deinit();
        return err;
    };

    state.keybindings.*.deinit(alloc);
    state.keymap.*.deinit();
    state.ai_config.*.deinit(alloc);

    state.keybindings.* = new_keybindings;
    state.keymap.* = new_keymap;
    state.ai_config.* = new_ai_config;

    std.log.info("Config reloaded (keybindings and AI settings)", .{});
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
        .toggle_right_panel => {
            state.right_panel_mode.* = switch (state.right_panel_mode.*) {
                .llm => .logs,
                .logs => .llm,
            };
            std.log.info("Toggled right panel to {s}", .{@tagName(state.right_panel_mode.*)});
        },
        .delete_char, .send_message, .none => {},
    }
    return 1;
}

fn handle_key_press(alloc: std.mem.Allocator, state: *AppState, key: vaxis.Key) !i32 {
    if (handle_scroll_input(state, key)) return 1;

    const action = keybindings.getKeyAction(state.keymap, key);

    if (handle_text_input(state, key, action)) return 1;

    return try handle_key_action(alloc, state, action);
}
