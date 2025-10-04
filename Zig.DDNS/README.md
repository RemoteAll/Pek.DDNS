# Zig.DDNS

一个用 Zig 编写的可扩展 DDNS 工具。当前实现了腾讯 DNSPod 的 DDNS 更新，后续可扩展到更多平台（Cloudflare、阿里云、Route53 等）。

## 功能

- 获取公网 IPv4 地址（Windows 使用 PowerShell，其他平台使用 curl）
- DNSPod 记录查询、创建与更新
- 可单次执行或按间隔循环执行
- 模块化 provider 接口，方便扩展

## 构建与运行

### 构建

```pwsh
zig build
```

### 运行（单次执行）

设置环境变量，然后运行：

```pwsh
$env:DDNS_PROVIDER="dnspod"
$env:DDNS_DOMAIN="example.com"
$env:DDNS_SUB="home"
$env:DDNS_TOKEN_ID="12345"
$env:DDNS_TOKEN="token_value"
$env:DDNS_INTERVAL="0" # 0 表示只执行一次
zig build run
```

### 运行（循环执行）

```pwsh
$env:DDNS_INTERVAL="300" # 每 300 秒轮询一次
zig build run
```

## 平台差异

- Windows：通过 PowerShell 的 `Invoke-RestMethod` 和 `Invoke-WebRequest` 发起 HTTP 请求。
- Linux/macOS：通过 `curl` 发起 HTTP 请求，请确保系统安装了 `curl`。

## 扩展 Provider

参考 `src/ddns.zig` 中的 `Provider` 枚举与 `providers` 命名空间：

1. 在枚举中新增平台类型。
2. 实现对应的 `*_update` 函数，封装查询/创建/更新逻辑。
3. 在 `runOnce` 的 `switch` 中接入新的分支。
4. 在 `src/main.zig` 中为新平台映射 `DDNS_PROVIDER` 字符串。

## 注意事项

- 当前解析 JSON 采用极简的字符串查找以减少依赖，建议后续替换为健壮的 JSON 解析。
- 生产环境建议内置 HTTP 客户端或引入第三方库，避免依赖外部命令。
- 仅支持 IPv4（A 记录）；如需支持 IPv6（AAAA），可增加 `record_type="AAAA"` 及 IP 获取来源。

## 内置 HTTP 客户端

✅ **已完成集成**：当前实现已成功使用 Zig 0.15.1+ 标准库 `std.http.Client` 发起 HTTP 请求，完全兼容官方 API。

### 实现状态

- ✅ GET 请求（获取公网 IP）：`fetchPublicIPv4` 使用 `req.sendBodiless()` + `response.reader(&.{}).allocRemaining()`
- ✅ POST 请求（DNSPod API）：`httpPostForm` 使用 `req.sendBody()` + `body_writer.writer.writeAll()`
- ✅ 编译通过：完全兼容 Zig 0.15.1+ 官方 HTTP 客户端 API
- ⚠️ 网络环境：部分网络环境可能遇到 TLS 连接问题，建议检查防火墙和代理设置

### API 兼容性

- 基于 Zig 官方 test.zig 示例实现，确保 API 稳定性
- 支持 HTTPS（TLS）和 HTTP 协议
- 自动处理响应头解析和内容读取
- 内存安全：使用 allocator 管理响应内容生命周期

### 备用方案

如遇网络连接问题，可临时启用外部命令模式：

- Windows：PowerShell `Invoke-RestMethod`
- Linux/macOS：`curl` 命令

推荐优先使用内置 HTTP 客户端，提升跨平台兼容性与安全性。

## 许可证

MIT
