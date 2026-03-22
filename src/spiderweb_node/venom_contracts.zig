const std = @import("std");
const unified = @import("spider-protocol").unified;

fn boolJson(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn escape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return unified.jsonEscape(allocator, value);
}

pub const namespace_service = struct {
    pub const descriptor_schema_json =
        "{\"model\":\"namespace-service-v1\",\"control\":{\"invoke\":\"control/invoke.json\",\"reset\":\"control/reset\",\"enable\":\"control/enable\",\"disable\":\"control/disable\",\"restart\":\"control/restart\"},\"result\":\"result.json\",\"status\":\"status.json\",\"last_error\":\"last_error.txt\",\"metrics\":\"metrics.json\",\"config\":\"config.json\",\"health\":\"health.json\",\"host\":\"HOST.json\"}";
    pub const default_invoke_template_json = "{}";
};

pub const terminal = struct {
    pub const help_md =
        "Terminal namespace driver.\nWrite JSON payloads to control/invoke.json with command or argv.";
    pub const descriptor_schema_json =
        "{\"model\":\"terminal-driver-v1\",\"arguments\":{\"command\":\"string (optional)\",\"argv\":\"string[] (optional)\",\"cwd\":\"string (optional)\",\"max_output_bytes\":\"number (optional)\"}}";
    pub const invoke_template_json =
        "{\"tool_name\":\"terminal_exec\",\"arguments\":{\"command\":\"echo hello\"}}";
};

pub const ChatMeta = struct {
    agent_id: []const u8,
    actor_type: []const u8,
    actor_id: []const u8,
    workspace_id: []const u8 = "",
};

