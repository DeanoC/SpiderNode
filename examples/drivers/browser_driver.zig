const std = @import("std");
const builtin = @import("builtin");
const capability = @import("spiderweb_node").macos_capability_venoms;

const max_payload_bytes: usize = 1024 * 1024;
const max_capture_bytes: usize = 512 * 1024;
const screenshot_resize_px: []const u8 = "720";
const browser_state_path_env_var = capability.browser_state_path_env_var;
const browser_profile_dir_env_var = capability.browser_profile_dir_env_var;
const runtime_platform_label = capability.currentPlatformLabel();
const playwright_helper_source =
    \\const fs = require("fs");
    \\const os = require("os");
    \\const path = require("path");
    \\const cp = require("child_process");
    \\
    \\function loadPlaywright() {
    \\  try {
    \\    return { playwright: require("playwright"), source: "local_require" };
    \\  } catch (_) {}
    \\  try {
    \\    const npmRoot = cp.execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
    \\    if (npmRoot) return { playwright: require(path.join(npmRoot, "playwright")), source: "npm_global" };
    \\  } catch (_) {}
    \\  return null;
    \\}
    \\
    \\function readState(statePath) {
    \\  try {
    \\    return JSON.parse(fs.readFileSync(statePath, "utf8"));
    \\  } catch (_) {
    \\    return {
    \\      current_url: null,
    \\      active_tab_index: 1,
    \\      inputs: {},
    \\      last_click_selector: null
    \\    };
    \\  }
    \\}
    \\
    \\function writeState(statePath, state) {
    \\  fs.mkdirSync(path.dirname(statePath), { recursive: true });
    \\  fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
    \\}
    \\
    \\function guidanceFor(reason) {
    \\  switch (reason) {
    \\    case "playwright_missing":
    \\      return "Install Playwright so the node can launch managed Chromium for the browser venom.";
    \\    case "browser_launch_failed":
    \\      return "Check the browser profile directory permissions and whether Playwright Chromium can launch on this host.";
    \\    case "playwright_runtime_failed":
    \\      return "Inspect the browser venom detail and the helper stderr, then retry the operation.";
    \\    default:
    \\      return "Inspect the browser venom detail and retry the operation.";
    \\  }
    \\}
    \\
    \\function statusForReady(statePath, profileDir, playwrightSource) {
    \\  return {
    \\    state: "ok",
    \\    readiness_state: "ready",
    \\    browser_ready: true,
    \\    browser_app: "Playwright Chromium",
    \\    driver: "playwright",
    \\    playwright_available: true,
    \\    playwright_source: playwrightSource,
    \\    state_path: statePath,
    \\    profile_dir: profileDir
    \\  };
    \\}
    \\
    \\function healthForReady(statePath, profileDir, playwrightSource) {
    \\  return {
    \\    state: "online",
    \\    platform: "__PLATFORM__",
    \\    readiness_state: "ready",
    \\    browser_ready: true,
    \\    browser_app: "Playwright Chromium",
    \\    driver: "playwright",
    \\    playwright_available: true,
    \\    playwright_source: playwrightSource,
    \\    state_path: statePath,
    \\    profile_dir: profileDir
    \\  };
    \\}
    \\
    \\function degraded(reason, detail, statePath, profileDir, playwrightSource) {
    \\  return {
    \\    ok: true,
    \\    venom_id: "browser-main",
    \\    op: "observe",
    \\    observation: {
    \\      ready: false,
    \\      browser_app: null,
    \\      current_url: null,
    \\      current_title: null,
    \\      tabs: [],
    \\      readiness_state: reason,
    \\      driver: "playwright",
    \\      state_path: statePath,
    \\      profile_dir: profileDir
    \\    },
    \\    status: {
    \\      state: "degraded",
    \\      readiness_state: reason,
    \\      browser_ready: false,
    \\      reason,
    \\      detail,
    \\      guidance: guidanceFor(reason),
    \\      driver: "playwright",
    \\      playwright_available: reason !== "playwright_missing",
    \\      playwright_source: playwrightSource,
    \\      state_path: statePath,
    \\      profile_dir: profileDir
    \\    },
    \\    health: {
    \\      state: "degraded",
    \\      platform: "__PLATFORM__",
    \\      readiness_state: reason,
    \\      browser_ready: false,
    \\      reason,
    \\      detail,
    \\      guidance: guidanceFor(reason),
    \\      driver: "playwright",
    \\      playwright_available: reason !== "playwright_missing",
    \\      playwright_source: playwrightSource,
    \\      state_path: statePath,
    \\      profile_dir: profileDir
    \\    },
    \\    artifact_updates: [
    \\      { path: "artifacts/last_observation.json", content: JSON.stringify({ ready: false, reason, detail, driver: "playwright", state_path: statePath, profile_dir: profileDir }) },
    \\      { path: "artifacts/last_dom.json", content: "{}" }
    \\    ]
    \\  };
    \\}
    \\
    \\async function ensurePage(context) {
    \\  const pages = context.pages();
    \\  if (pages.length > 0) return pages[0];
    \\  return await context.newPage();
    \\}
    \\
    \\async function restoreInputs(page, state) {
    \\  const inputs = state.inputs || {};
    \\  for (const [selector, value] of Object.entries(inputs)) {
    \\    try {
    \\      await page.locator(selector).fill(String(value));
    \\    } catch (_) {}
    \\  }
    \\}
    \\
    \\async function replayClick(page, state) {
    \\  if (!state.last_click_selector) return;
    \\  try {
    \\    await page.locator(state.last_click_selector).click();
    \\  } catch (_) {}
    \\}
    \\
    \\async function snapshotObservation(page) {
    \\  let title = "";
    \\  try { title = await page.title(); } catch (_) {}
    \\  let url = "";
    \\  try { url = page.url(); } catch (_) {}
    \\  return {
    \\    ready: true,
    \\    browser_app: "Playwright Chromium",
    \\    current_url: url,
    \\    current_title: title,
    \\    tabs: [{ index: 1, title, url }],
    \\    readiness_state: "ready"
    \\  };
    \\}
    \\
    \\function keyCombo(action) {
    \\  const mapping = { command: "Meta", option: "Alt", shift: "Shift", control: "Control" };
    \\  const modifiers = (action.modifiers || []).map((value) => mapping[value] || value);
    \\  return [...modifiers, action.key].join("+");
    \\}
    \\
    \\async function run() {
    \\  const requestPath = process.argv[2];
    \\  const request = JSON.parse(fs.readFileSync(requestPath, "utf8"));
    \\  const statePath = process.env.SPIDERWEB_BROWSER_STATE_PATH || path.join(os.tmpdir(), "spiderweb-browser-playwright-state.json");
    \\  const profileDir = process.env.SPIDERWEB_BROWSER_PROFILE_DIR || path.join(os.tmpdir(), "spiderweb-browser-playwright-profile");
    \\  const state = readState(statePath);
    \\  const playwrightBundle = loadPlaywright();
    \\  const playwright = playwrightBundle && playwrightBundle.playwright;
    \\  const playwrightSource = playwrightBundle ? playwrightBundle.source : "missing";
    \\  if (!playwright || !playwright.chromium) {
    \\    process.stdout.write(JSON.stringify(degraded("playwright_missing", "Playwright is not available to the browser venom driver", statePath, profileDir, playwrightSource)));
    \\    return;
    \\  }
    \\
    \\  let context;
    \\  try {
    \\    const launchOptions = {
    \\      headless: false,
    \\      viewport: { width: 1280, height: 900 }
    \\    };
    \\    if (process.platform === "linux") {
    \\      launchOptions.args = ["--no-sandbox"];
    \\    }
    \\    context = await playwright.chromium.launchPersistentContext(profileDir, launchOptions);
    \\  } catch (error) {
    \\    process.stdout.write(JSON.stringify(degraded("browser_launch_failed", String(error && error.message || error), statePath, profileDir, playwrightSource)));
    \\    return;
    \\  }
    \\
    \\  try {
    \\    const page = await ensurePage(context);
    \\    if (state.current_url) {
    \\      try {
    \\        await page.goto(state.current_url, { waitUntil: "domcontentloaded", timeout: 15000 });
    \\      } catch (_) {}
    \\    }
    \\    await restoreInputs(page, state);
    \\
    \\    if (request.op === "observe") {
    \\      await replayClick(page, state);
    \\      const observation = await snapshotObservation(page);
    \\      state.current_url = observation.current_url || state.current_url || null;
    \\      const includeDom = !request.arguments || request.arguments.include_dom !== false;
    \\      const includeScreenshot = !!(request.arguments && request.arguments.include_screenshot);
    \\      const dom = includeDom
    \\        ? {
    \\            title: observation.current_title,
    \\            url: observation.current_url,
    \\            html: (await page.content()).slice(0, 200000)
    \\          }
    \\        : {};
    \\      const artifactUpdates = [
    \\        { path: "artifacts/last_observation.json", content: JSON.stringify(observation) },
    \\        { path: "artifacts/last_dom.json", content: JSON.stringify(dom) }
    \\      ];
    \\      if (includeScreenshot) {
    \\        const screenshot = await page.screenshot({ type: "png" });
    \\        artifactUpdates.push({
    \\          path: "artifacts/last_screenshot.png",
    \\          content_b64: screenshot.toString("base64")
    \\        });
    \\      }
    \\      process.stdout.write(JSON.stringify({
    \\        ok: true,
    \\        venom_id: "browser-main",
    \\        op: "observe",
    \\        observation,
    \\        status: statusForReady(statePath, profileDir, playwrightSource),
    \\        health: healthForReady(statePath, profileDir, playwrightSource),
    \\        artifact_updates: artifactUpdates
    \\      }));
    \\      return;
    \\    }
    \\
    \\    if (request.op !== "act") {
    \\      process.stdout.write(JSON.stringify(degraded("invalid_op", `Unsupported op: ${request.op}`, statePath, profileDir, playwrightSource)));
    \\      return;
    \\    }
    \\
    \\    const action = request.arguments || {};
    \\    let actionResult = { ok: true, action: action.action || null };
    \\    try {
    \\      switch (action.action) {
    \\        case "navigate":
    \\          await page.goto(action.url, { waitUntil: "domcontentloaded", timeout: 15000 });
    \\          state.current_url = page.url();
    \\          state.inputs = {};
    \\          state.last_click_selector = null;
    \\          break;
    \\        case "activate_tab":
    \\          if ((action.tab_index || 1) !== 1) throw new Error("tab_unavailable");
    \\          await page.bringToFront();
    \\          state.active_tab_index = 1;
    \\          break;
    \\        case "click":
    \\          await page.locator(action.selector).click();
    \\          state.last_click_selector = action.selector;
    \\          break;
    \\        case "text_input":
    \\          await page.locator(action.selector).fill(action.text);
    \\          state.inputs = state.inputs || {};
    \\          state.inputs[action.selector] = action.text;
    \\          break;
    \\        case "key_combo":
    \\          await page.keyboard.press(keyCombo(action));
    \\          break;
    \\        default:
    \\          throw new Error(`unsupported_action:${action.action}`);
    \\      }
    \\    } catch (error) {
    \\      actionResult = {
    \\        ok: false,
    \\        action: action.action || null,
    \\        reason: "playwright_action_failed",
    \\        detail: String(error && error.message || error)
    \\      };
    \\    }
    \\
    \\    const observation = await snapshotObservation(page);
    \\    if (observation.current_url) state.current_url = observation.current_url;
    \\    process.stdout.write(JSON.stringify({
    \\      ok: true,
    \\      venom_id: "browser-main",
    \\      op: "act",
    \\      action_result: actionResult,
    \\      observation,
    \\      status: statusForReady(statePath, profileDir, playwrightSource),
    \\      health: healthForReady(statePath, profileDir, playwrightSource)
    \\    }));
    \\  } finally {
    \\    writeState(statePath, state);
    \\    await context.close().catch(() => {});
    \\  }
    \\}
    \\
    \\run().catch((error) => {
    \\  const statePath = process.env.SPIDERWEB_BROWSER_STATE_PATH || path.join(os.tmpdir(), "spiderweb-browser-playwright-state.json");
    \\  const profileDir = process.env.SPIDERWEB_BROWSER_PROFILE_DIR || path.join(os.tmpdir(), "spiderweb-browser-playwright-profile");
    \\  const response = degraded("playwright_runtime_failed", String(error && error.stack || error && error.message || error), statePath, profileDir, "unknown");
    \\  process.stdout.write(JSON.stringify(response));
    \\});
