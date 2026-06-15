//! DNSPod API 客户端
//!
//! 通过 DNSPod API 查询域名的 DNS 记录。

use serde::Deserialize;

/// DNSPod API 响应
#[derive(Deserialize, Debug)]
struct DnsPodResponse {
    #[serde(rename = "code")]
    code: Option<String>,
    #[serde(rename = "message")]
    message: Option<String>,
    #[serde(rename = "records")]
    records: Option<Vec<Record>>,
}

/// DNS 记录
#[derive(Deserialize, Debug)]
struct Record {
    #[serde(rename = "value")]
    value: Option<String>,
}

/// 颜色常量
const RESET: &str = "\x1b[0m";
const RED: &str = "\x1b[31m";

/// 通过 DNSPod API 查询目标域名的 A 记录 IP
pub fn query_record(
    token_id: &str,
    token: &str,
    domain: &str,
    sub_domain: &str,
    record_type: &str,
) -> Result<String, String> {
    // 构造 POST 表单数据
    let login_token = format!("{},{}", token_id, token);
    let form_body = format!(
        "login_token={}&format=json&domain={}&sub_domain={}&record_type={}",
        login_token, domain, sub_domain, record_type
    );

    println!("   正在请求 DNSPod API...");

    // 发起 HTTP POST 请求
    let response = ureq::post("https://dnsapi.cn/Record.List")
        .set("Content-Type", "application/x-www-form-urlencoded")
        .send_string(&form_body)
        .map_err(|e| {
            format!("网络请求失败: {}", e)
        })?;

    // 检查 HTTP 状态码
    let status = response.status();
    if status != 200 {
        return Err(format!("API 返回非 200 状态码: {}", status));
    }

    // 读取响应正文
    let body = response.into_string().map_err(|e| format!("读取响应失败: {}", e))?;

    // 解析 JSON 响应
    let parsed: DnsPodResponse = serde_json::from_str(&body).map_err(|e| {
        format!("JSON 解析失败: {}\n响应内容: {}", e, body)
    })?;

    // 检查 API 错误码
    if let Some(ref code) = parsed.code {
        if code != "0" {
            let msg = parsed.message.as_deref().unwrap_or("未知错误");
            return Err(format!(
                "{}[API 错误]{} DNSPod API 返回错误: {}",
                RED, RESET, msg
            ));
        }
    }

    // 提取第一条记录的值
    if let Some(records) = parsed.records {
        if let Some(first) = records.first() {
            if let Some(ref value) = first.value {
                return Ok(value.clone());
            }
        }
    }

    Err("未找到 DNS 记录或记录格式异常".to_string())
}
