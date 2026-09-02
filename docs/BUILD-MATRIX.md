# The build matrix — every option, every channel, verified

_State key: **✅ shipped** (on `main`) · **🚧 in-flight** · **🔭 planned**._

This repo builds a **matrix** of images: platform × role × build ENV (× the
platform's own axes), and it exposes that matrix through **four scriptable
build front-ends ("channels")**, plus a fifth, admin-triggered one. This
document is the canonical description of both, and of the harness that keeps
them from drifting apart.

## The standing rule: all options in all menus

> Every documented image option must be reachable from every build channel.
> (Standing rule — [`specs-jetson/README.md`](../specs-jetson/README.md).)

A role, board, flavor, desktop weight or builder flag that exists on the CLI
must also be buildable from `make`, from the ncurses menu, and from the Studio
GUI — and vice versa. Where a channel has no dedicated widget for a flag, it
must still be *expressible* (the menu's and Studio's **extra-flags escape
hatch** exists for exactly that). New options land in **all four channels in
the same change**, plus a row (or axis) in the canonical matrix below.

### Four-choice taxonomy parity

The Studio GUI's four-choice opening screen
([`gui/pages/mode.py`](../studio/hugmesh_studio/gui/pages/mode.py); the flow is
specced in [`docs/STUDIO-WIZARD-FLOW.md`](STUDIO-WIZARD-FLOW.md)) is the **reference**
taxonomy — **Mesh node** / **Local Docker mesh** / **Mesh desktop client** /
**Standalone Gentoo desktop**. Every channel that presents an opening choice mirrors
those four labels verbatim: the ncurses menu's `mode_screen()`
([`scripts/build-menu.sh`](../scripts/build-menu.sh)) and the CLI's guided `--help`
(`print_intents_guide` in [`docker/build-image.sh`](../docker/build-image.sh)). The
three *image* choices are a clarity layer on top of the existing screens/flags — they
change navigation only, so the emission the matrix guards is byte-identical.

The **`TAXO` bucket** in [`tests/build-matrix/check.sh`](../tests/build-matrix/check.sh)
enforces this the same code-copy way the `JOB`/`COVG` buckets work: the golden set is
extracted **live** from `mode.py` (grep'd — it imports Qt, so it can't be imported
Qt-free), a canary asserts the reference taxonomy is **exactly four** (a silent
shrink/grow trips the gate), a bogus label must be absent from every channel
(non-vacuity), and each of the four labels must be present in both the menu and the CLI
guide. Fail-closed: an expected pass count, shortfall = failure.

**Local Docker mesh (choice ii) is the one non-build channel.** It builds no image and
has **no matrix row and no emission** — it runs a dockerized node on the operator's own
machine through [`core/local_mesh.py`](../studio/hugmesh_studio/core/local_mesh.py)'s
Qt-free entrypoint (`python3 -m hugmesh_studio.core.local_mesh`, wrapped by
`make mesh-node-up`), shared verbatim by the GUI launcher, the ncurses `local_mesh_screen`,
and the Makefile targets. It never enters `resolve_build_target`/`build_make_cmd`.

**The MDM phone wizard (🚧) rides the same non-build precedent, one step
further out.** [`scripts/phone-wizard.sh`](../scripts/phone-wizard.sh)
([`MDM.md`](MDM.md)) builds no image at all — it
flashes an externally-released, signature-verified GrapheneOS artifact onto a
USB-connected Pixel — so the phone is **not a matrix row, not a platform, not an
emission, and not a channel choice**: it never enters
`resolve_build_target`/`build_make_cmd`, and the harness deliberately does not
gate it.

**Cloud image packaging rides the same non-build precedent.**
[`scripts/cloud-package.sh`](../scripts/cloud-package.sh)
([`CLOUD-IMAGE-PACKAGING.md`](CLOUD-IMAGE-PACKAGING.md)) re-packages an
**already-built** x86 raw `.img` as `qcow2` / fixed `VHD` / checksummed raw for
cloud import. Output format is a post-build property of an existing artifact,
not an image option — so it is **not a matrix row, not an axis, and not a
channel choice**: it never enters `resolve_build_target`/`build_make_cmd`, the
builders' emission is untouched, and the harness deliberately does not gate it
(its own hermetic suite is `tests/scripts/test-cloud-package.sh`).

**Per-user first-login `registration` (discord / gmail / password / derive) is
manifest-only.** It is an additive `User.registration` field surfaced in the Studio
`users.py` + `--print-specs`; the ncurses/CLI image builders carry no per-user mesh
manifest, so it is **not** a menu/CLI image-build knob and the `TAXO` bucket asserts its
four tokens in the Studio users surface only (keeping the gate honest, not vacuously
green on channels that do not offer it).

## The four scriptable channels

| Channel | Entry point | How a build is described |
|---|---|---|
| **CLI** | `./build-{rpi5,x86-host,frite,jetson,orangepi5,orangepi-zero2}-stage4.sh` | flags (`--role`, `--env`, `--board`, `--flavor`, `--desktop`, …) |
| **make** | `Makefile` targets (`make x86-<role>`, `make rpi-<role>`, `make frite`, `make jetson-<role>`, `make orangepi5`, `make orangepizero2`, `make build-all`, `make build-everything`) | make vars (`ENV=`, `BRAND=`, `RPI_BOARD=`, `FRITE_*=`, `JETSON_*=`, `ORANGEPI5_*=`, `IMG_FLAGS=`, `STANDALONE_FLAGS=`) |
| **ncurses menu** | `make menu` (`scripts/build-menu.sh`) | interactive screens persisting `OPT_*` state; composes the same make invocation |
| **Studio GUI** | `studio/` (`python -m hugmesh_studio`) | wizard pages over `ImageConfig`; the same config drives the headless `--print-command` |

Note: `build-rpi5-stage4.sh` is a **single builder covering three boards** via
`--board rpi5\|rpi4\|rpi3` (the `--board` axis, not a separate script per
board) — see "Board axes vs. new builders" below.

**Arch-first device taxonomy** ✅ (Studio) / 🔭 (menu, CLI guided help): the Studio's
machine tier now presents an architecture selector over a family-grouped **device
catalog** (`studio/hugmesh_studio/core/device_catalog.py` +
`core/device-catalog.json`) with the #351 honesty statuses (supported / experimental
labelled / unsupported visible-but-unselectable, reason shown). A device is exactly a
`(platform, board)` pair and its roles are **derived** from `ROLE_CHOICES` +
`rpi_boards_for_role()` — the selection layer regrouped, the emission untouched (the
GUI column + the byte-identical `matrix.tsv` guard it). The web/JOB channel gets the
same hierarchy via the `archs`/`families`/`devices` keys of
[`docs/catalog/image-catalog.json`](catalog/image-catalog.json) (the `CAT` bucket, now
6 assertions, pins its honesty); the ncurses menu / CLI guided help should render from
that committed JSON — see the PARITY-TODO in
[`docs/STUDIO-WIZARD-FLOW.md`](STUDIO-WIZARD-FLOW.md).

