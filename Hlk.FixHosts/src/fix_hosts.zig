//! FixHosts 核心逻辑
//!
//! 硬编码 DNSPod 凭证和目标域名，通过 DNSPod API 查询 A 记录 IP，
//! 然后更新本地 hosts 文件并刷新 DNS 缓存。

const std = @import("std");
const hosts = @import("hosts.zig");

// ═══════════════════════════════════════════════════════════════
// 密钥导入（编译时嵌入，不进 Git，不依赖外部文件）
//
// 请复制 local.secret.example.zig → local.secret.zig，
// 将占位符替换为你的 DNSPod API Token 后重新编译。
// ═══════════════════════════════════════════════════════════════
const secret = @import("local.secret.zig");

const DNSPOD_TOKEN_ID = secret.DNSPOD_TOKEN_ID;
const DNSPOD_TOKEN = secret.DNSPOD_TOKEN;

/// 目标主域名
const TARGET_DOMAIN = "hlktech.com";
/// 目标子域名（主机记录）
const TARGET_SUB_DOMAIN = "erp";
/// DNS 记录类型
const RECORD_TYPE = "A";

// ═══════════════════════════════════════════════════════════════

/// 颜色常量
const Color = struct {
    const reset = "\x1b[0m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const bold = "\x1b[1m";
};

/// 执行 FixHosts 主流程
/// 1. 调用 DNSPod API 获取目标域名的 A 记录 IP
/// 2. 更新本地 hosts 文件
/// 3. 刷新 DNS 缓存
pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("{s}────────────────────────────────────────{s}\n", .{ Color.cyan, Color.reset });
    std.debug.print("{s}{s}  Hlk.FixHosts — DNSPod → Hosts 更新工具{s}\n", .{ Color.bold, Color.cyan, Color.reset });
    std.debug.print("{s}────────────────────────────────────────{s}\n", .{ Color.cyan, Color.reset });
    std.debug.print("\n", .{});

    // ── 步骤 1：通过 DNSPod API 查询记录 IP ──
    std.debug.print("{s}➜ 步骤 1/3：查询 DNSPod 记录...{s}\n", .{ Color.cyan, Color.reset });
    std.debug.print("   域名: {s}{s}.{s}{s}\n", .{ Color.yellow, TARGET_SUB_DOMAIN, TARGET_DOMAIN, Color.reset });
    std.debug.print("   类型: {s}{s}{s}\n", .{ Color.yellow, RECORD_TYPE, Color.reset });

    const dnspod_ip = queryDnsPodRecord(allocator) catch |err| {
        std.debug.print("{s}[错误]{s} DNSPod API 查询失败: {s}{s}{s}\n", .{
            Color.red, Color.reset, Color.red, @errorName(err), Color.reset,
        });
        std.debug.print("{s}可能原因：网络连接问题、Token 无效或 DNS 记录不存在{s}\n", .{ Color.yellow, Color.reset });
        return err;
    };
    defer allocator.free(dnspod_ip);

    std.debug.print("   {s}✓{s} 当前 DNSPod 权威 IP: {s}{s}{s}\n", .{
        Color.green, Color.reset, Color.bold, dnspod_ip, Color.reset,
    });

    // ── 步骤 2：更新 hosts 文件 ──
    std.debug.print("\n{s}➜ 步骤 2/3：更新 hosts 文件...{s}\n", .{ Color.cyan, Color.reset });

    const full_domain = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ TARGET_SUB_DOMAIN, TARGET_DOMAIN });
    defer allocator.free(full_domain);

    const result = hosts.updateHostEntry(allocator, full_domain, dnspod_ip) catch |err| {
        switch (err) {
            error.AccessDenied => {
                std.debug.print("{s}[错误]{s} 无法访问 hosts 文件，{s}请以管理员身份运行本程序！{s}\n", .{
                    Color.red, Color.reset, Color.bold, Color.reset,
                });
            },
            else => {
                std.debug.print("{s}[错误]{s} 更新 hosts 文件失败: {s}{s}{s}\n", .{
                    Color.red, Color.reset, Color.red, @errorName(err), Color.reset,
                });
            },
        }
        return err;
    };
    defer {
        allocator.free(result.current_ip);
    }

    if (result.changed) {
        std.debug.print("   {s}✓{s} hosts 文件已更新: {s}{s}{s} → {s}{s}{s}\n", .{
            Color.green, Color.reset,
            Color.red, result.current_ip, Color.reset,
            Color.green, dnspod_ip, Color.reset,
        });
    } else {
        std.debug.print("   {s}✓{s} hosts 中 IP 无变化（{s}{s}{s}），跳过写入{s}\n", .{
            Color.green, Color.reset, Color.yellow, result.current_ip, Color.reset, Color.reset,
        });
    }

    // ── 步骤 3：刷新 DNS 缓存 ──
    std.debug.print("\n{s}➜ 步骤 3/3：刷新 DNS 缓存...{s}\n", .{ Color.cyan, Color.reset });
    hosts.flushDns() catch |err| {
        std.debug.print("   {s}[警告]{s} 刷新 DNS 缓存失败: {s}{s}\n", .{
            Color.yellow, Color.reset, @errorName(err), Color.reset,
        });
    };
    std.debug.print("   {s}✓{s} 完成\n", .{ Color.green, Color.reset });

    // ── 步骤 4：验证连通性 ──
    std.debug.print("\n{s}➜ 步骤 4/4：验证连通性...{s}\n", .{ Color.cyan, Color.reset });
    const verify_ok = verifyReachability(allocator);
    if (verify_ok) {
        std.debug.print("   {s}✓{s} 请求成功 — {s}erp.hlktech.com:8099{s} 已可访问\n", .{
            Color.green, Color.reset, Color.bold, Color.reset,
        });
    } else {
        std.debug.print("   {s}✗{s} 请求失败 — {s}erp.hlktech.com:8099{s} 暂时无法连通\n", .{
            Color.red, Color.reset, Color.yellow, Color.reset,
        });
        std.debug.print("   可能是服务端未就绪或网络策略限制，请稍后手动验证\n", .{});
    }

    // ── 输出结果摘要 ──
    std.debug.print("\n{s}────────────────────────────────────────{s}\n", .{ Color.green, Color.reset });
    if (verify_ok) {
        std.debug.print("{s}✓ 全部完成！{s}\n", .{ Color.green, Color.reset });
    } else {
        std.debug.print("{s}⚠ 部分完成（hosts 已更新，但连通验证未通过）{s}\n", .{ Color.yellow, Color.reset });
    }
    std.debug.print("  {s}域名:{s}  {s}.{s}\n", .{ Color.yellow, Color.reset, TARGET_SUB_DOMAIN, TARGET_DOMAIN });
    std.debug.print("  {s}IP:{s}    {s}{s}{s}\n", .{ Color.yellow, Color.reset, Color.bold, dnspod_ip, Color.reset });
    if (result.changed) {
        std.debug.print("  {s}状态:{s}  hosts 已更新 + DNS 缓存已刷新\n", .{ Color.yellow, Color.reset });
    } else {
        std.debug.print("  {s}状态:{s}  hosts 无需变更\n", .{ Color.yellow, Color.reset });
    }
    std.debug.print("{s}────────────────────────────────────────{s}\n", .{ Color.green, Color.reset });
}

