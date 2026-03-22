const std = @import("std");

pub const JobState = enum {
    queued,
    running,
    done,
    failed,
};

pub fn isTerminalState(state: JobState) bool {
    return switch (state) {
        .done, .failed => true,
        else => false,
    };
}

pub fn jobStateName(state: JobState) []const u8 {
    return switch (state) {
        .queued => "queued",
        .running => "running",
        .done => "done",
        .failed => "failed",
    };
}

pub const ThoughtFrame = struct {
    ts_ms: i64,
    source: ?[]u8 = null,
    round: ?usize = null,
    content: []u8,

    pub fn deinit(self: *ThoughtFrame, allocator: std.mem.Allocator) void {
        if (self.source) |value| allocator.free(value);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub fn deinitThoughtFrames(allocator: std.mem.Allocator, frames: []ThoughtFrame) void {
    for (frames) |*frame| frame.deinit(allocator);
    if (frames.len > 0) allocator.free(frames);
}

pub const JobTerminalEventView = struct {
    seq: u64,
    created_at_ms: i64,
    job_id: []u8,
    agent_id: []u8,
    state: JobState,
    correlation_id: ?[]u8 = null,
    result_text: ?[]u8 = null,
    error_text: ?[]u8 = null,

    pub fn deinit(self: *JobTerminalEventView, allocator: std.mem.Allocator) void {
        allocator.free(self.job_id);
        allocator.free(self.agent_id);
        if (self.correlation_id) |value| allocator.free(value);
        if (self.result_text) |value| allocator.free(value);
        if (self.error_text) |value| allocator.free(value);
        self.* = undefined;
    }
};

test "chat_job_types exposes terminal-state helpers" {
    try std.testing.expect(isTerminalState(.done));
    try std.testing.expect(!isTerminalState(.running));
    try std.testing.expectEqualStrings("failed", jobStateName(.failed));
}
