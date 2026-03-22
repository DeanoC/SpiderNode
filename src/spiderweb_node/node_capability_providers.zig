const std = @import("std");
const fs_node_ops = @import("fs_node_ops.zig");
const venom_contracts = @import("venom_contracts.zig");

pub const NodeLabelArg = struct {
    key: []const u8,
    value: []const u8,
};

pub const ExtraVenomArg = struct {
    venom_id: []const u8,
    venom_json: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    enable_fs_venom: bool = true,
    fs_export_count: usize = 0,
    fs_rw_export_count: usize = 0,
    terminal_ids: std.ArrayListUnmanaged([]u8) = .{},
    labels: std.ArrayListUnmanaged(NodeLabel) = .{},
    extra_venoms: std.ArrayListUnmanaged(ExtraVenom) = .{},

    pub const InitOptions = struct {
        enable_fs_venom: bool = true,
        export_specs: []const fs_node_ops.ExportSpec = &.{},
        terminal_ids: []const []const u8 = &.{},
        labels: []const NodeLabelArg = &.{},
        extra_venoms: []const ExtraVenomArg = &.{},
    };

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Registry {
        var registry = Registry{
            .allocator = allocator,
            .enable_fs_venom = options.enable_fs_venom,
            .fs_export_count = options.export_specs.len,
            .fs_rw_export_count = countRwExports(options.export_specs),
        };
        errdefer registry.deinit();

        var terminal_ids = std.StringHashMapUnmanaged(void){};
        defer terminal_ids.deinit(allocator);
        for (options.terminal_ids) |terminal_id| {
            try validateIdentifier(terminal_id, 128);
            if (terminal_ids.contains(terminal_id)) return error.InvalidProviderConfig;
            try terminal_ids.put(allocator, terminal_id, {});
            try registry.terminal_ids.append(allocator, try allocator.dupe(u8, terminal_id));
        }

        var label_keys = std.StringHashMapUnmanaged(void){};
        defer label_keys.deinit(allocator);
        for (options.labels) |item| {
            try validateIdentifier(item.key, 128);
            try validateLabelValue(item.value, 512);
            if (label_keys.contains(item.key)) return error.InvalidProviderConfig;
            try label_keys.put(allocator, item.key, {});
            try registry.labels.append(allocator, .{
                .key = try allocator.dupe(u8, item.key),
                .value = try allocator.dupe(u8, item.value),
            });
        }

        for (options.extra_venoms) |item| {
            try registry.addExtraVenom(item.venom_id, item.venom_json);
        }

        return registry;
    }

    pub fn clone(self: *const Registry, allocator: std.mem.Allocator) !Registry {
        var copy = Registry{
            .allocator = allocator,
            .enable_fs_venom = self.enable_fs_venom,
            .fs_export_count = self.fs_export_count,
            .fs_rw_export_count = self.fs_rw_export_count,
        };
        errdefer copy.deinit();

        for (self.terminal_ids.items) |terminal_id| {
            try copy.terminal_ids.append(allocator, try allocator.dupe(u8, terminal_id));
        }

        for (self.labels.items) |label| {
            try copy.labels.append(allocator, .{
                .key = try allocator.dupe(u8, label.key),
                .value = try allocator.dupe(u8, label.value),
            });
        }

        for (self.extra_venoms.items) |service| {
            try copy.extra_venoms.append(allocator, .{
                .venom_id = try allocator.dupe(u8, service.venom_id),
                .venom_json = try allocator.dupe(u8, service.venom_json),
            });
        }

        return copy;
    }

    pub fn deinit(self: *Registry) void {
        for (self.terminal_ids.items) |terminal_id| self.allocator.free(terminal_id);
        self.terminal_ids.deinit(self.allocator);
        for (self.labels.items) |*label| label.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        for (self.extra_venoms.items) |*service| service.deinit(self.allocator);
        self.extra_venoms.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearExtraVenoms(self: *Registry) void {
        for (self.extra_venoms.items) |*service| service.deinit(self.allocator);
        self.extra_venoms.clearRetainingCapacity();
    }

    pub fn addExtraVenom(self: *Registry, venom_id: []const u8, venom_json: []const u8) !void {
        try validateIdentifier(venom_id, 128);
        if (venomIdExists(self, venom_id)) return error.InvalidProviderConfig;
        try validateExtraVenomJson(self.allocator, venom_id, venom_json);
        try self.extra_venoms.append(self.allocator, .{
            .venom_id = try self.allocator.dupe(u8, venom_id),
            .venom_json = try self.allocator.dupe(u8, venom_json),
        });
    }

    pub fn buildVenomUpsertPayload(
        self: *const Registry,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        node_secret: []const u8,
        platform_os: []const u8,
        platform_arch: []const u8,
        platform_runtime_kind: []const u8,
    ) ![]u8 {
        const escaped_node_id = try jsonEscape(allocator, node_id);
        defer allocator.free(escaped_node_id);
        const escaped_node_secret = try jsonEscape(allocator, node_secret);
        defer allocator.free(escaped_node_secret);
        const escaped_os = try jsonEscape(allocator, platform_os);
        defer allocator.free(escaped_os);
        const escaped_arch = try jsonEscape(allocator, platform_arch);
        defer allocator.free(escaped_arch);
        const escaped_runtime = try jsonEscape(allocator, platform_runtime_kind);
        defer allocator.free(escaped_runtime);

        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(allocator);

        try out.writer(allocator).print(
            "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"{s}\"}}",
            .{ escaped_node_id, escaped_node_secret, escaped_os, escaped_arch, escaped_runtime },
        );

        if (self.labels.items.len > 0) {
            try out.appendSlice(allocator, ",\"labels\":{");
            for (self.labels.items, 0..) |label, idx| {
                if (idx != 0) try out.append(allocator, ',');
                const escaped_key = try jsonEscape(allocator, label.key);
                defer allocator.free(escaped_key);
                const escaped_value = try jsonEscape(allocator, label.value);
                defer allocator.free(escaped_value);
                try out.writer(allocator).print("\"{s}\":\"{s}\"", .{ escaped_key, escaped_value });
            }
            try out.append(allocator, '}');
        }

        try out.appendSlice(allocator, ",\"venoms\":[");
        var venom_count: usize = 0;

        if (self.enable_fs_venom) {
            try appendFsVenom(self, allocator, &out, node_id);
            venom_count += 1;
        }

        for (self.terminal_ids.items) |terminal_id| {
            if (venom_count > 0) try out.append(allocator, ',');
            try appendTerminalVenom(allocator, &out, node_id, terminal_id);
            venom_count += 1;
        }

        for (self.extra_venoms.items) |service| {
            if (venom_count > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, service.venom_json);
            venom_count += 1;
        }

        try out.appendSlice(allocator, "]}");
        return out.toOwnedSlice(allocator);
    }
};

const NodeLabel = struct {
    key: []u8,
    value: []u8,

    fn deinit(self: *NodeLabel, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const ExtraVenom = struct {
    venom_id: []u8,
    venom_json: []u8,

    fn deinit(self: *ExtraVenom, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        allocator.free(self.venom_json);
        self.* = undefined;
    }
};

fn countRwExports(specs: []const fs_node_ops.ExportSpec) usize {
    var rw_count: usize = 0;
    for (specs) |spec| {
        if (!spec.ro) rw_count += 1;
    }
    return rw_count;
}

fn venomIdExists(registry: *const Registry, venom_id: []const u8) bool {
    if (registry.enable_fs_venom and std.mem.eql(u8, venom_id, "fs")) return true;
    for (registry.terminal_ids.items) |terminal_id| {
        const prefix = "terminal-";
        if (venom_id.len != prefix.len + terminal_id.len) continue;
        if (!std.mem.startsWith(u8, venom_id, prefix)) continue;
        if (std.mem.eql(u8, venom_id[prefix.len..], terminal_id)) return true;
    }
    for (registry.extra_venoms.items) |item| {
        if (std.mem.eql(u8, item.venom_id, venom_id)) return true;
    }
    return false;
}

fn validateExtraVenomJson(
    allocator: std.mem.Allocator,
    expected_venom_id: []const u8,
    venom_json: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, venom_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderConfig;

    const venom_id_val = parsed.value.object.get("venom_id") orelse return error.InvalidProviderConfig;
    if (venom_id_val != .string) return error.InvalidProviderConfig;
    if (!std.mem.eql(u8, venom_id_val.string, expected_venom_id)) return error.InvalidProviderConfig;

    const kind_val = parsed.value.object.get("kind") orelse return error.InvalidProviderConfig;
    if (kind_val != .string or kind_val.string.len == 0) return error.InvalidProviderConfig;

    const state_val = parsed.value.object.get("state") orelse return error.InvalidProviderConfig;
    if (state_val != .string or state_val.string.len == 0) return error.InvalidProviderConfig;

    const endpoints_val = parsed.value.object.get("endpoints") orelse return error.InvalidProviderConfig;
    if (endpoints_val != .array or endpoints_val.array.items.len == 0) return error.InvalidProviderConfig;
}

fn appendFsVenom(
    registry: *const Registry,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    node_id: []const u8,
) !void {
    const escaped_node_id = try jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const endpoint = try std.fmt.allocPrint(allocator, "/nodes/{s}/fs", .{escaped_node_id});
    defer allocator.free(endpoint);

    try out.writer(allocator).print(
        "{{\"venom_id\":\"fs\",\"kind\":\"fs\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"{s}\"],\"capabilities\":{{\"rw\":{s},\"export_count\":{d}}},\"mounts\":[{{\"mount_id\":\"fs\",\"mount_path\":\"{s}\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"style\":\"plan9\"}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"fs_roots\":\"export-scoped\"}},\"schema\":{{\"model\":\"namespace-mount\"}},\"help_md\":\"Builtin filesystem namespace driver\"}}",
        .{
            endpoint,
            if (registry.fs_rw_export_count > 0) "true" else "false",
            registry.fs_export_count,
            endpoint,
        },
    );
}

fn appendTerminalVenom(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    node_id: []const u8,
    terminal_id: []const u8,
) !void {
    const escaped_node_id = try jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_terminal_id = try jsonEscape(allocator, terminal_id);
    defer allocator.free(escaped_terminal_id);

    const venom_id = try std.fmt.allocPrint(allocator, "terminal-{s}", .{escaped_terminal_id});
    defer allocator.free(venom_id);
    const endpoint = try std.fmt.allocPrint(allocator, "/nodes/{s}/terminal/{s}", .{ escaped_node_id, escaped_terminal_id });
    defer allocator.free(endpoint);

    try out.writer(allocator).print(
        "{{\"venom_id\":\"{s}\",\"kind\":\"terminal\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"{s}\"],\"capabilities\":{{\"pty\":true,\"terminal_id\":\"{s}\",\"invoke\":true}},\"mounts\":[{{\"mount_id\":\"{s}\",\"mount_path\":\"{s}\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"style\":\"plan9\",\"interactive\":true,\"invoke\":\"control/invoke.json\",\"paths\":{{\"exec\":\"control/invoke.json\"}}}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"venom-driver-v1\",\"entry\":\"internal-terminal-invoke\"}},\"permissions\":{{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"device\":\"terminal\"}},\"schema\":{s},\"invoke_template\":{s},\"help_md\":\"Terminal namespace driver\"}}",
        .{
            venom_id,
            endpoint,
            escaped_terminal_id,
            venom_id,
            endpoint,
            venom_contracts.terminal.descriptor_schema_json,
            venom_contracts.terminal.invoke_template_json,
        },
    );
}

fn validateIdentifier(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return error.InvalidProviderConfig;
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) continue;
        if (char == '-' or char == '_' or char == '.') continue;
        return error.InvalidProviderConfig;
    }
}

fn validateLabelValue(value: []const u8, max_len: usize) !void {
    if (value.len == 0 or value.len > max_len) return error.InvalidProviderConfig;
    for (value) |char| {
        if (char < 0x20) return error.InvalidProviderConfig;
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

test "node_capability_providers: build service upsert payload includes fs and terminal" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator, .{
        .enable_fs_venom = true,
        .export_specs = &[_]fs_node_ops.ExportSpec{
            .{ .name = "work", .path = ".", .ro = false },
            .{ .name = "read-only", .path = "/tmp", .ro = true },
        },
        .terminal_ids = &.{ "1", "2" },
        .labels = &.{
            .{ .key = "site", .value = "home-lab" },
            .{ .key = "tier", .value = "edge" },
        },
    });
    defer registry.deinit();

    const payload = try registry.buildVenomUpsertPayload(
        allocator,
        "node-99",
        "secret-abc",
        "linux",
        "amd64",
        "native",
    );
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"terminal-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"terminal-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"export_count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"site\":\"home-lab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"mounts\":[{\"mount_id\":\"fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"runtime\":{\"type\":\"builtin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"permissions\":{\"default\":\"deny-by-default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"ops\":{\"model\":\"namespace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema\":{\"model\":\"terminal-driver-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"invoke_template\":{\"tool_name\":\"terminal_exec\"") != null);
}

