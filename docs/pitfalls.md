# 踩坑全记录

> 本方案在 2026-10-25 的完整实战中踩过的所有坑，按"出现顺序"排列。每条含**症状 → 原因 → 解法**。如果你在自己动手时卡住，大概率能在这里对号入座。

## 1. `HSA_OVERRIDE_GFX_VERSION` 在 Windows 上无效

- **症状**：按 Linux 教程设置环境变量 `HSA_OVERRIDE_GFX_VERSION=10.3.0`，想让 gfx1031 伪装成 gfx1030 跑 gfx1030 内核，完全无效。
- **原因**：这个环境变量是 Linux 上 HSA 运行时的机制，Windows 的 HIP 运行时根本不看它。
- **结论**：Windows 上必须让每一层都拿到**原生 gfx1031 代码对象**，没有"伪装"捷径。

## 2. 官方 HIP SDK 的运行库枚举不到 gfx1031

- **症状**：引擎能启动（说明 DLL 加载正常），但报 `Error trying to query ROCm gpus: No hip devices found!`。
- **原因**：LM Studio vendor 里的 `amdhip64_7.dll`（官方 HIP SDK 10.0.3665）在 Windows 上对设备枚举做了严格过滤/依赖更新的驱动接口；gfx1031 不在官方支持列表里。而 **TheRock 发行版的 `amdhip64_7.dll`（10.0.0）能正常枚举** gfx1031。
- **解法**：把 vendor 里的 `amdhip64_7.dll` 换成 TheRock 的版本。
- **注意**：TheRock 的 amdhip 依赖 `amd_comgr.dll`（注意名字，官方版叫 `amd_comgr_3.dll`）和 `rocm_kpack.dll`，必须一并就位。

## 3. TheRock 依赖链：缺一个 DLL 就"静默退出"，无任何日志

- **症状**：进程以 `0xC0000135`（STATUS_DLL_NOT_FOUND）退出，**stdout/stderr 全空**，日志文件 0 字节。
- **原因**：TheRock 的 BLAS 栈是长依赖链，任何一个 DLL 缺失，Windows 加载器在 main 之前就终止进程：

  ```
  ggml-hip.dll
    ├─ amdhip64_7.dll ── amd_comgr.dll + rocm_kpack.dll
    └─ hipblas.dll
         ├─ rocblas.dll ── libhipblaslt.dll ── origami.dll   ← 最容易漏的隐藏依赖！
         └─ rocsolver.dll
  ```

  其中 `origami.dll` 是新版 hipBLASLt 拆分出来的启发式引擎库，搜索资料几乎查不到，是最阴的一个。
- **解法**：整链一起补齐（共 8 个 DLL：amdhip64_7、amd_comgr、rocm_kpack、hipblas、rocsolver、rocblas、libhipblaslt、origami）。
- **诊断技巧**：解析 PE 导入表（读 PE 头 → DataDirectory[1] → 逐个 IMAGE_IMPORT_DESCRIPTOR 拿名字），对每个导入名在"引擎目录 / vendor 目录 / System32"三处找，第一个三处都没有的就是缺的那个。字符串搜索 DLL 名只能当线索（会有 `amdhip64.dll` 这种红鲱鱼），**不能当结论**。

## 4. survey 能过、加载必崩的"迷惑现象"

- **症状**：`lms runtime survey` 显示 `AMD Radeon RX 6700 XT (ROCm, Discrete)` 一切正常，但真正加载模型必挂。
- **原因**：survey 只做设备枚举（走 amdhip），**不触发 BLAS**。BLAS 链断裂只在真正分配 GEMM 时暴露。
- **教训**：survey 通过 ≠ runtime 可用，必须真实加载模型验证。

## 5. ggml 后端 ABI：差 283 个 commit 崩溃，差 7 个 commit 兼容

- **症状**：DLL 全部加载成功、模型开始加载，然后 `0xC0000005`（访问违例）崩在 `ggml_backend_dev_get_props()`。
- **原因**：`ggml-hip.dll` 与引擎里的 `ggml-base.dll` / `llama.dll` 必须是**同一 llama.cpp commit**（或极近）。ggml 的后端注册接口是 C ABI，但结构体布局在 commit 间会变：实测 **b11228 → b11511（差 283 commit）崩**，**b11228 → b11235（差 7 commit）兼容**。
- **解法**：查 LM Studio 各 runtime 版本对应哪个 llama.cpp commit（每个 backend 目录的 `display-data.json` 里 `releaseNotes` 写得清清楚楚，如 2.47.0 = b11235、2.55.0 = b11511、2.64.0 = b11840），选与可获得的 ggml-hip.dll 最接近的版本。
- **备用方案**：用 TheRock 自带工具链（`lib\llvm\bin\clang++.exe` + hipcc + cmake）自编译目标 commit 的 ggml-hip.dll，`-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1031;...`。本方案用 7-commit 接近的现成二进制绕过了编译。

