const std = @import("std");
const builtin = @import("builtin");
const fs_node_server = @import("fs_node_server.zig");
const fs_node_service = @import("fs_node_service.zig");
const fs_node_ops = @import("fs_node_ops.zig");
const fs_protocol = @import("spiderweb_fs").fs_protocol;
const node_capability_providers = @import("node_capability_providers.zig");
const plugin_loader_native = @import("plugin_loader_native.zig");
const plugin_loader_process = @import("plugin_loader_process.zig");
const plugin_loader_wasm = @import("plugin_loader_wasm.zig");
const zwasm_runtime = @import("zwasm_runtime.zig");
const venom_manifest = @import("venom_manifest.zig");
const venom_runtime_manager = @import("venom_runtime_manager.zig");
const venom_contracts = @import("venom_contracts.zig");
const namespace_driver = @import("namespace_driver.zig");
const unified = @import("spider-protocol").unified;

const default_state_path = ".spiderweb-fs-node-state.json";
const default_node_name = "spiderweb-fs-node";
const default_control_backoff_ms: u64 = 5_000;
const default_control_backoff_max_ms: u64 = 60_000;
const default_lease_ttl_ms: u64 = 15 * 60 * 1000;
const default_lease_refresh_interval_ms: u64 = 60 * 1000;
const default_manifest_reload_interval_ms: u64 = 2_000;
const default_runtime_probe_catalog_sync_interval_ms: u64 = 1_000;
const control_reply_timeout_ms: i32 = 45_000;
const fsrpc_node_protocol_version = "spiderweb-fs";
const fsrpc_node_proto_id: i64 = 2;
const control_node_not_found_code = "node_not_found";
const control_node_auth_failed_code = "node_auth_failed";
const inproc_helper_max_io_bytes: usize = 1024 * 1024;
const namespace_venom_schema_default_json = venom_contracts.namespace_service.descriptor_schema_json;
const namespace_venom_invoke_template_default_json = venom_contracts.namespace_service.default_invoke_template_json;

const PairMode = enum {
    invite,
    request,
};

const ParsedWsUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
};

const WsFrame = struct {
    opcode: u8,
    payload: []u8,

    fn deinit(self: *WsFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const ControlConnectOptions = struct {
    url: []const u8,
    auth_token: ?[]const u8 = null,
};

const ControlResult = union(enum) {
    payload_json: []u8,
    remote_error: RemoteError,

    fn deinit(self: *ControlResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .payload_json => |value| allocator.free(value),
            .remote_error => |*err| err.deinit(allocator),
        }
        self.* = undefined;
    }
};

const RemoteError = struct {
    code: []u8,
    message: []u8,

    fn deinit(self: *RemoteError, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        self.* = undefined;
    }
};

const NodeJoinPayload = struct {
    node_id: []u8,
    node_secret: []u8,
    lease_token: []u8,
    lease_expires_at_ms: i64,
    node_name: ?[]u8 = null,
    fs_url: ?[]u8 = null,

    fn deinit(self: *NodeJoinPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.node_id);
        allocator.free(self.node_secret);
        allocator.free(self.lease_token);
        if (self.node_name) |value| allocator.free(value);
        if (self.fs_url) |value| allocator.free(value);
        self.* = undefined;
    }
};

const NodePairState = struct {
    node_id: ?[]u8 = null,
    node_secret: ?[]u8 = null,
    lease_token: ?[]u8 = null,
    lease_expires_at_ms: i64 = 0,
    request_id: ?[]u8 = null,
    node_name: ?[]u8 = null,
    fs_url: ?[]u8 = null,

    fn deinit(self: *NodePairState, allocator: std.mem.Allocator) void {
        if (self.node_id) |value| allocator.free(value);
        if (self.node_secret) |value| allocator.free(value);
        if (self.lease_token) |value| allocator.free(value);
        if (self.request_id) |value| allocator.free(value);
        if (self.node_name) |value| allocator.free(value);
        if (self.fs_url) |value| allocator.free(value);
        self.* = .{};
    }

    fn isPaired(self: *const NodePairState) bool {
        return self.node_id != null and self.node_secret != null;
    }

    fn clearRequest(self: *NodePairState, allocator: std.mem.Allocator) void {
        if (self.request_id) |value| allocator.free(value);
        self.request_id = null;
    }

    fn setRequestId(self: *NodePairState, allocator: std.mem.Allocator, request_id: []const u8) !void {
        self.clearRequest(allocator);
        self.request_id = try allocator.dupe(u8, request_id);
    }

    fn setFromJoin(self: *NodePairState, allocator: std.mem.Allocator, join: NodeJoinPayload) !void {
        if (self.node_id) |value| allocator.free(value);
        if (self.node_secret) |value| allocator.free(value);
        if (self.lease_token) |value| allocator.free(value);
        if (self.node_name) |value| allocator.free(value);
        if (self.fs_url) |value| allocator.free(value);

        self.node_id = join.node_id;
        self.node_secret = join.node_secret;
        self.lease_token = join.lease_token;
        self.lease_expires_at_ms = join.lease_expires_at_ms;
        self.node_name = if (join.node_name) |value| value else null;
        self.fs_url = if (join.fs_url) |value| value else null;
        self.clearRequest(allocator);
    }

    fn adoptFrom(self: *NodePairState, allocator: std.mem.Allocator, incoming: *NodePairState) void {
        self.deinit(allocator);
        self.* = incoming.*;
        incoming.* = .{};
    }
};

const ControlPairingOptions = struct {
    connect: ControlConnectOptions,
    pair_mode: PairMode,
    invite_token: ?[]const u8,
    operator_token: ?[]const u8,
    node_name: []const u8,
    fs_url: []const u8,
    lease_ttl_ms: u64,
    state_path: []const u8,
    reconnect_backoff_ms: u64,
    reconnect_backoff_max_ms: u64,
};

const SharedVenomRegistry = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    registry: node_capability_providers.Registry,

    fn init(allocator: std.mem.Allocator, initial: *const node_capability_providers.Registry) !SharedVenomRegistry {
        return .{
            .allocator = allocator,
            .registry = try initial.clone(allocator),
        };
    }

    fn deinit(self: *SharedVenomRegistry) void {
        self.registry.deinit();
        self.* = undefined;
    }

    fn snapshot(self: *SharedVenomRegistry) !node_capability_providers.Registry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.registry.clone(self.allocator);
    }

    fn replaceFrom(self: *SharedVenomRegistry, incoming: *const node_capability_providers.Registry) !void {
        const next = try incoming.clone(self.allocator);
        self.mutex.lock();
        var old = self.registry;
        self.registry = next;
        self.mutex.unlock();
        old.deinit();
    }
};

const LeaseRefreshContext = struct {
    allocator: std.mem.Allocator,
    connect: ControlConnectOptions,
    state_path: []u8,
    fs_url: []u8,
    shared_venom_registry: *SharedVenomRegistry,
    lease_ttl_ms: u64,
    refresh_interval_ms: u64,
    reconnect_backoff_ms: u64,
    reconnect_backoff_max_ms: u64,
    stop_mutex: std.Thread.Mutex = .{},
    stop: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        connect: ControlConnectOptions,
        state_path: []const u8,
        fs_url: []const u8,
        shared_venom_registry: *SharedVenomRegistry,
        lease_ttl_ms: u64,
        refresh_interval_ms: u64,
        reconnect_backoff_ms: u64,
        reconnect_backoff_max_ms: u64,
    ) !LeaseRefreshContext {
        return .{
            .allocator = allocator,
            .connect = .{
                .url = try allocator.dupe(u8, connect.url),
                .auth_token = if (connect.auth_token) |token| try allocator.dupe(u8, token) else null,
            },
            .state_path = try allocator.dupe(u8, state_path),
            .fs_url = try allocator.dupe(u8, fs_url),
            .shared_venom_registry = shared_venom_registry,
            .lease_ttl_ms = lease_ttl_ms,
            .refresh_interval_ms = refresh_interval_ms,
            .reconnect_backoff_ms = reconnect_backoff_ms,
            .reconnect_backoff_max_ms = reconnect_backoff_max_ms,
        };
    }

    fn deinit(self: *LeaseRefreshContext) void {
        self.allocator.free(self.connect.url);
        if (self.connect.auth_token) |value| self.allocator.free(value);
        self.allocator.free(self.state_path);
        self.allocator.free(self.fs_url);
        self.* = undefined;
    }

    fn requestStop(self: *LeaseRefreshContext) void {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();
        self.stop = true;
    }

    fn shouldStop(self: *LeaseRefreshContext) bool {
        self.stop_mutex.lock();
        defer self.stop_mutex.unlock();
        return self.stop;
    }

    fn sleepWithStop(self: *LeaseRefreshContext, total_ms: u64) bool {
        if (total_ms == 0) return !self.shouldStop();

        var elapsed: u64 = 0;
        while (elapsed < total_ms) {
            if (self.shouldStop()) return false;
            const chunk_ms: u64 = @min(@as(u64, 250), total_ms - elapsed);
            std.Thread.sleep(chunk_ms * std.time.ns_per_ms);
            elapsed += chunk_ms;
        }

        return !self.shouldStop();
    }
};

const NamespaceVenomExportSpecOwned = struct {
    name: []u8,
    path: []u8,
    source_id: []u8,
    desc: []u8,
    venom_id: []u8,
    runtime_kind: fs_node_ops.NamespaceVenomRuntimeKind = .native_proc,
    executable_path: ?[]u8 = null,
    library_path: ?[]u8 = null,
    module_path: ?[]u8 = null,
    wasm_entrypoint: ?[]u8 = null,
    args: std.ArrayListUnmanaged([]u8) = .{},
    timeout_ms: u64 = 30_000,
    fuel: ?u64 = null,
    max_memory_bytes: ?u64 = null,
    help_md: ?[]u8 = null,
    schema_json: ?[]u8 = null,
    invoke_template_json: ?[]u8 = null,

    fn deinit(self: *NamespaceVenomExportSpecOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.source_id);
        allocator.free(self.desc);
        allocator.free(self.venom_id);
        if (self.executable_path) |value| allocator.free(value);
        if (self.library_path) |value| allocator.free(value);
        if (self.module_path) |value| allocator.free(value);
        if (self.wasm_entrypoint) |value| allocator.free(value);
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
        if (self.help_md) |value| allocator.free(value);
        if (self.schema_json) |value| allocator.free(value);
        if (self.invoke_template_json) |value| allocator.free(value);
        self.* = undefined;
    }

    fn asExportSpec(self: *const NamespaceVenomExportSpecOwned) fs_node_ops.ExportSpec {
        return .{
            .name = self.name,
            .path = self.path,
            .ro = false,
            .desc = self.desc,
            .source_kind = .namespace,
            .source_id = self.source_id,
            .namespace_venom = .{
                .venom_id = self.venom_id,
                .runtime_kind = self.runtime_kind,
                .executable_path = self.executable_path,
                .library_path = self.library_path,
                .module_path = self.module_path,
                .wasm_entrypoint = self.wasm_entrypoint,
                .args = self.args.items,
                .timeout_ms = self.timeout_ms,
                .fuel = self.fuel,
                .max_memory_bytes = self.max_memory_bytes,
                .help_md = self.help_md,
                .schema_json = self.schema_json,
                .invoke_template_json = self.invoke_template_json,
            },
        };
    }
};

const RuntimeProbeDriverCtx = struct {
    mutex: std.Thread.Mutex = .{},
    venom_id: []u8,
    runtime_type: namespace_driver.RuntimeType,
    executable_path: ?[]u8 = null,
    library_path: ?[]u8 = null,
    module_path: ?[]u8 = null,
    entrypoint: ?[]u8 = null,
    invoke_symbol: ?[]u8 = null,
    in_process: bool = true,
    args: std.ArrayListUnmanaged([]u8) = .{},
    running: bool = false,

    fn deinit(self: *RuntimeProbeDriverCtx, allocator: std.mem.Allocator) void {
        allocator.free(self.venom_id);
        if (self.executable_path) |value| allocator.free(value);
        if (self.library_path) |value| allocator.free(value);
        if (self.module_path) |value| allocator.free(value);
        if (self.entrypoint) |value| allocator.free(value);
        if (self.invoke_symbol) |value| allocator.free(value);
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
        self.* = undefined;
    }
};

const runtime_probe_driver_vtable = namespace_driver.DriverVTable{
    .start = runtimeProbeDriverStart,
    .stop = runtimeProbeDriverStop,
    .health = runtimeProbeDriverHealth,
    .invoke_json = runtimeProbeDriverInvokeJson,
};

const RuntimeProbeDriverStore = struct {
    allocator: std.mem.Allocator,
    contexts: std.ArrayListUnmanaged(*RuntimeProbeDriverCtx) = .{},

    fn init(allocator: std.mem.Allocator) RuntimeProbeDriverStore {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RuntimeProbeDriverStore) void {
        self.clear();
        self.contexts.deinit(self.allocator);
        self.* = undefined;
    }

    fn clear(self: *RuntimeProbeDriverStore) void {
        for (self.contexts.items) |ctx| {
            ctx.deinit(self.allocator);
            self.allocator.destroy(ctx);
        }
        self.contexts.clearRetainingCapacity();
    }

    fn driverFromServiceJson(
        self: *RuntimeProbeDriverStore,
        descriptor: *const namespace_driver.VenomDescriptor,
        venom_json: []const u8,
    ) !?namespace_driver.DriverHandle {
        const maybe_ctx = try runtimeProbeDriverContextFromServiceJson(
            self.allocator,
            descriptor,
            venom_json,
        );
        const ctx = maybe_ctx orelse return null;
        errdefer {
            ctx.deinit(self.allocator);
            self.allocator.destroy(ctx);
        }
        try self.contexts.append(self.allocator, ctx);
        return .{
            .ctx = ctx,
            .vtable = &runtime_probe_driver_vtable,
        };
    }
};

fn runtimeProbeDriverContextFromServiceJson(
    allocator: std.mem.Allocator,
    descriptor: *const namespace_driver.VenomDescriptor,
    venom_json: []const u8,
) !?*RuntimeProbeDriverCtx {
    if (descriptor.runtime_type == .builtin) return null;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, venom_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;

    const runtime = parsed.value.object.get("runtime") orelse return null;
    if (runtime != .object) return error.InvalidArguments;

    var ctx = try allocator.create(RuntimeProbeDriverCtx);
    ctx.* = .{
        .venom_id = try allocator.dupe(u8, descriptor.venom_id),
        .runtime_type = descriptor.runtime_type,
    };
    errdefer {
        ctx.deinit(allocator);
        allocator.destroy(ctx);
    }

    switch (descriptor.runtime_type) {
        .builtin => return null,
        .native_proc => {
            const executable_path = runtime.object.get("executable_path") orelse return null;
            if (executable_path != .string or executable_path.string.len == 0) return error.InvalidArguments;
            ctx.executable_path = try allocator.dupe(u8, executable_path.string);
            try runtimeProbeParseRuntimeArgs(allocator, runtime.object, &ctx.args);
        },
        .native_inproc => {
            const library_path = runtime.object.get("library_path") orelse return null;
            if (library_path != .string or library_path.string.len == 0) return error.InvalidArguments;
            ctx.library_path = try allocator.dupe(u8, library_path.string);
            if (runtime.object.get("in_process")) |in_process| {
                if (in_process != .bool) return error.InvalidArguments;
                ctx.in_process = in_process.bool;
            }
            if (runtime.object.get("invoke_symbol")) |invoke_symbol| {
                if (invoke_symbol != .string or invoke_symbol.string.len == 0) return error.InvalidArguments;
                ctx.invoke_symbol = try allocator.dupe(u8, invoke_symbol.string);
            } else {
                ctx.invoke_symbol = try allocator.dupe(u8, plugin_loader_native.default_invoke_symbol);
            }
            try runtimeProbeParseRuntimeArgs(allocator, runtime.object, &ctx.args);
        },
        .wasm => {
            const module_path = runtime.object.get("module_path") orelse return null;
            if (module_path != .string or module_path.string.len == 0) return error.InvalidArguments;
            ctx.module_path = try allocator.dupe(u8, module_path.string);
            if (runtime.object.get("entrypoint")) |entrypoint| {
                if (entrypoint != .string or entrypoint.string.len == 0) return error.InvalidArguments;
                ctx.entrypoint = try allocator.dupe(u8, entrypoint.string);
            } else {
                ctx.entrypoint = try allocator.dupe(u8, "spiderweb_driver_v1");
            }
            try runtimeProbeParseRuntimeArgs(allocator, runtime.object, &ctx.args);
        },
    }

    return ctx;
}

fn runtimeProbeParseRuntimeArgs(
    allocator: std.mem.Allocator,
    runtime: std.json.ObjectMap,
    args: *std.ArrayListUnmanaged([]u8),
) !void {
    if (runtime.get("args")) |raw_args| {
        if (raw_args != .array) return error.InvalidArguments;
        for (raw_args.array.items) |item| {
            if (item != .string or item.string.len == 0) return error.InvalidArguments;
            try args.append(allocator, try allocator.dupe(u8, item.string));
        }
    }
}

fn runtimeProbeDriverStart(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
    const ctx: *RuntimeProbeDriverCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    const health = runtimeProbeEvaluateHealth(allocator, ctx);
    if (health.state != .online) return error.DriverProbeOffline;
    ctx.running = true;
}

fn runtimeProbeDriverStop(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) void {
    _ = allocator;
    const ctx: *RuntimeProbeDriverCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ctx.running = false;
}

