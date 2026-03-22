const std = @import("std");
const venom_contracts = @import("venom_contracts.zig");

pub const LoadedVenom = struct {
    venom_id: []u8,
    venom_json: []u8,

    pub fn deinit(self: *LoadedVenom, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        allocator.free(self.venom_json);
        self.* = undefined;
    }
};

pub fn loadVenomManifestFile(
    allocator: std.mem.Allocator,
    manifest_path: []const u8,
    node_id: []const u8,
) !?LoadedVenom {
    const raw = try std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidManifest;

    const enabled = parseOptionalBool(parsed.value.object, "enabled") orelse true;
    if (!enabled) return null;

    const venom_id = try dupRequiredIdentifier(allocator, parsed.value.object, "venom_id", 128);
    errdefer allocator.free(venom_id);
    const kind = try dupRequiredIdentifier(allocator, parsed.value.object, "kind", 128);
    defer allocator.free(kind);

    const version = try dupOptionalStringOrDefault(allocator, parsed.value.object, "version", "1", 64);
    defer allocator.free(version);
    const state = try dupOptionalStringOrDefault(allocator, parsed.value.object, "state", "online", 64);
    defer allocator.free(state);
    const package_id = try dupOptionalStringOrDefault(allocator, parsed.value.object, "package_id", venom_id, 128);
    defer allocator.free(package_id);
    const instance_id = try dupOptionalString(allocator, parsed.value.object, "instance_id", 128);
    defer if (instance_id) |value| allocator.free(value);
    const provider_scope = try dupOptionalStringOrDefault(allocator, parsed.value.object, "provider_scope", "node_export", 64);
    defer allocator.free(provider_scope);
    const categories_json = try parseOptionalArrayJsonOrDefault(allocator, parsed.value.object, "categories", "[]");
    defer allocator.free(categories_json);
    const hosts_json = try parseOptionalArrayJsonOrDefault(allocator, parsed.value.object, "hosts", "[\"node\"]");
    defer allocator.free(hosts_json);
    const projection_modes_json = try parseOptionalArrayJsonOrDefault(allocator, parsed.value.object, "projection_modes", "[\"node_export\"]");
    defer allocator.free(projection_modes_json);
    const requirements_json = try parseOptionalObjectJsonOrDefault(allocator, parsed.value.object, "requirements", "{}");
    defer allocator.free(requirements_json);

    var endpoints = std.ArrayListUnmanaged([]u8){};
    defer freeStringList(allocator, &endpoints);
    try parseEndpoints(allocator, parsed.value.object, node_id, venom_id, &endpoints);

    const mounts_json = try parseMountsJson(allocator, parsed.value.object, node_id, venom_id, state, endpoints.items[0]);
    defer allocator.free(mounts_json);

    const capabilities_json = try parseOptionalObjectJsonOrDefault(allocator, parsed.value.object, "capabilities", "{}");
    defer allocator.free(capabilities_json);
    const ops_json = try parseOptionalObjectJsonOrDefault(
        allocator,
        parsed.value.object,
        "ops",
        "{\"model\":\"namespace\",\"style\":\"plan9\"}",
    );
    defer allocator.free(ops_json);
    const runtime_json = try parseOptionalObjectJsonOrDefault(
        allocator,
        parsed.value.object,
        "runtime",
        "{\"type\":\"native_proc\",\"abi\":\"venom-driver-v1\"}",
    );
    defer allocator.free(runtime_json);
    const permissions_json = try parseOptionalObjectJsonOrDefault(
        allocator,
        parsed.value.object,
        "permissions",
        "{\"default\":\"deny-by-default\"}",
    );
    defer allocator.free(permissions_json);
    const schema_json = try parseOptionalObjectJsonOrDefault(
        allocator,
        parsed.value.object,
        "schema",
        defaultSchemaJsonForManifest(parsed.value.object),
    );
    defer allocator.free(schema_json);
    const invoke_template_json = try parseOptionalObjectJsonOrDefault(
        allocator,
        parsed.value.object,
        "invoke_template",
        "{}",
    );
    defer allocator.free(invoke_template_json);

    const help_md = try dupOptionalString(allocator, parsed.value.object, "help_md", 64 * 1024);
    defer if (help_md) |value| allocator.free(value);

    const endpoints_json = try buildEndpointsJson(allocator, endpoints.items);
    defer allocator.free(endpoints_json);

    const escaped_venom_id = try jsonEscape(allocator, venom_id);
    defer allocator.free(escaped_venom_id);
    const escaped_package_id = try jsonEscape(allocator, package_id);
    defer allocator.free(escaped_package_id);
    const escaped_kind = try jsonEscape(allocator, kind);
    defer allocator.free(escaped_kind);
    const escaped_version = try jsonEscape(allocator, version);
    defer allocator.free(escaped_version);
    const escaped_state = try jsonEscape(allocator, state);
    defer allocator.free(escaped_state);
    const escaped_provider_scope = try jsonEscape(allocator, provider_scope);
    defer allocator.free(escaped_provider_scope);
    const instance_fragment = if (instance_id) |value| blk: {
        const escaped_instance_id = try jsonEscape(allocator, value);
        defer allocator.free(escaped_instance_id);
        break :blk try std.fmt.allocPrint(allocator, ",\"instance_id\":\"{s}\"", .{escaped_instance_id});
    } else try allocator.dupe(u8, "");
    defer allocator.free(instance_fragment);

    const venom_json = if (help_md) |help| blk: {
        const escaped_help = try jsonEscape(allocator, help);
        defer allocator.free(escaped_help);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"venom_id\":\"{s}\",\"package_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"state\":\"{s}\",\"provider_scope\":\"{s}\",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"endpoints\":{s},\"capabilities\":{s},\"mounts\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s},\"invoke_template\":{s},\"help_md\":\"{s}\"{s}}}",
            .{ escaped_venom_id, escaped_package_id, escaped_kind, escaped_version, escaped_state, escaped_provider_scope, categories_json, hosts_json, projection_modes_json, requirements_json, endpoints_json, capabilities_json, mounts_json, ops_json, runtime_json, permissions_json, schema_json, invoke_template_json, escaped_help, instance_fragment },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"package_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"state\":\"{s}\",\"provider_scope\":\"{s}\",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"endpoints\":{s},\"capabilities\":{s},\"mounts\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s},\"invoke_template\":{s}{s}}}",
        .{ escaped_venom_id, escaped_package_id, escaped_kind, escaped_version, escaped_state, escaped_provider_scope, categories_json, hosts_json, projection_modes_json, requirements_json, endpoints_json, capabilities_json, mounts_json, ops_json, runtime_json, permissions_json, schema_json, invoke_template_json, instance_fragment },
    );

    return .{
        .venom_id = venom_id,
        .venom_json = venom_json,
    };
}

