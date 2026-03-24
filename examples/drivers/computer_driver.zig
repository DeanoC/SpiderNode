const std = @import("std");
const builtin = @import("builtin");
const capability = @import("spiderweb_node").macos_capability_venoms;

const max_payload_bytes: usize = 1024 * 1024;
const max_capture_bytes: usize = 512 * 1024;
const screenshot_resize_px: []const u8 = "640";

const c = if (builtin.os.tag == .macos) @cImport({
    @cInclude("ApplicationServices/ApplicationServices.h");
}) else struct {};

const Action = enum {
    activate,
    focus_window,
    primary_tap,
    text_input,
    key_combo,
};

const ObserveArgs = struct {
    include_screenshot: bool = true,
};

const ActArgs = struct {
    action: Action,
    app_name: ?[]u8 = null,
    window_title: ?[]u8 = null,
    button_title: ?[]u8 = null,
    text: ?[]u8 = null,
    key: ?[]u8 = null,
    modifiers: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *ActArgs, allocator: std.mem.Allocator) void {
        if (self.app_name) |value| allocator.free(value);
        if (self.window_title) |value| allocator.free(value);
        if (self.button_title) |value| allocator.free(value);
        if (self.text) |value| allocator.free(value);
        if (self.key) |value| allocator.free(value);
        for (self.modifiers.items) |value| allocator.free(value);
        self.modifiers.deinit(allocator);
        self.* = undefined;
    }
};

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const ArtifactUpdate = struct {
    path: []const u8,
    content: ?[]u8 = null,
    content_b64: ?[]u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const payload = try std.fs.File.stdin().readToEndAlloc(allocator, max_payload_bytes);
    defer allocator.free(payload);
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) fatal("invalid_payload: invoke payload must be a JSON object");

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        fatal("invalid_payload: invoke payload must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) fatal("invalid_payload: invoke payload must be a JSON object");

    const op = getRequiredString(parsed.value.object, "op") orelse fatal("invalid_payload: missing op");
    if (builtin.os.tag != .macos) {
        const rendered = try std.fmt.allocPrint(
            allocator,
            "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"{s}\",\"status\":{{\"state\":\"offline\",\"reason\":\"unsupported_platform\",\"platform\":\"{s}\"}},\"health\":{{\"state\":\"offline\",\"platform\":\"{s}\",\"supported\":false}},\"result\":{{\"ok\":false,\"reason\":\"unsupported_platform\"}},\"artifact_updates\":[{{\"path\":\"artifacts/last_observation.json\",\"content\":\"{{\\\"platform\\\":\\\"{s}\\\",\\\"supported\\\":false}}\"}}]}}",
            .{ capability.computer_venom_id, op, @tagName(builtin.os.tag), @tagName(builtin.os.tag), @tagName(builtin.os.tag) },
        );
        defer allocator.free(rendered);
        try std.fs.File.stdout().writeAll(rendered);
        return;
    }

    if (std.mem.eql(u8, op, "observe")) {
        const args = try parseObserveArgs(allocator, parsed.value.object);
        const rendered = try performObserve(allocator, args);
        defer allocator.free(rendered);
        try std.fs.File.stdout().writeAll(rendered);
        return;
    }
    if (std.mem.eql(u8, op, "act")) {
        var args = try parseActArgs(allocator, parsed.value.object);
        defer args.deinit(allocator);
        const rendered = try performAct(allocator, &args);
        defer allocator.free(rendered);
        try std.fs.File.stdout().writeAll(rendered);
        return;
    }

    fatal("invalid_payload: unsupported op");
}

