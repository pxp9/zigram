const std = @import("std");
const vaxis = @import("vaxis");
const render = @import("render.zig");

pub const InputMode = render.InputMode;

pub const KeyAction = enum {
    quit,
    switch_mode,
    navigate_up,
    navigate_down,
    scroll_up,
    scroll_down,
    select,
    send_message,
    delete_char,
    reload_config,
    load_more_messages,
    none,
};

pub const AppConfig = struct {
    datetime_format: []const u8,
    message_limit: usize,
    allocated: bool = false,

    pub fn deinit(self: *AppConfig, alloc: std.mem.Allocator) void {
        if (self.allocated) {
            alloc.free(self.datetime_format);
        }
    }
};

pub const DEFAULT_DATETIME_FORMAT = "%H:%M";
pub const DEFAULT_MESSAGE_LIMIT: usize = 50;

pub const KeyBindings = struct {
    quit: []const u8,
    quit_ctrl: []const u8,
    switch_mode: []const u8,
    navigate_up: []const u8,
    navigate_up_alt: []const u8,
    navigate_down: []const u8,
    navigate_down_alt: []const u8,
    scroll_up: []const u8,
    scroll_down: []const u8,
    select: []const u8,
    backspace: []const u8,
    reload_config: []const u8,
    load_more_messages: []const u8,
    allocated: bool = false,

    pub fn deinit(self: *KeyBindings, alloc: std.mem.Allocator) void {
        if (self.allocated) {
            alloc.free(self.quit);
            alloc.free(self.quit_ctrl);
            alloc.free(self.switch_mode);
            alloc.free(self.navigate_up);
            alloc.free(self.navigate_up_alt);
            alloc.free(self.navigate_down);
            alloc.free(self.navigate_down_alt);
            alloc.free(self.scroll_up);
            alloc.free(self.scroll_down);
            alloc.free(self.select);
            alloc.free(self.backspace);
            alloc.free(self.reload_config);
            alloc.free(self.load_more_messages);
        }
    }
};

pub const DEFAULT_QUIT = "q";
pub const DEFAULT_QUIT_CTRL = "ctrl+c";
pub const DEFAULT_SWITCH_MODE = "tab";
pub const DEFAULT_NAVIGATE_UP = "k";
pub const DEFAULT_NAVIGATE_UP_ALT = "up";
pub const DEFAULT_NAVIGATE_DOWN = "j";
pub const DEFAULT_NAVIGATE_DOWN_ALT = "down";
pub const DEFAULT_SCROLL_UP = "up";
pub const DEFAULT_SCROLL_DOWN = "down";
pub const DEFAULT_SELECT = "enter";
pub const DEFAULT_BACKSPACE = "backspace";
pub const DEFAULT_RELOAD_CONFIG = "ctrl+r";
pub const DEFAULT_LOAD_MORE_MESSAGES = "ctrl+l";

