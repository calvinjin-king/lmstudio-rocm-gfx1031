#Requires -Version 5.1
<#
.SYNOPSIS
  Unlock ROCm (gfx1030-1036, RDNA2) for LM Studio — one-click script.

.DESCRIPTION
  1. Locate LM Studio and the lms CLI
  2. Install runtime 2.47.0 via lms (= llama.cpp b11235)
  3. Download llama.cpp b11228 official ROCm package (245MB), extract ggml-hip.dll
     (ships gfx1030-1036 code objects)
  4. Download the TheRock gfx103X stable dist (1.87GB, AMD CDN), selectively extract
     the ROCm runtime DLLs and BLAS kernels
  5. Apply the patch (idempotent): vendor v6 runtime libs + rocblas kernels
     + engine ggml-hip.dll + manifest targets
  6. Verify

  All binaries come from official upstream channels. Downloads are cached in
  %LOCALAPPDATA%\lmstudio-rocm-gfx1031-cache with resume support; the script is
  idempotent and safe to re-run.

.PARAMETER MirrorPrefix
  Optional prefix for GitHub downloads only (AMD CDN needs no mirror).
  Example: -MirrorPrefix "https://ghfast.top/"

.PARAMETER Targets
  Architectures appended to the manifest. Defaults to the RDNA2 family.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\unlock-rocm-gfx1031.ps1 -MirrorPrefix "https://ghfast.top/"
#>
param(
  [string]$MirrorPrefix = "",
  [string]$LmStudioHome = "$env:USERPROFILE\.lmstudio",
  [string]$CacheDir = "$env:LOCALAPPDATA\lmstudio-rocm-gfx1031-cache",
  [string[]]$Targets = @('gfx1031','gfx1032','gfx1034','gfx1035','gfx1036'),
  [string]$RuntimeVersion = "2.47.0",
  [switch]$KeepDownloads
)

