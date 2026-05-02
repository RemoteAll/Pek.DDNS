const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("\n=== Zig 0.16 原生 HTTP 功能验证 ===\n\n", .{});

    std.debug.print("[测试1] HTTP GET - httpbin.org/get\n", .{});
    if (testHttpGet(allocator, io)) |body| {
        defer allocator.free(body);
        std.debug.print("  GET ok, len={d}\n", .{body.len});
        const preview = if (body.len > 200) body[0..200] else body;
        std.debug.print("  body: {s}\n\n", .{preview});
    } else |err| std.debug.print("  GET fail: {s}\n\n", .{@errorName(err)});

    std.debug.print("[测试2] HTTP POST form - t.sc8.fun/api/client-ip\n", .{});
    if (testHttpPostForm(allocator, io)) |body| {
        defer allocator.free(body);
        std.debug.print("  POST form ok, len={d}\n", .{body.len});
        const preview = if (body.len > 200) body[0..200] else body;
        std.debug.print("  body: {s}\n\n", .{preview});
    } else |err| std.debug.print("  POST form fail: {s}\n\n", .{@errorName(err)});

    std.debug.print("[测试3] HTTP POST JSON - httpbin.org/post\n", .{});
    if (testHttpPostJson(allocator, io)) |body| {
        defer allocator.free(body);
        std.debug.print("  POST JSON ok, len={d}\n", .{body.len});
        const preview = if (body.len > 300) body[0..300] else body;
        std.debug.print("  body: {s}\n\n", .{preview});
    } else |err| std.debug.print("  POST JSON fail: {s}\n\n", .{@errorName(err)});

    std.debug.print("[测试4] HTTP GET + custom header - httpbin.org/headers\n", .{});
    if (testHttpGetWithHeaders(allocator, io)) |body| {
        defer allocator.free(body);
        std.debug.print("  GET+Headers ok, len={d}\n", .{body.len});
        const preview = if (body.len > 300) body[0..300] else body;
        std.debug.print("  body: {s}\n\n", .{preview});
    } else |err| std.debug.print("  GET+Headers fail: {s}\n\n", .{@errorName(err)});

    std.debug.print("[测试5] 复用Client连续请求\n", .{});
    if (testReuseClient(allocator, io)) |_| {
        std.debug.print("  复用Client ok\n\n", .{});
    } else |err| std.debug.print("  复用Client fail: {s}\n\n", .{@errorName(err)});

    std.debug.print("=== 验证完成 ===\n", .{});
}

fn testHttpGet(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://httpbin.org/get" },
        .method = .GET,
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.UnexpectedStatus;
    return try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

fn testHttpPostForm(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://t.sc8.fun/api/client-ip" },
        .method = .POST,
        .payload = "from=hlktech-nuget&test=true",
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.UnexpectedStatus;
    return try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

fn testHttpPostJson(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://httpbin.org/post" },
        .method = .POST,
        .payload = "{\"hello\":\"world\",\"zig\":16}",
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "Zig-HttpTest/0.16" },
        },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.UnexpectedStatus;
    return try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

fn testHttpGetWithHeaders(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://httpbin.org/headers" },
        .method = .GET,
        .headers = .{
            .user_agent = .{ .override = "Zig-HttpTest/0.16" },
        },
        .response_writer = &aw.writer,
    });

    if (result.status != .ok) return error.UnexpectedStatus;
    return try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
}

fn testReuseClient(allocator: std.mem.Allocator, io: std.Io) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    for (0..3) |i| {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = "https://httpbin.org/get" },
            .method = .GET,
            .response_writer = &aw.writer,
        });

        if (result.status != .ok) return error.UnexpectedStatus;
        std.debug.print("  #{d} len={d}\n", .{ i + 1, aw.writer.end });
    }
}

test "http get" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const body = try testHttpGet(allocator, io);
    defer allocator.free(body);
    try std.testing.expect(body.len > 0);
}

test "http post form" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const body = try testHttpPostForm(allocator, io);
    defer allocator.free(body);
    try std.testing.expect(body.len > 0);
}
