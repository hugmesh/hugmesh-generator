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
- `jq` present and `/etc/hugmesh/role` marker written

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
| `launch-arm.sh` | Boot a non-Pi ARM `.img` (frite/jetson/orangepi5/orangepizero2[w]/orangepizero3/orangepi3-lts/orangepi4-lts) under `-M virt` (kernel+DTB direct). |
| `run-matrix-e2e.sh` | Opt-in matrix driver: walk `matrix.tsv`, boot each cell + assert size/load. |
| `matrix-assertions.sh` | `assert_size` / `assert_build_load` / `assert_runtime_load` helpers (limits read from the code). |
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

## Windows Studio `.bat` e2e (`windows-studio-e2e.sh`)

Proves the SHIPPED Windows launcher works on real Windows. `hugmesh-studio.bat` is
the **guided bootstrapper** (see `studio/README.md`, "Run"): on automation args it goes
straight to `python -m hugmesh_studio %*`, and `--print-command` is a
**headless-safe** mode (app.py returns before importing Qt), so it exercises the whole
launcher → module → builder-command path with no display. The harness packs the entire
`studio/` tree onto a FAT **payload** disk (a stock Windows guest has no virtio-9p
driver, so a shared FAT is the transport), boots the guest, runs the `.bat` **twice**,
writes the results back to the FAT, and reads them back with `mtools` after power-off:

1. **DETECT leg** (`hugmesh-studio.bat /detect > DETECT.txt`) — the bootstrapper's
   report mode; it never prompts and never installs, so it needs **no new guest
   prerequisites** and existing operator images keep passing. The verdict requires
   `DETECT_EXITCODE=0`, `DETECT python=found` (Python on PATH is already part of the
   image contract below), a **definite** `DETECT pyside6=` and `DETECT docker=` verdict
   either way (`missing` is the expected answer on a minimal image — a docker-equipped
   image must also pass), and a `DETECT winget=` line.
2. **MARKER leg** (unchanged) — `hugmesh-studio.bat --print-command --backend
   native > MARKER.txt` must exit `0` **and** emit a `build-*-stage4.sh` command.

A missing `MARKER.txt` is still INCONCLUSIVE (guest hook/boot problem); a present
`MARKER.txt` with a missing/failing `DETECT.txt` is a **FAIL** — the detect leg runs
first, so that points at the shipped `.bat`, not the guest.

Because we cannot ship a Windows image, the guest is **operator-provided** (like the
Gentoo build prerequisites above):

- a minimal **Windows desktop qcow2** (`WINDOWS_QEMU_IMAGE`) with **Python 3.10+ on
  `PATH`** (so `python -m hugmesh_studio` runs) and `pip install -r requirements.txt`
  is **not** needed for `--print-command` (it is Qt-free);
- **autologon** to the desktop, and a **Startup / SetupComplete hook** that runs
  `D:\run-selftest.bat` — the tiny runner the harness places at the payload-disk root.
  It `cd`s into `D:\studio`, runs the `/detect` leg, then `hugmesh-studio.bat
  --print-command --backend native`, appends the exit codes, and `shutdown /s /t 0`.

The base image is never mutated (a throwaway qcow2 overlay is booted on top); the
payload FAT the guest sees as **`D:`** is rebuilt per run.

```bash
# real boot (operator supplies the Windows qcow2):
WINDOWS_QEMU_IMAGE=/srv/vm/win-min.qcow2 ./tests/qemu/windows-studio-e2e.sh
WINDOWS_QEMU_IMAGE=/srv/vm/win-min.qcow2 ./tests/qemu/windows-studio-e2e.sh --timeout 900 --keep

# no Windows image needed — pack + validate the payload FAT (and the guest runner)
# round-trip, without booting (needs only sys-fs/dosfstools + sys-fs/mtools):
./tests/qemu/windows-studio-e2e.sh --dry-run
```

Without `WINDOWS_QEMU_IMAGE` (or qemu/OVMF/mtools) the real-boot path **SKIPS cleanly**
(`SKIP: …`, exit 0), so CI stays green. The always-run **offline** half of this proof —
that the `.bat` targets the right entrypoint, that
`python -m hugmesh_studio --print-command` really emits a builder command on Linux
(`studio/tests/test_bat_launcher.py`), and the bootstrapper's static contract (CRLF,
label resolution, pinned winget IDs, consent gating, the DETECT vocabulary — the same
tokens this harness asserts; `studio/tests/test_bat_bootstrap.py`) — lives in the
studio pytest suite and runs every pass.

## Matrix QEMU e2e (`run-matrix-e2e.sh` — opt-in)

