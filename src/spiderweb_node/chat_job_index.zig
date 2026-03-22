const std = @import("std");
const unified = @import("spider-protocol").unified;
const shared_job = @import("chat_job_types.zig");

const snapshot_filename = "chat-job-index.json";
const snapshot_schema: u32 = 2;
const default_ttl_ms: i64 = 24 * 60 * 60 * 1000;
const max_snapshot_bytes: usize = 32 * 1024 * 1024;

pub const JobState = shared_job.JobState;

pub const JobIndexError = error{
    JobNotFound,
    JobAlreadyTerminal,
};

const JobRecord = struct {
    job_id: []u8,
    agent_id: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    expires_at_ms: i64,
    state: JobState,
    correlation_id: ?[]u8 = null,
    request_text: ?[]u8 = null,
    request_json: ?[]u8 = null,
    result_text: ?[]u8 = null,
    error_text: ?[]u8 = null,
    log_text: ?[]u8 = null,
    thought_frames: std.ArrayListUnmanaged(ThoughtFrame) = .{},

    fn deinit(self: *JobRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.agent_id);
        if (self.correlation_id) |value| allocator.free(value);
        if (self.request_text) |value| allocator.free(value);
        if (self.request_json) |value| allocator.free(value);
        if (self.result_text) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        if (self.log_text) |value| allocator.free(value);
        clearThoughtFrameList(allocator, &self.thought_frames);
        self.* = undefined;
    }
};

pub const ThoughtFrame = shared_job.ThoughtFrame;
pub const deinitThoughtFrames = shared_job.deinitThoughtFrames;

fn clearThoughtFrameList(allocator: std.mem.Allocator, frames: *std.ArrayListUnmanaged(ThoughtFrame)) void {
    for (frames.items) |*frame| frame.deinit(allocator);
    frames.deinit(allocator);
    frames.* = .{};
}

