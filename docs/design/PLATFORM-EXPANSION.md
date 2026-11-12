# Platform expansion: Studio hosts beyond Linux and Windows, RISC-V and MIPS images, and the planned devices

State: 🔭 planned (design only). Nothing here is built yet, and no lane starts
until the operator confirms the wider program. The only part that is in flight
is finishing the macOS host layer (section 2).

This document covers five things. It also says what is impossible and why.

- The Studio on BSD desktops (text UI and GUI).
- The Studio text UI on 64-bit Solaris and illumos.
- A 64-bit Solaris omnibus option.
- RISC-V and MIPS desktop and node images.
- What happens to every device the docs list as planned.

## 0. Scope and order

1. **Finish the macOS host layer first.** That is the open macOS pull request.
   Every other host lane is built on what it introduces:
   - `host_kind()`, the one function that names the host;
   - the typed `HostBlocker` sentence;
   - `entry.bootstrap()`, the per-process hook.
2. **Then the rest, only once the operator confirms.** The remaining lanes
   start only after that layer is merged and re-verified on main. Draft status
   protects nothing, so "merged" means checking what the merge actually took,
   not reading the pull request's state.
3. **File and hold.** Until the operator confirms the wider program, every
   other lane is filed on the board as held. None is started.

**Lanes that do not need the macOS layer.** These can run in any order once
confirmed:

- the guest host-facts experiment;
- the package resolution report;
- the mainline evidence table;
- the fail-closed flash plan;
- text-UI catalog parity;
- the catalog truth pass;
- the Orange Pi installer fix;
- the web admin channel;
- the silicon boots.

Everything else names the macOS layer, merged, as its first dependency.

## 1. Rules every lane follows

- **One place decides the host.** `host_kind()` returns linux, windows, darwin,
  bsd or sunos. No host may fall through to the Linux text or to the Windows
  text.
  - Every blocker travels as a `HostBlocker` that carries its kind.
  - Once a source scan shows every producer returns one, `blocker_kind()`
    raises on a plain string instead of reading it as Windows.
- **Greyed until proven.** On a new host, every feature starts greyed with one
  inline reason: a label beside the control, never a modal dialog. Only the lane
  whose CI or manual record proves a feature may un-grey it.
  - A completeness test fails if any host kind lacks a live, manual or greyed
    state, with a non-empty reason, for any feature.
- **GUI, text UI and CLI stay in parity.** All three read the same state and the
  same reason text. `--self-check` prints the same table.
- **Docs change in the same pull request as the proof.** They say only what that
  proof covers.
- **Proof labels:**
  - EMULATED: proven on a Linux x86-64 machine with QEMU and containers. This
    includes BSD and Solaris guests that VM actions boot on GitHub-hosted
    runners.
  - MANUAL: a person on real hardware. Every lane states which applies.
- **Secrets never appear on argv or in logs.** The local login account is never
  an administrator unless asked.
- **Guards are mutation-tested.** A new guard (source scan, completeness test,
  promotion test) is shown to fail by breaking the production code it protects.
  The lane says which mutations it ran.
- **Emitted and vendored files** (host tables, schema enums, image catalogs) are
  compared by tests and never rewritten by them.
- **Heavy work stays off shared workstations.** Image builds, QEMU boots and
  compose stacks run in CI or on a dedicated build host.

## 2. Finishing the macOS host layer

The macOS work is mostly done: an `.app` in a `.dmg`, Docker-only builds,
Terminal.app launchers and a macOS `--self-check` section. These are
runner-proven on arm64 and Intel macOS. To finish it, one engineer, who is the
only writer on that branch, does the following.

1. **Recover and fix the full review blocker list.** The earlier list was cut
   off after its first entry.
   - Re-run the refute review against the current head and record every blocker
     on the tracking issue.
   - Fix each one.
   - Prove the first blocker (Windows advice shown on a Mac missing the GNU
     tools) closed with one darwin test per consumer.
