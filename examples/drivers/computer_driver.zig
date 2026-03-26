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

const PermissionState = struct {
    accessibility: bool,
    screen_capture_checked: bool = false,
    screen_capture: bool = false,
};

const linux_helper_source =
    \\import json
    \\import os
    \\import sys
    \\
    \\try:
    \\    import pyatspi
    \\except Exception as exc:
    \\    response = {
    \\        "ok": True,
    \\        "venom_id": "computer-main",
    \\        "op": "observe",
    \\        "observation": {
    \\            "focused_window": None,
    \\            "windows": [],
    \\            "ui_tree": None,
    \\            "permission_state": {
    \\                "accessibility": False,
    \\                "screen_capture": False
    \\            }
    \\        },
    \\        "status": {
    \\            "state": "degraded",
    \\            "readiness_state": "accessibility_required",
    \\            "observe_ready": False,
    \\            "act_ready": False,
    \\            "screenshot_ready": False,
    \\            "permissions": {
    \\                "accessibility": {
    \\                    "granted": False,
    \\                    "required": True,
    \\                    "guidance": "Install python3-pyatspi and run the Linux node inside an AT-SPI-enabled desktop session."
    \\                },
    \\                "screen_capture": {
    \\                    "granted": False,
    \\                    "checked": False,
    \\                    "required": False,
    \\                    "guidance": "Linux screenshot artifacts are optional in this first capability lane."
    \\                }
    \\            },
    \\            "detail": str(exc)
    \\        },
    \\        "health": {
    \\            "state": "degraded",
    \\            "platform": "linux",
    \\            "readiness_state": "accessibility_required",
    \\            "observe_ready": False,
    \\            "act_ready": False,
    \\            "screenshot_ready": False,
    \\            "permissions": {
    \\                "accessibility": {
    \\                    "granted": False,
    \\                    "required": True,
    \\                    "guidance": "Install python3-pyatspi and run the Linux node inside an AT-SPI-enabled desktop session."
    \\                },
    \\                "screen_capture": {
    \\                    "granted": False,
    \\                    "checked": False,
    \\                    "required": False,
    \\                    "guidance": "Linux screenshot artifacts are optional in this first capability lane."
    \\                }
    \\            }
    \\        },
    \\        "artifact_updates": [
    \\            {
    \\                "path": "artifacts/last_observation.json",
    \\                "content": json.dumps({
    \\                    "focused_window": None,
    \\                    "windows": [],
    \\                    "ui_tree": None,
    \\                    "permission_state": {
    \\                        "accessibility": False,
    \\                        "screen_capture": False
    \\                    }
    \\                })
    \\            }
    \\        ]
    \\    }
    \\    print(json.dumps(response))
    \\    sys.exit(0)
    \\
    \\REQUEST = json.load(open(sys.argv[1], "r", encoding="utf-8"))
    \\FIXTURE_APP = os.environ.get("SPIDER_FIXTURE_APP_NAME", "SpiderLinuxComputerFixture")
    \\FIXTURE_WINDOW = os.environ.get("SPIDER_FIXTURE_WINDOW_TITLE", "Spider Linux Computer Fixture")
    \\
    \\WINDOW_ROLES = {"frame", "window", "dialog", "application"}
    \\TEXT_ROLES = {"text", "entry", "text field", "password text"}
    \\BUTTON_ROLES = {"push button", "button"}
    \\
    \\def children(acc):
    \\    try:
    \\        count = acc.childCount
    \\    except Exception:
    \\        count = 0
    \\    for idx in range(count):
    \\        try:
    \\            child = acc[idx]
    \\        except Exception:
    \\            continue
    \\        if child is not None:
    \\            yield child
    \\
    \\def walk(acc):
    \\    yield acc
    \\    for child in children(acc):
    \\        for nested in walk(child):
    \\            yield nested
    \\
    \\def role_name(acc):
    \\    try:
    \\        return (acc.getRoleName() or "").lower()
    \\    except Exception:
    \\        return ""
    \\
    \\def state_flags(acc):
    \\    try:
    \\        state = acc.getState()
    \\        return {
    \\            "active": state.contains(pyatspi.STATE_ACTIVE),
    \\            "focused": state.contains(pyatspi.STATE_FOCUSED),
    \\            "enabled": state.contains(pyatspi.STATE_SENSITIVE) or state.contains(pyatspi.STATE_ENABLED),
    \\        }
    \\    except Exception:
    \\        return {"active": False, "focused": False, "enabled": True}
    \\
    \\def text_value(acc):
    \\    try:
    \\        return acc.queryText().getText(0, -1)
    \\    except Exception:
    \\        return None
    \\
    \\def canonical_role(acc):
    \\    role = role_name(acc)
    \\    if role in WINDOW_ROLES:
    \\        return "window"
    \\    if role in TEXT_ROLES:
    \\        return "text_field"
    \\    if role in BUTTON_ROLES:
    \\        return "button"
    \\    if role == "label":
    \\        return "label"
    \\    return role.replace(" ", "_") or "node"
    \\
    \\def render_tree(acc, depth=0, max_depth=3):
    \\    node = {
    \\        "role": canonical_role(acc),
    \\        "name": getattr(acc, "name", "") or "",
    \\        "children": []
    \\    }
    \\    value = text_value(acc)
    \\    if value not in (None, ""):
    \\        node["value"] = value
    \\    if depth >= max_depth:
    \\        return node
    \\    for child in children(acc):
    \\        child_node = render_tree(child, depth + 1, max_depth)
    \\        if child_node["role"] != "node" or child_node.get("name") or child_node.get("value") or child_node["children"]:
    \\            node["children"].append(child_node)
    \\    return node
    \\
    \\def find_fixture_window(app_name=None, window_title=None):
    \\    desktop = pyatspi.Registry.getDesktop(0)
    \\    fallback = None
    \\    for app in desktop:
    \\        current_app_name = getattr(app, "name", "") or ""
    \\        if app_name and current_app_name != app_name:
    \\            app_matches = False
    \\        else:
    \\            app_matches = True
    \\        for child in children(app):
    \\            if role_name(child) not in WINDOW_ROLES:
    \\                continue
    \\            current_title = getattr(child, "name", "") or ""
    \\            if window_title and window_title not in current_title:
    \\                continue
    \\            if app_matches:
    \\                return app, child
    \\            if fallback is None:
    \\                fallback = (app, child)
    \\    if fallback is not None:
    \\        return fallback
    \\    return None, None
    \\
    \\def collect_windows():
    \\    result = []
    \\    desktop = pyatspi.Registry.getDesktop(0)
    \\    for app in desktop:
    \\        app_name = getattr(app, "name", "") or ""
    \\        for child in children(app):
    \\            if role_name(child) not in WINDOW_ROLES:
    \\                continue
    \\            result.append({
    \\                "app_name": app_name,
    \\                "window_title": getattr(child, "name", "") or "",
    \\                "states": state_flags(child),
    \\            })
    \\    return result
    \\
    \\def do_named_action(acc, preferred):
    \\    try:
    \\        actions = acc.queryAction()
    \\    except Exception:
    \\        return False
    \\    for idx in range(actions.nActions):
    \\        try:
    \\            name = (actions.getName(idx) or "").lower()
    \\        except Exception:
    \\            continue
    \\        if name in preferred:
    \\            try:
    \\                return bool(actions.doAction(idx))
    \\            except Exception:
    \\                return False
    \\    return False
    \\
    \\def find_first(window, role_set, match_name=None):
    \\    for node in walk(window):
    \\        if role_name(node) not in role_set:
    \\            continue
    \\        current_name = getattr(node, "name", "") or ""
    \\        if match_name and current_name != match_name:
    \\            continue
    \\        return node
    \\    return None
    \\
    \\def set_text(acc, value):
    \\    try:
    \\        editable = acc.queryEditableText()
    \\        editable.setTextContents(value)
    \\        return True
    \\    except Exception:
    \\        return False
    \\
    \\def collect_observation():
    \\    app, window = find_fixture_window(FIXTURE_APP, FIXTURE_WINDOW)
    \\    windows = collect_windows()
    \\    focused = None
    \\    for item in windows:
    \\        if item["states"].get("active") or item["states"].get("focused"):
    \\            focused = {
    \\                "app_name": item["app_name"],
    \\                "window_title": item["window_title"]
    \\            }
    \\            break
    \\    if focused is None and app is not None and window is not None:
    \\        focused = {
    \\            "app_name": getattr(app, "name", "") or "",
    \\            "window_title": getattr(window, "name", "") or "",
    \\        }
    \\    return {
    \\        "focused_window": focused,
    \\        "windows": windows,
    \\        "ui_tree": render_tree(window) if window is not None else None,
    \\        "permission_state": {
    \\            "accessibility": True,
    \\            "screen_capture": False
    \\        }
    \\    }
    \\
    \\def status_payload():
    \\    return {
    \\        "state": "ok",
    \\        "device": "computer",
    \\        "readiness_state": "ready",
    \\        "observe_ready": True,
    \\        "act_ready": True,
    \\        "screenshot_ready": False,
    \\        "permissions": {
    \\            "accessibility": {
    \\                "granted": True,
    \\                "required": True,
    \\                "guidance": "Linux computer automation requires an AT-SPI-enabled desktop session."
    \\            },
    \\            "screen_capture": {
    \\                "granted": False,
    \\                "checked": False,
    \\                "required": False,
    \\                "guidance": "Linux screenshot artifacts are optional in this first capability lane."
    \\            }
    \\        }
    \\    }
    \\
    \\def health_payload():
    \\    health = status_payload()
    \\    health["state"] = "online"
    \\    health["platform"] = "linux"
    \\    return health
    \\
    \\def observe_response():
    \\    observation = collect_observation()
    \\    return {
    \\        "ok": True,
    \\        "venom_id": "computer-main",
    \\        "op": "observe",
    \\        "observation": observation,
    \\        "artifact_paths": {
    \\            "observation": "artifacts/last_observation.json",
    \\            "screenshot": None
    \\        },
    \\        "status": status_payload(),
    \\        "health": health_payload(),
    \\        "artifact_updates": [
    \\            {
    \\                "path": "artifacts/last_observation.json",
    \\                "content": json.dumps(observation)
    \\            }
    \\        ]
    \\    }
    \\
    \\def act_response(action_result):
    \\    return {
    \\        "ok": True,
    \\        "venom_id": "computer-main",
    \\        "op": "act",
    \\        "action_result": action_result,
    \\        "observation": collect_observation(),
    \\        "status": status_payload(),
    \\        "health": health_payload()
    \\    }
    \\
    \\args = REQUEST.get("arguments") or {}
    \\op = REQUEST.get("op")
    \\if op == "observe":
    \\    print(json.dumps(observe_response()))
    \\    sys.exit(0)
    \\if op != "act":
    \\    print(json.dumps(act_response({"ok": False, "reason": "invalid_op", "action": None})))
    \\    sys.exit(0)
    \\
    \\action = args.get("action")
    \\app_name = args.get("app_name") or FIXTURE_APP
    \\window_title = args.get("window_title") or FIXTURE_WINDOW
    \\app, window = find_fixture_window(app_name, window_title)
    \\if window is None:
    \\    print(json.dumps(act_response({"ok": False, "reason": "window_missing", "action": action})))
    \\    sys.exit(0)
    \\
    \\if action == "activate":
    \\    ok = do_named_action(window, {"activate", "raise", "switch"})
    \\    print(json.dumps(act_response({"ok": bool(ok), "action": action, "reason": None if ok else "activate_failed"})))
    \\    sys.exit(0)
    \\if action == "focus_window":
    \\    ok = do_named_action(window, {"activate", "raise", "switch"})
    \\    print(json.dumps(act_response({"ok": bool(ok), "action": action, "reason": None if ok else "focus_failed"})))
    \\    sys.exit(0)
    \\if action == "primary_tap":
    \\    target = find_first(window, BUTTON_ROLES, args.get("button_title"))
    \\    ok = target is not None and do_named_action(target, {"click", "press", "jump"})
    \\    print(json.dumps(act_response({"ok": bool(ok), "action": action, "reason": None if ok else "button_missing"})))
    \\    sys.exit(0)
    \\if action == "text_input":
    \\    target = find_first(window, TEXT_ROLES)
    \\    ok = target is not None and set_text(target, args.get("text") or "")
    \\    print(json.dumps(act_response({"ok": bool(ok), "action": action, "reason": None if ok else "text_field_missing"})))
    \\    sys.exit(0)
    \\if action == "key_combo":
    \\    print(json.dumps(act_response({"ok": False, "action": action, "reason": "unsupported_action"})))
    \\    sys.exit(0)
    \\print(json.dumps(act_response({"ok": False, "action": action, "reason": "unsupported_action"})))
    \\sys.exit(0)
