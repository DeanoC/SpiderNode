const std = @import("std");
const namespace_driver = @import("namespace_driver.zig");

const supervisor_loop_sleep_ms: u64 = 25;
const runtime_stats_last_error_max: usize = 256;

pub const VenomSupervisionPolicy = struct {
    health_check_interval_ms: u64 = 5_000,
    restart_backoff_ms: u64 = 500,
    restart_backoff_max_ms: u64 = 30_000,
    max_consecutive_failures: u32 = 0,
    auto_disable_on_failures: bool = false,
};

pub const VenomRuntimeStats = struct {
    enabled: bool,
    running: bool,
    start_attempts_total: u64,
    restarts_total: u64,
    consecutive_failures: u32,
    backoff_until_ms: i64,
    last_transition_ms: i64,
    last_healthy_ms: i64,
    last_error_len: usize = 0,
    last_error_buf: [runtime_stats_last_error_max]u8 = [_]u8{0} ** runtime_stats_last_error_max,

    pub fn lastError(self: *const VenomRuntimeStats) ?[]const u8 {
        if (self.last_error_len == 0) return null;
        return self.last_error_buf[0..self.last_error_len];
    }
};

pub const ParsedVenomRegistration = struct {
    descriptor: namespace_driver.VenomDescriptor,
    policy: VenomSupervisionPolicy,

    pub fn deinit(self: *ParsedVenomRegistration, allocator: std.mem.Allocator) void {
        self.descriptor.deinit(allocator);
        self.* = undefined;
    }
};

