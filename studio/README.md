# HugMesh Image Studio

A cross-platform desktop app (Linux **and Windows**) that builds HugMesh images with a
Calamares-style wizard — no need to remember `build-x86-host-stage4.sh` flags. It also runs
a **local mesh node** from the system tray.

## What it does

- **Three modes**: a hardened **standalone desktop** (LUKS + SELinux), a **branded cloud
  image** (tailnet client + SSO, with an admin **key-zip** drop-in), or a **superadmin mesh**
  (define domains + attach users, then build node images).
- **Role & platform picker** — EVERY documented image role, grouped by mode (the
  all-options-in-all-menus rule, [docs/BUILD-MATRIX.md](../docs/BUILD-MATRIX.md)): both
  standalone variants **plus the two plain-Gentoo arms** — `standalone-unaffiliated`
  (an x86 desktop with ZERO HugMesh branding/tooling baked; branding pages disable
  themselves and any conflicting setting fails the command loudly, exactly like the
  builder) and the rpi5 `generic` unbranded arm64 server; the laptop/chromebook/desktop
  clients **and the arm64 La Frite family** (board + live/installer flavor +
  light/headless desktop); every cluster role on **x86 or Raspberry Pi 5**, plus the
  **NVIDIA Jetson Orin** roles (`edge-ai`, `backend-gpu`, `omnibus`, `jetson-desktop`) —
  Jetson is **EXPERIMENTAL, hardware validation pending**. The platform axis picks the
  builder script (`build-{x86-host,rpi5,frite,jetson}-stage4.sh`).
- **Every generator flag** is on a wizard page: hardware/GPU (the builder's **full
  `--gpu-driver` matrix**: all-free / nvidia-free / nvidia / amd-free / amd-pro /
  intel-free / intel-pro / none, or auto), the **test|prod `--env` picker** on the Build
  page, branding (boot screen / login /
  wallpaper / accent), the **web login theme** (primary/secondary colours with every
  other token derived at guaranteed WCAG-AA legibility, 7 system font stacks or an
  uploaded face with recorded licence/sha256, live token board + a real-browser
  preview of the captured login page; applied at container start — no rebuild),
  Wi-Fi/BT, **kernel built-in vs modules**, egress VPN, home mode +
  eCryptfs, installer front-ends, cached/uncached — plus the **cluster optional-services
  catalog** (+ games), client **desktop weight + Steam delivery**, **LUKS root encryption**
  (`--encrypt-root` + keyfile/YubiKey unlock factors), `--compress`/`--resume`, and an
  **extra-flags escape hatch** so any unfielded CLI flag stays expressible.
- **Secrets are never saved**: `--local-pass` / `--luks-pass` live only in the live command —
  a saved config JSON always carries them blanked, and saving warns you to re-enter them.
- **Hardware scanner**: detect the GPU / Wi-Fi / Bluetooth on the machine you're running on
  (Linux **and** Windows) and pre-fill the build. A **machine menu** ships Framework laptops,
  the ASUS VivoBook, and popular Amazon/Best Buy/Costco/Walmart laptops & gaming desktops.
- **Build backend**: native on Gentoo, otherwise **Docker** (Windows uses Docker Desktop).
  Same config → same command on every OS.
- **Device imaging**: the Review & Build page lists every attached USB/SD/eMMC
  device (recognising a Pi in rpiboot gadget mode and Libre-Computer/Amlogic
  eMMC in burn mode; the disk backing `/` can never appear) and lets you assign
  each one a worklist image **with its cluster domains shown**, plus **which
  artifact it becomes — install USB (`.installer.iso`), live USB (`.live.iso`)
  or the OS image (`.img`)** — only what that platform's builder actually emits
  is offered, and a flavour the finished run didn't produce is skipped with the
  reason, never guessed. Flashing runs post-build via `scripts/flash-disk.sh`
  behind a fresh per-device identity re-check.
- **Local mesh node**: start/stop/inspect a dockerized node from the **system tray**;
  the wizard's **local Docker mesh** flow is complete end-to-end from the GUI — a
  **Check readiness** probe (docker/buildx/disk/maven, read-only), the cold-build
  maven prerequisite (`make stack-m2-bootstrap`) as a button, live **streamed**
  build output with a **Cancel** that stops the whole process group, cold-aware
  timeouts (a first build compiles ~28 images and is never killed at minute 30),
  and an **Open web UI** shortcut to the running stack's front door.

## Run

```sh
# Linux (Gentoo can build natively; others need Docker)
pip install -r requirements.txt        # PySide6 (or use an existing PyQt6)
./hugmesh-studio

# Windows — the .bat is a guided bootstrapper: just double-click (or run) it
hugmesh-studio.bat
```

On Windows, `hugmesh-studio.bat` bootstraps a bare box end-to-end:

- **Ready box** (Python 3.10+ with PySide6/PyQt6 importable, or the local venv built):
  launches the wizard immediately — no report, no prompts.
