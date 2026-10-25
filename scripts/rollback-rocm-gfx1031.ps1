#Requires -Version 5.1
<#
.SYNOPSIS
  回滚 unlock-rocm-gfx1031.ps1 的全部改动。
#>
param(
  [string]$LmStudioHome = "$env:USERPROFILE\.lmstudio",
  [string]$RuntimeVersion = "2.47.0"
)
$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host "[i] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }

$RT       = Join-Path $LmStudioHome "extensions\backends\llama.cpp-win-x86_64-amd-rocm-avx2-$RuntimeVersion"
$VENDOR   = Join-Path $LmStudioHome 'extensions\backends\vendor\win-llama-rocm-vendor-v6\bin'
$VendorDlls = @('amdhip64_7.dll','amd_comgr.dll','rocm_kpack.dll','hipblas.dll','rocsolver.dll','rocblas.dll','libhipblaslt.dll','origami.dll')

Info "回滚引擎 ggml-hip.dll..."
$hipBackup = Join-Path $RT 'ggml-hip.dll.orig'
if (Test-Path $hipBackup) {
    Copy-Item $hipBackup (Join-Path $RT 'ggml-hip.dll') -Force
    Ok "已还原官方原版 ggml-hip.dll"
} else { Info "无备份（未打过补丁或已回滚）" }

Info "还原 vendor 原始 DLL..."
$vendorBackup = Join-Path $VENDOR 'gfx1031-unlock-backup'
if (Test-Path $vendorBackup) {
    foreach ($d in $VendorDlls) {
        $bak = Join-Path $vendorBackup $d
        if (Test-Path $bak) { Copy-Item $bak (Join-Path $VENDOR $d) -Force }
    }
    Remove-Item $vendorBackup -Recurse -Force
    Ok "vendor 运行库已还原"
} else { Info "无 vendor 备份" }

Info "移除补丁添加的 gfx103X 内核文件..."
$libDst = Join-Path $VENDOR 'rocblas\library'
if (Test-Path $libDst) {
    Get-ChildItem $libDst -File | Where-Object { $_.Name -match 'gfx1031|gfx1032|gfx1034|gfx1035|gfx1036' } |
        Remove-Item -Force
    Ok "内核文件已清理"
}

Info "manifest 移除 gfx103X targets..."
$manifest = Join-Path $RT 'backend-manifest.json'
if (Test-Path $manifest) {
    $j = Get-Content $manifest -Raw | ConvertFrom-Json
    $j.gpu.targets = @($j.gpu.targets | Where-Object { $_ -notmatch '^gfx103[123456]$' })
    [IO.File]::WriteAllText($manifest, ($j | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
    Ok "targets: $($j.gpu.targets -join ', ')"
}

Write-Host ""
Ok "回滚完成。本地缓存（%LOCALAPPDATA%\lmstudio-rocm-gfx1031-cache）已保留，如需彻底清理请手动删除。"
