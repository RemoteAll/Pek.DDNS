const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;
const zhttp = zzig.Http;

const probe_url = "https://t.sc8.fun/api/client-ip";
const probe_payload = "from=hlktech-nuget&probe=1";
const timeout_sec: u64 = 5;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("=== Zig.DDNS Network Probe ===\n", .{});
    std.debug.print("target={s}\n", .{@tagName(@import("builtin").os.tag)});
    std.debug.print("url={s}\n", .{probe_url});
    std.debug.print("timeout={d}s\n\n", .{timeout_sec});

    try runProbe(allocator, "main-init-io", io);
}

fn runProbe(allocator: std.mem.Allocator, label: []const u8, io: std.Io) !void {
    std.debug.print("[{s}] start\n", .{label});

    const start = compat.nanoTimestamp();
    const result = fetchClientIpWithTimeout(allocator, io, label, timeout_sec);
    const elapsed_ms = @divFloor(compat.nanoTimestamp() - start, std.time.ns_per_ms);

    if (result) |body| {
        defer allocator.free(body);
        std.debug.print("[{s}] ok elapsed={d}ms len={d}\n", .{ label, elapsed_ms, body.len });
        const preview = if (body.len > 300) body[0..300] else body;
        std.debug.print("[{s}] body={s}\n", .{ label, preview });
    } else |err| {
        std.debug.print("[{s}] fail elapsed={d}ms err={s}\n", .{ label, elapsed_ms, @errorName(err) });
    }
}

fn fetchClientIpWithTimeout(allocator: std.mem.Allocator, io: std.Io, label: []const u8, timeout_seconds: u64) ![]u8 {
    return fetchClientIp(allocator, io, label, timeout_seconds);
}

fn fetchClientIp(allocator: std.mem.Allocator, io: std.Io, label: []const u8, timeout_seconds: u64) ![]u8 {
    std.debug.print("[{s}] fetch-enter\n", .{label});
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    std.debug.print("[{s}] fetch-dispatch\n", .{label});
    const response = try zhttp.fetchBytesWithTimeout(allocator, &client, .{
        .url = probe_url,
        .method = .POST,
        .payload = probe_payload,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .user_agent = "Zig.DDNS.NetProbe/0.16",
    }, timeout_seconds * std.time.ms_per_s, 100);
    errdefer allocator.free(response.body);

    std.debug.print("[{s}] fetch-return status={s}\n", .{ label, @tagName(response.status) });

    if (response.status != .ok) return error.UnexpectedStatus;
    return response.body;
}
