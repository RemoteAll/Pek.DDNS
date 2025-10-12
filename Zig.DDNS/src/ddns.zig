const std = @import("std");
const json_utils = @import("json_utils.zig");

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
        std.Thread.sleep(@as(u64, config.interval_sec) * std.time.ns_per_s);
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
    defer allocator.free(body);
    // 打印是否检测到压缩（通过 gzip 魔数）
    const is_gzip = isGzipMagic(body);
    std.debug.print("[ip-source encoding] gzip_magic={any}\n", .{is_gzip});
    if (is_gzip) {
        const unzipped = try gzipDecompress(allocator, body);
        std.debug.print("[ip-source gunzip] {s}\n", .{unzipped});
        defer allocator.free(unzipped);
        // 使用通用 JSON 工具库提取 Type 为 IPv4 的 Ip 字段
        const ip_field = try json_utils.quickGetStringFromArray(allocator, unzipped, .{
            .match_key = "Type",
            .match_value = "IPv4",
            .target_key = "Ip",
        });
        return ip_field;
    } else {
        // 打印接口返回的原始数据，便于观察/调试
        std.debug.print("[ip-source raw] {s}\n", .{body});
        // 使用通用 JSON 工具库提取 Type 为 IPv4 的 Ip 字段
        const ip_field = try json_utils.quickGetStringFromArray(allocator, body, .{
            .match_key = "Type",
            .match_value = "IPv4",
            .target_key = "Ip",
        });
        return ip_field;
    }
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

        // 验证配置是否为默认占位符
        if (std.mem.indexOf(u8, dp.token_id, "TokenId") != null or
            std.mem.indexOf(u8, dp.token, "Token") != null)
        {
            std.debug.print("[错误] 请在 config.json 中配置真实的 DNSPod API Token\n", .{});
            std.debug.print("[提示] token_id 和 token 当前仍为占位符，请访问 https://console.dnspod.cn/account/token/apikey 获取\n", .{});
            return error.InvalidConfiguration;
        }

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
        const body = try allocFormEncoded(allocator, &.{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
        });
        defer allocator.free(body);
        std.debug.print("[dnspod] Record.List domain={s} sub_domain={s} type={s}\n", .{ domain, sub, rtype });

        const resp = try httpPostForm(allocator, "https://dnsapi.cn/Record.List", body);
        defer allocator.free(resp);
        // 打印接口原始 JSON（完整）
        std.debug.print("[dnspod response] {s}\n", .{resp});
        printDnspodStatus(allocator, resp);
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
        const body = try allocFormEncoded(allocator, &.{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
            .{ .key = "record_line", .v1 = cfg.dnspod.?.line, .v2 = "" },
            .{ .key = "value", .v1 = ip, .v2 = "" },
        });
        defer allocator.free(body);
        const resp = try httpPostForm(allocator, "https://dnsapi.cn/Record.Create", body);
        defer allocator.free(resp);
        std.debug.print("[dnspod response] {s}\n", .{resp});
        printDnspodStatus(allocator, resp);
        // 可加入状态检查，这里简化为成功只要返回中包含 "code":"1"
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }

    fn dnspod_modify_record(allocator: std.mem.Allocator, dp: DnsPodConfig, record_id: []const u8, domain: []const u8, sub: []const u8, rtype: []const u8, ip: []const u8, cfg: Config) !void {
        const body = try allocFormEncoded(allocator, &.{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "record_id", .v1 = record_id, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
            .{ .key = "record_line", .v1 = cfg.dnspod.?.line, .v2 = "" },
            .{ .key = "value", .v1 = ip, .v2 = "" },
        });
        defer allocator.free(body);
        const resp = try httpPostForm(allocator, "https://dnsapi.cn/Record.Modify", body);
        defer allocator.free(resp);
        std.debug.print("[dnspod response] {s}\n", .{resp});
        printDnspodStatus(allocator, resp);
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }
};

