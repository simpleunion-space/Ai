Target: https://github.com/ROCm/ROCm/issues/6522

Status: drafted for posting upstream; not tracked elsewhere in this repo's
own docs (added 2026-09-08, same commit that first added the ai-stand
module). The workaround this describes (Vulkan/Mesa RADV instead of the
ROCm backend, plus a kernel >=7.0 requirement) is the same fix already
committed as this installation's actual default - see
`ai-stand/compose.amd.yaml`'s `LMSTUDIO_RUNTIME_ID` and the comment there,
and `ensure_amd_kernel()` in `ai-stand/apply.sh`. This file and its sibling
(`ROCm-ROCm-5151.md`) exist purely as upstream-issue reference material,
kept for whoever eventually follows up with ROCm/AMD.

---

Reproducing what looks like the same underlying eviction issue on the same chip, though my case fully crashes the process rather than livelocking — sharing in case the trigger conditions overlap, plus an update below with a workaround that might be worth trying.

**Hardware/software:**
- AMD Ryzen AI Max+ PRO 395 (Strix Halo), integrated Radeon 8060S, gfx1151
- Ubuntu 24.04.4 LTS
- LM Studio (llama.cpp backend), model Qwen3.6-35B-A3B GGUF Q8_0 (~22GB), context 262144 — also an autoregressive text-generation workload, like the report here

**Trigger (ROCm backend, kernel `6.17.0-1032-oem`, ROCm 10.0.0 via `stable.repo.amd.com`):** loading the model alone is fine — it reports "ready" and idles for 1+ minute with no issue. The *first real chat-completion request* reliably triggers:
```
amdgpu: Freeing queue vital buffer 0x<addr>, queue evicted
```
(several buffers per event) in dmesg, and the container/process dies shortly after — Swarm's own restart policy cleanly recovers by falling back to a smaller model, so I haven't directly observed the livelock behavior described here, but the eviction trigger (real inference load, not just model load) matches.

One detail that might be relevant to the concurrent-context-count hypothesis in #6012: my LM Studio setup runs its own container health-monitor that appears to issue a small internal test request shortly after the model reports ready — if that overlaps with the first "real" request rather than running strictly sequentially, it could produce exactly the kind of multi-context pressure that hypothesis points at. Haven't isolated this yet, flagging as a hypothesis, not a confirmed factor.

Ruled out on my end as the sole cause (on the 6.17.0-1032-oem kernel): ROCm 7.2.4 vs 10.0.0 (identical crash on both, confirmed SONAME-compatible), llama.cpp/LM Studio runtime version (2.27.1/2.28.2/2.32.0), BIOS UMA static vs dynamic memory split, host swap on/off, and `amdgpu.gttsize`/`ttm.pages_limit` kernel params raising the GTT ceiling to the full 128GB physical RAM (confirmed applied via dmesg, same crash regardless). Also checked the gfx1151 VGPR/CWSR sizing fix from #2991 in TheRock directly via sysfs (`cwsr_size`/`ctl_stack_size` on the gfx1151 KFD node both report sane non-zero values), so that specific bug's fix is already active here and doesn't appear to be the cause.

**Update — kernel 7.0 changes the failure mode, Vulkan seems to dodge it entirely:**
Installed `linux-generic-hwe-24.04` (kernel `7.0.0-31-generic`, available on 24.04 without a full OS upgrade). ROCm still fails on this kernel too, but differently depending on GTT/TTM tuning: with the GTT params still set, a system-wide OOM killer fires (kills the container's own processes); with GTT/TTM at kernel defaults, there's no kernel/dmesg error at all — LM Studio's own health monitor just silently loses the model 3x and self-stops, which reads more like a userspace fault than a driver one.

Switching to the **Vulkan (Mesa RADV)** backend of the same LM Studio image, still on kernel 7.0, same model + context 262144: 3 consecutive real completions succeeded cleanly (`finish_reason: stop`, correct output, zero dmesg errors, no restarts). I'd tried Vulkan before on the old 6.17.0-1032-oem kernel too and it crashed there identically to ROCm, so this looks like specifically **Vulkan + kernel 7.0** avoiding it, not Vulkan alone — in case it helps others correlate this with the concurrent-queue/context-count angle in #6012, a different userspace API path (Vulkan vs ROCm/HIP) hitting the GPU very differently might be a useful data point either way.

**Update 2 (following day) — held up under sustained real-world use:** made Vulkan + kernel 7.0 the permanent runtime config rather than a one-off test. Since then: 7+ hours of continuous uptime under normal real usage with zero `queue evicted`/livelock/OOM events, including surviving an unrelated full host reboot (the model and an in-progress model download both resumed cleanly on their own afterward) and several deliberate service restarts. Also swapped in a completely different model (a 27B dense model, vs. the original 35B-A3B MoE) under the identical config, equally stable — so this doesn't look specific to one model's access pattern, which may be relevant against the concurrent-context-count hypothesis above.

Happy to share more diagnostics if it helps triage.