Boots the **whole device build matrix** — every `(platform, role, env, board, flavor,
desktop)` cell of `tests/build-matrix/matrix.tsv` (118 rows; the same single source of
truth `check.sh` walks) — under `qemu-system`, and per row asserts the **boot marker**,
the image **SIZE**, and the runtime **LOAD** envelope. Like `run-qemu-test.sh` it
**never builds anything**: it boots operator-supplied golden `.img`/`.iso` artifacts
(`windows-studio-e2e.sh`'s operator-image contract). x86 rows self-boot via
`launch-x86.sh`, rpi5 via `launch-pi.sh`, every other aarch64 platform via the
generalized `launch-arm.sh`. The JOB-channel pseudo-roles are translated to their real
form exactly as `check.sh`'s CLI leg documents: rpi5 `standalone-desktop` →
`--role desktop --standalone`; ARM `flavor=standalone` → `flavor=installer --standalone`.

Every LIMIT is **read from the code**, never hardcoded:

- **SIZE** — `assert_size` reads `ROOT_MiB` from the row's builder `--print-plan`
  (`img_size=<ROOT_MiB>`, which every builder emits and `check.sh` already proves
  prints), computes the compact layout `(1 + 512 + ROOT_MiB + 1) MiB`, and asserts the
  built `.img` (or, for `compress=true` rows, its `xz --list` uncompressed size) does not
  exceed it. The Pi default was reconciled to `9216` here (bugfix #414 had bumped the
  docs/help/tests but missed `build-rpi5-stage4.sh`'s `ROOT_MiB`).
- **BUILD LOAD** — `assert_build_load` proves the 2026-07-15 host-freeze caps are wired
  into the docker build channel: `host_resources.build_memory_flag()`/`default_jobs()`
  produce the caps, `build_driver.docker_memory_args()` carries them as `--memory`, and
  `docker/build-image.sh` threads `-j "$JOBS"`. (Native builds cannot be cgroup-capped,
  so this is a docker-channel invariant only.)
- **RUNTIME LOAD** — `assert_runtime_load` re-boots the row under its **device RAM
  ceiling** (`ram_mb` in `device-catalog.json`, e.g. rpi3 = 1024, orin-nano-4gb = 4096)
  and asserts it still reaches the boot marker with **no oom-killer**. This is a boot
  **envelope** check (does the image come up inside device RAM), *not* a peak-load
  stress test — a QEMU node with `kubernetes.bootstrap=false` does not exercise the
  cluster's real memory peak. Multi-SKU boards (rpi5/4, la-frite) declare no single
  ceiling, so their runtime-load re-boot is skipped rather than guessed.

```bash
# ALWAYS-RUN, hermetic (no root, no boot, no builder): enumerate every row + resolve
# its launcher / normalized invocation / RAM ceiling. This is the CI-green half.
tests/qemu/run-matrix-e2e.sh --dry-run
make qemu-matrix-enumerate

# real boot (operator supplies golden artifacts under WORK_DIR):
HUGMESH_QEMU_E2E=1 make qemu-matrix MATRIX_FILTER=x86/be+gpu
HUGMESH_QEMU_E2E=1 tests/qemu/run-matrix-e2e.sh --only jetson/edge_ai -w /srv/img
```

Gated exactly like the Tor onion e2e: without `HUGMESH_QEMU_E2E=1` (and qemu) the
boot path **SKIPs cleanly** (exit 0), and a missing artifact for a row is a per-row SKIP,
never a FAIL. EXPERIMENTAL boards (frite/jetson/orangepi) may be **INCONCLUSIVE** under
`-M virt` (no vendor firmware) — recorded as soft-pass, not FAIL. Under TCG on an x86
host the full 118-cell walk is many hours (no aarch64 KVM), so keep it nightly and use
`--only` / `MATRIX_FILTER` for a subset.

The always-run **offline** half of this proof lives in the studio pytest suite
(`studio/tests/test_qemu_matrix_e2e.py`): the harness-exists check, the matrix
enumeration + per-platform census, the launcher resolution, the pseudo-role translation,
the `(1 + 512 + ROOT_MiB + 1)` size formula, the `img_size=`-from-`--print-plan` parser,
the `ram_mb` ceiling accessor, and the driver's `--dry-run` (118 rows) — all runs every
pass with the gate unset. The pure Python view of the enumeration + maths is
`studio/hugmesh_studio/core/build_matrix.py`.

## Saving the whole emulated mesh (`make qemu-save-mesh` — #50 item 10)

Everything done inside a running `--keep-alive` mesh — every device's disk **plus**
the KEYS provisioning stick it booted from — saved as **one flashable set** under
`out/qemu-runs/saves/mesh-<stamp>/`, so it can be written to real hardware:

```bash
make qemu-save-mesh-plan                  # preview: devices, disk budget, KEYS pieces
make qemu-save-mesh                       # save every live device
make qemu-save-mesh SAVE_ONLY=rpi5        # label substring, like the runner's --only
PYTHONPATH=studio python3 -m hugmesh_studio.core.emulation_save save --only rpi5/pki
```

Per device the set holds `<label>.qcow2` (the disk, via the landed
`run-qemu-docker.sh --save-device` — standalone, merged over the golden,
crash-consistent; the golden stays untouched), `<label>.keys/` + `<label>.keys.img`
(the run's **exact** KEYS payload, copied back — regenerating would mint a login key
the saved disk was never provisioned with), `<label>.id_ed25519[.pub]` (the key that
logs into the saved system), and a `mesh-save.json` manifest. To reach real hardware:
`qemu-img convert -O raw <label>.qcow2 <label>.img` then flash it like any built
image, and `sudo scripts/make-keys-usb.sh /dev/sdX <label>.keys` for the stick.

Real saves are **9.5–20.5 GB each** (`sync=full` over fully-allocated goldens), so
the orchestrator budgets each disk's FULL virtual size (16 GiB, 32 GiB for x86) and
refuses the whole save — naming the shortfall — **before pausing anything**. One
device failing (its partial is quarantined as `*.partial` by the runner) never
touches another device's save. Core + tests:
`studio/hugmesh_studio/core/emulation_save.py`,
`studio/tests/test_emulation_save.py`.
