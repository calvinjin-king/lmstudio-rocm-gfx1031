#Requires -Version 5.1
<#
.SYNOPSIS
  LM Studio ROCm runtime 解锁 AMD RDNA2 (gfx1030-1036)：一键脚本。

.DESCRIPTION
  1. 定位 LM Studio 与 lms CLI
  2. 通过 lms 安装 runtime 2.47.0（= llama.cpp b11235）
  3. 下载 llama.cpp b11228 官方 ROCm 包（245MB），提取含 gfx1030-1036 内核的 ggml-hip.dll
  4. 下载 TheRock gfx103X stable 发行包（1.87GB），选择性提取 ROCm 运行库与 BLAS 内核
  5. 打补丁（幂等）：vendor v6 运行库 + rocblas 内核 + 引擎 ggml-hip.dll + manifest targets
  6. 校验

  全程使用官方上游二进制；下载缓存在 %LOCALAPPDATA%\lmstudio-rocm-gfx1031-cache，可中断重跑（断点续传）。

.PARAMETER MirrorPrefix
  GitHub 加速前缀（仅作用于 github.com 下载，AMD CDN 无需）。例: -MirrorPrefix "https://ghfast.top/"

.PARAMETER Targets
  追加到 manifest 的架构列表，默认 RDNA2 全家族。

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
# TheRock 的 8 个 DLL（BLAS 栈 + HIP 运行层）
$VendorDlls  = @('amdhip64_7.dll','amd_comgr.dll','rocm_kpack.dll','hipblas.dll','rocsolver.dll','rocblas.dll','libhipblaslt.dll','origami.dll')

Write-Host ""
Write-Host "====== LM Studio ROCm 解锁 gfx1030-1036 ======" -ForegroundColor White

# ---------- 0) 环境 ----------
if (-not (Test-Path $LMS))        { Die "找不到 lms.exe: $LMS —— LM Studio 未安装？" }
if (-not (Test-Path $BACKENDS))   { Die "找不到 backends 目录: $BACKENDS" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { Die "curl.exe 不可用（Windows 10 1803+ 自带）" }
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
Info "LM Studio home: $LmStudioHome"
Info "缓存目录: $CacheDir"

# ---------- 1) runtime 2.47.0 ----------
if (-not (Test-Path (Join-Path $RT 'backend-manifest.json'))) {
    Info "runtime $RuntimeVersion 未安装，尝试通过 lms 下载（需要 LM Studio 正在运行）..."
    if (-not (Get-Process -Name 'LM Studio' -ErrorAction SilentlyContinue)) {
        Die "LM Studio 未运行。请先启动 LM Studio（保持网络可用），然后重跑本脚本。"
    }
    & $LMS runtime get "llama.cpp-win-x86_64-amd-rocm-avx2@$RuntimeVersion" -y --allow-incompatible
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $RT 'backend-manifest.json'))) {
        Die "runtime 下载失败。可手动执行: lms runtime get `"llama.cpp-win-x86_64-amd-rocm-avx2@$RuntimeVersion`" -y --allow-incompatible"
    }
}
Ok "runtime $RuntimeVersion 就绪: $RT"
if (-not (Test-Path $VENDOR)) { Die "vendor v6 不存在: $VENDOR —— runtime 安装异常" }

# ---------- 2) ggml-hip.dll（b11228，含 gfx1030-1036 内核） ----------
$GgmlHip = Join-Path $CacheDir 'ggml-hip.dll'
if (-not (Test-Path $GgmlHip) -or (Get-Item $GgmlHip).Length -lt 400MB) {
    $zip = Join-Path $CacheDir 'llama-b11228-bin-win-rocm-10.0-x64.zip'
    $url = if ($MirrorPrefix) { $MirrorPrefix.TrimEnd('/') + '/' + $LlamaZipUrl } else { $LlamaZipUrl }
    Info "下载 llama.cpp b11228 ROCm 包 (245MB)..."
    & curl.exe -L -C - --retry 8 --retry-delay 3 --connect-timeout 30 -o $zip $url
    if ($LASTEXITCODE -ne 0) { Die "下载失败（退出码 $LASTEXITCODE）。国内网络可加参数 -MirrorPrefix `"https://ghfast.top/`" 重试" }
    Info "提取 ggml-hip.dll..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $za = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $za.Entries | Where-Object { $_.Name -eq 'ggml-hip.dll' } | Select-Object -First 1
        if (-not $entry) { Die "zip 里没有 ggml-hip.dll？" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $GgmlHip, $true)
    } finally { $za.Dispose() }
    if (-not $KeepDownloads) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
}
Ok "ggml-hip.dll: $([math]::Round((Get-Item $GgmlHip).Length/1MB)) MB"

