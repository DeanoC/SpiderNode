const std = @import("std");
const fs_node_ops = @import("fs_node_ops.zig");
const fs_node_service = @import("fs_node_service.zig");
const spider_venom_wasm_abi = @import("spider_venom_wasm_abi.zig");
const zwasm_runtime = @import("zwasm_runtime.zig");

const default_entrypoint: ?[]const u8 = null;
const default_max_output_bytes: usize = 256 * 1024;

pub const Config = struct {
    module_path: []const u8,
    entrypoint: ?[]const u8 = default_entrypoint,
    args: []const []const u8 = &.{},
    timeout_ms: u64 = 30_000,
    fuel: ?u64 = null,
    max_memory_bytes: ?u64 = null,
    max_output_bytes: usize = default_max_output_bytes,
};

pub const OwnedConfig = struct {
    module_path: []u8,
    entrypoint: ?[]u8 = null,
    args: std.ArrayListUnmanaged([]u8) = .{},
    timeout_ms: u64 = 30_000,
    fuel: ?u64 = null,
    max_memory_bytes: ?u64 = null,
    max_output_bytes: usize = default_max_output_bytes,

    pub fn clone(self: *const OwnedConfig, allocator: std.mem.Allocator) !OwnedConfig {
        var out = OwnedConfig{
            .module_path = try allocator.dupe(u8, self.module_path),
            .entrypoint = if (self.entrypoint) |value| try allocator.dupe(u8, value) else null,
            .timeout_ms = self.timeout_ms,
            .fuel = self.fuel,
            .max_memory_bytes = self.max_memory_bytes,
            .max_output_bytes = self.max_output_bytes,
        };
        errdefer out.deinit(allocator);
        for (self.args.items) |arg| {
            try out.args.append(allocator, try allocator.dupe(u8, arg));
        }
        return out;
    }

    pub fn deinit(self: *OwnedConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.module_path);
        if (self.entrypoint) |value| allocator.free(value);
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
        self.* = undefined;
    }

    pub fn asConfig(self: *const OwnedConfig) Config {
        return .{
            .module_path = self.module_path,
            .entrypoint = self.entrypoint,
            .args = self.args.items,
            .timeout_ms = self.timeout_ms,
            .fuel = self.fuel,
            .max_memory_bytes = self.max_memory_bytes,
            .max_output_bytes = self.max_output_bytes,
        };
    }
};

pub fn buildSubmission(
    allocator: std.mem.Allocator,
    config: Config,
    job_id: []u8,
    input: []const u8,
    correlation_id: ?[]const u8,
) !fs_node_service.NodeService.ChatInputSubmission {
    var result = try invoke(allocator, config, input);
    defer result.deinit(allocator);

    return .{
        .job_id = job_id,
        .correlation_id = if (correlation_id) |value| try allocator.dupe(u8, value) else null,
        .state = result.state,
        .error_text = if (result.error_text) |value| try allocator.dupe(u8, value) else null,
        .result_text = if (result.result_text) |value| try allocator.dupe(u8, value) else null,
        .log_text = if (result.log_text) |value| try allocator.dupe(u8, value) else null,
    };
}

