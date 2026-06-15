//! FixHosts 核心逻辑
//!
//! 硬编码 DNSPod 凭证和目标域名，通过 DNSPod API 查询 A 记录 IP，
//! 然后更新本地 hosts 文件并刷新 DNS 缓存。

use crate::dnspod;
use crate::hosts;
use crate::secret;

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
/// 2. 更新本地 hosts 文件
/// 3. 刷新 DNS 缓存
/// 4. 验证连通性
pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    println!("{}{}{}", CYAN, "────────────────────────────────────────", RESET);
    println!("{}{}  Hlk.FixHosts — DNSPod → Hosts 更新工具{}", BOLD, CYAN, RESET);
    println!("{}{}{}", CYAN, "────────────────────────────────────────", RESET);
    println!();

    // ── 步骤 1：通过 DNSPod API 查询记录 IP ──
    println!("{}➜ 步骤 1/4：查询 DNSPod 记录...{}", CYAN, RESET);
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

    // ── 步骤 2：更新 hosts 文件 ──
    println!();
    println!("{}➜ 步骤 2/4：更新 hosts 文件...{}", CYAN, RESET);

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
            "   {}✓{} hosts 文件已更新: {}{}{} → {}{}{}",
            GREEN, RESET, RED, result.current_ip, RESET, GREEN, dnspod_ip, RESET
        );
    } else {
        println!(
            "   {}✓{} hosts 中 IP 无变化（{}{}{}），跳过写入{}",
            GREEN, RESET, YELLOW, result.current_ip, RESET, RESET
        );
    }

    // ── 步骤 3：刷新 DNS 缓存 ──
    println!();
    println!("{}➜ 步骤 3/4：刷新 DNS 缓存...{}", CYAN, RESET);
    match hosts::flush_dns() {
        Ok(()) => {
            println!("   {}✓{} 完成", GREEN, RESET);
        }
        Err(e) => {
            println!("   {}[警告]{} 刷新 DNS 缓存失败: {}", YELLOW, RESET, e);
        }
    }

    // ── 步骤 4：验证连通性 ──
    println!();
    println!("{}➜ 步骤 4/4：验证连通性...{}", CYAN, RESET);
    let verify_ok = verify_reachability();
    if verify_ok {
        println!(
            "   {}✓{} 请求成功 — {}{}:8099{} 已可访问",
            GREEN, RESET, BOLD, full_domain, RESET
        );
    } else {
        println!(
            "   {}✗{} 请求失败 — {}{}:8099{} 暂时无法连通",
            RED, RESET, YELLOW, full_domain, RESET
        );
        println!("   可能是服务端未就绪或网络策略限制，请稍后手动验证");
    }

    // ── 输出结果摘要 ──
    println!();
    println!("{}{}{}", GREEN, "────────────────────────────────────────", RESET);
    if verify_ok {
        println!("{}✓ 全部完成！{}", GREEN, RESET);
    } else {
        println!("{}⚠ 部分完成（hosts 已更新，但连通验证未通过）{}", YELLOW, RESET);
    }
    println!("  {}域名:{}  {}.{}", YELLOW, RESET, TARGET_SUB_DOMAIN, TARGET_DOMAIN);
    println!("  {}IP:{}    {}{}{}", YELLOW, RESET, BOLD, dnspod_ip, RESET);
    if result.changed {
        println!("  {}状态:{}  hosts 已更新 + DNS 缓存已刷新", YELLOW, RESET);
    } else {
        println!("  {}状态:{}  hosts 无需变更", YELLOW, RESET);
    }
    println!("{}{}{}", GREEN, "────────────────────────────────────────", RESET);

    Ok(())
}
