const std = @import("std");
const zzig = @import("zzig");
const compat = zzig.compat;
const zhttpenh = zzig.HttpEnhanced;
const logger = @import("logger.zig");

pub const Provider = enum {
    dnspod,
    // 未来可扩展更多平台: cloudflare, alicloud, huawei, aws_route53, etc.
};

pub const Config = struct {
    provider: Provider,
    // 解析记录基本信息
    domain: []const u8, // 主域名，如 example.com
    sub_domains: [][]const u8, // 子域名/主机记录列表，支持逗号或分号分隔，如 "www,@,home"
    record_type: []const u8 = "A", // 默认为 A 记录
    // 轮询/执行模式
    interval_sec: u32 = 60, // 轮询更新周期，0 表示只执行一次
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
    // 可选：TTL 值（秒），最小 60，最大 604800（7天）
    ttl: u32 = 600, // 默认 600 秒（10分钟）
};

/// 运行时统计信息
const RuntimeStats = struct {
    cycle_count: u64 = 0,
    success_count: u64 = 0,
    error_count: u64 = 0,
    consecutive_errors: u32 = 0,
    last_success_time: i64 = 0,
    mutex: zzig.compat.Mutex = .{},
};

var runtime_stats = RuntimeStats{};
var app_io: ?std.Io = null;

pub fn configureIo(io: std.Io) void {
    app_io = io;
}

fn currentIo() std.Io {
    return app_io orelse std.Io.Threaded.global_single_threaded.io();
}

pub fn run(config: Config) !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    logger.info("🚀 程序启动 - 更新周期: {d}秒", .{config.interval_sec});
    runtime_stats.last_success_time = compat.timestamp();

    if (config.interval_sec == 0) {
        try runOnce(allocator, config);
        return;
    }

    var last_heartbeat: i64 = compat.timestamp();
    const heartbeat_interval: i64 = 300; // 5分钟输出一次心跳

    while (true) {
        runtime_stats.mutex.lock();
        runtime_stats.cycle_count += 1;
        const cycle_num = runtime_stats.cycle_count;
        runtime_stats.mutex.unlock();

        // 定期输出心跳日志
        const now = compat.timestamp();
        if ((now - last_heartbeat) >= heartbeat_interval) {
            runtime_stats.mutex.lock();
            const stats = .{
                .cycle = cycle_num,
                .success = runtime_stats.success_count,
                .errors = runtime_stats.error_count,
                .consecutive = runtime_stats.consecutive_errors,
                .last_success = now - runtime_stats.last_success_time,
            };
            runtime_stats.mutex.unlock();

            logger.info("💓 心跳 #({d}) - 成功:{d} 错误:{d} 连续错误:{d} 距上次成功:{d}秒", .{
                stats.cycle,
                stats.success,
                stats.errors,
                stats.consecutive,
                stats.last_success,
            });
            last_heartbeat = now;
        }

        logger.debug("===== 周期 #{d} =====", .{cycle_num});
        logger.debug("===== 周期 #{d} =====", .{cycle_num});
        const start_time = compat.nanoTimestamp();

        // 捕获单次执行的错误，记录日志但不退出循环
        const run_result = runOnce(allocator, config);
        if (run_result) |_| {
            // 成功执行
            runtime_stats.mutex.lock();
            runtime_stats.success_count += 1;
            runtime_stats.consecutive_errors = 0;
            runtime_stats.last_success_time = compat.timestamp();
            runtime_stats.mutex.unlock();
            logger.debug("✓ 更新成功", .{});
        } else |err| {
            // 执行失败
            runtime_stats.mutex.lock();
            runtime_stats.error_count += 1;
            runtime_stats.consecutive_errors += 1;
            const consecutive = runtime_stats.consecutive_errors;
            runtime_stats.mutex.unlock();

            switch (err) {
                error.RequestTimeout => {
                    logger.err("请求超时: 网络请求在 {d} 秒内未完成 (连续错误:{d})", .{ NETWORK_TIMEOUT_SEC, consecutive });
                    logger.warn("可能原因: 网络延迟过高、服务器无响应或防火墙阻止", .{});
                },
                error.UnknownHostName => {
                    logger.err("DNS 解析失败: 无法解析主机名 (连续错误:{d})", .{consecutive});
                    logger.warn("可能原因: 网络连接问题、DNS 服务器不可用或主机名错误", .{});
                },
                error.ConnectionRefused => {
                    logger.err("连接被拒绝: 目标服务器拒绝连接 (连续错误:{d})", .{consecutive});
                },
                error.NetworkUnreachable => {
                    logger.err("网络不可达: 无法访问目标网络 (连续错误:{d})", .{consecutive});
                },
                error.ConnectionTimedOut => {
                    logger.err("连接超时: 网络响应超时 (连续错误:{d})", .{consecutive});
                },
                error.HttpConnectionClosing => {
                    logger.err("HTTP 连接被服务器关闭 (连续错误:{d})", .{consecutive});
                    logger.warn("这可能是服务器端的问题或网络环境限制", .{});
                },
                error.InvalidConfiguration, error.MissingProviderConfig => {
                    // 配置错误是致命错误，应该立即退出
                    logger.err("配置错误，无法继续运行", .{});
                    return err;
                },
                error.PartialUpdateFailure => {
                    // 部分子域名更新失败，记录但继续运行
                    logger.warn("部分子域名更新失败 (连续错误:{d})", .{consecutive});
                },
                else => {
                    // 其他未知错误，记录详情但继续运行
                    logger.err("执行失败: {s} (连续错误:{d})", .{ @errorName(err), consecutive });
                },
            }
            logger.info("将在下一个周期重试...", .{});
        }

        // 计算执行耗时并动态调整睡眠时间，确保固定周期
        const end_time = compat.nanoTimestamp();
        const elapsed_ns = end_time - start_time;
        const interval_ns = @as(i64, config.interval_sec) * std.time.ns_per_s;

        if (elapsed_ns < interval_ns) {
            const sleep_ns = interval_ns - elapsed_ns;
            // 确保睡眠时间为正数
            if (sleep_ns > 0) {
                logger.debug("周期睡眠: {d}秒 (执行耗时: {d}ms)", .{
                    @divFloor(sleep_ns, std.time.ns_per_s),
                    @divFloor(elapsed_ns, std.time.ns_per_ms),
                });
                compat.sleep(@as(u64, @intCast(sleep_ns)));
            }
        } else {
            // 执行时间超过间隔，记录警告但继续运行
            logger.warn("执行耗时 {d}ms 超过配置周期 {d}秒，立即开始下一轮", .{
                @divFloor(elapsed_ns, std.time.ns_per_ms),
                config.interval_sec,
            });
        }
    }
}

