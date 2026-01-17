const std = @import("std");
const zigram = @import("zigram");
const vaxis = @import("vaxis");
const auth = @import("auth.zig");
const tdlib = @import("tdlib.zig");
const telegram = @import("telegram.zig");
const keybindings = @import("keybindings.zig");
const render = @import("render.zig");

const KeyAction = keybindings.KeyAction;
const KeyBindings = keybindings.KeyBindings;

// Global log file and log messages for UI
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

    // Direct write to file without buffering
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[{d}] {s} {s}", .{ timestamp, level_txt, scope_txt }) catch return;
    global_log_file.writeAll(msg) catch return;

    const formatted = std.fmt.bufPrint(&buf, format, args) catch return;
    global_log_file.writeAll(formatted) catch return;
    global_log_file.writeAll("\n") catch return;

    // Also add to UI log messages if available
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

    // Set TDLib log verbosity to silent
    try tdlib.setLogVerbosityLevel(0);

    // Create TDLib client
    const client = try tdlib.Client.create();
    defer client.destroy();

    // Authenticate with Telegram
    var user = try auth.authenticate(client, alloc);
    defer user.deinit(alloc);

    std.Thread.sleep(1 * std.time.ns_per_s); // Give user time to see auth message

    // Load keybindings from config file
    var kb = try keybindings.loadKeybindings(alloc);
    defer kb.deinit(alloc);

    // Build keymap from keybindings
    var keymap = try keybindings.buildKeymap(alloc, kb);
    defer keymap.deinit();

    // Initialize TTY with buffer
    var tty_buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buffer);
    defer tty.deinit();

    // Initialize Vaxis
    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.writer());

    // Create event loop
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
    try llm_messages.append(alloc, try alloc.dupe(u8, "AI: Hello! How can I help you today?"));
    try llm_messages.append(alloc, try alloc.dupe(u8, "You: Summarize chat"));
    try llm_messages.append(alloc, try alloc.dupe(u8, "AI: Alice wants to meet for coffee at 3pm."));

    // Open log file for std.log
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

    // Log messages for display in UI
    var log_messages: std.ArrayList([]const u8) = .empty;
    defer {
        for (log_messages.items) |msg| {
            alloc.free(msg);
        }
        log_messages.deinit(alloc);
    }

    // Set global pointers for logging to UI
    global_log_messages = &log_messages;
    global_allocator = alloc;

    std.log.info("Zigram started", .{});
    std.log.info("Log file: {s}", .{log_file_path});

    // Initialize telegram request queue
    var telegram_queue = telegram.TelegramQueue.init(alloc);
    defer telegram_queue.deinit();

    // Spawn telegram update thread early
    const tg_ctx = TelegramThreadContext{
        .client = client,
        .loop = &loop,
        .request_queue = &telegram_queue,
        .alloc = alloc,
    };
    const tg_thread = try std.Thread.spawn(.{}, telegram.telegramUpdateLoop, .{tg_ctx});
    // Don't detach - we need to join it on shutdown
    defer tg_thread.join();

    // Initialize empty chats list - will be filled by telegram thread
    var chats: std.ArrayList(telegram.Chat) = .empty;
    defer {
        for (chats.items) |*chat| {
            chat.deinit(alloc);
        }
        chats.deinit(alloc);
    }

    // Request chats from telegram thread
    std.log.info("Requesting chats from Telegram...", .{});
    try telegram_queue.postRequest(.{ .load_chats = .{ .count = 20 } });

    var selected_chat_idx: usize = 0;

    // Store messages for each chat in a HashMap
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

    var chat_input_buf: [2048]u8 = [_]u8{0} ** 2048;
    var chat_input_len: usize = 0;
    var llm_input_buf: [256]u8 = [_]u8{0} ** 256;
    var llm_input_len: usize = 0;
    var active_mode: InputMode = .chat;
    var right_panel_mode: RightPanelMode = .llm;

    // Main event loop
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
            .chat_input_buf = &chat_input_buf,
            .chat_input_len = &chat_input_len,
            .llm_input_buf = llm_input_buf[0..],
            .llm_input_len = &llm_input_len,
            .llm_messages = &llm_messages,
            .log_messages = &log_messages,
            .keybindings = &kb,
            .keymap = &keymap,
            .telegram_queue = &telegram_queue,
        };

        const status = try handle_event(alloc, event, &state);

        if (status == 0) break;

        // Render after handling event
        try render.render(alloc, &state);
    }
}

