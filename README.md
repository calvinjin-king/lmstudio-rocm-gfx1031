# LM Studio ROCm Unlock: full AMD RDNA2 support (gfx1030–1036)

Unlock **ROCm (HIP) acceleration** for mid-range RDNA2 GPUs — **RX 6600 / 6650 XT / 6700 XT / 6750 XT / 6500 XT / 6400** — in **LM Studio**. No driver hacks, no OS reinstall, no compiling: everything comes from official upstream binaries.

> [中文说明（README.zh-CN.md）](README.zh-CN.md)

LM Studio's official ROCm runtime only lists `gfx1030` and newer architectures (gfx1100/1101/1102/1151/1200/1201), silently excluding RDNA2 `gfx1031`–`gfx1036`. But the AMD HIP runtime **does work on those GPUs** ([ROCm #2770](https://github.com/ROCm/legacy-rocm-build/issues/2770)) — three pieces are just missing (see [How it works](docs/how-it-works.md)):

1. **HIP enumeration layer**: the official HIP SDK runtime fails to enumerate gfx1031 on Windows (`No hip devices found`) → use the `amdhip64_7.dll` from AMD's [TheRock](https://github.com/ROCm/TheRock) community builds (ROCm 10.0.0)
2. **GPU kernel layer**: LM Studio's engine `ggml-hip.dll` was never compiled for gfx1031 → use the `ggml-hip.dll` from llama.cpp's official HIP release (officially ships gfx1030–1036 code objects, built on TheRock)
3. **BLAS layer**: the vendored rocBLAS has no gfx1031 GEMM kernels → drop in TheRock's rocBLAS/hipBLASLt and the gfx103X kernel files

## Benchmarks

| Setup | ROCm (this project) | Vulkan | Gain |
|---|---|---|---|
| RX 6700 XT 12GB · LM Studio 0.4.26 · Qwen3.5-9B Q4_K_M · same prompt | **48.13 tok/s** | 40.77 tok/s | **+18%** |
| RX 6700 XT · 300-token generation test (32K ctx; larger with FA + q8_0 KV) | 43.4 tok/s | — | — |

Test machine: Windows 10 19045 · Adrenalin 32.0.21045.16010 · runtime 2.47.0 (llama.cpp b11235).

## Supported GPUs

| Arch | Cards (examples) | Status |
|---|---|---|
| gfx1030 | RX 6800 / 6900 XT | officially supported already |
| **gfx1031** | **RX 6700 XT / 6700 / 6650 XT** | ✅ **tested by this project** |
| gfx1032 | RX 6600 / 6600 XT / 6500 XT | should work* |
| gfx1034/1035/1036 | RX 6400 etc. | should work* |

\* The llama.cpp b11228 HIP build ships code objects for the whole gfx1030–1036 family, and TheRock's gfx103X runtime + BLAS kernels cover it too. Only gfx1031 has been end-to-end tested so far — feedback welcome.

## Quick start (one-click script)

Requirements: Windows 10/11 x64 · [LM Studio](https://lmstudio.ai) 0.3.9+ (0.4.x recommended, tested on 0.4.26) · stock AMD driver (no special version needed) · ~2.5 GB of downloads · ≥ 10 GB free disk.

Run in PowerShell (**quit LM Studio first**; the script will remind you):

```powershell
git clone https://github.com/calvinjin-king/lmstudio-rocm-gfx1031.git
cd lmstudio-rocm-gfx1031\scripts
powershell -ExecutionPolicy Bypass -File .\unlock-rocm-gfx1031.ps1
```

The script: installs LM Studio runtime 2.47.0 via `lms runtime get` → downloads the [official llama.cpp b11228 ROCm package](https://github.com/ggml-org/llama.cpp/releases/download/b11228/llama-b11228-bin-win-rocm-10.0-x64.zip) (245 MB) and extracts `ggml-hip.dll` → downloads the [TheRock gfx103X stable dist](https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx103X-all-10.0.0.tar.gz) (1.87 GB, AMD's official stable repo) and selectively extracts 8 runtime DLLs + gfx103X BLAS kernels → applies the patch → verifies. Everything is cached in `%LOCALAPPDATA%\lmstudio-rocm-gfx1031-cache` with resume support; the script is idempotent.

Then start LM Studio → pick **`llama.cpp-win-x86_64-amd-rocm-avx2@2.47.0`** as the runtime → load a model with GPU offload at max. Done.

Behind a slow GitHub connection (mainland China): add `-MirrorPrefix https://ghfast.top/` (or any gh proxy prefix) — only GitHub downloads are affected; TheRock is served from AMD's own CDN.

## After an LM Studio update

- Runtime updates **add new version folders**, they don't overwrite 2.47.0 — normally nothing to do;
- If a major app update resets the vendor libs or renames folders, just **re-run `unlock-rocm-gfx1031.ps1`** (idempotent, cache hits make it take minutes);
- Don't "remove/repair" the 2.47.0 entry in the Runtime manager.

## Rollback

```powershell
powershell -ExecutionPolicy Bypass -File .\rollback-rocm-gfx1031.ps1
```

Restores the original `ggml-hip.dll`, removes the gfx103X targets from the manifest, and restores the original vendor DLLs (backed up automatically on first patch).

## Background

- [docs/how-it-works.md](docs/how-it-works.md) — LM Studio runtime package format, version ↔ llama.cpp commit mapping, DLL dependency chain
- [docs/pitfalls.md](docs/pitfalls.md) — every pitfall hit on the way (silent 0xC0000135 exits, ggml ABI crashes, HIP enumeration failures, the hidden `origami.dll`, BOM-free JSON, …)

## FAQ

**Q: How does this compare to ZLUDA / DirectML?**
This is the native HIP backend — no translation layer, better speed and stability than ZLUDA setups; DirectML for llama.cpp is unmaintained.

**Q: Isn't Vulkan good enough?**
It works, but on RDNA2 the HIP backend is clearly faster (same machine, same model: +18%, and the gap grows with context length), and Vulkan lacks several quantized-kernel optimizations.

**Q: Can I patch the newer 2.55.0 / 2.61.0 / 2.64.0 runtimes instead?**
Not by swapping their `ggml-hip.dll` — the ggml backend ABI is tied to the llama.cpp commit, and cross-version swaps crash (b11228 → b11511 crashes in `ggml_backend_dev_get_props`, tested). 2.47.0 was chosen precisely because its b11235 is only 7 commits away from b11228.

**Q: Is this safe?**
Every binary comes from an official channel: TheRock stable CDN (AMD), llama.cpp GitHub releases, LM Studio's own runtime catalog. This repository contains only documentation and PowerShell scripts you can read before running.

## License

Repository content (docs & scripts) is [MIT](LICENSE). Referenced binaries follow their upstream licenses (llama.cpp: MIT; ROCm/TheRock components: AMD ROCm license). Not affiliated with AMD or LM Studio.