;

const BrowserApp = struct {
    app_name: []const u8,
    app_path: []const u8,
};

const known_browsers = [_]BrowserApp{
    .{ .app_name = "Google Chrome", .app_path = "/Applications/Google Chrome.app" },
    .{ .app_name = "Chromium", .app_path = "/Applications/Chromium.app" },
    .{ .app_name = "Brave Browser", .app_path = "/Applications/Brave Browser.app" },
};

const Action = enum {
    navigate,
    activate_tab,
    click,
    text_input,
    key_combo,
};

const ObserveArgs = struct {
    include_dom: bool = true,
    include_screenshot: bool = true,
};

const ActArgs = struct {
    action: Action,
    url: ?[]u8 = null,
    selector: ?[]u8 = null,
    text: ?[]u8 = null,
    key: ?[]u8 = null,
    tab_index: ?usize = null,
    modifiers: std.ArrayListUnmanaged([]u8) = .{},

    fn deinit(self: *ActArgs, allocator: std.mem.Allocator) void {
        if (self.url) |value| allocator.free(value);
        if (self.selector) |value| allocator.free(value);
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
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) {
        const rendered = try std.fmt.allocPrint(
            allocator,
            "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"{s}\",\"status\":{{\"state\":\"offline\",\"reason\":\"unsupported_platform\"}},\"health\":{{\"state\":\"offline\",\"platform\":\"{s}\"}},\"artifact_updates\":[{{\"path\":\"artifacts/last_observation.json\",\"content\":\"{{\\\"platform\\\":\\\"{s}\\\",\\\"supported\\\":false}}\"}},{{\"path\":\"artifacts/last_dom.json\",\"content\":\"{{}}\"}}]}}",
            .{ capability.browser_venom_id, op, @tagName(builtin.os.tag), @tagName(builtin.os.tag) },
        );
        defer allocator.free(rendered);
        try std.fs.File.stdout().writeAll(rendered);
        return;
    }

    if (std.mem.eql(u8, op, "observe")) {
        _ = try parseObserveArgs(parsed.value.object);
        const rendered = try runPlaywrightDriver(allocator, trimmed);
        defer allocator.free(rendered);
        try std.fs.File.stdout().writeAll(rendered);
        return;
    }
    if (std.mem.eql(u8, op, "act")) {
        var args = try parseActArgs(allocator, parsed.value.object);
        defer args.deinit(allocator);
        const rendered = try runPlaywrightDriver(allocator, trimmed);
        defer allocator.free(rendered);
        try std.fs.File.stdout().writeAll(rendered);
        return;
    }

    fatal("invalid_payload: unsupported op");
}

