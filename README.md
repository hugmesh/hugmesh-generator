# Catalyst Scripts

Crossdev-based build scripts for producing hardened Gentoo Linux stage4 images targeting the Raspberry Pi 5 (BCM2712 / Cortex-A76) with a full Kubernetes stack, all cross-compiled from an x86_64 host.

No root or sudo is required to run the build. The included SD card / NVMe installer (`install.sh` inside the ISO) is the only component that needs root, and only on the machine writing the image.

## What You Get

- **Hardened Gentoo** — `default/linux/arm64/23.0/hardened` profile, PIE/SSP/FORTIFY_SOURCE, full RELRO, AppArmor LSM, audit subsystem, hardened sysctl and SSH
- **Kubernetes-ready** — containerd + runc, kubelet, kubeadm, kubectl, CNI plugins, cgroup v2, IPVS, eBPF/XDP (Cilium-ready), OverlayFS
- **RPi 5 optimised** — `cortex-a76` tuning, RP1 south-bridge support, PCIe/NVMe, fan control, `kernel_2712.img`
- **Portable config** — all spec files are separated from the build script so you can view, diff, and version them independently

## Prerequisites

The following must already be installed on the x86_64 build host:

| Tool | Package |
|---|---|
| `crossdev` | `sys-devel/crossdev` |
| `aarch64-unknown-linux-gnu-gcc` | Built via `crossdev --target aarch64-unknown-linux-gnu` |
| `xorrisofs` | `dev-libs/libisoburn` |
| `curl` | `net-misc/curl` |
| `tar` | `app-arch/tar` |
| `file` | `sys-apps/file` |

Build the cross-toolchain once:

```bash
crossdev --stable --target aarch64-unknown-linux-gnu
```

## Quick Start

```bash
git clone https://github.com/Snapdragon-Systems/catalyst-scripts.git
cd catalyst-scripts

# Build with all defaults — output lands in ./rpi5-stage4-build/
./build-rpi5-stage4.sh

# Or point at a fast scratch disk
./build-rpi5-stage4.sh -w /mnt/nvme/rpi-build
```

When the build finishes you get:

```
rpi5-stage4-build/
├── stage4-aarch64-unknown-linux-gnu-rpi5-hardened-k8s-2026.0.tar.xz
├── gentoo-rpi5-arm64-hardened-k8s-2026.0.iso
├── sysroot/        # full root filesystem
├── pkgdir/         # binary packages (reusable)
└── build.log       # complete build log
```

## Writing to SD Card / NVMe

```bash
# Mount the ISO
mount -o loop rpi5-stage4-build/gentoo-rpi5-arm64-hardened-k8s-2026.0.iso /mnt/iso

# SD card
sudo /mnt/iso/install.sh /dev/sdX

# NVMe (via M.2 HAT)
sudo /mnt/iso/install.sh /dev/nvme0n1
```

Or extract the tarball directly:

```bash
sudo parted /dev/sdX mklabel msdos
sudo parted /dev/sdX mkpart primary fat32 1MiB 512MiB
sudo parted /dev/sdX set 1 boot on
sudo parted /dev/sdX mkpart primary ext4 512MiB 100%
sudo mkfs.vfat -F32 /dev/sdX1 && sudo mkfs.ext4 /dev/sdX2
sudo mount /dev/sdX2 /mnt/root && sudo mount /dev/sdX1 /mnt/root/boot
sudo tar -C /mnt/root --xattrs-include='*.*' -xJf stage4-*.tar.xz
sudo mv /mnt/root/boot/* /mnt/root/boot/   # already in place
```

## Default Credentials

| User | Password |
|---|---|
| `root` | `gentoo` |
| `pi` | `raspberry` |

SSH is key-only — add your public key to `~/.ssh/authorized_keys` after first boot.

**Change all default passwords immediately.**

## Options Reference

### Directories

| Flag | Short | Default | Description |
|---|---|---|---|
| `--work-dir DIR` | `-w` | `./rpi5-stage4-build` | Base directory for all build artifacts. Created under the current working directory if not specified. |
| `--specs-dir DIR` | `-s` | `specs/` (next to script) | Path to the spec files directory. Copy and customise `specs/`, then point here. |

### Toolchain

| Flag | Short | Default | Description |
|---|---|---|---|
| `--target TUPLE` | `-t` | `aarch64-unknown-linux-gnu` | Cross-compilation target triplet. |
| `--jobs N` | `-j` | `$(nproc)` | Number of parallel make/emerge jobs. |

