# Rust.DDNS 部署说明（Linux，星尘托管）

> 程序为常驻服务（按 `config.json` 的 `interval_sec` 轮询更新解析，默认 60 秒）；
> 推荐由**星尘（Pek.RAgent）**托管：守护拉起、面板可视化管理、覆盖程序文件即自动重启升级。

## 一、一键安装（推荐）

```bash
# 在解压目录内执行（目录内含 Rust_DDNS、install.sh、config.example.json）
sudo sh install.sh                # 就地安装并注册进星尘
# 或指定目录：sudo sh install.sh /opt/rust-ddns

# 填写配置（首次会自动放置 config.example.json 模板；脚本检测到占位配置时暂不启动）
vi /opt/rust-ddns/config.json     # domain / DNSPod Token 等

# 启动（路径按本机星尘实际安装位置；星尘运行中也可直接在其面板「子服务」页启动）
/www/Agent/pek-ragent -StartService Rust_DDNS
```

## 二、脚本做了什么

1. **文件就位**：复制 `Rust_DDNS` 到目标目录并补执行位；无 `config.json` 时放置 `config.example.json` 模板；
2. **探测星尘并停旧实例**：`--agent-exe` → systemd 单元（`StarAgentRust`/`StarAgent`）→ 运行中进程（`pek-ragent`）→ 常见安装路径；
3. **注册子服务 `Rust_DDNS`**：`-AddService <名称> <程序> <目录>`（注册即启用；星尘运行中则立即重载并拉起）；
4. **配置就绪检查**：`config.json` 缺失或仍是占位值（`example.com` / `你的TokenId`）→ **暂不启动**，避免星尘对无效配置反复拉起；填好后一键启动。

> 探测不到星尘或 C# 版星尘：脚本会打印星尘面板手动注册指引（名称 `Rust_DDNS` / 程序 `{目录}/Rust_DDNS` / 工作目录 `{目录}`）。

## 三、托管与升级

- **升级**：直接覆盖目标目录中的 `Rust_DDNS` 文件——星尘监视到变动后自动重启（约 5~10 秒）；也可在面板「子服务」页点「重启」；
- **修改配置**：改完 `config.json` 后在面板重启该子服务即可（无需重跑本脚本）；
- **运行状态**：星尘面板「子服务」页查看（启停/重启/资源占用）；程序日志输出到标准输出，随星尘日志捕获。

## 四、无星尘环境（自行 systemd）

```bash
sudo sh install.sh --no-agent     # 只部署文件，不注册
```

```ini
# /etc/systemd/system/rust-ddns.service
[Unit]
Description=Rust.DDNS (DDNS updater)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/rust-ddns
ExecStart=/opt/rust-ddns/Rust_DDNS
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## 五、注销

```bash
sudo sh install.sh --unregister   # 停止并移除星尘条目；保留文件与配置
```

## 六、一键打包（仓库已内置）

```powershell
# Windows 主机执行：产出 dist\（Linux 包内已含本 install.sh + 配置模板 + 本说明）
powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1
```

产物（`dist\`，附 `SHA256SUMS.txt`）：

| 产物 | 内容 |
|---|---|
| `Rust_DDNS-v{v}-x86_64-unknown-linux-musl.tar.gz` | `Rust_DDNS`（0755）+ `install.sh` + `config.example.json` + 本说明 |
| `Rust_DDNS-v{v}-x86_64-pc-windows-msvc.zip` | `Rust_DDNS.exe` + `config.example.json` |

目标机解压后 `sudo sh install.sh` 一步完成部署与托管注册；Linux 交叉构建前置（cargo-zigbuild、rustup musl 目标、zig）由脚本自动补齐。

> 安全规则：同一版本号重复打包且内容有变化会被版本守卫拒绝（需 `-Bump` 递升版本号或 `-Force` 放行；守卫脚本取自 DH.RustBase `tools/version-guard.ps1`，未找到时仅告警）。

> 注意：`install.sh` 必须以 **LF 行尾**随包发布（本仓库已配 `.gitattributes` 固定 `*.sh` 为 LF，避免 Windows 检出为 CRLF 导致 Linux 上无法执行）。
