# The build matrix — every option, every channel, verified

_State key: **✅ shipped** (on `main`) · **🚧 in-flight** · **🔭 planned**._

This repo builds a **matrix** of images: platform × role × build ENV, plus each
platform's own axes. Four scriptable front-ends ("channels") expose it, and a
fifth is triggered from the admin UI. This page describes the matrix, the
channels, and the harness that keeps them in step.

## The standing rule: all options in all menus

> Every documented image option must be reachable from every build channel.
> (Standing rule — [`specs-jetson/README.md`](../specs-jetson/README.md).)

Anything the CLI can build (a role, board, flavor, desktop weight or builder
flag) must also be buildable from `make`, the ncurses menu and the Studio GUI,
and the reverse. A channel with no widget for a flag must still let you
*express* it: the menu and the Studio have an **extra-flags escape hatch** for
that. A new option lands in **all four channels in the same change**, with a row
or axis in the canonical matrix below.

### Four-choice taxonomy parity

The Studio GUI's four-choice opening screen
([`gui/pages/mode.py`](../studio/hugmesh_studio/gui/pages/mode.py); the flow is in
[`docs/STUDIO-WIZARD-FLOW.md`](STUDIO-WIZARD-FLOW.md)) is the **reference**
taxonomy: **Mesh node** / **Local Docker mesh** / **Mesh desktop client** /
**Standalone Gentoo desktop**. Every channel with an opening choice repeats those
four labels verbatim: the ncurses menu's `mode_screen()`
([`scripts/build-menu.sh`](../scripts/build-menu.sh)) and the CLI's guided `--help`
(`print_intents_guide` in [`docker/build-image.sh`](../docker/build-image.sh)). The
three *image* choices only change navigation, so the emission the matrix guards is
byte-identical.

The **`TAXO` bucket** in [`tests/build-matrix/check.sh`](../tests/build-matrix/check.sh)
enforces this the way the `JOB` and `COVG` buckets work: it copies the code. The
golden set is extracted **live** from `mode.py` with grep, because `mode.py`
imports Qt and cannot be imported Qt-free. A canary asserts the reference taxonomy
is **exactly four**, so a silent shrink or growth trips the gate. A bogus label
must be absent from every channel, so the check cannot pass vacuously. Each of the
four labels must appear in both the menu and the CLI guide. The bucket is
fail-closed: it expects a fixed pass count, and a shortfall is a failure.

**Local Docker mesh (choice ii) is the one non-build channel.** It builds no image
and has **no matrix row and no emission**. It runs a dockerized node on the
operator's own machine through the Qt-free entrypoint of
[`core/local_mesh.py`](../studio/hugmesh_studio/core/local_mesh.py)
(`python3 -m hugmesh_studio.core.local_mesh`, wrapped by `make mesh-node-up`). The
GUI launcher, the ncurses `local_mesh_screen` and the Makefile targets share it
verbatim. It never enters `resolve_build_target` or `build_make_cmd`.