const JobTerminalEventRecord = struct {
    seq: u64,
    created_at_ms: i64,
    job_id: []u8,
    agent_id: []u8,
    state: JobState,
    correlation_id: ?[]u8 = null,
    result_text: ?[]u8 = null,
    error_text: ?[]u8 = null,

    fn deinit(self: *JobTerminalEventRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.agent_id);
        if (self.correlation_id) |value| allocator.free(value);
        if (self.result_text) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const JobTerminalEventView = shared_job.JobTerminalEventView;
pub const isTerminalState = shared_job.isTerminalState;
pub const jobStateName = shared_job.jobStateName;

pub const JobView = struct {
    job_id: []u8,
    agent_id: []u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    expires_at_ms: i64,
    state: JobState,
    correlation_id: ?[]u8 = null,
    request_text: ?[]u8 = null,
    request_json: ?[]u8 = null,
    result_text: ?[]u8 = null,
    error_text: ?[]u8 = null,
    log_text: ?[]u8 = null,

    pub fn deinit(self: *JobView, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.agent_id);
        if (self.correlation_id) |value| allocator.free(value);
        if (self.request_text) |value| allocator.free(value);
        if (self.request_json) |value| allocator.free(value);
        if (self.result_text) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        if (self.log_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn deinitJobViews(allocator: std.mem.Allocator, views: []JobView) void {
    for (views) |*view| view.deinit(allocator);
    if (views.len > 0) allocator.free(views);
}

pub const ChatJobIndex = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    snapshot_path: ?[]u8 = null,
    next_job_seq: u64 = 1,
    next_terminal_event_seq: u64 = 1,
    ttl_ms: i64 = default_ttl_ms,
    jobs: std.StringHashMapUnmanaged(JobRecord) = .{},
    terminal_events: std.ArrayListUnmanaged(JobTerminalEventRecord) = .{},

    pub fn init(allocator: std.mem.Allocator, ltm_directory: []const u8) ChatJobIndex {
        var index = ChatJobIndex{
            .allocator = allocator,
        };
        if (ltm_directory.len == 0) return index;

        std.fs.cwd().makePath(ltm_directory) catch |err| {
            std.log.warn("chat job index disabled (cannot create ltm dir): {s}", .{@errorName(err)});
            return index;
        };

        index.snapshot_path = std.fs.path.join(allocator, &.{ ltm_directory, snapshot_filename }) catch |err| {
            std.log.warn("chat job index disabled (path allocation failed): {s}", .{@errorName(err)});
            return index;
        };

        index.loadFromDiskLocked() catch |err| {
            std.log.warn("chat job index load failed: {s}", .{@errorName(err)});
        };
        return index;
    }

    pub fn deinit(self: *ChatJobIndex) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.jobs.valueIterator();
        while (it.next()) |record| record.deinit(self.allocator);
        self.jobs.deinit(self.allocator);
        self.jobs = .{};
        for (self.terminal_events.items) |*event| event.deinit(self.allocator);
        self.terminal_events.deinit(self.allocator);
        self.terminal_events = .{};

        if (self.snapshot_path) |value| {
            self.allocator.free(value);
            self.snapshot_path = null;
        }
    }

    pub fn createJob(
        self: *ChatJobIndex,
        agent_id: []const u8,
        correlation_id: ?[]const u8,
    ) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ms = std.time.milliTimestamp();
        try self.pruneExpiredLocked(now_ms);

        const job_id = try std.fmt.allocPrint(self.allocator, "job-{d}", .{self.next_job_seq});
        self.next_job_seq +%= 1;
        if (self.next_job_seq == 0) self.next_job_seq = 1;
        errdefer self.allocator.free(job_id);

        const record = JobRecord{
            .job_id = try self.allocator.dupe(u8, job_id),
            .agent_id = try self.allocator.dupe(u8, agent_id),
            .created_at_ms = now_ms,
            .updated_at_ms = now_ms,
            .expires_at_ms = now_ms + self.ttl_ms,
            .state = .queued,
            .correlation_id = if (correlation_id) |value| try self.allocator.dupe(u8, value) else null,
        };
        errdefer {
            var tmp = record;
            tmp.deinit(self.allocator);
        }

        try self.jobs.put(self.allocator, record.job_id, record);
        self.persistSnapshotBestEffortLocked();
        return job_id;
    }

    pub fn markRunning(self: *ChatJobIndex, job_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const record = self.jobs.getPtr(job_id) orelse return JobIndexError.JobNotFound;
        const now_ms = std.time.milliTimestamp();
        record.state = .running;
        record.updated_at_ms = now_ms;
        record.expires_at_ms = now_ms + self.ttl_ms;
        self.persistSnapshotBestEffortLocked();
    }

    pub fn setRequestText(self: *ChatJobIndex, job_id: []const u8, request_text: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const record = self.jobs.getPtr(job_id) orelse return JobIndexError.JobNotFound;
        const now_ms = std.time.milliTimestamp();
        const next_request_text = try self.allocator.dupe(u8, request_text);
        if (record.request_text) |value| self.allocator.free(value);
        record.request_text = next_request_text;
        record.updated_at_ms = now_ms;
        record.expires_at_ms = now_ms + self.ttl_ms;
        self.persistSnapshotBestEffortLocked();
    }

    pub fn setRequestEnvelopeJson(self: *ChatJobIndex, job_id: []const u8, request_json: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const record = self.jobs.getPtr(job_id) orelse return JobIndexError.JobNotFound;
        const now_ms = std.time.milliTimestamp();
        const next_request_json = try self.allocator.dupe(u8, request_json);
        if (record.request_json) |value| self.allocator.free(value);
        record.request_json = next_request_json;
        record.updated_at_ms = now_ms;
        record.expires_at_ms = now_ms + self.ttl_ms;
        self.persistSnapshotBestEffortLocked();
    }

    pub fn updateArtifacts(
        self: *ChatJobIndex,
        job_id: []const u8,
        result_text: ?[]const u8,
        error_text: ?[]const u8,
        log_text: ?[]const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const record = self.jobs.getPtr(job_id) orelse return JobIndexError.JobNotFound;
        if (isTerminalState(record.state)) return JobIndexError.JobAlreadyTerminal;
        const now_ms = std.time.milliTimestamp();
        if (result_text) |value| {
            const next_result_text = try self.allocator.dupe(u8, value);
            if (record.result_text) |existing| self.allocator.free(existing);
            record.result_text = next_result_text;
        }
        if (error_text) |value| {
            const next_error_text = try self.allocator.dupe(u8, value);
            if (record.error_text) |existing| self.allocator.free(existing);
            record.error_text = next_error_text;
        }
        if (log_text) |value| {
            const next_log_text = try self.allocator.dupe(u8, value);
            if (record.log_text) |existing| self.allocator.free(existing);
            record.log_text = next_log_text;
        }
        record.updated_at_ms = now_ms;
        record.expires_at_ms = now_ms + self.ttl_ms;
        self.persistSnapshotBestEffortLocked();
    }

    pub fn markCompleted(
        self: *ChatJobIndex,
        job_id: []const u8,
        succeeded: bool,
        result_text: []const u8,
        error_text: ?[]const u8,
        log_text: []const u8,
    ) !void {
        return self.markCompletedWithThoughtFrames(job_id, succeeded, result_text, error_text, log_text, &.{});
    }

    pub fn markCompletedWithThoughtFrames(
        self: *ChatJobIndex,
        job_id: []const u8,
        succeeded: bool,
        result_text: []const u8,
        error_text: ?[]const u8,
        log_text: []const u8,
        thought_frames_override: []const ThoughtFrame,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const record = self.jobs.getPtr(job_id) orelse return JobIndexError.JobNotFound;
        const now_ms = std.time.milliTimestamp();
        record.state = if (succeeded) .done else .failed;
        record.updated_at_ms = now_ms;
        record.expires_at_ms = now_ms + self.ttl_ms;

        if (record.result_text) |value| {
            self.allocator.free(value);
            record.result_text = null;
        }
        if (record.error_text) |value| {
            self.allocator.free(value);
            record.error_text = null;
        }
        if (record.log_text) |value| {
            self.allocator.free(value);
            record.log_text = null;
        }
        clearThoughtFrameList(self.allocator, &record.thought_frames);

        record.result_text = try self.allocator.dupe(u8, result_text);
        if (error_text) |value| {
            record.error_text = try self.allocator.dupe(u8, value);
        }
        record.log_text = try self.allocator.dupe(u8, log_text);
        if (thought_frames_override.len > 0) {
            for (thought_frames_override) |frame| {
                try record.thought_frames.append(self.allocator, try duplicateThoughtFrame(self.allocator, frame));
            }
        } else {
            var parsed_thoughts = try parseThoughtFramesFromLogText(self.allocator, log_text);
            defer {
                clearThoughtFrameList(self.allocator, &parsed_thoughts);
            }
            for (parsed_thoughts.items) |frame| {
                try record.thought_frames.append(self.allocator, try duplicateThoughtFrame(self.allocator, frame));
            }
        }

        try self.terminal_events.append(self.allocator, .{
            .seq = self.next_terminal_event_seq,
            .created_at_ms = now_ms,
            .job_id = try self.allocator.dupe(u8, record.job_id),
            .agent_id = try self.allocator.dupe(u8, record.agent_id),
            .state = record.state,
            .correlation_id = if (record.correlation_id) |value| try self.allocator.dupe(u8, value) else null,
            .result_text = if (record.result_text) |value| try self.allocator.dupe(u8, value) else null,
            .error_text = if (record.error_text) |value| try self.allocator.dupe(u8, value) else null,
        });
        self.next_terminal_event_seq +%= 1;
        if (self.next_terminal_event_seq == 0) self.next_terminal_event_seq = 1;

        self.persistSnapshotBestEffortLocked();
    }

    pub fn listJobsForAgent(self: *ChatJobIndex, allocator: std.mem.Allocator, agent_id: []const u8) ![]JobView {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pruneExpiredLocked(std.time.milliTimestamp());

        var out = std.ArrayListUnmanaged(JobView){};
        errdefer {
            for (out.items) |*view| view.deinit(allocator);
            out.deinit(allocator);
        }

        var it = self.jobs.valueIterator();
        while (it.next()) |record| {
            if (!std.mem.eql(u8, record.agent_id, agent_id)) continue;
            try out.append(allocator, try duplicateRecordView(allocator, record.*));
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn hasInFlightForAgent(self: *ChatJobIndex, agent_id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pruneExpiredLocked(std.time.milliTimestamp());

        var it = self.jobs.valueIterator();
        while (it.next()) |record| {
            if (!std.mem.eql(u8, record.agent_id, agent_id)) continue;
            if (record.state == .queued or record.state == .running) return true;
        }
        return false;
    }

    pub fn getJob(self: *ChatJobIndex, allocator: std.mem.Allocator, job_id: []const u8) !?JobView {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pruneExpiredLocked(std.time.milliTimestamp());
        const record = self.jobs.get(job_id) orelse return null;
        return try duplicateRecordView(allocator, record);
    }

    pub fn listThoughtFramesForJob(self: *ChatJobIndex, allocator: std.mem.Allocator, job_id: []const u8) ![]ThoughtFrame {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pruneExpiredLocked(std.time.milliTimestamp());
        const record = self.jobs.get(job_id) orelse return try allocator.alloc(ThoughtFrame, 0);
        return duplicateThoughtFrames(allocator, record.thought_frames.items);
    }

    pub fn latestTerminalEventSeqForAgent(self: *ChatJobIndex, agent_id: []const u8) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pruneExpiredLocked(std.time.milliTimestamp());
        var latest: u64 = 0;
        for (self.terminal_events.items) |event| {
            if (!std.mem.eql(u8, event.agent_id, agent_id)) continue;
            if (event.seq > latest) latest = event.seq;
        }
        return latest;
    }

    pub fn firstTerminalEventForAgentAfter(
        self: *ChatJobIndex,
        allocator: std.mem.Allocator,
        agent_id: []const u8,
        after_seq: u64,
    ) !?JobTerminalEventView {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.pruneExpiredLocked(std.time.milliTimestamp());
        for (self.terminal_events.items) |event| {
            if (!std.mem.eql(u8, event.agent_id, agent_id)) continue;
            if (event.seq <= after_seq) continue;
            return @as(?JobTerminalEventView, try duplicateTerminalEventView(allocator, event));
        }
        return null;
    }

    fn duplicateRecordView(allocator: std.mem.Allocator, record: JobRecord) !JobView {
        return .{
            .job_id = try allocator.dupe(u8, record.job_id),
            .agent_id = try allocator.dupe(u8, record.agent_id),
            .created_at_ms = record.created_at_ms,
            .updated_at_ms = record.updated_at_ms,
            .expires_at_ms = record.expires_at_ms,
            .state = record.state,
            .correlation_id = if (record.correlation_id) |value| try allocator.dupe(u8, value) else null,
            .request_text = if (record.request_text) |value| try allocator.dupe(u8, value) else null,
            .request_json = if (record.request_json) |value| try allocator.dupe(u8, value) else null,
            .result_text = if (record.result_text) |value| try allocator.dupe(u8, value) else null,
            .error_text = if (record.error_text) |value| try allocator.dupe(u8, value) else null,
            .log_text = if (record.log_text) |value| try allocator.dupe(u8, value) else null,
        };
    }

    fn pruneExpiredLocked(self: *ChatJobIndex, now_ms: i64) !void {
        var expired_keys = std.ArrayListUnmanaged([]u8){};
        defer {
            for (expired_keys.items) |key| self.allocator.free(key);
            expired_keys.deinit(self.allocator);
        }

        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            const record = entry.value_ptr.*;
            const terminal = record.state == .done or record.state == .failed;
            if (!terminal) continue;
            if (record.expires_at_ms > now_ms) continue;
            try expired_keys.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        if (expired_keys.items.len == 0) return;
        var event_idx: usize = 0;
        while (event_idx < self.terminal_events.items.len) {
            var should_remove = false;
            for (expired_keys.items) |key| {
                if (std.mem.eql(u8, self.terminal_events.items[event_idx].job_id, key)) {
                    should_remove = true;
                    break;
                }
            }
            if (should_remove) {
                var removed_event = self.terminal_events.orderedRemove(event_idx);
                removed_event.deinit(self.allocator);
                continue;
            }
            event_idx += 1;
        }
        for (expired_keys.items) |key| {
            const removed = self.jobs.fetchRemove(key) orelse continue;
            var record = removed.value;
            record.deinit(self.allocator);
        }
        self.persistSnapshotBestEffortLocked();
    }

    fn persistSnapshotBestEffortLocked(self: *ChatJobIndex) void {
        self.persistSnapshotLocked() catch |err| {
            std.log.warn("chat job index persist failed: {s}", .{@errorName(err)});
        };
    }

    fn persistSnapshotLocked(self: *ChatJobIndex) !void {
        const path = self.snapshot_path orelse return;
        const snapshot = try self.buildSnapshotJsonLocked();
        defer self.allocator.free(snapshot);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        {
            var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(snapshot);
        }
        std.fs.cwd().rename(tmp_path, path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.fs.cwd().deleteFile(path) catch {};
                try std.fs.cwd().rename(tmp_path, path);
            },
            else => return err,
        };
    }

    fn buildSnapshotJsonLocked(self: *ChatJobIndex) ![]u8 {
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.allocator);

        try out.writer(self.allocator).print(
            "{{\"schema\":{d},\"next_job_seq\":{d},\"ttl_ms\":{d},\"jobs\":[",
            .{ snapshot_schema, self.next_job_seq, self.ttl_ms },
        );

        var first = true;
        var it = self.jobs.valueIterator();
        while (it.next()) |record| {
            if (!first) try out.append(self.allocator, ',');
            first = false;
            try appendRecordJson(self.allocator, &out, record.*);
        }
        try out.appendSlice(self.allocator, "]}");
        return out.toOwnedSlice(self.allocator);
    }

    fn loadFromDiskLocked(self: *ChatJobIndex) !void {
        const path = self.snapshot_path orelse return;
        const raw = std.fs.cwd().readFileAlloc(self.allocator, path, max_snapshot_bytes) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(raw);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSnapshot;
        const root = parsed.value.object;

        const schema_val = root.get("schema") orelse return error.InvalidSnapshot;
        if (schema_val != .integer) return error.InvalidSnapshot;
        if (schema_val.integer != 1 and schema_val.integer != snapshot_schema) return error.InvalidSnapshot;

        if (root.get("next_job_seq")) |value| {
            if (value != .integer or value.integer <= 0) return error.InvalidSnapshot;
            self.next_job_seq = @intCast(value.integer);
        }
        if (root.get("ttl_ms")) |value| {
            if (value != .integer or value.integer <= 0) return error.InvalidSnapshot;
            self.ttl_ms = value.integer;
        }

        const jobs_val = root.get("jobs") orelse return error.InvalidSnapshot;
        if (jobs_val != .array) return error.InvalidSnapshot;
        for (jobs_val.array.items) |item| {
            if (item != .object) return error.InvalidSnapshot;
            const record = try parseRecord(self.allocator, item.object);
            errdefer {
                var tmp = record;
                tmp.deinit(self.allocator);
            }
            try self.jobs.put(self.allocator, record.job_id, record);
        }

        try self.pruneExpiredLocked(std.time.milliTimestamp());
    }
};