fn performObserve(allocator: std.mem.Allocator, args: ObserveArgs) ![]u8 {
    const accessibility = accessibilityTrusted();
    var screen_capture = false;

    const observation_json = if (accessibility)
        try collectObservationJson(allocator)
    else
        try allocator.dupe(u8, "{\"focused_window\":null,\"windows\":[],\"ui_tree\":null,\"permission_state\":{\"accessibility\":false,\"screen_capture\":false}}");
    defer allocator.free(observation_json);

    const status_json = try std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"{s}\",\"permissions\":{{\"accessibility\":{},\"screen_capture\":{}}},\"device\":\"computer\"}}",
        .{ if (accessibility) "ok" else "degraded", accessibility, false },
    );
    defer allocator.free(status_json);
    const health_json = try std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"{s}\",\"platform\":\"macos\",\"permissions\":{{\"accessibility\":{},\"screen_capture\":{}}}}}",
        .{ if (accessibility) "online" else "degraded", accessibility, false },
    );
    defer allocator.free(health_json);

    var updates = std.ArrayListUnmanaged(ArtifactUpdate){};
    defer updates.deinit(allocator);

    const observation_content = try allocator.dupe(u8, observation_json);
    errdefer allocator.free(observation_content);
    try updates.append(allocator, .{
        .path = "artifacts/last_observation.json",
        .content = observation_content,
    });

    if (args.include_screenshot) {
        if (try captureScreenshotBase64(allocator)) |encoded| {
            screen_capture = true;
            errdefer allocator.free(encoded);
            try updates.append(allocator, .{
                .path = "artifacts/last_screenshot.png",
                .content_b64 = encoded,
            });
        }
    }

    const result_json = try std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"observe\",\"observation\":{s},\"artifact_paths\":{{\"observation\":\"artifacts/last_observation.json\",\"screenshot\":{s}}},\"status\":{s},\"health\":{{\"state\":\"{s}\",\"platform\":\"macos\",\"permissions\":{{\"accessibility\":{},\"screen_capture\":{}}}}},\"artifact_updates\":{s}}}",
        .{
            capability.computer_venom_id,
            observation_json,
            if (screen_capture) "\"artifacts/last_screenshot.png\"" else "null",
            status_json,
            if (accessibility) "online" else "degraded",
            accessibility,
            screen_capture,
            try renderArtifactUpdatesJson(allocator, updates.items),
        },
    );
    return result_json;
}

fn performAct(allocator: std.mem.Allocator, args: *ActArgs) ![]u8 {
    const accessibility = accessibilityTrusted();
    if (!accessibility) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"act\",\"action_result\":{{\"ok\":false,\"reason\":\"accessibility_not_granted\",\"action\":\"{s}\"}},\"status\":{{\"state\":\"degraded\",\"permissions\":{{\"accessibility\":false,\"screen_capture\":false}}}},\"health\":{{\"state\":\"degraded\",\"platform\":\"macos\",\"permissions\":{{\"accessibility\":false,\"screen_capture\":false}}}}}}",
            .{ capability.computer_venom_id, @tagName(args.action) },
        );
    }

    switch (args.action) {
        .activate => try activateApp(allocator, args.app_name.?),
        .focus_window => try focusWindow(allocator, args.app_name.?, args.window_title.?),
        .primary_tap => try clickFrontButton(allocator, args.button_title.?),
        .text_input => try typeText(allocator, args.text.?),
        .key_combo => try sendKeyCombo(allocator, args.key.?, args.modifiers.items),
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"act\",\"action_result\":{{\"ok\":true,\"action\":\"{s}\"}},\"status\":{{\"state\":\"ok\",\"permissions\":{{\"accessibility\":true,\"screen_capture\":false}}}},\"health\":{{\"state\":\"online\",\"platform\":\"macos\",\"permissions\":{{\"accessibility\":true,\"screen_capture\":false}}}}}}",
        .{ capability.computer_venom_id, @tagName(args.action) },
    );
}