2. **Make CPU clamping visible everywhere it happens.** Docker on a Mac refuses
   a CPU cap above its VM's CPU count, so the cap is clamped. The build
   preflight already warns with both numbers and names `HUGMESH_CPUS`. The local
   stack and the mesh node clamp their compose limits the same way, so they must
   show the same warning in the GUI, text UI and CLI. No silent lowering.
3. **Check the Linux wording.** On Linux, the emulation tooltips and labels
   describe the Linux Docker lane, not QEMU for Windows.
4. **Fix the installer guide.** It still says macOS and BSD have no package. The
   macOS part points to the macOS section. The BSD claim is removed, because
   nothing proves it today; the BSD lanes restore it per OS once CI proves it.
5. **Re-run prove and refute on the final head.** The operator marks it ready
   and merges.

Then:

- the `.dmg` is published on a signed Studio release;
- the site offers it;
- the org profile lists macOS with EXPERIMENTAL image builds.

**Local login agent.** It checks which local user connected through
`SO_PEERCRED` or `/proc/net/tcp`. Where neither exists (macOS, BSD, Solaris) it
currently fails open with a warning. Since the macOS layer enables the local
Docker stack on a Mac, the agent will refuse the loopback login handoff on any
host where it cannot check the peer, and show a greyed reason.

- This rule is based on what the host can check, not on its name, so BSD and
  Solaris are covered as soon as it lands.
- Where a real check exists it is used: `getpeereid` / `LOCAL_PEERCRED` on an
  AF_UNIX transport.
- The operator may keep macOS fail-open (see the decisions at the end).
- Windows is outside this work.

## 3. The Studio on BSD desktops

**Which BSDs.** All x86-64, because VM actions boot them on hosted runners:

- FreeBSD 14 and 15;
- OpenBSD 7.8 and 8.0;
- NetBSD 10 and 11;
- DragonFly, as offered by the VM action (6.4.x).

DragonFly's text UI and GUI packages (urwid, PyQt6) are confirmed in its newer
package repository, not in the release the VM action boots. So DragonFly is
listed only if the guest experiment installs them on the guest that exists.
FreeBSD arm64 and every other CPU are not claimed until a person runs them.

**Detecting the host.**

- `host_kind()` gains `bsd`, covering freebsd, openbsd, netbsd and dragonfly.
- `host_arch()` gives the CPU from `uname -p`, never from what Python reports
  for the machine.

**What works natively in the first version (plan and hand off).**

- The text UI (urwid, or the plain numbered prompts) and the CLI. Both are
  Qt-free: every core and text-UI module imports without Qt.
- A person can design an image in the wizard, save and manage sessions, and
  print the exact build command and plan.
- They can also write a worklist file for a Linux build host to run.

**GUI.**

- FreeBSD uses PySide6 from its ports, which are packaged for amd64 and aarch64.
- OpenBSD, NetBSD and DragonFly use PyQt6 from the OS package manager. The
  Studio already falls back to PyQt6.
- PyQt6 is never bundled or frozen, so the licence rule for frozen builds is
  untouched.
- A GUI is claimed only for a BSD whose offscreen CI smoke passed, plus a manual
  check on a real desktop.

**Greyed on BSD in the first version, one reason each:**

| Feature | Reason |
|---|---|
| Native build | Needs Gentoo Linux, chroot and loop devices |
| Docker build | No local Linux Docker engine. A remote `DOCKER_HOST` cannot see the builder's bind mounts |
| Emulation, local mesh, kind and DevOps lanes | Need Linux Docker plus GNU make and bash |
| Go Live (every target) | Its emulated target needs this host's emulation, which is greyed; its local target is a bash driver |
| Cloud deploy, phone wizard, keys ZIP and keys USB | Bash drivers that need GNU `stat`, `sha256sum`, `mktemp` and `base64`, or Linux disk tools. On BSD the GNU tools are g-prefixed, so the macOS PATH hook does not carry over |
| Hardware scan | Reads `/proc` and `lspci` |
| Local AI | Ollama is unproven on these hosts |
| Local login | No peer check over loopback TCP (section 2) |