pub const chat = struct {
    pub const example_send_txt = "hello from acheron chat";
    pub const readme_md =
        "# Chat Capability\n\n" ++
        "Use `control/input` for inbound user/admin chat (creates a chat job).\n" ++
        "Use `control/reply` for outbound agent reply text to the current chat turn.\n" ++
        "Read `/global/jobs/<job-id>/result.txt` for chat job output.\n";
    pub const export_help_md =
        "# Chat Capability\n\n" ++
        "Write UTF-8 text to `control/input` to create a chat job.\n" ++
        "Read `/global/jobs/<job-id>/result.txt` for assistant output.\n";
    pub const caps_json =
        "{\"invoke\":true,\"write_input\":true,\"write_reply\":true,\"read_jobs\":true}";
    pub const export_schema_json =
        "{\"name\":\"chat\",\"input\":\"control/input\",\"jobs\":\"/global/jobs\",\"result\":\"result.txt\"}";
    pub const descriptor_permissions_json =
        "{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}";
    pub const descriptor_schema_json = "{\"model\":\"namespace-chat-v1\"}";
    pub const descriptor_help_md = "Spiderweb local chat namespace";

    pub fn renderSchemaJson(
        allocator: std.mem.Allocator,
        jobs_root_path: []const u8,
        reply_path: ?[]const u8,
    ) ![]u8 {
        const escaped_jobs = try escape(allocator, jobs_root_path);
        defer allocator.free(escaped_jobs);
        if (reply_path) |path| {
            const escaped_reply = try escape(allocator, path);
            defer allocator.free(escaped_reply);
            return std.fmt.allocPrint(
                allocator,
                "{{\"name\":\"chat\",\"input\":\"control/input\",\"reply\":\"{s}\",\"jobs\":\"{s}\",\"result\":\"result.txt\"}}",
                .{ escaped_reply, escaped_jobs },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"chat\",\"input\":\"control/input\",\"jobs\":\"{s}\",\"result\":\"result.txt\"}}",
            .{escaped_jobs},
        );
    }

    pub fn renderOpsJson(
        allocator: std.mem.Allocator,
        invoke_path: []const u8,
        jobs_root_path: []const u8,
        reply_path: ?[]const u8,
    ) ![]u8 {
        const escaped_invoke = try escape(allocator, invoke_path);
        defer allocator.free(escaped_invoke);
        const escaped_jobs = try escape(allocator, jobs_root_path);
        defer allocator.free(escaped_jobs);
        if (reply_path) |path| {
            const escaped_reply = try escape(allocator, path);
            defer allocator.free(escaped_reply);
            return std.fmt.allocPrint(
                allocator,
                "{{\"model\":\"namespace\",\"invoke\":\"{s}\",\"paths\":{{\"invoke\":\"{s}\",\"reply\":\"{s}\",\"jobs_root\":\"{s}\",\"result_leaf\":\"result.txt\",\"status_leaf\":\"status.json\"}}}}",
                .{ escaped_invoke, escaped_invoke, escaped_reply, escaped_jobs },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":\"namespace\",\"invoke\":\"{s}\",\"paths\":{{\"invoke\":\"{s}\",\"jobs_root\":\"{s}\",\"result_leaf\":\"result.txt\",\"status_leaf\":\"status.json\"}}}}",
            .{ escaped_invoke, escaped_invoke, escaped_jobs },
        );
    }

    pub fn renderStatusJson(
        allocator: std.mem.Allocator,
        endpoint_path: []const u8,
        jobs_root_path: []const u8,
    ) ![]u8 {
        const escaped_endpoint = try escape(allocator, endpoint_path);
        defer allocator.free(escaped_endpoint);
        const escaped_jobs = try escape(allocator, jobs_root_path);
        defer allocator.free(escaped_jobs);
        return std.fmt.allocPrint(
            allocator,
            "{{\"state\":\"online\",\"endpoint\":\"{s}\",\"jobs_root\":\"{s}\"}}",
            .{ escaped_endpoint, escaped_jobs },
        );
    }

    pub fn renderMetaJson(allocator: std.mem.Allocator, meta: ChatMeta) ![]u8 {
        const escaped_agent = try escape(allocator, meta.agent_id);
        defer allocator.free(escaped_agent);
        const escaped_actor_type = try escape(allocator, meta.actor_type);
        defer allocator.free(escaped_actor_type);
        const escaped_actor_id = try escape(allocator, meta.actor_id);
        defer allocator.free(escaped_actor_id);
        const escaped_workspace = try escape(allocator, meta.workspace_id);
        defer allocator.free(escaped_workspace);
        return std.fmt.allocPrint(
            allocator,
            "{{\"name\":\"chat\",\"version\":\"1\",\"agent_id\":\"{s}\",\"actor_type\":\"{s}\",\"actor_id\":\"{s}\",\"workspace_id\":\"{s}\",\"cost_hint\":\"provider-dependent\",\"latency_hint\":\"seconds\"}}",
            .{ escaped_agent, escaped_actor_type, escaped_actor_id, escaped_workspace },
        );
    }

    pub fn renderDescriptorJson(
        allocator: std.mem.Allocator,
        endpoint_path: []const u8,
        mount_path: []const u8,
        jobs_root_path: []const u8,
        runtime_entry: []const u8,
    ) ![]u8 {
        const escaped_endpoint = try escape(allocator, endpoint_path);
        defer allocator.free(escaped_endpoint);
        const escaped_mount = try escape(allocator, mount_path);
        defer allocator.free(escaped_mount);
        const escaped_jobs = try escape(allocator, jobs_root_path);
        defer allocator.free(escaped_jobs);
        const escaped_runtime = try escape(allocator, runtime_entry);
        defer allocator.free(escaped_runtime);
        return std.fmt.allocPrint(
            allocator,
            "{{\"venom_id\":\"chat\",\"kind\":\"chat\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"{s}\"],\"capabilities\":{s},\"mounts\":[{{\"mount_id\":\"chat\",\"mount_path\":\"{s}\",\"state\":\"online\"}}],\"ops\":{{\"model\":\"namespace\",\"invoke\":\"control/input\",\"paths\":{{\"invoke\":\"control/input\",\"reply\":\"control/reply\",\"jobs_root\":\"{s}\",\"result_leaf\":\"result.txt\",\"status_leaf\":\"status.json\"}}}},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\",\"entry\":\"{s}\"}},\"permissions\":{s},\"schema\":{s},\"help_md\":\"{s}\"}}",
            .{
                escaped_endpoint,
                caps_json,
                escaped_mount,
                escaped_jobs,
                escaped_runtime,
                descriptor_permissions_json,
                descriptor_schema_json,
                descriptor_help_md,
            },
        );
    }
};

pub const jobs = struct {
    pub const readme_md =
        "Job collection for asynchronous Venom operations such as chat.\n" ++
        "Each job directory exposes status.json, result.txt, and log.txt.\n";
    pub const caps_json =
        "{\"read_collection\":true,\"read_job_status\":true,\"read_job_result\":true}";
    pub const ops_json =
        "{\"model\":\"collection\",\"paths\":{\"status_leaf\":\"status.json\",\"result_leaf\":\"result.txt\",\"log_leaf\":\"log.txt\"}}";
    pub const descriptor_permissions_json =
        "{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"]}";
    pub const descriptor_schema_json = "{\"model\":\"namespace-job-collection-v1\"}";
    pub const descriptor_help_md = "Spiderweb local jobs namespace";

    pub fn renderSchemaJson(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
        const escaped_root = try escape(allocator, root_path);
        defer allocator.free(escaped_root);
        return std.fmt.allocPrint(
            allocator,
            "{{\"root\":\"{s}\",\"job\":{{\"status\":\"status.json\",\"result\":\"result.txt\",\"log\":\"log.txt\"}}}}",
            .{escaped_root},
        );
    }

    pub fn renderStatusJson(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
        const escaped_root = try escape(allocator, root_path);
        defer allocator.free(escaped_root);
        return std.fmt.allocPrint(
            allocator,
            "{{\"state\":\"online\",\"root\":\"{s}\"}}",
            .{escaped_root},
        );
    }

    pub fn renderDescriptorJson(
        allocator: std.mem.Allocator,
        endpoint_path: []const u8,
        mount_path: []const u8,
        runtime_entry: []const u8,
    ) ![]u8 {
        const escaped_endpoint = try escape(allocator, endpoint_path);
        defer allocator.free(escaped_endpoint);
        const escaped_mount = try escape(allocator, mount_path);
        defer allocator.free(escaped_mount);
        const escaped_runtime = try escape(allocator, runtime_entry);
        defer allocator.free(escaped_runtime);
        return std.fmt.allocPrint(
            allocator,
            "{{\"venom_id\":\"jobs\",\"kind\":\"jobs\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"{s}\"],\"capabilities\":{s},\"mounts\":[{{\"mount_id\":\"jobs\",\"mount_path\":\"{s}\",\"state\":\"online\"}}],\"ops\":{s},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\",\"entry\":\"{s}\"}},\"permissions\":{s},\"schema\":{s},\"help_md\":\"{s}\"}}",
            .{
                escaped_endpoint,
                caps_json,
                escaped_mount,
                ops_json,
                escaped_runtime,
                descriptor_permissions_json,
                descriptor_schema_json,
                descriptor_help_md,
            },
        );
    }
};

