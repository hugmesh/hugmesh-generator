# Studio — the operator's walkthrough

Every page of the HugMesh Image Studio wizard, in the order you meet them, and
what each one changes.

**Read this if** you are standing in front of the Studio for the first time and
want to know what to click. If you want the flow's *design* — why the pages are
grouped the way they are, and what parity the other front-ends owe it — read
[STUDIO-WIZARD-FLOW.md](STUDIO-WIZARD-FLOW.md) instead. If you want to install
or run the Studio, read [../studio/README.md](../studio/README.md).

## The one thing to understand first

**The Studio is not a fixed sequence of screens.** There are twenty-six pages,
and which ones you see depends on what you pick on the build menu. A run that
builds a standalone desktop skips seven pages a mesh run walks through.

Two numbers explain the whole shape:

- **Ten cards** on the build menu.
- **Three image build modes** — `standalone`, `cloud`, `mesh`. Only these three
  are ever written to the configuration, and only these three key the skip map.

The other seven cards are side-flows: they raise a transient wizard flag, run
their own page, and mostly end there without touching the image configuration
at all. That is why the menu looks like ten choices but the saved config only
ever records three modes.

The skip map lives in one place — `MODE_SKIPPED_PAGES` in
`studio/hugmesh_studio/core/config.py` — and the page order is
`WIZARD_PAGE_SLUGS` beside it. If this document and that file ever disagree,
the file is right.

## Getting in

The Studio is a Qt wizard, but it is not a fixed list of screens. Three screens decide everything that follows: a Welcome screen that routes you, an optional Prior-sessions screen, and the build menu. What you pick on the third one determines which of the remaining twenty-three pages you ever see.

The window's **About** button (Qt's Help button, renamed) shows the Studio version and which Qt binding is live, with the licence that binding ships under. It is on the wizard's button row throughout.

### Welcome — "HugMesh Image Studio"

The first screen on every fresh start. It reads a paragraph on what HugMesh is, with a link to the GitHub README's getting-started guide ([`#quick-start`](https://github.com/hugmesh/hugmesh-generator#quick-start)). The link is a real anchor: clicking it hands the URL to your desktop browser. The Studio never fetches it itself.

Below that is a paragraph about **this machine**, generated from a host probe:

- If a build backend exists, it says `Build backend: native` (Linux + Gentoo + bash) or `docker`, plus a one-line host summary — OS, WSL version, Gentoo, session type, docker, KVM, root.
- If neither exists, it says in red that this machine cannot build images yet, and names the fix. Under WSL that fix is Docker Desktop's per-distro WSL Integration checkbox (Settings → Resources → WSL Integration), not a reinstall — and on WSL1, converting the distro to WSL2 first. You can still configure and save an image here and build it elsewhere.
- Either way, if the generator directory is on a Windows drive **and** this is WSL, or on a network filesystem, a red **SLOW FILESYSTEM** warning appears. Read it. That build does not fail — it stops appearing to move, and you will read it as a hang. The Windows-drive remedy is to put the repo on the Linux filesystem (`git clone … ~/Github/hugmesh-generator`); the network-filesystem remedy is to copy it onto a local disk. The check is made on the filesystem type from `/proc/mounts`, so a symlink from `~/Github` into `/mnt/c` is caught too; only an unreadable mount table falls back to the shape of the path.

Then two cards. Pick one:

| Card | Goes to |
| --- | --- |
| **Start building** | the build menu (`mode`) |
| **Review prior sessions** | the Prior-sessions screen |

**Start building** is pre-selected, so pressing Next or Enter without touching anything takes the ordinary path. **Clicking a card both selects it and advances** — there is no confirm step. Space, Return or Enter on a focused card does the same, and the arrow keys move the selection between cards. Back works normally if you overshoot.

