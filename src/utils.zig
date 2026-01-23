const std = @import("std");
const vaxis = @import("vaxis");
const telegram = @import("telegram.zig");
const ai = @import("ai.zig");
const tdlib = @import("tdlib.zig");
const auth = @import("auth.zig");
const keybindings = @import("keybindings.zig");

const TextView = vaxis.widgets.TextView;
const TextViewBuffer = TextView.Buffer;
const TextInput = vaxis.widgets.TextInput;

pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
    mouse: vaxis.Mouse,
    telegram_update: telegram.TelegramUpdate,
    ai_update: ai.AiUpdate,
};

pub const TelegramThreadContext = struct {
    client: *tdlib.Client,
    loop: *vaxis.Loop(Event),
    request_queue: *telegram.TelegramQueue,
    alloc: std.mem.Allocator,
};

pub const AiThreadContext = struct {
    config: *ai.Config,
    loop: *vaxis.Loop(Event),
    request_queue: *ai.AiQueue,
    alloc: std.mem.Allocator,
};

pub const InputMode = enum {
    chat,
    llm,
    chat_list,
};

pub const AppState = struct {
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    user: *auth.User,
    chats: *std.ArrayList(telegram.Chat),
    selected_chat_idx: *usize,
    chat_messages_cache: *std.AutoHashMap(i64, std.ArrayList(telegram.Message)),
    loading_messages: *bool,
    active_mode: *InputMode,
    llm_messages: *std.ArrayList([]const u8),
    llm_loading: *bool,
    keybindings: *keybindings.KeyBindings,
    keymap: *keybindings.ModeKeymap,
    telegram_queue: *telegram.TelegramQueue,
    ai_queue: *ai.AiQueue,
    chat_list_text_view: *TextView,
    chat_list_text_buffer: *TextViewBuffer,
    chat_text_view: *TextView,
    chat_text_buffer: *TextViewBuffer,
    chat_input: *TextInput,
    llm_text_view: *TextView,
    llm_text_buffer: *TextViewBuffer,
    llm_input: *TextInput,
    ai_config: *ai.Config,
    app_config: *keybindings.AppConfig,
};
