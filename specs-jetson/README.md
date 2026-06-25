# specs-jetson — NVIDIA Jetson Orin Nano platform (aarch64 + Tegra/L4T)

> **Status: SCAFFOLD.** The cross-architecture **edge-AI capability** (the `edge_ai`
> node role + the `edge-ai` inference service + the mesh/k8s/tailnet exposure + the
> model library + all front-ends) is **done and runs on x86 today** — see
> [docs/EDGE-AI.md](../docs/EDGE-AI.md). This tree holds the **Jetson PLATFORM**
> bring-up, which is hardware-gated (needs a board to validate) and is therefore
> scaffolded here rather than shipped as a working build. Do not assume a working
> `build-jetson-stage4.sh` exists yet.

## What the Jetson adds

The **Jetson Orin Nano Super Developer Kit** (Amazon B0BZJTQ5YP): aarch64 + Ampere
GPU, 8 GB, 67 TOPS, ~$249. It is an **arm64 edge-AI node**: the same `edge_ai` role
and `edge-ai` service that run on the x86 RTX host run here — Ollama has arm64 +
Jetson CUDA images, and the kustomize manifests are arch-portable. The hard part is
the **platform** (kernel + CUDA userspace + board boot), which is L4T (Linux for
Tegra)-based rather than the mainline amd64/RPi5 path.

Deliverables for the device (mirroring the x86/Pi families):
1. a **full-stack** image, a **gpu-host-only** image, and a **desktop** image;
2. the **`edge_ai`** image (GPU + the inference service) — the headline node;
3. all model-library options exposed to the mesh (already done — `edge-ai-models`);
4. the GPU made schedulable for existing voice/video services (already done — the
   `nvidia-device-plugin` + RuntimeClass apply on arm64 GPU nodes too).

## Tree layout to fill (mirror `specs-rpi5/` + the Tegra specifics)

| Subdir | Holds | Jetson-specific notes |
|---|---|---|
| `kernel/` | aarch64 kernel config + fragments | **DECIDE: L4T BSP kernel** (NVIDIA `tegra` kernel + out-of-tree GPU/nvgpu, the supported path) **vs mainline + nouveau-tegra** (freer, weaker GPU/CUDA). CUDA needs the NVIDIA stack. |
| `portage/` | package lists | `packages-edge-ai.list` (the inference node set), CUDA-on-Tegra userspace (NVIDIA L4T `nvidia-l4t-*` equivalents — NOT the desktop `x11-drivers/nvidia-drivers`), arm64 Mesa for the desktop image. |
| `boot/` | bootloader / device tree | Jetson uses **U-Boot + extlinux** + a board **device tree** (Orin Nano DTB); the Orin boot flow (UEFI/cboot) differs from RPi5. |
| `etc/` | platform configs | Tegra-specific `modules-load.d`, power/fan (`nvpmodel`/`jetson_clocks` equivalents), `/dev/dri` + nvgpu device nodes. |
| `installer/` | board installer | flash to NVMe/microSD; the Jetson recovery-mode flash (`tegraflash`) is out-of-band on first provision. |

## Build entry (TODO)

A `build-jetson-stage4.sh` (model it on `build-frite-stage4.sh`, the other arm64
builder) that:
- seeds an arm64 Gentoo stage3 (musl/glibc — glibc for CUDA),
- layers the L4T/Tegra kernel + CUDA userspace + the `edge_ai` role payload,
- reuses the SHARED `specs/cluster` tree (the edge-ai manifests are already arch-
  portable) and the SHARED role machinery in the stage4 builders.

Wire it into all front-ends (a `jetson-*` target in `scripts/build-menu.sh`, a
`jetson` platform in the Studio wizard, a `--platform jetson` entry) once the
platform boots — per the **all-options-in-all-menus** standing rule.

## Cross-references
- Capability (done, x86): [docs/EDGE-AI.md](../docs/EDGE-AI.md)
- Hardware profiles + scanner: `specs-x86/hwprofiles/`
- Memory: `snapdragon-edge-ai-jetson`, `snapdragon-hardware-profiles`,
  `snapdragon-all-options-all-menus`, `snapdragon-selinux-sync`.
