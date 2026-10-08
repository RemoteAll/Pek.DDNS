//! Hosts 文件读写与 DNS 缓存刷新工具
//!
//! 负责读取/修改 C:\Windows\System32\drivers\etc\hosts 文件，
//! 以及执行 ipconfig /flushdns 刷新系统 DNS 缓存。

use std::fs;
use std::process::Command;
use std::sync::atomic::AtomicBool;

/// 标记当前是否已修改 hosts 且尚未清理（供控制台事件处理器使用）
pub static CLEANUP_NEEDED: AtomicBool = AtomicBool::new(false);

/// Hosts 文件路径（仅 Windows）
const HOSTS_PATH: &str = "C:\\Windows\\System32\\drivers\\etc\\hosts";

/// Hosts 备份文件路径
const BACKUP_PATH: &str = "C:\\Windows\\System32\\drivers\\etc\\hosts.fixhosts.bak";

/// 执行结果
pub struct HostsResult {
    /// true 表示 hosts 文件实际发生了修改
    pub changed: bool,
    /// 当前 hosts 中的 IP 值（修改前或不变的值）
    pub current_ip: String,
}

/// 在 hosts 文件内容中查找指定域名的 IP
fn find_host_ip(content: &str, domain: &str) -> Option<String> {
    for line in content.lines() {
        let trimmed = line.trim();
        // 跳过空行和注释行
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        // 查找域名是否在这行中
        if !trimmed.contains(domain) {
            continue;
        }

        // 提取 IP（行首到第一个空白符）
        let ip_end = trimmed.find(|c: char| c == ' ' || c == '\t')?;
        let ip = &trimmed[..ip_end];
        // 验证 IP 格式（简单检查：包含点号）
        if !ip.contains('.') {
            continue;
        }
        return Some(ip.to_string());
    }
    None
}

/// 将 hosts 内容中指定域名的 IP 替换为新值
fn replace_ip_in_hosts(content: &str, domain: &str, new_ip: &str) -> String {
    let mut result = String::with_capacity(content.len());

    for line in content.lines() {
        // 去除末尾 \r（Windows 换行符）
        let trimmed = line.trim_end_matches('\r');

        // 检查这行是否包含目标域名
        if trimmed.contains(domain) {
            // 跳过注释行
            let trimmed_left = trimmed.trim_start();
            if !trimmed_left.is_empty() && !trimmed_left.starts_with('#') {
                // 构造新行：new_ip + 空白 + 域名及后面内容
                if let Some(domain_pos) = trimmed.find(domain) {
                    let after_domain = &trimmed[domain_pos + domain.len()..];
                    result.push_str(new_ip);
                    result.push_str(" \t");
                    result.push_str(domain);
                    result.push_str(after_domain);
                    result.push('\n');
                    continue;
                }
            }
        }

        // 非目标行，原样保留
        result.push_str(trimmed);
        result.push('\n');
    }

    result
}

/// 备份当前 hosts 文件
fn backup_hosts_file() -> Result<(), String> {
    let content = match fs::read(HOSTS_PATH) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err("无法访问 hosts 文件，请以管理员身份运行本程序！".to_string());
        }
        Err(e) => return Err(format!("读取 hosts 文件失败: {}", e)),
    };

    fs::write(BACKUP_PATH, &content).map_err(|e| {
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            "无法写入备份文件，请以管理员身份运行本程序！".to_string()
        } else {
            format!("备份 hosts 文件失败: {}", e)
        }
    })?;

    Ok(())
}

