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
    return allocator.dupe(u8, default_json);
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

pub fn runtimeKindMatchesRuntimeObject(obj: std.json.ObjectMap) bool {
    const declared = if (obj.get("runtime_kind")) |value|
        if (value == .string and value.string.len > 0) value.string else return false
    else
        return true;

    const runtime = obj.get("runtime") orelse return true;
    if (runtime != .object) return false;
    const runtime_type = if (runtime.object.get("type")) |value|
        if (value == .string and value.string.len > 0) value.string else return false
    else
        "builtin";

    if (std.mem.eql(u8, declared, "wasm")) return std.mem.eql(u8, runtime_type, "wasm");
    if (std.mem.eql(u8, declared, "native")) return !std.mem.eql(u8, runtime_type, "wasm");
    return false;
}