fn appendRecordJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    record: JobRecord,
) !void {
    const escaped_id = try unified.jsonEscape(allocator, record.job_id);
    defer allocator.free(escaped_id);
    const escaped_agent = try unified.jsonEscape(allocator, record.agent_id);
    defer allocator.free(escaped_agent);
    const correlation_json = if (record.correlation_id) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(correlation_json);
    const request_json = if (record.request_text) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(request_json);
    const request_payload_json = if (record.request_json) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(request_payload_json);
    const result_json = if (record.result_text) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(result_json);
    const error_json = if (record.error_text) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(error_json);
    const log_json = if (record.log_text) |value| blk: {
        const escaped = try unified.jsonEscape(allocator, value);
        defer allocator.free(escaped);
        break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
    } else try allocator.dupe(u8, "null");
    defer allocator.free(log_json);
    const thought_json = try buildThoughtFramesJson(allocator, record.thought_frames.items);
    defer allocator.free(thought_json);

    try out.writer(allocator).print(
        "{{\"job_id\":\"{s}\",\"agent_id\":\"{s}\",\"created_at_ms\":{d},\"updated_at_ms\":{d},\"expires_at_ms\":{d},\"state\":\"{s}\",\"correlation_id\":{s},\"request_text\":{s},\"request_json\":{s},\"result_text\":{s},\"error_text\":{s},\"log_text\":{s},\"thought_frames\":{s}}}",
        .{
            escaped_id,
            escaped_agent,
            record.created_at_ms,
            record.updated_at_ms,
            record.expires_at_ms,
            jobStateName(record.state),
            correlation_json,
            request_json,
            request_payload_json,
            result_json,
            error_json,
            log_json,
            thought_json,
        },
    );
}

