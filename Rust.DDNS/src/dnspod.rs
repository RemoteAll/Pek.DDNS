use crate::config::{Config, DnsPodConfig};
use crate::debug;
use std::time::Duration;

/// DNSPod 记录结构
#[derive(Debug)]
pub struct DnsPodRecord {
    pub id: String,
    pub value: String,
    pub ttl: u32,
}

const USER_AGENT: &str = "Zig-DDNS/1.0";
const API_BASE: &str = "https://dnsapi.cn";

/// DNSPod API 请求/响应工具
impl DnsPodConfig {
    /// 构建 login_token 字符串
    fn login_token(&self) -> String {
        format!("{},{}", self.token_id, self.token)
    }
}

/// 发送 POST 表单请求到 DNSPod API，带超时
fn post_form(
    url: &str,
    form_data: &[(&str, String)],
    timeout_sec: u64,
) -> Result<String, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(timeout_sec))
        .timeout_read(Duration::from_secs(timeout_sec))
        .timeout_write(Duration::from_secs(timeout_sec))
        .user_agent(USER_AGENT)
        .build();

    debug!("POST {}", url);

    // 将 (key, String) 转换为 (key, &str)
    let form_refs: Vec<(&str, &str)> = form_data
        .iter()
        .map(|(k, v)| (*k, v.as_str()))
        .collect();

    let resp = agent
        .post(url)
        .set("Content-Type", "application/x-www-form-urlencoded")
        .send_form(&form_refs)
        .map_err(|e| {
            let reason = match &e {
                ureq::Error::Status(code, _) => format!("HTTP {}", code),
                ureq::Error::Transport(t) => format!("网络错误: {}", t),
            };
            format!("请求失败: {}", reason)
        })?;

    let body = resp
        .into_string()
        .map_err(|e| format!("读取响应失败: {}", e))?;

    Ok(body)
}

/// 查找 DNS 记录
///
/// 遍历所有记录：
/// 1. 如果已有记录的 value 等于 current_ip → 返回该记录（无需更新）
/// 2. 如果没有记录匹配 current_ip → 返回第一条记录（用于修改）
/// 3. 如果数组为空 → 返回 None（需要新建）
pub fn find_record(
    config: &DnsPodConfig,
    domain: &str,
    sub: &str,
    rtype: &str,
    current_ip: &str,
    timeout_sec: u64,
) -> Result<Option<DnsPodRecord>, String> {
    let url = format!("{}/Record.List", API_BASE);
    let login_token = config.login_token();
    let form = &[
        ("login_token", login_token),
        ("format", "json".to_string()),
        ("domain", domain.to_string()),
        ("sub_domain", sub.to_string()),
        ("record_type", rtype.to_string()),
    ];

    debug!("dnspod Record.List - domain={} sub_domain={} type={}", domain, sub, rtype);

    let resp = post_form(&url, form, timeout_sec)?;
    debug!("dnspod response: {}", resp);

    // 解析 JSON 响应并检查 API 状态
    let json: serde_json::Value =
        serde_json::from_str(&resp).map_err(|e| format!("JSON 解析失败: {}", e))?;

    if let Some(status) = json.get("status") {
        if let (Some(code), Some(msg)) = (status.get("code"), status.get("message")) {
            let code_str = code.as_str().unwrap_or("");
            let msg_str = msg.as_str().unwrap_or("");
            debug!("dnspod status: code={} message={}", code_str, msg_str);
            if code_str != "1" {
                return Err(format!("DNSPod API 错误 ({}): {}", code_str, msg_str));
            }
        }
    }

    let records = json.get("records");
    if records.is_none() {
        return Ok(None);
    }

    let records = records.unwrap();
    let arr = match records.as_array() {
        Some(a) if !a.is_empty() => a,
        _ => return Ok(None),
    };

    // 遍历所有记录，提取 id/value/ttl，优先找已匹配 current_ip 的记录
    let mut first_record: Option<DnsPodRecord> = None;
    for item in arr {
        let id = match item.get("id").and_then(|v| v.as_str()) {
            Some(id) => id.to_string(),
            None => continue,
        };
        let value = match item.get("value").and_then(|v| v.as_str()) {
            Some(v) => v.to_string(),
            None => continue,
        };
        let ttl = item
            .get("ttl")
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(600);

        // 如果这条记录已经匹配当前 IP，直接返回（无需更新）
        if value == current_ip {
            debug!(
                "dnspod: 记录 {} 已匹配当前 IP={}，无需更新",
                id, current_ip
            );
            return Ok(Some(DnsPodRecord { id, value, ttl }));
        }

        // 记录第一条作为候选（备用修改目标）
        if first_record.is_none() {
            first_record = Some(DnsPodRecord { id, value, ttl });
        }
    }

    // 没有记录匹配当前 IP，返回第一条记录供修改
    Ok(first_record)
}

