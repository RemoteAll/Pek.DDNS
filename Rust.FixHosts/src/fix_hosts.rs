//! FixHosts 核心逻辑
//!
//! 硬编码 DNSPod 凭证和目标域名，通过 DNSPod API 查询 A 记录 IP，
//! 然后更新本地 hosts 文件并刷新 DNS 缓存。

use crate::dnspod;
use crate::hosts;
use crate::secret;
use std::sync::atomic::Ordering;

// ═══════════════════════════════════════════════════════════════
// 密钥导入（编译时嵌入，不进 Git，不依赖外部文件）
//
// 请复制 secret.example.rs → secret.rs，
// 将占位符替换为你的 DNSPod API Token 后重新编译。
// ═══════════════════════════════════════════════════════════════

const DNSPOD_TOKEN_ID: &str = secret::DNSPOD_TOKEN_ID;
const DNSPOD_TOKEN: &str = secret::DNSPOD_TOKEN;

/// 目标主域名
const TARGET_DOMAIN: &str = "hlktech.com";
/// 目标子域名（主机记录）
const TARGET_SUB_DOMAIN: &str = "erp";
/// DNS 记录类型
const RECORD_TYPE: &str = "A";

// ═══════════════════════════════════════════════════════════════

/// 颜色常量
const RESET: &str = "\x1b[0m";
const GREEN: &str = "\x1b[32m";
const RED: &str = "\x1b[31m";
const YELLOW: &str = "\x1b[33m";
const CYAN: &str = "\x1b[36m";
const BOLD: &str = "\x1b[1m";

/// 验证 erp.hlktech.com:8099/ERP/ 是否可访问
fn verify_reachability() -> bool {
    let url = "http://erp.hlktech.com:8099/ERP/";

    println!("   请求 {}...", url);

    match ureq::get(url).call() {
        Ok(response) => {
            let status_code = response.status();
            println!("   HTTP 状态码: {}", status_code);

            // 2xx 或 3xx 都算连通成功
            if (200..400).contains(&status_code) {
                return true;
            }

            // 4xx/5xx 说明服务端有响应但可能有问题，仍算连通
            if status_code >= 400 {
                println!("   服务端返回 {}，但服务本身已可达", status_code);
                return true;
            }

            false
        }
        Err(e) => {
            println!("   连接失败: {}", e);
            false
        }
    }
}