**The MDM phone wizard (✅) follows the same non-build rule.**
[`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh) ([`MDM.md`](MDM.md)) builds
no image. It flashes an externally released, signature-verified GrapheneOS
artifact onto a USB-connected Pixel. The phone is therefore **not a matrix row,
not a platform, not an emission and not a channel choice**. It never enters
`resolve_build_target` or `build_make_cmd`, and the harness deliberately does not
gate it.

**Cloud image packaging follows the same rule.**
[`scripts/cloud-package.sh`](../scripts/cloud-package.sh)
([`CLOUD-IMAGE-PACKAGING.md`](CLOUD-IMAGE-PACKAGING.md)) re-packages an
**already-built** x86 raw `.img` as `qcow2`, fixed `VHD` or checksummed raw for
cloud import. Output format is a property of a finished artifact, not an image
option, so it is **not a matrix row, not an axis and not a channel choice**. It
never enters `resolve_build_target` or `build_make_cmd`, the builders' emission is
untouched, and the harness does not gate it. Its own hermetic suite is
`tests/scripts/test-cloud-package.sh`.

**Per-user first-login `registration` (discord / gmail / password / derive) is
manifest-only.** It is an additive `User.registration` field in the Studio
`users.py` and `--print-specs`. The ncurses and CLI image builders carry no
per-user mesh manifest, so it is **not** a menu or CLI image-build knob. The
`TAXO` bucket asserts its four tokens in the Studio users surface only; asserting
them on channels that do not offer them would be vacuously green.

## The four scriptable channels

| Channel | Entry point | How a build is described |
|---|---|---|
| **CLI** | `./build-{rpi5,x86-host,frite,jetson,orangepi5,orangepi-zero2,orangepi-zero2w,orangepi-zero3,orangepi3-lts,orangepi4-lts}-stage4.sh` | flags (`--role`, `--env`, `--board`, `--flavor`, `--desktop`, …) |
| **make** | `Makefile` targets (`make x86-<role>`, `make rpi-<role>`, `make frite`, `make jetson-<role>`, `make orangepi5`, `make orangepizero2`, `make orangepizero2w`, `make orangepizero3`, `make orangepi3-lts`, `make orangepi4-lts`, `make build-all`, `make build-everything`) | make vars (`ENV=`, `BRAND=`, `RPI_BOARD=`, `FRITE_*=`, `JETSON_*=`, `ORANGEPI5_*=` (and the same per Orange Pi platform), `IMG_FLAGS=`, `STANDALONE_FLAGS=`) |
| **ncurses menu** | `make menu` (`scripts/build-menu.sh`) | interactive screens persisting `OPT_*` state; composes the same make invocation |
| **Studio GUI** | `studio/` (`python -m hugmesh_studio`) | wizard pages over `ImageConfig`; the same config drives the headless `--print-command` |

`build-rpi5-stage4.sh` is a **single builder covering three boards** through
`--board rpi5\|rpi4\|rpi3`, not a separate script per board. See "Board axes vs.
new builders" below.

**Arch-first device taxonomy** ✅ (Studio) / 🔭 (menu, CLI guided help): the
Studio's machine tier now offers an architecture selector over a family-grouped
**device catalog** (`studio/hugmesh_studio/core/device_catalog.py` +
`core/device-catalog.json`). The catalog carries the #351 honesty statuses:
supported; experimental (labelled); unsupported (visible but not selectable, with
the reason shown). A device is exactly a `(platform, board)` pair, and its roles
are **derived** from `ROLE_CHOICES` + `rpi_boards_for_role()`. This regroups
selection and leaves emission untouched; the GUI column and the byte-identical
`matrix.tsv` guard it. The web/JOB channel gets the same hierarchy from the
`archs`/`families`/`devices` keys of
[`docs/catalog/image-catalog.json`](catalog/image-catalog.json); the `CAT` bucket
(6 assertions) pins its honesty. The ncurses menu and CLI guided help should
render from that committed JSON; see the PARITY-TODO in
[`docs/STUDIO-WIZARD-FLOW.md`](STUDIO-WIZARD-FLOW.md).

Every channel is crossed with the **build ENV** (`test` | `prod`), passed as
`--env` to the builders and as `ENV=` through make. See the
[Build ENV section of the README](../README.md#build-env-testprod-baked-at-image-creation).

The **fifth channel** is triggered from the admin web UI: the image-gen **k8s Job**
worker (`docker/build-image.sh`, launched by admin-bff-api). It maps the Job
contract's `IMAGE_TYPE` + `HARDWARE_CLASS` strings onto the same generator build
targets through its own role whitelists (the `HARDWARE_CLASS` convention in that
script's header). It deliberately has no `env` axis, because the Job contract
carries no hardening-tier field, so every Job build gets the fail-secure `prod`
posture. It has no frite `desktop` axis. It has no `flavor=both` on any
live/installer platform, because its ingest contract reports exactly one
`imageRef` per build, so a two-artifact flavor is a clean rejection wherever it
would apply.

The standalone/LUKS posture **is** reachable through this channel on rpi5, frite
and every Orange Pi platform, mirroring x86's standalone-thin, standalone-thick
and standalone-unaffiliated roles. rpi5 gets a dedicated `standalone-desktop` role
token, because it already has a role axis to extend. Frite and the Orange Pi
desktops have no desktop role axis (the Orange Pi 5 and 4 LTS node roles refuse
`--standalone`), so they signal the posture with a `standalone` *flavor* value. Both normalize onto the real build target plus
`--standalone`/`--local-user` (see the `HARDWARE_CLASS` convention in the header
of `docker/build-image.sh`). Jetson is the one deliberate exception. Its builder
hard-errors on `--standalone` and `--encrypt-root`: the Orin's single boot+root
partition would leave UEFI firmware unable to find a kernel if it were encrypted
(see STANDALONE-DESKTOP.md's Jetson section). So this channel gives Jetson no
`HARDWARE_CLASS` token for the posture either (see the "JETSON STANDALONE
EXCEPTION" note in the same header).

## The canonical matrix — `tests/build-matrix/matrix.tsv`

One row per buildable image cell `(platform, role, env, board, flavor,
desktop)`; `-` marks an axis a platform does not have. **170 cells** today
(includes 16 JOB-channel-only standalone-posture probe rows, see below):

### The role vocabulary — one spelling, everywhere

A role token means the same thing, spelled the same way, on every platform and in
every channel. It is declared **once**, in `scripts/_roles-lib.sh`. Every builder
sources that file, and `studio/hugmesh_studio/core/roles.py` reads it:

| Canonical | What it is | Platforms |
|---|---|---|
| `pki` | cluster CA / control plane | x86, rpi5, orangepi5 |
| `backend` | backend k8s worker | x86, rpi5, orangepi5 |
| `frontend` | frontend k8s worker | x86, rpi5, orangepi5, orangepi4-lts |
| `backend-gpu` | backend worker + GPU, no inference service | x86, jetson |
| `omnibus` | every cluster role on one node | x86, jetson, rpi5 (Pi 4 / Pi 5), orangepi5 |
| `edge-ai` | GPU inference node (OpenAI-compatible model API) | x86, jetson |
| `generic` | plain unbranded arm64 server | rpi5 |
| `laptop` `chromebook` `desktop` | person-device desktops | x86 (+ `desktop` on rpi5/jetson) |
| `standalone-thin` `standalone-thick` `standalone-unaffiliated` | no mesh, no SSO | x86 |

The Orange Pi node roles are EXPERIMENTAL (no Orange Pi has booted an image from this
repo; hardware validation pending) and installer-only. On a Raspberry Pi or an Orange
Pi, a node role takes the board's RAM as `--ram-gb N` (`RAM_GB=N` in make and
build-all, the RAM column in the Studio worklist, the RAM picker in the menu, a
trailing `.<N>gb` field on the Job channel): one image serves every RAM size a board
is sold with, so the build cannot see it. `omnibus` REQUIRES it and needs 16 GB or
more; backend is refused below 8 GB and pki/frontend below 4 GB when it is given
(`HUGMESH_ROLE_MIN_RAM_GB` in `scripts/_roles-lib.sh`). A board that is not sold
with enough RAM for a role is refused it outright, so the Pi 4 (8 GB at most) is
never an omnibus. The numbers come from the live single-node kind cluster: every
namespace together asks the scheduler for about 8.3 GiB of memory, the backend
tier alone for 4 GiB. The Orange Pi 4 LTS (4 GB,
16 GB eMMC) builds only `frontend`; the Allwinner boards and Frite build no node role.
Every refusal names its reason (`HUGMESH_ROLE_REFUSAL`).

The old spellings are **accepted forever** on every CLI that documented them. They
are normalized at parse time, so nothing downstream sees two names for one role:
`be`=backend, `fe`=frontend, `be+gpu`/`be-gpu`/`host`/`gpu-host`/`gpu_host`=backend-gpu,
`full`=omnibus, `edge_ai`=edge-ai, `standalone-full`=standalone-thick. They are
never EMITTED. `tests/scripts/test-role-key-spelling.sh` fails on an alias in an
artifact name, a role marker, a matrix cell, a catalog id or a documented
command.

One canonical role is the **prefix** of another: `backend` of `backend-gpu` (and,
among the aliases, `be` of `be-gpu` and `full` of `standalone-full`). Artifact names
put the role between hyphens, so a plain `*-backend-*` glob also matches
`<brand>-x86-amd64-backend-gpu-<env>-<ts>.img`. With the default x86 fleet built in
one work dir (`pki backend frontend backend-gpu`), the GPU image is always the
newest, so the wrong pick is deterministic, not a race. Every artifact consumer
(the flasher, the three QEMU launchers, the container harness) therefore filters
its role-scoped candidates through `hugmesh_role_shadow_filter`. A request for
`backend` with only a `backend-gpu` image present resolves to NOTHING, not to the
GPU image: `scripts/flash-disk.sh` writes a whole physical disk, so refusing is the
safe answer. `tests/scripts/test-role-key-spelling.sh` section D7 asserts it.

The k8s label keys (`hugmesh.net/backend`, `/frontend`, `/pki`, `/edge-ai`) are a
DIFFERENT axis and **not** part of this vocabulary. They were always long,
`scripts/tooling/tokens.json` freezes them, and 73 files under `specs/cluster/` use
them in a `nodeSelector`. The builders' `ROLE_LABELS` is print-only, so the CLI
token and the label key are fully decoupled.

| Platform | Builder | Cells | Axes |
|---|---|---|---|
| **rpi5** | `build-rpi5-stage4.sh` | board `rpi5`(default): 5 roles × 2 env = 10; board `rpi4`: 4 roles × 2 env = 8 + 2 `standalone-desktop` probe rows; board `rpi3`: 1 role × 2 env = 2 → **22** | roles `pki backend frontend omnibus desktop` (rpi5 — all 5, omnibus rows probed with `--ram-gb 16`; rpi4 — all but omnibus, which needs 16 GB and a Pi 4 has 8 GB at most); `desktop` only on `rpi3` (1 GB RAM has no headroom for the k8s cluster-node stack); board `rpi5\|rpi4\|rpi3`; JOB-channel-only role `standalone-desktop` (resolves the same `--role desktop`, plus `--standalone`) |
| **x86** | `build-x86-host-stage4.sh` | 12 roles × 2 env = **24** | nodes `pki backend frontend backend-gpu`, `omnibus`, `edge-ai`, clients `laptop chromebook desktop`, `standalone-thin standalone-thick standalone-unaffiliated` |
| **frite** | `build-frite-stage4.sh` | 3 boards × 3 flavors × 2 desktops × 2 env = 36 + 2 `standalone` probe rows → **38** | board `la-frite\|le-potato\|sweet-potato`, flavor `live\|installer\|both`, desktop `light\|none`; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **jetson** *(EXPERIMENTAL)* | `build-jetson-stage4.sh` | 4 roles × 2 env on `orin-nano` + 3 boards × 2 env on `edge-ai` = **14** | roles `edge-ai backend-gpu omnibus desktop`; board `orin-nano\|orin-nano-4gb\|orin-nx-8gb\|orin-nx-16gb` (non-default boards carried on the headline `edge-ai` role); deliberately **no** standalone token (see above) |
| **orangepi5** *(EXPERIMENTAL)* | `build-orangepi5-stage4.sh` | desktop: 2 boards × 3 flavors × 2 env = 12 + 2 `standalone` probe rows; nodes: 4 roles × 2 boards × 2 env = 16 (installer) → **30** | board `orange-pi-5-plus\|orange-pi-5` (RK3588 vs RK3588S), flavor `live\|installer\|both` for the `desktop`; cluster node roles `pki backend frontend omnibus` are installer-only (`--flavor live\|both` is refused) and omnibus rows are probed with `--ram-gb 16`; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepizero2** *(EXPERIMENTAL)* | `build-orangepi-zero2-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; headless only — Allwinner H616 has no mainline display-engine driver, so this platform never gets a `desktop` role; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepizero2w** *(EXPERIMENTAL)* | `build-orangepi-zero2w-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; the Zero 2's Allwinner H618 sibling — same headless-only rationale (identical DE33 display engine, no mainline driver) and NO onboard Ethernet (USB-Ethernet-first); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepizero3** *(EXPERIMENTAL)* | `build-orangepi-zero3-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; the Zero 2's Allwinner H618 sibling — same headless-only rationale (identical DE33 display engine, no mainline driver) but onboard Gigabit Ethernet is BACK (Ethernet-first, unlike the Zero 2W); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepi3-lts** *(EXPERIMENTAL)* | `build-orangepi3-lts-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; Allwinner H6 — headless by SCOPE decision (unlike the H616 siblings' hard driver gap; see the specs README), boots the PLAIN Orange Pi 3's mainline DTB/defconfig (no `-lts` variant upstream), USB-Ethernet-first (the GbE jack is dead on that DTB); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepi4-lts** *(EXPERIMENTAL)* | `build-orangepi4-lts-stage4.sh` | 1 role (`desktop`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; Rockchip RK3399 — the one Orange Pi platform here that is a LIGHT DESKTOP rather than a headless appliance (the mainline `rk3399-orangepi` DTB it boots has an enabled Mali-T860 GPU, enabled HDMI and both VOPs), so role `desktop` like `orangepi5`; but SINGLE-BOARD like the appliances (mainline ships one Orange Pi RK3399 DTB/defconfig for the whole 4/4B/4 LTS family), so no `--board` axis and no `--desktop` axis; blob-free boot chain; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`). Plus the `frontend` cluster node role × 2 env = 2 rows (installer only; pki/backend/omnibus refused: 4 GB RAM, 16 GB eMMC) → **10** |