fn runtimeProbeDriverHealth(ctx_ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!namespace_driver.Health {
    const ctx: *RuntimeProbeDriverCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (!ctx.running) {
        return .{
            .state = .offline,
            .detail = "runtime probe stopped",
        };
    }
    return runtimeProbeEvaluateHealth(allocator, ctx);
}

fn runtimeProbeDriverInvokeJson(
    ctx_ptr: *anyopaque,
    allocator: std.mem.Allocator,
    op: []const u8,
    args_json: []const u8,
) anyerror![]u8 {
    _ = ctx_ptr;
    _ = op;
    return allocator.dupe(u8, args_json);
}

fn runtimeProbeEvaluateHealth(
    allocator: std.mem.Allocator,
    ctx: *RuntimeProbeDriverCtx,
) namespace_driver.Health {
    return switch (ctx.runtime_type) {
        .builtin => .{
            .state = .online,
            .detail = "builtin runtime",
        },
        .native_proc => runtimeProbeEvaluateNativeProc(allocator, ctx),
        .native_inproc => runtimeProbeEvaluateNativeInproc(allocator, ctx),
        .wasm => runtimeProbeEvaluateWasm(allocator, ctx),
    };
}

fn runtimeProbeEvaluateNativeProc(
    allocator: std.mem.Allocator,
    ctx: *RuntimeProbeDriverCtx,
) namespace_driver.Health {
    const executable_path = ctx.executable_path orelse return .{
        .state = .offline,
        .detail = "missing executable_path",
    };

    const args = allocator.alloc([]const u8, ctx.args.items.len) catch return .{
        .state = .degraded,
        .detail = "out_of_memory",
    };
    defer allocator.free(args);
    for (ctx.args.items, 0..) |arg, idx| args[idx] = arg;

    var process = plugin_loader_process.launch(allocator, .{
        .executable_path = executable_path,
        .args = args,
    }) catch |err| return runtimeProbeHealthFromError(err);
    defer process.deinit(allocator);

    runtimeProbeEnsureRegularFile(executable_path) catch |err| return runtimeProbeHealthFromError(err);
    return .{
        .state = .online,
        .detail = "native_proc ready",
    };
}

fn runtimeProbeEvaluateNativeInproc(
    allocator: std.mem.Allocator,
    ctx: *RuntimeProbeDriverCtx,
) namespace_driver.Health {
    const library_path = ctx.library_path orelse return .{
        .state = .offline,
        .detail = "missing library_path",
    };
    const invoke_symbol = ctx.invoke_symbol orelse plugin_loader_native.default_invoke_symbol;

    var plugin = plugin_loader_native.load(allocator, .{
        .library_path = library_path,
        .in_process = ctx.in_process,
        .invoke_symbol = invoke_symbol,
        .validate_abi_symbol = true,
    }) catch |err| return runtimeProbeHealthFromError(err);
    defer plugin.deinit(allocator);

    return .{
        .state = .online,
        .detail = "native_inproc ready",
    };
}

fn runtimeProbeEvaluateWasm(
    allocator: std.mem.Allocator,
    ctx: *RuntimeProbeDriverCtx,
) namespace_driver.Health {
    const module_path = ctx.module_path orelse return .{
        .state = .offline,
        .detail = "missing module_path",
    };
    const entrypoint = ctx.entrypoint orelse "spiderweb_driver_v1";

    const args = allocator.alloc([]const u8, ctx.args.items.len) catch return .{
        .state = .degraded,
        .detail = "out_of_memory",
    };
    defer allocator.free(args);
    for (ctx.args.items, 0..) |arg, idx| args[idx] = arg;

    zwasm_runtime.validateConfig(.{
        .module_path = module_path,
        .entrypoint = entrypoint,
        .args = args,
    }) catch |err| return runtimeProbeHealthFromError(err);

    var plugin = plugin_loader_wasm.load(allocator, .{
        .module_path = module_path,
        .entrypoint = entrypoint,
        .args = args,
    }) catch |err| return runtimeProbeHealthFromError(err);
    defer plugin.deinit(allocator);

    runtimeProbeEnsureRegularFile(module_path) catch |err| return runtimeProbeHealthFromError(err);

    return .{
        .state = .online,
        .detail = "wasm ready",
    };
}

fn runtimeProbeEnsureRegularFile(path: []const u8) !void {
    const stat = try std.fs.cwd().statFile(path);
    if (stat.kind == .directory) return error.PathIsDirectory;
}

fn runtimeProbeLooksLikePath(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, '/')) |_| return true;
    if (std.mem.indexOfScalar(u8, value, '\\')) |_| return true;
    if (std.mem.startsWith(u8, value, ".")) return true;
    if (value.len >= 2 and std.ascii.isAlphabetic(value[0]) and value[1] == ':') return true;
    return false;
}

fn runtimeProbeHealthFromError(err: anyerror) namespace_driver.Health {
    return switch (err) {
        error.FileNotFound, error.PathIsDirectory => .{
            .state = .offline,
            .detail = @errorName(err),
        },
        else => .{
            .state = .degraded,
            .detail = @errorName(err),
        },
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--internal-inproc-invoke")) {
        runInternalInprocInvoke(allocator, args[2..]) catch |err| {
            std.debug.print("internal inproc invoke failed: {s}\n", .{@errorName(err)});
            std.process.exit(125);
        };
        unreachable;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--internal-terminal-invoke")) {
        runInternalTerminalInvoke(allocator, args[2..]) catch |err| {
            std.debug.print("internal terminal invoke failed: {s}\n", .{@errorName(err)});
            std.process.exit(125);
        };
        unreachable;
    }

    var bind_addr: []const u8 = "127.0.0.1";
    var port: u16 = 18891;
    var exports = std.ArrayListUnmanaged(fs_node_ops.ExportSpec){};
    defer exports.deinit(allocator);
    var auth_token: ?[]const u8 = null;
    var auth_token_from_pair_state = false;
    var control_url: ?[]const u8 = null;
    var control_auth_token: ?[]const u8 = null;
    var operator_token: ?[]const u8 = null;
    var pair_mode: PairMode = .request;
    var pair_mode_explicit = false;
    var invite_token: ?[]const u8 = null;
    var node_name: []const u8 = default_node_name;
    var advertised_fs_url: ?[]const u8 = null;
    var state_path: []const u8 = default_state_path;
    var lease_ttl_ms: u64 = default_lease_ttl_ms;
    var refresh_interval_ms: u64 = default_lease_refresh_interval_ms;
    var manifest_reload_interval_ms: u64 = default_manifest_reload_interval_ms;
    var reconnect_backoff_ms: u64 = default_control_backoff_ms;
    var reconnect_backoff_max_ms: u64 = default_control_backoff_max_ms;
    var enable_fs_venom = true;
    var terminal_ids = std.ArrayListUnmanaged([]const u8){};
    defer terminal_ids.deinit(allocator);
    var node_labels = std.ArrayListUnmanaged(node_capability_providers.NodeLabelArg){};
    defer node_labels.deinit(allocator);
    var venom_manifest_paths = std.ArrayListUnmanaged([]const u8){};
    defer venom_manifest_paths.deinit(allocator);
    var venom_dirs = std.ArrayListUnmanaged([]const u8){};
    defer venom_dirs.deinit(allocator);
    var terminal_namespace_exports = std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned){};
    defer {
        deinitNamespaceVenomExportList(allocator, &terminal_namespace_exports);
        terminal_namespace_exports.deinit(allocator);
    }
    var runtime_namespace_exports = std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned){};
    defer {
        deinitNamespaceVenomExportList(allocator, &runtime_namespace_exports);
        runtime_namespace_exports.deinit(allocator);
    }
    var effective_exports = std.ArrayListUnmanaged(fs_node_ops.ExportSpec){};
    defer effective_exports.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bind")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            bind_addr = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--export")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            const spec = parseExportFlag(args[i]) catch return error.InvalidArguments;
            try exports.append(allocator, spec);
        } else if (std.mem.eql(u8, arg, "--auth-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            auth_token = args[i];
        } else if (std.mem.eql(u8, arg, "--control-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            control_url = args[i];
        } else if (std.mem.eql(u8, arg, "--control-auth-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            control_auth_token = args[i];
        } else if (std.mem.eql(u8, arg, "--operator-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            operator_token = args[i];
        } else if (std.mem.eql(u8, arg, "--pair-mode")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            pair_mode = parsePairMode(args[i]) orelse return error.InvalidArguments;
            pair_mode_explicit = true;
        } else if (std.mem.eql(u8, arg, "--invite-token")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            invite_token = args[i];
        } else if (std.mem.eql(u8, arg, "--node-name")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            node_name = args[i];
        } else if (std.mem.eql(u8, arg, "--fs-url")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            advertised_fs_url = args[i];
        } else if (std.mem.eql(u8, arg, "--state-file")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            state_path = args[i];
        } else if (std.mem.eql(u8, arg, "--lease-ttl-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            lease_ttl_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--refresh-interval-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            refresh_interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--manifest-reload-interval-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            manifest_reload_interval_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--reconnect-backoff-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            reconnect_backoff_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--reconnect-backoff-max-ms")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            reconnect_backoff_max_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--no-fs-venom")) {
            enable_fs_venom = false;
        } else if (std.mem.eql(u8, arg, "--terminal-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            try terminal_ids.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--label")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            try node_labels.append(allocator, try parseLabelArg(args[i]));
        } else if (std.mem.eql(u8, arg, "--venom-manifest")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            try venom_manifest_paths.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--venoms-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            try venom_dirs.append(allocator, args[i]);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            try printHelp();
            return error.InvalidArguments;
        }
    }

    if (!pair_mode_explicit and invite_token != null) {
        pair_mode = .invite;
    }
    try buildTerminalNamespaceExports(
        allocator,
        terminal_ids.items,
        args[0],
        &terminal_namespace_exports,
    );

    const effective_fs_url = if (advertised_fs_url) |value|
        value
    else
        try std.fmt.allocPrint(allocator, "ws://{s}:{d}/fs", .{ bind_addr, port });
    defer if (advertised_fs_url == null) allocator.free(effective_fs_url);

    var venom_registry = try node_capability_providers.Registry.init(allocator, .{
        .enable_fs_venom = enable_fs_venom,
        .export_specs = exports.items,
        .terminal_ids = terminal_ids.items,
        .labels = node_labels.items,
    });
    defer venom_registry.deinit();
    var shared_venom_registry = try SharedVenomRegistry.init(allocator, &venom_registry);
    defer shared_venom_registry.deinit();

    if (control_url) |control_url_value| {
        const pairing_fs_url = if (advertised_fs_url != null) effective_fs_url else "";
        if (control_auth_token == null) {
            const from_env = std.process.getEnvVarOwned(allocator, "SPIDERWEB_AUTH_TOKEN") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            if (from_env) |raw| {
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (trimmed.len > 0) {
                    control_auth_token = try allocator.dupe(u8, trimmed);
                }
                allocator.free(raw);
            }
        }

        var state = try loadNodePairState(allocator, state_path);
        defer state.deinit(allocator);
        const control_connect = ControlConnectOptions{
            .url = control_url_value,
            .auth_token = control_auth_token,
        };
        const pairing_opts = ControlPairingOptions{
            .connect = control_connect,
            .pair_mode = pair_mode,
            .invite_token = invite_token,
            .operator_token = operator_token,
            .node_name = node_name,
            .fs_url = pairing_fs_url,
            .lease_ttl_ms = lease_ttl_ms,
            .state_path = state_path,
            .reconnect_backoff_ms = reconnect_backoff_ms,
            .reconnect_backoff_max_ms = reconnect_backoff_max_ms,
        };

        while (true) {
            var routed_fs_url: []u8 = undefined;
            while (true) {
                if (!state.isPaired()) {
                    try pairNodeUntilCredentials(allocator, pairing_opts, &state);
                }

                if (!state.isPaired()) {
                    std.log.err("control pairing did not produce node credentials", .{});
                    return error.PairingFailed;
                }

                if (auth_token_from_pair_state) {
                    auth_token = state.node_secret;
                } else if (auth_token) |manual_auth| {
                    if (state.node_secret) |secret| {
                        if (!std.mem.eql(u8, manual_auth, secret)) {
                            std.log.warn("--auth-token differs from paired node_secret; node_secret should be used for control-routed mounts", .{});
                        }
                    }
                } else {
                    auth_token = state.node_secret;
                    auth_token_from_pair_state = true;
                }

                if (auth_token) |token| {
                    std.log.info("FS node session auth enabled", .{});
                    if (state.node_secret) |secret| {
                        if (!std.mem.eql(u8, token, secret)) {
                            std.log.warn("fs auth token does not match paired node secret", .{});
                        }
                    }
                }

                venom_registry.clearExtraVenoms();
                deinitNamespaceVenomExportList(allocator, &runtime_namespace_exports);
                try loadConfiguredManifestVenoms(
                    allocator,
                    state.node_id.?,
                    venom_manifest_paths.items,
                    venom_dirs.items,
                    &venom_registry,
                    &runtime_namespace_exports,
                );
                try rebuildEffectiveExportSpecs(
                    allocator,
                    exports.items,
                    terminal_namespace_exports.items,
                    runtime_namespace_exports.items,
                    &effective_exports,
                );
                venom_registry.fs_export_count = countFilesystemExportSpecs(effective_exports.items);
                venom_registry.fs_rw_export_count = countRwExportSpecs(effective_exports.items);
                try shared_venom_registry.replaceFrom(&venom_registry);

                upsertNodeVenomCatalog(
                    allocator,
                    control_connect,
                    &venom_registry,
                    &state,
                ) catch |err| switch (err) {
                    error.ControlNodeIdentityRejected => {
                        std.log.warn("paired node identity missing on control plane; clearing local node state and re-pairing", .{});
                        state.deinit(allocator);
                        try saveNodePairState(allocator, state_path, &state);
                        continue;
                    },
                    else => std.log.warn("initial node Venom catalog upsert failed: {s}", .{@errorName(err)}),
                };

                routed_fs_url = try buildControlRoutedFsUrl(
                    allocator,
                    control_url_value,
                    state.node_id.?,
                );

                refreshNodeLeaseOnce(
                    allocator,
                    control_connect,
                    state_path,
                    routed_fs_url,
                    &venom_registry,
                    lease_ttl_ms,
                ) catch |err| switch (err) {
                    error.ControlNodeIdentityRejected => {
                        allocator.free(routed_fs_url);
                        std.log.warn("initial node lease refresh rejected saved node identity; clearing local node state and re-pairing", .{});
                        state.deinit(allocator);
                        try saveNodePairState(allocator, state_path, &state);
                        continue;
                    },
                    else => std.log.warn("initial node lease refresh failed: {s}", .{@errorName(err)}),
                };

                break;
            }
            defer allocator.free(routed_fs_url);

            var refresh_ctx = try allocator.create(LeaseRefreshContext);
            defer allocator.destroy(refresh_ctx);
            refresh_ctx.* = try LeaseRefreshContext.init(
                allocator,
                .{
                    .url = control_url_value,
                    .auth_token = control_auth_token,
                },
                state_path,
                routed_fs_url,
                &shared_venom_registry,
                lease_ttl_ms,
                refresh_interval_ms,
                reconnect_backoff_ms,
                reconnect_backoff_max_ms,
            );
            defer refresh_ctx.deinit();

            var refresh_thread = try std.Thread.spawn(.{}, leaseRefreshThreadMain, .{refresh_ctx});
            defer {
                refresh_ctx.requestStop();
                refresh_thread.join();
            }

            std.log.info("Starting spiderweb-fs-node control tunnel", .{});
            std.log.info("Control pairing enabled via {s} ({s})", .{ control_url_value, @tagName(pair_mode) });
            std.log.info("Advertised routed FS URL: {s}", .{routed_fs_url});
            if (effective_exports.items.len == 0) {
                std.log.info("No exports configured via CLI; using default export name='work' path='.' rw", .{});
            } else {
                for (effective_exports.items) |spec| {
                    std.log.info("Export {s} => {s} ({s})", .{ spec.name, spec.path, if (spec.ro) "ro" else "rw" });
                }
            }

            runControlRoutedNodeService(
                allocator,
                .{
                    .url = control_url_value,
                    .auth_token = control_auth_token,
                },
                exports.items,
                terminal_namespace_exports.items,
                venom_manifest_paths.items,
                venom_dirs.items,
                &venom_registry,
                &shared_venom_registry,
                state_path,
                manifest_reload_interval_ms,
                reconnect_backoff_ms,
                reconnect_backoff_max_ms,
            ) catch |err| switch (err) {
                error.ControlNodeIdentityRejected, error.PairingFailed => {
                    std.log.warn("control tunnel rejected saved node identity; clearing local node state and re-pairing", .{});
                    state.deinit(allocator);
                    try saveNodePairState(allocator, state_path, &state);
                    continue;
                },
                else => return err,
            };
            return;
        }
    }

    if (auth_token == null) {
        const from_env = std.process.getEnvVarOwned(allocator, "SPIDERWEB_FS_NODE_AUTH_TOKEN") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (from_env) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                auth_token = try allocator.dupe(u8, trimmed);
            }
            allocator.free(raw);
        }
    }

    venom_registry.clearExtraVenoms();
    deinitNamespaceVenomExportList(allocator, &runtime_namespace_exports);
    try loadConfiguredManifestVenoms(
        allocator,
        node_name,
        venom_manifest_paths.items,
        venom_dirs.items,
        &venom_registry,
        &runtime_namespace_exports,
    );
    try rebuildEffectiveExportSpecs(
        allocator,
        exports.items,
        terminal_namespace_exports.items,
        runtime_namespace_exports.items,
        &effective_exports,
    );
    venom_registry.fs_export_count = countFilesystemExportSpecs(effective_exports.items);
    venom_registry.fs_rw_export_count = countRwExportSpecs(effective_exports.items);
    try shared_venom_registry.replaceFrom(&venom_registry);

    std.log.info("Starting spiderweb-fs-node on {s}:{d}", .{ bind_addr, port });
    if (auth_token != null) {
        std.log.info("FS node session auth enabled", .{});
    }
    if (effective_exports.items.len == 0) {
        std.log.info("No exports configured via CLI; using default export name='work' path='.' rw", .{});
    } else {
        for (effective_exports.items) |spec| {
            std.log.info("Export {s} => {s} ({s})", .{ spec.name, spec.path, if (spec.ro) "ro" else "rw" });
        }
    }

    try fs_node_server.run(allocator, bind_addr, port, effective_exports.items, auth_token);
}

