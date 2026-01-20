const std = @import("std");
const vaxis = @import("vaxis");
const auth = @import("auth.zig");
const telegram = @import("telegram.zig");
const keybindings = @import("keybindings.zig");
const ai = @import("ai.zig");

const TextView = vaxis.widgets.TextView;
const TextViewBuffer = TextView.Buffer;
const TextInput = vaxis.widgets.TextInput;

pub const MAX_MESSAGE_LENGTH = 2048;

fn formatTimestamp(alloc: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const epoch_seconds: u64 = @intCast(timestamp);
    const epoch_day = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day_seconds = epoch_day.getDaySeconds();
    const hours = day_seconds.getHoursIntoDay();
    const minutes = day_seconds.getMinutesIntoHour();
    return try std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}", .{ hours, minutes });
}

fn wrapText(alloc: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    if (width == 0) return try alloc.dupe(u8, text);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);

    var line_start: usize = 0;
    var last_space: ?usize = null;
    var col: usize = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];

        if (c == '\n') {
            try result.appendSlice(alloc, text[line_start..i + 1]);
            line_start = i + 1;
            col = 0;
            last_space = null;
            continue;
        }

        if (c == ' ' or c == '\t') {
            last_space = i;
        }

        col += 1;

        if (col >= width) {
            if (last_space) |space_pos| {
                if (space_pos > line_start) {
                    try result.appendSlice(alloc, text[line_start..space_pos]);
                    try result.append(alloc, '\n');
                    line_start = space_pos + 1;
                    i = space_pos;
                    col = 0;
                    last_space = null;
                    continue;
                }
            }

            try result.appendSlice(alloc, text[line_start..i]);
            try result.append(alloc, '\n');
            line_start = i;
            col = 0;
            last_space = null;
        }
    }

    if (line_start < text.len) {
        try result.appendSlice(alloc, text[line_start..]);
    }

    return try result.toOwnedSlice(alloc);
}

pub const InputMode = enum {
    chat,
    llm,
    chat_list,
};

pub const RightPanelMode = enum {
    llm,
    logs,
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
    right_panel_mode: *RightPanelMode,
    llm_messages: *std.ArrayList([]const u8),
    llm_loading: *bool,
    log_messages: *std.ArrayList([]const u8),
    keybindings: *keybindings.KeyBindings,
    keymap: *std.AutoHashMap(u64, keybindings.KeyAction),
    telegram_queue: *telegram.TelegramQueue,
    ai_queue: *ai.AiQueue,
    chat_text_view: *TextView,
    chat_text_buffer: *TextViewBuffer,
    chat_input: *TextInput,
    llm_text_view: *TextView,
    llm_text_buffer: *TextViewBuffer,
    llm_input: *TextInput,
    ai_config: *ai.Config,
};