fn httpPostForm(allocator: std.mem.Allocator, url: []const u8, body: []const u8) ![]u8 {
    // 使用 Zig 0.15.2+ 内置 HTTP 客户端 POST 表单
    std.debug.print("[httpPostForm] 开始创建 HTTP 客户端...\n", .{});
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    std.debug.print("[httpPostForm] 解析 URI: {s}\n", .{url});
    const uri = try std.Uri.parse(url);

    std.debug.print("[httpPostForm] 创建 POST 请求...\n", .{});
    // 创建请求，添加完整的 HTTP 头（模拟标准浏览器/工具行为）
    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "user-agent", .value = "Zig-DDNS/1.0" },
            .{ .name = "accept", .value = "*/*" },
            .{ .name = "accept-encoding", .value = "gzip, deflate" },
            .{ .name = "connection", .value = "keep-alive" },
        },
    });
    defer req.deinit();

    std.debug.print("[httpPostForm] 设置请求体长度: {d} 字节\n", .{body.len});
    // 设置请求体长度
    req.transfer_encoding = .{ .content_length = body.len };

    std.debug.print("[httpPostForm] 发送请求体...\n", .{});
    // 发送请求体
    var body_writer = try req.sendBody(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();

    std.debug.print("[httpPostForm] 等待接收响应头...\n", .{});
    // 接收响应
    var redirect_buffer: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        std.debug.print("[httpPostForm ERROR] ❌ 接收响应头失败: {any}\n", .{err});
        std.debug.print("[httpPostForm ERROR] 这通常意味着服务器在 HTTP 层之前就关闭了连接\n", .{});
        std.debug.print("[httpPostForm ERROR] 可能原因：\n", .{});
        std.debug.print("[httpPostForm ERROR]   1) TLS 握手失败（证书问题）\n", .{});
        std.debug.print("[httpPostForm ERROR]   2) 服务器检测到无效的认证信息直接断开\n", .{});
        std.debug.print("[httpPostForm ERROR]   3) 请求格式不符合服务器要求\n", .{});
        std.debug.print("[httpPostForm ERROR]   4) 网络层面的连接问题\n", .{});
        if (err == error.HttpConnectionClosing) {
            std.debug.print("[httpPostForm Fallback] 尝试使用 PowerShell Invoke-WebRequest 执行 POST...\n", .{});
            const escaped_body = try escapeForPSSingleQuoted(allocator, body);
            defer allocator.free(escaped_body);
            const ps_cmd = try std.fmt.allocPrint(
                allocator,
                "Invoke-WebRequest -Method POST -Uri '{s}' -Body '{s}' -ContentType 'application/x-www-form-urlencoded' -UserAgent 'Zig-DDNS/1.0' | Select-Object -ExpandProperty Content",
                .{ url, escaped_body },
            );
            defer allocator.free(ps_cmd);
            const ps_out = try runPowerShell(allocator, ps_cmd);
            return ps_out;
        }
        return err;
    };

    // 能走到这里说明成功接收到响应头
    std.debug.print("[httpPostForm] ✓ 响应接收成功\n", .{});
    std.debug.print("[httpPostForm] 读取响应体...\n", .{});
    const resp_buf = try response.reader(&.{}).allocRemaining(allocator, .unlimited);
    defer allocator.free(resp_buf);

    std.debug.print("[post encoding] gzip_magic={any}\n", .{isGzipMagic(resp_buf)});
    if (isGzipMagic(resp_buf)) {
        const unzipped = try gzipDecompress(allocator, resp_buf);
        // 返回前复制一份，保证释放本地缓冲不会影响调用方
        const out = try allocator.dupe(u8, unzipped);
        allocator.free(unzipped);
        return out;
    }
    // 返回前复制一份，保证释放本地缓冲不会影响调用方
    const out = try allocator.dupe(u8, resp_buf);
    return out;
}

// 打印 DNSPod 返回中的 status.code 与 status.message，若无法解析，打印前 200 字节作为诊断
fn printDnspodStatus(allocator: std.mem.Allocator, resp: []const u8) void {
    const code_key = "\"code\":\"";
    const msg_key = "\"message\":\"";
    const code_start = std.mem.indexOf(u8, resp, code_key);
    const msg_start = std.mem.indexOf(u8, resp, msg_key);
    if (code_start) |cs| if (msg_start) |ms| {
        const c_slice = resp[cs + code_key.len ..];
        const m_slice = resp[ms + msg_key.len ..];
        const c_end_rel = std.mem.indexOfScalar(u8, c_slice, '"') orelse 0;
        const m_end_rel = std.mem.indexOfScalar(u8, m_slice, '"') orelse 0;
        const code = c_slice[0..c_end_rel];
        const message_raw = m_slice[0..m_end_rel];
        const decoded = unicodeUnescapeJson(allocator, message_raw) catch {
            std.debug.print("[dnspod status] code={s} message={s}\n", .{ code, message_raw });
            return;
        };
        defer allocator.free(decoded);
        std.debug.print("[dnspod status] code={s} message={s}\n", .{ code, decoded });
        return;
    };
    const max = if (resp.len > 200) 200 else resp.len;
    std.debug.print("[dnspod status] raw: {s}...\n", .{resp[0..max]});
}