pub const thoughts = struct {
    pub const readme_md =
        "Internal per-cycle thought frames from runtime provider loops.\n" ++
        "Use latest.txt for current thought and history.ndjson for trace.\n";
    pub const schema_json =
        "{\"latest\":\"latest.txt\",\"history\":\"history.ndjson\",\"status\":\"status.json\",\"event\":{\"seq\":1,\"ts_ms\":0,\"source\":\"thinking|text\",\"round\":1,\"content\":\"...\"}}";
    pub const caps_json =
        "{\"read_latest\":true,\"read_history\":true,\"stream_append\":true}";
    pub const ops_json =
        "{\"model\":\"stream\",\"paths\":{\"latest\":\"latest.txt\",\"history\":\"history.ndjson\",\"status\":\"status.json\"}}";
    pub const initial_status_json =
        "{\"count\":0,\"updated_at_ms\":0,\"latest_source\":null,\"latest_round\":null}";

    pub fn renderDescriptorJson(
        allocator: std.mem.Allocator,
        endpoint_path: []const u8,
        mount_path: []const u8,
        runtime_entry: []const u8,
    ) ![]u8 {
        const escaped_endpoint = try escape(allocator, endpoint_path);
        defer allocator.free(escaped_endpoint);
        const escaped_mount = try escape(allocator, mount_path);
        defer allocator.free(escaped_mount);
        const escaped_runtime = try escape(allocator, runtime_entry);
        defer allocator.free(escaped_runtime);
        return std.fmt.allocPrint(
            allocator,
            "{{\"venom_id\":\"thoughts\",\"kind\":\"thoughts\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"{s}\"],\"capabilities\":{s},\"mounts\":[{{\"mount_id\":\"thoughts\",\"mount_path\":\"{s}\",\"state\":\"online\"}}],\"ops\":{s},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\",\"entry\":\"{s}\"}},\"permissions\":{s},\"schema\":{s},\"help_md\":\"App or host thought telemetry stream\"}}",
            .{
                escaped_endpoint,
                caps_json,
                escaped_mount,
                ops_json,
                escaped_runtime,
                jobs.descriptor_permissions_json,
                schema_json,
            },
        );
    }
};