Adding an image option means adding or extending rows here. The harness then holds
every channel to it.

### Board axes vs. new builders — when to add which

Two cases of related hardware look alike but resolve differently:

- **Same platform family, same install/boot model: extend the existing builder
  with a `--board` axis.** `build-rpi5-stage4.sh` covers Pi 5/4/3 this way (a
  `select_board()` table fills CPU, defconfig, DTB and kernel image only when not
  explicitly overridden), and Jetson covers the Orin SKUs the same way.
  Board-exclusive hardware becomes a small additive kernel-config fragment
  (`rp1-pi5.config`, `bcm2711-pi4.config`, `bcm2837-pi3.config`) layered on a
  shared base (`hardened-k8s.config`), not a fork of the builder.
- **Different SoC vendor, boot chain or install story: a new builder script.**
  Orange Pi 5 (Rockchip RK3588, its own U-Boot+rkbin blob, its own
  `specs-<platform>/` tree) and Orange Pi Zero 2 (Allwinner H616, no display driver
  at all) each got their own `build-orangepi*-stage4.sh` and `specs-orangepi*/`
  tree, not a force-fit onto an unrelated script.

## The harness — `tests/build-matrix/check.sh` (`make matrix-check`)

**✅ shipped.** For **every** matrix row the harness proves that all five channels
agree on the cell. It is entirely **dry-run**: no root, no writes outside `mktemp`,
no network, no docker/k8s. It takes a few minutes on this host:

