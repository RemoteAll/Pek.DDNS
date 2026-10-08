use serde::Deserialize;
use serde::Serialize;
use std::fs;
use std::path::Path;

/// DNS 服务商枚举
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    DnsPod,
}

/// DNSPod 专属配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DnsPodConfig {
    pub token_id: String,
    pub token: String,
    #[serde(default = "default_line")]
    pub line: String,
    #[serde(default = "default_ttl")]
    pub ttl: u32,
}

fn default_line() -> String {
    "默认".to_string()
}

fn default_ttl() -> u32 {
    600
}

/// 顶层配置文件
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigFile {
    #[serde(default = "default_provider")]
    pub provider: String,
    pub domain: Option<String>,
    #[serde(default = "default_sub_domain")]
    pub sub_domain: String,
    #[serde(default = "default_record_type")]
    pub record_type: String,
    #[serde(default = "default_interval_sec")]
    pub interval_sec: u64,
    pub dnspod: Option<DnsPodConfig>,
    #[serde(default = "default_ip_source_url")]
    pub ip_source_url: String,
}

fn default_provider() -> String {
    "dnspod".to_string()
}

fn default_sub_domain() -> String {
    "@".to_string()
}

fn default_record_type() -> String {
    "A".to_string()
}

fn default_interval_sec() -> u64 {
    60
}

fn default_ip_source_url() -> String {
    "https://t.sc8.fun/api/client-ip".to_string()
}

/// 解析后的运行配置
#[derive(Debug, Clone)]
pub struct Config {
    pub provider: Provider,
    pub domain: String,
    pub sub_domains: Vec<String>,
    pub record_type: String,
    pub interval_sec: u64,
    pub dnspod: Option<DnsPodConfig>,
    pub ip_source_url: String,
}

/// 将 sub_domain 字符串按逗号或分号分隔为子域名列表
pub fn split_sub_domains(input: &str) -> Vec<String> {
    input
        .split(|c: char| c == ',' || c == ';')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// 生成默认配置模板
pub fn generate_template() -> String {
    r#"{
  "provider": "dnspod",
  "domain": "example.com",
  "sub_domain": "www",
  "record_type": "A",
  "interval_sec": 60,
  "dnspod": {
    "token_id": "你的TokenId",
    "token": "你的Token值",
    "line": "默认",
    "ttl": 60
  },
  "ip_source_url": "https://t.sc8.fun/api/client-ip"
}
"#
    .to_string()
}

/// 加载并解析配置文件
pub fn load_config(config_path: &str) -> Result<Config, String> {
    let data = fs::read_to_string(config_path)
        .map_err(|e| format!("读取配置文件失败: {}", e))?;

    let cf: ConfigFile = serde_json::from_str(&data)
        .map_err(|e| format!("解析配置文件失败: {}", e))?;

    let domain = cf.domain.clone().unwrap_or_else(|| "example.com".to_string());

    let provider = match cf.provider.to_lowercase().as_str() {
        "dnspod" => Provider::DnsPod,
        _ => return Err(format!("不支持的 provider: {}", cf.provider)),
    };

    Ok(Config {
        provider,
        domain,
        sub_domains: split_sub_domains(&cf.sub_domain),
        record_type: cf.record_type,
        interval_sec: cf.interval_sec,
        dnspod: cf.dnspod,
        ip_source_url: cf.ip_source_url,
    })
}

/// 检查配置文件是否存在，不存在则生成模板
pub fn ensure_config(config_path: &str) -> Result<bool, String> {
    if !Path::new(config_path).exists() {
        let template = generate_template();
        fs::write(config_path, &template)
            .map_err(|e| format!("写入配置文件模板失败: {}", e))?;
        Ok(false)
    } else {
        Ok(true)
    }
}
