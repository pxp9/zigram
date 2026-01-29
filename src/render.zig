const std = @import("std");
const vaxis = @import("vaxis");
const auth = @import("auth.zig");
const telegram = @import("telegram.zig");
const keybindings = @import("keybindings.zig");
const ai = @import("ai.zig");
const utils = @import("utils.zig");

const libc = @cImport({
    @cInclude("time.h");
});

const TextView = vaxis.widgets.TextView;
const TextViewBuffer = TextView.Buffer;
const TextInput = vaxis.widgets.TextInput;

pub const MAX_MESSAGE_LENGTH = 2048;

fn formatTimestamp(alloc: std.mem.Allocator, timestamp: i64, format: []const u8) ![]const u8 {
    // Convert to time_t for C
    const time_val: libc.time_t = @intCast(timestamp);

    // Convert to struct tm
    const tm_ptr = libc.localtime(&time_val);
    if (tm_ptr == null) {
        std.log.err("Failed to convert timestamp. Using default format.", .{});
        return std.fmt.allocPrint(alloc, "??:??", .{});
    }

    // Create null-terminated format string for C
    const format_z = try alloc.dupeZ(u8, format);
    defer alloc.free(format_z);

    // Use strftime to format the timestamp
    var buf: [128]u8 = undefined;
    const len = libc.strftime(&buf, buf.len, format_z.ptr, tm_ptr);

    if (len == 0) {
        std.log.err("Invalid datetime_format '{s}'. Using default format.", .{format});
        // Fallback to manual formatting
        const tm = tm_ptr.*;
        return std.fmt.allocPrint(alloc, "{d:0>2}:{d:0>2}", .{ tm.tm_hour, tm.tm_min });
    }

    return try alloc.dupe(u8, buf[0..len]);
}

fn stripVariationSelectors(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);

    var i: usize = 0;
    while (i < text.len) {
        // VS16 (U+FE0F) = 0xEF 0xB8 0x8F (emoji presentation)
        // VS15 (U+FE0E) = 0xEF 0xB8 0x8E (text presentation)
        if (i + 2 < text.len and text[i] == 0xEF and text[i + 1] == 0xB8 and (text[i + 2] == 0x8F or text[i + 2] == 0x8E)) {
            i += 3;
            continue;
        }
        try result.append(alloc, text[i]);
        i += 1;
    }

    return try result.toOwnedSlice(alloc);
}

fn displayWidthWithMethod(text: []const u8, method: vaxis.gwidth.Method) usize {
    return vaxis.gwidth.gwidth(text, method);
}