1. **CLI** — runs the builder with `--print-plan` plus the row's flags. It asserts
   exit 0 and exact `PLAN_BUILDER` / `PLAN_ROLE` / `PLAN_ENV`, plus `PLAN_BOARD` /
   `PLAN_FLAVOR` / `PLAN_DESKTOP` where the platform has those axes.
2. **MAKE** — `make -n <target> NATIVE=1 …` must resolve, and its recipe must call
   the right builder with the row's `--role`/`--env`/axis flags.
3. **MENU** — sources `scripts/build-menu.sh` under `NO_TUI` with an isolated
   `SNAP_MENU_STATE`, sets the row's `OPT_*`, and asserts that `build_make_cmd`
   composes the right make target with `ENV=` (plus the `FRITE_*` / `JETSON_BOARD`
   make-vars).
4. **GUI** — writes a per-row config JSON and asserts that the Studio's headless,
   Qt-free `python -m hugmesh_studio --print-command` emits a command with the
   right builder, role, axes and env. The 16 standalone-posture rows translate the
   JOB-grammar tokens to the real Studio semantics (`role=desktop` /
   `flavor=installer` + `standalone: true`, as the CLI leg does). They get one more
   proof: the printed argv is re-run against the real builder with `--print-plan`
   and must be accepted with `PLAN_STANDALONE=true`. That tests builder acceptance,
   not token echo.
5. **JOB** — extracts the *real* `resolve_build_target()` from
   `docker/build-image.sh` statically; docker and k8s are never invoked. The
   extraction and a known-good canary **fail loud** if the worker's whitelist
   format drifts. The leg asserts that every row's `HARDWARE_CLASS` spelling
   resolves to the right platform, role, board and flavor, so the Job worker's
   hand-kept whitelists cannot drift from `matrix.tsv` unnoticed. `test`/`prod`
   rows (and frite's own `light`/`none` desktop-weight axis; no other platform has
   one) probe the same whitelist cell, because the channel has no such axes (see
   above). `flavor=both` rows (every platform with a flavor axis) assert the
   worker's *documented rejection*. The 16 standalone-posture probe rows (rpi5's
   `standalone-desktop` role; the `standalone` flavor on frite and every Orange Pi
   platform) assert that the JOB channel resolves them onto the real target
   (`--role desktop` / `--flavor installer`) and that the matching `*_STANDALONE`
   flag goes true. The CLI leg of the same rows translates the same JOB-only token
   into a real `--standalone` invocation before running it, since the token is not
   builder vocabulary. Five bogus-`HARDWARE_CLASS` negatives keep the whitelists
   fail-closed, including two standalone-shaped ones: a jetson request shaped like
   the new token (jetson deliberately has none) and an rpi5 `standalone-desktop`
   role with `IMAGE_TYPE=client` (rpi5 is never a client platform).