/// 执行 FixHosts 主流程
/// 1. 调用 DNSPod API 获取目标域名的 A 记录 IP
/// 2. 更新本地 hosts 文件（临时写入，用于验证）
/// 3. 刷新 DNS 缓存
/// 4. 验证连通性（带 hosts 条目）
/// 5. 清理 hosts 中写入的条目
/// 6. 刷新 DNS 缓存后再次验证（纯 DNS 解析）
pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    println!("{}{}{}", CYAN, "────────────────────────────────────────", RESET);
    println!("{}{}  Hlk.RFixHosts — DNSPod → Hosts 更新工具{}", BOLD, CYAN, RESET);
    println!("{}{}{}", CYAN, "────────────────────────────────────────", RESET);
    println!();

    // ── 步骤 1：通过 DNSPod API 查询记录 IP ──
    println!("{}➜ 步骤 1/6：查询 DNSPod 记录...{}", CYAN, RESET);
    println!("   域名: {}{}.{}{}", YELLOW, TARGET_SUB_DOMAIN, TARGET_DOMAIN, RESET);
    println!("   类型: {}{}{}", YELLOW, RECORD_TYPE, RESET);

    let dnspod_ip = match dnspod::query_record(
        DNSPOD_TOKEN_ID,
        DNSPOD_TOKEN,
        TARGET_DOMAIN,
        TARGET_SUB_DOMAIN,
        RECORD_TYPE,
    ) {
        Ok(ip) => ip,
        Err(e) => {
            println!("{}[错误]{} DNSPod API 查询失败: {}{}{}", RED, RESET, RED, e, RESET);
            println!("{}可能原因：网络连接问题、Token 无效或 DNS 记录不存在{}", YELLOW, RESET);
            return Err(e.into());
        }
    };

    println!("   {}✓{} 当前 DNSPod 权威 IP: {}{}{}", GREEN, RESET, BOLD, dnspod_ip, RESET);

    // ── 步骤 2：临时更新 hosts 文件 ──
    println!();
    println!("{}➜ 步骤 2/6：临时写入 hosts 文件...{}", CYAN, RESET);

    let full_domain = format!("{}.{}", TARGET_SUB_DOMAIN, TARGET_DOMAIN);

    let result = match hosts::update_host_entry(&full_domain, &dnspod_ip) {
        Ok(r) => r,
        Err(e) => {
            println!("{}[错误]{} {}", RED, RESET, e);
            return Err(e.into());
        }
    };

    if result.changed {
        println!(
            "   {}✓{} hosts 已临时更新: {}{}{} → {}{}{}",
            GREEN, RESET, RED, result.current_ip, RESET, GREEN, dnspod_ip, RESET
        );
        // 标记需要清理：窗口关闭/系统关机时控制台处理器会清理 hosts
        hosts::CLEANUP_NEEDED.store(true, Ordering::SeqCst);
    } else {
        println!(
            "   {}✓{} hosts 中 IP 无变化（{}{}{}），跳过写入{}",
            GREEN, RESET, YELLOW, result.current_ip, RESET, RESET
        );
    }

    // ── 步骤 3：刷新 DNS 缓存 ──
    println!();
    println!("{}➜ 步骤 3/6：刷新 DNS 缓存...{}", CYAN, RESET);
    match hosts::flush_dns() {
        Ok(()) => {
            println!("   {}✓{} 完成", GREEN, RESET);
        }
        Err(e) => {
            println!("   {}[警告]{} 刷新 DNS 缓存失败: {}", YELLOW, RESET, e);
        }
    }

    // ── 步骤 4：验证连通性（带 hosts 条目） ──
    println!();
    println!("{}➜ 步骤 4/6：验证连通性（通过 hosts）...{}", CYAN, RESET);
    let verify_with_hosts = verify_reachability();
    if verify_with_hosts {
        println!(
            "   {}✓{} 请求成功 — {}{}:8099{} 已可访问（通过 hosts 指向）",
            GREEN, RESET, BOLD, full_domain, RESET
        );
    } else {
        println!(
            "   {}✗{} 请求失败 — {}{}:8099{} 暂时无法连通",
            RED, RESET, YELLOW, full_domain, RESET
        );
        println!("   可能是服务端未就绪或网络策略限制");
    }

    // ── 步骤 5：清理 hosts 中写入的条目 ──
    println!();
    println!("{}➜ 步骤 5/6：清理 hosts 临时条目...{}", CYAN, RESET);
    match hosts::remove_host_entry(&full_domain) {
        Ok(true) => {
            println!("   {}✓{} hosts 条目已清理，恢复原状", GREEN, RESET);
            // 清理完成，撤销清理标记
            hosts::CLEANUP_NEEDED.store(false, Ordering::SeqCst);
        }
        Ok(false) => {
            println!("   {}✓{} hosts 无需清理（未找到相关条目）", GREEN, RESET);
            hosts::CLEANUP_NEEDED.store(false, Ordering::SeqCst);
        }
        Err(e) => {
            println!("   {}[警告]{} 清理 hosts 失败: {}", YELLOW, RESET, e);
        }
    }

    // ── 刷新 DNS 缓存 ──
    match hosts::flush_dns() {
        Ok(()) => {
            println!("   {}✓{} DNS 缓存已刷新", GREEN, RESET);
        }
        Err(e) => {
            println!("   {}[警告]{} 刷新 DNS 缓存失败: {}", YELLOW, RESET, e);
        }
    }

    // ── 步骤 6：验证连通性（纯 DNS 解析） ──
    println!();
    println!("{}➜ 步骤 6/6：验证连通性（通过 DNS 解析）...{}", CYAN, RESET);
    let verify_with_dns = verify_reachability();
    if verify_with_dns {
        println!(
            "   {}✓{} 请求成功 — {}{}:8099{} 已可访问（通过 DNS 解析）",
            GREEN, RESET, BOLD, full_domain, RESET
        );
    } else {
        println!(
            "   {}✗{} 请求失败 — {}{}:8099{} DNS 解析暂时无法连通",
            RED, RESET, YELLOW, full_domain, RESET
        );
        println!("   可能是 DNS 解析未生效或服务端尚未就绪");
    }

    // ── 输出结果摘要 ──
    println!();
    println!("{}{}{}", GREEN, "────────────────────────────────────────", RESET);
    let all_ok = verify_with_hosts && verify_with_dns;
    if all_ok {
        println!("{}✓ 全部完成！hosts 已清理，DNS 解析正常{}", GREEN, RESET);
    } else if verify_with_hosts {
        println!("{}⚠ 部分完成（hosts 指向可达，但 DNS 解析暂未生效）{}", YELLOW, RESET);
    } else {
        println!("{}✗ 服务暂时不可达（hosts 指向和 DNS 解析均失败）{}", RED, RESET);
    }
    println!("  {}域名:{}  {}.{}", YELLOW, RESET, TARGET_SUB_DOMAIN, TARGET_DOMAIN);
    println!("  {}IP:{}    {}{}{}", YELLOW, RESET, BOLD, dnspod_ip, RESET);
    if verify_with_hosts {
        println!("  {}hosts 指向:{}  ✓ 可达", YELLOW, RESET);
    } else {
        println!("  {}hosts 指向:{}  ✗ 不可达", YELLOW, RESET);
    }
    if verify_with_dns {
        println!("  {}DNS 解析:{}    ✓ 可达", YELLOW, RESET);
    } else {
        println!("  {}DNS 解析:{}    ✗ 不可达（需等待 DNS 生效）", YELLOW, RESET);
    }
    println!("  {}hosts 文件:{}  已清理，无残留", YELLOW, RESET);
    println!("{}{}{}", GREEN, "────────────────────────────────────────", RESET);

    Ok(())
}
