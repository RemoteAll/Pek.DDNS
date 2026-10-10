#Requires -Version 5.1
<#
=============================================================================
Rust.DDNS Windows 一键安装（文件就位 + 安装到本机星尘）
-----------------------------------------------------------------------------
把 Rust.DDNS 部署到本机并以星尘（Pek.RAgent / C# StarAgent）子服务方式托管：
  文件就位 → 停止旧实例 → 注册子服务（-AddService，注册即启用）→ 配置就绪检查。
  config.json 未就绪（缺失或仍是模板占位）时：自动放置配置模板并「暂不启动」，
  填好后一键启动，避免星尘对无效配置反复拉起。

参考实现：deploy/install.sh（Linux 版）、DHDeploy.Agent.Rust/deploy/install.sh

用法（在解压目录内执行）：
  powershell -ExecutionPolicy Bypass -File install.ps1                    就地安装 + 注册进星尘
  powershell -ExecutionPolicy Bypass -File install.ps1 -Dir D:\rust-ddns  安装到指定目录
  powershell -ExecutionPolicy Bypass -File install.ps1 -NoAgent           只部署文件，不注册
  powershell -ExecutionPolicy Bypass -File install.ps1 -AgentExe <星尘exe路径>
  powershell -ExecutionPolicy Bypass -File install.ps1 -Unregister        从星尘注销
  powershell -ExecutionPolicy Bypass -File install.ps1 -Name Rust_DDNS_B  多实例：注册为不同子服务名（默认 Rust_DDNS）

说明：
  - 本程序为常驻服务（按 config.json 的 interval_sec 轮询，默认 60 秒）；
  - 升级＝直接覆盖 Rust_DDNS.exe——星尘监视到变动后自动重启（约 5~10 秒）；
  - 星尘探测顺序：-AgentExe → Windows 服务（StarAgentRust/StarAgent）→ 运行中
    进程（pek-ragent）→ PATH → 常见安装路径；C# 版星尘无 -AddService，按提示在面板注册。
=============================================================================
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Dir,
    [string]$AgentExe,
    [string]$Name = 'Rust_DDNS',
    [switch]$NoAgent,
    [switch]$Unregister,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$SelfDir = Split-Path -Parent $PSCommandPath
$BinName = 'Rust_DDNS'
$ServiceName = $Name

if ($Help) {
    Write-Host '用法：'
    Write-Host '  powershell -ExecutionPolicy Bypass -File install.ps1                    就地安装 + 注册进星尘'
    Write-Host '  powershell -ExecutionPolicy Bypass -File install.ps1 -Dir D:\rust-ddns  安装到指定目录'
    Write-Host '  powershell -ExecutionPolicy Bypass -File install.ps1 -NoAgent           只部署文件，不注册'
    Write-Host '  powershell -ExecutionPolicy Bypass -File install.ps1 -AgentExe <星尘exe路径>'
    Write-Host '  powershell -ExecutionPolicy Bypass -File install.ps1 -Unregister        从星尘注销'
    Write-Host '  powershell -ExecutionPolicy Bypass -File install.ps1 -Name Rust_DDNS_B  多实例：注册为不同子服务名（默认 Rust_DDNS）'
    Write-Host '  -Help                                                                   显示帮助'
    exit 0
}

# ---- 星尘程序探测 ----
function Find-AgentExe {
    if ($AgentExe) {
        if (Test-Path -LiteralPath $AgentExe) { return (Resolve-Path -LiteralPath $AgentExe).Path }
        Write-Warning "指定的星尘程序不存在：$AgentExe"
    }
    # Windows 服务（StarAgentRust = Rust 版；StarAgent = C# 版/旧名）
    foreach ($name in @('StarAgentRust', 'StarAgent', 'staragent')) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
        if ($svc -and $svc.PathName) {
            $p = $svc.PathName
            if ($p -match '^\s*"([^"]+)"') { $p = $Matches[1] }
            elseif ($p -match '^\s*([^\s]+\.exe)') { $p = $Matches[1] }
            if ($p -and (Test-Path -LiteralPath $p)) { return $p }
        }
    }
    # 运行中进程
    $proc = Get-Process 'pek-ragent' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path -and (Test-Path -LiteralPath $proc.Path)) { return $proc.Path }
    # PATH
    $cmd = Get-Command 'pek-ragent.exe' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
    # 常见安装路径
    $cands = @()
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'StarAgent\pek-ragent.exe') }
    if (${env:ProgramFiles(x86)}) { $cands += (Join-Path ${env:ProgramFiles(x86)} 'StarAgent\pek-ragent.exe') }
    if ($env:ProgramData) { $cands += (Join-Path $env:ProgramData 'StarAgent\pek-ragent.exe') }
    $cands += 'C:\StarAgent\pek-ragent.exe'
    foreach ($p in $cands) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