pub const InvokeResult = struct {
    state: fs_node_ops.ChatJobState = .done,
    result_text: ?[]u8 = null,
    error_text: ?[]u8 = null,
    log_text: ?[]u8 = null,

    pub fn deinit(self: *InvokeResult, allocator: std.mem.Allocator) void {
        if (self.result_text) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        if (self.log_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn invoke(
    allocator: std.mem.Allocator,
    config: Config,
    input: []const u8,
) !InvokeResult {
    const abi_output = spider_venom_wasm_abi.tryInvokeJsonDetailed(
        allocator,
        config.module_path,
        input,
        config.max_output_bytes,
        .{
            .timeout_ms = config.timeout_ms,
            .fuel = config.fuel,
            .max_memory_bytes = config.max_memory_bytes,
        },
        .{},
    ) catch |err| switch (err) {
        error.TimeoutExceeded => return .{
            .state = .failed,
            .error_text = try allocator.dupe(u8, "wasm chat backend timed out"),
            .log_text = try allocator.dupe(u8, "timeout_ms reached before WASM execution completed"),
        },
        else => return err,
    };

    if (abi_output) |resolved_abi_output| {
        defer {
            var owned = resolved_abi_output;
            owned.deinit(allocator);
        }
        const aux_log = try mergeAuxLogText(
            allocator,
            resolved_abi_output.host_log_text,
            resolved_abi_output.event_jsonl,
        );
        defer if (aux_log) |value| allocator.free(value);
        return try parseAbiOrStdoutResult(allocator, resolved_abi_output.output, aux_log);
    }

    var raw = zwasm_runtime.invokeModule(
        allocator,
        .{
            .module_path = config.module_path,
            .entrypoint = config.entrypoint,
            .args = config.args,
            .timeout_ms = config.timeout_ms,
            .fuel = config.fuel,
            .max_memory_bytes = config.max_memory_bytes,
        },
        input,
        config.max_output_bytes,
    ) catch |err| switch (err) {
        error.TimeoutExceeded => return .{
            .state = .failed,
            .error_text = try allocator.dupe(u8, "wasm chat backend timed out"),
            .log_text = try allocator.dupe(u8, "timeout_ms reached before WASM execution completed"),
        },
        else => return err,
    };
    defer raw.deinit(allocator);

    const stderr_trimmed = std.mem.trim(u8, raw.stderr, " \t\r\n");

    if (raw.exit_code != 0) {
        return .{
            .state = .failed,
            .error_text = try allocator.dupe(
                u8,
                if (stderr_trimmed.len > 0) stderr_trimmed else "wasm chat backend exited with failure",
            ),
            .log_text = if (stderr_trimmed.len > 0) try allocator.dupe(u8, stderr_trimmed) else null,
        };
    }

    return try parseAbiOrStdoutResult(allocator, raw.stdout, stderr_trimmed);
}

fn parseAbiOrStdoutResult(
    allocator: std.mem.Allocator,
    stdout_bytes: []const u8,
    stderr_trimmed: ?[]const u8,
) !InvokeResult {
    var parsed = parseOutputJson(allocator, stdout_bytes) catch |err| switch (err) {
        error.InvalidJson => InvokeResult{
            .state = .done,
            .result_text = try allocator.dupe(u8, std.mem.trim(u8, stdout_bytes, " \t\r\n")),
            .log_text = if (stderr_trimmed) |value|
                if (value.len > 0) try allocator.dupe(u8, value) else null
            else
                null,
        },
        else => return err,
    };
    errdefer parsed.deinit(allocator);

    if (stderr_trimmed) |value| {
        if (value.len > 0) {
            parsed.log_text = try mergeOptionalLogText(allocator, parsed.log_text, value);
        }
    }
    if (parsed.state == .failed and parsed.error_text == null) {
        parsed.error_text = try allocator.dupe(u8, "wasm chat backend returned failed state");
    }
    return parsed;
}

fn mergeAuxLogText(
    allocator: std.mem.Allocator,
    host_log_text: ?[]const u8,
    event_jsonl: ?[]const u8,
) !?[]u8 {
    const trimmed_log = if (host_log_text) |value|
        std.mem.trim(u8, value, " \t\r\n")
    else
        "";
    const trimmed_events = if (event_jsonl) |value|
        std.mem.trim(u8, value, " \t\r\n")
    else
        "";

    if (trimmed_log.len == 0 and trimmed_events.len == 0) return null;
    if (trimmed_log.len == 0) return try allocator.dupe(u8, trimmed_events);
    if (trimmed_events.len == 0) return try allocator.dupe(u8, trimmed_log);
    return try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ trimmed_log, trimmed_events });
}

fn mergeOptionalLogText(
    allocator: std.mem.Allocator,
    existing: ?[]u8,
    appended: []const u8,
) !?[]u8 {
    const trimmed_appended = std.mem.trim(u8, appended, " \t\r\n");
    if (trimmed_appended.len == 0) return existing;
    if (existing) |value| {
        const trimmed_existing = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed_existing.len == 0) {
            allocator.free(value);
            return try allocator.dupe(u8, trimmed_appended);
        }
        const merged = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ trimmed_existing, trimmed_appended });
        allocator.free(value);
        return merged;
    }
    return try allocator.dupe(u8, trimmed_appended);
}

