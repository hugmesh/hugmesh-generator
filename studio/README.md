# HugMesh Image Studio

A desktop app for Linux **and Windows**. A Calamares-style wizard builds HugMesh images, so
you do not have to remember `build-x86-host-stage4.sh` flags. The app also runs a **local
mesh node** from the system tray.

## What it does

- **Three image modes.** A hardened **standalone desktop** (`standalone`; LUKS + SELinux).
  A **mesh desktop client** (`cloud`; tailnet client + SSO, with an admin **key-zip**
  drop-in). A **mesh node** build (`mesh`; the superadmin defines domains and users, then
  builds node images). The build menu has ten cards: these three, and seven that run a tool
  instead of building an image. [docs/STUDIO-WALKTHROUGH.md](../docs/STUDIO-WALKTHROUGH.md)
  covers all ten.
- **Role and platform picker.** It lists EVERY documented image role, grouped by mode (the
  all-options-in-all-menus rule, [docs/BUILD-MATRIX.md](../docs/BUILD-MATRIX.md)).
  - Both standalone variants, plus the two plain-Gentoo arms. `standalone-unaffiliated` is
    an x86 desktop with ZERO HugMesh branding or tooling baked in: the brand-identity fields
    hide themselves, themes and wallpapers stay available, and any conflicting setting
    fails the command loudly, exactly like the builder. The rpi5 `generic` arm is an
    unbranded arm64 server.
  - The laptop, chromebook and desktop clients, and the arm64 La Frite family (board,
    live/installer flavor, light/headless desktop).
  - Every cluster role on **x86 or Raspberry Pi 5**, plus the **NVIDIA Jetson Orin** roles
    (`edge-ai`, `backend-gpu`, `omnibus`, `jetson-desktop`). Jetson is **EXPERIMENTAL,
    hardware validation pending**.
  - The platform axis picks the builder script: `build-x86-host-stage4.sh`,
    `build-rpi5-stage4.sh`, `build-frite-stage4.sh`, `build-jetson-stage4.sh` and one script
    per Orange Pi board (`BUILDER_SCRIPTS` in `core/config.py` lists all ten).
- **Every generator flag** is on a wizard page:
  - hardware and GPU, with the builder's **full `--gpu-driver` matrix** (all-free /
    nvidia-free / nvidia / amd-free / amd-pro / intel-free / intel-pro / none, or auto);
  - the **test|prod `--env` picker** on the Build page;
  - branding (boot screen, login, wallpaper, accent);
  - the **web login theme**: primary and secondary colours, with every other token derived
    at guaranteed WCAG-AA legibility; 7 system font stacks, or an uploaded face with its
    licence and sha256 recorded; a live token board and a real-browser preview of the
    captured login page. It applies at container start, with no rebuild;
  - Wi-Fi/BT, **kernel built-in vs modules**, egress VPN, home mode + eCryptfs, installer
    front-ends, cached/uncached;
  - the **cluster optional-services catalog** (+ games), client **desktop weight + Steam
    delivery**, **LUKS root encryption** (`--encrypt-root` + keyfile/YubiKey unlock
    factors), `--compress`/`--resume`;
  - an **extra-flags escape hatch**, so any flag without a field stays expressible.
- **Secrets are never saved.** `--local-pass`, `--luks-pass`, `--user-password` and
  `--root-password` live only in the live command. A saved config JSON always carries them
  blanked, and saving warns you to re-enter them.
- **Hardware scanner.** It detects the GPU, Wi-Fi and Bluetooth on the machine you run it on
  (Linux **and** Windows) and pre-fills the build. A **machine menu** ships Framework
  laptops, the ASUS VivoBook, and popular Amazon/Best Buy/Costco/Walmart laptops and gaming
  desktops.
- **Build backend.** Native on Gentoo, otherwise **Docker** (Windows uses Docker Desktop).
  The same config gives the same command on every OS.
- **Device imaging.** The Review & Build page lists every attached USB/SD/eMMC device. It
  recognises a Pi in rpiboot gadget mode and Libre-Computer/Amlogic eMMC in burn mode. The
  disk backing `/` can never appear. You assign each device a worklist image **with its
  cluster domains shown**, and **the artifact it becomes**: install USB (`.installer.iso`),
  live USB (`.live.iso`) or the OS image (`.img`). Only what that platform's builder emits
  is offered. A flavour the finished run did not produce is skipped with the reason, never
  guessed. Flashing runs after the build, through `scripts/flash-disk.sh`, behind a fresh
  per-device identity re-check.
