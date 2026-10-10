# tools/continuity — 接续基建（自检 + 记忆同步）

> 打开本项目时自动确保本机装有最新的「用户级接续协议」指令；并提供工作记忆回灌工具（sync-memory.ps1）。幂等、可安全反复运行。

## 组成

| 文件 | 作用 |
|---|---|
| `install-global-instruction.ps1` | 幂等安装/更新用户级指令到本机 VS Code（缺失→安装、过旧→更新、一致→不动；带版本守卫，旧副本不会覆盖新版本） |
| `sync-memory.ps1` | 把本机 Copilot 工作记忆（workspaceStorage 中的 repo 记忆）复制到项目 `docs/项目记忆.md`（自动按项目路径定位，任意电脑通用；`docs/` 随仓库走） |
| `templates/用户级指令.instructions.md` | 指令模板（多仓库副本同步维护；内容更新时递增文件末尾的「版本：」行） |
| `.vscode/tasks.json` | VS Code 打开项目时静默执行上述脚本（首次需点「允许自动任务」；仅 Windows 的 PowerShell 环境生效） |

## 手动运行

```powershell
powershell -ExecutionPolicy Bypass -File tools/continuity/install-global-instruction.ps1
powershell -ExecutionPolicy Bypass -File tools/continuity/sync-memory.ps1 -ProjectPath .
```

## 说明

- 属于「接续基建」体系：把个人工作偏好与跨项目接续协议以 VS Code 用户级指令形式就位于任意开发机；
- 本项目与其他已装备仓库互为自愈锚点——任一台新电脑打开任一锚点仓库，即自动补齐/更新本机用户级指令；
- 模板变更时需同步所有已装备仓库的副本；`sync-memory.ps1` 各已装备仓库保持逐字节一致。
