const std = @import("std");
const unified = @import("spider-protocol").unified;

pub const max_internal_retries: usize = 2;

pub const RuntimeExecutor = struct {
    ctx: ?*anyopaque = null,
    execute: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        request_json: []const u8,
        emit_debug: bool,
    ) anyerror![][]u8,
    deinit_frames: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        frames: [][]u8,
    ) void,
};

pub const ExecuteOptions = struct {
    allocator: std.mem.Allocator,
    executor: RuntimeExecutor,
    request_id: []const u8,
    input: []const u8,
    correlation_id: ?[]const u8 = null,
    emit_debug: bool = false,
    max_retries: usize = max_internal_retries,
};

pub const ExecutionResult = struct {
    succeeded: bool,
    result_text: []u8,
    error_text: ?[]u8 = null,
    log_text: []u8,

    pub fn deinit(self: *ExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.result_text);
        if (self.error_text) |value| allocator.free(value);
        allocator.free(self.log_text);
        self.* = undefined;
    }
};

pub const NormalizedRuntimeFailure = struct {
    code: []const u8,
    message: []const u8,
};

pub fn execute(options: ExecuteOptions) !ExecutionResult {
    const runtime_req = try buildRuntimeRequest(
        options.allocator,
        options.request_id,
        options.input,
        options.correlation_id,
    );
    defer options.allocator.free(runtime_req);

    var log_buf = std.ArrayListUnmanaged(u8){};
    defer log_buf.deinit(options.allocator);

    var result_text = try options.allocator.dupe(u8, "");
    errdefer options.allocator.free(result_text);

    var failed = true;
    var failure_code: []const u8 = "runtime_error";
    var failure_message: []const u8 = "runtime error";
    var failure_message_owned: ?[]u8 = null;
    defer if (failure_message_owned) |value| options.allocator.free(value);

    var attempt_idx: usize = 0;
    while (attempt_idx <= options.max_retries) : (attempt_idx += 1) {
        failed = false;
        failure_code = "runtime_error";
        failure_message = "";
        if (failure_message_owned) |owned| {
            options.allocator.free(owned);
            failure_message_owned = null;
        }
        options.allocator.free(result_text);
        result_text = try options.allocator.dupe(u8, "");

        var responses: ?[][]u8 = null;
        if (options.executor.execute(options.executor.ctx, options.allocator, runtime_req, options.emit_debug)) |frames| {
            responses = frames;
        } else |runtime_err| {
            failed = true;
            const normalized = normalizeRuntimeFailureForAgent("runtime_error", @errorName(runtime_err));
            failure_code = normalized.code;
            failure_message = normalized.message;
            try log_buf.writer(options.allocator).print("[runtime error] {s}\n", .{@errorName(runtime_err)});
        }
        defer if (responses) |frames| options.executor.deinit_frames(options.executor.ctx, options.allocator, frames);

        if (responses) |frames| {
            for (frames) |frame| {
                try log_buf.appendSlice(options.allocator, frame);
                try log_buf.append(options.allocator, '\n');

                var parsed = std.json.parseFromSlice(std.json.Value, options.allocator, frame, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const obj = parsed.value.object;
                const type_value = obj.get("type") orelse continue;
                if (type_value != .string) continue;

                if (std.mem.eql(u8, type_value.string, "session.receive")) {
                    if (extractSessionReceiveContent(obj)) |content| {
                        options.allocator.free(result_text);
                        result_text = try options.allocator.dupe(u8, content);
                    }
                    continue;
                }

                if (std.mem.eql(u8, type_value.string, "error")) {
                    failed = true;
                    const code = if (obj.get("code")) |value|
                        if (value == .string) value.string else "runtime_error"
                    else
                        "runtime_error";
                    const message = if (obj.get("message")) |value|
                        if (value == .string) value.string else "runtime error"
                    else
                        "runtime error";
                    const normalized = normalizeRuntimeFailureForAgent(code, message);
                    failure_code = normalized.code;
                    if (failure_message_owned) |owned| options.allocator.free(owned);
                    failure_message_owned = try options.allocator.dupe(u8, normalized.message);
                    failure_message = failure_message_owned.?;
                }
            }
        }

        if (!failed and isInternalRuntimeLoopGuardText(result_text)) {
            failed = true;
            if (failure_message_owned) |owned| options.allocator.free(owned);
            const normalized = normalizeRuntimeFailureForAgent("execution_failed", result_text);
            failure_code = normalized.code;
            failure_message_owned = try options.allocator.dupe(u8, normalized.message);
            failure_message = failure_message_owned.?;
        }

        if (!failed) break;
        if (!std.mem.eql(u8, failure_code, "runtime_internal_limit")) break;
        if (attempt_idx >= options.max_retries) break;

        try log_buf.writer(options.allocator).print(
            "[runtime retry] attempt={d} reason={s}\n",
            .{ attempt_idx + 1, failure_code },
        );
    }

    if (failed) {
        options.allocator.free(result_text);
        result_text = try options.allocator.dupe(u8, failure_message);
    }

    const log_text = try log_buf.toOwnedSlice(options.allocator);
    errdefer options.allocator.free(log_text);

    const error_text = if (failed)
        try options.allocator.dupe(u8, result_text)
    else
        null;
    errdefer if (error_text) |value| options.allocator.free(value);

    return .{
        .succeeded = !failed,
        .result_text = result_text,
        .error_text = error_text,
        .log_text = log_text,
    };
}

pub fn normalizeRuntimeFailureForAgent(code: []const u8, message: []const u8) NormalizedRuntimeFailure {
    if (runtimeFailureIsToolContractFailure(code, message)) {
        return .{
            .code = "runtime_protocol_error",
            .message = "Assistant runtime lost the tool-call contract after the last result. The agent should use the last result to reply or choose a different approach.",
        };
    }
    if (runtimeFailureShouldBeRedacted(code, message)) {
        return .{
            .code = "runtime_internal_limit",
            .message = "Temporary internal runtime limit reached; retry this request.",
        };
    }
    return .{ .code = code, .message = message };
}

pub fn normalizeRuntimeFailure(code: []const u8, message: []const u8) NormalizedRuntimeFailure {
    return normalizeRuntimeFailureForAgent(code, message);
}

pub fn isInternalRuntimeLoopGuardText(text: []const u8) bool {
    const markers = [_][]const u8{
        "internal reasoning loop",
        "loop while preparing that response",
        "provider followup cap",
        "provider tool loop exceeded",
    };
    return containsAnyIgnoreCase(text, &markers);
}

fn buildRuntimeRequest(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    input: []const u8,
    correlation_id: ?[]const u8,
) ![]u8 {
    const escaped = try unified.jsonEscape(allocator, input);
    defer allocator.free(escaped);
    if (correlation_id) |value| {
        const escaped_corr = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped_corr);
        return std.fmt.allocPrint(
            allocator,
            "{{\"id\":\"{s}\",\"type\":\"session.send\",\"content\":\"{s}\",\"correlation_id\":\"{s}\"}}",
            .{ request_id, escaped, escaped_corr },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"{s}\",\"type\":\"session.send\",\"content\":\"{s}\"}}",
        .{ request_id, escaped },
    );
}

fn extractSessionReceiveContent(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("content")) |content| {
        if (content == .string) return content.string;
    }
    if (obj.get("payload")) |payload| {
        if (payload == .object) {
            if (payload.object.get("content")) |content| {
                if (content == .string) return content.string;
            }
        }
    }
    return null;
}

