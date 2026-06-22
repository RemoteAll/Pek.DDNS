use crate::config::*;
use crate::dnspod;
use crate::{debug, error, info, warn};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;
use std::sync::OnceLock;
use std::time::Duration;

// ========================== 运行时统计 ==========================

struct RuntimeStats {
    cycle_count: AtomicU64,
    success_count: AtomicU64,
    error_count: AtomicU64,
    consecutive_errors: AtomicU32,
    last_success_time: Mutex<i64>,
}

fn runtime_stats() -> &'static RuntimeStats {
    static STATS: OnceLock<RuntimeStats> = OnceLock::new();
    STATS.get_or_init(|| RuntimeStats {
        cycle_count: AtomicU64::new(0),
        success_count: AtomicU64::new(0),
        error_count: AtomicU64::new(0),
        consecutive_errors: AtomicU32::new(0),
        last_success_time: Mutex::new(0),
    })
}

// ========================== 常量 ==========================

/// 网络操作超时时间（秒）
const NETWORK_TIMEOUT_SEC: u64 = 5;

/// 心跳输出间隔（秒）
const HEARTBEAT_INTERVAL: i64 = 300;

// ========================== 公网 IP 获取 ==========================

/// 获取公网 IPv4 地址
pub fn fetch_public_ipv4(url: &str, timeout_sec: u64) -> Result<String, String> {
    // POST form data to the URL
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(timeout_sec))
        .timeout_read(Duration::from_secs(timeout_sec))
        .timeout_write(Duration::from_secs(timeout_sec))
        .user_agent("Zig-DDNS/1.0")
        .build();

    debug!("POST {} (form: from=hlktech-nuget)", url);

    let resp = agent
        .post(url)
        .set("Content-Type", "application/x-www-form-urlencoded")
        .send_string("from=hlktech-nuget")
        .map_err(|e| {
            let reason = match &e {
                ureq::Error::Status(code, _) => format!("HTTP {}", code),
                ureq::Error::Transport(t) => format!("网络错误: {}", t),
            };
            format!("IP 请求失败: {}", reason)
        })?;

    let body = resp
        .into_string()
        .map_err(|e| format!("读取 IP 响应失败: {}", e))?;

    debug!("ip-source raw: {}", body);

    // 解析 JSON: 期望根数组 [{"Type":"IPv4","Ip":"..."}]
    let json: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("JSON 解析失败: {}", e))?;

    let arr = match &json {
        serde_json::Value::Array(a) => a,
        // 也可能是 {"Data": [...]} 形式
        serde_json::Value::Object(o) => {
            if let Some(data) = o.get("Data") {
                if let Some(a) = data.as_array() {
                    a
                } else {
                    return Err("Data 字段不是数组".to_string());
                }
            } else {
                return Err("JSON 既不是根数组也没有 Data 字段".to_string());
            }
        }
        _ => return Err("JSON 格式不符".to_string()),
    };

    for item in arr {
        if let Some(obj) = item.as_object() {
            let typ = obj
                .get("Type")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if typ == "IPv4" {
                if let Some(ip) = obj.get("Ip").and_then(|v| v.as_str()) {
                    info!("获取到公网 IPv4: {}", ip);
                    return Ok(ip.to_string());
                }
            }
        }
    }

    Err("未找到 IPv4 地址".to_string())
}

// ========================== 单次 DDNS 更新 ==========================

/// 执行单次 DDNS 更新
pub fn run_once(config: &Config) -> Result<(), String> {
    info!("→ runOnce: 开始执行 (超时: {}秒)", NETWORK_TIMEOUT_SEC);

    let ip = fetch_public_ipv4(&config.ip_source_url, NETWORK_TIMEOUT_SEC)?;

    info!("→ runOnce: 开始更新 DNS 记录 (provider=dnspod)");

    match config.provider {
        Provider::DnsPod => dnspod_update(config, &ip)?,
    }

    info!("✓ runOnce: DNS 更新完成");
    Ok(())
}

/// DNSPod 更新逻辑：遍历所有子域名，逐一检查并更新
fn dnspod_update(config: &Config, ip: &str) -> Result<(), String> {
    let dp = config
        .dnspod
        .as_ref()
        .ok_or("MissingProviderConfig: 缺少 DNSPod 配置")?;

    // 验证配置是否为默认占位符
    if dp.token_id.contains("TokenId") || dp.token.contains("Token") {
        error!("请在 config.json 中配置真实的 DNSPod API Token");
        warn!(
            "token_id 和 token 当前仍为占位符，请访问 https://console.dnspod.cn/account/token/apikey 获取"
        );
        return Err("InvalidConfiguration".to_string());
    }

    let mut had_error = false;
    let total = config.sub_domains.len();

    for (i, sub_domain) in config.sub_domains.iter().enumerate() {
        if total > 1 {
            info!(
                "dnspod: 处理子域名 [{}/{}]: {}.{}",
                i + 1,
                total,
                sub_domain,
                config.domain
            );
        }

        if let Err(e) = dnspod_update_single(dp, &config.domain, sub_domain, config, ip) {
            error!(
                "dnspod: 更新 {}.{} 失败 - {}",
                sub_domain, config.domain, e
            );
            had_error = true;
        }
    }

    if had_error {
        Err("PartialUpdateFailure: 部分子域名更新失败".to_string())
    } else {
        Ok(())
    }
}

