# The build matrix — every option, every channel, verified

_State key: **✅ shipped** (on `main`) · **🚧 in-flight** · **🔭 planned**._

This repo builds a **matrix** of images: platform × role × build ENV (× the
platform's own axes), and it exposes that matrix through **four build
front-ends ("channels")**. This document is the canonical description of both,
and of the harness that keeps them from drifting apart.

## The standing rule: all options in all menus

> Every documented image option must be reachable from every build channel.
> (Standing rule — [`specs-jetson/README.md`](../specs-jetson/README.md).)

A role, board, flavor, desktop weight or builder flag that exists on the CLI
must also be buildable from `make`, from the ncurses menu, and from the Studio
GUI — and vice versa. Where a channel has no dedicated widget for a flag, it
must still be *expressible* (the menu's and Studio's **extra-flags escape
hatch** exists for exactly that). New options land in **all four channels in
the same change**, plus a row (or axis) in the canonical matrix below.

## The four channels

| Channel | Entry point | How a build is described |
|---|---|---|
| **CLI** | `./build-{rpi5,x86-host,frite,jetson}-stage4.sh` | flags (`--role`, `--env`, `--board`, `--flavor`, `--desktop`, …) |
| **make** | `Makefile` targets (`make x86-<role>`, `make rpi-<role>`, `make frite`, `make jetson-<role>`, `make build-all`, `make build-everything`) | make vars (`ENV=`, `BRAND=`, `FRITE_*=`, `JETSON_*=`, `IMG_FLAGS=`, `STANDALONE_FLAGS=`) |
| **ncurses menu** | `make menu` (`scripts/build-menu.sh`) | interactive screens persisting `OPT_*` state; composes the same make invocation |
| **Studio GUI** | `studio/` (`python -m snapdragon_studio`) | wizard pages over `ImageConfig`; the same config drives the headless `--print-command` |

Every channel is crossed with the **build ENV** (`test` | `prod`), threaded as
`--env` on the builders and `ENV=` through make — see the
[Build ENV section of the README](../README.md#build-env-testprod-baked-at-image-creation).

## The canonical matrix — `tests/build-matrix/matrix.tsv`

One row per buildable image cell `(platform, role, env, board, flavor,
desktop)`; `-` marks an axis a platform does not have. **78 cells** today:

| Platform | Builder | Cells | Axes |
|---|---|---|---|
| **rpi5** | `build-rpi5-stage4.sh` | 3 roles (`pki`, `backend`, `frontend`) × 2 env = **6** | — |
| **x86** | `build-x86-host-stage4.sh` | 11 roles × 2 env = **22** | nodes `pki be fe be+gpu`, `omnibus`, `edge_ai`, clients `laptop chromebook desktop`, `standalone-thin standalone-thick` |
| **frite** | `build-frite-stage4.sh` | 3 boards × 3 flavors × 2 desktops × 2 env = **36** | board `la-frite\|le-potato\|sweet-potato`, flavor `live\|installer\|both`, desktop `light\|none` |
| **jetson** *(EXPERIMENTAL)* | `build-jetson-stage4.sh` | 4 roles × 2 env on `orin-nano` + 3 boards × 2 env on `edge_ai` = **14** | roles `edge_ai gpu-host full desktop`; board `orin-nano\|orin-nano-4gb\|orin-nx-8gb\|orin-nx-16gb` (non-default boards carried on the headline `edge_ai` role) |

Adding an image option means adding/extending rows here — the harness then
holds every channel to it.

## The harness — `tests/build-matrix/check.sh` (`make matrix-check`)

**✅ shipped.** For **every** matrix row the harness proves all four channels
agree on the cell — entirely **dry-run**: no root, no writes outside `mktemp`,
no network, ~15 s:

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

Plus **negative checks** (11): invalid roles on x86/rpi5/jetson, an invalid
frite board and desktop, an invalid jetson board, invalid `--env` values,
x86-only flags (`--steam`, `--local-pass`) rejected by the rpi5 builder, and an
unknown platform refused by the GUI — all must exit non-zero, so a typo can
never *silently* build the wrong image. The harness exits 1 on any failure —
including a **completeness gate**: every channel's pass count must equal the
row count (a crashed channel child or a silently skipped row fails the run,
never degrades it). It also runs **14 flag-threading probes**: `STANDALONE_FLAGS`
must reach the builder argv on the `x86-%` / `jetson` / `jetson-%` / `frite`
recipes (the menu's and Studio's extra-flags escape hatch rides it), `IMG_FLAGS`
must reach it on `rpi-%` / `x86-%` / `frite` / `jetson` / `jetson-%` (every
platform offers the image-flags knob), and four end-to-end MENU→MAKE probes
prove `build_make_cmd`'s composed invocation lands both `OPT_IMGFLAGS` and
`OPT_EXTRA_FLAGS` in the builder argv on one target per platform — a recipe
that ignores a make-var the menu emits can never go green. Current totals:
78 cells × 4 channels + 14 threading probes + 11 negatives = **337 checks**.

```sh
make matrix-check                 # or: bash tests/build-matrix/check.sh
```

### `--print-plan` — the dry-run contract

All four builders take `--print-plan`: resolve + **validate** every flag, print
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

`make matrix-check` validates; **`make build-everything`** builds — the full
documented matrix (3 Pi roles + all 11 x86 roles + the Frite + all 4 Jetson
roles), honoring `ENV=test|prod` and the usual `BRAND=` / `DOMAIN=` /
`WORK_DIR=` overrides. It threads `scripts/build-all-roles.sh`'s role-selector
knobs (`X86_ROLES`, `FRITE=1`, `JETSON=1 JETSON_ROLES=…`), so partial
supersets are one env-var away.

## Related

- Channel parity per feature area: [`docs/STANDALONE-DESKTOP.md`](STANDALONE-DESKTOP.md),
  [`docs/CLIENT-IMAGES.md`](CLIENT-IMAGES.md), [`docs/EDGE-AI.md`](EDGE-AI.md) §1/§5.
- The Jetson platform (**EXPERIMENTAL** — hardware validation pending):
  [`specs-jetson/README.md`](../specs-jetson/README.md).
- Unit companions: `tests/menu/build_menu_cmd_test.sh` (menu command
  composition) and the Studio pytest suite (`studio/tests/`).
- **🔭 planned**: run `make matrix-check` as a fail-closed GitLab lint stage
  alongside the other `tests/scripts/*` gates (CI images need `pytest`
  available for the GUI leg).
