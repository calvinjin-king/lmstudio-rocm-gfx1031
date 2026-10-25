# 原理：LM Studio runtime 包格式与解锁机制

> 本文档描述 LM Studio 0.4.x（engine protocol runtimes，清单版本 `manifest_version: 4`）的 runtime 包结构，全部通过逆向本机已安装包得出（官方未公开此格式，但包内无签名/哈希校验，文件可自由替换）。

## 1. 目录结构

```
%USERPROFILE%\.lmstudio\extensions\backends\
├─ llama.cpp-win-x86_64-amd-rocm-avx2-<版本>\        ← 引擎包（每个版本一个独立目录）
│  ├─ backend-manifest.json                         ← 核心清单（见下）
│  ├─ display-data.json                             ← UI 显示名 + 各版本 release notes（含 llama.cpp commit！）
│  ├─ engine-protocol-server-artifacts.json         ← llama-server.exe 启动所需文件清单
│  ├─ llama.dll / llama-common.dll / llama-server-impl.dll   ← LM Studio 定制 llama.cpp
│  ├─ ggml-base.dll / ggml-cpu.dll / ggml-hip.dll            ← ggml 后端（ggml-hip.dll 含 GPU 代码对象）
│  ├─ mtmd.dll / ggml_llamacpp.dll
│  └─ llm_engine_rocm.node / liblmstudio_bindings_rocm.node  ← 引擎协议桥（Node 插件）
└─ vendor\
   └─ win-llama-rocm-vendor-v6\bin\                 ← ROCm 运行库（多引擎包共享）
      ├─ amdhip64_7.dll / amd_comgr_3.dll / rocm_kpack.dll ...
      ├─ libhipblas.dll / libhipblaslt.dll / rocblas.dll
      └─ rocblas\library\                           ← rocBLAS 按架构懒加载的内核文件
```

## 2. backend-manifest.json 关键字段

以 2.47.0 为例（关键字段）：

```json
{
  "version": "2.47.0",
  "engine": "llama.cpp",
  "gpu": {
    "make": "AMD",
    "framework": "ROCm",
    "targets": ["gfx1030", "gfx1100", "gfx1101", "gfx1102", "gfx1151", "gfx1200", "gfx1201"]
  },
  "vendor_lib_package_names": ["win-llama-rocm-vendor-v6"],
  "engine_protocol_server": {
    "runtime_kind": "llama-server",
    "executable_relative_path": "llama-server.exe"
  }
}
```