fn runInternalInprocInvoke(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var library_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--library-path")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            library_path = args[i];
        } else {
            return error.InvalidArguments;
        }
    }

    const lib_path = library_path orelse return error.InvalidArguments;
    var lib = try std.DynLib.open(lib_path);
    defer lib.close();
    const invoke_fn = lib.lookup(
        plugin_loader_native.InprocInvokeFn,
        plugin_loader_native.default_invoke_symbol,
    ) orelse return error.MissingSymbol;
    const payload = try std.fs.File.stdin().readToEndAlloc(allocator, inproc_helper_max_io_bytes);
    defer allocator.free(payload);

    const stdout_buffer = try allocator.alloc(u8, inproc_helper_max_io_bytes);
    defer allocator.free(stdout_buffer);
    const stderr_buffer = try allocator.alloc(u8, inproc_helper_max_io_bytes);
    defer allocator.free(stderr_buffer);
    var stdout_len: usize = 0;
    var stderr_len: usize = 0;

    const exit_code = invoke_fn(
        payload.ptr,
        payload.len,
        stdout_buffer.ptr,
        stdout_buffer.len,
        &stdout_len,
        stderr_buffer.ptr,
        stderr_buffer.len,
        &stderr_len,
    );
    if (stdout_len > stdout_buffer.len or stderr_len > stderr_buffer.len) return error.InvalidPayload;

    if (stdout_len > 0) try std.fs.File.stdout().writeAll(stdout_buffer[0..stdout_len]);
    if (stderr_len > 0) try std.fs.File.stderr().writeAll(stderr_buffer[0..stderr_len]);

    const clamped_exit_code: u8 = if (exit_code < 0)
        255
    else if (exit_code > 255)
        255
    else
        @intCast(exit_code);
    std.process.exit(clamped_exit_code);
}

fn runInternalTerminalInvoke(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var terminal_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--terminal-id")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            terminal_id = args[i];
        } else {
            return error.InvalidArguments;
        }
    }

    const terminal = terminal_id orelse return error.InvalidArguments;
    const payload = try std.fs.File.stdin().readToEndAlloc(allocator, inproc_helper_max_io_bytes);
    defer allocator.free(payload);

    const result_json = try invokeTerminalRequestJson(allocator, terminal, payload);
    defer allocator.free(result_json);
    try std.fs.File.stdout().writeAll(result_json);
    std.process.exit(0);
}

fn invokeTerminalRequestJson(
    allocator: std.mem.Allocator,
    terminal_id: []const u8,
    payload: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPayload;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;

    const root = parsed.value.object;
    const args_obj = if (root.get("arguments")) |value|
        if (value == .object) value.object else return error.InvalidPayload
    else
        root;

    if (jsonObjectOptionalString(root, "tool_name")) |tool_name| {
        if (!std.mem.eql(u8, tool_name, "terminal_exec") and
            !std.mem.eql(u8, tool_name, "shell_exec") and
            !std.mem.eql(u8, tool_name, "exec"))
        {
            return error.InvalidPayload;
        }
    }

    const operation = jsonObjectOptionalString(args_obj, "op") orelse
        jsonObjectOptionalString(args_obj, "operation") orelse
        jsonObjectOptionalString(root, "op") orelse
        jsonObjectOptionalString(root, "operation") orelse
        "exec";
    if (!std.mem.eql(u8, operation, "exec")) return error.InvalidPayload;

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);

    if (args_obj.get("argv")) |argv_value| {
        if (argv_value != .array or argv_value.array.items.len == 0) return error.InvalidPayload;
        for (argv_value.array.items) |item| {
            if (item != .string or item.string.len == 0) return error.InvalidPayload;
            try argv.append(allocator, item.string);
        }
    }

    if (argv.items.len == 0) {
        const command = jsonObjectOptionalString(args_obj, "command") orelse return error.InvalidPayload;
        if (builtin.os.tag == .windows) {
            try argv.appendSlice(allocator, &.{ "cmd", "/C", command });
        } else {
            try argv.appendSlice(allocator, &.{ "/bin/sh", "-lc", command });
        }
    }

    const cwd = jsonObjectOptionalString(args_obj, "cwd");
    const max_output_bytes = terminalInvokeMaxOutputBytes(args_obj);

    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = max_output_bytes,
    }) catch |run_err| {
        return renderTerminalInvokeErrorJson(
            allocator,
            terminal_id,
            operation,
            "launch_failed",
            @errorName(run_err),
        );
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const exit_code: i32 = switch (run_result.term) {
        .Exited => |code| code,
        else => -1,
    };
    const term_state = switch (run_result.term) {
        .Exited => "exited",
        else => "terminated",
    };

    const escaped_terminal = try jsonEscape(allocator, terminal_id);
    defer allocator.free(escaped_terminal);
    const escaped_op = try jsonEscape(allocator, operation);
    defer allocator.free(escaped_op);
    const escaped_term_state = try jsonEscape(allocator, term_state);
    defer allocator.free(escaped_term_state);
    const escaped_stdout = try jsonEscape(allocator, run_result.stdout);
    defer allocator.free(escaped_stdout);
    const escaped_stderr = try jsonEscape(allocator, run_result.stderr);
    defer allocator.free(escaped_stderr);

    return std.fmt.allocPrint(
        allocator,
        "{{\"service\":\"terminal\",\"terminal_id\":\"{s}\",\"operation\":\"{s}\",\"ok\":{s},\"state\":\"{s}\",\"exit_code\":{d},\"stdout\":\"{s}\",\"stderr\":\"{s}\"}}",
        .{
            escaped_terminal,
            escaped_op,
            if (exit_code == 0) "true" else "false",
            escaped_term_state,
            exit_code,
            escaped_stdout,
            escaped_stderr,
        },
    );
}

fn renderTerminalInvokeErrorJson(
    allocator: std.mem.Allocator,
    terminal_id: []const u8,
    operation: []const u8,
    state: []const u8,
    err_text: []const u8,
) ![]u8 {
    const escaped_terminal = try jsonEscape(allocator, terminal_id);
    defer allocator.free(escaped_terminal);
    const escaped_op = try jsonEscape(allocator, operation);
    defer allocator.free(escaped_op);
    const escaped_state = try jsonEscape(allocator, state);
    defer allocator.free(escaped_state);
    const escaped_error = try jsonEscape(allocator, err_text);
    defer allocator.free(escaped_error);
    return std.fmt.allocPrint(
        allocator,
        "{{\"service\":\"terminal\",\"terminal_id\":\"{s}\",\"operation\":\"{s}\",\"ok\":false,\"state\":\"{s}\",\"exit_code\":-1,\"stdout\":\"\",\"stderr\":\"{s}\"}}",
        .{ escaped_terminal, escaped_op, escaped_state, escaped_error },
    );
}

fn terminalInvokeMaxOutputBytes(args_obj: std.json.ObjectMap) usize {
    const default_bytes: usize = 128 * 1024;
    const max_bytes: usize = 1024 * 1024;
    const raw = jsonObjectOptionalU64(args_obj, "max_output_bytes") orelse return default_bytes;
    const bounded = @min(raw, @as(u64, max_bytes));
    if (bounded == 0) return default_bytes;
    return @intCast(bounded);
}

fn buildTerminalNamespaceExports(
    allocator: std.mem.Allocator,
    terminal_ids: []const []const u8,
    self_executable_path: []const u8,
    out: *std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned),
) !void {
    var seen = std.StringHashMapUnmanaged(void){};
    defer seen.deinit(allocator);

    for (terminal_ids) |terminal_id| {
        if (terminal_id.len == 0) return error.InvalidArguments;
        if (seen.contains(terminal_id)) continue;
        try seen.put(allocator, terminal_id, {});

        const venom_id = try std.fmt.allocPrint(allocator, "terminal-{s}", .{terminal_id});
        errdefer allocator.free(venom_id);
        const endpoint = try std.fmt.allocPrint(allocator, "/terminal/{s}", .{terminal_id});
        errdefer allocator.free(endpoint);
        const source_id = try std.fmt.allocPrint(allocator, "service:{s}", .{venom_id});
        errdefer allocator.free(source_id);
        const desc = try std.fmt.allocPrint(allocator, "Terminal namespace service ({s})", .{terminal_id});
        errdefer allocator.free(desc);

        var spec = NamespaceVenomExportSpecOwned{
            .name = venom_id,
            .path = endpoint,
            .source_id = source_id,
            .desc = desc,
            .venom_id = try allocator.dupe(u8, venom_id),
            .runtime_kind = .native_proc,
            .executable_path = try allocator.dupe(u8, self_executable_path),
            .timeout_ms = 30_000,
            .help_md = try allocator.dupe(u8, venom_contracts.terminal.help_md),
            .schema_json = try allocator.dupe(u8, venom_contracts.terminal.descriptor_schema_json),
            .invoke_template_json = try allocator.dupe(u8, venom_contracts.terminal.invoke_template_json),
        };
        errdefer spec.deinit(allocator);
        try spec.args.append(allocator, try allocator.dupe(u8, "--internal-terminal-invoke"));
        try spec.args.append(allocator, try allocator.dupe(u8, "--terminal-id"));
        try spec.args.append(allocator, try allocator.dupe(u8, terminal_id));
        try out.append(allocator, spec);
    }
}

fn jsonObjectOptionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn jsonObjectOptionalU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => if (value.integer >= 0) @intCast(value.integer) else null,
        else => null,
    };
}

fn dupOptionalObjectJson(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    default_json: []const u8,
) ![]u8 {
    if (obj.get(key)) |value| {
        if (value != .object) return error.InvalidArguments;
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
    }
    return allocator.dupe(u8, default_json);
}

fn parsePairMode(raw: []const u8) ?PairMode {
    if (std.mem.eql(u8, raw, "invite")) return .invite;
    if (std.mem.eql(u8, raw, "request")) return .request;
    return null;
}

fn parseLabelArg(raw: []const u8) !node_capability_providers.NodeLabelArg {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidArguments;
    if (eq_idx == 0 or eq_idx + 1 >= raw.len) return error.InvalidArguments;
    return .{
        .key = raw[0..eq_idx],
        .value = raw[eq_idx + 1 ..],
    };
}

fn countRwExportSpecs(specs: []const fs_node_ops.ExportSpec) usize {
    var rw: usize = 0;
    for (specs) |spec| {
        if (spec.source_kind) |source_kind| {
            if (source_kind == .namespace) continue;
        }
        if (!spec.ro) rw += 1;
    }
    return rw;
}

fn countFilesystemExportSpecs(specs: []const fs_node_ops.ExportSpec) usize {
    var total: usize = 0;
    for (specs) |spec| {
        if (spec.source_kind) |source_kind| {
            if (source_kind == .namespace) continue;
        }
        total += 1;
    }
    return total;
}

fn loadConfiguredManifestVenoms(
    allocator: std.mem.Allocator,
    node_id: []const u8,
    manifest_paths: []const []const u8,
    service_dirs: []const []const u8,
    registry: *node_capability_providers.Registry,
    runtime_namespace_exports: *std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned),
) !void {
    var loaded = std.ArrayListUnmanaged(venom_manifest.LoadedVenom){};
    defer {
        for (loaded.items) |*item| item.deinit(allocator);
        loaded.deinit(allocator);
    }

    for (manifest_paths) |manifest_path| {
        const maybe_loaded = try venom_manifest.loadVenomManifestFile(
            allocator,
            manifest_path,
            node_id,
        );
        if (maybe_loaded) |item| try loaded.append(allocator, item);
    }

    for (service_dirs) |dir_path| {
        try venom_manifest.loadVenomManifestDirectory(
            allocator,
            dir_path,
            node_id,
            &loaded,
        );
    }

    if (loaded.items.len == 0) return;

    var runtime_manager = venom_runtime_manager.RuntimeManager.init(allocator);
    defer runtime_manager.deinit();

    var ids = std.StringHashMapUnmanaged(void){};
    defer ids.deinit(allocator);
    for (loaded.items) |item| {
        if (ids.contains(item.venom_id)) return error.InvalidArguments;
        try ids.put(allocator, item.venom_id, {});
    }

    for (loaded.items) |item| {
        try validateVenomRuntimeConfig(allocator, item.venom_json);
        try runtime_manager.registerFromVenomJson(item.venom_json);
        if (try buildNamespaceVenomExportFromVenomJson(allocator, item.venom_json)) |service_export| {
            try runtime_namespace_exports.append(allocator, service_export);
        }
        try registry.addExtraVenom(item.venom_id, item.venom_json);
        std.log.info("Loaded Venom manifest: {s}", .{item.venom_id});
    }

    try runtime_manager.startAll();
    runtime_manager.stopAll();
}

fn buildManifestInputsFingerprint(
    allocator: std.mem.Allocator,
    manifest_paths: []const []const u8,
    service_dirs: []const []const u8,
) ![]u8 {
    var entries = std.ArrayListUnmanaged([]u8){};
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit(allocator);
    }

    for (manifest_paths) |manifest_path| {
        try appendManifestPathFingerprint(allocator, &entries, manifest_path);
    }
    for (service_dirs) |dir_path| {
        try appendManifestDirectoryFingerprint(allocator, &entries, dir_path);
    }

    std.mem.sort([]u8, entries.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (entries.items) |entry| {
        try out.appendSlice(allocator, entry);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn appendManifestPathFingerprint(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged([]u8),
    path: []const u8,
) !void {
    const stat = statManifestFile(path) catch |err| switch (err) {
        error.FileNotFound => {
            try entries.append(allocator, try std.fmt.allocPrint(allocator, "missing:{s}", .{path}));
            return;
        },
        else => return err,
    };
    try entries.append(allocator, try std.fmt.allocPrint(
        allocator,
        "file:{s}:{d}:{d}",
        .{ path, stat.size, stat.mtime },
    ));
}

fn appendManifestDirectoryFingerprint(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged([]u8),
    dir_path: []const u8,
) !void {
    var dir = openManifestDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try entries.append(allocator, try std.fmt.allocPrint(allocator, "missing-dir:{s}", .{dir_path}));
            return;
        },
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const full_path = if (entry.path.len == 0)
            try allocator.dupe(u8, dir_path)
        else
            try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        defer allocator.free(full_path);

        const stat = switch (entry.kind) {
            .directory => entry.dir.stat() catch continue,
            else => entry.dir.statFile(entry.basename) catch continue,
        };

        try entries.append(allocator, try std.fmt.allocPrint(
            allocator,
            "dir:{s}:{s}:{d}:{d}",
            .{ dir_path, full_path, stat.size, stat.mtime },
        ));
    }
}

fn openManifestDir(path: []const u8, flags: std.fs.Dir.OpenOptions) !std.fs.Dir {
    return if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, flags)
    else
        std.fs.cwd().openDir(path, flags);
}

fn statManifestFile(path: []const u8) !std.fs.File.Stat {
    if (std.fs.path.isAbsolute(path)) {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.IsDir => return error.FileNotFound,
            else => return err,
        };
        defer file.close();
        return file.stat();
    }
    return std.fs.cwd().statFile(path);
}

fn buildNamespaceVenomExportFromVenomJson(
    allocator: std.mem.Allocator,
    venom_json: []const u8,
) !?NamespaceVenomExportSpecOwned {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, venom_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;

    const obj = parsed.value.object;
    const venom_id = getRequiredString(obj, "venom_id") orelse return error.InvalidArguments;
    const runtime = obj.get("runtime") orelse return null;
    if (runtime != .object) return null;
    const runtime_type = if (runtime.object.get("type")) |value|
        if (value == .string and value.string.len > 0) value.string else return error.InvalidArguments
    else
        "builtin";
    const runtime_kind: fs_node_ops.NamespaceVenomRuntimeKind = if (std.mem.eql(u8, runtime_type, "native_proc"))
        .native_proc
    else if (std.mem.eql(u8, runtime_type, "native_inproc"))
        .native_inproc
    else if (std.mem.eql(u8, runtime_type, "wasm"))
        .wasm
    else
        return null;

    const executable_path: ?[]const u8 = blk: {
        if (runtime.object.get("executable_path")) |value| {
            if (value != .string or value.string.len == 0) return error.InvalidArguments;
            break :blk value.string;
        }
        break :blk null;
    };
    const library_path: ?[]const u8 = blk: {
        if (runtime.object.get("library_path")) |value| {
            if (value != .string or value.string.len == 0) return error.InvalidArguments;
            break :blk value.string;
        }
        break :blk null;
    };
    const module_path: ?[]const u8 = blk: {
        if (runtime.object.get("module_path")) |value| {
            if (value != .string or value.string.len == 0) return error.InvalidArguments;
            break :blk value.string;
        }
        break :blk null;
    };
    const wasm_entrypoint: ?[]const u8 = blk: {
        if (runtime.object.get("entrypoint")) |value| {
            if (value != .string or value.string.len == 0) return error.InvalidArguments;
            break :blk value.string;
        }
        break :blk null;
    };
    const timeout_ms: u64 = blk: {
        if (runtime.object.get("timeout_ms")) |value| {
            if (value != .integer or value.integer < 0) return error.InvalidArguments;
            break :blk @intCast(value.integer);
        }
        break :blk 30_000;
    };
    const fuel: ?u64 = blk: {
        if (runtime.object.get("fuel")) |value| {
            if (value != .integer or value.integer < 0) return error.InvalidArguments;
            break :blk @intCast(value.integer);
        }
        break :blk null;
    };
    const max_memory_bytes: ?u64 = blk: {
        if (runtime.object.get("max_memory_bytes")) |value| {
            if (value != .integer or value.integer < 0) return error.InvalidArguments;
            break :blk @intCast(value.integer);
        }
        break :blk null;
    };
    const schema_json = try dupOptionalObjectJson(
        allocator,
        obj,
        "schema",
        namespace_venom_schema_default_json,
    );
    errdefer allocator.free(schema_json);
    const invoke_template_json = try dupOptionalObjectJson(
        allocator,
        obj,
        "invoke_template",
        namespace_venom_invoke_template_default_json,
    );
    errdefer allocator.free(invoke_template_json);

    switch (runtime_kind) {
        .native_proc => if (executable_path == null) return null,
        .native_inproc => if (library_path == null) return null,
        .wasm => if (module_path == null) return null,
    }

    var owned = NamespaceVenomExportSpecOwned{
        .name = try allocator.dupe(u8, venom_id),
        .path = try std.fmt.allocPrint(allocator, "service:{s}", .{venom_id}),
        .source_id = try std.fmt.allocPrint(allocator, "service:{s}", .{venom_id}),
        .desc = try std.fmt.allocPrint(allocator, "namespace service {s}", .{venom_id}),
        .venom_id = try allocator.dupe(u8, venom_id),
        .runtime_kind = runtime_kind,
        .executable_path = if (executable_path) |value| try allocator.dupe(u8, value) else null,
        .library_path = if (library_path) |value| try allocator.dupe(u8, value) else null,
        .module_path = if (module_path) |value| try allocator.dupe(u8, value) else null,
        .wasm_entrypoint = if (wasm_entrypoint) |value| try allocator.dupe(u8, value) else null,
        .timeout_ms = timeout_ms,
        .fuel = fuel,
        .max_memory_bytes = max_memory_bytes,
        .help_md = if (obj.get("help_md")) |value|
            if (value == .string and value.string.len > 0) try allocator.dupe(u8, value.string) else null
        else
            null,
        .schema_json = schema_json,
        .invoke_template_json = invoke_template_json,
    };
    errdefer owned.deinit(allocator);

    if (runtime.object.get("args")) |raw_args| {
        if (raw_args != .array) return error.InvalidArguments;
        for (raw_args.array.items) |item| {
            if (item != .string or item.string.len == 0) return error.InvalidArguments;
            try owned.args.append(allocator, try allocator.dupe(u8, item.string));
        }
    }

    return owned;
}