fn performObserve(allocator: std.mem.Allocator, args: ObserveArgs) ![]u8 {
    const browser = resolveBrowserApp() orelse {
        return std.fmt.allocPrint(
            allocator,
            "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"observe\",\"observation\":{{\"ready\":false,\"browser_app\":null,\"tabs\":[]}},\"status\":{{\"state\":\"degraded\",\"reason\":\"browser_missing\"}},\"health\":{{\"state\":\"degraded\",\"platform\":\"macos\",\"browser_ready\":false}},\"artifact_updates\":[{{\"path\":\"artifacts/last_observation.json\",\"content\":\"{{\\\"ready\\\":false,\\\"browser_app\\\":null,\\\"tabs\\\":[]}}\"}},{{\"path\":\"artifacts/last_dom.json\",\"content\":\"{{}}\"}}]}}",
            .{capability.browser_venom_id},
        );
    };

    const observation_json = try collectObservationJson(allocator, browser.app_name);
    defer allocator.free(observation_json);
    const dom_json = if (args.include_dom)
        try collectDomJson(allocator, browser.app_name)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(dom_json);

    var updates = std.ArrayListUnmanaged(ArtifactUpdate){};
    defer updates.deinit(allocator);
    try updates.append(allocator, .{
        .path = "artifacts/last_observation.json",
        .content = try allocator.dupe(u8, observation_json),
    });
    try updates.append(allocator, .{
        .path = "artifacts/last_dom.json",
        .content = try allocator.dupe(u8, dom_json),
    });

    var screen_capture = false;
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

    const artifacts_json = try renderArtifactUpdatesJson(allocator, updates.items);
    defer allocator.free(artifacts_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"observe\",\"observation\":{s},\"status\":{{\"state\":\"ok\",\"browser_ready\":true,\"browser_app\":\"{s}\"}},\"health\":{{\"state\":\"online\",\"platform\":\"macos\",\"browser_ready\":true,\"browser_app\":\"{s}\",\"screen_capture\":{}}},\"artifact_updates\":{s}}}",
        .{
            capability.browser_venom_id,
            observation_json,
            browser.app_name,
            browser.app_name,
            screen_capture,
            artifacts_json,
        },
    );
}

