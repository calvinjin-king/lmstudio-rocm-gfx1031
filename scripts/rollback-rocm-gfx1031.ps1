#Requires -Version 5.1
<#
.SYNOPSIS
  Roll back every change made by unlock-rocm-gfx1031.ps1.
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

Info "restoring the engine ggml-hip.dll..."
$hipBackup = Join-Path $RT 'ggml-hip.dll.orig'
if (Test-Path $hipBackup) {
    Copy-Item $hipBackup (Join-Path $RT 'ggml-hip.dll') -Force
    Ok "official ggml-hip.dll restored"
} else { Info "no backup found (never patched, or already rolled back)" }

Info "restoring original vendor DLLs..."
$vendorBackup = Join-Path $VENDOR 'gfx1031-unlock-backup'
if (Test-Path $vendorBackup) {
    foreach ($d in $VendorDlls) {
        $bak = Join-Path $vendorBackup $d
        if (Test-Path $bak) { Copy-Item $bak (Join-Path $VENDOR $d) -Force }
    }
    Remove-Item $vendorBackup -Recurse -Force
    Ok "vendor runtime libs restored"
} else { Info "no vendor backup found" }

Info "removing the gfx103X kernel files added by the patch..."
$libDst = Join-Path $VENDOR 'rocblas\library'
if (Test-Path $libDst) {
    Get-ChildItem $libDst -File | Where-Object { $_.Name -match 'gfx1031|gfx1032|gfx1034|gfx1035|gfx1036' } |
        Remove-Item -Force
    Ok "kernel files cleaned"
}

Info "removing gfx103X targets from the manifest..."
$manifest = Join-Path $RT 'backend-manifest.json'
if (Test-Path $manifest) {
    $j = Get-Content $manifest -Raw | ConvertFrom-Json
    $j.gpu.targets = @($j.gpu.targets | Where-Object { $_ -notmatch '^gfx103[123456]$' })
    [IO.File]::WriteAllText($manifest, ($j | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
    Ok "targets: $($j.gpu.targets -join ', ')"
}

Write-Host ""
Ok "rollback complete. The download cache (%LOCALAPPDATA%\lmstudio-rocm-gfx1031-cache) is kept; delete it manually if you want a full cleanup."
