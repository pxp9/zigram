const std = @import("std");
const vaxis = @import("vaxis");

pub const KeyAction = enum {
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

pub const KeyBindings = struct {
    quit: []const u8,
    quit_ctrl: []const u8,
    switch_mode: []const u8,
    navigate_up: []const u8,
    navigate_up_alt: []const u8,
    navigate_down: []const u8,
    navigate_down_alt: []const u8,
    select: []const u8,
    backspace: []const u8,
    reload_config: []const u8,
    toggle_right_panel: []const u8,
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
            alloc.free(self.select);
            alloc.free(self.backspace);
            alloc.free(self.reload_config);
            alloc.free(self.toggle_right_panel);
        }
    }
};

// Default keybindings
pub const DEFAULT_QUIT = "q";
pub const DEFAULT_QUIT_CTRL = "ctrl+c";
pub const DEFAULT_SWITCH_MODE = "tab";
pub const DEFAULT_NAVIGATE_UP = "k";
pub const DEFAULT_NAVIGATE_UP_ALT = "up";
pub const DEFAULT_NAVIGATE_DOWN = "j";
pub const DEFAULT_NAVIGATE_DOWN_ALT = "down";
pub const DEFAULT_SELECT = "enter";
pub const DEFAULT_BACKSPACE = "backspace";
pub const DEFAULT_RELOAD_CONFIG = "ctrl+r";
pub const DEFAULT_TOGGLE_RIGHT_PANEL = "ctrl+l";

pub fn loadKeybindings(alloc: std.mem.Allocator) !KeyBindings {
    // Try to get HOME directory
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    const config_path = try std.fs.path.join(alloc, &[_][]const u8{ home, ".config", "zigram", "zigram.json" });
    defer alloc.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        // Config file doesn't exist, return defaults
        return KeyBindings{
            .quit = DEFAULT_QUIT,
            .quit_ctrl = DEFAULT_QUIT_CTRL,
            .switch_mode = DEFAULT_SWITCH_MODE,
            .navigate_up = DEFAULT_NAVIGATE_UP,
            .navigate_up_alt = DEFAULT_NAVIGATE_UP_ALT,
            .navigate_down = DEFAULT_NAVIGATE_DOWN,
            .navigate_down_alt = DEFAULT_NAVIGATE_DOWN_ALT,
            .select = DEFAULT_SELECT,
            .backspace = DEFAULT_BACKSPACE,
            .reload_config = DEFAULT_RELOAD_CONFIG,
            .toggle_right_panel = DEFAULT_TOGGLE_RIGHT_PANEL,
            .allocated = false,
        };
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
    defer parsed.deinit();

    var keybindings = KeyBindings{
        .quit = DEFAULT_QUIT,
        .quit_ctrl = DEFAULT_QUIT_CTRL,
        .switch_mode = DEFAULT_SWITCH_MODE,
        .navigate_up = DEFAULT_NAVIGATE_UP,
        .navigate_up_alt = DEFAULT_NAVIGATE_UP_ALT,
        .navigate_down = DEFAULT_NAVIGATE_DOWN,
        .navigate_down_alt = DEFAULT_NAVIGATE_DOWN_ALT,
        .select = DEFAULT_SELECT,
        .backspace = DEFAULT_BACKSPACE,
        .reload_config = DEFAULT_RELOAD_CONFIG,
        .toggle_right_panel = DEFAULT_TOGGLE_RIGHT_PANEL,
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
        if (kb_obj.object.get("toggle_right_panel")) |v| {
            keybindings.toggle_right_panel = try alloc.dupe(u8, v.string);
        } else {
            keybindings.toggle_right_panel = try alloc.dupe(u8, DEFAULT_TOGGLE_RIGHT_PANEL);
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
        keybindings.toggle_right_panel = try alloc.dupe(u8, DEFAULT_TOGGLE_RIGHT_PANEL);
    }

    return keybindings;
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

    // Parse modifiers
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

    // Parse key
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

pub fn buildKeymap(alloc: std.mem.Allocator, keybindings: KeyBindings) !std.AutoHashMap(u64, KeyAction) {
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

pub fn getKeyAction(keymap: *const std.AutoHashMap(u64, KeyAction), key: vaxis.Key) KeyAction {
    const hash = KeyHash.fromKey(key).toU64();
    return keymap.get(hash) orelse .none;
}