Memory-based sizing has no `/proc/meminfo` here. `--self-check` says so in one
line instead of silently dropping the limits.

If a later lane un-greys a feature that calls `make`, it calls
`gmake SHELL=<bash> JOBS=<n>` rather than editing the Makefile.

**Flashing.** No live device picker. The blocker text gives the exact manual
commands:

- FreeBSD: `geom disk list`, then `dd if=IMAGE of=/dev/daN bs=4m status=progress`
  and `sync`;
- OpenBSD: `sysctl hw.disknames`, then the raw `c` partition;
- NetBSD: `sysctl hw.disknames`, then the raw `d` partition.

A native writer is deferred until a person has proven one on hardware.

**Image builds on a host with no Linux Docker.**

- *First version:* no local backend. The Studio exports the worklist and prints
  the command for a Linux machine.
- *Second step:* a remote Linux build host over SSH, one backend for BSD,
  Solaris, illumos and a Mac without Docker:
  - key-based SSH with the host key pinned in `known_hosts`, and no
    trust-on-first-use prompt;
  - a remote preflight: Docker reachable, a generator checkout at the Studio's
    commit, free disk;
  - the same builder argv the Docker backend runs locally;
  - secrets only over SSH stdin or a mode-0600 remote env file that is removed
    afterwards;
  - logs streamed back, artifacts copied back with checksums, and cancel killing
    the remote process group.

  The backend is greyed with a reason until a host is configured and its
  preflight passes.
- *Rejected:* a per-OS local Linux VM (bhyve, vmm, NVMM). It differs per OS and
  has no shared-folder story proven on any of them.

**Install path.**

- The Studio ships as a signed pure-Python wheel and sdist on each Studio
  release.
- PySide6 moves from a hard dependency to a `gui` extra, since no PySide6 wheel
  exists for BSD or Solaris. The frozen Linux, Windows and macOS builds already
  install it from their own locked requirement files.
- Install on BSD:
  1. Install Python, urwid and (for the GUI) the Qt binding from the OS package
     manager.
  2. Create a venv with `--system-site-packages`, so those packages are visible.
  3. `pip install` the wheel.
- `--self-check` prints the exact install line for the host, and CI runs that
  line verbatim.
- A FreeBSD port, an OpenBSD port and a pkgsrc package are deferred: each needs a
  maintainer.

**CI.**

- A `bsd` job in the Studio test workflow uses the VM actions, pinned by commit
  SHA, and records the guest image digest. It:
  1. captures the host facts (`uname`, `sysctl`, package list) as fixtures;
  2. proves that a stock guest's `--self-check` refuses and names the missing
     packages;
  3. runs the documented install line;
  4. proves `--self-check` then passes, with a BSD section and the greyed
     reasons;
  5. runs a named-file text-UI and CLI contract list and a scripted plain-text-UI
     session that writes a worklist and a printed command;
  6. checks the single-instance AF_UNIX path socket.
- A GUI step renders the Role and Build pages offscreen at 1200x800 and 942x552,
  with box-geometry assertions so no reason label is clipped.
- Before this job is written, a dispatch-only experiment boots each guest,
  records facts and an argv log, and sizes the contract list. The PR job
  therefore starts from measured fixtures.

## 4. The Studio text UI on 64-bit Solaris and illumos

**Detecting the host.**

- `host_kind()` gains `sunos`.
- Solaris and illumos are told apart by `uname -o` and `/etc/release`.
- `host_arch()` uses `isainfo -k`, because Python reports `i86pc` or `sun4v` for
  the machine and no arch table must ever see those.

| Flavour | CPU | Text UI and CLI | Proof |
|---|---|---|---|
| Oracle Solaris 11.4, SRU 78 or later, or CBE 11.4.81 or later (these carry Python 3.11 and 3.13) | x86-64 | yes | EMULATED (Solaris VM action) |
| Oracle Solaris 11.4 | SPARC64 (sun4v) | "not tested" until a person records it | MANUAL only: no SPARC64 Solaris VM exists and QEMU cannot boot 11.4 on sun4v |
| OmniOS (r151056 or later), OpenIndiana | x86-64 | yes | EMULATED (VM actions) |

