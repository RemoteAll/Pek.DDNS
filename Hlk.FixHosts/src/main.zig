//! Zig.FixHosts — 通过 DNSPod API 查询域名 IP 并更新本地 hosts 文件
//!
//! 使用方式：以管理员身份运行 Zig_FixHosts.exe
//! 程序会自动查询硬编码的目标域名在 DNSPod 上的 A 记录，
//! 更新到 C:\Windows\System32\drivers\etc\hosts 中，
//! 并执行 ipconfig /flushdns 刷新系统 DNS 缓存，使新 IP 立即生效。

const std = @import("std");
const fix_hosts = @import("fix_hosts.zig");
const builtin = @import("builtin");

// Windows API 函数声明
// （Zig 0.16+ 标准库移除了 kernel32 常用封装，改为自行 extern 声明）
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) c_int;
extern "kernel32" fn SetConsoleCP(wCodePageID: u32) c_int;
extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn ReadFile(hFile: std.os.windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *u32) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: u32) callconv(.winapi) std.os.windows.BOOL;

/// 标准控制台句柄编号（-10 / -11，按 Win32 定义）
const STD_INPUT_HANDLE: u32 = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));

/// 等待用户按键后退出
fn waitForKeyPress() void {
    std.debug.print("\n按任意键退出...", .{});

    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const stdin_handle = GetStdHandle(STD_INPUT_HANDLE);
        if (stdin_handle == null or stdin_handle == w.INVALID_HANDLE_VALUE) return;

        var buf: [1]u8 = undefined;
        var bytes_read: w.DWORD = 0;
        _ = ReadFile(stdin_handle.?, &buf, 1, &bytes_read, null);
    } else {
        var buf: [1]u8 = undefined;
        _ = std.posix.read(std.posix.STDIN_FILENO, &buf) catch {};
    }
}

pub fn main() !void {
    // 设置 Windows 控制台 UTF-8 编码
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;

        _ = SetConsoleOutputCP(65001);
        _ = SetConsoleCP(65001);

        // 启用 ANSI 转义序列支持
        const h = GetStdHandle(STD_OUTPUT_HANDLE);
        if (h != null and h != w.INVALID_HANDLE_VALUE) {
            var m: w.DWORD = 0;
            if (GetConsoleMode(h.?, &m).toBool()) {
                _ = SetConsoleMode(h.?, m | 0x0004);
            }
        }
    }

    // 执行核心逻辑
    fix_hosts.run() catch |err| {
        std.debug.print("\n[错误] 执行失败: {s}\n", .{@errorName(err)});
        waitForKeyPress();
        std.process.exit(1);
    };

    // 正常退出前等待用户按键（避免双击时窗口一闪而过）
    waitForKeyPress();
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