pub fn render(alloc: std.mem.Allocator, state: *const AppState) !void {
    var render_arena = std.heap.ArenaAllocator.init(alloc);
    defer render_arena.deinit();
    const render_alloc = render_arena.allocator();

    const win = state.vx.window();
    win.clear();

    const width = win.width;
    const height = win.height;

    var title_buf: [256]u8 = undefined;
    const user_display = if (state.user.username) |username|
        try std.fmt.bufPrint(&title_buf, "Zigram - Logged as: {s} (@{s})", .{ state.user.first_name, username })
    else
        try std.fmt.bufPrint(&title_buf, "Zigram - Logged as: {s} {s}", .{ state.user.first_name, state.user.last_name });

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

    const panel_height = if (height > 4) height - 2 else 2; // Minimum height of 2 for at least border
    const min_chat_list_width = 20; // Minimum width for chat list
    const chat_list_width = @max(width / 4, min_chat_list_width); // 25% for chat list, minimum 20
    const chat_width = width / 2; // 50% for main chat
    const llm_chat_width = if (width > chat_list_width + chat_width)
        width - chat_list_width - chat_width
    else
        0; // Remaining for LLM chat

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
    const chat_list_title_text = if (state.active_mode.* == .chat_list) "Chat List [ACTIVE]" else "Chat List";
    const chat_list_border_style: vaxis.Style = if (state.active_mode.* == .chat_list)
        .{ .bold = true, .fg = .{ .index = 3 }, .reverse = true } // Yellow and highlighted
    else
        .{ .bold = true, .fg = .{ .index = 6 } }; // Cyan
    _ = chat_list_title.printSegment(.{
        .text = chat_list_title_text,
        .style = chat_list_border_style,
    }, .{});

    const chat_list_content = chat_list_panel.child(.{
        .x_off = 1,
        .y_off = 2,
        .width = if (chat_list_width > 2) chat_list_width - 2 else 1,
        .height = if (panel_height > 3) panel_height - 3 else 1,
    });
    chat_list_content.fill(.{ .char = .{ .grapheme = " " } });

    if (state.chats.items.len == 0) {
        const no_chats_win = chat_list_panel.child(.{
            .x_off = 2,
            .y_off = 3,
        });
        _ = no_chats_win.printSegment(.{
            .text = "No chats",
            .style = .{ .fg = .{ .index = 8 } }, // Gray
        }, .{});
    } else {
        var idx: usize = 0;
        while (idx < state.chats.items.len) : (idx += 1) {
            const chat = state.chats.items[idx];
            const item_y = 3 + idx;

            if (item_y < panel_height - 1) {
                const is_selected = idx == state.selected_chat_idx.*;
                const chat_style: vaxis.Style = if (is_selected)
                    .{ .bold = true, .fg = .{ .index = 3 }, .reverse = state.active_mode.* == .chat_list }
                else
                    .{};

                const prefix_win = chat_list_panel.child(.{
                    .x_off = 2,
                    .y_off = @intCast(item_y),
                });
                const prefix = if (is_selected) "> " else "  ";
                _ = prefix_win.printSegment(.{
                    .text = prefix,
                    .style = chat_style,
                }, .{});

                const max_name_width = if (chat_list_width > 6) chat_list_width - 6 else 1;

                const truncated_chat = if (chat.title.len > max_name_width)
                    chat.title[0..max_name_width]
                else
                    chat.title;

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

    const chat_title_win = chat_panel.child(.{
        .x_off = 2,
        .y_off = 1,
    });

    if (state.chats.items.len > 0) {
        var chat_title_buf: [128]u8 = undefined;
        const current_chat_name = state.chats.items[state.selected_chat_idx.*].title;
        const chat_title_text = try std.fmt.bufPrint(&chat_title_buf, "Chat: {s}", .{current_chat_name});
        _ = chat_title_win.printSegment(.{
            .text = chat_title_text,
            .style = .{ .bold = true, .fg = .{ .index = 2 } }, // Green
        }, .{});
    } else {
        _ = chat_title_win.printSegment(.{
            .text = "No chat selected",
            .style = .{ .bold = true, .fg = .{ .index = 8 } }, // Gray
        }, .{});
    }

    const messages_start_y: u16 = 3;
    const messages_height = if (panel_height > 6) panel_height - 8 else 1;
    const messages_window = chat_panel.child(.{
        .x_off = 2,
        .y_off = messages_start_y,
        .width = if (chat_width > 4) chat_width - 4 else 1,
        .height = messages_height,
    });

    if (state.loading_messages.*) {
        const loading_text = "Loading messages...";
        try state.chat_text_buffer.append(alloc, .{ .bytes = loading_text });
        try state.chat_text_buffer.updateStyle(alloc, .{
            .begin = 0,
            .end = loading_text.len,
            .style = .{ .italic = true, .fg = .{ .index = 3 } },
        });
    } else if (state.chats.items.len > 0) {
        state.chat_text_buffer.clear(alloc);
        const selected_chat = state.chats.items[state.selected_chat_idx.*];
        const messages_opt = state.chat_messages_cache.get(selected_chat.id);

        if (messages_opt) |messages| {
            if (messages.items.len == 0) {
                const no_msg_text = "No messages";
                try state.chat_text_buffer.append(alloc, .{ .bytes = no_msg_text });
                try state.chat_text_buffer.updateStyle(alloc, .{
                    .begin = 0,
                    .end = no_msg_text.len,
                    .style = .{ .italic = true, .fg = .{ .index = 8 } },
                });
            } else {
                state.chat_text_buffer.clear(alloc);
                const chat_panel_width = if (chat_width > 8) chat_width - 8 else 1;
                for (messages.items) |msg| {
                    const time_str = formatTimestamp(render_alloc, msg.timestamp) catch "??:??";
                    const msg_text = std.fmt.allocPrint(render_alloc, "[{s}] {s}: {s}", .{ time_str, msg.sender_name, msg.content }) catch continue;
                    const wrapped = wrapText(render_alloc, msg_text, chat_panel_width) catch continue;
                    const display_text = std.fmt.allocPrint(render_alloc, "{s}\n", .{wrapped}) catch continue;
                    state.chat_text_buffer.append(alloc, .{ .bytes = display_text }) catch continue;
                }
            }
        } else {
            const prompt_text = "Press Enter to load messages";
            try state.chat_text_buffer.append(alloc, .{ .bytes = prompt_text });
            try state.chat_text_buffer.updateStyle(alloc, .{
                .begin = 0,
                .end = prompt_text.len,
                .style = .{ .italic = true, .fg = .{ .index = 6 } },
            });
        }
    }

    state.chat_text_view.draw(messages_window, state.chat_text_buffer.*);

    const input_y = if (panel_height > 5) panel_height - 5 else 1;

    const prompt_win = chat_panel.child(.{
        .x_off = 2,
        .y_off = input_y + 1,
    });
    const prompt_style = if (state.active_mode.* == .chat)
        vaxis.Style{ .fg = .{ .index = 2 }, .bold = true } // Green, bold
    else
        vaxis.Style{ .fg = .{ .index = 8 } }; // Gray
    _ = prompt_win.printSegment(.{ .text = "> ", .style = prompt_style }, .{});

    const input_width = if (chat_width > 6) chat_width - 6 else 1;

    const input_win = chat_panel.child(.{
        .x_off = 4, // After "> "
        .y_off = input_y,
        .width = input_width,
        .height = 3, // Explicit height for border + content
        .border = .{
            .where = .all,
            .style = .{ .fg = .{ .index = 2 } },
        },
    });

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
    const panel_title = if (state.right_panel_mode.* == .llm) "AI Assistant" else "Logs";
    _ = llm_title.printSegment(.{
        .text = panel_title,
        .style = .{ .bold = true, .fg = .{ .index = 5 } }, // Magenta
    }, .{});

    const llm_messages_height = if (panel_height > 6) panel_height - 8 else 1;
    const llm_messages_window = llm_panel.child(.{
        .x_off = 2,
        .y_off = 3,
        .width = if (llm_chat_width > 4) llm_chat_width - 4 else 1,
        .height = llm_messages_height,
    });

    state.llm_text_buffer.clear(alloc);

    if (state.right_panel_mode.* == .llm) {
        var char_count: usize = 0;
        const panel_width = if (llm_chat_width > 6) llm_chat_width - 6 else 1;

        for (state.llm_messages.items) |msg| {
            const wrapped = wrapText(render_alloc, msg, panel_width) catch continue;
            const display_text = std.fmt.allocPrint(render_alloc, "{s}\n", .{wrapped}) catch continue;
            char_count += display_text.len;
            state.llm_text_buffer.append(alloc, .{ .bytes = display_text }) catch continue;
        }

        if (state.llm_loading.*) {
            const loading_text = "\nLoading...";
            try state.llm_text_buffer.append(alloc, .{ .bytes = loading_text });
            try state.llm_text_buffer.updateStyle(alloc, .{
                .begin = char_count,
                .end = char_count + loading_text.len,
                .style = .{ .italic = true, .fg = .{ .index = 3 } },
            });
        }
    } else {
        for (state.log_messages.items) |msg| {
            const display_text = std.fmt.allocPrint(render_alloc, "{s}\n", .{msg}) catch continue;
            state.llm_text_buffer.append(alloc, .{ .bytes = display_text }) catch continue;
        }
    }

    state.llm_text_view.draw(llm_messages_window, state.llm_text_buffer.*);

    const llm_input_y = if (panel_height > 5) panel_height - 5 else 1;

    const llm_prompt_win = llm_panel.child(.{
        .x_off = 2,
        .y_off = llm_input_y + 1,
    });
    const llm_prompt_style = if (state.active_mode.* == .llm)
        vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }
    else
        vaxis.Style{ .fg = .{ .index = 8 } }; // Gray
    _ = llm_prompt_win.printSegment(.{ .text = "> ", .style = llm_prompt_style }, .{});

    const llm_input_width = if (llm_chat_width > 6) llm_chat_width - 6 else 1;

    const llm_input_win = llm_panel.child(.{
        .x_off = 4, // After "> "
        .y_off = @intCast(llm_input_y),
        .width = llm_input_width,
        .height = 3, // Explicit height for border + content
        .border = .{
            .where = .all,
            .style = .{ .fg = .{ .index = 5 } },
        },
    });

    const mode_text = switch (state.active_mode.*) {
        .chat => "[CHAT]",
        .llm => "[AI]",
        .chat_list => "[SELECT]",
    };

    var help_buf: [256]u8 = undefined;
    const mode_help = switch (state.active_mode.*) {
        .chat, .llm => try std.fmt.bufPrint(&help_buf, "{s}: Switch | {s}: Send | {s}: Delete", .{ state.keybindings.*.switch_mode, state.keybindings.*.select, state.keybindings.*.backspace }),
        .chat_list => try std.fmt.bufPrint(&help_buf, "{s}: Switch | {s}/{s}: Up | {s}/{s}: Down | {s}: Select", .{ state.keybindings.*.switch_mode, state.keybindings.*.navigate_up, state.keybindings.*.navigate_up_alt, state.keybindings.*.navigate_down, state.keybindings.*.navigate_down_alt, state.keybindings.*.select }),
    };

    var status_buf: [512]u8 = undefined;
    const status = try std.fmt.bufPrint(&status_buf, "Mode: {s} | {s} | {s}/{s}: Quit | {s}: Reload | Terminal: {d}x{d}", .{ mode_text, mode_help, state.keybindings.*.quit, state.keybindings.*.quit_ctrl, state.keybindings.*.reload_config, width, height });
    const status_win = win.child(.{
        .x_off = 1,
        .y_off = @intCast(height - 1),
    });
    _ = status_win.printSegment(.{
        .text = status,
        .style = .{ .italic = true, .fg = .{ .index = 8 } }, // Gray
    }, .{});

    if (state.active_mode.* == .chat) {
        state.llm_input.draw(llm_input_win);
        state.chat_input.draw(input_win);
    } else if (state.active_mode.* == .llm) {
        state.chat_input.draw(input_win);
        state.llm_input.draw(llm_input_win);
    } else {
        state.chat_input.draw(input_win);
        state.llm_input.draw(llm_input_win);
        win.hideCursor();
    }

    try state.vx.render(state.tty.writer());
}
