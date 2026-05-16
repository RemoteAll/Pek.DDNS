# Zig.DDNS

[![Zig Version](https://img.shields.io/badge/Zig-0.15.2+-orange.svg)](https://ziglang.org/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

一个用 Zig 语言编写的高性能、可扩展 DDNS（动态域名解析）工具。当前实现了腾讯 DNSPod 的 DDNS 自动更新，后续可扩展支持 Cloudflare、阿里云 DNS、华为云等主流 DNS 服务商。

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
- **本地时区显示**：自动获取系统时区（UTC+8 等），显示本地时间
- **彩色输出支持**：Linux/macOS 支持 ANSI 颜色，Windows 使用纯文本避免字符重复

### 🌍 平台支持

- **Windows**：原生 UTF-8 支持，使用 Windows API 获取时区
- **Linux/macOS**：POSIX 标准接口，完整跨平台兼容
- **内置 HTTP 客户端**：基于 Zig 0.15.2+ 标准库，无外部依赖

### 🛠️ 扩展性

- **模块化架构**：Provider 接口设计，易于添加新 DNS 服务商
- **可组合模块**：logger、json_utils、ddns 核心模块独立可复用

## 快速开始

### 安装要求

- Zig 0.15.2 及以上版本
- Windows/Linux/macOS 任意平台
- 推荐使用 VSCode + [Zig Language](https://marketplace.visualstudio.com/items?itemName=ziglang.vscode-zig) 插件

### 构建项目

#### 开发构建（调试模式）

```bash
zig build
```

#### 生产构建（优化模式）

```bash
# 快速优化（推荐）
zig build -Doptimize=ReleaseFast

# 小体积优化
zig build -Doptimize=ReleaseSmall

# 安全优化（保留运行时检查）
zig build -Doptimize=ReleaseSafe
```

编译后的可执行文件位于 `zig-out/bin/Zig_DDNS.exe`（Windows）或 `zig-out/bin/Zig_DDNS`（Linux/macOS）。

### 配置 DNSPod Token

首次运行会自动生成配置文件模板 `config.json`：

```bash
zig build run
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
# 使用 zig build 运行
zig build run

# 或直接运行编译后的二进制
./zig-out/bin/Zig_DDNS.exe  # Windows
./zig-out/bin/Zig_DDNS      # Linux/macOS
```

程序将每 60 秒（可配置）自动检测公网 IP，如有变化则更新 DNS 解析。

## 配置说明

### 配置文件字段

| 字段 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| `provider` | string | 是 | - | DNS 服务商，当前支持 `dnspod` |
| `domain` | string | 是 | - | 主域名，如 `example.com` |
| `sub_domain` | string | 否 | `@` | 子域名，如 `www`、`blog`，根域名用 `@` |
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
[2025-10-29 20:21:45] DEBUG ip-source encoding gzip_magic=true
[2025-10-29 20:21:45] DEBUG ip-source gunzip: [{"Ip": "113.116.242.207", "Type": "IPv4"}]
[2025-10-29 20:21:45] DEBUG dnspod Record.List - domain=example.com sub_domain=www type=A
[2025-10-29 20:21:46] INFO dnspod: www.example.com 无变化 (ip=113.116.242.207, ttl=60)
```

## 平台兼容性

### Windows

- **UTF-8 支持**：自动设置控制台为 UTF-8 编码（代码页 65001）
- **本地时区**：使用 Windows API `GetTimeZoneInformation` 获取系统时区
- **日志输出**：纯文本模式，避免 ANSI 转义序列导致的字符重复问题
- **按键等待**：配置错误时使用 `ReadFile` 等待用户按键，防止窗口闪退

### Linux/macOS

- **POSIX 标准**：使用 `std.posix` 接口实现跨平台兼容
- **彩色日志**：支持 ANSI 颜色输出（DEBUG=青色，INFO=绿色，WARN=黄色，ERROR=红色）
- **标准输入**：使用 `std.posix.read(STDIN_FILENO)` 读取用户输入

### HTTP 客户端

- **优先内置**：使用 Zig 0.15.2+ 标准库 `std.http.Client`
- **备用方案**：PowerShell（Windows）或 curl（Linux/macOS）
- **TLS 支持**：自动处理 HTTPS 连接

## 高级功能

### TTL 自动同步

程序会自动检测 DNS 记录的 TTL 值，如与配置不一致则自动更新：

```log
[2025-10-29 20:22:10] INFO dnspod: 检测到 TTL 不一致，当前=600 期望=60，正在更新...
[2025-10-29 20:22:11] INFO dnspod: TTL 更新成功 www.example.com (60)
```

### 固定间隔执行

采用时间戳补偿机制，确保严格按照配置的间隔执行，避免累积漂移：

```zig
// 伪代码示例
start_time = nanoTimestamp()
// 执行任务...
elapsed = nanoTimestamp() - start_time
sleep(interval - elapsed)  // 动态调整睡眠时间
```

### 智能错误处理

- **配置错误**：显示详细错误信息，等待用户按键后退出
- **网络异常**：自动重试或使用备用 IP 获取接口
- **API 限流**：建议调整 `interval_sec` 避免频繁调用

## 扩展开发

### 添加新的 DNS 服务商

参考 `src/ddns.zig` 中的 DNSPod 实现：

1. **定义 Provider**

```zig
pub const Provider = enum {
    dnspod,
    cloudflare,  // 新增
    // ...
};
```

2. **实现配置结构**

```zig
pub const CloudflareConfig = struct {
    api_token: []const u8,
    zone_id: []const u8,
};
```

3. **实现更新逻辑**

```zig
fn cloudflare_update(allocator: std.mem.Allocator, config: Config, ip: []const u8) !void {
    // 查询现有记录
    // 比对 IP 和 TTL
    // 调用 Cloudflare API 更新
}
```

4. **接入主流程**

在 `runOnce()` 的 `switch` 中添加分支：

```zig
switch (config.provider) {
    .dnspod => try providers.dnspod_update(allocator, config, ip),
    .cloudflare => try providers.cloudflare_update(allocator, config, ip),
}
```

5. **更新配置解析**

在 `src/main.zig` 中添加 provider 字符串映射：

```zig
if (std.ascii.eqlIgnoreCase(provider_str, "cloudflare")) break :blk Provider.cloudflare;
```

### 代码规范

遵循 [PeiKeSmart Copilot 协作指令](.github/copilot-instructions.md)：

- 禁止删除已有代码注释
- 保留逻辑分隔空行
- 优先可读性，就近声明变量
- 使用 Zig 0.15.2+ 标准 API，避免废弃接口
- 错误处理需明确类型，使用 `error union`
- 提交前运行相关测试，确保编译通过

## 常见问题

### Token 配置错误

**症状**：`ERROR 请在 config.json 中配置真实的 DNSPod API Token`

**解决方案**：

1. 访问 [DNSPod 控制台](https://console.dnspod.cn/account/token/apikey)
2. 创建新的 API Token
3. 将 `ID` 和 `Token` 分别填入配置文件

### 网络连接失败

**症状**：`HttpConnectionClosing` 或超时错误

**可能原因**：

- 防火墙/代理阻止 HTTPS 连接
- TLS 版本不兼容
- DNS 解析失败

**解决方案**：

1. 检查防火墙和代理设置
2. 尝试更换 `ip_source_url` 接口
3. 临时禁用代理或使用 HTTP（不推荐）

### 中文字符重复显示

**症状**：日志输出 "请请求求"（字符重复）

**原因**：PowerShell 进度条输出到 stderr 导致终端渲染异常

**解决方案**：已在代码中修复，使用 `$ProgressPreference='SilentlyContinue'` 禁用进度条

### Zig 版本兼容性

**要求**：Zig 0.15.2 及以上

**常见 API 变动**：

- `std.time.sleep` → `std.Thread.sleep`
- `std.mem.dupe` → `allocator.dupe`
- `std.io.getStdIn()` 不存在，使用 `std.posix.read(STDIN_FILENO)`

## 项目结构

```text
Zig.DDNS/
├── build.zig              # 构建配置
├── build.zig.zon          # 包管理配置
├── config.json            # 运行时配置（首次运行自动生成）
├── README.md              # 项目文档
├── .github/
│   └── copilot-instructions.md  # 开发规范
└── src/
    ├── main.zig           # 程序入口，配置解析
    ├── root.zig           # 模块导出
    ├── ddns.zig           # DDNS 核心逻辑
    ├── logger.zig         # 日志系统
    └── json_utils.zig     # JSON 工具函数
```

## 内置 HTTP 客户端

✅ **已完成集成**：当前实现已成功使用 Zig 0.15.2+ 标准库 `std.http.Client` 发起 HTTP 请求，完全兼容官方 API。

### 实现状态

- ✅ GET 请求（获取公网 IP）：`fetchPublicIPv4` 使用 `req.sendBodiless()` + `response.reader(&.{}).allocRemaining()`
- ✅ POST 请求（DNSPod API）：`httpPostForm` 使用 `req.sendBody()` + `body_writer.writer.writeAll()`
- ✅ 编译通过：完全兼容 Zig 0.15.2+ 官方 HTTP 客户端 API
- ⚠️ 网络环境：部分网络环境可能遇到 TLS 连接问题，建议检查防火墙和代理设置

### API 兼容性

- 基于 Zig 官方标准库实现，确保 API 稳定性
- 支持 HTTPS（TLS）和 HTTP 协议
- 自动处理响应头解析和内容读取
- 内存安全：使用 allocator 管理响应内容生命周期

### 备用方案

如遇网络连接问题，可临时启用外部命令模式：

- Windows：PowerShell `Invoke-RestMethod`
- Linux/macOS：`curl` 命令

推荐优先使用内置 HTTP 客户端，提升跨平台兼容性与安全性。

## 参考链接

- **官方文档**
  - [DNSPod API 文档](https://docs.dnspod.cn/api/)
  - [Zig 官方文档](https://ziglang.org/documentation/)
  - [Zig 0.15.2 Release Notes](https://ziglang.org/download/0.15.2/release-notes.html)

- **同类项目**
  - [NewFuture/DDNS](https://github.com/NewFuture/DDNS)（Python，功能最全）
  - [jeessy2/ddns-go](https://github.com/jeessy2/ddns-go)（Go，Web 界面）
  - [TimothyYe/godns](https://github.com/TimothyYe/godns)（Go，多平台）

- **PeiKeSmart 生态**
  - [PeiKeSmart 组织主页](https://github.com/PeiKeSmart)
  - [开发规范](.github/copilot-instructions.md)

## 贡献指南

欢迎提交 Issue 和 Pull Request！

### 开发流程

1. Fork 本仓库
2. 创建功能分支（`git checkout -b feature/AmazingFeature`）
3. 提交改动（`git commit -m 'feat(provider): 添加 Cloudflare 支持'`）
4. 推送到分支（`git push origin feature/AmazingFeature`）
5. 提交 Pull Request

### 提交规范

遵循 [Conventional Commits](https://www.conventionalcommits.org/)：

```text
类型(范围): 简短描述

详细说明（可选）

影响范围:
- [x] 公共 API 变更
- [ ] 性能影响
- [ ] 兼容性变更

测试情况:
- [x] 单元测试已通过
- [x] 编译测试通过
```

**类型**：`feat`（新功能）、`fix`（修复）、`docs`（文档）、`refactor`（重构）、`test`（测试）、`chore`（构建/工具）

## 许可证

本项目采用 [MIT 许可证](LICENSE)。

---

**Made with ❤️ by [PeiKeSmart](https://github.com/PeiKeSmart) | Powered by Zig 🦎**