| 字段 | 作用 | 备注 |
|---|---|---|
| `gpu.targets` | 声明该 runtime 支持的 GPU 架构；决定 UI 是否标记"兼容"。**与 `ggml-hip.dll` 内嵌的代码对象一一对应**（已实测） | 加上自己的架构即可让 UI 显示兼容；能否真正跑起来取决于二进制内核 |
| `vendor_lib_package_names` | 引用 `backends\vendor\` 下的运行库包 | ROCm 库不放在引擎目录，集中在 vendor |
| `display-data.json` | 每个版本的 release notes 注明对应 llama.cpp 版本 | **自编译/换内核时据此对齐 commit** |

## 3. 解锁的三层缺失

```
┌─ 第 1 层：HIP 枚举 ──────────────────────────────────────────┐
│ 官方 HIP SDK 的 amdhip64_7.dll 在 Windows 上枚举不到 gfx1031 │
│ → TheRock 10.0.0 的 amdhip64_7.dll（+ amd_comgr + rocm_kpack）│
├─ 第 2 层：ggml GPU 内核 ─────────────────────────────────────┐
│ LM Studio 官方 ggml-hip.dll 只编了 targets 列表里的架构       │
│ → llama.cpp 官方 HIP release 的 ggml-hip.dll                 │
│   （官方 release 本就带 gfx1030–1036 内核，TheRock 构建）     │
├─ 第 3 层：BLAS 内核 ─────────────────────────────────────────┐
│ vendor 的 rocblas\library 没有 gfx1031–1036 的 GEMM 内核     │
│ → TheRock 的 8 个 DLL + gfx103X 内核文件灌入 vendor          │
└──────────────────────────────────────────────────────────────┘
```

任何一层缺失的症状不同：缺第 1 层 → `No hip devices found`；缺第 2 层 → 设备可见但内核缺失/ABI 崩溃；缺第 3 层 → 进程启动正常但 GEMM 失败（或因 DLL 链不完整直接 0xC0000135 静默退出）。

## 4. 版本选择：为什么是 2.47.0

LLM Studio runtime 版本 ↔ llama.cpp commit 对照（节选自 `display-data.json`）：

| runtime | llama.cpp | 说明 |
|---|---|---|
| 2.47.0 | **b11235** | ✅ 与 b11228 仅差 7 commit，ggml ABI 兼容（实测） |
| 2.55.0 | b11511 | ❌ 与 b11228 差 283 commit，实测崩 `ggml_backend_dev_get_props`（0xC0000005） |
| 2.61.0 | b11738 | ❌ 同上风险 |
| 2.64.0 | b11840 | ❌ 同上风险 |

ggml-hip.dll 的来源是 llama.cpp **b11228 官方 Windows ROCm 包**（`llama-b11228-bin-win-rocm-10.0-x64.zip`）。这是 llama.cpp 官方 release 中基于 TheRock 的 HIP 构建，内含 gfx1030/1031/1032/1034/1035/1036/1100/1101/1102/1150/1151/1200/1201 全部代码对象。

若未来想用更新的 runtime：用 TheRock 工具链（发行包内自带 `lib\llvm\bin\clang++.exe`、hipcc、cmake）在该 runtime 对应的 commit 上自编译：

```bat
cmake -B build-hip -S llama.cpp ^
  -DCMAKE_C_COMPILER=<therock>\lib\llvm\bin\clang.exe ^
  -DCMAKE_CXX_COMPILER=<therock>\lib\llvm\bin\clang++.exe ^
  -DCMAKE_PREFIX_PATH=<therock> ^
  -DGGML_HIP=ON ^
  -DAMDGPU_TARGETS="gfx1031;gfx1032;gfx1034;gfx1035;gfx1036;gfx1030;gfx1100;gfx1101;gfx1102;gfx1151;gfx1200;gfx1201" ^
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-hip --target ggml-hip --config Release
```

## 5. TheRock 运行库从哪来

AMD TheRock（开源 ROCm 构建系统）的 stable 发行包索引：

```
https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx103X-all-10.0.0.tar.gz   (1.87 GB)
```

（频道路由：`/v2/` 下的 gfx103X-all 等是 pip nightly 索引；stable tarball 在 `stable.repo.amd.com`。来源见 [TheRock RELEASES.md](https://github.com/ROCm/TheRock/blob/main/RELEASES.md)。）

脚本从中选择性提取（Windows 自带 bsdtar 支持通配符，无需解压全包）：

- `bin/amdhip64_7.dll`、`bin/amd_comgr.dll`、`bin/rocm_kpack.dll`（HIP 运行层）
- `bin/hipblas.dll`、`bin/rocsolver.dll`、`bin/rocblas.dll`、`bin/libhipblaslt.dll`、`bin/origami.dll`（BLAS 栈）
- `bin/rocblas/library/*gfx103*`（RDNA2 全家族 BLAS 内核，~23 MB）

保留 vendor 原有的 `libhipblas.dll`（官方引擎用）与 `amd_comgr_3.dll`（官方 amdhip 用），两套命名共存。

## 6. 完整依赖链（全部必须就位）

```
llama-server.exe
└─ llama-server-impl.dll ── llama.dll ── ggml-base.dll
                                            └─ ggml-hip.dll（b11228, 含 gfx1030-1036 内核）
                                                 ├─ amdhip64_7.dll (TheRock) ── amd_comgr.dll + rocm_kpack.dll
                                                 └─ hipblas.dll (TheRock)
                                                      ├─ rocblas.dll (TheRock) ── libhipblaslt.dll ── origami.dll
                                                      └─ rocsolver.dll
（rocblas.dll 按架构从 bin\rocblas\library\ 懒加载 gfxXXXX 内核）
```