fn performAct(allocator: std.mem.Allocator, args: *ActArgs) ![]u8 {
    const browser = resolveBrowserApp() orelse {
        return std.fmt.allocPrint(
            allocator,
            "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"act\",\"action_result\":{{\"ok\":false,\"reason\":\"browser_missing\",\"action\":\"{s}\"}},\"status\":{{\"state\":\"degraded\",\"reason\":\"browser_missing\"}},\"health\":{{\"state\":\"degraded\",\"platform\":\"macos\",\"browser_ready\":false}}}}",
            .{ capability.browser_venom_id, @tagName(args.action) },
        );
    };

    switch (args.action) {
        .navigate => try navigateBrowser(allocator, browser.app_name, args.url.?),
        .activate_tab => try activateBrowserTab(allocator, browser.app_name, args.tab_index.?),
        .click => {
            const selector_json = try quotedJsString(allocator, args.selector.?);
            defer allocator.free(selector_json);
            const js_source = try std.fmt.allocPrint(
                allocator,
                "(function(){{var el=document.querySelector({s}); if(!el) throw new Error('selector_missing'); el.click(); return JSON.stringify({{ok:true}});}})()",
                .{selector_json},
            );
            defer allocator.free(js_source);
            const result = try browserExecJs(allocator, browser.app_name, js_source);
            defer allocator.free(result);
        },
        .text_input => {
            const selector_json = try quotedJsString(allocator, args.selector.?);
            defer allocator.free(selector_json);
            const text_json = try quotedJsString(allocator, args.text.?);
            defer allocator.free(text_json);
            const js_source = try std.fmt.allocPrint(
                allocator,
                "(function(){{var el=document.querySelector({s}); if(!el) throw new Error('selector_missing'); el.focus(); el.value={s}; el.dispatchEvent(new Event('input',{{bubbles:true}})); el.dispatchEvent(new Event('change',{{bubbles:true}})); return JSON.stringify({{ok:true,value:el.value}});}})()",
                .{ selector_json, text_json },
            );
            defer allocator.free(js_source);
            const result = try browserExecJs(allocator, browser.app_name, js_source);
            defer allocator.free(result);
        },
        .key_combo => try sendBrowserKeyCombo(allocator, browser.app_name, args.key.?, args.modifiers.items),
    }

    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"venom_id\":\"{s}\",\"op\":\"act\",\"action_result\":{{\"ok\":true,\"action\":\"{s}\"}},\"status\":{{\"state\":\"ok\",\"browser_ready\":true,\"browser_app\":\"{s}\"}},\"health\":{{\"state\":\"online\",\"platform\":\"macos\",\"browser_ready\":true,\"browser_app\":\"{s}\"}}}}",
        .{ capability.browser_venom_id, @tagName(args.action), browser.app_name, browser.app_name },
    );
}