### Board / CPU

| Flag | Short | Default | Description |
|---|---|---|---|
| `--cpu CPU` | `-c` | `cortex-a76` | GCC `-mcpu`/`-mtune` value. Use `cortex-a53` for RPi 3, `cortex-a72` for RPi 4. |
| `--defconfig NAME` | `-d` | `bcm2712_defconfig` | Kernel defconfig. Use `bcmrpi3_defconfig` for RPi 3, `bcm2711_defconfig` for RPi 4. |
| `--dtb-prefix PREFIX` | | `bcm2712` | Device-tree blob filename prefix. |
| `--kernel-img NAME` | | `kernel_2712.img` | Output kernel image filename for `/boot`. |
| `--pcie-gen3` | | off | Force PCIe Gen 3 for NVMe. Not all drives are stable — test first. |

### Image

| Flag | Short | Default | Description |
|---|---|---|---|
| `--version STRING` | `-v` | `2026.0` | Release version stamp for filenames and ISO volume ID. |
| `--seed-url URL` | | Gentoo arm64 autobuilds | URL to the `latest-stage3` index file for the seed tarball. |

### System

| Flag | Short | Default | Description |
|---|---|---|---|
| `--hostname NAME` | `-H` | `gentoo-rpi5` | Target system hostname. |
| `--timezone ZONE` | `-T` | `UTC` | Target timezone (e.g. `America/New_York`). |
| `--user NAME` | `-u` | `pi` | Default non-root user created on first boot. |
| `--user-password PASS` | | `raspberry` | Password for the default user. |
| `--root-password PASS` | | `gentoo` | Root password. |

### Packages

| Flag | Short | Default | Description |
|---|---|---|---|
| `--extra-packages "PKG ..."` | `-p` | *(none)* | Space-separated list of additional Gentoo packages to emerge. Appended to `specs/portage/packages.list`. |

### Build Phases

| Flag | Default | Description |
|---|---|---|
| `--skip-kernel` | off | Skip kernel compilation. Useful when iterating on packages only. |
| `--skip-iso` | off | Skip ISO generation. Only produce the stage4 tarball. |
| `--skip-clean` | off | Keep debug symbols, headers, and docs in the sysroot. |
| `--resume` | off | Resume a previous build. Skips seed extraction if the sysroot exists. |

### General

| Flag | Short | Description |
|---|---|---|
| `--help` | `-h` | Show the full man-style help and exit. |

## Examples

```bash
# Minimal — build everything with defaults
./build-rpi5-stage4.sh

# Fast scratch disk, 8 jobs, custom hostname, extra packages, PCIe Gen 3
./build-rpi5-stage4.sh \
    -w /mnt/nvme/rpi-build \
    -j 8 \
    -H k8s-node-01 \
    -T America/New_York \
    --pcie-gen3 \
    -p "app-misc/tmux sys-fs/btrfs-progs net-misc/chrony"

# Target RPi 4 instead of RPi 5
./build-rpi5-stage4.sh \
    -c cortex-a72 \
    -d bcm2711_defconfig \
    --dtb-prefix bcm2711 \
    --kernel-img kernel8.img

# Resume a failed build, tarball only, keep debug info
./build-rpi5-stage4.sh \
    -w ~/rpi5-stage4-build \
    --resume \
    --skip-iso \
    --skip-clean

# Use a customised specs directory
cp -r specs ~/my-specs
nano ~/my-specs/portage/packages.list
nano ~/my-specs/kernel/hardened-k8s.config
./build-rpi5-stage4.sh -s ~/my-specs

# Full production build with every option
./build-rpi5-stage4.sh \
    -w /var/tmp/rpi5-build \
    -s ./specs \
    -t aarch64-unknown-linux-gnu \
    -j 16 \
    -c cortex-a76 \
    -d bcm2712_defconfig \
    --dtb-prefix bcm2712 \
    --kernel-img kernel_2712.img \
    --pcie-gen3 \
    -v 2026.1 \
    -H k8s-master \
    -T Europe/London \
    -u admin \
    --user-password 'Ch@ng3Me!' \
    --root-password 'S3cur3R00t!' \
    -p "app-misc/tmux net-misc/chrony sys-fs/btrfs-progs dev-vcs/git"
```

