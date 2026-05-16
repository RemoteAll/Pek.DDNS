// Windows 控制台全局 UTF-8 支持
// 仅在 Windows 下生效，其他平台无影响
const std = @import("std");
const Zig_DDNS = @import("Zig_DDNS");
const zzig = Zig_DDNS.zzig;
const logger = Zig_DDNS.logger;

/// 跨平台等待用户按键，避免窗口一闪而过
fn waitForKeyPress() void {
    logger.info("按任意键退出...", .{});
    _ = zzig.Input.readKey() catch {};
}

/// 配置错误退出：显示错误信息后等待用户按键（跨平台）
fn configError() noreturn {
    waitForKeyPress();
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const console_result = zzig.Console.init(.{});
    defer zzig.Console.deinit(console_result);
    logger.enableThreadSafe();

    // 优先使用配置文件 config.json；若不存在则生成模板并提示填充，再退出。
    const allocator = init.gpa;
    const io = init.io;

    const config_path = "config.json";
    const cwd = std.Io.Dir.cwd();
    var file_exists: bool = true;
    _ = cwd.statFile(io, config_path, .{}) catch |e| switch (e) {
        error.FileNotFound => file_exists = false,
        else => return e,
    };

    if (!file_exists) {
        const tpl =
            "{\n" ++
            "  \"provider\": \"dnspod\",\n" ++
            "  \"domain\": \"example.com\",\n" ++
            "  \"sub_domain\": \"www\",\n" ++
            "  \"record_type\": \"A\",\n" ++
            "  \"interval_sec\": 60,\n" ++
            "  \"dnspod\": {\n" ++
            "    \"token_id\": \"你的TokenId\",\n" ++
            "    \"token\": \"你的Token值\",\n" ++
            "    \"line\": \"默认\",\n" ++
            "    \"ttl\": 60\n" ++
            "  },\n" ++
            "  \"ip_source_url\": \"https://t.sc8.fun/api/client-ip\"\n" ++
            "}\n";
        var f = try cwd.createFile(io, config_path, .{ .read = true, .truncate = true });
        defer f.close(io);

        var writer_buffer: [4096]u8 = undefined;
        var writer = std.Io.File.Writer.init(f, io, &writer_buffer);
        try writer.interface.writeAll(tpl);
        try writer.flush();
        logger.warn("已生成配置文件 {s}，请填入实际值后再运行。", .{config_path});
        configError();
    }

    // 读取并解析 JSON 配置
    var f2 = try cwd.openFile(io, config_path, .{});
    defer f2.close(io);

    const file_stat = try f2.stat(io);
    var reader_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.init(f2, io, &reader_buffer);
    const data = try reader.interface.readAlloc(allocator, @intCast(file_stat.size));
    defer allocator.free(data);

    const json = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |e| {
        logger.err("解析 config.json 失败: {s}", .{@errorName(e)});
        logger.err("请检查 JSON 语法是否正确", .{});
        configError();
    };
    defer json.deinit();
    const root = json.value;

    if (root != .object) {
        logger.err("config.json 根节点必须为对象", .{});
        configError();
    }
    const obj = root.object;

    const provider_str = blk: {
        const v = obj.get("provider") orelse break :blk "dnspod";
        if (v != .string) {
            logger.err("provider 字段类型应为字符串", .{});
            return;
        }
        break :blk v.string;
    };
    const provider = blk: {
        if (std.ascii.eqlIgnoreCase(provider_str, "dnspod")) break :blk Zig_DDNS.Provider.dnspod;
        logger.err("不支持的 provider: {s}", .{provider_str});
        configError();
    };

    const domain = blk: {
        const v = obj.get("domain") orelse {
            logger.err("缺少 domain 字段", .{});
            configError();
        };
        if (v != .string) {
            logger.err("domain 字段类型应为字符串", .{});
            configError();
        }
        break :blk v.string;
    };
    // 解析 sub_domain 字段，支持逗号或分号分隔的多个子域名
    // 例如 "www" / "www,@,home" / "www;home"
    const sub_domains = blk: {
        const maybe = obj.get("sub_domain");
        const raw: []const u8 = if (maybe) |v| blk2: {
            if (v != .string) {
                logger.err("sub_domain 字段类型应为字符串", .{});
                return;
            }
            break :blk2 v.string;
        } else "@"; // 默认子域名为根域名
        break :blk zzig.Strings.splitMulti(allocator, raw, ",;") catch |e| {
            logger.err("解析 sub_domain 字段失败: {s}", .{@errorName(e)});
            configError();
        };
    };
    const record_type = blk: {
        const maybe = obj.get("record_type");
        if (maybe == null) break :blk "A";
        const v = maybe.?;
        if (v != .string) {
            logger.err("record_type 字段类型应为字符串", .{});
            return;
        }
        break :blk v.string;
    };
    const interval_sec_any = blk: {
        const maybe = obj.get("interval_sec");
        if (maybe == null) break :blk 0;
        const v = maybe.?;
        if (v != .integer) {
            logger.err("interval_sec 字段类型应为整数", .{});
            return;
        }
        break :blk v.integer;
    };
    const interval_sec = @as(u32, @intCast(interval_sec_any));
    const ip_source_url = blk: {
        const maybe = obj.get("ip_source_url");
        if (maybe == null) break :blk "https://t.sc8.fun/api/client-ip";
        const v = maybe.?;
        if (v != .string) {
            logger.err("ip_source_url 字段类型应为字符串", .{});
            return;
        }
        break :blk v.string;
    };
    const dnspod_val = obj.get("dnspod") orelse {
        logger.err("缺少 dnspod 字段", .{});
        return;
    };
    if (dnspod_val != .object) {
        logger.err("dnspod 字段类型应为对象", .{});
        return;
    }
    const dnspod_obj = dnspod_val.object;
    const token_id = blk: {
        const v = dnspod_obj.get("token_id") orelse {
            logger.err("缺少 dnspod.token_id 字段", .{});
            return;
        };
        if (v != .string) {
            logger.err("dnspod.token_id 字段类型应为字符串", .{});
            return;
        }
        break :blk v.string;
    };
    const token = blk: {
        const v = dnspod_obj.get("token") orelse {
            logger.err("缺少 dnspod.token 字段", .{});
            return;
        };
        if (v != .string) {
            logger.err("dnspod.token 字段类型应为字符串", .{});
            return;
        }
        break :blk v.string;
    };
    const line = blk: {
        const maybe = dnspod_obj.get("line");
        if (maybe == null) break :blk "默认";
        const v = maybe.?;
        if (v != .string) {
            logger.err("dnspod.line 字段类型应为字符串", .{});
            return;
        }
        break :blk v.string;
    };
    const ttl_any = blk: {
        const maybe = dnspod_obj.get("ttl");
        if (maybe == null) break :blk 600; // 默认 600 秒
        const v = maybe.?;
        if (v != .integer) {
            logger.err("dnspod.ttl 字段类型应为整数", .{});
            return;
        }
        break :blk v.integer;
    };
    const ttl = @as(u32, @intCast(ttl_any));

    const cfg = Zig_DDNS.Config{
        .provider = provider,
        .domain = domain,
        .sub_domains = sub_domains,
        .record_type = record_type,
        .interval_sec = interval_sec,
        .dnspod = Zig_DDNS.ddns.DnsPodConfig{ .token_id = token_id, .token = token, .line = line, .ttl = ttl },
        .ip_source_url = ip_source_url,
    };

    Zig_DDNS.configureIo(io);

    // 捕获特定错误，友好处理（不显示堆栈跟踪）
    Zig_DDNS.run(cfg) catch |err| {
        switch (err) {
            error.InvalidConfiguration => {
                // 配置错误已在 dnspod_update 中打印详细信息，等待用户按键后退出
                configError();
            },
            error.MissingProviderConfig => {
                std.debug.print("[错误] 缺少 Provider 配置，请检查 config.json\n", .{});
                std.process.exit(1);
            },
            error.HttpConnectionClosing => {
                std.debug.print("\n[致命错误] HTTP 连接被服务器关闭\n", .{});
                std.debug.print("[可能原因]\n", .{});
                std.debug.print("  1. DNSPod API 服务器与 Zig HTTP 客户端存在兼容性问题\n", .{});
                std.debug.print("  2. TLS 握手或 HTTP 协议协商失败\n", .{});
                std.debug.print("  3. 网络环境限制（防火墙、代理等）\n", .{});
                std.debug.print("\n[建议措施]\n", .{});
                std.debug.print("  • 检查网络连接和防火墙设置\n", .{});
                std.debug.print("  • 尝试使用其他网络环境\n", .{});
                std.process.exit(1);
            },
            error.PartialUpdateFailure => {
                // 部分子域名更新失败，已在循环中记录，正常退出
            },
            else => {
                // 其他错误继续抛出，显示堆栈跟踪以便调试
                return err;
            },
        }
    };
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), smith: *std.testing.Smith) anyerror!void {
            _ = context;
            var input: [32]u8 = undefined;
            const len = @as(usize, smith.valueRangeAtMost(u8, 0, 32));
            smith.bytes(input[0..len]);
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input[0..len]));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