fn parseObserveArgs(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ObserveArgs {
    var result = ObserveArgs{};
    if (obj.get("arguments")) |value| {
        if (value != .object) return error.InvalidPayload;
        if (value.object.get("include_screenshot")) |raw| {
            if (raw != .bool) return error.InvalidPayload;
            result.include_screenshot = raw.bool;
        }
    }
    _ = allocator;
    return result;
}

fn parseActArgs(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ActArgs {
    const arguments = obj.get("arguments") orelse return error.InvalidPayload;
    if (arguments != .object) return error.InvalidPayload;
    const action_raw = getRequiredString(arguments.object, "action") orelse return error.InvalidPayload;

    var result = ActArgs{
        .action = std.meta.stringToEnum(Action, action_raw) orelse return error.InvalidPayload,
    };
    errdefer result.deinit(allocator);

    if (arguments.object.get("app_name")) |value| {
        result.app_name = try dupRequiredNonEmptyString(allocator, value);
    }
    if (arguments.object.get("window_title")) |value| {
        result.window_title = try dupRequiredNonEmptyString(allocator, value);
    }
    if (arguments.object.get("button_title")) |value| {
        result.button_title = try dupRequiredNonEmptyString(allocator, value);
    }
    if (arguments.object.get("text")) |value| {
        result.text = try dupRequiredNonEmptyString(allocator, value);
    }
    if (arguments.object.get("key")) |value| {
        result.key = try dupRequiredNonEmptyString(allocator, value);
    }
    if (arguments.object.get("modifiers")) |value| {
        if (value != .array) return error.InvalidPayload;
        for (value.array.items) |item| {
            const modifier = try dupRequiredNonEmptyString(allocator, item);
            errdefer allocator.free(modifier);
            if (!isSupportedModifier(modifier)) return error.InvalidPayload;
            try result.modifiers.append(allocator, modifier);
        }
    }

    switch (result.action) {
        .activate => if (result.app_name == null) return error.InvalidPayload,
        .focus_window => if (result.app_name == null or result.window_title == null) return error.InvalidPayload,
        .primary_tap => if (result.button_title == null) return error.InvalidPayload,
        .text_input => if (result.text == null) return error.InvalidPayload,
        .key_combo => if (result.key == null) return error.InvalidPayload,
    }
    return result;
}

fn collectObservationJson(allocator: std.mem.Allocator) ![]u8 {
    const script =
        "function safeCall(fn, fallback) { try { return fn(); } catch (e) { return fallback; } }\n" ++
        "function safeName(obj) { return safeCall(function(){ return obj.name(); }, \"\"); }\n" ++
        "function safeValue(obj) { return safeCall(function(){ return String(obj.value()); }, \"\"); }\n" ++
        "function run() {\n" ++
        "  var se = Application('System Events');\n" ++
        "  var result = { focused_window: null, windows: [], ui_tree: null, permission_state: { accessibility: true, screen_capture: false } };\n" ++
        "  var fronts = se.applicationProcesses.whose({ frontmost: true })();\n" ++
        "  if (fronts.length > 0) {\n" ++
        "    var proc = fronts[0];\n" ++
        "    var wins = safeCall(function(){ return proc.windows(); }, []);\n" ++
        "    var firstTitle = wins.length > 0 ? safeName(wins[0]) : '';\n" ++
        "    result.focused_window = { app_name: safeName(proc), window_title: firstTitle };\n" ++
        "    var children = [];\n" ++
        "    if (wins.length > 0) {\n" ++
        "      var buttons = safeCall(function(){ return wins[0].buttons(); }, []);\n" ++
        "      for (var i = 0; i < buttons.length; i++) children.push({ role: 'button', title: safeName(buttons[i]) });\n" ++
        "      var fields = safeCall(function(){ return wins[0].textFields(); }, []);\n" ++
        "      for (var j = 0; j < fields.length; j++) children.push({ role: 'text_field', value: safeValue(fields[j]) });\n" ++
        "      result.ui_tree = { role: 'window', title: firstTitle, children: children };\n" ++
        "    }\n" ++
        "  }\n" ++
        "  var procs = safeCall(function(){ return se.applicationProcesses.whose({ backgroundOnly: false })(); }, []);\n" ++
        "  for (var p = 0; p < procs.length; p++) {\n" ++
        "    var proc = procs[p];\n" ++
        "    var wins = safeCall(function(){ return proc.windows(); }, []);\n" ++
        "    for (var w = 0; w < wins.length; w++) result.windows.push({ app_name: safeName(proc), window_title: safeName(wins[w]) });\n" ++
        "  }\n" ++
        "  return JSON.stringify(result);\n" ++
        "}";
    return runOsascriptJavaScript(allocator, script);
}

fn activateApp(allocator: std.mem.Allocator, app_name: []const u8) !void {
    const escaped = try appleScriptEscape(allocator, app_name);
    defer allocator.free(escaped);
    const line = try std.fmt.allocPrint(allocator, "tell application \"{s}\" to activate", .{escaped});
    defer allocator.free(line);
    try runAppleScriptExpectOk(allocator, &.{line});
}

fn focusWindow(allocator: std.mem.Allocator, app_name: []const u8, window_title: []const u8) !void {
    const escaped_app = try appleScriptEscape(allocator, app_name);
    defer allocator.free(escaped_app);
    const escaped_title = try appleScriptEscape(allocator, window_title);
    defer allocator.free(escaped_title);

    const line1 = try std.fmt.allocPrint(allocator, "tell application \"System Events\"", .{});
    defer allocator.free(line1);
    const line2 = try std.fmt.allocPrint(allocator, "set targetProc to first application process whose name is \"{s}\"", .{escaped_app});
    defer allocator.free(line2);
    const line3 = try allocator.dupe(u8, "set frontmost of targetProc to true");
    defer allocator.free(line3);
    const line4 = try allocator.dupe(u8, "repeat with win in windows of targetProc");
    defer allocator.free(line4);
    const line5 = try std.fmt.allocPrint(allocator, "if name of win is \"{s}\" then", .{escaped_title});
    defer allocator.free(line5);
    const line6 = try allocator.dupe(u8, "try");
    defer allocator.free(line6);
    const line7 = try allocator.dupe(u8, "perform action \"AXRaise\" of win");
    defer allocator.free(line7);
    const line8 = try allocator.dupe(u8, "end try");
    defer allocator.free(line8);
    const line9 = try allocator.dupe(u8, "exit repeat");
    defer allocator.free(line9);
    const line10 = try allocator.dupe(u8, "end if");
    defer allocator.free(line10);
    const line11 = try allocator.dupe(u8, "end repeat");
    defer allocator.free(line11);
    const line12 = try allocator.dupe(u8, "end tell");
    defer allocator.free(line12);
    try runAppleScriptExpectOk(allocator, &.{ line1, line2, line3, line4, line5, line6, line7, line8, line9, line10, line11, line12 });
}

fn clickFrontButton(allocator: std.mem.Allocator, button_title: []const u8) !void {
    const escaped_title = try appleScriptEscape(allocator, button_title);
    defer allocator.free(escaped_title);
    const line = try std.fmt.allocPrint(
        allocator,
        "tell application \"System Events\" to click first button of first window of first application process whose frontmost is true and name is \"{s}\"",
        .{escaped_title},
    );
    defer allocator.free(line);
    try runAppleScriptExpectOk(allocator, &.{line});
}

fn typeText(allocator: std.mem.Allocator, text: []const u8) !void {
    const escaped = try appleScriptEscape(allocator, text);
    defer allocator.free(escaped);
    const line = try std.fmt.allocPrint(allocator, "tell application \"System Events\" to keystroke \"{s}\"", .{escaped});
    defer allocator.free(line);
    try runAppleScriptExpectOk(allocator, &.{line});
}

fn sendKeyCombo(allocator: std.mem.Allocator, key: []const u8, modifiers: []const []u8) !void {
    const escaped_key = try appleScriptEscape(allocator, key);
    defer allocator.free(escaped_key);

    const using_fragment = if (modifiers.len > 0) blk: {
        var out = std.ArrayListUnmanaged(u8){};
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, " using {");
        for (modifiers, 0..) |modifier, idx| {
            if (idx != 0) try out.appendSlice(allocator, ", ");
            if (std.mem.eql(u8, modifier, "command")) try out.appendSlice(allocator, "command down") else if (std.mem.eql(u8, modifier, "option")) try out.appendSlice(allocator, "option down") else if (std.mem.eql(u8, modifier, "shift")) try out.appendSlice(allocator, "shift down") else if (std.mem.eql(u8, modifier, "control")) try out.appendSlice(allocator, "control down") else return error.InvalidPayload;
        }
        try out.appendSlice(allocator, "}");
        break :blk try out.toOwnedSlice(allocator);
    } else try allocator.dupe(u8, "");
    defer allocator.free(using_fragment);

    const line = try std.fmt.allocPrint(
        allocator,
        "tell application \"System Events\" to keystroke \"{s}\"{s}",
        .{ escaped_key, using_fragment },
    );
    defer allocator.free(line);
    try runAppleScriptExpectOk(allocator, &.{line});
}

fn runAppleScriptExpectOk(allocator: std.mem.Allocator, lines: []const []const u8) !void {
    var result = try runAppleScript(allocator, lines);
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.CommandFailed;
}

fn runAppleScript(allocator: std.mem.Allocator, lines: []const []const u8) !CommandResult {
    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "osascript" });
    for (lines) |line| {
        try argv.appendSlice(allocator, &.{ "-e", line });
    }
    return runCommand(allocator, argv.items);
}

