const std = @import("std");
const utils = @import("utils.zig");

pub const c = @cImport({
    @cInclude("td/telegram/td_json_client.h");
});

pub const Client = opaque {
    pub fn create() !*Client {
        const client = c.td_json_client_create() orelse return error.ClientCreationFailed;
        return @ptrCast(client);
    }

    pub fn destroy(self: *Client) void {
        c.td_json_client_destroy(@ptrCast(self));
    }

    pub fn send(self: *Client, request: [:0]const u8) void {
        c.td_json_client_send(@ptrCast(self), request.ptr);
    }

    pub fn receive(self: *Client, timeout: f64) ?[:0]const u8 {
        const result = c.td_json_client_receive(@ptrCast(self), timeout);
        if (result == null) return null;
        return std.mem.span(result);
    }

    pub fn execute(request: [:0]const u8) ?[:0]const u8 {
        const result = c.td_json_client_execute(null, request.ptr);
        if (result == null) return null;
        return std.mem.span(result);
    }
};

pub fn setLogVerbosityLevel(allocator: std.mem.Allocator, level: i32) !void {
    const request_obj = .{
        .@"@type" = "setLogVerbosityLevel",
        .new_verbosity_level = level,
    };

    const request = try utils.formatJsonZ(allocator, request_obj);
    defer allocator.free(request);

    _ = Client.execute(request);
}

pub fn setLogStream(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const request_obj = .{
        .@"@type" = "setLogStream",
        .log_stream = .{
            .@"@type" = "logStreamFile",
            .path = file_path,
            .max_file_size = 10485760,
        },
    };

    const request = try utils.formatJsonZ(allocator, request_obj);
    defer allocator.free(request);

    _ = Client.execute(request);
}
