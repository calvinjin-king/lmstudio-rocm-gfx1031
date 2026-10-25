# How it works: LM Studio runtime package format & the unlock mechanism

> This documents the LM Studio 0.4.x runtime package layout ("engine protocol" runtimes, `manifest_version: 4`), reverse-engineered from installed packages. The format is not publicly documented, but packages carry **no signature/hash checks** — files can be replaced freely.

## 1. Directory layout

```
%USERPROFILE%\.lmstudio\extensions\backends\
├─ llama.cpp-win-x86_64-amd-rocm-avx2-<version>\     ← engine package (one folder per version)
│  ├─ backend-manifest.json                         ← core manifest (see below)
│  ├─ display-data.json                             ← display name + per-version release notes (includes the llama.cpp commit!)
│  ├─ engine-protocol-server-artifacts.json         ← files required to launch llama-server.exe
│  ├─ llama.dll / llama-common.dll / llama-server-impl.dll   ← LM Studio's llama.cpp build
│  ├─ ggml-base.dll / ggml-cpu.dll / ggml-hip.dll            ← ggml backends (ggml-hip.dll carries the GPU code objects)
│  ├─ mtmd.dll / ggml_llamacpp.dll
│  └─ llm_engine_rocm.node / liblmstudio_bindings_rocm.node  ← engine protocol bridge (Node addon)
└─ vendor\
   └─ win-llama-rocm-vendor-v6\bin\                 ← ROCm runtime libs (shared by all ROCm engine versions)
      ├─ amdhip64_7.dll / amd_comgr_3.dll / rocm_kpack.dll ...
      ├─ libhipblas.dll / libhipblaslt.dll / rocblas.dll
      └─ rocblas\library\                           ← rocBLAS lazily-loaded per-arch kernel files
```

## 2. Key fields of backend-manifest.json

Example (2.47.0, trimmed):

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

| Field | Purpose | Notes |
|---|---|---|
| `gpu.targets` | Declares supported GPU archs; drives the "compatible" flag in the UI. **Matches the code objects embedded in `ggml-hip.dll` one to one** (verified) | Adding your arch makes the UI show it as compatible; whether it actually runs depends on the binary kernels |
| `vendor_lib_package_names` | References a runtime lib package under `backends\vendor\` | ROCm libs live in the shared vendor folder, not in the engine folder |
| `display-data.json` | Each version's release notes state the llama.cpp version | **Use this to align commits** when swapping/self-building ggml-hip.dll |

## 3. The three missing layers this project fills

```
┌─ Layer 1: HIP enumeration ─────────────────────────────────────┐
│ Official HIP SDK's amdhip64_7.dll cannot enumerate gfx1031 on   │
│ Windows → TheRock 10.0.0 amdhip64_7.dll (+ amd_comgr + kpack)   │
├─ Layer 2: ggml GPU kernels ────────────────────────────────────┐
│ LM Studio's ggml-hip.dll only compiled for its targets list     │
│ → llama.cpp official HIP release ggml-hip.dll                   │
│   (officially ships gfx1030–1036 objects; TheRock-based build)  │
├─ Layer 3: BLAS kernels ────────────────────────────────────────┐
│ vendor's rocblas\library has no gfx1031–1036 GEMM kernels       │
│ → TheRock's 8 DLLs + gfx103X kernel files into the vendor       │
└─────────────────────────────────────────────────────────────────┘
```

Symptoms per missing layer: layer 1 → `No hip devices found`; layer 2 → device visible but kernels missing / ABI crash; layer 3 → process starts but GEMM fails (or an incomplete DLL chain kills the process with a silent 0xC0000135).

## 4. Version selection: why 2.47.0

LM Studio runtime ↔ llama.cpp commit mapping (from `display-data.json`):

| runtime | llama.cpp | Notes |
|---|---|---|
| 2.47.0 | **b11235** | ✅ only 7 commits from b11228 — ggml ABI compatible (tested) |
| 2.55.0 | b11511 | ❌ 283 commits from b11228 — crashes in `ggml_backend_dev_get_props` (tested) |
| 2.61.0 | b11738 | ❌ same risk |
| 2.64.0 | b11840 | ❌ same risk |

The `ggml-hip.dll` comes from llama.cpp's **b11228 official Windows ROCm package** (`llama-b11228-bin-win-rocm-10.0-x64.zip`) — the official TheRock-based HIP release, containing code objects for gfx1030/1031/1032/1034/1035/1036/1100/1101/1102/1150/1151/1200/1201.

To target a newer runtime in the future: self-compile ggml-hip.dll at that runtime's exact commit using the TheRock toolchain (the dist bundles `lib\llvm\bin\clang++.exe`, hipcc, cmake):

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

## 5. Where the TheRock runtime comes from

AMD TheRock (the open-source ROCm build system) publishes stable dists here:

```
https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx103X-all-10.0.0.tar.gz   (1.87 GB)
```

(The `/v2/` gfx103X-all etc. endpoints are pip nightly indexes; stable tarballs live under `stable.repo.amd.com`. Source: [TheRock RELEASES.md](https://github.com/ROCm/TheRock/blob/main/RELEASES.md).)

The script selectively extracts (Windows' bundled bsdtar supports wildcards — no need to unpack the whole thing):

- `bin/amdhip64_7.dll`, `bin/amd_comgr.dll`, `bin/rocm_kpack.dll` (HIP runtime layer)
- `bin/hipblas.dll`, `bin/rocsolver.dll`, `bin/rocblas.dll`, `bin/libhipblaslt.dll`, `bin/origami.dll` (BLAS stack)
- `bin/rocblas/library/*gfx103*` (whole RDNA2-family BLAS kernels, ~23 MB)

The vendor's original `libhipblas.dll` (used by official engines) and `amd_comgr_3.dll` (used by the official amdhip) are kept — the two naming schemes coexist.

## 6. The complete dependency chain (every piece required)

```
llama-server.exe
└─ llama-server-impl.dll ── llama.dll ── ggml-base.dll
                                            └─ ggml-hip.dll (b11228, gfx1030-1036 kernels)
                                                 ├─ amdhip64_7.dll (TheRock) ── amd_comgr.dll + rocm_kpack.dll
                                                 └─ hipblas.dll (TheRock)
                                                      ├─ rocblas.dll (TheRock) ── libhipblaslt.dll ── origami.dll
                                                      └─ rocsolver.dll
(rocblas.dll lazily loads gfxXXXX kernels from bin\rocblas\library\)
```
