// Windows 控制台全局 UTF-8 支持
// 仅在 Windows 下生效，其他平台无影响
const std = @import("std");
const Zig_DDNS = @import("Zig_DDNS");

// Windows API 函数声明（Zig 0.15.2+ 会自动使用正确的调用约定）
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) c_int;
extern "kernel32" fn SetConsoleCP(wCodePageID: u32) c_int;

pub fn main() !void {
    // Windows 控制台中文/颜色显示：设置 UTF-8 编码并启用虚拟终端处理（ANSI 序列）
    if (@import("builtin").os.tag == .windows) {
        const w = std.os.windows;

        // 设置控制台输入输出为 UTF-8 (代码页 65001)
        _ = SetConsoleOutputCP(65001);
        _ = SetConsoleCP(65001);

        // 启用虚拟终端处理（支持 ANSI 转义序列）
        const h = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
        if (h != null and h != w.INVALID_HANDLE_VALUE) {
            var m: w.DWORD = 0;
            if (w.kernel32.GetConsoleMode(h.?, &m) != 0) _ = w.kernel32.SetConsoleMode(h.?, m | 0x0004);
        }
    }
    // 优先使用配置文件 config.json；若不存在则生成模板并提示填充，再退出。
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config_path = "config.json";
    var cwd = std.fs.cwd();
    var file_exists: bool = true;
    _ = cwd.statFile(config_path) catch |e| switch (e) {
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
            "  \"interval_sec\": 300,\n" ++
            "  \"dnspod\": {\n" ++
            "    \"token_id\": \"你的TokenId\",\n" ++
            "    \"token\": \"你的Token值\",\n" ++
            "    \"line\": \"默认\"\n" ++
            "  },\n" ++
            "  \"ip_source_url\": \"https://t.sc8.fun/api/client-ip\"\n" ++
            "}\n";
        var f = try cwd.createFile(config_path, .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll(tpl);
        try print_cn("\x1b[1;33m[警告]\x1b[0m 已生成配置文件 {s}，请填入实际值后再运行。\n", .{config_path});
        return;
    }

    // 读取并解析 JSON 配置
    var f2 = try cwd.openFile(config_path, .{});
    defer f2.close();
    const data = try f2.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const json = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |e| {
        _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m 解析 config.json 失败: {s}\n", .{@errorName(e)}) catch {};
        return;
    };
    defer json.deinit();
    const root = json.value;

    if (root != .object) {
        _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m config.json 根节点必须为对象\n", .{}) catch {};
        return;
    }
    const obj = root.object;

    const provider_str = blk: {
        const v = obj.get("provider") orelse break :blk "dnspod";
        if (v != .string) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m provider 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };
    const provider = blk: {
        if (std.ascii.eqlIgnoreCase(provider_str, "dnspod")) break :blk Zig_DDNS.Provider.dnspod;
        _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m 不支持的 provider: {s}\n", .{provider_str}) catch {};
        return;
    };

    const domain = blk: {
        const v = obj.get("domain") orelse {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m 缺少 domain 字段\n", .{}) catch {};
            return;
        };
        if (v != .string) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m domain 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };
    const sub_domain = blk: {
        const maybe = obj.get("sub_domain");
        if (maybe == null) break :blk "@";
        const v = maybe.?;
        if (v != .string) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m sub_domain 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };
    const record_type = blk: {
        const maybe = obj.get("record_type");
        if (maybe == null) break :blk "A";
        const v = maybe.?;
        if (v != .string) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m record_type 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };
    const interval_sec_any = blk: {
        const maybe = obj.get("interval_sec");
        if (maybe == null) break :blk 0;
        const v = maybe.?;
        if (v != .integer) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m interval_sec 字段类型应为整数\n", .{}) catch {};
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
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m ip_source_url 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };
    const dnspod_val = obj.get("dnspod") orelse {
        _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m 缺少 dnspod 字段\n", .{}) catch {};
        return;
    };
    if (dnspod_val != .object) {
        _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m dnspod 字段类型应为对象\n", .{}) catch {};
        return;
    }
    const dnspod_obj = dnspod_val.object;
    const token_id = blk: {
        const v = dnspod_obj.get("token_id") orelse {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m 缺少 dnspod.token_id 字段\n", .{}) catch {};
            return;
        };
        if (v != .string) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m dnspod.token_id 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };
    const token = blk: {
        const v = dnspod_obj.get("token") orelse {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m 缺少 dnspod.token 字段\n", .{}) catch {};
            return;
        };
        if (v != .string) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m dnspod.token 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };
    const line = blk: {
        const maybe = dnspod_obj.get("line");
        if (maybe == null) break :blk "默认";
        const v = maybe.?;
        if (v != .string) {
            _ = print_cn("\x1b[1;31m[配置错误]\x1b[0m dnspod.line 字段类型应为字符串\n", .{}) catch {};
            return;
        }
        break :blk v.string;
    };

    const cfg = Zig_DDNS.Config{
        .provider = provider,
        .domain = domain,
        .sub_domain = sub_domain,
        .record_type = record_type,
        .interval_sec = interval_sec,
        .dnspod = Zig_DDNS.ddns.DnsPodConfig{ .token_id = token_id, .token = token, .line = line },
        .ip_source_url = ip_source_url,
    };

    // 捕获特定错误，友好处理（不显示堆栈跟踪）
    Zig_DDNS.run(cfg) catch |err| {
        switch (err) {
            error.InvalidConfiguration => {
                // 配置错误已在 dnspod_update 中打印详细信息，这里静默退出
                std.process.exit(1);
            },
            error.MissingProviderConfig => {
                std.debug.print("[错误] 缺少 Provider 配置，请检查 config.json\n", .{});
                std.process.exit(1);
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
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

// 跨平台中文打印：Windows 下使用 WriteConsoleW，其他平台回退到 std.debug.print
fn print_cn(comptime fmt: []const u8, args: anytype) !void {
    if (@import("builtin").os.tag != .windows) {
        std.debug.print(fmt, args);
        return;
    }
    // 格式化为 UTF-8 文本
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const utf8 = try std.fmt.allocPrint(alloc, fmt, args);

    // 转为 UTF-16LE 并调用 WriteConsoleW
    const w = std.os.windows;
    const h = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
    if (h == null or h == w.INVALID_HANDLE_VALUE) {
        // 退回普通打印
        std.debug.print("{s}", .{utf8});
        return;
    }
    const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, utf8);
    // WriteConsoleW 需要 UTF-16 code units 数量
    var written: w.DWORD = 0;
    _ = w.kernel32.WriteConsoleW(h.?, utf16.ptr, @as(w.DWORD, @intCast(utf16.len)), &written, null);
}
