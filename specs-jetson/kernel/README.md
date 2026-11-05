# specs-jetson/kernel — the MAINLINE-vs-L4T kernel decision

The Jetson Orin family boots one of TWO kernel stacks. `build-jetson-stage4.sh`
selects one with `--kernel-flavor` (default `mainline`):

## 1. `--kernel-flavor mainline` (DEFAULT — the buildable route)

Mainline/gentoo-sources arm64 kernel: generic `defconfig` + two fragments merged
by `scripts/kconfig/merge_config.sh` (same mechanism as the Frite builder). A third fragment, `luks-crypt.config`, is merged only with `--encrypt-root`, which the builder refuses today (see [../README.md](../README.md)):

| Fragment | Job |
|---|---|
| `hardened-node.config` | Fleet hardening posture (SELinux LSM, audit, ASLR/slab) + the container/k8s data plane + mesh (tun/WireGuard). |
| `tegra234.config` | Tegra234 (Orin) SoC bring-up: TCU console (`ttyTCU0`), SDHCI/NVMe/PCIe, EQOS Ethernet, XUSB, BPMP, SMMU, host1x/tegra-drm. |

The kernel's OWN device tree is shipped, as on the Frite. The builder copies
`arch/arm64/boot/dts/nvidia/*.dtb` to `/boot/dtb/nvidia/`, and extlinux's `FDT`
line points at the board DTB (Orin Nano Developer Kit:
`nvidia/tegra234-p3768-0000+p3767-0005.dtb`).

**What mainline gives you:** a bootable, hardened arm64 node with serial
console, SD/NVMe storage, Ethernet, USB and thermal. That is everything the
`edge-ai`, `backend-gpu` and `omnibus` roles need to JOIN the mesh and cluster
and run CPU workloads. The `desktop` role gets basic tegra-drm/simple-framebuffer
display.

**What mainline does NOT give you: CUDA.** In L4T, NVIDIA's out-of-tree `nvgpu`
driver runs the integrated Ampere GPU (GA10B). Upstream support (nouveau/nova)
is not CUDA-capable. On the mainline flavor the `edge-ai` inference service
runs CPU-only (Ollama arm64 works, slowly) until you reflash or rebuild the
node on the L4T flavor. The builder prints this caveat loudly.

## 2. `--kernel-flavor l4t` (STUBBED — documented, not automated)

The supported NVIDIA path: the L4T BSP kernel (`nvidia-l4t-*`, a.k.a. "Jetson
Linux") + `nvgpu` + the CUDA-on-Tegra userspace. The builder makes this flavor a
**hard error** today, for three reasons:

* The BSP kernel sources and userspace `.deb`s sit behind NVIDIA's developer
  downloads. They are EULA-gated, not redistributable from this repo, and a CI
  fetch cannot mirror them.
* The flash flow is `tegraflash`/`l4t_initrd_flash` in board recovery mode,
  which is out-of-band (see `../installer/TEGRAFLASH.md`).
* Nothing about it can be validated without the physical board.

To pursue it: download "Jetson Linux" (L4T) for your JetPack release from
developer.nvidia.com, unpack `Linux_for_Tegra/`, and follow
`../installer/TEGRAFLASH.md`. The stage4 is built so that the L4T kernel and the
`nvidia-l4t-*` userspace can be layered onto it on the device.

## Hardware-validation status

EXPERIMENTAL: the mainline fragment set mirrors the proven Frite/RPi5 flow and
the upstream Tegra234 defconfig deltas. It has NOT been booted on a physical
Orin Nano from this repo. Treat every image as needing hardware until the first
boot is confirmed (then update specs-jetson/README.md).

## Emulation under the QEMU runner: serial only (deliberate)

The containerised QEMU runner opens desktop images through a SPICE door and a
viewer whose window size the guest follows — but only when the guest kernel
carries `CONFIG_DRM_VIRTIO_GPU` + `CONFIG_VIRTIO_INPUT` + `CONFIG_INPUT_UINPUT`
(see docs/CLIENT-IMAGES.md, "Emulated desktop display"). The Jetson fragments are
left WITHOUT them on purpose:

* the mainline flavor's display is tegra-drm / simple-framebuffer, the board's own
  silicon; nothing in `tegra234.config` is virt-aware, and the kernel is tuned
  for a Tegra234 DTB that QEMU's `virt` machine does not provide;
* the L4T flavor is a hard error today, so there is no second kernel to equip;
* no Jetson image has ever been booted, on hardware or in QEMU, from this repo —
  adding a display stack here would advertise a capability nobody can verify.

So under the runner a Jetson desktop image is **serial only**: the runner attaches
no display device, the device record carries no `display_port`, and the UI says
`serial only: kernel lacks virtio-gpu` rather than offering a window that would stay
black. `tests/scripts/test-virtual-display-kernel.sh` pins this: the Jetson row of
the board table is `serial only` and its fragments must NOT claim virtio-gpu until
someone boots one and flips the row.
