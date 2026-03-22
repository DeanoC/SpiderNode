const std = @import("std");
const builtin = @import("builtin");
const zwasm = @import("zwasm");
const windows = std.os.windows;
const c = if (builtin.os.tag == .windows) @cImport({
    @cInclude("fcntl.h");
    @cInclude("io.h");
}) else struct {};

const fd_t = if (builtin.os.tag == .windows) c_int else std.posix.fd_t;

extern "kernel32" fn SetStdHandle(
    nStdHandle: windows.DWORD,
    hHandle: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

var stdio_capture_mutex: std.Thread.Mutex = .{};

pub const Config = struct {
    module_path: []const u8,
    entrypoint: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    timeout_ms: ?u64 = null,
    fuel: ?u64 = null,
    max_memory_bytes: ?u64 = null,
};

pub const InvokeResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,

    pub fn deinit(self: *InvokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub fn validateConfig(config: Config) !void {
    if (!isSafeToken(config.module_path)) return error.InvalidZwasmConfig;
    if (config.entrypoint) |entrypoint| {
        if (!isSafeEntrypoint(entrypoint)) return error.InvalidZwasmConfig;
    }
    for (config.args) |arg| {
        if (!isSafeToken(arg)) return error.InvalidZwasmConfig;
    }
}

pub fn invokeModule(
    allocator: std.mem.Allocator,
    config: Config,
    stdin_bytes: []const u8,
    max_output_bytes: usize,
) anyerror!InvokeResult {
    try validateConfig(config);
    if (builtin.os.tag == .wasi) return error.UnsupportedPlatform;

    const wasm_bytes = try readModuleBytes(allocator, config.module_path);
    defer allocator.free(wasm_bytes);

    var wasi_args = std.ArrayList([:0]u8).empty;
    defer {
        for (wasi_args.items) |arg| allocator.free(arg);
        wasi_args.deinit(allocator);
    }

    const program_name = std.fs.path.basename(config.module_path);
    try wasi_args.append(allocator, try allocator.dupeZ(u8, program_name));
    for (config.args) |arg| {
        try wasi_args.append(allocator, try allocator.dupeZ(u8, arg));
    }

    stdio_capture_mutex.lock();
    defer stdio_capture_mutex.unlock();

    var capture = try StdioCapture.init(allocator, stdin_bytes, max_output_bytes);
    defer capture.deinit();
    try capture.begin();
    defer capture.end();

    var module = try zwasm.WasmModule.loadWasiWithOptions(allocator, wasm_bytes, .{
        .args = wasi_args.items,
        .caps = zwasm.Capabilities.cli_default,
    });
    defer module.deinit();
    module.vm.setDeadlineTimeoutMs(config.timeout_ms);
    module.vm.fuel = config.fuel;
    module.vm.max_memory_bytes = config.max_memory_bytes;

    const invoke_name = if (config.entrypoint) |value| value else "_start";
    var invoke_error: ?anyerror = null;
    module.invoke(invoke_name, &.{}, &.{}) catch |err| {
        if (err == error.TimeoutExceeded) return err;
        invoke_error = err;
    };

    const exit_code = module.getWasiExitCode() orelse 0;
    if (invoke_error) |err| {
        if (err != error.Trap or module.getWasiExitCode() == null) {
            var fallback = std.ArrayList(u8).empty;
            defer fallback.deinit(allocator);
            try fallback.writer(allocator).print("zwasm invoke failed: {s}", .{@errorName(err)});
            try capture.appendStderrFallback(fallback.items);
            return .{
                .stdout = try capture.takeStdout(),
                .stderr = try capture.takeStderr(),
                .exit_code = -1,
            };
        }
    }

    return .{
        .stdout = try capture.takeStdout(),
        .stderr = try capture.takeStderr(),
        .exit_code = @intCast(exit_code),
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

fn isSafeToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (ch == 0 or ch == '\n' or ch == '\r') return false;
    }
    return true;
}

fn isSafeEntrypoint(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        if (ch == '_' or ch == '-' or ch == '.' or ch == ':') continue;
        return false;
    }
    return true;
}

const PipeReader = struct {
    allocator: std.mem.Allocator,
    fd: fd_t,
    max_output_bytes: usize,
    output: std.ArrayList(u8) = .empty,
    read_err: ?anyerror = null,
    too_long: bool = false,

    fn run(self: *PipeReader) void {
        defer fdClose(self.fd);

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = fdRead(self.fd, &buffer) catch |err| {
                self.read_err = err;
                return;
            };
            if (bytes_read == 0) return;

            if (self.output.items.len < self.max_output_bytes) {
                const remaining = self.max_output_bytes - self.output.items.len;
                const take = @min(remaining, bytes_read);
                self.output.appendSlice(self.allocator, buffer[0..take]) catch |err| {
                    self.read_err = err;
                    return;
                };
                if (take < bytes_read) self.too_long = true;
            } else {
                self.too_long = true;
            }
        }
    }

    fn deinit(self: *PipeReader) void {
        self.output.deinit(self.allocator);
        self.* = undefined;
    }
};

