# sync-memory.ps1 —— 把本机 Copilot 的"仓库记忆"同步到当前项目的 docs/项目记忆.md
# 用法（在项目根目录运行）：
#   powershell -ExecutionPolicy Bypass -File tools\continuity\sync-memory.ps1
# 任意电脑通用：脚本自动按项目路径在本机 workspaceStorage 中定位工作区，再找记忆目录。
param(
  [string]$ProjectPath = (Get-Location).Path,
  [string]$Out = 'docs\项目记忆.md'
)
$ErrorActionPreference = 'Stop'

$proj = (Resolve-Path $ProjectPath).Path.TrimEnd('\')
$wsRoot = Join-Path $env:APPDATA 'Code\User\workspaceStorage'
if (-not (Test-Path $wsRoot)) { throw "未找到 workspaceStorage：$wsRoot" }

# 1) 收集所有匹配当前项目路径的工作区
$hits = @()
foreach ($d in Get-ChildItem $wsRoot -Directory) {
  $wj = Join-Path $d.FullName 'workspace.json'
  if (-not (Test-Path $wj)) { continue }
  try { $j = Get-Content $wj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  $uri = $null
  if ($j.folder) { $uri = $j.folder } elseif ($j.workspace) { $uri = $j.workspace }
  if (-not $uri) { continue }
  $decoded = ([uri]::UnescapeDataString(($uri -replace '^file:///',''))) -replace '/','\'
  $decoded = $decoded.TrimEnd('\')
  if ($decoded -ieq $proj) { $hits += $d.FullName }
}
if ($hits.Count -eq 0) { throw "未找到该项目的本机工作区记录（请先用 VS Code 打开过该项目、并有过 AI 对话）" }

# 2) 优先选择存在记忆目录的那个工作区
$hit = $null
foreach ($h in $hits) {
  $md = Join-Path $h 'GitHub.copilot-chat\memory-tool\memories\repo'
  if (Test-Path $md) { $hit = $h; break }
}
if (-not $hit) { $hit = $hits[0] }

$memDir = Join-Path $hit 'GitHub.copilot-chat\memory-tool\memories\repo'
if (-not (Test-Path $memDir)) { throw "尚无仓库记忆目录：$memDir（先在对话里让 AI 写一条 repo 记忆）" }
$files = @(Get-ChildItem $memDir -Filter *.md)
if ($files.Count -eq 0) { throw "记忆目录为空：$memDir" }

# 3) 输出到项目
$outPath = Join-Path $proj $Out
$outDir = Split-Path $outPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

$header = @'
> 本文件＝Copilot 跨会话工作记忆（repo memory）的**仓库镜像**，由 `tools/continuity/sync-memory.ps1` 自动同步。
> 新电脑接续：配合 `.github/copilot-instructions.md` 与 `docs/项目接续指南.md` 阅读。

'@

if ($files.Count -eq 1) {
  $content = Get-Content $files[0].FullName -Raw -Encoding UTF8
  [IO.File]::WriteAllText($outPath, $header + $content, (New-Object Text.UTF8Encoding($false)))
  Write-Host ("OK: " + $files[0].Name + "  ->  " + $Out)
} else {
  $outFolder = Join-Path $proj (($Out -replace '\.md$','.d'))
  if (-not (Test-Path $outFolder)) { New-Item -ItemType Directory -Path $outFolder | Out-Null }
  foreach ($f in $files) {
    $content = Get-Content $f.FullName -Raw -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $outFolder $f.Name), $header + $content, (New-Object Text.UTF8Encoding($false)))
  }
  Write-Host ("OK: " + $files.Count + " 个记忆文件 -> " + (($Out -replace '\.md$','.d')))
}