- **Local mesh node.** Start, stop and inspect a dockerized node from the **system tray**.
  The wizard's **local Docker mesh** flow (join an existing mesh with a key, or generate a
  new one in a few steps) works end to end from the GUI:
  - a read-only **Check readiness** probe (docker, buildx, disk, maven);
  - the cold-build maven prerequisite (`make stack-m2-bootstrap`) as a button;
  - live **streamed** build output, with a **Cancel** that stops the whole process group;
  - cold-aware timeouts (a first build compiles ~28 images and is never killed at minute 30);
  - an **Open web UI** shortcut to the running stack's front door.

### Local mesh: code folders (on the Repo source step)

Under the Repo source cards, a **Code folders** block lists every domain from the
Domains step and, under each, the apps that domain runs: the platform apps (one set
of images serves every domain) plus the optional services chosen for it on the
Domain services step, marked `[<slug>]`. Each row names the git checkout compose
builds that app from and has an **Open folder** button; every domain has **Open
all**; the block has **Open source root**. The folder is the one the build reads —
`<source dir>/hugmesh-<name>` with *Build from a source tree I already have*,
`./.stack-src/hugmesh-<name>` with *Download the source* (or, if you exported
`STACK_SRC` before starting the Studio, that folder — the Makefile keeps it and so
does the block) — parsed from the
`context:` values of `tests/stack/compose.local.yaml` and the files it includes
(`core/code_folders.py`), so the rows cannot drift from what `docker compose build`
resolves. The source directory is read exactly as the build reads it, so `~` is not
expanded (type the full path) and the block names the same folder the coverage line
above it counts. The block re-reads the disk when a run finishes, so folders the
Studio just cloned become openable without touching a control (the end-to-end
scenario below finishes a run the way *Generate & start* does and reads the rows
after it, so removing that re-read turns it red). A folder that is not
there yet is a disabled button with the reason beside it ("not downloaded yet…",
"no hugmesh-<name> checkout in …"); a service that runs a stock image (Akkoma,
tuwunel, the databases) gets a note instead of a row. In *Download the source* mode
the block says that `make stack-clone` git-resets the checkouts under `.stack-src`
(only ones holding local commits are kept), and that the other mode never touches
yours.

Opening (`core/open_path.py`) uses `xdg-open`/`gio` on Linux, `explorer.exe` via
`wslpath` on WSL2, `os.startfile` on Windows and `open` on macOS, with Qt's desktop
fallback last. Only an opener that exits 0 counts as confirmed. One that is still
running after 3 seconds (usually the file manager itself) is reported as *asked,
not confirmed*, in amber, with the path to copy. **Open all** shares one 3-second
waiting budget across all of a domain's folders (a click runs on the window's own
thread, so 25 folders must not mean 25 waits); folders handed over after the budget
is spent are reported as unconfirmed. When nothing can be confirmed the block says
so inline and offers the path to copy. No dialogs.

The end-to-end scenarios for this block are
`tests/e2e/features/studio-code-folders/studio-code-folders.feature` (steps in
`tests/e2e/steps/studio-code-folders.steps.ts`), driven by
`tests/e2e/studio-code-folders-driver.py` (the real wizard, offscreen, with a
stand-in `xdg-open` on PATH that logs what it is handed). Run them with
`cd tests/e2e && SNAP_STUDIO_PYTHON=<python with PySide6 or PyQt6> npx bddgen test &&
QT_QPA_PLATFORM=offscreen npx playwright test --project=bdd -g "git checkout behind every app"`.
They need no mesh and start nothing.

## Run

```sh
# Linux, from the root of a checkout (Gentoo can build natively; others need Docker)
cd studio
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt        # PySide6 (or use an existing PyQt6)
./hugmesh-studio

# Windows — the .bat is a guided bootstrapper: just double-click (or run) it
hugmesh-studio.bat
```

On Windows, `hugmesh-studio.bat` sets up a bare box from start to finish:

- **Ready box** (Python 3.10+ with PySide6/PyQt6 importable, or the local venv built): it
  launches the wizard at once. No report, no prompts.
