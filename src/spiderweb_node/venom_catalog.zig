const std = @import("std");

pub const Error = error{
    InvalidPayload,
};

pub const VenomDescriptor = struct {
    venom_id: []u8,
    package_id: ?[]u8 = null,
    instance_id: ?[]u8 = null,
    kind: []u8,
    version: []u8,
    state: []u8,
    provider_scope: ?[]u8 = null,
    categories_json: []u8,
    hosts_json: []u8,
    projection_modes_json: []u8,
    requirements_json: []u8,
    capabilities_json: []u8,
    mounts_json: []u8,
    ops_json: []u8,
    runtime_json: []u8,
    permissions_json: []u8,
    schema_json: []u8,
    invoke_template_json: ?[]u8 = null,
    help_md: ?[]u8 = null,
    endpoints: std.ArrayListUnmanaged([]u8) = .{},

    pub fn deinit(self: *VenomDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        if (self.package_id) |value| allocator.free(value);
        if (self.instance_id) |value| allocator.free(value);
        allocator.free(self.kind);
        allocator.free(self.version);
        allocator.free(self.state);
        if (self.provider_scope) |value| allocator.free(value);
        allocator.free(self.categories_json);
        allocator.free(self.hosts_json);
        allocator.free(self.projection_modes_json);
        allocator.free(self.requirements_json);
        allocator.free(self.capabilities_json);
        allocator.free(self.mounts_json);
        allocator.free(self.ops_json);
        allocator.free(self.runtime_json);
        allocator.free(self.permissions_json);
        allocator.free(self.schema_json);
        if (self.invoke_template_json) |value| allocator.free(value);
        if (self.help_md) |value| allocator.free(value);
        for (self.endpoints.items) |endpoint| allocator.free(endpoint);
        self.endpoints.deinit(allocator);
        self.* = undefined;
    }
};

pub fn venomDigest64(service: VenomDescriptor) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashField(&hasher, service.venom_id);
    if (service.package_id) |package_id| {
        hasher.update(&.{1});
        hashField(&hasher, package_id);
    } else {
        hasher.update(&.{0});
    }
    if (service.instance_id) |instance_id| {
        hasher.update(&.{1});
        hashField(&hasher, instance_id);
    } else {
        hasher.update(&.{0});
    }
    hashField(&hasher, service.kind);
    hashField(&hasher, service.version);
    hashField(&hasher, service.state);
    if (service.provider_scope) |provider_scope| {
        hasher.update(&.{1});
        hashField(&hasher, provider_scope);
    } else {
        hasher.update(&.{0});
    }
    hashField(&hasher, service.categories_json);
    hashField(&hasher, service.hosts_json);
    hashField(&hasher, service.projection_modes_json);
    hashField(&hasher, service.requirements_json);
    hashField(&hasher, service.capabilities_json);
    hashField(&hasher, service.mounts_json);
    hashField(&hasher, service.ops_json);
    hashField(&hasher, service.runtime_json);
    hashField(&hasher, service.permissions_json);
    hashField(&hasher, service.schema_json);
    if (service.invoke_template_json) |invoke_template| {
        hasher.update(&.{1});
        hashField(&hasher, invoke_template);
    } else {
        hasher.update(&.{0});
    }
    if (service.help_md) |help| {
        hasher.update(&.{1});
        hashField(&hasher, help);
    } else {
        hasher.update(&.{0});
    }
    var endpoint_count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &endpoint_count_buf, @intCast(service.endpoints.items.len), .little);
    hasher.update(&endpoint_count_buf);
    for (service.endpoints.items) |endpoint| {
        hashField(&hasher, endpoint);
    }
    return hasher.final();
}

pub fn deinitVenoms(
    allocator: std.mem.Allocator,
    services: *std.ArrayListUnmanaged(VenomDescriptor),
) void {
    for (services.items) |*service| service.deinit(allocator);
    services.deinit(allocator);
    services.* = .{};
}