## Spec Files

All configuration lives in `specs/`. Edit these files to customise the image without touching the build script.

| File | Description |
|---|---|
| `portage/make.conf.tmpl` | Main portage config — CFLAGS, USE, FEATURES (templated) |
| `portage/packages.list` | Stage4 package list, one atom per line |
| `portage/profile/parent` | Gentoo profile selection (`hardened/arm64`) |
| `portage/profile/use.mask` | Global USE flags to mask |
| `portage/package.accept_keywords/rpi` | RPi firmware `~arm64` keywords |
| `portage/package.accept_keywords/kubernetes` | K8s stack `~arm64` keywords |
| `portage/package.use/rpi5` | RPi 5 per-package USE flags |
| `portage/package.use/kubernetes` | K8s per-package USE flags |
| `portage/env/cross-go.conf.tmpl` | Go cross-compile environment (templated) |
| `portage/package.env/kubernetes` | Maps K8s packages to `cross-go.conf` |
| `boot/config.txt.tmpl` | RPi 5 boot firmware config (templated) |
| `boot/cmdline.txt` | Kernel command line — hardened + cgroup v2 |
| `etc/fstab` | Filesystem table (SD + NVMe commented) |
| `etc/modules-load.d/kubernetes.conf` | Kernel modules loaded at boot for K8s |
| `etc/sysctl.d/10-hardened.conf` | Hardened sysctl parameters |
| `etc/sysctl.d/99-kubernetes.conf` | K8s networking sysctl |
| `etc/containerd/config.toml` | containerd CRI runtime config |
| `etc/kubernetes/kubeadm-config.yaml` | kubeadm init defaults |
| `etc/kubernetes/kubelet-config.yaml` | Hardened kubelet config |
| `etc/init.d/containerd` | OpenRC init script for containerd |
| `etc/init.d/kubelet` | OpenRC init script for kubelet |
| `etc/ssh/sshd_config.d/hardened.conf` | Hardened SSH — key-only, restricted ciphers |
| `etc/local.d/01-firstboot.start.tmpl` | First-boot user/locale/module setup (templated) |
| `kernel/hardened-k8s.config` | Kernel config fragment — one option per line |
| `installer/install.sh` | SD/NVMe installer bundled into the ISO |

### Templating

Files ending in `.tmpl` contain `@@VARIABLE@@` markers substituted at build time. The available variables are:

| Variable | Source |
|---|---|
| `@@CBUILD@@` | Host compiler triplet (auto-detected) |
| `@@CROSS_TARGET@@` | `--target` option |
| `@@RPI_CPU@@` | `--cpu` option |
| `@@JOBS@@` | `--jobs` option |
| `@@WORK_DIR@@` | `--work-dir` option |
| `@@RPI_KERNEL_IMG@@` | `--kernel-img` option |
| `@@PCIE_LINE@@` | Resolved from `--pcie-gen3` flag |
| `@@HOSTNAME@@` | `--hostname` option |
| `@@TIMEZONE@@` | `--timezone` option |
| `@@DEFAULT_USER@@` | `--user` option |
| `@@DEFAULT_USER_PASS@@` | `--user-password` option |
| `@@ROOT_PASS@@` | `--root-password` option |

### Kernel Config Fragment

`specs/kernel/hardened-k8s.config` uses a simple format — one `scripts/config` action per line:

```
enable CONFIG_SECCOMP
module CONFIG_IP_VS_RR
disable CONFIG_DEVKMEM
set-str CONFIG_LSM "apparmor,integrity"
set-val CONFIG_DEFAULT_MMAP_MIN_ADDR 65536
```

Lines starting with `#` are comments. The fragment is applied on top of the board defconfig (`--defconfig`).

## Post-Install: Bootstrapping Kubernetes

After booting the RPi 5:

```bash
# 1. Change passwords
passwd root
passwd pi

# 2. Add SSH keys
ssh-copy-id pi@<rpi-ip>

# 3. Initialize the control plane
kubeadm init --config /etc/kubernetes/kubeadm-config.yaml

# 4. Set up kubeconfig
mkdir -p $HOME/.kube
cp /etc/kubernetes/admin.conf $HOME/.kube/config

# 5. Install a CNI (e.g. Flannel)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 6. Join worker nodes
kubeadm token create --print-join-command
# Run the output on each worker
```

## License

MIT