pub fn loadKeybindings(alloc: std.mem.Allocator) !KeyBindings {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    const config_path = try std.fs.path.join(alloc, &[_][]const u8{ home, ".config", "zigram", "zigram.json" });
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        return KeyBindings{
            .quit = DEFAULT_QUIT,
            .quit_ctrl = DEFAULT_QUIT_CTRL,
            .switch_mode = DEFAULT_SWITCH_MODE,
            .navigate_up = DEFAULT_NAVIGATE_UP,
            .navigate_up_alt = DEFAULT_NAVIGATE_UP_ALT,
            .navigate_down = DEFAULT_NAVIGATE_DOWN,
            .navigate_down_alt = DEFAULT_NAVIGATE_DOWN_ALT,
            .scroll_up = DEFAULT_SCROLL_UP,
            .scroll_down = DEFAULT_SCROLL_DOWN,
            .select = DEFAULT_SELECT,
            .backspace = DEFAULT_BACKSPACE,
            .reload_config = DEFAULT_RELOAD_CONFIG,
            .load_more_messages = DEFAULT_LOAD_MORE_MESSAGES,
            .allocated = false,
        };
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch {
        std.log.err("Failed to parse config file. Please check ~/.config/zigram/zigram.json for JSON syntax errors", .{});
        std.log.err("Using default keybindings", .{});
        return KeyBindings{
            .quit = DEFAULT_QUIT,
            .quit_ctrl = DEFAULT_QUIT_CTRL,
            .switch_mode = DEFAULT_SWITCH_MODE,
            .navigate_up = DEFAULT_NAVIGATE_UP,
            .navigate_up_alt = DEFAULT_NAVIGATE_UP_ALT,
            .navigate_down = DEFAULT_NAVIGATE_DOWN,
            .navigate_down_alt = DEFAULT_NAVIGATE_DOWN_ALT,
            .scroll_up = DEFAULT_SCROLL_UP,
            .scroll_down = DEFAULT_SCROLL_DOWN,
            .select = DEFAULT_SELECT,
            .backspace = DEFAULT_BACKSPACE,
            .reload_config = DEFAULT_RELOAD_CONFIG,
            .load_more_messages = DEFAULT_LOAD_MORE_MESSAGES,
            .allocated = false,
        };
    };
    defer parsed.deinit();

    var keybindings = KeyBindings{
        .quit = DEFAULT_QUIT,
        .quit_ctrl = DEFAULT_QUIT_CTRL,
        .switch_mode = DEFAULT_SWITCH_MODE,
        .navigate_up = DEFAULT_NAVIGATE_UP,
        .navigate_up_alt = DEFAULT_NAVIGATE_UP_ALT,
        .navigate_down = DEFAULT_NAVIGATE_DOWN,
        .navigate_down_alt = DEFAULT_NAVIGATE_DOWN_ALT,
        .scroll_up = DEFAULT_SCROLL_UP,
        .scroll_down = DEFAULT_SCROLL_DOWN,
        .select = DEFAULT_SELECT,
        .backspace = DEFAULT_BACKSPACE,
        .reload_config = DEFAULT_RELOAD_CONFIG,
        .load_more_messages = DEFAULT_LOAD_MORE_MESSAGES,
        .allocated = true,
    };

    const root = parsed.value;
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
        if (kb_obj.object.get("scroll_up")) |v| {
            keybindings.scroll_up = try alloc.dupe(u8, v.string);
        } else {
            keybindings.scroll_up = try alloc.dupe(u8, DEFAULT_SCROLL_UP);
        }
        if (kb_obj.object.get("scroll_down")) |v| {
            keybindings.scroll_down = try alloc.dupe(u8, v.string);
        } else {
            keybindings.scroll_down = try alloc.dupe(u8, DEFAULT_SCROLL_DOWN);
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
        if (kb_obj.object.get("load_more_messages")) |v| {
            keybindings.load_more_messages = try alloc.dupe(u8, v.string);
        } else {
            keybindings.load_more_messages = try alloc.dupe(u8, DEFAULT_LOAD_MORE_MESSAGES);
        }
    } else {
        keybindings.quit = try alloc.dupe(u8, DEFAULT_QUIT);
        keybindings.quit_ctrl = try alloc.dupe(u8, DEFAULT_QUIT_CTRL);
        keybindings.switch_mode = try alloc.dupe(u8, DEFAULT_SWITCH_MODE);
        keybindings.navigate_up = try alloc.dupe(u8, DEFAULT_NAVIGATE_UP);
        keybindings.navigate_up_alt = try alloc.dupe(u8, DEFAULT_NAVIGATE_UP_ALT);
        keybindings.navigate_down = try alloc.dupe(u8, DEFAULT_NAVIGATE_DOWN);
        keybindings.navigate_down_alt = try alloc.dupe(u8, DEFAULT_NAVIGATE_DOWN_ALT);
        keybindings.scroll_up = try alloc.dupe(u8, DEFAULT_SCROLL_UP);
        keybindings.scroll_down = try alloc.dupe(u8, DEFAULT_SCROLL_DOWN);
        keybindings.select = try alloc.dupe(u8, DEFAULT_SELECT);
        keybindings.backspace = try alloc.dupe(u8, DEFAULT_BACKSPACE);
        keybindings.reload_config = try alloc.dupe(u8, DEFAULT_RELOAD_CONFIG);
        keybindings.load_more_messages = try alloc.dupe(u8, DEFAULT_LOAD_MORE_MESSAGES);
    }

    return keybindings;
}

