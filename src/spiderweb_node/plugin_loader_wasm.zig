const std = @import("std");

pub const WasmPluginConfig = struct {
    module_path: []const u8,
    entrypoint: []const u8 = "spiderweb_driver_v1",
    args: []const []const u8 = &.{},
};

pub const WasmPluginHandle = struct {
    module_path: []u8,
    entrypoint: []u8,
    args: std.ArrayListUnmanaged([]u8) = .{},

    pub fn deinit(self: *WasmPluginHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.module_path);
        allocator.free(self.entrypoint);
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    config: WasmPluginConfig,
) !WasmPluginHandle {
    if (config.module_path.len == 0) return error.InvalidPluginConfig;
    if (!isSafeHostPath(config.module_path)) return error.InvalidPluginConfig;
    if (!isSafeEntrypoint(config.entrypoint)) return error.InvalidPluginConfig;
    var handle = WasmPluginHandle{
        .module_path = try allocator.dupe(u8, config.module_path),
        .entrypoint = try allocator.dupe(u8, config.entrypoint),
    };
    errdefer handle.deinit(allocator);
    for (config.args) |arg| {
        if (arg.len == 0) return error.InvalidPluginConfig;
        try handle.args.append(allocator, try allocator.dupe(u8, arg));
    }
    return handle;
}

fn isSafeHostPath(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch == 0 or ch == '\n' or ch == '\r') return false;
    }
    return true;
}

fn isSafeEntrypoint(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (ch == '_' or ch == '-' or ch == '.' or ch == ':') continue;
        return false;
    }
    return true;
}

test "plugin_loader_wasm: validates module path" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPluginConfig, load(allocator, .{ .module_path = "" }));
    try std.testing.expectError(error.InvalidPluginConfig, load(allocator, .{ .module_path = "plugins/\nmodule.wasm" }));
    try std.testing.expectError(error.InvalidPluginConfig, load(allocator, .{ .module_path = "plugins/module.wasm", .entrypoint = "bad name" }));
}

test "plugin_loader_wasm: captures module and entrypoint" {
    const allocator = std.testing.allocator;
    var handle = try load(allocator, .{
        .module_path = "plugins/camera.wasm",
        .entrypoint = "spiderweb_driver_v1",
        .args = &.{ "--dir", "." },
    });
    defer handle.deinit(allocator);

    try std.testing.expectEqualStrings("plugins/camera.wasm", handle.module_path);
    try std.testing.expectEqualStrings("spiderweb_driver_v1", handle.entrypoint);
    try std.testing.expectEqual(@as(usize, 2), handle.args.items.len);
}
