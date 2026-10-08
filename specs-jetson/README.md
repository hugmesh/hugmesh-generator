# specs-jetson — NVIDIA Jetson Orin Nano platform (aarch64 + Tegra/L4T)

> **Status: EXPERIMENTAL BUILDABLE (hardware validation pending).** The
> cross-architecture **edge-AI capability** (the `edge-ai` node role, the
> `edge-ai` inference service, the mesh/k8s/tailnet exposure, the model
> library and all front-ends) is **done and runs on x86 today**. See
> [docs/EDGE-AI.md](../docs/EDGE-AI.md). This tree also carries a working
> **`build-jetson-stage4.sh`**. All 8 role/env combinations pass
> `--print-plan`, and the mainline-kernel image assembly is written end to end,
> mirroring the proven RPi5/Frite cross flow. But **no physical Orin has booted
> an image from this repo**, so every real build prints a LOUD EXPERIMENTAL
> banner until first boot is confirmed on hardware.

## What the Jetson adds

The **Jetson Orin Nano Super Developer Kit** (Amazon B0BZJTQ5YP): aarch64 plus an
Ampere GPU, 8 GB, 67 TOPS, about $249. It is an **arm64 edge-AI node**. The same
`edge-ai` role and `edge-ai` service that run on the x86 RTX host run here:
Ollama has arm64 and Jetson CUDA images, and the kustomize manifests are
arch-portable. The hard part is the **platform** (kernel, CUDA userspace, board
boot). It is based on L4T (Linux for Tegra), not on the mainline amd64/RPi5 path.

## Build entry (IMPLEMENTED — `build-jetson-stage4.sh`)

```sh
./build-jetson-stage4.sh --role edge-ai            # the headline (DEFAULT)
./build-jetson-stage4.sh --role omnibus --env prod # full stack on one Orin
./build-jetson-stage4.sh --role desktop            # arm64 client desktop
./build-jetson-stage4.sh --role backend-gpu           # GPU worker, no inference svc
./build-jetson-stage4.sh --role edge-ai --print-plan   # dry-run plan (no root)
```

Roles (× `--env test|prod`, all 8 combos pass `--print-plan` today):

| Role | What it is | k8s | edge-ai service |
|---|---|---|---|
| `edge-ai` (default, headline) | GPU inference node | worker | yes |
| `backend-gpu` | GPU worker (backend-gpu analogue) | worker | no |
| `omnibus` (`full` is an accepted old spelling) | full stack on one Orin | single-node + headscale | yes |
| `desktop` | arm64 client desktop (lean LXDE) | none | no |

The builder is modeled on `build-frite-stage4.sh`, the other arm64 builder. It:
- seeds an arm64 **glibc** Gentoo stage3. Glibc is deliberate, because CUDA links glibc.
- layers the kernel and the role payload. The shared flags are `--jobs`,
  `--work-dir`, `--compress`, `--resume`, `--permit-root-login`, `--skip-mesh`,
  `--skip-tailscale`, `--img-size` and `--grow`.
- reuses the SHARED `specs/` mesh, provisioning and sshd plumbing. Cluster roles
  also reuse the SHARED `specs/cluster` GitOps tree, because the edge-ai
  manifests are arch-portable.
- emits `<brand>-jetson-<board>-arm64-<role>-<env>-<ts>.stage4.tar.xz` and a
  flashable raw `.img` (one ext4 partition, `JETSON_ROOT`, extlinux boot).

### The KERNEL DECISION (`--kernel-flavor`, hardware-gated)

| Flavor | Status | What you get |
|---|---|---|
| `mainline` (DEFAULT) | **implemented, buildable** | gentoo-sources arm64 + `kernel/hardened-node.config` + `kernel/tegra234.config` fragments; boots the node (serial/SD/NVMe/GbE/USB) — **NO CUDA** (the GA10B iGPU needs NVIDIA's nvgpu); the edge-ai service runs CPU-only. |
| `l4t` | **STUB (hard error)** | NVIDIA's L4T/BSP kernel + CUDA userspace — **requires NVIDIA L4T downloads** (EULA-gated); documented, not automated. See [kernel/README.md](kernel/README.md) + [installer/TEGRAFLASH.md](installer/TEGRAFLASH.md). |

## Tree layout (filled)

| Subdir | Holds |
|---|---|
| `kernel/` | `hardened-node.config` (fleet posture + k8s data plane) + `tegra234.config` (Orin SoC bring-up) + `luks-crypt.config` (merged only with `--encrypt-root`, which the builder refuses; see below) + the mainline-vs-L4T decision doc. |
| `portage/` | `make.conf.tmpl` (cortex-a78ae, glibc, hardened) + `packages.list` (base) / `packages-k8s.list` / `packages-edge-ai.list` / `packages-desktop.list` + cross-build package.use/env fixups. NVIDIA's `nvidia-l4t-*` userspace is NOT a portage atom — deliberately absent (documented in `packages-edge-ai.list`). |
| `boot/` | `extlinux.conf.tmpl` + `cmdline.base` (ttyTCU0 console) + Orin Nano DTB table / UEFI-distro-boot notes. NO u-boot — the Orin's UEFI lives in QSPI. |
| `etc/` | `fstab` (single `JETSON_ROOT` ext4), `modules-load.d/jetson.conf`, `dracut.conf.d/60-hugmesh-crypt.conf`, `POWER.md` (nvpmodel/jetson_clocks vs mainline equivalents). |
| `installer/` | `TEGRAFLASH.md` — the normal dd-the-.img path vs the out-of-band recovery-mode tegraflash (QSPI firmware / future L4T+CUDA stack). |

## Encryption is not available yet

`--encrypt-root` and `--standalone` (which forces `--encrypt-root`) exit with an
error on this platform. The image has one ext4 partition. It holds both
`/boot/extlinux/extlinux.conf` and the root filesystem, and the Orin's UEFI reads
that file before Linux runs. A LUKS2 partition would leave the firmware with no
kernel to find. The fix is a separate unencrypted boot partition, as on RPi5 and
Frite. The builder carries LUKS code (`luks-crypt.config`, a dracut crypt module)
that no run can reach today.

## Front-end wiring (all-options-in-all-menus)

Under the **all-options-in-all-menus** standing rule, the platform is exposed in
the CLI and make channel now that it validates: `make jetson`,
`make jetson-<role>` (role pattern), the `JETSON=1` / `JETSON_ONLY=1` /
`JETSON_ROLES=...` knobs on `scripts/build-all-roles.sh`, and
`make build-everything`. The ncurses menu (`scripts/build-menu.sh`) and the
Studio wizard pick it up through the same builder and `--print-plan` contract.

## Hardware-validation checklist (flip Status when done)

1. Boot the mainline `.img` on an Orin Nano devkit (UEFI distro-boot, ttyTCU0).
2. KEYS-USB first-boot provisioning + tailnet join.
3. `edge-ai` role: kubeadm join + CPU-only Ollama serving `/v1`.
4. L4T flavor: out-of-band flash per TEGRAFLASH.md + nvgpu CUDA smoke test.

## Cross-references
- Capability (done, x86): [docs/EDGE-AI.md](../docs/EDGE-AI.md)
- Hardware profiles: `specs-x86/hwprofiles/profiles.json` (no Jetson entry)
