Target: https://github.com/ROCm/ROCm/issues/5151

Status: drafted for posting upstream; not tracked elsewhere in this repo's
own docs (added 2026-09-08, same commit that first added the ai-stand
module). The workaround this describes (Vulkan/Mesa RADV instead of the
ROCm backend, plus a kernel >=7.0 requirement) is the same fix already
committed as this installation's actual default - see
`ai-stand/compose.amd.yaml`'s `LMSTUDIO_RUNTIME_ID` and the comment there,
and `ensure_amd_kernel()` in `ai-stand/apply.sh`. This file and its sibling
(`ROCm-ROCm-6522.md`) exist purely as upstream-issue reference material,
kept for whoever eventually follows up with ROCm/AMD.

---

Adding a reproduction that matches this exact signature — same chip family, different trigger path, plus an update with a workaround that might help others hitting this.

**Hardware/software:**
- AMD Ryzen AI Max+ PRO 395 (Strix Halo), integrated Radeon 8060S, gfx1151
- Ubuntu 24.04.4 LTS
- LM Studio (llama.cpp backend), model Qwen3.6-35B-A3B GGUF Q8_0 (~22GB), context 262144

**Trigger (on the ROCm backend):** the crash requires an actual inference forward pass — a model can load successfully, report "ready", and idle for 1+ minute without issue. The *first real chat-completion request* reliably triggers:
```
amdgpu: Freeing queue vital buffer 0x<addr>, queue evicted
```
(repeated for several buffers per event), and the process dies shortly after. Reproduced identically on kernel `6.17.0-1032-oem` with ROCm 7.2.4 and ROCm 10.0.0 (`stable.repo.amd.com`, `amdrocm10.0-gfx1151`) — confirmed SONAME-compatible, identical crash on both.

**Ruled out as the sole cause** (each tested live, on kernel 6.17.0-1032-oem unless noted):
- ROCm 7.2.4 vs 10.0.0
- BIOS UMA static VRAM/host-RAM split vs dynamic "Auto" mode
- Host swap enabled vs fully disabled
- `amdgpu.gttsize=131072 ttm.pages_limit=33554432` kernel boot params (raising the GTT/TTM ceiling to the full 128GB physical RAM) — confirmed applied via dmesg (`amdgpu: 131072M of GTT memory ready.`), same crash on first real request regardless
- The gfx1151 VGPR/CWSR sizing bug (#2991 in ROCm/TheRock) — checked directly via `cat /sys/class/kfd/kfd/topology/nodes/*/properties | grep -E "cwsr_size|ctl_stack_size"`, both report sane non-zero values (`cwsr_size 19185664`, `ctl_stack_size 16384`) on the gfx1151 KFD node, so that specific fix is already active here and doesn't appear to be the cause of this crash

**Update — kernel 7.0 and a Vulkan workaround:**
Installed `linux-generic-hwe-24.04` (kernel `7.0.0-31-generic`, available on Ubuntu 24.04 without a full OS upgrade). On this newer kernel, the ROCm backend **still fails**, but with two *different*, non-`queue evicted` failure modes depending on GTT/TTM tuning: with the GTT params above still set, the system-wide OOM killer fires instead (kills the container's own processes, `total-vm` in the tens of GB); with GTT/TTM left at kernel defaults, there's no dmesg error of any kind — LM Studio's own health monitor just silently loses the model 3 times in a row and self-stops (looks like a userspace llama-server-level fault, no kernel/driver trace visible).

Switching the **same** LM Studio image to its **Vulkan (Mesa RADV)** backend instead of ROCm, still on kernel 7.0, at the same model + context 262144: **3 consecutive real completions succeeded** — `finish_reason: stop`, correct generated content, zero dmesg errors, no restarts. Vulkan had also been tried earlier on the old 6.17.0-1032-oem kernel and crashed there too, so it looks like it's specifically the **Vulkan + kernel 7.0 combination** that avoids whatever this is, not Vulkan alone.

**Update 2 (following day) — held up under sustained real-world use:** promoted Vulkan + kernel 7.0 to the permanent runtime config rather than a one-off test. Since then: 7+ hours of continuous uptime under normal real usage with zero `queue evicted`/OOM events, including surviving an unrelated full host reboot (model reload and an in-progress model download both resumed cleanly on their own afterward, no manual intervention needed for the GPU/runtime side) and several deliberate service restarts. Also swapped in a completely different model (a 27B dense model, vs. the original 35B-A3B MoE) under the identical Vulkan + kernel 7.0 config, and it's been equally stable — so this doesn't look specific to one model's memory-access pattern.

Happy to gather more diagnostics (full dmesg, `rocminfo`, llama.cpp server logs, etc.) if useful.
