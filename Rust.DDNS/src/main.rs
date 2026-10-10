mod config;
mod ddns;
mod dnspod;

use dhrust::logs::{error, info, warn};
use std::io::Read;

/// 跨平台等待用户按键，避免窗口一闪而过
fn wait_for_key_press() {
    warn!("");
    info!("按任意键退出...");

    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 1];
    let _ = stdin.read(&mut buf);
}

/// 配置错误退出：等待按键、日志同步落盘后以非零码退出
fn config_error() -> ! {
    wait_for_key_press();
    dhrust::logs::flush();
    std::process::exit(1);
}

fn main() {
    // 日志：DH.RustBase 通用日志（控制台着色 + 按天文件 Log/；RUST_LOG 调整级别，默认 Info）
    dhrust::logs::init_console_and_file("Log", true, dhrust::logs::level_from_env());

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



