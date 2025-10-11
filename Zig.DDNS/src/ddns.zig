const std = @import("std");

pub const Provider = enum {
    dnspod,
    // 未来可扩展更多平台: cloudflare, alicloud, huawei, aws_route53, etc.
};

pub const Config = struct {
    provider: Provider,
    // 解析记录基本信息
    domain: []const u8, // 主域名，如 example.com
    sub_domain: []const u8, // 子域名/主机记录，如 @、www、home
    record_type: []const u8 = "A", // 默认为 A 记录
    // 轮询/执行模式
    interval_sec: u32 = 300, // 轮询更新周期，0 表示只执行一次
    // Provider 专属配置（以 union 方式未来承载更多平台专属字段）
    dnspod: ?DnsPodConfig = null,
    // 网络设置
    ip_source_url: []const u8 = "https://t.sc8.fun/api/client-ip", // 查询公网 IPv4 地址（JSON 数组返回）
};

pub const DnsPodConfig = struct {
    token_id: []const u8, // 登录 token 的 id
    token: []const u8, // token 值
    // 可选：记录线路, 例如 默认
    line: []const u8 = "默认",
};

pub fn run(config: Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (config.interval_sec == 0) {
        try runOnce(allocator, config);
        return;
    }

    while (true) {
        try runOnce(allocator, config);
        // 简单睡眠；在 CLI 模式下足够使用
        std.Thread.sleep(config.interval_sec * std.time.ns_per_s);
    }
}

fn runOnce(allocator: std.mem.Allocator, config: Config) !void {
    const ip = try fetchPublicIPv4(allocator, config.ip_source_url);
    defer allocator.free(ip);
    switch (config.provider) {
        .dnspod => try providers.dnspod_update(allocator, config, ip),
    }
}

fn fetchPublicIPv4(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    // 使用 Zig 0.15.1+ 内置 HTTP 客户端获取公网 IP
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buffer: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const body = try response.reader(&.{}).allocRemaining(allocator, .unlimited);

    // 期望返回格式：
    // [
    //   {
    //     "Ip": "113.87.xxx.xxx",
    //     "Type": "IPv4",
    //     "SourceHeader": "X-Real-IP",
    //     "FromForwardedHeader": true
    //   }
    // ]
    // 这里进行轻量 JSON 解析，提取 Type 为 IPv4 的 Ip 字段。
    const ip_field = try parseClientIpJson(allocator, body);
    allocator.free(body);
    return ip_field;
}

fn parseClientIpJson(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    // 简易解析：查找 IPv4 条目并提取 Ip 值。为避免引入完整 JSON 解析，采用字符串搜索。
    const type_key = "\"Type\":\"IPv4\"";
    const ip_key = "\"Ip\":\"";

    const type_pos = std.mem.indexOf(u8, json, type_key) orelse {
        // 若找不到 IPv4 类型，尝试直接提取第一个 Ip 字段
        const ip_pos_fallback = std.mem.indexOf(u8, json, ip_key) orelse return error.InvalidFormat;
        const ip_slice_fallback = json[ip_pos_fallback + ip_key.len ..];
        const ip_end_fallback = std.mem.indexOf(u8, ip_slice_fallback, "\"") orelse return error.InvalidFormat;
        return allocator.dupe(u8, ip_slice_fallback[0..ip_end_fallback]);
    };

    // 从 type 位置向前查找最近的 Ip 键
    const search_window_start: usize = 0;
    const window = json[search_window_start..type_pos];
    const ip_pos_rel = std.mem.lastIndexOf(u8, window, ip_key) orelse return error.InvalidFormat;
    const ip_slice = window[ip_pos_rel + ip_key.len ..];
    const ip_end = std.mem.indexOf(u8, ip_slice, "\"") orelse return error.InvalidFormat;
    return allocator.dupe(u8, ip_slice[0..ip_end]);
}