fn parseOutputJson(allocator: std.mem.Allocator, stdout_bytes: []const u8) !InvokeResult {
    const trimmed = std.mem.trim(u8, stdout_bytes, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidJson;
    if (trimmed[0] != '{') return error.InvalidJson;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    const obj = parsed.value.object;
    return .{
        .state = parseState(jsonObjectStringOr(obj, "state", "done")),
        .result_text = if (jsonObjectStringOr(obj, "reply", "").len > 0)
            try allocator.dupe(u8, jsonObjectStringOr(obj, "reply", ""))
        else
            null,
        .error_text = if (jsonObjectStringOr(obj, "error", "").len > 0)
            try allocator.dupe(u8, jsonObjectStringOr(obj, "error", ""))
        else
            null,
        .log_text = if (jsonObjectStringOr(obj, "log", "").len > 0)
            try allocator.dupe(u8, jsonObjectStringOr(obj, "log", ""))
        else
            null,
    };
}

fn parseState(value: []const u8) fs_node_ops.ChatJobState {
    if (std.mem.eql(u8, value, "queued")) return .queued;
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    return .done;
}

fn jsonObjectStringOr(obj: std.json.ObjectMap, key: []const u8, fallback: []const u8) []const u8 {
    const value = obj.get(key) orelse return fallback;
    if (value != .string) return fallback;
    return value.string;
}

fn writeAbsoluteTestFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{
        .truncate = true,
        .read = false,
    });
    defer file.close();
    try file.writeAll(data);
}

fn runFixtureCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 256 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    return error.CommandFailed;
}

