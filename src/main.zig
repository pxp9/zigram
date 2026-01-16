const std = @import("std");
const zigram = @import("zigram");
const vaxis = @import("vaxis");
const auth = @import("auth.zig");
const tdlib = @import("tdlib.zig");
const telegram = @import("telegram.zig");
const log = @import("log.zig");
const addLog = log.addLog;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    new_message: void,
};

const InputMode = enum {
    chat,
    llm,
    chat_list,
};

const RightPanelMode = enum {
    llm,
    logs,
};

const KeyAction = enum {
    quit,
    switch_mode,
    navigate_up,
    navigate_down,
    select,
    send_message,
    delete_char,
    reload_config,
    toggle_right_panel,
    none,
};

// Default keybinding constants
const DEFAULT_QUIT = "ctrl+q";
const DEFAULT_QUIT_CTRL = "ctrl+c";
const DEFAULT_SWITCH_MODE = "tab";
const DEFAULT_NAVIGATE_UP = "up";
const DEFAULT_NAVIGATE_UP_ALT = "k";
const DEFAULT_NAVIGATE_DOWN = "down";
const DEFAULT_NAVIGATE_DOWN_ALT = "j";
const DEFAULT_SELECT = "enter";
const DEFAULT_BACKSPACE = "backspace";
const DEFAULT_RELOAD_CONFIG = "ctrl+r";
const DEFAULT_TOGGLE_RIGHT_PANEL = "ctrl+l";

const KeyBindings = struct {
    quit: []const u8 = DEFAULT_QUIT,
    quit_ctrl: []const u8 = DEFAULT_QUIT_CTRL,
    switch_mode: []const u8 = DEFAULT_SWITCH_MODE,
    navigate_up: []const u8 = DEFAULT_NAVIGATE_UP,
    navigate_up_alt: []const u8 = DEFAULT_NAVIGATE_UP_ALT,
    navigate_down: []const u8 = DEFAULT_NAVIGATE_DOWN,
    navigate_down_alt: []const u8 = DEFAULT_NAVIGATE_DOWN_ALT,
    select: []const u8 = DEFAULT_SELECT,
    backspace: []const u8 = DEFAULT_BACKSPACE,
    reload_config: []const u8 = DEFAULT_RELOAD_CONFIG,
    toggle_right_panel: []const u8 = DEFAULT_TOGGLE_RIGHT_PANEL,
    allocated: bool = false, // Track if strings were allocated

    fn deinit(self: *KeyBindings, allocator: std.mem.Allocator) void {
        if (self.allocated) {
            allocator.free(self.quit);
            allocator.free(self.quit_ctrl);
            allocator.free(self.switch_mode);
            allocator.free(self.navigate_up);
            allocator.free(self.navigate_up_alt);
            allocator.free(self.navigate_down);
            allocator.free(self.navigate_down_alt);
            allocator.free(self.select);
            allocator.free(self.backspace);
            allocator.free(self.reload_config);
        }
    }
};

fn createConfigDir(alloc: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const config_dir = try std.fs.path.join(alloc, &[_][]const u8{ home, ".config", "zigram" });

    // Create .config/zigram directory if it doesn't exist
    std.fs.makeDirAbsolute(config_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    return config_dir;
}

fn createDefaultConfig(alloc: std.mem.Allocator) !void {
    const config_dir = try createConfigDir(alloc);
    defer alloc.free(config_dir);

    const config_path = try std.fs.path.join(alloc, &[_][]const u8{ config_dir, "zigram.json" });
    defer alloc.free(config_path);

    // Check if config already exists
    if (std.fs.openFileAbsolute(config_path, .{})) |file| {
        file.close();
        return; // Config already exists, don't overwrite
    } else |_| {}

    // Create default keybindings
    const default_keybindings = KeyBindings{};

    // Write JSON config
    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    var write_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&write_buf);
    const writer = fbs.writer();

    try writer.writeAll("{\n");
    try writer.writeAll("  \"keybindings\": {\n");
    try writer.print("    \"quit\": \"{s}\",\n", .{default_keybindings.quit});
    try writer.print("    \"quit_ctrl\": \"{s}\",\n", .{default_keybindings.quit_ctrl});
    try writer.print("    \"switch_mode\": \"{s}\",\n", .{default_keybindings.switch_mode});
    try writer.print("    \"navigate_up\": \"{s}\",\n", .{default_keybindings.navigate_up});
    try writer.print("    \"navigate_up_alt\": \"{s}\",\n", .{default_keybindings.navigate_up_alt});
    try writer.print("    \"navigate_down\": \"{s}\",\n", .{default_keybindings.navigate_down});
    try writer.print("    \"navigate_down_alt\": \"{s}\",\n", .{default_keybindings.navigate_down_alt});
    try writer.print("    \"select\": \"{s}\",\n", .{default_keybindings.select});
    try writer.print("    \"backspace\": \"{s}\",\n", .{default_keybindings.backspace});
    try writer.print("    \"reload_config\": \"{s}\"\n", .{default_keybindings.reload_config});
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");

    try file.writeAll(fbs.getWritten());
}

