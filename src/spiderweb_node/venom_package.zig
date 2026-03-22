const std = @import("std");

pub const Error = error{
    InvalidPayload,
};

pub const VenomPackage = struct {
    venom_id: []u8,
    kind: []u8,
    version: []u8,
    categories_json: []u8,
    hosts_json: []u8,
    projection_modes_json: []u8,
    requirements_json: []u8,
    capabilities_json: []u8,
    ops_json: []u8,
    runtime_json: []u8,
    permissions_json: []u8,
    schema_json: []u8,
    help_md: ?[]u8 = null,

    pub fn deinit(self: *VenomPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        allocator.free(self.kind);
        allocator.free(self.version);
        allocator.free(self.categories_json);
        allocator.free(self.hosts_json);
        allocator.free(self.projection_modes_json);
        allocator.free(self.requirements_json);
        allocator.free(self.capabilities_json);
        allocator.free(self.ops_json);
        allocator.free(self.runtime_json);
        allocator.free(self.permissions_json);
        allocator.free(self.schema_json);
        if (self.help_md) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn deinitPackages(
    allocator: std.mem.Allocator,
    packages: *std.ArrayListUnmanaged(VenomPackage),
) void {
    for (packages.items) |*package| package.deinit(allocator);
    packages.deinit(allocator);
    packages.* = .{};
}

pub fn replacePackagesFromJsonValue(
    allocator: std.mem.Allocator,
    packages: *std.ArrayListUnmanaged(VenomPackage),
    raw: std.json.Value,
) !void {
    if (raw != .array) return Error.InvalidPayload;

    var next = std.ArrayListUnmanaged(VenomPackage){};
    errdefer {
        for (next.items) |*package| package.deinit(allocator);
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

        var package = VenomPackage{
            .venom_id = try allocator.dupe(u8, venom_id),
            .kind = try allocator.dupe(u8, kind),
            .version = try allocator.dupe(u8, version),
            .categories_json = if (obj.get("categories")) |value|
                try encodeArrayValue(allocator, value)
            else
                try allocator.dupe(u8, "[]"),
            .hosts_json = if (obj.get("hosts")) |value|
                try encodeArrayValue(allocator, value)
            else
                try allocator.dupe(u8, "[]"),
            .projection_modes_json = if (obj.get("projection_modes")) |value|
                try encodeArrayValue(allocator, value)
            else
                try allocator.dupe(u8, "[]"),
            .requirements_json = if (obj.get("requirements")) |value|
                try encodeObjectValue(allocator, value)
            else
                try allocator.dupe(u8, "{}"),
            .capabilities_json = if (obj.get("capabilities")) |value|
                try encodeObjectValue(allocator, value)
            else
                try allocator.dupe(u8, "{}"),
            .ops_json = if (obj.get("ops")) |value|
                try encodeObjectValue(allocator, value)
            else
                try allocator.dupe(u8, "{}"),
            .runtime_json = if (obj.get("runtime")) |value|
                try encodeObjectValue(allocator, value)
            else
                try allocator.dupe(u8, "{}"),
            .permissions_json = if (obj.get("permissions")) |value|
                try encodeObjectValue(allocator, value)
            else
                try allocator.dupe(u8, "{}"),
            .schema_json = if (obj.get("schema")) |value|
                try encodeObjectValue(allocator, value)
            else
                try allocator.dupe(u8, "{}"),
            .help_md = if (obj.get("help_md")) |help_value| blk: {
                if (help_value != .string) return Error.InvalidPayload;
                if (help_value.string.len == 0 or help_value.string.len > 64 * 1024) return Error.InvalidPayload;
                break :blk try allocator.dupe(u8, help_value.string);
            } else null,
        };
        errdefer package.deinit(allocator);

        try next.append(allocator, package);
    }

    deinitPackages(allocator, packages);
    packages.* = next;
}

pub fn appendPackageJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    package: VenomPackage,
) !void {
    const escaped_id = try jsonEscape(allocator, package.venom_id);
    defer allocator.free(escaped_id);
    const escaped_kind = try jsonEscape(allocator, package.kind);
    defer allocator.free(escaped_kind);
    const escaped_version = try jsonEscape(allocator, package.version);
    defer allocator.free(escaped_version);

    try out.writer(allocator).print(
        "{{\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"{s}\",\"categories\":{s},\"hosts\":{s},\"projection_modes\":{s},\"requirements\":{s},\"capabilities\":{s},\"ops\":{s},\"runtime\":{s},\"permissions\":{s},\"schema\":{s}",
        .{
            escaped_id,
            escaped_kind,
            escaped_version,
            package.categories_json,
            package.hosts_json,
            package.projection_modes_json,
            package.requirements_json,
            package.capabilities_json,
            package.ops_json,
            package.runtime_json,
            package.permissions_json,
            package.schema_json,
        },
    );
    if (package.help_md) |help| {
        const escaped_help = try jsonEscape(allocator, help);
        defer allocator.free(escaped_help);
        try out.writer(allocator).print(",\"help_md\":\"{s}\"}}", .{escaped_help});
        return;
    }
    try out.appendSlice(allocator, "}");
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

fn encodeArrayValue(allocator: std.mem.Allocator, raw: std.json.Value) ![]u8 {
    if (raw != .array) return Error.InvalidPayload;
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
}

fn encodeObjectValue(allocator: std.mem.Allocator, raw: std.json.Value) ![]u8 {
    if (raw != .object) return Error.InvalidPayload;
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
}

fn validateIdentifier(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return Error.InvalidPayload;
    for (value, 0..) |ch, idx| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') continue;
        if (idx > 0 and ch == ':') continue;
        return Error.InvalidPayload;
    }
}

fn validateDisplayString(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return Error.InvalidPayload;
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (value) |ch| switch (ch) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, ch),
    };
    return out.toOwnedSlice(allocator);
}

test "venom_package: parses and re-renders packages array" {
    const allocator = std.testing.allocator;
    const raw =
        \\[
        \\  {
        \\    "venom_id":"git",
        \\    "kind":"git",
        \\    "version":"1",
        \\    "categories":["developer","scm"],
        \\    "hosts":["spiderweb"],
        \\    "projection_modes":["workspace_service"],
        \\    "requirements":{"venoms":["mounts"]},
        \\    "capabilities":{"invoke":true},
        \\    "ops":{"model":"namespace"},
        \\    "runtime":{"type":"builtin"},
        \\    "permissions":{"default":"allow-by-default"},
        \\    "schema":{"model":"namespace-mount"},
        \\    "help_md":"Git service"
        \\  }
        \\]
    ;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    var packages = std.ArrayListUnmanaged(VenomPackage){};
    defer deinitPackages(allocator, &packages);
    try replacePackagesFromJsonValue(allocator, &packages, parsed.value);

    try std.testing.expectEqual(@as(usize, 1), packages.items.len);
    try std.testing.expectEqualStrings("git", packages.items[0].venom_id);
    try std.testing.expect(std.mem.indexOf(u8, packages.items[0].projection_modes_json, "\"workspace_service\"") != null);

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    try appendPackageJson(allocator, &out, packages.items[0]);
    try out.append(allocator, ']');

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"venom_id\":\"git\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"projection_modes\":[\"workspace_service\"]") != null);
}