;

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
    if (builtin.os.tag == .linux) {
        if (std.mem.eql(u8, op, "observe")) {
            _ = try parseObserveArgs(allocator, parsed.value.object);
            const rendered = try runLinuxHelper(allocator, trimmed);
            defer allocator.free(rendered);
            try std.fs.File.stdout().writeAll(rendered);
            return;
        }
        if (std.mem.eql(u8, op, "act")) {
            var args = try parseActArgs(allocator, parsed.value.object);
            defer args.deinit(allocator);
            const rendered = try runLinuxHelper(allocator, trimmed);
            defer allocator.free(rendered);
            try std.fs.File.stdout().writeAll(rendered);
            return;
        }
        fatal("invalid_payload: unsupported op");
    }

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
    var permissions = PermissionState{
        .accessibility = uiScriptingAvailable(allocator),
        .screen_capture_checked = args.include_screenshot,
    };

    const observation_json = if (permissions.accessibility)
        try collectObservationJson(allocator)
    else
        try allocator.dupe(u8, "{\"focused_window\":null,\"windows\":[],\"ui_tree\":null,\"permission_state\":{\"accessibility\":false,\"screen_capture\":false}}");
    defer allocator.free(observation_json);

    const status_json = try renderComputerStatusJson(allocator, permissions);
    defer allocator.free(status_json);
    const health_json = try renderComputerHealthJson(allocator, permissions);
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
            permissions.screen_capture = true;
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
            if (permissions.screen_capture) "\"artifacts/last_screenshot.png\"" else "null",
            status_json,
            if (permissions.accessibility) "online" else "degraded",
            permissions.accessibility,
            permissions.screen_capture,
            try renderArtifactUpdatesJson(allocator, updates.items),
        },
    );
    return result_json;
}