fn deinitNamespaceVenomExportList(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned),
) void {
    for (list.items) |*item| item.deinit(allocator);
    list.clearRetainingCapacity();
}

fn rebuildEffectiveExportSpecs(
    allocator: std.mem.Allocator,
    base_exports: []const fs_node_ops.ExportSpec,
    static_namespace_exports: []const NamespaceVenomExportSpecOwned,
    runtime_namespace_exports: []const NamespaceVenomExportSpecOwned,
    out: *std.ArrayListUnmanaged(fs_node_ops.ExportSpec),
) !void {
    out.clearRetainingCapacity();
    for (base_exports) |spec| try out.append(allocator, spec);

    var names = std.StringHashMapUnmanaged(void){};
    defer names.deinit(allocator);
    for (out.items) |spec| {
        if (names.contains(spec.name)) return error.InvalidArguments;
        try names.put(allocator, spec.name, {});
    }

    for (static_namespace_exports) |*owned_spec| {
        const candidate = owned_spec.asExportSpec();
        if (names.contains(candidate.name)) return error.InvalidArguments;
        try names.put(allocator, candidate.name, {});
        try out.append(allocator, candidate);
    }

    for (runtime_namespace_exports) |*owned_spec| {
        const candidate = owned_spec.asExportSpec();
        if (names.contains(candidate.name)) return error.InvalidArguments;
        try names.put(allocator, candidate.name, {});
        try out.append(allocator, candidate);
    }
}

fn validateVenomRuntimeConfig(
    allocator: std.mem.Allocator,
    venom_json: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, venom_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArguments;

    const runtime = parsed.value.object.get("runtime") orelse return;
    if (runtime != .object) return error.InvalidArguments;

    const runtime_type = blk: {
        if (runtime.object.get("type")) |value| {
            if (value != .string or value.string.len == 0) return error.InvalidArguments;
            break :blk value.string;
        }
        break :blk "builtin";
    };

    if (std.mem.eql(u8, runtime_type, "builtin")) return;

    if (std.mem.eql(u8, runtime_type, "native_proc")) {
        const executable_path = blk: {
            if (runtime.object.get("executable_path")) |value| {
                if (value != .string) return error.InvalidArguments;
                break :blk value.string;
            }
            break :blk null;
        };
        if (executable_path) |path| {
            var args = std.ArrayListUnmanaged([]const u8){};
            defer args.deinit(allocator);
            if (runtime.object.get("args")) |value| {
                if (value != .array) return error.InvalidArguments;
                for (value.array.items) |item| {
                    if (item != .string) return error.InvalidArguments;
                    try args.append(allocator, item.string);
                }
            }
            var handle = try plugin_loader_process.launch(allocator, .{
                .executable_path = path,
                .args = args.items,
            });
            defer handle.deinit(allocator);
        }
        return;
    }

    if (std.mem.eql(u8, runtime_type, "native_inproc")) {
        if (runtime.object.get("abi")) |value| {
            if (value != .string or !isSupportedDriverAbi(value.string)) {
                return error.InvalidArguments;
            }
        }
        const library_path = blk: {
            if (runtime.object.get("library_path")) |value| {
                if (value != .string) return error.InvalidArguments;
                break :blk value.string;
            }
            break :blk null;
        };
        if (library_path) |path| {
            const in_process = blk: {
                if (runtime.object.get("in_process")) |value| {
                    if (value != .bool) return error.InvalidArguments;
                    break :blk value.bool;
                }
                break :blk true;
            };
            var handle = try plugin_loader_native.load(allocator, .{
                .library_path = path,
                .in_process = in_process,
            });
            defer handle.deinit(allocator);
        }
        return;
    }

    if (std.mem.eql(u8, runtime_type, "wasm")) {
        const module_path = blk: {
            if (runtime.object.get("module_path")) |value| {
                if (value != .string) return error.InvalidArguments;
                break :blk value.string;
            }
            break :blk null;
        };
        if (module_path) |path| {
            const entrypoint = blk: {
                if (runtime.object.get("entrypoint")) |value| {
                    if (value != .string or value.string.len == 0) return error.InvalidArguments;
                    break :blk value.string;
                }
                break :blk "spiderweb_driver_v1";
            };
            const fuel = blk: {
                if (runtime.object.get("fuel")) |value| {
                    if (value != .integer or value.integer < 0) return error.InvalidArguments;
                    break :blk @as(?u64, @intCast(value.integer));
                }
                break :blk null;
            };
            const max_memory_bytes = blk: {
                if (runtime.object.get("max_memory_bytes")) |value| {
                    if (value != .integer or value.integer < 0) return error.InvalidArguments;
                    break :blk @as(?u64, @intCast(value.integer));
                }
                break :blk null;
            };
            var args = std.ArrayListUnmanaged([]const u8){};
            defer args.deinit(allocator);
            if (runtime.object.get("args")) |value| {
                if (value != .array) return error.InvalidArguments;
                for (value.array.items) |item| {
                    if (item != .string or item.string.len == 0) return error.InvalidArguments;
                    try args.append(allocator, item.string);
                }
            }
            try zwasm_runtime.validateConfig(.{
                .module_path = path,
                .entrypoint = entrypoint,
                .args = args.items,
                .fuel = fuel,
                .max_memory_bytes = max_memory_bytes,
            });
            var handle = try plugin_loader_wasm.load(allocator, .{
                .module_path = path,
                .entrypoint = entrypoint,
                .args = args.items,
            });
            defer handle.deinit(allocator);
        }
        return;
    }

    return error.InvalidArguments;
}

fn getRequiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    return null;
}

fn getRequiredStringAlias(obj: std.json.ObjectMap, primary: []const u8, alias: []const u8) ?[]const u8 {
    if (obj.get(primary)) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    if (obj.get(alias)) |value| {
        if (value == .string and value.string.len > 0) return value.string;
    }
    return null;
}

fn isSupportedDriverAbi(value: []const u8) bool {
    return std.mem.eql(u8, value, plugin_loader_native.stable_abi_name) or
        std.mem.eql(u8, value, plugin_loader_native.venom_abi_name);
}

fn upsertNodeVenomCatalog(
    allocator: std.mem.Allocator,
    connect: ControlConnectOptions,
    venom_registry: *const node_capability_providers.Registry,
    state: *const NodePairState,
) !void {
    const node_id = state.node_id orelse return error.MissingField;
    const node_secret = state.node_secret orelse return error.MissingField;
    const payload = try venom_registry.buildVenomUpsertPayload(
        allocator,
        node_id,
        node_secret,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        "native",
    );
    defer allocator.free(payload);

    var result = try requestControlPayload(
        allocator,
        connect,
        "control.venom_upsert",
        payload,
    );
    defer result.deinit(allocator);

    switch (result) {
        .payload_json => {},
        .remote_error => |remote| {
            std.log.warn("node service upsert rejected: code={s} message={s}", .{ remote.code, remote.message });
            if (isControlNodeIdentityErrorCode(remote.code)) return error.ControlNodeIdentityRejected;
            return error.ControlRequestFailed;
        },
    }
}

fn pairNodeUntilCredentials(
    allocator: std.mem.Allocator,
    opts: ControlPairingOptions,
    state: *NodePairState,
) !void {
    var attempts: u32 = 0;

    while (!state.isPaired()) {
        var from_disk = try loadNodePairState(allocator, opts.state_path);
        defer from_disk.deinit(allocator);

        if (from_disk.isPaired()) {
            state.adoptFrom(allocator, &from_disk);
            break;
        }

        if (from_disk.request_id != null and state.request_id == null) {
            state.clearRequest(allocator);
            if (from_disk.request_id) |value| {
                state.request_id = try allocator.dupe(u8, value);
            }
        }

        try attemptPairingOnce(allocator, opts, state);
        try saveNodePairState(allocator, opts.state_path, state);

        if (state.isPaired()) break;

        const wait_ms = computeBackoff(
            opts.reconnect_backoff_ms,
            opts.reconnect_backoff_max_ms,
            attempts,
        );
        attempts +%= 1;
        std.log.info("node pairing pending; retrying in {d} ms", .{wait_ms});
        std.Thread.sleep(wait_ms * std.time.ns_per_ms);
    }

    try saveNodePairState(allocator, opts.state_path, state);
}

fn attemptPairingOnce(
    allocator: std.mem.Allocator,
    opts: ControlPairingOptions,
    state: *NodePairState,
) !void {
    if (state.isPaired()) return;

    switch (opts.pair_mode) {
        .invite => {
            const token = opts.invite_token orelse return error.InvalidArguments;
            var payload = std.ArrayListUnmanaged(u8){};
            defer payload.deinit(allocator);
            const escaped_invite = try jsonEscape(allocator, token);
            defer allocator.free(escaped_invite);
            const escaped_name = try jsonEscape(allocator, opts.node_name);
            defer allocator.free(escaped_name);
            const escaped_fs_url = try jsonEscape(allocator, opts.fs_url);
            defer allocator.free(escaped_fs_url);
            try payload.writer(allocator).print(
                "{{\"invite_token\":\"{s}\",\"node_name\":\"{s}\",\"fs_url\":\"{s}\",\"lease_ttl_ms\":{d}}}",
                .{ escaped_invite, escaped_name, escaped_fs_url, opts.lease_ttl_ms },
            );

            var result = requestControlPayload(
                allocator,
                opts.connect,
                "control.node_join",
                payload.items,
            ) catch |err| {
                std.log.warn("node invite join request failed: {s}", .{@errorName(err)});
                return;
            };
            defer result.deinit(allocator);

            switch (result) {
                .payload_json => |payload_json| {
                    var joined = parseNodeJoinPayload(allocator, payload_json) catch |err| {
                        std.log.warn("node invite join payload invalid: {s}", .{@errorName(err)});
                        return;
                    };
                    errdefer joined.deinit(allocator);
                    try state.setFromJoin(allocator, joined);
                    std.log.info("node paired via invite: {s}", .{state.node_id.?});
                },
                .remote_error => |remote| {
                    std.log.warn(
                        "node invite join rejected: code={s} message={s}",
                        .{ remote.code, remote.message },
                    );
                },
            }
        },
        .request => {
            if (state.request_id == null) {
                var req_payload = std.ArrayListUnmanaged(u8){};
                defer req_payload.deinit(allocator);
                const escaped_name = try jsonEscape(allocator, opts.node_name);
                defer allocator.free(escaped_name);
                const escaped_fs_url = try jsonEscape(allocator, opts.fs_url);
                defer allocator.free(escaped_fs_url);
                const escaped_os = try jsonEscape(allocator, @tagName(builtin.os.tag));
                defer allocator.free(escaped_os);
                const escaped_arch = try jsonEscape(allocator, @tagName(builtin.cpu.arch));
                defer allocator.free(escaped_arch);

                try req_payload.writer(allocator).print(
                    "{{\"node_name\":\"{s}\",\"fs_url\":\"{s}\",\"platform\":{{\"os\":\"{s}\",\"arch\":\"{s}\",\"runtime_kind\":\"native\"}}}}",
                    .{ escaped_name, escaped_fs_url, escaped_os, escaped_arch },
                );

                var result = requestControlPayload(
                    allocator,
                    opts.connect,
                    "control.node_join_request",
                    req_payload.items,
                ) catch |err| {
                    std.log.warn("node join-request failed: {s}", .{@errorName(err)});
                    return;
                };
                defer result.deinit(allocator);

                switch (result) {
                    .payload_json => |payload_json| {
                        const request_id = parsePendingRequestId(allocator, payload_json) catch |err| {
                            std.log.warn("node join-request response invalid: {s}", .{@errorName(err)});
                            return;
                        };
                        defer allocator.free(request_id);
                        try state.setRequestId(allocator, request_id);
                        std.log.info("node join request submitted: {s}", .{request_id});
                    },
                    .remote_error => |remote| {
                        std.log.warn(
                            "node join-request rejected: code={s} message={s}",
                            .{ remote.code, remote.message },
                        );
                        return;
                    },
                }
            }

            const request_id = state.request_id orelse return;
            var approve_payload = std.ArrayListUnmanaged(u8){};
            defer approve_payload.deinit(allocator);
            const escaped_request = try jsonEscape(allocator, request_id);
            defer allocator.free(escaped_request);
            try approve_payload.writer(allocator).print(
                "{{\"request_id\":\"{s}\",\"lease_ttl_ms\":{d}",
                .{ escaped_request, opts.lease_ttl_ms },
            );
            if (opts.operator_token) |token| {
                const escaped_token = try jsonEscape(allocator, token);
                defer allocator.free(escaped_token);
                try approve_payload.writer(allocator).print(",\"operator_token\":\"{s}\"", .{escaped_token});
            }
            try approve_payload.append(allocator, '}');

            var approve_result = requestControlPayload(
                allocator,
                opts.connect,
                "control.node_join_approve",
                approve_payload.items,
            ) catch |err| {
                std.log.warn("node join approval attempt failed: {s}", .{@errorName(err)});
                return;
            };
            defer approve_result.deinit(allocator);

            switch (approve_result) {
                .payload_json => |payload_json| {
                    var joined = parseNodeJoinPayload(allocator, payload_json) catch |err| {
                        std.log.warn("node join approval payload invalid: {s}", .{@errorName(err)});
                        return;
                    };
                    errdefer joined.deinit(allocator);
                    try state.setFromJoin(allocator, joined);
                    std.log.info("node paired via join-request approval: {s}", .{state.node_id.?});
                },
                .remote_error => |remote| {
                    if (std.mem.eql(u8, remote.code, "pending_join_not_found")) {
                        state.clearRequest(allocator);
                    }
                    std.log.info(
                        "node join approval pending: code={s} message={s}",
                        .{ remote.code, remote.message },
                    );
                },
            }
        },
    }
}

fn leaseRefreshThreadMain(ctx: *LeaseRefreshContext) void {
    var failures: u32 = 0;

    while (true) {
        const wait_ms = if (failures == 0)
            ctx.refresh_interval_ms
        else
            computeBackoff(ctx.reconnect_backoff_ms, ctx.reconnect_backoff_max_ms, failures - 1);

        if (!ctx.sleepWithStop(wait_ms)) return;

        var state = loadNodePairState(ctx.allocator, ctx.state_path) catch |err| {
            failures +%= 1;
            std.log.warn("lease refresh: failed to read node state: {s}", .{@errorName(err)});
            continue;
        };
        defer state.deinit(ctx.allocator);

        if (!state.isPaired()) {
            failures = 0;
            continue;
        }

        const node_id = state.node_id orelse continue;
        const node_secret = state.node_secret orelse continue;

        var payload = std.ArrayListUnmanaged(u8){};
        defer payload.deinit(ctx.allocator);
        const escaped_node_id = jsonEscape(ctx.allocator, node_id) catch |err| {
            failures +%= 1;
            std.log.warn("lease refresh: escape node_id failed: {s}", .{@errorName(err)});
            continue;
        };
        defer ctx.allocator.free(escaped_node_id);
        const escaped_node_secret = jsonEscape(ctx.allocator, node_secret) catch |err| {
            failures +%= 1;
            std.log.warn("lease refresh: escape node_secret failed: {s}", .{@errorName(err)});
            continue;
        };
        defer ctx.allocator.free(escaped_node_secret);
        const escaped_fs_url = jsonEscape(ctx.allocator, ctx.fs_url) catch |err| {
            failures +%= 1;
            std.log.warn("lease refresh: escape fs_url failed: {s}", .{@errorName(err)});
            continue;
        };
        defer ctx.allocator.free(escaped_fs_url);

        payload.writer(ctx.allocator).print(
            "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"fs_url\":\"{s}\",\"lease_ttl_ms\":{d}}}",
            .{ escaped_node_id, escaped_node_secret, escaped_fs_url, ctx.lease_ttl_ms },
        ) catch |err| {
            failures +%= 1;
            std.log.warn("lease refresh: build payload failed: {s}", .{@errorName(err)});
            continue;
        };

        var result = requestControlPayload(
            ctx.allocator,
            ctx.connect,
            "control.node_lease_refresh",
            payload.items,
        ) catch |err| {
            failures +%= 1;
            std.log.warn("lease refresh RPC failed: {s}", .{@errorName(err)});
            continue;
        };
        defer result.deinit(ctx.allocator);

        switch (result) {
            .payload_json => |payload_json| {
                var joined = parseNodeJoinPayload(ctx.allocator, payload_json) catch |err| {
                    failures +%= 1;
                    std.log.warn("lease refresh payload invalid: {s}", .{@errorName(err)});
                    continue;
                };
                errdefer joined.deinit(ctx.allocator);

                tryApplyLeaseRefresh(ctx.allocator, ctx.state_path, &state, joined) catch |err| {
                    failures +%= 1;
                    std.log.warn("lease refresh state update failed: {s}", .{@errorName(err)});
                    continue;
                };

                failures = 0;
                var registry_snapshot = ctx.shared_venom_registry.snapshot() catch |clone_err| {
                    std.log.warn("lease refresh: snapshot service registry failed: {s}", .{@errorName(clone_err)});
                    std.log.debug("node lease refreshed: node={s} lease_expires_at_ms={d}", .{ state.node_id.?, state.lease_expires_at_ms });
                    continue;
                };
                defer registry_snapshot.deinit();
                upsertNodeVenomCatalog(
                    ctx.allocator,
                    ctx.connect,
                    &registry_snapshot,
                    &state,
                ) catch |err| {
                    std.log.warn("lease refresh: service catalog upsert failed: {s}", .{@errorName(err)});
                };
                std.log.debug("node lease refreshed: node={s} lease_expires_at_ms={d}", .{ state.node_id.?, state.lease_expires_at_ms });
            },
            .remote_error => |remote| {
                failures +%= 1;
                std.log.warn("lease refresh rejected: code={s} message={s}", .{ remote.code, remote.message });
                if (isControlNodeIdentityErrorCode(remote.code)) {
                    std.log.warn("lease refresh: clearing stale local node pairing state after identity rejection", .{});
                    state.deinit(ctx.allocator);
                    saveNodePairState(ctx.allocator, ctx.state_path, &state) catch |save_err| {
                        std.log.warn("lease refresh: failed to persist cleared node state: {s}", .{@errorName(save_err)});
                    };
                    failures = 0;
                }
            },
        }
    }
}

