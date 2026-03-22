const std = @import("std");

pub const HostKind = enum {
    static_linked,
    native_process,
    native_plugin,
    wasm,

    pub fn asString(self: HostKind) []const u8 {
        return switch (self) {
            .static_linked => "static_linked",
            .native_process => "native_process",
            .native_plugin => "native_plugin",
            .wasm => "wasm",
        };
    }
};

pub const HostContract = struct {
    host_kind: HostKind,
    runtime_kind: []const u8,
    abi: []const u8,
    contract: []const u8,
    supports_supervision: bool,
    supports_hot_reload: bool,
    supports_dynamic_mounts: bool,
};

pub fn classifyRuntimeKind(runtime_kind: []const u8) HostContract {
    if (std.mem.eql(u8, runtime_kind, "native_proc")) {
        return .{
            .host_kind = .native_process,
            .runtime_kind = "native_proc",
            .abi = "venom-driver-v1",
            .contract = "acheron.namespace-driver",
            .supports_supervision = true,
            .supports_hot_reload = true,
            .supports_dynamic_mounts = true,
        };
    }
    if (std.mem.eql(u8, runtime_kind, "native_inproc")) {
        return .{
            .host_kind = .native_plugin,
            .runtime_kind = "native_inproc",
            .abi = "venom-driver-v1",
            .contract = "acheron.namespace-driver",
            .supports_supervision = true,
            .supports_hot_reload = true,
            .supports_dynamic_mounts = true,
        };
    }
    if (std.mem.eql(u8, runtime_kind, "wasm")) {
        return .{
            .host_kind = .wasm,
            .runtime_kind = "wasm",
            .abi = "venom-driver-v1",
            .contract = "acheron.namespace-driver",
            .supports_supervision = true,
            .supports_hot_reload = true,
            .supports_dynamic_mounts = true,
        };
    }

    return .{
        .host_kind = .static_linked,
        .runtime_kind = if (runtime_kind.len > 0) runtime_kind else "builtin",
        .abi = "venom-driver-v1",
        .contract = "acheron.namespace-driver",
        .supports_supervision = true,
        .supports_hot_reload = false,
        .supports_dynamic_mounts = true,
    };
}

pub fn renderMetadataJson(allocator: std.mem.Allocator, runtime_kind: []const u8) ![]u8 {
    const contract = classifyRuntimeKind(runtime_kind);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":1,\"contract\":\"{s}\",\"abi\":\"{s}\",\"host_kind\":\"{s}\",\"runtime_kind\":\"{s}\",\"features\":{{\"supervision\":{},\"hot_reload\":{},\"dynamic_mounts\":{}}}}}",
        .{
            contract.contract,
            contract.abi,
            contract.host_kind.asString(),
            contract.runtime_kind,
            contract.supports_supervision,
            contract.supports_hot_reload,
            contract.supports_dynamic_mounts,
        },
    );
}

test "service_runtime_host: classification maps known runtime kinds" {
    try std.testing.expectEqual(HostKind.native_process, classifyRuntimeKind("native_proc").host_kind);
    try std.testing.expectEqual(HostKind.native_plugin, classifyRuntimeKind("native_inproc").host_kind);
    try std.testing.expectEqual(HostKind.wasm, classifyRuntimeKind("wasm").host_kind);
    try std.testing.expectEqual(HostKind.static_linked, classifyRuntimeKind("builtin").host_kind);
}