test "node_capability_providers: duplicate terminal id rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidProviderConfig, Registry.init(allocator, .{
        .terminal_ids = &.{ "1", "1" },
    }));
}

test "node_capability_providers: supports extra namespace service payloads" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator, .{
        .enable_fs_venom = false,
    });
    defer registry.deinit();

    const camera_json =
        \\{"venom_id":"camera-main","kind":"camera","version":"1","state":"online","endpoints":["/nodes/node-1/camera"],"capabilities":{"still":true},"mounts":[{"mount_id":"camera-main","mount_path":"/nodes/node-1/camera","state":"online"}],"ops":{"model":"namespace","style":"plan9"},"runtime":{"type":"native_proc","abi":"namespace-driver-v1"},"permissions":{"default":"deny-by-default"},"schema":{"model":"namespace-mount"}}
    ;
    try registry.addExtraVenom("camera-main", camera_json);

    const payload = try registry.buildVenomUpsertPayload(
        allocator,
        "node-1",
        "secret-xyz",
        "linux",
        "amd64",
        "native",
    );
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"camera-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"runtime\":{\"type\":\"native_proc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"mount_path\":\"/nodes/node-1/camera\"") != null);
}

test "node_capability_providers: rejects malformed extra service payloads" {
    const allocator = std.testing.allocator;
    var registry = try Registry.init(allocator, .{});
    defer registry.deinit();

    try std.testing.expectError(
        error.InvalidProviderConfig,
        registry.addExtraVenom("camera-main", "{\"venom_id\":\"other\",\"kind\":\"camera\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/camera\"]}"),
    );
    try std.testing.expectError(
        error.InvalidProviderConfig,
        registry.addExtraVenom("camera-main", "{\"venom_id\":\"camera-main\",\"kind\":\"camera\",\"state\":\"online\",\"endpoints\":[]}"),
    );
}