fn parseObserveArgs(obj: std.json.ObjectMap) !ObserveArgs {
    var result = ObserveArgs{};
    if (obj.get("arguments")) |value| {
        if (value != .object) return error.InvalidPayload;
        if (value.object.get("include_dom")) |raw| {
            if (raw != .bool) return error.InvalidPayload;
            result.include_dom = raw.bool;
        }
        if (value.object.get("include_screenshot")) |raw| {
            if (raw != .bool) return error.InvalidPayload;
            result.include_screenshot = raw.bool;
        }
    }
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

    if (arguments.object.get("url")) |value| result.url = try dupRequiredNonEmptyString(allocator, value);
    if (arguments.object.get("selector")) |value| result.selector = try dupRequiredNonEmptyString(allocator, value);
    if (arguments.object.get("text")) |value| result.text = try dupRequiredNonEmptyString(allocator, value);
    if (arguments.object.get("key")) |value| result.key = try dupRequiredNonEmptyString(allocator, value);
    if (arguments.object.get("tab_index")) |value| {
        if (value != .integer or value.integer < 1) return error.InvalidPayload;
        result.tab_index = @intCast(value.integer);
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
        .navigate => if (result.url == null) return error.InvalidPayload,
        .activate_tab => if (result.tab_index == null) return error.InvalidPayload,
        .click => if (result.selector == null) return error.InvalidPayload,
        .text_input => if (result.selector == null or result.text == null) return error.InvalidPayload,
        .key_combo => if (result.key == null) return error.InvalidPayload,
    }
    return result;
}