pub const RuntimeManager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    venoms: std.ArrayListUnmanaged(ManagedVenom) = .{},
    supervisor_thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const ManagedVenom = struct {
        descriptor: namespace_driver.VenomDescriptor,
        driver: ?namespace_driver.DriverHandle = null,
        policy: VenomSupervisionPolicy = .{},

        enabled: bool = true,
        running: bool = false,
        started_once: bool = false,
        start_attempts_total: u64 = 0,
        restarts_total: u64 = 0,
        consecutive_failures: u32 = 0,
        next_health_check_ms: i64 = 0,
        backoff_until_ms: i64 = 0,
        last_start_ms: i64 = 0,
        last_stop_ms: i64 = 0,
        last_transition_ms: i64 = 0,
        last_healthy_ms: i64 = 0,
        last_error: ?[]u8 = null,

        fn deinit(self: *ManagedVenom, allocator: std.mem.Allocator) void {
            self.descriptor.deinit(allocator);
            if (self.last_error) |value| allocator.free(value);
            self.* = undefined;
        }

        fn setLastError(self: *ManagedVenom, allocator: std.mem.Allocator, detail: []const u8) void {
            if (self.last_error) |value| allocator.free(value);
            self.last_error = allocator.dupe(u8, detail) catch null;
        }

        fn clearLastError(self: *ManagedVenom, allocator: std.mem.Allocator) void {
            if (self.last_error) |value| {
                allocator.free(value);
                self.last_error = null;
            }
        }

        fn runtimeStats(self: *const ManagedVenom) VenomRuntimeStats {
            var stats: VenomRuntimeStats = .{
                .enabled = self.enabled,
                .running = self.running,
                .start_attempts_total = self.start_attempts_total,
                .restarts_total = self.restarts_total,
                .consecutive_failures = self.consecutive_failures,
                .backoff_until_ms = self.backoff_until_ms,
                .last_transition_ms = self.last_transition_ms,
                .last_healthy_ms = self.last_healthy_ms,
            };
            if (self.last_error) |value| {
                const copy_len = @min(value.len, runtime_stats_last_error_max);
                if (copy_len > 0) {
                    @memcpy(stats.last_error_buf[0..copy_len], value[0..copy_len]);
                    stats.last_error_len = copy_len;
                }
            }
            return stats;
        }
    };

    pub fn init(allocator: std.mem.Allocator) RuntimeManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RuntimeManager) void {
        self.stopAll();
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.venoms.items) |*service| service.deinit(self.allocator);
        self.venoms.deinit(self.allocator);
    }

    pub fn register(self: *RuntimeManager, descriptor: *const namespace_driver.VenomDescriptor, driver: ?namespace_driver.DriverHandle) !void {
        return self.registerWithPolicy(descriptor, driver, .{});
    }

    pub fn registerWithPolicy(
        self: *RuntimeManager,
        descriptor: *const namespace_driver.VenomDescriptor,
        driver: ?namespace_driver.DriverHandle,
        policy: VenomSupervisionPolicy,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.findVenomIndexLocked(descriptor.venom_id) != null) {
            return error.DuplicateVenomId;
        }

        var normalized = policy;
        normalizePolicy(&normalized);

        try self.venoms.append(self.allocator, .{
            .descriptor = try descriptor.clone(self.allocator),
            .driver = driver,
            .policy = normalized,
            .enabled = true,
        });
    }

    pub fn startAll(self: *RuntimeManager) !void {
        self.stop_requested.store(false, .release);

        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = std.time.milliTimestamp();
        var has_supervised_drivers = false;

        for (self.venoms.items) |*service| {
            if (service.driver == null) continue;
            has_supervised_drivers = true;
            service.enabled = true;
            service.backoff_until_ms = 0;
            self.startVenomLocked(service, now_ms);
        }

        if (has_supervised_drivers and self.supervisor_thread == null) {
            self.supervisor_thread = try std.Thread.spawn(.{}, supervisorThreadMain, .{self});
        }
    }

    pub fn stopAll(self: *RuntimeManager) void {
        self.stop_requested.store(true, .release);

        var thread_to_join: ?std.Thread = null;

        self.mutex.lock();
        thread_to_join = self.supervisor_thread;
        self.supervisor_thread = null;

        const now_ms = std.time.milliTimestamp();
        for (self.venoms.items) |*service| {
            self.stopVenomLocked(service, now_ms, .offline);
            service.enabled = false;
            service.backoff_until_ms = 0;
            service.next_health_check_ms = 0;
        }
        self.mutex.unlock();

        if (thread_to_join) |thread| thread.join();
    }

    pub fn enableVenom(self: *RuntimeManager, venom_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const idx = self.findVenomIndexLocked(venom_id) orelse return error.VenomNotFound;
        const service = &self.venoms.items[idx];
        service.enabled = true;
        service.backoff_until_ms = 0;

        if (service.driver != null and !service.running) {
            self.startVenomLocked(service, std.time.milliTimestamp());
        }
    }

    pub fn disableVenom(self: *RuntimeManager, venom_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const idx = self.findVenomIndexLocked(venom_id) orelse return error.VenomNotFound;
        const service = &self.venoms.items[idx];
        service.enabled = false;
        service.backoff_until_ms = 0;
        self.stopVenomLocked(service, std.time.milliTimestamp(), .offline);
    }

    pub fn restartVenom(self: *RuntimeManager, venom_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const idx = self.findVenomIndexLocked(venom_id) orelse return error.VenomNotFound;
        const service = &self.venoms.items[idx];
        service.enabled = true;
        service.backoff_until_ms = 0;
        self.stopVenomLocked(service, std.time.milliTimestamp(), .degraded);
        self.startVenomLocked(service, std.time.milliTimestamp());
    }

    pub fn venomState(self: *RuntimeManager, venom_id: []const u8) ?namespace_driver.VenomState {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.findVenomIndexLocked(venom_id) orelse return null;
        return self.venoms.items[idx].descriptor.state;
    }

    pub fn venomRuntimeStats(self: *RuntimeManager, venom_id: []const u8) ?VenomRuntimeStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.findVenomIndexLocked(venom_id) orelse return null;
        return self.venoms.items[idx].runtimeStats();
    }

    pub fn registerFromVenomJson(self: *RuntimeManager, venom_json: []const u8) !void {
        var parsed = try parseVenomRegistrationFromVenomJson(self.allocator, venom_json);
        defer parsed.deinit(self.allocator);
        try self.registerWithPolicy(&parsed.descriptor, null, parsed.policy);
    }

    fn findVenomIndexLocked(self: *RuntimeManager, venom_id: []const u8) ?usize {
        for (self.venoms.items, 0..) |service, idx| {
            if (std.mem.eql(u8, service.descriptor.venom_id, venom_id)) return idx;
        }
        return null;
    }

    fn startVenomLocked(self: *RuntimeManager, service: *ManagedVenom, now_ms: i64) void {
        const driver = service.driver orelse return;

        service.start_attempts_total +%= 1;
        driver.start(self.allocator) catch |err| {
            self.setVenomStateLocked(service, .degraded, now_ms);
            service.running = false;
            service.setLastError(self.allocator, @errorName(err));
            service.consecutive_failures +%= 1;
            self.applyFailurePolicyLocked(service, now_ms);
            std.log.warn("venom start failed ({s}): {s}", .{ service.descriptor.venom_id, @errorName(err) });
            return;
        };

        if (service.started_once) {
            service.restarts_total +%= 1;
        } else {
            service.started_once = true;
        }

        service.running = true;
        self.setVenomStateLocked(service, .online, now_ms);
        service.consecutive_failures = 0;
        service.backoff_until_ms = 0;
        service.last_start_ms = now_ms;
        service.last_healthy_ms = now_ms;
        service.next_health_check_ms = now_ms + @as(i64, @intCast(service.policy.health_check_interval_ms));
        service.clearLastError(self.allocator);
    }

    fn stopVenomLocked(
        self: *RuntimeManager,
        service: *ManagedVenom,
        now_ms: i64,
        target_state: namespace_driver.VenomState,
    ) void {
        if (service.driver) |driver| {
            if (service.running) {
                driver.stop(self.allocator);
            }
        }
        service.running = false;
        service.last_stop_ms = now_ms;
        self.setVenomStateLocked(service, target_state, now_ms);
    }

    fn applyFailurePolicyLocked(self: *RuntimeManager, service: *ManagedVenom, now_ms: i64) void {
        if (service.policy.auto_disable_on_failures and
            service.policy.max_consecutive_failures > 0 and
            service.consecutive_failures >= service.policy.max_consecutive_failures)
        {
            service.enabled = false;
            service.backoff_until_ms = 0;
            self.setVenomStateLocked(service, .offline, now_ms);
            return;
        }

        const backoff_ms = computeBackoffMs(service.policy, service.consecutive_failures);
        if (backoff_ms == 0) {
            service.backoff_until_ms = 0;
        } else {
            service.backoff_until_ms = now_ms + @as(i64, @intCast(backoff_ms));
        }
    }

    fn recordHealthFailureLocked(
        self: *RuntimeManager,
        service: *ManagedVenom,
        now_ms: i64,
        detail: []const u8,
        state: namespace_driver.VenomState,
    ) void {
        service.setLastError(self.allocator, detail);
        service.consecutive_failures +%= 1;
        self.stopVenomLocked(service, now_ms, state);
        self.applyFailurePolicyLocked(service, now_ms);
        if (!service.enabled) {
            self.setVenomStateLocked(service, .offline, now_ms);
        } else {
            self.setVenomStateLocked(service, .degraded, now_ms);
        }
    }

    fn setVenomStateLocked(
        self: *RuntimeManager,
        service: *ManagedVenom,
        next: namespace_driver.VenomState,
        now_ms: i64,
    ) void {
        _ = self;
        if (service.descriptor.state != next or service.last_transition_ms == 0) {
            service.last_transition_ms = now_ms;
        }
        service.descriptor.state = next;
    }

    fn superviseTick(self: *RuntimeManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = std.time.milliTimestamp();

        for (self.venoms.items) |*service| {
            if (service.driver == null) continue;
            if (!service.enabled) continue;

            if (!service.running) {
                if (service.backoff_until_ms > now_ms) continue;
                self.startVenomLocked(service, now_ms);
                continue;
            }

            if (service.next_health_check_ms > now_ms) continue;
            service.next_health_check_ms = now_ms + @as(i64, @intCast(service.policy.health_check_interval_ms));

            const health = service.driver.?.health(self.allocator) catch |err| {
                self.recordHealthFailureLocked(
                    service,
                    now_ms,
                    @errorName(err),
                    .degraded,
                );
                continue;
            };

            if (health.state == .online) {
                if (service.descriptor.state != .online or service.last_healthy_ms == 0) {
                    service.last_healthy_ms = now_ms;
                }
                self.setVenomStateLocked(service, .online, now_ms);
                service.consecutive_failures = 0;
                service.clearLastError(self.allocator);
                continue;
            }

            const detail = if (health.detail.len > 0) health.detail else "driver health check failed";
            self.recordHealthFailureLocked(service, now_ms, detail, health.state);
        }
    }

    fn supervisorThreadMain(self: *RuntimeManager) void {
        while (!self.stop_requested.load(.acquire)) {
            self.superviseTick();
            std.Thread.sleep(supervisor_loop_sleep_ms * std.time.ns_per_ms);
        }
    }
};

