# QEMU integration test

Boots a **built** Gentoo RPi 5 image under `qemu-system-aarch64 -M virt` with
a synthetic FAT32 **KEYS** disk. It asserts that first-boot provisioning
worked end to end:

- users created from `users.json` on KEYS, SSH key-only login works
- `keys-provision` ran (done + users.created markers)
- hostname applied from `provision.json`
- headscale binary present; when the KEYS manifest asks for headscale, the
  service is started and listening on `:8080` (otherwise those two checks skip)
- containerd / kubelet / kubeadm / kubectl present, kubeadm config staged
- Kubernetes kernel modules + sysctls active
- `jq` present and `/etc/hugmesh/role` marker written

## What it does / doesn't cover

QEMU has no BCM2712 (RPi 5) machine model, so this is **not** a firmware or PCIe
test. It tests the *software* stack: the rootfs, the `keys-provision` engine, the
services, the mesh and k8s tooling. It boots the **same kernel Image** the build
produced. The kernel config enables virtio and PL011, so it boots under `-M virt` as
well as on real hardware.

`kubernetes.bootstrap` is `false` in the test manifest. The test checks that config
is *staged*. It does not run a full `kubeadm init`, which is impractical under TCG
emulation. `mesh-cluster.sh` (below) is the lane that runs a real `kubeadm init`.

## Prerequisites (Gentoo host)

```bash
sudo emerge -av \
    app-emulation/qemu \      # USE="qemu_softmmu_targets_aarch64"
    sys-fs/dosfstools \       # mkfs.vfat
    sys-fs/e2fsprogs          # mkfs.ext4 (>= 1.43, for -d) + debugfs
# mtools is optional (lets make-test-keys.sh build the FAT image without root)
```

Build QEMU with the aarch64 system target
(`QEMU_SOFTMMU_TARGETS="aarch64"` in your make.conf / package.use).

## Run

```bash
# 1. Build an image first (kernel must be built — do NOT pass --skip-kernel)
./build-rpi5-stage4.sh --role pki

# 2. Run the test. Root is needed to extract a stage4 with its ownership and
#    security.* xattrs intact — NOT for a loop mount: since 2026-08-26 the
#    rootfs is populated with `mkfs.ext4 -d`, so stage4 mode takes no loop
#    device and holds no mount for the boot+assert window.
sudo ./tests/qemu/run-qemu-test.sh --role pki
```

Useful flags: `--timeout 2400` (the default is 1800 s; raise it on slow TCG
hosts), `--mem 3072`, `--keep` (keep the scratch dir `<work>/qemu-test` instead
of deleting it; the guest is still powered off after the assertions),
`--ssh-port 2223`.

On a slow emulated boot the first SSH attempt can take several minutes. The
runner polls until `--timeout`. Console output goes to
`<work>/qemu-test/console.log`.

## Files