fn tryApplyLeaseRefresh(
    allocator: std.mem.Allocator,
    state_path: []const u8,
    state: *NodePairState,
    join: NodeJoinPayload,
) !void {
    errdefer {
        var cleanup = join;
        cleanup.deinit(allocator);
    }

    const old_id = state.node_id;
    const old_secret = state.node_secret;
    if (old_id == null or old_secret == null) {
        try state.setFromJoin(allocator, join);
        try saveNodePairState(allocator, state_path, state);
        return;
    }

    if (!std.mem.eql(u8, old_id.?, join.node_id) or !std.mem.eql(u8, old_secret.?, join.node_secret)) {
        std.log.warn("lease refresh returned mismatched node identity; ignoring update", .{});
        return;
    }

    try state.setFromJoin(allocator, join);
    try saveNodePairState(allocator, state_path, state);
}

fn buildControlRoutedFsUrl(
    allocator: std.mem.Allocator,
    control_url: []const u8,
    node_id: []const u8,
) ![]u8 {
    const parsed = try parseWsUrlWithDefaultPath(control_url, "/");
    return std.fmt.allocPrint(
        allocator,
        "ws://{s}:{d}/fs/node/{s}",
        .{ parsed.host, parsed.port, node_id },
    );
}

fn refreshNodeLeaseOnce(
    allocator: std.mem.Allocator,
    connect: ControlConnectOptions,
    state_path: []const u8,
    fs_url: []const u8,
    venom_registry: *const node_capability_providers.Registry,
    lease_ttl_ms: u64,
) !void {
    var state = try loadNodePairState(allocator, state_path);
    defer state.deinit(allocator);
    if (!state.isPaired()) return error.MissingField;
    const node_id = state.node_id orelse return error.MissingField;
    const node_secret = state.node_secret orelse return error.MissingField;

    const escaped_node_id = try jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_node_secret = try jsonEscape(allocator, node_secret);
    defer allocator.free(escaped_node_secret);
    const escaped_fs_url = try jsonEscape(allocator, fs_url);
    defer allocator.free(escaped_fs_url);
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"node_id\":\"{s}\",\"node_secret\":\"{s}\",\"fs_url\":\"{s}\",\"lease_ttl_ms\":{d}}}",
        .{ escaped_node_id, escaped_node_secret, escaped_fs_url, lease_ttl_ms },
    );
    defer allocator.free(payload);

    var result = try requestControlPayload(
        allocator,
        connect,
        "control.node_lease_refresh",
        payload,
    );
    defer result.deinit(allocator);
    switch (result) {
        .payload_json => |payload_json| {
            var joined = try parseNodeJoinPayload(allocator, payload_json);
            errdefer joined.deinit(allocator);
            try tryApplyLeaseRefresh(allocator, state_path, &state, joined);
            try upsertNodeVenomCatalog(allocator, connect, venom_registry, &state);
        },
        .remote_error => |remote| {
            std.log.warn("initial lease refresh rejected: code={s} message={s}", .{ remote.code, remote.message });
            if (isControlNodeIdentityErrorCode(remote.code)) return error.ControlNodeIdentityRejected;
            return error.ControlRequestFailed;
        },
    }
}

fn refreshControlRuntimeForNode(
    allocator: std.mem.Allocator,
    state: *const NodePairState,
    base_exports: []const fs_node_ops.ExportSpec,
    static_namespace_exports: []const NamespaceVenomExportSpecOwned,
    venom_manifest_paths: []const []const u8,
    venom_dirs: []const []const u8,
    venom_registry: *node_capability_providers.Registry,
    shared_venom_registry: *SharedVenomRegistry,
    runtime_manager: *venom_runtime_manager.RuntimeManager,
    runtime_probe_store: *RuntimeProbeDriverStore,
    runtime_namespace_exports: *std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned),
    effective_exports: *std.ArrayListUnmanaged(fs_node_ops.ExportSpec),
    service: *fs_node_service.NodeService,
    runtime_state_path: []const u8,
    last_manifest_payload: *?[]u8,
    last_manifest_inputs_fingerprint: *?[]u8,
) !bool {
    const node_id = state.node_id orelse return error.MissingField;
    const node_secret = state.node_secret orelse return error.MissingField;

    const next_inputs_fingerprint = try buildManifestInputsFingerprint(
        allocator,
        venom_manifest_paths,
        venom_dirs,
    );
    errdefer allocator.free(next_inputs_fingerprint);
    const inputs_changed = if (last_manifest_inputs_fingerprint.*) |previous|
        !std.mem.eql(u8, previous, next_inputs_fingerprint)
    else
        true;

    if (!inputs_changed) {
        allocator.free(next_inputs_fingerprint);
        return false;
    }

    venom_registry.clearExtraVenoms();
    deinitNamespaceVenomExportList(allocator, runtime_namespace_exports);
    try loadConfiguredManifestVenoms(
        allocator,
        node_id,
        venom_manifest_paths,
        venom_dirs,
        venom_registry,
        runtime_namespace_exports,
    );
    try rebuildEffectiveExportSpecs(
        allocator,
        base_exports,
        static_namespace_exports,
        runtime_namespace_exports.items,
        effective_exports,
    );
    venom_registry.fs_export_count = countFilesystemExportSpecs(effective_exports.items);
    venom_registry.fs_rw_export_count = countRwExportSpecs(effective_exports.items);

    const next_payload = try venom_registry.buildVenomUpsertPayload(
        allocator,
        node_id,
        node_secret,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        "native",
    );

    const changed = if (last_manifest_payload.*) |previous|
        !std.mem.eql(u8, previous, next_payload)
    else
        true;

    if (!changed) {
        allocator.free(next_payload);
        return false;
    }

    const runtime_snapshot: ?[]u8 = service.exportNamespaceRuntimeStateJson(allocator) catch null;
    defer if (runtime_snapshot) |snapshot| allocator.free(snapshot);

    var next_service = try fs_node_service.NodeService.init(allocator, effective_exports.items);
    errdefer next_service.deinit();
    if (runtime_snapshot) |snapshot| {
        next_service.restoreNamespaceRuntimeStateJson(snapshot) catch |restore_err| {
            std.log.warn("manifest reload: runtime state restore failed: {s}", .{@errorName(restore_err)});
        };
    }

    var old_service = service.*;
    service.* = next_service;
    old_service.deinit();

    try syncVenomRuntimeManagerFromRegistry(
        allocator,
        venom_registry,
        runtime_manager,
        runtime_probe_store,
    );
    try shared_venom_registry.replaceFrom(venom_registry);

    if (last_manifest_payload.*) |previous| allocator.free(previous);
    last_manifest_payload.* = next_payload;
    if (last_manifest_inputs_fingerprint.*) |previous| allocator.free(previous);
    last_manifest_inputs_fingerprint.* = next_inputs_fingerprint;

    saveNamespaceRuntimeStateToFile(allocator, runtime_state_path, service) catch |save_err| {
        std.log.warn("manifest reload: persist runtime state failed: {s}", .{@errorName(save_err)});
    };
    return true;
}

fn syncVenomRuntimeManagerFromRegistry(
    allocator: std.mem.Allocator,
    venom_registry: *const node_capability_providers.Registry,
    runtime_manager: *venom_runtime_manager.RuntimeManager,
    runtime_probe_store: *RuntimeProbeDriverStore,
) !void {
    runtime_manager.stopAll();
    runtime_manager.deinit();
    runtime_probe_store.clear();
    runtime_manager.* = venom_runtime_manager.RuntimeManager.init(allocator);
    for (venom_registry.extra_venoms.items) |service| {
        var parsed = try venom_runtime_manager.parseVenomRegistrationFromVenomJson(
            allocator,
            service.venom_json,
        );
        defer parsed.deinit(allocator);
        const driver = try runtime_probe_store.driverFromServiceJson(
            &parsed.descriptor,
            service.venom_json,
        );
        try runtime_manager.registerWithPolicy(
            &parsed.descriptor,
            driver,
            parsed.policy,
        );
    }
    try runtime_manager.startAll();
}

fn applyRuntimeManagerStateToServiceRegistry(
    allocator: std.mem.Allocator,
    venom_registry: *node_capability_providers.Registry,
    runtime_manager: *venom_runtime_manager.RuntimeManager,
) !bool {
    var changed = false;
    for (venom_registry.extra_venoms.items) |*entry| {
        const state = runtime_manager.venomState(entry.venom_id) orelse continue;
        const stats = runtime_manager.venomRuntimeStats(entry.venom_id) orelse continue;
        const next_json = try renderVenomJsonWithRuntimeProbeState(
            allocator,
            entry.venom_json,
            state,
            stats,
        );
        if (std.mem.eql(u8, next_json, entry.venom_json)) {
            allocator.free(next_json);
            continue;
        }
        allocator.free(entry.venom_json);
        entry.venom_json = next_json;
        changed = true;
    }
    return changed;
}

fn renderVenomJsonWithRuntimeProbeState(
    allocator: std.mem.Allocator,
    venom_json: []const u8,
    state: namespace_driver.VenomState,
    stats: venom_runtime_manager.VenomRuntimeStats,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, temp_allocator, venom_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, venom_json);

    const state_name = venomStateJsonName(state);
    const root = &parsed.value.object;
    try jsonObjectPutString(root, "state", state_name);

    if (root.getPtr("mounts")) |mounts| {
        if (mounts.* == .array) {
            for (mounts.array.items) |*item| {
                if (item.* != .object) continue;
                try jsonObjectPutString(&item.object, "state", state_name);
            }
        }
    }

    const runtime_obj = try ensureJsonObjectField(temp_allocator, root, "runtime");
    var supervision_status = std.json.ObjectMap.init(temp_allocator);
    try jsonObjectPutString(&supervision_status, "state", state_name);
    try jsonObjectPutBool(&supervision_status, "enabled", stats.enabled);
    try jsonObjectPutBool(&supervision_status, "running", stats.running);
    try jsonObjectPutI64(&supervision_status, "start_attempts_total", clampU64ToI64(stats.start_attempts_total));
    try jsonObjectPutI64(&supervision_status, "restarts_total", clampU64ToI64(stats.restarts_total));
    try jsonObjectPutI64(&supervision_status, "consecutive_failures", stats.consecutive_failures);
    try jsonObjectPutI64(&supervision_status, "backoff_until_ms", stats.backoff_until_ms);
    try jsonObjectPutI64(&supervision_status, "last_transition_ms", stats.last_transition_ms);
    if (stats.last_healthy_ms > 0) {
        try jsonObjectPutI64(&supervision_status, "last_healthy_ms", stats.last_healthy_ms);
    } else {
        try jsonObjectPutNull(&supervision_status, "last_healthy_ms");
    }
    if (stats.lastError()) |last_error| {
        try jsonObjectPutString(&supervision_status, "last_error", last_error);
    } else {
        try jsonObjectPutNull(&supervision_status, "last_error");
    }
    const updated_at_ms: i64 = @max(stats.last_transition_ms, stats.last_healthy_ms);
    if (updated_at_ms > 0) {
        try jsonObjectPutI64(&supervision_status, "updated_at_ms", updated_at_ms);
    } else {
        try jsonObjectPutNull(&supervision_status, "updated_at_ms");
    }
    try jsonObjectPutValue(runtime_obj, "supervision_status", .{ .object = supervision_status });

    const rendered = try std.json.Stringify.valueAlloc(temp_allocator, parsed.value, .{});
    return allocator.dupe(u8, rendered);
}

fn venomStateJsonName(state: namespace_driver.VenomState) []const u8 {
    return switch (state) {
        .online => "online",
        .degraded => "degraded",
        .offline => "offline",
    };
}

fn clampU64ToI64(value: u64) i64 {
    if (value > std.math.maxInt(i64)) return std.math.maxInt(i64);
    return @intCast(value);
}

fn jsonObjectPutValue(obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const gop = try obj.getOrPut(key);
    gop.value_ptr.* = value;
}

fn jsonObjectPutString(obj: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try jsonObjectPutValue(obj, key, .{ .string = value });
}

fn jsonObjectPutBool(obj: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try jsonObjectPutValue(obj, key, .{ .bool = value });
}

fn jsonObjectPutNull(obj: *std.json.ObjectMap, key: []const u8) !void {
    try jsonObjectPutValue(obj, key, .null);
}

fn jsonObjectPutI64(obj: *std.json.ObjectMap, key: []const u8, value: anytype) !void {
    const typed: i64 = @intCast(value);
    try jsonObjectPutValue(obj, key, .{ .integer = typed });
}

fn ensureJsonObjectField(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    const gop = try obj.getOrPut(key);
    if (!gop.found_existing or gop.value_ptr.* != .object) {
        gop.value_ptr.* = .{ .object = std.json.ObjectMap.init(allocator) };
    }
    return &gop.value_ptr.object;
}