const PipeWriter = struct {
    fd: fd_t,
    input: []const u8,
    write_err: ?anyerror = null,

    fn run(self: *PipeWriter) void {
        defer fdClose(self.fd);
        var offset: usize = 0;
        while (offset < self.input.len) {
            const wrote = fdWrite(self.fd, self.input[offset..]) catch |err| {
                self.write_err = err;
                return;
            };
            if (wrote == 0) {
                self.write_err = error.BrokenPipe;
                return;
            }
            offset += wrote;
        }
    }
};

const StdioCapture = struct {
    allocator: std.mem.Allocator,
    max_output_bytes: usize,
    stdin_reader: fd_t,
    stdout_writer: fd_t,
    stderr_writer: fd_t,
    saved_stdin: fd_t,
    saved_stdout: fd_t,
    saved_stderr: fd_t,
    stdin_writer: PipeWriter,
    stdout_reader: PipeReader,
    stderr_reader: PipeReader,
    stdin_thread: ?std.Thread = null,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    active: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        stdin_bytes: []const u8,
        max_output_bytes: usize,
    ) !StdioCapture {
        const stdin_pipe = try fdPipe();
        errdefer {
            fdClose(stdin_pipe[0]);
            fdClose(stdin_pipe[1]);
        }
        const stdout_pipe = try fdPipe();
        errdefer {
            fdClose(stdout_pipe[0]);
            fdClose(stdout_pipe[1]);
        }
        const stderr_pipe = try fdPipe();
        errdefer {
            fdClose(stderr_pipe[0]);
            fdClose(stderr_pipe[1]);
        }

        return .{
            .allocator = allocator,
            .max_output_bytes = max_output_bytes,
            .stdin_reader = stdin_pipe[0],
            .stdout_writer = stdout_pipe[1],
            .stderr_writer = stderr_pipe[1],
            .saved_stdin = try fdDup(0),
            .saved_stdout = try fdDup(1),
            .saved_stderr = try fdDup(2),
            .stdin_writer = .{
                .fd = stdin_pipe[1],
                .input = stdin_bytes,
            },
            .stdout_reader = .{
                .allocator = allocator,
                .fd = stdout_pipe[0],
                .max_output_bytes = max_output_bytes,
            },
            .stderr_reader = .{
                .allocator = allocator,
                .fd = stderr_pipe[0],
                .max_output_bytes = max_output_bytes,
            },
        };
    }

    fn deinit(self: *StdioCapture) void {
        if (self.active) self.end();
        self.stdout_reader.deinit();
        self.stderr_reader.deinit();
        self.* = undefined;
    }

    fn begin(self: *StdioCapture) !void {
        self.stdin_thread = try std.Thread.spawn(.{}, pipeWriterMain, .{&self.stdin_writer});
        errdefer {
            self.stdin_thread.?.join();
            self.stdin_thread = null;
        }
        self.stdout_thread = try std.Thread.spawn(.{}, pipeReaderMain, .{&self.stdout_reader});
        errdefer {
            self.stdout_thread.?.join();
            self.stdout_thread = null;
        }
        self.stderr_thread = try std.Thread.spawn(.{}, pipeReaderMain, .{&self.stderr_reader});
        errdefer {
            self.stderr_thread.?.join();
            self.stderr_thread = null;
        }

        try fdDup2(self.stdin_reader, 0);
        try fdDup2(self.stdout_writer, 1);
        try fdDup2(self.stderr_writer, 2);
        fdClose(self.stdin_reader);
        fdClose(self.stdout_writer);
        fdClose(self.stderr_writer);
        self.active = true;
    }

    fn end(self: *StdioCapture) void {
        if (!self.active) return;

        fdDup2(self.saved_stdin, 0) catch {};
        fdDup2(self.saved_stdout, 1) catch {};
        fdDup2(self.saved_stderr, 2) catch {};
        fdClose(self.saved_stdin);
        fdClose(self.saved_stdout);
        fdClose(self.saved_stderr);
        self.saved_stdin = -1;
        self.saved_stdout = -1;
        self.saved_stderr = -1;

        if (self.stdin_thread) |thread| thread.join();
        if (self.stdout_thread) |thread| thread.join();
        if (self.stderr_thread) |thread| thread.join();
        self.stdin_thread = null;
        self.stdout_thread = null;
        self.stderr_thread = null;
        self.active = false;
    }

    fn appendStderrFallback(self: *StdioCapture, message: []const u8) !void {
        if (self.stderr_reader.output.items.len == 0) {
            try self.stderr_reader.output.appendSlice(self.allocator, message);
            return;
        }
        if (self.stderr_reader.output.items.len < self.max_output_bytes) {
            const remaining = self.max_output_bytes - self.stderr_reader.output.items.len;
            const prefix = if (remaining > 0) "\n" else "";
            const with_prefix = @min(prefix.len, remaining);
            if (with_prefix > 0) {
                try self.stderr_reader.output.appendSlice(self.allocator, prefix[0..with_prefix]);
            }
            const remaining_after_prefix = self.max_output_bytes - self.stderr_reader.output.items.len;
            const take = @min(message.len, remaining_after_prefix);
            try self.stderr_reader.output.appendSlice(self.allocator, message[0..take]);
            if (take < message.len) self.stderr_reader.too_long = true;
        } else {
            self.stderr_reader.too_long = true;
        }
    }

    fn takeStdout(self: *StdioCapture) ![]u8 {
        if (self.stdout_reader.read_err) |err| return err;
        if (self.stdout_reader.too_long) return error.StdoutStreamTooLong;
        const output = try self.stdout_reader.output.toOwnedSlice(self.allocator);
        self.stdout_reader.output = .empty;
        return output;
    }

    fn takeStderr(self: *StdioCapture) ![]u8 {
        if (self.stderr_reader.read_err) |err| return err;
        if (self.stderr_reader.too_long) return error.StderrStreamTooLong;
        if (self.stdin_writer.write_err) |err| return err;
        const output = try self.stderr_reader.output.toOwnedSlice(self.allocator);
        self.stderr_reader.output = .empty;
        return output;
    }
};