pub fn loadVenomManifestDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    node_id: []const u8,
    out: *std.ArrayListUnmanaged(LoadedVenom),
) !void {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);
        const loaded = try loadVenomManifestFile(allocator, path, node_id);
        if (loaded) |item| {
            try out.append(allocator, item);
        }
    }
}

fn parseEndpoints(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    node_id: []const u8,
    venom_id: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
) !void {
    if (obj.get("endpoints")) |value| {
        if (value != .array) return error.InvalidManifest;
        for (value.array.items) |item| {
            if (item != .string or item.string.len == 0) return error.InvalidManifest;
            const resolved = try resolveNodeTemplate(allocator, item.string, node_id);
            errdefer allocator.free(resolved);
            try validateAbsolutePath(resolved);
            try out.append(allocator, resolved);
        }
    }

    if (out.items.len == 0) {
        const fallback = try std.fmt.allocPrint(allocator, "/nodes/{s}/{s}", .{ node_id, venom_id });
        errdefer allocator.free(fallback);
        try out.append(allocator, fallback);
    }
}

fn defaultSchemaJsonForManifest(obj: std.json.ObjectMap) []const u8 {
    if (obj.get("invoke_template") != null) return venom_contracts.namespace_service.descriptor_schema_json;
    if (obj.get("ops")) |ops_value| {
        if (ops_value == .object) {
            if (ops_value.object.get("invoke")) |invoke_value| {
                if (invoke_value == .string and invoke_value.string.len > 0) {
                    return venom_contracts.namespace_service.descriptor_schema_json;
                }
            }
            if (ops_value.object.get("paths")) |paths_value| {
                if (paths_value == .object) {
                    if (paths_value.object.get("invoke")) |invoke_value| {
                        if (invoke_value == .string and invoke_value.string.len > 0) {
                            return venom_contracts.namespace_service.descriptor_schema_json;
                        }
                    }
                }
            }
        }
    }
    return "{\"model\":\"namespace-mount\"}";
}