fn loadKeybindings(alloc: std.mem.Allocator) !KeyBindings {
    const config_dir = try createConfigDir(alloc);
    defer alloc.free(config_dir);

    const config_path = try std.fs.path.join(alloc, &[_][]const u8{ config_dir, "zigram.json" });
    defer alloc.free(config_path);

    // Try to read config file
    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        // If file doesn't exist, return defaults
        return KeyBindings{};
    };
    defer file.close();

    // Read file contents
    const max_size = 1024 * 10; // 10KB max
    const contents = try file.readToEndAlloc(alloc, max_size);
    defer alloc.free(contents);

    // Parse JSON
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        contents,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value;

    // Extract keybindings - always dupe all strings for consistency
    var keybindings = KeyBindings{ .allocated = true };

    if (root.object.get("keybindings")) |kb_obj| {
        if (kb_obj.object.get("quit")) |v| {
            keybindings.quit = try alloc.dupe(u8, v.string);
        } else {
            keybindings.quit = try alloc.dupe(u8, DEFAULT_QUIT);
        }
        if (kb_obj.object.get("quit_ctrl")) |v| {
            keybindings.quit_ctrl = try alloc.dupe(u8, v.string);
        } else {
            keybindings.quit_ctrl = try alloc.dupe(u8, DEFAULT_QUIT_CTRL);
        }
        if (kb_obj.object.get("switch_mode")) |v| {
            keybindings.switch_mode = try alloc.dupe(u8, v.string);
        } else {
            keybindings.switch_mode = try alloc.dupe(u8, DEFAULT_SWITCH_MODE);
        }
        if (kb_obj.object.get("navigate_up")) |v| {
            keybindings.navigate_up = try alloc.dupe(u8, v.string);
        } else {
            keybindings.navigate_up = try alloc.dupe(u8, DEFAULT_NAVIGATE_UP);
        }
        if (kb_obj.object.get("navigate_up_alt")) |v| {
            keybindings.navigate_up_alt = try alloc.dupe(u8, v.string);
        } else {
            keybindings.navigate_up_alt = try alloc.dupe(u8, DEFAULT_NAVIGATE_UP_ALT);
        }
        if (kb_obj.object.get("navigate_down")) |v| {
            keybindings.navigate_down = try alloc.dupe(u8, v.string);
        } else {
            keybindings.navigate_down = try alloc.dupe(u8, DEFAULT_NAVIGATE_DOWN);
        }
        if (kb_obj.object.get("navigate_down_alt")) |v| {
            keybindings.navigate_down_alt = try alloc.dupe(u8, v.string);
        } else {
            keybindings.navigate_down_alt = try alloc.dupe(u8, DEFAULT_NAVIGATE_DOWN_ALT);
        }
        if (kb_obj.object.get("select")) |v| {
            keybindings.select = try alloc.dupe(u8, v.string);
        } else {
            keybindings.select = try alloc.dupe(u8, DEFAULT_SELECT);
        }
        if (kb_obj.object.get("backspace")) |v| {
            keybindings.backspace = try alloc.dupe(u8, v.string);
        } else {
            keybindings.backspace = try alloc.dupe(u8, DEFAULT_BACKSPACE);
        }
        if (kb_obj.object.get("reload_config")) |v| {
            keybindings.reload_config = try alloc.dupe(u8, v.string);
        } else {
            keybindings.reload_config = try alloc.dupe(u8, DEFAULT_RELOAD_CONFIG);
        }
    } else {
        // No keybindings in config, dupe defaults
        keybindings.quit = try alloc.dupe(u8, DEFAULT_QUIT);
        keybindings.quit_ctrl = try alloc.dupe(u8, DEFAULT_QUIT_CTRL);
        keybindings.switch_mode = try alloc.dupe(u8, DEFAULT_SWITCH_MODE);
        keybindings.navigate_up = try alloc.dupe(u8, DEFAULT_NAVIGATE_UP);
        keybindings.navigate_up_alt = try alloc.dupe(u8, DEFAULT_NAVIGATE_UP_ALT);
        keybindings.navigate_down = try alloc.dupe(u8, DEFAULT_NAVIGATE_DOWN);
        keybindings.navigate_down_alt = try alloc.dupe(u8, DEFAULT_NAVIGATE_DOWN_ALT);
        keybindings.select = try alloc.dupe(u8, DEFAULT_SELECT);
        keybindings.backspace = try alloc.dupe(u8, DEFAULT_BACKSPACE);
        keybindings.reload_config = try alloc.dupe(u8, DEFAULT_RELOAD_CONFIG);
    }

    return keybindings;
}

const KeyHash = struct {
    codepoint: u32,
    ctrl: bool,
    alt: bool,
    shift: bool,

    fn fromKey(key: vaxis.Key) KeyHash {
        return .{
            .codepoint = key.codepoint,
            .ctrl = key.mods.ctrl,
            .alt = key.mods.alt,
            .shift = key.mods.shift,
        };
    }

    fn toU64(self: KeyHash) u64 {
        var hash: u64 = self.codepoint;
        if (self.ctrl) hash |= (1 << 32);
        if (self.alt) hash |= (1 << 33);
        if (self.shift) hash |= (1 << 34);
        return hash;
    }
};