fn runControlRoutedNodeService(
    allocator: std.mem.Allocator,
    connect: ControlConnectOptions,
    base_exports: []const fs_node_ops.ExportSpec,
    static_namespace_exports: []const NamespaceVenomExportSpecOwned,
    venom_manifest_paths: []const []const u8,
    venom_dirs: []const []const u8,
    venom_registry: *node_capability_providers.Registry,
    shared_venom_registry: *SharedVenomRegistry,
    state_path: []const u8,
    manifest_reload_interval_ms: u64,
    reconnect_backoff_ms: u64,
    reconnect_backoff_max_ms: u64,
) !void {
    var runtime_namespace_exports = std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned){};
    defer {
        deinitNamespaceVenomExportList(allocator, &runtime_namespace_exports);
        runtime_namespace_exports.deinit(allocator);
    }
    var effective_exports = std.ArrayListUnmanaged(fs_node_ops.ExportSpec){};
    defer effective_exports.deinit(allocator);

    var service = try fs_node_service.NodeService.init(allocator, base_exports);
    defer service.deinit();
    var runtime_probe_store = RuntimeProbeDriverStore.init(allocator);
    defer runtime_probe_store.deinit();
    var runtime_manager = venom_runtime_manager.RuntimeManager.init(allocator);
    defer runtime_manager.deinit();
    const runtime_state_path = try runtimeStatePathForNodeState(allocator, state_path);
    defer allocator.free(runtime_state_path);
    loadNamespaceRuntimeStateFromFile(allocator, runtime_state_path, &service) catch |err| {
        std.log.warn("control tunnel: failed loading runtime state from {s}: {s}", .{ runtime_state_path, @errorName(err) });
    };
    var last_manifest_payload: ?[]u8 = null;
    defer if (last_manifest_payload) |payload| allocator.free(payload);
    var last_manifest_inputs_fingerprint: ?[]u8 = null;
    defer if (last_manifest_inputs_fingerprint) |payload| allocator.free(payload);
    const reload_interval_ms = if (manifest_reload_interval_ms == 0)
        default_manifest_reload_interval_ms
    else
        manifest_reload_interval_ms;
    const probe_sync_interval_ms: i64 = @intCast(default_runtime_probe_catalog_sync_interval_ms);
    var next_manifest_reload_ms = std.time.milliTimestamp() + @as(i64, @intCast(reload_interval_ms));
    var next_probe_sync_ms = std.time.milliTimestamp() + probe_sync_interval_ms;

    var attempts: u32 = 0;
    while (true) {
        var state = loadNodePairState(allocator, state_path) catch |state_err| {
            const wait_ms = computeBackoff(reconnect_backoff_ms, reconnect_backoff_max_ms, attempts);
            attempts +%= 1;
            std.log.warn("control tunnel: failed to read node state: {s}; retrying in {d} ms", .{ @errorName(state_err), wait_ms });
            std.Thread.sleep(wait_ms * std.time.ns_per_ms);
            continue;
        };
        defer state.deinit(allocator);
        if (!state.isPaired()) return error.PairingFailed;
        const node_id = state.node_id orelse return error.MissingField;
        const node_secret = state.node_secret orelse return error.MissingField;

        _ = refreshControlRuntimeForNode(
            allocator,
            &state,
            base_exports,
            static_namespace_exports,
            venom_manifest_paths,
            venom_dirs,
            venom_registry,
            shared_venom_registry,
            &runtime_manager,
            &runtime_probe_store,
            &runtime_namespace_exports,
            &effective_exports,
            &service,
            runtime_state_path,
            &last_manifest_payload,
            &last_manifest_inputs_fingerprint,
        ) catch |reload_err| {
            const wait_ms = computeBackoff(reconnect_backoff_ms, reconnect_backoff_max_ms, attempts);
            attempts +%= 1;
            std.log.warn("control tunnel: manifest load failed: {s}; retrying in {d} ms", .{ @errorName(reload_err), wait_ms });
            std.Thread.sleep(wait_ms * std.time.ns_per_ms);
            continue;
        };

        const parsed_url = parseWsUrlWithDefaultPath(connect.url, "/") catch |url_err| {
            const wait_ms = computeBackoff(reconnect_backoff_ms, reconnect_backoff_max_ms, attempts);
            attempts +%= 1;
            std.log.warn("control tunnel: invalid control URL: {s}; retrying in {d} ms", .{ @errorName(url_err), wait_ms });
            std.Thread.sleep(wait_ms * std.time.ns_per_ms);
            continue;
        };

        var stream = std.net.tcpConnectToHost(allocator, parsed_url.host, parsed_url.port) catch |conn_err| {
            const wait_ms = computeBackoff(reconnect_backoff_ms, reconnect_backoff_max_ms, attempts);
            attempts +%= 1;
            std.log.warn("control tunnel: connect failed: {s}; retrying in {d} ms", .{ @errorName(conn_err), wait_ms });
            std.Thread.sleep(wait_ms * std.time.ns_per_ms);
            continue;
        };
        defer stream.close();

        performClientHandshake(
            allocator,
            &stream,
            parsed_url.host,
            parsed_url.port,
            "/v2/node",
            connect.auth_token,
        ) catch |hs_err| {
            const wait_ms = computeBackoff(reconnect_backoff_ms, reconnect_backoff_max_ms, attempts);
            attempts +%= 1;
            std.log.warn("control tunnel: websocket handshake failed: {s}; retrying in {d} ms", .{ @errorName(hs_err), wait_ms });
            std.Thread.sleep(wait_ms * std.time.ns_per_ms);
            continue;
        };

        negotiateNodeTunnelHello(allocator, &stream, node_id, node_secret) catch |hello_err| switch (hello_err) {
            error.ControlNodeIdentityRejected => return error.ControlNodeIdentityRejected,
            else => {
                const wait_ms = computeBackoff(reconnect_backoff_ms, reconnect_backoff_max_ms, attempts);
                attempts +%= 1;
                std.log.warn("control tunnel: fs hello failed: {s}; retrying in {d} ms", .{ @errorName(hello_err), wait_ms });
                std.Thread.sleep(wait_ms * std.time.ns_per_ms);
                continue;
            },
        };

        attempts = 0;
        std.log.info("control tunnel established for node {s}", .{node_id});
        next_manifest_reload_ms = std.time.milliTimestamp() + @as(i64, @intCast(reload_interval_ms));
        next_probe_sync_ms = std.time.milliTimestamp() + probe_sync_interval_ms;

        while (true) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms >= next_manifest_reload_ms) {
                const changed = blk: {
                    break :blk refreshControlRuntimeForNode(
                        allocator,
                        &state,
                        base_exports,
                        static_namespace_exports,
                        venom_manifest_paths,
                        venom_dirs,
                        venom_registry,
                        shared_venom_registry,
                        &runtime_manager,
                        &runtime_probe_store,
                        &runtime_namespace_exports,
                        &effective_exports,
                        &service,
                        runtime_state_path,
                        &last_manifest_payload,
                        &last_manifest_inputs_fingerprint,
                    ) catch |reload_err| {
                        std.log.warn("control tunnel: manifest reload failed: {s}", .{@errorName(reload_err)});
                        break :blk false;
                    };
                };
                if (changed) {
                    const overlay_changed = blk: {
                        break :blk applyRuntimeManagerStateToServiceRegistry(
                            allocator,
                            venom_registry,
                            &runtime_manager,
                        ) catch |sync_err| {
                            std.log.warn("control tunnel: runtime state overlay failed after reload: {s}", .{@errorName(sync_err)});
                            break :blk false;
                        };
                    };
                    _ = overlay_changed;
                    shared_venom_registry.replaceFrom(venom_registry) catch |replace_err| {
                        std.log.warn("control tunnel: shared service registry replace failed after reload: {s}", .{@errorName(replace_err)});
                    };
                    upsertNodeVenomCatalog(
                        allocator,
                        connect,
                        venom_registry,
                        &state,
                    ) catch |upsert_err| switch (upsert_err) {
                        error.ControlNodeIdentityRejected => return error.ControlNodeIdentityRejected,
                        else => std.log.warn("control tunnel: service catalog upsert after reload failed: {s}", .{@errorName(upsert_err)}),
                    };
                    std.log.info("control tunnel: applied manifest hot-reload for node {s}", .{node_id});
                }
                next_manifest_reload_ms = now_ms + @as(i64, @intCast(reload_interval_ms));
            }

            if (now_ms >= next_probe_sync_ms) {
                const probe_changed = applyRuntimeManagerStateToServiceRegistry(
                    allocator,
                    venom_registry,
                    &runtime_manager,
                ) catch |sync_err| blk: {
                    std.log.warn("control tunnel: runtime probe state sync failed: {s}", .{@errorName(sync_err)});
                    break :blk false;
                };
                if (probe_changed) {
                    shared_venom_registry.replaceFrom(venom_registry) catch |replace_err| {
                        std.log.warn("control tunnel: shared service registry replace failed: {s}", .{@errorName(replace_err)});
                    };
                    upsertNodeVenomCatalog(
                        allocator,
                        connect,
                        venom_registry,
                        &state,
                    ) catch |upsert_err| switch (upsert_err) {
                        error.ControlNodeIdentityRejected => return error.ControlNodeIdentityRejected,
                        else => std.log.warn("control tunnel: runtime probe catalog upsert failed: {s}", .{@errorName(upsert_err)}),
                    };
                }
                next_probe_sync_ms = now_ms + probe_sync_interval_ms;
            }

            const readable = waitReadable(&stream, 250) catch |wait_err| {
                std.log.warn("control tunnel wait failed: {s}", .{@errorName(wait_err)});
                break;
            };
            if (!readable) continue;

            var frame = readServerFrame(allocator, &stream, 4 * 1024 * 1024) catch |read_err| {
                std.log.warn("control tunnel disconnected: {s}", .{@errorName(read_err)});
                break;
            };
            defer frame.deinit(allocator);

            switch (frame.opcode) {
                0x1 => {
                    var handled = service.handleRequestJsonWithEvents(frame.payload) catch |handle_err| blk: {
                        const fallback = try unified.buildFsrpcFsError(
                            allocator,
                            null,
                            fs_protocol.Errno.EIO,
                            @errorName(handle_err),
                        );
                        break :blk fs_node_service.NodeService.HandledRequest{
                            .response_json = fallback,
                            .events = try allocator.alloc(fs_protocol.InvalidationEvent, 0),
                        };
                    };
                    defer handled.deinit(allocator);

                    for (handled.events) |event| {
                        const event_json = try fs_node_service.buildInvalidationEventJson(allocator, event);
                        defer allocator.free(event_json);
                        try writeClientTextFrameMasked(allocator, &stream, event_json);
                    }
                    try writeClientTextFrameMasked(allocator, &stream, handled.response_json);
                    if (service.takeNamespaceRuntimeStateDirty()) {
                        saveNamespaceRuntimeStateToFile(allocator, runtime_state_path, &service) catch |save_err| {
                            std.log.warn("control tunnel: failed saving runtime state to {s}: {s}", .{ runtime_state_path, @errorName(save_err) });
                        };
                    }
                },
                0x8 => {
                    _ = writeClientFrameMasked(allocator, &stream, frame.payload, 0x8) catch {};
                    break;
                },
                0x9 => {
                    try writeClientPongFrameMasked(allocator, &stream, frame.payload);
                },
                0xA => {},
                else => {},
            }
        }

        const wait_ms = computeBackoff(reconnect_backoff_ms, reconnect_backoff_max_ms, attempts);
        attempts +%= 1;
        std.log.info("control tunnel reconnect in {d} ms", .{wait_ms});
        std.Thread.sleep(wait_ms * std.time.ns_per_ms);
    }
}

fn negotiateNodeTunnelHello(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    node_id: []const u8,
    node_secret: []const u8,
) !void {
    const escaped_node_id = try jsonEscape(allocator, node_id);
    defer allocator.free(escaped_node_id);
    const escaped_node_secret = try jsonEscape(allocator, node_secret);
    defer allocator.free(escaped_node_secret);
    const hello_request = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"acheron\",\"type\":\"acheron.t_fs_hello\",\"tag\":1,\"payload\":{{\"protocol\":\"{s}\",\"proto\":{d},\"node_id\":\"{s}\",\"node_secret\":\"{s}\"}}}}",
        .{ fsrpc_node_protocol_version, fsrpc_node_proto_id, escaped_node_id, escaped_node_secret },
    );
    defer allocator.free(hello_request);

    try writeClientTextFrameMasked(allocator, stream, hello_request);

    const deadline_ms = std.time.milliTimestamp() + @as(i64, control_reply_timeout_ms);
    while (true) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) return error.ControlRequestTimeout;
        const remaining_i64 = deadline_ms - now_ms;
        const remaining_ms: i32 = @intCast(@min(remaining_i64, @as(i64, std.math.maxInt(i32))));
        if (!try waitReadable(stream, remaining_ms)) return error.ControlRequestTimeout;

        var frame = try readServerFrame(allocator, stream, 4 * 1024 * 1024);
        defer frame.deinit(allocator);
        switch (frame.opcode) {
            0x1 => {
                var parsed = try unified.parseMessage(allocator, frame.payload);
                defer parsed.deinit(allocator);
                if (parsed.channel != .acheron) continue;
                if (parsed.tag == null or parsed.tag.? != 1) continue;
                const msg_type = parsed.acheron_type orelse continue;
                if (msg_type == .fs_r_hello) return;
                if (msg_type == .fs_err) {
                    if (parsed.payload_json) |payload_json| {
                        if (isNodeIdentityFsHelloError(payload_json)) return error.ControlNodeIdentityRejected;
                    }
                    return error.ControlRequestFailed;
                }
                continue;
            },
            0x8 => return error.ConnectionClosed,
            0x9 => try writeClientPongFrameMasked(allocator, stream, frame.payload),
            0xA => {},
            else => return error.InvalidFrameOpcode,
        }
    }
}

fn isControlNodeIdentityErrorCode(code: []const u8) bool {
    return std.mem.eql(u8, code, control_node_not_found_code) or
        std.mem.eql(u8, code, control_node_auth_failed_code);
}

fn isNodeIdentityFsHelloError(payload_json: []const u8) bool {
    return std.mem.indexOf(u8, payload_json, "NodeNotFound") != null or
        std.mem.indexOf(u8, payload_json, "NodeAuthFailed") != null;
}

fn computeBackoff(base_ms: u64, max_ms: u64, attempt: u32) u64 {
    const capped_attempt: u6 = @intCast(@min(attempt, 20));
    const shifted = base_ms << capped_attempt;
    if (shifted < base_ms) return max_ms;
    return @min(shifted, max_ms);
}

fn requestControlPayload(
    allocator: std.mem.Allocator,
    connect: ControlConnectOptions,
    op_type: []const u8,
    payload_json: []const u8,
) !ControlResult {
    const parsed_url = try parseWsUrlWithDefaultPath(connect.url, "/");
    var stream = try std.net.tcpConnectToHost(allocator, parsed_url.host, parsed_url.port);
    defer stream.close();

    try performClientHandshake(
        allocator,
        &stream,
        parsed_url.host,
        parsed_url.port,
        parsed_url.path,
        connect.auth_token,
    );
    try negotiateControlVersion(allocator, &stream, "fs-node-version");

    try writeClientTextFrameMasked(
        allocator,
        &stream,
        "{\"channel\":\"control\",\"type\":\"control.connect\",\"id\":\"fs-node-connect\",\"payload\":{}}",
    );
    const connect_envelope = try readControlEnvelopeFor(
        allocator,
        &stream,
        "fs-node-connect",
        control_reply_timeout_ms,
    );
    defer allocator.free(connect_envelope);
    try ensureEnvelopeType(allocator, connect_envelope, "control.connect_ack");

    const escaped_type = try jsonEscape(allocator, op_type);
    defer allocator.free(escaped_type);
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"{s}\",\"id\":\"fs-node-op\",\"payload\":{s}}}",
        .{ escaped_type, payload_json },
    );
    defer allocator.free(message);

    try writeClientTextFrameMasked(allocator, &stream, message);
    const envelope = try readControlEnvelopeFor(
        allocator,
        &stream,
        "fs-node-op",
        control_reply_timeout_ms,
    );
    defer allocator.free(envelope);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, envelope, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidControlResponse;

    const msg_type_val = parsed.value.object.get("type") orelse return error.InvalidControlResponse;
    if (msg_type_val != .string) return error.InvalidControlResponse;

    if (std.mem.eql(u8, msg_type_val.string, "control.error")) {
        const err_val = parsed.value.object.get("error") orelse return error.InvalidControlResponse;
        if (err_val != .object) return error.InvalidControlResponse;
        const code_val = err_val.object.get("code") orelse return error.InvalidControlResponse;
        if (code_val != .string or code_val.string.len == 0) return error.InvalidControlResponse;
        const message_val = err_val.object.get("message") orelse return error.InvalidControlResponse;
        if (message_val != .string) return error.InvalidControlResponse;
        return .{
            .remote_error = .{
                .code = try allocator.dupe(u8, code_val.string),
                .message = try allocator.dupe(u8, message_val.string),
            },
        };
    }

    if (!std.mem.eql(u8, msg_type_val.string, op_type)) return error.UnexpectedControlResponse;

    const payload_val = parsed.value.object.get("payload") orelse return .{ .payload_json = try allocator.dupe(u8, "{}") };
    return .{ .payload_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload_val, .{})}) };
}

fn ensureEnvelopeType(allocator: std.mem.Allocator, envelope_json: []const u8, expected_type: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, envelope_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidControlResponse;

    const msg_type_val = parsed.value.object.get("type") orelse return error.InvalidControlResponse;
    if (msg_type_val != .string) return error.InvalidControlResponse;

    if (std.mem.eql(u8, msg_type_val.string, expected_type)) return;

    if (std.mem.eql(u8, msg_type_val.string, "control.error")) {
        const err_val = parsed.value.object.get("error") orelse return error.ControlRequestFailed;
        if (err_val == .object) {
            const code = if (err_val.object.get("code")) |value| if (value == .string) value.string else "unknown" else "unknown";
            const message = if (err_val.object.get("message")) |value| if (value == .string) value.string else "control.error" else "control.error";
            std.log.warn("control operation rejected during handshake: code={s} message={s}", .{ code, message });
        }
        return error.ControlRequestFailed;
    }

    return error.UnexpectedControlResponse;
}

fn parseNodeJoinPayload(allocator: std.mem.Allocator, payload_json: []const u8) !NodeJoinPayload {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;

    const node_id = try dupRequiredString(allocator, parsed.value.object, "node_id");
    errdefer allocator.free(node_id);
    const node_secret = try dupRequiredString(allocator, parsed.value.object, "node_secret");
    errdefer allocator.free(node_secret);
    const lease_token = try dupRequiredString(allocator, parsed.value.object, "lease_token");
    errdefer allocator.free(lease_token);
    const lease_expires_at_ms = getOptionalI64(parsed.value.object, "lease_expires_at_ms", 0) catch 0;

    return .{
        .node_id = node_id,
        .node_secret = node_secret,
        .lease_token = lease_token,
        .lease_expires_at_ms = lease_expires_at_ms,
        .node_name = try dupOptionalString(allocator, parsed.value.object, "node_name"),
        .fs_url = try dupOptionalString(allocator, parsed.value.object, "fs_url"),
    };
}

fn parsePendingRequestId(allocator: std.mem.Allocator, payload_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    return dupRequiredString(allocator, parsed.value.object, "request_id");
}

fn loadNodePairState(allocator: std.mem.Allocator, state_path: []const u8) !NodePairState {
    const raw = std.fs.cwd().readFileAlloc(allocator, state_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidStateFile;

    var state = NodePairState{};
    errdefer state.deinit(allocator);

    state.node_id = try dupOptionalNullableString(allocator, parsed.value.object, "node_id");
    state.node_secret = try dupOptionalNullableString(allocator, parsed.value.object, "node_secret");
    state.lease_token = try dupOptionalNullableString(allocator, parsed.value.object, "lease_token");
    state.request_id = try dupOptionalNullableString(allocator, parsed.value.object, "request_id");
    state.node_name = try dupOptionalNullableString(allocator, parsed.value.object, "node_name");
    state.fs_url = try dupOptionalNullableString(allocator, parsed.value.object, "fs_url");
    state.lease_expires_at_ms = getOptionalI64(parsed.value.object, "lease_expires_at_ms", 0) catch 0;

    return state;
}

fn saveNodePairState(allocator: std.mem.Allocator, state_path: []const u8, state: *const NodePairState) !void {
    try ensureParentPathExists(state_path);

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1");
    try appendOptionalJsonStringField(allocator, &out, "node_id", state.node_id);
    try appendOptionalJsonStringField(allocator, &out, "node_secret", state.node_secret);
    try appendOptionalJsonStringField(allocator, &out, "lease_token", state.lease_token);
    try out.writer(allocator).print(",\"lease_expires_at_ms\":{d}", .{state.lease_expires_at_ms});
    try appendOptionalJsonStringField(allocator, &out, "request_id", state.request_id);
    try appendOptionalJsonStringField(allocator, &out, "node_name", state.node_name);
    try appendOptionalJsonStringField(allocator, &out, "fs_url", state.fs_url);
    try out.append(allocator, '}');

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{state_path});
    defer allocator.free(tmp_path);

    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = out.items });
    try std.fs.cwd().rename(tmp_path, state_path);
}

fn runtimeStatePathForNodeState(allocator: std.mem.Allocator, state_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.runtime-services.json", .{state_path});
}

fn loadNamespaceRuntimeStateFromFile(
    allocator: std.mem.Allocator,
    runtime_state_path: []const u8,
    service: *fs_node_service.NodeService,
) !void {
    const raw = std.fs.cwd().readFileAlloc(allocator, runtime_state_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(raw);
    try service.restoreNamespaceRuntimeStateJson(raw);
}

fn saveNamespaceRuntimeStateToFile(
    allocator: std.mem.Allocator,
    runtime_state_path: []const u8,
    service: *fs_node_service.NodeService,
) !void {
    const payload = try service.exportNamespaceRuntimeStateJson(allocator);
    defer allocator.free(payload);

    try ensureParentPathExists(runtime_state_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{runtime_state_path});
    defer allocator.free(tmp_path);

    try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = payload });
    try std.fs.cwd().rename(tmp_path, runtime_state_path);
}