fn parseRecord(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !JobRecord {
    const job_id = try dupRequiredString(allocator, obj, "job_id");
    errdefer allocator.free(job_id);
    const agent_id = try dupRequiredString(allocator, obj, "agent_id");
    errdefer allocator.free(agent_id);
    const state = try jobStateFromString(try getRequiredString(obj, "state"));
    return .{
        .job_id = job_id,
        .agent_id = agent_id,
        .created_at_ms = try getRequiredI64(obj, "created_at_ms"),
        .updated_at_ms = try getRequiredI64(obj, "updated_at_ms"),
        .expires_at_ms = try getRequiredI64(obj, "expires_at_ms"),
        .state = state,
        .correlation_id = try dupOptionalNullableString(allocator, obj, "correlation_id"),
        .request_text = try dupOptionalNullableString(allocator, obj, "request_text"),
        .request_json = try dupOptionalNullableString(allocator, obj, "request_json"),
        .result_text = try dupOptionalNullableString(allocator, obj, "result_text"),
        .error_text = try dupOptionalNullableString(allocator, obj, "error_text"),
        .log_text = try dupOptionalNullableString(allocator, obj, "log_text"),
        .thought_frames = try parseThoughtFramesArray(allocator, obj.get("thought_frames")),
    };
}

fn buildThoughtFramesJson(allocator: std.mem.Allocator, frames: []const ThoughtFrame) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (frames, 0..) |frame, idx| {
        if (idx != 0) try out.append(allocator, ',');
        const source_json = if (frame.source) |value| blk: {
            const escaped = try unified.jsonEscape(allocator, value);
            defer allocator.free(escaped);
            break :blk try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
        } else try allocator.dupe(u8, "null");
        defer allocator.free(source_json);
        const round_json = if (frame.round) |value|
            try std.fmt.allocPrint(allocator, "{d}", .{value})
        else
            try allocator.dupe(u8, "null");
        defer allocator.free(round_json);
        const escaped_content = try unified.jsonEscape(allocator, frame.content);
        defer allocator.free(escaped_content);
        try out.writer(allocator).print(
            "{{\"ts_ms\":{d},\"source\":{s},\"round\":{s},\"content\":\"{s}\"}}",
            .{ frame.ts_ms, source_json, round_json, escaped_content },
        );
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn parseThoughtFramesArray(allocator: std.mem.Allocator, value: ?std.json.Value) !std.ArrayListUnmanaged(ThoughtFrame) {
    var out = std.ArrayListUnmanaged(ThoughtFrame){};
    errdefer {
        clearThoughtFrameList(allocator, &out);
    }
    const actual = value orelse return out;
    if (actual == .null) return out;
    if (actual != .array) return error.InvalidSnapshot;
    for (actual.array.items) |item| {
        if (item != .object) return error.InvalidSnapshot;
        const content = try dupRequiredString(allocator, item.object, "content");
        errdefer allocator.free(content);
        const ts_ms = try getRequiredI64(item.object, "ts_ms");
        const source = try dupOptionalNullableString(allocator, item.object, "source");
        errdefer if (source) |value2| allocator.free(value2);
        const round = if (item.object.get("round")) |round_value|
            switch (round_value) {
                .null => null,
                .integer => if (round_value.integer >= 0) @as(?usize, @intCast(round_value.integer)) else return error.InvalidSnapshot,
                else => return error.InvalidSnapshot,
            }
        else
            null;
        try out.append(allocator, .{
            .ts_ms = ts_ms,
            .source = source,
            .round = round,
            .content = content,
        });
    }
    return out;
}

fn parseThoughtFramesFromLogText(
    allocator: std.mem.Allocator,
    log_text: []const u8,
) !std.ArrayListUnmanaged(ThoughtFrame) {
    var out = std.ArrayListUnmanaged(ThoughtFrame){};
    errdefer {
        clearThoughtFrameList(allocator, &out);
    }
    var cursor: usize = 0;
    while (cursor < log_text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, log_text, cursor, '\n') orelse log_text.len;
        const line = std.mem.trim(u8, log_text[cursor..line_end], " \t\r\n");
        if (line.len > 0 and line[0] == '{') {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
                cursor = if (line_end < log_text.len) line_end + 1 else line_end;
                continue;
            };
            defer parsed.deinit();
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                const type_value = obj.get("type") orelse {
                    cursor = if (line_end < log_text.len) line_end + 1 else line_end;
                    continue;
                };
                if (type_value == .string and std.mem.eql(u8, type_value.string, "agent.thought")) {
                    const content_value = obj.get("content") orelse {
                        cursor = if (line_end < log_text.len) line_end + 1 else line_end;
                        continue;
                    };
                    if (content_value == .string and content_value.string.len > 0) {
                        try out.append(allocator, .{
                            .ts_ms = std.time.milliTimestamp(),
                            .source = if (obj.get("source")) |value|
                                if (value == .string and value.string.len > 0) try allocator.dupe(u8, value.string) else null
                            else
                                null,
                            .round = if (obj.get("round")) |value|
                                if (value == .integer and value.integer >= 0) @as(?usize, @intCast(value.integer)) else null
                            else
                                null,
                            .content = try allocator.dupe(u8, content_value.string),
                        });
                    }
                }
            }
        }
        cursor = if (line_end < log_text.len) line_end + 1 else line_end;
    }
    return out;
}

