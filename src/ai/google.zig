const std = @import("std");
const vaxis = @import("vaxis");
const ai = @import("../ai.zig");
const utils = @import("../utils.zig");

const AiUpdateKind = ai.AiUpdateKind;
const ConversationMessage = ai.ConversationMessage;
const ToolCall = ai.ToolCall;
const GoogleAiConfig = ai.GoogleAiConfig;

pub const default_model = "gemini-3-flash-preview";

pub fn listModels(alloc: std.mem.Allocator, config: *const GoogleAiConfig) ![]const u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const url = "https://generativelanguage.googleapis.com/v1beta/models";
    const uri = try std.Uri.parse(url);

    var allocating_writer = std.Io.Writer.Allocating.init(alloc);
    defer allocating_writer.deinit();

    const req = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_writer = &allocating_writer.writer,
        .extra_headers = &.{
            .{ .name = "x-goog-api-key", .value = config.api_key },
        },
    });

    const response_body = try allocating_writer.toOwnedSlice();

    if (req.status != .ok) {
        std.log.err("ListModels API request failed with status: {}", .{req.status});
        std.log.err("Response body: {s}", .{response_body});
        alloc.free(response_body);
        return error.ApiRequestFailed;
    }

    return response_body;
}

pub fn sendMessageStreaming(alloc: std.mem.Allocator, config: *const GoogleAiConfig, history: []const ConversationMessage, loop: *vaxis.Loop(utils.Event)) ![]const u8 {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const url = try std.fmt.allocPrint(alloc, "https://generativelanguage.googleapis.com/v1beta/models/{s}:streamGenerateContent?alt=sse", .{config.model});
    defer alloc.free(url);

    const contents_json = try buildContentsJson(alloc, history);
    defer alloc.free(contents_json);

    const escaped_system_prompt = try escapeJsonString(alloc, config.system_prompt);
    defer alloc.free(escaped_system_prompt);

    const request_body = try std.fmt.allocPrint(alloc,
        \\{{"systemInstruction":{{"parts":[{{"text":"{s}"}}]}},"contents":[{s}],"tools":[{{"functionDeclarations":[{{"name":"send_telegram_message","description":"Send a message to a Telegram chat by chat name","parameters":{{"type":"object","properties":{{"chat_name":{{"type":"string","description":"The name/title of the chat to send the message to"}},"message_text":{{"type":"string","description":"The text content of the message to send"}}}},"required":["chat_name","message_text"]}}}}]}}]}}
    , .{ escaped_system_prompt, contents_json });
    defer alloc.free(request_body);

    const uri = try std.Uri.parse(url);

    var allocating_writer = std.Io.Writer.Allocating.init(alloc);
    defer allocating_writer.deinit();

    const req = try client.fetch(.{
        .location = .{ .uri = uri },
        .method = .POST,
        .payload = request_body,
        .response_writer = &allocating_writer.writer,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-goog-api-key", .value = config.api_key },
        },
    });

    const response_body = try allocating_writer.toOwnedSlice();
    defer alloc.free(response_body);

    if (req.status != .ok) {
        std.log.err("AI API request failed with status: {}", .{req.status});
        std.log.err("Response body: {s}", .{response_body});
        return error.ApiRequestFailed;
    }

    var full_response: std.ArrayList(u8) = .empty;
    errdefer full_response.deinit(alloc);

    var line_iter = std.mem.splitSequence(u8, response_body, "\n");
    while (line_iter.next()) |line| {
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const json_data = line[6..];

        if (std.mem.eql(u8, json_data, "[DONE]")) break;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_data, .{}) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        const candidates = root.object.get("candidates") orelse continue;
        if (candidates.array.items.len == 0) continue;

        const candidate = candidates.array.items[0];
        const content = candidate.object.get("content") orelse continue;
        const parts = content.object.get("parts") orelse continue;
        if (parts.array.items.len == 0) continue;

        const part = parts.array.items[0];

        if (part.object.get("functionCall")) |func_call| {
            const func_name = func_call.object.get("name") orelse continue;
            if (std.mem.eql(u8, func_name.string, "send_telegram_message")) {
                const args = func_call.object.get("args") orelse continue;
                const chat_name = args.object.get("chat_name") orelse continue;
                const message_text = args.object.get("message_text") orelse continue;

                const tool_call = ToolCall{
                    .tool_name = try alloc.dupe(u8, func_name.string),
                    .chat_name = try alloc.dupe(u8, chat_name.string),
                    .message_text = try alloc.dupe(u8, message_text.string),
                };

                const tool_response = try std.fmt.allocPrint(alloc, "[Tool call: {s}]", .{func_name.string});
                try full_response.appendSlice(alloc, tool_response);
                alloc.free(tool_response);

                loop.postEvent(.{
                    .ai_update = .{
                        .kind = .tool_call,
                        .data = try alloc.dupe(u8, ""),
                        .tool_call = tool_call,
                    },
                });
                break;
            }
            continue;
        }

        if (part.object.get("text")) |text| {
            try full_response.appendSlice(alloc, text.string);

            const chunk = try alloc.dupe(u8, text.string);
            loop.postEvent(.{
                .ai_update = .{
                    .kind = .message_chunk,
                    .data = chunk,
                },
            });
        }
    }

    return try full_response.toOwnedSlice(alloc);
}

fn escapeJsonString(alloc: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    for (input) |c| {
        switch (c) {
            '"' => try result.appendSlice(alloc, "\\\""),
            '\\' => try result.appendSlice(alloc, "\\\\"),
            '\n' => try result.appendSlice(alloc, "\\n"),
            '\r' => try result.appendSlice(alloc, "\\r"),
            '\t' => try result.appendSlice(alloc, "\\t"),
            '\x08' => try result.appendSlice(alloc, "\\b"),
            '\x0C' => try result.appendSlice(alloc, "\\f"),
            else => try result.append(alloc, c),
        }
    }

    return try result.toOwnedSlice(alloc);
}

fn buildContentsJson(alloc: std.mem.Allocator, history: []const ConversationMessage) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    for (history, 0..) |msg, i| {
        if (i > 0) try result.appendSlice(alloc, ",");

        const role = switch (msg.role) {
            .user, .tool => "user",
            .model => "model",
        };
        const escaped = try escapeJsonString(alloc, msg.content);
        defer alloc.free(escaped);

        const content = try std.fmt.allocPrint(alloc, "{{\"role\":\"{s}\",\"parts\":[{{\"text\":\"{s}\"}}]}}", .{ role, escaped });
        defer alloc.free(content);

        try result.appendSlice(alloc, content);
    }

    return try result.toOwnedSlice(alloc);
}
