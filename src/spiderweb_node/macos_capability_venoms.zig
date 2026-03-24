const std = @import("std");

pub const computer_package_id = "computer";
pub const computer_venom_id = "computer-main";
pub const browser_package_id = "browser";
pub const browser_venom_id = "browser-main";

pub const computer_driver_binary_name = "spiderweb-computer-driver";
pub const browser_driver_binary_name = "spiderweb-browser-driver";

pub const computer_readme_md =
    "macOS desktop automation driver.\n" ++
    "Write JSON payloads to control/invoke.json with op observe or act.\n" ++
    "Observation artifacts are refreshed under artifacts/.\n";
pub const browser_readme_md =
    "macOS browser automation driver.\n" ++
    "Write JSON payloads to control/invoke.json with op observe or act.\n" ++
    "Observation artifacts are refreshed under artifacts/.\n";

pub const computer_schema_json =
    "{\"model\":\"computer-observe-act-v1\",\"control\":{\"invoke\":\"control/invoke.json\"},\"result\":\"result.json\",\"status\":\"status.json\",\"health\":\"health.json\",\"artifacts\":{\"observation\":\"artifacts/last_observation.json\",\"screenshot\":\"artifacts/last_screenshot.png\"},\"ops\":{\"observe\":{\"arguments\":{\"include_screenshot\":\"bool (optional)\"}},\"act\":{\"arguments\":{\"action\":\"focus_window|activate|primary_tap|text_input|key_combo\",\"app_name\":\"string (required for activate/focus_window)\",\"window_title\":\"string (required for focus_window)\",\"button_title\":\"string (required for primary_tap)\",\"text\":\"string (required for text_input)\",\"key\":\"string (required for key_combo)\",\"modifiers\":\"string[] (optional for key_combo)\"}}}}";
pub const browser_schema_json =
    "{\"model\":\"browser-observe-act-v1\",\"control\":{\"invoke\":\"control/invoke.json\"},\"result\":\"result.json\",\"status\":\"status.json\",\"health\":\"health.json\",\"artifacts\":{\"observation\":\"artifacts/last_observation.json\",\"screenshot\":\"artifacts/last_screenshot.png\",\"dom\":\"artifacts/last_dom.json\"},\"ops\":{\"observe\":{\"arguments\":{\"include_dom\":\"bool (optional)\",\"include_screenshot\":\"bool (optional)\"}},\"act\":{\"arguments\":{\"action\":\"navigate|activate_tab|click|text_input|key_combo\",\"url\":\"string (required for navigate)\",\"tab_index\":\"number (required for activate_tab)\",\"selector\":\"string (required for click/text_input)\",\"text\":\"string (required for text_input)\",\"key\":\"string (required for key_combo)\",\"modifiers\":\"string[] (optional for key_combo)\"}}}}";

pub const computer_invoke_template_json =
    "{\"op\":\"observe\",\"arguments\":{\"include_screenshot\":true}}";
pub const browser_invoke_template_json =
    "{\"op\":\"observe\",\"arguments\":{\"include_dom\":true,\"include_screenshot\":true}}";

const computer_capabilities_json =
    "{\"invoke\":true,\"discoverable\":true,\"observe\":true,\"act\":true,\"operations\":[\"observe\",\"act\"],\"device\":\"desktop\"}";
const browser_capabilities_json =
    "{\"invoke\":true,\"discoverable\":true,\"observe\":true,\"act\":true,\"operations\":[\"observe\",\"act\"],\"device\":\"browser\"}";
const computer_categories_json = "[\"desktop\",\"automation\",\"macos\"]";
const browser_categories_json = "[\"browser\",\"automation\",\"macos\"]";
const computer_requirements_json =
    "{\"host_capabilities\":[\"macos_accessibility\",\"screen_capture\"]}";
const browser_requirements_json =
    "{\"host_capabilities\":[\"managed_browser\"]}";
const permissions_json =
    "{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"scope\":\"workspace\",\"requires_user_consent\":true,\"platform\":\"macos\"}";

pub fn renderComputerManifestJson(allocator: std.mem.Allocator, executable_path: []const u8) ![]u8 {
    return renderManifestJson(
        allocator,
        .{
            .package_id = computer_package_id,
            .venom_id = computer_venom_id,
            .kind = "computer",
            .categories_json = computer_categories_json,
            .requirements_json = computer_requirements_json,
            .capabilities_json = computer_capabilities_json,
            .schema_json = computer_schema_json,
            .invoke_template_json = computer_invoke_template_json,
            .help_md = computer_readme_md,
        },
        executable_path,
    );
}