fn performAct(allocator: std.mem.Allocator, args: *ActArgs) ![]u8 {
    const permissions = PermissionState{
        .accessibility = uiScriptingAvailable(allocator),
    };
    const status_json = try renderComputerStatusJson(allocator, permissions);
    defer allocator.free(status_json);
    const health_json = try renderComputerHealthJson(allocator, permissions);
    defer allocator.free(health_json);
    if (!permissions.accessibility) {
        return std.fmt.allocPrint(
            allocator,
            "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"act\",\"action_result\":{{\"ok\":false,\"reason\":\"accessibility_not_granted\",\"action\":\"{s}\",\"guidance\":\"Enable Accessibility for the host app controlling System Events to allow desktop actuation.\"}},\"status\":{s},\"health\":{s}}}",
            .{ capability.computer_venom_id, @tagName(args.action), status_json, health_json },
        );
    }

    const action_attempt = switch (args.action) {
        .activate => activateApp(allocator, args.app_name.?),
        .focus_window => focusWindow(allocator, args.app_name.?, args.window_title.?),
        .primary_tap => clickFrontButton(allocator, args.button_title.?),
        .text_input => typeText(allocator, args.text.?),
        .key_combo => sendKeyCombo(allocator, args.key.?, args.modifiers.items),
    };
    _ = action_attempt catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"act\",\"action_result\":{{\"ok\":false,\"action\":\"{s}\",\"reason\":\"action_failed\",\"detail\":\"{s}\"}},\"status\":{s},\"health\":{s}}}",
            .{ capability.computer_venom_id, @tagName(args.action), @errorName(err), status_json, health_json },
        );
    };

    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"act\",\"action_result\":{{\"ok\":true,\"action\":\"{s}\"}},\"status\":{s},\"health\":{s}}}",
        .{ capability.computer_venom_id, @tagName(args.action), status_json, health_json },
    );
}