fn renderAiPanel(
    alloc: std.mem.Allocator,
    render_alloc: std.mem.Allocator,
    win: vaxis.Window,
    state: *AppState,
    chat_list_width: usize,
    chat_width: usize,
    llm_chat_width: usize,
    panel_height: usize,
    width_method: vaxis.gwidth.Method,
) !vaxis.Window {
    const llm_panel = win.child(.{
        .x_off = @intCast(chat_list_width + chat_width),
        .y_off = 1,
        .width = @intCast(llm_chat_width),
        .height = @intCast(panel_height),
        .border = .{
            .where = .all,
            .style = .{ .fg = .{ .index = 5 } },
        },
    });
    const llm_title = llm_panel.child(.{
        .x_off = 2,
        .y_off = 1,
    });
    _ = llm_title.printSegment(.{
        .text = "AI Assistant",
        .style = .{ .bold = true, .fg = .{ .index = 5 } },
    }, .{});

    const llm_messages_height = if (panel_height > 6) panel_height - 8 else 1;
    const llm_messages_window = llm_panel.child(.{
        .x_off = 2,
        .y_off = 3,
        .width = @intCast(if (llm_chat_width > 4) llm_chat_width - 4 else 1),
        .height = @intCast(llm_messages_height),
    });

    state.llm_text_buffer.clear(alloc);

    var char_count: usize = 0;
    const panel_width = if (llm_chat_width > 6) llm_chat_width - 6 else 1;

    for (state.llm_messages.items) |msg| {
        const clean_msg = stripVariationSelectors(render_alloc, msg) catch msg;
        const wrapped = wrapText(render_alloc, clean_msg, panel_width, width_method) catch continue;
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

    state.llm_text_view.draw(llm_messages_window, state.llm_text_buffer.*);

    const llm_input_y = if (panel_height > 5) panel_height - 5 else 1;

    const llm_prompt_win = llm_panel.child(.{
        .x_off = 2,
        .y_off = @intCast(llm_input_y + 1),
    });
    const llm_prompt_style = if (state.active_mode.* == .llm)
        vaxis.Style{ .fg = .{ .index = 5 }, .bold = true }
    else
        vaxis.Style{ .fg = .{ .index = 8 } };
    _ = llm_prompt_win.printSegment(.{ .text = "> ", .style = llm_prompt_style }, .{});

    const llm_input_width = if (llm_chat_width > 6) llm_chat_width - 6 else 1;

    const llm_input_win = llm_panel.child(.{
        .x_off = 4,
        .y_off = @intCast(llm_input_y),
        .width = @intCast(llm_input_width),
        .height = 3,
        .border = .{
            .where = .all,
            .style = .{ .fg = .{ .index = 5 } },
        },
    });

    return llm_input_win;
}

fn wrapText(alloc: std.mem.Allocator, text: []const u8, width: usize, method: vaxis.gwidth.Method) ![]const u8 {
    if (width == 0) return try alloc.dupe(u8, text);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;

    while (lines.next()) |line| {
        if (!first_line) {
            try result.append(alloc, '\n');
        }
        first_line = false;

        if (line.len == 0) continue;

        var line_col: usize = 0;
        var line_start: usize = 0;
        var last_space: ?usize = null;

        var giter = vaxis.unicode.GraphemeIterator.init(line);
        while (giter.next()) |grapheme| {
            const grapheme_bytes = grapheme.bytes(line);
            const grapheme_width = vaxis.gwidth.gwidth(grapheme_bytes, method);
            const grapheme_end = grapheme.start + grapheme.len;

            if (grapheme_bytes.len == 1 and grapheme_bytes[0] == ' ') {
                last_space = grapheme.start;
            }

            if (line_col + grapheme_width > width and line_col > 0) {
                if (last_space) |space_pos| {
                    if (space_pos > line_start) {
                        try result.appendSlice(alloc, line[line_start..space_pos]);
                        try result.append(alloc, '\n');
                        line_start = space_pos + 1;
                        line_col = displayWidthWithMethod(line[line_start..grapheme_end], method);
                        last_space = null;
                        continue;
                    }
                }
                try result.appendSlice(alloc, line[line_start..grapheme.start]);
                try result.append(alloc, '\n');
                line_start = grapheme.start;
                line_col = grapheme_width;
                last_space = null;
                continue;
            }

            line_col += grapheme_width;
        }

        if (line_start < line.len) {
            try result.appendSlice(alloc, line[line_start..]);
        }
    }

    return try result.toOwnedSlice(alloc);
}

pub const InputMode = utils.InputMode;
pub const AppState = utils.AppState;

fn renderChatMessages(
    alloc: std.mem.Allocator,
    render_alloc: std.mem.Allocator,
    state: *AppState,
    chat_width: usize,
    width_method: vaxis.gwidth.Method,
) !void {
    if (state.chats.items.len == 0) return;

    const selected_chat = state.chats.items[state.selected_chat_idx.*];
    const messages_opt = state.chat_messages_cache.get(selected_chat.id);

    // If loading and no messages cached yet, show loading message
    if (state.loading_messages.* and messages_opt == null) {
        const loading_text = "Loading messages...";
        try state.chat_text_buffer.append(alloc, .{ .bytes = loading_text });
        try state.chat_text_buffer.updateStyle(alloc, .{
            .begin = 0,
            .end = loading_text.len,
            .style = .{ .italic = true, .fg = .{ .index = 3 } },
        });
        return;
    }

    if (messages_opt == null) {
        const prompt_text = "Press Enter to load messages";
        try state.chat_text_buffer.append(alloc, .{ .bytes = prompt_text });
        try state.chat_text_buffer.updateStyle(alloc, .{
            .begin = 0,
            .end = prompt_text.len,
            .style = .{ .italic = true, .fg = .{ .index = 6 } },
        });
        return;
    }

    const messages = messages_opt.?;
    if (messages.items.len == 0) {
        const no_msg_text = "No messages";
        try state.chat_text_buffer.append(alloc, .{ .bytes = no_msg_text });
        try state.chat_text_buffer.updateStyle(alloc, .{
            .begin = 0,
            .end = no_msg_text.len,
            .style = .{ .italic = true, .fg = .{ .index = 8 } },
        });
        return;
    }

    // Show loading indicator at the top if loading more messages
    var char_offset: usize = 0;
    if (state.loading_messages.*) {
        const loading_text = "Loading older messages...\n";
        try state.chat_text_buffer.append(alloc, .{ .bytes = loading_text });
        try state.chat_text_buffer.updateStyle(alloc, .{
            .begin = 0,
            .end = loading_text.len,
            .style = .{ .italic = true, .fg = .{ .index = 3 } },
        });
        char_offset = loading_text.len;
    }

    const chat_panel_width = if (chat_width > 8) chat_width - 8 else 1;
    for (messages.items) |msg| {
        const time_str = formatTimestamp(render_alloc, msg.timestamp, state.app_config.datetime_format) catch "??:??";
        const clean_sender = stripVariationSelectors(render_alloc, msg.sender_name) catch msg.sender_name;
        const clean_content = stripVariationSelectors(render_alloc, msg.content) catch msg.content;
        const msg_text = std.fmt.allocPrint(render_alloc, "[{s}] {s}: {s}", .{ time_str, clean_sender, clean_content }) catch continue;
        const wrapped = wrapText(render_alloc, msg_text, chat_panel_width, width_method) catch continue;
        const display_text = std.fmt.allocPrint(render_alloc, "{s}\n", .{wrapped}) catch continue;
        state.chat_text_buffer.append(alloc, .{ .bytes = display_text }) catch continue;
    }
}

pub fn render(alloc: std.mem.Allocator, state: *AppState) !void {
    var render_arena = std.heap.ArenaAllocator.init(alloc);
    defer render_arena.deinit();
    const render_alloc = render_arena.allocator();

    const win = state.vx.window();
    win.clear();

    const width_method = state.vx.caps.unicode;

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
    const ai_enabled = state.ai_enabled.*;
    const chat_list_width = @max(width / 4, min_chat_list_width); // 25% for chat list, minimum 20
    const chat_width = if (ai_enabled) width / 2 else (width * 3 / 4);
    const llm_chat_width = if (ai_enabled)
        width - chat_list_width - chat_width
    else
        0;

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

    const chat_list_content_height = if (panel_height > 3) panel_height - 3 else 1;
    const chat_list_content = chat_list_panel.child(.{
        .x_off = 1,
        .y_off = 2,
        .width = if (chat_list_width > 2) chat_list_width - 2 else 1,
        .height = chat_list_content_height,
    });
    chat_list_content.fill(.{ .char = .{ .grapheme = " " } });

    state.chat_list_text_buffer.clear(alloc);

    if (state.chats.items.len == 0) {
        const no_chats_text = "No chats";
        try state.chat_list_text_buffer.append(alloc, .{ .bytes = no_chats_text });
        try state.chat_list_text_buffer.updateStyle(alloc, .{
            .begin = 0,
            .end = no_chats_text.len,
            .style = .{ .italic = true, .fg = .{ .index = 8 } },
        });
    } else {
        const max_name_width = if (chat_list_width > 4) chat_list_width - 4 else 1;

        for (state.chats.items, 0..) |chat, idx| {
            const is_selected = idx == state.selected_chat_idx.*;

            const clean_title = stripVariationSelectors(render_alloc, chat.title) catch chat.title;
            const wrapped_title = wrapText(render_alloc, clean_title, max_name_width, width_method) catch clean_title;

            const prefix = if (is_selected) "> " else "  ";
            const entry_text = std.fmt.allocPrint(render_alloc, "{s}{s}\n", .{ prefix, wrapped_title }) catch continue;

            const start_pos = state.chat_list_text_buffer.content.items.len;
            state.chat_list_text_buffer.append(alloc, .{ .bytes = entry_text }) catch continue;

            if (is_selected) {
                state.chat_list_text_buffer.updateStyle(alloc, .{
                    .begin = start_pos,
                    .end = start_pos + entry_text.len,
                    .style = .{ .bold = true, .fg = .{ .index = 3 }, .reverse = state.active_mode.* == .chat_list },
                }) catch continue;
            }
        }
    }

    state.chat_list_text_view.draw(chat_list_content, state.chat_list_text_buffer.*);

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
        const current_chat_name = state.chats.items[state.selected_chat_idx.*].title;
        const clean_chat_name = stripVariationSelectors(render_alloc, current_chat_name) catch current_chat_name;
        const chat_title_text = try std.fmt.allocPrint(render_alloc, "Chat: {s}", .{clean_chat_name});
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

    state.chat_text_buffer.clear(alloc);
    try renderChatMessages(alloc, render_alloc, state, chat_width, width_method);

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

    const llm_input_win = if (ai_enabled)
        try renderAiPanel(alloc, render_alloc, win, state, chat_list_width, chat_width, llm_chat_width, panel_height, width_method)
    else
        undefined;

    const mode_text = switch (state.active_mode.*) {
        .chat => "[CHAT]",
        .llm => "[AI]",
        .chat_list => "[SELECT]",
    };

    const mode_color = switch (state.active_mode.*) {
        .chat => vaxis.Color{ .index = 2 }, // Green - matches chat border
        .llm => vaxis.Color{ .index = 5 }, // Magenta - matches LLM border
        .chat_list => vaxis.Color{ .index = 4 }, // Blue - matches chat list border
    };

    var help_buf: [512]u8 = undefined;
    const mode_help = switch (state.active_mode.*) {
        .chat, .llm => try std.fmt.bufPrint(&help_buf, "{s}: Switch | {s}: Send | {s}: Delete | {s}: Load More", .{ state.keybindings.*.switch_mode, state.keybindings.*.select, state.keybindings.*.backspace, state.keybindings.*.load_more_messages }),
        .chat_list => try std.fmt.bufPrint(&help_buf, "{s}: Switch | {s}/{s}: Up | {s}/{s}: Down | {s}: Select", .{ state.keybindings.*.switch_mode, state.keybindings.*.navigate_up, state.keybindings.*.navigate_up_alt, state.keybindings.*.navigate_down, state.keybindings.*.navigate_down_alt, state.keybindings.*.select }),
    };

    var status_buf: [512]u8 = undefined;
    const status_rest = try std.fmt.bufPrint(&status_buf, " | {s} | {s}/{s}: Quit | {s}: Reload | Terminal: {d}x{d}", .{ mode_help, state.keybindings.*.quit, state.keybindings.*.quit_ctrl, state.keybindings.*.reload_config, width, height });
    const status_win = win.child(.{
        .x_off = 1,
        .y_off = @intCast(height - 1),
    });
    var col: u16 = 0;
    const r1 = status_win.printSegment(.{
        .text = "Mode: ",
        .style = .{ .italic = true, .fg = .{ .index = 8 } }, // Gray
    }, .{});
    col += r1.col;
    const r2 = status_win.printSegment(.{
        .text = mode_text,
        .style = .{ .bold = true, .fg = mode_color },
    }, .{ .col_offset = col });
    col += r2.col;
    _ = status_win.printSegment(.{
        .text = status_rest,
        .style = .{ .italic = true, .fg = .{ .index = 8 } }, // Gray
    }, .{ .col_offset = col });

    if (state.active_mode.* == .chat) {
        if (ai_enabled) state.llm_input.draw(llm_input_win);
        state.chat_input.draw(input_win);
    } else if (state.active_mode.* == .llm) {
        state.chat_input.draw(input_win);
        if (ai_enabled) state.llm_input.draw(llm_input_win);
    } else {
        state.chat_input.draw(input_win);
        if (ai_enabled) state.llm_input.draw(llm_input_win);
        win.hideCursor();
    }

    try state.vx.render(state.tty.writer());
}
