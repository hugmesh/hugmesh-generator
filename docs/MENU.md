# The ncurses build menu (`scripts/build-menu.sh`)

A terminal (whiptail/ncurses) front door over the image build. It is one of the four
build channels in [`BUILD-MATRIX.md`](BUILD-MATRIX.md) (CLI / `make` / this menu / Studio
GUI) and is covered briefly in [`RUNNING.md`](RUNNING.md#3menu-interactive-console-menu-easiest)
as part of the build walkthrough. This page is the menu's own reference: every screen it
offers and what each one does.

```bash
make menu          # or:  ./scripts/build-menu.sh
```

It adds no logic of its own to the build engine — every build path dispatches through the
same `make`/`build_make_cmd` invocations the CLI and `make` targets use, so a fix or a new
flag only has to land once. It drives **both** build paths: the default Docker builder
image, and the local `NATIVE=1` Gentoo path (toggled from *Options → Build path*).

## Renderer and fallback

With a real TTY, `whiptail` on `PATH`, and `NO_TUI` unset, it draws whiptail (newt/ncurses)
dialogs. Otherwise — inside the minimal Docker builder image, in a dumb terminal, or with
`NO_TUI=1` set deliberately — it falls back on its own to a plain numbered-prompt menu, so
it still works without a rich terminal. The live build monitor (below) is plain ANSI either
way, since it needs to show a "press q to leave the build running" hint a whiptail gauge
cannot offer.

## Startup: re-attach before anything else

On every launch, before showing the main menu, it checks for a build already running —
either one this menu itself started (tracked by PID file) or one started by hand (e.g. a
direct `./scripts/build-all-roles.sh …` run). If one is found, it opens the live monitor
for it immediately; `q` from the monitor drops into the main menu, which also opens with
**Monitor the running build** as its first, pre-selected item in that case.

## Main menu

The top-level screen (`main_menu()`), always reachable with `‹ back›` from any build
screen:

| Item | What it does |
| --- | --- |
| **Monitor the running build** | only shown while a build (ours or a foreign one) is alive; live progress |
| **Build images …** | opens *What do you want to build?* (below) |
| **Options (path / env / brand / jobs) …** | the options screen |
| **Show built artifacts** | lists output images/ISOs for the current work dir |
| **Show build log tail** | the rolling tail of the current/last build log |
| **Clean / wipe work dir** | removes build state under the work dir (confirms first) |
| **Quit** | any build already running keeps going; re-run the menu to re-attach |

### What do you want to build?

The menu's build-mode picker (`mode_screen()`) is the single golden source of the
four-label build taxonomy that `BUILD-MATRIX.md`'s channel-parity check anchors to — the
Studio GUI's mode page mirrors the same four labels:

| Choice | Builds an image? | Goes to |
| --- | --- | --- |
| **Mesh node** | yes | the full build screen (fleet/role targets) |
| **Local Docker mesh** | no — runs a mesh on this machine right now | the local-mesh driver (`python3 -m hugmesh_studio.core.local_mesh`) |
| **Mesh desktop client** | yes | the single-role screen (client desktop roles) |
| **Standalone Gentoo desktop** | yes | the single-role screen (standalone/ARM posture) |
| **MDM phone** | no — flashes + enrolls a USB Pixel | the phone driver |
| **MDM Quest headset** | no — enrolls an as-is Quest 3/3S | the phone driver, quest device class |
| **Cloud deploy** | no — publishes an already-built image | the cloud-deploy driver |
| **Advanced** | — | the full build screen (every target, the escape hatch) |

Three of the eight commit an image mode and build; the rest each run one tool (a local
mesh, an MDM enrollment, or a cloud publish) and build nothing.

### Options

Everything the build invocation needs besides the mode: build path (docker/native),
environment (test/prod), parallel jobs, work/output dir, brand and domain override, the
full-fleet-only toggles (resume, x86 omnibus, Frite/Jetson/Orange Pi 5 fleet membership,
OWASP pen-test), optional services and managed-backing-service overrides, Tor onion,
thin-desktop host (Sunshine), identity provider, Character Studio/Forge, advanced branding
overrides, home provisioning mode, installer UI, image format flags, a shared distfiles
dir, an escape-hatch extra-flags field, and the root SSH login posture. Choices are saved
and reloaded between runs.

## Live progress monitor

Once a build is launched, the monitor screen parses the build log for emerge's
`(X of Y)` package counter and the per-role banners and draws overall, per-role and
current-package progress bars plus a rolling log tail.

- **Quit without stopping**: every build is launched *detached* (`setsid nohup … &`, its
  own session), so pressing `q` in the monitor — or even closing the terminal — leaves it
  running. Press `s` in the monitor to stop it instead.
- **Re-attach**: re-running `make menu` at any later point drops straight back into the
  live progress of a build still running, whether this menu started it or not.

## Other screens reachable from the build picker

`single_role_screen` (per-role/device builds for the client and standalone paths),
`build_screen`/`prebuild_screen` (the full target list, review before launch),
`local_mesh_screen`/`local_mesh_bootstrap_screen` (the Local Docker mesh flow),
`phone_screen`/`quest_screen` (the MDM enrollment driver), `deploy_screen` (cloud publish),
`frite_screen` (Frite-specific device steps), `desktop_screen`/`home_screen` (home
provisioning for standalone/client desktops), `services_screen`/`managed_services_screen`/
`edge_ai_options_screen` (optional-service and managed-backend toggles), `idp_screen`
(identity provider), `branding_screen` (wallpaper/GRUB/login/logo/accent/scheme), and
`ram_screen` (a resource-limit prompt). Each is a thin front end over the same build/driver
entry points the CLI and `make` targets call — nothing here is menu-only logic.

## First run

The menu runs the same advisory, one-time first-run bootstrap as the rest of the repo (see
[`FIRST-RUN.md`](FIRST-RUN.md)): `~/.local/bin/hugmesh-build-menu`, a `properties.json`, and
a doctor pass. It is a no-op once stamped and can never block the menu from opening
(`--redo-first-run` forces it again).

## Host-side Python twin

`python -m hugmesh_studio.tui` is the Studio's text-mode parity lane: the same guided
journey (welcome screen, mode menu, Themes, create-nodes-for-local-cloud, whole-mesh
emulation, per-domain Sign-in) over the Qt-free `core/` the GUI wizard drives, and it
follows the same `NO_TUI` degradation rule. See
[`studio/README.md`](../studio/README.md#terminal-ui-parity-lane-issue-51) for its flags
(`--sessions`, `--worklist`, `--meshemu`, `--fleet`, `--go-live`) and optional-urwid notes.
