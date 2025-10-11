const std = @import("std");
const Zig_DDNS = @import("Zig_DDNS");

pub fn main() !void {
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
        std.debug.print("已生成配置文件 {s}，请填入实际值后再运行。\n", .{config_path});
        return;
    }

    // 读取并解析 JSON 配置
    var f2 = try cwd.openFile(config_path, .{});
    defer f2.close();
    const data = try f2.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    const json = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer json.deinit();
    const root = json.value;

    if (root != .object) return error.InvalidArgument;
    const obj = root.object;

    const provider_str = blk: {
        const v = obj.get("provider") orelse break :blk "dnspod";
        if (v != .string) break :blk "dnspod";
        break :blk v.string;
    };
    const provider = blk: {
        if (std.ascii.eqlIgnoreCase(provider_str, "dnspod")) break :blk Zig_DDNS.Provider.dnspod;
        std.debug.print("unsupported provider: {s}\n", .{provider_str});
        return error.InvalidArgument;
    };

    const domain = blk: {
        const v = obj.get("domain") orelse return error.MissingEnvironmentVariable;
        if (v != .string) return error.InvalidArgument;
        break :blk v.string;
    };
    const sub_domain = blk: {
        const maybe = obj.get("sub_domain");
        if (maybe == null) break :blk "@";
        const v = maybe.?;
        if (v != .string) break :blk "@";
        break :blk v.string;
    };
    const record_type = blk: {
        const maybe = obj.get("record_type");
        if (maybe == null) break :blk "A";
        const v = maybe.?;
        if (v != .string) break :blk "A";
        break :blk v.string;
    };
    const interval_sec_any = blk: {
        const maybe = obj.get("interval_sec");
        if (maybe == null) break :blk 0;
        const v = maybe.?;
        if (v != .integer) break :blk 0;
        break :blk v.integer;
    };
    const interval_sec = @as(u32, @intCast(interval_sec_any));
    const ip_source_url = blk: {
        const maybe = obj.get("ip_source_url");
        if (maybe == null) break :blk "https://t.sc8.fun/api/client-ip";
        const v = maybe.?;
        if (v != .string) break :blk "https://t.sc8.fun/api/client-ip";
        break :blk v.string;
    };
    const dnspod_val = obj.get("dnspod") orelse return error.MissingEnvironmentVariable;
    if (dnspod_val != .object) return error.InvalidArgument;
    const dnspod_obj = dnspod_val.object;
    const token_id = blk: {
        const v = dnspod_obj.get("token_id") orelse return error.MissingEnvironmentVariable;
        if (v != .string) return error.InvalidArgument;
        break :blk v.string;
    };
    const token = blk: {
        const v = dnspod_obj.get("token") orelse return error.MissingEnvironmentVariable;
        if (v != .string) return error.InvalidArgument;
        break :blk v.string;
    };
    const line = blk: {
        const maybe = dnspod_obj.get("line");
        if (maybe == null) break :blk "默认";
        const v = maybe.?;
        if (v != .string) break :blk "默认";
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

    try Zig_DDNS.run(cfg);
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