fn runReadCmd(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]u8 {
    var argv = try allocator.alloc([]const u8, 1 + args.len);
    defer allocator.free(argv);
    argv[0] = exe;
    for (args, 0..) |a, i| argv[i + 1] = a;
    const res = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    switch (res.term) {
        .Exited => |code| {
            if (code != 0) return error.ProcessFailed;
        },
        else => return error.ProcessFailed,
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \r\n\t");
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(res.stdout);
    return out;
}

fn runPowerShell(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const args_pwsh = [_][]const u8{ "-NoProfile", "-Command", command };
    return runReadCmd(allocator, "pwsh", &args_pwsh) catch {
        const args_ps = [_][]const u8{ "-NoProfile", "-Command", command };
        return runReadCmd(allocator, "powershell", &args_ps);
    };
}

const providers = struct {
    pub fn dnspod_update(allocator: std.mem.Allocator, config: Config, ip: []const u8) !void {
        if (config.dnspod == null) return error.MissingProviderConfig;
        const dp = config.dnspod.?;

        // DNSPod API: https://docs.dnspod.cn/api/5f26a529e5b5810a610d3714/
        // 主要步骤：
        // 1) 获取记录列表，找到指定 domain/sub_domain 的记录（Record.List）
        // 2) 若不存在则创建（Record.Create）
        // 3) 若存在且值不同，则更新（Record.Modify）

        const record = try dnspod_find_record(allocator, dp, config.domain, config.sub_domain, config.record_type);
        if (record == null) {
            try dnspod_create_record(allocator, dp, config.domain, config.sub_domain, config.record_type, ip, config);
            std.debug.print("[dnspod] created record {s}.{s} -> {s}\n", .{ config.sub_domain, config.domain, ip });
        } else {
            const r = record.?;
            if (!std.mem.eql(u8, r.value, ip)) {
                try dnspod_modify_record(allocator, dp, r.id, config.domain, config.sub_domain, config.record_type, ip, config);
                std.debug.print("[dnspod] updated record {s}.{s} -> {s}\n", .{ config.sub_domain, config.domain, ip });
            } else {
                std.debug.print("[dnspod] no change for {s}.{s} (ip={s})\n", .{ config.sub_domain, config.domain, ip });
            }
            allocator.free(r.id);
            allocator.free(r.value);
        }
    }

    const DnsPodRecord = struct { id: []const u8, value: []const u8 };

    fn dnspod_find_record(allocator: std.mem.Allocator, dp: DnsPodConfig, domain: []const u8, sub: []const u8, rtype: []const u8) !?DnsPodRecord {
        // POST https://dnsapi.cn/Record.List
        // params: login_token, format=json, domain, sub_domain, record_type
        const body = try std.fmt.allocPrint(
            allocator,
            "login_token={s},{s}&format=json&domain={s}&sub_domain={s}&record_type={s}",
            .{ dp.token_id, dp.token, domain, sub, rtype },
        );
        defer allocator.free(body);
        const resp = try httpPostForm(allocator, "https://dnsapi.cn/Record.List", body);
        defer allocator.free(resp);
        // 简易解析：查找 "records":[{...}] 中第一条的 id 与 value
        const id_key = "\"id\":\"";
        const value_key = "\"value\":\"";
        const id_start = std.mem.indexOf(u8, resp, id_key) orelse return null;
        const id_slice = resp[id_start + id_key.len ..];
        const id_rel_end = std.mem.indexOf(u8, id_slice, "\"") orelse return null;
        const id_val = id_slice[0..id_rel_end];

        const val_start = std.mem.indexOf(u8, resp, value_key) orelse return null;
        const val_slice = resp[val_start + value_key.len ..];
        const val_rel_end = std.mem.indexOf(u8, val_slice, "\"") orelse return null;
        const value_val = val_slice[0..val_rel_end];

        // 复制切片，避免释放 resp 后悬挂
        const id_copy = try allocator.dupe(u8, id_val);
        const val_copy = try allocator.dupe(u8, value_val);
        return DnsPodRecord{ .id = id_copy, .value = val_copy };
    }

    fn dnspod_create_record(allocator: std.mem.Allocator, dp: DnsPodConfig, domain: []const u8, sub: []const u8, rtype: []const u8, ip: []const u8, cfg: Config) !void {
        const body = try std.fmt.allocPrint(
            allocator,
            "login_token={s},{s}&format=json&domain={s}&sub_domain={s}&record_type={s}&record_line={s}&value={s}",
            .{ dp.token_id, dp.token, domain, sub, rtype, cfg.dnspod.?.line, ip },
        );
        defer allocator.free(body);
        const resp = try httpPostForm(allocator, "https://dnsapi.cn/Record.Create", body);
        defer allocator.free(resp);
        // 可加入状态检查，这里简化为成功只要返回中包含 "code":"1"
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }

    fn dnspod_modify_record(allocator: std.mem.Allocator, dp: DnsPodConfig, record_id: []const u8, domain: []const u8, sub: []const u8, rtype: []const u8, ip: []const u8, cfg: Config) !void {
        const body = try std.fmt.allocPrint(
            allocator,
            "login_token={s},{s}&format=json&domain={s}&record_id={s}&sub_domain={s}&record_type={s}&record_line={s}&value={s}",
            .{ dp.token_id, dp.token, domain, record_id, sub, rtype, cfg.dnspod.?.line, ip },
        );
        defer allocator.free(body);
        const resp = try httpPostForm(allocator, "https://dnsapi.cn/Record.Modify", body);
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }
};

fn httpPostForm(allocator: std.mem.Allocator, url: []const u8, body: []const u8) ![]u8 {
    // 使用 Zig 0.15.1+ 内置 HTTP 客户端 POST 表单
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        },
    });
    defer req.deinit();
    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBody(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    var redirect_buffer: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    const resp_body = try response.reader(&.{}).allocRemaining(allocator, .unlimited);
    return resp_body;
}
