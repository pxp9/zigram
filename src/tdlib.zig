const std = @import("std");

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

pub fn setLogVerbosityLevel(level: i32) !void {
    var buffer: [256]u8 = undefined;
    const request = try std.fmt.bufPrintZ(
        &buffer,
        "{{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":{d}}}",
        .{level},
    );

    _ = Client.execute(request);
}

pub fn setLogStream(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const request_str = try std.fmt.allocPrint(
        allocator,
        "{{\"@type\":\"setLogStream\",\"log_stream\":{{\"@type\":\"logStreamFile\",\"path\":\"{s}\",\"max_file_size\":10485760}}}}",
        .{file_path},
    );
    defer allocator.free(request_str);

    const request = try allocator.dupeZ(u8, request_str);
    defer allocator.free(request);

    _ = Client.execute(request);
}
