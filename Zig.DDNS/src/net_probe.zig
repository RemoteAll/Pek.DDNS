const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;

const probe_url = "https://t.sc8.fun/api/client-ip";
const probe_payload = "from=hlktech-nuget&probe=1";
const timeout_sec: u64 = 5;

const ProbeResult = struct {
    data: ?[]u8 = null,
    err: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: compat.Mutex = .{},
};

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
    var result = ProbeResult{};
    const thread = try std.Thread.spawn(.{}, fetchWorker, .{ allocator, io, label, &result });

    const timeout_ns = timeout_seconds * std.time.ns_per_s;
    const start = compat.nanoTimestamp();

    while (true) {
        if (result.completed.load(.acquire)) {
            thread.join();

            result.mutex.lock();
            defer result.mutex.unlock();

            if (result.err) |err| return err;
            if (result.data) |data| return data;
            return error.UnknownError;
        }

        if (compat.nanoTimestamp() - start >= timeout_ns) {
            std.debug.print("[{s}] timeout after {d}s while waiting for fetch\n", .{ label, timeout_seconds });
            thread.detach();
            return error.RequestTimeout;
        }

        compat.sleep(100 * std.time.ns_per_ms);
    }
}

fn fetchWorker(allocator: std.mem.Allocator, io: std.Io, label: []const u8, result: *ProbeResult) void {
    std.debug.print("[{s}] worker-start\n", .{label});
    defer result.completed.store(true, .release);

    const body = fetchClientIp(allocator, io, label) catch |err| {
        result.mutex.lock();
        defer result.mutex.unlock();
        result.err = err;
        return;
    };

    result.mutex.lock();
    defer result.mutex.unlock();
    result.data = body;
}

fn fetchClientIp(allocator: std.mem.Allocator, io: std.Io, label: []const u8) ![]u8 {
    std.debug.print("[{s}] fetch-enter\n", .{label});
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();
    std.debug.print("[{s}] fetch-dispatch\n", .{label});
    const result = try client.fetch(.{
        .location = .{ .url = probe_url },
        .method = .POST,
        .payload = probe_payload,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "Zig.DDNS.NetProbe/0.16" },
        },
        .response_writer = &allocating_writer.writer,
    });
    std.debug.print("[{s}] fetch-return status={s}\n", .{ label, @tagName(result.status) });

    if (result.status != .ok) return error.UnexpectedStatus;
    return try allocator.dupe(u8, allocating_writer.writer.buffer[0..allocating_writer.writer.end]);
}