fn handle_event(alloc: std.mem.Allocator, event: Event, state: *AppState) !i32 {
    switch (event) {
        .key_press => |key| {
            const action = keybindings.getKeyAction(state.keymap, key);

            // Check if this is a navigation action but we're not in chat_list mode
            const is_nav_action = action == .navigate_up or action == .navigate_down;
            const should_handle_as_text = is_nav_action and state.active_mode.* != .chat_list;

            if (should_handle_as_text) {
                // Treat navigation keys as regular text input when not in chat_list mode
                if (key.codepoint != 0 and key.codepoint < 128) {
                    const char: u8 = @intCast(key.codepoint);
                    if (state.active_mode.* == .chat and state.chat_input_len.* < state.chat_input_buf.len) {
                        state.chat_input_buf[state.chat_input_len.*] = char;
                        state.chat_input_len.* += 1;
                    } else if (state.active_mode.* == .llm and state.llm_input_len.* < state.llm_input_buf.len) {
                        state.llm_input_buf[state.llm_input_len.*] = char;
                        state.llm_input_len.* += 1;
                    }
                }
            } else {
                switch (action) {
                    .quit => {
                        // Request telegram thread to shutdown
                        std.log.info("Quit requested, shutting down telegram thread", .{});
                        state.telegram_queue.postRequest(.{ .shutdown = {} }) catch {};
                        return 0;
                    },
                    .switch_mode => {
                        // Cycle through modes: chat -> llm -> chat_list -> chat
                        state.active_mode.* = switch (state.active_mode.*) {
                            .chat => .llm,
                            .llm => .chat_list,
                            .chat_list => .chat,
                        };
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
                    .select => {
                        if (state.active_mode.* == .chat_list and state.chats.items.len > 0) {
                            const selected_chat = state.chats.items[state.selected_chat_idx.*];

                            // Check if messages are already cached
                            if (!state.chat_messages_cache.contains(selected_chat.id)) {
                                std.log.info("Requesting messages for chat: {s}", .{selected_chat.title});

                                // Set loading state
                                state.loading_messages.* = true;

                                // Request messages from telegram thread
                                try state.telegram_queue.postRequest(.{
                                    .load_chat_history = .{
                                        .chat_id = selected_chat.id,
                                        .limit = 10,
                                    },
                                });
                            }

                            // Clear input buffer when switching chats
                            state.chat_input_len.* = 0;

                            // Switch back to chat mode after selecting
                            state.active_mode.* = .chat;
                        } else if (state.active_mode.* == .chat and state.chat_input_len.* > 0) {
                            // Send chat message via Telegram
                            const selected_chat = state.chats.items[state.selected_chat_idx.*];
                            const message_text = try alloc.dupe(u8, state.chat_input_buf[0..state.chat_input_len.*]);
                            std.log.info("Sending message to chat {d}", .{selected_chat.id});

                            // Request send from telegram thread
                            try state.telegram_queue.postRequest(.{
                                .send_message = .{
                                    .chat_id = selected_chat.id,
                                    .text = message_text,
                                },
                            });

                            state.chat_input_len.* = 0;
                        } else if (state.active_mode.* == .llm and state.llm_input_len.* > 0) {
                            // Send LLM message
                            const msg = try std.fmt.allocPrint(alloc, "You: {s}", .{state.llm_input_buf[0..state.llm_input_len.*]});
                            try state.llm_messages.append(alloc, msg);
                            state.llm_input_len.* = 0;
                        }
                    },
                    .delete_char => {
                        if (state.active_mode.* == .chat and state.chat_input_len.* > 0) {
                            state.chat_input_len.* -= 1;
                        } else if (state.active_mode.* == .llm and state.llm_input_len.* > 0) {
                            state.llm_input_len.* -= 1;
                        }
                    },
                    .reload_config => {
                        // Reload keybindings from config file
                        // First try to load new keybindings
                        var new_keybindings = keybindings.loadKeybindings(alloc) catch |err| {
                            std.log.err("Failed to reload config: {any}", .{err});
                            return 1;
                        };

                        // Build new keymap with new keybindings
                        const new_keymap = keybindings.buildKeymap(alloc, new_keybindings) catch |err| {
                            std.log.err("Failed to build keymap: {any}", .{err});
                            new_keybindings.deinit(alloc);
                            return 1;
                        };

                        // Success - now replace old with new
                        state.keybindings.*.deinit(alloc);
                        state.keymap.*.deinit();
                        state.keybindings.* = new_keybindings;
                        state.keymap.* = new_keymap;

                        std.log.info("Config reloaded", .{});
                    },
                    .toggle_right_panel => {
                        state.right_panel_mode.* = switch (state.right_panel_mode.*) {
                            .llm => .logs,
                            .logs => .llm,
                        };
                        std.log.info("Toggled right panel to {s}", .{@tagName(state.right_panel_mode.*)});
                    },
                    .send_message, .none => {
                        // Handle text input for unbound keys
                        if (key.codepoint != 0 and key.codepoint < 128) {
                            const char: u8 = @intCast(key.codepoint);
                            if (state.active_mode.* == .chat and state.chat_input_len.* < state.chat_input_buf.len) {
                                state.chat_input_buf[state.chat_input_len.*] = char;
                                state.chat_input_len.* += 1;
                            } else if (state.active_mode.* == .llm and state.llm_input_len.* < state.llm_input_buf.len) {
                                state.llm_input_buf[state.llm_input_len.*] = char;
                                state.llm_input_len.* += 1;
                            }
                        }
                    },
                }
            }
            // Post render event after key press
        },
        .winsize => |ws| {
            try state.vx.resize(alloc, state.tty.writer(), ws);
        },
        .telegram_update => |update| {
            defer alloc.free(update.data);

            switch (update.kind) {
                .chats_loaded => {
                    // Parse chats JSON and populate chats list
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

                    // Clear existing chats
                    for (state.chats.items) |*chat| {
                        chat.deinit(alloc);
                    }
                    state.chats.clearRetainingCapacity();

                    // Parse JSON array of chats
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

                    // Auto-load first chat messages
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
                    // Parse messages JSON and add to cache
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

                    // Parse JSON array of messages
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

                        const message = telegram.Message{
                            .id = id.integer,
                            .sender_name = try alloc.dupe(u8, sender_name.string),
                            .content = try alloc.dupe(u8, content.string),
                            .is_outgoing = is_outgoing.bool,
                        };

                        try messages.append(alloc, message);
                    }

                    try state.chat_messages_cache.put(update.chat_id, messages);
                    std.log.info("Loaded {d} messages for chat {d}", .{ messages.items.len, update.chat_id });
                },
                .new_message => {
                    // Parse the JSON data
                    const parsed = std.json.parseFromSlice(
                        std.json.Value,
                        alloc,
                        update.data,
                        .{},
                    ) catch return 1;
                    defer parsed.deinit();

                    const value = parsed.value;
                    if (value.object.get("message")) |msg_obj| {
                        // Only process if we have this chat cached
                        if (state.chat_messages_cache.getPtr(update.chat_id)) |cached_messages| {
                            const msg_id = msg_obj.object.get("id") orelse return 1;
                            const is_outgoing = msg_obj.object.get("is_outgoing") orelse return 1;

                            // Get sender name (simplified - TODO: get actual username from cache)
                            const sender_name: []const u8 = if (is_outgoing.bool) "You" else "Unknown";

                            // Get message content
                            var content: []const u8 = "";
                            if (msg_obj.object.get("content")) |msg_content| {
                                if (msg_content.object.get("text")) |text_obj| {
                                    if (text_obj.object.get("text")) |text| {
                                        content = text.string;
                                    }
                                } else if (msg_content.object.get("@type")) |_| {
                                    content = "[Media]";
                                }
                            }

                            // Add the new message to the cache
                            cached_messages.append(alloc, telegram.Message{
                                .id = msg_id.integer,
                                .sender_name = try alloc.dupe(u8, sender_name),
                                .content = try alloc.dupe(u8, content),
                                .is_outgoing = is_outgoing.bool,
                            }) catch return 1;

                            std.log.info("Added new message to chat {d}: {s}", .{ update.chat_id, content });
                        }
                    }
                },
                .message_edited, .message_deleted, .chat_updated => {
                    // TODO: Handle other update types
                    std.log.info("Received {s} update for chat {d}", .{ @tagName(update.kind), update.chat_id });
                },
                .thread_shutdown => {
                    std.log.info("Telegram thread has shut down", .{});
                },
                .unknown => {},
            }
        },
    }

    return 1;
}
