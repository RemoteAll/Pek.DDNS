const std = @import("std");
const json_utils = @import("json_utils.zig");
const logger = @import("logger.zig");

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
    active_threads: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_success_time: i64 = 0,
    mutex: std.Thread.Mutex = .{},
};

var runtime_stats = RuntimeStats{};

pub fn run(config: Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    logger.info("🚀 程序启动 - 更新周期: {d}秒", .{config.interval_sec});
    runtime_stats.last_success_time = std.time.timestamp();

    if (config.interval_sec == 0) {
        try runOnce(allocator, config);
        return;
    }

    var last_heartbeat: i64 = std.time.timestamp();
    const heartbeat_interval: i64 = 300; // 5分钟输出一次心跳

    while (true) {
        runtime_stats.mutex.lock();
        runtime_stats.cycle_count += 1;
        const cycle_num = runtime_stats.cycle_count;
        runtime_stats.mutex.unlock();

        // 定期输出心跳日志
        const now = std.time.timestamp();
        if ((now - last_heartbeat) >= heartbeat_interval) {
            runtime_stats.mutex.lock();
            const stats = .{
                .cycle = cycle_num,
                .success = runtime_stats.success_count,
                .errors = runtime_stats.error_count,
                .consecutive = runtime_stats.consecutive_errors,
                .threads = runtime_stats.active_threads.load(.monotonic),
                .last_success = now - runtime_stats.last_success_time,
            };
            runtime_stats.mutex.unlock();

            logger.info("💓 心跳 #({d}) - 成功:{d} 错误:{d} 连续错误:{d} 活动线程:{d} 距上次成功:{d}秒", .{
                stats.cycle,
                stats.success,
                stats.errors,
                stats.consecutive,
                stats.threads,
                stats.last_success,
            });
            last_heartbeat = now;
        }

        logger.debug("===== 周期 #{d} =====", .{cycle_num});
        logger.debug("===== 周期 #{d} =====", .{cycle_num});
        const start_time = std.time.nanoTimestamp();

        // 捕获单次执行的错误，记录日志但不退出循环
        const run_result = runOnce(allocator, config);
        if (run_result) |_| {
            // 成功执行
            runtime_stats.mutex.lock();
            runtime_stats.success_count += 1;
            runtime_stats.consecutive_errors = 0;
            runtime_stats.last_success_time = std.time.timestamp();
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
                else => {
                    // 其他未知错误，记录详情但继续运行
                    logger.err("执行失败: {s} (连续错误:{d})", .{ @errorName(err), consecutive });
                },
            }
            logger.info("将在下一个周期重试...", .{});
        }

        // 计算执行耗时并动态调整睡眠时间，确保固定周期
        const end_time = std.time.nanoTimestamp();
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
                std.Thread.sleep(@as(u64, @intCast(sleep_ns)));
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
/// 这是应用层超时，用于防止网络请求阻塞导致程序卡住
/// 当超时发生时，主线程会放弃等待并继续，工作线程会被 detach
///
/// 超时也间接限制了最大数据量：
/// - 假设 1MB/s 网络速度，30秒最多接收 30MB
/// - 因此不需要额外设置响应大小限制
const NETWORK_TIMEOUT_SEC = 30;

/// 带超时保护的执行单次更新
fn runOnce(allocator: std.mem.Allocator, config: Config) !void {
    logger.debug("runOnce: 开始获取公网 IP (超时: {d}秒)", .{NETWORK_TIMEOUT_SEC});

    // 使用超时保护执行网络请求
    const ip = try fetchPublicIPv4WithTimeout(allocator, config.ip_source_url, NETWORK_TIMEOUT_SEC);
    defer allocator.free(ip);
    logger.debug("runOnce: 获取到 IP = {s}", .{ip});

    logger.debug("runOnce: 开始更新 DNS 记录", .{});
    switch (config.provider) {
        .dnspod => try providers.dnspod_update(allocator, config, ip),
    }
    logger.debug("runOnce: DNS 更新完成", .{});
}

/// 带超时的网络请求结果
const FetchResult = struct {
    data: ?[]u8 = null,
    err: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
};

/// 带超时保护的获取公网 IP
fn fetchPublicIPv4WithTimeout(allocator: std.mem.Allocator, url: []const u8, timeout_sec: u32) ![]u8 {
    var result = FetchResult{};

    // 记录活动线程数
    _ = runtime_stats.active_threads.fetchAdd(1, .monotonic);

    // 创建工作线程执行实际的网络请求
    const thread = try std.Thread.spawn(.{}, fetchWorker, .{ allocator, url, &result });

    // 主线程等待超时
    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;
    const start_time = std.time.nanoTimestamp();

    while (true) {
        // 检查是否完成
        if (result.completed.load(.acquire)) {
            thread.join();
            _ = runtime_stats.active_threads.fetchSub(1, .monotonic);

            result.mutex.lock();
            defer result.mutex.unlock();

            if (result.err) |err| {
                if (result.data) |data| allocator.free(data);
                return err;
            }

            if (result.data) |data| {
                return data;
            }

            return error.UnknownError;
        }

        // 检查是否超时
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed >= timeout_ns) {
            const active = runtime_stats.active_threads.load(.monotonic);
            logger.warn("⏱️ 网络请求超时 ({d}秒)，放弃等待 [活动线程:{d}]", .{ timeout_sec, active });
            // 线程会在后台完成或超时，不detach避免资源泄漏
            // 让线程自然结束，通过 completed 标志可以知道它何时完成
            thread.detach();
            // 注意：线程计数不减少，因为线程仍在运行
            // 当线程实际完成时，会在 fetchWorker 中减少计数
            return error.RequestTimeout;
        }

        // 短暂睡眠避免忙等待
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

/// 工作线程：执行实际的网络请求
fn fetchWorker(allocator: std.mem.Allocator, url: []const u8, result: *FetchResult) void {
    defer {
        result.completed.store(true, .release);
        // 线程完成时减少计数（即使是被detach的线程）
        _ = runtime_stats.active_threads.fetchSub(1, .monotonic);
    }

    const ip = fetchPublicIPv4(allocator, url) catch |err| {
        result.mutex.lock();
        defer result.mutex.unlock();
        result.err = err;
        return;
    };

    result.mutex.lock();
    defer result.mutex.unlock();
    result.data = ip;
}

fn fetchPublicIPv4(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    logger.debug("fetchPublicIPv4: 准备发起请求", .{});
    // 使用 Zig 0.15.2+ fetch API（已验证可用）
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    logger.debug("POST {s} (form: from=hlktech-nuget)", .{url});

    // 准备表单数据
    const form_data = "from=hlktech-nuget";

    // 使用 Allocating Writer 捕获响应体
    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    logger.debug("fetchPublicIPv4: 发送请求...", .{});
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = form_data,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .response_writer = &allocating_writer.writer,
    });

    logger.debug("fetchPublicIPv4: 读取响应体", .{});
    // 从 Allocating Writer 获取响应体
    const body = allocating_writer.writer.buffer[0..allocating_writer.writer.end];

    // 打印是否检测到压缩（通过 gzip 魔数）
    const is_gzip = isGzipMagic(body);
    logger.debug("ip-source encoding gzip_magic={any}", .{is_gzip});

    if (is_gzip) {
        logger.debug("fetchPublicIPv4: 开始 gzip 解压", .{});
        const unzipped = try gzipDecompress(allocator, body);
        logger.debug("ip-source gunzip: {s}", .{unzipped});
        defer allocator.free(unzipped);
        // 使用通用 JSON 工具库提取 Type 为 IPv4 的 Ip 字段
        logger.debug("fetchPublicIPv4: 解析 JSON 提取 IP", .{});
        const ip_field = try json_utils.quickGetStringFromArray(allocator, unzipped, .{
            .match_key = "Type",
            .match_value = "IPv4",
            .target_key = "Ip",
        });
        logger.debug("fetchPublicIPv4: 完成，IP = {s}", .{ip_field});
        return ip_field;
    } else {
        // 打印接口返回的原始数据，便于观察/调试
        logger.debug("ip-source raw: {s}", .{body});
        // 使用通用 JSON 工具库提取 Type 为 IPv4 的 Ip 字段
        logger.debug("fetchPublicIPv4: 解析 JSON 提取 IP", .{});
        const ip_field = try json_utils.quickGetStringFromArray(allocator, body, .{
            .array_key = "Data",
            .match_key = "Type",
            .match_value = "IPv4",
            .target_key = "Ip",
        });
        logger.debug("fetchPublicIPv4: 完成，IP = {s}", .{ip_field});
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
    // 在命令前添加 $ProgressPreference='SilentlyContinue' 禁用进度条输出到 stderr
    const silent_cmd = try std.fmt.allocPrint(allocator, "$ProgressPreference='SilentlyContinue'; {s}", .{command});
    defer allocator.free(silent_cmd);

    const args_pwsh = [_][]const u8{ "-NoProfile", "-Command", silent_cmd };
    return runReadCmd(allocator, "pwsh", &args_pwsh) catch {
        const args_ps = [_][]const u8{ "-NoProfile", "-Command", silent_cmd };
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
            logger.err("请在 config.json 中配置真实的 DNSPod API Token", .{});
            logger.warn("token_id 和 token 当前仍为占位符，请访问 https://console.dnspod.cn/account/token/apikey 获取", .{});
            return error.InvalidConfiguration;
        }

        // DNSPod API: https://docs.dnspod.cn/api/5f26a529e5b5810a610d3714/
        // 主要步骤：
        // 1) 获取记录列表，找到指定 domain/sub_domain 的记录（Record.List）
        // 2) 若不存在则创建（Record.Create）
        // 3) 若存在且值不同，则更新（Record.Modify）

        const record = try dnspod_find_record(allocator, dp, config.domain, config.sub_domain, config.record_type);
        if (record == null) {
            logger.info("dnspod: 未找到现有记录，将创建 {s}.{s} -> {s} (TTL={d})", .{ config.sub_domain, config.domain, ip, dp.ttl });
            try dnspod_create_record(allocator, dp, config.domain, config.sub_domain, config.record_type, ip, config);
            logger.info("dnspod: 已创建记录 {s}.{s} -> {s} (TTL={d})", .{ config.sub_domain, config.domain, ip, dp.ttl });
        } else {
            const r = record.?;
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
                try dnspod_modify_record(allocator, dp, r.id, config.domain, config.sub_domain, config.record_type, ip, config);
                logger.info("dnspod: 已更新记录 {s}.{s} -> {s} (TTL={d})", .{ config.sub_domain, config.domain, ip, dp.ttl });
            } else {
                logger.info("dnspod: {s}.{s} 无变化 (ip={s}, ttl={d})", .{ config.sub_domain, config.domain, ip, r.ttl });
            }
            allocator.free(r.id);
            allocator.free(r.value);
        }
    }

    const DnsPodRecord = struct {
        id: []const u8,
        value: []const u8,
        ttl: u32,
    };

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
        logger.debug("dnspod Record.List - domain={s} sub_domain={s} type={s}", .{ domain, sub, rtype });

        const resp = try httpPostFormWithTimeout(allocator, "https://dnsapi.cn/Record.List", body, NETWORK_TIMEOUT_SEC);
        defer allocator.free(resp);
        // 打印接口原始 JSON（完整）
        logger.debug("dnspod response: {s}", .{resp});
        printDnspodStatus(allocator, resp);
        // 更严格的解析：限定在 records 数组第一条记录的对象范围内查找 id/value，避免误命中其他位置
        const recs_key = "\"records\":[";
        const recs_start = std.mem.indexOf(u8, resp, recs_key) orelse return null;
        const after_recs = resp[recs_start + recs_key.len ..];
        const first_obj_start_rel = std.mem.indexOfScalar(u8, after_recs, '{') orelse return null;
        const obj_slice = after_recs[first_obj_start_rel..];
        // 找到与之匹配的第一个对象的结束位置（简易括号计数）
        var depth: i32 = 0;
        var end_rel: ?usize = null;
        for (obj_slice, 0..) |ch, i| {
            if (ch == '{') depth += 1;
            if (ch == '}') {
                depth -= 1;
                if (depth == 0) {
                    end_rel = i;
                    break;
                }
            }
        }
        const first_obj = if (end_rel) |e| obj_slice[0..(e + 1)] else return null;
        const id_key = "\"id\":\"";
        const value_key = "\"value\":\"";
        const ttl_key = "\"ttl\":\"";

        const id_start_rel = std.mem.indexOf(u8, first_obj, id_key) orelse return null;
        const id_slice = first_obj[id_start_rel + id_key.len ..];
        const id_rel_end = std.mem.indexOfScalar(u8, id_slice, '"') orelse return null;
        const id_val = id_slice[0..id_rel_end];

        const val_start_rel = std.mem.indexOf(u8, first_obj, value_key) orelse return null;
        const val_slice = first_obj[val_start_rel + value_key.len ..];
        const val_rel_end = std.mem.indexOfScalar(u8, val_slice, '"') orelse return null;
        const value_val = val_slice[0..val_rel_end];

        // 提取 TTL 值
        const ttl_val: u32 = blk: {
            const ttl_start_rel = std.mem.indexOf(u8, first_obj, ttl_key) orelse break :blk 600; // 默认 600
            const ttl_slice = first_obj[ttl_start_rel + ttl_key.len ..];
            const ttl_rel_end = std.mem.indexOfScalar(u8, ttl_slice, '"') orelse break :blk 600;
            const ttl_str = ttl_slice[0..ttl_rel_end];
            break :blk std.fmt.parseInt(u32, ttl_str, 10) catch 600;
        };

        // 复制切片，避免释放 resp 后悬挂
        const id_copy = try allocator.dupe(u8, id_val);
        const val_copy = try allocator.dupe(u8, value_val);
        return DnsPodRecord{ .id = id_copy, .value = val_copy, .ttl = ttl_val };
    }

    fn dnspod_create_record(allocator: std.mem.Allocator, dp: DnsPodConfig, domain: []const u8, sub: []const u8, rtype: []const u8, ip: []const u8, cfg: Config) !void {
        // 将 TTL 转换为字符串
        const ttl_str = try std.fmt.allocPrint(allocator, "{d}", .{dp.ttl});
        defer allocator.free(ttl_str);

        const body = try allocFormEncoded(allocator, &.{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
            .{ .key = "record_line", .v1 = cfg.dnspod.?.line, .v2 = "" },
            .{ .key = "value", .v1 = ip, .v2 = "" },
            .{ .key = "ttl", .v1 = ttl_str, .v2 = "" },
        });
        defer allocator.free(body);
        logger.debug("dnspod Record.Create - domain={s} sub={s} type={s} value={s}", .{ domain, sub, rtype, ip });
        const resp = try httpPostFormWithTimeout(allocator, "https://dnsapi.cn/Record.Create", body, NETWORK_TIMEOUT_SEC);
        defer allocator.free(resp);
        logger.debug("dnspod response: {s}", .{resp});
        printDnspodStatus(allocator, resp);
        // 可加入状态检查，这里简化为成功只要返回中包含 "code":"1"
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }

    fn dnspod_modify_record(allocator: std.mem.Allocator, dp: DnsPodConfig, record_id: []const u8, domain: []const u8, sub: []const u8, rtype: []const u8, ip: []const u8, cfg: Config) !void {
        // 将 TTL 转换为字符串
        const ttl_str = try std.fmt.allocPrint(allocator, "{d}", .{dp.ttl});
        defer allocator.free(ttl_str);

        const body = try allocFormEncoded(allocator, &.{
            .{ .key = "login_token", .v1 = dp.token_id, .v2 = dp.token },
            .{ .key = "format", .v1 = "json", .v2 = "" },
            .{ .key = "domain", .v1 = domain, .v2 = "" },
            .{ .key = "record_id", .v1 = record_id, .v2 = "" },
            .{ .key = "sub_domain", .v1 = sub, .v2 = "" },
            .{ .key = "record_type", .v1 = rtype, .v2 = "" },
            .{ .key = "record_line", .v1 = cfg.dnspod.?.line, .v2 = "" },
            .{ .key = "value", .v1 = ip, .v2 = "" },
            .{ .key = "ttl", .v1 = ttl_str, .v2 = "" },
        });
        defer allocator.free(body);
        logger.debug("dnspod Record.Modify - id={s} domain={s} sub={s} type={s} new_value={s}", .{ record_id, domain, sub, rtype, ip });
        const resp = try httpPostFormWithTimeout(allocator, "https://dnsapi.cn/Record.Modify", body, NETWORK_TIMEOUT_SEC);
        defer allocator.free(resp);
        logger.debug("dnspod response: {s}", .{resp});
        printDnspodStatus(allocator, resp);
        if (std.mem.indexOf(u8, resp, "\"code\":\"1\"") == null) return error.ApiFailed;
    }
};