pub fn parseVenomRegistrationFromVenomJson(
    allocator: std.mem.Allocator,
    venom_json: []const u8,
) !ParsedVenomRegistration {
    return .{
        .descriptor = try parseVenomDescriptor(allocator, venom_json),
        .policy = try parseVenomSupervisionPolicy(allocator, venom_json),
    };
}

fn normalizePolicy(policy: *VenomSupervisionPolicy) void {
    if (policy.health_check_interval_ms == 0) policy.health_check_interval_ms = 5_000;
    if (policy.restart_backoff_max_ms == 0) policy.restart_backoff_max_ms = 30_000;
    if (policy.restart_backoff_ms > policy.restart_backoff_max_ms) {
        policy.restart_backoff_max_ms = policy.restart_backoff_ms;
    }
}

fn computeBackoffMs(policy: VenomSupervisionPolicy, consecutive_failures: u32) u64 {
    if (policy.restart_backoff_ms == 0 or consecutive_failures == 0) return 0;

    var backoff = policy.restart_backoff_ms;
    var step: u32 = 1;
    while (step < consecutive_failures and backoff < policy.restart_backoff_max_ms) : (step += 1) {
        if (backoff > policy.restart_backoff_max_ms / 2) {
            backoff = policy.restart_backoff_max_ms;
            break;
        }
        backoff *= 2;
    }

    if (backoff > policy.restart_backoff_max_ms) return policy.restart_backoff_max_ms;
    return backoff;
}

