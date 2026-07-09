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

## The four scriptable channels

| Channel | Entry point | How a build is described |
|---|---|---|
| **CLI** | `./build-{rpi5,x86-host,frite,jetson,orangepi5,orangepi-zero2}-stage4.sh` | flags (`--role`, `--env`, `--board`, `--flavor`, `--desktop`, …) |
| **make** | `Makefile` targets (`make x86-<role>`, `make rpi-<role>`, `make frite`, `make jetson-<role>`, `make orangepi5`, `make orangepizero2`, `make build-all`, `make build-everything`) | make vars (`ENV=`, `BRAND=`, `RPI_BOARD=`, `FRITE_*=`, `JETSON_*=`, `ORANGEPI5_*=`, `IMG_FLAGS=`, `STANDALONE_FLAGS=`) |
| **ncurses menu** | `make menu` (`scripts/build-menu.sh`) | interactive screens persisting `OPT_*` state; composes the same make invocation |
| **Studio GUI** | `studio/` (`python -m snapdragon_studio`) | wizard pages over `ImageConfig`; the same config drives the headless `--print-command` |

Note: `build-rpi5-stage4.sh` is a **single builder covering three boards** via
`--board rpi5\|rpi4\|rpi3` (the `--board` axis, not a separate script per
board) — see "Board axes vs. new builders" below.

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
desktop)`; `-` marks an axis a platform does not have. **118 cells** today
(includes 8 JOB-channel-only standalone-posture probe rows — see below):

| Platform | Builder | Cells | Axes |
|---|---|---|---|
| **rpi5** | `build-rpi5-stage4.sh` | board `rpi5`(default): 4 roles × 2 env = 8; board `rpi4`: 4 roles × 2 env = 8 + 2 `standalone-desktop` probe rows; board `rpi3`: 1 role × 2 env = 2 → **20** | roles `pki backend frontend desktop` (rpi5/rpi4 — all 4); `desktop` only on `rpi3` (1 GB RAM has no headroom for the k8s cluster-node stack); board `rpi5\|rpi4\|rpi3`; JOB-channel-only role `standalone-desktop` (resolves the same `--role desktop`, plus `--standalone`) |
| **x86** | `build-x86-host-stage4.sh` | 12 roles × 2 env = **24** | nodes `pki be fe be+gpu`, `omnibus`, `edge_ai`, clients `laptop chromebook desktop`, `standalone-thin standalone-thick standalone-unaffiliated` |
| **frite** | `build-frite-stage4.sh` | 3 boards × 3 flavors × 2 desktops × 2 env = 36 + 2 `standalone` probe rows → **38** | board `la-frite\|le-potato\|sweet-potato`, flavor `live\|installer\|both`, desktop `light\|none`; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **jetson** *(EXPERIMENTAL)* | `build-jetson-stage4.sh` | 4 roles × 2 env on `orin-nano` + 3 boards × 2 env on `edge_ai` = **14** | roles `edge_ai gpu-host full desktop`; board `orin-nano\|orin-nano-4gb\|orin-nx-8gb\|orin-nx-16gb` (non-default boards carried on the headline `edge_ai` role); deliberately **no** standalone token (see above) |
| **orangepi5** *(EXPERIMENTAL)* | `build-orangepi5-stage4.sh` | 2 boards × 3 flavors × 2 env = 12 + 2 `standalone` probe rows → **14** | board `orange-pi-5-plus\|orange-pi-5` (RK3588 vs RK3588S), flavor `live\|installer\|both`; `desktop` is the only role (no cluster-node roles on this platform); JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |
| **orangepizero2** *(EXPERIMENTAL)* | `build-orangepi-zero2-stage4.sh` | 1 role (`appliance`) × 3 flavors × 2 env = 6 + 2 `standalone` probe rows → **8** | flavor `live\|installer\|both`; headless only — Allwinner H616 has no mainline display-engine driver, so this platform never gets a `desktop` role; JOB-channel-only flavor `standalone` (normalizes to `installer`, plus `--standalone`) |

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
   Qt-free `python -m snapdragon_studio --print-command` emits a command with
   the right builder / role / axes / env.
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

Plus **negative checks** (31): invalid roles on x86/rpi5/jetson, an invalid
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
two unaffiliated conflict probes (the unaffiliated role with a `--theme`, and
`--unaffiliated` on a cluster role, must both hard-error), an unknown platform
refused by the GUI, and the five bogus-`HARDWARE_CLASS` Job-channel
rejections (the three original whitelist negatives plus the two
standalone-shaped ones above) — all must exit non-zero, so a typo can never
*silently* build the wrong image. The harness exits 1 on any failure —
including a **completeness gate**: every channel's pass count must equal the
row count (a crashed channel child or a silently skipped row fails the run,
never degrades it).

It also runs **24 flag-threading probes**: `STANDALONE_FLAGS` must reach the
builder argv on the `x86-%` / `x86-standalone-thin` / `jetson` / `jetson-%` /
`frite` / `orangepi5` / `orangepizero2` recipes (the menu's and Studio's
extra-flags escape hatch rides it — 7 probes), `IMG_FLAGS` must reach it on
`rpi-%` / `x86-%` / `frite` / `jetson` / `jetson-%` / `orangepi5` /
`orangepizero2` (every platform offers the image-flags knob — 7 probes), 6
end-to-end MENU→MAKE probes prove `build_make_cmd`'s composed invocation lands
both `OPT_IMGFLAGS` and `OPT_EXTRA_FLAGS` in the builder argv on one target per
platform (`rpi-backend`, `x86-pki`, `frite`, `jetson-edge_ai`, `orangepi5`,
`orangepizero2`), 2 fleet-option threading probes prove
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
target/knob added without wiring the same gate, can never go green. Current
totals:
118 cells × 5 channels + 24 threading probes + 31 negatives = **645 checks**.

```sh
make matrix-check                 # or: bash tests/build-matrix/check.sh
```

### `--print-plan` — the dry-run contract

Every builder takes `--print-plan`: resolve + **validate** every flag, print
the machine-greppable plan (one `PLAN_KEY=VALUE` per line) and exit 0 —
**before any mutation** (no root, no disk writes, no network). Invalid
role/flag combinations exit non-zero *before* the plan prints, and secret
values (`--local-pass`, `--luks-pass`, …) are only ever echoed as `REDACTED`.
This is the contract every channel is verified against.

```sh
./build-x86-host-stage4.sh --role standalone-thick --env test --print-plan
./build-jetson-stage4.sh   --role edge_ai --print-plan
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

