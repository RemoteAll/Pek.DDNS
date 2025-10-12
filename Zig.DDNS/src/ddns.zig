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
    defer allocator.free(body);
    // 打印是否检测到压缩（通过 gzip 魔数）
    const is_gzip = isGzipMagic(body);
    std.debug.print("[ip-source encoding] gzip_magic={any}\n", .{is_gzip});
    if (is_gzip) {
        const unzipped = try gunzipAlloc(allocator, body);
        std.debug.print("[ip-source gunzip] {s}\n", .{unzipped});
        defer allocator.free(unzipped);
        // 这里进行轻量 JSON 解析，提取 Type 为 IPv4 的 Ip 字段。
        const ip_field = try parseClientIpJson(allocator, unzipped);
        return ip_field;
    } else {
        // 打印接口返回的原始数据，便于观察/调试
        std.debug.print("[ip-source raw] {s}\n", .{body});
        // 这里进行轻量 JSON 解析，提取 Type 为 IPv4 的 Ip 字段。
        const ip_field = try parseClientIpJson(allocator, body);
        return ip_field;
    }
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
    const resp_buf = try response.reader(&.{}).allocRemaining(allocator, .unlimited);
    defer allocator.free(resp_buf);
    std.debug.print("[post encoding] gzip_magic={any}\n", .{isGzipMagic(resp_buf)});
    if (isGzipMagic(resp_buf)) {
        const unzipped = try gunzipAlloc(allocator, resp_buf);
        // 返回前复制一份，保证释放本地缓冲不会影响调用方
        const out = try allocator.dupe(u8, unzipped);
        allocator.free(unzipped);
        return out;
    }
    // 返回前复制一份，保证释放本地缓冲不会影响调用方
    const out = try allocator.dupe(u8, resp_buf);
    return out;
}

// 检测 gzip 魔数 (0x1F, 0x8B)
fn isGzipMagic(buf: []const u8) bool {
    return buf.len >= 2 and buf[0] == 0x1F and buf[1] == 0x8B;
}

// 仅支持常见无特殊标志的 gzip 格式，解压 deflate 数据段
fn gunzipAlloc(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    // 参考 RFC1952 gzip 格式
    if (compressed.len < 18) return error.GzipHeaderTooShort;
    if (!(compressed[0] == 0x1F and compressed[1] == 0x8B and compressed[2] == 8)) return error.GzipHeaderInvalid;
    const flg = compressed[3];
    var pos: usize = 10;
    if ((flg & 0x04) != 0) { // FEXTRA
        if (pos + 2 > compressed.len) return error.GzipHeaderTooShort;
        const xlen = @as(u16, compressed[pos]) | (@as(u16, compressed[pos + 1]) << 8);
        pos += 2 + xlen;
        if (pos > compressed.len) return error.GzipHeaderTooShort;
    }
    if ((flg & 0x08) != 0) { // FNAME
        while (pos < compressed.len and compressed[pos] != 0) : (pos += 1) {}
        pos += 1;
    }
    if ((flg & 0x10) != 0) { // FCOMMENT
        while (pos < compressed.len and compressed[pos] != 0) : (pos += 1) {}
        pos += 1;
    }
    if ((flg & 0x02) != 0) { // FHCRC
        pos += 2;
    }
    if (pos >= compressed.len) return error.GzipHeaderTooShort;
    // 数据段到倒数8字节为止
    if (compressed.len < pos + 8) return error.GzipDataTooShort;
    const deflate_data = compressed[pos .. compressed.len - 8];
    // --- 极简 deflate 解码，仅支持固定 Huffman 表 ---
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    var bitpos: usize = 0;
    var finished = false;
    while (!finished) {
        if (bitpos / 8 >= deflate_data.len) return error.DeflateUnexpectedEof;
        // 读取块头
        const bfinal = (deflate_data[bitpos / 8] >> @intCast(bitpos % 8)) & 1;
        const btype = (deflate_data[bitpos / 8] >> @intCast((bitpos % 8) + 1)) & 0x3;
        bitpos += 3;
        if (btype == 0) return error.DeflateNoUncompressedBlock;
        if (btype == 2) return error.DeflateDynamicNotSupported;
        if (btype != 1) return error.DeflateUnknownBlockType;
        // 固定 Huffman 表
        // 参考 RFC1951 3.2.6
        // 这里只实现最常见的 LZ77+固定表解码，未实现所有边界
        while (true) {
            // 读取一个符号
            var code: u16 = 0;
            var codelen: u8 = 0;
            while (true) {
                if (bitpos / 8 >= deflate_data.len) return error.DeflateUnexpectedEof;
                code |= (((deflate_data[bitpos / 8] >> @intCast(bitpos % 8)) & 1) << @intCast(codelen));
                bitpos += 1;
                codelen += 1;
                // 固定表 literal/length 7-9bit
                if (codelen >= 7 and codelen <= 9) {
                    // 参照 RFC1951 固定表编码区间
                    if (codelen == 7 and code >= 0b0000000 and code <= 0b0010111) break;
                    if (codelen == 8 and code >= 0b00110000 and code <= 0b10111111) break;
                    if (codelen == 8 and code >= 0b11000000 and code <= 0b11000111) break;
                    if (codelen == 9 and code >= 0b000110000 and code <= 0b000111111) break;
                }
            }
            // literal/length 解码
            var sym: u16 = 0;
            if (codelen == 7) {
                sym = code;
            } else if (codelen == 8) {
                sym = code + 0x30;
            } else if (codelen == 9) {
                sym = code + 0x190;
            } else {
                return error.DeflateBadCode;
            }
            if (sym < 256) {
                try out.append(allocator, @intCast(sym));
            } else if (sym == 256) {
                // end of block
                break;
            } else {
                // 只实现最常见的 257-264 长度（3-10字节），不支持更长和额外位
                if (sym < 257 or sym > 264) return error.DeflateLengthNotSupported;
                const length = sym - 254;
                if (out.items.len < length) return error.DeflateLengthOutOfRange;
                for (0..length) |_| {
                    try out.append(allocator, out.items[out.items.len - length]);
                }
            }
        }
        if (bfinal == 1) finished = true;
    }
    return out.toOwnedSlice(allocator);
}