| File | Purpose |
|---|---|
| `run-qemu-test.sh` | Pi: orchestrates build disks, boot QEMU, wait for SSH, assert, power off (root). |
| `run-qemu-e2e.sh` | Node E2E: boot a role image + run the **Playwright** suite against the forwarded UI (root to boot; `--list` / `--dry-run` need none). |
| `qemu-e2e-lane_test.sh` | Hermetic tests for that lane's `--list`, `--dry-run`, non-root refusal and the `make e2e`/`e2e-list` argv (no boot, no docker, no root — and **no skip under uid 0**: the refusal legs use a proven `id -u` shim). |
| `verify-client.sh` | Client desktop: non-root boot + console-assertion verification (laptop/chromebook/desktop). |
| `launch-x86.sh` | Boot a self-booting x86 `.img` under OVMF/KVM (`--gpu`, `--keys-img`, `--run-dir`). |
| `launch-pi.sh` | Boot a Pi **golden `.img`** under `-M virt` with a KEYS disk (`--kernel` loaded directly — QEMU has no BCM2712 model; it takes no `--stage4`, that is `run-qemu-test.sh`'s input). |
| `launch-arm.sh` | Boot a non-Pi ARM `.img` (frite/jetson/orangepi5/orangepizero2[w]/orangepizero3/orangepi3-lts/orangepi4-lts) under `-M virt` (kernel+DTB direct). |
| `run-qemu-docker.sh` | Containerized device tests: one `--privileged` container per platform/role row against a build session's artifacts; `--keep-alive` leaves the devices running and registers them for the Studio; `--save-device`, `--stop-all-devices`. Needs `docker` group membership, not `sudo`. |
| `docker-entrypoint.sh` | Runs inside the `hugmesh-qemu-runner` container (`docker/Dockerfile.qemu-runner`): one container, one emulated device. |
| `run-matrix-e2e.sh` | Opt-in matrix driver: walk `matrix.tsv`, boot each cell + assert size/load. |
| `mesh-cluster.sh` | Opt-in 3-node k8s cluster: CP `kubeadm init` + two pinned-token joins over a shared QEMU mcast L2 (issue #48). `--identities FILE` takes the nodes' MAC/IP/L2 from the planner. |
| `mesh-identities.sh` | **Sourced, not run.** The one reader of the planner's identity file, shared by `mesh-cluster.sh` and `run-qemu-docker.sh` (parse + per-row sanity; each lane keeps its own policy). |
| `mesh-cluster_test.sh` | Static gate + hermetic tests for the whole mesh lane — all three launchers, the driver, the shared identity reader and the runner's shared-L2 plumbing (nothing boots; also run by `tests/build-matrix/check.sh`'s smokes + CI `lint:qemu-mesh-cluster`). |
| `matrix-assertions.sh` | `assert_size` / `assert_build_load` / `assert_runtime_load` helpers (limits read from the code). |
| `make-test-keys.sh` | Packs a directory into a FAT32 `KEYS` image (reusable, non-root with mtools). |
| `assertions.sh` | The node checks, executed inside the guest over SSH. |
| `seed-accounts.sh` | Renders/pushes the E2E account + Casdoor-role fixtures. |
| `avc-workout.sh` | SELinux AVC workout driver: boot ONE image, drive confined workloads, harvest AVCs, emit the narrowing report (issue #45). |
| `avc-workload.sh` | The in-guest probe list (one probe per workload the `specs/selinux/*.te` modules confine; presence-gated = role-appropriate). |
| `avc-report.sh` | Groups a raw AVC harvest by source type → the owning `specs/selinux/*.te` (hermetic text processing). |
| `avc-workout_test.sh` | Hermetic tests + mutation legs for the whole workout lane (nothing boots; also run by `tests/build-matrix/check.sh`'s smokes). |
| `stage4_rootfs_test.sh` | Hermetic tests + mutation legs for the stage4 rootfs lane: `build_rootfs()` driven against fixture tarballs with `mount`/`umount`/`losetup` stubbed to fail loudly, and `assertions.sh`'s rootfs-is-labelled precondition (nothing boots, no root; also run by `tests/build-matrix/check.sh`'s smokes). |

All three launchers carry the same default-off mesh flags: `--mesh-net SPEC`,
`--mesh-mac MAC`, `--mesh-id N`. One identical block spells them, so a mixed-arch
mesh is a launcher choice, not a missing feature. Without `--mesh-net` the QEMU
argv is byte-identical to a copy of the launcher with the mesh code cut out
(`mesh-cluster_test.sh` pins that).

## 3-node emulated k8s cluster (`mesh-cluster.sh`, issue #48)

Multi-node needs two things the single-node lane never exercised: the kubelet join
fix (`specs/etc/init.d/kubelet`) and a shared L2 so the emulated nodes see each
other. `launch-x86.sh --mesh-net ADDR:PORT` (default-off) attaches a **second** virtio
NIC on a QEMU UDP-multicast socket netdev. Every node given the same SPEC lands on
one broadcast domain. The slirp NIC keeps its per-node SSH/API hostfwds.
`--mesh-mac` / `--mesh-id N` give each node a distinct MAC (`52:54:00:6d:65:NN`).

`mesh-cluster.sh` drives three launches behind qcow2 overlays. The golden images are
never written, and overlays are **never** committed back: a `qemu-img commit`
against a live device silently rewrites the golden artifact.

All join material is minted **offline**, so nothing scrapes the serial console:

- a throwaway cluster CA goes onto the CP's KEYS stick (`kubernetes/pki`);
- the bootstrap token is pinned in the CP's kubeadm-config;
- the workers' KEYS carry the matching `.kubernetes.join.{api_server,token,ca_cert_hash}`;
- static IPs ride `KEYS/network/mesh0.nmconnection`, bound to each mesh MAC (the
  shared L2 has no DHCP).

Gates: the CP's `Running kubeadm init` → `First control plane initialised` →
`=== keys-provision complete ===` console markers; `Joined cluster (` on both
workers; and `kubectl get nodes` listing 3 registered nodes. Ready needs a CNI. That
is the post-build campaign's phase, so it is reported, not gated.

```bash
make qemu-mesh-enumerate                          # the plan; nothing boots
make qemu-mesh WORK_DIR=out/sessions/<id>/artifacts   # opt-in real 3-node boot
HUGMESH_QEMU_MESH=1 tests/qemu/mesh-cluster.sh --img <golden.img>
```

Headscale and tailscale stay **off** here (phase 2, LAN cluster). The mesh-faithful
variant (headscale + MagicDNS + a `reusable:true` preauth key) is phase 3 on the
same plumbing. It is planned, not built.

## ONE identity source + the containerized mesh lane (issue #48 phase 4)

Two lanes boot multi-node meshes: this driver (three launches on the host) and the
containerized fleet (`run-qemu-docker.sh --keep-alive`, which registers devices the
Studio can see). Both take their **MACs, IPs and L2 from the same place**: the
planner in `studio/hugmesh_studio/core/mesh_emulation.py`. Its identities are
deterministic per build session: MAC `52:54:00:<sha(session)>:<idx>`, address
`10.77.0.11+`, and a session-derived multicast group in `239.118.72.0/24`. Mint the
file, then hand it to the lane you use:

```bash
PYTHONPATH=studio python3 -m hugmesh_studio.core.mesh_emulation \
    identities --out out/qemu-runs/identities.json          # the file
tests/qemu/mesh-cluster.sh --dry-run --identities out/qemu-runs/identities.json
tests/qemu/run-qemu-docker.sh --keep-alive --mesh-net auto \
    --identities out/qemu-runs/identities.json              # the whole fleet
```

Nothing downstream invents an identity:

- `run-qemu-docker.sh` refuses `--mesh-net` without `--identities`, and refuses to
  start a row the file does not cover.
- `docker-entrypoint.sh` refuses a half identity (a NIC with no address, or an
  address with no NIC).

Both flags are **off by default**. A run without them produces exactly the
`docker run` and QEMU argv it always did.

How the containerized fleet gets an L2: the runner creates ONE docker **bridge
network per session** (`hugmesh-qemu-mesh-<8 hex of the session hash>`, created
idempotently) and attaches every device container to it. Containers on one bridge
share a broadcast domain. That lets each guest's second virtio NIC, a QEMU
`socket,mcast=` netdev, reach the other guests.

Per device, the entrypoint writes `KEYS/network/mesh0.nmconnection`. It binds the
static address to that device's mesh MAC with `never-default=true`. The shared L2
has no DHCP, and the slirp NIC must keep the default route or the published ssh/UI
forwards would break.

The identity also lands in the device record (`mesh_net`/`mesh_mac`/`mesh_ip`). That
is the only place a reader can learn where a device is reachable **from its peers**.
The registry's `ssh_host_port` is a loopback forward on the workstation and means
nothing to another guest. `--stop-all-devices` removes a mesh bridge once its last
member is gone, and never a network this harness did not create.

Status: every layer above is gated hermetically (`mesh-cluster_test.sh`): launcher
argv byte-identity, identity parsing and its fail-closed legs, the driver end to end
through the file, the bridge lifecycle against a fake docker, and the
planner→driver contract. The **live** multi-container boot has NOT been run. It
needs ≥25 G free on `/`, and `df -h /` on this workstation showed 3.4 G free on
2026-10-07. When it is run, watch multicast delivery across the bridge. If the host
bridge filters it, the same guests work with the point-to-point `listen=`/`connect=`
SPEC, which the launchers already accept.

## SELinux AVC workout (`avc-workout.sh`, issue #45)

The `specs/selinux/*.te` modules carry rules tagged `# INFERRED-WIDE: narrow after
QEMU enforcing AVC pass`. This driver produces that pass, one image type per run.

It boots the image on a per-run qcow2 overlay (the golden artifact is never
written). It drives every confined workload: ssh logins through sshd's
AuthorizedKeysCommand, the reconcile-agent service starts, device-registry sync,
tor/vpn starts, `kubeadm init --dry-run`. It harvests
`ausearch -m AVC,USER_AVC -ts boot` (dmesg fallback). It emits `report.txt`, which
groups denials by source type and names the `.te` file that owns each, so
narrowing is mechanical.

Gates: every module in `/usr/share/hugmesh/selinux-modules.list` must be in
`semodule -l`, the per-module `selinux-modules.status` must be clean, and
`getenforce` must match the expected mode.

```bash
# permissive pass (the narrowing input), once per image type:
make avc-workout PLATFORM=x86  ROLE=pki WORK_DIR=out/sessions/<id>/artifacts
make avc-workout PLATFORM=rpi5 ROLE=pki WORK_DIR=out/sessions/<id>/artifacts

# enforcing campaign (after narrowing): setenforce 1 before the workload
make avc-workout PLATFORM=x86 ROLE=pki ENFORCING=1 WORK_DIR=...
```

Artifacts land in `out/qemu-runs/avc/<platform>_<role>_<ts>/` (`report.txt`,
`avc-raw.txt`, `probes.log`, `logins.log`, `semodule-l.txt`,
`selinux-modules.status`, `manifest.txt`, `getenforce.txt`,
`keys-provision.log`, `launch/console.log`).

## Enumerating the Playwright lane (`run-qemu-e2e.sh --list`)

`--list` answers "what would this lane run?" without booting anything. It emits one
JSON document and exits. The document holds the resolved boot plan (target, role,
ports, base URL, the artifacts it found, or `null` for those it did not) **and** the
Playwright spec tree.

```bash
make e2e-list                                   # ROLE/ARCH as usual
make e2e-list E2E_ARGS='--grep @smoke'          # what would that narrowing run?
make e2e      E2E_ARGS='--grep @smoke'          # and the real (root) boot, narrowed
tests/qemu/run-qemu-e2e.sh -w /srv/img --list -- specs/01-frontpage.spec.ts
```

`E2E_ARGS` reaches Playwright through the `--` separator both targets render. The
separator is **not optional** here, unlike `make stack-e2e`, where `npx playwright
test` is the direct consumer. This lane puts a shell script in between, and its parser
hard-errors on any word it does not recognise. A bare `--grep @smoke`, or a bare spec
path, gives `Unknown arg`. `make e2e` shipped without the separator on 2026-08-26 and
was dead for every value. `qemu-e2e-lane_test.sh` now renders both targets with
`make -n` and feeds the result to the real parser.

`--list` needs **no root, no image and no network**. It runs before the artifact
autodetect, so a tree that has built nothing still describes the lane. The spec half
is `playwright test --list --reporter=json`. `--reporter=json` is **forced**: a bare
`--list` under this config's reporter array still fires every file writer and would
clobber the last real run's `junit.xml`/`report.json`/`summary.json` in
`SNAP_REPORT_DIR`.

Measured 2026-10-07 with `npx playwright test -c playwright.config.ts --list
--reporter=json` in `tests/e2e`: 35 spec files / 246 tests (2026-08-26: 33 files / 221
tests), and nothing written to the worktree. When `tests/e2e/node_modules` is missing,
the spec half skips **loudly and by name** (`playwright_skipped` in the JSON, plus a
line on stderr) and the boot-plan half still answers.

## Why this lane refuses instead of calling `sudo`

`run-qemu-e2e.sh` refuses to boot unless it is uid 0 (`run-qemu-e2e.sh:340`). Its
refusal message says the launchers loop-mount the golden image to lift its kernel out
of the boot partition. That reason is out of date. `launch-x86.sh` has no mount code.
Since 2026-08-26 `launch-pi.sh --kernel-from-img` reads the FAT boot partition at a
byte offset with mtools, with a privileged offset mount only as the fallback for a
non-FAT `/boot`. Whether the lane still needs root for anything else is not verified.

`run-qemu-e2e.sh` never invokes `sudo`. The Studio drives it, and a GUI cannot answer
an interactive password prompt. Its refusal names three routes: `--list`/`--dry-run`
(no root), the **privileged container** the device-test lane already uses for this
same constraint (`make qemu-docker-image`, then `docker run --privileged … --entrypoint …`),
or a shell that is already root.

The container path is **not automatic yet**, and the script says why.
`docker/Dockerfile.qemu-runner` keeps the guest's port forwards inside the container
on purpose, and ships no Node. The browser half would have to run on the host against
a published `--ui-port` while phases 1-3 run inside. That is a new entrypoint, and it
cannot be verified without booting a guest.

## Client desktop images (`verify-client.sh`)

The node E2E (`run-qemu-e2e.sh`) drives the cluster UI with Playwright. That does
**not** apply to a **client** desktop image (`--role laptop|chromebook|desktop`). A
client image is a person's device. It joins the mesh and runs no BFF or gateway. For
those, `verify-client.sh` does a **non-root** boot plus console-assertion pass (the
lighter Pi-style approach). It builds a synthetic KEYS disk (`mcopy`), boots the
self-booting x86 `.img` under `launch-x86.sh --gpu --keys-img`, and asserts boot and
first-boot provisioning on the serial console: kernel boot, `keys-provision`, user and
SSH key, `sshd`, `tailscaled`, `display-manager`/lightdm, and (superadmin) the
device-password.

```bash
# build a client image first (needs root):
sudo ./build-x86-host-stage4.sh --role laptop --person-role user \
     --domains acme.example -w /home/me/x86-client-build

# then verify it (NON-root; user in the kvm group):
./tests/qemu/verify-client.sh -w /home/me/x86-client-build --role laptop
./tests/qemu/verify-client.sh -w /home/me/x86-client-build --role chromebook --person-role superadmin
./tests/qemu/verify-client.sh --dry-run --role laptop      # validate the KEYS payload, don't boot
```

The greeter renders under QEMU because the client kernel carries a generic framebuffer
fallback (`simpledrm`/sysfb + bochs/qxl, in `specs-x86/kernel/desktop.config`;
virtio-gpu is in `specs-x86/kernel/hardened-k8s.config`) and `launch-x86.sh --gpu`
attaches a `virtio-gpu-pci` device.

## Windows Studio `.bat` e2e (`windows-studio-e2e.sh`)

This proves the SHIPPED Windows launcher works on real Windows. `hugmesh-studio.bat` is
the **guided bootstrapper** (see `studio/README.md`, "Run"). On automation args it goes
straight to `python -m hugmesh_studio %*`. `--print-command` is a **headless-safe** mode
(app.py returns before importing Qt), so it exercises the whole launcher → module →
builder-command path with no display.

The harness packs the entire `studio/` tree onto a FAT **payload** disk. A stock Windows
guest has no virtio-9p driver, so a shared FAT is the transport. It boots the guest, runs
the `.bat` **twice**, writes the results back to the FAT, and reads them with `mtools`
after power-off:

1. **DETECT leg** (`hugmesh-studio.bat /detect > DETECT.txt`) — the bootstrapper's report
   mode. It never prompts and never installs, so it needs **no new guest prerequisites**,
   and existing operator images keep passing. The verdict requires:
   - `DETECT_EXITCODE=0`;
   - `DETECT python=found` (Python on PATH is already part of the image contract below);
   - a **definite** `DETECT pyside6=` and `DETECT docker=` verdict, either way
     (`missing` is the expected answer on a minimal image; a docker-equipped image
     must also pass);
   - a `DETECT winget=` line.
2. **MARKER leg** (unchanged) — `hugmesh-studio.bat --print-command --backend native >
   MARKER.txt` must exit `0` **and** emit a `build-*-stage4.sh` command.

A missing `MARKER.txt` is INCONCLUSIVE (guest hook or boot problem). A present
`MARKER.txt` with a missing or failing `DETECT.txt` is a **FAIL**. The detect leg runs
first, so that points at the shipped `.bat`, not the guest.

We cannot ship a Windows image, so the guest is **operator-provided**, like the Gentoo
build prerequisites above:

- a minimal **Windows desktop qcow2** (`WINDOWS_QEMU_IMAGE`) with **Python 3.10+ on
  `PATH`**, so `python -m hugmesh_studio` runs. `pip install -r requirements.txt` is
  **not** needed for `--print-command` (it is Qt-free);
- **autologon** to the desktop, and a **Startup / SetupComplete hook** that runs
  `D:\run-selftest.bat`, the tiny runner the harness places at the payload-disk root.
  It `cd`s into `D:\studio`, runs the `/detect` leg, then `hugmesh-studio.bat
  --print-command --backend native`, appends the exit codes, and runs `shutdown /s /t 0`.

The base image is never mutated: a throwaway qcow2 overlay is booted on top. The
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
(`SKIP: …`, exit 0), so CI stays green. The always-run **offline** half of the proof
lives in the studio pytest suite and runs every pass:

- the `.bat` targets the right entrypoint, and `python -m hugmesh_studio
  --print-command` emits a builder command on Linux (`studio/tests/test_bat_launcher.py`);
- the bootstrapper's static contract: CRLF, label resolution, pinned winget IDs, consent
  gating, and the DETECT vocabulary, the same tokens this harness asserts
  (`studio/tests/test_bat_bootstrap.py`).

## Matrix QEMU e2e (`run-matrix-e2e.sh` — opt-in)

This boots the **whole device build matrix**: every `(platform, role, env, board,
flavor, desktop)` cell of `tests/build-matrix/matrix.tsv` (150 rows; the same single
source of truth `tests/build-matrix/check.sh` walks), under `qemu-system`. Per row it
asserts the **boot marker**, the image **SIZE**, and the runtime **LOAD** envelope.

Like `run-qemu-test.sh`, it **never builds anything**. It boots operator-supplied golden
`.img`/`.iso` artifacts (the `windows-studio-e2e.sh` operator-image contract). x86 rows
self-boot via `launch-x86.sh`, rpi5 via `launch-pi.sh`, every other aarch64 platform via
the generalized `launch-arm.sh`. The JOB-channel pseudo-roles are translated to their real
form, as the CLI leg of `tests/build-matrix/check.sh` documents: rpi5 `standalone-desktop`
→ `--role desktop --standalone`; ARM `flavor=standalone` → `flavor=installer --standalone`.

Every LIMIT is **read from the code**, never hardcoded:

- **SIZE** — `assert_size` reads `ROOT_MiB` from the row's builder `--print-plan`
  (`img_size=<ROOT_MiB>`, which every builder emits and `check.sh` already proves
  prints). It computes the compact layout `(1 + 512 + ROOT_MiB + 1) MiB` and asserts the
  built `.img` (or, for `compress=true` rows, its `xz --list` uncompressed size) does not
  exceed it. The Pi default is `9216` (`build-rpi5-stage4.sh`: `ROOT_MiB=9216`).
- **BUILD LOAD** — `assert_build_load` proves the 2026-07-15 host-freeze caps are wired
  into the docker build channel. `host_resources.build_memory_flag()` and
  `default_jobs()` produce the caps, `build_driver.docker_memory_args()` carries them as
  `--memory`, and `docker/build-image.sh` threads `-j "$JOBS"`. Native builds cannot be
  cgroup-capped, so this is a docker-channel invariant only.
- **RUNTIME LOAD** — `assert_runtime_load` re-boots the row under its **device RAM
  ceiling** (`ram_mb` in `device-catalog.json`, e.g. rpi3 = 1024, orin-nano-4gb = 4096).
  It asserts the row still reaches the boot marker with **no oom-killer**. This is a boot
  **envelope** check (does the image come up inside device RAM), *not* a peak-load stress
  test: a QEMU node with `kubernetes.bootstrap=false` does not exercise the cluster's real
  memory peak. Multi-SKU boards (rpi5/4, la-frite) declare no single ceiling, so their
  runtime-load re-boot is skipped, not guessed.

```bash
# ALWAYS-RUN, hermetic (no root, no boot, no builder): enumerate every row + resolve
# its launcher / normalized invocation / RAM ceiling. This is the CI-green half.
tests/qemu/run-matrix-e2e.sh --dry-run
make qemu-matrix-enumerate

# real boot (operator supplies golden artifacts under WORK_DIR):
HUGMESH_QEMU_E2E=1 make qemu-matrix MATRIX_FILTER=x86/backend-gpu
HUGMESH_QEMU_E2E=1 tests/qemu/run-matrix-e2e.sh --only jetson/edge-ai -w /srv/img
```

The gate matches the Tor onion e2e. Without `HUGMESH_QEMU_E2E=1` (and qemu) the boot path
**SKIPs cleanly** (exit 0). A missing artifact for a row is a per-row SKIP, never a FAIL.
EXPERIMENTAL boards (frite/jetson/orangepi) may be **INCONCLUSIVE** under `-M virt` (no
vendor firmware); that is recorded as a soft pass, not a FAIL. Under TCG on an x86 host
the full 150-cell walk takes many hours (no aarch64 KVM). Keep it nightly, and use
`--only` / `MATRIX_FILTER` for a subset.

The always-run **offline** half lives in the studio pytest suite
(`studio/tests/test_qemu_matrix_e2e.py`) and runs every pass with the gate unset:

- the harness-exists check;
- the matrix enumeration and per-platform census;
- the launcher resolution and the pseudo-role translation;
- the `(1 + 512 + ROOT_MiB + 1)` size formula and the `img_size=`-from-`--print-plan` parser;
- the `ram_mb` ceiling accessor;
- the driver's `--dry-run` (150 rows).

The pure Python view of the enumeration and the maths is
`studio/hugmesh_studio/core/build_matrix.py`.

## Saving the whole emulated mesh (`make qemu-save-mesh` — #50 item 10)

This saves everything done inside a running `--keep-alive` mesh as **one flashable set**
under `out/qemu-runs/saves/mesh-<stamp>/`: every device's disk **plus** the KEYS
provisioning stick it booted from. You can write the set to real hardware.

```bash
make qemu-save-mesh-plan                  # preview: devices, disk budget, KEYS pieces
make qemu-save-mesh                       # save every live device
make qemu-save-mesh SAVE_ONLY=rpi5        # label substring, like the runner's --only
PYTHONPATH=studio python3 -m hugmesh_studio.core.emulation_save save --only rpi5/pki
```

Per device, the set holds:

- `<label>.qcow2`, the disk, via `run-qemu-docker.sh --save-device`: standalone, merged
  over the golden, crash-consistent; the golden stays untouched;
- `<label>.keys/` and `<label>.keys.img`, the run's **exact** KEYS payload, copied back.
  Regenerating it would mint a login key the saved disk was never provisioned with;
- `<label>.id_ed25519[.pub]`, the key that logs into the saved system;
- a `mesh-save.json` manifest.

To reach real hardware: `qemu-img convert -O raw <label>.qcow2 <label>.img`, then flash it
like any built image. For the stick, run `sudo scripts/make-keys-usb.sh /dev/sdX
<label>.keys`.

Real saves are **9.5–20.5 GB each** (`sync=full` over fully allocated goldens). The
orchestrator budgets each disk's FULL virtual size (16 GiB, 32 GiB for x86). If the
space is short, it refuses the whole save, names the shortfall, and does so **before
pausing anything**. One device failing (the runner quarantines its partial as
`*.partial`) never touches another device's save. Core and tests:
`studio/hugmesh_studio/core/emulation_save.py`, `studio/tests/test_emulation_save.py`.
