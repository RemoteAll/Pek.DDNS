<#
Rust.DDNS 一键发布打包（Windows 主机）

功能：
  - Windows：本机 MSVC release 构建（target\release\Rust_DDNS.exe），产物含配置模板
  - Linux  ：cargo-zigbuild + zig 交叉编译（静态单文件，musl x86_64），
              包内附带 install.sh（一键安装进星尘 Pek.RAgent）+ 配置模板 + 部署说明
  - 产物输出到 dist\（zip / tar.gz / SHA256SUMS.txt）
  - 版本号：默认自动递升补丁号（-NoBump 关闭；-BumpMinor 升次版本）

用法：
  powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1
  可选参数：
    -Targets 默认 all；可多选：-Targets linux / -Targets windows
    -Clean        先清理 dist 旧产物与 zig 缓存，再构建
    -CleanAll     额外执行 cargo clean（清空全部编译缓存，最省磁盘）
    -NoBump       关闭「默认自动递升补丁版本号」（保持当前版本打包；仍受守卫拦截）
    -Force        跳过「同版本内容变化」打包拦截（逃生门；需版本守卫可用）
    -Bump         兼容保留：显式递升补丁号（现为默认行为）
    -BumpMinor    递升次版本号（minor，补丁归零）

前置条件（仅 Linux 交叉构建需要；缺失时脚本自动补齐）：
  - cargo-zigbuild：cargo install --locked cargo-zigbuild      （缺失时自动安装）
  - rustup 目标组件：x86_64-unknown-linux-musl                 （缺失时自动安装）
  - zig 可执行文件（查找顺序：CARGO_ZIGBUILD_ZIG_PATH → E:\Soft\zig-* → G:\Tools\zig →
      项目 tools\zig → 自动从清华 PyPI 镜像下载到 tools\zig）

版本守卫（可选，推荐）：
  自动定位 DH.RustBase 的 tools\version-guard.ps1（查找：$env:DHRUST_PATH →
  F:\Code\Rust\DH.RustBase → G:\Code\Rust\DH.RustBase → 相对路径 ../../../Code/Rust →
  %USERPROFILE%\Code\Rust）；**打包默认自动递升补丁版本号**（-NoBump 关闭），
  同版本号内容指纹变化时默认拒绝；找不到守卫时跳过升号与拦截（仅告警），
  显式 -Bump/-BumpMinor 在无守卫时报错终止。
#>

param(
    [ValidateSet('all', 'windows', 'linux')]
    [string[]]$Targets = @('all'),
    [switch]$Clean,
    [switch]$CleanAll,
    [switch]$Force,
    [switch]$NoBump,     # 关闭默认的自动递升补丁版本号
    [switch]$Bump,       # 兼容保留：显式递升补丁号（现为默认行为）
    [switch]$BumpMinor   # 递升次版本号（minor，补丁归零）
)

function Test-Want([string]$name) { $Targets -contains 'all' -or $Targets -contains $name }

function Write-ToolOutput([object]$item) {
    # 原生命令 stderr 经 2>&1 会被包装为 ErrorRecord（[string] 转换只得类型名）——取消息本体回显
    if ($item -is [System.Management.Automation.ErrorRecord]) { Write-Host $item.Exception.Message }
    else { Write-Host ([string]$item) }
}

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# ———— 版本升号守卫（可选：定位 DH.RustBase/tools/version-guard.ps1；防「同版本号打包出不同内容」）————
$guardScript = $null
$guardCands = @()
if ($env:DHRUST_PATH) { $guardCands += (Join-Path $env:DHRUST_PATH 'tools\version-guard.ps1') }
$guardCands += 'F:\Code\Rust\DH.RustBase\tools\version-guard.ps1'
$guardCands += 'G:\Code\Rust\DH.RustBase\tools\version-guard.ps1'
$guardCands += (Join-Path $root '..\..\..\Code\Rust\DH.RustBase\tools\version-guard.ps1')
$guardCands += (Join-Path $env:USERPROFILE 'Code\Rust\DH.RustBase\tools\version-guard.ps1')
foreach ($c in $guardCands) {
    if ($c -and (Test-Path $c)) { $guardScript = (Resolve-Path $c).Path; break }
}
if ($guardScript) {
    . $guardScript
    # 默认自动递升补丁版本号（-NoBump 关闭；-BumpMinor 递升次版本）
    Assert-VersionGuard -RepoRoot $root -Name 'rust-ddns' -Force:$Force `
        -Bump:((-not $NoBump) -and (-not $BumpMinor)) -BumpMinor:$BumpMinor `
        -Include @('Cargo.toml', 'Cargo.lock', 'src', 'deploy', 'config.example.json')
} else {
    if ($Bump -or $BumpMinor) { throw '-Bump/-BumpMinor 需要版本守卫脚本（未找到 DH.RustBase/tools/version-guard.ps1；可设置环境变量 DHRUST_PATH）' }
    Write-Warning '未找到版本守卫（DH.RustBase/tools/version-guard.ps1）——跳过自动升号与「同版本内容变化」打包拦截'
}