Plus **negative checks** (the `NEG` bucket, **72** as the harness summary reports
it). The list below names the families; it is not one line per check. All must exit
non-zero, so a typo can never *silently* build the wrong image.

- Invalid roles on x86, rpi5 and jetson; an invalid frite board and desktop; an
  invalid jetson board.
- Invalid `--env` values on x86, jetson, orangepi5 and the four Orange Pi appliance
  builders (zero2, zero2w, zero3, 3-lts).
- x86-only flags (`--steam`, `--gpu-driver`) rejected by the rpi5 builder, and
  `--standalone` on an rpi5 role with no compatible posture.
- **`--board rpi3` rejected on every non-`desktop` rpi5 role**
  (`backend`/`pki`/`frontend`/`generic`). Pi 3's 1 GB RAM has no headroom for the
  k8s cluster-node stack, so this is enforced, not just undocumented.
- An invalid orangepi5 board and flavor; an invalid flavor on the four appliance
  builders; `--board` rejected on those four (it is not a flag there: one board, no
  axis).
- **A path-traversal-shaped `--role` value rejected on orangepi5 and the four
  appliance builders.** That flag is an undocumented marker-only escape hatch on
  those builders (none has a real `--role` axis), and it used to flow unescaped into
  the artifact-path strings with no allow-list check at all.
- The unaffiliated **identity/look boundary probes**. Since the 2026-08-26 split,
  `--theme`, `--wallpaper` and `--accent-color` on the unaffiliated role must be
  *accepted* (a look names nobody, and its artefacts bake under neutral names).
  `--brand`, `--brand-logo` and `--brand-locked` must still hard-error (a brand
  names whose image this is), as must `--unaffiliated` on a cluster role. Both
  directions are pinned, because a boundary tested on one side can move without any
  probe going red.
- **The two premade-theme probes.** An unknown `--theme`, and a path-shaped one like
  `../..`, must both be rejected *by `--print-plan` itself*. The name used to be
  resolved only at the branding step ~2100 lines later, so every channel's
  preflight passed themes the build then rejected. `[ -d ]` alone never stopped a
  traversal, because the name is concatenated straight into
  `${SPECS_DIR}/branding/themes/<name>`.
- A `--desktop` that contradicts a weight-pinning standalone role (`standalone-thin`
  with `--desktop full`, `standalone-thick` with `--desktop thin`,
  `standalone-unaffiliated` with `--desktop thin`).
- A malformed `--packages-add` atom, a `--packages-drop` of a mandatory-payload
  atom, and a malformed `--superdomain`.
- An unknown platform refused by the GUI, and the five bogus-`HARDWARE_CLASS`
  Job-channel rejections (the three original whitelist negatives plus the two
  standalone-shaped ones above).

`orangepi4-lts` has no negative probe of its own. The harness exits 1 on any
failure. It includes a **completeness gate**: every channel's pass count must equal
the row count, so a crashed channel child or a silently skipped row fails the run
instead of degrading it.

It also runs **42 menu-side flag-threading probes**:

- `STANDALONE_FLAGS` must reach the builder argv on the `x86-%` /
  `x86-standalone-thin` / `jetson` / `jetson-%` / `frite` / `orangepi5` /
  `orangepizero2` / `orangepizero2w` / `orangepizero3` / `orangepi3-lts` /
  `orangepi4-lts` recipes (the menu's and Studio's extra-flags escape hatch rides
  it). 11 probes.
- `IMG_FLAGS` must reach it on `rpi-%` / `x86-%` / `frite` / `jetson` / `jetson-%` /
  `orangepi5` / `orangepizero2` / `orangepizero2w` / `orangepizero3` /
  `orangepi3-lts` / `orangepi4-lts` (every platform offers the image-flags knob).
  11 probes.
- 10 end-to-end MENU→MAKE probes prove that `build_make_cmd`'s composed invocation
  lands both `OPT_IMGFLAGS` and `OPT_EXTRA_FLAGS` in the builder argv on one target
  per platform (`rpi-backend`, `x86-pki`, `frite`, `jetson-edge-ai`, `orangepi5`,
  `orangepizero2`, `orangepizero2w`, `orangepizero3`, `orangepi3-lts`,
  `orangepi4-lts`).
- 6 installer-ui probes prove the menu defers to the builder's role-aware default:
  the pristine `OPT_INSTALLER_UI` is empty; `x86-pki`, `x86-backend`, `x86-frontend`
  and `x86-omnibus` emit no `--installer-ui`; `x86-standalone-thick` honours an
  explicit one.
- 2 fleet-option probes prove `RESUME`/`PENTEST`/`X86_OMNIBUS`/`FRITE`/`JETSON` all
  gate to both `build-all` and `build-everything`.