fn duplicateThoughtFrame(allocator: std.mem.Allocator, frame: ThoughtFrame) !ThoughtFrame {
    return .{
        .ts_ms = frame.ts_ms,
        .source = if (frame.source) |value| try allocator.dupe(u8, value) else null,
        .round = frame.round,
        .content = try allocator.dupe(u8, frame.content),
    };
}

fn duplicateThoughtFrames(allocator: std.mem.Allocator, frames: []const ThoughtFrame) ![]ThoughtFrame {
    const out = try allocator.alloc(ThoughtFrame, frames.len);
    errdefer allocator.free(out);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |*frame| frame.deinit(allocator);
    }
    for (frames, 0..) |frame, idx| {
        out[idx] = try duplicateThoughtFrame(allocator, frame);
        built += 1;
    }
    return out;
}

fn duplicateTerminalEventView(allocator: std.mem.Allocator, event: JobTerminalEventRecord) !JobTerminalEventView {
    return .{
        .seq = event.seq,
        .created_at_ms = event.created_at_ms,
        .job_id = try allocator.dupe(u8, event.job_id),
        .agent_id = try allocator.dupe(u8, event.agent_id),
        .state = event.state,
        .correlation_id = if (event.correlation_id) |value| try allocator.dupe(u8, value) else null,
        .result_text = if (event.result_text) |value| try allocator.dupe(u8, value) else null,
        .error_text = if (event.error_text) |value| try allocator.dupe(u8, value) else null,
    };
}