pub fn loadAppConfig(alloc: std.mem.Allocator) !AppConfig {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    const config_path = try std.fs.path.join(alloc, &[_][]const u8{ home, ".config", "zigram", "zigram.json" });
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        return AppConfig{
            .datetime_format = DEFAULT_DATETIME_FORMAT,
            .message_limit = DEFAULT_MESSAGE_LIMIT,
            .allocated = false,
        };
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, content, .{}) catch {
        std.log.err("Failed to parse config file. Please check ~/.config/zigram/zigram.json for JSON syntax errors", .{});
        std.log.err("Using default app config", .{});
        return AppConfig{
            .datetime_format = DEFAULT_DATETIME_FORMAT,
            .message_limit = DEFAULT_MESSAGE_LIMIT,
            .allocated = false,
        };
    };
    defer parsed.deinit();

    const root = parsed.value;
    var config = AppConfig{
        .datetime_format = DEFAULT_DATETIME_FORMAT,
        .message_limit = DEFAULT_MESSAGE_LIMIT,
        .allocated = true,
    };

    if (root.object.get("datetime_format")) |dt_format| {
        config.datetime_format = try alloc.dupe(u8, dt_format.string);
    } else {
        config.datetime_format = try alloc.dupe(u8, DEFAULT_DATETIME_FORMAT);
    }

    if (root.object.get("message_limit")) |msg_limit| {
        config.message_limit = @intCast(msg_limit.integer);
    }

    return config;
}

const KeyHash = struct {
    codepoint: u21,
    mods: vaxis.Key.Modifiers,

    pub fn fromKey(key: vaxis.Key) KeyHash {
        return .{
            .codepoint = key.codepoint,
            .mods = key.mods,
        };
    }

    pub fn toU64(self: KeyHash) u64 {
        const cp: u64 = @intCast(self.codepoint);
        const shift: u64 = if (self.mods.shift) 1 else 0;
        const alt: u64 = if (self.mods.alt) 1 else 0;
        const ctrl: u64 = if (self.mods.ctrl) 1 else 0;
        const super: u64 = if (self.mods.super) 1 else 0;
        const hyper: u64 = if (self.mods.hyper) 1 else 0;
        const meta: u64 = if (self.mods.meta) 1 else 0;

        return (cp << 32) | (shift << 0) | (alt << 1) | (ctrl << 2) | (super << 3) | (hyper << 4) | (meta << 5);
    }
};

fn parseKeyString(key_str: []const u8) ?vaxis.Key {
    var mods = vaxis.Key.Modifiers{};
    var key_part = key_str;

    if (std.mem.startsWith(u8, key_str, "ctrl+")) {
        mods.ctrl = true;
        key_part = key_str[5..];
    } else if (std.mem.startsWith(u8, key_str, "alt+")) {
        mods.alt = true;
        key_part = key_str[4..];
    } else if (std.mem.startsWith(u8, key_str, "shift+")) {
        mods.shift = true;
        key_part = key_str[6..];
    }

    if (std.mem.eql(u8, key_part, "enter")) {
        return vaxis.Key{ .codepoint = vaxis.Key.enter, .mods = mods };
    } else if (std.mem.eql(u8, key_part, "tab")) {
        return vaxis.Key{ .codepoint = vaxis.Key.tab, .mods = mods };
    } else if (std.mem.eql(u8, key_part, "backspace")) {
        return vaxis.Key{ .codepoint = vaxis.Key.backspace, .mods = mods };
    } else if (std.mem.eql(u8, key_part, "up")) {
        return vaxis.Key{ .codepoint = vaxis.Key.up, .mods = mods };
    } else if (std.mem.eql(u8, key_part, "down")) {
        return vaxis.Key{ .codepoint = vaxis.Key.down, .mods = mods };
    } else if (std.mem.eql(u8, key_part, "left")) {
        return vaxis.Key{ .codepoint = vaxis.Key.left, .mods = mods };
    } else if (std.mem.eql(u8, key_part, "right")) {
        return vaxis.Key{ .codepoint = vaxis.Key.right, .mods = mods };
    } else if (key_part.len == 1) {
        return vaxis.Key{ .codepoint = key_part[0], .mods = mods };
    }

    return null;
}