- 1 unaffiliated-menu probe proves the `x86-standalone-unaffiliated` recipe carries
  `--role standalone-unaffiliated` and `--theme dark` (a look is legal there), and
  never the `BRAND=` make-var, its `brands/*.conf` profile, `--brand-logo` or
  `--home-seed-code` (identity and platform machinery are not).
- 1 ROLESET_ENVVARS docker-boundary probe drives `make -n build-everything
  RPI_BOARD=rpi4 RPI_ROLES="..."` directly, not through the menu: RPI_BOARD,
  RPI_ROLES and SKIP_RPI have no menu widget for the fleet targets at all. It
  asserts that RPI_BOARD, RPI_ROLES and the ORANGEPIZERO2/ORANGEPIZERO2W/ORANGEPIZERO3
  flags and flavors all survive into the composed docker-run recipe. A prior
  version of `ROLESET_ENVVARS` silently dropped them at that boundary, on both the
  native and Docker legs.

A recipe that ignores a make-var the menu emits, or a new fleet target or knob
added without the same gate, can never go green.

The Studio channel gets the same treatment with **73 GUI flag-threading probes**
(`GUITHR`). For every config-field family the Studio threads to the builders
(cluster domain, person-role, host identity, secure-boot family, artifact
selection, u-boot chain, kernel/DTB plumbing, standalone/local-user, CUDA,
optional/exclude services, mesh version pins, home/media sets, …), a probe feeds a
config JSON through `--print-command` and asserts the exact flag tokens, including
must-NOT-appear grammar. It then re-runs the printed argv against the real builder
with `--print-plan` and asserts acceptance plus the matching `PLAN_*` echo
(`PLAN_CLUSTER_DOMAIN`, `PLAN_PERSON_ROLE`, `PLAN_HOSTNAME`, `PLAN_MESH`,
`PLAN_UNAFFILIATED`, …). Every probe is builder-accepted, never token-echoed.

**17 GUI gating negatives** ride along. 15 prove that a wrong-platform field set in
a config JSON emits *no* flag at all on ARM configs (steam, gpu-driver, the edge-AI
set, the u-boot chain, the secure-boot family, node fallback creds,
release-tag/distdir, services/games, cluster plane, a retired or path-shaped theme
name, branding assets on the four smaller Orange Pi platforms). 2 prove the jetson
encrypt-root and jetson standalone hard-blocks still refuse `--print-command`
outright.

The **flag-coverage differ** (`tests/build-matrix/flag-coverage.sh`, the `COVG`
bucket, 50 checks: forward, reverse, `--packages-add`, `--packages-drop` and
`--superdomain` for each of the ten builders) parses each builder's live arg-parser
case arms. It diffs them in both directions against the Studio's *real* emission
vocabulary, computed by running `ImageConfig.to_cli_args()` over a sample battery
driven by the capability table. A builder flag with no Studio field and no
documented allowlist reason, or a Studio-emitted flag no builder parses, fails the
run.

Every probe family is fail-closed behind an expected-count gate. Current totals, as
the harness bucket summary reports them (measured 2026-10-21): 172 cells × 5 channels + 118 threading
probes (`THRD`) + 123 negatives (`NEG`) + 50 flag-coverage
checks (`COVG`) + 12 emerge-group banner probes (`EGB`: 10 builder multisets, the
heredoc-safety sweep and the taxonomy declaration cross-check) + 24 emerge-plan
preview probes (`EPL`) + 16 taxonomy-parity checks (`TAXO`) + 6 web-catalog honesty
checks (`CAT`) = **1209 checks**. Six more buckets delegate to their own scripts and
fold the tally in, each fail-closed on an expected count: `SLX` (161, SELinux
node-policy install, `tests/scripts/test-selinux-policy-install.sh`), `PCS` (39,
portage-config sync, `tests/scripts/test-portage-config-sync.sh`), `RAR` (25,
requested atoms stay resolvable), `SBP` (7, the shared-binpkg smokes, see below),
`SFO` (14, sendfile-noise patch ordering and residue) and `BCF` (6, the image-side
`brand.conf` round trip and neutral modprobe.d names). Measured on 2026-10-07 on
`main` (`c257067e`): **1297 passed, 0 failed**.

```sh
make matrix-check                 # or: bash tests/build-matrix/check.sh
```

### The full inventory — every advertised image × every channel

**✅ shipped.** `matrix.tsv` is a *curated sample* of the image grammar. The **full
inventory** is the other half of the standing rule. `scripts/emit-image-inventory.py`
expands [`docs/catalog/image-catalog.json`](catalog/image-catalog.json)'s grammar
into **every** advertised image (mode × platform × role × board/flavor/desktop) and
probes all six channels for each one: CLI (`--print-plan`), `make -n`, the ncurses
menu's real `ui_menu` pickers, the Studio's `--print-command`, the k8s Job
worker's `resolve_build_target()` (really executed), and a materialized
`hugmesh-worklist/v1` envelope. It records, per image, whether each channel has a
first-class selection, only an escape hatch, or nothing. The result is committed as
[`docs/catalog/image-inventory.json`](catalog/image-inventory.json) +
[`docs/IMAGE-INVENTORY.md`](IMAGE-INVENTORY.md) (channel gaps, phantom catalog
entries and undocumented targets each get their own table).
`tests/build-matrix/inventory-check.sh` regenerates and re-proves it five ways
(DRIFT/CLI/JOB/INV/BASE), so the channels and the documented inventory cannot
silently disagree:

```sh
make inventory-check              # or: bash tests/build-matrix/inventory-check.sh
make image-inventory              # regenerate after a deliberate channel/grammar change
```

`scripts/render-all-images.py` goes one level deeper than the inventory's
*verdicts*. For every inventory record it makes each claimed channel actually
**render** a coherent build plan: the builder's `--print-plan` for both envs,
`make -n` of the dispatch (re-proving escape-hatch claims through
`STANDALONE_FLAGS`), the real Studio via `--print-command` and a one-entry worklist
through `WorklistDriver`, and `docker/build-image.sh` in its
`BUILD_IMAGE_SH_PRINT_ONLY=1` preview mode. It checks that every rendered argv
names the record's own platform, role, board, flavor and desktop, and writes
[`docs/catalog/image-render-report.json`](catalog/image-render-report.json). It is
a plan-level prover (no root, no writes, no network), run by hand:

```sh
python3 scripts/render-all-images.py        # re-render every image on every claimed channel
```

### Shared-binpkg prebuild flags (host/CI build-phase, not GUI options)

The shared-binpkg track (**✅ shipped**, see
[`docs/SHARED-BINPKG.md`](SHARED-BINPKG.md)) adds two builder flags that are
deliberately **not** Studio `ImageConfig` fields. They are host/CI **build-phase**
controls, the same class as `--specs-dir`/`--target`, and sit on the
`flag-coverage.sh` allowlist with that reason:

- **`--packages-only`** (all ten builders) — run the emerge that populates the
  per-board `PKGDIR` under `FEATURES=buildpkg`, then `exit 0` **before** any image
  assembly (x86 before Phase 6 mesh; ARM before kernel/img/iso/tar). It emits
  nothing image-shaped and adds a `PLAN_PACKAGES_ONLY=0|1` fact to `--print-plan`.
  The **`prebuild-binaries`** make target drives it; it is never a GUI knob.
- **`--distdir DIR`** (+ `SNAP_DISTDIR_SRC` env) — reuse a shared **read-only**
  distfiles (source-tarball) cache. Distfiles are arch-independent, so one
  fleet-wide pool is safe on every board. x86 *does* field it as a GUI knob; the
  nine ARM builders take it as host plumbing only, hence the ARM allowlist
  entries.

