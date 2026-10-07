# NixOS / SteamOS / gaming-distro launchers

Running the **Studio wizard** and the **ncurses build menu** on hosts where the
usual assumptions (`python3` on PATH, `make` installed, an FHS layout) do **not**
hold: NixOS, SteamOS / Steam Deck, Arch, Debian/Ubuntu, Fedora.

Everything here is **additive** — it adds new launch paths, it does not change the
existing `make` targets, the Windows `studio/hugmesh-studio.bat`, or the
`python -m hugmesh_studio` entrypoint. Nothing installs anything without a `y/N`
confirmation (or `--auto`), and the launcher never calls a system package manager
for you — it only prints the exact command to run.

Two additive front doors are added:

- a **Nix flake + `shell.nix`** ([`flake.nix`](../flake.nix), [`shell.nix`](../shell.nix))
  that provide python3 + PySide6 + make + whiptail on any Nix host, and
- a **portable bash launcher** ([`scripts/studio-launch.sh`](../scripts/studio-launch.sh))
  that detects the distro, uses the system Python (3.10 or newer) when it can, and otherwise
  bootstraps a project-local venv — and, crucially, exports
  `PYTHONPATH=$REPO/studio` so it runs from **any** working directory.

The launcher's flags mirror the Windows `.bat`:

| flag | effect |
|---|---|
| *(none)* | guided run: detect, offer a venv if needed, launch the wizard |
| `--detect` | print the machine-greppable `DETECT …` report and exit (never prompts/installs/launches) |
| `--auto` | as guided, but accept every offer without a prompt |
| `--redo-first-run` | force the first-run bootstrap (see [FIRST-RUN.md](FIRST-RUN.md)) |
| `--menu` | hand off to the ncurses build menu (`scripts/build-menu.sh`) |
| `--tray`, `--stack-tray`, `--go-live`, `--fleet`, `--dev` | interactive GUI modes: forwarded to the wizard, but they keep the guided path (distro report, consent-gated venv) |
| `--<anything-else>` | **headless** automation (e.g. `--print-command`): no prompts, no installs, straight to `python3 -m hugmesh_studio` |

---

## NixOS

A pip venv of manylinux wheels will not link against the non-FHS `/nix` interpreter,
so on NixOS use **Nix**, not the venv path. The flake devShell supplies python3 +
PySide6 (satisfies `studio/requirements.txt`), `gnumake` and `whiptail` (`newt`), so
both the Studio wizard and the `make menu` real-build targets work inside it.

```sh
# Flakes enabled (experimental-features = nix-command flakes):
nix develop                     # then: ./scripts/studio-launch.sh   or   make menu
nix run .#studio                # launch the wizard directly
nix run .#studio -- --print-command --config my-image.json   # headless, args after --
nix run .#menu                  # launch the ncurses build menu

# No flakes? shell.nix gives the same toolchain:
nix-shell                       # then: ./scripts/studio-launch.sh   or   make menu
```

`./scripts/studio-launch.sh` (with no args) on NixOS **outside** a nix shell prints
these same commands and, with `--auto` and `nix` on PATH, re-execs through
`nix develop`. Inside a `nix develop` / `nix-shell` it launches the wizard directly.

> The committed tree ships **no `flake.lock`** — generate it once on a real Nix host
> (`nix flake lock`) and commit it, then smoke-test `nix develop -c true`.

---

## SteamOS / Steam Deck

SteamOS has a **read-only rootfs** and an empty pacman keyring. **Do not** run
`steamos-readonly disable` or pacman — you don't need to. The system Python is
present, and PySide6's manylinux wheel bundles its own Qt, so the launcher bootstraps
a venv **inside this checkout** (`studio/.venv-studio`, under `$HOME` — writable), and
the rootfs is never touched.

### Desktop Mode (recommended)

The wizard is keyboard/mouse-heavy, so run it from **Desktop Mode**:

```sh
./scripts/studio-launch.sh          # detect → offer the venv (y/N) → launch
./scripts/studio-launch.sh --menu   # the ncurses build menu
```

### Game Mode / adding it as a non-Steam game

Game Mode runs **gamescope** (Wayland). Qt needs XWayland, so the launcher exports
`QT_QPA_PLATFORM=xcb` automatically when it detects gamescope
(`XDG_CURRENT_DESKTOP=gamescope` or `$GAMESCOPE_WAYLAND_DISPLAY` set). To reach it
from the Steam UI: **Add a Non-Steam Game → Browse →** pick
`scripts/studio-launch.sh`. Desktop Mode is still the better experience.

### Missing shared library for the wheel

If the venv builds but the wizard fails to start with a missing shared library
(e.g. `libxcb-cursor.so.0`, `libxkbcommon`), install the freedesktop Flatpak runtime
and run under it, or point `LD_LIBRARY_PATH` at a runtime that has the lib. The
launcher **does not** auto-install system libraries (read-only rootfs); it prints
this remedy and stops.

### `make` for real builds

The Deck has no `make` by default. The ncurses menu still **renders** and its
python-driven local-mesh submenus work, but **real image builds shell `make`**. Get
`make` from a Nix dev shell (`nix develop`) or a distrobox/toolbox container; the
launcher warns when `make` is absent.

---

## Debian / Ubuntu

```sh
# Fast path (optional): the distro packages Qt for you.
sudo apt install python3 python3-venv python3-pyside6.qtwidgets
./scripts/studio-launch.sh

# Or let the launcher bootstrap a venv (it uses python3 -m venv + pip):
./scripts/studio-launch.sh          # detect → offer the venv (y/N) → launch
./scripts/studio-launch.sh --menu   # ncurses menu (apt install whiptail for the rich UI)
```

## Fedora

```sh
# Fast path (optional):
sudo dnf install python3 python3-pyside6
./scripts/studio-launch.sh

# Or bootstrap a venv:
./scripts/studio-launch.sh
./scripts/studio-launch.sh --menu   # ncurses menu (dnf install newt for the rich UI)
```

## Arch / Manjaro / EndeavourOS

```sh
# Fast path (optional):
sudo pacman -S python python-pyside6 make libnewt
./scripts/studio-launch.sh

# Or bootstrap a venv (do NOT pacman on SteamOS — see above):
./scripts/studio-launch.sh
./scripts/studio-launch.sh --menu
```

---

## Headless / automation (any distro)

The `--print-command` path is **Qt-free** (only `core/` is imported), so it needs no
display and no PySide6/PyQt6 — the build-matrix GUI channel relies on this:

```sh
./scripts/studio-launch.sh --print-command --config my-image.json
./scripts/studio-launch.sh --print-command --config my-image.json --backend docker
```

Any `--`-prefixed arg other than `--detect` / `--auto` / `--menu` / `--redo-first-run` and the
GUI modes in the table above takes this headless path: no prompts, no installs, straight to `python3 -m hugmesh_studio` with the
args forwarded.

## What the launcher detects

`./scripts/studio-launch.sh --detect` prints one greppable `DETECT` line per fact, then a short
`note:` paragraph, and exits 0:

```
DETECT os=steamos id_like=arch family=arch nix_shell=0 gamescope=1
DETECT python=found version=3.11.6 path=/usr/bin/python3.11
DETECT qt=missing binding=none scope=none
DETECT venv=missing path=/home/deck/hugmesh-generator/studio/.venv-studio
DETECT make=missing
DETECT whiptail=found
DETECT nix=missing
```