fn resolveBrowserApp() ?BrowserApp {
    for (known_browsers) |browser| {
        std.fs.accessAbsolute(browser.app_path, .{}) catch continue;
        return browser;
    }
    return null;
}

fn runPlaywrightDriver(allocator: std.mem.Allocator, request_json: []const u8) ![]u8 {
    const timestamp = std.time.milliTimestamp();
    const helper_path = try std.fmt.allocPrint(allocator, "/tmp/spiderweb-browser-playwright-{d}.js", .{timestamp});
    defer allocator.free(helper_path);
    const request_path = try std.fmt.allocPrint(allocator, "/tmp/spiderweb-browser-playwright-{d}.json", .{timestamp});
    defer allocator.free(request_path);
    const rendered_helper_source = try std.mem.replaceOwned(
        u8,
        allocator,
        playwright_helper_source,
        "__PLATFORM__",
        runtime_platform_label,
    );
    defer allocator.free(rendered_helper_source);

    try writeFileAbsoluteCompat(helper_path, rendered_helper_source);
    defer std.fs.deleteFileAbsolute(helper_path) catch {};
    try writeFileAbsoluteCompat(request_path, request_json);
    defer std.fs.deleteFileAbsolute(request_path) catch {};

    var result = try runCommand(allocator, &.{ "node", helper_path, request_path });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.CommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
}

fn collectObservationJson(allocator: std.mem.Allocator, app_name: []const u8) ![]u8 {
    const app_json = try quotedJsString(allocator, app_name);
    defer allocator.free(app_json);
    const script = try std.fmt.allocPrint(
        allocator,
        "function run() {{ var app = Application({s}); var result = {{ ready: app.running(), browser_app: {s}, current_url: null, current_title: null, tabs: [] }}; if (app.running() && app.windows.length > 0) {{ var win = app.windows[0]; var tabs = win.tabs(); for (var i = 0; i < tabs.length; i++) result.tabs.push({{ index: i + 1, title: tabs[i].title(), url: tabs[i].url() }}); var active = win.activeTab(); result.current_url = active.url(); result.current_title = active.title(); }} return JSON.stringify(result); }}",
        .{ app_json, app_json },
    );
    defer allocator.free(script);
    return runOsascriptJavaScript(allocator, script);
}

fn collectDomJson(allocator: std.mem.Allocator, app_name: []const u8) ![]u8 {
    return browserExecJs(
        allocator,
        app_name,
        "(function(){ return JSON.stringify({ title: document.title, url: location.href, html: document.documentElement.outerHTML.slice(0, 200000) }); })()",
    );
}

fn navigateBrowser(allocator: std.mem.Allocator, app_name: []const u8, url: []const u8) !void {
    const escaped_app = try appleScriptEscape(allocator, app_name);
    defer allocator.free(escaped_app);
    const escaped_url = try appleScriptEscape(allocator, url);
    defer allocator.free(escaped_url);
    const line1 = try std.fmt.allocPrint(allocator, "tell application \"{s}\" to activate", .{escaped_app});
    defer allocator.free(line1);
    const line2 = try std.fmt.allocPrint(allocator, "tell application \"{s}\" to set URL of active tab of front window to \"{s}\"", .{ escaped_app, escaped_url });
    defer allocator.free(line2);
    try runAppleScriptExpectOk(allocator, &.{ line1, line2 });
}

