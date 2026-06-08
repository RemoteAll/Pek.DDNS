//! Hosts 文件读写与 DNS 缓存刷新工具
//!
//! 负责读取/修改 C:\Windows\System32\drivers\etc\hosts 文件，
//! 以及执行 ipconfig /flushdns 刷新系统 DNS 缓存。

const std = @import("std");
const builtin = @import("builtin");

/// Hosts 文件路径（仅 Windows）
const HOSTS_PATH = "C:\\Windows\\System32\\drivers\\etc\\hosts";

/// Hosts 备份文件路径
const BACKUP_PATH = "C:\\Windows\\System32\\drivers\\etc\\hosts.fixhosts.bak";

/// 执行结果
pub const HostsResult = struct {
    /// true 表示 hosts 文件实际发生了修改
    changed: bool,
    /// 当前 hosts 中的 IP 值（修改前或不变的值）
    current_ip: []const u8,
};

/// 查询指定域名在 hosts 文件中的当前 IP
/// 返回 null 表示 hosts 中不存在该域名
pub fn lookupHostEntry(allocator: std.mem.Allocator, domain: []const u8) !?[]const u8 {
    const hosts_dir = std.fs.path.dirname(HOSTS_PATH) orelse return error.InvalidPath;
    var dir = try std.fs.openDirAbsolute(hosts_dir, .{});
    defer dir.close();

    var file = dir.openFile("hosts", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    return findHostIp(allocator, content, domain);
}

/// 在 hosts 文件内容中查找指定域名的 IP
/// 返回 null 表示未找到
fn findHostIp(allocator: std.mem.Allocator, content: []const u8, domain: []const u8) !?[]const u8 {
    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r \t");
        // 跳过空行和注释行
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // 查找域名是否在这行中
        if (std.mem.indexOf(u8, trimmed, domain)) |_| {
            // 提取 IP（行首到第一个空白符）
            const ip_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse continue;
            const ip = trimmed[0..ip_end];
            // 验证 IP 格式（简单检查：包含点号）
            if (std.mem.indexOfScalar(u8, ip, '.') == null) continue;
            return @as(?[]const u8, try allocator.dupe(u8, ip));
        }
    }
    return null;
}

/// 更新 hosts 文件：将指定域名的 IP 设为新值
/// 若域名已存在则替换，否则追加
/// 修改前自动备份原文件
pub fn updateHostEntry(allocator: std.mem.Allocator, domain: []const u8, new_ip: []const u8) !HostsResult {
    // 1. 备份原 hosts 文件
    try backupHostsFile();

    // 2. 读取当前 hosts 内容
    const hosts_dir = std.fs.path.dirname(HOSTS_PATH) orelse return error.InvalidPath;
    var dir = try std.fs.openDirAbsolute(hosts_dir, .{});
    defer dir.close();

    const content = dir.readFileAlloc(allocator, "hosts", std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => "",
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };
    defer if (content.len > 0) allocator.free(content);

    // 3. 检查是否已有该域名
    const existing_ip = try findHostIp(allocator, content, domain);
    if (existing_ip) |ip| {
        defer allocator.free(ip);
        if (std.mem.eql(u8, ip, new_ip)) {
            // IP 未变化，无需修改
            return HostsResult{ .changed = false, .current_ip = try allocator.dupe(u8, ip) };
        }

        // IP 变化：替换行中的 IP
        const new_content = try replaceIpInHosts(allocator, content, domain, new_ip);
        defer allocator.free(new_content);

        var file = try dir.createFile("hosts", .{ .truncate = true });
        defer file.close();
        try file.writeAll(new_content);

        return HostsResult{ .changed = true, .current_ip = try allocator.dupe(u8, new_ip) };
    } else {
        // 域名不存在：追加一行
        var new_content = try std.ArrayList(u8).initCapacity(allocator, content.len + domain.len + new_ip.len + 4);
        defer new_content.deinit(allocator);
        try new_content.appendSlice(allocator, content);
        // 确保末尾有换行
        if (content.len > 0 and content[content.len - 1] != '\n') {
            try new_content.append(allocator, '\n');
        }
        try new_content.appendSlice(allocator, new_ip);
        try new_content.append(allocator, ' ');
        try new_content.append(allocator, '\t');
        try new_content.appendSlice(allocator, domain);
        try new_content.append(allocator, '\n');

        var file = try dir.createFile("hosts", .{ .truncate = true });
        defer file.close();
        try file.writeAll(new_content.items);

        return HostsResult{ .changed = true, .current_ip = try allocator.dupe(u8, new_ip) };
    }
}

/// 将 hosts 内容中指定域名的 IP 替换为新值
fn replaceIpInHosts(allocator: std.mem.Allocator, content: []const u8, domain: []const u8, new_ip: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len);
    defer result.deinit(allocator);

    var lines_iter = std.mem.splitScalar(u8, content, '\n');
    var first: bool = true;
    while (lines_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (!first) {
            try result.append(allocator, '\n');
        }
        first = false;

        // 检查这行是否包含目标域名
        if (std.mem.indexOf(u8, trimmed, domain) != null) {
            // 跳过注释行
            const trimmed_left = std.mem.trimLeft(u8, trimmed, " \t");
            if (trimmed_left.len > 0 and trimmed_left[0] != '#') {
                // 构造新行：new_ip + 空白 + 域名及后面内容
                // 找到域名在行中的位置
                const domain_pos = std.mem.indexOf(u8, trimmed, domain).?;
                // 域名后的部分（包括注释等）
                const after_domain = trimmed[domain_pos + domain.len ..];
                try result.appendSlice(allocator, new_ip);
                try result.appendSlice(allocator, " \t");
                try result.appendSlice(allocator, domain);
                try result.appendSlice(allocator, after_domain);
                continue;
            }
        }
        // 非目标行，原样保留
        try result.appendSlice(allocator, trimmed);
    }

    return result.toOwnedSlice(allocator);
}

/// 备份当前 hosts 文件
fn backupHostsFile() !void {
    const hosts_dir = std.fs.path.dirname(HOSTS_PATH) orelse return error.InvalidPath;
    var dir = try std.fs.openDirAbsolute(hosts_dir, .{});
    defer dir.close();

    // 读取当前 hosts
    const content = dir.readFileAlloc(std.heap.page_allocator, "hosts", std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return,
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };
    defer std.heap.page_allocator.free(content);

    // 写入备份文件
    var backup = dir.createFile("hosts.fixhosts.bak", .{ .truncate = true }) catch |err| switch (err) {
        error.AccessDenied => return error.AccessDenied,
        else => return err,
    };
    defer backup.close();
    try backup.writeAll(content);
}

/// 执行 ipconfig /flushdns 刷新系统 DNS 缓存
pub fn flushDns() !void {
    if (builtin.os.tag != .windows) {
        // 非 Windows 平台提示跳过
        std.debug.print("[信息] 非 Windows 平台，跳过 flushdns\n", .{});
        return;
    }

    const result = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "ipconfig", "/flushdns" },
    });
    defer {
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("[警告] ipconfig /flushdns 返回非零退出码: {d}\n", .{code});
                if (result.stderr.len > 0) {
                    std.debug.print("  stderr: {s}\n", .{result.stderr});
                }
            }
        },
        else => {
            std.debug.print("[警告] ipconfig /flushdns 异常终止\n", .{});
        },
    }
}