**What works.** The same plan-and-hand-off set as BSD.

- urwid is pure Python and comes from pip in the venv. Without it, the plain
  numbered prompts run.
- GNU tools are under `/usr/gnu/bin`, but every feature that needs them is
  greyed in the first version anyway.
- Elevation is never needed, because the native backend is refused.

**GUI: not offered.** No Qt 6 Python binding is packaged for Solaris or
illumos. The docs say exactly that, and the GUI entry prints "use the text UI"
with that reason.

**Flashing.** Manual text only: `rmformat -l`, then
`dd if=IMAGE of=/dev/rdsk/cXtYdZp0 bs=4M`.

**Builds.** Export and hand off in the first version, then the SSH build host. A
Studio on SPARC64 is a full designer: it builds x86-64 or ARM images on a Linux
build host over SSH.

**Install path.** The same wheel. Python comes from IPS: `pkg install` of the
Python package on Solaris and OmniOS, the OpenIndiana package otherwise. An IPS
package of the Studio is deferred.

**CI.** A `sunos` job, the same shape as the BSD job, for Solaris 11.4 CBE,
OmniOS and OpenIndiana. Before this job is merged, check that the Solaris CBE
licence allows CI use. The SPARC64 row is added to the docs only with a person's
recorded `--self-check` and plain-text-UI transcript.

**Deferred.** illumos as a mesh client through its packaged tailscale. It is not
part of this work.

## 5. A 64-bit Solaris omnibus option

**What the operator gets.**

- The existing x86-64 omnibus image, unchanged: raw `.img`, the same UEFI GRUB
  and shim chain, already proven under q35 with OVMF.
- A Studio-written run recipe next to it, for an illumos bhyve zone:
  - a `zonecfg` command file;
  - the commands that copy the raw image into a ZFS volume;
  - a README.

The recipe sets:

- a UEFI boot ROM;
- virtio disk and network;
- 16 GB or more of guest RAM (24 GB or more on the host);
- a vnic on a physical link, or an etherstub with NAT, so the guest is
  reachable;
- a serial console through `zlogin -C`, with VNC for the UEFI framebuffer;
- a pre-check that the CPU has hardware virtualisation (`bhhwcompat`).

**What runs where.**

- The illumos host runs only bhyve.
- The Linux guest runs every HugMesh service exactly as on x86-64 hardware.
- The operator administers the guest over SSH or the mesh through the vnic, and
  uses the serial console if networking fails.