Every channel is crossed with the **build ENV** (`test` | `prod`), threaded as
`--env` on the builders and `ENV=` through make — see the
[Build ENV section of the README](../README.md#build-env-testprod-baked-at-image-creation).

There is also a **fifth, admin-triggered channel**: the admin web-UI's
image-gen **k8s Job** worker (`docker/build-image.sh`, launched by
admin-bff-api), which maps the Job contract's `IMAGE_TYPE` + `HARDWARE_CLASS`
strings onto the same generator build targets through its own role whitelists
(the `HARDWARE_CLASS` convention in that script's header). It deliberately has
no `env` axis (the Job contract carries no hardening-tier field, so every Job
build gets the fail-secure `prod` posture), no frite/orangepi5/orangepizero2
`desktop` axis, and no `flavor=both` on any live/installer platform (its
ingest contract reports exactly one `imageRef` per build, so a two-artifact
flavor is a clean rejection everywhere it would otherwise apply). The
standalone/LUKS posture **is** now reachable through this channel on
rpi5/frite/orangepi5/orangepizero2, mirroring x86's
standalone-thin/standalone-thick/standalone-unaffiliated roles: rpi5 gets a
dedicated `standalone-desktop` role token (it already has a role axis to
extend), while frite/orangepi5/orangepizero2 (which have no role axis at all)
signal it through a `standalone` *flavor* value instead — both normalize onto
the real build target plus `--standalone`/`--local-user` (see the
`HARDWARE_CLASS` convention in `docker/build-image.sh`'s own header). Jetson is
the one deliberate exception: its builder hard-errors on `--standalone`/
`--encrypt-root` outright (the Orin's single boot+root partition means
encrypting it would leave UEFI firmware unable to find a kernel — see
STANDALONE-DESKTOP.md's Jetson section), so this channel gives it no
HARDWARE_CLASS token for the posture either (see the "JETSON STANDALONE
EXCEPTION" note in `docker/build-image.sh`'s own header).

## The canonical matrix — `tests/build-matrix/matrix.tsv`

One row per buildable image cell `(platform, role, env, board, flavor,
desktop)`; `-` marks an axis a platform does not have. **150 cells** today
(includes 14 JOB-channel-only standalone-posture probe rows — see below):

### The role vocabulary — one spelling, everywhere

A role token means the same thing and is spelled the same way on every platform and
in every channel. It is declared **once**, in `scripts/_roles-lib.sh`, which every
builder sources and which `studio/hugmesh_studio/core/roles.py` reads:

| Canonical | What it is | Platforms |
|---|---|---|
| `pki` | cluster CA / control plane | x86, rpi5 |
| `backend` | backend k8s worker | x86, rpi5 |
| `frontend` | frontend k8s worker | x86, rpi5 |
| `backend-gpu` | backend worker + GPU, no inference service | x86, jetson |
| `omnibus` | every cluster role on one node | x86, jetson |
| `edge-ai` | GPU inference node (OpenAI-compatible model API) | x86, jetson |
| `generic` | plain unbranded arm64 server | rpi5 |
| `laptop` `chromebook` `desktop` | person-device desktops | x86 (+ `desktop` on rpi5/jetson) |
| `standalone-thin` `standalone-thick` `standalone-unaffiliated` | no mesh, no SSO | x86 |

The old spellings are **still accepted, forever**, on every CLI that documented them,
and are normalized at parse time so nothing downstream ever sees two names for one
role: `be`=backend, `fe`=frontend, `be+gpu`/`be-gpu`/`host`/`gpu-host`/`gpu_host`=backend-gpu,
`full`=omnibus, `edge_ai`=edge-ai, `standalone-full`=standalone-thick. They are never
EMITTED — `tests/scripts/test-role-key-spelling.sh` fails on an alias in an artifact
name, a role marker, a matrix cell, a catalog id or a documented command.

The k8s label keys (`hugmesh.net/backend`, `/frontend`, `/pki`, `/edge-ai`) are a
DIFFERENT axis and are **not** part of this vocabulary: they were always long, are
frozen by `scripts/tooling/tokens.json`, and are `nodeSelector`'d by 73 files under
`specs/cluster/`. The builders' `ROLE_LABELS` is print-only, so the CLI token and the
label key are fully decoupled.

| Platform | Builder | Cells | Axes |
|---|---|---|---|
| **rpi5** | `build-rpi5-stage4.sh` | board `rpi5`(default): 4 roles × 2 env = 8; board `rpi4`: 4 roles × 2 env = 8 + 2 `standalone-desktop` probe rows; board `rpi3`: 1 role × 2 env = 2 → **20** | roles `pki backend frontend desktop` (rpi5/rpi4 — all 4); `desktop` only on `rpi3` (1 GB RAM has no headroom for the k8s cluster-node stack); board `rpi5\|rpi4\|rpi3`; JOB-channel-only role `standalone-desktop` (resolves the same `--role desktop`, plus `--standalone`) |
| **x86** | `build-x86-host-stage4.sh` | 12 roles × 2 env = **24** | nodes `pki backend frontend backend-gpu`, `omnibus`, `edge-ai`, clients `laptop chromebook desktop`, `standalone-thin standalone-thick standalone-unaffiliated` |
| **frite** | `build-frite-stage4.sh` | 3 boards × 3 flavors × 2 desktops × 2 env = 36 + 2 `standalone` probe rows → **38** | board `la-frite\|le-potato\|sweet-potato`, flavor `live\|installer\|both`, desktop `light\|none`; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **jetson** *(EXPERIMENTAL)* | `build-jetson-stage4.sh` | 4 roles × 2 env on `orin-nano` + 3 boards × 2 env on `edge-ai` = **14** | roles `edge-ai backend-gpu omnibus desktop`; board `orin-nano\|orin-nano-4gb\|orin-nx-8gb\|orin-nx-16gb` (non-default boards carried on the headline `edge-ai` role); deliberately **no** standalone token (see above) |
| **orangepi5** *(EXPERIMENTAL)* | `build-orangepi5-stage4.sh` | 2 boards × 3 flavors × 2 env = 12 + 2 `standalone` probe rows → **14** | board `orange-pi-5-plus\|orange-pi-5` (RK3588 vs RK3588S), flavor `live\|installer\|both`; `desktop` is the only role (no cluster-node roles on this platform); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepizero2** *(EXPERIMENTAL)* | `build-orangepi-zero2-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; headless only — Allwinner H616 has no mainline display-engine driver, so this platform never gets a `desktop` role; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepizero2w** *(EXPERIMENTAL)* | `build-orangepi-zero2w-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; the Zero 2's Allwinner H618 sibling — same headless-only rationale (identical DE33 display engine, no mainline driver) and NO onboard Ethernet (USB-Ethernet-first); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepizero3** *(EXPERIMENTAL)* | `build-orangepi-zero3-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; the Zero 2's Allwinner H618 sibling — same headless-only rationale (identical DE33 display engine, no mainline driver) but onboard Gigabit Ethernet is BACK (Ethernet-first, unlike the Zero 2W); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepi3-lts** *(EXPERIMENTAL)* | `build-orangepi3-lts-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; Allwinner H6 — headless by SCOPE decision (unlike the H616 siblings' hard driver gap; see the specs README), boots the PLAIN Orange Pi 3's mainline DTB/defconfig (no `-lts` variant upstream), USB-Ethernet-first (the GbE jack is dead on that DTB); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepi4-lts** *(EXPERIMENTAL)* | `build-orangepi4-lts-stage4.sh` | 1 role (`desktop`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; Rockchip RK3399 — the one Orange Pi platform here that is a LIGHT DESKTOP rather than a headless appliance (the mainline `rk3399-orangepi` DTB it boots has an enabled Mali-T860 GPU, enabled HDMI and both VOPs), so role `desktop` like `orangepi5`; but SINGLE-BOARD like the appliances (mainline ships one Orange Pi RK3399 DTB/defconfig for the whole 4/4B/4 LTS family), so no `--board` axis and no `--desktop` axis; blob-free boot chain; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |

Adding an image option means adding/extending rows here — the harness then
holds every channel to it.

### Board axes vs. new builders — when to add which

Two closely-related-hardware situations look similar but resolve differently:

- **Same platform family, same install/boot model → extend the existing
  builder with a `--board` axis.** `build-rpi5-stage4.sh` covers Pi 5/4/3 this
  way (a `select_board()` table fills CPU/defconfig/DTB/kernel-image only when
  not explicitly overridden), and Jetson covers the Orin SKUs the same way.
  Board-exclusive hardware becomes a small additive kernel-config fragment
  (`rp1-pi5.config`, `bcm2711-pi4.config`, `bcm2837-pi3.config`) layered on a
  shared base (`hardened-k8s.config`), not a fork of the builder.
- **Different SoC vendor / boot chain / install story → a new builder script.**
  Orange Pi 5 (Rockchip RK3588, its own U-Boot+rkbin blob, its own `specs-<platform>/`
  tree) and Orange Pi Zero 2 (Allwinner H616, no display driver at all) each
  got their own `build-orangepi*-stage4.sh` + `specs-orangepi*/` tree instead
  of being force-fit onto an unrelated existing script.

## The harness — `tests/build-matrix/check.sh` (`make matrix-check`)

**✅ shipped.** For **every** matrix row the harness proves all five channels
agree on the cell — entirely **dry-run**: no root, no writes outside `mktemp`,
no network, no docker/k8s, ~15 s:

1. **CLI** — invokes the builder with `--print-plan` + the row's flags and
   asserts exit 0 plus exact `PLAN_BUILDER` / `PLAN_ROLE` / `PLAN_ENV` (and
   `PLAN_BOARD` / `PLAN_FLAVOR` / `PLAN_DESKTOP` where the platform has those
   axes).
2. **MAKE** — `make -n <target> NATIVE=1 …` must resolve, and its recipe must
   invoke the right builder with the row's `--role`/`--env`/axis flags.
3. **MENU** — sources `scripts/build-menu.sh` under `NO_TUI` with an isolated
   `SNAP_MENU_STATE`, sets the row's `OPT_*`, and asserts `build_make_cmd`
   composes the right make target with `ENV=` (+ the `FRITE_*` /
   `JETSON_BOARD` make-vars).
4. **GUI** — writes a per-row config JSON and asserts the Studio's headless,
   Qt-free `python -m hugmesh_studio --print-command` emits a command with
   the right builder / role / axes / env. The 8 standalone-posture rows
   translate the JOB-grammar tokens to the real Studio semantics
   (`role=desktop` / `flavor=installer` + `standalone: true`, exactly like the
   CLI leg) and are additionally proven end-to-end: the printed argv is re-run
   against the real builder with `--print-plan` and must be accepted with
   `PLAN_STANDALONE=true` — builder acceptance, not token echo.
5. **JOB** — extracts the *real* `resolve_build_target()` out of
   `docker/build-image.sh` (statically — docker/k8s are never invoked; the
   extraction and a known-good canary **fail loud** if the worker's whitelist
   format drifts) and asserts every row's `HARDWARE_CLASS` spelling resolves
   to the right platform / role / board / flavor, so the Job worker's
   hand-maintained whitelists can never silently drift from `matrix.tsv`.
   `test`/`prod` (and frite's own `light`/`none` desktop-weight axis —
   orangepi5/orangepizero2 have no such axis at all) rows probe the same
   whitelist cell — the channel has no such axes (see above) — and
   `flavor=both` rows (frite/orangepi5/orangepizero2) assert the worker's
   *documented rejection*. The 8 standalone-posture probe rows (rpi5's
   `standalone-desktop` role, frite/orangepi5/orangepizero2's `standalone`
   flavor) assert the JOB channel resolves them onto the real target
   (`--role desktop` / `--flavor installer`) plus the matching `*_STANDALONE`
   flag going true; the CLI leg of the same rows translates the same
   JOB-channel-only token into the real `--standalone` invocation before
   executing it, since the token itself is not real builder vocabulary. Five
   bogus-`HARDWARE_CLASS` negatives keep the whitelists fail-closed, including
   two standalone-shaped ones: a jetson request shaped like the new token
   (jetson deliberately has none) and an rpi5 `standalone-desktop` role
   combined with `IMAGE_TYPE=client` (rpi5 is never a client platform).

Plus **negative checks** (the `NEG` bucket — **61** as reported by the harness
summary; the families enumerated here are not an exhaustive one-per-check list):
invalid roles on x86/rpi5/jetson, an invalid
frite board and desktop, an invalid jetson board, invalid `--env` values on
x86/jetson/orangepi5/orangepizero2, x86-only flags (`--steam`, `--gpu-driver`)
rejected by the rpi5 builder, `--standalone` on an rpi5 role with no compatible
posture, **`--board rpi3` rejected on every non-`desktop` rpi5 role**
(`backend`/`pki`/`frontend`/`generic` — Pi 3's 1 GB RAM has no headroom for the
k8s cluster-node stack, so this is enforced, not just undocumented), invalid
orangepi5 board/flavor, invalid orangepizero2 flavor, `--board` rejected on
`build-orangepi-zero2-stage4.sh` (it isn't a flag on that builder — one board,
no axis), **a path-traversal-shaped `--role` value rejected on both
orangepi5 and orangepizero2** (that flag is an undocumented marker-only escape
hatch on both builders — neither has a real `--role` axis — that used to flow
unescaped into the artifact-path strings with no allow-list check at all), the
unaffiliated **identity/look boundary probes** — since the 2026-08-26 split a
`--theme` / `--wallpaper` / `--accent-color` on the unaffiliated role must be
*accepted* (a look names nobody, and its artefacts bake under neutral names),
while `--brand`, `--brand-logo` and `--brand-locked` must still hard-error (a
brand names whose image this is), as must `--unaffiliated` on a cluster role;
both directions are pinned, because a boundary that is only tested on one side
can move without any probe going red, **the two
premade-theme probes** (an unknown `--theme`, and a path-shaped one like
`../..`, must both be rejected *by `--print-plan` itself* — the name used to be
resolved only at the branding step ~2100 lines later, so the validator every
channel preflights with green-lit themes the build then hard-errored on, and
`[ -d ]` alone never stopped a traversal because the name is concatenated
straight into `${SPECS_DIR}/branding/themes/<name>`), an unknown platform
refused by the GUI, and the five bogus-`HARDWARE_CLASS` Job-channel
rejections (the three original whitelist negatives plus the two
standalone-shaped ones above) — all must exit non-zero, so a typo can never
*silently* build the wrong image. The harness exits 1 on any failure —
including a **completeness gate**: every channel's pass count must equal the
row count (a crashed channel child or a silently skipped row fails the run,
never degrades it).

It also runs **33 flag-threading probes**: `STANDALONE_FLAGS` must reach the
builder argv on the `x86-%` / `x86-standalone-thin` / `jetson` / `jetson-%` /
`frite` / `orangepi5` / `orangepizero2` / `orangepizero2w` / `orangepizero3` /
`orangepi3-lts` / `orangepi4-lts` recipes (the menu's
and Studio's extra-flags escape hatch rides it — 11 probes), `IMG_FLAGS` must
reach it on `rpi-%` / `x86-%` / `frite` / `jetson` / `jetson-%` / `orangepi5` /
`orangepizero2` / `orangepizero2w` / `orangepizero3` / `orangepi3-lts` /
`orangepi4-lts` (every platform offers the image-flags knob
— 11 probes), 10
end-to-end MENU→MAKE probes prove `build_make_cmd`'s composed invocation lands
both `OPT_IMGFLAGS` and `OPT_EXTRA_FLAGS` in the builder argv on one target per
platform (`rpi-backend`, `x86-pki`, `frite`, `jetson-edge-ai`, `orangepi5`,
`orangepizero2`, `orangepizero2w`, `orangepizero3`, `orangepi3-lts`,
`orangepi4-lts`), 2 fleet-option threading probes prove
`RESUME`/`PENTEST`/`X86_OMNIBUS`/`FRITE`/`JETSON` all gate to both
`build-all` and `build-everything`, 1 unaffiliated-menu probe proves the
`x86-standalone-unaffiliated` recipe carries `--role standalone-unaffiliated`
and never `--theme`, even with the menu's persisted theme default, and 1
ROLESET_ENVVARS docker-boundary probe drives `make -n build-everything
RPI_BOARD=rpi4 RPI_ROLES="..."` directly (not through the menu — RPI_BOARD/
RPI_ROLES/SKIP_RPI have no menu widget for the fleet targets at all) and
asserts RPI_BOARD/RPI_ROLES/ORANGEPIZERO2/ORANGEPIZERO2_FLAVOR all survive
into the composed docker-run recipe — a prior version of `ROLESET_ENVVARS`
silently dropped all four at that exact boundary, on both the native and
Docker legs. A recipe that ignores a make-var the menu emits, or a new fleet
target/knob added without wiring the same gate, can never go green.

The Studio channel gets the same treatment with **51 GUI flag-threading
probes** (`GUITHR`): for every config-field family the Studio threads to the
builders (cluster domain, person-role, host identity, secure-boot family,
artifact selection, u-boot chain, kernel/DTB plumbing, standalone/local-user,
CUDA, optional/exclude services, mesh version pins, home/media sets, …) a
probe feeds a config JSON through `--print-command`, asserts the exact flag
tokens (including must-NOT-appear grammar), then re-runs the printed argv
against the real builder with `--print-plan` and asserts acceptance plus the
matching `PLAN_*` echo (`PLAN_CLUSTER_DOMAIN`, `PLAN_PERSON_ROLE`,
`PLAN_HOSTNAME`, `PLAN_MESH`, `PLAN_UNAFFILIATED`, …) — every probe is
builder-accepted, never token-echoed. **12 GUI gating negatives** ride along:
10 prove a wrong-platform field set in a config JSON emits *no* flag at all on
ARM configs (steam, gpu-driver, the edge-AI set, the u-boot chain, the
secure-boot family, node fallback creds, services/games, cluster plane,
branding assets), and 2 prove the jetson encrypt-root and jetson standalone
hard-blocks still refuse `--print-command` outright. Finally the
**flag-coverage differ** (`tests/build-matrix/flag-coverage.sh`, the `COVG`
bucket, 40 checks) parses each builder's live arg-parser case arms and diffs
them against the Studio's *real* emission vocabulary (computed by exercising
`ImageConfig.to_cli_args()` over a capability-table-driven sample battery) in
both directions: a builder flag with no Studio field and no documented
allowlist reason, or a Studio-emitted flag no builder parses, fails the run.
Every probe family is fail-closed behind an expected-count gate. Current
totals (as reported by the harness bucket summary):
150 cells × 5 channels + 110 threading probes (42 menu + 68 GUI — incl. the 4
`character-forge` probes: the tri-state flag pair on x86 AND rpi5 plus the
`--optional-services` checklist path) + 61 negatives + 50 flag-coverage checks
+ 11 emerge-group banner probes (`EGB`: 10 builder multisets + the heredoc-safety
sweep) + 16 taxonomy-parity + 6 web-catalog honesty =
**1004 checks**.

```sh
make matrix-check                 # or: bash tests/build-matrix/check.sh
```

### The full inventory — every advertised image × every channel

**✅ shipped.** `matrix.tsv` is a *curated sample* of the image grammar; the
**full inventory** is the other half of the standing rule. `scripts/emit-image-inventory.py`
expands [`docs/catalog/image-catalog.json`](catalog/image-catalog.json)'s grammar
into **every** advertised image (mode × platform × role × board/flavor/desktop)
and probes all six channels for each one — CLI (`--print-plan`), `make -n`, the
ncurses menu's real `ui_menu` pickers, the Studio's `--print-command`, the k8s
Job worker's `resolve_build_target()` (really executed), and a materialized
`hugmesh-worklist/v1` envelope — recording per image whether each channel has a
first-class selection, only an escape hatch, or nothing. The result is committed
as [`docs/catalog/image-inventory.json`](catalog/image-inventory.json) +
[`docs/IMAGE-INVENTORY.md`](IMAGE-INVENTORY.md) (channel gaps, phantom catalog
entries and undocumented targets each get their own table), and
`tests/build-matrix/inventory-check.sh` regenerates + re-proves it five ways
(DRIFT/CLI/JOB/INV/BASE) so the channels and the documented inventory can never
silently disagree:

```sh
make inventory-check              # or: bash tests/build-matrix/inventory-check.sh
make image-inventory              # regenerate after a deliberate channel/grammar change
```

### Shared-binpkg prebuild flags (host/CI build-phase, not GUI options)

The shared-binpkg track (**✅ shipped**, see
[`docs/SHARED-BINPKG.md`](SHARED-BINPKG.md)) adds two builder flags that are
deliberately **not** Studio `ImageConfig` fields — they are host/CI
**build-phase** controls, the same class as `--specs-dir`/`--target`, and are
carried on the `flag-coverage.sh` allowlist with that documented reason:

- **`--packages-only`** (all six builders) — run the emerge that populates the
  per-board `PKGDIR` under `FEATURES=buildpkg`, then `exit 0` **before** any
  image assembly (x86 before Phase 6 mesh; ARM before kernel/img/iso/tar).
  Emits nothing image-shaped; adds a `PLAN_PACKAGES_ONLY=0|1` fact to
  `--print-plan`. It is driven by the **`prebuild-binaries`** make target, never
  a GUI knob.
- **`--distdir DIR`** (+ `SNAP_DISTDIR_SRC` env) — reuse a shared **read-only**
  distfiles (source-tarball) cache. Arch-independent, so one fleet-wide pool is
  safe on every board (x86 *does* field it as a GUI knob; the five ARM builders
  take it as host plumbing only, hence the ARM allowlist entries).

The **`prebuild-binaries ARCH=<platform> [BOARD=]`** make target computes the
platform's role-union via the Qt-free `python3 -m
hugmesh_studio.core.prebuild_union <platform>` module and invokes the builder
once with `--packages-only` into the per-board pool (MAKE channel). The ncurses
menu surfaces it as **Build → Prebuild shared binpkg pool** plus a **Shared
distfiles** option; a non-gating `sharedbinpkg-*` smoke set (`prebuild-smoke.sh`
+ the three hermetic tests) exercises the target, the per-board pkgdir
distinctness, the RO-distfiles wiring and the pool fingerprint guard. The
compile-once **speedup + correctness is UNPROVEN without a live fleet build** —
the mechanism + the fingerprint SIGILL guard ship; the live proof is owed.

### `--print-plan` — the dry-run contract

Every builder takes `--print-plan`: resolve + **validate** every flag, print
the machine-greppable plan (one `PLAN_KEY=VALUE` per line) and exit 0 —
**before any mutation** (no root, no disk writes, no network). Invalid
role/flag combinations exit non-zero *before* the plan prints, and secret
values (`--local-pass`, `--luks-pass`, …) are only ever echoed as `REDACTED`.
This is the contract every channel is verified against.

```sh
./build-x86-host-stage4.sh --role standalone-thick --env test --print-plan
./build-jetson-stage4.sh   --role edge-ai --print-plan
```

## Building the whole matrix for real

`make matrix-check` validates; **`make build-everything`** builds — the
default fleet (3 RPi5-board `pki`/`backend`/`frontend` roles + 4 x86 cluster
roles), honoring `ENV=test|prod` and the usual `BRAND=` / `DOMAIN=` /
`WORK_DIR=` overrides. It threads `scripts/build-all-roles.sh`'s role-selector
knobs, so partial supersets are one env-var away — every non-default-fleet
platform/role is **opt-in** here (kept out of the default fleet the same way
`standalone-thin`/`standalone-thick`/`standalone-unaffiliated` are: they're
appliances, not cluster nodes, and/or still EXPERIMENTAL):

| Knob | Adds |
|---|---|
| `RPI_ROLES="pki backend frontend desktop"` | the rpi5 `desktop` role to the default set |
| `RPI_BOARD=rpi4` / `RPI_BOARD=rpi3` | re-targets every selected `RPI_ROLES` at that board (`rpi3` is desktop-only — pair with `RPI_ROLES=desktop`) |
| `X86_STANDALONE=1` | `standalone-thin`/`standalone-thick` |
| `FRITE=1` | the Frite light-desktop (board/flavor/desktop via `FRITE_*`) |
| `JETSON=1` | the Jetson Orin edge-AI platform *(EXPERIMENTAL)* |
| `ORANGEPI5=1` | Orange Pi 5 / 5 Plus *(EXPERIMENTAL)* |
| `ORANGEPIZERO2=1` | Orange Pi Zero 2 headless appliance *(EXPERIMENTAL)* |
| `ORANGEPIZERO2W=1` | Orange Pi Zero 2W headless appliance *(EXPERIMENTAL)* |
| `ORANGEPIZERO3=1` | Orange Pi Zero 3 headless appliance *(EXPERIMENTAL)* |
| `ORANGEPI3LTS=1` | Orange Pi 3 LTS headless appliance *(EXPERIMENTAL)* |

Each also has an `_ONLY=1` variant (`FRITE_ONLY=1`, `JETSON_ONLY=1`,
`ORANGEPI5_ONLY=1`, `ORANGEPIZERO2_ONLY=1`, `ORANGEPIZERO2W_ONLY=1`, `ORANGEPIZERO3_ONLY=1`, `ORANGEPI3LTS_ONLY=1`) that builds **only** that platform,
skipping every other one. `SKIP_X86=1` / `SKIP_RPI=1` drop those instead. See
`scripts/build-all-roles.sh`'s header comment for the full knob list — it is
independent of (and not verified by) the `matrix.tsv`/`check.sh` harness above,
since it's a real-build orchestrator rather than a dry-run one; any new
platform lands here in the *same* change as its `matrix.tsv`/`check.sh`
wiring, not as an afterthought.

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
  `platform-key-spelling` smoke). Every channel keys off a *string*, and nothing
  in the buckets above notices when two channels disagree by a hyphen — each stays
  internally consistent, so `check.sh` goes green while the GUI cannot dispatch the
  builder the menu offers. That guard makes `config.py`'s `BUILDER_SCRIPTS` the
  reference key set, holds the worklist schema enums / `matrix.tsv` column 1 /
  `prebuild-smoke.sh`'s arch loop / `device-catalog.json`'s `builder.platform` /
  `PLATFORM_LABELS` to exactly that set, and closes the Orange Pi 3 LTS spelling
  namespace (`orangepi4-lts` key, `ORANGEPI4LTS_*` env prefix, `OPI4LTS_*` builder
  vars, `orangepi4lts` Python stem, `orange-pi-4-lts` catalog id) — and the same for the
  `orangepi3-lts` key, `ORANGEPI3LTS_*` env prefix, `OPI3LTS_*` builder
  vars, `orangepi3lts` Python/function stem, `orange-pi-3-lts` device id) so a
  fifth spelling fails the run.
- **🔭 planned**: run `make matrix-check` as a fail-closed GitLab lint stage
  alongside the other `tests/scripts/*` gates (CI images need `pytest`
  available for the GUI leg).
