const std = @import("std");
const zwasm = @import("zwasm");
const spider_venom_wasm_constants = @import("spider_venom_wasm_constants.zig");

pub const import_module_name = spider_venom_wasm_constants.import_module_name;
pub const capabilities_export_name = spider_venom_wasm_constants.capabilities_export_name;
pub const now_ms_export_name = spider_venom_wasm_constants.now_ms_export_name;
pub const log_export_name = spider_venom_wasm_constants.log_export_name;
pub const random_fill_export_name = spider_venom_wasm_constants.random_fill_export_name;
pub const emit_event_json_export_name = spider_venom_wasm_constants.emit_event_json_export_name;

pub const LogLevel = enum(u32) {
    debug = 10,
    info = 20,
    warn = 30,
    err = 40,

    pub fn fromInt(value: u32) LogLevel {
        return switch (value) {
            10 => .debug,
            20 => .info,
            30 => .warn,
            40 => .err,
            else => .info,
        };
    }

    pub fn asText(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }
};

pub const CapabilitySet = struct {
    log: bool = true,
    clock: bool = true,
    random: bool = true,
    emit_event: bool = false,

    pub fn toMask(self: CapabilitySet) u64 {
        var mask: u64 = 0;
        if (self.log) mask |= 1 << spider_venom_wasm_constants.capability_bit_log;
        if (self.clock) mask |= 1 << spider_venom_wasm_constants.capability_bit_clock;
        if (self.random) mask |= 1 << spider_venom_wasm_constants.capability_bit_random;
        if (self.emit_event) mask |= 1 << spider_venom_wasm_constants.capability_bit_emit_event;
        return mask;
    }
};

pub const LogFn = *const fn (?*anyopaque, LogLevel, []const u8) anyerror!void;
pub const EventFn = *const fn (?*anyopaque, []const u8) anyerror!void;

pub const HostConfig = struct {
    capabilities: CapabilitySet = .{},
    log_fn: ?LogFn = null,
    log_ctx: ?*anyopaque = null,
    event_fn: ?EventFn = null,
    event_ctx: ?*anyopaque = null,
};