/// POST 请求工作线程结果
const PostResult = struct {
    data: ?[]u8 = null,
    err: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
};

/// 带超时保护的 POST 请求
fn httpPostFormWithTimeout(allocator: std.mem.Allocator, url: []const u8, body: []const u8, timeout_sec: u32) ![]u8 {
    var result = PostResult{};

    _ = runtime_stats.active_threads.fetchAdd(1, .monotonic);
    const thread = try std.Thread.spawn(.{}, postWorker, .{ allocator, url, body, &result });

    const timeout_ns = @as(u64, timeout_sec) * std.time.ns_per_s;
    const start_time = std.time.nanoTimestamp();

    while (true) {
        if (result.completed.load(.acquire)) {
            thread.join();
            _ = runtime_stats.active_threads.fetchSub(1, .monotonic);

            result.mutex.lock();
            defer result.mutex.unlock();

            if (result.err) |err| {
                if (result.data) |data| allocator.free(data);
                return err;
            }

            if (result.data) |data| {
                return data;
            }

            return error.UnknownError;
        }

        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed >= timeout_ns) {
            const active = runtime_stats.active_threads.load(.monotonic);
            logger.warn("⏱️ POST 请求超时 ({d}秒)，放弃等待 [活动线程:{d}] - {s}", .{ timeout_sec, active, url });
            thread.detach();
            return error.RequestTimeout;
        }

        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

/// POST 工作线程
fn postWorker(allocator: std.mem.Allocator, url: []const u8, body: []const u8, result: *PostResult) void {
    defer {
        result.completed.store(true, .release);
        _ = runtime_stats.active_threads.fetchSub(1, .monotonic);
    }

    const data = httpPostForm(allocator, url, body) catch |err| {
        result.mutex.lock();
        defer result.mutex.unlock();
        result.err = err;
        return;
    };

    result.mutex.lock();
    defer result.mutex.unlock();
    result.data = data;
}

fn httpPostForm(allocator: std.mem.Allocator, url: []const u8, body: []const u8) ![]u8 {
    // 使用 Zig 0.15.2+ 低层 HTTP 客户端 POST 表单（稳定路径）
    logger.debug("httpPostForm: 使用低层 request 发送 POST", .{});
    var client = std.http.Client{ .allocator = allocator, .write_buffer_size = 64 * 1024 };
    defer client.deinit();

    logger.debug("httpPostForm: 解析 URI - {s}", .{url});
    const uri = try std.Uri.parse(url);

    logger.debug("httpPostForm: 创建 POST 请求", .{});
    logger.debug("POST {s}", .{url});
    // 创建请求，添加完整的 HTTP 头（模拟标准浏览器/工具行为）
    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
            .{ .name = "user-agent", .value = "Zig-DDNS/1.0" },
            .{ .name = "accept", .value = "*/*" },
            .{ .name = "accept-encoding", .value = "gzip, deflate" },
            .{ .name = "connection", .value = "close" },
        },
    });
    defer req.deinit();

    logger.debug("httpPostForm: 设置请求体长度 {d} 字节", .{body.len});
    // 设置请求体长度
    req.transfer_encoding = .{ .content_length = body.len };

    logger.debug("httpPostForm: 发送请求体", .{});
    // 发送请求体
    var body_writer = req.sendBody(&.{}) catch |e| {
        logger.err("POST {s} 建立连接/发送失败: {s}", .{ url, @errorName(e) });
        return e;
    };
    body_writer.writer.writeAll(body) catch |e| {
        logger.err("POST {s} 写入请求体失败: {s}", .{ url, @errorName(e) });
        return e;
    };
    body_writer.end() catch |e| {
        logger.err("POST {s} 结束请求体失败: {s}", .{ url, @errorName(e) });
        return e;
    };

    logger.debug("httpPostForm: 等待接收响应头", .{});
    // 接收响应
    var redirect_buffer: [1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        logger.err("httpPostForm: 接收响应头失败 - {any} - url={s}", .{ err, url });
        logger.warn("这通常意味着服务器在 HTTP 层之前就关闭了连接", .{});
        logger.warn("可能原因:", .{});
        logger.warn("  1) TLS 握手失败（证书问题）", .{});
        logger.warn("  2) 服务器检测到无效的认证信息直接断开", .{});
        logger.warn("  3) 请求格式不符合服务器要求", .{});
        logger.warn("  4) 网络层面的连接问题", .{});
        if (err == error.HttpConnectionClosing) {
            logger.info("httpPostForm Fallback: 尝试使用 PowerShell Invoke-WebRequest 执行 POST", .{});
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
    logger.debug("httpPostForm: 响应接收成功", .{});
    logger.debug("httpPostForm: 读取响应体", .{});
    // 使用 allocRemaining 无限制读取
    // 内存安全由超时机制保证：30秒超时限制了最大数据量
    const resp_buf = response.reader(&.{}).allocRemaining(allocator, .unlimited) catch |e| {
        logger.err("读取 POST 响应失败: {s}", .{@errorName(e)});
        return e;
    };
    defer allocator.free(resp_buf);

    logger.debug("post encoding gzip_magic={any}", .{isGzipMagic(resp_buf)});
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
            logger.debug("dnspod status: code={s} message={s}", .{ code, message_raw });
            return;
        };
        defer allocator.free(decoded);
        logger.debug("dnspod status: code={s} message={s}", .{ code, decoded });
        return;
    };
    const max = if (resp.len > 200) 200 else resp.len;
    logger.debug("dnspod status raw: {s}...", .{resp[0..max]});
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