## 6. 别用 Ollama 的 DLL（社区血泪教训）

- **症状**：按老教程用 Ollama 的 `rocm_v5.7` / `rocm_v6.1` runner DLL 补窟窿，要么加载失败要么输出全是乱码。
- **原因**：Ollama ≥0.4 的构建与 LM Studio 的引擎协议不兼容（[likelovewant wiki](https://github.com/likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU/wiki) 明确警告）。
- **结论**：用 llama.cpp 官方 release（本方案）或自编译。

## 7. manifest JSON 带 BOM 会出问题

- **症状**：用 PowerShell `Set-Content -Encoding UTF8` 写 `backend-manifest.json` 后，runtime 可能从列表里消失或行为异常。
- **原因**：Windows PowerShell 5.1 的 `-Encoding UTF8` 会写 **UTF-8 with BOM**（`EF BB BF`），而 LM Studio（Node/Electron）解析 JSON 对 BOM 敏感。
- **解法**：`[IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))`。
- **教训**：改完任何 JSON 后用十六进制看一眼前三个字节。

## 8. DLL 导入名的"双名陷阱"

- **现象**：官方 HIP SDK 构建的 ggml-hip.dll 导入 `libhipblas.dll`，而 llama.cpp 官方 HIP release（TheRock 构建）的 ggml-hip.dll 导入 `hipblas.dll`——同一个库两个名字。
- **解法**：vendor 里两个名字共存（官方 `libhipblas.dll` 保留给官方引擎，TheRock `hipblas.dll` 供 b11228 内核用）。它们会共享同一个 `rocblas.dll` 实例，C ABI 层面无冲突。

## 9. rocblas 内核文件是"按架构懒加载"的

- **现象**：`rocblas.dll` 存在且能加载，GEMM 调用时才报错。
- **原因**：`rocblas\library\` 目录下的 `Kernels.so-000-gfxXXXX.hsaco`、`TensileLibrary_lazy_gfxXXXX.dat` 等文件按 GPU 架构懒加载。官方 vendor 只有 gfx906/1030/1100–1102/1150–1151/1200–1201，**没有 gfx1031–1036**。
- **解法**：把 TheRock 的 gfx103X 内核文件（每个架构约 142 个，共 ~23 MB）放进 `bin\rocblas\library\`。官方与 TheRock 同为 ROCm 10 代，文件格式互相兼容，直接合并目录即可。

## 10. 版本代际必须三方一致

- **规律**：`ggml-hip.dll` 构建时所链接的 ROCm 版本 ↔ vendor 运行库版本 ↔ 内核文件版本。三者同为 ROCm 10.0.x 时兼容良好；跨大版本（5.7/6.1 时代的 DLL 混 10.0 的库）必然失败。
- **佐证**：本方案 llama.cpp b11228 与 TheRock 10.0.0、LM Studio vendor v6（10.0.3665）同为 10 代。

## 11. LM Studio runtime 的更新机制（防覆盖）

- **事实**：`lms runtime update` / 应用更新是**新增版本目录**（本机 2.55.0 / 2.61.0 / 2.64.0 / 2.47.0 并存），不会覆盖旧版本目录；自定义补丁的目录不在官方 catalog 里，更新器根本不认它。
- **风险点**：① 手动 `lms runtime remove` 会删补丁；② 应用大版本更新可能重置 vendor；③ 目录名规则变化。
- **对策**：幂等重打脚本（所有补丁动作可重复执行）+ 缓存下载物（重打只需几分钟）。

## 12. 诊断顺序速查

```
1. lms runtime survey          → HIP 枚举层是否正常（amdhip + comgr + kpack）
2. 直接运行 llama-server.exe    → BLAS 依赖链是否完整（配 PATH 指向 vendor bin）
   ├─ 0xC0000135 秒退无日志     → 缺 DLL，解析 PE 导入表定位
   └─ 0xC0000005 崩在 ggml_*    → ggml ABI 不匹配，换同 commit 的 ggml-hip.dll
3. 真实加载模型 + 生成          → BLAS 内核是否存在（gfxXXXX.hsaco）
```

## 13. 杂项坑（自动化脚本作者向）

- Windows PowerShell 5.1 里 `robocopy` 复制 947MB 级 DLL 遇杀软实时扫描会长时间卡住，用 `Copy-Item` 并耐心等待；
- cmd 的 `%var%` 在 `set X=...&& echo %X%` 同一行**不展开**（未定义时保留字面量 `%X%`），写批处理要么分开两行，要么全用 PowerShell；
- `tar.exe`（Windows 自带 bsdtar）支持通配符选择性解压，是从 1.87GB tar.gz 里抠几十个文件的正确工具；
- LM Studio 的 CLI（`lms`）在应用未运行时部分子命令不可用，自动化脚本要处理这种情况。
