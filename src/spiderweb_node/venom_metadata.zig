const std = @import("std");

pub fn encodeHostRolesJson(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    default_json: []const u8,
) ![]u8 {
    if (obj.get("host_roles")) |value| {
        if (value != .array) return error.InvalidPayload;
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    if (obj.get("hosts")) |value| {
        if (value != .array) return error.InvalidPayload;
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    return allocator.dupe(u8, default_json);
}

pub fn encodeBindingScopesJson(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    default_json: []const u8,
) ![]u8 {
    if (obj.get("binding_scopes")) |value| {
        if (value != .array) return error.InvalidPayload;
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    if (obj.get("projection_modes")) |value| {
        if (value != .array) return error.InvalidPayload;
        if (arrayContainsString(value, "worker_private")) return allocator.dupe(u8, "[\"agent\"]");
        if (arrayContainsString(value, "workspace_service")) return allocator.dupe(u8, "[\"workspace\"]");
        if (arrayContainsString(value, "node_export")) return allocator.dupe(u8, "[\"node\"]");
        if (arrayContainsString(value, "host_local")) return allocator.dupe(u8, "[\"workspace\"]");
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    return allocator.dupe(u8, default_json);
}

pub fn encodeProjectionModesJson(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    default_host_role: []const u8,
) ![]u8 {
    if (obj.get("projection_modes")) |value| {
        if (value != .array) return error.InvalidPayload;
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    const host_role = preferredHostRole(obj, default_host_role);
    const has_workspace = if (obj.get("binding_scopes")) |value| arrayContainsString(value, "workspace") else false;
    const has_agent = if (obj.get("binding_scopes")) |value| arrayContainsString(value, "agent") else false;
    const has_client = if (obj.get("binding_scopes")) |value| arrayContainsString(value, "client") else false;
    const has_node = if (obj.get("binding_scopes")) |value| arrayContainsString(value, "node") else false;

    if (std.mem.eql(u8, host_role, "spiderweb")) {
        return allocator.dupe(u8, if (has_workspace) "[\"host_local\",\"workspace_service\"]" else "[\"host_local\"]");
    }
    if (std.mem.eql(u8, host_role, "client") or std.mem.eql(u8, host_role, "worker")) {
        _ = has_agent;
        _ = has_client;
        return allocator.dupe(u8, "[\"worker_private\"]");
    }
    return allocator.dupe(u8, if (has_workspace) "[\"node_export\",\"workspace_service\"]" else if (has_node) "[\"node_export\"]" else "[\"node_export\"]");
}

pub fn inferRuntimeKindFromObject(obj: std.json.ObjectMap) []const u8 {
    if (obj.get("runtime_kind")) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    if (obj.get("runtime")) |value| {
        if (value == .object) {
            if (value.object.get("type")) |runtime_type| {
                if (runtime_type == .string and std.mem.eql(u8, runtime_type.string, "wasm")) return "wasm";
            }
        }
    }
    return "native";
}

pub fn inferProviderScopeFromObject(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    default_host_role: []const u8,
) ![]u8 {
    if (obj.get("provider_scope")) |value| {
        if (value != .string or value.string.len == 0) return error.InvalidPayload;
        return allocator.dupe(u8, value.string);
    }
    const host_role = preferredHostRole(obj, default_host_role);
    if (std.mem.eql(u8, host_role, "spiderweb")) return allocator.dupe(u8, "host_local");
    if (std.mem.eql(u8, host_role, "client") or std.mem.eql(u8, host_role, "worker")) return allocator.dupe(u8, "worker_private");
    return allocator.dupe(u8, "node_export");
}

fn preferredHostRole(obj: std.json.ObjectMap, default_host_role: []const u8) []const u8 {
    if (obj.get("host_roles")) |value| {
        if (firstArrayString(value)) |role| return role;
    }
    if (obj.get("hosts")) |value| {
        if (firstArrayString(value)) |role| return role;
    }
    return default_host_role;
}

fn firstArrayString(value: std.json.Value) ?[]const u8 {
    if (value != .array) return null;
    for (value.array.items) |item| {
        if (item == .string and item.string.len > 0) return item.string;
    }
    return null;
}

fn arrayContainsString(value: std.json.Value, needle: []const u8) bool {
    if (value != .array) return false;
    for (value.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, needle)) return true;
    }
    return false;
}
