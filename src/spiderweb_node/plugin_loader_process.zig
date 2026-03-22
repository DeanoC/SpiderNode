const std = @import("std");

pub const ProcessPluginConfig = struct {
    executable_path: []const u8,
    args: []const []const u8 = &.{},
};

pub const ProcessPluginHandle = struct {
    executable_path: []u8,
    args: std.ArrayListUnmanaged([]u8) = .{},

    pub fn deinit(self: *ProcessPluginHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.executable_path);
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
        self.* = undefined;
    }
};

pub fn launch(
    allocator: std.mem.Allocator,
    config: ProcessPluginConfig,
) !ProcessPluginHandle {
    if (config.executable_path.len == 0) return error.InvalidPluginConfig;
    var handle = ProcessPluginHandle{
        .executable_path = try allocator.dupe(u8, config.executable_path),
    };
    errdefer handle.deinit(allocator);
    for (config.args) |arg| {
        if (arg.len == 0) return error.InvalidPluginConfig;
        try handle.args.append(allocator, try allocator.dupe(u8, arg));
    }
    return handle;
}

test "plugin_loader_process: validates executable path" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPluginConfig, launch(allocator, .{ .executable_path = "" }));
}

test "plugin_loader_process: captures executable and args" {
    const allocator = std.testing.allocator;
    var handle = try launch(allocator, .{
        .executable_path = "camera-driver",
        .args = &.{ "--format", "jpg" },
    });
    defer handle.deinit(allocator);

    try std.testing.expectEqualStrings("camera-driver", handle.executable_path);
    try std.testing.expectEqual(@as(usize, 2), handle.args.items.len);
}