$ErrorActionPreference = 'Stop'
function Info($m)  { Write-Host "[i] $m" -ForegroundColor Cyan }
function Ok($m)    { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m)  { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m)   { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$RT_NAME   = "llama.cpp-win-x86_64-amd-rocm-avx2-$RuntimeVersion"
$BACKENDS  = Join-Path $LmStudioHome 'extensions\backends'
$RT        = Join-Path $BACKENDS $RT_NAME
$VENDOR    = Join-Path $BACKENDS 'vendor\win-llama-rocm-vendor-v6\bin'
$LMS       = Join-Path $LmStudioHome 'bin\lms.exe'

$LlamaZipUrl = 'https://github.com/ggml-org/llama.cpp/releases/download/b11228/llama-b11228-bin-win-rocm-10.0-x64.zip'
$TheRockUrl  = 'https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx103X-all-10.0.0.tar.gz'
# TheRock DLLs (HIP runtime layer + BLAS stack)
$VendorDlls  = @('amdhip64_7.dll','amd_comgr.dll','rocm_kpack.dll','hipblas.dll','rocsolver.dll','rocblas.dll','libhipblaslt.dll','origami.dll')

Write-Host ""
Write-Host "====== LM Studio ROCm unlock for gfx1030-1036 ======" -ForegroundColor White

# ---------- 0) environment ----------
if (-not (Test-Path $LMS))        { Die "lms.exe not found: $LMS — is LM Studio installed?" }
if (-not (Test-Path $BACKENDS))   { Die "backends directory not found: $BACKENDS" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { Die "curl.exe unavailable (bundled with Windows 10 1803+)" }
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
Info "LM Studio home: $LmStudioHome"
Info "Cache dir: $CacheDir"

# ---------- 1) runtime 2.47.0 ----------
if (-not (Test-Path (Join-Path $RT 'backend-manifest.json'))) {
    Info "runtime $RuntimeVersion not installed; fetching via lms (requires LM Studio to be running)..."
    if (-not (Get-Process -Name 'LM Studio' -ErrorAction SilentlyContinue)) {
        Die "LM Studio is not running. Start it first (network required), then re-run this script."
    }
    & $LMS runtime get "llama.cpp-win-x86_64-amd-rocm-avx2@$RuntimeVersion" -y --allow-incompatible
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $RT 'backend-manifest.json'))) {
        Die "runtime download failed. You can run it manually: lms runtime get `"llama.cpp-win-x86_64-amd-rocm-avx2@$RuntimeVersion`" -y --allow-incompatible"
    }
}
Ok "runtime $RuntimeVersion ready: $RT"
if (-not (Test-Path $VENDOR)) { Die "vendor v6 missing: $VENDOR — runtime install looks broken" }

# ---------- 2) ggml-hip.dll (b11228, gfx1030-1036 kernels) ----------
$GgmlHip = Join-Path $CacheDir 'ggml-hip.dll'
if (-not (Test-Path $GgmlHip) -or (Get-Item $GgmlHip).Length -lt 400MB) {
    $zip = Join-Path $CacheDir 'llama-b11228-bin-win-rocm-10.0-x64.zip'
    $url = if ($MirrorPrefix) { $MirrorPrefix.TrimEnd('/') + '/' + $LlamaZipUrl } else { $LlamaZipUrl }
    Info "downloading llama.cpp b11228 ROCm package (245MB)..."
    & curl.exe -L -C - --retry 8 --retry-delay 3 --connect-timeout 30 -o $zip $url
    if ($LASTEXITCODE -ne 0) { Die "download failed (exit $LASTEXITCODE). On slow GitHub links, re-run with -MirrorPrefix `"https://ghfast.top/`"" }
    Info "extracting ggml-hip.dll..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $za.Entries | Where-Object { $_.Name -eq 'ggml-hip.dll' } | Select-Object -First 1
        if (-not $entry) { Die "ggml-hip.dll not found in the zip?" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $GgmlHip, $true)
    } finally { $za.Dispose() }
    if (-not $KeepDownloads) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
}
Ok "ggml-hip.dll: $([math]::Round((Get-Item $GgmlHip).Length/1MB)) MB"

# ---------- 3) TheRock vendor subset ----------
$VendorCache = Join-Path $CacheDir 'rocm-vendor'
$KernelCache = Join-Path $CacheDir 'rocblas-gfx103x-library'
$needVendor = (@($VendorDlls | ForEach-Object { Test-Path (Join-Path $VendorCache $_) }) -contains $false)
if ($needVendor) {
    $tgz = Join-Path $CacheDir 'therock-dist-windows-gfx103X-all-10.0.0.tar.gz'
    if (-not (Test-Path $tgz) -or (Get-Item $tgz).Length -lt 1GB) {
        Info "downloading the TheRock gfx103X stable dist (1.87GB, AMD CDN, resumable)..."
        & curl.exe -L -C - --retry 8 --retry-delay 3 --connect-timeout 30 -o $tgz $TheRockUrl
        if ($LASTEXITCODE -ne 0) { Die "download failed (exit $LASTEXITCODE)" }
    }
    $extract = Join-Path $CacheDir 'therock-extract'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    Info "selectively extracting runtime DLLs and gfx103X kernels (tar wildcards)..."
    $patterns = @($VendorDlls | ForEach-Object { "*/bin/$_" }) + '*/bin/rocblas/library/*gfx103*'
    & tar.exe -xzf $tgz -C $extract @patterns
    if ($LASTEXITCODE -ne 0) { Die "tar extraction failed" }
    $binDir = Split-Path (Get-ChildItem $extract -Recurse -Filter 'amdhip64_7.dll' | Select-Object -First 1).FullName
    if (-not $binDir) { Die "amdhip64_7.dll not found in the extraction output" }
    New-Item -ItemType Directory -Path $VendorCache, $KernelCache -Force | Out-Null
    foreach ($d in $VendorDlls) { Copy-Item (Join-Path $binDir $d) (Join-Path $VendorCache $d) -Force }
    $libDir = Join-Path $binDir 'rocblas\library'
    Copy-Item (Join-Path $libDir '*') $KernelCache -Force
    Info "cleaning up extraction temp dir..."
    Remove-Item $extract -Recurse -Force
    if (-not $KeepDownloads) { Remove-Item $tgz -Force -ErrorAction SilentlyContinue }
}
$missing = @($VendorDlls | Where-Object { -not (Test-Path (Join-Path $VendorCache $_)) })
if ($missing.Count -gt 0) { Die ("vendor subset incomplete, missing: " + ($missing -join ', ')) }
$kernelCount = (Get-ChildItem $KernelCache -File).Count
Ok "TheRock vendor subset: $($VendorDlls.Count) DLLs + $kernelCount gfx103X kernel files"