fn getRequiredString(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = obj.get(field) orelse return error.InvalidSnapshot;
    if (value != .string or value.string.len == 0) return error.InvalidSnapshot;
    return value.string;
}

fn dupRequiredString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, field: []const u8) ![]u8 {
    return allocator.dupe(u8, try getRequiredString(obj, field));
}

fn dupOptionalNullableString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, field: []const u8) !?[]u8 {
    const value = obj.get(field) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidSnapshot;
    const copied = try allocator.dupe(u8, value.string);
    return @as(?[]u8, copied);
}

fn getRequiredI64(obj: std.json.ObjectMap, field: []const u8) !i64 {
    const value = obj.get(field) orelse return error.InvalidSnapshot;
    if (value != .integer) return error.InvalidSnapshot;
    return value.integer;
}

fn jobStateFromString(value: []const u8) !JobState {
    if (std.mem.eql(u8, value, "queued")) return .queued;
    if (std.mem.eql(u8, value, "running")) return .running;
    if (std.mem.eql(u8, value, "done")) return .done;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    return error.InvalidSnapshot;
}

test "chat_job_index: create and complete in memory" {
    const allocator = std.testing.allocator;
    var index = ChatJobIndex.init(allocator, "");
    defer index.deinit();

    const job_id = try index.createJob("agent-a", "corr-1");
    defer allocator.free(job_id);
    try index.markRunning(job_id);
    try index.markCompleted(job_id, true, "result", null, "log");

    const job = try index.getJob(allocator, job_id);
    try std.testing.expect(job != null);
    var view = job.?;
    defer view.deinit(allocator);
    try std.testing.expectEqual(JobState.done, view.state);
    try std.testing.expect(view.result_text != null);
    try std.testing.expectEqualStrings("result", view.result_text.?);
}