fn parseKeyToHash(key_str: []const u8) ?u64 {
    var ctrl = false;
    var actual_key_str = key_str;

    // Check for modifiers
    if (std.mem.startsWith(u8, key_str, "ctrl+")) {
        ctrl = true;
        actual_key_str = key_str[5..];
    }

    // Parse the key and create hash
    var codepoint: u32 = 0;

    if (std.mem.eql(u8, actual_key_str, "enter")) {
        codepoint = '\r';
    } else if (std.mem.eql(u8, actual_key_str, "tab")) {
        codepoint = '\t';
    } else if (std.mem.eql(u8, actual_key_str, "backspace")) {
        codepoint = 127;
    } else if (std.mem.eql(u8, actual_key_str, "up")) {
        codepoint = vaxis.Key.up;
    } else if (std.mem.eql(u8, actual_key_str, "down")) {
        codepoint = vaxis.Key.down;
    } else if (std.mem.eql(u8, actual_key_str, "left")) {
        codepoint = vaxis.Key.left;
    } else if (std.mem.eql(u8, actual_key_str, "right")) {
        codepoint = vaxis.Key.right;
    } else if (std.mem.eql(u8, actual_key_str, "escape") or std.mem.eql(u8, actual_key_str, "esc")) {
        codepoint = 27;
    } else if (actual_key_str.len == 1) {
        codepoint = actual_key_str[0];
    } else {
        return null;
    }

    var hash: u64 = codepoint;
    if (ctrl) hash |= (1 << 32);
    return hash;
}

fn buildKeymap(alloc: std.mem.Allocator, keybindings: KeyBindings) !std.AutoHashMap(u64, KeyAction) {
    var keymap = std.AutoHashMap(u64, KeyAction).init(alloc);

    // Map quit keys
    if (parseKeyToHash(keybindings.quit)) |hash| {
        try keymap.put(hash, .quit);
    }
    if (parseKeyToHash(keybindings.quit_ctrl)) |hash| {
        try keymap.put(hash, .quit);
    }

    // Map switch_mode
    if (parseKeyToHash(keybindings.switch_mode)) |hash| {
        try keymap.put(hash, .switch_mode);
    }

    // Map navigate_up
    if (parseKeyToHash(keybindings.navigate_up)) |hash| {
        try keymap.put(hash, .navigate_up);
    }
    if (parseKeyToHash(keybindings.navigate_up_alt)) |hash| {
        try keymap.put(hash, .navigate_up);
    }

    // Map navigate_down
    if (parseKeyToHash(keybindings.navigate_down)) |hash| {
        try keymap.put(hash, .navigate_down);
    }
    if (parseKeyToHash(keybindings.navigate_down_alt)) |hash| {
        try keymap.put(hash, .navigate_down);
    }

    // Map select/enter
    if (parseKeyToHash(keybindings.select)) |hash| {
        try keymap.put(hash, .select);
    }

    // Map backspace
    if (parseKeyToHash(keybindings.backspace)) |hash| {
        try keymap.put(hash, .delete_char);
    }

    // Map reload_config
    if (parseKeyToHash(keybindings.reload_config)) |hash| {
        try keymap.put(hash, .reload_config);
    }

    // Map toggle_right_panel
    if (parseKeyToHash(keybindings.toggle_right_panel)) |hash| {
        try keymap.put(hash, .toggle_right_panel);
    }

    return keymap;
}