/// 网络操作超时时间（秒）
/// 这是应用层超时，用于通过 std.Io 的取消机制中止长时间卡住的网络请求
const NETWORK_TIMEOUT_SEC = 5;
const NETWORK_POLL_INTERVAL_MS: u64 = 100;
const HTTP_POST_MAX_ATTEMPTS: u32 = 2;
const HTTP_POST_RETRY_DELAY_MS: u64 = 200;

/// 带超时保护的执行单次更新
fn runOnce(allocator: std.mem.Allocator, config: Config) !void {
    logger.info("→ runOnce: 开始执行 (超时: {d}秒)", .{NETWORK_TIMEOUT_SEC});

    var client = std.http.Client{ .allocator = allocator, .io = currentIo() };
    defer client.deinit();

    // 使用超时保护执行网络请求
    logger.debug("→ runOnce: 调用应用侧公网 IP 解析...", .{});
    logger.debug("fetchPublicIPv4: 准备发起请求", .{});
    logger.debug("POST {s} (form: from=hlktech-nuget)", .{config.ip_source_url});
    const ip = fetchPublicIPv4AddressWithRetry(allocator, &client, config.ip_source_url, .{
        .max_attempts = HTTP_POST_MAX_ATTEMPTS,
        .retry_delay_ms = HTTP_POST_RETRY_DELAY_MS,
        .timeout_sec = NETWORK_TIMEOUT_SEC,
        .poll_interval_ms = NETWORK_POLL_INTERVAL_MS,
    }) catch |err| {
        logger.err("✗ runOnce: 获取 IP 失败 - {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(ip);
    logger.debug("fetchPublicIPv4: 完成，IP = {s}", .{ip});
    logger.info("✓ runOnce: 获取到 IP = {s}", .{ip});

    logger.debug("→ runOnce: 开始更新 DNS 记录 (provider={s})", .{@tagName(config.provider)});
    switch (config.provider) {
        .dnspod => {
            providers.dnspod_update(allocator, &client, config, ip) catch |err| {
                if (err == error.PartialUpdateFailure) {
                    // 部分子域名更新失败，记录警告但不中断
                    logger.warn("⚠ runOnce: 部分子域名更新失败", .{});
                } else {
                    logger.err("✗ runOnce: DNS 更新失败 - {s}", .{@errorName(err)});
                    return err;
                }
            };
        },
    }
    logger.info("✓ runOnce: DNS 更新完成", .{});
}

// 公网 IP 查询服务的返回格式由具体平台决定，解析逻辑保留在应用侧。
fn fetchPublicIPv4AddressWithRetry(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    config: zhttpenh.RetryConfig,
) ![]u8 {
    const body = try zhttpenh.httpPostFormWithRetry(allocator, client, url, "from=hlktech-nuget", config);
    defer allocator.free(body);

    return extractPublicIPv4FromJson(allocator, body);
}

fn extractPublicIPv4FromJson(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    return zzig.json.quickGetStringFromArray(allocator, body, .{
        .array_key = "Data",
        .match_key = "Type",
        .match_value = "IPv4",
        .target_key = "Ip",
    }) catch |err| switch (err) {
        error.KeyNotFound, error.ElementNotFound, error.TypeMismatch => zzig.json.quickGetStringFromArray(allocator, body, .{
            .match_key = "Type",
            .match_value = "IPv4",
            .target_key = "Ip",
        }),
        else => err,
    };
}

const providers = struct {
    /// DNSPod 更新逻辑：遍历配置中的所有子域名，逐一检查并更新 DNS 记录
    /// 每个子域名独立处理，单个失败不影响其他子域名
    pub fn dnspod_update(allocator: std.mem.Allocator, client: *std.http.Client, config: Config, ip: []const u8) !void {
        if (config.dnspod == null) return error.MissingProviderConfig;
        const dp = config.dnspod.?;

        // 验证配置是否为默认占位符
        if (std.mem.indexOf(u8, dp.token_id, "TokenId") != null or
            std.mem.indexOf(u8, dp.token, "Token") != null)
        {
            logger.err("请在 config.json 中配置真实的 DNSPod API Token", .{});
            logger.warn("token_id 和 token 当前仍为占位符，请访问 https://console.dnspod.cn/account/token/apikey 获取", .{});
            return error.InvalidConfiguration;
        }

        // DNSPod API: https://docs.dnspod.cn/api/5f26a529e5b5810a610d3714/
        // 主要步骤：
        // 1) 获取记录列表，找到指定 domain/sub_domain 的记录（Record.List）
        // 2) 若不存在则创建（Record.Create）
        // 3) 若存在且值不同，则更新（Record.Modify）

        // 遍历所有子域名，逐一更新
        var had_error = false;
        for (config.sub_domains, 0..) |sub_domain, i| {
            if (config.sub_domains.len > 1) {
                logger.info("dnspod: 处理子域名 [{d}/{d}]: {s}.{s}", .{ i + 1, config.sub_domains.len, sub_domain, config.domain });
            }

            dnspod_update_single(allocator, client, dp, config.domain, sub_domain, config, ip) catch |err| {
                logger.err("dnspod: 更新 {s}.{s} 失败 - {s}", .{ sub_domain, config.domain, @errorName(err) });
                had_error = true;
            };
        }

        if (had_error) return error.PartialUpdateFailure;
    }

    /// 单个子域名的 DNS 记录更新：查找 → 创建/修改
    fn dnspod_update_single(allocator: std.mem.Allocator, client: *std.http.Client, dp: DnsPodConfig, domain: []const u8, sub_domain: []const u8, config: Config, ip: []const u8) !void {
        const record = try dnspod_find_record(allocator, client, dp, domain, sub_domain, config.record_type);
        if (record == null) {
            logger.info("dnspod: 未找到现有记录，将创建 {s}.{s} -> {s} (TTL={d})", .{ sub_domain, domain, ip, dp.ttl });
            try dnspod_create_record(allocator, client, dp, domain, sub_domain, config.record_type, ip, config);
            logger.info("dnspod: 已创建记录 {s}.{s} -> {s} (TTL={d})", .{ sub_domain, domain, ip, dp.ttl });
        } else {
            const r = record.?;
            // 检查 IP 和 TTL 是否发生变化
            const ip_changed = !std.mem.eql(u8, r.value, ip);
            const ttl_changed = r.ttl != dp.ttl;
            const need_update = ip_changed or ttl_changed;

            if (need_update) {
                if (ip_changed and ttl_changed) {
                    logger.info("dnspod: 检测到变化 - IP:{s}->{s}, TTL:{d}->{d} → 将更新", .{ r.value, ip, r.ttl, dp.ttl });
                } else if (ip_changed) {
                    logger.info("dnspod: 检测到 IP 变化 - {s} -> {s} → 将更新", .{ r.value, ip });
                } else {
                    logger.info("dnspod: 检测到 TTL 变化 - {d} -> {d} → 将更新", .{ r.ttl, dp.ttl });
                }
                try dnspod_modify_record(allocator, client, dp, r.id, domain, sub_domain, config.record_type, ip, config);
                logger.info("dnspod: 已更新记录 {s}.{s} -> {s} (TTL={d})", .{ sub_domain, domain, ip, dp.ttl });
            } else {
                logger.info("dnspod: {s}.{s} 无变化 (ip={s}, ttl={d})", .{ sub_domain, domain, ip, r.ttl });
            }
            freeDnsPodRecord(allocator, &r);
        }
    }

    const DnsPodRecord = struct {
        id: []const u8,
        value: []const u8,
        ttl: u32,
    };

    fn freeDnsPodRecord(allocator: std.mem.Allocator, record: *const DnsPodRecord) void {
        allocator.free(record.id);
        allocator.free(record.value);
    }

    fn dnspod_find_record(allocator: std.mem.Allocator, client: *std.http.Client, dp: DnsPodConfig, domain: []const u8, sub: []const u8, rtype: []const u8) !?DnsPodRecord {
        // POST https://dnsapi.cn/Record.List
        // params: login_token, format=json, domain, sub_domain, record_type
        const fields = [_]zhttpenh.FormField{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
        };
        const body = try zhttpenh.buildFormEncoded(allocator, &fields);
        defer allocator.free(body);
        logger.debug("dnspod Record.List - domain={s} sub_domain={s} type={s}", .{ domain, sub, rtype });

        logger.debug("httpPostForm: 使用 ZZig.HttpEnhanced 发送 POST", .{});
        logger.debug("POST {s}", .{"https://dnsapi.cn/Record.List"});
        const resp = try zhttpenh.httpPostFormWithRetry(allocator, client, "https://dnsapi.cn/Record.List", body, .{
            .max_attempts = HTTP_POST_MAX_ATTEMPTS,
            .retry_delay_ms = HTTP_POST_RETRY_DELAY_MS,
            .timeout_sec = NETWORK_TIMEOUT_SEC,
            .poll_interval_ms = NETWORK_POLL_INTERVAL_MS,
        });
        defer allocator.free(resp);
        logger.debug("dnspod response bytes: {d}", .{resp.len});
        printDnspodStatus(allocator, resp);
        const query = zzig.json.JsonQuery.init(allocator, resp);
        const records = query.getArray("records") catch |err| switch (err) {
            error.KeyNotFound => return null,
            else => return err,
        };
        const first = records.getObjectAt(0) catch |err| switch (err) {
            error.ElementNotFound => return null,
            else => return err,
        };

        var record = DnsPodRecord{
            .id = try first.getString("id"),
            .value = undefined,
            .ttl = 600,
        };
        errdefer allocator.free(record.id);

        record.value = try first.getString("value");
        errdefer freeDnsPodRecord(allocator, &record);

        const ttl_str = first.getString("ttl") catch null;
        if (ttl_str) |ttl| {
            defer allocator.free(ttl);
            record.ttl = std.fmt.parseInt(u32, ttl, 10) catch 600;
        }

        return record;
    }

    fn dnspod_create_record(allocator: std.mem.Allocator, client: *std.http.Client, dp: DnsPodConfig, domain: []const u8, sub: []const u8, rtype: []const u8, ip: []const u8, cfg: Config) !void {
        // 将 TTL 转换为字符串
        const ttl_str = try std.fmt.allocPrint(allocator, "{d}", .{dp.ttl});
        defer allocator.free(ttl_str);

        const fields = [_]zhttpenh.FormField{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
            .{ .key = "record_line", .v1 = cfg.dnspod.?.line, .v2 = "" },
            .{ .key = "value", .v1 = ip, .v2 = "" },
            .{ .key = "ttl", .v1 = ttl_str, .v2 = "" },
        };
        const body = try zhttpenh.buildFormEncoded(allocator, &fields);
        defer allocator.free(body);
        logger.debug("dnspod Record.Create - domain={s} sub={s} type={s} value={s}", .{ domain, sub, rtype, ip });
        logger.debug("httpPostForm: 使用 ZZig.HttpEnhanced 发送 POST", .{});
        logger.debug("POST {s}", .{"https://dnsapi.cn/Record.Create"});
        const resp = try zhttpenh.httpPostFormWithRetry(allocator, client, "https://dnsapi.cn/Record.Create", body, .{
            .max_attempts = HTTP_POST_MAX_ATTEMPTS,
            .retry_delay_ms = HTTP_POST_RETRY_DELAY_MS,
            .timeout_sec = NETWORK_TIMEOUT_SEC,
            .poll_interval_ms = NETWORK_POLL_INTERVAL_MS,
        });
        defer allocator.free(resp);
        logger.debug("dnspod response bytes: {d}", .{resp.len});
        printDnspodStatus(allocator, resp);
        // 可加入状态检查，这里简化为成功只要返回中包含 "code":"1"
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }

    fn dnspod_modify_record(allocator: std.mem.Allocator, client: *std.http.Client, dp: DnsPodConfig, record_id: []const u8, domain: []const u8, sub: []const u8, rtype: []const u8, ip: []const u8, cfg: Config) !void {
        // 将 TTL 转换为字符串
        const ttl_str = try std.fmt.allocPrint(allocator, "{d}", .{dp.ttl});
        defer allocator.free(ttl_str);

        const fields = [_]zhttpenh.FormField{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "record_id", .v1 = record_id, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
            .{ .key = "record_line", .v1 = cfg.dnspod.?.line, .v2 = "" },
            .{ .key = "value", .v1 = ip, .v2 = "" },
            .{ .key = "ttl", .v1 = ttl_str, .v2 = "" },
        };
        const body = try zhttpenh.buildFormEncoded(allocator, &fields);
        defer allocator.free(body);
        logger.debug("dnspod Record.Modify - id={s} domain={s} sub={s} type={s} new_value={s}", .{ record_id, domain, sub, rtype, ip });
        logger.debug("httpPostForm: 使用 ZZig.HttpEnhanced 发送 POST", .{});
        logger.debug("POST {s}", .{"https://dnsapi.cn/Record.Modify"});
        const resp = try zhttpenh.httpPostFormWithRetry(allocator, client, "https://dnsapi.cn/Record.Modify", body, .{
            .max_attempts = HTTP_POST_MAX_ATTEMPTS,
            .retry_delay_ms = HTTP_POST_RETRY_DELAY_MS,
            .timeout_sec = NETWORK_TIMEOUT_SEC,
            .poll_interval_ms = NETWORK_POLL_INTERVAL_MS,
        });
        defer allocator.free(resp);
        logger.debug("dnspod response bytes: {d}", .{resp.len});
        printDnspodStatus(allocator, resp);
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }
};

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
        const code_copy = allocator.dupe(u8, code) catch {
            logger.debug("dnspod status: code_len={d} message_len={d}", .{ code.len, message_raw.len });
            return;
        };
        defer allocator.free(code_copy);

        const decoded = zzig.json.unescapeJsonStringAlloc(allocator, message_raw) catch {
            const message_copy = allocator.dupe(u8, message_raw) catch {
                logger.debug("dnspod status: code={s} message_len={d}", .{ code_copy, message_raw.len });
                return;
            };
            defer allocator.free(message_copy);
            logger.debug("dnspod status: code={s} message={s}", .{ code_copy, message_copy });
            return;
        };
        defer allocator.free(decoded);
        logger.debug("dnspod status: code={s} message={s}", .{ code_copy, decoded });
        return;
    };
    logger.debug("dnspod status raw bytes: {d}", .{resp.len});
}