fn parseMountsJson(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    node_id: []const u8,
    venom_id: []const u8,
    default_state: []const u8,
    first_endpoint: []const u8,
) ![]u8 {
    if (obj.get("mounts")) |value| {
        if (value != .array) return error.InvalidManifest;
        var rendered = std.ArrayListUnmanaged(u8){};
        errdefer rendered.deinit(allocator);
        try rendered.append(allocator, '[');
        for (value.array.items, 0..) |item, idx| {
            if (item != .object) return error.InvalidManifest;
            const mount_id = getRequiredIdentifier(item.object, "mount_id") orelse return error.InvalidManifest;
            const mount_path_raw = getRequiredString(item.object, "mount_path") orelse return error.InvalidManifest;
            const mount_state = getOptionalString(item.object, "state") orelse default_state;

            const resolved_mount_path = try resolveNodeTemplate(allocator, mount_path_raw, node_id);
            defer allocator.free(resolved_mount_path);
            try validateAbsolutePath(resolved_mount_path);

            const escaped_mount_id = try jsonEscape(allocator, mount_id);
            defer allocator.free(escaped_mount_id);
            const escaped_mount_path = try jsonEscape(allocator, resolved_mount_path);
            defer allocator.free(escaped_mount_path);
            const escaped_state = try jsonEscape(allocator, mount_state);
            defer allocator.free(escaped_state);

            if (idx != 0) try rendered.append(allocator, ',');
            try rendered.writer(allocator).print(
                "{{\"mount_id\":\"{s}\",\"mount_path\":\"{s}\",\"state\":\"{s}\"}}",
                .{ escaped_mount_id, escaped_mount_path, escaped_state },
            );
        }
        try rendered.append(allocator, ']');
        return rendered.toOwnedSlice(allocator);
    }

    const escaped_venom_id = try jsonEscape(allocator, venom_id);
    defer allocator.free(escaped_venom_id);
    const escaped_endpoint = try jsonEscape(allocator, first_endpoint);
    defer allocator.free(escaped_endpoint);
    const escaped_state = try jsonEscape(allocator, default_state);
    defer allocator.free(escaped_state);
    return std.fmt.allocPrint(
        allocator,
        "[{{\"mount_id\":\"{s}\",\"mount_path\":\"{s}\",\"state\":\"{s}\"}}]",
        .{ escaped_venom_id, escaped_endpoint, escaped_state },
    );
}