// 将 JSON 字符串中的 \uXXXX 转义解码为 UTF-8。简单实现：只处理 \u 后跟 4 个十六进制。
fn unicodeUnescapeJson(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 5 < s.len and s[i + 1] == 'u') {
            const h0 = s[i + 2];
            const h1 = s[i + 3];
            const h2 = s[i + 4];
            const h3 = s[i + 5];
            const val = (hexVal(h0) << 12) | (hexVal(h1) << 8) | (hexVal(h2) << 4) | hexVal(h3);
            // 只处理基本多文种平面 BMP（不合并代理对），足以覆盖中文提示
            // 手动 UTF-8 编码（覆盖 0..0xFFFF 范围）
            const cp: u21 = @as(u21, @intCast(val));
            if (cp <= 0x7F) {
                try out.append(allocator, @as(u8, @intCast(cp)));
            } else if (cp <= 0x7FF) {
                try out.append(allocator, 0xC0 | @as(u8, @intCast((cp >> 6) & 0x1F)));
                try out.append(allocator, 0x80 | @as(u8, @intCast(cp & 0x3F)));
            } else {
                try out.append(allocator, 0xE0 | @as(u8, @intCast((cp >> 12) & 0x0F)));
                try out.append(allocator, 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F)));
                try out.append(allocator, 0x80 | @as(u8, @intCast(cp & 0x3F)));
            }
            i += 5; // 跳过 \uXXXX
        } else {
            try out.append(allocator, s[i]);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) u21 {
    return switch (c) {
        '0'...'9' => @as(u21, c - '0'),
        'a'...'f' => @as(u21, 10 + c - 'a'),
        'A'...'F' => @as(u21, 10 + c - 'A'),
        else => 0,
    };
}

// isGzipMagic 已在上文定义，这里不重复定义
fn isGzipMagic(buf: []const u8) bool {
    return buf.len >= 2 and buf[0] == 0x1F and buf[1] == 0x8B;
}

// 将字符串转换为 PowerShell 单引号字面量安全形式：将 ' 替换为 ''
fn escapeForPSSingleQuoted(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, src, '\'') == null) return allocator.dupe(u8, src);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    try list.ensureTotalCapacityPrecise(allocator, src.len + 8);
    for (src) |c| {
        if (c == '\'') {
            try list.appendSlice(allocator, "''");
        } else {
            try list.append(allocator, c);
        }
    }
    return list.toOwnedSlice(allocator);
}

// x-www-form-urlencoded 编码（最小实现）
fn urlFormEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, s.len + s.len / 4);
    const HEX = "0123456789ABCDEF";
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(allocator, c),
        ' ' => try out.appendSlice(allocator, "%20"),
        else => {
            try out.append(allocator, '%');
            try out.append(allocator, HEX[(c >> 4) & 0xF]);
            try out.append(allocator, HEX[c & 0xF]);
        },
    };
    return out.toOwnedSlice(allocator);
}

// 构造 application/x-www-form-urlencoded 表单体
fn allocFormEncoded(allocator: std.mem.Allocator, fields: []const struct { key: []const u8, v1: []const u8, v2: []const u8 }) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, "login_token")) {
            const a = try urlFormEncode(allocator, f.v1);
            defer allocator.free(a);
            const b = try urlFormEncode(allocator, f.v2);
            defer allocator.free(b);
            const token = try std.fmt.allocPrint(allocator, "{s},{s}", .{ a, b });
            defer allocator.free(token);
            const key = try urlFormEncode(allocator, f.key);
            defer allocator.free(key);
            const kv = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, token });
            try parts.append(allocator, kv);
        } else if (f.v1.len != 0) {
            const key = try urlFormEncode(allocator, f.key);
            defer allocator.free(key);
            const val = try urlFormEncode(allocator, f.v1);
            defer allocator.free(val);
            const kv = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, val });
            try parts.append(allocator, kv);
        }
    }
    const joined = try std.mem.join(allocator, "&", parts.items);
    for (parts.items) |p| allocator.free(p);
    return joined;
}

/// 使用 Zig 标准库解压 gzip 数据（基于 std.compress.flate）
/// 参数:
///   - allocator: 内存分配器
///   - compressed: gzip 压缩数据
/// 返回: 解压后的数据（调用方负责释放）
fn gzipDecompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    // 使用固定缓冲区创建 Io.Reader
    var input_reader: std.Io.Reader = .fixed(compressed);

    // 初始化 flate 解压缩器，指定为 gzip 容器格式
    // 空切片表示使用内部分配的历史窗口
    var decompressor = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});

    // 使用 Writer.Allocating 收集解压后的数据
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    // 流式解压所有数据
    _ = try decompressor.reader.streamRemaining(&output.writer);

    // 检查解压过程中的错误
    if (decompressor.err) |err| {
        output.deinit();
        return err;
    }

    // 转换为拥有的切片并返回
    return try output.toOwnedSlice();
}