fn parseKeyToHash(key_str: []const u8) ?u64 {
    const key = parseKeyString(key_str) orelse return null;
    return KeyHash.fromKey(key).toU64();
}

pub const ModeKeymap = struct {
    chat: std.AutoHashMap(u64, KeyAction),
    llm: std.AutoHashMap(u64, KeyAction),
    chat_list: std.AutoHashMap(u64, KeyAction),

    pub fn deinit(self: *ModeKeymap) void {
        self.chat.deinit();
        self.llm.deinit();
        self.chat_list.deinit();
    }

    pub fn get(self: *const ModeKeymap, mode: InputMode) *const std.AutoHashMap(u64, KeyAction) {
        return switch (mode) {
            .chat => &self.chat,
            .llm => &self.llm,
            .chat_list => &self.chat_list,
        };
    }
};

pub fn buildModeKeymap(alloc: std.mem.Allocator, keybindings: KeyBindings) !ModeKeymap {
    var chat_keymap = std.AutoHashMap(u64, KeyAction).init(alloc);
    var llm_keymap = std.AutoHashMap(u64, KeyAction).init(alloc);
    var chat_list_keymap = std.AutoHashMap(u64, KeyAction).init(alloc);

    const global_bindings = [_]struct { key: []const u8, action: KeyAction }{
        .{ .key = keybindings.quit, .action = .quit },
        .{ .key = keybindings.quit_ctrl, .action = .quit },
        .{ .key = keybindings.switch_mode, .action = .switch_mode },
        .{ .key = keybindings.select, .action = .select },
        .{ .key = keybindings.backspace, .action = .delete_char },
        .{ .key = keybindings.reload_config, .action = .reload_config },
        .{ .key = keybindings.load_more_messages, .action = .load_more_messages },
    };

    for (global_bindings) |binding| {
        if (parseKeyToHash(binding.key)) |hash| {
            try chat_keymap.put(hash, binding.action);
            try llm_keymap.put(hash, binding.action);
            try chat_list_keymap.put(hash, binding.action);
        }
    }

    if (parseKeyToHash(keybindings.scroll_up)) |hash| {
        try chat_keymap.put(hash, .scroll_up);
        try llm_keymap.put(hash, .scroll_up);
        try chat_list_keymap.put(hash, .navigate_up);
    }
    if (parseKeyToHash(keybindings.scroll_down)) |hash| {
        try chat_keymap.put(hash, .scroll_down);
        try llm_keymap.put(hash, .scroll_down);
        try chat_list_keymap.put(hash, .navigate_down);
    }

    if (parseKeyToHash(keybindings.navigate_up)) |hash| {
        try chat_list_keymap.put(hash, .navigate_up);
    }
    if (parseKeyToHash(keybindings.navigate_up_alt)) |hash| {
        try chat_list_keymap.put(hash, .navigate_up);
    }
    if (parseKeyToHash(keybindings.navigate_down)) |hash| {
        try chat_list_keymap.put(hash, .navigate_down);
    }
    if (parseKeyToHash(keybindings.navigate_down_alt)) |hash| {
        try chat_list_keymap.put(hash, .navigate_down);
    }

    return ModeKeymap{
        .chat = chat_keymap,
        .llm = llm_keymap,
        .chat_list = chat_list_keymap,
    };
}

pub fn getKeyAction(keymap: *const ModeKeymap, mode: InputMode, key: vaxis.Key) KeyAction {
    const hash = KeyHash.fromKey(key).toU64();
    return keymap.get(mode).get(hash) orelse .none;
}