test "chat_job_index: request and artifact updates persist in memory" {
    const allocator = std.testing.allocator;
    var index = ChatJobIndex.init(allocator, "");
    defer index.deinit();

    const job_id = try index.createJob("agent-a", "corr-request");
    defer allocator.free(job_id);
    try index.setRequestText(job_id, "hello from chat");
    try index.setRequestEnvelopeJson(job_id, "{\"job_id\":\"job-1\",\"input\":\"hello from chat\"}");
    try index.updateArtifacts(job_id, "partial result", null, "worker log");

    const job = try index.getJob(allocator, job_id);
    try std.testing.expect(job != null);
    var view = job.?;
    defer view.deinit(allocator);
    try std.testing.expectEqualStrings("hello from chat", view.request_text.?);
    try std.testing.expectEqualStrings("{\"job_id\":\"job-1\",\"input\":\"hello from chat\"}", view.request_json.?);
    try std.testing.expectEqualStrings("partial result", view.result_text.?);
    try std.testing.expectEqualStrings("worker log", view.log_text.?);
}

test "chat_job_index: artifact updates are rejected after terminal state" {
    const allocator = std.testing.allocator;
    var index = ChatJobIndex.init(allocator, "");
    defer index.deinit();

    const job_id = try index.createJob("agent-a", "corr-terminal");
    defer allocator.free(job_id);
    try index.markCompleted(job_id, true, "final result", null, "final log");

    try std.testing.expectError(
        JobIndexError.JobAlreadyTerminal,
        index.updateArtifacts(job_id, "late result", "late error", "late log"),
    );

    const job = try index.getJob(allocator, job_id);
    try std.testing.expect(job != null);
    var view = job.?;
    defer view.deinit(allocator);
    try std.testing.expectEqual(JobState.done, view.state);
    try std.testing.expectEqualStrings("final result", view.result_text.?);
    try std.testing.expectEqualStrings("final log", view.log_text.?);
    try std.testing.expect(view.error_text == null);
}

