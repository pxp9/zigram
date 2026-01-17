const std = @import("std");
const vaxis = @import("vaxis");
const auth = @import("auth.zig");
const telegram = @import("telegram.zig");
const keybindings = @import("keybindings.zig");

pub const MAX_MESSAGE_LENGTH = 2048;

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
    chat_input_buf: *[MAX_MESSAGE_LENGTH]u8,
    chat_input_len: *usize,
    llm_input_buf: []u8,
    llm_input_len: *usize,
    llm_messages: *std.ArrayList([]const u8),
    log_messages: *std.ArrayList([]const u8),
    keybindings: *keybindings.KeyBindings,
    keymap: *std.AutoHashMap(u64, keybindings.KeyAction),
    telegram_queue: *telegram.TelegramQueue,
};

pub fn render(alloc: std.mem.Allocator, state: *const AppState) !void {
    // Create arena allocator for this render cycle
    var render_arena = std.heap.ArenaAllocator.init(alloc);
    defer render_arena.deinit();
    const render_alloc = render_arena.allocator();

    // Get the root window (this is automatically full screen)
    const win = state.vx.window();
    win.clear();

    // Get window dimensions
    const width = win.width;
    const height = win.height;

    // Draw title bar with user info
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
    const chat_list_title_text = if (state.active_mode.* == .chat_list) "Chat List [ACTIVE]" else "Chat List";
    const chat_list_border_style: vaxis.Style = if (state.active_mode.* == .chat_list)
        .{ .bold = true, .fg = .{ .index = 3 }, .reverse = true } // Yellow and highlighted
    else
        .{ .bold = true, .fg = .{ .index = 6 } }; // Cyan
    _ = chat_list_title.printSegment(.{
        .text = chat_list_title_text,
        .style = chat_list_border_style,
    }, .{});

    // Clear the content area of chat list panel to prevent artifacts
    const chat_list_content = chat_list_panel.child(.{
        .x_off = 1,
        .y_off = 2,
        .width = if (chat_list_width > 2) chat_list_width - 2 else 1,
        .height = if (panel_height > 3) panel_height - 3 else 1,
    });
    chat_list_content.fill(.{ .char = .{ .grapheme = " " } });

    // Display chat list with selection or "No chats" message
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
        // Using while loop with index since inline for doesn't work with runtime arrays
        var idx: usize = 0;
        while (idx < state.chats.items.len) : (idx += 1) {
            const chat = state.chats.items[idx];
            const item_y = 3 + idx;

            // Only render if item is within the panel bounds
            if (item_y < panel_height - 1) {
                const is_selected = idx == state.selected_chat_idx.*;
                const chat_style: vaxis.Style = if (is_selected)
                    .{ .bold = true, .fg = .{ .index = 3 }, .reverse = state.active_mode.* == .chat_list }
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

    if (state.chats.items.len > 0) {
        var chat_title_buf: [128]u8 = undefined;
        const current_chat_name = state.chats.items[state.selected_chat_idx.*].title;
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

    // Clear the content area of chat panel to prevent artifacts
    const chat_content = chat_panel.child(.{
        .x_off = 1,
        .y_off = 2,
        .width = if (chat_width > 2) chat_width - 2 else 1,
        .height = if (panel_height > 3) panel_height - 3 else 1,
    });
    chat_content.fill(.{ .char = .{ .grapheme = " " } });

    // Display chat messages (scrollable)
    if (state.loading_messages.*) {
        // Show "Loading messages..." while waiting
        const loading_item = chat_panel.child(.{
            .x_off = 2,
            .y_off = 3,
        });
        _ = loading_item.printSegment(.{
            .text = "Loading messages...",
            .style = .{ .fg = .{ .index = 3 }, .italic = true }, // Yellow, italic
        }, .{});
    } else if (state.chats.items.len > 0) {
        const selected_chat = state.chats.items[state.selected_chat_idx.*];
        const messages_opt = state.chat_messages_cache.get(selected_chat.id);

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
                // Simple rendering with panel boundary cropping
                var msg_y: usize = 3;
                const max_y = panel_height - 3; // Leave space for input at bottom

                for (messages.items) |msg| {
                    // Stop if we've reached the panel boundary
                    if (msg_y >= max_y) break;

                    // Simple one-line rendering
                    const display_text = std.fmt.allocPrint(render_alloc, "{s}: {s}", .{ msg.sender_name, msg.content }) catch "[error]";

                    const msg_item = chat_panel.child(.{
                        .x_off = 2,
                        .y_off = @intCast(msg_y),
                    });
                    _ = msg_item.printSegment(.{ .text = display_text }, .{});
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
    const chat_prompt = if (state.active_mode.* == .chat) "> " else "  ";
    _ = chat_input_label.printSegment(.{
        .text = chat_prompt,
        .style = .{ .bold = true, .fg = .{ .index = 2 } },
    }, .{});
    const chat_input_field = chat_panel.child(.{
        .x_off = 4,
        .y_off = @intCast(chat_input_y),
    });
    const input_style: vaxis.Style = if (state.active_mode.* == .chat)
        .{ .fg = .{ .index = 7 }, .reverse = true }
    else
        .{ .fg = .{ .index = 8 } };
    _ = chat_input_field.printSegment(.{
        .text = state.chat_input_buf[0..state.chat_input_len.*],
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
    const panel_title = if (state.right_panel_mode.* == .llm) "AI Assistant" else "Logs";
    _ = llm_title.printSegment(.{
        .text = panel_title,
        .style = .{ .bold = true, .fg = .{ .index = 5 } }, // Magenta
    }, .{});

    // Display LLM messages or Logs based on mode
    var llm_y: usize = 3;

    if (state.right_panel_mode.* == .llm) {
        for (state.llm_messages.items) |msg| {
            const llm_item = llm_panel.child(.{
                .x_off = 2,
                .y_off = @intCast(llm_y),
            });
            _ = llm_item.printSegment(.{ .text = msg }, .{});
            llm_y += 1;
        }
    } else {
        // Display logs without cropping
        for (state.log_messages.items) |msg| {
            const log_item = llm_panel.child(.{
                .x_off = 2,
                .y_off = @intCast(llm_y),
            });
            _ = log_item.printSegment(.{ .text = msg }, .{});
            llm_y += 1;
        }
    }

    // LLM input field
    const llm_input_y = if (panel_height > 3) panel_height - 3 else 1;
    const llm_input_label = llm_panel.child(.{
        .x_off = 2,
        .y_off = @intCast(llm_input_y),
    });
    const llm_prompt = if (state.active_mode.* == .llm) "> " else "  ";
    _ = llm_input_label.printSegment(.{
        .text = llm_prompt,
        .style = .{ .bold = true, .fg = .{ .index = 5 } },
    }, .{});
    const llm_input_field = llm_panel.child(.{
        .x_off = 4,
        .y_off = @intCast(llm_input_y),
    });
    const llm_input_style: vaxis.Style = if (state.active_mode.* == .llm)
        .{ .fg = .{ .index = 7 }, .reverse = true }
    else
        .{ .fg = .{ .index = 8 } };
    _ = llm_input_field.printSegment(.{
        .text = state.llm_input_buf[0..state.llm_input_len.*],
        .style = llm_input_style,
    }, .{});

    // Status bar at the bottom
    const mode_text = switch (state.active_mode.*) {
        .chat => "[CHAT]",
        .llm => "[AI]",
        .chat_list => "[SELECT]",
    };

    // Build help text using actual state.keybindings
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

    // Render the screen
    try state.vx.render(state.tty.writer());
}