fn renderComputerStatusJson(allocator: std.mem.Allocator, permissions: PermissionState) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"{s}\",\"device\":\"computer\",\"readiness_state\":\"{s}\",\"observe_ready\":{},\"act_ready\":{},\"screenshot_ready\":{},\"permissions\":{{\"accessibility\":{{\"granted\":{},\"required\":true,\"guidance\":\"Enable Accessibility for the host app controlling System Events to allow desktop observation and actuation.\"}},\"screen_capture\":{{\"granted\":{},\"checked\":{},\"required\":false,\"guidance\":\"Enable Screen Recording for the host app if you want screenshot artifacts from the computer venom.\"}}}}}}",
        .{
            if (permissions.accessibility) "ok" else "degraded",
            if (permissions.accessibility) "ready" else "accessibility_required",
            permissions.accessibility,
            permissions.accessibility,
            permissions.screen_capture,
            permissions.accessibility,
            permissions.screen_capture,
            permissions.screen_capture_checked,
        },
    );
}

fn renderComputerHealthJson(allocator: std.mem.Allocator, permissions: PermissionState) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"state\":\"{s}\",\"platform\":\"macos\",\"readiness_state\":\"{s}\",\"observe_ready\":{},\"act_ready\":{},\"screenshot_ready\":{},\"permissions\":{{\"accessibility\":{{\"granted\":{},\"required\":true,\"guidance\":\"Enable Accessibility for the host app controlling System Events to allow desktop observation and actuation.\"}},\"screen_capture\":{{\"granted\":{},\"checked\":{},\"required\":false,\"guidance\":\"Enable Screen Recording for the host app if you want screenshot artifacts from the computer venom.\"}}}}}}",
        .{
            if (permissions.accessibility) "online" else "degraded",
            if (permissions.accessibility) "ready" else "accessibility_required",
            permissions.accessibility,
            permissions.accessibility,
            permissions.screen_capture,
            permissions.accessibility,
            permissions.screen_capture,
            permissions.screen_capture_checked,
        },
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
    const line1 = try allocator.dupe(u8, "tell application \"System Events\"");
    defer allocator.free(line1);
    const line2 = try std.fmt.allocPrint(allocator, "set targetProc to first application process whose name is \"{s}\"", .{escaped});
    defer allocator.free(line2);
    const line3 = try allocator.dupe(u8, "set frontmost of targetProc to true");
    defer allocator.free(line3);
    const line4 = try allocator.dupe(u8, "delay 0.2");
    defer allocator.free(line4);
    const line5 = try allocator.dupe(u8, "return name of first application process whose frontmost is true");
    defer allocator.free(line5);
    const line6 = try allocator.dupe(u8, "end tell");
    defer allocator.free(line6);

    const frontmost_name = try runAppleScriptExpectString(allocator, &.{ line1, line2, line3, line4, line5, line6 });
    defer allocator.free(frontmost_name);
    if (!std.mem.eql(u8, std.mem.trim(u8, frontmost_name, " \t\r\n"), app_name)) {
        return error.ActionVerificationFailed;
    }
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
    const line1 = try allocator.dupe(u8, "tell application \"System Events\"");
    defer allocator.free(line1);
    const line2 = try allocator.dupe(u8, "set targetProc to first application process whose frontmost is true");
    defer allocator.free(line2);
    const line3 = try std.fmt.allocPrint(
        allocator,
        "click first button of first window of targetProc whose name is \"{s}\"",
        .{escaped_title},
    );
    defer allocator.free(line3);
    const line4 = try allocator.dupe(u8, "end tell");
    defer allocator.free(line4);
    try runAppleScriptExpectOk(allocator, &.{ line1, line2, line3, line4 });
}

