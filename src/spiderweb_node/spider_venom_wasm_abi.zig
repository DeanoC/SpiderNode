const std = @import("std");
const zwasm = @import("zwasm");
const spider_venom_wasm_constants = @import("spider_venom_wasm_constants.zig");
const spider_venom_wasm_host = @import("spider_venom_wasm_host.zig");

pub const abi_version = spider_venom_wasm_constants.abi_version;
pub const abi_version_export_name = spider_venom_wasm_constants.abi_version_export_name;
pub const alloc_export_name = spider_venom_wasm_constants.alloc_export_name;
pub const invoke_json_export_name = spider_venom_wasm_constants.invoke_json_export_name;

pub const Limits = struct {
    timeout_ms: ?u64 = null,
    fuel: ?u64 = null,
    max_memory_bytes: ?u64 = null,
};

pub const InvokeResult = struct {
    output: []u8,
    host_log_text: ?[]u8 = null,
    event_jsonl: ?[]u8 = null,

    pub fn deinit(self: *InvokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.host_log_text) |value| allocator.free(value);
        if (self.event_jsonl) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn tryInvokeJson(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    input: []const u8,
    max_output_bytes: usize,
    limits: Limits,
) !?[]u8 {
    var detailed = (try tryInvokeJsonDetailed(
        allocator,
        module_path,
        input,
        max_output_bytes,
        limits,
        .{},
    )) orelse return null;
    errdefer detailed.deinit(allocator);
    const output = detailed.output;
    detailed.output = &.{};
    detailed.deinit(allocator);
    return output;
}

pub fn tryInvokeJsonDetailed(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    input: []const u8,
    max_output_bytes: usize,
    limits: Limits,
    host_config: spider_venom_wasm_host.HostConfig,
) !?InvokeResult {
    const wasm_bytes = try readModuleBytes(allocator, module_path);
    defer allocator.free(wasm_bytes);

    var host_imports = spider_venom_wasm_host.HostImports.init(allocator, host_config);
    host_imports.bind();
    defer host_imports.deinit();

    var module = zwasm.WasmModule.loadWithImports(allocator, wasm_bytes, host_imports.imports()) catch return null;
    defer module.deinit();
    module.vm.setDeadlineTimeoutMs(limits.timeout_ms);
    module.vm.fuel = limits.fuel;
    module.vm.max_memory_bytes = limits.max_memory_bytes;

    if (module.getExportInfo(alloc_export_name) == null) return null;
    if (module.getExportInfo(invoke_json_export_name) == null) return null;

    if (module.getExportInfo(abi_version_export_name) != null) {
        var version_results = [_]u64{0};
        try module.invoke(abi_version_export_name, &.{}, &version_results);
        if (@as(u32, @intCast(version_results[0])) != abi_version) {
            return error.UnsupportedWasmAbiVersion;
        }
    }

    var alloc_args = [_]u64{input.len};
    var alloc_results = [_]u64{0};
    try module.invoke(alloc_export_name, &alloc_args, &alloc_results);
    const input_ptr: u32 = @intCast(alloc_results[0]);
    if (input.len > 0 and input_ptr == 0) return error.OutOfMemory;
    if (input.len > 0) try module.memoryWrite(input_ptr, input);

    var invoke_args = [_]u64{ input_ptr, input.len };
    var invoke_results = [_]u64{0};
    try module.invoke(invoke_json_export_name, &invoke_args, &invoke_results);

    const packed_result = invoke_results[0];
    const output_ptr: u32 = @intCast(packed_result & 0xFFFF_FFFF);
    const output_len: u32 = @intCast(packed_result >> 32);
    if (output_len == 0) {
        var outputs = try host_imports.takeOutputs();
        errdefer outputs.deinit(allocator);
        return .{
            .output = try allocator.dupe(u8, ""),
            .host_log_text = outputs.log_text,
            .event_jsonl = outputs.event_jsonl,
        };
    }
    if (output_ptr == 0) return error.InvalidPayload;
    if (output_len > max_output_bytes) return error.StdoutStreamTooLong;

    const output = try module.memoryRead(allocator, output_ptr, output_len);
    var outputs = try host_imports.takeOutputs();
    errdefer outputs.deinit(allocator);
    return .{
        .output = @constCast(output),
        .host_log_text = outputs.log_text,
        .event_jsonl = outputs.event_jsonl,
    };
}

fn readModuleBytes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();
        return try file.readToEndAlloc(allocator, @intCast(stat.size));
    }

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    return try file.readToEndAlloc(allocator, @intCast(stat.size));
}