fn parseVenomDescriptor(
    allocator: std.mem.Allocator,
    venom_json: []const u8,
) !namespace_driver.VenomDescriptor {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, venom_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidServiceCatalog;

    const obj = parsed.value.object;
    const venom_id = getRequiredString(obj, "venom_id") orelse return error.InvalidServiceCatalog;
    const kind = getRequiredString(obj, "kind") orelse return error.InvalidServiceCatalog;
    const version = getOptionalString(obj, "version") orelse "1";
    const state_raw = getOptionalString(obj, "state") orelse "unknown";

    var descriptor = namespace_driver.VenomDescriptor{
        .venom_id = try allocator.dupe(u8, venom_id),
        .kind = try allocator.dupe(u8, kind),
        .version = try allocator.dupe(u8, version),
        .state = parseVenomState(state_raw),
        .runtime_type = parseRuntimeType(obj),
        .capabilities_json = if (obj.get("capabilities")) |value|
            if (value == .object) try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})}) else try allocator.dupe(u8, "{}")
        else
            try allocator.dupe(u8, "{}"),
        .ops_json = if (obj.get("ops")) |value|
            if (value == .object) try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})}) else try allocator.dupe(u8, "{}")
        else
            try allocator.dupe(u8, "{}"),
        .permissions_json = if (obj.get("permissions")) |value|
            if (value == .object) try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})}) else try allocator.dupe(u8, "{}")
        else
            try allocator.dupe(u8, "{}"),
        .schema_json = if (obj.get("schema")) |value|
            if (value == .object) try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})}) else try allocator.dupe(u8, "{}")
        else
            try allocator.dupe(u8, "{}"),
        .help_md = if (obj.get("help_md")) |value|
            if (value == .string and value.string.len > 0) try allocator.dupe(u8, value.string) else null
        else
            null,
    };
    errdefer descriptor.deinit(allocator);

    if (obj.get("mounts")) |mounts| {
        if (mounts == .array) {
            for (mounts.array.items) |item| {
                if (item != .object) continue;
                const mount_id = getRequiredString(item.object, "mount_id") orelse continue;
                const mount_path = getRequiredString(item.object, "mount_path") orelse continue;
                const mount_state_raw = getOptionalString(item.object, "state") orelse "online";
                try descriptor.mounts.append(allocator, .{
                    .mount_id = try allocator.dupe(u8, mount_id),
                    .mount_path = try allocator.dupe(u8, mount_path),
                    .state = parseVenomState(mount_state_raw),
                });
            }
        }
    }

    return descriptor;
}