test "chat_job_index: hasInFlightForAgent tracks queued/running jobs" {
    const allocator = std.testing.allocator;
    var index = ChatJobIndex.init(allocator, "");
    defer index.deinit();

    const a_job = try index.createJob("agent-a", null);
    defer allocator.free(a_job);
    const b_job = try index.createJob("agent-b", null);
    defer allocator.free(b_job);

    try std.testing.expect(try index.hasInFlightForAgent("agent-a"));
    try std.testing.expect(try index.hasInFlightForAgent("agent-b"));
    try std.testing.expect(!(try index.hasInFlightForAgent("agent-c")));

    try index.markRunning(a_job);
    try std.testing.expect(try index.hasInFlightForAgent("agent-a"));

    try index.markCompleted(a_job, true, "done", null, "");
    try std.testing.expect(!(try index.hasInFlightForAgent("agent-a")));
    try std.testing.expect(try index.hasInFlightForAgent("agent-b"));
}

test "chat_job_index: completion stores structured thought frames and terminal events" {
    const allocator = std.testing.allocator;
    var index = ChatJobIndex.init(allocator, "");
    defer index.deinit();

    const job_id = try index.createJob("agent-a", "corr-thought");
    defer allocator.free(job_id);
    try index.markRunning(job_id);
    try index.markCompleted(
        job_id,
        true,
        "done",
        null,
        "{\"type\":\"agent.thought\",\"source\":\"thinking\",\"round\":1,\"content\":\"drafting test plan\"}\n{\"type\":\"session.receive\",\"content\":\"done\"}\n",
    );

    const thought_frames = try index.listThoughtFramesForJob(allocator, job_id);
    defer deinitThoughtFrames(allocator, thought_frames);
    try std.testing.expectEqual(@as(usize, 1), thought_frames.len);
    try std.testing.expectEqualStrings("drafting test plan", thought_frames[0].content);
    try std.testing.expect(thought_frames[0].source != null);
    try std.testing.expectEqualStrings("thinking", thought_frames[0].source.?);
    try std.testing.expectEqual(@as(?usize, 1), thought_frames[0].round);

    const event = try index.firstTerminalEventForAgentAfter(allocator, "agent-a", 0);
    try std.testing.expect(event != null);
    var terminal_event = event.?;
    defer terminal_event.deinit(allocator);
    try std.testing.expectEqualStrings(job_id, terminal_event.job_id);
    try std.testing.expectEqual(JobState.done, terminal_event.state);
    try std.testing.expect(terminal_event.result_text != null);
    try std.testing.expectEqualStrings("done", terminal_event.result_text.?);
}