pub fn replaceVenomsFromJsonValue(
    allocator: std.mem.Allocator,
    services: *std.ArrayListUnmanaged(VenomDescriptor),
    raw: std.json.Value,
) !void {
    if (raw != .array) return Error.InvalidPayload;

    var next = std.ArrayListUnmanaged(VenomDescriptor){};
    errdefer {
        for (next.items) |*service| service.deinit(allocator);
        next.deinit(allocator);
    }

    var ids = std.StringHashMapUnmanaged(void){};
    defer ids.deinit(allocator);

    for (raw.array.items) |entry| {
        if (entry != .object) return Error.InvalidPayload;
        const obj = entry.object;

        const venom_id = getRequiredString(obj, "venom_id");
        try validateIdentifier(venom_id, 128);
        if (ids.contains(venom_id)) return Error.InvalidPayload;
        try ids.put(allocator, venom_id, {});

        const kind = getRequiredString(obj, "kind");
        try validateIdentifier(kind, 128);

        const version = getOptionalString(obj, "version") orelse "1";
        try validateDisplayString(version, 64);

        const state = getRequiredString(obj, "state");
        try validateIdentifier(state, 64);

        const endpoints_raw = obj.get("endpoints") orelse return Error.InvalidPayload;
        if (endpoints_raw != .array) return Error.InvalidPayload;
        if (endpoints_raw.array.items.len == 0) return Error.InvalidPayload;

        var service = VenomDescriptor{
            .venom_id = try allocator.dupe(u8, venom_id),
            .package_id = if (obj.get("package_id")) |package_id_value| blk: {
                if (package_id_value != .string or package_id_value.string.len == 0) return Error.InvalidPayload;
                break :blk try allocator.dupe(u8, package_id_value.string);
            } else null,
            .instance_id = if (obj.get("instance_id")) |instance_id_value| blk: {
                if (instance_id_value != .string or instance_id_value.string.len == 0) return Error.InvalidPayload;
                break :blk try allocator.dupe(u8, instance_id_value.string);
            } else null,
            .kind = try allocator.dupe(u8, kind),
            .version = try allocator.dupe(u8, version),
            .state = try allocator.dupe(u8, state),
            .provider_scope = if (obj.get("provider_scope")) |provider_scope_value| blk: {
                if (provider_scope_value != .string or provider_scope_value.string.len == 0) return Error.InvalidPayload;
                break :blk try allocator.dupe(u8, provider_scope_value.string);
            } else null,
            .categories_json = if (obj.get("categories")) |categories_value|
                try encodeArrayValue(allocator, categories_value)
            else
                try allocator.dupe(u8, "[]"),
            .hosts_json = if (obj.get("hosts")) |hosts_value|
                try encodeArrayValue(allocator, hosts_value)
            else
                try allocator.dupe(u8, "[]"),
            .projection_modes_json = if (obj.get("projection_modes")) |projection_modes_value|
                try encodeArrayValue(allocator, projection_modes_value)
            else
                try allocator.dupe(u8, "[]"),
            .requirements_json = if (obj.get("requirements")) |requirements_value|
                try encodeObjectValue(allocator, requirements_value)
            else
                try allocator.dupe(u8, "{}"),
            .capabilities_json = if (obj.get("capabilities")) |caps_value|
                try encodeCapabilitiesValue(allocator, caps_value)
            else
                try allocator.dupe(u8, "{}"),
            .mounts_json = if (obj.get("mounts")) |mounts_value|
                try encodeMountsValue(allocator, mounts_value)
            else
                try allocator.dupe(u8, "[]"),
            .ops_json = if (obj.get("ops")) |ops_value|
                try encodeObjectValue(allocator, ops_value)
            else
                try allocator.dupe(u8, "{}"),
            .runtime_json = if (obj.get("runtime")) |runtime_value|
                try encodeObjectValue(allocator, runtime_value)
            else
                try allocator.dupe(u8, "{}"),
            .permissions_json = if (obj.get("permissions")) |permissions_value|
                try encodeObjectValue(allocator, permissions_value)
            else
                try allocator.dupe(u8, "{}"),
            .schema_json = if (obj.get("schema")) |schema_value|
                try encodeObjectValue(allocator, schema_value)
            else
                try allocator.dupe(u8, "{}"),
            .invoke_template_json = if (obj.get("invoke_template")) |invoke_template_value|
                try encodeOptionalObjectValue(allocator, invoke_template_value)
            else
                null,
            .help_md = if (obj.get("help_md")) |help_value| blk: {
                if (help_value != .string) return Error.InvalidPayload;
                if (help_value.string.len == 0 or help_value.string.len > 64 * 1024) return Error.InvalidPayload;
                break :blk try allocator.dupe(u8, help_value.string);
            } else null,
        };
        errdefer service.deinit(allocator);

        for (endpoints_raw.array.items) |endpoint_value| {
            if (endpoint_value != .string) return Error.InvalidPayload;
            const endpoint = endpoint_value.string;
            if (endpoint.len == 0 or endpoint.len > 512) return Error.InvalidPayload;
            if (endpoint[0] != '/') return Error.InvalidPayload;
            try service.endpoints.append(allocator, try allocator.dupe(u8, endpoint));
        }

        try next.append(allocator, service);
    }

    deinitVenoms(allocator, services);
    services.* = next;
}

