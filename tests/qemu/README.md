# QEMU integration test

Boots a **built** Gentoo RPi 5 image under `qemu-system-aarch64 -M virt` with
a synthetic FAT32 **KEYS** disk and asserts that first-boot provisioning
worked end-to-end:

- users created from `users.json` on KEYS, SSH key-only login works
- `keys-provision` ran (done + users.created markers)
- hostname applied from `provision.json`
- headscale binary present, service started, listening on `:8080`
- containerd / kubelet / kubeadm / kubectl present, kubeadm config staged
- Kubernetes kernel modules + sysctls active
- `jq` present and `/etc/snapdragon/role` marker written

## What it does / doesn't cover

QEMU has no BCM2712 (RPi 5) machine model, so this is **not** a firmware/PCIe
fidelity test. It validates the *software* stack — the rootfs, the
`keys-provision` engine, the services, the mesh + k8s tooling — by booting the
**same kernel Image** the build produced (the kernel config enables virtio +
PL011 so it boots under `-M virt` as well as on real hardware).

`kubernetes.bootstrap` is `false` in the test manifest: it verifies config is
*staged*, it does not run a full `kubeadm init` (impractical under TCG
emulation). Pass `--keep` and SSH in to drive a real `kubeadm init` manually.

## Prerequisites (Gentoo host)

```bash
sudo emerge -av \
    app-emulation/qemu \      # USE="qemu_softmmu_targets_aarch64"
    sys-fs/dosfstools \       # mkfs.vfat
    sys-fs/e2fsprogs          # mkfs.ext4
# mtools is optional (lets make-test-keys.sh build the FAT image without root)
```

Ensure QEMU is built with the aarch64 system target
(`QEMU_SOFTMMU_TARGETS="aarch64"` in your make.conf / package.use).

## Run

```bash
# 1. Build an image first (kernel must be built — do NOT pass --skip-kernel)
./build-rpi5-stage4.sh --role pki

# 2. Run the test (root: it loop-mounts and extracts a stage4 with xattrs)
sudo ./tests/qemu/run-qemu-test.sh --role pki
```

Useful flags: `--timeout 1200` (slow TCG hosts), `--mem 3072`, `--keep` (leave
the VM/disks in `<work>/qemu-test` and don't power off), `--ssh-port 2223`.

On a slow emulated boot the first SSH attempt can take several minutes; the
runner polls until `--timeout`. Console output is captured to
`<work>/qemu-test/console.log`.

## Files

| File | Purpose |
|---|---|
| `run-qemu-test.sh` | Pi: orchestrates build disks, boot QEMU, wait for SSH, assert, power off (root). |
| `run-qemu-e2e.sh` | Node E2E: boot a role image + run the Playwright suite against the forwarded UI (root). |
| `verify-client.sh` | Client desktop: non-root boot + console-assertion verification (laptop/chromebook/desktop). |
| `launch-x86.sh` | Boot a self-booting x86 `.img` under OVMF/KVM (`--gpu`, `--keys-img`, `--run-dir`). |
| `launch-pi.sh` | Boot a Pi kernel+stage4 under `-M virt` with a KEYS disk. |
| `make-test-keys.sh` | Packs a directory into a FAT32 `KEYS` image (reusable, non-root with mtools). |
| `assertions.sh` | The node checks, executed inside the guest over SSH. |
| `seed-accounts.sh` | Renders/pushes the E2E account + Casdoor-role fixtures. |

## Client desktop images (`verify-client.sh`)

The node E2E (`run-qemu-e2e.sh`) drives the cluster UI with Playwright — that does
**not** apply to a **client** desktop image (`--role laptop|chromebook|desktop`),
which is a person's device that joins the mesh and runs no BFF/gateway. For those,
`verify-client.sh` does a **non-root** boot + console-assertion pass (the lighter
Pi-style approach): build a synthetic KEYS disk (`mcopy`), boot the self-booting x86
`.img` under `launch-x86.sh --gpu --keys-img`, and assert boot + first-boot
provisioning on the serial console — kernel boot, `keys-provision`, user + SSH key,
`sshd`, `tailscaled`, `display-manager`/lightdm, and (superadmin) the device-password.

```bash
# build a client image first (needs root):
sudo ./build-x86-host-stage4.sh --role laptop --person-role user \
     --domains acme.example -w /home/me/x86-client-build

# then verify it (NON-root; user in the kvm group):
./tests/qemu/verify-client.sh -w /home/me/x86-client-build --role laptop
./tests/qemu/verify-client.sh -w /home/me/x86-client-build --role chromebook --person-role superadmin
./tests/qemu/verify-client.sh --dry-run --role laptop      # validate the KEYS payload, don't boot
```

The greeter renders under QEMU because the client kernel now carries a generic
framebuffer fallback (`simpledrm`/sysfb + bochs/qxl; virtio-gpu is in the base
fragment) and `launch-x86.sh --gpu` attaches a virtio-GPU.