# ---- 注销模式 ----
if ($Unregister) {
    Write-Host "注销子服务 [$ServiceName]（保留文件与配置）…"
    $star = Find-AgentExe
    if ($star) {
        & $star -StopService $ServiceName *> $null
    } else {
        Write-Host '  （未探测到星尘程序：跳过停止；继续尝试移除条目）'
    }
    $removed = $false
    foreach ($port in @(5501, 5500)) {
        try {
            $resp = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/star/removeService" `
                -ContentType 'application/json' -Body ('{"serviceName":"' + $ServiceName + '"}') -TimeoutSec 15
            Write-Host ($resp | ConvertTo-Json -Compress -Depth 4)
            $removed = $true
            break
        } catch { }
    }
    if ($removed) {
        Write-Host '完成：已请求星尘移除条目（可在面板「子服务」页确认）。'
    } else {
        Write-Host "未完成自动移除（星尘未运行或接口不可达）。请在星尘面板「子服务」页删除 [$ServiceName]，"
        Write-Host '或编辑星尘配置 Config/StarAgent.config 移除对应条目。'
    }
    exit 0
}

# ---- [1/4] 文件就位 ----
if (-not $Dir) { $Dir = $SelfDir }
$src = Join-Path $SelfDir "$BinName.exe"
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "错误：未找到 $src（请在含 $BinName.exe 的目录内运行本脚本）"
    exit 1
}
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$target = (Resolve-Path -LiteralPath $Dir).Path
$dst = Join-Path $target "$BinName.exe"
if ($src -ne $dst) { Copy-Item -LiteralPath $src -Destination $dst -Force }
Write-Host "[1/4] 文件就位：$dst"

$config = Join-Path $target 'config.json'
$example = Join-Path $SelfDir 'config.example.json'
if (-not (Test-Path -LiteralPath $config) -and (Test-Path -LiteralPath $example)) {
    Copy-Item -LiteralPath $example -Destination $config
    Write-Host "      已放置配置模板：$config（请填写域名与 DNSPod Token 等）"
}

# ---- [2/4~3/4] 星尘探测与注册 ----
$ready = $false
$registered = $false
$starExe = $null
if (-not $NoAgent) {
    $starExe = Find-AgentExe
    if (-not $starExe) {
        Write-Host '[2/4] 未探测到星尘（Pek.RAgent / StarAgent）'
        Write-Host '[3/4] 跳过注册：如本机装有星尘，可用 -AgentExe <路径> 指定后重跑；'
        Write-Host "      或在星尘面板手动注册：名称 $ServiceName，程序 $dst，目录 $target"
    } elseif ($starExe -match 'pek-ragent') {
        Write-Host "[2/4] 检测到星尘（Pek.RAgent）：$starExe"
        # 覆盖安装/升级：先停旧实例（不存在时静默忽略）
        & $starExe -StopService $ServiceName *> $null
        Write-Host "[3/4] 注册子服务：$ServiceName"
        & $starExe -AddService $ServiceName $dst $target
        if ($LASTEXITCODE -ne 0) {
            Write-Host "注册失败（退出码 $LASTEXITCODE）：详见上方星尘输出"
            exit $LASTEXITCODE
        }
        $registered = $true
    } else {
        Write-Host "[2/4] 检测到非 Rust 版星尘：$starExe"
        Write-Host '[3/4] 跳过自动注册：C# 版请在星尘面板注册 ——'
        Write-Host "      名称 $ServiceName，程序 $dst，目录 $target"
    }
} else {
    Write-Host '[2/4] -NoAgent：跳过星尘探测'
    Write-Host '[3/4] 跳过注册（请自行以计划任务/前台方式运行）'
}

# ---- [4/4] 配置就绪检查 ----
# 未就绪 = 无 config.json，或仍是模板占位（占位配置运行会退出，星尘将反复拉起）
if (Test-Path -LiteralPath $config) {
    $text = [IO.File]::ReadAllText($config)
    if ($text -notmatch '你的TokenId|example\.com') { $ready = $true }
}

if ($ready) {
    Write-Host "[4/4] 配置就绪：$config"
    if ($registered) {
        Write-Host "      子服务已由星尘拉起；修改配置后重启生效（面板「子服务」页或 -RestartService $ServiceName）"
    }
} elseif ($registered) {
    # 占位/缺失配置：先停用，避免星尘反复拉起无效配置（-StopService 会同时禁用）
    & $starExe -StopService $ServiceName *> $null
    Write-Host '[4/4] 配置未就绪：已安装但「暂未启动」'
    Write-Host "      ① 编辑配置：$config（域名 / DNSPod Token 等）"
    Write-Host "      ② 启动子服务：& '$starExe' -StartService $ServiceName（或星尘面板「子服务」页启动）"
} else {
    Write-Host "[4/4] 配置未就绪：$config（填写后即可运行）"
}

Write-Host ''
Write-Host '=============================================================='
Write-Host ' [Rust.DDNS] 安装完成'
Write-Host "   程序：$dst"
Write-Host "   目录：$target"
if ($registered) {
    if ($ready) {
        Write-Host '   托管：由星尘守护（覆盖程序文件后自动重启升级）'
        Write-Host '   状态：已启动'
    } else {
        Write-Host '   托管：已注册进星尘（当前为停用状态，配置完成后启动）'
        Write-Host '   状态：待配置'
    }
} elseif ($NoAgent) {
    Write-Host '   托管：未注册（自行管理）'
} else {
    Write-Host '   托管：未注册进星尘（见上方 [2/4][3/4] 提示）'
}
Write-Host "   配置：$config"
Write-Host '=============================================================='