# ---------- 3) TheRock vendor 子集 ----------
$VendorCache = Join-Path $CacheDir 'rocm-vendor'
$KernelCache = Join-Path $CacheDir 'rocblas-gfx103x-library'
$needVendor = (@($VendorDlls | ForEach-Object { Test-Path (Join-Path $VendorCache $_) }) -contains $false)
if ($needVendor) {
    $tgz = Join-Path $CacheDir 'therock-dist-windows-gfx103X-all-10.0.0.tar.gz'
    if (-not (Test-Path $tgz) -or (Get-Item $tgz).Length -lt 1GB) {
        Info "下载 TheRock gfx103X stable 发行包 (1.87GB，AMD 官方 CDN，支持断点续传)..."
        & curl.exe -L -C - --retry 8 --retry-delay 3 --connect-timeout 30 -o $tgz $TheRockUrl
        if ($LASTEXITCODE -ne 0) { Die "下载失败（退出码 $LASTEXITCODE）" }
    }
    $extract = Join-Path $CacheDir 'therock-extract'
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    Info "选择性提取运行库 DLL 与 gfx103X 内核（tar 通配符，无需解压全包）..."
    $patterns = @($VendorDlls | ForEach-Object { "*/bin/$_" }) + '*/bin/rocblas/library/*gfx103*'
    & tar.exe -xzf $tgz -C $extract @patterns
    if ($LASTEXITCODE -ne 0) { Die "tar 解压失败" }
    $binDir = Split-Path (Get-ChildItem $extract -Recurse -Filter 'amdhip64_7.dll' | Select-Object -First 1).FullName
    if (-not $binDir) { Die "解压结果里找不到 amdhip64_7.dll" }
    New-Item -ItemType Directory -Path $VendorCache, $KernelCache -Force | Out-Null
    foreach ($d in $VendorDlls) { Copy-Item (Join-Path $binDir $d) (Join-Path $VendorCache $d) -Force }
    $libDir = Join-Path $binDir 'rocblas\library'
    Copy-Item (Join-Path $libDir '*') $KernelCache -Force
    Info "清理解压临时目录..."
    Remove-Item $extract -Recurse -Force
    if (-not $KeepDownloads) { Remove-Item $tgz -Force -ErrorAction SilentlyContinue }
}
$missing = @($VendorDlls | Where-Object { -not (Test-Path (Join-Path $VendorCache $_)) })
if ($missing.Count -gt 0) { Die ("vendor 子集不完整，缺: " + ($missing -join ', ')) }
$kernelCount = (Get-ChildItem $KernelCache -File).Count
Ok "TheRock vendor 子集: $($VendorDlls.Count) DLL + $kernelCount 个 gfx103X 内核"

# ---------- 4) 打补丁 ----------
Info "打补丁（先备份原始文件）..."

# 4a. 备份并替换引擎 ggml-hip.dll
$rtHip = Join-Path $RT 'ggml-hip.dll'
$hipBackup = Join-Path $RT 'ggml-hip.dll.orig'
if ((Test-Path $rtHip) -and -not (Test-Path $hipBackup)) {
    Copy-Item $rtHip $hipBackup -Force
    Ok "已备份引擎原版 ggml-hip.dll"
}
Copy-Item $GgmlHip $rtHip -Force

# 4b. 备份并替换 vendor DLLs
$vendorBackup = Join-Path $VENDOR 'gfx1031-unlock-backup'
New-Item -ItemType Directory -Path $vendorBackup -Force | Out-Null
foreach ($d in $VendorDlls) {
    $src = Join-Path $VENDOR $d
    $bak = Join-Path $vendorBackup $d
    if ((Test-Path $src) -and -not (Test-Path $bak)) { Copy-Item $src $bak -Force }
    Copy-Item (Join-Path $VendorCache $d) $src -Force
}

# 4c. rocblas 内核
$libDst = Join-Path $VENDOR 'rocblas\library'
New-Item -ItemType Directory -Path $libDst -Force | Out-Null
Copy-Item (Join-Path $KernelCache '*') $libDst -Force

# 4d. manifest targets（无 BOM！）
$manifest = Join-Path $RT 'backend-manifest.json'
$j = Get-Content $manifest -Raw | ConvertFrom-Json
$changed = $false
foreach ($t in $Targets) { if ($j.gpu.targets -notcontains $t) { $j.gpu.targets += $t; $changed = $true } }
[IO.File]::WriteAllText($manifest, ($j | ConvertTo-Json -Depth 100), (New-Object Text.UTF8Encoding($false)))
Ok "manifest targets: $($j.gpu.targets -join ', ')"

# ---------- 5) 校验 ----------
Write-Host ""
Write-Host "====== 校验 ======" -ForegroundColor White
$ok = $true
$j2 = Get-Content $manifest -Raw | ConvertFrom-Json
foreach ($t in $Targets) { if ($j2.gpu.targets -notcontains $t) { Warn "targets 缺 $t"; $ok = $false } }
if ((Get-Item $rtHip).Length -lt 400MB) { Warn "ggml-hip.dll 大小异常"; $ok = $false }
foreach ($d in $VendorDlls) { if (-not (Test-Path (Join-Path $VENDOR $d))) { Warn "vendor 缺 $d"; $ok = $false } }
$kCount = (Get-ChildItem $libDst -File | Where-Object { $_.Name -match 'gfx1031|gfx1032|gfx1034|gfx1035|gfx1036' }).Count
if ($kCount -lt 100) { Warn "gfx103X 内核文件不足 ($kCount)"; $ok = $false }
if ($ok) {
    Ok "全部就绪！"
    Write-Host ""
    Write-Host "下一步：" -ForegroundColor White
    Write-Host "  1. 启动 LM Studio"
    Write-Host "  2. 右下角 Runtime（或 My Models → Settings）里选择 llama.cpp-win-x86_64-amd-rocm-avx2@$RuntimeVersion"
    Write-Host "  3. 加载模型，GPU Offload 拉满，享受 ROCm"
    Write-Host "  4. 验证: lms runtime survey 应显示你的显卡 (ROCm, Discrete)"
} else { Die "校验未通过，请查看上方警告" }