fn pipeReaderMain(reader: *PipeReader) void {
    reader.run();
}

fn pipeWriterMain(writer: *PipeWriter) void {
    writer.run();
}

fn fdPipe() ![2]fd_t {
    if (builtin.os.tag == .windows) {
        var fds: [2]c_int = undefined;
        if (c._pipe(&fds, 4096, c._O_BINARY) != 0) return error.CreatePipeFailed;
        return fds;
    }
    return try std.posix.pipe();
}

fn fdDup(fd: fd_t) !fd_t {
    if (builtin.os.tag == .windows) {
        const duped = c._dup(fd);
        if (duped < 0) return error.DupFailed;
        return duped;
    }
    return try std.posix.dup(fd);
}

fn fdDup2(from: fd_t, to: fd_t) !void {
    if (builtin.os.tag == .windows) {
        if (c._dup2(from, to) != 0) return error.Dup2Failed;
        try syncWindowsStdHandle(to);
        return;
    }
    try std.posix.dup2(from, to);
}

fn syncWindowsStdHandle(fd: fd_t) !void {
    if (builtin.os.tag != .windows) return;

    const std_handle_id = switch (fd) {
        0 => windows.STD_INPUT_HANDLE,
        1 => windows.STD_OUTPUT_HANDLE,
        2 => windows.STD_ERROR_HANDLE,
        else => return,
    };

    const raw_handle = c._get_osfhandle(fd);
    if (raw_handle == -1) return error.GetOsHandleFailed;
    const handle: windows.HANDLE = @ptrFromInt(std.math.cast(usize, raw_handle) orelse return error.GetOsHandleFailed);

    if (SetStdHandle(std_handle_id, handle) == 0) return error.SetStdHandleFailed;

    const process_parameters = windows.peb().ProcessParameters;
    switch (std_handle_id) {
        windows.STD_INPUT_HANDLE => process_parameters.hStdInput = handle,
        windows.STD_OUTPUT_HANDLE => process_parameters.hStdOutput = handle,
        windows.STD_ERROR_HANDLE => process_parameters.hStdError = handle,
        else => unreachable,
    }
}

fn fdRead(fd: fd_t, buffer: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const rc = c._read(fd, buffer.ptr, @intCast(buffer.len));
        if (rc < 0) return error.ReadFailed;
        return @intCast(rc);
    }
    return try std.posix.read(fd, buffer);
}

fn fdWrite(fd: fd_t, buffer: []const u8) !usize {
    if (builtin.os.tag == .windows) {
        const rc = c._write(fd, buffer.ptr, @intCast(buffer.len));
        if (rc < 0) return error.WriteFailed;
        return @intCast(rc);
    }
    return try std.posix.write(fd, buffer);
}

fn fdClose(fd: fd_t) void {
    if (fd < 0) return;
    if (builtin.os.tag == .windows) {
        _ = c._close(fd);
        return;
    }
    std.posix.close(fd);
}

test "zwasm_runtime: validates fields" {
    try std.testing.expectError(error.InvalidZwasmConfig, validateConfig(.{
        .module_path = "",
    }));
    try std.testing.expectError(error.InvalidZwasmConfig, validateConfig(.{
        .module_path = "module.wasm",
        .entrypoint = "bad name",
    }));
}

test "zwasm_runtime: timeout limit traps looping module" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source_path = try std.fs.path.join(allocator, &.{ root, "loop_driver.zig" });
    defer allocator.free(source_path);
    const module_path = try std.fs.path.join(allocator, &.{ root, "loop_driver.wasm" });
    defer allocator.free(module_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{module_path});
    defer allocator.free(emit_arg);

    const source =
        "pub export fn loop() void {\n" ++
        "  while (true) {}\n" ++
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
        invokeModule(allocator, .{
            .module_path = module_path,
            .entrypoint = "loop",
            .timeout_ms = 10,
        }, "", 1024),
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