/// 更新 hosts 文件：将指定域名的 IP 设为新值
/// 若域名已存在则替换，否则追加
/// 修改前自动备份原文件
pub fn update_host_entry(domain: &str, new_ip: &str) -> Result<HostsResult, String> {
    // 1. 备份原 hosts 文件
    backup_hosts_file()?;

    // 2. 读取当前 hosts 内容
    let content = match fs::read_to_string(HOSTS_PATH) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err("无法访问 hosts 文件，请以管理员身份运行本程序！".to_string());
        }
        Err(e) => return Err(format!("读取 hosts 文件失败: {}", e)),
    };

    // 3. 检查是否已有该域名
    if let Some(existing_ip) = find_host_ip(&content, domain) {
        if existing_ip == new_ip {
            // IP 未变化，无需修改
            return Ok(HostsResult {
                changed: false,
                current_ip: existing_ip,
            });
        }

        // IP 变化：替换行中的 IP
        let new_content = replace_ip_in_hosts(&content, domain, new_ip);
        fs::write(HOSTS_PATH, &new_content).map_err(|e| {
            if e.kind() == std::io::ErrorKind::PermissionDenied {
                "无法写入 hosts 文件，请以管理员身份运行本程序！".to_string()
            } else {
                format!("写入 hosts 文件失败: {}", e)
            }
        })?;

        Ok(HostsResult {
            changed: true,
            current_ip: new_ip.to_string(),
        })
    } else {
        // 域名不存在：追加一行
        let mut new_content = content;
        // 确保末尾有换行
        if !new_content.is_empty() && !new_content.ends_with('\n') {
            new_content.push('\n');
        }
        new_content.push_str(new_ip);
        new_content.push_str(" \t");
        new_content.push_str(domain);
        new_content.push('\n');

        fs::write(HOSTS_PATH, &new_content).map_err(|e| {
            if e.kind() == std::io::ErrorKind::PermissionDenied {
                "无法写入 hosts 文件，请以管理员身份运行本程序！".to_string()
            } else {
                format!("写入 hosts 文件失败: {}", e)
            }
        })?;

        Ok(HostsResult {
            changed: true,
            current_ip: new_ip.to_string(),
        })
    }
}

/// 从 hosts 文件中移除指定域名的条目
/// 返回 true 表示实际移除了条目，false 表示未找到对应条目
pub fn remove_host_entry(domain: &str) -> Result<bool, String> {
    let content = match fs::read_to_string(HOSTS_PATH) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err("无法访问 hosts 文件，请以管理员身份运行本程序！".to_string());
        }
        Err(e) => return Err(format!("读取 hosts 文件失败: {}", e)),
    };

    // 查找域名所在的行并移除
    let mut new_lines = String::with_capacity(content.len());
    let mut found = false;

    for line in content.lines() {
        let trimmed = line.trim_end_matches('\r');

        // 检查这行是否包含目标域名（非注释行）
        let is_target = trimmed.contains(domain)
            && !trimmed.trim_start().starts_with('#')
            && {
                let trimmed_left = trimmed.trim_start();
                // 行首是 IP（含点号）
                let ip_end = trimmed_left.find(|c: char| c == ' ' || c == '\t').unwrap_or(usize::MAX);
                ip_end < domain.len() + 20 // 粗略判断是 hosts 条目而非巧合
            };

        if is_target {
            found = true;
            // 跳过此行（不追加到 new_lines）
            continue;
        }

        new_lines.push_str(trimmed);
        new_lines.push('\n');
    }

    if found {
        fs::write(HOSTS_PATH, &new_lines).map_err(|e| {
            if e.kind() == std::io::ErrorKind::PermissionDenied {
                "无法写入 hosts 文件，请以管理员身份运行本程序！".to_string()
            } else {
                format!("写入 hosts 文件失败: {}", e)
            }
        })?;
    }

    Ok(found)
}

/// 执行 ipconfig /flushdns 刷新系统 DNS 缓存
pub fn flush_dns() -> Result<(), String> {
    #[cfg(not(target_os = "windows"))]
    {
        println!("[信息] 非 Windows 平台，跳过 flushdns");
        return Ok(());
    }

    #[cfg(target_os = "windows")]
    {
        let output = Command::new("ipconfig")
            .arg("/flushdns")
            .output()
            .map_err(|e| format!("执行 ipconfig 失败: {}", e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            return Err(format!(
                "ipconfig 返回错误:\nstdout: {}\nstderr: {}",
                stdout, stderr
            ));
        }

        Ok(())
    }
}