/// 创建 DNS 记录
pub fn create_record(
    config: &DnsPodConfig,
    domain: &str,
    sub: &str,
    rtype: &str,
    ip: &str,
    cfg: &Config,
    timeout_sec: u64,
) -> Result<(), String> {
    let url = format!("{}/Record.Create", API_BASE);
    let dp = cfg.dnspod.as_ref().unwrap();
    let login_token = config.login_token();
    let ttl_str = dp.ttl.to_string();
    let form = &[
        ("login_token", login_token),
        ("format", "json".to_string()),
        ("domain", domain.to_string()),
        ("sub_domain", sub.to_string()),
        ("record_type", rtype.to_string()),
        ("record_line", dp.line.clone()),
        ("value", ip.to_string()),
        ("ttl", ttl_str),
    ];

    debug!(
        "dnspod Record.Create - domain={} sub={} type={} value={}",
        domain, sub, rtype, ip
    );

    let resp = post_form(&url, form, timeout_sec)?;
    debug!("dnspod response: {}", resp);
    print_dnspod_status(&resp);

    // 检查返回码: code=1 成功, code=104 记录已存在（值相同），视为成功
    if resp.contains("\"code\":\"1\"") || resp.contains("\"code\":\"104\"") {
        return Ok(());
    }
    Err("API 返回非成功状态".to_string())
}

/// 修改 DNS 记录
pub fn modify_record(
    config: &DnsPodConfig,
    record_id: &str,
    domain: &str,
    sub: &str,
    rtype: &str,
    ip: &str,
    cfg: &Config,
    timeout_sec: u64,
) -> Result<(), String> {
    let url = format!("{}/Record.Modify", API_BASE);
    let dp = cfg.dnspod.as_ref().unwrap();
    let login_token = config.login_token();
    let ttl_str = dp.ttl.to_string();
    let form = &[
        ("login_token", login_token),
        ("format", "json".to_string()),
        ("domain", domain.to_string()),
        ("record_id", record_id.to_string()),
        ("sub_domain", sub.to_string()),
        ("record_type", rtype.to_string()),
        ("record_line", dp.line.clone()),
        ("value", ip.to_string()),
        ("ttl", ttl_str),
    ];

    debug!(
        "dnspod Record.Modify - id={} domain={} sub={} type={} new_value={}",
        record_id, domain, sub, rtype, ip
    );

    let resp = post_form(&url, form, timeout_sec)?;
    debug!("dnspod response: {}", resp);
    print_dnspod_status(&resp);

    // code=1: 成功; code=104: 记录已存在（值相同），视为成功
    if resp.contains("\"code\":\"1\"") || resp.contains("\"code\":\"104\"") {
        return Ok(());
    }
    Err("API 返回非成功状态".to_string())
}

/// 打印 DNSPod 响应中的状态信息
fn print_dnspod_status(resp: &str) {
    if let Ok(json) = serde_json::from_str::<serde_json::Value>(resp) {
        if let Some(status) = json.get("status") {
            let code = status
                .get("code")
                .and_then(|v| v.as_str())
                .unwrap_or("?");
            let msg = status
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("?");
            debug!("dnspod status: code={} message={}", code, msg);
            return;
        }
    }
    let preview = if resp.len() > 200 { &resp[..200] } else { resp };
    debug!("dnspod status raw: {}...", preview);
}