/// 验证 erp.hlktech.com:8099/ERP/ 是否可访问
fn verifyReachability(allocator: std.mem.Allocator) bool {
    const url = "http://erp.hlktech.com:8099/ERP/";

    std.debug.print("   请求 {s}...\n", .{url});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &allocating_writer.writer,
    }) catch |err| {
        std.debug.print("   连接失败: {s}\n", .{@errorName(err)});
        return false;
    };

    const status_code = @intFromEnum(result.status);
    std.debug.print("   HTTP 状态码: {d}\n", .{status_code});

    // 2xx 或 3xx 都算连通成功
    if (status_code >= 200 and status_code < 400) {
        return true;
    }

    // 4xx/5xx 说明服务端有响应但可能有问题，仍算连通
    if (status_code >= 400) {
        std.debug.print("   服务端返回 {d}，但服务本身已可达\n", .{status_code});
        return true;
    }

    return false;
}

/// 解析 DNSPod API 返回的 JSON，提取 records 数组中第一条记录的 value 字段
/// 使用手动解析避免依赖 std.json 可能的 API 变动
fn parseDnsPodResponse(allocator: std.mem.Allocator, json: []const u8) ![]const u8 {
    // 查找 "records":[ 开始位置
    const records_key = "\"records\":[";
    const recs_start = std.mem.indexOf(u8, json, records_key) orelse {
        // 尝试检查 API 返回的错误信息
        if (std.mem.indexOf(u8, json, "\"code\":\"0\"")) |_| {
            std.debug.print("{s}[API 错误]{s} DNSPod API 返回错误，响应内容:\n  {s}\n", .{
                Color.red, Color.reset, json,
            });
        }
        return error.RecordsNotFound;
    };

    const after_recs = json[recs_start + records_key.len ..];

    // 找到第一个对象开始位置
    const obj_start = std.mem.indexOfScalar(u8, after_recs, '{') orelse return error.InvalidResponse;
    const obj_slice = after_recs[obj_start..];

    // 括号计数找到对象结束位置
    var depth: i32 = 0;
    var obj_end: ?usize = null;
    for (obj_slice, 0..) |ch, i| {
        if (ch == '{') depth += 1;
        if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                obj_end = i;
                break;
            }
        }
    }
    const first_record = if (obj_end) |e| obj_slice[0 .. e + 1] else return error.InvalidResponse;

    // 提取 value 字段
    const value_key = "\"value\":\"";
    const val_start = std.mem.indexOf(u8, first_record, value_key) orelse return error.ValueNotFound;
    const val_slice = first_record[val_start + value_key.len ..];
    const val_end = std.mem.indexOfScalar(u8, val_slice, '"') orelse return error.InvalidResponse;

    return allocator.dupe(u8, val_slice[0..val_end]);
}

