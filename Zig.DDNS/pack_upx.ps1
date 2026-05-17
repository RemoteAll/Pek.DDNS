$ErrorActionPreference = 'Stop'

function Find-Upx {
    $command = Get-Command upx -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    $candidates = @(
        (Join-Path $env:ProgramData 'chocolatey\bin\upx.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\UPX.UPX_Microsoft.Winget.Source_8wekyb3d8bbwe\upx-5.1.1-win64\upx.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $packageRoot) {
        $found = Get-ChildItem -Path $packageRoot -Filter upx.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $found) { return $found.FullName }
    }

    throw 'UPX not found. Install it with winget or choco first.'
}

$projectRoot = $PSScriptRoot
$upxPath = Find-Upx
$releaseDir = Join-Path $projectRoot 'release\Zig_DDNS-min-upx'
$releaseExe = Join-Path $releaseDir 'Zig_DDNS.exe'
$releaseConfig = Join-Path $releaseDir 'config.json'
$releaseZip = Join-Path $projectRoot 'release\Zig_DDNS-min-upx-win-x64.zip'

Set-Location -LiteralPath $projectRoot
zig build -Doptimize=ReleaseSmall --prefix zig-out-small

New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
Copy-Item '.\zig-out-small\bin\Zig_DDNS.exe' $releaseExe -Force
Copy-Item '.\zig-out-small\bin\config.json' $releaseConfig -Force
& $upxPath --best --lzma $releaseExe
if ($LASTEXITCODE -ne 0) { throw "UPX failed with exit code $LASTEXITCODE" }

Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $releaseZip -Force

$exeItem = Get-Item -LiteralPath $releaseExe
$zipItem = Get-Item -LiteralPath $releaseZip
Write-Host "UPX: $upxPath"
Write-Host "EXE: $($exeItem.FullName) [$($exeItem.Length) bytes]"
Write-Host "ZIP: $($zipItem.FullName) [$($zipItem.Length) bytes]"