/// 单个子域名的 DNS 记录更新：查找 → 创建/修改
fn dnspod_update_single(
    dp: &DnsPodConfig,
    domain: &str,
    sub_domain: &str,
    config: &Config,
    ip: &str,
) -> Result<(), String> {
    let record = dnspod::find_record(dp, domain, sub_domain, &config.record_type, ip, NETWORK_TIMEOUT_SEC)?;

    match record {
        None => {
            info!(
                "dnspod: 未找到现有记录，将创建 {}.{} -> {} (TTL={})",
                sub_domain, domain, ip, dp.ttl
            );
            dnspod::create_record(dp, domain, sub_domain, &config.record_type, ip, config, NETWORK_TIMEOUT_SEC)?;
            info!(
                "dnspod: 已创建记录 {}.{} -> {} (TTL={})",
                sub_domain, domain, ip, dp.ttl
            );
        }
        Some(r) => {
            let ip_changed = r.value != ip;
            let ttl_changed = r.ttl != dp.ttl;
            let need_update = ip_changed || ttl_changed;

            if need_update {
                if ip_changed && ttl_changed {
                    info!(
                        "dnspod: 检测到变化 - IP:{}->{}, TTL:{}->{} → 将更新",
                        r.value, ip, r.ttl, dp.ttl
                    );
                } else if ip_changed {
                    info!(
                        "dnspod: 检测到 IP 变化 - {} -> {} → 将更新",
                        r.value, ip
                    );
                } else {
                    info!(
                        "dnspod: 检测到 TTL 变化 - {} -> {} → 将更新",
                        r.ttl, dp.ttl
                    );
                }
                dnspod::modify_record(
                    dp, &r.id, domain, sub_domain, &config.record_type, ip, config,
                    NETWORK_TIMEOUT_SEC,
                )?;
                info!(
                    "dnspod: 已更新记录 {}.{} -> {} (TTL={})",
                    sub_domain, domain, ip, dp.ttl
                );
            } else {
                info!(
                    "dnspod: {}.{} 无变化 (ip={}, ttl={})",
                    sub_domain, domain, ip, r.ttl
                );
            }
        }
    }

    Ok(())
}

// ========================== 主循环 ==========================

/// 运行 DDNS 主循环
pub fn run(config: &Config) -> Result<(), String> {
    info!("🚀 程序启动 - 更新周期: {}秒", config.interval_sec);

    {
        let now = chrono::Local::now().timestamp();
        let mut last_success = runtime_stats().last_success_time.lock().unwrap();
        *last_success = now;
    }

    if config.interval_sec == 0 {
        return run_once(config);
    }

    let mut last_heartbeat: i64 = chrono::Local::now().timestamp();

    loop {
        let cycle_num = runtime_stats().cycle_count.fetch_add(1, Ordering::Relaxed) + 1;

        // 定期输出心跳日志
        let now = chrono::Local::now().timestamp();
        if (now - last_heartbeat) >= HEARTBEAT_INTERVAL {
            let success = runtime_stats().success_count.load(Ordering::Relaxed);
            let errors = runtime_stats().error_count.load(Ordering::Relaxed);
            let consecutive = runtime_stats().consecutive_errors.load(Ordering::Relaxed);
            let last_success = {
                let ls = runtime_stats().last_success_time.lock().unwrap();
                *ls
            };
            info!(
                "💓 心跳 #({}) - 成功:{} 错误:{} 连续错误:{} 距上次成功:{}秒",
                cycle_num,
                success,
                errors,
                consecutive,
                now - last_success
            );
            last_heartbeat = now;
        }

        debug!("===== 周期 #{} =====", cycle_num);
        let start_time = std::time::Instant::now();

        // 捕获单次执行的错误，记录日志但不退出循环
        match run_once(config) {
            Ok(_) => {
                runtime_stats().success_count.fetch_add(1, Ordering::Relaxed);
                runtime_stats().consecutive_errors.store(0, Ordering::Relaxed);
                {
                    let mut ls = runtime_stats().last_success_time.lock().unwrap();
                    *ls = chrono::Local::now().timestamp();
                }
                debug!("✓ 更新成功");
            }
            Err(e) => {
                let consecutive = runtime_stats().consecutive_errors.fetch_add(1, Ordering::Relaxed) + 1;
                runtime_stats().error_count.fetch_add(1, Ordering::Relaxed);

                error!("执行失败: {} (连续错误:{})", e, consecutive);
                info!("将在下一个周期重试...");
            }
        }

        // 计算执行耗时并动态调整睡眠时间
        let elapsed = start_time.elapsed();
        let interval_dur = Duration::from_secs(config.interval_sec);

        if elapsed < interval_dur {
            let sleep_dur = interval_dur - elapsed;
            debug!(
                "周期睡眠: {}秒 (执行耗时: {}ms)",
                sleep_dur.as_secs(),
                elapsed.as_millis()
            );
            std::thread::sleep(sleep_dur);
        } else {
            warn!(
                "执行耗时 {}ms 超过配置周期 {}秒，立即开始下一轮",
                elapsed.as_millis(),
                config.interval_sec
            );
        }
    }
}