/// 通过 DNSPod API 查询目标域名的 A 记录 IP
fn queryDnsPodRecord(allocator: std.mem.Allocator) ![]const u8 {
    // 构造 POST 表单数据
    // login_token = TOKEN_ID,TOKEN
    // format = json
    // domain = TARGET_DOMAIN
    // sub_domain = TARGET_SUB_DOMAIN
    // record_type = A
    const login_token = try std.fmt.allocPrint(allocator, "{s},{s}", .{ DNSPOD_TOKEN_ID, DNSPOD_TOKEN });
    defer allocator.free(login_token);

    const form_body = try std.fmt.allocPrint(allocator,
        "login_token={s}&format=json&domain={s}&sub_domain={s}&record_type={s}",
        .{ login_token, TARGET_DOMAIN, TARGET_SUB_DOMAIN, RECORD_TYPE },
    );
    defer allocator.free(form_body);

    // 发起 HTTP POST 请求
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    std.debug.print("   正在请求 DNSPod API...\n", .{});

    const result = client.fetch(.{
        .location = .{ .url = "https://dnsapi.cn/Record.List" },
        .method = .POST,
        .payload = form_body,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .response_writer = &allocating_writer.writer,
    }) catch |err| {
        std.debug.print("   网络请求失败: {s}\n", .{@errorName(err)});
        return err;
    };

    if (result.status != .ok) {
        std.debug.print("   API 返回非 200 状态码: {}\n", .{result.status});
        return error.ApiRequestFailed;
    }

    const body = allocating_writer.writer.buffer[0..allocating_writer.writer.end];

    // 解析 JSON 响应，提取 IP
    return parseDnsPodResponse(allocator, body);
}