pub const events = struct {
    pub const readme_md =
        "# Event Waiting\n\n" ++
        "1. Write selector JSON to `control/wait.json`.\n" ++
        "2. Read `next.json` to block until the first matching event.\n\n" ++
        "Selectors support chat/jobs plus event sources under `/global/events/sources/*`.\n" ++
        "Single-event waits can also use a direct blocking read on that endpoint when supported.\n";
    pub const schema_json =
        "{\"wait_config\":{\"paths\":[\"/global/chat/control/input\",\"/global/jobs/<job-id>/status.json\",\"/global/events/sources/time/after/1000.json\",\"/global/events/sources/agent/build.json\",\"/global/events/sources/hook/pre_observe.json\"],\"timeout_ms\":60000},\"signal\":{\"event_type\":\"agent|hook|user\",\"parameter\":\"string?\",\"payload\":{}},\"event\":{\"event_id\":1,\"source_path\":\"...\",\"event_path\":\"...\",\"updated_at_ms\":0}}";
    pub const caps_json =
        "{\"invoke\":true,\"sources\":[\"/global/chat/control/input\",\"/global/jobs/<job-id>/status.json\",\"/global/jobs/<job-id>/result.txt\",\"/global/events/sources/time/after/<ms>.json\",\"/global/events/sources/time/at/<unix_ms>.json\",\"/global/events/sources/agent/<parameter>.json\",\"/global/events/sources/hook/<parameter>.json\",\"/global/events/sources/user/<parameter>.json\"],\"multi_wait\":true,\"single_blocking_read\":true}";
    pub const ops_json =
        "{\"model\":\"namespace\",\"invoke\":\"control/wait.json\",\"paths\":{\"invoke\":\"control/wait.json\",\"next\":\"next.json\"}}";
    pub const status_json =
        "{\"state\":\"online\",\"endpoint\":\"/global/events\",\"next\":\"next.json\"}";
    pub const control_readme_md =
        "Write wait selector JSON to wait.json. Required: paths[]. Optional: timeout_ms. Emit synthetic agent/hook/user signals via signal.json.\n";
    pub const default_wait_json = "{\"paths\":[],\"timeout_ms\":60000}";
    pub const default_signal_json =
        "{\"event_type\":\"agent\",\"parameter\":\"example\",\"payload\":{}}";
    pub const sources_readme_md =
        "Wait source selectors: time/after/<ms>.json, time/at/<unix_ms>.json, agent/<parameter>.json, hook/<parameter>.json, user/<parameter>.json.\n";
    pub const agent_source_help_md =
        "Use `/global/events/sources/agent/<parameter>.json` in wait.json selectors.\n";
    pub const hook_source_help_md =
        "Use `/global/events/sources/hook/<parameter>.json` in wait.json selectors.\n";
    pub const user_source_help_md =
        "Use `/global/events/sources/user/<parameter>.json` in wait.json selectors.\n";
    pub const time_source_help_md =
        "Use `/global/events/sources/time/after/<ms>.json` or `/global/events/sources/time/at/<unix_ms>.json` in wait.json selectors.\n";
    pub const initial_next_json = "{\"configured\":false,\"waiting\":false}";

    pub fn renderDescriptorJson(
        allocator: std.mem.Allocator,
        endpoint_path: []const u8,
        mount_path: []const u8,
        runtime_entry: []const u8,
    ) ![]u8 {
        const escaped_endpoint = try escape(allocator, endpoint_path);
        defer allocator.free(escaped_endpoint);
        const escaped_mount = try escape(allocator, mount_path);
        defer allocator.free(escaped_mount);
        const escaped_runtime = try escape(allocator, runtime_entry);
        defer allocator.free(escaped_runtime);
        return std.fmt.allocPrint(
            allocator,
            "{{\"venom_id\":\"events\",\"kind\":\"events\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"{s}\"],\"capabilities\":{s},\"mounts\":[{{\"mount_id\":\"events\",\"mount_path\":\"{s}\",\"state\":\"online\"}}],\"ops\":{s},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\",\"entry\":\"{s}\"}},\"permissions\":{s},\"schema\":{s},\"help_md\":\"App or host event wait namespace\"}}",
            .{
                escaped_endpoint,
                caps_json,
                escaped_mount,
                ops_json,
                escaped_runtime,
                jobs.descriptor_permissions_json,
                schema_json,
            },
        );
    }
};