fn appendOptionalJsonStringField(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    key: []const u8,
    value: ?[]const u8,
) !void {
    if (value) |raw| {
        const escaped = try jsonEscape(allocator, raw);
        defer allocator.free(escaped);
        try out.writer(allocator).print(",\"{s}\":\"{s}\"", .{ key, escaped });
        return;
    }
    try out.writer(allocator).print(",\"{s}\":null", .{key});
}

fn ensureParentPathExists(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;

    if (std.fs.path.isAbsolute(parent)) {
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        const relative = std.mem.trimLeft(u8, parent, "/");
        if (relative.len == 0) return;
        try root.makePath(relative);
        return;
    }

    try std.fs.cwd().makePath(parent);
}

fn dupRequiredString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ![]u8 {
    const value = obj.get(name) orelse return error.MissingField;
    if (value != .string or value.string.len == 0) return error.InvalidPayload;
    return allocator.dupe(u8, value.string);
}

fn dupOptionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) !?[]u8 {
    const value = obj.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidPayload;
    const copy = try allocator.dupe(u8, value.string);
    return @as(?[]u8, copy);
}

fn dupOptionalNullableString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) !?[]u8 {
    const value = obj.get(name) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidPayload;
    const copy = try allocator.dupe(u8, value.string);
    return @as(?[]u8, copy);
}

fn getOptionalI64(obj: std.json.ObjectMap, name: []const u8, default_value: i64) !i64 {
    const value = obj.get(name) orelse return default_value;
    if (value != .integer) return error.InvalidPayload;
    return value.integer;
}

fn parseExportFlag(raw: []const u8) !fs_node_ops.ExportSpec {
    const eq_index = std.mem.indexOfScalar(u8, raw, '=') orelse return error.InvalidFormat;
    const name = raw[0..eq_index];
    if (name.len == 0) return error.InvalidFormat;

    const rhs = raw[eq_index + 1 ..];
    if (rhs.len == 0) return error.InvalidFormat;

    var ro = false;
    var path = rhs;
    var gdrive_credential_handle: ?[]const u8 = null;

    while (true) {
        if (std.mem.endsWith(u8, path, ":ro")) {
            ro = true;
            path = path[0 .. path.len - 3];
            continue;
        }
        if (std.mem.endsWith(u8, path, ":rw")) {
            ro = false;
            path = path[0 .. path.len - 3];
            continue;
        }

        const cred_idx = std.mem.lastIndexOf(u8, path, ":cred=") orelse break;
        const handle = path[cred_idx + ":cred=".len ..];
        if (handle.len == 0) return error.InvalidFormat;
        if (std.mem.indexOfScalar(u8, handle, ':') != null) break;
        gdrive_credential_handle = handle;
        path = path[0..cred_idx];
    }

    if (path.len == 0) return error.InvalidFormat;

    return .{
        .name = name,
        .path = path,
        .ro = ro,
        .gdrive_credential_handle = gdrive_credential_handle,
        .desc = null,
    };
}

fn parseWsUrlWithDefaultPath(url: []const u8, default_path: []const u8) !ParsedWsUrl {
    const prefix = "ws://";
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidUrl;
    const rest = url[prefix.len..];

    const slash_idx = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..slash_idx];
    const path = if (slash_idx < rest.len) rest[slash_idx..] else default_path;
    if (host_port.len == 0) return error.InvalidUrl;

    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon_idx| {
        const host = host_port[0..colon_idx];
        const port_str = host_port[colon_idx + 1 ..];
        if (host.len == 0 or port_str.len == 0) return error.InvalidUrl;
        const port = try std.fmt.parseInt(u16, port_str, 10);
        return .{ .host = host, .port = port, .path = path };
    }
    return .{ .host = host_port, .port = 80, .path = path };
}

fn performClientHandshake(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    host: []const u8,
    port: u16,
    path: []const u8,
    auth_token: ?[]const u8,
) !void {
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    var encoded_nonce: [std.base64.standard.Encoder.calcSize(nonce.len)]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&encoded_nonce, &nonce);
    const auth_line = if (auth_token) |token|
        try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\r\n", .{token})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(auth_line);

    const request = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}:{d}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "{s}\r\n",
        .{ path, host, port, key, auth_line },
    );
    defer allocator.free(request);

    try streamWriteAll(stream, request);

    const response = try readHttpResponse(allocator, stream, 8 * 1024);
    defer allocator.free(response);
    if (std.mem.indexOf(u8, response, " 101 ") == null and std.mem.indexOf(u8, response, " 101\r\n") == null) {
        return error.HandshakeRejected;
    }
}

fn readHttpResponse(allocator: std.mem.Allocator, stream: *std.net.Stream, max_bytes: usize) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var chunk: [512]u8 = undefined;
    while (out.items.len < max_bytes) {
        const n = try streamRead(stream, &chunk);
        if (n == 0) return error.ConnectionClosed;
        try out.appendSlice(allocator, chunk[0..n]);
        if (std.mem.indexOf(u8, out.items, "\r\n\r\n") != null) {
            return out.toOwnedSlice(allocator);
        }
    }
    return error.ResponseTooLarge;
}

fn negotiateControlVersion(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    request_id: []const u8,
) !void {
    const escaped_request_id = try jsonEscape(allocator, request_id);
    defer allocator.free(escaped_request_id);
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"channel\":\"control\",\"type\":\"control.version\",\"id\":\"{s}\",\"payload\":{{\"protocol\":\"spiderweb-control\"}}}}",
        .{escaped_request_id},
    );
    defer allocator.free(message);

    try writeClientTextFrameMasked(allocator, stream, message);
    const envelope = try readControlEnvelopeFor(allocator, stream, request_id, control_reply_timeout_ms);
    defer allocator.free(envelope);
    try ensureEnvelopeType(allocator, envelope, "control.version_ack");
}

fn readControlEnvelopeFor(
    allocator: std.mem.Allocator,
    stream: *std.net.Stream,
    expected_id: []const u8,
    timeout_ms: i32,
) ![]u8 {
    const deadline_ms = std.time.milliTimestamp() + @as(i64, timeout_ms);

    while (true) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= deadline_ms) return error.ControlRequestTimeout;
        const remaining_i64 = deadline_ms - now_ms;
        const remaining_ms: i32 = @intCast(@min(remaining_i64, @as(i64, std.math.maxInt(i32))));
        if (!try waitReadable(stream, remaining_ms)) {
            return error.ControlRequestTimeout;
        }

        var frame = try readServerFrame(allocator, stream, 4 * 1024 * 1024);
        defer frame.deinit(allocator);

        switch (frame.opcode) {
            0x1 => {
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame.payload, .{});
                defer parsed.deinit();
                if (parsed.value != .object) continue;

                const channel = parsed.value.object.get("channel") orelse continue;
                if (channel != .string or !std.mem.eql(u8, channel.string, "control")) continue;

                const msg_id = parsed.value.object.get("id") orelse continue;
                if (msg_id != .string or !std.mem.eql(u8, msg_id.string, expected_id)) continue;

                return allocator.dupe(u8, frame.payload);
            },
            0x8 => return error.ConnectionClosed,
            0x9 => try writeClientPongFrameMasked(allocator, stream, frame.payload),
            0xA => {},
            else => return error.InvalidFrameOpcode,
        }
    }
}

fn waitReadable(stream: *std.net.Stream, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const ready = try std.posix.poll(&fds, timeout_ms);
    if (ready == 0) return false;
    if ((fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL)) != 0) {
        return error.ConnectionClosed;
    }
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

fn readServerFrame(allocator: std.mem.Allocator, stream: *std.net.Stream, max_payload_bytes: usize) !WsFrame {
    var header: [2]u8 = undefined;
    try readExact(stream, &header);

    const fin = (header[0] & 0x80) != 0;
    if (!fin) return error.UnsupportedFragmentation;
    const opcode = header[0] & 0x0F;
    const masked = (header[1] & 0x80) != 0;
    if (masked) return error.UnexpectedMaskedFrame;

    var payload_len: usize = header[1] & 0x7F;
    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
    }

    if (payload_len > max_payload_bytes) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    if (payload_len > 0) try readExact(stream, payload);

    return .{ .opcode = opcode, .payload = payload };
}

fn writeClientTextFrameMasked(allocator: std.mem.Allocator, stream: *std.net.Stream, payload: []const u8) !void {
    try writeClientFrameMasked(allocator, stream, payload, 0x1);
}

fn writeClientPongFrameMasked(allocator: std.mem.Allocator, stream: *std.net.Stream, payload: []const u8) !void {
    try writeClientFrameMasked(allocator, stream, payload, 0xA);
}

fn writeClientFrameMasked(allocator: std.mem.Allocator, stream: *std.net.Stream, payload: []const u8, opcode: u8) !void {
    var header: [14]u8 = undefined;
    var header_len: usize = 2;
    header[0] = 0x80 | opcode;

    if (payload.len < 126) {
        header[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= std.math.maxInt(u16)) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }

    var mask_key: [4]u8 = undefined;
    std.crypto.random.bytes(&mask_key);
    @memcpy(header[header_len .. header_len + 4], &mask_key);
    header_len += 4;

    const masked = try allocator.alloc(u8, payload.len);
    defer allocator.free(masked);
    for (payload, 0..) |byte, idx| {
        masked[idx] = byte ^ mask_key[idx % 4];
    }

    try streamWriteAll(stream, header[0..header_len]);
    if (masked.len > 0) try streamWriteAll(stream, masked);
}

fn readExact(stream: *std.net.Stream, out: []u8) !void {
    var offset: usize = 0;
    while (offset < out.len) {
        const n = try streamRead(stream, out[offset..]);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn streamRead(stream: *std.net.Stream, out: []u8) !usize {
    if (builtin.os.tag == .windows) {
        return std.posix.recv(stream.handle, out, 0) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            error.ConnectionTimedOut,
            => error.ConnectionClosed,
            else => err,
        };
    }
    return stream.read(out);
}

fn streamWriteAll(stream: *std.net.Stream, data: []const u8) !void {
    if (builtin.os.tag == .windows) {
        var offset: usize = 0;
        while (offset < data.len) {
            const sent = std.posix.send(stream.handle, data[offset..], 0) catch |err| switch (err) {
                error.ConnectionResetByPeer,
                error.BrokenPipe,
                => return error.ConnectionClosed,
                else => return err,
            };
            if (sent == 0) return error.ConnectionClosed;
            offset += sent;
        }
        return;
    }
    try stream.writeAll(data);
}

fn jsonEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    for (input) |char| {
        switch (char) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (char < 0x20) {
                    try out.writer(allocator).print("\\u00{x:0>2}", .{char});
                } else {
                    try out.append(allocator, char);
                }
            },
        }
    }

    return out.toOwnedSlice(allocator);
}

fn printHelp() !void {
    const help =
        \\spiderweb-fs-node - Distributed filesystem node server / daemon
        \\
        \\Usage:
        \\  spiderweb-fs-node [--bind <addr>] [--port <port>] [--export <name>=<path>[:ro|:rw][:cred=<handle>]] [--auth-token <token>]
        \\                    [--control-url <ws-url> [--control-auth-token <token>] [--pair-mode <invite|request>] [--invite-token <token>]
        \\                     [--operator-token <token>] [--node-name <name>] [--fs-url <ws-url>] [--state-file <path>]
        \\                     [--lease-ttl-ms <ms>] [--refresh-interval-ms <ms>] [--manifest-reload-interval-ms <ms>] [--reconnect-backoff-ms <ms>] [--reconnect-backoff-max-ms <ms>]
        \\                     [--no-fs-venom] [--terminal-id <id>] [--label <key=value>]
        \\                     [--venom-manifest <path>] [--venoms-dir <path>]]
        \\
        \\Examples:
        \\  spiderweb-fs-node --export work=.:rw
        \\  spiderweb-fs-node --bind 0.0.0.0 --port 18891 --export repo=/home/user/repo:ro
        \\  spiderweb-fs-node --export cloud=drive:root:ro:cred=gdrive.team
        \\  spiderweb-fs-node --auth-token my-node-session-token
        \\  spiderweb-fs-node --control-url ws://127.0.0.1:18790/ --pair-mode invite --invite-token invite-abc --node-name clawz --fs-url ws://10.0.0.8:18891/fs
        \\  spiderweb-fs-node --control-url ws://127.0.0.1:18790/ --pair-mode request --node-name edge-1 --state-file ./node-state.json
        \\  spiderweb-fs-node --control-url ws://127.0.0.1:18790/ --pair-mode request --terminal-id 1 --terminal-id 2 --label site=hq --label tier=edge
        \\  spiderweb-fs-node --control-url ws://127.0.0.1:18790/ --pair-mode request --venoms-dir ./services.d
        \\  spiderweb-fs-node --venom-manifest ./services.d/camera.json
        \\  (control auth token can come from SPIDERWEB_AUTH_TOKEN when --control-url is used)
        \\  (standalone fs auth token can come from SPIDERWEB_FS_NODE_AUTH_TOKEN when --control-url is not used)
        \\
    ;
    try std.fs.File.stdout().writeAll(help);
}

test "fs_node_main: parsePairMode accepts invite and request" {
    try std.testing.expect(parsePairMode("invite").? == .invite);
    try std.testing.expect(parsePairMode("request").? == .request);
    try std.testing.expect(parsePairMode("other") == null);
}

test "fs_node_main: parseLabelArg validates key-value format" {
    const parsed = try parseLabelArg("site=home-lab");
    try std.testing.expectEqualStrings("site", parsed.key);
    try std.testing.expectEqualStrings("home-lab", parsed.value);
    try std.testing.expectError(error.InvalidArguments, parseLabelArg("missing"));
    try std.testing.expectError(error.InvalidArguments, parseLabelArg("=empty"));
}

test "fs_node_main: loads extra services from manifest file" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.writeFile(.{
        .sub_path = "camera.json",
        .data =
        \\{
        \\  "venom_id": "camera-main",
        \\  "kind": "camera",
        \\  "endpoints": ["/nodes/{node_id}/camera"],
        \\  "mounts": [{"mount_id":"camera-main","mount_path":"/nodes/{node_id}/camera","state":"online"}]
        \\}
        ,
    });

    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/camera.json", .{root});
    defer allocator.free(manifest_path);

    var registry = try node_capability_providers.Registry.init(allocator, .{
        .enable_fs_venom = false,
    });
    defer registry.deinit();
    var runtime_exports = std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned){};
    defer {
        deinitNamespaceVenomExportList(allocator, &runtime_exports);
        runtime_exports.deinit(allocator);
    }

    try loadConfiguredManifestVenoms(
        allocator,
        "node-5",
        &.{manifest_path},
        &.{},
        &registry,
        &runtime_exports,
    );

    const payload = try registry.buildVenomUpsertPayload(
        allocator,
        "node-5",
        "secret",
        "linux",
        "amd64",
        "native",
    );
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"camera-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"/nodes/node-5/camera\"") != null);
}

test "fs_node_main: loads wasm non-fs service and creates runtime namespace export" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    try temp.dir.writeFile(.{
        .sub_path = "converter.json",
        .data =
        \\{
        \\  "venom_id": "doc-convert",
        \\  "kind": "converter",
        \\  "endpoints": ["/nodes/{node_id}/convert"],
        \\  "runtime": {
        \\    "type": "wasm",
        \\    "module_path": "./drivers/convert.wasm",
        \\    "entrypoint": "invoke",
        \\    "args": ["--sandbox", "strict"]
        \\  },
        \\  "mounts": [{"mount_id":"doc-convert","mount_path":"/nodes/{node_id}/convert","state":"online"}]
        \\}
        ,
    });

    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/converter.json", .{root});
    defer allocator.free(manifest_path);

    var registry = try node_capability_providers.Registry.init(allocator, .{
        .enable_fs_venom = false,
    });
    defer registry.deinit();
    var runtime_exports = std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned){};
    defer {
        deinitNamespaceVenomExportList(allocator, &runtime_exports);
        runtime_exports.deinit(allocator);
    }

    try loadConfiguredManifestVenoms(
        allocator,
        "node-9",
        &.{manifest_path},
        &.{},
        &registry,
        &runtime_exports,
    );

    try std.testing.expectEqual(@as(usize, 1), runtime_exports.items.len);
    try std.testing.expect(runtime_exports.items[0].runtime_kind == .wasm);
    try std.testing.expectEqualStrings("doc-convert", runtime_exports.items[0].venom_id);
    try std.testing.expectEqualStrings("./drivers/convert.wasm", runtime_exports.items[0].module_path.?);

    const payload = try registry.buildVenomUpsertPayload(
        allocator,
        "node-9",
        "secret",
        "linux",
        "amd64",
        "native",
    );
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"venom_id\":\"doc-convert\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"kind\":\"converter\"") != null);
}

test "fs_node_main: runtime validator accepts declarative runtime metadata" {
    const allocator = std.testing.allocator;
    try validateVenomRuntimeConfig(
        allocator,
        "{\"venom_id\":\"camera-main\",\"kind\":\"camera\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/camera\"],\"runtime\":{\"type\":\"native_proc\"}}",
    );
    try validateVenomRuntimeConfig(
        allocator,
        "{\"venom_id\":\"pdf-wasm\",\"kind\":\"converter\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/convert\"],\"runtime\":{\"type\":\"wasm\"}}",
    );
}

