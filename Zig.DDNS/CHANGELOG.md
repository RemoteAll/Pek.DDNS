# 更新日志

本文档记录 Zig.DDNS 项目的重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增功能

- JSON 配置文件支持，首次运行自动生成模板
- 结构化日志系统（DEBUG/INFO/WARN/ERROR 四级日志）
- 本地时区显示（自动获取系统时区偏移）
- 智能 TTL 管理（自动检测并同步 DNS 记录 TTL）
- 固定间隔执行机制（避免时间累积漂移）
- 跨平台按键等待功能（配置错误时友好提示）
- 内置 HTTP 客户端（基于 Zig 0.15.2+ 标准库）

### 改进优化

- Windows 控制台 UTF-8 支持
- PowerShell 进度条静默处理（避免字符重复）
- 跨平台日志输出（Windows 纯文本，Linux/macOS 彩色）
- 错误处理优化（友好提示，等待用户按键）

### 技术栈

- Zig 0.15.2+
- 标准库 `std.http.Client`（HTTPS 支持）
- Windows API（时区、控制台、按键）
- POSIX 接口（Linux/macOS 兼容）

### 已知问题

- 仅支持 IPv4（A 记录），IPv6 支持待实现
- 部分网络环境可能遇到 TLS 连接问题
- 暂仅支持 DNSPod，其他 DNS 服务商待扩展

## [0.1.0] - 初始版本

### 初始实现

- DNSPod DDNS 基础功能
- 公网 IPv4 地址自动获取
- DNS 记录查询、创建、更新
- 环境变量配置支持
- 定时轮询机制
- 模块化 Provider 架构

---

[Unreleased]: https://github.com/PeiKeSmart/Zig.DDNS/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/PeiKeSmart/Zig.DDNS/releases/tag/v0.1.0
