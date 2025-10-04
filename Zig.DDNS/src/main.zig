const std = @import("std");
const Zig_DDNS = @import("Zig_DDNS");

pub fn main() !void {
    // 从环境变量读取配置，方便在不同平台运行：
    // DDNS_PROVIDER=dnspod
    // DDNS_DOMAIN=example.com
    // DDNS_SUB=home
    // DDNS_TOKEN_ID=12345
    // DDNS_TOKEN=token_value
    // DDNS_INTERVAL=300 (可选)

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env = std.process.getEnvMap(allocator) catch |e| {
        std.debug.print("failed to read env: {s}\n", .{@errorName(e)});
        return e;
    };
    defer env.deinit();

    const provider_str = env.get("DDNS_PROVIDER") orelse "dnspod";
    const domain = env.get("DDNS_DOMAIN") orelse return error.MissingEnvironmentVariable;
    const sub = env.get("DDNS_SUB") orelse "@";
    const token_id = env.get("DDNS_TOKEN_ID") orelse return error.MissingEnvironmentVariable;
    const token = env.get("DDNS_TOKEN") orelse return error.MissingEnvironmentVariable;
    const interval_str = env.get("DDNS_INTERVAL") orelse "0";
    const interval = std.fmt.parseInt(u32, interval_str, 10) catch 0;

    const provider = blk: {
        if (std.ascii.eqlIgnoreCase(provider_str, "dnspod")) break :blk Zig_DDNS.Provider.dnspod;
        // 未来平台映射留口
        std.debug.print("unsupported provider: {s}\n", .{provider_str});
        return error.InvalidArgument;
    };

    const cfg = Zig_DDNS.Config{
        .provider = provider,
        .domain = domain,
        .sub_domain = sub,
        .interval_sec = interval,
        .dnspod = Zig_DDNS.ddns.DnsPodConfig{ .token_id = token_id, .token = token },
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