(A third card, **Start a local mesh**, was removed on 2026-08-26 — it duplicated the build menu's own **Local Docker mesh** card. That flow is reached through **Start building** now; see `STUDIO-WIZARD-FLOW.md`.)

One exception to all of this: a **Restart** from a prior session sets the wizard's start page to the build-progress page. You never see this screen on that path.

### Prior sessions — only if you asked for it

Reached only from Welcome's second card — nothing else routes into it. Its own Next continues to the build menu, carrying whatever you loaded, so it is a stop on the way rather than a dead end. If you have nothing to reuse, skip it.

**Load config… / Save config…** One loader handles both file shapes: a flat single-image config, and a `hugmesh-worklist/v1` envelope. You do not have to know which you have.

- Loading **restarts the wizard**. You are dropped back on the Welcome screen with every page repopulated. That is expected, not a failure.
- Saving defaults to `hugmesh-image.json`. It writes the envelope when a worklist exists, otherwise flat JSON. Only pages you actually visited are collected, so a page the flow skipped cannot leak stale values into the file.
- Plaintext secrets are blanked on save — `local-pass`, `luks-pass`, `user-password`, `root-password`. A dialog names the ones that were dropped. Re-enter them before building from that file.

**Previous builds** is a table below the buttons, with a free-text filter and a status dropdown above it. It hides itself completely when there is nothing to list, so a first run shows only the two buttons. It lists persisted build sessions newest-first, plus best-effort discovered `wl-<role>.<platform>` build directories at the top level of the output directory (status honestly `unknown`), plus any record file it could not parse. It refreshes on every visit to the screen — a build you just finished appears without restarting the Studio. Clicking a row opens that build in its own window.

Six actions:

- **Restart** — rebuild the same config into the *same* workdir; existing artifacts are reused or overwritten. The confirm dialog carries a "Resume from existing build tree (`--resume`)" checkbox, pre-checked when `wl-` build trees are already in that workdir, and lists any secrets that were not saved with the session and any secret *files* that were held in memory only. Accepting jumps straight to the build-progress page, which re-runs the full preflight before it launches and prompts for those held files. Restart refuses if the session is running in another Studio process, and offers Redo instead if its artifact directory is gone. (A fleet run restarts through the fleet window instead.)
- **Redo (edit as new)** — loads that session's config back into the wizard as a new session and returns you to Welcome to walk the pages and edit. A fresh session id and workdir are minted at build time.
- **Open artifacts** — opens the build directory in your file manager. Disabled when the directory no longer exists.
- **View errors/log** — the persisted per-image error tails, or the tail of the legacy shared `build.log` for a discovered unmanaged tree. For a stale `running` record it says the process is gone; it never upgrades that to "complete".
- **Delete** — removes the record. Deleting the artifacts on disk is a separate checkbox that defaults **off**. Refused for a session running elsewhere. (An unmanaged tree or an unreadable record file is deleted outright, on a plain confirm.)
- **Delete all finished…** — prunes finished records only; running sessions are kept. Same artifacts-are-opt-in checkbox.

Restart and Redo are disabled for anything that is not a session record — discovered `wl-*` directories and unreadable record files both predate or fail the config snapshot there is nothing to replay.

A **Fleet build…** button appears here only when `HUGMESH_STUDIO_ADVANCED` is set truthy (`1`/`true`/`yes`/`on`). It builds every role for a whole release, not the single image this wizard configures. `hugmesh_studio --fleet` reaches it without the flag.

### What do you want to build?

Ten cards. Clicking one commits the page and advances, same as Welcome. **Standalone Gentoo desktop** is pre-selected on a fresh flow; on a Back-navigation or after loading a config, the card matching the loaded mode is re-selected instead.

Only **three** of the ten are image builds. Those three are the only values the config's `mode` ever takes, and the only things that change which pages you see:

| Card | Commits | Then skips (statically) | Default role |
| --- | --- | --- | --- |
| **Mesh node** | `mode=mesh` | Target machine & image type, Target hardware | `omnibus` |
| **Mesh desktop client** | `mode=cloud` | Identity provider, the worklist, the two "do you want to configure…" choice screens for domains and users, and the secrets store | `desktop` |
| **Standalone Gentoo desktop** | `mode=standalone` | Identity provider, the worklist, the key-zip screen, both domains and users screens entirely, and the secrets store | `standalone-thick` |

So a mesh run reads Identity provider → Choose the images to build → Branding → Network → Load your admin config (key-zip or link) → Domains → *Domains & their services* → Users → *Superusers & domain users* → System identity → Secrets store → Home folder, encryption & login → Review → Build → Building. The two tables in italics are reachable only if the choice screen before each one asked for them (`additional_domains`, `configure_users`). Standalone is the shortest path: Target machine & image type → Target hardware → Branding → Network → System identity → Home folder, encryption & login → Review → Build → Building. Individual pages can still drop themselves beyond the static list when they have nothing to contribute — Branding, Domains and Users are the three that do.

Mesh replaces the role and hardware pages with the worklist, which owns role × platform for the whole set of node images. Committing mesh also runs the mesh-entry defaults every time: it zeroes the theming and home-folder fields the committed role class does not permit, forces tailnet and SSO on, and sets encrypted root from the platform-keyed posture — true wherever the builder has a full-disk-encryption path, false on Jetson, which has none.

The other seven cards commit **nothing** to `mode`. They raise a transient flag that the matching page reads, and five of them are terminal — the flow ends there, with no image:

| Card | What it is |
| --- | --- |
| **Local Docker mesh** | run a whole mesh on this machine in Docker |
| **Run e2e tests** | drive `tests/e2e` against a mesh that is already running — and the door to the QEMU device-test lanes |
| **Mesh emulation** | boot a whole prior build as persistent guests, with console, ssh and disk saves |
| **Cloud deploy** | publish an already-packaged x86 image to a cloud provider |
| **MDM phone** | flash and enroll a USB Pixel |
| **MDM Quest headset** | enroll a USB Meta Quest 3/3S |
| **Create nodes for local cloud** | turn the local Docker mesh into real node images |

Two of those seven are not terminal:

- **Run e2e tests** offers "Emulated-device test lanes (QEMU device tests)" against "Run the suite against a running mesh" on its own screen. That arm continues into the **QEMU device tests** page, which in turn offers "Build new images first, then run these tests" — and *that* arm rejoins the image flow, using whatever mode is *already* committed. On a fresh run that is standalone. If you meant to build mesh nodes and test them, pick **Mesh node** first.
- **Create nodes for local cloud** is a gate. It imports the local mesh's apex domain and provisioned accounts, then commits `mode=mesh` itself on Next and restricts the worklist to the laptop role plus every mesh role that produces a cluster node. The rest of the flow is an abbreviated mesh wizard. The local Kubernetes stack has to come down first: an inline checkbox takes your consent and *arms* a Stop button that runs `make kind-down` on a worker thread with streamed output and Cancel — nothing is torn down without a press, and Next stays disabled while a cluster is still known to be up or a teardown is in flight. The consent box is cleared afresh on every forward entry.

**The trap on this screen is coming back to it.** Committing a card rewrites state you may have already entered, with no warning:

- Entering or leaving mesh discards the worklist. Both directions.
- Committing standalone clears the key-zip path, the domains list, the users list, both "configure domains / configure users" flags, and forces tailnet and SSO off. Those pages are unreachable in standalone, so anything parked in them would otherwise be saved but invisible.
- Your role resets to the mode default only when the role you had is not valid in the new mode. A valid role survives.
- Every image-mode commit also rewrites `bundle_source`: on for standalone (except the unaffiliated role, where bundling the generator source is a hard conflict), off for cloud and mesh.

If you have configured a lot and want to try a different build type, save the config first.

## Choosing what to build

The screen behind Welcome's **Start building** card is **What do you want to build?** It offers ten cards, and clicking one is the decision — the card commits the page and moves the flow on. Only three of them commit an image mode:

| Card | Mode |
| --- | --- |
| Mesh node | `mesh` |
| Mesh desktop client | `cloud` |
| Standalone Gentoo desktop | `standalone` |

**Standalone Gentoo desktop** is preselected. The other seven cards run a tool instead of configuring a build. Six of those are terminal: Local Docker mesh, MDM phone, MDM Quest headset, Cloud deploy, Mesh emulation, and Run e2e tests on its "run the suite" arm. On a terminal page the final button reads **Exit**, not Finish — pressing it closes Studio and does nothing else. Whatever you started keeps running.

Two cards are exceptions. **Run e2e tests** continues into the QEMU device-test page on its "emulated-device test lanes" arm, and that page rejoins the image flow on its own "build new images first" arm. **Create nodes for local cloud** leads to a page that commits `mode = "mesh"` itself on Next.

Picking one of the seven tool cards raises a flag on the wizard, not a field in the config. Every page whose card you did not pick skips itself, so the flow you walk contains only the pages your choice reached.

### Local Docker mesh

Runs a dockerized HugMesh mesh on this machine. No image build, no server hardware.

Two tabs, and they are alternatives.

**Join an existing mesh with a key.** Asks for a tailnet/headscale auth key (required — Start refuses without one), an optional node name, and an optional self-hosted headscale URL. Buttons: Start, Stop, View logs…. The key is staged as `TS_AUTHKEY` into the local compose project's `.env` and nowhere else.

**Generate & start a NEW local mesh from scratch.** Mints every credential and brings up the whole platform stack seeded with a fresh superadmin. What it asks:

- **Environment** — `test` (default: LAN-only, self-signed, nothing published) or `prod`. Prod additionally requires a public apex domain and a tailnet auth key; the run is blocked until both are set.
- **Brand** — a picker over the `brands/` catalog, editable. Must be a DNS label. A brand with no `brands/<brand>.conf` is allowed and warns that profile presets stay unset.
- **Repo source** — download and update every repo into `./.stack-src` (the default), or point at a tree of `hugmesh-<name>` checkouts you already have. The second mode sets `STACK_NO_CLONE=1`, so your checkouts are never fetched, updated or `git reset`. A third option, "Render repo source from templates", is permanently disabled with its reason on the page.
- **Superadmin** — defaults to `superadmin`. Its password is generated and written only to the offline secrets bundle; the page never shows it.
- **Services** — one row per service, grouped. Three mechanisms, and the row tells you which it is. *Compose profile* rows start or stop containers, so changing one later needs a stop and a start. *Federation* rows start nothing; they flip the service's `enabled` row at seed time, which is what makes it appear in the mesh menu. *DevOps lane* rows are greyed with no checkbox — they are Kubernetes controllers this docker mesh cannot run. A service the local stack has no mechanism for at all is greyed with its reason rather than offered as a toggle that would change nothing. Boxes start at the shipped defaults, not at off.
- **Web login languages** — empty means English only, which is also the smallest image.
- **Themes** and **Identity provider** — collapsed by default. External OIDC here is validation-only config; the local stack pins its own Casdoor split, and the page says so.

A read-only plan preview refreshes live from every control. Nothing runs until you press a button.

The action bar wraps and holds more than the bring-up: Check readiness (read-only host probes — docker, buildx, disk headroom, maven prerequisites), Build maven prereqs (m2), Generate & start, Stop mesh, Stop & clean Docker…, Open web UI, Copy .onion address, Sign-in credentials, e2e features…, Vaults & volumes…, Add user…, and a separate Kubernetes lane (Install DevOps prerequisites, Start DevOps lane, its add-on checkboxes, Delete DevOps lane). Every verb runs on a worker thread; the long ones stream into a stage tree and can be cancelled. The log pane below filters to whichever stage you click.

Sensible first run: `test`, the default source mode, Check readiness, then Generate & start.

Saved meshes: once a mesh is up, **Save this mesh** records it (configuration, the env it exports, overlay text, per-repo source HEADs, doors, account names and roles, credential *pointers*, and an inventory of its data volumes — never the volumes' contents and never a password) under the Studio state dir. The **Saved meshes** table sits above the action bar; each row says, before you click, whether it would Start (volumes still present after Stop mesh: reattach, no re-mint, no re-seed) or Restore (volumes gone after Stop & clean Docker: bring up empty and re-seed — same usernames; the same passwords only if the record kept credential copies, an opt-in that is off by default). Delete removes only the record. Never restored: the tailnet auth key, passwords of users added with Add user…, exact image bits and the .onion after a clean. The same records drive `python3 -m hugmesh_studio.core.local_mesh_bootstrap mesh-save|mesh-restore`.

Traps:

- Entering the page probes the real compose project. If a mesh is already up, the mesh-state line says so — "Generate & start" would bring it up a second time over the live stack.
- "Stop mesh" runs `make stack-halt`, which the Makefile documents as the non-destructive stop that keeps identity, rooms, accounts and the BFF databases — its tooltip and log line used to claim `make stack-down` + dropped volumes and were corrected with the saved-meshes work, whose warm Start depends on the true behaviour. **Stop & clean Docker…** is the destructive one: volumes and the ~28 built images go, and the next start is a cold build measured in hours. It confirms first and lists exactly what it removes and what it does not.
- The DevOps lane is a separate Kubernetes cluster. Starting or deleting it changes nothing about the running containers.

Downstream: nothing. This page emits no image-config fields and ends the path.

### MDM phone

Reached only from the "MDM phone" card. Flashes a USB-connected Google Pixel with verified GrapheneOS and enrolls it as an MDM-managed mesh device. It is a thin front over `core/phone_wizard.py`, which shells `scripts/phone-wizard.sh` — the same driver the ncurses menu uses. Every gate lives in the driver.

Asks: device codename (from the driver's vetted catalog `scripts/phone-devices.tsv`, plus a `<detect at run>` entry, and editable), release channel (`stable` default, or beta/alpha), serial (blank means auto when exactly one device is connected), keys dir, login server, a masked auth key, and mesh role.

Nine verbs. Seven stream into the log here: Plan (dry-run), Detect, Fetch + verify, Enroll, Profile, Ingest, Status. Two hand off to a real terminal emulator: **Flash (DESTRUCTIVE)** and the **Guided wizard**. That is deliberate — the driver's typed-serial confirmation needs a TTY, and Studio never injects a bypass or pipes `/dev/null` at a confirmation gate.

The auth key is never persisted and never lands on argv; a run stages it into a `0600 --authkey-file` that the core shreds afterwards.

Sensible default: leave the codename at `<detect at run>`, keep `stable`, run Plan first.

Trap: Flash and the guided wizard appear to do nothing in the window. They open a terminal. If no terminal can be opened, the status line says so and nothing runs.

Downstream: nothing. Terminal.

### MDM Quest headset

The same driver with `--device-class quest`, so the catalog becomes `scripts/quest-devices.tsv`: `eureka` is the Quest 3, `panther` the Quest 3S. No flash and no release channel — a Quest keeps Horizon OS, and the driver refuses `fetch`, `flash`, `attest` and `profile` for this class with its reasons.

Asks the same identity block as the phone page (codename, serial, keys dir, login server, masked auth key, mesh role), plus:

- **Headwind management plane** — server URL, DPC APK path, the expected APK signing-cert SHA-256 (enrollment fails closed on a mismatch), and the Headwind *configuration* the headset self-selects into. Paths, URLs and names only; never secrets.
- **XR-chat URL** — a toggle plus an `https://` room URL. WebXR needs a secure context.
- **Thin desktop** — a toggle plus a Moonlight APK path, its signer SHA-256, and a comma-separated list of thin-client tailnet names.

Both toggles gate their own fields, and the values are emitted only while the toggle is on — the driver refuses the value knobs without the capability flag.

Seven verbs. Only the **Guided wizard** goes to a terminal; **MDM-enroll + chat URL** streams here, because the phone's interactive fresh-device gates become non-interactive advisories on a Quest.

Prerequisite: Developer Mode must be on, which needs a Meta developer account. The driver prints the runbook when the headset is not adb-visible.

Trap: `panther` is *also* the Pixel 7 codename. The device class picks the catalog, and the driver pins USB vendor 2833 and `ro.product.manufacturer=oculus`, so a phone can never be driven down this path.

Downstream: nothing. Terminal.

### Cloud deploy

Publishes an **already-built, already-packaged** x86 artifact. It does not build and it does not package: run `scripts/cloud-package.sh` first and point this page at its output (`.qcow2`, `.vhd`, `.img`).

Asks: provider (read live from `hugmesh-cloud-deploy list`; Refresh re-reads it, and an empty combo means the driver is not present), image path, domain, region, either a path to a `0600` credentials file or pasted credentials, an output directory for rendered artifacts, a keys dir, and an identity-provider passthrough — Casdoor built-in by default, or Entra / Cognito / other OIDC, which enable issuer, client id and JWKS fields and make the plan emit `idp/idp.conf`.

A read-only monospace pane previews the knobs, the exact plan command, and any blockers. It is pure: nothing runs until you pick a verb.

Four verbs:

- **Plan** renders the provider's artifacts offline. No cloud API is touched.
- **Status** reads the emitted state hints. It never calls a cloud API either.
- **Apply** streams here, but only behind the "I understand APPLY executes the plan's emitted apply.sh against a REAL cloud account" tick, and only after `validate()` passes.
- **Destroy** opens a terminal, where the driver's own confirmation runs.

A fifth button, **Open artifacts folder**, just opens the output directory.

Pasted credentials are never persisted and never reach argv; a run stages them into a `0600 --creds-file` tempfile that is shredded afterwards.

Sensible default: Plan first, read the rendered artifacts, then tick and Apply.

Trap: the acknowledgement checkbox is Studio's gate, not the driver's. The driver confirms again and fails closed without a TTY. Studio never sets its test-only assume-yes variable.

Downstream: nothing. Terminal.

### Run e2e tests

Added 2026-08-27 at the operator's request — *"remove QEMU device emulation menu item as it does not do anything that cannot be done from the other menu, but add the run e2e tests button"*. It holds the mode-menu slot the **QEMU device tests** card used to hold. That card is gone; the page behind it is not, and this screen is its door.

Two arms, chosen by radio.

**Run the suite against a running mesh** (the default, and terminal). This is `tests/e2e` — the Gherkin lane, `make stack-e2e-bdd-env` — against a mesh that is *already serving*. Nothing here starts one.

- The **e2e target** chooser is built from `core/e2e_environments.py`, never restated: `docker` (the compose stack), `kind` (the local DevOps cluster) and `qemu` (an emulated device over its forwarded UI port). The choice rides as `SNAP_ENV` on the child process — the same channel `SNAP_ENV=kind make stack-e2e-bdd-env` uses and `tests/e2e/steps/world.ts` reads — so the Studio and a terminal can never target different meshes.
- Under it the page states what that environment *is*, the exact `make` target and pins a run would use, and the command that would **start** it. That last one is text. The Studio will not spawn it: bringing a QEMU device up needs root, and an unanswerable password prompt does not fail, it hangs.
- The **readiness** line is a live, off-thread probe (`LocalStackNode.e2e_ready`) asked about *the chosen environment*. Until it answers, the door is shut and says so — nothing established reads as a blocker, never as permission. When it refuses, it names every reason. That same list rides into the feature tree, so its Run button can never be armed against a mesh that cannot host the suite.
- That gate is deliberately **scoped**. For `kind` and `qemu` it checks only this checkout (`tests/e2e` + `node_modules`) and leaves liveness to the harness, which skips each scenario with a reason naming what to start. The page says so rather than implying a full check. For `qemu` it also reports whether a `qemu-system-*` process is running — as a **note**, never a block, because it cannot see a device emulating inside the runner container.
- **Identity.** The suite's superadmin scenarios log in as the *minted* superadmin whenever the mesh was bootstrapped from Studio. This page reads that bundle through the bootstrap's own reader and says which brand answered — or that none did, which is the terminal-seeded case where the deterministic e2e defaults apply. It is never silent about which identity a run will use.
- **e2e features…** opens the feature tree (non-modal, so a run streams into the log below it): Gherkin features, spec files with their last verdicts and skip reasons, the personas each draws from, the source, and the screenshots a run produced. What you check is what runs.

The 33 handwritten spec files are a separate lane and are **not** run here: `make stack-e2e` from a terminal.

**Emulated-device test lanes (QEMU device tests).** Picking this hides everything above and leaves one line: Next continues into the QEMU device-test page, described next.

### QEMU device tests

Reached from **Run e2e tests**, and from nowhere else in the menu — its own card was removed 2026-08-27. (The post-build opt-in is unaffected: the Build screen's "run the QEMU emulated-device tests" checkbox still runs this same containerized harness when a build finishes, with no menu involved.) Keeping the page mattered because it is the only place in Studio that can spawn the Playwright-on-an-emulated-device harness and the SELinux AVC workout — neither of which Mesh emulation offers.

The **test** lane of emulation: ephemeral asserted boots. Boot a session's images, check they provisioned correctly, power them off. Two arms, chosen by radio.

**Images from a previous build session.** Pick a prior session — partial sessions are listed and badged, and the newest complete one is preselected — and run its rows now. An image build takes hours, so retesting must not mean rebuilding.

The run envelope is one box, and every knob in it is a field of the same object that authors the spawned command, so the preview cannot drift from what happens:

- Concurrent devices — default 2. Each device holds its own guest RAM, so this multiplies the next field.
- Guest RAM — default 2048 MB.
- Boot timeout — default 2400 s. A first boot under ARM emulation runs a full-filesystem SELinux relabel before sshd starts.
- Assertion timeout — default 0, meaning the entrypoint's own default and no flag emitted. This is a different clock from the boot timeout.
- Extra guest logins — additional wheel accounts created on every guest, beyond the payload's own `tester`.
- Image cache cap — default unbounded. Every `.img.xz` row is decompressed once and kept.

Buttons: **List devices** (enumerates what would run, boots nothing), **Run device tests**, **Read verdicts** (re-reads files and records; starts and stops nothing), **Cancel** (reaches the whole process group, docker children included).

Two single-row lanes sit below. The **SELinux AVC workout** (`tests/qemu/avc-workout.sh`) runs against one planned row. The **Playwright browser suite** (`tests/qemu/run-qemu-e2e.sh`) runs against one row, with forwarded UI and SSH ports and a spec/`--grep` passthrough; only rows whose platform has a launcher in that script are offered, and while List specs and Preview need nothing special, the real run needs root — Studio refuses it up front and names the containerized route rather than reaching for sudo.

Read the results table carefully. It has one row per **planned** row, including rows that produced nothing, and only **PASS** is green:

- **SUSPECT** — graded PASS with zero assertions recorded.
- **STALE** — a verdict from an earlier boot.
- **NO-RESULT** — planned, the run completed, no verdict emitted.

Two notes sit up front. Docker availability is probed off the GUI thread and gates the run buttons — they stay greyed until the probe answers. KVM is a warning, never a block: without it the runner still produces correct results, but an x86 row goes from minutes to hours (Pi/aarch64 rows are pure emulation either way), and under WSL2 that is the default state unless a `.wslconfig` stanza turns nested virtualisation on.

**Build new images first, then run these tests.** Picking this hides everything above and leaves one line: Next continues into the normal image flow with `cfg.qemu_device_tests` set. That is the same flag the Build screen shows as a checkbox, and it stays yours to untick there. Once the Build screen has been reached, its checkbox is the only writer.

Traps:

- This lane runs the whole fleet. There is no per-platform filter. To boot a single device, use Mesh emulation's per-device Start, or the AVC workout above.
- Nothing on the way here commits an image mode. "Build new images first" continues into whatever mode is already committed — **standalone** on a fresh Studio. If you want node images, go back to the Mode screen and pick Mesh node first.
- With no session holding a bootable image, the existing-images arm is disabled and build-first is preselected for you.
- Nothing this page starts is meant to outlive the run. For guests that stay up, use Mesh emulation.

### Mesh emulation

The **deploy** lane: boots every image of a chosen prior build session as persistent (`--keep-alive`) emulated devices and lets you drive the whole mesh locally.

It asks one thing first: which build session's images. Every image in it becomes one device. Partial sessions are marked; the newest complete one is preselected.

The device table is driven by the **plan**, not the registry, so rows exist before their guests do and you can see what will boot. Reality is reconciled onto those rows by a poll that keeps running while anything is still booting or asserting, so a mesh coming up repaints itself instead of looking dead for the many minutes an emulated boot takes. Columns: Device, Role, Arch, State, Verdict, Sections, SSH, Login, Actions, QEMU, Save disk. Verdicts are graded by the same rules as the test page.

Mesh-wide: Start mesh, Stop all, Refresh, Cancel. Per device: Start, Stop, an SSH button that opens a desktop terminal (with a copy-ready command as fallback), a login dropdown, the QMP console, and Save copy / Overwrite save.

**The web front door.** The keep-alive runner publishes exactly one port per device — ssh, on loopback. The web UI is reached through it. "Open web UI" opens an `ssh -N -L` tunnel from the plan's local UI port to the gateway guest's own `:443` and opens `https://127.0.0.1:<port>/`. TLS is self-signed, so the browser warns once. The page states whether it started a tunnel or reused one, shows the exact command, and offers a Close tunnel button; tunnels also come down when the mesh stops, when the gateway device stops, when you leave the page, and when Studio closes.

**Saving the whole mesh.** The first press only *previews*: per-device budget, how many KEYS pieces are present, the fleet total against free space, and a refusal with remedies when the filesystem cannot hold it. Then tick "confirm mesh save" and press again. A save is each disk's full virtual size, 9.5–20.5 GB per device, and the tick is cleared after every run — it is consent for one save, not a mode. Devices are paused for their copy and put back as they were found; the copies are crash-consistent.

Traps:

- The QMP button reads **"Reset (ends guest)"** and means it. Every launcher runs qemu with `-no-reboot`, so a QMP `system_reset` shuts the guest down and exits instead of rebooting it. It sits behind an inline confirm tick for that reason. Power off ends the guest too — the orderly way. Either way, only Start brings the row back, and that is a full emulated boot.
- The guests ship `PermitRootLogin no`, and the assertions check that it stays that way. Root is reached by logging in as a wheel user and then `sudo -i`; the login dropdown offers that as its own row.
- Exiting Studio from this page leaves the emulated devices running. The verbs on the page are what start and stop them.

Downstream: nothing reaches the image config. Terminal.

### Create nodes for local cloud

The gate between a running local Docker mesh and the node-image wizard. Unlike its siblings it is an entry, not a destination.

On every forward entry it reads the local mesh's identity **offline** — plain file reads, no docker probe — and shows exactly what will be imported: the apex domain from the bootstrap config, and the accounts the Studio itself provisioned (the minted superadmin from the runtime secrets bundle, plus the seeder's persona roster). Passwords are never read; imported user rows carry no secret. Accounts created interactively after go-live are not listed and do not need to be — they live in the mesh's identity tier and stay valid once the node images join the same domain.

Then it asks for consent, as an inline checkbox: *"I understand: k8s will stop to proceed — the local Kubernetes (DevOps) stack must come down before these node images are configured and built."* With a cluster actually up, ticking it arms **Stop Kubernetes now**, which runs `make kind-down` on a worker thread with streamed output and Cancel. That deletes the DevOps lane only — the docker mesh and every one of its volumes are untouched. With nothing running, the button stays greyed and the line under it says there is nothing to stop.

### Stopping the DevOps lane without deleting it

`make kind-down` is the **destructive** control: it deletes the kind cluster and everything in it, and the next bring-up is a full one that comes back empty. When the intent is only to stop the lane, use the halt instead:

| command | what it does |
|---|---|
| `make kind-halt` | Suspends ArgoCD auto-sync on the Applications it records, then scales the mesh workloads to 0. Writes what it changed to the `hugmesh-kind-halt` ConfigMap in the ArgoCD namespace, so the undo does not depend on the Studio still running. Auto-sync must be suspended as well as the workloads scaled — `prune + selfHeal` would otherwise scale everything straight back and the button would be a lie. |
| `make kind-halt-status` | Read-only. Says whether the lane is halted, what it suspended, and the sync/health each Application was in at the moment it froze. Refuses rather than guessing if the record cannot be read. |
| `make kind-resume` | Restores exactly the replica counts and the auto-sync the halt recorded — not "everything", so an Application suspended for some other reason stays suspended. |

**Some pods keep running after a halt, by design.** DaemonSets are never halted (`kindnet`, `kube-proxy`, `local-path-provisioner`, the internal ingress controller), and neither are the static control-plane pods owned by the node — `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`. Stopping those would not be halting the cluster, it would be deleting it. A halted lane therefore shows a handful of Running pods and no mesh workloads.

Next stays disabled until three things hold: the box is ticked, no teardown is in flight, and no cluster is still known to be up. After a teardown the page re-probes rather than trusting the exit status, because `kind delete cluster` exits 0 for a cluster that was never there and a failed or cancelled run can leave one half gone. The consent box is cleared again on every entry.

On Next the page commits the mesh chain itself: `cfg.mode = "mesh"`, the mesh default role if the current one does not belong, source bundling off, mesh defaults applied. It then installs the abbreviation — the worklist offers only `laptop` plus every node-class mesh role (`pki`, `backend`, `frontend`, `backend-gpu`, `omnibus`, `edge-ai`). The person-desktop variants are withdrawn, because a local cloud's devices are its nodes plus your laptop. Any other Mode choice made later lifts the restriction.

The import is one-shot per entry, so edits you make later — the cluster domain on the Network step, say — are not clobbered when the Build screen re-collects every visited page. Imported superadmins land on the Tailscale root domain and everyone else on the imported apex, and the Users table is made reachable so you can see and edit them. Every Casdoor grant the table knows (`ROLE_SUPERADMIN`, `ROLE_ADMIN`, `ROLE_MOD`, `ROLE_USER`, `ROLE_GAMES`, `ROLE_GAMES_SERVICES`) is carried into the row's roles; a persona with none of them imports as `user`.

Trap: this is the only card that both takes something down and changes the mode. If you Back out before pressing Next, nothing is committed to the config — but the cluster you stopped is still stopped.

### Identity provider

Not a side-flow. This is a regular flow page, and it is **mesh-only**: the standalone and desktop-client flows skip it outright, so their configuration and emitted arguments are identical to a build made before the page existed. In a mesh run it comes early — the first configuration screen after the mode and side-flow screens. Mesh mode skips the single-image role step, so the worklist is what follows it.

Four cards: **Casdoor (built-in) — default**, Azure Entra ID, AWS Cognito, Other OIDC provider.

Clicking Casdoor simply proceeds. It commits `idp="casdoor"` and clears the three external fields, so typing values and then changing your mind back leaves no residue.

Clicking an external provider opens a separate configuration window: a "before you start" page listing the console work you perform yourself at that vendor, an endpoints page (issuer URL, client id, optional JWKS override), and a review page. That window makes no network calls and holds no cloud credentials. It records the values; it does not create your Entra app registration or your Cognito user pool.

Back on the page you get a read-only echo of what the window produced, a "Configure provider…" button to reopen it, and a preview of the JWKS URL that will be derived if you left the override empty (Entra: `<issuer>/discovery/v2.0/keys`; Cognito: `<issuer>/.well-known/jwks.json`; other: `<issuer>/.well-known/jwks`).

Next is gated on the same fail-closed rule the build enforces: an `https://` issuer that byte-matches the `iss` claim your provider actually mints, and a client id. Client *secrets* are never entered here, never baked, and never on any argv.

Downstream, external mode bakes `/etc/hugmesh/idp.conf`, rewrites the baked cluster tree's issuer and JWKS pins to your provider, and gates the built-in Casdoor apps out of the image. Services then validate tokens your IdP minted.

Read the page's honesty note before choosing one. External mode re-points token **validation** and nothing more. The native first-party `/bff/login` page, MFA step-up stamping, the roles/permissions/groups token model behind the headscale, Harbor and desktop-sudo gates, the signup gate and the role-sync jobs all remain Casdoor-only until the service repos grow per-provider support. Entra additionally mints pairwise per-app `sub` values and per-resource audiences. Cognito carries groups in the `cognito:groups` claim, which the platform's role gates do not read.

Sensible default: Casdoor, unless you already run an identity provider this mesh must trust.

## Shaping the mesh

These eight screens are where you say what gets built and what it runs. Which of them you see is decided by the card you picked on the mode screen. Ten cards are offered there, but only three commit an image mode — **Standalone Gentoo desktop** (`standalone`), **Mesh desktop client** (`cloud`) and **Mesh node** (`mesh`) — and that mode is what the page flow keys on. **Create nodes for local cloud** commits nothing at the mode screen; its own gate page commits `mesh` and then restricts the image list to the laptop and cluster-node roles, so it walks an abbreviated version of the mesh flow described below.

Every claim here is read off the wizard in `studio/hugmesh_studio/gui/`.

### Target machine & image type — standalone and cloud

Skipped in mesh. Mesh picks role and platform on the worklist screen instead.

You pick three things, top to bottom. First the **architecture** (x86-64, ARM64, ARMv7, RISC-V 64). Then a **device** from a searchable tree grouped by vendor family — 51 devices across 11 families today, with a Status column. Then the **image type**, a list containing only the roles that device really supports in the mode you are in.

The catalogue is honest rather than tidy. Unsupported devices are listed with the reason they cannot be built and are not selectable; 27 of the 51 are in that state, including everything under ARMv7 and RISC-V. A device that is buildable but has no image type in *this* mode is also unselectable, with an inline note saying which path does offer it. Search matches the device name, its SoC, and its family or vendor.

Underneath, only the knobs the chosen platform actually has appear: board, flavor and desktop for La Frite; board plus kernel flavor for Jetson; board for the Raspberry Pi family; board and flavor for Orange Pi 5; flavor alone for each of the other Orange Pi boards (Zero 2, Zero 2W, Zero 3, 3 LTS, 4 LTS). Every La Frite and Orange Pi box also carries U-Boot URL, defconfig and skip rows — flashability-critical on La Frite and Orange Pi 5, optional convenience on the rest; the Raspberry Pi and Jetson boxes carry none. On x86 you also get **Client desktop options** (desktop weight, Steam delivery, the Sunshine stream host, `--capable`, `--unaffiliated`) and the **Machine profile** preset. A separate **Image posture** box carries `--standalone`, and it appears only where that flag is in scope for the role and platform you have selected.

Sensible defaults: leave the machine profile at "(none / generic)", desktop weight and Steam at "(default)", and the U-Boot rows empty. Standalone opens on `standalone-thick`, cloud on `desktop`.

Downstream, this screen commits role, platform, board, flavor, desktop weight and the composable flags. The machine profile is different: it emits no flag of its own, it pre-fills the GPU driver and the Wi-Fi/Bluetooth fields that the next screen finalises. The profile list also carries an entry called "This machine — run the hardware scanner", which runs the scan right here and seeds those same fields.

Traps worth knowing:

- Once you select a device, the board combo below becomes a read-only display of that device's board. To change the board, pick a different device row.
- Arrow-keying through the tree can land on a bold family header. That is not a device, so the image-type list empties and Next greys out. Click a device row.
- Choosing the unaffiliated role, or ticking the composable Unaffiliated box, blanks every branding field and turns off source bundling the moment you press Next — and removes the Branding screen from the rest of the flow.
- The Jetson `l4t` kernel flavor is accepted by the plan and the matrix, but the l4t kernel build is a stub that hard-errors. Do not select it for a real build.
- Sunshine is a three-state box and arrives in the middle state, which means "leave the builder default". Checked bakes it, unchecked emits the explicit off.

### Choose the images to build — mesh only

Skipped in standalone and cloud, which synthesise a single-entry worklist at build time.

This is the multi-image screen. A checkable tree of role x platform rows, grouped under the same device families, with an architecture filter and a search box above it. Each checked row becomes one image with the stable id `<role>.<platform>`. Per row you get Board, Flavor/Desktop, Encryption, Services and an auto-filled Notes column.

The button labelled **Select the required trio (pki + be + fe)** is the fast path. It checks those three rows on every architecture the filter admits, so with the filter on "All architectures" you get the trio on x86 and on arm64. It is additive and never unchecks a GPU or edge row you already picked. GPU and edge-AI nodes are deferrable — build them here or later from a saved config.

Encryption is per node. "default" inherits the choice made on the Home step; on/off force it for that row. Jetson rows show a disabled "off" because that builder cannot encrypt. The Services column is the one genuinely per-node service knob in the wizard: a Tor onion on x86; Tor, an egress VPN, or both on rpi5; and no combo at all on platforms whose builder can express neither.

A fresh mesh flow arrives with one row already checked — the mode default, `omnibus` on x86. Add to it; do not assume it is a placeholder.

Checking a desktop-class row asks who uses it. The dialog opens when you tick the row with the mouse — a programmatic check, such as a loaded worklist re-seeding the tree, never opens it. The named people appear in a **Desktop users** table below the tree, and double-clicking a row there edits one. Cancelling the dialog unchecks the row. Next stays disabled until every checked desktop has a named user, and the placeholder row shows in red until it does. That account is created on the internal Tailscale root domain, and the person's role rides the image. The dialog asks for the person's tier (`user`, `mod`, `admin`, `superadmin`) and any grants (`games`, `games-services`). The tier is what `--person-role` bakes into the image; the grants ride only the manifest account, which holds the tier plus every ticked grant, and the **Desktop users** table lists the full set.

Two things the survey of this page usually misses. There is a checkbox reading "Also list the 37 devices that cannot be mesh nodes" — off by default, and it brings back read-only rows explaining exactly why each device has nothing to build here. And the combos in this tree ignore the scroll wheel on purpose: a plain combo would silently change a board or an encryption setting under the cursor while you scrolled the table, which is how one node once shipped with the wrong board.

Downstream, the worklist stamps the base config's role from the first checked row and pins its platform to x86 as the option superset, so later screens show the widest field set. Unchecking a row also removes its id from every domain's "Applies to" list.

### Target hardware — standalone and cloud

Skipped in mesh, where per-image hardware comes from the worklist row.

Tuning, not machine selection. **Scan THIS machine** autofills from the machine running Studio — not from the target — and fills in the GPU driver and the radio boxes. Then: the GPU driver combo carrying the builder's full matrix (`auto` by default), a CUDA toolkit checkbox, Enable Wi-Fi and Enable Bluetooth (both off by default, deliberately hardened), "compile most everything into the kernel", and an advanced ARM overrides group holding CPU, defconfig, DTB, DTB prefix, kernel image and PCIe Gen3.

The ARM group is hidden entirely on x86. The GPU driver, CUDA and kernel-builtin controls are x86-only flags and grey out on ARM. Anything greyed is reset to its default when you press Next, so a value set while another platform was selected does not linger.

The CUDA box greys out and clears under a GPU driver that contradicts it, because the builder hard-errors on that pair. Leave the driver at `auto` if you want CUDA implied.

### Branding

Shown in every mode. Dropped entirely when the role is `standalone-unaffiliated` or the composable unaffiliated flag is set — every field here is a builder hard conflict for that image, so the screen is removed rather than shown greyed.

Two surfaces with opposite scopes.

**Desktop theme** is baked into the image. It is a top-level either/or between two cards: a premade theme, or custom branding. The premade set is closed and is exactly four — light, dark, purple, grey — each shown as a card with a preview swatch painted from the same numbers that generated the wallpaper; a fifth card, "No premade theme", is the default and ships the stock look. Nothing is appended to that list. Custom branding is eight fields: branding directory, wallpaper, GRUB background, GRUB theme directory, login background, brand logo, colour scheme file, accent colour. The brand lock sits outside the either/or and applies to whichever channel you chose.

The either/or is enforced by clearing. Switching to Custom clears your theme selection; switching back to Premade clears all eight paths. Decide which channel you want before you start typing. A saved config that carries both keeps the custom assets and clears the theme, with a note saying so. A saved config naming a theme this generator does not ship is cleared, also with a note, because that name would hard-error the builder.

The desktop half greys off-x86 and on node-class images, with the reason shown. In mesh it is hidden outright when the worklist has no desktop entry, since there would be nothing to theme. In any of those cases the branding fields are blanked on Next.

**Themes (the web pages this mesh serves)** is the second half, and it is never touched by the desktop gating. Pick a primary and a secondary colour, or a preset, plus a dark or light neutral ramp; everything else is derived. No colour is rejected — text tokens are auto-adjusted to WCAG AA, and a live board shows the measured contrast. You can set a font preset or upload a font, in which case licence and source become required. A browser preview writes one self-contained page: the login pane is the real captured page, the chat, feed and forum panes are labelled mockups. A separate modeless editor covers header and footer chrome and the page background effect. These settings apply at container start and need no image rebuild; empty means the shipped brand. This group is collapsed by default and expanded in mesh, where it is the reason the screen is shown at all.

### Domain, Mesh, and Services — every mode

This screen is never skipped. Only its contents are mode-gated. In standalone it is titled "Network Identity, Egress, and Security"; in cloud and mesh, "Domain, Mesh, and Services". Sections are collapsible, and the Security Stack section folds itself away when everything in it is at its default. Every field carries a tooltip saying what it is and which builder flag it becomes; the tooltip is hung on the row, so hovering the caption works as well as hovering the field, and a greyed or hidden control shows the reason it is unavailable instead.

**Identity & Domain** carries the brand profile file, brand id, brand title, org, the public apex domain, the games domain and the release state. Blank fields are not left blank: on Next the brand id commits `hugmesh`, the brand title `HugMesh Systems`, the org `hugmesh` and the public apex `hugmesh.net`. Release state at "default" emits nothing — which is not the same as "internal": with no `--release-state` on the argv the value falls to whatever `RELEASE_STATE` a `-C` brand profile sets, and only then to the builders' own default of `internal`.

**Tailnet + SSO** is editable only for a cloud desktop client, where both boxes arrive checked. Standalone and mesh hide it and show a grey line saying why — mesh forces both on elsewhere, off-screen.

**Headscale / Mesh Networking** shows for cloud and mesh: the Headscale URL (delivered as an environment variable, not a flag), agent version pins, the headscale-only posture, and the **Tailscale root domain** (`--superdomain`; called the orchestration superdomain before this section was renamed). It is editable in mesh and read-only in cloud, where it displays the derived `<brand>.internal`. It is baked twice — as headscale's MagicDNS `base_domain` and to `/etc/hugmesh/superdomain`, the domain superadmin accounts are created on — is permanently internal, and is never the public apex above it.

**Egress VPN** is a profile file plus a lock for managed nodes. The whole section is hidden on node-class images, because a node would otherwise pay for VPN packages and a kernel fragment it can never use.

**Security Stack** holds the proxy stack (auto by default), Snort — on by default — AIDE, and root SSH login, which defaults to `no`. The section folds away when all four are at their defaults.

**Services & Apps** is one table. Rows are services, columns are the options: On, Hosting/Mode, Setting, and a plain sentence saying what enabling that row does. Groups are Social & Community (akkoma, tuwunel, phpbb), Media & Play (owncast, tube, games), Characters & Avatars (character-studio, character-forge, edge-ai-tts), Network & Access (egress-vpn, workloadConsole), Privacy Services (tor, anubis, media-poisoner), plus AI & Inference and Backing Services. The privacy group is not called "anti-scraping" because anubis is not decided here alone: ticking its row installs it on any build, but leaving it alone still turns its proof-of-work gate on for every `prod` build, and the builder refuses `--exclude-services` for it by name. Which rows appear depends on what the selected platform's builder can actually parse; a row it cannot express is hidden, not greyed. The infra rows `egress-vpn`, `workloadConsole` and `anubis` only appear on rpi5, the one platform whose `--optional-services` catalogue carries them. Tor's x86 row appears only on a cloud or mesh build. AI & inference and Backing services appear only for cloud and mesh. Backing-service rows offer self-hosted, which is the default, or a managed hosted endpoint; tier-3 services are listed read-only with the reason they are refused in v1.

Traps here are worth reading twice:

- **Ticking replaces, it does not add.** `--optional-services` overrides the built-in set outright. The builders' own defaults (akkoma, tuwunel, phpbb) therefore arrive ticked, and unticking one genuinely removes it.
- Because of that, unticking every offered row is a real answer and commits an explicit "none", not silence.
- The Selection dropdown above the table holds two whole-set shortcuts beside the default "pick individually". "Every user-level service" is not the same as ticking every row — it expands a fixed set that excludes the infra services, and every row it decides is set to the state it produces and then locked (user-level rows ticked, an infra slug row unticked) so you can see what it builds.
- **Services are mesh-wide.** They are baked into the cluster GitOps tree every node shares. The only per-node service choice is the Services column on the worklist screen.
- On a client or desktop role the builders accept these selections and then ignore them, because a desktop bakes no cluster tree. The page says so in an orange note rather than greying the controls.
- On an unaffiliated image the whole services table is hidden instead, and its values are cleared so hiding it changes no build.
- The media cloak (`media-poisoner`) is listed in the service groups but is reachable through no builder flag or slug, so its row never appears on this screen. It exists only on the local Docker mesh surface.

There is no "exclude services" field any more; ticking what you want is the subtraction. The flag itself still exists for brand profiles.

### Load your admin config (key-zip or link) — cloud and mesh

Skipped in standalone, which has no admin plane. Always shown in the other two.

Two equivalent ways in. Browse to the key-zip your admin generated and press **Import & apply**, or paste their remote-config link and press **Fetch from link…**. Both go through the same extract-and-apply path, so a fetched link behaves identically to a browsed file. On the cloud path this is what lets the desktop join an existing mesh; on the mesh path it carries the fleet Secure-Boot signing key.

A third control, off by default, remembers loginable roles from the key-zip for passwordless login. Understand what it does before ticking it: it writes real login credentials to `~/.config/hugmesh-studio/local-login/roles.json` at mode 0600. It never writes database passwords or other machine secrets.

Traps: the import happens when you press the button, not when you press Next. Nothing on this screen is required — Next is always enabled, so it is easy to walk past without importing anything. Only `http`, `https` and `file` links are followed, anything else is refused before a connection is attempted, and nothing is contacted until you click Fetch. A fetch runs off the GUI thread and gives up after 60 seconds of silence from the server, so a wedged link cannot freeze the window.

### Domains — mesh only

Skipped in standalone and cloud. A cloud client's single domain is the tie its image is built around, not an "additional" domain, so that flow keeps its table unconditionally and never sees this screen.

Two cards. **Just this mesh's own domain** is the default and names the real values in its description — the cluster domain you set on the network screen, and the Tailscale root domain every node joins. **Add more domains** opens the table.

One trap, and it is destructive. Choosing the default card clears the domains list. Rows you typed before changing your mind are dropped, not hidden, because a skipped table must leave nothing behind for the mesh manifest to publish.

### Domains & their services

Skipped in standalone. In mesh it appears only if you chose "Add more domains" on the previous screen. In cloud it appears unless the role is one of the x86 cluster-node roles (`pki`, `backend`, `frontend`, `backend-gpu`, `omnibus`, `edge-ai`) — which the cloud picker does not offer, so in practice it always appears there unless a loaded config carries one.

Each row is a domain: **Domain**, **Title**, **Optional services**, **Applies to** and **Sign-in**. The last two are mesh-only and hidden in cloud.

"Title" is the domain's display name, and the column header says where it is actually read: it is written to the mesh manifest as `domains[].title` for cluster provisioning to pick up when it sets up the domain. It is not emitted anywhere on a cloud build. Leave it empty and the domain name itself is used.

"Optional services" is a checkable menu, not a text box — it used to be freeform, which meant a typo went into the mesh manifest verbatim with nothing to catch it. The menu offers the eight user-level cluster services (the same set `--all-services` expands to), grouped, each with a one-line description on hover. The infrastructure slugs (`tor`, `egress-vpn`, `workloadConsole`, `anubis`) are deliberately absent: they are node- or cluster-plane scoped, so a per-domain checkbox for them would claim something the builders do not do. If a config you load carries a slug the menu does not offer, it is added to the menu pre-checked and labelled as carried over, so loading an older worklist never silently drops it. Empty means the cluster-wide set applies, and the button says so — it reads "Cluster default" rather than "None", which is the spelling of the opposite setting (an explicit empty allow-list). The slugs you tick are read back in catalogue order, not in the order the menu happens to group them, so re-grouping the menu can never change what the manifest says.

One thing this column does **not** do: it does not change which services the image bakes. Those slugs are provisioning input carried in the mesh manifest for a cluster to read later; the services baked into an image come from the services step.

"Applies to" is a checkable menu of your worklist image ids. Leaving it empty means every eligible image. Node-role images take no `--domains` at all — the attachment is manifest and provisioning data only, and the menu labels them as such rather than implying a flag it cannot emit. "Sign-in" chooses between the superdomain's central Casdoor, which is the default, and a dedicated Casdoor instance provisioned for that domain alone.

A read-only header names the Tailscale root domain. It is never a table row and is never attachable.

Traps: in mesh the table arrives empty — the prefill of row 0 with the cluster domain happens only in cloud — so press **Add domain**. Row order is load-bearing: the first attached domain is the primary one. And each domain you add automatically gets its own default admin account with a generated random password, which is surfaced at provisioning time. You never type or store it here.

Verified against the source. Here is the corrected section.

## Building and finishing

These are the last seven screens. The first two are about accounts, the next two about what gets baked into each image, and the last three are the review, the launch gate, and the build itself.

### Users — generated accounts, or your own

Mesh only. Standalone and the mesh desktop client never see this screen.

Two cards. The default, **Use the accounts generated with the node keys**, is rewritten from your current worklist every time you arrive, so it names the actual rows you checked. It tells you that one login — `admin` — is created on the control-plane node (the `pki` key profile, which `omnibus` and jetson `full` also map onto), that its password is random, stored salted and hashed, and never printed, and that root stays locked in that key set. Every other node gets keys only, no accounts. If you have not checked a control-plane row at all, the card says so, and that no account would be created. What you actually log in with is the private key written beside the hashes: `ssh -i ssh/admin_ed25519 admin@<node>`.

The card also names the folder: `<output directory>/sessions/<session id>/keys-<entry id>/`. The session id is minted when the build starts, and it appears in the `-w` path of the command on the Review screen. This only happens if **Generate node key-zips** is left on at Review, which is the default.

The second card, **Name superusers and domain users myself**, opens the users table.

Trap: choosing the generated accounts clears any rows you already typed into that table. The choice is the emission guard, so a table filled in and then abandoned cannot reach the mesh manifest.

### Superusers & domain users

The table. Each row is a Username, a Domain, a set of Roles, an Email, and a Registration method.

Domain is a dropdown of the Tailscale root domain plus every name from the Domains table. Ticking `superadmin` forces the row to the Tailscale root domain and disables the dropdown — superadmins belong to the Tailscale root domain, not a tenant one; that holds whatever else is ticked beside it. Roles is a row of checkboxes: `superadmin`, `admin`, `mod`, `user`, `games`, `games-services`, and an account may hold several at once (an `admin` who is also a `games` member, say). The highest tier ticked is the account's primary role — that is the `role` the manifest and the `--person-role` derivation read — and `games` / `games-services` are grants on top of it. A row with nothing ticked is saved as `user`. Registration offers `derive`, `discord`, `gmail`, `password`: the OAuth options let the user self-register with that account at first login, `password` means one is generated and handed over at provisioning, and `derive` keeps the provisioning default.

A loaded row whose domain is not defined on the Domains page is kept and flagged `(not defined)` with an orange warning. It is never silently rewritten. Rows with a blank username are dropped when you leave.

When you see it: never in standalone. In mesh, only if you chose the second card on the previous screen — that is a separate question from the domains opt-in, and either answer combines with either. In the mesh desktop client the gate is whether the image's role is one of the x86 cluster-node roles (`pki`, `backend`, `frontend`, `backend-gpu`, `omnibus`, `edge-ai`), and that flow offers none of them, so in practice the table always appears there.

Downstream, these rows are provisioning data for the mesh manifest and the identity provider. In the manifest every row carries `role` (the primary) and, only when it holds more than one, `roles` (the full set) — a single-role row is byte-identical to before multi-role existed. One thing can reach the build, and only on the mesh desktop client: with the account tier left on `derive`, `--person-role` falls back to the first row's highest tier (`user` for a row holding only games grants — the builder accepts exactly the four tiers). A mesh build does not take it from here — there the flag comes from the person named on the worklist's own desktop row.

The terminal Studio shows the same rows, with every role listed, but does not edit them yet.

### System identity

Always shown, in every mode. Three blocks.

**Host identity** — hostname, timezone, default user. All three arrive filled in with exactly what the build would produce if you left them blank; timezone is a dropdown over this machine's own zoneinfo database, not a text box.

Trap: on a mesh worklist whose rows derive *different* hostnames or *different* default accounts, the field is deliberately left blank and an amber note lists what each node will get. Typing a value there gives every node in the worklist the same one, overriding each board's own default.

**Who this image is for** — the account tier, `--person-role`. Each option's consequence is printed under the picker. The tier is stamped into `/etc/hugmesh/identity-role` and into the artifact filename so you can tell whose device an image is; nothing in the shipped first-boot provisioning reads that marker yet. One tier does change the build: `superadmin` makes the device demand a separate device password at first boot, taken from a salted and hashed value on the KEYS USB.

The whole group is hidden wherever the builder would discard the flag — standalone always, unaffiliated images, and cluster-node roles — and the picker itself greys out on the ARM platforms, whose builders take no such flag. In mesh the role tested is the *first checked worklist row*, so a worklist led by a node row hides the picker even if a laptop row follows it.

**Node fallback login** — off by default, and the two password fields do not exist on screen until you tick it. Un-ticking wipes them, and nothing is collected unless the box is ticked. The group only appears when some image in this flow is a node-class role on x86; a desktop image logs in with the account from the next step. These passwords are hashed at build time and never written to a saved config, so a reloaded config always comes back un-opted-in.

### Secrets store — mesh only

Where this mesh's nodes fetch their cluster secrets from at first boot, and the base CA certificates its domains chain to. Two groups. The first is HashiCorp Vault: an **internal** address (the one a node reaches Vault at from inside the mesh — this is the field that was always here, same config key and same flag), and an optional **external** address for the same Vault as reached from outside it. The internal address is the whole decision — empty emits no flag, so a config that never saw this page and one that left it blank build the same bytes. What an absent flag means is then the builder's own rule, the same as for every other knob (built-in < env < brand.conf < CLI): a brand profile's `VAULT_ADDR` still applies, and with none set nothing is baked and secrets come off the KEYS stick's `vault/secrets.json` bundle. The external address only means something once an internal one is set; typing it alone is refused inline, and clearing the internal address clears it with it. It must also be `https://` and must differ from the internal one: one Vault reached at one address needs no split, and two identical entries are a copy/paste rather than a decision.

**There is no KV-mount or base-path field, and there are no such flags** (issue #285; decision 22 on #347, operator 2026-09-16 *"A: drop both controls"*). The page carried both until 2026-09-16: they were validated, threaded as `--vault-kv-mount` / `--vault-base-path`, baked into `vault.conf` and logged at first boot — and read by nothing. Where the cluster reads is not a choice, and **neither half is brand-derived**. The mount is pinned in the shipped `manifests/external-secrets/secretstore.yaml` (`path: "secret"` at the in-cluster `vault.vault.svc` server), which `apps/04-external-secrets-config.yaml` serves with `automated {prune: true, selfHeal: true}` — ArgoCD re-applies it from git on every reconcile, so no image-side value and no `kubectl patch` could ever re-point it. The key prefix the ExternalSecrets read is the **literal** `hugmesh/<service>`: all 143 `remoteRef` keys under `specs/cluster` spell it out and none templates the brand (measured 2026-09-16 — `grep -rhao 'key: *[A-Za-z0-9_.-]*/' specs/cluster --include='*.yaml' | sort | uniq -c` returns `143 key: hugmesh/`). Both builders still write the two values into `vault.conf`, now derived from `--brand`, so the first-boot log names the paths the image was built for — the base path is set to the brand slug because that is the **writer** side (`BASE="${BRAND:-hugmesh}"` in `scripts/gen-cluster-secrets.sh`). For a brand other than `hugmesh` the writer and the reader therefore **disagree** today: the generator writes `secret/<brand>/…` and ESO still reads `secret/hugmesh/…`. That gap pre-dates #285 — which only removed two controls that changed nothing — and closing it is its own call. A build script that still passes either flag now stops at `Unknown option`, which is the intended loud failure. A saved config that still carries `vault_kv_mount` / `vault_base_path` loads with the keys dropped and emits the same argv as one that never had them.

What a set address does: the x86 and rpi5 node builders take `--vault-addr [--vault-external-addr]` and bake `/etc/hugmesh/vault.conf` (0644, connection facts only) into every cluster-node image in the flow. At first boot `keys-provision` reads that file whenever the KEYS stick's `provision.json` carries no `.vault` block and seeds the External Secrets Operator's `vault-token` / `vault-ca` Secrets from the token on the stick — the same seeding a hand-written `.vault` block always drove, which still wins when present. Desktop rows in a mesh worklist ignore the flag and say so in the build log; an `--unaffiliated` x86 build has no `/etc/hugmesh` tree at all and says that too.

How far each field reaches, because they used to be described as doing more than they do. The **address** is live: setting it is what makes first-boot seeding create the `vault-token` / `vault-ca` Secrets at all. The **external address** is a real flag on both node builders and is appended to `vault.conf` as `VAULT_EXTERNAL_ADDR`, so it genuinely lands in the image — and it has no reader at all: `keys-provision` seeds from the internal address, and a node boots identically with and without it. It is baked for operators and out-of-cluster tooling. Leaving it empty writes no such line, so a config that never named one produces the same file it produced before the field existed. It needs the internal address: a builder handed `--vault-external-addr` with no `--vault-addr` refuses the run rather than accepting the flag and writing nothing. The tooltips and the page's limits note say all of this.

**Base CA certificates** are the second group, and the honest weakest part of the page. Add the PEM files of the certificate authorities this mesh's domains chain to; each one is checked as you add it and refused with the reason printed under the list rather than added silently — a private key, a DER file and a plain text file are each named for what they are. How deep that check goes depends on the machine: the `-----BEGIN CERTIFICATE-----` framing and a decodable body are always verified, and where the optional `python-cryptography` package is installed (it is not in `studio/requirements.txt`) the certificate is parsed for real, so PEM framing wrapped around something that is not an X.509 certificate is refused too. That same package is what reads the subject and expiry shown beside the file name; without it the row says so instead of guessing. The list is **recorded only**: no builder script parses a CA flag, so nothing here copies a PEM into an image, into a node's trust store or onto a KEYS stick, and no manifest carries it. What the list is FOR is the per-domain **Base CA** column on the Domains step, which records which authority each domain is meant to chain to (`domain_ca` in the saved config). Removing a certificate here clears it from every domain that had picked it, so no domain can name a CA the config no longer carries. A recorded path that is not readable when you come back to the page — the file moved, or its volume is not mounted — is **kept and marked**, never dropped: opening a page must not be able to destroy a recorded list, and because nothing here reaches an image, an unreadable CA path blocks no build. Remove the row yourself if you mean to. Note the step order: Domains runs BEFORE this page, so on a first pass through the wizard the column offers only "None" and says where to add certificates; come back to Domains after this step and the picker offers them.

What it never does: take a token. The Vault token and unseal key are custody material and ride the KEYS stick (`vault/token`, `vault/unseal-key` — see `keys-template/vault/README.md`); they are not a wizard field, not a flag and not a byte of any image. The address must be `https://`; anything else greys Next with the reason printed under the fields. The group greys out when no image in the flow can take the flag (a worklist of only jetson or Orange Pi rows), naming the row that cannot.

The TUI has the same step (`a URL` internal, `x URL` external, `m NAME`, `p PATH`, `c PATH` to add a base CA certificate, `r NUMBER` to remove one, Enter to continue) and refuses the same inputs with the same sentence. Its Domains step takes `b DOMAIN-NUMBER CERT-NUMBER` for the per-domain choice.

### Home folder, encryption & login

Always shown. Four groups, three of them conditional.

**Home provisioning** — home mode (`create` a fresh home, `adopt` one already on the target, `archive` to bake a tarball into the image, `restore` from a backup), each explained on the page; home device; home backup; per-user eCryptfs home on top of the LUKS root; seed stack code; and the archive/seed extras. **Copy this machine's home folder…** is a preset: it selects `archive` mode and points you at the tarball and package-list fields. It copies nothing and runs nothing.

**External media-data device** — the Steam library and gocryptfs Vaults set. x86 only.

**Your login** — the local user and password for a desktop image.

Trap for all three: they are desktop surfaces, and the test is *every* image in the flow, not any. One node row in a mesh worklist takes all three off the screen, and the home fields are reset to their defaults on the way out. That is deliberate — the mesh base is copied onto every entry, so a desktop password offered because one row could use it would be baked into all of them.

**Root-disk encryption** is checked and disabled. It is a statement, not a choice: every image the Studio builds encrypts its installed root with LUKS2. The one exception is jetson, whose builder has no FDE path; there the box is replaced by a plain explanation. Two consequences are printed on the page. On x86 the build also produces an installer ISO, because the installer is what creates the encrypted root. If you leave the LUKS passphrase blank the installer asks for one interactively, which stalls an unattended fleet install. On ARM rows an encrypted root also drags in the arm64 cross-dracut initramfs, and the builder exits 1 at its own preflight before any work happens if this host cannot supply it — whenever the flow carries such a row, an amber note names the affected rows and says whether this host's `qemu-aarch64` binfmt registration will satisfy it.

Two unlock factors are offered, keyfile and YubiKey. Each offers `(off)`, `boot`, and — on desktop images only — `login`; both rows are x86-only. Read the keyfile tooltip before choosing `boot`: the build generates a random keyfile, the installer enrolls it as a second keyslot and places it on the ESP, and the ESP is unencrypted, so a stolen whole disk auto-unlocks. A recovery copy lands in the work dir.

### Review

Nothing starts here. Leaving this page commits the worklist and advances to the launch screen; the button says **Continue**, and reads *Checking Docker…* and stays disabled while the preflight probe is running.

A plain-language summary sits at the top: how many images and which, the output directory, the backend, `--env`, parallel jobs, the artifact set, the encryption consequence, and — in mesh — whether node key folders will be generated. Below it are collapsible sections, plus the device table, which is deliberately not one of them: a hardware scan should not hide behind a closed header.

- **Build execution** — backend (`auto`, `native`, `docker`), `--env` (`test` or `prod`), output directory, parallel jobs. All four explain themselves on hover, and it is worth reading them: `auto` resolves to `native` only on a Gentoo host with bash and Docker otherwise; `--env` is *baked* into the image at `/etc/hugmesh/env` and decides which ArgoCD apps survive in it, so it is a decision about the shipped system rather than about this build run; the output directory is the builder's `-w`, under which each dispatch gets its own `sessions/<session id>/`; and the jobs default is derived from this host's cores and available memory, not a fixed number (`HUGMESH_BUILD_JOBS` overrides it).
- **Mesh worklist** — one row per image with a facts summary, a per-image **Packages…** dialog, and **Show command**, which renders that row's exact builder command into a captioned pane directly under the table. It does not move the page or unfold anything; the page-wide *Exact builder command* fold below always holds the whole-config argv. **Generate node key-zips after each successful node build** is on by default; turning it off means no key folders and no generated accounts.
- **Image options** — installer front-end, root image size, `--grow`, version stamp, release tag, and (outside mesh) the single-image **Packages…** button. On an x86 node the installer front-end is greyed with the reason: a node cannot build the graphical front-end, and the combo is reporting what the build will actually use rather than offering a choice. Root image size `0` means the role default; an explicit size below the role's measured floor is refused here, on Continue, with an inline error — otherwise it aborts hours later in the image pre-flight.
- **Artifacts & build options** — each row pairs an option with the artifact it yields. Root image, live ISO with its two modifiers (embedded binpkg cache/distfiles, and a copy-to-RAM boot entry), installer ISO, the two rpi5-only rows (installer ISO for an unencrypted image, SD-card image only), rootfs tar, source bundling, compress, resume, skip the ISO stage, and image-only. Trap: **Resume is on by default**, so a build continues from whatever sysroot the last run left behind. Untick it when you want a guaranteed clean build. Source bundling is disabled with a note on an unaffiliated image — it is a builder hard conflict.
- **Attached devices** — every row defaults to `(none)`, so nothing is ever flashed by default. A row can be assigned as a flash target for one worklist image, or as the Keys USB, which writes through to the KEYS USB field below. The Keys USB role is offered disabled, with the reason, when the stick is not mounted or the platform's builder has no `--keys-usb` flag.
- **Secure Boot (x86)** — on by default with a throwaway org key. `--keys-usb` points at an *existing* fleet key directory supplying `Keys/kernel_key.{pem,der}`. This screen consumes a KEYS USB; it does not create one. Browsing for the KEYS USB directory or the signing key also holds that file's content in memory for the session, so the build survives the stick being unplugged, and the row shows the filename and a sha256 fingerprint. Typing a path instead of browsing does *not* hold it — the row says so. The certificate stays a plain path because it is the public half, baked into the image for enrollment.
- **Build plumbing** — folded unless something in it is non-default. Skip kernel, skip clean, distfiles cache, build subdir, seed URL, the `PENTEST=1` environment knob, the post-build QEMU device tests (available only with `--env test`), and an extra-flags box appended to the command verbatim.

The exact builder command is one fold below, showing the real per-session `-w` path. The preflight pane under it never folds, and Continue stays disabled until it is clean. **Build builder image now** appears only when the docker builder image is missing — it builds the builder, not an OS image.

This is a Qt commit page, so Back is disabled from here onward. That is why the next screen offers an explicit way out.

### Build

The launch gate. One short block states what Continue will run: the image count and ids, the backend, the output directory, whether node keys will be generated, and the ARM cross-dracut warning if an encrypted root needs it. A muted line notes that a native build needs root and will ask for your password.

Two action cards. **Continue the build** advances to the progress screen, which dispatches on arrival. **Back to the main menu** returns to the first screen with your configuration intact — nothing has been dispatched at this point, no session record exists, and nothing is written. The wizard's own Next button still works.

This page exists because the progress page starts building the moment it is reached and Back is already disabled. It is the last place to stop.

### Building

The build runs on a worker thread, one image at a time in worklist order.

An overall bar spans the whole worklist. Under it is a drillable tree: job, then stage, then emerge group, then package. Package rows carry their own bar, their USE flags read from that package's portage log, badge columns for `USE_EXPAND`/`USE`/`KEYWORDS`/`LICENSE`, and click-to-open of that package's emerge log. A badge column appears on its own once some package supplies that flag. The **Packages ▸** control on a job row stays greyed until that job's own emerge phase actually begins.

Clicking any row switches the shared log pane to it. The pane can be collapsed to its header or detached into its own window; neither loses a line. The help line under it names the real log file the builder writes and hands you the `tail -F` command for it, with a Copy button, so a terminal shows the same stream.

Footer lines record the once-per-worklist steps: the mesh manifest path (written before any image is built) and one line per node key folder. **Configure view** chooses columns, and a choice made there overrides the automatic badge columns for the rest of the session. **Stop all** stops everything; to stop one image, right-click its still-running row. **Next failure** cycles through failed jobs and stages, loading each one's log slice.

The final button is **Exit**, not Finish — the build is already running, and it only closes the Studio. It stays disabled until every row has finished, failed, or stopped. Back is re-enabled at that same moment, so a failed build is not a dead end: step back to Review, fix the config, and build again.

Closing the window does not stop the build. The run is owned by a supervisor outside the wizard and the tray keeps reporting it. Quitting the Studio does cancel.

After an all-ok run, any flash plan you set on the Review page runs in sequence — each write re-checking the device's identity first — and the QEMU device tests run if you ticked them. The **Flash to a device** panel appears too, if at least one device is attached; its own Flash… button makes you type the exact device path before it erases anything. A failed run flashes nothing.

Two things to know about arriving here directly. The preflight runs again on entry, and a failure means nothing is dispatched and the page says so. And a **Restart** from the sessions screen lands straight on this page, reusing that session's recorded config and workdir; if the original run consumed a signing key held only in memory, you are prompted to re-select it, and declining aborts honestly rather than falling back to the recorded path.
---

## Keeping this document true

It was written by reading `studio/hugmesh_studio/gui/pages/*.py` and verified
against that source page by page. It replaces a walkthrough that had drifted
badly: that one described a linear nine-page flow, which the Studio had not had
for some time.

Two properties make drift detectable rather than silent:

- The page list here is `WIZARD_PAGE_SLUGS`, and the skip rules are
  `MODE_SKIPPED_PAGES`. Both are in `core/config.py`, and `wizard.py` asserts
  that its page constructors have not drifted from the slug list.
- Page titles and field labels quoted here are quoted from the source, not
  paraphrased, so a rename shows up as a mismatch rather than a rewording.

When you add or reorder a page, update this file in the same commit.