fn runtimeFailureShouldBeRedacted(code: []const u8, message: []const u8) bool {
    if (std.mem.startsWith(u8, code, "provider_")) return true;
    if (isInternalRuntimeLoopGuardText(message)) return true;
    const markers = [_][]const u8{
        "ProviderRequestInvalid",
        "ProviderToolLoopExceeded",
        "ProviderTimeout",
        "ProviderUnavailable",
        "ProviderStreamFailed",
        "ProviderRateLimited",
        "ProviderAuthFailed",
        "ProviderModelNotFound",
        "provider request invalid",
        "provider tool loop exceeded",
        "provider stream failed",
        "provider temporarily unavailable",
        "provider request timed out",
        "provider rate limited",
        "provider authentication failed",
        "provider model not found",
        "internal runtime limit",
    };
    return containsAnyIgnoreCase(message, &markers);
}

fn runtimeFailureIsToolContractFailure(code: []const u8, message: []const u8) bool {
    _ = code;
    const markers = [_][]const u8{
        "single_tool_call_per_round",
        "missing_tool_calls",
        "exactly one tool call",
        "zero tool calls is protocol-invalid",
        "provider tool loop exceeded",
    };
    return containsAnyIgnoreCase(message, &markers);
}

fn containsAnyIgnoreCase(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return true;
    }
    return false;
}

const DummyExecutorState = struct {
    attempts: usize = 0,
};

fn testExecute(raw_ctx: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8, _: bool) ![][]u8 {
    const ctx: *DummyExecutorState = @ptrCast(@alignCast(raw_ctx.?));
    ctx.attempts += 1;
    const frames = try allocator.alloc([]u8, 1);
    frames[0] = if (ctx.attempts == 1)
        try allocator.dupe(u8, "{\"type\":\"error\",\"code\":\"provider_request_invalid\",\"message\":\"provider request invalid\"}")
    else
        try allocator.dupe(u8, "{\"type\":\"session.receive\",\"content\":\"done\"}");
    return frames;
}

fn testDeinitFrames(_: ?*anyopaque, allocator: std.mem.Allocator, frames: [][]u8) void {
    for (frames) |frame| allocator.free(frame);
    allocator.free(frames);
}

test "chat_runtime_exec retries internal-limit failures and returns final result" {
    const allocator = std.testing.allocator;
    var state = DummyExecutorState{};
    var result = try execute(.{
        .allocator = allocator,
        .executor = .{
            .ctx = @ptrCast(&state),
            .execute = testExecute,
            .deinit_frames = testDeinitFrames,
        },
        .request_id = "req-1",
        .input = "hello",
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.succeeded);
    try std.testing.expectEqualStrings("done", result.result_text);
    try std.testing.expect(std.mem.indexOf(u8, result.log_text, "[runtime retry]") != null);
}

test "chat_runtime_exec normalizes tool-contract failures" {
    const normalized = normalizeRuntimeFailureForAgent("execution_failed", "provider tool loop exceeded limits");
    try std.testing.expectEqualStrings("runtime_protocol_error", normalized.code);
    try std.testing.expect(isInternalRuntimeLoopGuardText("I hit an internal reasoning loop while preparing that response. Please retry."));
}