pub fn appendVenomJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    service: VenomDescriptor,
) !void {
    const escaped_id = try jsonEscape(allocator, service.venom_id);
    defer allocator.free(escaped_id);
    const escaped_kind = try jsonEscape(allocator, service.kind);
    defer allocator.free(escaped_kind);
    const escaped_version = try jsonEscape(allocator, service.version);
    defer allocator.free(escaped_version);
    const escaped_state = try jsonEscape(allocator, service.state);
    defer allocator.free(escaped_state);

    try out.writer(allocator).print(
        "{{\"venom_id\":\"{s}\"",
        .{escaped_id},
    );
    if (service.package_id) |package_id| {
        const escaped_package_id = try jsonEscape(allocator, package_id);
        defer allocator.free(escaped_package_id);
        try out.writer(allocator).print(",\"package_id\":\"{s}\"", .{escaped_package_id});
    }
    if (service.instance_id) |instance_id| {
        const escaped_instance_id = try jsonEscape(allocator, instance_id);
        defer allocator.free(escaped_instance_id);
        try out.writer(allocator).print(",\"instance_id\":\"{s}\"", .{escaped_instance_id});
    }
    try out.writer(allocator).print(
        ",\"kind\":\"{s}\",\"version\":\"{s}\",\"state\":\"{s}\"",
        .{ escaped_kind, escaped_version, escaped_state },
    );
    if (service.provider_scope) |provider_scope| {
        const escaped_provider_scope = try jsonEscape(allocator, provider_scope);
        defer allocator.free(escaped_provider_scope);
        try out.writer(allocator).print(",\"provider_scope\":\"{s}\"", .{escaped_provider_scope});
    }
    try out.writer(allocator).print(
        ",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"endpoints\":[",
        .{
            service.categories_json,
            service.hosts_json,
            service.projection_modes_json,
            service.requirements_json,
        },
    );
    for (service.endpoints.items, 0..) |endpoint, idx| {
        if (idx != 0) try out.append(allocator, ',');
        const escaped_endpoint = try jsonEscape(allocator, endpoint);
        defer allocator.free(escaped_endpoint);
        try out.writer(allocator).print("\"{s}\"", .{escaped_endpoint});
    }
    if (service.help_md) |help| {
        const escaped_help = try jsonEscape(allocator, help);
        defer allocator.free(escaped_help);
        try out.writer(allocator).print(
            "],\"capabilities\":{s},\"mounts\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s}",
            .{
                service.capabilities_json,
                service.mounts_json,
                service.ops_json,
                service.runtime_json,
                service.permissions_json,
                service.schema_json,
            },
        );
        if (service.invoke_template_json) |invoke_template| {
            try out.writer(allocator).print(",\"invoke_template\":{s}", .{invoke_template});
        }
        try out.writer(allocator).print(",\"help_md\":\"{s}\"}}", .{escaped_help});
        return;
    }
    try out.writer(allocator).print(
        "],\"capabilities\":{s},\"mounts\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s}",
        .{
            service.capabilities_json,
            service.mounts_json,
            service.ops_json,
            service.runtime_json,
            service.permissions_json,
            service.schema_json,
        },
    );
    if (service.invoke_template_json) |invoke_template| {
        try out.writer(allocator).print(",\"invoke_template\":{s}", .{invoke_template});
    }
    try out.appendSlice(allocator, "}}");
}

fn getRequiredString(obj: std.json.ObjectMap, name: []const u8) []const u8 {
    const value = obj.get(name) orelse return "";
    if (value != .string or value.string.len == 0) return "";
    return value.string;
}

fn getOptionalString(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn encodeCapabilitiesValue(allocator: std.mem.Allocator, raw: std.json.Value) ![]u8 {
    if (raw != .object) return Error.InvalidPayload;
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
}

fn encodeArrayValue(allocator: std.mem.Allocator, raw: std.json.Value) ![]u8 {
    if (raw != .array) return Error.InvalidPayload;
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
}

fn encodeObjectValue(allocator: std.mem.Allocator, raw: std.json.Value) ![]u8 {
    if (raw != .object) return Error.InvalidPayload;
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
}

fn encodeOptionalObjectValue(allocator: std.mem.Allocator, raw: std.json.Value) !?[]u8 {
    if (raw != .object) return Error.InvalidPayload;
    const rendered = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
    return rendered;
}

fn encodeMountsValue(allocator: std.mem.Allocator, raw: std.json.Value) ![]u8 {
    if (raw != .array) return Error.InvalidPayload;
    for (raw.array.items) |item| {
        if (item != .object) return Error.InvalidPayload;
        const mount_id = getRequiredString(item.object, "mount_id");
        try validateIdentifier(mount_id, 128);
        const mount_path = getRequiredString(item.object, "mount_path");
        if (mount_path.len == 0 or mount_path.len > 512) return Error.InvalidPayload;
        if (mount_path[0] != '/') return Error.InvalidPayload;
    }
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
}

fn validateIdentifier(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return Error.InvalidPayload;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.') continue;
        return Error.InvalidPayload;
    }
}

