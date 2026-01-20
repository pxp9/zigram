const std = @import("std");
const tdlib = @import("tdlib.zig");

pub const User = struct {
    id: i64,
    first_name: []const u8,
    last_name: []const u8,
    username: ?[]const u8,
    phone_number: []const u8,

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.first_name);
        allocator.free(self.last_name);
        if (self.username) |username| allocator.free(username);
        allocator.free(self.phone_number);
    }
};

fn askUser(prompt: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    var stdout_buffer: [4096]u8 = undefined;
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    var stdin_reader = stdin_file.reader(&stdin_buffer);

    try stdout_writer.interface.print("{s} ", .{prompt});
    try stdout_writer.interface.flush();

    const line = try stdin_reader.interface.takeDelimiterExclusive('\n');
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    return try allocator.dupe(u8, trimmed);
}

fn askPassword(prompt: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    var stdout_buffer: [4096]u8 = undefined;
    var stdin_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    var stdin_reader = stdin_file.reader(&stdin_buffer);

    try stdout_writer.interface.print("{s} ", .{prompt});
    try stdout_writer.interface.flush();

    const termios = std.posix.tcgetattr(stdin_file.handle) catch |err| {
        std.debug.print("Warning: Could not disable echo: {}\n", .{err});
        const line = try stdin_reader.interface.takeDelimiterExclusive('\n');
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        return try allocator.dupe(u8, trimmed);
    };

    var new_termios = termios;
    new_termios.lflag.ECHO = false;
    std.posix.tcsetattr(stdin_file.handle, .FLUSH, new_termios) catch |err| {
        std.debug.print("Warning: Could not disable echo: {}\n", .{err});
    };

    const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| {
        std.posix.tcsetattr(stdin_file.handle, .FLUSH, termios) catch {};
        return err;
    };

    std.posix.tcsetattr(stdin_file.handle, .FLUSH, termios) catch {};

    try stdout_writer.interface.print("\n", .{});
    try stdout_writer.interface.flush();

    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    return try allocator.dupe(u8, trimmed);
}

fn formatRequestZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const str = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(str);
    return try allocator.dupeZ(u8, str);
}

fn handleAuthorizationState(
    client: *tdlib.Client,
    auth_state: std.json.Value,
    allocator: std.mem.Allocator,
) !bool {
    const state_type = auth_state.object.get("@type") orelse return error.MissingStateType;
    const state_str = state_type.string;

    if (std.mem.eql(u8, state_str, "authorizationStateWaitTdlibParameters")) {
        const api_id_str = std.posix.getenv("API_ID") orelse "94575";
        const api_hash = std.posix.getenv("API_HASH") orelse "a3406de8d171bb422bb6ddf3bbd800e2";
        const api_id = try std.fmt.parseInt(i32, api_id_str, 10);

        const request = try formatRequestZ(
            allocator,
            \\{{"@type":"setTdlibParameters","database_directory":".data/tdlib","use_test_dc":false,"api_id":{d},"api_hash":"{s}","system_language_code":"en","device_model":"Desktop","application_version":"0.1.0","use_message_database":true,"use_secret_chats":false}}
            ,
            .{ api_id, api_hash },
        );
        defer allocator.free(request);
        client.send(request);
    } else if (std.mem.eql(u8, state_str, "authorizationStateWaitPhoneNumber")) {
        const phone = try askUser("Enter your phone number (with country code):", allocator);
        defer allocator.free(phone);

        const request = try formatRequestZ(
            allocator,
            "{{\"@type\":\"setAuthenticationPhoneNumber\",\"phone_number\":\"{s}\"}}",
            .{phone},
        );
        defer allocator.free(request);
        client.send(request);
    } else if (std.mem.eql(u8, state_str, "authorizationStateWaitCode")) {
        const code = try askUser("Enter the verification code:", allocator);
        defer allocator.free(code);

        const request = try formatRequestZ(
            allocator,
            "{{\"@type\":\"checkAuthenticationCode\",\"code\":\"{s}\"}}",
            .{code},
        );
        defer allocator.free(request);
        client.send(request);
    } else if (std.mem.eql(u8, state_str, "authorizationStateWaitPassword")) {
        const password = try askPassword("Enter your 2FA password:", allocator);
        defer allocator.free(password);

        const request = try formatRequestZ(
            allocator,
            "{{\"@type\":\"checkAuthenticationPassword\",\"password\":\"{s}\"}}",
            .{password},
        );
        defer allocator.free(request);
        client.send(request);
    } else if (std.mem.eql(u8, state_str, "authorizationStateReady")) {
        return true;
    } else if (std.mem.eql(u8, state_str, "authorizationStateClosed")) {
        return false;
    }

    return false;
}

pub fn authenticate(client: *tdlib.Client, allocator: std.mem.Allocator) !User {
    std.debug.print("=== Zigram Authentication ===\n\n", .{});

    var is_authorized = false;
    var user_data: ?User = null;

    while (true) {
        const response_opt = client.receive(1.0);
        if (response_opt) |response| {
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                response,
                .{},
            ) catch |err| {
                std.debug.print("Failed to parse JSON: {}\n", .{err});
                continue;
            };
            defer parsed.deinit();

            const value = parsed.value;
            const update_type = value.object.get("@type") orelse continue;

            if (std.mem.eql(u8, update_type.string, "updateAuthorizationState")) {
                const auth_state = value.object.get("authorization_state") orelse continue;
                is_authorized = try handleAuthorizationState(client, auth_state, allocator);

                if (is_authorized) {
                    const request = try allocator.dupeZ(u8, "{\"@type\":\"getMe\"}");
                    defer allocator.free(request);
                    client.send(request);
                }
            } else if (is_authorized and std.mem.eql(u8, update_type.string, "user")) {
                const id = value.object.get("id").?.integer;
                const first_name = value.object.get("first_name").?.string;
                const last_name = if (value.object.get("last_name")) |ln| ln.string else "";
                const username_obj = value.object.get("usernames");
                const phone_number = if (value.object.get("phone_number")) |pn| pn.string else "";

                var username: ?[]const u8 = null;
                if (username_obj) |un_obj| {
                    if (un_obj.object.get("editable_username")) |editable| {
                        if (editable.string.len > 0) {
                            username = try allocator.dupe(u8, editable.string);
                        }
                    }
                }

                user_data = User{
                    .id = id,
                    .first_name = try allocator.dupe(u8, first_name),
                    .last_name = try allocator.dupe(u8, last_name),
                    .username = username,
                    .phone_number = try allocator.dupe(u8, phone_number),
                };

                std.debug.print("\nAuthenticated as: {s} {s}\n", .{ user_data.?.first_name, user_data.?.last_name });
                if (user_data.?.username) |un| {
                    std.debug.print("Username: @{s}\n", .{un});
                }

                return user_data.?;
            } else if (std.mem.eql(u8, update_type.string, "error")) {
                const code = value.object.get("code") orelse continue;
                const message = value.object.get("message") orelse continue;
                std.debug.print("\nError {d}: {s}\n", .{ code.integer, message.string });

                if (code.integer == 400) {
                    std.debug.print("Authentication failed.\n", .{});
                    return error.AuthenticationFailed;
                }
            }
        }
    }
}