test "spider_venom_wasm_abi: invokes freestanding abi module" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source_path = try std.fs.path.join(allocator, &.{ root, "abi_driver.zig" });
    defer allocator.free(source_path);
    const module_path = try std.fs.path.join(allocator, &.{ root, "abi_driver.wasm" });
    defer allocator.free(module_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{module_path});
    defer allocator.free(emit_arg);

    const source =
        "const std = @import(\"std\");\n" ++
        "extern \"spider_host_v1\" fn spider_host_capabilities() u64;\n" ++
        "extern \"spider_host_v1\" fn spider_host_now_ms() u64;\n" ++
        "extern \"spider_host_v1\" fn spider_host_log(level: u32, ptr: u32, len: u32) u32;\n" ++
        "extern \"spider_host_v1\" fn spider_host_emit_event_json(ptr: u32, len: u32) u32;\n" ++
        "var input_buf: [4096]u8 = undefined;\n" ++
        "var output_buf: [8192]u8 = undefined;\n" ++
        "const log_line = \"abi invoked\";\n" ++
        "const event_json = \"{\\\"type\\\":\\\"abi.invoked\\\"}\";\n" ++
        "pub export fn spider_venom_abi_version() u32 { return 1; }\n" ++
        "pub export fn spider_venom_alloc(len: u32) u32 {\n" ++
        "  if (len > input_buf.len) return 0;\n" ++
        "  return @intCast(@intFromPtr(&input_buf));\n" ++
        "}\n" ++
        "pub export fn spider_venom_invoke_json(ptr: u32, len: u32) u64 {\n" ++
        "  const input = input_buf[0..len];\n" ++
        "  _ = spider_host_log(20, @intCast(@intFromPtr(log_line.ptr)), log_line.len);\n" ++
        "  _ = spider_host_emit_event_json(@intCast(@intFromPtr(event_json.ptr)), event_json.len);\n" ++
        "  const caps = spider_host_capabilities();\n" ++
        "  const now_ms = spider_host_now_ms();\n" ++
        "  var stream = std.io.fixedBufferStream(&output_buf);\n" ++
        "  const writer = stream.writer();\n" ++
        "  writer.print(\"{{\\\"state\\\":\\\"done\\\",\\\"reply\\\":\\\"abi:{s}\\\",\\\"caps\\\":{d},\\\"now_ms\\\":{d}}}\", .{ input, caps, now_ms }) catch return 0;\n" ++
        "  const out_ptr: u32 = @intCast(@intFromPtr(&output_buf));\n" ++
        "  const out_len: u32 = @intCast(stream.pos);\n" ++
        "  _ = ptr;\n" ++
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

    const detailed = (try tryInvokeJsonDetailed(allocator, module_path, "hello", 4096, .{}, .{
        .capabilities = .{ .emit_event = true },
    })).?;
    defer {
        var owned = detailed;
        owned.deinit(allocator);
    }
    try std.testing.expect(std.mem.indexOf(u8, detailed.output, "\"reply\":\"abi:hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, detailed.output, "\"caps\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, detailed.output, "\"now_ms\":") != null);
    try std.testing.expect(detailed.host_log_text != null);
    try std.testing.expect(detailed.event_jsonl != null);
    try std.testing.expect(std.mem.indexOf(u8, detailed.host_log_text.?, "info: abi invoked") != null);
    try std.testing.expect(std.mem.indexOf(u8, detailed.event_jsonl.?, "\"type\":\"abi.invoked\"") != null);
}

test "spider_venom_wasm_abi: fuel limit traps looping module" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source_path = try std.fs.path.join(allocator, &.{ root, "abi_loop_driver.zig" });
    defer allocator.free(source_path);
    const module_path = try std.fs.path.join(allocator, &.{ root, "abi_loop_driver.wasm" });
    defer allocator.free(module_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{module_path});
    defer allocator.free(emit_arg);

    const source =
        "pub export fn spider_venom_abi_version() u32 { return 1; }\n" ++
        "pub export fn spider_venom_alloc(len: u32) u32 { _ = len; return 1024; }\n" ++
        "pub export fn spider_venom_invoke_json(ptr: u32, len: u32) u64 {\n" ++
        "  _ = ptr; _ = len;\n" ++
        "  while (true) {}\n" ++
        "  return 0;\n" ++
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

    try std.testing.expectError(
        error.FuelExhausted,
        tryInvokeJson(allocator, module_path, "loop", 4096, .{ .fuel = 1_000 }),
    );
}

test "spider_venom_wasm_abi: timeout limit traps looping module" {
    if (@import("builtin").os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source_path = try std.fs.path.join(allocator, &.{ root, "abi_timeout_driver.zig" });
    defer allocator.free(source_path);
    const module_path = try std.fs.path.join(allocator, &.{ root, "abi_timeout_driver.wasm" });
    defer allocator.free(module_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{module_path});
    defer allocator.free(emit_arg);

    const source =
        "pub export fn spider_venom_abi_version() u32 { return 1; }\n" ++
        "pub export fn spider_venom_alloc(len: u32) u32 { _ = len; return 1024; }\n" ++
        "pub export fn spider_venom_invoke_json(ptr: u32, len: u32) u64 {\n" ++
        "  _ = ptr; _ = len;\n" ++
        "  while (true) {}\n" ++
        "  return 0;\n" ++
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

    try std.testing.expectError(
        error.TimeoutExceeded,
        tryInvokeJson(allocator, module_path, "loop", 4096, .{ .timeout_ms = 10 }),
    );
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