test "fs_node_main: native_proc namespace export is built only when executable path is provided" {
    const allocator = std.testing.allocator;

    const missing_path = try buildNamespaceVenomExportFromVenomJson(
        allocator,
        "{\"venom_id\":\"camera-main\",\"kind\":\"camera\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/camera\"],\"runtime\":{\"type\":\"native_proc\"}}",
    );
    try std.testing.expect(missing_path == null);

    const with_path = try buildNamespaceVenomExportFromVenomJson(
        allocator,
        "{\"venom_id\":\"camera-main\",\"kind\":\"camera\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/camera\"],\"runtime\":{\"type\":\"native_proc\",\"executable_path\":\"./camera-driver\",\"args\":[\"--mode\",\"still\"]},\"schema\":{\"model\":\"camera-v1\",\"input\":\"control/invoke.json\"},\"invoke_template\":{\"op\":\"capture\",\"arguments\":{\"mode\":\"still\"}}}",
    );
    try std.testing.expect(with_path != null);
    var export_spec = with_path.?;
    defer export_spec.deinit(allocator);
    try std.testing.expectEqualStrings("camera-main", export_spec.name);
    try std.testing.expectEqualStrings("service:camera-main", export_spec.path);
    try std.testing.expect(export_spec.runtime_kind == .native_proc);
    try std.testing.expectEqualStrings("./camera-driver", export_spec.executable_path.?);
    try std.testing.expectEqual(@as(usize, 2), export_spec.args.items.len);
    try std.testing.expect(std.mem.indexOf(u8, export_spec.schema_json.?, "\"camera-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, export_spec.invoke_template_json.?, "\"capture\"") != null);

    const inproc_export = try buildNamespaceVenomExportFromVenomJson(
        allocator,
        "{\"venom_id\":\"camera-inproc\",\"kind\":\"camera\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/camera\"],\"runtime\":{\"type\":\"native_inproc\",\"library_path\":\"./camera-driver-inproc.so\",\"timeout_ms\":15000}}",
    );
    try std.testing.expect(inproc_export != null);
    var inproc_spec = inproc_export.?;
    defer inproc_spec.deinit(allocator);
    try std.testing.expect(inproc_spec.runtime_kind == .native_inproc);
    try std.testing.expectEqualStrings("./camera-driver-inproc.so", inproc_spec.library_path.?);
    try std.testing.expectEqual(@as(u64, 15_000), inproc_spec.timeout_ms);

    const wasm_export = try buildNamespaceVenomExportFromVenomJson(
        allocator,
        "{\"venom_id\":\"pdf-wasm\",\"kind\":\"converter\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/convert\"],\"runtime\":{\"type\":\"wasm\",\"module_path\":\"./drivers/pdf.wasm\",\"entrypoint\":\"invoke\",\"fuel\":1234,\"max_memory_bytes\":65536}}",
    );
    try std.testing.expect(wasm_export != null);
    var wasm_spec = wasm_export.?;
    defer wasm_spec.deinit(allocator);
    try std.testing.expect(wasm_spec.runtime_kind == .wasm);
    try std.testing.expectEqualStrings("./drivers/pdf.wasm", wasm_spec.module_path.?);
    try std.testing.expectEqualStrings("invoke", wasm_spec.wasm_entrypoint.?);
    try std.testing.expectEqual(@as(?u64, 1234), wasm_spec.fuel);
    try std.testing.expectEqual(@as(?u64, 65536), wasm_spec.max_memory_bytes);
}

test "fs_node_main: runtime validator rejects unknown runtime type" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidArguments,
        validateVenomRuntimeConfig(
            allocator,
            "{\"venom_id\":\"bad\",\"kind\":\"custom\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/custom\"],\"runtime\":{\"type\":\"mystery\"}}",
        ),
    );
}

test "fs_node_main: runtime validator rejects unsupported native_inproc abi marker" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidArguments,
        validateVenomRuntimeConfig(
            allocator,
            "{\"venom_id\":\"camera\",\"kind\":\"camera\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/camera\"],\"runtime\":{\"type\":\"native_inproc\",\"abi\":\"legacy-v0\"}}",
        ),
    );
}

test "fs_node_main: control node identity error codes are detected" {
    try std.testing.expect(isControlNodeIdentityErrorCode("node_not_found"));
    try std.testing.expect(isControlNodeIdentityErrorCode("node_auth_failed"));
    try std.testing.expect(!isControlNodeIdentityErrorCode("invalid_payload"));
}

test "fs_node_main: fs hello identity errors are detected" {
    try std.testing.expect(isNodeIdentityFsHelloError("{\"errno\":13,\"message\":\"NodeNotFound\"}"));
    try std.testing.expect(isNodeIdentityFsHelloError("{\"errno\":13,\"message\":\"NodeAuthFailed\"}"));
    try std.testing.expect(!isNodeIdentityFsHelloError("{\"errno\":5,\"message\":\"Unexpected\"}"));
}

test "fs_node_main: node pair state save/load roundtrip" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const state_path = try std.fmt.allocPrint(allocator, "{s}/pair-state.json", .{root});
    defer allocator.free(state_path);

    var state = NodePairState{
        .node_id = try allocator.dupe(u8, "node-12"),
        .node_secret = try allocator.dupe(u8, "secret-abc"),
        .lease_token = try allocator.dupe(u8, "lease-xyz"),
        .lease_expires_at_ms = 1739999999999,
        .request_id = try allocator.dupe(u8, "pending-join-2"),
        .node_name = try allocator.dupe(u8, "edge-12"),
        .fs_url = try allocator.dupe(u8, "ws://10.0.0.12:18891/fs"),
    };
    defer state.deinit(allocator);

    try saveNodePairState(allocator, state_path, &state);

    var loaded = try loadNodePairState(allocator, state_path);
    defer loaded.deinit(allocator);

    try std.testing.expect(loaded.isPaired());
    try std.testing.expectEqualStrings("node-12", loaded.node_id.?);
    try std.testing.expectEqualStrings("secret-abc", loaded.node_secret.?);
    try std.testing.expectEqualStrings("lease-xyz", loaded.lease_token.?);
    try std.testing.expectEqual(@as(i64, 1739999999999), loaded.lease_expires_at_ms);
    try std.testing.expectEqualStrings("pending-join-2", loaded.request_id.?);
    try std.testing.expectEqualStrings("edge-12", loaded.node_name.?);
    try std.testing.expectEqualStrings("ws://10.0.0.12:18891/fs", loaded.fs_url.?);
}

test "fs_node_main: runtime state path derives from node state path" {
    const allocator = std.testing.allocator;
    const path = try runtimeStatePathForNodeState(allocator, "/tmp/pair-state.json");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/pair-state.json.runtime-services.json", path);
}

test "fs_node_main: terminal ids build executable namespace exports" {
    const allocator = std.testing.allocator;
    var terminal_exports = std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned){};
    defer {
        deinitNamespaceVenomExportList(allocator, &terminal_exports);
        terminal_exports.deinit(allocator);
    }

    try buildTerminalNamespaceExports(
        allocator,
        &.{ "1", "2" },
        "/tmp/spiderweb-fs-node",
        &terminal_exports,
    );

    try std.testing.expectEqual(@as(usize, 2), terminal_exports.items.len);
    const first = terminal_exports.items[0];
    try std.testing.expectEqualStrings("terminal-1", first.name);
    try std.testing.expectEqualStrings("/terminal/1", first.path);
    try std.testing.expectEqualStrings("service:terminal-1", first.source_id);
    try std.testing.expectEqualStrings("terminal-1", first.venom_id);
    try std.testing.expect(first.runtime_kind == .native_proc);
    try std.testing.expectEqualStrings("/tmp/spiderweb-fs-node", first.executable_path.?);
    try std.testing.expectEqual(@as(usize, 3), first.args.items.len);
    try std.testing.expectEqualStrings("--internal-terminal-invoke", first.args.items[0]);
    try std.testing.expectEqualStrings("--terminal-id", first.args.items[1]);
    try std.testing.expectEqualStrings("1", first.args.items[2]);
    try std.testing.expect(std.mem.indexOf(u8, first.schema_json.?, "\"terminal-driver-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.invoke_template_json.?, "\"terminal_exec\"") != null);
}

test "fs_node_main: invokeTerminalRequestJson executes argv payload" {
    const allocator = std.testing.allocator;
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const escaped_self_exe = try jsonEscape(allocator, self_exe);
    defer allocator.free(escaped_self_exe);

    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"argv\":[\"{s}\",\"--help\"],\"max_output_bytes\":4096}}",
        .{escaped_self_exe},
    );
    defer allocator.free(payload);

    const result = try invokeTerminalRequestJson(allocator, "1", payload);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"service\":\"terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"terminal_id\":\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"operation\":\"exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"exit_code\":0") != null);
}

test "fs_node_main: invokeTerminalRequestJson rejects invalid payload" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidPayload,
        invokeTerminalRequestJson(allocator, "1", "{}"),
    );
}

test "fs_node_main: refreshControlRuntimeForNode detects manifest changes" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/hot.json", .{root});
    defer allocator.free(manifest_path);
    const runtime_state_path = try std.fmt.allocPrint(allocator, "{s}/runtime-state.json", .{root});
    defer allocator.free(runtime_state_path);

    try temp.dir.writeFile(.{
        .sub_path = "hot.json",
        .data =
        \\{
        \\  "venom_id": "hot-a",
        \\  "kind": "tooling",
        \\  "runtime": { "type": "builtin" }
        \\}
        ,
    });

    var state = NodePairState{
        .node_id = try allocator.dupe(u8, "node-hot"),
        .node_secret = try allocator.dupe(u8, "secret-hot"),
    };
    defer state.deinit(allocator);

    var registry = try node_capability_providers.Registry.init(allocator, .{
        .enable_fs_venom = false,
        .export_specs = &.{},
    });
    defer registry.deinit();
    var shared_registry = try SharedVenomRegistry.init(allocator, &registry);
    defer shared_registry.deinit();

    var runtime_probe_store = RuntimeProbeDriverStore.init(allocator);
    defer runtime_probe_store.deinit();
    var runtime_manager = venom_runtime_manager.RuntimeManager.init(allocator);
    defer runtime_manager.deinit();
    var runtime_exports = std.ArrayListUnmanaged(NamespaceVenomExportSpecOwned){};
    defer {
        deinitNamespaceVenomExportList(allocator, &runtime_exports);
        runtime_exports.deinit(allocator);
    }
    var effective_exports = std.ArrayListUnmanaged(fs_node_ops.ExportSpec){};
    defer effective_exports.deinit(allocator);
    var service = try fs_node_service.NodeService.init(allocator, &.{});
    defer service.deinit();
    var last_payload: ?[]u8 = null;
    defer if (last_payload) |payload| allocator.free(payload);
    var last_inputs_fingerprint: ?[]u8 = null;
    defer if (last_inputs_fingerprint) |value| allocator.free(value);

    const changed_initial = try refreshControlRuntimeForNode(
        allocator,
        &state,
        &.{},
        &.{},
        &.{manifest_path},
        &.{},
        &registry,
        &shared_registry,
        &runtime_manager,
        &runtime_probe_store,
        &runtime_exports,
        &effective_exports,
        &service,
        runtime_state_path,
        &last_payload,
        &last_inputs_fingerprint,
    );
    try std.testing.expect(changed_initial);
    try std.testing.expectEqual(@as(usize, 1), registry.extra_venoms.items.len);
    try std.testing.expect(last_payload != null);

    const changed_noop = try refreshControlRuntimeForNode(
        allocator,
        &state,
        &.{},
        &.{},
        &.{manifest_path},
        &.{},
        &registry,
        &shared_registry,
        &runtime_manager,
        &runtime_probe_store,
        &runtime_exports,
        &effective_exports,
        &service,
        runtime_state_path,
        &last_payload,
        &last_inputs_fingerprint,
    );
    try std.testing.expect(!changed_noop);

    try temp.dir.writeFile(.{
        .sub_path = "hot.json",
        .data =
        \\{
        \\  "venom_id": "hot-b",
        \\  "kind": "tooling",
        \\  "runtime": { "type": "builtin" }
        \\}
        ,
    });

    const changed_update = try refreshControlRuntimeForNode(
        allocator,
        &state,
        &.{},
        &.{},
        &.{manifest_path},
        &.{},
        &registry,
        &shared_registry,
        &runtime_manager,
        &runtime_probe_store,
        &runtime_exports,
        &effective_exports,
        &service,
        runtime_state_path,
        &last_payload,
        &last_inputs_fingerprint,
    );
    try std.testing.expect(changed_update);
    try std.testing.expectEqualStrings("hot-b", registry.extra_venoms.items[0].venom_id);
}

test "fs_node_main: syncVenomRuntimeManagerFromRegistry probes runtime drivers" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const executable_path = try std.fmt.allocPrint(allocator, "{s}/probe-driver", .{root});
    defer allocator.free(executable_path);
    try temp.dir.writeFile(.{
        .sub_path = "probe-driver",
        .data = "#!/bin/sh\necho ok\n",
    });

    var registry = try node_capability_providers.Registry.init(allocator, .{
        .enable_fs_venom = false,
    });
    defer registry.deinit();

    const escaped_exec = try jsonEscape(allocator, executable_path);
    defer allocator.free(escaped_exec);
    const venom_json = try std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"svc-probe\",\"kind\":\"tooling\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"/nodes/node-1/venoms/svc-probe\"],\"mounts\":[{{\"mount_id\":\"svc-probe\",\"mount_path\":\"/nodes/node-1/venoms/svc-probe\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"style\":\"plan9\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\",\"executable_path\":\"{s}\",\"supervision\":{{\"health_check_interval_ms\":10,\"restart_backoff_ms\":5,\"restart_backoff_max_ms\":20}}}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}",
        .{escaped_exec},
    );
    defer allocator.free(venom_json);

    try registry.addExtraVenom("svc-probe", venom_json);

    var runtime_probe_store = RuntimeProbeDriverStore.init(allocator);
    defer runtime_probe_store.deinit();
    var runtime_manager = venom_runtime_manager.RuntimeManager.init(allocator);
    defer runtime_manager.deinit();

    try syncVenomRuntimeManagerFromRegistry(
        allocator,
        &registry,
        &runtime_manager,
        &runtime_probe_store,
    );

    const initial_stats = runtime_manager.venomRuntimeStats("svc-probe") orelse return error.TestExpectedResponse;
    try std.testing.expect(initial_stats.running);
    try std.testing.expectEqual(namespace_driver.VenomState.online, runtime_manager.venomState("svc-probe").?);

    try temp.dir.deleteFile("probe-driver");

    const deadline = std.time.milliTimestamp() + 2_000;
    var degraded = false;
    while (std.time.milliTimestamp() < deadline) {
        const state = runtime_manager.venomState("svc-probe") orelse return error.TestExpectedResponse;
        if (state != .online) {
            degraded = true;
            break;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    try std.testing.expect(degraded);
}

test "fs_node_main: runtime probe state overlays service catalog json" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const executable_path = try std.fmt.allocPrint(allocator, "{s}/probe-driver", .{root});
    defer allocator.free(executable_path);
    try temp.dir.writeFile(.{
        .sub_path = "probe-driver",
        .data = "#!/bin/sh\necho ok\n",
    });

    var registry = try node_capability_providers.Registry.init(allocator, .{
        .enable_fs_venom = false,
    });
    defer registry.deinit();

    const escaped_exec = try jsonEscape(allocator, executable_path);
    defer allocator.free(escaped_exec);
    const venom_json = try std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"svc-runtime-overlay\",\"kind\":\"tooling\",\"version\":\"1\",\"state\":\"offline\",\"endpoints\":[\"/nodes/node-1/venoms/svc-runtime-overlay\"],\"mounts\":[{{\"mount_id\":\"svc-runtime-overlay\",\"mount_path\":\"/nodes/node-1/venoms/svc-runtime-overlay\",\"state\":\"offline\"}}],\"ops\":{{\"model\":\"namespace\",\"style\":\"plan9\"}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\",\"executable_path\":\"{s}\",\"supervision\":{{\"health_check_interval_ms\":10,\"restart_backoff_ms\":5,\"restart_backoff_max_ms\":20}}}},\"permissions\":{{\"default\":\"deny-by-default\"}},\"schema\":{{\"model\":\"namespace-mount\"}}}}",
        .{escaped_exec},
    );
    defer allocator.free(venom_json);
    try registry.addExtraVenom("svc-runtime-overlay", venom_json);

    var runtime_probe_store = RuntimeProbeDriverStore.init(allocator);
    defer runtime_probe_store.deinit();
    var runtime_manager = venom_runtime_manager.RuntimeManager.init(allocator);
    defer runtime_manager.deinit();
    try syncVenomRuntimeManagerFromRegistry(
        allocator,
        &registry,
        &runtime_manager,
        &runtime_probe_store,
    );

    const first_overlay = try applyRuntimeManagerStateToServiceRegistry(
        allocator,
        &registry,
        &runtime_manager,
    );
    try std.testing.expect(first_overlay);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"supervision_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"state\":\"online\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"last_healthy_ms\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"last_error\":null") != null);

    try temp.dir.deleteFile("probe-driver");
    const degraded_deadline = std.time.milliTimestamp() + 2_000;
    while (std.time.milliTimestamp() < degraded_deadline) {
        const state = runtime_manager.venomState("svc-runtime-overlay") orelse return error.TestExpectedResponse;
        if (state != .online) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const degraded_overlay = try applyRuntimeManagerStateToServiceRegistry(
        allocator,
        &registry,
        &runtime_manager,
    );
    try std.testing.expect(degraded_overlay);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"state\":\"degraded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"last_error\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"last_transition_ms\":") != null);

    try temp.dir.writeFile(.{
        .sub_path = "probe-driver",
        .data = "#!/bin/sh\necho ok\n",
    });
    const recover_deadline = std.time.milliTimestamp() + 2_000;
    while (std.time.milliTimestamp() < recover_deadline) {
        const state = runtime_manager.venomState("svc-runtime-overlay") orelse return error.TestExpectedResponse;
        if (state == .online) break;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }

    const recovered_overlay = try applyRuntimeManagerStateToServiceRegistry(
        allocator,
        &registry,
        &runtime_manager,
    );
    try std.testing.expect(recovered_overlay);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"state\":\"online\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, registry.extra_venoms.items[0].venom_json, "\"last_error\":null") != null);

    const no_churn_overlay = try applyRuntimeManagerStateToServiceRegistry(
        allocator,
        &registry,
        &runtime_manager,
    );
    try std.testing.expect(!no_churn_overlay);
}