fn getKeyAction(keymap: *const std.AutoHashMap(u64, KeyAction), key: vaxis.Key) KeyAction {
    const hash = KeyHash.fromKey(key).toU64();
    return keymap.get(hash) orelse .none;
}

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

    std.debug.print("\nStarting Zigram UI...\n", .{});
    std.Thread.sleep(1 * std.time.ns_per_s); // Give user time to see auth message

    // Create default config file if it doesn't exist
    try createDefaultConfig(alloc);

    // Load keybindings from config file
    var keybindings = try loadKeybindings(alloc);
    defer keybindings.deinit(alloc);

    // Build keymap from keybindings
    var keymap = try buildKeymap(alloc, keybindings);
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

    // State for messages and inputs
    var chat_messages: std.ArrayList([]const u8) = .empty;
    defer chat_messages.deinit(alloc);
    // Track which messages were allocated (to free them later)
    var allocated_chat_messages: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_chat_messages.items) |msg| {
            alloc.free(msg);
        }
        allocated_chat_messages.deinit(alloc);
    }
    try chat_messages.append(alloc, "Alice: Hey, how are you?");
    try chat_messages.append(alloc, "You: I'm doing great, thanks!");
    try chat_messages.append(alloc, "Alice: Want to grab coffee later?");
    try chat_messages.append(alloc, "You: Sure, what time works?");
    try chat_messages.append(alloc, "Alice: How about 3pm?");

    var llm_messages: std.ArrayList([]const u8) = .empty;
    defer llm_messages.deinit(alloc);
    var allocated_llm_messages: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocated_llm_messages.items) |msg| {
            alloc.free(msg);
        }
        allocated_llm_messages.deinit(alloc);
    }
    try llm_messages.append(alloc, "AI: Hello! How can I help you today?");
    try llm_messages.append(alloc, "You: Summarize chat");
    try llm_messages.append(alloc, "AI: Alice wants to meet for coffee at 3pm.");

    // Open log file
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    const log_dir = try std.fs.path.join(alloc, &[_][]const u8{ home, ".local", "share", "zigram" });
    defer alloc.free(log_dir);
    std.fs.makeDirAbsolute(log_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
    const log_path = try std.fs.path.join(alloc, &[_][]const u8{ log_dir, "zigram.log" });
    defer alloc.free(log_path);

    const log_file = try std.fs.createFileAbsolute(log_path, .{ .truncate = false });
    defer log_file.close();
    try log_file.seekFromEnd(0); // Append to end

    // Log messages
    var log_messages: std.ArrayList([]const u8) = .empty;
    defer {
        for (log_messages.items) |msg| {
            alloc.free(msg);
        }
        log_messages.deinit(alloc);
    }

    try addLog(&log_messages, alloc, log_file, "Zigram started", .{});
    try addLog(&log_messages, alloc, log_file, "Log file: {s}", .{log_path});

    // Give TDLib some time to settle after authentication and consume any pending updates
    try addLog(&log_messages, alloc, log_file, "Waiting for TDLib to settle...", .{});

    // Consume pending updates for a few seconds
    var settle_attempts: u32 = 0;
    while (settle_attempts < 20) : (settle_attempts += 1) {
        const update_opt = client.receive(0.1);
        if (update_opt) |update| {
            try addLog(&log_messages, alloc, log_file, "Background update: {s}", .{update[0..@min(update.len, 200)]});
        }
    }

    // Fetch real chats from Telegram
    std.debug.print("Fetching chats...\n", .{});
    try addLog(&log_messages, alloc, log_file, "Fetching chats from Telegram...", .{});
    var chats = telegram.getChats(client, alloc, 20, &log_messages, log_file) catch |err| blk: {
        try addLog(&log_messages, alloc, log_file, "Failed to fetch chats: {any}", .{err});
        break :blk std.ArrayList(telegram.Chat).empty;
    };
    try addLog(&log_messages, alloc, log_file, "Loaded {d} chats", .{chats.items.len});
    defer {
        for (chats.items) |*chat| {
            chat.deinit(alloc);
        }
        chats.deinit(alloc);
    }

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

    // Load messages for first chat automatically
    if (chats.items.len > 0) {
        const first_chat = chats.items[0];
        try addLog(&log_messages, alloc, log_file, "Loading messages for first chat: {s}", .{first_chat.title});
        const first_messages = telegram.getChatHistory(client, alloc, first_chat.id, 10, &log_messages, log_file) catch blk: {
            try addLog(&log_messages, alloc, log_file, "Failed to load messages for first chat", .{});
            break :blk std.ArrayList(telegram.Message).empty;
        };
        try chat_messages_cache.put(first_chat.id, first_messages);
        try addLog(&log_messages, alloc, log_file, "Loaded {d} messages for first chat", .{first_messages.items.len});
    }

    var chat_input_buf: [256]u8 = undefined;
    var chat_input_len: usize = 0;
    var llm_input_buf: [256]u8 = undefined;
    var llm_input_len: usize = 0;
    var active_mode: InputMode = .chat;
    var right_panel_mode: RightPanelMode = .llm;

    // Flag to track if we need to render
    var needs_render = true;

    // Main event loop
    while (true) {
        // Check for TDLib updates (non-blocking)
        var got_tdlib_update = false;
        while (client.receive(0.0)) |response| {
            got_tdlib_update = true;
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                alloc,
                response,
                .{},
            ) catch continue;
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse continue;

            // Handle new message updates
            if (std.mem.eql(u8, update_type.string, "updateNewMessage")) {
                if (value.object.get("message")) |msg_obj| {
                    const chat_id = msg_obj.object.get("chat_id") orelse continue;
                    const msg_chat_id = chat_id.integer;

                    // Only process if we have this chat cached
                    if (chat_messages_cache.getPtr(msg_chat_id)) |cached_messages| {
                        const msg_id = msg_obj.object.get("id") orelse continue;
                        const is_outgoing = msg_obj.object.get("is_outgoing") orelse continue;

                        // Get sender name
                        var sender_name: []const u8 = "Unknown";
                        if (is_outgoing.bool) {
                            sender_name = "You";
                        } else {
                            // Try to find chat title for this chat_id
                            for (chats.items) |chat| {
                                if (chat.id == msg_chat_id) {
                                    sender_name = chat.title;
                                    break;
                                }
                            }
                        }

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
                        }) catch continue;

                        try addLog(&log_messages, alloc, log_file, "Added new message to chat {d}: {s}", .{ msg_chat_id, content });

                        // Mark that we need to render
                        needs_render = true;
                    }
                }
            }
        }

        // Try to get event with a small sleep to allow periodic updates
        // This allows us to check TDLib updates even without keyboard input
        std.Thread.sleep(50 * std.time.ns_per_ms); // Sleep 50ms

        const event_opt = loop.tryEvent();
        if (event_opt == null) {
            // No event, but we might have TDLib updates, so continue to render
            if (got_tdlib_update) {
                needs_render = true;
            }
            // Skip event handling and go to render
        } else {
            const event = event_opt.?;
            switch (event) {
            .key_press => |key| {
                const action = getKeyAction(&keymap, key);

                // Check if this is a navigation action but we're not in chat_list mode
                const is_nav_action = action == .navigate_up or action == .navigate_down;
                const should_handle_as_text = is_nav_action and active_mode != .chat_list;

                if (should_handle_as_text) {
                    // Treat navigation keys as regular text input when not in chat_list mode
                    if (key.codepoint != 0 and key.codepoint < 128) {
                        const char: u8 = @intCast(key.codepoint);
                        if (active_mode == .chat and chat_input_len < chat_input_buf.len) {
                            chat_input_buf[chat_input_len] = char;
                            chat_input_len += 1;
                        } else if (active_mode == .llm and llm_input_len < llm_input_buf.len) {
                            llm_input_buf[llm_input_len] = char;
                            llm_input_len += 1;
                        }
                    }
                } else {
                    switch (action) {
                        .quit => break,
                        .switch_mode => {
                            // Cycle through modes: chat -> llm -> chat_list -> chat
                            active_mode = switch (active_mode) {
                                .chat => .llm,
                                .llm => .chat_list,
                                .chat_list => .chat,
                            };
                        },
                        .navigate_up => {
                            if (active_mode == .chat_list and selected_chat_idx > 0) {
                                selected_chat_idx -= 1;
                            }
                        },
                        .navigate_down => {
                            if (active_mode == .chat_list and selected_chat_idx < chats.items.len - 1) {
                                selected_chat_idx += 1;
                            }
                        },
                        .select => {
                            if (active_mode == .chat_list and chats.items.len > 0) {
                                const selected_chat = chats.items[selected_chat_idx];

                                // Check if messages are already cached
                                if (!chat_messages_cache.contains(selected_chat.id)) {
                                    try addLog(&log_messages, alloc, log_file, "Loading messages for chat: {s}", .{selected_chat.title});

                                    // Set loading state
                                    loading_messages = true;

                                    // Load new messages and cache them
                                    const new_messages = telegram.getChatHistory(client, alloc, selected_chat.id, 10, &log_messages, log_file) catch blk: {
                                        try addLog(&log_messages, alloc, log_file, "Failed to load messages", .{});
                                        break :blk std.ArrayList(telegram.Message).empty;
                                    };
                                    try chat_messages_cache.put(selected_chat.id, new_messages);
                                    loading_messages = false;
                                    try addLog(&log_messages, alloc, log_file, "Loaded {d} messages", .{new_messages.items.len});
                                }

                                // Switch back to chat mode after selecting
                                active_mode = .chat;
                            } else if (active_mode == .chat and chat_input_len > 0) {
                                // Send chat message via Telegram
                                const selected_chat = chats.items[selected_chat_idx];
                                const message_text = chat_input_buf[0..chat_input_len];
                                try addLog(&log_messages, alloc, log_file, "Sending message to {s}", .{selected_chat.title});
                                telegram.sendMessage(client, alloc, selected_chat.id, message_text) catch |err| {
                                    try addLog(&log_messages, alloc, log_file, "Failed to send message: {any}", .{err});
                                };

                                // Don't manually add to cache - TDLib will send updateNewMessage
                                try addLog(&log_messages, alloc, log_file, "Message sent, waiting for updateNewMessage", .{});
                                chat_input_len = 0;
                            } else if (active_mode == .llm and llm_input_len > 0) {
                                // Send LLM message
                                const msg = try std.fmt.allocPrint(alloc, "You: {s}", .{llm_input_buf[0..llm_input_len]});
                                try llm_messages.append(alloc, msg);
                                try allocated_llm_messages.append(alloc, msg);
                                llm_input_len = 0;
                            }
                        },
                        .delete_char => {
                            if (active_mode == .chat and chat_input_len > 0) {
                                chat_input_len -= 1;
                            } else if (active_mode == .llm and llm_input_len > 0) {
                                llm_input_len -= 1;
                            }
                        },
                        .reload_config => {
                            // Reload keybindings from config file
                            keybindings.deinit(alloc);
                            keybindings = loadKeybindings(alloc) catch blk: {
                                // If reload fails, use defaults
                                break :blk KeyBindings{ .allocated = false };
                            };
                            // Rebuild keymap with new keybindings
                            keymap.deinit();
                            keymap = buildKeymap(alloc, keybindings) catch blk: {
                                // If rebuild fails, create empty keymap
                                break :blk std.AutoHashMap(u64, KeyAction).init(alloc);
                            };
                            try addLog(&log_messages, alloc, log_file, "Config reloaded", .{});
                        },
                        .toggle_right_panel => {
                            right_panel_mode = switch (right_panel_mode) {
                                .llm => .logs,
                                .logs => .llm,
                            };
                            try addLog(&log_messages, alloc, log_file, "Toggled right panel to {s}", .{@tagName(right_panel_mode)});
                        },
                        .send_message, .none => {
                            // Handle text input for unbound keys
                            if (key.codepoint != 0 and key.codepoint < 128) {
                                const char: u8 = @intCast(key.codepoint);
                                if (active_mode == .chat and chat_input_len < chat_input_buf.len) {
                                    chat_input_buf[chat_input_len] = char;
                                    chat_input_len += 1;
                                } else if (active_mode == .llm and llm_input_len < llm_input_buf.len) {
                                    llm_input_buf[llm_input_len] = char;
                                    llm_input_len += 1;
                                }
                            }
                        },
                    }
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty.writer(), ws);
            },
            .new_message => {
                // Just trigger a re-render by continuing to render section
                needs_render = true;
            },
            }
        }

        // Always render after handling events or updates
        needs_render = true;

        // Create arena allocator for this render cycle
        var render_arena = std.heap.ArenaAllocator.init(alloc);
        defer render_arena.deinit();
        const render_alloc = render_arena.allocator();

        // Get the root window (this is automatically full screen)
        const win = vx.window();
        win.clear();

        // Get window dimensions
        const width = win.width;
        const height = win.height;

        // Draw title bar with user info
        var title_buf: [256]u8 = undefined;
        const user_display = if (user.username) |username|
            try std.fmt.bufPrint(&title_buf, "Zigram - Logged as: {s} (@{s})", .{ user.first_name, username })
        else
            try std.fmt.bufPrint(&title_buf, "Zigram - Logged as: {s} {s}", .{ user.first_name, user.last_name });

        const title_x = if (width > user_display.len) (width - user_display.len) / 2 else 0;
        const title_win = win.child(.{
            .x_off = @intCast(title_x),
            .y_off = 0,
        });
        const title_segment: vaxis.Cell.Segment = .{
            .text = user_display,
            .style = .{
                .bold = true,
                .fg = .{ .index = 2 }, // Green
            },
        };
        _ = title_win.printSegment(title_segment, .{});

        // Calculate panel dimensions (leave 2 rows for title and status bar)
        const panel_height = if (height > 4) height - 2 else 2; // Minimum height of 2 for at least border
        const min_chat_list_width = 20; // Minimum width for chat list
        const chat_list_width = @max(width / 4, min_chat_list_width); // 25% for chat list, minimum 20
        const chat_width = width / 2; // 50% for main chat
        const llm_chat_width = if (width > chat_list_width + chat_width)
            width - chat_list_width - chat_width
        else
            0; // Remaining for LLM chat

        // Panel 1: Chat List (left side - 25%)
        const chat_list_panel = win.child(.{
            .x_off = 0,
            .y_off = 1,
            .width = chat_list_width,
            .height = panel_height,
            .border = .{
                .where = .all,
                .style = .{ .fg = .{ .index = 4 } }, // Blue border
            },
        });
        const chat_list_title = chat_list_panel.child(.{
            .x_off = 2,
            .y_off = 1,
        });
        const chat_list_title_text = if (active_mode == .chat_list) "Chat List [ACTIVE]" else "Chat List";
        const chat_list_border_style: vaxis.Style = if (active_mode == .chat_list)
            .{ .bold = true, .fg = .{ .index = 3 }, .reverse = true } // Yellow and highlighted
        else
            .{ .bold = true, .fg = .{ .index = 6 } }; // Cyan
        _ = chat_list_title.printSegment(.{
            .text = chat_list_title_text,
            .style = chat_list_border_style,
        }, .{});

        // Display chat list with selection or "No chats" message
        if (chats.items.len == 0) {
            const no_chats_win = chat_list_panel.child(.{
                .x_off = 2,
                .y_off = 3,
            });
            _ = no_chats_win.printSegment(.{
                .text = "No chats",
                .style = .{ .fg = .{ .index = 8 } }, // Gray
            }, .{});
        } else {
            // Using while loop with index since inline for doesn't work with runtime arrays
            var idx: usize = 0;
            while (idx < chats.items.len) : (idx += 1) {
            const chat = chats.items[idx];
            const item_y = 3 + idx;

            // Only render if item is within the panel bounds
            if (item_y < panel_height - 1) {
                const is_selected = idx == selected_chat_idx;
                const chat_style: vaxis.Style = if (is_selected)
                    .{ .bold = true, .fg = .{ .index = 3 }, .reverse = active_mode == .chat_list }
                else
                    .{};

                // Render prefix separately
                const prefix_win = chat_list_panel.child(.{
                    .x_off = 2,
                    .y_off = @intCast(item_y),
                });
                const prefix = if (is_selected) "> " else "  ";
                _ = prefix_win.printSegment(.{
                    .text = prefix,
                    .style = chat_style,
                }, .{});

                // Calculate max width for chat name (panel width - borders - prefix - padding)
                const max_name_width = if (chat_list_width > 6) chat_list_width - 6 else 1;

                // Truncate chat name if it's too long
                const truncated_chat = if (chat.title.len > max_name_width)
                    chat.title[0..max_name_width]
                else
                    chat.title;

                // Render chat name after prefix
                const chat_item = chat_list_panel.child(.{
                    .x_off = 4, // 2 (padding) + 2 (prefix width)
                    .y_off = @intCast(item_y),
                });
                _ = chat_item.printSegment(.{
                    .text = truncated_chat,
                    .style = chat_style,
                }, .{});
            }
            }
        }

        // Panel 2: Main Chat (center - 50%)
        const chat_panel = win.child(.{
            .x_off = @intCast(chat_list_width),
            .y_off = 1,
            .width = chat_width,
            .height = panel_height,
            .border = .{
                .where = .all,
                .style = .{ .fg = .{ .index = 2 } }, // Green border
            },
        });
        const chat_title = chat_panel.child(.{
            .x_off = 2,
            .y_off = 1,
        });

        if (chats.items.len > 0) {
            var chat_title_buf: [128]u8 = undefined;
            const current_chat_name = chats.items[selected_chat_idx].title;
            const chat_title_text = try std.fmt.bufPrint(&chat_title_buf, "Chat: {s}", .{current_chat_name});
            _ = chat_title.printSegment(.{
                .text = chat_title_text,
                .style = .{ .bold = true, .fg = .{ .index = 2 } }, // Green
            }, .{});
        } else {
            _ = chat_title.printSegment(.{
                .text = "No chat selected",
                .style = .{ .bold = true, .fg = .{ .index = 8 } }, // Gray
            }, .{});
        }

        // Display chat messages (scrollable)
        if (loading_messages) {
            // Show "Loading messages..." while waiting
            const loading_item = chat_panel.child(.{
                .x_off = 2,
                .y_off = 3,
            });
            _ = loading_item.printSegment(.{
                .text = "Loading messages...",
                .style = .{ .fg = .{ .index = 3 }, .italic = true }, // Yellow, italic
            }, .{});
        } else if (chats.items.len > 0) {
            const selected_chat = chats.items[selected_chat_idx];
            const messages_opt = chat_messages_cache.get(selected_chat.id);

            if (messages_opt) |messages| {
                if (messages.items.len == 0) {
                    // Show "No messages"
                    const no_msg_item = chat_panel.child(.{
                        .x_off = 2,
                        .y_off = 3,
                    });
                    _ = no_msg_item.printSegment(.{
                        .text = "No messages",
                        .style = .{ .fg = .{ .index = 8 } }, // Gray
                    }, .{});
                } else {
                    const max_msg_height = if (panel_height > 6) panel_height - 6 else 1;
                    var msg_y: usize = 3;
                    const start_idx = if (messages.items.len > max_msg_height)
                        messages.items.len - max_msg_height
                    else
                        0;
                    for (messages.items[start_idx..]) |msg| {
                // Calculate max width for message content
                const max_msg_width = if (chat_width > 20) chat_width - 20 else 1;

                // Truncate message content if too long
                const truncated_content = if (msg.content.len > max_msg_width)
                    msg.content[0..max_msg_width]
                else
                    msg.content;

                // Allocate formatted message string (will be freed when arena is freed after render)
                const msg_text = std.fmt.allocPrint(render_alloc, "{s}: {s}", .{ msg.sender_name, truncated_content }) catch "[error]";

                const msg_item = chat_panel.child(.{
                    .x_off = 2,
                    .y_off = @intCast(msg_y),
                });
                _ = msg_item.printSegment(.{ .text = msg_text }, .{});
                msg_y += 1;
                    }
                }
            } else {
                // Messages not cached yet, show prompt
                const not_loaded_item = chat_panel.child(.{
                    .x_off = 2,
                    .y_off = 3,
                });
                _ = not_loaded_item.printSegment(.{
                    .text = "Press Enter to load messages",
                    .style = .{ .fg = .{ .index = 8 } }, // Gray
                }, .{});
            }
        }

        // Chat input field
        const chat_input_y = if (panel_height > 3) panel_height - 3 else 1;
        const chat_input_label = chat_panel.child(.{
            .x_off = 2,
            .y_off = @intCast(chat_input_y),
        });
        const chat_prompt = if (active_mode == .chat) "> " else "  ";
        _ = chat_input_label.printSegment(.{
            .text = chat_prompt,
            .style = .{ .bold = true, .fg = .{ .index = 2 } },
        }, .{});
        const chat_input_field = chat_panel.child(.{
            .x_off = 4,
            .y_off = @intCast(chat_input_y),
        });
        const input_style: vaxis.Style = if (active_mode == .chat)
            .{ .fg = .{ .index = 7 }, .reverse = true }
        else
            .{ .fg = .{ .index = 8 } };
        _ = chat_input_field.printSegment(.{
            .text = chat_input_buf[0..chat_input_len],
            .style = input_style,
        }, .{});

        // Panel 3: LLM Chat (right side - remaining space)
        const llm_panel = win.child(.{
            .x_off = @intCast(chat_list_width + chat_width),
            .y_off = 1,
            .width = llm_chat_width,
            .height = panel_height,
            .border = .{
                .where = .all,
                .style = .{ .fg = .{ .index = 5 } }, // Magenta border
            },
        });
        const llm_title = llm_panel.child(.{
            .x_off = 2,
            .y_off = 1,
        });
        const panel_title = if (right_panel_mode == .llm) "AI Assistant" else "Logs";
        _ = llm_title.printSegment(.{
            .text = panel_title,
            .style = .{ .bold = true, .fg = .{ .index = 5 } }, // Magenta
        }, .{});

        // Display LLM messages or Logs based on mode
        const max_llm_height = if (panel_height > 6) panel_height - 6 else 1;
        var llm_y: usize = 3;

        if (right_panel_mode == .llm) {
            const llm_start_idx = if (llm_messages.items.len > max_llm_height)
                llm_messages.items.len - max_llm_height
            else
                0;
            for (llm_messages.items[llm_start_idx..]) |msg| {
                const llm_item = llm_panel.child(.{
                    .x_off = 2,
                    .y_off = @intCast(llm_y),
                });
                _ = llm_item.printSegment(.{ .text = msg }, .{});
                llm_y += 1;
            }
        } else {
            // Display logs with cropping to fit panel width
            const log_start_idx = if (log_messages.items.len > max_llm_height)
                log_messages.items.len - max_llm_height
            else
                0;
            // Calculate max width: panel width - borders (2) - padding (2)
            const max_log_width = if (llm_chat_width > 4) llm_chat_width - 4 else 1;

            for (log_messages.items[log_start_idx..]) |msg| {
                if (llm_y >= panel_height - 3) break; // Don't overflow panel

                const log_item = llm_panel.child(.{
                    .x_off = 2,
                    .y_off = @intCast(llm_y),
                });

                // Crop message if too long, leaving room for ellipsis
                const cropped_msg = if (msg.len > max_log_width) blk: {
                    // Reserve 3 chars for "..."
                    const crop_len = if (max_log_width > 3) max_log_width - 3 else 0;
                    if (crop_len == 0) break :blk "...";

                    var log_buf: [1024]u8 = undefined;
                    const result = std.fmt.bufPrint(&log_buf, "{s}...", .{msg[0..crop_len]}) catch msg[0..@min(msg.len, max_log_width)];
                    break :blk result;
                } else msg;

                _ = log_item.printSegment(.{ .text = cropped_msg }, .{});
                llm_y += 1;
            }
        }

        // LLM input field
        const llm_input_y = if (panel_height > 3) panel_height - 3 else 1;
        const llm_input_label = llm_panel.child(.{
            .x_off = 2,
            .y_off = @intCast(llm_input_y),
        });
        const llm_prompt = if (active_mode == .llm) "> " else "  ";
        _ = llm_input_label.printSegment(.{
            .text = llm_prompt,
            .style = .{ .bold = true, .fg = .{ .index = 5 } },
        }, .{});
        const llm_input_field = llm_panel.child(.{
            .x_off = 4,
            .y_off = @intCast(llm_input_y),
        });
        const llm_input_style: vaxis.Style = if (active_mode == .llm)
            .{ .fg = .{ .index = 7 }, .reverse = true }
        else
            .{ .fg = .{ .index = 8 } };
        _ = llm_input_field.printSegment(.{
            .text = llm_input_buf[0..llm_input_len],
            .style = llm_input_style,
        }, .{});

        // Status bar at the bottom
        const mode_text = switch (active_mode) {
            .chat => "[CHAT]",
            .llm => "[AI]",
            .chat_list => "[SELECT]",
        };

        // Build help text using actual keybindings
        var help_buf: [256]u8 = undefined;
        const mode_help = switch (active_mode) {
            .chat, .llm => try std.fmt.bufPrint(&help_buf, "{s}: Switch | {s}: Send | {s}: Delete", .{ keybindings.switch_mode, keybindings.select, keybindings.backspace }),
            .chat_list => try std.fmt.bufPrint(&help_buf, "{s}: Switch | {s}/{s}: Up | {s}/{s}: Down | {s}: Select", .{ keybindings.switch_mode, keybindings.navigate_up, keybindings.navigate_up_alt, keybindings.navigate_down, keybindings.navigate_down_alt, keybindings.select }),
        };

        var status_buf: [512]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buf, "Mode: {s} | {s} | {s}/{s}: Quit | Terminal: {d}x{d}", .{ mode_text, mode_help, keybindings.quit, keybindings.quit_ctrl, width, height });
        const status_win = win.child(.{
            .x_off = 1,
            .y_off = @intCast(height - 1),
        });
        _ = status_win.printSegment(.{
            .text = status,
            .style = .{ .italic = true, .fg = .{ .index = 8 } }, // Gray
        }, .{});

        // Render the screen
        try vx.render(tty.writer());
    }
}