pub const HostOutputs = struct {
    log_text: ?[]u8 = null,
    event_jsonl: ?[]u8 = null,

    pub fn deinit(self: *HostOutputs, allocator: std.mem.Allocator) void {
        if (self.log_text) |value| allocator.free(value);
        if (self.event_jsonl) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const HostImports = struct {
    allocator: std.mem.Allocator,
    config: HostConfig,
    log_lines: std.ArrayList(u8) = .empty,
    event_lines: std.ArrayList(u8) = .empty,
    host_functions: [5]zwasm.HostFnEntry = undefined,
    import_entries: [1]zwasm.ImportEntry = undefined,

    pub fn init(allocator: std.mem.Allocator, config: HostConfig) HostImports {
        return .{
            .allocator = allocator,
            .config = config,
            .host_functions = .{
                .{ .name = capabilities_export_name, .callback = hostCapabilities, .context = 0 },
                .{ .name = now_ms_export_name, .callback = hostNowMs, .context = 0 },
                .{ .name = log_export_name, .callback = hostLog, .context = 0 },
                .{ .name = random_fill_export_name, .callback = hostRandomFill, .context = 0 },
                .{ .name = emit_event_json_export_name, .callback = hostEmitEventJson, .context = 0 },
            },
            .import_entries = .{.{
                .module = import_module_name,
                .source = undefined,
            }},
        };
    }

    pub fn bind(self: *HostImports) void {
        const ctx_value = @intFromPtr(self);
        for (&self.host_functions) |*entry| entry.context = ctx_value;
        self.import_entries[0].source = .{ .host_fns = self.host_functions[0..] };
    }

    pub fn deinit(self: *HostImports) void {
        self.log_lines.deinit(self.allocator);
        self.event_lines.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn imports(self: *const HostImports) []const zwasm.ImportEntry {
        return self.import_entries[0..];
    }

    pub fn takeOutputs(self: *HostImports) !HostOutputs {
        return .{
            .log_text = if (self.log_lines.items.len > 0) try self.log_lines.toOwnedSlice(self.allocator) else null,
            .event_jsonl = if (self.event_lines.items.len > 0) try self.event_lines.toOwnedSlice(self.allocator) else null,
        };
    }

    fn effectiveCapabilities(self: *const HostImports) CapabilitySet {
        var out = self.config.capabilities;
        if (self.config.event_fn != null) out.emit_event = true;
        return out;
    }
};

fn hostCapabilities(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    const host = hostFromContext(context_id);
    const vm = vmFromContext(ctx_ptr);
    try vm.pushOperand(host.effectiveCapabilities().toMask());
}

fn hostNowMs(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    const host = hostFromContext(context_id);
    const vm = vmFromContext(ctx_ptr);
    if (!host.effectiveCapabilities().clock) {
        try vm.pushOperand(0);
        return;
    }
    try vm.pushOperand(@intCast(std.time.milliTimestamp()));
}

fn hostLog(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    const host = hostFromContext(context_id);
    const vm = vmFromContext(ctx_ptr);
    const msg_len = vm.popOperandU32();
    const msg_ptr = vm.popOperandU32();
    const raw_level = vm.popOperandU32();
    if (!host.effectiveCapabilities().log) {
        try vm.pushOperand(1);
        return;
    }

    const message = try readGuestBytes(vm, msg_ptr, msg_len);
    const level = LogLevel.fromInt(raw_level);
    try appendCollectedLine(host.allocator, &host.log_lines, level.asText(), message);
    if (host.config.log_fn) |callback| {
        try callback(host.config.log_ctx, level, message);
    }
    try vm.pushOperand(0);
}

fn hostRandomFill(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    const host = hostFromContext(context_id);
    const vm = vmFromContext(ctx_ptr);
    const len = vm.popOperandU32();
    const ptr = vm.popOperandU32();
    if (!host.effectiveCapabilities().random) {
        try vm.pushOperand(1);
        return;
    }

    const dest = try writableGuestBytes(vm, ptr, len);
    std.crypto.random.bytes(dest);
    try vm.pushOperand(0);
}

fn hostEmitEventJson(ctx_ptr: *anyopaque, context_id: usize) anyerror!void {
    const host = hostFromContext(context_id);
    const vm = vmFromContext(ctx_ptr);
    const len = vm.popOperandU32();
    const ptr = vm.popOperandU32();
    if (!host.effectiveCapabilities().emit_event) {
        try vm.pushOperand(1);
        return;
    }

    const event_json = try readGuestBytes(vm, ptr, len);
    try appendJsonLine(host.allocator, &host.event_lines, event_json);
    if (host.config.event_fn) |callback| {
        try callback(host.config.event_ctx, event_json);
    }
    try vm.pushOperand(0);
}

fn hostFromContext(context_id: usize) *HostImports {
    return @ptrFromInt(context_id);
}

fn vmFromContext(ctx_ptr: *anyopaque) *zwasm.Vm {
    return @ptrCast(@alignCast(ctx_ptr));
}

fn readGuestBytes(vm: *zwasm.Vm, ptr: u32, len: u32) ![]const u8 {
    const memory = try vm.getMemory(0);
    const bytes = memory.memory();
    const end = @as(u64, ptr) + @as(u64, len);
    if (end > bytes.len) return error.OutOfBoundsMemoryAccess;
    return bytes[ptr..][0..len];
}

fn writableGuestBytes(vm: *zwasm.Vm, ptr: u32, len: u32) ![]u8 {
    const memory = try vm.getMemory(0);
    const bytes = memory.memory();
    const end = @as(u64, ptr) + @as(u64, len);
    if (end > bytes.len) return error.OutOfBoundsMemoryAccess;
    return bytes[ptr..][0..len];
}

fn appendCollectedLine(
    allocator: std.mem.Allocator,
    buffer: *std.ArrayList(u8),
    prefix: []const u8,
    body: []const u8,
) !void {
    if (buffer.items.len > 0) try buffer.append(allocator, '\n');
    try buffer.appendSlice(allocator, prefix);
    try buffer.appendSlice(allocator, ": ");
    try buffer.appendSlice(allocator, body);
}

fn appendJsonLine(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), body: []const u8) !void {
    if (buffer.items.len > 0) try buffer.append(allocator, '\n');
    try buffer.appendSlice(allocator, body);
}

test "spider_venom_wasm_host: host imports collect log and event output" {
    const allocator = std.testing.allocator;
    var imports = HostImports.init(allocator, .{
        .capabilities = .{ .emit_event = true },
    });
    defer imports.deinit();

    try appendCollectedLine(allocator, &imports.log_lines, "info", "hello");
    try appendJsonLine(allocator, &imports.event_lines, "{\"type\":\"demo\"}");
    var outputs = try imports.takeOutputs();
    defer outputs.deinit(allocator);

    try std.testing.expect(outputs.log_text != null);
    try std.testing.expect(outputs.event_jsonl != null);
    try std.testing.expectEqualStrings("info: hello", outputs.log_text.?);
    try std.testing.expectEqualStrings("{\"type\":\"demo\"}", outputs.event_jsonl.?);
}
