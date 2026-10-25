# Every pitfall we hit

> The complete list of traps encountered while building this unlock on 2026-10-25, in the order they appeared. Each one: **symptom → cause → fix**. If you're doing this by hand and something breaks, chances are it's on this list.

## 1. `HSA_OVERRIDE_GFX_VERSION` does nothing on Windows

- **Symptom**: following Linux tutorials, setting `HSA_OVERRIDE_GFX_VERSION=10.3.0` to make a gfx1031 GPU masquerade as gfx1030 and run gfx1030 kernels — nothing happens.
- **Cause**: that env var is a Linux HSA runtime mechanism. The Windows HIP runtime ignores it entirely.
- **Conclusion**: on Windows every layer must get **native gfx1031 code objects**. There is no masquerade shortcut.

## 2. The official HIP SDK runtime cannot enumerate gfx1031

- **Symptom**: the engine starts fine (DLLs all load), but reports `Error trying to query ROCm gpus: No hip devices found!`.
- **Cause**: LM Studio's vendored `amdhip64_7.dll` (official HIP SDK 10.0.3665) filters device enumeration on Windows / depends on newer driver interfaces; gfx1031 is not on the official support list. **TheRock's `amdhip64_7.dll` (10.0.0) enumerates gfx1031 just fine.**
- **Fix**: swap the vendor `amdhip64_7.dll` for TheRock's build.
- **Watch out**: TheRock's amdhip needs `amd_comgr.dll` (note the name — the official one is `amd_comgr_3.dll`) and `rocm_kpack.dll` alongside it.

## 3. The TheRock dependency chain: one missing DLL = silent exit with zero logs

- **Symptom**: process exits with `0xC0000135` (STATUS_DLL_NOT_FOUND) and **completely empty stdout/stderr** — log files of 0 bytes.
- **Cause**: TheRock's BLAS stack is a long dependency chain; any missing DLL kills the process inside the Windows loader, before `main`:

  ```
  ggml-hip.dll
    ├─ amdhip64_7.dll ── amd_comgr.dll + rocm_kpack.dll
    └─ hipblas.dll
         ├─ rocblas.dll ── libhipblaslt.dll ── origami.dll   ← the easiest one to miss!
         └─ rocsolver.dll
  ```

  `origami.dll` is the heuristic-engine library that newer hipBLASLt builds split out — it's barely documented and the nastiest one to discover.
- **Fix**: ship the whole chain at once (8 DLLs: amdhip64_7, amd_comgr, rocm_kpack, hipblas, rocsolver, rocblas, libhipblaslt, origami).
- **Diagnostic technique**: parse the PE import table (read the PE header → DataDirectory[1] → walk the IMAGE_IMPORT_DESCRIPTORs for names), then look each name up in "engine dir / vendor dir / System32". The first name missing from all three is your culprit. String-searching DLL names is only a *hint* (it turns up red herrings like `amdhip64.dll`), **not** the actual import table.

## 4. Survey passes, model load always crashes — the misleading case

- **Symptom**: `lms runtime survey` happily shows `AMD Radeon RX 6700 XT (ROCm, Discrete)`, but actually loading a model always fails.
- **Cause**: the survey only enumerates devices (via amdhip) and **never touches BLAS**. A broken BLAS chain only shows up when a real GEMM runs.
- **Lesson**: survey success ≠ working runtime. Always validate with a real model load.

## 5. ggml backend ABI: 283 commits apart = crash, 7 commits apart = works