# zig 版本（自动下载时使用；与 cargo-zigbuild 的已验证组合——2026-10-10 实测 0.17.0 通过）
$ZigVersion = '0.17.0'

# 定位 zig.exe：CARGO_ZIGBUILD_ZIG_PATH → E:\Soft\zig-* → G:\Tools\zig → 项目 tools\zig → 自动下载（清华 PyPI 镜像）
function Resolve-Zig {
    $candidates = @()
    if ($env:CARGO_ZIGBUILD_ZIG_PATH) { $candidates += $env:CARGO_ZIGBUILD_ZIG_PATH }
    # 注意：通配路径 + -Recurse -Filter 组合会返回空（PowerShell 行为）——先列目录、再各自递归
    $candidates += @(Get-ChildItem 'E:\Soft\zig-*' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                         Get-ChildItem $_.FullName -Recurse -Filter zig.exe -ErrorAction SilentlyContinue } |
                     Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
    $candidates += @(Get-ChildItem 'G:\Tools\zig' -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
                     Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
    $localTools = Join-Path $root 'tools\zig'
    $candidates += @(Get-ChildItem $localTools -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
                     Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)

    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }

    Write-Host "== 未找到 zig，自动下载 zig $ZigVersion（优先清华 PyPI 镜像，失败自动回退官网） =="
    New-Item -ItemType Directory -Force -Path $localTools | Out-Null
    $ok = $false

    # 1) 清华 PyPI 的 ziglang wheel（本质 zip；curl 失败时用 Invoke-WebRequest 重试）
    $whl = Join-Path $localTools 'ziglang.whl'
    try {
        $simple = Invoke-WebRequest -Uri 'https://pypi.tuna.tsinghua.edu.cn/simple/ziglang/' -UseBasicParsing -TimeoutSec 60
        $line = ($simple.Content -split "`n" | Select-String "ziglang-$ZigVersion-py3-none-win_amd64\.whl" | Select-Object -First 1).ToString()
        $href = [regex]::Match($line, 'href="([^"]+)"').Groups[1].Value
        if (-not $href) { throw '镜像索引中未找到对应 wheel' }
        $url = [Uri]::new([Uri]'https://pypi.tuna.tsinghua.edu.cn/simple/ziglang/', $href).AbsoluteUri

        try {
            curl.exe -L --fail --silent --show-error -o $whl $url
            if ($LASTEXITCODE -ne 0) { throw "curl 下载失败（$LASTEXITCODE）" }
        } catch {
            Write-Host '  curl 失败，改用 Invoke-WebRequest 重试…'
            Invoke-WebRequest -Uri $url -OutFile $whl -UseBasicParsing -TimeoutSec 300
        }

        tar.exe -xf $whl -C $localTools
        if ($LASTEXITCODE -ne 0) { throw 'tar 解压失败' }
        if (Test-Path (Join-Path $localTools 'ziglang')) {
            Rename-Item (Join-Path $localTools 'ziglang') (Join-Path $localTools "zig-$ZigVersion") -ErrorAction SilentlyContinue
            $ok = $true
        }
    } catch {
        Write-Host "  清华镜像不可用：$($_.Exception.Message)"
    } finally {
        Remove-Item $whl -Force -ErrorAction SilentlyContinue
    }

    # 2) 官网 zip 兜底（国内可能较慢）
    if (-not $ok) {
        $zip = Join-Path $localTools 'zig.zip'
        $official = "https://ziglang.org/download/$ZigVersion/zig-x86_64-windows-$ZigVersion.zip"
        try {
            Write-Host "  尝试官网兜底：$official"
            try {
                curl.exe -L --fail --silent --show-error -o $zip $official
                if ($LASTEXITCODE -ne 0) { throw "curl 下载失败（$LASTEXITCODE）" }
            } catch {
                Invoke-WebRequest -Uri $official -OutFile $zip -UseBasicParsing -TimeoutSec 600
            }
            Expand-Archive -LiteralPath $zip -DestinationPath $localTools -Force
            $ok = $true
        } catch {
            Write-Host "  官网兜底也失败：$($_.Exception.Message)"
        } finally {
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item (Join-Path $localTools 'ziglang-*.dist-info') -Recurse -Force -ErrorAction SilentlyContinue

    $found = (Get-ChildItem $localTools -Recurse -Filter zig.exe -ErrorAction SilentlyContinue |
              Sort-Object FullName -Descending | Select-Object -First 1).FullName
    if ($found) {
        Write-Host "zig 已就绪：$found"
        return $found
    }
    throw "自动下载 zig 失败：请手动准备 —— 1) 官网 https://ziglang.org/download/ 下载 zig-$ZigVersion 并解压；2) 或清华 PyPI 的 ziglang wheel（zip）解压；然后用环境变量 CARGO_ZIGBUILD_ZIG_PATH 指向 zig.exe，或放到 E:\Soft\zig-* / G:\Tools\zig / 项目 tools\zig"
}

# ---- 清理 ----
if ($Clean -or $CleanAll) {
    Write-Host '== 清理：dist 旧产物 + zig 缓存 =='
    if (Test-Path 'dist') { Remove-Item 'dist\*' -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item 'target\zig-cache' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\cargo-zigbuild" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:LOCALAPPDATA\zig" -Recurse -Force -ErrorAction SilentlyContinue
}
if ($CleanAll) {
    Write-Host '== 清理：cargo clean（全部编译缓存，下次全量重建）=='
    cargo clean
    if ($LASTEXITCODE -ne 0) { throw 'cargo clean 失败' }
}

# ---- 版本号 ----
$ver = (Select-String -Path 'Cargo.toml' -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value
Write-Host "Rust.DDNS v$ver 打包开始（$($Targets -join ', ')）"
New-Item -ItemType Directory -Force -Path 'dist' | Out-Null

# ---- Windows ----
if (Test-Want 'windows') {
    Write-Host '== Windows release 构建（MSVC，增量） =='
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    cargo build --release --locked 2>&1 | ForEach-Object { Write-ToolOutput $_ }
    $code = $LASTEXITCODE; $ErrorActionPreference = $prevEap
    if ($code -ne 0) { throw 'Windows 构建失败' }

    $zipWin = "dist\Rust_DDNS-v$ver-x86_64-pc-windows-msvc.zip"
    Compress-Archive -Path 'target\release\Rust_DDNS.exe', 'config.example.json' -DestinationPath $zipWin -Force
    Write-Host "zip OK：$zipWin"
}

# ---- Linux（zig 交叉编译） ----
if (Test-Want 'linux') {
    # 前置：cargo-zigbuild（缺失则自动安装，走工程内 rsproxy 镜像）
    if (-not (Get-Command cargo-zigbuild -ErrorAction SilentlyContinue)) {
        Write-Host '== 缺少 cargo-zigbuild，自动安装：cargo install --locked cargo-zigbuild =='
        cargo install --locked cargo-zigbuild
        if ($LASTEXITCODE -ne 0) {
            throw 'cargo-zigbuild 安装失败：请手动执行 cargo install --locked cargo-zigbuild 后重试'
        }
    }

    # 前置：zig（CARGO_ZIGBUILD_ZIG_PATH → G:\Tools\zig → 项目 tools\zig → 自动下载）
    $zig = Resolve-Zig
    $env:CARGO_ZIGBUILD_ZIG_PATH = $zig
    Write-Host "zig：$zig"

    # python 打包助手（tar.gz 需要执行位；Windows 自带 bsdtar 无法设置权限）
    $py = $null
    foreach ($cand in @('py', 'python')) {
        $src = (Get-Command $cand -ErrorAction SilentlyContinue).Source
        if ($src -and ($src -notlike '*WindowsApps*')) { $py = $cand; break }
    }
    $helper = Join-Path $env:TEMP 'rustddns-tar.py'
    if ($py) {
        $pyCode = @'
import io, tarfile, time, sys
# 用法：python helper <dst.tar.gz> <path> <name> [<path> <name> ...]
# .sh/.md 文件行尾归一化为 LF（Windows 工作区可能是 CRLF）；二进制与 .sh 置 0755，其余 0644
dst, args = sys.argv[1], sys.argv[2:]
with tarfile.open(dst, 'w:gz') as t:
    for path, name in zip(args[0::2], args[1::2]):
        with open(path, 'rb') as f:
            data = f.read()
        if name.endswith(('.sh', '.md')):
            data = data.replace(b'\r\n', b'\n')
        ti = tarfile.TarInfo(name)
        ti.size = len(data)
        ti.mode = 0o644 if name.endswith(('.json', '.md')) else 0o755
        ti.mtime = int(time.time())
        ti.uname = 'root'
        ti.gname = 'root'
        t.addfile(ti, io.BytesIO(data))
'@
        Set-Content -Path $helper -Value $pyCode -Encoding ASCII
    }

    $t = 'x86_64-unknown-linux-musl'
    $installed = (rustup target list --installed) -join ' '
    if ($installed -notlike "*$t*") {
        Write-Host "== 首次需要：rustup target add $t =="
        rustup target add $t
        if ($LASTEXITCODE -ne 0) { throw "缺少目标 $t：请先执行 rustup target add $t 后重试" }
    }

    Write-Host "== Linux 交叉构建：$t（cargo-zigbuild，增量） =="
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    cargo zigbuild --release --locked --target $t 2>&1 | ForEach-Object { Write-ToolOutput $_ }
    $code = $LASTEXITCODE; $ErrorActionPreference = $prevEap
    if ($code -ne 0) { throw "交叉构建失败：$t" }

    $bin = "target\$t\release\Rust_DDNS"
    $tgz = "dist\Rust_DDNS-v$ver-$t.tar.gz"
    $packed = $false
    if ($py) {
        # 附带 install.sh（`sh install.sh` 一键安装进星尘）+ 配置模板 + 部署说明
        & $py $helper $tgz $bin 'Rust_DDNS' 'deploy\install.sh' 'install.sh' 'config.example.json' 'config.example.json' 'deploy\README-部署.md' 'README-部署.md'
        $packed = ($LASTEXITCODE -eq 0)
    }
    if (-not $packed) {
        Write-Warning '未找到可用的 python：tar.gz 内文件不带执行位且不附带安装脚本，解压后请手动 chmod +x Rust_DDNS'
        tar -czf $tgz -C (Split-Path $bin) 'Rust_DDNS'
    }
    if ($py) { Remove-Item $helper -Force -ErrorAction SilentlyContinue }
}

# ---- 校验和（覆盖 dist 内全部产物，支持按目标增量构建） ----
$shaLines = Get-ChildItem 'dist\*.zip', 'dist\*.tar.gz' -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower() + '  ' + $_.Name }
if ($shaLines) {
    # 行尾固定 LF（Set-Content 在 Windows 会写 CRLF，导致 Linux 上 sha256sum -c 报 "No such file"）
    [IO.File]::WriteAllText((Join-Path $root 'dist\SHA256SUMS.txt'), (($shaLines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}

Write-Host ''
Write-Host '== 打包完成，产物（dist） =='
Get-ChildItem 'dist' | Sort-Object Name | Format-Table Name, @{ n = 'KB'; e = { [math]::Round($_.Length / 1KB, 0) } } -AutoSize | Out-String | Write-Host
Write-Host '提示：打包默认自动递升补丁号（-NoBump 可关；次版本用 -BumpMinor）。'
Write-Host '提示：Linux 包解压后 sudo sh install.sh（一键安装进星尘/手动运行）；Windows 包解压直接运行 exe。'
Write-Host '提示：-Clean 清理 zig 缓存与旧产物；-CleanAll 额外清空 target（全量重建、最省空间）。'