The **`prebuild-binaries ARCH=<platform> [BOARD=]`** make target computes the
platform's role-union with the Qt-free `python3 -m
hugmesh_studio.core.prebuild_union <platform>` module and runs the builder once
with `--packages-only` into the per-board pool (MAKE channel). The ncurses menu
offers it as **Build → Prebuild shared binpkg pool**, plus a **Shared distfiles**
option. A `sharedbinpkg-*` smoke set (`prebuild-smoke.sh` + six hermetic tests)
exercises the target, the per-board pkgdir distinctness, the RO-distfiles wiring,
the pool fingerprint guard, the shared build assets, the host build-dependency pool
and the kernel artifact cache. The set is **gating**: the `SBP` bucket scores it
into the harness total, and a missing smoke counts as a failure. The compile-once
**speedup and correctness are UNPROVEN without a live fleet build**. The mechanism
and the fingerprint SIGILL guard ship; the live proof is owed.

### `--print-plan` — the dry-run contract

Every builder takes `--print-plan`. It resolves and **validates** every flag, prints
the machine-greppable plan (one `PLAN_KEY=VALUE` per line) and exits 0 **before any
mutation** (no root, no disk writes, no network). Invalid role/flag combinations
exit non-zero *before* the plan prints, and secret values (`--local-pass`,
`--luks-pass`, …) are only ever echoed as `REDACTED`. Every channel is verified
against this contract.

```sh
./build-x86-host-stage4.sh --role standalone-thick --env test --print-plan
./build-jetson-stage4.sh   --role edge-ai --print-plan
```

## Building the whole matrix for real

`make matrix-check` validates; `make build-all` and `make build-everything` build.
`make build-all` builds the **default fleet**: 3 RPi5-board
`pki`/`backend`/`frontend` roles + 4 x86 cluster roles (`pki`, `backend`,
`frontend`, `backend-gpu`). `make build-everything` builds the **full documented
matrix**: the same 3 Pi roles, all 12 x86 roles (nodes, `omnibus`, `edge-ai`,
clients, the three standalone roles), then Frite, Jetson and every Orange Pi
platform. Both honor `ENV=test|prod` and the usual `BRAND=` / `DOMAIN=` /
`WORK_DIR=` overrides.

Both pass `scripts/build-all-roles.sh`'s role-selector knobs through, so a partial
superset of the default fleet is one env-var away on `make build-all`. Every
non-default-fleet platform and role is **opt-in** there. They stay out of the
default fleet the same way `standalone-thin`/`standalone-thick`/
`standalone-unaffiliated` do: they are appliances, not cluster nodes, and/or still
EXPERIMENTAL:

| Knob | Adds |
|---|---|
| `RPI_ROLES="pki backend frontend desktop"` | the rpi5 `desktop` role to the default set |
| `RPI_BOARD=rpi4` / `RPI_BOARD=rpi3` | re-targets every selected `RPI_ROLES` at that board (`rpi3` is desktop-only — pair with `RPI_ROLES=desktop`) |
| `X86_OMNIBUS=1` / `X86_ALL=1` | `omnibus` (built first) |
| `X86_STANDALONE=1` | `standalone-thin`/`standalone-thick`/`standalone-unaffiliated` |
| `FRITE=1` | the Frite light-desktop (board/flavor/desktop via `FRITE_*`) |
| `JETSON=1` | the Jetson Orin edge-AI platform *(EXPERIMENTAL)* |
| `ORANGEPI5=1` | Orange Pi 5 / 5 Plus *(EXPERIMENTAL)*; `ORANGEPI5_ROLES="pki backend frontend omnibus"` builds node roles instead of (or with `desktop`, beside) the desktop |
| `RAM_GB=N` | the board RAM passed as `--ram-gb` to every Pi / Orange Pi node role of the run; REQUIRED (8+) when `RPI_ROLES` or `ORANGEPI5_ROLES` names `omnibus` |
| `ORANGEPIZERO2=1` | Orange Pi Zero 2 headless appliance *(EXPERIMENTAL)* |
| `ORANGEPIZERO2W=1` | Orange Pi Zero 2W headless appliance *(EXPERIMENTAL)* |
| `ORANGEPIZERO3=1` | Orange Pi Zero 3 headless appliance *(EXPERIMENTAL)* |
| `ORANGEPI3LTS=1` | Orange Pi 3 LTS headless appliance *(EXPERIMENTAL)* |
| `ORANGEPI4LTS=1` | Orange Pi 4 LTS light desktop *(EXPERIMENTAL)*; `ORANGEPI4LTS_ROLES=frontend` builds its one node role |

Each platform knob also has an `_ONLY=1` variant (`FRITE_ONLY=1`,
`JETSON_ONLY=1`, `ORANGEPI5_ONLY=1`, `ORANGEPIZERO2_ONLY=1`,
`ORANGEPIZERO2W_ONLY=1`, `ORANGEPIZERO3_ONLY=1`, `ORANGEPI3LTS_ONLY=1`,
`ORANGEPI4LTS_ONLY=1`) that builds **only** that platform, skipping every other
one. `X86_STANDALONE_ONLY=1` does the same for the three standalone roles.
`SKIP_X86=1` / `SKIP_RPI=1` drop those instead. The header comment of
`scripts/build-all-roles.sh` has the full knob list. The script is a real-build
orchestrator, not a dry run, so the `matrix.tsv`/`check.sh` harness above does not
verify it. A new platform lands here in the *same* change as its
`matrix.tsv`/`check.sh` wiring, not afterwards.

## Related

- Channel parity per feature area: [`docs/STANDALONE-DESKTOP.md`](STANDALONE-DESKTOP.md),
  [`docs/CLIENT-IMAGES.md`](CLIENT-IMAGES.md), [`docs/EDGE-AI.md`](EDGE-AI.md) §1/§5.
- The **EXPERIMENTAL** platforms (hardware validation pending):
  [`specs-jetson/README.md`](../specs-jetson/README.md) (NVIDIA Jetson Orin),
  [`specs-orangepi5/README.md`](../specs-orangepi5/README.md) (Orange Pi 5 / 5 Plus),
  [`specs-orangepi-zero2/README.md`](../specs-orangepi-zero2/README.md) (Orange Pi Zero 2, headless),
  [`specs-orangepi-zero2w/README.md`](../specs-orangepi-zero2w/README.md) (Orange Pi Zero 2W, headless),
  [`specs-orangepi-zero3/README.md`](../specs-orangepi-zero3/README.md) (Orange Pi Zero 3, headless),
  [`specs-orangepi3-lts/README.md`](../specs-orangepi3-lts/README.md) (Orange Pi 3 LTS, headless),
  [`specs-orangepi4-lts/README.md`](../specs-orangepi4-lts/README.md) (Orange Pi 4 LTS, light desktop).
- Unit companions: `tests/menu/build_menu_cmd_test.sh` (menu command
  composition) and the Studio pytest suite (`studio/tests/`).
- **Platform-key spelling contract**:
  `tests/scripts/test-platform-key-spelling.sh` (run as the
  `platform-key-spelling` smoke). Every channel keys off a *string*, and nothing in
  the buckets above notices when two channels disagree by a hyphen. Each stays
  internally consistent, so `check.sh` goes green while the GUI cannot dispatch the
  builder the menu offers. The guard makes `config.py`'s `BUILDER_SCRIPTS` the
  reference key set and holds the worklist schema enums, `matrix.tsv` column 1,
  `prebuild-smoke.sh`'s arch loop, `device-catalog.json`'s `builder.platform` and
  `PLATFORM_LABELS` to exactly that set. It also closes the spelling namespaces of
  the two Orange Pi LTS boards: `orangepi3-lts` key, `ORANGEPI3LTS_*` env prefix,
  `OPI3LTS_*` builder vars, `orangepi3lts` Python/function stem, `orange-pi-3-lts`
  device id, and the same for `orangepi4-lts` (`ORANGEPI4LTS_*` env prefix,
  `orange-pi-4-lts` device id). A fifth spelling fails the run.
- **🔭 planned**: run `make matrix-check` as a fail-closed GitLab lint stage
  alongside the other `tests/scripts/*` gates (CI images need `pytest` for the GUI
  leg). Today neither `.gitlab-ci.yml` nor `.github/workflows/` names it.
