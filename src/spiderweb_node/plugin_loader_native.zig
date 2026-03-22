const std = @import("std");

pub const default_invoke_symbol = "spiderweb_driver_v1_invoke_json";
pub const stable_abi_name = "namespace-driver-v1";
pub const venom_abi_name = "venom-driver-v1";

pub const InprocInvokeFn = *const fn (
    payload_ptr: [*]const u8,
    payload_len: usize,
    stdout_ptr: [*]u8,
    stdout_cap: usize,
    stdout_len: *usize,
    stderr_ptr: [*]u8,
    stderr_cap: usize,
    stderr_len: *usize,
) callconv(.c) i32;

pub const NativePluginConfig = struct {
    library_path: []const u8,
    in_process: bool = true,
    invoke_symbol: []const u8 = default_invoke_symbol,
    validate_abi_symbol: bool = true,
};

pub const LoadedNativePlugin = struct {
    library_path: []u8,
    in_process: bool,
    invoke_symbol: []u8,

    pub fn deinit(self: *LoadedNativePlugin, allocator: std.mem.Allocator) void {
        allocator.free(self.library_path);
        allocator.free(self.invoke_symbol);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    config: NativePluginConfig,
) !LoadedNativePlugin {
    if (config.library_path.len == 0) return error.InvalidPluginConfig;
    if (config.invoke_symbol.len == 0) return error.InvalidPluginConfig;

    if (config.validate_abi_symbol) {
        var lib = try std.DynLib.open(config.library_path);
        defer lib.close();
        const symbol_z = try allocator.dupeZ(u8, config.invoke_symbol);
        defer allocator.free(symbol_z);
        _ = lib.lookup(InprocInvokeFn, symbol_z) orelse return error.MissingInvokeSymbol;
    }

    return .{
        .library_path = try allocator.dupe(u8, config.library_path),
        .in_process = config.in_process,
        .invoke_symbol = try allocator.dupe(u8, config.invoke_symbol),
    };
}

test "plugin_loader_native: validates config" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPluginConfig, load(allocator, .{ .library_path = "" }));
    try std.testing.expectError(error.InvalidPluginConfig, load(allocator, .{ .library_path = "camera_plugin.dll", .invoke_symbol = "" }));
}

test "plugin_loader_native: captures load metadata" {
    const allocator = std.testing.allocator;
    var plugin = try load(allocator, .{
        .library_path = "camera_plugin.dll",
        .in_process = false,
        .validate_abi_symbol = false,
    });
    defer plugin.deinit(allocator);

    try std.testing.expectEqualStrings("camera_plugin.dll", plugin.library_path);
    try std.testing.expect(!plugin.in_process);
    try std.testing.expectEqualStrings(default_invoke_symbol, plugin.invoke_symbol);
}