fn validateDisplayString(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return Error.InvalidPayload;
    for (value) |char| {
        if (char < 0x20) return Error.InvalidPayload;
    }
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    for (value) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (char < 0x20) {
                try out.writer(allocator).print("\\u00{x:0>2}", .{char});
            } else {
                try out.append(allocator, char);
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn hashField(hasher: *std.hash.Wyhash, value: []const u8) void {
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, @intCast(value.len), .little);
    hasher.update(&len_buf);
    hasher.update(value);
}

test "venom_catalog: parses and re-renders venoms array" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "[{\"venom_id\":\"fs\",\"package_id\":\"fs\",\"instance_id\":\"local:fs\",\"kind\":\"fs\",\"version\":\"1\",\"state\":\"online\",\"provider_scope\":\"host_local\",\"categories\":[\"filesystem\"],\"hosts\":[\"node\"],\"projection_modes\":[\"node_export\"],\"requirements\":{},\"endpoints\":[\"/nodes/node-1/fs\"],\"capabilities\":{\"rw\":true}}]",
        .{},
    );
    defer parsed.deinit();

    var services = std.ArrayListUnmanaged(VenomDescriptor){};
    defer deinitVenoms(allocator, &services);
    try replaceVenomsFromJsonValue(allocator, &services, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), services.items.len);

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    try appendVenomJson(allocator, &out, services.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"venom_id\":\"fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"package_id\":\"fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"capabilities\":{\"rw\":true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"mounts\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"runtime\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"invoke_template\":") == null);
}

test "venom_catalog: accepts optional namespace metadata fields" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "[{\"venom_id\":\"camera-main\",\"package_id\":\"camera-main\",\"instance_id\":\"node-1:camera-main\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"online\",\"provider_scope\":\"node_export\",\"categories\":[\"camera\",\"edge\"],\"hosts\":[\"node\"],\"projection_modes\":[\"node_export\"],\"requirements\":{\"host_capabilities\":[\"namespace_driver\"]},\"endpoints\":[\"/nodes/node-1/camera\"],\"capabilities\":{\"still\":true},\"mounts\":[{\"mount_id\":\"camera-main\",\"mount_path\":\"/nodes/node-1/camera\",\"state\":\"online\"}],\"ops\":{\"model\":\"namespace\"},\"runtime\":{\"type\":\"native_proc\"},\"permissions\":{\"default\":\"deny-by-default\"},\"schema\":{\"model\":\"namespace-mount\"},\"invoke_template\":{\"op\":\"capture\"},\"help_md\":\"Camera driver\"}]",
        .{},
    );
    defer parsed.deinit();

    var services = std.ArrayListUnmanaged(VenomDescriptor){};
    defer deinitVenoms(allocator, &services);
    try replaceVenomsFromJsonValue(allocator, &services, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), services.items.len);
    try std.testing.expectEqualStrings("camera-main", services.items[0].package_id.?);
    try std.testing.expectEqualStrings("node_export", services.items[0].provider_scope.?);
    try std.testing.expect(std.mem.indexOf(u8, services.items[0].projection_modes_json, "\"node_export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, services.items[0].mounts_json, "\"mount_id\":\"camera-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, services.items[0].runtime_json, "\"type\":\"native_proc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, services.items[0].invoke_template_json.?, "\"capture\"") != null);
    try std.testing.expectEqualStrings("Camera driver", services.items[0].help_md.?);
}

test "venom_catalog: requires venom_id and re-renders it" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "[{\"venom_id\":\"memory\",\"kind\":\"memory\",\"version\":\"1\",\"state\":\"online\",\"categories\":[],\"hosts\":[],\"projection_modes\":[],\"requirements\":{},\"endpoints\":[\"/global/memory\"]}]",
        .{},
    );
    defer parsed.deinit();

    var services = std.ArrayListUnmanaged(VenomDescriptor){};
    defer deinitVenoms(allocator, &services);
    try replaceVenomsFromJsonValue(allocator, &services, parsed.value);
    try std.testing.expectEqual(@as(usize, 1), services.items.len);
    try std.testing.expectEqualStrings("memory", services.items[0].venom_id);

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    try appendVenomJson(allocator, &out, services.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"venom_id\":\"memory\"") != null);
}