fn parseVenomSupervisionPolicy(
    allocator: std.mem.Allocator,
    venom_json: []const u8,
) !VenomSupervisionPolicy {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, venom_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidServiceCatalog;

    const runtime = parsed.value.object.get("runtime") orelse return .{};
    if (runtime != .object) return error.InvalidServiceCatalog;

    const supervision = runtime.object.get("supervision") orelse return .{};
    if (supervision != .object) return error.InvalidServiceCatalog;

    var policy = VenomSupervisionPolicy{};

    if (supervision.object.get("health_check_interval_ms")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidServiceCatalog;
        policy.health_check_interval_ms = @intCast(value.integer);
    }
    if (supervision.object.get("restart_backoff_ms")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidServiceCatalog;
        policy.restart_backoff_ms = @intCast(value.integer);
    }
    if (supervision.object.get("restart_backoff_max_ms")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidServiceCatalog;
        policy.restart_backoff_max_ms = @intCast(value.integer);
    }
    if (supervision.object.get("max_consecutive_failures")) |value| {
        if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) {
            return error.InvalidServiceCatalog;
        }
        policy.max_consecutive_failures = @intCast(value.integer);
    }
    if (supervision.object.get("auto_disable_on_failures")) |value| {
        if (value != .bool) return error.InvalidServiceCatalog;
        policy.auto_disable_on_failures = value.bool;
    }

    normalizePolicy(&policy);
    return policy;
}

fn parseRuntimeType(obj: std.json.ObjectMap) namespace_driver.RuntimeType {
    const runtime = obj.get("runtime") orelse return .builtin;
    if (runtime != .object) return .builtin;
    const runtime_type = getOptionalString(runtime.object, "type") orelse return .builtin;
    if (std.mem.eql(u8, runtime_type, "native_inproc")) return .native_inproc;
    if (std.mem.eql(u8, runtime_type, "native_proc")) return .native_proc;
    if (std.mem.eql(u8, runtime_type, "wasm")) return .wasm;
    return .builtin;
}

fn parseVenomState(raw: []const u8) namespace_driver.VenomState {
    if (std.mem.eql(u8, raw, "degraded")) return .degraded;
    if (std.mem.eql(u8, raw, "offline")) return .offline;
    return .online;
}

fn getRequiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn getRequiredStringAlias(obj: std.json.ObjectMap, primary: []const u8, alias: []const u8) ?[]const u8 {
    return getRequiredString(obj, primary) orelse getRequiredString(obj, alias);
}

fn getOptionalString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

test "venom_runtime_manager: rejects duplicate service ids" {
    const allocator = std.testing.allocator;
    var manager = RuntimeManager.init(allocator);
    defer manager.deinit();

    var descriptor = namespace_driver.VenomDescriptor{
        .venom_id = try allocator.dupe(u8, "svc-1"),
        .kind = try allocator.dupe(u8, "test"),
        .version = try allocator.dupe(u8, "1"),
        .capabilities_json = try allocator.dupe(u8, "{}"),
        .ops_json = try allocator.dupe(u8, "{}"),
        .permissions_json = try allocator.dupe(u8, "{}"),
        .schema_json = try allocator.dupe(u8, "{}"),
    };
    defer descriptor.deinit(allocator);

    try manager.register(&descriptor, null);
    try std.testing.expectError(error.DuplicateVenomId, manager.register(&descriptor, null));
}