- **Symptom**: every DLL loads, model loading begins, then `0xC0000005` (access violation) inside `ggml_backend_dev_get_props()`.
- **Cause**: `ggml-hip.dll` and the engine's `ggml-base.dll` / `llama.dll` must come from the **same llama.cpp commit** (or extremely close). The ggml backend registration interface is a C ABI, but struct layouts drift between commits: tested — **b11228 → b11511 (283 commits) crashes**, **b11228 → b11235 (7 commits) works**.
- **Fix**: check which llama.cpp commit each LM Studio runtime version corresponds to (every backend folder's `display-data.json` spells it out in `releaseNotes`: 2.47.0 = b11235, 2.55.0 = b11511, 2.64.0 = b11840), then pick the runtime closest to the ggml-hip.dll you can obtain.
- **Fallback**: self-compile ggml-hip.dll for the target commit using the TheRock toolchain (`lib\llvm\bin\clang++.exe` + hipcc + cmake, `-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1031;...`). This project dodged compiling by using a stock binary 7 commits away.

## 6. Don't use Ollama's DLLs (community scar tissue)

- **Symptom**: following older guides and dropping in Ollama's `rocm_v5.7` / `rocm_v6.1` runner DLLs → load failures or output that is all garbage.
- **Cause**: Ollama ≥0.4 builds are incompatible with LM Studio's engine protocol (the [likelovewant wiki](https://github.com/likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU/wiki) warns about this explicitly).
- **Conclusion**: use llama.cpp official releases (this project) or self-compile.

## 7. The manifest JSON must be BOM-free

- **Symptom**: after writing `backend-manifest.json` with PowerShell `Set-Content -Encoding UTF8`, the runtime may vanish from the list or misbehave.
- **Cause**: Windows PowerShell 5.1's `-Encoding UTF8` writes **UTF-8 with BOM** (`EF BB BF`), and LM Studio (Node/Electron) JSON parsing chokes on it.
- **Fix**: `[IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))`.
- **Lesson**: after editing any JSON, hex-inspect the first three bytes.

## 8. The dual-name DLL trap

- **What happens**: ggml-hip.dll built on the official HIP SDK imports `libhipblas.dll`, while llama.cpp's official HIP release (built on TheRock) imports `hipblas.dll` — same library, two names.
- **Fix**: keep both names in the vendor folder (official `libhipblas.dll` serves official engines; TheRock `hipblas.dll` serves the b11228 kernel). They end up sharing the same `rocblas.dll` instance — no conflict at the C ABI level.

## 9. rocBLAS kernels are lazy-loaded per architecture

- **What happens**: `rocblas.dll` loads fine, but GEMM calls fail at runtime.
- **Cause**: the files in `rocblas\library\` (`Kernels.so-000-gfxXXXX.hsaco`, `TensileLibrary_lazy_gfxXXXX.dat`, …) are loaded lazily per GPU arch. The official vendor ships gfx906/1030/1100–1102/1150–1151/1200–1201 only — **no gfx1031–1036**.
- **Fix**: drop TheRock's gfx103X kernel files in (≈142 files per arch, ~23 MB total) into `bin\rocblas\library\`. Official and TheRock are both ROCm 10 generation — the file formats interoperate, so merging directories works.

## 10. All three layers must be the same ROCm generation

- **Rule**: the ROCm version `ggml-hip.dll` was linked against ↔ the vendor runtime version ↔ the kernel file version. All on ROCm 10.0.x: good. Mixing 5.7/6.1-era DLLs with 10.0 libs: guaranteed failure.
- **Evidence**: this project pairs llama.cpp b11228 + TheRock 10.0.0 + LM Studio vendor v6 (10.0.3665) — all generation 10.

## 11. How LM Studio runtime updates work (anti-overwrite)

- **Fact**: `lms runtime update` / app updates **add new version folders** (2.55.0 / 2.61.0 / 2.64.0 / 2.47.0 coexist on our machine); old folders are not overwritten. A folder outside the official catalog is invisible to the updater.
- **Risks**: ① manually running `lms runtime remove` deletes the patch; ② a major app update may reset the vendor; ③ folder naming rules may change.
- **Mitigation**: an idempotent re-apply script (every patch action is repeatable) + cached downloads (a re-apply takes minutes).

## 12. Diagnostic order cheat sheet

```
1. lms runtime survey          → HIP enumeration layer OK? (amdhip + comgr + kpack)
2. run llama-server.exe directly → BLAS dependency chain complete? (PATH → vendor bin)
   ├─ 0xC0000135, instant exit, no output → missing DLL; parse PE imports to find it
   └─ 0xC0000005 inside ggml_*            → ggml ABI mismatch; swap ggml-hip.dll to the same commit
3. real model load + generation  → BLAS kernels present? (gfxXXXX.hsaco)
```

## 13. Misc traps (for script authors)

- In Windows PowerShell 5.1, `robocopy` on a ~947 MB DLL can stall for ages under real-time AV scanning — prefer `Copy-Item` and be patient;
- In cmd, `%var%` inside `set X=...&& echo %X%` on the **same line** does not expand (an undefined variable stays as the literal `%X%`) — split lines or use PowerShell for everything;
- `tar.exe` (bsdtar, bundled with Windows) supports wildcard-based selective extraction — the right tool for pulling ~300 MB out of a 1.87 GB tar.gz;
- Some `lms` subcommands require the LM Studio app to be running; automation scripts need to handle that.
