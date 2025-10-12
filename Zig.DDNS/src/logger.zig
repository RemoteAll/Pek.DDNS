const std = @import("std");
const builtin = @import("builtin");

/// 日志级别
pub const Level = enum {
    debug,
    info,
    warn,
    err,

    /// 获取日志级别的颜色代码
    fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // 青色
            .info => "\x1b[32m", // 绿色
            .warn => "\x1b[33m", // 黄色
            .err => "\x1b[31m", // 红色
        };
    }

    /// 获取日志级别的标签
    fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// 全局日志级别，可通过环境变量或配置调整
var global_level: Level = .debug;

/// 设置全局日志级别
pub fn setLevel(level: Level) void {
    global_level = level;
}

/// 获取当前时间戳字符串 (格式: YYYY-MM-DD HH:MM:SS)
fn getTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
    const seconds_since_epoch: i64 = timestamp;

    // 转换为本地时间 (简化版，使用 UTC)
    const days_since_epoch = @divFloor(seconds_since_epoch, 86400);
    const seconds_today = @mod(seconds_since_epoch, 86400);

    const hour: u32 = @intCast(@divFloor(seconds_today, 3600));
    const minute: u32 = @intCast(@divFloor(@mod(seconds_today, 3600), 60));
    const second: u32 = @intCast(@mod(seconds_today, 60));

    // 简化的日期计算 (从 1970-01-01 开始)
    const year: u32 = @intCast(1970 + @divFloor(days_since_epoch, 365));
    const day_of_year: u32 = @intCast(@mod(days_since_epoch, 365));
    const month: u32 = @intCast(@min(@divFloor(day_of_year, 30) + 1, 12));
    const day: u32 = @intCast(@mod(day_of_year, 30) + 1);

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year, month, day, hour, minute, second,
    });
}

/// 跨平台打印函数：Windows 使用 WriteConsoleW 确保中文正确显示
fn printUtf8(text: []const u8) void {
    if (builtin.os.tag != .windows) {
        std.debug.print("{s}", .{text});
        return;
    }

    // Windows 平台：使用 WriteConsoleW 保证中文显示
    const w = std.os.windows;
    const h = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
    if (h == null or h == w.INVALID_HANDLE_VALUE) {
        // 降级到普通打印
        std.debug.print("{s}", .{text});
        return;
    }

    // 转换为 UTF-16LE
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const utf16 = std.unicode.utf8ToUtf16LeAlloc(alloc, text) catch {
        std.debug.print("{s}", .{text});
        return;
    };

    var written: w.DWORD = 0;
    _ = w.kernel32.WriteConsoleW(h.?, utf16.ptr, @as(w.DWORD, @intCast(utf16.len)), &written, null);
}

/// 通用日志打印函数
fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    // 级别过滤
    if (@intFromEnum(level) < @intFromEnum(global_level)) {
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 获取时间戳
    const timestamp = getTimestamp(allocator) catch "????-??-?? ??:??:??";

    // 格式化用户消息
    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;

    // 组装完整日志
    const color_code = level.color();
    const reset_code = "\x1b[0m";
    const level_label = level.label();

    const full_message = std.fmt.allocPrint(
        allocator,
        "{s}[{s}] {s}{s}{s} {s}\n",
        .{ color_code, timestamp, color_code, level_label, reset_code, message },
    ) catch return;

    printUtf8(full_message);
}

/// 调试级别日志
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

/// 信息级别日志
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

/// 警告级别日志
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

/// 错误级别日志
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

/// 不带时间戳和级别的简单打印（用于替换原有的简单打印场景）
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    printUtf8(message);
}
