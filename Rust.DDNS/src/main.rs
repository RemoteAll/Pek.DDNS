mod config;
mod ddns;
mod dnspod;
mod logger;

use std::io::Read;

/// 跨平台等待用户按键，避免窗口一闪而过
fn wait_for_key_press() {
    warn!("");
    info!("按任意键退出...");

    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 1];
    let _ = stdin.read(&mut buf);
}

/// 配置错误退出：显示错误信息后等待用户按键
fn config_error() -> ! {
    wait_for_key_press();
    std::process::exit(1);
}

fn main() {
    // Windows 控制台 UTF-8 支持
    #[cfg(windows)]
    {
        unsafe {
            // 设置控制台输出为 UTF-8 (代码页 65001)
            kernel32::SetConsoleOutputCP(65001);
            kernel32::SetConsoleCP(65001);

            // 启用虚拟终端处理（支持 ANSI 转义序列）
            let h = kernel32::GetStdHandle(kernel32::STD_OUTPUT_HANDLE);
            if h != kernel32::INVALID_HANDLE_VALUE as _ && !h.is_null() {
                let mut mode: u32 = 0;
                if kernel32::GetConsoleMode(h, &mut mode) != 0 {
                    kernel32::SetConsoleMode(h, mode | 0x0004);
                }
            }
        }
    }

    // 优先使用配置文件 config.json
    let config_path = "config.json";
    match config::ensure_config(config_path) {
        Ok(true) => {}  // 配置文件已存在
        Ok(false) => {
            warn!("已生成配置文件 {}，请填入实际值后再运行。", config_path);
            config_error();
        }
        Err(e) => {
            error!("检查配置文件失败: {}", e);
            config_error();
        }
    }

    // 加载配置
    let cfg = match config::load_config(config_path) {
        Ok(c) => c,
        Err(e) => {
            error!("{}", e);
            config_error();
        }
    };

    // 验证配置
    if cfg.domain.is_empty() || cfg.domain == "example.com" {
        error!("请在 config.json 中配置真实的 domain");
        config_error();
    }

    // 验证 DNSPod 配置
    if let Some(ref dp) = cfg.dnspod {
        if dp.token_id.is_empty() || dp.token_id == "你的TokenId" {
            error!("请在 config.json 中配置真实的 DNSPod API Token");
            warn!("请访问 https://console.dnspod.cn/account/token/apikey 获取");
            config_error();
        }
    }

    // 运行 DDNS
    if let Err(e) = ddns::run(&cfg) {
        error!("程序异常退出: {}", e);
        config_error();
    }
}

// Windows kernel32 API 绑定
#[cfg(windows)]
mod kernel32 {
    use std::ffi::c_void;

    pub const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5u32;
    pub const INVALID_HANDLE_VALUE: isize = -1;

    pub type DWORD = u32;
    pub type HANDLE = *mut c_void;
    pub type LPDWORD = *mut DWORD;

    extern "system" {
        pub fn SetConsoleOutputCP(wCodePageID: DWORD) -> i32;
        pub fn SetConsoleCP(wCodePageID: DWORD) -> i32;
        pub fn GetStdHandle(nStdHandle: DWORD) -> HANDLE;
        pub fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: LPDWORD) -> i32;
        pub fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) -> i32;
    }
}


