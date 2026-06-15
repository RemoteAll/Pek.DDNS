//! Rust.FixHosts — 通过 DNSPod API 查询域名 IP 并更新本地 hosts 文件
//!
//! 通过嵌入的 Windows 清单声明 requireAdministrator，
//! Windows 会在启动前自动弹出 UAC 提权，无需代码动态处理。
//! 成功启动后自动查询硬编码的目标域名在 DNSPod 上的 A 记录，
//! 更新到 C:\Windows\System32\drivers\etc\hosts 中，
//! 并执行 ipconfig /flushdns 刷新系统 DNS 缓存，使新 IP 立即生效。

mod dnspod;
mod fix_hosts;
mod hosts;
mod secret;

use std::io::{self, Read};

// ═══════════════════════════════════════════════════════════════

/// 等待用户按键后退出
fn wait_for_key_press() {
    print!("\n按任意键退出...");
    // 确保输出被刷新
    let _ = std::io::Write::flush(&mut std::io::stdout());

    #[cfg(target_os = "windows")]
    {
        // Windows 下使用控制台原始读取，避免行缓冲
        let mut stdin = io::stdin();
        let mut buf = [0u8; 1];
        let _ = stdin.read_exact(&mut buf);
    }

    #[cfg(not(target_os = "windows"))]
    {
        let mut buf = [0u8; 1];
        let _ = std::io::stdin().read_exact(&mut buf);
    }
}

/// 设置 Windows 控制台为 UTF-8 编码并启用 ANSI 转义序列支持
#[cfg(target_os = "windows")]
fn setup_console() {
    // 声明 Windows API 函数
    extern "system" {
        fn SetConsoleOutputCP(wCodePageID: u32) -> i32;
        fn SetConsoleCP(wCodePageID: u32) -> i32;
        fn GetStdHandle(nStdHandle: u32) -> isize;
        fn GetConsoleMode(hConsoleHandle: isize, lpMode: *mut u32) -> i32;
        fn SetConsoleMode(hConsoleHandle: isize, dwMode: u32) -> i32;
    }

    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5;
    const INVALID_HANDLE_VALUE: isize = -1;

    unsafe {
        // 设置控制台代码页为 UTF-8 (65001)
        SetConsoleOutputCP(65001);
        SetConsoleCP(65001);

        // 启用 ANSI 转义序列支持（ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004）
        let h = GetStdHandle(STD_OUTPUT_HANDLE);
        if h != 0 && h != INVALID_HANDLE_VALUE {
            let mut mode: u32 = 0;
            if GetConsoleMode(h, &mut mode) != 0 {
                SetConsoleMode(h, mode | 0x0004);
            }
        }
    }
}

#[cfg(not(target_os = "windows"))]
fn setup_console() {
    // 非 Windows 平台无需特殊设置
}

fn main() {
    // 设置控制台 UTF-8 编码和 ANSI 支持
    //（管理员权限由嵌入的 Windows 清单静态声明，启动前 Windows 自动弹 UAC）
    setup_console();

    // 执行核心逻辑
    if let Err(e) = fix_hosts::run() {
        eprintln!("\n[错误] 执行失败: {}", e);
    }

    // 正常退出前等待用户按键（避免双击时窗口一闪而过）
    wait_for_key_press();
}