const TestFixture = struct {
    tmp: std.testing.TmpDir,
    module_path: []u8,

    fn deinit(self: *TestFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.module_path);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn buildTestFixture(allocator: std.mem.Allocator) !TestFixture {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source_path = try std.fs.path.join(allocator, &.{ root, "wasm_chat_runner.zig" });
    defer allocator.free(source_path);
    const module_path = try std.fs.path.join(allocator, &.{ root, "fixture.wasm" });
    errdefer allocator.free(module_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{module_path});
    defer allocator.free(emit_arg);

    const source =
        "const std = @import(\"std\");\n" ++
        "extern \"spider_host_v1\" fn spider_host_emit_event_json(ptr: u32, len: u32) u32;\n" ++
        "var input_buf: [4096]u8 = undefined;\n" ++
        "var output_buf: [8192]u8 = undefined;\n" ++
        "const thought_event = \"{\\\"type\\\":\\\"agent.thought\\\",\\\"content\\\":\\\"fixture thought\\\",\\\"source\\\":\\\"wasm\\\",\\\"round\\\":1}\";\n" ++
        "const debug_event = \"{\\\"type\\\":\\\"debug.event\\\",\\\"timestamp\\\":123,\\\"category\\\":\\\"wasm.fixture\\\",\\\"payload\\\":{\\\"message\\\":\\\"fixture debug\\\"}}\";\n" ++
        "pub export fn spider_venom_abi_version() u32 { return 1; }\n" ++
        "pub export fn spider_venom_alloc(len: u32) u32 {\n" ++
        "  if (len > input_buf.len) return 0;\n" ++
        "  return @intCast(@intFromPtr(&input_buf));\n" ++
        "}\n" ++
        "fn appendEscapedJson(writer: anytype, input: []const u8) !void {\n" ++
        "  for (input) |char| switch (char) {\n" ++
        "    '\\\\' => try writer.writeAll(\"\\\\\\\\\"),\n" ++
        "    '\"' => try writer.writeAll(\"\\\\\\\"\"),\n" ++
        "    '\\n' => try writer.writeAll(\"\\\\n\"),\n" ++
        "    '\\r' => try writer.writeAll(\"\\\\r\"),\n" ++
        "    '\\t' => try writer.writeAll(\"\\\\t\"),\n" ++
        "    else => try writer.writeByte(char),\n" ++
        "  };\n" ++
        "}\n" ++
        "pub export fn spider_venom_invoke_json(ptr: u32, len: u32) u64 {\n" ++
        "  _ = ptr;\n" ++
        "  const trimmed = std.mem.trim(u8, input_buf[0..len], \" \\t\\r\\n\");\n" ++
        "  _ = spider_host_emit_event_json(@intCast(@intFromPtr(thought_event.ptr)), thought_event.len);\n" ++
        "  _ = spider_host_emit_event_json(@intCast(@intFromPtr(debug_event.ptr)), debug_event.len);\n" ++
        "  var stream = std.io.fixedBufferStream(&output_buf);\n" ++
        "  const writer = stream.writer();\n" ++
        "  if (std.mem.indexOf(u8, trimmed, \"fail\") != null) {\n" ++
        "    writer.writeAll(\"{\\\"state\\\":\\\"failed\\\",\\\"error\\\":\\\"driver requested failure\\\",\\\"log\\\":\\\"fixture\\\"}\") catch return 0;\n" ++
        "  } else {\n" ++
        "    writer.writeAll(\"{\\\"state\\\":\\\"done\\\",\\\"reply\\\":\\\"wasm:\") catch return 0;\n" ++
        "    appendEscapedJson(writer, trimmed) catch return 0;\n" ++
        "    writer.writeAll(\"\\\",\\\"log\\\":\\\"fixture\\\"}\") catch return 0;\n" ++
        "  }\n" ++
        "  const out_ptr: u32 = @intCast(@intFromPtr(&output_buf));\n" ++
        "  const out_len: u32 = @intCast(stream.pos);\n" ++
        "  return (@as(u64, out_len) << 32) | out_ptr;\n" ++
        "}\n";

    try writeAbsoluteTestFile(source_path, source);
    try runFixtureCommand(allocator, &.{
        "zig",
        "build-exe",
        "-target",
        "wasm32-freestanding",
        "-fno-entry",
        "-rdynamic",
        "-fexport-memory",
        "-O",
        "Debug",
        source_path,
        emit_arg,
    });

    return .{
        .tmp = tmp,
        .module_path = module_path,
    };
}

test "wasm_chat_backend: successful execution builds chat submission" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var fixture = try buildTestFixture(allocator);
    defer fixture.deinit(allocator);

    var submission = try buildSubmission(
        allocator,
        .{
            .module_path = fixture.module_path,
        },
        "job-1",
        "hello",
        "corr-1",
    );
    defer submission.deinit(allocator);

    try std.testing.expect(submission.state == .done);
    try std.testing.expectEqualStrings("job-1", submission.job_id);
    try std.testing.expectEqualStrings("corr-1", submission.correlation_id.?);
    try std.testing.expectEqualStrings("wasm:hello", submission.result_text.?);
    try std.testing.expect(std.mem.indexOf(u8, submission.log_text.?, "fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, submission.log_text.?, "\"type\":\"agent.thought\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, submission.log_text.?, "\"type\":\"debug.event\"") != null);
}

test "wasm_chat_backend: non-zero exit becomes failed submission" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var fixture = try buildTestFixture(allocator);
    defer fixture.deinit(allocator);

    var submission = try buildSubmission(
        allocator,
        .{
            .module_path = fixture.module_path,
        },
        "job-2",
        "please fail",
        null,
    );
    defer submission.deinit(allocator);

    try std.testing.expect(submission.state == .failed);
    try std.testing.expect(submission.result_text == null);
    try std.testing.expectEqualStrings("driver requested failure", submission.error_text.?);
    try std.testing.expect(std.mem.indexOf(u8, submission.log_text.?, "fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, submission.log_text.?, "\"type\":\"debug.event\"") != null);
}
