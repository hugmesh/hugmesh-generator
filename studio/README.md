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
  - the **web login theme**, chosen per domain on the **Look** tab of each domain's Brand
    settings (the Domain services step; row 0 is the mesh's own look and the only place it
    is chosen): presets, primary and secondary colours with every other token derived at
    guaranteed WCAG-AA legibility; 7 system font stacks, or an uploaded face with its
    licence and sha256 recorded; a live token board and a real-browser preview of the
    captured login page. It applies at container start, with no rebuild;
  - **per-domain sign-in, Tor, VPN and egress** on the same tabs (Identity, Ways to reach
    it): a domain signs in through the mesh, its own Casdoor, or its own Entra / Cognito /
    OIDC provider; it can have its own onion, and records its own VPN and egress choice.
    On the Docker mesh a domain's egress is APPLIED when that domain runs the mesh's one
    Mastodon (the tuwunel service): the egress VPN carries only Mastodon's outbound
    delivery, so those domains decide whether it runs and with which provider file (two
    different files are refused at start). A per-domain VPN choice is applied by no
    route, and the image, fleet and kind lanes apply neither; the Ways tab says which;
  - the brand's **ID, title, organisation and public apex domain**: on a mesh they are set
    in the superbrand step at the top of the Branding page and nowhere else. The Network
    page shows them greyed, says where they are changed, and its **Go back to the
    superbrand step** button takes you there (a value typed on Network would be put back
    by Branding's next Next, so it is not offered). Off a mesh they are edited on Network;
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
  - an **Open web UI** shortcut to the running stack's front door;
  - a running-mesh table (*Running mesh — pods, addresses and doors*) whose **Domain**
    column says which domain each pod or container serves. The domain is read, never
    guessed: the `hugmesh.net/domain` label (written on each per-domain own Casdoor and
    its database by the Studio's overlay, and on each per-domain Casdoor pod by the
    casdoor-domains ApplicationSet), the onion key directory of a per-domain onion, or
    the Studio's own Domain services choice when only one domain chose a service. Rows
    that serve every domain say **All domains**. Under the table, pick a domain and
    press **Start**, **Stop**, **Restart** or **Logs**: they act on that domain's rows
    only (`docker start|stop|restart|logs <container>`, databases first on Start and
    last on Stop), and each button's tooltip lists the rows it will touch. On the kind
    lane, Restart replaces the pod (`kubectl delete pod`) and Start/Stop are refused
    with the reason: ArgoCD self-heal owns the replica count, so use **Halt DevOps
    lane**. Logs show inline under the table. **Tor addresses** lists every onion the
    mesh publishes (the mesh's own, then one per Tor domain), each with its own **Open
    in Tor Browser** (greyed, with the reason, when no Tor Browser launcher is on
    PATH) and **Copy**.

### Local mesh: saved meshes (on the "Saved meshes and the plan" step)

The **Saved meshes** list opens with the **current mesh**: the one being set up in
the steps before it. It names every domain and what is kept for it (sign-in, services,
look, VPN and outbound traffic, its own Tor front door), and says whether the mesh is
saved already, unchanged, or changed since (by field). **Save current mesh** writes a
new record (named from the **Save as** box, or derived when the box is empty; a name
another record has is refused, with Overwrite named as the way). **Overwrite
selected** replaces the selected record, keeping its place: the first click arms it
and says what is replaced, the second click saves. No dialogs, and nothing has to be
running: a record is the configuration, plus what was true when it was saved (which
lanes were up, the volume inventory, credential **pointers**, never a password). The
Actions-row button saves the same way; its credential-copy box is offered only while a
mesh is running. A record saved before the mesh's first bring-up restores through
**Load into the form** and **Generate && start**; its Restore refuses before any
preflight. Records live in `<Studio state dir>/meshes/<id>.json`
(`python3 -m hugmesh_studio.core.saved_meshes list|show|delete`). A record saved while
neither the Docker mesh nor the DevOps lane was up is a **draft** ("never ran"). The
node-image flow ("Create nodes for local cloud", GUI and terminal) imports the newest
record for the checkout whose mesh **ran**, with every domain's settings; a newer draft
never replaces it. Its **Import from saved mesh** list (a number in the terminal) picks
any other record of the checkout, a draft included, and the summary then says NEVER
RAN. An **Overwrite** made while nothing runs files a configuration that has not run,
but a record whose mesh ran keeps when it last did: it reads NOT RUN AS SAVED (with
that date), never NEVER RAN, and the import lists it after the records that ran and
before the true drafts. From the command line, `local_mesh_bootstrap mesh-save` saves
with nothing running too (a draft), refuses `--copy-credentials` then and a name
another record has, and `--overwrite ID` replaces a record the way Overwrite selected
does. It records the DevOps lane as unknown, never as "not running", when its `kind
get clusters` probe fails.

### Local mesh: vaults and volumes (the panel's Local mesh tab, **Vaults & volumes…**)

One window, two tabs. **Managed volumes** lists the running mesh's Docker volumes with
their size and what holds each one; deleting one needs its own name typed in, never a
pop-up. **Vault entries** reads the DevOps (kind) lane's `vault-0` through `kubectl
exec`, with the token passed on stdin, never on a command line. When it cannot read
them it says exactly why and what to do instead of showing an empty table: the lane is
not up or is halted, Vault is sealed, or its token Secret is not readable (that last one
names the context and the Secret). The fix for "the vault entries never show even with
the kind lane up" is in this branch; the reason path was exercised against the live kind
lane, but a full entry listing against a running, unsealed Vault has not been run yet.

### Local mesh: code folders (on the Repo source step)

Under the Repo source cards, a **Code folders** block lists every domain from the
Domains step and, under each, the apps that domain runs: the platform apps (one set
of images serves every domain) plus the optional services chosen for it on the
Domain services step, marked `[<slug>]`. The apps of a per-domain service the domain
did NOT choose are not listed under it (owncast, tube, the two character apps, and
the Matrix and Mastodon front ends of tuwunel/akkoma; `code_folders.service_owners`):
compose still builds them for the whole mesh, and one note under the domain names
what was left out. Each row names the git checkout compose
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

**Copies for each domain.** Under each domain's rows, the block gives that domain its
own folder of git copies (`core/domain_workspaces.py`):
`<state dir>/domain-code/<mesh>/<domain>/<app>.<domain>/`, one per app the domain has
(only `hugmesh-<name>` checkouts; the games and Tor folders and stock images get
none). **Make N copies** runs on a worker thread and `git clone`s each missing app from
the build checkout above (local, no network, the exact commit the mesh compiles), then
names the copy for its domain: branch `domain/<domain>`, `.git/description` "<app> for
the domain <domain>", and `git config hugmesh.domain` / `hugmesh.app` /
`hugmesh.mesh` / `hugmesh.remote`. Its git remote is named for the domain, not
`origin` (`git push chat.example.org domain/chat.example.org`); the remote's URL is the
build checkout it came from. A marker
file, `.git/hugmesh-workspace.json`, is written last; only a folder carrying it is ever
treated as the Studio's. Once a copy exists, its row shows and opens the copy (the
build folder is in the row's tooltip). The copies do not change what the mesh builds:
an edit reaches the mesh once it is in the build tree (push it, or pull it there), and
the block says so.

Domain names become folder names made safe (lower case, only `a-z 0-9 . -`, no `..`,
no leading dot or dash); two domains that would share a folder are refused. Nothing is
created or removed through a symbolic link, and no copy is ever made inside a
`.stack-src`. When a service is un-ticked on a domain, its copies are listed as
**extra**, and so is the folder of a domain that is not in the mesh. **Remove N extra
folders…** removes nothing on the first click: it checks each folder (off the window's
thread) and lists what it holds ("a plain copy: no edits, commits, stashes, ignored
files, hooks or settings of its own, and the build checkout has every commit", or
"holds 1 stashed change — it will be kept"); when every extra folder holds work, the
button reads "Nothing to remove: all kept". The second click
re-reads the disk and removes only the folders that the first click listed, that are
still extra and still a plain copy; **Keep them** cancels. A copy is always kept when it
has changed, untracked or ignored files (a `.env`, build output), commits on ANY of its
branches or tags that no remote has, stashed changes, another working tree made from
it, files git was told not to check for changes (skip-worktree, assume-unchanged),
commits the build checkout it came from does not have NOW (checked in that checkout,
not only against the copy's own remote refs, which go stale when the build checkout is
reset or a branch there is deleted), or its own git hooks, `.git/config` or
`.git/info` files changed since the Studio made it (a pre-commit hook, an added remote,
an `info/exclude` line; what was there is recorded in the marker when the copy is made,
and a copy made before that is judged by what a clone writes). The
untracked-file check overrides `status.showUntrackedFiles`, so a new file is seen even
when the copy's or the person's git config hides untracked files. Not seen: a commit no branch, tag or stash points to any more (only git's reflog
has it). A folder the Studio did not make is listed as "left alone" and never offered.

The copies folder is named for the mesh's own domain, and every test mesh has the same
one, so meshes share it. A copy this mesh does not need but a **saved** mesh still has
(same domain, same app) is listed as kept, with that mesh's name, and never offered
for removal; the saved mesh the form was loaded from does not count, and neither do
the EARLIER saves of that same mesh (each record lists the records it was saved after,
so saving a mesh twice does not leave the first save keeping copies the second one
dropped). An earlier save of a mesh that was saved again never counts, whatever the
form holds (after a restart, and on the text interface, which loads no saved mesh). A
newer save of the same mesh still counts. A mesh that was never saved
cannot be checked, so save a mesh before removing another one's folders. The last
outcome line ("Made 20 copies…") goes away when the domains or their services change.

On the text interface the same screen is `f` on the Local Docker mesh review
(`m N` / `m all` makes copies, `r N` lists extras, `yes` removes what `r` listed,
anything else keeps them; `src PATH` copies from your own tree).

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

# macOS (13 or newer), from the root of a checkout: the GNU tools the generator's
# scripts need, a Docker runtime (Docker Desktop, colima or OrbStack), then as on Linux
brew install bash coreutils gnu-sed findutils grep make
cd studio && python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt && ./hugmesh-studio
```

On macOS the Studio puts Homebrew's GNU tools, Docker Desktop's and colima's CLI folders
in front of its own PATH when it starts (a Mac app opened from Finder gets none of them),
builds only through Docker (no native backend), opens Terminal.app (or iTerm2) for the
commands that need a terminal, and says what is missing with the one `brew install` line.
`hugmesh-studio --self-check` reports it. The `.app` and `.dmg`, what is proven on a real
Mac and what is not yet: [docs/STUDIO-INSTALLERS.md](../docs/STUDIO-INSTALLERS.md#macos).

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

Four more **Qt-free** headless faces ride the same flag channel (#49: everything the GUI can
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

- **Device catalog** — every device in `core/device-catalog.json`, architecture, then
  family, then device, with the same words the wizard's device browser and the text UI's
  browse show: the status (EXPERIMENTAL caveat, or NOT BUILDABLE with its reason), the
  builder flags the device selects (`--platform`/`--board`), and why a refused row cannot
  be picked. Rows are labelled for one build path (`--mode`, default `standalone`): a
  device with no image on that path is listed as refused. It reads the catalog and never
  edits it:

  ```sh
  python -m hugmesh_studio --list-devices                     # the tree, as text
  python -m hugmesh_studio --list-devices --mode cloud --json # stable rows: pickable, refusal, roles
  ```

- **Local AI** — the local-assistant status of the Studio panel along the bottom of every
  Studio window (see "The Studio panel" below), as text
  (`core/local_ai_status.py`: the Ollama server and model loaded, the queue and drafts
  that `scripts/local-ai.sh` keeps, the Studio's own running builds). Loopback only; no
  hosted service, no account, no key:

  ```sh
  python -m hugmesh_studio --local-ai-status          # the one-line summary, then the work list
  python -m hugmesh_studio --local-ai-status --json   # the same snapshot, stable schema
  python -m hugmesh_studio --local-ai-prompt "what does a git worktree do?"   # one question, one answer
  ```

  Both exit non-zero with a plain sentence on stderr (what is wrong, the fix, the doc)
  when Ollama is not installed, not answering, or has no model pulled. The command that
  starts and feeds it is `scripts/local-ai.sh` (see `docs/LOCAL-AI-ASSISTANT.md`,
  section 11).

## The Studio panel (bottom of every window)

Every Studio window has one panel docked along its bottom. Collapsed it is one row: the
local-AI status, what is running ("Mesh: Bootstrapping running · 1 image build running"),
**Start local assistant**, **Current work** and **Pop out**. The chevron opens it on any
page; **Pop out** moves it into a window of its own (close that window, or press **Put
back**, to return it). Its tabs:

- **Assistant** — the prompt line and the answer area, and beside them every option the
  local assistant has:
  - **Which Ollama the assistant uses**: the system Ollama (`$OLLAMA_HOST` or
    `127.0.0.1:11434`), or **Ollama in Docker** — the Studio's own container
    `hugmesh-studio-ollama`, from `ollama/ollama:0.40.0` pinned by digest, on the
    loopback-only port `127.0.0.1:11435` (never 11434, so it can run beside a system
    one; `HUGMESH_OLLAMA_DOCKER_PORT` moves it), models kept in the named volume
    `hugmesh-studio-ollama-models`, and the GPU passed through only when Docker can
    provide one (`--gpus all` with the NVIDIA runtime or a CDI spec, the ROCm image on an
    AMD machine, otherwise CPU, said in words). The line under the choice says which
    instance is in use and where. The choice is saved, and the text UI's Local AI screen
    uses the same one (`ollama docker` / `ollama system` there). Every call the assistant
    makes takes its address from this one choice: the status read, the prompt, Start, the
    agent launcher's look at the machine and the agent it starts. Nothing starts until you
    press **Start local assistant** (Docker mode starts the container first and waits for
    it to answer; the first start downloads about 3.8 GB) or **Start Docker Ollama**.
    **Stop Docker Ollama** stops the container and keeps the models.
  - **Where your checkouts are**: the folder that holds your `hugmesh-*` checkouts
    (empty = the folder that holds this generator checkout, or `$HUGMESH_REPOS_ROOT`).
  - the **local AI agent launcher** described below.
- **Local mesh** — the local-mesh Actions box (Generate & start, Stop mesh, Check
  readiness, the DevOps lane, Add user, Save this mesh, …). The status line is copied
  just above the buttons, so a press that is refused says why right there. Off the
  local-mesh steps (the Welcome page, say) the first press of **Generate & start** only
  arms it ("Press again to start"): the settings have not been reviewed yet.
- **Running mesh** — every pod and container of both lanes, with addresses, doors and
  replicas. It keeps refreshing on any page while it is on screen.
- **Mesh run** — the stage tree and log of the local-mesh verb that is running. The panel
  opens on it when a verb starts, wherever you are.
- **Image builds** — every image build this Studio is running, and the mesh verb; the
  picked build's log is followed live beside the list (its last 400 lines), and **Show
  this build** brings its window, with the stages and packages, to the front (the tray's
  door).

These are the local-mesh page's own widgets, moved into the panel, so a verb keeps
running and streaming whatever page you are on, with the panel collapsed or popped out.
The Bring-up step now holds a note saying where they went and a **Show the panel** button;
arriving at it opens the panel on its Local mesh tab, and while it is on screen the panel
takes most of the window. A refusal from a button outside the Local mesh tab (a saved
mesh's Start on the review step, the join step's Start, a pod row's Open) opens the panel
on its Mesh run tab, where the status line is. The standalone single-page frame
(`LocalMeshDialog`), which has no panel, still shows them on its page.

## Local mesh: work on it with a local AI agent (issue #695)

In the **Assistant** tab of the Studio panel (it used to be a card on the Bring-up page of
the local-mesh path; the operator moved it out of the build phase on 2026-10-21, with every
option it had) the agent launcher **Start a local AI agent on this mesh's code** starts a
coding agent on a model that runs on this PC, in a copy of one app's repository. It does
what [docs/LOCAL-AI-ASSISTANT.md](../docs/LOCAL-AI-ASSISTANT.md) tells a person to do by hand:

- The card names, in plain words, the first thing that is missing: Ollama not installed,
  the server not answering on `127.0.0.1:11434`, no pulled model with the **tools**
  capability, the agent command (`claude`, `opencode`, `codex`) not installed, or the
  chosen app's folder not being a git repository. **Start local agent chat** stays
  disabled, with the reason as its tooltip, until nothing is missing. **Re-check** reads the
  machine again (read-only: `GET /api/tags`, `POST /api/show`, never a generation);
  **Copy command** is always available. Nothing starts without a press. No dialogs.
- **Lane** follows the lane whose verb last ran on the page (Start DevOps lane sets it to
  the kind cluster, Generate & start to the Docker mesh) and only changes what the brief
  says about rebuilding a service; a lane you pick by hand stays until the next verb. The
  **App** list follows the Repo source choice of the window's local-mesh page.
- A press makes `<state dir>/agent-work/<mesh>/<repo>` with `git clone --no-hardlinks`,
  `git remote remove origin` and `git switch -c lm/<timestamp>` from the app's folder
  (`./.stack-src/hugmesh-<name>`, or your own tree), writes the brief beside it, and opens a
  terminal (xfce4-terminal, konsole, kitty, gnome-terminal, alacritty, foot, xterm) running
  `ollama launch <agent> --model <model>` there. A copy is reused only when it has no
  uncommitted work, no remote and was cloned from the folder's current commit; otherwise a
  numbered one is made and nothing is deleted. Uncommitted edits in the real folder are not
  in the copy, and the card says so.
- **Project context.** Every start (and every Copy command) writes
  `HUGMESH-CONTEXT.md` fresh beside the brief (`core/agent_context.py`): what the hugmesh
  org and each checked-out repository are, what the Studio is and where its parts live,
  and where the sources are on this machine — the checkouts folder, the generator
  checkout, the folder the mesh builds from and each domain's code folders. The brief
  tells the agent to read it first and carries the same text inline. **Start local
  assistant** writes it too, into the local-AI state folder, and hands the queue worker
  `HUGMESH_AGENT_CONTEXT` and `HUGMESH_REPOS_ROOT`, so the worker's agents
  (`AGENT=opencode`, or an explicit agent) start with the same context.
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
  Native Windows does not open a window; run the Studio inside WSL2 or follow the doc
  by hand. macOS opens Terminal.app (iTerm2 when installed) on a self-deleting
  `.command` file that exports only the allowlisted variables.

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

### Sharing a mesh with a signed HugMesh token

A mesh admin can hand someone a single line of text, a **HugMesh token**, that lets that
person's tray run a mesh node as it says: an **access domain**, a **role** (user, mod,
admin or superadmin) and whether **shell access** is granted. Shell access means the
node accepts SSH sessions from the mesh (Tailscale SSH), as the mesh's SSH policy
allows; it does not give the holder a shell on other machines. The token carries the headscale pre-auth key and login server and is signed with the admin's
`ssh-ed25519` key through OpenSSH (`ssh-keygen -Y`). OpenSSH ships with Windows 10/11,
macOS and Linux, so nothing extra is installed.

#### Issuing a token for a mesh you created here

The admin of a mesh created with the Studio can issue tokens from the window, the text
interface or the command line, the same way on Linux, Windows and macOS. All three go
through `core/mesh_token.py`, and every field is checked before anything is created or
minted, so a typo never leaves a pre-auth key behind on the server.

- **The Studio's issuer key.** You need no SSH key of your own. The first token for a
  mesh creates an `ssh-ed25519` issuer key for it in the Studio state dir
  (`mesh-issuers/<mesh>/issuer_ed25519`, no passphrase; mode 0600 on Linux and macOS,
  and on Windows narrowed to your account if OpenSSH finds it readable by others) and
  trusts it on this computer, so your own tray accepts the tokens it signs. Every issued
  token is shown with that key's `SHA256:` **fingerprint**: send it to the recipient
  separately from the token, because their tray asks them to compare it.
- **The pre-auth key** is pasted (the window), read from a file (the text interface and
  `--authkey-file`), or **minted** in the mesh's running headscale container with
  `docker exec <container> headscale preauthkeys create --user <user> --expiration
  <token lifetime>`: a single-use key that expires with the token. Pasting a key or
  reading it from a file always works; minting needs a running headscale container,
  such as the one the Studio's local Docker mesh runs. The container is the one running
  container labelled `net.hugmesh.role=headscale` (the local Docker mesh's headscale),
  else the running container named like `headscale` (when several match, the one that
  is headscale itself, such as `hugmesh-headscale` beside `headscale-ui`). The headscale
  user defaults to the one that container's `net.hugmesh.headscale.user` label names,
  else `hugmesh` (on the local Docker mesh it is `hugmesh` either way): the membership
  user, which owns no access tag. Name another only if your mesh sets one aside for
  joining devices. The key asks for the tags the container's
  `net.hugmesh.headscale.key-tags` label names (`tag:hugmesh` on the local Docker mesh)
  when it is minted for that label's user, else none; a label naming an access tag is
  ignored. The mesh's headscale policy
  forces the access tags server-side, and a minted key may not carry one
  (`tag:superadmin`, `tag:mesh_*`, `tag:dev_*`, `tag:dom_*` are refused), because
  headscale forces a key's tags on whoever joins with it. The issuer key signs once
  before the key is minted, and a key minted for a token that then fails to sign is
  expired straight away. A minted key is read from headscale's output, never put on a
  command line or in a log; expiring an unused one passes it to the container on
  stdin, but inside the container it is an argument of `headscale preauthkeys expire`
  for a moment, so it briefly shows in the docker host's process list.

**In the window.** **Issue a HugMesh token…** is in the tray's mesh menu and in the Local
mesh Actions box (the panel's Local mesh tab). From the Local mesh page it opens with the
brand as the mesh name, the mesh's own domain as the access domain, and the page's
**Login server** when one is typed. Pick the role, shell access (admin and superadmin
only), the lifetime (up to 90 days) and the pre-auth key: a hidden paste field, cleared
once the token is issued, or **Mint from the local headscale**, offered for the
container under **Headscale container** (the running headscale container the dialog
found, one picked from several, or a name you type). **Headscale user** is optional: its
placeholder shows the default (the found container's label, else `hugmesh`), and an
empty field mints for it. **Issue** shows the token, **Copy token** and the issuer
fingerprint.

**In the text interface.** `t` on the Local Docker mesh screen (its first screen and its
review) opens the same form: `m NAME`, `d DOMAIN`, `r ROLE`, `s` (shell), `l URL`,
`e 7d`, `k PATH` (the file holding the pre-auth key, which is never typed on screen),
`i` signs, `w PATH` saves the token to a file (mode 0600 on Linux and macOS). `mint`
does not start docker from the screen: it prints the `--mesh-token issue --mint`
command line, ready to paste into a terminal. `u USER` names the headscale user
(optional: the default is below) and `c NAME` its headscale container.

**On the command line** (Qt-free):

```sh
# this Studio's issuer key for the mesh, and its fingerprint (created on first use)
python -m hugmesh_studio.core.mesh_token issuer --mesh west
# mint a single-use pre-auth key in a running headscale container, sign with the Studio
# issuer key (the headscale user defaults to the container's label, else hugmesh)
python -m hugmesh_studio.core.mesh_token issue --mesh west --domain example.org \
  --role admin --shell --login-server https://hs.example.org --mint --expires 7d
# or bring your own issuer key and pre-auth key (read from a file, never the command line)
python -m hugmesh_studio.core.mesh_token issue --key ~/.ssh/mesh_issuer \
  --mesh west --domain example.org --role admin --shell \
  --login-server https://hs.example.org --authkey-file key.txt --expires 7d
```

The Studio's own command forwards everything after `--mesh-token` to the same CLI:
`python -m hugmesh_studio --mesh-token issue …`, `hugmesh-studio --mesh-token issue …`
when installed with pip, and on Windows the MSI's console twin
`hugmesh-studio-cli.exe --mesh-token issue …` (the windowed `hugmesh-studio.exe` prints
nothing). `--mesh-token issue --help` lists every option; `--headscale-container`,
`--headscale-user` and `--tag` go with `--mint` and override the defaults above.

**On the mesh.** An issuer in the mesh's web admin UI is being added on the mesh side.
It signs the same v1 format ([`docs/HUGMESH-TOKEN.md`](../docs/HUGMESH-TOKEN.md)), so
the tray treats its tokens the same way.

#### Using a token

Send the token, and separately send the issuer fingerprint. In the
tray, **HugMesh token…** imports it. The first token from a new issuer asks you to
compare that fingerprint before it is trusted. After that, **Start mesh node** runs the
node only as the token allows:

- the token is checked again at every start (signature, trusted issuer, not expired);
- the login server must be inside the token's domain;
- only admin and superadmin can hold shell access, and the node's Tailscale SSH server is
  on (`--ssh`) only when it is granted, otherwise explicitly off;
- the `tailscale up` arguments come from the token alone, so a `TS_EXTRA_ARGS` in the
  environment cannot widen it;
- a node whose token expires, is forgotten, or whose issuer is no longer trusted is
  stopped (the tray checks every minute).

The tray's status line shows the grant (for example *admin in example.org, SSH in*).
Without a token, the tray still runs a node on `TS_AUTHKEY`.

**Role and domain are labels; the mesh decides what this node may do. The pre-auth key
only lets it join.** It cannot carry the domain or role tags: the mesh's control node
forces the access tags (`tag:dom_*`, `tag:mesh_*`, `tag:dev_*`, `tag:superadmin`) itself
when it approves the node, and its `ssh` policy decides who may open a shell where. The
policy gives those tags no owner, so a node that advertises one at join is refused it.
The token makes this tray run the node exactly as granted and refuses an edited token,
but whoever holds a token holds a real pre-auth key, so issue tokens only to people you
would give that key to.

**Resource limits** saved from the tray apply to a token-run node too. If the mesh node
is running when you save them, the tray restarts it under the new limits straight away.

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
screen and the journey-ordered mode menu; each domain's Brand settings sections on the
Domain services step (1 Identity with its own sign-in, 2 Look — the theme, row 0's being the
mesh's own — 3 Services, 4 Ways to reach it with Tor, VPN and egress); the
create-nodes-for-local-cloud abbreviated wizard (k8s
gate, identity import, laptop/node-only worklist); the whole-mesh emulation per-device status
list (ssh and web access as copy-ready command hints); and the per-domain Sign-in choice on
the domains step; and the single-image step's device browse (`d` on the image-type list:
architecture, then family, then device, every catalog row listed, refused rows with their
reason and never selectable, the same words as the GUI and `--list-devices`). Steps not
ported yet say so and keep the config's defaults. The walk ends
in a config you can save and build from the GUI, or pass to `--print-commands`.

urwid is deliberately **not** in `requirements.txt`: it must never become a hard studio
dependency, and the test suite runs without it. For the rich UI on Gentoo, where
`dev-python/urwid` is ~arch-keyworded, accept it with one line:

```sh
echo "dev-python/urwid ~amd64" >> /etc/portage/package.accept_keywords/hugmesh-studio
emerge --ask dev-python/urwid
```

(everywhere else: `pip install urwid`.)

**Local AI in the terminal UI.** The bottom row of every screen is the Local AI status
line (it reads the worker's `status.json`, never the network, so redrawing it is free).
In the urwid face press **F2**, and in either face type `local-ai`, to open the Local AI
screen over the screen you are on: a live status, the work list (queued, running and
finished drafts), and a prompt line — anything you type there that is not `start`, `r`,
`clear` or `q` is sent to the local model; `q` returns to the screen you left. Both work
on every screen, the previous-builds list included (`q` returns to the list), and on the
Local AI screen itself they re-read the state instead of opening a second screen.

### Go-Live: export a domain's repositories to a GitHub org (optional step)

Every domain row (the Domains step, both faces) has a **GitHub org** cell: an org slug,
never a token. When some domain names one, the Go-Live wizard gains a step **Export to
GitHub org** (`python -m hugmesh_studio --go-live`; `x` on the TUI's go-live plan screen)
that copies the domain's repositories — the Code-folders map's apps plus the Java build
chain and the generator — into that organisation as fresh single-commit snapshots,
renamed `hugmesh-<name> -> <brand>-<name>` (`exampleorg -> example`), with the org path
segments and repository names rewritten inside files (Java packages, Maven groupIds,
Angular scopes and label keys are deliberately left alone), and creates a
`<domain>.github.io` site repository whose workflows clone every exported repository and
run what each one's own CI runs. Plan is the default and touches nothing; Apply needs the
org name typed (GUI/TUI, letter case does not matter) or `--apply` (CLI); nothing is ever
force-pushed or deleted, and an existing repository that already holds something — on
`main` or on any other branch — is refused unless *update via branch* is chosen. The
step can be pointed at a config file (its rules are taken whole), and a **Rename map**
field (`r FILE` in the TUI, `--rename-map` in the CLI) merges extra rules — the way to drop
a file a `refused: banned marker` row names; the generator's own two test fixtures need
exactly that (`tests/fixtures/org_export/generator-rename-map.json`). Every kept file is
scanned for a banned marker as bytes (a latin-1 or binary file is not skipped), the commit is
checked to hold every file the plan counted, and a config file's values are type-checked
(exit 2 naming the key). Snapshot commits are authored as the person running the export
(their git identity) unless the config names an author. Plan reads each checkout as it
is on this machine (it never fetches or pulls) and prints `not looked at` for a target it
did not ask GitHub about; a plan is applied once.

```sh
python -m hugmesh_studio --org-export PLAN  --domain mesh.example --org exampleorg --source-dir ~/src
python -m hugmesh_studio --org-export PLAN  --config export.json --rename-map extra.json --out /tmp/export
python -m hugmesh_studio --org-export APPLY --config export.json --apply
```

The engine is `core/org_export.py` (Qt-free; every git/gh call through one injected runner,
so `tests/test_org_export.py` proves it against bare repositories and a fake `gh`). The
end-to-end scenarios are `tests/e2e/features/studio-org-export/studio-org-export.feature`,
driven by `tests/e2e/studio-org-export-driver.py` (the real wizards offscreen over the same
stand-ins; run as the Code folders ones above, with `-g "exports a domain's repositories"`). The
full flow, the rename map's format and what a person still has to set up are in
[docs/GOLIVE-ORG-EXPORT.md](../docs/GOLIVE-ORG-EXPORT.md).

## QEMU for Windows (WHPX)

Every emulation lane of the Studio (the QEMU device tests, the AVC workout, the Playwright
suite, whole-mesh emulation) is a bash script driving QEMU inside Docker, so a native
Windows Studio refuses them with the WSL2 sentence. QEMU for Windows is the one lane that
runs there with no bash, Docker or WSL2: QEMU's own Windows build, accelerated by the
Windows Hypervisor Platform (`-accel whpx`), driven from Python (`core/qemu_windows.py`).

**Install** once, then restart Windows:

```bat
winget install --id SoftwareFreedomConservancy.QEMU -e
REM in an administrator terminal:
DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All
```

The QEMU installer records its folder in the registry and does not touch `PATH`; the
Studio looks there (then in `%ProgramFiles%\qemu`, then on `PATH`) for
`qemu-system-x86_64.exe`, `qemu-img.exe` and the bundled x86 UEFI firmware. Until both are
in place every face says which one is missing and prints its command.

**What it boots.** ONE x86 device at a time, a thin desktop image or a single node, from a
build session's `.img` or `.img.xz` (an `.xz` is unpacked once into
`<work>/native-images`; `<work>` is `<generator>/out/qemu-runs` unless `--work` says
otherwise). Each start gets a fresh qcow2 overlay, so the image itself is never written.
The guest has 2 GiB of memory and 2 CPUs by default, and a start is refused when free
memory cannot hold the guest plus 768 MiB kept for Windows. Ports are forwarded on
`127.0.0.1` only: **2222** -> ssh, **8443** -> 443, **8080** -> 80. **Headless** (the
default) writes the serial console to `console.log` in the device's run folder
(`<work>/native-runs/<label>`); **window** opens the guest's screen in a QEMU window, for
a thin desktop. Stop powers the guest off over QMP (ACPI power-off, then quit, then a
kill) and deletes the overlay unless it was kept.

- **GUI:** the **Mesh emulation** page's **Emulation backend** chooser, with **Show
  desktop window** and **Memory** beside it. Each x86 row's Start, Stop and SSH then use
  this backend. A native Windows Studio opens on it when QEMU and the hypervisor platform
  are ready; everywhere else the default stays Docker, and choosing QEMU for Windows on
  Linux shows why it is not offered there. The QEMU device tests page points here from
  its WSL2 note.
- **TUI:** start the journey (`python -m hugmesh_studio.tui`), pick **Start building**,
  then the **Mesh emulation** card, and press **b** there to switch backend
  (`--meshemu SESSION` only prints the Docker plan and exits; it has no backend key).
  The screen spawns nothing: an x86 row shows what a start runs and the CLI line to
  paste into a Windows terminal.
- **CLI** (Qt-free; from the MSI use `hugmesh-studio-cli.exe`, the console twin):

```bat
hugmesh-studio --qemu-windows check
hugmesh-studio --qemu-windows rows   --session SESSION
hugmesh-studio --qemu-windows plan   --session SESSION --row x86/standalone-thin
hugmesh-studio --qemu-windows start  --session SESSION --row x86/standalone-thin --window
hugmesh-studio --qemu-windows status
hugmesh-studio --qemu-windows stop   --row x86/standalone-thin
python -m hugmesh_studio.core.qemu_windows start --img path\to\image.img.xz --mem 2048
```

`plan` prints exactly what `start` runs. Other options: `--ssh-port`, `--ui-port`,
`--http-port`, `--smp`, `--work`, `--keep` (keep the overlay after stop), `--json`, and
`--tcg` (no acceleration, very slow; only when the hypervisor platform cannot be turned
on). A refusal exits 2 and prints `REFUSED:` with its sentence.

**What stays refused, and why.** ARM and Raspberry Pi rows: WHPX accelerates only x86_64
guests on an x64 PC, and those rows boot a kernel taken out of the image. Whole-mesh start
and stop, and a second device while one runs: this backend boots one device at a time.
The QMP console, the web tunnel, and saving a device's disk or the whole mesh: those are
the Docker backend's runner. The QEMU device tests, the AVC workout and the Playwright
suite: they boot and assert through bash scripts. All of these run on Linux, or in a
Studio inside WSL2, on the Docker backend.

## Package a Windows .exe

The PyInstaller spec is committed at `packaging/hugmesh-studio.spec`; the MSI, the Flatpak,
the macOS `.app`/`.dmg` (`packaging/build-macos-app.sh`) and the local build commands are in
[docs/STUDIO-INSTALLERS.md](../docs/STUDIO-INSTALLERS.md).

## Layout

```
hugmesh_studio/
  core/        config (flag mapping) · build_driver (native/docker) · hw_scan ·
               profiles · keyzip · mesh_node · platform_info ·
               local_ai_status (Local AI snapshot + prompt)      <- headless, unit-testable
  gui/         qt shim (PySide6|PyQt6) · wizard (pages) · tray · the Studio panel (_local_ai_dock)
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
