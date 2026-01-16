const std = @import("std");

pub fn addLog(logs: *std.ArrayList([]const u8), allocator: std.mem.Allocator, file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    const timestamp = std.time.timestamp();
    const msg = try std.fmt.allocPrint(allocator, "[{d}] " ++ fmt, .{timestamp} ++ args);

    // Write to file directly (unbuffered for immediate write)
    const file_msg = try std.fmt.allocPrint(allocator, "{s}\n", .{msg});
    defer allocator.free(file_msg);
    _ = file.write(file_msg) catch {};

    // Add to memory for display
    try logs.append(allocator, msg);
}
