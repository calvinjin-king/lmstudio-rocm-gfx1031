# LM Studio ROCm 解锁：AMD RDNA2（gfx1030–1036）全系支持

> [English TL;DR](#english-tldr) 在文末。

给 **LM Studio** 的 ROCm（HIP）runtime 解锁 **RDNA2 中低端显卡**——RX 6600 / 6650 XT / 6700 XT / 6750 XT / 6500 XT / 6400 等。无需改驱动、无需重装系统、无需自编译，全部使用官方上游二进制组合。

官方 LM Studio 的 ROCm runtime 只列出了 `gfx1030` 及更新的架构（gfx1100/1101/1102/1151/1200/1201），RDNA2 的 `gfx1031`–`gfx1036` 被"默认排除"——实际上 AMD HIP 运行时**完全可以在这些卡上工作**（[ROCm #2770](https://github.com/ROCm/legacy-rocm-build/issues/2770)），缺的只是三样东西（见[原理](docs/how-it-works.md)）：

1. **HIP 枚举层**：官方 HIP SDK 的运行库在 Windows 上枚举不到 gfx1031（报 `No hip devices found`）→ 换用 AMD [TheRock](https://github.com/ROCm/TheRock) 社区发行版的 `amdhip64_7.dll`（ROCm 10.0.0）
2. **GPU 内核层**：LM Studio 引擎的 `ggml-hip.dll` 没有为 gfx1031 编译内核 → 换用 llama.cpp 官方 HIP release 的 `ggml-hip.dll`（官方 release 本来就带 gfx1030–1036 内核，基于 TheRock 构建）
3. **BLAS 库层**：vendor 里的 rocBLAS 没有 gfx1031 的 GEMM 内核 → 灌入 TheRock 的 rocBLAS/hipBLASLt 及 gfx103X 内核文件

## 实测成绩

| 环境 | ROCm (本方案) | Vulkan | 提升 |
|---|---|---|---|
| RX 6700 XT 12GB · LM Studio 0.4.26 · Qwen3.5-9B Q4_K_M · 同提示词 | **48.13 tok/s** | 40.77 tok/s | **+18%** |
| RX 6700 XT · 300 token 生成测试（32K 上下文，FA + q8_0 KV 时更长） | 43.4 tok/s | — | — |

测试机：Windows 10 19045 · Adrenalin 32.0.21045.16010 · runtime 2.47.0（llama.cpp b11235）。

## 支持的显卡

| 架构 | 显卡（举例） | 状态 |
|---|---|---|
| gfx1030 | RX 6800 / 6900 XT | 官方本就支持 |
| **gfx1031** | **RX 6700 XT / 6700 / 6650 XT** | ✅ **本方案实测** |
| gfx1032 | RX 6600 / 6600 XT / 6500 XT | 同源可用* |
| gfx1034/1035/1036 | RX 6400 等 | 同源可用* |

\* llama.cpp b11228 HIP 构建内含全部 gfx1030–1036 代码对象，TheRock gfx103X 运行库与 BLAS 内核亦覆盖全家族；除 gfx1031 外未逐一实测，欢迎反馈。

## 快速开始（一键脚本）

前提：Windows 10/11 x64 · [LM Studio](https://lmstudio.ai) 0.3.9+（建议 0.4.x，实测 0.4.26）· AMD 官方驱动（无需特殊版本）· 约 12 GB 下载量 · 磁盘空间 ≥ 10 GB。

以 PowerShell 运行（**先退出 LM Studio**，脚本会提示）：

```powershell
git clone https://github.com/calvinjin-king/lmstudio-rocm-gfx1031.git
cd lmstudio-rocm-gfx1031\scripts
powershell -ExecutionPolicy Bypass -File .\unlock-rocm-gfx1031.ps1
```

脚本自动完成：安装 LM Studio runtime 2.47.0（`lms runtime get`）→ 下载 [llama.cpp b11228 官方 ROCm 包](https://github.com/ggml-org/llama.cpp/releases/download/b11228/llama-b11228-bin-win-rocm-10.0-x64.zip)（245 MB）提取 `ggml-hip.dll` → 下载 [TheRock gfx103X 稳定发行包](https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx103X-all-10.0.0.tar.gz)（1.87 GB，AMD 官方 stable 仓库）选择性提取 8 个运行库 DLL 和 gfx103X BLAS 内核 → 打补丁 → 校验。所有下载缓存在 `%LOCALAPPDATA%\lmstudio-rocm-gfx1031-cache`，可断点续跑。

完成后启动 LM Studio → **Runtime 里选择 `llama.cpp-win-x86_64-amd-rocm-avx2@2.47.0`** → 加载模型（GPU offload 拉满）即可。

国内网络慢：加 `-MirrorPrefix https://ghfast.top/`（或其它 gh 代理前缀）加速 GitHub 侧下载；TheRock 走 AMD 自己的 CDN，一般不需要代理。

## 更新后失效了？（防覆盖）

- LM Studio 更新 runtime 时**只新增版本目录**，不会覆盖 2.47.0，正常情况无需任何操作；
- 应用大版本更新若重置了 vendor 库或引擎目录，**重跑一次 `unlock-rocm-gfx1031.ps1` 即可**（幂等，缓存命中则几分钟完成）；
- 不要在 Runtime 管理里对 2.47.0 条目做"删除/修复"。

## 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\rollback-rocm-gfx1031.ps1
```

脚本会把 `ggml-hip.dll` 换回官方原版、从 manifest 移除 gfx103X 目标，并还原被替换的 vendor 原始 DLL（首次打补丁时已自动备份）。

## 原理与踩坑

- [docs/how-it-works.md](docs/how-it-works.md) —— LM Studio runtime 包格式逆向、版本↔llama.cpp commit 对照、DLL 依赖链
- [docs/pitfalls.md](docs/pitfalls.md) —— 完整踩坑记录（12+ 坑：静默退出、ABI 崩溃、BOM、枚举失败、迷惑性 survey 等）

## FAQ

**Q: 和 ZLUDA / DirectML 比呢？**
本方案是原生 HIP 后端，无转译层开销，稳定性和速度都优于 ZLUDA 方案；DirectML 在 llama.cpp 上已无维护。

**Q: 直接用 Vulkan 不好吗？**
能用，但 RDNA2 上 Vulkan 后端明显慢于 HIP（同机同模型实测 +18%，上下文越长差距越大），且 Vulkan 无部分量化内核优化。

**Q: 能用于 2.55.0 / 2.61.0 / 2.64.0 这些更新版本吗？**
不建议直接替换它们的 `ggml-hip.dll`——ggml 后端 ABI 与 llama.cpp commit 强相关，跨版本会崩（实测 b11228→b11511 崩 `ggml_backend_dev_get_props`）。本方案选用 2.47.0 正因为它对应的 b11235 与 b11228 仅差 7 个 commit。

**Q: 安全吗？**
所有二进制均来自 AMD 与 llama.cpp 官方发布渠道（TheRock stable CDN、llama.cpp GitHub release、LM Studio 官方 runtime 目录），本仓库只包含文档与 PowerShell 脚本，可自行审阅。

## English TL;DR

LM Studio's official ROCm runtime excludes RDNA2 mid-range GPUs (gfx1031–1036, e.g. RX 6600/6700 XT). This project unlocks them by combining three official upstream pieces: llama.cpp's official HIP build `ggml-hip.dll` (already ships gfx1030–1036 kernels, built on TheRock), TheRock's ROCm 10.0.0 runtime DLLs (whose `amdhip64_7.dll` actually enumerates these GPUs on Windows, unlike the official HIP SDK), and TheRock's rocBLAS/hipBLASLt gfx103X kernel files dropped into LM Studio's `win-llama-rocm-vendor-v6` vendor package. Runtime **2.47.0** (llama.cpp b11235) is used because its ggml ABI is compatible with b11228 (7 commits apart). Run `scripts/unlock-rocm-gfx1031.ps1`, then select the ROCm 2.47.0 runtime in LM Studio. Tested on RX 6700 XT: **48.1 tok/s (ROCm) vs 40.8 tok/s (Vulkan)** with Qwen3.5-9B Q4_K_M. See [docs/pitfalls.md](docs/pitfalls.md) for the full gory details.

## License

仓库内容（文档与脚本）以 [MIT](LICENSE) 提供。所引用的二进制遵循其上游许可（llama.cpp: MIT；ROCm/TheRock 组件: AMD ROCm 许可）。本项目与 AMD、LM Studio 无关联。