Each also has an `_ONLY=1` variant (`FRITE_ONLY=1`, `JETSON_ONLY=1`,
`ORANGEPI5_ONLY=1`, `ORANGEPIZERO2_ONLY=1`) that builds **only** that platform,
skipping every other one. `SKIP_X86=1` / `SKIP_RPI=1` drop those instead. See
`scripts/build-all-roles.sh`'s header comment for the full knob list — it is
independent of (and not verified by) the `matrix.tsv`/`check.sh` harness above,
since it's a real-build orchestrator rather than a dry-run one; any new
platform lands here in the *same* change as its `matrix.tsv`/`check.sh`
wiring, not as an afterthought.

## Related

- Channel parity per feature area: [`docs/STANDALONE-DESKTOP.md`](STANDALONE-DESKTOP.md),
  [`docs/CLIENT-IMAGES.md`](CLIENT-IMAGES.md), [`docs/EDGE-AI.md`](EDGE-AI.md) §1/§5.
- The three **EXPERIMENTAL** platforms (hardware validation pending):
  [`specs-jetson/README.md`](../specs-jetson/README.md) (NVIDIA Jetson Orin),
  [`specs-orangepi5/README.md`](../specs-orangepi5/README.md) (Orange Pi 5 / 5 Plus),
  [`specs-orangepi-zero2/README.md`](../specs-orangepi-zero2/README.md) (Orange Pi Zero 2, headless).
- Unit companions: `tests/menu/build_menu_cmd_test.sh` (menu command
  composition) and the Studio pytest suite (`studio/tests/`).
- **🔭 planned**: run `make matrix-check` as a fail-closed GitLab lint stage
  alongside the other `tests/scripts/*` gates (CI images need `pytest`
  available for the GUI leg).