**Where it is true.** illumos on x86-64: OmniOS first, OpenIndiana only if a
person proves it too. Even there, the option is greyed ("not yet proven on an
illumos host") until a person records the evidence:

- the guest boots;
- they log in on the serial console;
- they reach the guest from the host over the vnic;
- the cluster is Ready and the node has joined the mesh.

After that the option is EXPERIMENTAL.

**Impossible, and the docs say why:**

- *A native Solaris or illumos omnibus.* Kubernetes, containerd and every
  workload image are Linux.
- *Any SPARC64 omnibus.* Go has no SPARC64 port for Linux or Solaris, so
  headscale, tailscale and kubelet cannot be built, and no workload image exists
  for SPARC64. Linux in an LDom is unsupported by Oracle and would not close that
  gap.
- *Oracle Solaris 11.4 on x86-64 as the host.* Kernel zones run only Solaris, and
  no Linux-guest hypervisor is proven on 11.4. Not offered.
- *lx-branded zones.* Not pursued: kubelet and containerd need Linux cgroups and
  namespaces that are unverified there. Nothing claims otherwise.

## 6. RISC-V and MIPS

Before any builder work, two measurements run in CI or on a build host, in the
existing builder image, with no image build:

1. **A package resolution report** for riscv64 and MIPS. A pretend resolve over
   each role's package set gives a measured reason for every greyed role.
2. **A mainline evidence table.** It lists the device-tree and defconfig pair
   for each candidate board, and a test refuses to promote a catalog row without
   a "found" entry.

### RISC-V (riscv64)

**Platform.**

- New platform key `riscv64`, cross-built like the ARM platforms: crossdev for
  `riscv64-unknown-linux-gnu`, and a static `qemu-riscv64` user emulator for the
  chroot-only steps.
- Seed: the `rv64_lp64d` openrc stage3. The shared-assets seed matcher learns
  that this name belongs to riscv64.

**Profile.** `default/linux/riscv/23.0/rv64/lp64d`, stacked with
`features/hardened` and `features/selinux`.

- This is a project-assembled stack, because Gentoo ships no hardened or SELinux
  riscv profile. The docs say so.
- The builder's profile check validates every parent line.
- An image ships only if enforcing SELinux is proven at boot in QEMU (see the
  decisions at the end). Otherwise the platform stays greyed with that reason.

**Kernel.** `gentoo-sources` with the riscv defconfig plus a riscv hardened
fragment.

**Boot.**

- OpenSBI and U-Boot reading `extlinux.conf`, the same distro-boot model as the
  ARM builders.
- OpenSBI and U-Boot are not compiled here. The QEMU target uses QEMU's bundled
  OpenSBI. Real boards use the vendor's SPI firmware, which is a documented
  precondition.

**Mesh client.** tailscale from the upstream riscv64 tarball, pinned by
checksum. The auth key is read from a file.

**Roles.** riscv64 has no node-role axis, like the Frite and Allwinner Orange Pi
platforms.

- Its image is a headless mesh-client appliance (no Kubernetes, no headscale),
  with a `--desktop none|light` axis.
- `light` (LXDE with lightdm and a browser built from source) lands in a second
  lane. It is offered only if the browser builds. There is no prebuilt Firefox
  for riscv64.
- Every node role (pki, backend, frontend, omnibus, backend-gpu, edge-ai, and the
  server form of `generic`) is shown greyed with one reason: Kubernetes is not
  published for riscv64. kubelet, kubeadm, kubectl and cri-tools carry no riscv
  keyword, and the control-plane and pause images have no riscv64 build.
  headscale has no riscv64 release, and several workload images are amd64 and
  arm64 only.
- Secure Boot and the keys USB are greyed: that chain is x86-only and shim has no
  riscv keyword.
- The standalone desktop's login account is not an administrator.

**Boards.**

1. `riscv64-virt`, the generic QEMU target and the proof target. The harness
   boots it with `-M virt`, OpenSBI and a direct kernel, and the runner image
   gains the riscv system emulator.
2. StarFive VisionFive 2 (JH7110) as an EXPERIMENTAL board row, only if the
   evidence table finds its mainline pair. Silicon boot is MANUAL.
3. Banana Pi BPI-F3 stays refused. New reason: builder exists; SpacemiT K1
   mainline support not confirmed.

### MIPS (mips64el and mips64)

**Documented as not possible.** The catalog gains a `mips64el` arch with one
QEMU-generic device, shown greyed in the GUI, text UI and CLI. Its reason comes
from the measured resolution report. In the tree today:

- no SELinux policy keyword;
- no containerd, runc or Kubernetes;
- no graphical browser, greeter or panel;
- no MIPS build of any workload image;
- Gentoo MIPS is a testing-only arch.

No builder is written. A headless MIPS image without SELinux would break the
hardened baseline every image carries. It would need its own request.

## 7. Every planned device

| Group | Disposition | Proof |
|---|---|---|
| 9 supported rows (x86 PC, laptop, Chromebook, Pi 5/4/3, Le Frite, Le Potato, Sweet Potato) | Unchanged. Docs keep "recipe, not silicon-proven" | MANUAL boots, per board |
| 15 experimental rows (Jetson Orin family, Orange Pi 5 and 5 Plus, Zero 2/2W/3, 3 LTS, 4 LTS, Pi 400, CM4, Pi 500, CM5) | Stay EXPERIMENTAL until a person boots one image per family and logs in | MANUAL |
| Jetson `l4t` kernel flavour | A stub that exits non-zero: removed from the offered choices and shown greyed with its reason | EMULATED (tests) |
| Orange Pi installers' SPI write | Ship `mtd-utils`, or remove the SPI write path and its offer | EMULATED content guard; MANUAL write |
| Orange Pi 5 node raw image, Orange Pi 4 LTS U-Boot compilation | Deferred, reasons kept | none |
| Radxa Rock 5B, FriendlyElec NanoPC-T6 | Finished as EXPERIMENTAL board rows on the Orange Pi 5 builder, gated by the evidence table | EMULATED rootfs under virt; MANUAL silicon |
| Orange Pi 5 Pro, 5 Max, 3, 4 | Deferred: need a person with the board to validate | none |
| Boards needing a new boot chain (Amlogic SM1/G12B, RK3328, RK3568, generic RK3399, older Jetsons, Coral, Orange Pi 6), Banana Pi M7, armv7 boards | Stay refused, each with its reason | none |
| Raspberry Pi 6 | Row removed: the product does not exist | EMULATED (catalog test) |
| VisionFive 2, BPI-F3, mips64el | See section 6 | as stated there |
| Meshtastic firmware, LoRaWAN | Deferred. Design-only banners kept, off the site | none |
| Phones, Quest | Existing tracking only | none |

**Wording fixes in the same pass.**

- The Orange Pi 4 versus generic-RK3399 wording is reconciled.
- The claim about omnibus on a Pi 4 is reconciled.
- The Jetson encryption wording is reconciled.
- Rationales that cite outside threads are rewritten as in-tree reasons.
- The ROCm future-path sentence becomes "CUDA only".
- The walkthrough's counts are checked against the catalog.

**Channel parity, needed before any new device.**

- The text UI browses the catalog: arch, then family, then device. Refused rows
  are shown with their reasons.
- The CLI gains `--list-devices`.
- The flash plan and arch tables refuse an unknown platform instead of falling
  back to the x86 menu.
- The web admin channel accepts every generator platform, from the vendored
  schema rather than a hand list. Platforms the image worker cannot build are
  shown greyed.

## 8. CI and supply chain

- VM-action guest images come from third parties.
  - Each action is pinned by commit SHA, and each guest image digest is recorded
    in the host-facts artifact.
  - Guest jobs get no secrets and a read-only token, and never run in release
    workflows.
  - Whether they may gate pull requests is a decision for the operator.
- Hosted-runner KVM availability is unmeasured, so guest jobs budget for TCG
  speed. Non-x86 guests only run nightly.

## 9. File ownership and order

Several lanes edit the same files, so each lane starts from the merged result of
the one before it. After rebasing, it asserts that the earlier lane's additions
survived.

| File | Order |
|---|---|
| The Studio test workflow | macOS finish, then login agent, then BSD job, then Solaris job, then BSD GUI step, then SSH builder test |
| The Studio release workflow | `.dmg` publish, then wheel and sdist |
| The site and the org profile | macOS first, then BSD and Solaris once their CI has passed, each in its own pull request |
| The device catalog | truth pass, then Rock 5B and NanoPC-T6, then MIPS row, then riscv64 platform, then VisionFive 2 |

## Decisions the operator owns

Each has a default that applies if nobody answers.

1. **Does the wider program start?** Default: only the macOS finish and its
   follow-ups run; everything else stays filed as held.
2. **Local login agent on macOS.** Fail closed (local login greyed with a
   reason) or keep fail-open with a warning. Default: fail closed.
3. **riscv64 and SELinux.** Ship only if enforcing SELinux is proven in QEMU, or
   ship labelled "no SELinux", or do not do riscv64. Default: ship only if
   proven; otherwise grey the platform.
4. **What a 64-bit Solaris omnibus means.** Default: the existing x86-64 omnibus
   image as a bhyve zone guest on illumos x86-64, greyed until a person boots it.
5. **Whether jobs that boot third-party guest images may gate Studio pull
   requests.** Default: non-required checks, pinned by SHA, no secrets, never in
   release workflows.