test "venom_runtime_manager: registers descriptor from service json" {
    const allocator = std.testing.allocator;
    var manager = RuntimeManager.init(allocator);
    defer manager.deinit();

    try manager.registerFromVenomJson(
        "{\"venom_id\":\"camera-main\",\"kind\":\"camera\",\"version\":\"1\",\"state\":\"degraded\",\"endpoints\":[\"/nodes/node-1/camera\"],\"capabilities\":{\"still\":true},\"mounts\":[{\"mount_id\":\"camera-main\",\"mount_path\":\"/nodes/node-1/camera\",\"state\":\"offline\"}],\"runtime\":{\"type\":\"native_proc\",\"supervision\":{\"health_check_interval_ms\":10,\"restart_backoff_ms\":20}},\"permissions\":{\"default\":\"deny-by-default\"},\"schema\":{\"model\":\"namespace\"}}",
    );

    try std.testing.expectEqual(@as(usize, 1), manager.venoms.items.len);
    try std.testing.expect(manager.venoms.items[0].descriptor.runtime_type == .native_proc);
    try std.testing.expect(manager.venoms.items[0].descriptor.state == .degraded);
    try std.testing.expectEqual(@as(usize, 1), manager.venoms.items[0].descriptor.mounts.items.len);
    try std.testing.expect(manager.venoms.items[0].descriptor.mounts.items[0].state == .offline);
    try std.testing.expectEqual(@as(u64, 10), manager.venoms.items[0].policy.health_check_interval_ms);
    try std.testing.expectEqual(@as(u64, 20), manager.venoms.items[0].policy.restart_backoff_ms);
}

test "venom_runtime_manager: accepts venom_id alias in service json" {
    const allocator = std.testing.allocator;
    var manager = RuntimeManager.init(allocator);
    defer manager.deinit();

    try manager.registerFromVenomJson(
        "{\"venom_id\":\"web-search\",\"kind\":\"search\",\"version\":\"1\",\"state\":\"online\",\"runtime\":{\"type\":\"native_proc\"}}",
    );

    try std.testing.expectEqual(@as(usize, 1), manager.venoms.items.len);
    try std.testing.expectEqualStrings("web-search", manager.venoms.items[0].descriptor.venom_id);
}

const MockDriver = struct {
    const HealthMode = enum {
        online,
        offline,
        error_state,
    };

    const Snapshot = struct {
        start_calls: u32,
        stop_calls: u32,
        health_calls: u32,
    };

    mutex: std.Thread.Mutex = .{},
    fail_starts_remaining: u32 = 0,
    health_mode: HealthMode = .online,
    start_calls: u32 = 0,
    stop_calls: u32 = 0,
    health_calls: u32 = 0,

    const vtable = namespace_driver.DriverVTable{
        .start = startFn,
        .stop = stopFn,
        .health = healthFn,
        .invoke_json = invokeFn,
    };

    fn handle(self: *MockDriver) namespace_driver.DriverHandle {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    fn snapshot(self: *MockDriver) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .start_calls = self.start_calls,
            .stop_calls = self.stop_calls,
            .health_calls = self.health_calls,
        };
    }

    fn setHealthMode(self: *MockDriver, mode: HealthMode) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.health_mode = mode;
    }

    fn startFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!void {
        _ = allocator;
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.start_calls +%= 1;
        if (self.fail_starts_remaining > 0) {
            self.fail_starts_remaining -= 1;
            return error.MockStartFailed;
        }
    }

    fn stopFn(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stop_calls +%= 1;
    }

    fn healthFn(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!namespace_driver.Health {
        _ = allocator;
        const self: *MockDriver = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.health_calls +%= 1;
        return switch (self.health_mode) {
            .online => .{ .state = .online, .detail = "ok" },
            .offline => .{ .state = .offline, .detail = "offline" },
            .error_state => error.MockHealthFailed,
        };
    }

    fn invokeFn(ctx: *anyopaque, allocator: std.mem.Allocator, op: []const u8, args_json: []const u8) anyerror![]u8 {
        _ = ctx;
        _ = op;
        return allocator.dupe(u8, args_json);
    }
};

fn makeTestDescriptor(allocator: std.mem.Allocator, venom_id: []const u8) !namespace_driver.VenomDescriptor {
    return .{
        .venom_id = try allocator.dupe(u8, venom_id),
        .kind = try allocator.dupe(u8, "test"),
        .version = try allocator.dupe(u8, "1"),
        .capabilities_json = try allocator.dupe(u8, "{}"),
        .ops_json = try allocator.dupe(u8, "{}"),
        .permissions_json = try allocator.dupe(u8, "{}"),
        .schema_json = try allocator.dupe(u8, "{}"),
    };
}