fn typeText(allocator: std.mem.Allocator, text: []const u8) !void {
    const script = try buildTypeTextScript(allocator, text);
    defer allocator.free(script);

    const applied_value = try runAppleScriptExpectString(allocator, &.{script});
    defer allocator.free(applied_value);
    if (!std.mem.eql(u8, std.mem.trim(u8, applied_value, " \t\r\n"), text)) {
        return error.ActionVerificationFailed;
    }
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

fn runAppleScriptExpectString(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var result = try runAppleScript(allocator, lines);
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.CommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
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

fn runLinuxHelper(allocator: std.mem.Allocator, request_json: []const u8) ![]u8 {
    const timestamp = std.time.milliTimestamp();
    const helper_path = try std.fmt.allocPrint(allocator, "/tmp/spiderweb-computer-linux-{d}.py", .{timestamp});
    defer allocator.free(helper_path);
    const request_path = try std.fmt.allocPrint(allocator, "/tmp/spiderweb-computer-linux-{d}.json", .{timestamp});
    defer allocator.free(request_path);

    try writeFileAbsoluteCompat(helper_path, linux_helper_source);
    defer std.fs.deleteFileAbsolute(helper_path) catch {};
    try writeFileAbsoluteCompat(request_path, request_json);
    defer std.fs.deleteFileAbsolute(request_path) catch {};

    var result = try runCommand(allocator, &.{ "python3", helper_path, request_path });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.CommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
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

fn buildTypeTextScript(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const escaped = try appleScriptEscape(allocator, text);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(
        allocator,
        "tell application \"System Events\"\n" ++
            "set targetProc to first application process whose frontmost is true\n" ++
            "if (count of windows of targetProc) is 0 then error number -1728\n" ++
            "if (count of text fields of first window of targetProc) is 0 then error number -1728\n" ++
            "set targetField to first text field of first window of targetProc\n" ++
            "try\n" ++
            "set focused of targetField to true\n" ++
            "end try\n" ++
            "try\n" ++
            "click targetField\n" ++
            "end try\n" ++
            "delay 0.1\n" ++
            "try\n" ++
            "set value of targetField to \"{s}\"\n" ++
            "delay 0.1\n" ++
            "set fieldValue to value of targetField as text\n" ++
            "on error\n" ++
            "set fieldValue to \"\"\n" ++
            "end try\n" ++
            "if fieldValue is not \"{s}\" then\n" ++
            "try\n" ++
            "keystroke \"a\" using command down\n" ++
            "delay 0.05\n" ++
            "key code 51\n" ++
            "delay 0.05\n" ++
            "end try\n" ++
            "keystroke \"{s}\"\n" ++
            "delay 0.1\n" ++
            "try\n" ++
            "set fieldValue to value of targetField as text\n" ++
            "on error\n" ++
            "set fieldValue to \"\"\n" ++
            "end try\n" ++
            "end if\n" ++
            "return fieldValue\n" ++
            "end tell",
        .{ escaped, escaped, escaped },
    );
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

fn writeFileAbsoluteCompat(path: []const u8, contents: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn uiScriptingAvailable(allocator: std.mem.Allocator) bool {
    if (builtin.os.tag != .macos) return false;
    var result = runAppleScript(allocator, &.{
        "tell application \"System Events\"",
        "count of application processes",
        "end tell",
    }) catch return false;
    defer result.deinit(allocator);
    return result.exit_code == 0;
}

fn fatal(msg: []const u8) noreturn {
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(2);
}

test "computer_driver: parse act payload requires action-specific fields" {
    const allocator = std.testing.allocator;

    var valid = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"op\":\"act\",\"arguments\":{\"action\":\"primary_tap\",\"button_title\":\"Press Fixture Button\"}}",
        .{},
    );
    defer valid.deinit();
    var parsed = try parseActArgs(allocator, valid.value.object);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(Action.primary_tap, parsed.action);
    try std.testing.expectEqualStrings("Press Fixture Button", parsed.button_title.?);

    var invalid = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"op\":\"act\",\"arguments\":{\"action\":\"primary_tap\"}}",
        .{},
    );
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidPayload, parseActArgs(allocator, invalid.value.object));
}

test "computer_driver: parse observe payload honors include_screenshot" {
    const allocator = std.testing.allocator;
    _ = allocator;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"op\":\"observe\",\"arguments\":{\"include_screenshot\":false}}",
        .{},
    );
    defer parsed.deinit();
    const args = try parseObserveArgs(std.testing.allocator, parsed.value.object);
    try std.testing.expect(!args.include_screenshot);
}

test "computer_driver: status and health report readiness guidance" {
    const allocator = std.testing.allocator;

    const degraded_status = try renderComputerStatusJson(allocator, .{
        .accessibility = false,
        .screen_capture_checked = true,
        .screen_capture = false,
    });
    defer allocator.free(degraded_status);
    try std.testing.expect(std.mem.indexOf(u8, degraded_status, "\"readiness_state\":\"accessibility_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, degraded_status, "\"guidance\":\"Enable Accessibility") != null);

    const ready_health = try renderComputerHealthJson(allocator, .{
        .accessibility = true,
        .screen_capture_checked = false,
        .screen_capture = false,
    });
    defer allocator.free(ready_health);
    try std.testing.expect(std.mem.indexOf(u8, ready_health, "\"state\":\"online\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_health, "\"screenshot_ready\":false") != null);
}

test "computer_driver: type text script prefers direct text field set" {
    const allocator = std.testing.allocator;
    const script = try buildTypeTextScript(allocator, "Hello from hardening");
    defer allocator.free(script);

    try std.testing.expect(std.mem.indexOf(u8, script, "set targetField to first text field of first window of targetProc") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "set value of targetField to \"Hello from hardening\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "click targetField") != null);
    try std.testing.expect(std.mem.count(u8, script, "keystroke \"Hello from hardening\"") == 1);
}

test "computer_driver: linux helper encodes observation and action responses" {
    try std.testing.expect(std.mem.indexOf(u8, linux_helper_source, "\"venom_id\": \"computer-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux_helper_source, "\"platform\": \"linux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux_helper_source, "\"path\": \"artifacts/last_observation.json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, linux_helper_source, "python3-pyatspi") != null);
}