fn buildEndpointsJson(allocator: std.mem.Allocator, endpoints: []const []u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (endpoints, 0..) |endpoint, idx| {
        if (idx != 0) try out.append(allocator, ',');
        const escaped = try jsonEscape(allocator, endpoint);
        defer allocator.free(escaped);
        try out.writer(allocator).print("\"{s}\"", .{escaped});
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn parseOptionalObjectJsonOrDefault(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    default_json: []const u8,
) ![]u8 {
    if (obj.get(key)) |value| {
        if (value != .object) return error.InvalidManifest;
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    return allocator.dupe(u8, default_json);
}

fn parseOptionalArrayJsonOrDefault(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    default_json: []const u8,
) ![]u8 {
    if (obj.get(key)) |value| {
        if (value != .array) return error.InvalidManifest;
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    return allocator.dupe(u8, default_json);
}

fn parseOptionalBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn dupRequiredIdentifier(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    max_len: usize,
) ![]u8 {
    const value = getRequiredIdentifier(obj, key) orelse return error.InvalidManifest;
    if (value.len > max_len) return error.InvalidManifest;
    return allocator.dupe(u8, value);
}

fn dupRequiredIdentifierAlias(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    primary: []const u8,
    alias: []const u8,
    max_len: usize,
) ![]u8 {
    const value = getRequiredIdentifier(obj, primary) orelse getRequiredIdentifier(obj, alias) orelse return error.InvalidManifest;
    if (value.len > max_len) return error.InvalidManifest;
    return allocator.dupe(u8, value);
}

fn dupOptionalStringOrDefault(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    default_value: []const u8,
    max_len: usize,
) ![]u8 {
    const value = getOptionalString(obj, key) orelse default_value;
    if (value.len == 0 or value.len > max_len) return error.InvalidManifest;
    return allocator.dupe(u8, value);
}

fn dupOptionalString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    max_len: usize,
) !?[]u8 {
    const value = getOptionalString(obj, key) orelse return null;
    if (value.len == 0 or value.len > max_len) return error.InvalidManifest;
    return try allocator.dupe(u8, value);
}

fn getRequiredIdentifier(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = getRequiredString(obj, key) orelse return null;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.') continue;
        return null;
    }
    return value;
}

fn getRequiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn resolveNodeTemplate(allocator: std.mem.Allocator, value: []const u8, node_id: []const u8) ![]u8 {
    const marker = "{node_id}";
    if (std.mem.indexOf(u8, value, marker) == null) return allocator.dupe(u8, value);

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var start: usize = 0;
    while (true) {
        const idx_opt = std.mem.indexOfPos(u8, value, start, marker);
        if (idx_opt) |idx| {
            try out.appendSlice(allocator, value[start..idx]);
            try out.appendSlice(allocator, node_id);
            start = idx + marker.len;
            continue;
        }
        try out.appendSlice(allocator, value[start..]);
        break;
    }

    return out.toOwnedSlice(allocator);
}

fn validateAbsolutePath(path: []const u8) !void {
    if (path.len == 0 or path[0] != '/') return error.InvalidManifest;
}

fn freeStringList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
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

test "venom_manifest: loads enabled manifest with node_id template" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "camera.json",
        .data =
        \\{
        \\  "enabled": true,
        \\  "venom_id": "camera-main",
        \\  "kind": "camera",
        \\  "endpoints": ["/nodes/{node_id}/camera"],
        \\  "mounts": [{"mount_id": "camera-main", "mount_path": "/nodes/{node_id}/camera", "state": "online"}],
        \\  "runtime": {"type": "native_proc", "abi": "namespace-driver-v1"},
        \\  "invoke_template": {"op": "capture", "arguments": {"mode": "still"}}
        \\}
        ,
    });

    const abs = try tmp.dir.realpathAlloc(allocator, "camera.json");
    defer allocator.free(abs);

    const loaded = try loadVenomManifestFile(allocator, abs, "node-77");
    try std.testing.expect(loaded != null);
    var service = loaded.?;
    defer service.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, service.venom_id, "camera-main"));
    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"/nodes/node-77/camera\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"runtime\":{\"type\":\"native_proc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"invoke_template\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"capture\"") != null);
}

test "venom_manifest: disabled manifest is ignored" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "disabled.json",
        .data =
        \\{
        \\  "enabled": false,
        \\  "venom_id": "ignored",
        \\  "kind": "camera"
        \\}
        ,
    });

    const abs = try tmp.dir.realpathAlloc(allocator, "disabled.json");
    defer allocator.free(abs);

    const loaded = try loadVenomManifestFile(allocator, abs, "node-77");
    try std.testing.expect(loaded == null);
}

test "venom_manifest: service-like manifest defaults to namespace service schema" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "tool.json",
        .data =
        \\{
        \\  "venom_id": "tool-main",
        \\  "kind": "tool",
        \\  "endpoints": ["/nodes/{node_id}/tool/main"],
        \\  "ops": {"model": "namespace", "invoke": "control/invoke.json"},
        \\  "runtime": {"type": "native_proc", "abi": "namespace-driver-v1"}
        \\}
        ,
    });

    const abs = try tmp.dir.realpathAlloc(allocator, "tool.json");
    defer allocator.free(abs);

    const loaded = try loadVenomManifestFile(allocator, abs, "node-77");
    try std.testing.expect(loaded != null);
    var service = loaded.?;
    defer service.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"schema\":{\"model\":\"namespace-service-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"invoke_template\":{}") != null);
}

test "venom_manifest: accepts venom_id alias and emits venom ABI metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "venom.json",
        .data =
        \\{
        \\  "venom_id": "doc-convert",
        \\  "kind": "converter",
        \\  "runtime": {"type": "native_proc", "abi": "venom-driver-v1"}
        \\}
        ,
    });

    const abs = try tmp.dir.realpathAlloc(allocator, "venom.json");
    defer allocator.free(abs);

    const loaded = try loadVenomManifestFile(allocator, abs, "node-22");
    try std.testing.expect(loaded != null);
    var service = loaded.?;
    defer service.deinit(allocator);

    try std.testing.expectEqualStrings("doc-convert", service.venom_id);
    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"venom_id\":\"doc-convert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, service.venom_json, "\"abi\":\"venom-driver-v1\"") != null);
}