- **Bare box**: it prints a machine-greppable `DETECT …` report (python / pyside6 / venv /
  docker / winget) and offers **consent-gated** installs. Nothing installs without an
  explicit `y/N` answer, every offer shows the exact command first, and only `winget` (the
  OS package manager) is used: `Python.Python.3.12` for Python and `Docker.DockerDesktop`
  for Docker Desktop. Studio dependencies go into a project-local venv at
  `studio/.venv-studio` (`python -m venv` + `pip install -r requirements.txt`). The
  launcher activates it on later runs.
- **Docker Desktop is OPTIONAL.** Only the docker build backend needs it; native builds are
  not available on Windows. It needs WSL2, a reboot or log-out, and admin rights. Declining
  it never blocks the wizard: config, preview and `--print-command` all work without it,
  and the wizard's own preflight greys out the docker backend.
- Flags: `hugmesh-studio.bat /detect` prints the DETECT report and exits (it never prompts,
  installs or launches). `/auto` accepts every offer. Any `--`-prefixed arg (for example
  `--print-command`) runs **headless**: no prompts, no installs, straight to
  `python -m hugmesh_studio` (the automation/e2e contract).
- No `winget` (LTSC/Server editions)? The launcher prints the manual install URLs
  (python.org / docs.docker.com) and exits with code 3. It never downloads or executes
  anything itself.

Preview the exact build command for a saved config without a GUI. This path is **Qt-free**
(only `core/` is imported), so it needs no display and no PySide6/PyQt6:

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
A GUI-launched build's generated `SUDO_ASKPASS` helper passes `--askpass-gui` by design: it
is the operator's real credential prompt. A harness other than pytest that walks the real
wizard under `QT_QPA_PLATFORM=offscreen` with `DISPLAY` set, and WITHOUT the knob, would run
a root `sudo -A` build and block on a dialog nobody can see (the #288 wedge). With the knob
set, the driver and the flash worker refuse to spawn any elevation program. pytest sets it
for you. Every other harness must set it itself (`scripts/render-all-images.py` does).

The build-matrix harness (`make matrix-check` at the repo root) drives this headless path.
It proves the GUI channel agrees with the CLI/make/menu/job channels on every matrix cell.

Two more **Qt-free** headless faces ride the same flag channel (#49: everything the GUI can
do must be a documented command; repo-root `make` fronts: `scan-hardware`,
`sessions-list/-show/-artifacts/-delete`):

- **Hardware scan** — the wizard HardwarePage's probe (`core/hw_scan.py`: CPU, GPUs, Wi-Fi,
  Bluetooth, and the recommended `--gpu-driver` / `--enable-wifi` / `--enable-bluetooth` /
  hw-profile settings):

  ```sh
  python -m hugmesh_studio --scan-hardware          # human two-column table
  python -m hugmesh_studio --scan-hardware --json   # stable machine-readable schema
  ```

