const std = @import("std");

pub const RuntimeType = enum {
    builtin,
    native_inproc,
    native_proc,
    wasm,

    pub fn asString(self: RuntimeType) []const u8 {
        return switch (self) {
            .builtin => "builtin",
            .native_inproc => "native_inproc",
            .native_proc => "native_proc",
            .wasm => "wasm",
        };
    }
};

pub const VenomState = enum {
    online,
    degraded,
    offline,

    pub fn asString(self: VenomState) []const u8 {
        return switch (self) {
            .online => "online",
            .degraded => "degraded",
            .offline => "offline",
        };
    }
};

pub const MountDescriptor = struct {
    mount_id: []u8,
    mount_path: []u8,
    state: VenomState = .online,

    pub fn deinit(self: *MountDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.mount_id);
        allocator.free(self.mount_path);
        self.* = undefined;
    }

    pub fn clone(self: *const MountDescriptor, allocator: std.mem.Allocator) !MountDescriptor {
        return .{
            .mount_id = try allocator.dupe(u8, self.mount_id),
            .mount_path = try allocator.dupe(u8, self.mount_path),
            .state = self.state,
        };
    }
};

pub const VenomDescriptor = struct {
    venom_id: []u8,
    kind: []u8,
    version: []u8,
    state: VenomState = .online,
    runtime_type: RuntimeType = .builtin,
    capabilities_json: []u8,
    ops_json: []u8,
    permissions_json: []u8,
    schema_json: []u8,
    help_md: ?[]u8 = null,
    mounts: std.ArrayListUnmanaged(MountDescriptor) = .{},

    pub fn deinit(self: *VenomDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        allocator.free(self.kind);
        allocator.free(self.version);
        allocator.free(self.capabilities_json);
        allocator.free(self.ops_json);
        allocator.free(self.permissions_json);
        allocator.free(self.schema_json);
        if (self.help_md) |value| allocator.free(value);
        for (self.mounts.items) |*mount| mount.deinit(allocator);
        self.mounts.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: *const VenomDescriptor, allocator: std.mem.Allocator) !VenomDescriptor {
        var out = VenomDescriptor{
            .venom_id = try allocator.dupe(u8, self.venom_id),
            .kind = try allocator.dupe(u8, self.kind),
            .version = try allocator.dupe(u8, self.version),
            .state = self.state,
            .runtime_type = self.runtime_type,
            .capabilities_json = try allocator.dupe(u8, self.capabilities_json),
            .ops_json = try allocator.dupe(u8, self.ops_json),
            .permissions_json = try allocator.dupe(u8, self.permissions_json),
            .schema_json = try allocator.dupe(u8, self.schema_json),
            .help_md = if (self.help_md) |value| try allocator.dupe(u8, value) else null,
        };
        errdefer out.deinit(allocator);

        for (self.mounts.items) |mount| {
            try out.mounts.append(allocator, try mount.clone(allocator));
        }
        return out;
    }
};

pub const Health = struct {
    state: VenomState,
    detail: []const u8,
};

pub const DriverVTable = struct {
    start: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void,
    stop: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    health: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!Health,
    invoke_json: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, op: []const u8, args_json: []const u8) anyerror![]u8,
};

pub const DriverHandle = struct {
    ctx: *anyopaque,
    vtable: *const DriverVTable,

    pub fn start(self: *const DriverHandle, allocator: std.mem.Allocator) !void {
        try self.vtable.start(self.ctx, allocator);
    }

    pub fn stop(self: *const DriverHandle, allocator: std.mem.Allocator) void {
        self.vtable.stop(self.ctx, allocator);
    }

    pub fn health(self: *const DriverHandle, allocator: std.mem.Allocator) !Health {
        return self.vtable.health(self.ctx, allocator);
    }

    pub fn invokeJson(self: *const DriverHandle, allocator: std.mem.Allocator, op: []const u8, args_json: []const u8) ![]u8 {
        return self.vtable.invoke_json(self.ctx, allocator, op, args_json);
    }
};

test "namespace_driver: runtime type names are stable" {
    try std.testing.expectEqualStrings("builtin", RuntimeType.builtin.asString());
    try std.testing.expectEqualStrings("native_inproc", RuntimeType.native_inproc.asString());
    try std.testing.expectEqualStrings("native_proc", RuntimeType.native_proc.asString());
    try std.testing.expectEqualStrings("wasm", RuntimeType.wasm.asString());
}

test "namespace_driver: descriptor clone preserves mount metadata" {
    const allocator = std.testing.allocator;
    var descriptor = VenomDescriptor{
        .venom_id = try allocator.dupe(u8, "camera-main"),
        .kind = try allocator.dupe(u8, "camera"),
        .version = try allocator.dupe(u8, "1"),
        .state = .online,
        .runtime_type = .native_proc,
        .capabilities_json = try allocator.dupe(u8, "{}"),
        .ops_json = try allocator.dupe(u8, "{}"),
        .permissions_json = try allocator.dupe(u8, "{}"),
        .schema_json = try allocator.dupe(u8, "{}"),
    };
    defer descriptor.deinit(allocator);

    try descriptor.mounts.append(allocator, .{
        .mount_id = try allocator.dupe(u8, "camera-main"),
        .mount_path = try allocator.dupe(u8, "/nodes/node-1/camera"),
        .state = .online,
    });

    var copy = try descriptor.clone(allocator);
    defer copy.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), copy.mounts.items.len);
    try std.testing.expectEqualStrings("/nodes/node-1/camera", copy.mounts.items[0].mount_path);
    try std.testing.expect(copy.runtime_type == .native_proc);
}
