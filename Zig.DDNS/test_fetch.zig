const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    std.debug.print("测试 fetch API with Allocating Writer...\n", .{});

    const form_data = "from=hlktech-nuget";

    // 使用 std.Io.Writer.Allocating 来自动分配和存储响应体
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://t.sc8.fun/api/client-ip" },
        .method = .POST,
        .payload = form_data,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .response_writer = &allocating_writer.writer,
    });

    std.debug.print("Status: {any}\n", .{result.status});
    std.debug.print("响应体长度: {d} 字节\n", .{allocating_writer.writer.end});

    // 读取实际写入的数据
    const body = allocating_writer.writer.buffer[0..allocating_writer.writer.end];
    std.debug.print("响应体: {s}\n", .{body});
}