test "venom_runtime_manager: supervisor retries start with backoff" {
    const allocator = std.testing.allocator;
    var manager = RuntimeManager.init(allocator);
    defer manager.deinit();

    var descriptor = try makeTestDescriptor(allocator, "svc-supervise");
    defer descriptor.deinit(allocator);

    var mock = MockDriver{ .fail_starts_remaining = 1 };
    try manager.registerWithPolicy(&descriptor, mock.handle(), .{
        .health_check_interval_ms = 10,
        .restart_backoff_ms = 10,
        .restart_backoff_max_ms = 40,
    });

    try manager.startAll();
    defer manager.stopAll();

    const deadline = std.time.milliTimestamp() + 2_000;
    var online = false;
    while (std.time.milliTimestamp() < deadline) {
        const stats = manager.venomRuntimeStats("svc-supervise") orelse return error.TestExpectedResponse;
        const state = manager.venomState("svc-supervise") orelse return error.TestExpectedResponse;
        if (stats.running and stats.start_attempts_total >= 2 and state == .online) {
            online = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(online);

    const snap = mock.snapshot();
    try std.testing.expect(snap.start_calls >= 2);
}

test "venom_runtime_manager: auto disables after consecutive failures" {
    const allocator = std.testing.allocator;
    var manager = RuntimeManager.init(allocator);
    defer manager.deinit();

    var descriptor = try makeTestDescriptor(allocator, "svc-auto-disable");
    defer descriptor.deinit(allocator);

    var mock = MockDriver{ .health_mode = .offline };
    try manager.registerWithPolicy(&descriptor, mock.handle(), .{
        .health_check_interval_ms = 10,
        .restart_backoff_ms = 5,
        .restart_backoff_max_ms = 5,
        .max_consecutive_failures = 1,
        .auto_disable_on_failures = true,
    });

    try manager.startAll();
    defer manager.stopAll();

    const deadline = std.time.milliTimestamp() + 2_000;
    var disabled = false;
    while (std.time.milliTimestamp() < deadline) {
        const stats = manager.venomRuntimeStats("svc-auto-disable") orelse return error.TestExpectedResponse;
        if (!stats.enabled and !stats.running) {
            disabled = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try std.testing.expect(disabled);
    try std.testing.expectEqual(namespace_driver.VenomState.offline, manager.venomState("svc-auto-disable").?);

    const snap = mock.snapshot();
    try std.testing.expect(snap.stop_calls >= 1);
}

test "venom_runtime_manager: runtime stats include transition and recovery details" {
    const allocator = std.testing.allocator;
    var manager = RuntimeManager.init(allocator);
    defer manager.deinit();

    var descriptor = try makeTestDescriptor(allocator, "svc-transition-details");
    defer descriptor.deinit(allocator);

    var mock = MockDriver{ .health_mode = .offline };
    try manager.registerWithPolicy(&descriptor, mock.handle(), .{
        .health_check_interval_ms = 10,
        .restart_backoff_ms = 5,
        .restart_backoff_max_ms = 20,
    });

    try manager.startAll();
    defer manager.stopAll();

    const degraded_deadline = std.time.milliTimestamp() + 2_000;
    var degraded_stats: ?VenomRuntimeStats = null;
    while (std.time.milliTimestamp() < degraded_deadline) {
        const stats = manager.venomRuntimeStats("svc-transition-details") orelse return error.TestExpectedResponse;
        const state = manager.venomState("svc-transition-details") orelse return error.TestExpectedResponse;
        if (state == .degraded and stats.lastError() != null and stats.last_transition_ms > 0) {
            degraded_stats = stats;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(degraded_stats != null);
    const degraded = degraded_stats.?;
    const degraded_last_error = degraded.lastError() orelse return error.TestExpectedResponse;
    try std.testing.expect(degraded_last_error.len > 0);

    mock.setHealthMode(.online);

    const recovered_deadline = std.time.milliTimestamp() + 2_000;
    var recovered_stats: ?VenomRuntimeStats = null;
    while (std.time.milliTimestamp() < recovered_deadline) {
        const stats = manager.venomRuntimeStats("svc-transition-details") orelse return error.TestExpectedResponse;
        const state = manager.venomState("svc-transition-details") orelse return error.TestExpectedResponse;
        if (state == .online and stats.lastError() == null and stats.last_healthy_ms >= degraded.last_transition_ms) {
            recovered_stats = stats;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(recovered_stats != null);
    try std.testing.expect(recovered_stats.?.last_transition_ms >= degraded.last_transition_ms);
}