pub fn renderBrowserManifestJson(allocator: std.mem.Allocator, executable_path: []const u8) ![]u8 {
    return renderManifestJson(
        allocator,
        .{
            .package_id = browser_package_id,
            .venom_id = browser_venom_id,
            .kind = "browser",
            .categories_json = browser_categories_json,
            .requirements_json = browser_requirements_json,
            .capabilities_json = browser_capabilities_json,
            .schema_json = browser_schema_json,
            .invoke_template_json = browser_invoke_template_json,
            .help_md = browser_readme_md,
        },
        executable_path,
    );
}

pub fn isComputerVenomId(venom_id: []const u8) bool {
    return std.mem.eql(u8, venom_id, computer_package_id) or
        std.mem.eql(u8, venom_id, computer_venom_id);
}

pub fn isBrowserVenomId(venom_id: []const u8) bool {
    return std.mem.eql(u8, venom_id, browser_package_id) or
        std.mem.eql(u8, venom_id, browser_venom_id);
}

pub fn requiresBrowserArtifacts(venom_id: []const u8) bool {
    return isBrowserVenomId(venom_id);
}

pub fn requiresComputerArtifacts(venom_id: []const u8) bool {
    return isComputerVenomId(venom_id);
}

const ManifestRenderSpec = struct {
    package_id: []const u8,
    venom_id: []const u8,
    kind: []const u8,
    categories_json: []const u8,
    requirements_json: []const u8,
    capabilities_json: []const u8,
    schema_json: []const u8,
    invoke_template_json: []const u8,
    help_md: []const u8,
};

fn renderManifestJson(
    allocator: std.mem.Allocator,
    spec: ManifestRenderSpec,
    executable_path: []const u8,
) ![]u8 {
    const escaped_exec = try jsonEscape(allocator, executable_path);
    defer allocator.free(escaped_exec);
    const escaped_help = try jsonEscape(allocator, spec.help_md);
    defer allocator.free(escaped_help);

    return std.fmt.allocPrint(
        allocator,
        "{{\"venom_id\":\"{s}\",\"package_id\":\"{s}\",\"kind\":\"{s}\",\"version\":\"1\",\"enabled\":true,\"state\":\"online\",\"categories\":{s},\"host_roles\":[\"node\"],\"binding_scopes\":[\"workspace\"],\"runtime_kind\":\"native\",\"requirements\":{s},\"endpoints\":[\"/nodes/{{node_id}}/venoms/{s}\"],\"mounts\":[{{\"mount_id\":\"{s}\",\"mount_path\":\"/nodes/{{node_id}}/venoms/{s}\",\"state\":\"online\"}}],\"capabilities\":{s},\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/invoke.json\",\"paths\":{{\"invoke\":\"control/invoke.json\"}}}},\"runtime\":{{\"type\":\"native_proc\",\"abi\":\"namespace-driver-v1\",\"executable_path\":\"{s}\",\"timeout_ms\":60000}},\"permissions\":{s},\"schema\":{s},\"invoke_template\":{s},\"help_md\":\"{s}\"}}",
        .{
            spec.venom_id,
            spec.package_id,
            spec.kind,
            spec.categories_json,
            spec.requirements_json,
            spec.venom_id,
            spec.venom_id,
            spec.venom_id,
            spec.capabilities_json,
            escaped_exec,
            permissions_json,
            spec.schema_json,
            spec.invoke_template_json,
            escaped_help,
        },
    );
}

fn jsonEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
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

test "macos capability venoms: render computer and browser manifests" {
    const allocator = std.testing.allocator;

    const computer_manifest = try renderComputerManifestJson(allocator, "./spiderweb-computer-driver");
    defer allocator.free(computer_manifest);
    try std.testing.expect(std.mem.indexOf(u8, computer_manifest, "\"venom_id\":\"computer-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, computer_manifest, "\"package_id\":\"computer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, computer_manifest, "\"runtime_kind\":\"native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, computer_manifest, "\"binding_scopes\":[\"workspace\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, computer_manifest, "\"executable_path\":\"./spiderweb-computer-driver\"") != null);

    const browser_manifest = try renderBrowserManifestJson(allocator, "./spiderweb-browser-driver");
    defer allocator.free(browser_manifest);
    try std.testing.expect(std.mem.indexOf(u8, browser_manifest, "\"venom_id\":\"browser-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_manifest, "\"package_id\":\"browser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_manifest, "\"kind\":\"browser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser_manifest, "\"model\":\"browser-observe-act-v1\"") != null);
}