# ---------- 4) apply the patch ----------
Info "applying patch (originals backed up first)..."

# 4a. back up and swap the engine ggml-hip.dll
$rtHip = Join-Path $RT 'ggml-hip.dll'
$hipBackup = Join-Path $RT 'ggml-hip.dll.orig'
if ((Test-Path $rtHip) -and -not (Test-Path $hipBackup)) {
    Copy-Item $rtHip $hipBackup -Force
    Ok "engine's original ggml-hip.dll backed up"
}
Copy-Item $GgmlHip $rtHip -Force

# 4b. back up and replace vendor DLLs
$vendorBackup = Join-Path $VENDOR 'gfx1031-unlock-backup'
New-Item -ItemType Directory -Path $vendorBackup -Force | Out-Null
foreach ($d in $VendorDlls) {
    $src = Join-Path $VENDOR $d
    $bak = Join-Path $vendorBackup $d
    if ((Test-Path $src) -and -not (Test-Path $bak)) { Copy-Item $src $bak -Force }
    Copy-Item (Join-Path $VendorCache $d) $src -Force
}

# 4c. rocblas kernels
$libDst = Join-Path $VENDOR 'rocblas\library'
New-Item -ItemType Directory -Path $libDst -Force | Out-Null
Copy-Item (Join-Path $KernelCache '*') $libDst -Force

# 4d. manifest targets (BOM-free!)
$manifest = Join-Path $RT 'backend-manifest.json'
$j = Get-Content $manifest -Raw | ConvertFrom-Json
foreach ($t in $Targets) { if ($j.gpu.targets -notcontains $t) { $j.gpu.targets += $t } }
[IO.File]::WriteAllText($manifest, ($j | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
Ok "manifest targets: $($j.gpu.targets -join ', ')"

# ---------- 5) verify ----------
Write-Host ""
Write-Host "====== Verify ======" -ForegroundColor White
$ok = $true
$j2 = Get-Content $manifest -Raw | ConvertFrom-Json
foreach ($t in $Targets) { if ($j2.gpu.targets -notcontains $t) { Warn "targets missing $t"; $ok = $false } }
if ((Get-Item $rtHip).Length -lt 400MB) { Warn "ggml-hip.dll size looks wrong"; $ok = $false }
foreach ($d in $VendorDlls) { if (-not (Test-Path (Join-Path $VENDOR $d))) { Warn "vendor missing $d"; $ok = $false } }
$kCount = (Get-ChildItem $libDst -File | Where-Object { $_.Name -match 'gfx1031|gfx1032|gfx1034|gfx1035|gfx1036' }).Count
if ($kCount -lt 100) { Warn "too few gfx103X kernel files ($kCount)"; $ok = $false }
if ($ok) {
    Ok "all set!"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host "  1. Start LM Studio"
    Write-Host "  2. Pick llama.cpp-win-x86_64-amd-rocm-avx2@$RuntimeVersion as the runtime"
    Write-Host "  3. Load a model with GPU offload at max — enjoy ROCm"
    Write-Host "  4. Sanity check: lms runtime survey should list your GPU as (ROCm, Discrete)"
} else { Die "verification failed — see the warnings above" }