pub const fs = struct {
    pub const descriptor_ops_json = "{\"model\":\"namespace\",\"style\":\"plan9\"}";
    pub const descriptor_permissions_json =
        "{\"default\":\"deny-by-default\",\"allow_roles\":[\"admin\",\"user\"],\"fs_roots\":\"export-scoped\"}";
    pub const descriptor_schema_json = "{\"model\":\"namespace-mount\"}";
    pub const descriptor_help_md = "Spiderweb local filesystem namespace";

    pub fn renderDescriptorJson(
        allocator: std.mem.Allocator,
        endpoint_path: []const u8,
        mount_path: []const u8,
        runtime_entry: []const u8,
        rw: bool,
        export_count: usize,
    ) ![]u8 {
        const escaped_endpoint = try escape(allocator, endpoint_path);
        defer allocator.free(escaped_endpoint);
        const escaped_mount = try escape(allocator, mount_path);
        defer allocator.free(escaped_mount);
        const escaped_runtime = try escape(allocator, runtime_entry);
        defer allocator.free(escaped_runtime);
        return std.fmt.allocPrint(
            allocator,
            "{{\"venom_id\":\"fs\",\"kind\":\"fs\",\"version\":\"1\",\"state\":\"online\",\"endpoints\":[\"{s}\"],\"capabilities\":{{\"rw\":{s},\"export_count\":{d}}},\"mounts\":[{{\"mount_id\":\"fs\",\"mount_path\":\"{s}\",\"state\":\"online\"}}],\"ops\":{s},\"runtime\":{{\"type\":\"builtin\",\"abi\":\"venom-driver-v1\",\"entry\":\"{s}\"}},\"permissions\":{s},\"schema\":{s},\"help_md\":\"{s}\"}}",
            .{
                escaped_endpoint,
                boolJson(rw),
                export_count,
                escaped_mount,
                descriptor_ops_json,
                escaped_runtime,
                descriptor_permissions_json,
                descriptor_schema_json,
                descriptor_help_md,
            },
        );
    }
};

test "venom contracts render chat descriptor and fs descriptor" {
    const allocator = std.testing.allocator;

    const chat_json = try chat.renderDescriptorJson(
        allocator,
        "/nodes/local/chat",
        "/nodes/local/chat",
        "/nodes/local/jobs",
        "spiderweb-local-chat",
    );
    defer allocator.free(chat_json);
    try std.testing.expect(std.mem.indexOf(u8, chat_json, "\"venom_id\":\"chat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chat_json, "\"jobs_root\":\"/nodes/local/jobs\"") != null);

    const fs_json = try fs.renderDescriptorJson(
        allocator,
        "/nodes/local/fs",
        "/nodes/local/fs",
        "spiderweb-local-fs",
        true,
        3,
    );
    defer allocator.free(fs_json);
    try std.testing.expect(std.mem.indexOf(u8, fs_json, "\"venom_id\":\"fs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fs_json, "\"export_count\":3") != null);
}
