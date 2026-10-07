# specs-jetson/kernel — the MAINLINE-vs-L4T kernel decision

The Jetson Orin family boots one of TWO kernel stacks. `build-jetson-stage4.sh`
selects between them with `--kernel-flavor` (default `mainline`):

## 1. `--kernel-flavor mainline` (DEFAULT — the buildable route)

Mainline/gentoo-sources arm64 kernel: generic `defconfig` + two fragments merged
by `scripts/kconfig/merge_config.sh` (same mechanism as the Frite builder). A third fragment, `luks-crypt.config`, is merged only with `--encrypt-root`, which the builder refuses today (see [../README.md](../README.md)):

| Fragment | Job |
|---|---|
| `hardened-node.config` | Fleet hardening posture (SELinux LSM, audit, ASLR/slab) + the container/k8s data plane + mesh (tun/WireGuard). |
| `tegra234.config` | Tegra234 (Orin) SoC bring-up: TCU console (`ttyTCU0`), SDHCI/NVMe/PCIe, EQOS Ethernet, XUSB, BPMP, SMMU, host1x/tegra-drm. |

The kernel's OWN device tree is shipped (like the Frite): the builder copies
`arch/arm64/boot/dts/nvidia/*.dtb` to `/boot/dtb/nvidia/` and extlinux's `FDT`
line points at the board DTB (Orin Nano Developer Kit:
`nvidia/tegra234-p3768-0000+p3767-0005.dtb`).

**What mainline gives you:** a bootable, hardened arm64 node — serial console,
SD/NVMe storage, Ethernet, USB, thermal — i.e. everything the `edge-ai`,
`backend-gpu` and `omnibus` roles need to JOIN the mesh + cluster and run CPU
workloads, plus basic tegra-drm/simple-framebuffer display for the `desktop`
role.

**What mainline does NOT give you: CUDA.** The integrated Ampere GPU (GA10B) is
driven in L4T by NVIDIA's out-of-tree `nvgpu` driver; upstream support (nouveau/
nova) is not CUDA-capable. On the mainline flavor the `edge-ai` inference
service runs CPU-only (Ollama arm64 works, slowly) until the node is reflashed/
rebuilt on the L4T flavor. The builder prints this caveat loudly.

## 2. `--kernel-flavor l4t` (STUBBED — documented, not automated)

The supported NVIDIA path: the L4T BSP kernel (`nvidia-l4t-*` a.k.a. "Jetson
Linux") + `nvgpu` + the CUDA-on-Tegra userspace. This flavor is deliberately a
**hard error** in the builder today:

* the BSP kernel sources + userspace `.deb`s are behind NVIDIA's developer
  downloads (EULA-gated; not redistributable from this repo, not mirrorable by
  a CI fetch);
* the flash flow is `tegraflash`/`l4t_initrd_flash` in board recovery mode —
  inherently out-of-band (see `../installer/TEGRAFLASH.md`);
* nothing about it can be validated without the physical board.

To pursue it: download "Jetson Linux" (L4T) for your JetPack release from
developer.nvidia.com, unpack `Linux_for_Tegra/`, and follow
`../installer/TEGRAFLASH.md`. The stage4 this builder produces is designed so
the L4T kernel + `nvidia-l4t-*` userspace can be layered onto it on-device.

## Hardware-validation status

EXPERIMENTAL: the mainline fragment set mirrors the proven Frite/RPi5 flow and
the upstream Tegra234 defconfig deltas, but has NOT been booted on a physical
Orin Nano from this repo yet. Treat every image as needs-hardware until the
first boot is confirmed (then update specs-jetson/README.md).