fn activateBrowserTab(allocator: std.mem.Allocator, app_name: []const u8, tab_index: usize) !void {
    const escaped_app = try appleScriptEscape(allocator, app_name);
    defer allocator.free(escaped_app);
    const line1 = try std.fmt.allocPrint(allocator, "tell application \"{s}\" to activate", .{escaped_app});
    defer allocator.free(line1);
    const line2 = try std.fmt.allocPrint(allocator, "tell application \"{s}\" to set active tab index of front window to {d}", .{ escaped_app, tab_index });
    defer allocator.free(line2);
    try runAppleScriptExpectOk(allocator, &.{ line1, line2 });
}

fn sendBrowserKeyCombo(allocator: std.mem.Allocator, app_name: []const u8, key: []const u8, modifiers: []const []u8) !void {
    const escaped_app = try appleScriptEscape(allocator, app_name);
    defer allocator.free(escaped_app);
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

    const line1 = try std.fmt.allocPrint(allocator, "tell application \"{s}\" to activate", .{escaped_app});
    defer allocator.free(line1);
    const line2 = try std.fmt.allocPrint(allocator, "tell application \"System Events\" to keystroke \"{s}\"{s}", .{ escaped_key, using_fragment });
    defer allocator.free(line2);
    try runAppleScriptExpectOk(allocator, &.{ line1, line2 });
}

fn browserExecJs(allocator: std.mem.Allocator, app_name: []const u8, js_source: []const u8) ![]u8 {
    const escaped_app = try appleScriptEscape(allocator, app_name);
    defer allocator.free(escaped_app);
    const escaped_js = try appleScriptEscape(allocator, js_source);
    defer allocator.free(escaped_js);
    const line = try std.fmt.allocPrint(
        allocator,
        "tell application \"{s}\" to execute active tab of front window javascript \"{s}\"",
        .{ escaped_app, escaped_js },
    );
    defer allocator.free(line);
    var result = try runAppleScript(allocator, &.{line});
    defer result.deinit(allocator);
    if (result.exit_code != 0) return error.CommandFailed;
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
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
    for (lines) |line| try argv.appendSlice(allocator, &.{ "-e", line });
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
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/spiderweb-browser-{d}.png", .{std.time.milliTimestamp()});
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
            try out.writer(allocator).print("{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{ escaped_path, escaped_content });
        } else if (update.content_b64) |content_b64| {
            const escaped_content = try jsonEscapeOwned(allocator, content_b64);
            defer allocator.free(escaped_content);
            try out.writer(allocator).print("{{\"path\":\"{s}\",\"content_b64\":\"{s}\"}}", .{ escaped_path, escaped_content });
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn quotedJsString(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const escaped = try jsonEscapeOwned(allocator, value);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
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

fn fatal(msg: []const u8) noreturn {
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(2);
}

test "browser_driver: parse act payload requires selector for click" {
    const allocator = std.testing.allocator;

    var valid = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"op\":\"act\",\"arguments\":{\"action\":\"click\",\"selector\":\"#fixture-button\"}}",
        .{},
    );
    defer valid.deinit();
    var parsed = try parseActArgs(allocator, valid.value.object);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(Action.click, parsed.action);
    try std.testing.expectEqualStrings("#fixture-button", parsed.selector.?);

    var invalid = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"op\":\"act\",\"arguments\":{\"action\":\"click\"}}",
        .{},
    );
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidPayload, parseActArgs(allocator, invalid.value.object));
}

test "browser_driver: parse observe payload honors include flags" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"op\":\"observe\",\"arguments\":{\"include_dom\":false,\"include_screenshot\":false}}",
        .{},
    );
    defer parsed.deinit();
    const args = try parseObserveArgs(parsed.value.object);
    try std.testing.expect(!args.include_dom);
    try std.testing.expect(!args.include_screenshot);
}

test "browser_driver: helper advertises runtime readiness metadata" {
    try std.testing.expect(std.mem.indexOf(u8, playwright_helper_source, browser_state_path_env_var) != null);
    try std.testing.expect(std.mem.indexOf(u8, playwright_helper_source, browser_profile_dir_env_var) != null);
    try std.testing.expect(std.mem.indexOf(u8, playwright_helper_source, "playwright_available") != null);
    try std.testing.expect(std.mem.indexOf(u8, playwright_helper_source, "guidanceFor(reason)") != null);
    try std.testing.expect(std.mem.indexOf(u8, playwright_helper_source, "state_path") != null);
    try std.testing.expect(std.mem.indexOf(u8, playwright_helper_source, "profile_dir") != null);
}
