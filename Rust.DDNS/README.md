# Rust.DDNS

[![Rust Version](https://img.shields.io/badge/Rust-2021+-orange.svg)](https://www.rust-lang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

一个用 Rust 语言编写的高性能、可扩展 DDNS（动态域名解析）工具。当前实现了腾讯 DNSPod 的 DDNS 自动更新，后续可扩展支持 Cloudflare、阿里云 DNS、华为云等主流 DNS 服务商。

> 本工程是 [Zig.DDNS](../Zig.DDNS) 的 Rust 重写版，功能完全一致，解决 Zig 在 Windows 下的兼容性限制。

## 主要特性

### 🚀 核心功能

- **自动更新 DNS 解析**：自动检测公网 IP 变化并更新 DNS 记录
- **智能 TTL 管理**：自动检测并同步 DNS 记录 TTL 值
- **定时轮询机制**：支持固定间隔执行（精确到秒级），避免时间漂移
- **自动创建记录**：DNS 记录不存在时自动创建
- **IPv4/IPv6 支持**：当前支持 A 记录，可扩展 AAAA 记录

### ⚙️ 配置与部署

- **JSON 配置文件**：简洁的配置方式，首次运行自动生成模板
- **友好错误提示**：配置错误时显示详细信息并等待按键，避免窗口闪退
- **跨平台兼容**：Windows / Linux / macOS 自动适配

### 📝 日志系统

- **结构化日志输出**：支持 DEBUG/INFO/WARN/ERROR 四级日志
- **本地时区显示**：自动显示本地时间
- **彩色输出支持**：支持 ANSI 颜色输出

### 🌍 平台支持

- **Windows**：原生 UTF-8 支持，使用 Windows API 获取控制台编码
- **Linux/macOS**：POSIX 标准接口，完整跨平台兼容
- **内置 HTTP 客户端**：基于 ureq 库，轻量无外部运行时依赖

### 🛠️ 扩展性

- **模块化架构**：Provider 接口设计，易于添加新 DNS 服务商
- **可组合模块**：logger、config、ddns、dnspod 核心模块独立可复用

## 快速开始

### 安装要求

- Rust 2021 edition 及以上版本
- Windows/Linux/macOS 任意平台

### 构建项目

#### 开发构建（调试模式）

```bash
cargo build
```

#### 生产构建（优化模式）

```bash
# 快速优化（推荐）
cargo build --release
```

编译后的可执行文件位于 `target/release/Rust_DDNS.exe`（Windows）或 `target/release/Rust_DDNS`（Linux/macOS）。

### 配置 DNSPod Token

首次运行会自动生成配置文件模板 `config.json`：

```bash
cargo run
```

打开 `config.json`，填写你的 DNSPod API Token：

```json
{
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
```

#### 获取 DNSPod Token

1. 访问 [DNSPod API Token 管理](https://console.dnspod.cn/account/token/apikey)
2. 点击 "创建密钥" 生成新的 API Token
3. 将 `ID` 填入 `token_id`，`Token` 填入 `token` 字段

### 运行程序

配置完成后直接运行：

```bash
# 使用 cargo run 运行
cargo run

# 或直接运行编译后的二进制
./target/release/Rust_DDNS.exe  # Windows
./target/release/Rust_DDNS      # Linux/macOS
```

程序将每 60 秒（可配置）自动检测公网 IP，如有变化则更新 DNS 解析。

## 配置说明

### 配置文件字段

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `provider` | string | 是 | - | DNS 服务商，当前支持 `dnspod` |
| `domain` | string | 是 | - | 主域名，如 `example.com` |
| `sub_domain` | string | 否 | `@` | 子域名，如 `www`、`blog`，根域名用 `@`，支持逗号/分号分隔多个 |
| `record_type` | string | 否 | `A` | 记录类型，当前支持 `A`（IPv4） |
| `interval_sec` | number | 否 | 60 | 检测间隔（秒），推荐 60-300 |
| `dnspod.token_id` | string | 是 | - | DNSPod API Token ID |
| `dnspod.token` | string | 是 | - | DNSPod API Token 密钥 |
| `dnspod.line` | string | 否 | `默认` | 解析线路，如 `默认`、`电信`、`联通` 等 |
| `dnspod.ttl` | number | 否 | 600 | DNS TTL（秒），推荐 60-600 |
| `ip_source_url` | string | 否 | - | 公网 IP 获取接口 URL |

### 配置示例

#### 基础配置（每 5 分钟更新）

```json
{
  "provider": "dnspod",
  "domain": "example.com",
  "sub_domain": "home",
  "record_type": "A",
  "interval_sec": 300,
  "dnspod": {
    "token_id": "123456",
    "token": "abcdef1234567890",
    "line": "默认",
    "ttl": 600
  },
  "ip_source_url": "https://api.ipify.org"
}
```

#### 快速更新配置（每分钟检测）

```json
{
  "provider": "dnspod",
  "domain": "mydomain.com",
  "sub_domain": "ddns",
  "interval_sec": 60,
  "dnspod": {
    "token_id": "592175",
    "token": "your_token_here",
    "ttl": 60
  }
}
```

### IP 获取接口

支持自定义公网 IP 获取接口，推荐以下服务：

- `https://api.ipify.org`（国际）
- `https://api64.ipify.org`（国际 IPv4+IPv6）
- `https://ipinfo.io/ip`（国际）
- `https://myip.ipip.net`（国内）
- `https://ddns.oray.com/checkip`（国内）
- `https://t.sc8.fun/api/client-ip`（支持 gzip，返回详细信息）

## 日志输出

### 日志级别

- **DEBUG**：详细调试信息（API 请求、响应内容等）
- **INFO**：正常运行信息（IP 检测、DNS 更新成功等）
- **WARN**：警告信息（配置提示、降级处理等）
- **ERROR**：错误信息（API 失败、网络异常等）

### 日志示例

```log
[2025-10-29 20:21:45] DEBUG ip-source raw: [{"Ip": "113.116.242.207", "Type": "IPv4"}]
[2025-10-29 20:21:45] DEBUG dnspod Record.List - domain=example.com sub_domain=www type=A
[2025-10-29 20:21:46] INFO dnspod: www.example.com 无变化 (ip=113.116.242.207, ttl=60)
```

## 项目结构

```
Rust.DDNS/
├── Cargo.toml           # 项目配置与依赖
├── config.example.json  # 配置模板
├── config.json          # 运行时配置（自动生成）
├── README.md            # 本文件
├── LICENSE              # MIT 许可证
└── src/
    ├── main.rs          # 程序入口 - 配置加载、Windows UTF-8 支持
    ├── config.rs        # 配置模块 - 配置文件解析与验证
    ├── ddns.rs          # 核心逻辑 - IP 获取、DNS 更新循环
    ├── dnspod.rs        # DNSPod API 客户端 - Record.List/Create/Modify
    └── logger.rs        # 日志模块 - 彩色结构化日志输出
```

## 与 Zig 版本的差异

| 特性 | Zig.DDNS | Rust.DDNS |
|------|----------|-----------|
| 语言 | Zig 0.15.2+ | Rust 2021+ |
| HTTP 客户端 | 标准库 std.http.Client | ureq 2.x |
| JSON 解析 | 手写轻量解析器 | serde_json |
| gzip 支持 | 手写解压 | ureq 内置 |
| 构建 | zig build | cargo build |
| Windows 兼容 | ⚠️ 部分限制 | ✅ 完善 |

## 许可证

[MIT](LICENSE)
