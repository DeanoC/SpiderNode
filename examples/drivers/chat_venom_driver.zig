const std = @import("std");

extern "spider_host_v1" fn spider_host_capabilities() u64;
extern "spider_host_v1" fn spider_host_now_ms() u64;
extern "spider_host_v1" fn spider_host_log(level: u32, ptr: u32, len: u32) u32;
extern "spider_host_v1" fn spider_host_emit_event_json(ptr: u32, len: u32) u32;
extern "spider_host_v1" fn spider_host_random_fill(ptr: u32, len: u32) u32;

var input_buf: [16 * 1024]u8 = undefined;
var output_buf: [64 * 1024]u8 = undefined;
var random_buf: [8]u8 = undefined;
const log_line = "spiderweb-chat-wasm abi invoked";
const thought_event_json = "{\"type\":\"agent.thought\",\"content\":\"WASM driver drafting reply\",\"source\":\"wasm\",\"round\":1}";
const debug_event_json = "{\"type\":\"debug.event\",\"category\":\"wasm.chat_driver\",\"payload\":{\"message\":\"chat venom invoked\"}}";

pub export fn spider_venom_abi_version() u32 {
    return 1;
}

pub export fn spider_venom_alloc(len: u32) u32 {
    if (len > input_buf.len) return 0;
    return @intCast(@intFromPtr(&input_buf));
}

pub export fn spider_venom_invoke_json(ptr: u32, len: u32) u64 {
    _ = ptr;
    const trimmed = std.mem.trim(u8, input_buf[0..len], " \t\r\n");
    const caps = spider_host_capabilities();
    const now_ms = spider_host_now_ms();
    _ = spider_host_log(20, @intCast(@intFromPtr(log_line.ptr)), log_line.len);
    _ = spider_host_emit_event_json(@intCast(@intFromPtr(thought_event_json.ptr)), thought_event_json.len);
    _ = spider_host_emit_event_json(@intCast(@intFromPtr(debug_event_json.ptr)), debug_event_json.len);
    _ = spider_host_random_fill(@intCast(@intFromPtr(&random_buf)), random_buf.len);

    var stream = std.io.fixedBufferStream(&output_buf);
    const writer = stream.writer();

    if (std.mem.indexOf(u8, trimmed, "fail") != null) {
        writer.writeAll(
            "{\"state\":\"failed\",\"error\":\"spiderweb-chat-wasm requested failure\",\"log\":\"spiderweb-chat-wasm abi\"}",
        ) catch return 0;
    } else {
        writer.writeAll("{\"state\":\"done\",\"reply\":\"WASM chat reply: ") catch return 0;
        appendEscapedJson(writer, trimmed) catch return 0;
        writer.print(
            "\",\"log\":\"spiderweb-chat-wasm abi\",\"host_caps\":{d},\"now_ms\":{d},\"random_hex\":\"",
            .{ caps, now_ms },
        ) catch return 0;
        appendHex(writer, &random_buf) catch return 0;
        writer.writeAll("\"}") catch return 0;
    }

    const out_ptr: u32 = @intCast(@intFromPtr(&output_buf));
    const out_len: u32 = @intCast(stream.pos);
    return (@as(u64, out_len) << 32) | out_ptr;
}

fn appendHex(writer: anytype, bytes: []const u8) !void {
    for (bytes) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
}

fn appendEscapedJson(writer: anytype, input: []const u8) !void {
    for (input) |char| {
        switch (char) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (char < 0x20) {
                    try writer.print("\\u00{x:0>2}", .{char});
                } else {
                    try writer.writeByte(char);
                }
            },
        }
    }
}