- **Build-session history** — the Prior-sessions page's Previous-builds list (the
  `core/build_sessions.py` records, with the same guards):

  ```sh
  python -m hugmesh_studio --list-sessions [--json]        # one line per session:
                                                           # id, date, roles, status, artifact count
  python -m hugmesh_studio --show-session ID [--json]      # full record + per-image outcomes
  python -m hugmesh_studio --session-artifacts ID [--json] # files under <out>/sessions/<ID>/
  python -m hugmesh_studio --delete-session ID --yes       # record only; REFUSES without --yes
  python -m hugmesh_studio --delete-session ID --yes --delete-artifacts
                                                           # ...also remove its artifact tree
  ```

  Deletion keeps the GUI's three-way guard. No `--yes` is refused (exit 2). An in-progress
  build is never deleted (exit 1). The artifact tree goes only on an explicit
  `--delete-artifacts` (core checks the workdir's shape first).

## Local mesh: work on it with a local AI agent (issue #695)

On the **Bring-up** page of the local-mesh path (where both the Docker mesh and the
kind DevOps lane end) the card **Work on this mesh with a local AI agent** starts a coding
agent on a model that runs on this PC, in a copy of one app's repository. It does what
[docs/LOCAL-AI-ASSISTANT.md](../docs/LOCAL-AI-ASSISTANT.md) tells a person to do by hand:

- The card names, in plain words, the first thing that is missing: Ollama not installed,
  the server not answering on `127.0.0.1:11434`, no pulled model with the **tools**
  capability, the agent command (`claude`, `opencode`, `codex`) not installed, or the
  chosen app's folder not being a git repository. **Start local agent chat** stays
  disabled, with the reason as its tooltip, until nothing is missing. **Re-check** reads the
  machine again (read-only: `GET /api/tags`, `POST /api/show`, never a generation);
  **Copy command** is always available. Nothing starts without a press. No dialogs.
- A press makes `<state dir>/agent-work/<mesh>/<repo>` with `git clone --no-hardlinks`,
  `git remote remove origin` and `git switch -c lm/<timestamp>` from the app's folder
  (`./.stack-src/hugmesh-<name>`, or your own tree), writes the brief beside it, and opens a
  terminal (xfce4-terminal, konsole, kitty, gnome-terminal, alacritty, foot, xterm) running
  `ollama launch <agent> --model <model>` there. A copy is reused only when it has no
  uncommitted work, no remote and was cloned from the folder's current commit; otherwise a
  numbered one is made and nothing is deleted. Uncommitted edits in the real folder are not
  in the copy, and the card says so.
- The model is `hugmesh-agent` when pulled, else the first model the doc names that is
  pulled with tools (`qwen3:8b` first), else the first with tools. Cloud models are never
  offered.
- The launch environment is an allowlist (`PATH`, `HOME`, `USER`, `LANG`, `LC_*`, `TERM`, the
  display variables, `XDG_*`, `DBUS_SESSION_BUS_ADDRESS`, and `OLLAMA_HOST` only when it
  points at this machine), applied inside the window with `env -i` under
  `bash --noprofile --norc`, so `GH_TOKEN`, `GITHUB_TOKEN`, registry and cloud tokens,
  `SSH_AUTH_SOCK` and `ARGOCD_*` never reach the agent. No auto-approve flag is ever passed
  (`-y`, `--yes`, `--experimental-yolo`, ...). A keyring that answers on the desktop session
  bus is still reachable, which is why the agent's commands are for you to read and approve.
- When no terminal takes the request (no desktop, WSL2 without WSLg, nothing installed, every
  terminal refused) the card shows the exact lines to run yourself. After a Start the copy
  already exists, so those lines are only `cd <copy>` and the launch line; **Copy command**,
  which can be pressed before any copy exists, also has the clone, remote-removal and branch
  lines first. Every line is chained to the one before with `&&`, so a failed clone or a
  missing copy stops the rest instead of running them in whatever folder your shell is in.
  Native Windows and macOS do not open a window; run the Studio inside WSL2 or
  follow the doc by hand.

Code: `core/local_agent.py` (Qt-free) and `gui/pages/_local_agent_widget.py`; tests:
`tests/test_local_agent.py`, `tests/test_local_agent_gui.py`.

## Memory guard (2026-07-15 host-freeze incident)

A dockerized build runs under a **container memory cap** by default (`--memory` and
`--memory-swap`, equal: zero container swap). A runaway compile now OOMs the *container* and
fails the build honestly, instead of freezing the host. The default is
`max(2 GiB, min(MemTotal − 4 GiB, 75% of MemTotal))`. The command preview always shows the cap
verbatim. Override it with `HUGMESH_BUILD_MEMORY` (`16g` or `8192m`, a docker size string;
`0`, `off` or `none` removes the cap).

A **fresh** config's parallel-jobs default depends on the host:
`max(2, min(cores, MemAvailable_GiB / 2))`. Override it with `HUGMESH_BUILD_JOBS`. A saved
config's explicit `jobs` value is always used as written.

If the host looks memory-tight at dispatch (< 4 GiB available, or swap > 90% full), the
Review and Progress pages show an advisory **warning**. It never blocks and never silently
throttles. It comes from a fresh `/proc/meminfo` reading at each preflight, not a snapshot
from Studio launch, because memory filling up *during* a session is the incident signature.

A docker build killed by the cap exits 137 (a bare SIGKILL; docker prints nothing). The Studio
then appends a log hint ("likely killed by its memory cap") that names the cap value and the
remedies. One asymmetry: **native builds cannot be memory-capped by the Studio**. On a tight
host, prefer the Docker backend. On hosts without `/proc/meminfo` (Windows/macOS) behaviour
falls back to the old rules: no cap, jobs = `min(cores, 8)`, no warnings.

Tray-only (mesh-node controller):

```sh
python -m hugmesh_studio --tray
```

Fleet builds (every role for the selected platforms in one run; the GUI front-end to
`scripts/build-all-roles.sh`). The wizard's Prior-sessions page also reaches it, but that
button shows only when `HUGMESH_STUDIO_ADVANCED` is set:

```sh
python -m hugmesh_studio --fleet
```

## Terminal UI (parity lane, issue #51)

A host-side TUI over the same Qt-free `core/` the wizard drives. It is the Python twin of the
on-device whiptail menu (`scripts/build-menu.sh`) and degrades the same way: **urwid is
optional**. With `NO_TUI=1`, no interactive TTY, `TERM=dumb`, or urwid not installed, every
flow falls back to plain numbered prompts instead of crashing (the menu's `NO_TUI` rule,
reused as is).

```sh
python -m hugmesh_studio.tui                       # the guided journey (welcome screen
                                                   #   first — the GUI wizard's page order)
python -m hugmesh_studio.tui --sessions            # sessions review (build history):
                                                   #   status · artifacts · delete-with-confirm
python -m hugmesh_studio.tui --worklist SESSION_ID # read-only worklist table for one session
python -m hugmesh_studio.tui --meshemu SESSION     # whole-mesh emulation status list
python -m hugmesh_studio.tui --fleet               # fleet build (scripts/build-all-roles.sh)
python -m hugmesh_studio.tui --go-live             # go-live flow: provider, domain, exposure plan
python -m hugmesh_studio.tui --plain               # force the plain-prompt fallback
NO_TUI=1 python -m hugmesh_studio.tui              # the same, by environment
```

The journey mirrors the GUI's flow. `hugmesh_studio/tui/journey.py` consumes
`config.WIZARD_PAGE_SLUGS`, so both faces share one page order. It has the two-card welcome
screen and the journey-ordered mode menu; the Themes screen (web login theme: colours,
header/footer, background effect); the create-nodes-for-local-cloud abbreviated wizard (k8s
gate, identity import, laptop/node-only worklist); the whole-mesh emulation per-device status
list (ssh and web access as copy-ready command hints); and the per-domain Sign-in choice on
the domains step. Steps not ported yet say so and keep the config's defaults. The walk ends
in a config you can save and build from the GUI, or pass to `--print-commands`.

urwid is deliberately **not** in `requirements.txt`: it must never become a hard studio
dependency, and the test suite runs without it. For the rich UI on Gentoo, where
`dev-python/urwid` is ~arch-keyworded, accept it with one line:

```sh
echo "dev-python/urwid ~amd64" >> /etc/portage/package.accept_keywords/hugmesh-studio
emerge --ask dev-python/urwid
```

(everywhere else: `pip install urwid`.)

## Package a Windows .exe

The PyInstaller spec is committed at `packaging/hugmesh-studio.spec`; the MSI, the Flatpak
and the local build commands are in [docs/STUDIO-INSTALLERS.md](../docs/STUDIO-INSTALLERS.md).

## Layout

```
hugmesh_studio/
  core/        config (flag mapping) · build_driver (native/docker) · hw_scan ·
               profiles · keyzip · mesh_node · platform_info     <- headless, unit-testable
  gui/         qt shim (PySide6|PyQt6) · wizard (pages) · tray
  tui/         terminal UI (urwid, OPTIONAL — degrades to plain prompts)  <- headless, unit-testable
  app.py       entry point
packaging/     PyInstaller spec, WiX (MSI) and Flatpak files
tests/         pytest suite
pytest.ini
```

The `core/` package has **no Qt dependency**, so you can script or test the build logic
without a display.

## Tests

```sh
cd studio && python -m pytest -q     # needs the `test` extra: pytest, PyYAML, jsonschema, cryptography
```

Many tests need Qt and skip (`pytest.importorskip`) when no binding is installed. CI runs
the Qt-free suite (`.github/workflows/studio-tests.yml`).

The suite covers the `ImageConfig` → CLI-args translation for every platform (the
composite `rpi5-desktop`/`jetson-desktop` role ids, the frite axes), the secret-blanking
save/load round-trip, the `BuildDriver` native/docker command assembly, and the
headless `--print-command` CLI path. The repo-level build-matrix harness
(`tests/build-matrix/check.sh`) additionally exercises the Studio as the GUI
channel for every canonical matrix cell.