fn runOsascriptJavaScript(allocator: std.mem.Allocator, script: []const u8) ![]u8 {
    var result = try runCommand(allocator, &.{ "osascript", "-l", "JavaScript", "-e", script });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.CommandFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = max_payload_bytes,
    });
    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => 255,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

fn captureScreenshotBase64(allocator: std.mem.Allocator) !?[]u8 {
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/spiderweb-computer-{d}.png", .{std.time.milliTimestamp()});
    defer allocator.free(tmp_path);
    std.fs.deleteFileAbsolute(tmp_path) catch {};
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var capture = try runCommand(allocator, &.{ "screencapture", "-x", tmp_path });
    defer capture.deinit(allocator);
    if (capture.exit_code != 0) return null;

    var resize = try runCommand(allocator, &.{ "sips", "-Z", screenshot_resize_px, tmp_path, "--out", tmp_path });
    defer resize.deinit(allocator);

    const bytes = readFileAbsoluteAllocCompat(allocator, tmp_path, max_capture_bytes) catch return null;
    defer allocator.free(bytes);
    if (bytes.len == 0) return null;

    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn renderArtifactUpdatesJson(allocator: std.mem.Allocator, updates: []const ArtifactUpdate) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (updates, 0..) |update, idx| {
        if (idx != 0) try out.append(allocator, ',');
        const escaped_path = try jsonEscapeOwned(allocator, update.path);
        defer allocator.free(escaped_path);
        if (update.content) |content| {
            const escaped_content = try jsonEscapeOwned(allocator, content);
            defer allocator.free(escaped_content);
            try out.writer(allocator).print(
                "{{\"path\":\"{s}\",\"content\":\"{s}\"}}",
                .{ escaped_path, escaped_content },
            );
        } else if (update.content_b64) |content_b64| {
            const escaped_content = try jsonEscapeOwned(allocator, content_b64);
            defer allocator.free(escaped_content);
            try out.writer(allocator).print(
                "{{\"path\":\"{s}\",\"content_b64\":\"{s}\"}}",
                .{ escaped_path, escaped_content },
            );
        } else {
            try out.writer(allocator).print(
                "{{\"path\":\"{s}\",\"content\":\"\"}}",
                .{escaped_path},
            );
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn getRequiredString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn dupRequiredNonEmptyString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    if (value != .string) return error.InvalidPayload;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPayload;
    return allocator.dupe(u8, trimmed);
}

fn jsonEscapeOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.writer(allocator).print("\\u00{x:0>2}", .{ch});
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appleScriptEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isSupportedModifier(modifier: []const u8) bool {
    return std.mem.eql(u8, modifier, "command") or
        std.mem.eql(u8, modifier, "option") or
        std.mem.eql(u8, modifier, "shift") or
        std.mem.eql(u8, modifier, "control");
}

fn readFileAbsoluteAllocCompat(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return error.FileNotFound;
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn accessibilityTrusted() bool {
    if (builtin.os.tag != .macos) return false;
    return c.AXIsProcessTrusted() != 0;
}

fn fatal(msg: []const u8) noreturn {
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(2);
}
