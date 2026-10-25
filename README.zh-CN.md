# LM Studio ROCm 解锁：AMD RDNA2（gfx1030–1036）全系支持（中文说明）

> **English documentation: [README.md](README.md)**（主文档，更新更及时）
> 本页为中文摘要。文档（[docs/](docs/)）与脚本输出为英文。

给 **LM Studio** 的 ROCm（HIP）runtime 解锁 **RDNA2 中低端显卡**——RX 6600 / 6650 XT / 6700 XT / 6750 XT / 6500 XT / 6400 等。无需改驱动、无需重装系统、无需自编译，全部使用官方上游二进制组合。

官方 LM Studio 的 ROCm runtime 只列出 `gfx1030` 及更新的架构，RDNA2 的 `gfx1031`–`gfx1036` 被默认排除——实际上 AMD HIP 运行时**完全可以在这些卡上工作**（[ROCm #2770](https://github.com/ROCm/legacy-rocm-build/issues/2770)），缺的只是三样东西：

1. **HIP 枚举层**：官方 HIP SDK 的运行库在 Windows 上枚举不到 gfx1031（报 `No hip devices found`）→ 换用 AMD [TheRock](https://github.com/ROCm/TheRock) 社区发行版的 `amdhip64_7.dll`（ROCm 10.0.0）
2. **GPU 内核层**：LM Studio 引擎的 `ggml-hip.dll` 没有为 gfx1031 编译内核 → 换用 llama.cpp 官方 HIP release 的 `ggml-hip.dll`（官方 release 本来就带 gfx1030–1036 内核，基于 TheRock 构建）
3. **BLAS 库层**：vendor 里的 rocBLAS 没有 gfx1031 的 GEMM 内核 → 灌入 TheRock 的 rocBLAS/hipBLASLt 及 gfx103X 内核文件

## 实测成绩

| 环境 | ROCm (本方案) | Vulkan | 提升 |
|---|---|---|---|
| RX 6700 XT 12GB · LM Studio 0.4.26 · Qwen3.5-9B Q4_K_M · 同提示词 | **48.13 tok/s** | 40.77 tok/s | **+18%** |
| RX 6700 XT · 300 token 生成测试 | 43.4 tok/s | — | — |

测试机：Windows 10 19045 · Adrenalin 32.0.21045.16010 · runtime 2.47.0（llama.cpp b11235）。

## 支持显卡

| 架构 | 显卡（举例） | 状态 |
|---|---|---|
| gfx1030 | RX 6800 / 6900 XT | 官方本就支持 |
| **gfx1031** | **RX 6700 XT / 6700 / 6650 XT** | ✅ **本方案实测** |
| gfx1032 | RX 6600 / 6600 XT / 6500 XT | 同源可用* |
| gfx1034/1035/1036 | RX 6400 等 | 同源可用* |

\* llama.cpp b11228 HIP 构建内含全部 gfx1030–1036 代码对象，TheRock gfx103X 运行库与 BLAS 内核亦覆盖全家族；除 gfx1031 外未逐一实测，欢迎反馈。

## 快速开始（一键脚本）

前提：Windows 10/11 x64 · LM Studio 0.3.9+（建议 0.4.x，实测 0.4.26）· AMD 官方驱动 · 约 2.5 GB 下载量 · 磁盘 ≥ 10 GB。

**先退出 LM Studio**，然后：

```powershell
git clone https://github.com/calvinjin-king/lmstudio-rocm-gfx1031.git
cd lmstudio-rocm-gfx1031\scripts
powershell -ExecutionPolicy Bypass -File .\unlock-rocm-gfx1031.ps1
```

脚本自动完成：安装 runtime 2.47.0（`lms runtime get`）→ 下载 [llama.cpp b11228 官方 ROCm 包](https://github.com/ggml-org/llama.cpp/releases/download/b11228/llama-b11228-bin-win-rocm-10.0-x64.zip)（245 MB）提取 `ggml-hip.dll` → 下载 [TheRock gfx103X stable 发行包](https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx103X-all-10.0.0.tar.gz)（1.87 GB，AMD 官方 CDN）选择性提取 8 个运行库 DLL 和 gfx103X BLAS 内核 → 打补丁 → 校验。下载缓存在 `%LOCALAPPDATA%\lmstudio-rocm-gfx1031-cache`，支持断点续跑，脚本幂等。

完成后启动 LM Studio → **Runtime 里选择 `llama.cpp-win-x86_64-amd-rocm-avx2@2.47.0`** → 加载模型（GPU offload 拉满）即可。

国内网络：GitHub 侧下载可加 `-MirrorPrefix https://ghfast.top/`（或其它 gh 代理前缀）；TheRock 走 AMD 自己的 CDN，一般无需代理。

## 更新后失效？（防覆盖）

- runtime 更新**只新增版本目录**，不会覆盖 2.47.0，正常无需操作；
- 应用大版本更新若重置 vendor 或改了目录名，**重跑一次 unlock 脚本即可**（幂等，缓存命中几分钟完成）；
- 不要在 Runtime 管理里对 2.47.0 条目"删除/修复"。

## 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\rollback-rocm-gfx1031.ps1
```

自动还原 `ggml-hip.dll` 原版、移除 manifest 里的 gfx103X 目标、还原被替换的 vendor 原始 DLL（首次打补丁时已自动备份）。

## 原理与踩坑（英文）

- [docs/how-it-works.md](docs/how-it-works.md) —— runtime 包格式逆向、版本↔commit 对照、DLL 依赖链
- [docs/pitfalls.md](docs/pitfalls.md) —— 13 条踩坑全记录（静默 0xC0000135、ggml ABI 崩溃、枚举失败、隐藏的 origami.dll、无 BOM JSON 等）

## FAQ

**Q: 和 ZLUDA / DirectML 比呢？** 原生 HIP 后端，无转译层开销，优于 ZLUDA；llama.cpp 的 DirectML 已无维护。

**Q: 直接用 Vulkan 不好吗？** 能用，但 RDNA2 上 HIP 明显更快（同机同模型 +18%，上下文越长差距越大）。

**Q: 能用在 2.55.0 / 2.61.0 / 2.64.0 吗？** 不建议直接换它们的 `ggml-hip.dll`——ggml 后端 ABI 与 llama.cpp commit 强相关，跨版本崩（实测 b11228→b11511 崩）。选 2.47.0 正因为 b11235 与 b11228 仅差 7 commit。

**Q: 安全吗？** 所有二进制均来自 AMD 与 llama.cpp 官方渠道；本仓库只含文档与脚本，可自行审阅。

## 许可

仓库内容以 MIT 提供；引用的二进制遵循上游许可（llama.cpp: MIT；ROCm/TheRock: AMD ROCm 许可）。与 AMD、LM Studio 无关联。