- **Bare box**: prints a machine-greppable `DETECT …` report (python / pyside6 / venv /
  docker / winget) and offers **consent-gated** installs — nothing is ever installed
  without an explicit `y/N` answer, every offer shows the exact command first, and only
  `winget` (the OS package manager) is used: `Python.Python.3.12` for Python and
  `Docker.DockerDesktop` for Docker Desktop. Studio deps go into a project-local venv at
  `studio/.venv-studio` (`python -m venv` + `pip install -r requirements.txt`); the
  launcher activates it automatically on later runs.
- **Docker Desktop is OPTIONAL**: only the docker build backend needs it (native builds
  are not available on Windows), it needs WSL2 + a reboot/log-out + admin, and declining
  it never blocks the wizard — config/preview/`--print-command` all work without it (the
  docker backend stays greyed by the wizard's own preflight gating).
- Flags: `hugmesh-studio.bat /detect` prints the DETECT report and exits (never
  prompts, installs, or launches); `/auto` accepts every offer; any `--`-prefixed arg
  (e.g. `--print-command`) runs **headless** — no prompts, no installs, straight to
  `python -m hugmesh_studio` (the automation/e2e contract).
- No `winget` (LTSC/Server editions)? The launcher prints the manual install URLs
  (python.org / docs.docker.com) and exits with code 3 — it never downloads or executes
  anything itself.

Headless preview of the exact build command for a saved config — **Qt-free** (only
`core/` is imported, so it runs with no display and no PySide6/PyQt6 installed):

```sh
python -m hugmesh_studio --print-command --config my-image.json
python -m hugmesh_studio --print-command --config my-image.json --backend docker
# --backend auto|native|docker (auto = the host default; a host with no build
# backend still prints a deterministic native command)
```

The config's `platform` field (`x86` | `rpi5` | `frite` | `jetson` |
`orangepi5` | `orangepizero2` | `orangepizero2w` | `orangepizero3` | `orangepi3-lts` |
`orangepi4-lts`) selects the builder script the command targets.
**Driving the GUI headlessly (offscreen)?** Export `HUGMESH_STUDIO_NO_ELEVATION=1`.
A GUI-launched build's generated `SUDO_ASKPASS` helper passes `--askpass-gui` by design
(it is the operator's real credential prompt), so a non-pytest harness that walks the
real wizard under `QT_QPA_PLATFORM=offscreen` with `DISPLAY` set and WITHOUT the knob
would run a root `sudo -A` build and block on a dialog nobody can see (the #288 wedge).
With the knob set the driver and the flash worker refuse to spawn any elevation program.
pytest is covered automatically; every other harness must set it where it is written
(`scripts/render-all-images.py` does).

This headless path is what the build-matrix harness (`make matrix-check` at
the repo root) drives to prove the GUI channel agrees with the
CLI/make/menu/job channels on every matrix cell.

Two more **Qt-free** headless faces ride the same flag channel (#49 — everything
the GUI can do must be a documented command; repo-root `make` fronts:
`scan-hardware`, `sessions-list/-show/-artifacts/-delete`):

- **Hardware scan** — the wizard HardwarePage's probe (`core/hw_scan.py`:
  CPU / GPUs / Wi-Fi / Bluetooth + the recommended `--gpu-driver` /
  `--enable-wifi` / `--enable-bluetooth` / hw-profile settings):

  ```sh
  python -m hugmesh_studio --scan-hardware          # human two-column table
  python -m hugmesh_studio --scan-hardware --json   # stable machine-readable schema
  ```

- **Build-session history** — the Welcome page's Previous-builds list
  (`core/build_sessions.py` records; same records, same guards):

  ```sh
  python -m hugmesh_studio --list-sessions [--json]        # one line per session:
                                                           # id, date, roles, status, artifact count
  python -m hugmesh_studio --show-session ID [--json]      # full record + per-image outcomes
  python -m hugmesh_studio --session-artifacts ID [--json] # files under <out>/sessions/<ID>/
  python -m hugmesh_studio --delete-session ID --yes       # record only; REFUSES without --yes
  python -m hugmesh_studio --delete-session ID --yes --delete-artifacts
                                                           # ...also remove its artifact tree
  ```

  Deletion keeps the GUI's three-way guard: no `--yes` = refused (exit 2), an
  in-progress build is never deleted (exit 1), and the artifact tree is only
  removed on explicit `--delete-artifacts` (workdir shape-checked in core).

## Memory guard (2026-07-15 host-freeze incident)

A dockerized build runs under a **container memory cap** by default
(`--memory`/`--memory-swap`, equal — zero container swap), so a runaway compile
OOMs the *container* with an honest build failure instead of freezing the host.
The default is `max(2 GiB, min(MemTotal − 4 GiB, 75% of MemTotal))`; the cap is
always visible verbatim in the command preview. Override with
`HUGMESH_BUILD_MEMORY` (`16g`/`8192m` — a docker size string; `0`/`off`/`none`
disables the cap entirely).

A **fresh** config's parallel-jobs default is host-aware —
`max(2, min(cores, MemAvailable_GiB / 2))`, override with `HUGMESH_BUILD_JOBS`
— but a saved config's explicit `jobs` value is always used verbatim. When the
host looks memory-tight at dispatch (< 4 GiB available, or swap > 90% full) the
Review/Progress pages show an advisory **warning** (never a block, never a
silent throttle) — computed from a fresh `/proc/meminfo` reading at each
preflight, not a Studio-launch snapshot, because memory filling up *during* a
session is exactly the incident signature. A docker build killed by the cap
exits 137 (a bare SIGKILL — docker prints nothing); the Studio appends an
explicit log hint ("likely killed by its memory cap") naming the cap value and
the remedies. Asymmetry, honestly: **native builds cannot be memory-capped
by the Studio** — on a tight host prefer the Docker backend. On hosts without
`/proc/meminfo` (Windows/macOS) everything degrades to the historical behavior:
no cap, flat-8 jobs, no warnings.

Tray-only (mesh-node controller):

```sh
python -m hugmesh_studio --tray
```

Fleet builds (every role for the selected platforms in one run — the GUI
front-end to `scripts/build-all-roles.sh`; also reachable from the wizard's
welcome page):

```sh
python -m hugmesh_studio --fleet
```

## Terminal UI (parity lane, issue #51)

A host-side TUI over the same Qt-free `core/` the wizard drives — the Python twin of
the on-device whiptail menu (`scripts/build-menu.sh`), including its degradation
pattern: **urwid is optional**. With `NO_TUI=1`, no interactive TTY, `TERM=dumb`, or
urwid not installed, every flow degrades to plain numbered prompts instead of
crashing (the menu's `NO_TUI` rule, reused verbatim).

```sh
python -m hugmesh_studio.tui                       # the guided journey (welcome screen
                                                   #   first — the GUI wizard's page order)
python -m hugmesh_studio.tui --sessions            # sessions review (build history):
                                                   #   status · artifacts · delete-with-confirm
python -m hugmesh_studio.tui --worklist SESSION_ID # read-only worklist table for one session
python -m hugmesh_studio.tui --meshemu SESSION     # whole-mesh emulation status list
NO_TUI=1 python -m hugmesh_studio.tui              # force the plain-prompt fallback
```

The journey mirrors the GUI's flow (`hugmesh_studio/tui/journey.py` consumes
`config.WIZARD_PAGE_SLUGS` — one source, both faces): the three-card welcome
screen and journey-ordered mode menu, the Themes screen (web login theme:
colours, header/footer, background effect), the create-nodes-for-local-cloud
abbreviated wizard (k8s gate + identity import + laptop/node-only worklist),
the whole-mesh emulation per-device status list (ssh/web access as copy-ready
command hints), and the per-domain Sign-in choice on the domains step. Steps
not ported yet say so and keep the config's defaults; the walk ends in a config
you can save and build from the GUI or `--print-commands`.

urwid is deliberately **not** in `requirements.txt` (it must never become a hard
studio dependency — the test suite runs with it absent). To get the rich UI on
Gentoo, where `dev-python/urwid` is ~arch-keyworded, accept it with one line:

```sh
echo "dev-python/urwid ~amd64" >> /etc/portage/package.accept_keywords/hugmesh-studio
emerge --ask dev-python/urwid
```

(everywhere else: `pip install urwid`.)

## Package a Windows .exe

```sh
pip install pyinstaller PySide6
pyinstaller --noconfirm --windowed --name HugMeshImageStudio \
  --collect-all PySide6 -p . hugmesh_studio/__main__.py
```

## Layout

```
hugmesh_studio/
  core/        config (flag mapping) · build_driver (native/docker) · hw_scan ·
               profiles · keyzip · mesh_node · platform_info     <- headless, unit-testable
  gui/         qt shim (PySide6|PyQt6) · wizard (pages) · tray
  tui/         terminal UI (urwid, OPTIONAL — degrades to plain prompts)  <- headless, unit-testable
  app.py       entry point
tests/         pytest suite (headless, Qt-free)
pytest.ini
```

The `core/` package has **no Qt dependency**, so the build logic can be scripted or tested
without a display.

## Tests

```sh
cd studio && python -m pytest -q     # needs pytest; no Qt, no display, no root
```

The suite covers the `ImageConfig` → CLI-args translation for all four platforms
(including the rpi5/jetson role-name maps and the frite axes), the secret-blanking
save/load round-trip, the `BuildDriver` native/docker command assembly, and the
headless `--print-command` CLI path. The repo-level build-matrix harness
(`tests/build-matrix/check.sh`) additionally exercises the Studio as the GUI
channel for every canonical matrix cell.
