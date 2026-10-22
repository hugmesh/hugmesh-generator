# Studio — the operator's walkthrough

Every page of the HugMesh Image Studio wizard, in the order you meet them, and what each
one changes.

**Read this if** you are standing in front of the Studio for the first time and want to
know what to click. To learn why the pages are grouped as they are, and what parity the
other front-ends owe them, read [STUDIO-WIZARD-FLOW.md](STUDIO-WIZARD-FLOW.md). To install
or run the Studio, read [../studio/README.md](../studio/README.md).

## The one thing to understand first

**The Studio is not a fixed sequence of screens**, whatever the wizard frame suggests.
There are twenty-nine pages (`WIZARD_PAGE_SLUGS`). Which ones you see depends on what you
pick on the build menu. One of them, `localmesh`, expands into an eleven-page branch of its
own. A standalone desktop run skips nine pages that a mesh run walks through.

Two numbers explain the shape:

- **Ten cards** on the build menu.
- **Three image build modes** — `standalone`, `cloud`, `mesh`. Only these three are ever
  written to the configuration, and only these three key the skip map.

The other seven cards are side-flows. Each raises a transient wizard flag and runs its own
page. Most end there without touching the image configuration. So the menu looks like ten
choices, and the saved config records only three modes.

The skip map lives in one place, `MODE_SKIPPED_PAGES` in
`studio/hugmesh_studio/core/config.py`. The page order is `WIZARD_PAGE_SLUGS`, beside it.
If this document and that file disagree, the file is right.

## Getting in

The Studio is a Qt wizard. Three screens decide everything after them: a Welcome screen that routes you, an optional Prior-sessions screen, and the build menu. Your pick on the build menu decides which of the remaining twenty-six pages you ever see.

The window's **About** button (Qt's Help button, renamed) shows the Studio version, the Qt binding in use, and the licence that binding ships under. It stays on the wizard's button row throughout.

### Welcome — "HugMesh Image Studio"

The first screen on every fresh start. It has a short paragraph on what HugMesh is, with a link to the GitHub README's getting-started guide ([`#quick-start`](https://github.com/hugmesh/hugmesh-generator#quick-start)). The link is a real anchor: a click hands the URL to your desktop browser. The Studio never fetches it.

Below that is a paragraph about **this machine**, built from a host probe:

- If a build backend exists, it says `Build backend: native` (Linux + Gentoo + bash) or `docker`, plus a one-line host summary: OS, WSL version, Gentoo, session type, docker, KVM, root.
- If neither exists, it says in red that this machine cannot build images yet, and names the fix. Under WSL the fix is Docker Desktop's per-distro WSL Integration checkbox (Settings → Resources → WSL Integration), not a reinstall. On WSL1, convert the distro to WSL2 first. You can still configure and save an image here and build it elsewhere.
- Either way, a red **SLOW FILESYSTEM** warning appears if the generator directory is on a Windows drive **and** this is WSL, or if it is on a network filesystem. Read it. That build does not fail. It stops appearing to move, and you will take it for a hang. If the repo is on a Windows drive, put it on the Linux filesystem (`git clone … ~/Github/hugmesh-generator`). If it is on a network filesystem, copy it onto a local disk. The check uses the filesystem type from `/proc/mounts`, so a symlink from `~/Github` into `/mnt/c` is caught too. Only an unreadable mount table falls back to the shape of the path.

Then two cards. Pick one:

| Card | Goes to |
| --- | --- |
| **Start building** | the build menu (`mode`) |
| **Review prior sessions** | the Prior-sessions screen |

**Start building** is pre-selected, so Next or Enter with no other input takes the ordinary path. **Clicking a card both selects it and advances**; there is no confirm step. Space, Return or Enter on a focused card does the same, and the arrow keys move the selection between cards. Back works if you overshoot.

(A third card, **Start a local mesh**, was removed on 2026-08-26. It duplicated the build menu's own **Local Docker mesh** card. That flow is now reached through **Start building**; see `STUDIO-WIZARD-FLOW.md`.)

One exception: a **Restart** from a prior session sets the wizard's start page to the build-progress page. You never see this screen on that path.

### Prior sessions — only if you asked for it

Welcome's second card is the only way in. Its own Next continues to the build menu with whatever you loaded, so it is a stop on the way, not a dead end. If you have nothing to reuse, skip it.

**Load config… / Save config…** One loader reads both file shapes: a flat single-image config, and a `hugmesh-worklist/v1` envelope. You do not have to know which you have.

- Loading **restarts the wizard**. You land back on the Welcome screen with every page repopulated. That is expected, not a failure.
- Saving defaults to `hugmesh-image.json`. It writes the envelope when a worklist exists, and flat JSON otherwise. It collects only the pages you visited, so a page the flow skipped cannot leak stale values into the file.
- Saving blanks plaintext secrets — `local-pass`, `luks-pass`, `user-password`, `root-password`. A dialog names the ones it dropped. Re-enter them before you build from that file.

**Previous builds** is a table below the buttons, with a free-text filter and a status dropdown above it. It hides itself when there is nothing to list, so a first run shows only the two buttons. It lists persisted build sessions, newest first. After them come `wl-<role>.<platform>` build directories found at the top level of the output directory (best effort, status `unknown`), and any record file it could not parse. The table refreshes on every visit, so a build you just finished appears without a Studio restart.

Seven actions:

- **Open build window** — opens the per-build actions window. Clicking or activating a row opens the same one.
- **Restart** — rebuilds the same config into the *same* workdir; existing artifacts are reused or overwritten. The confirm dialog has a "Resume from existing build tree (`--resume`)" checkbox, pre-checked when `wl-` build trees already sit in that workdir (an x86 build resumed from a tree that is not root's, that cannot get its static libraries back from the seed it came from, or that cannot link a C program stops in its first minutes with one sentence saying to rebuild without `--resume`: untick the box and restart, which wipes and re-extracts that tree as root — hugmesh-generator#659). It lists any secrets that were not saved with the session and any secret *files* held in memory only. Accepting jumps to the build-progress page, which re-runs the full preflight before it launches and prompts for those held files. Restart refuses if another Studio process is running the session, and offers Redo if the artifact directory is gone. (A fleet run restarts through the fleet window.)
- **Redo (edit as new)** — loads that session's config back into the wizard as a new session and returns you to Welcome, where you walk the pages and edit. A fresh session id and workdir are minted at build time.
- **Open artifacts** — opens the build directory in your file manager. Disabled when the directory is gone.
- **View errors/log** — shows the persisted per-image error tails, or the tail of the legacy shared `build.log` for a discovered unmanaged tree. For a stale `running` record it says the process is gone; it never upgrades that to "complete".
- **Delete** — removes the record. Deleting the artifacts on disk is a separate checkbox, **off** by default. Refused for a session running elsewhere. (An unmanaged tree or an unreadable record file is deleted outright, on a plain confirm.)
- **Delete all finished…** — prunes finished records only; running sessions stay. Same artifacts-are-opt-in checkbox.

Restart and Redo are disabled for anything that is not a session record. Discovered `wl-*` directories and unreadable record files have no config snapshot to replay.

A **Fleet build…** button appears here only when `HUGMESH_STUDIO_ADVANCED` is set truthy (`1`/`true`/`yes`/`on`). It builds every role for a whole release, not the single image this wizard configures. `hugmesh_studio --fleet` reaches it without the flag.

### What do you want to build?

Ten cards. Clicking one commits the page and advances, as on Welcome. **Standalone Gentoo desktop** is pre-selected on a fresh flow. After a Back-navigation or a loaded config, the card that matches the loaded mode is selected instead.

Only **three** of the ten build an image. Those three are the only values the config's `mode` ever takes, and the only things that change which pages you see:

| Card | Commits | Then skips (statically) | Default role |
| --- | --- | --- | --- |
| **Mesh node** | `mode=mesh` | Target machine & image type, Target hardware | `omnibus` |
| **Mesh desktop client** | `mode=cloud` | Identity provider, the worklist, the two "do you want to configure…" choice screens for domains and users, and the secrets store | `desktop` |
| **Standalone Gentoo desktop** | `mode=standalone` | Identity provider, the worklist, the key-zip screen, both domains and users screens entirely, and the secrets store | `standalone-thick` |

A mesh run reads Identity provider → Choose the images to build → Branding → Network → Load your admin config (key-zip or link) → Domains → *Domains & their services* → *Domain services* → Users → *Superusers & domain users* → System identity → Secrets store → Home folder, encryption & login → Review → Build → Building.

- *Domains & their services* shows only if the Domains choice screen before it asked for more domains (`additional_domains`).
- *Domain services* always shows, because the mesh's own domain always gets a services page. It then walks one page per further named domain.
- *Superusers & domain users* shows only if the Users choice screen before it asked for it (`configure_users`).
- A build refuses while any domain, the mesh's own included, has never been walked on *Domain services*. See that section below.

Standalone is the shortest path: Target machine & image type → Target hardware → Branding → Network → System identity → Home folder, encryption & login → Review → Build → Building. It never sees the Domains, *Domain services* or Users screens. Beyond the static list, four pages can drop themselves when they have nothing to contribute: Branding (only for an unaffiliated image with no desktop half to theme), Domains, *Domain services* and Users.

Mesh replaces the role and hardware pages with the worklist, which owns role × platform for the whole set of node images. Committing mesh also runs the mesh-entry defaults every time. They zero the theming and home-folder fields the committed role class does not permit, force tailnet and SSO on, and set encrypted root from the platform-keyed posture: true wherever the builder has a full-disk-encryption path, false on Jetson, which has none.

The other seven cards commit **nothing** to `mode`. Each raises a transient flag that the matching page reads. Five of them are terminal: the flow ends there, with no image.

| Card | What it is |
| --- | --- |
| **Local Docker mesh** | run a whole mesh on this machine in Docker |
| **Run e2e tests** | drive `tests/e2e` against a mesh that is already running — and the door to the QEMU device-test lanes |
| **Mesh emulation** | boot a whole prior build as persistent guests, with console, ssh and disk saves |
| **Cloud deploy** | publish an already-packaged x86 image to a cloud provider |
| **MDM phone** | flash and enroll a USB Pixel |
| **MDM Quest headset** | enroll a USB Meta Quest 3/3S |
| **Create nodes for local cloud** | turn the local Docker mesh into real node images |

Two of the seven are not terminal:

- **Run e2e tests** offers "Emulated-device test lanes (QEMU device tests)" against "Run the suite against a running mesh" on its own screen. The test-lanes arm continues into the **QEMU device tests** page, which offers "Build new images first, then run these tests". *That* arm rejoins the image flow. It asks "Which image build should run first?" with the three image builds, preselects the mode this Studio session was already carrying and says so, and commits your pick before the flow continues.
- **Create nodes for local cloud** is a gate. It imports the local mesh's apex domain, its other domains and its provisioned accounts. On Next it commits `mode=mesh` itself and restricts the worklist to the laptop role plus every mesh role that produces a cluster node. The rest of the flow is an abbreviated mesh wizard. The local Kubernetes stack has to come down first. An inline checkbox takes your consent and *arms* a Stop button, which runs `make kind-down` on a worker thread with streamed output and Cancel. Nothing is torn down without a press. Next stays disabled while a cluster is known to be up or a teardown is in flight. The consent box is cleared on every forward entry.

**The trap on this screen is coming back to it.** Committing a card rewrites state you may have already entered, and it gives no warning:

- Entering or leaving mesh discards the worklist. Both directions.
- Committing standalone clears the key-zip path, the domains list, the users list and both "configure domains / configure users" flags, and forces tailnet and SSO off. Those pages are unreachable in standalone, so anything parked in them would be saved but invisible.
- Your role resets to the mode default only when the role you had is not valid in the new mode. A valid role survives.
- Every image-mode commit also rewrites `bundle_source`: on for standalone (except the unaffiliated role, where bundling the generator source is a hard conflict), off for cloud and mesh.

To try a different build type after a lot of configuring, save the config first.

## Choosing what to build

The screen behind Welcome's **Start building** card is **What do you want to build?** (above). Clicking a card is the decision: it commits the page and moves the flow on. Only three cards commit an image mode (Mesh node → `mesh`, Mesh desktop client → `cloud`, Standalone Gentoo desktop → `standalone`). The other seven run a tool instead of configuring a build.

On a terminal page the final button reads **Exit**, not Finish. It closes Studio and does nothing else. Whatever you started keeps running. Those pages are Local Docker mesh, MDM phone, MDM Quest headset, Cloud deploy, Mesh emulation, and Run e2e tests on its "run the suite" arm.

Picking a tool card raises a flag on the wizard, not a field in the config. Every page whose card you did not pick skips itself, so the flow you walk holds only the pages your choice reached.

### Local Docker mesh

Runs a dockerized HugMesh mesh on this machine. No image build, no server hardware.

The card opens a **Local Docker mesh** screen with two cards, and they are alternatives. **Join an existing mesh with a key** is the default.

**Join an existing mesh with a key.** One terminal page. It asks for a tailnet/headscale auth key (required — Start refuses without one), an optional node name, and an optional self-hosted headscale URL. Buttons: Start, Stop, View logs…. The key is staged as `TS_AUTHKEY` into the local compose project's `.env` and nowhere else.

**Generate a new mesh.** Mints every credential and brings up the whole platform stack seeded with a fresh superadmin. Nine steps, in this order (the design of a new superbrand is part of the first, not a tenth):

1. **Environment and brand.**
   - **Environment** — `test` (default: LAN-only, self-signed, nothing published) or `prod`. Prod needs a public apex domain, typed in row 0 of the Domains step, and a tailnet auth key, entered on the Mesh overlay step. The run is blocked until both are set.
   - **Superbrand** — a drop-down, not a box you type a slug into. **Create a new superbrand** is the first item and is selected when you arrive; below it come this configuration's own superbrand (when a saved mesh carried one), your saved designs, and the profiles in `brands/*.conf`. Choosing Create opens **Design your superbrand** directly under the drop-down on this same step (it is not a step of its own): an id, a title, an organisation, the internal root name, and the look (colours, a font, shape, decoration and two small pictures, with a meter against the 100 KiB stylesheet budget). The public name is read-only here because its one home is the first row of the Domains step. Choosing a saved design copies it in; choosing a profile skips the design and shows a read-only summary with a **Change it** click that opens the same design. The id must be a DNS label, and a profile pick with no `brands/<id>.conf` still warns that profile presets stay unset (nothing is said about that under Create, where no profile was picked). The design goes into the mesh's brand record (saved when you leave the step) and into the plan. The design has no look of its own any more: the look (presets, colours, font, shape, pictures, header and footer) is chosen on the **Look** tab of the mesh's own domain on the Domain services step, and that look is what this Docker mesh's sign-in page shows. The same choices are offered, numbered, in the text screens (`superbrand` on the first local-mesh page).
   - **Superadmin** — defaults to `superadmin`. Its password is generated and written only to the offline secrets bundle; the page never shows it.
2. **Domains.** Row 0 is the mesh's own domain: on a test mesh the brand-default apex, fixed; on a prod mesh the public apex, typed here. Add every other domain this mesh serves below it. **Sign-in** is `Superdomain` (the central Casdoor) or `Own`; an `Own` row brings up a Casdoor of its own beside the central one, on host ports 8001, 8002, … in row order. *Optional services* is read-only here. The Next button refuses a row that is not a domain name, a duplicate, or an added row named after row 0, and says why inline.
3. **Domain services.** One page per domain, the mesh's own domain first, with the four Brand settings tabs (Identity, Look, Services, Ways to reach it). It is the same page the image flow uses (see *Domain services* below). On this route **what you tick runs**: the mesh starts every service any of its domains chose, one copy each. Row 0's **Look** tab is the one place the mesh's look (its theme) is chosen; an added domain's Look tab overrides it field by field.
4. **Repo source** — download and update every repo into `./.stack-src` (the default), or point at a tree of `hugmesh-<name>` checkouts you already have. The second mode sets `STACK_NO_CLONE=1`, so your checkouts are never fetched, updated or `git reset`. A third option, "Render repo source from templates", is permanently disabled with its reason on the page. Under the cards, the **Code folders** block lists each domain's apps (the apps of a service a domain did not choose are not listed under it) and gives each domain its own folder of git copies: **Make N copies** clones each of that domain's apps from the build checkout into `<state dir>/domain-code/<mesh>/<domain>/<app>.<domain>/`, on a branch `domain/<domain>`. When a service is un-ticked, its copies are listed as extra; **Remove N extra folders…** lists them on the first click and removes them only on the second, and a copy that holds edits or local commits is always kept. On the text interface the same thing is `f` on the Local Docker mesh review screen.
5. **Mesh infrastructure** (it was "Services"; the mesh-wide "Local services" pick was retired on 2026-10-21) — only what runs once for the whole mesh: Tor, Anubis, the wiki, the AI services and the egress VPN, grouped. A domain's own services (Matrix, the forums, video, games, the character tools) are on that domain's page; a saved mesh that listed them here moves them onto its domain rows when it is loaded. Three mechanisms, and the row tells you which it is. *Compose profile* rows start or stop containers, so changing one later needs a stop and a start. *Federation* rows start nothing; they flip the service's `enabled` row at seed time, which is what makes it appear in the mesh menu. *DevOps lane* rows are greyed with no checkbox, because they are Kubernetes controllers this docker mesh cannot run. A service the local stack has no mechanism for at all is greyed with its reason rather than offered as a toggle that would change nothing. Boxes start at the shipped defaults, not at off. The step also holds **Web login languages** (empty means English only, which is also the smallest image). The **Themes** panel that used to sit here is gone: the look is row 0's Look tab. A saved mesh's theme inputs still load, into that look.
6. **Identity provider** — collapsed by default. This is the mesh's own sign-in: the default every domain inherits. A domain chooses its own on its Identity tab (its own Casdoor, or its own Azure Entra ID, AWS Cognito or OIDC provider). External OIDC here is validation-only config; the local stack pins its own Casdoor split, and the page says so.
7. **Mesh overlay** — prod only. The tailnet auth key, an optional headscale URL, and the public domain, shown read-only because the Domains step owns it.
8. **Saved meshes and the plan.** A read-only plan preview refreshes live from every earlier step, and a mesh-state line reports whether a mesh is already running. The **Saved meshes** list sits here, open. Its top line is the **current mesh** — the one you are working on in these steps — with every domain and what is kept for it (sign-in, services, look, VPN and outbound traffic, its own Tor front door), and whether it is saved already, unchanged or changed since. **Save current mesh** records it as a new entry (named from the **Save as** box, or a derived name when the box is empty); it does not need the mesh to be running. **Overwrite selected** replaces the selected entry with the current mesh, but only on a second click: the first click arms it and says which entry is replaced. Nothing runs until you press a button on the next step, except a saved row's Start or Restore, which does run docker.
9. **Bring-up and monitor.** The end of the path: **Exit** closes the Studio and the mesh keeps running in Docker. The step itself holds a note and a **Show the panel** button: the actions, the running mesh and the run log live in the **Studio panel** docked at the bottom of the window, and arriving here opens it on its **Local mesh** tab. The panel is there on every page, can be collapsed, or popped out into its own window, and a verb keeps running whatever page you are on.

The panel's Local mesh action bar wraps and holds more than the bring-up. Its buttons:

- Generate & start, Stop mesh, Stop & clean Docker…, Cancel.
- Check readiness (read-only host probes: docker, buildx, disk headroom, maven prerequisites) and Build maven prereqs (m2).
- Open web UI, Copy .onion address, Sign-in credentials.
- An *e2e target* chooser, with e2e features… and e2e evidence….
- Vaults & volumes…, Save current mesh, Add user….
- A separate Kubernetes lane: Install DevOps prerequisites, Start DevOps lane, its add-on checkboxes, Delete DevOps lane.

Every verb runs on a worker thread. The long ones stream into a stage tree (the panel's **Mesh run** tab, which opens by itself when a verb starts) and can be cancelled. The log pane filters to whichever stage you click. The **Running mesh** tab, *Running mesh — pods, addresses and doors*, lists every pod and container of both lanes with its addresses, the domain it serves (or *All domains* for shared ones), an Open button only where the browser may safely go, and a Replicas column for scaling. Under the table, a domain picker with **Start**, **Stop**, **Restart** and **Logs** acts on that one domain's containers and pods only (a per-domain own Casdoor and its database, a service only that domain chose); shared rows are never touched from there, and kind pods refuse Start/Stop because ArgoCD self-heal would undo them. **Tor addresses** lists every onion the mesh publishes, each with its own **Open in Tor Browser** and **Copy**, so several Tor domains can be opened at once. The **Image builds** tab lists every image build this Studio is running. The **Assistant** tab holds the local assistant and the local AI agent launcher (it used to be a card on this step).

Sensible first run: `test`, the default source mode, Check readiness, then Generate & start.

Saved meshes: **Save current mesh** records the mesh you are working on, running or not (configuration with every domain's sign-in, services, look and VPN/egress choices, the env it exports, overlay text, per-repo source HEADs, doors, account names and roles, credential *pointers*, and an inventory of its data volumes — never the volumes' contents and never a password) under the Studio state dir. The **Saved meshes** table on the plan step says, before you click, whether each row would Start (volumes still present after Stop mesh: reattach, no re-mint, no re-seed) or Restore (volumes gone after Stop & clean Docker: bring up empty and re-seed — same usernames; the same passwords only if the record kept credential copies, an opt-in that is off by default). A mesh saved before its first bring-up has no volumes on record and no minted credentials: Load it into the form and use Generate && start; its Restore says so and refuses before any preflight runs. The credential-copy box next to the Actions-row save is offered only while a mesh is running, because the files on disk belong to whatever mesh last ran. Delete removes only the record. Never restored: the tailnet auth key, passwords of users added with Add user…, exact image bits and the .onion after a clean. The same records drive `python3 -m hugmesh_studio.core.local_mesh_bootstrap mesh-save|mesh-restore`; `mesh-save` also saves with nothing running and takes `--overwrite ID`.

Traps:

- The plan step probes the real compose project. If a mesh is already up, the mesh-state line says so; "Generate & start" would bring it up a second time over the live stack.
- "Stop mesh" runs `make stack-halt`, which the Makefile documents as the non-destructive stop that keeps identity, rooms, accounts and the BFF databases. (Its tooltip and log line once claimed `make stack-down` plus dropped volumes; the saved-meshes warm Start depends on the true behaviour.) **Stop & clean Docker…** is the destructive one: volumes and the ~28 built images go, and the next start is a cold build measured in hours. It confirms first and lists exactly what it removes and what it does not.
- The DevOps lane is a separate Kubernetes cluster. Starting or deleting it changes nothing about the running containers.
- The mesh will not start while any domain on the Domains step has never been through the Domain services step. The refusal names the domain and points back at those two steps.

Downstream: nothing. This page emits no image-config fields and ends the path.

### MDM phone

Reached only from the "MDM phone" card. It flashes a USB-connected Google Pixel with verified GrapheneOS and enrolls it as an MDM-managed mesh device. The page is a thin front over `core/phone_wizard.py`, which shells `scripts/phone-wizard.sh`, the driver the ncurses menu also uses. Every gate lives in the driver.

It asks for: device codename (from the driver's vetted catalog `scripts/phone-devices.tsv`, plus a `<detect at run>` entry; editable), release channel (`stable` by default, or beta/alpha), serial (blank means auto when exactly one device is connected), keys dir, login server, a masked auth key, and mesh role.

Nine verbs. Seven stream into the log here: Plan (dry-run), Detect, Fetch + verify, Enroll, Profile, Ingest, Status. Two hand off to a real terminal emulator: **Flash (DESTRUCTIVE)** and the **Guided wizard**. That is deliberate. The driver's typed-serial confirmation needs a TTY, and Studio never injects a bypass or pipes `/dev/null` at a confirmation gate.

The auth key is never persisted and never lands on argv. A run stages it into a `0600 --authkey-file`, and the core shreds that file afterwards.

Sensible default: leave the codename at `<detect at run>`, keep `stable`, run Plan first.

Trap: Flash and the guided wizard seem to do nothing in the window. They open a terminal. If no terminal can be opened, the status line says so and nothing runs.

Downstream: nothing. Terminal.

### MDM Quest headset

The same driver with `--device-class quest`, so the catalog becomes `scripts/quest-devices.tsv`: `eureka` is the Quest 3, `panther` the Quest 3S. There is no flash and no release channel. A Quest keeps Horizon OS, and the driver refuses `fetch`, `flash`, `attest` and `profile` for this class and says why.

The page asks for the same identity block as the phone page (codename, serial, keys dir, login server, masked auth key, mesh role), plus:

- **Headwind management plane** — server URL, DPC APK path, the expected APK signing-cert SHA-256 (enrollment fails closed on a mismatch), and the Headwind *configuration* the headset self-selects into. Paths, URLs and names only; never secrets.
- **XR-chat URL** — a toggle plus an `https://` room URL. WebXR needs a secure context.
- **Thin desktop** — a toggle plus a Moonlight APK path, its signer SHA-256, and a comma-separated list of thin-client tailnet names.

Each toggle gates its own fields, and the values are emitted only while the toggle is on. The driver refuses the value knobs without the capability flag.

Seven verbs. Only the **Guided wizard** goes to a terminal. **MDM-enroll + chat URL** streams here, because the phone's interactive fresh-device gates become non-interactive advisories on a Quest.

Prerequisite: Developer Mode must be on, and that needs a Meta developer account. The driver prints the runbook when the headset is not adb-visible.

Trap: `panther` is *also* the Pixel 7 codename. The device class picks the catalog, and the driver pins USB vendor 2833 and `ro.product.manufacturer=oculus`, so a phone can never be driven down this path.

Downstream: nothing. Terminal.

### Cloud deploy

Publishes an **already-built, already-packaged** x86 artifact. It does not build or package. Run `scripts/cloud-package.sh` first and point this page at its output (`.qcow2`, `.vhd`, `.img`).

It asks for: provider (read live from `hugmesh-cloud-deploy list`; Refresh re-reads it, and an empty combo means the driver is missing), image path, domain, region, a path to a `0600` credentials file or pasted credentials, an output directory for rendered artifacts, a keys dir, and an identity-provider passthrough. The passthrough is Casdoor built-in by default, or Entra / Cognito / other OIDC. The external choices enable issuer, client id and JWKS fields and make the plan emit `idp/idp.conf`.

A read-only monospace pane previews the knobs, the exact plan command, and any blockers. It is pure: nothing runs until you pick a verb.

Four verbs:

- **Plan** renders the provider's artifacts offline. It touches no cloud API.
- **Status** reads the emitted state hints. It never calls a cloud API either.
- **Apply** streams here, but only behind the "I understand APPLY executes the plan's emitted apply.sh against a REAL cloud account" tick, and only after `validate()` passes.
- **Destroy** opens a terminal, where the driver's own confirmation runs.

A fifth button, **Open artifacts folder**, opens the output directory.

Pasted credentials are never persisted and never reach argv. A run stages them into a `0600 --creds-file` tempfile and shreds it afterwards.

Sensible default: Plan first, read the rendered artifacts, then tick and Apply.

Trap: the acknowledgement checkbox is Studio's gate, not the driver's. The driver confirms again and fails closed without a TTY. Studio never sets its test-only assume-yes variable.

Downstream: nothing. Terminal.

### Run e2e tests

Added 2026-08-27 at the operator's request — *"remove QEMU device emulation menu item as it does not do anything that cannot be done from the other menu, but add the run e2e tests button"*. It holds the mode-menu slot that the **QEMU device tests** card used to hold. That card is gone. The page behind it remains, and this screen is its door.

Two arms, chosen by radio.

**Run the suite against a running mesh** (the default, and terminal). This is `tests/e2e`, the Gherkin lane (`make stack-e2e-bdd-env`), run against a mesh that is *already serving*. Nothing here starts one.

- The **e2e target** chooser is built from `core/e2e_environments.py`, never restated: `docker` (the compose stack), `kind` (the local DevOps cluster) and `qemu` (an emulated device over its forwarded UI port). The choice rides as `SNAP_ENV` on the child process, the same channel `SNAP_ENV=kind make stack-e2e-bdd-env` uses and `tests/e2e/steps/world.ts` reads. So the Studio and a terminal can never target different meshes.
- Under the chooser the page states what that environment *is*, the exact `make` target and pins a run would use, and the command that would **start** it. That last one is text only. The Studio will not spawn it: bringing a QEMU device up needs root, and an unanswerable password prompt does not fail, it hangs.
- The **readiness** line is a live, off-thread probe (`LocalStackNode.e2e_ready`) about *the chosen environment*. Until it answers, the door is shut and says so; "nothing established" reads as a blocker, never as permission. When it refuses, it names every reason. The same list goes into the feature tree, so its Run button can never be armed against a mesh that cannot host the suite.
- That gate is deliberately **scoped**. For `kind` and `qemu` it checks only this checkout (`tests/e2e` + `node_modules`) and leaves liveness to the harness, which skips each scenario with a reason naming what to start. The page says so; it does not imply a full check. For `qemu` it also reports whether a `qemu-system-*` process is running, as a **note**, never a block, because it cannot see a device emulating inside the runner container.
- **Identity.** The suite's superadmin scenarios log in as the *minted* superadmin whenever the mesh was bootstrapped from Studio. The page reads that bundle through the bootstrap's own reader and says which brand answered. If none did, the mesh was seeded from a terminal and the deterministic e2e defaults apply. The page always says which identity a run will use.
- **e2e features…** opens the feature tree (non-modal, so a run streams into the log below it): Gherkin features, spec files with their last verdicts and skip reasons, the personas each draws from, the source, and the screenshots a run produced. What you check is what runs.

The 35 handwritten spec files (`tests/e2e/specs/NN-*.spec.ts`) are a separate lane and are **not** run here. Run `make stack-e2e` from a terminal.

**Emulated-device test lanes (QEMU device tests).** This arm hides everything above and leaves one line: Next continues into the QEMU device-test page, described next.

### QEMU device tests

Reached from **Run e2e tests**, and from nowhere else in the menu; its own card was removed 2026-08-27. (The post-build opt-in is unaffected. The Build screen's "run the QEMU emulated-device tests" checkbox still runs this same containerized harness when a build finishes, with no menu involved.) The page stayed because it is the only place in Studio that can spawn the Playwright-on-an-emulated-device harness and the SELinux AVC workout. Mesh emulation offers neither.

This is the **test** lane of emulation: ephemeral asserted boots. It boots a session's images, checks they provisioned correctly, and powers them off. Two arms, chosen by radio.

**Images from a previous build session.** Pick a prior session and run its rows now. Partial sessions are listed and badged, and the newest complete one is preselected. An image build takes hours, so retesting must not mean rebuilding. The per-domain gate described under *Mesh emulation* applies here too: run, AVC and Playwright are disabled for a session whose recorded configuration names an unwalked domain.

The run envelope is one box. Every knob in it is a field of the same object that authors the spawned command, so the preview cannot drift from what happens:

- Concurrent devices — default 2. Each device holds its own guest RAM, so this multiplies the next field.
- Guest RAM — default 2048 MB.
- Boot timeout — default 2400 s. A first boot under ARM emulation runs a full-filesystem SELinux relabel before sshd starts.
- Assertion timeout — default 0, meaning the entrypoint's own default, with no flag emitted. This clock is separate from the boot timeout.
- Extra guest logins — additional wheel accounts created on every guest, beyond the payload's own `tester`.
- Image cache cap — default unbounded. Every `.img.xz` row is decompressed once and kept.

Buttons: **List devices** (lists what would run, boots nothing), **Run device tests**, **Read verdicts** (re-reads files and records; starts and stops nothing), **Cancel** (reaches the whole process group, docker children included).

Two single-row lanes sit below. The **SELinux AVC workout** (`tests/qemu/avc-workout.sh`) runs against one planned row. The **Playwright browser suite** (`tests/qemu/run-qemu-e2e.sh`) runs against one row, with forwarded UI and SSH ports and a spec/`--grep` passthrough. Only rows whose platform has a launcher in that script are offered. List specs and Preview need nothing special, but the real run needs root. Studio refuses it up front and names the containerized route; it does not reach for sudo.

Read the results table carefully. It has one row per **planned** row, including rows that produced nothing, and only **PASS** is green:

- **SUSPECT** — graded PASS with zero assertions recorded.
- **STALE** — a verdict from an earlier boot.
- **NO-RESULT** — planned, the run completed, no verdict emitted.

Two notes sit up front. Docker availability is probed off the GUI thread and gates the run buttons, which stay greyed until the probe answers. KVM is a warning, never a block. Without it the runner still gives correct results, but an x86 row goes from minutes to hours (Pi/aarch64 rows are pure emulation either way). Under WSL2 that is the default state unless a `.wslconfig` stanza turns nested virtualisation on.

**Build new images first, then run these tests.** This arm hides everything above and leaves one line: Next continues into the normal image flow with `cfg.qemu_device_tests` set. The Build screen shows the same flag as a checkbox, and it stays yours to untick there. Once the Build screen has been reached, its checkbox is the only writer.

Traps:

- This lane runs the whole fleet. There is no per-platform filter. To boot a single device, use Mesh emulation's per-device Start, or the AVC workout above.
- "Build new images first" shows the three image builds ("Which image build should run first?") and preselects the mode the session is already carrying (**standalone** on a fresh Studio), with a note that this is a leftover, not a choice. Pick the build the tests should run against; the page commits it before the image flow continues. The "images from a previous build session" arm commits nothing.
- With no session holding a bootable image, the existing-images arm is disabled and build-first is preselected for you.
- Nothing this page starts is meant to outlive the run. For guests that stay up, use Mesh emulation.

### Mesh emulation

The **deploy** lane. It boots every image of a chosen prior build session as persistent (`--keep-alive`) emulated devices and lets you drive the whole mesh locally.

It asks one thing first: which build session's images. Every image in the session becomes one device. Partial sessions are marked, and the newest complete one is preselected. If that session's recorded configuration names a domain nobody walked on *Domain services*, Start mesh, per-device Start and Replicas Apply are disabled. A note under the picker names the domain and points at **Redo**. Listing, dry runs, stop, ssh and save still work. A session with no record, or one from before the per-domain step existed, is never refused.

The **plan** drives the device table, not the registry, so rows exist before their guests do and you can see what will boot. A poll reconciles reality onto those rows. It keeps running while anything is still booting or asserting, so a mesh coming up repaints itself and does not look dead for the many minutes an emulated boot takes. Columns: Device, Role, Arch, State, Verdict, Sections, SSH, Login, Actions, QEMU, Save disk, Replicas (0/1). The Replicas column is 0 or 1 because an emulated device is one guest per built image. Apply(1) and Apply(0) run the same runner commands as Start and Stop. Verdicts are graded by the same rules as the test page. Below the table, a collapsed *Running mesh — pods, containers and their addresses* section reads the docker compose project and the kind cluster on this workstation, not the emulated guests.

Mesh-wide: Start mesh, Stop all, Refresh, Cancel. Per device: Start, Stop, an SSH button that opens a desktop terminal (with a copy-ready command as fallback), a login dropdown, the QMP console, and Save copy / Overwrite save.

**The web front door.** The keep-alive runner publishes exactly one port per device: ssh, on loopback. The web UI is reached through it. "Open web UI" opens an `ssh -N -L` tunnel from the plan's local UI port to the gateway guest's own `:443`, then opens `https://127.0.0.1:<port>/`. TLS is self-signed, so the browser warns once. The page says whether it started a tunnel or reused one, shows the exact command, and offers a Close tunnel button. Tunnels also come down when the mesh stops, when the gateway device stops, when you leave the page, and when Studio closes.

**Saving the whole mesh.** The first press only *previews*: per-device budget, how many KEYS pieces are present, the fleet total against free space, and a refusal with remedies when the filesystem cannot hold it. Then tick "confirm mesh save" and press again. A save is each disk's full virtual size, 9.5–20.5 GB per device. The tick is cleared after every run: it is consent for one save, not a mode. Devices are paused for their copy and put back as they were found. The copies are crash-consistent.

Traps:

- The QMP button reads **"Reset (ends guest)"** and means it. Every launcher runs qemu with `-no-reboot`, so a QMP `system_reset` shuts the guest down and exits; it does not reboot. It sits behind an inline confirm tick for that reason. Power off also ends the guest, the orderly way. Either way, only Start brings the row back, and that is a full emulated boot.
- The guests ship `PermitRootLogin no`, and the assertions check that it stays that way. Reach root by logging in as a wheel user and running `sudo -i`; the login dropdown offers that as its own row.
- Exiting Studio from this page leaves the emulated devices running. The verbs on the page start and stop them.

Downstream: nothing reaches the image config. Terminal.

### Create nodes for local cloud

The gate between a running local Docker mesh and the node-image wizard. Unlike its siblings it is an entry, not a destination.

On every forward entry it reads the local mesh's identity **offline** (plain file reads, no docker probe) and shows exactly what it will import. The apex domain comes from the newest saved-mesh record for this checkout whose mesh was running when it was saved; a newer draft (saved before its first bring-up) never replaces it, and is used only when nothing ever ran. With no record, the defaults apply. The **Import from saved mesh** list above the summary picks any other record of this checkout (the terminal flow takes its number), and the summary names the record and says NEVER RAN for a draft. Every added domain comes from the same record, with its title, sign-in and per-domain services. A row the import cannot take is listed as "NOT imported" with the reason. The accounts are the ones the Studio itself provisioned: the minted superadmin from the runtime secrets bundle, plus the seeder's persona roster. If the saved mesh ran Tor, a note says the node images will carry the onion too, on x86 and rpi5 node images and never on a laptop or desktop. Passwords are never read; imported user rows carry no secret. Accounts created interactively after go-live are not listed and need not be. They live in the mesh's identity tier and stay valid once the node images join the same domain.

Then it asks for consent, as an inline checkbox: *"I understand: k8s will stop to proceed — the local Kubernetes (DevOps) stack must come down before these node images are configured and built."* With a cluster actually up, ticking it arms **Stop Kubernetes now**, which runs `make kind-down` on a worker thread with streamed output and Cancel. That deletes the DevOps lane only; the docker mesh and every one of its volumes are untouched. With nothing running, the button stays greyed and the line under it says there is nothing to stop.

### Stopping the DevOps lane without deleting it

`make kind-down` is the **destructive** control. It deletes the kind cluster and everything in it, and the next bring-up is a full one that comes back empty. To stop the lane without deleting it, use the halt instead:

| command | what it does |
|---|---|
| `make kind-halt` | Suspends ArgoCD auto-sync on the Applications it records, then scales the mesh workloads to 0. Writes what it changed to the `hugmesh-kind-halt` ConfigMap in the ArgoCD namespace, so the undo does not depend on the Studio still running. Auto-sync must be suspended as well as the workloads scaled — `prune + selfHeal` would otherwise scale everything straight back and the button would be a lie. |
| `make kind-halt-status` | Read-only. Says whether the lane is halted, what it suspended, and the sync/health each Application was in at the moment it froze. Refuses rather than guessing if the record cannot be read. |
| `make kind-resume` | Restores exactly the replica counts and the auto-sync the halt recorded — not "everything", so an Application suspended for some other reason stays suspended. |

**Some pods keep running after a halt, by design.** A halt never touches DaemonSets (`kindnet`, `kube-proxy`, `local-path-provisioner`, the internal ingress controller) or the static control-plane pods the node owns (`etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`). Stopping those would delete the cluster, not halt it. A halted lane therefore shows a handful of Running pods and no mesh workloads.

Next stays disabled until three things hold: the box is ticked, no teardown is in flight, and no cluster is still known to be up. After a teardown the page re-probes and does not trust the exit status, because `kind delete cluster` exits 0 for a cluster that was never there, and a failed or cancelled run can leave one half gone. The consent box is cleared again on every entry.

On Next the page commits the mesh chain itself: `cfg.mode = "mesh"`, the mesh default role if the current one does not belong, source bundling off, mesh defaults applied. Then it installs the abbreviation: the worklist offers only `laptop` plus every node-class mesh role (`pki`, `backend`, `frontend`, `backend-gpu`, `omnibus`, `edge-ai`). The person-desktop variants are withdrawn, because a local cloud's devices are its nodes plus your laptop. Any later Mode choice lifts the restriction.

The import runs once per entry, so edits you make later, such as the cluster domain on the Network step, survive when the Build screen re-collects every visited page. Imported superadmins land on the Tailscale root domain and everyone else on the imported apex. The Users table is made reachable so you can see and edit them. The import carries every Casdoor grant the table knows (`ROLE_SUPERADMIN`, `ROLE_ADMIN`, `ROLE_MOD`, `ROLE_USER`, `ROLE_GAMES`, `ROLE_GAMES_SERVICES`) into the row's roles. A persona with none of them imports as `user`.

Trap: this is the only card that both takes something down and changes the mode. If you Back out before pressing Next, nothing is committed to the config, but the cluster you stopped stays stopped.

### Identity provider

Not a side-flow. This is a regular flow page, and it is **mesh-only**. The standalone and desktop-client flows skip it outright, so their configuration and emitted arguments are identical to a build made before the page existed. In a mesh run it comes early: the first configuration screen after the mode and side-flow screens. Mesh mode skips the single-image role step, so the worklist follows it.

Four cards: **Casdoor (built-in) — default**, Azure Entra ID, AWS Cognito, Other OIDC provider.

Clicking Casdoor proceeds at once. It commits `idp="casdoor"` and clears the three external fields, so typing values and then changing your mind leaves no residue.

Clicking an external provider opens a separate configuration window with three pages: a "before you start" page listing the console work you do yourself at that vendor, an endpoints page (issuer URL, client id, optional JWKS override), and a review page. The window makes no network calls and holds no cloud credentials. It records the values. It does not create your Entra app registration or your Cognito user pool.

Back on the page you get a read-only echo of what the window produced, a "Configure provider…" button to reopen it, and a preview of the JWKS URL derived when you leave the override empty (Entra: `<issuer>/discovery/v2.0/keys`; Cognito: `<issuer>/.well-known/jwks.json`; other: `<issuer>/.well-known/jwks`).

Next follows the same fail-closed rule the build enforces: an `https://` issuer that byte-matches the `iss` claim your provider actually mints, and a client id. Client *secrets* are never entered here, never baked, and never on any argv.

Downstream, external mode bakes `/etc/hugmesh/idp.conf`, rewrites the baked cluster tree's issuer and JWKS pins to your provider, and gates the built-in Casdoor apps out of the image. Services then validate tokens your IdP minted.

Read the page's honesty note before you choose one. External mode re-points token **validation** and nothing more. The native first-party `/bff/login` page, MFA step-up stamping, the roles/permissions/groups token model behind the headscale, Harbor and desktop-sudo gates, the signup gate and the role-sync jobs all stay Casdoor-only until the service repos grow per-provider support. Entra also mints pairwise per-app `sub` values and per-resource audiences. Cognito carries groups in the `cognito:groups` claim, which the platform's role gates do not read.

Sensible default: Casdoor, unless you already run an identity provider this mesh must trust.

## Shaping the mesh

These nine screens are where you say what gets built and what it runs. The card you picked on the mode screen decides which of them you see. The mode screen offers ten cards, but only three commit an image mode — **Standalone Gentoo desktop** (`standalone`), **Mesh desktop client** (`cloud`) and **Mesh node** (`mesh`) — and that mode keys the page flow. **Create nodes for local cloud** commits nothing at the mode screen. Its own gate page commits `mesh` and then restricts the image list to the laptop and cluster-node roles, so it walks an abbreviated version of the mesh flow described below.

Every claim here is read off the wizard in `studio/hugmesh_studio/gui/`.

### Target machine & image type — standalone and cloud

Skipped in mesh. Mesh picks role and platform on the worklist screen instead.

You pick three things, top to bottom. First the **architecture** (x86-64, ARM64, ARMv7, RISC-V 64). Then a **device** from a searchable tree grouped by vendor family: 51 devices across 11 families today, with a Status column. Then the **image type**, a list of only the roles that device supports in the mode you are in.

The catalogue is honest rather than tidy. Unsupported devices are listed with the reason they cannot be built, and you cannot select them. 27 of the 51 are in that state, including everything under ARMv7 and RISC-V. A device that is buildable but has no image type in *this* mode is also unselectable, with an inline note saying which path does offer it. Search matches the device name, its SoC, and its family or vendor.

Underneath, only the knobs the chosen platform has appear:

- La Frite: board, flavor and desktop.
- Jetson: board plus kernel flavor.
- Raspberry Pi family: board.
- Orange Pi 5: board and flavor.
- Each of the other Orange Pi boards (Zero 2, Zero 2W, Zero 3, 3 LTS, 4 LTS): flavor alone.

Every La Frite and Orange Pi box also carries U-Boot URL, defconfig and skip rows. They are flashability-critical on La Frite and Orange Pi 5, and an optional convenience on the rest. The Raspberry Pi and Jetson boxes carry none.

On x86 you also get **Client desktop options** (desktop weight, Steam delivery, the Sunshine stream host, `--capable`, `--unaffiliated`) and the **Machine profile** preset. Some of those hide where the role has already answered them. `--capable` and the desktop-weight row hide on the standalone roles whose builder arm sets them. Sunshine hides in standalone mode, which has no tailnet for it. The `--unaffiliated` box hides on the `standalone-unaffiliated` role, which already is that, and greys out with a reason in cloud mode. A separate **Image posture** box carries `--standalone`. It appears only where that flag is in scope for the role and platform you selected.

Sensible defaults: leave the machine profile at "(none / generic)", desktop weight and Steam at "(default)", and the U-Boot rows empty. Standalone opens on `standalone-thick`, cloud on `desktop`.

Downstream, this screen commits role, platform, board, flavor, desktop weight and the composable flags. The machine profile is different. It emits no flag of its own; it pre-fills the GPU driver and the Wi-Fi/Bluetooth fields that the next screen finalises. The hardware scan is not on this screen; it lives on Target hardware.

Traps worth knowing:

- Once you select a device, the board combo below becomes a read-only display of that device's board. To change the board, pick a different device row.
- Arrow-keying through the tree can land on a bold family header. That is not a device, so the image-type list empties and Next greys out. Click a device row.
- Choosing the unaffiliated role, or ticking the composable Unaffiliated box, turns off source bundling and resets the brand id, title, org, logo and lock to their defaults the moment you press Next. The look fields (theme, wallpaper and the rest) are not touched, and the Branding screen stays in the flow.
- The Jetson `l4t` kernel flavor is accepted by the plan and the matrix, but the l4t kernel build is a stub that hard-errors. Do not select it for a real build.
- Sunshine is a three-state box that starts in the middle state, which means "leave the builder default". Checked bakes it. Unchecked emits the explicit off.

### Choose the images to build — mesh only

Skipped in standalone and cloud, which synthesise a single-entry worklist at build time.

This is the multi-image screen: a checkable tree of role x platform rows, grouped under the same device families, with an architecture filter and a search box above it. Each checked row becomes one image with the stable id `<role>.<platform>`. Per row you get Board, Flavor/Desktop, Encryption, Services and an auto-filled Notes column.

The button labelled **Select the required trio (pki + be + fe)** is the fast path. It checks those three rows on every architecture the filter admits, so with the filter on "All architectures" you get the trio on x86 and on arm64. It is additive and never unchecks a GPU or edge row you already picked. GPU and edge-AI nodes can wait: build them here, or later from a saved config.

Encryption is per node. "default" inherits the choice made on the Home step; on/off force it for that row. Jetson rows show a disabled "off" because that builder cannot encrypt. The Services column is the one per-node service knob in the wizard: a Tor onion on x86; Tor, an egress VPN, or both on rpi5; and no combo at all on platforms whose builder can express neither.

A fresh mesh flow arrives with one row already checked: the mode default, `omnibus` on x86. Add to it; it is not a placeholder.

Checking a desktop-class row asks who uses it. The dialog opens when you tick the row with the mouse. A programmatic check, such as a loaded worklist re-seeding the tree, never opens it. The named people appear in a **Desktop users** table below the tree, and double-clicking a row there edits one. Cancelling the dialog unchecks the row. Next stays disabled until every checked desktop has a named user, and the placeholder row shows in red until it does. That account is created on the internal Tailscale root domain, and the person's role rides the image. The dialog asks for the person's tier (`user`, `mod`, `admin`, `superadmin`) and any grants (`games`, `games-services`). The tier is what `--person-role` bakes into the image. The grants ride only the manifest account, which holds the tier plus every ticked grant, and the **Desktop users** table lists the full set.

Two things a survey of this page usually misses. First, a checkbox reads "Also list the 37 devices that cannot be mesh nodes". It is off by default, and it brings back read-only rows that explain why each device has nothing to build here. Second, the combos in this tree ignore the scroll wheel on purpose. A plain combo would change a board or an encryption setting under the cursor while you scrolled the table, which is how one node once shipped with the wrong board.

Downstream, the worklist stamps the base config's role from the first checked row and pins its platform to x86 as the option superset, so later screens show the widest field set. Unchecking a row also removes its id from every domain's "Applies to" list.

### Target hardware — standalone and cloud

Skipped in mesh, where per-image hardware comes from the worklist row.

Tuning, not machine selection. **Scan THIS machine** autofills from the machine running Studio, not from the target. It fills in the GPU driver and the radio boxes. The page then offers: the GPU driver combo with the builder's full matrix (`auto` by default), a CUDA toolkit checkbox, Enable Wi-Fi and Enable Bluetooth (both off by default, deliberately hardened), "compile most everything into the kernel", and an advanced ARM overrides group holding CPU, defconfig, DTB, DTB prefix, kernel image and PCIe Gen3.

The ARM group is hidden entirely on x86. The GPU driver, CUDA and kernel-builtin controls are x86-only flags and grey out on ARM. Anything greyed is reset to its default when you press Next, so a value set under another platform does not linger.

The CUDA box greys out and clears under a GPU driver that contradicts it, because the builder hard-errors on that pair. Leave the driver at `auto` if you want CUDA implied.

### Branding

At the top sits the **superbrand drop-down** (Create a new superbrand first and selected; an existing design or profile shows a summary with a **Change it** click), with the design opening under it. It is the same drop-down and design the Docker mesh route shows on *Environment and brand*. The design's look is not edited here: one line points at the Look tab of the mesh's own domain on the Domain services step.

Shown in every mode. An unaffiliated image (the `standalone-unaffiliated` role, or the composable unaffiliated flag) keeps the screen, but two brand-identity widgets, the brand logo row and the branding lock, are hidden and cleared. A logo and a lock are a brand's marks, and the builder refuses them on that image. The look stays yours: themes, wallpaper, GRUB screens, login background, accent colour and colour scheme. The builder bakes them under neutral names. The page drops out of the flow only for an unaffiliated image with no desktop half to theme.

Two surfaces with opposite scopes.

**Desktop theme** is baked into the image. It is a top-level either/or between two cards: a premade theme, or custom branding. The premade set is closed and has exactly four themes: light, dark, purple, grey. Each is a card with a preview swatch painted from the same numbers that generated the wallpaper. A fifth card, "No premade theme", is the default and ships the stock look. Nothing is appended to that list. Custom branding is eight fields: branding directory, wallpaper, GRUB background, GRUB theme directory, login background, brand logo, colour scheme file, accent colour (seven on an unaffiliated image, which has no logo). The brand lock sits outside the either/or and applies to whichever channel you chose.

Clearing enforces the either/or. Switching to Custom clears your theme selection. Switching back to Premade clears all eight paths. Decide which channel you want before you start typing. A saved config that carries both keeps the custom assets and clears the theme, with a note saying so. A saved config naming a theme this generator does not ship is cleared too, with a note, because that name would hard-error the builder.

The desktop half greys off-x86 and on node-class images, with the reason shown. In mesh it is hidden outright when the worklist has no desktop entry, since there would be nothing to theme. In each of those cases the branding fields are blanked on Next.

**Web login theme** is no longer on this screen (2026-10-21, the operator: "the theme selection should be there instead of where it is now"). It is chosen on the **Look** tab of the mesh's own domain, the first page of the Domain services step, over the same `login_*` configuration fields, so a saved configuration loads as it did. On a mesh this screen shows one line saying where it went. Everything the old section did is on that tab: presets, a primary and a secondary colour, a dark or light ramp with text auto-adjusted to WCAG AA, a font preset or an uploaded font (with licence and source), header and footer chrome, the background effect, shape, decoration, the two pictures and a browser preview. It applies at container start and needs no image rebuild.

### Domain, Mesh, and Services — every mode

This screen is never skipped; only its contents are mode-gated. In standalone it is titled "Network Identity, Egress, and Security"; in cloud and mesh, "Domain, Mesh, and Services". Sections are collapsible, and the Security Stack section folds itself away when everything in it is at its default. Every field carries a tooltip saying what it is and which builder flag it becomes. The tooltip hangs on the row, so hovering the caption works as well as hovering the field. A greyed or hidden control shows the reason it is unavailable instead.

**Identity & Domain** carries the brand profile file, brand id, brand title, org, the public apex domain, the games domain and the release state. Two of its groups hide where they mean nothing. The apex domain, games domain and release state show only for cloud and mesh, or on an ARM platform; a standalone x86 image bakes no cluster plane. The brand profile, brand id, title and org hide on an unaffiliated image. When both groups hide, the whole section goes. Blank fields are not left blank: on Next the brand id commits `hugmesh`, the brand title `HugMesh Systems`, the org `hugmesh` and the public apex `hugmesh.net`. Release state at "default" emits nothing, which is not the same as "internal". With no `--release-state` on the argv, the value falls to whatever `RELEASE_STATE` a `-C` brand profile sets, and only then to the builders' own default of `internal`.

**Tailnet + SSO** is editable only for a cloud desktop client, where both boxes arrive checked. Standalone and mesh hide it and show a grey line saying why. Mesh forces both on elsewhere, off-screen.

**Headscale / Mesh Networking** shows for cloud and mesh: the Headscale URL (delivered as an environment variable, not a flag), agent version pins, the headscale-only posture, and the **Tailscale root domain** (`--superdomain`; called the orchestration superdomain before this section was renamed). It is editable in mesh and read-only in cloud, where it shows the derived `<brand>.internal`. It is baked twice: as headscale's MagicDNS `base_domain`, and to `/etc/hugmesh/superdomain`, the domain superadmin accounts are created on. It is permanently internal and is never the public apex above it.

**Egress VPN** is a profile file plus a lock for managed nodes. The whole section is hidden on node-class images, because a node would otherwise pay for VPN packages and a kernel fragment it can never use.

**Security Stack** holds the proxy stack (auto by default), Snort (on by default), AIDE, and root SSH login, which defaults to `no`. The section folds away when all four are at their defaults.

**Services & Apps** is one table. Rows are services. Columns are On, Hosting/Mode, Setting, and a plain sentence saying what enabling that row does. The groups are Social & Community (akkoma, tuwunel, phpbb), Media & Play (owncast, tube, games), Characters & Avatars (character-studio, character-forge, edge-ai-tts), Network & Access (egress-vpn, workloadConsole), Privacy Services (tor, anubis, media-poisoner), plus AI & Inference and Backing Services. The privacy group is not called "anti-scraping" because this page does not decide anubis alone. Ticking its row installs it on any build, but leaving it alone still turns its proof-of-work gate on for every `prod` build, and the builder refuses `--exclude-services` for it by name. Which rows appear depends on what the selected platform's builder can parse; a row it cannot express is hidden, not greyed. The infra rows `egress-vpn`, `workloadConsole` and `anubis` appear only on rpi5, the one platform whose `--optional-services` catalogue carries them. Tor's x86 row appears only on a cloud or mesh build. AI & inference and Backing services appear only for cloud and mesh. Backing-service rows offer self-hosted, which is the default, or a managed hosted endpoint. Tier-3 services are listed read-only with the reason they are refused in v1.

Traps here are worth reading twice:

- **Ticking replaces, it does not add.** `--optional-services` overrides the built-in set outright. The builders' own defaults (akkoma, tuwunel, phpbb) therefore arrive ticked, and unticking one removes it.
- So unticking every offered row is a real answer, and it commits an explicit "none", not silence.
- The Selection dropdown above the table holds two whole-set shortcuts beside the default "pick individually". "Every user-level service" is not the same as ticking every row. It expands a fixed set that excludes the infra services. Every row it decides is set to the state it produces and then locked (user-level rows ticked, an infra slug row unticked), so you can see what it builds.
- **Services are mesh-wide.** They are baked into the cluster GitOps tree every node shares. The only per-node service choice is the Services column on the worklist screen.
- On a client or desktop role the builders accept these selections and then ignore them, because a desktop bakes no cluster tree. The page says so in an orange note and does not grey the controls.
- On an unaffiliated image the whole services table is hidden instead, and its values are cleared, so hiding it changes no build.
- The media cloak (`media-poisoner`) is listed in the service groups, but no builder flag or slug reaches it, so its row never appears on this screen. It exists only on the local Docker mesh surface.

There is no "exclude services" field any more; ticking what you want is the subtraction. The flag itself still exists for brand profiles.

### Load your admin config (key-zip or link) — cloud and mesh

Skipped in standalone, which has no admin plane. Always shown in the other two.

Two equivalent ways in. Browse to the key-zip your admin generated and press **Import & apply**, or paste their remote-config link and press **Fetch from link…**. Both use the same extract-and-apply path, so a fetched link behaves exactly like a browsed file. On the cloud path this is what lets the desktop join an existing mesh. On the mesh path it carries the fleet Secure-Boot signing key.

A third control, off by default, remembers loginable roles from the key-zip for passwordless login. Know what it does before you tick it: it writes real login credentials to `~/.config/hugmesh-studio/local-login/roles.json` at mode 0600. It never writes database passwords or other machine secrets.

Traps: the import happens when you press the button, not when you press Next. Nothing on this screen is required, and Next is always enabled, so it is easy to walk past without importing anything. Only `http`, `https` and `file` links are followed. Anything else is refused before a connection is attempted, and nothing is contacted until you click Fetch. A fetch runs off the GUI thread and gives up after 60 seconds of silence from the server, so a wedged link cannot freeze the window.

### Domains — mesh only

Skipped in standalone and cloud. A cloud client's single domain is the tie its image is built around, not an "additional" domain. That flow keeps its table unconditionally and never sees this screen.

Two cards. **Just this mesh's own domain** is the default, and its description names the real values: the cluster domain you set on the network screen, and the Tailscale root domain every node joins. **Add more domains** opens the table.

One trap, and it is destructive. Choosing the default card clears the domains list. Rows you typed before you changed your mind are dropped, not hidden, because a skipped table must leave nothing behind for the mesh manifest to publish.

### Domains & their services

Skipped in standalone. In mesh it appears only if you chose "Add more domains" on the previous screen. In cloud it appears unless the role is one of the x86 cluster-node roles (`pki`, `backend`, `frontend`, `backend-gpu`, `omnibus`, `edge-ai`). The cloud picker offers none of them, so in practice it always appears there, unless a loaded config carries one.

Each row is a domain: **Domain**, **Title**, **Optional services**, **Applies to**, **Sign-in**, **Base CA** and **GitHub org**. Applies to, Sign-in and Base CA are mesh-only and hidden in cloud. In mesh, row 0 is the mesh's own domain, display-only except for its GitHub org cell. Its name and title are fixed because other steps own them. Its Applies to, Sign-in and Base CA cells read "All images (this mesh's own domain)", "Superdomain Casdoor (the mesh's central one)" and "Mesh default". It is never removable, never a `--domains` element, and never in the saved `domains` list. Its services summary mirrors what the *Domain services* step recorded for it.

"GitHub org" is optional and empty by default: the slug of the GitHub organisation the Go-Live wizard's *Export to GitHub org* step exports this domain's repositories to (e.g. `exampleorg`; letters, digits and single hyphens, at most 39 characters). A slug only, never a token: the export signs in as you at run time. A value that is not a slug is refused on Next, inline, and the typed text stays in the cell. An added row saves it as `domains[].github_org`, the own domain as `cluster_domain_github_org`, both omitted while empty, so an untouched configuration keeps its bytes. The text-mode step takes `o NUMBER ORG` (`o own ORG` for the mesh's own domain, `o NUMBER -` to clear). The step itself is described in [`GOLIVE-ORG-EXPORT.md`](GOLIVE-ORG-EXPORT.md). In cloud, a note says that a client image carries no CA of its own: at first boot `keys-provision` imports every `*.crt` and `*.pem` in the KEYS stick's `certs/` folder into the system trust store.

"Title" is the domain's display name. The column header says where it is read: it is written to the mesh manifest as `domains[].title`, for cluster provisioning to pick up when it sets up the domain. A cloud build emits it nowhere. Leave it empty and the domain name itself is used.

"Optional services" is a **read-only** cell (`_ServicesCell`) since #495. It used to be freeform text, then a checkable menu behind a toolbutton (#227). Nothing obliged you to open that menu, so most builds never answered "what does this domain provide". The choice now lives on its own step, *Domain services* (below). That step gives every domain its own page, and the build/mesh-start gate requires it. The cell only **reports** what that step recorded, and refreshes each time the Domains table becomes the current page. It reads one of three ways. The wording is the literal string the code emits (`core.domain_services.services_summary`), not a paraphrase:

- **"not configured yet"** — nobody has walked this domain's page. Shown in the same warn colour as an unset field.
- **"not confirmed — `<slugs>`"** — a loaded config already carried slugs from before this step existed. They show, so an older manifest's data is visibly not lost. Also warn-coloured.
- Once the step has walked the domain, either **"cluster default"** (the domain records no allow-list of its own, so the cluster-wide set applies; a real, recorded answer, muted rather than warned) or the comma-joined slug list you picked there.

If a config you load carries a slug the *Domain services* catalogue does not offer, that step shows it pre-checked and labelled as carried over, so loading an older worklist never silently drops it.

This column does **not** change which services the image bakes. Those slugs are provisioning input carried in the mesh manifest for a cluster to read later. The services baked into an image come from the services step.

"Applies to" is a checkable menu of your worklist image ids. Empty means every eligible image. Node-role images take no `--domains` at all. The attachment is manifest and provisioning data only, and the menu labels it as such and does not imply a flag it cannot emit. "Sign-in" chooses between the superdomain's central Casdoor, the default, and a dedicated Casdoor instance provisioned for that domain alone.

A read-only header names the Tailscale root domain. It is never a table row and is never attachable.

Traps: in mesh the table opens with only the own-domain row. Press **Add domain** for the others; the cluster-domain prefill of an editable row happens only in cloud. Row order is load-bearing: the first attached domain is the primary one. Each domain you add automatically gets its own default admin account with a generated random password, surfaced at provisioning time. You never type or store it here.

### Domain services

Skipped in standalone, which has no domains table at all. In mesh it shows on every flow, because the mesh's own domain always gets a page; it walks the own domain first, then each named row. In cloud it shows once the Domains table has at least one **named** domain, which in practice is every run: that flow's row 0 is prefilled with the cluster domain and can't be emptied the way the mesh table can. An unnamed or all-deleted domains table means nothing to configure, so the page is skipped rather than shown empty.

The operator asked for this page directly: *"for each domain, the service page needs to be config, so there's basically a service page per domain you make you have to go through before building or starting a mesh in docker or nodes."* It shows **one domain at a time**, with **Next domain** and **Back** controls. The wizard builds its pages once, before it knows how many domains there will be, so N domains do not mean N Qt pages. This one page is walked once per domain. It lands on the first domain you have not been through, and Back into it resumes where the work stopped, not at the top.

Each domain's screen has four **Brand settings** tabs, in this order: **Identity**, **Look**, **Services** (where the page opens) and **Ways to reach it**. The text screens number the same four sections.

- **Identity** mirrors the Domains table (public name, title, images, certificate authority) and **chooses the domain's sign-in**: through the mesh's sign-in (inherited, the default), its own Casdoor, or its own Azure Entra ID, AWS Cognito or other OIDC provider with a sign-in address, a client id and an optional key address. Nothing is written until the values are valid, and a refusal is said under the controls (one sign-in address can only be one brand, an address must be `https://`). Row 0 shows the mesh's own sign-in, which every domain that signs in through the mesh inherits; it is chosen on the Identity provider step.
- **Look** is the theme. On row 0 it is the mesh's own look, edited here and nowhere else, on every route. On an added domain every setting starts from row 0's and can be made the domain's own; *Use the superbrand's value* gives it back on a second click. A domain's own look shows on the Docker mesh only: when the Studio starts the mesh, it writes `tests/stack/.looks/` (one `by-host/<domain name>/` folder per domain with a look of its own) and the HTTPS front door answers that domain's `hug-theme.css` from it, by Host, so its sign-in page shows its own look. The door looks for the file on every request, so a domain added or switched to its own look shows on the next start without restarting the door, and the stack tray's Start and Stop leave the folder as the last Studio start wrote it. A look the Studio cannot write is said at the top of the run log as a `[looks]` line, and the domains then show the mesh's own look. Open it by name with `make view LANE=compose` (one row per added domain, ports 9100 and up; the plan lists them). The plain http door, Tor addresses and a domain that only inherits show the mesh's own look. On a built image and in Fleet a domain's own look is not applied yet, and its controls are drawn disabled with that sentence.
- **Ways to reach it** chooses the domain's **Tor address** (its own onion: the same choice as the Services tab's front door, kept in step), its **VPN** membership (the mesh's choice, on or off) and its **egress** (the mesh's choice, through an egress VPN with an optional provider file typed as an absolute path, or direct). VPN and egress are recorded with the domain; no start path applies them per domain yet, and the tab says so. Row 0's are the mesh's own. The internal and public names stay with the Go-Live wizard; one button opens it.

The Services tab has two tables. The top one is the optional-service catalogue the old table-cell menu offered: the eight user-level cluster services `--all-services` expands to, checkable and grouped. Each row's **Scope** column reads "Domain" in the row itself, not in a tooltip, so you see the scope without reading source. The table below it is **read-only**. It lists the four infrastructure slugs (`tor`, `egress-vpn`, `workloadConsole`, `anubis`) that are deliberately **not** checkboxes here. They belong to a node or to the cluster plane, not to a domain, so a per-domain checkbox would claim something the builders do not do. That table shows where each one is really set (the image-wide services step, plus any per-node opt-in in the worklist) and what it is doing now. It is data, not a control. A legend under both tables names all three scopes (domain, image, node) and where each is chosen.

Moving off a domain (**Next domain**, **Back**, or leaving the page) records it into `cfg.domain_services_reviewed`. An empty selection you have walked records as "cluster default". That is a real answer, and it differs from a domain nobody has walked yet. The difference drives the three-way wording in the Domains table's cell above. The mesh's own domain keeps its selection in `cfg.cluster_domain_services`, which both mesh manifests carry only when it is not empty.

**The gate.** These actions refuse outright while a domain has never been through this page. Each refusal names every domain, not just a count, and its remedy is written for where you are standing:

- **An image build** refuses for any named table row *and* for the mesh's own domain. A config loaded on the Prior-sessions screen that never opened this page does not build. The wording on the Build screen, where Back is disabled because the Review screen before it is a commit page, is: *"Cannot build these images: 2 domains have no recorded service configuration — acme.example, beta.example. Use ‘Back to the main menu’ on this screen — nothing has started and your settings are kept — then walk to the ‘Domain services’ step, where every domain has its own page. (The Back button is disabled here because the review screen before it is a commit page.)"*
- **A docker mesh start** (bring-up, and Saved meshes → Start/Restore) refuses for unwalked table rows only. The generate route has its own Domains and Domain services steps, so its remedy sends you back to those two steps; the saved-mesh door tells you to load the record into the form, walk the named domains, and start it again.
- **A previous-builds Restart** is narrower. It refuses only a configuration that already carries at least one reviewed domain (it was recorded under this feature) and has since gained a domain with none. A session saved before this page existed, or before the own domain had a page, is never punished for a question it was never asked. Its remedy points at **Redo**, which reloads the same configuration into the wizard.
- **Booting a previous build session's images** (Mesh emulation, and the QEMU device tests' existing-images arm) is narrow in the same way, and reads the session's recorded configuration. Its remedy is Redo too.
- **A Fleet build** checks the Domains and Domain services steps the Fleet window hosts, before the build script starts.

Every refusal renders as an inline label, never a modal. This page's own **Next** is never blocked; the block comes downstream, where it can be acted on.

**Honesty note**, carried over unchanged from the old control: the selection made here does not yet reach the cluster (#496) — it is provisioning input recorded for a cluster to read later, same as before.

## Building and finishing

These are the last eight screens. The first two are about accounts, the next three about what gets baked into each image (system identity, secrets store, home folder), and the last three are the review, the launch gate, and the build itself.

### Users — generated accounts, or your own

Mesh only. Standalone and the mesh desktop client never see this screen.

Two cards. The default, **Use the accounts generated with the node keys**, is rewritten from your current worklist every time you arrive, so it names the rows you actually checked. It tells you that one login, `admin`, is created on the control-plane node (the `pki` key profile, which `omnibus` and jetson `full` also map onto). Its password is random, stored salted and hashed, and never printed, and root stays locked in that key set. Every other node gets keys only, no accounts. If you have not checked a control-plane row at all, the card says so, and says that no account would be created. What you log in with is the private key written beside the hashes: `ssh -i ssh/admin_ed25519 admin@<node>`.

The card also names the folder: `<output directory>/sessions/<session id>/keys-<entry id>/`. The session id is minted when the build starts, and it appears in the `-w` path of the command on the Review screen. This happens only if **Generate node key-zips** is on at Review, which is the default.

The second card, **Name superusers and domain users myself**, opens the users table.

Trap: choosing the generated accounts clears any rows you already typed into that table. The choice is the emission guard, so a table you filled in and then abandoned cannot reach the mesh manifest.

### Superusers & domain users

The table. Each row has a Username, a Domain, a set of Roles, an Email and a Registration method.

Domain is a dropdown of the Tailscale root domain plus every name from the Domains table. Ticking `superadmin` forces the row to the Tailscale root domain and disables the dropdown. Superadmins belong to the Tailscale root domain, not a tenant one, whatever else is ticked beside it. Roles is a row of checkboxes: `superadmin`, `admin`, `mod`, `user`, `games`, `games-services`. An account may hold several at once (an `admin` who is also a `games` member, say). The highest tier ticked is the account's primary role, which is the `role` the manifest and the `--person-role` derivation read. `games` and `games-services` are grants on top of it. A row with nothing ticked is saved as `user`. Registration offers `derive`, `discord`, `gmail`, `password`. The OAuth options let the user self-register with that account at first login. `password` means one is generated and handed over at provisioning. `derive` keeps the provisioning default.

A loaded row whose domain is not defined on the Domains page is kept and flagged `(not defined)` with an orange warning. It is never silently rewritten. Rows with a blank username are dropped when you leave.

When you see it: never in standalone. In mesh, only if you chose the second card on the previous screen. That is a separate question from the domains opt-in, and either answer combines with either. In the mesh desktop client the gate is whether the image's role is one of the x86 cluster-node roles (`pki`, `backend`, `frontend`, `backend-gpu`, `omnibus`, `edge-ai`). That flow offers none of them, so in practice the table always appears there.

Downstream, these rows are provisioning data for the mesh manifest and the identity provider. In the manifest every row carries `role` (the primary) and, only when it holds more than one, `roles` (the full set). A single-role row is byte-identical to before multi-role existed. One thing can reach the build, and only on the mesh desktop client: with the account tier left on `derive`, `--person-role` falls back to the first row's highest tier. That is `user` for a row holding only games grants, because the builder accepts exactly the four tiers. A mesh build does not take it from here; there the flag comes from the person named on the worklist's own desktop row.

The terminal Studio shows the same rows, with every role listed, but does not edit them yet.

### System identity

Always shown, in every mode. Three blocks.

**Host identity** — hostname, timezone, default user. All three arrive filled in with exactly what the build would produce if you left them blank. Timezone is a dropdown over this machine's own zoneinfo database, not a text box. The default-user row is withheld on a desktop image whose builder is handed `--local-user`, because Home folder, encryption & login already asks for that account.

Hostnames are per image. A mesh worklist with several rows replaces the single Hostname row with one editor per image, each showing in grey the name that node derives when left blank. Blank keeps the derived name. The page refuses a duplicate name, a typed name equal to what a blank sibling derives, and a name the hostname allowlist rejects, all inline. A one-row worklist keeps the plain field.

Trap: on a mesh worklist whose rows derive *different* default accounts, the default-user field is deliberately left blank, and an amber note lists what each node will get. Typing a value there gives every node in the worklist the same account, overriding each board's own default. Timezone is also one value for the whole worklist.

**Who this image is for** — the account tier, `--person-role`. Each option's consequence is printed under the picker. The tier is stamped into `/etc/hugmesh/identity-role` and into the artifact filename, so you can tell whose device an image is. Nothing in the shipped first-boot provisioning reads that marker yet. One tier does change the build: `superadmin` makes the device demand a separate device password at first boot, taken from a salted and hashed value on the KEYS USB.

The whole group is hidden wherever the builder would discard the flag: standalone always, unaffiliated images, and cluster-node roles. The picker itself greys out on the ARM platforms, whose builders take no such flag. In mesh the page tests the *first checked worklist row*, so a worklist led by a node row hides the picker even if a laptop row follows it.

**Node fallback login** — off by default. The two password fields do not exist on screen until you tick it. Un-ticking wipes them, and nothing is collected unless the box is ticked. The group appears only when some image in this flow is a node-class role on x86; a desktop image logs in with the account from the next step. These passwords are hashed at build time and never written to a saved config, so a reloaded config always comes back un-opted-in.

### Secrets store — mesh only

This is where this mesh's nodes fetch their cluster secrets at first boot, and where you list the base CA certificates its domains chain to. Two groups.

The first is HashiCorp Vault. It has an **internal** address (the one a node reaches Vault at from inside the mesh; this is the field that was always here, with the same config key and the same flag) and an optional **external** address for the same Vault as reached from outside it.

- The internal address is the whole decision. Empty emits no flag, so a config that never saw this page and one that left it blank build the same bytes. What an absent flag means is the builder's own rule, as for every other knob (built-in < env < brand.conf < CLI). A brand profile's `VAULT_ADDR` still applies, and with none set nothing is baked and secrets come off the KEYS stick's `vault/secrets.json` bundle.
- The external address means something only once an internal one is set. Typing it alone is refused inline, and clearing the internal address clears it too. It must also be `https://` and must differ from the internal one: one Vault reached at one address needs no split, and two identical entries are a copy/paste, not a decision.

**There is no KV-mount or base-path field, and there are no such flags** (issue #285; decision 22 on #347, operator 2026-09-16 *"A: drop both controls"*). The page carried both until 2026-09-16. The Studio validated them, passed them as `--vault-kv-mount` / `--vault-base-path`, baked them into `vault.conf` and logged them at first boot. Nothing read them. Where the cluster reads is not a choice, and **neither half is brand-derived**:

- The mount is pinned in the shipped `specs/cluster/manifests/external-secrets/secretstore.yaml` (`path: "secret"` at the in-cluster `vault.vault.svc` server). `specs/cluster/apps/04-external-secrets-config.yaml` serves it with `automated {prune: true, selfHeal: true}`. ArgoCD re-applies it from git on every reconcile, so no image-side value and no `kubectl patch` can re-point it.
- The key prefix the ExternalSecrets read is the **literal** `hugmesh/<service>`. All 143 ExternalSecret keys under `specs/cluster` spell it out, and none templates the brand (measured 2026-09-16 and again 2026-10-07: `grep -rhao 'key: *[A-Za-z0-9_.-]*/' specs/cluster --include='*.yaml' | sort | uniq -c` prints `143 key: hugmesh/` among its lines; the other lines are Kubernetes label and taint keys).

Both builders still write the two values into `vault.conf`, now derived from `--brand`, so the first-boot log names the paths the image was built for. The base path is the brand slug because that is the **writer** side (`BASE="${BRAND:-hugmesh}"` in `scripts/gen-cluster-secrets.sh`). For a brand other than `hugmesh`, the writer and the reader therefore **disagree** today: the generator writes `secret/<brand>/…` and ESO still reads `secret/hugmesh/…`. That gap pre-dates #285, which only removed two controls that changed nothing. Closing it is its own call. A build script that still passes either flag now stops at `Unknown option`, the intended loud failure. A saved config that still carries `vault_kv_mount` / `vault_base_path` loads with the keys dropped and emits the same argv as one that never had them.

What a set address does: the x86 and rpi5 node builders take `--vault-addr [--vault-external-addr]` and bake `/etc/hugmesh/vault.conf` (0644, connection facts only) into every cluster-node image in the flow. At first boot `keys-provision` reads that file whenever the KEYS stick's `provision.json` carries no `.vault` block. It then seeds the External Secrets Operator's `vault-token` / `vault-ca` Secrets from the token on the stick. A hand-written `.vault` block always drove the same seeding, and it still wins when present. Desktop rows in a mesh worklist ignore the flag and say so in the build log. An `--unaffiliated` x86 build has no `/etc/hugmesh` tree at all and says that too.

How far each field reaches, since they used to be described as doing more than they do. The **address** is live: setting it is what makes first-boot seeding create the `vault-token` / `vault-ca` Secrets at all. The **external address** is a real flag on both node builders and is appended to `vault.conf` as `VAULT_EXTERNAL_ADDR`, so it does land in the image. But nothing reads it: `keys-provision` seeds from the internal address, and a node boots identically with and without it. It is baked for operators and out-of-cluster tooling. Leaving it empty writes no such line, so a config that never named one produces the same file it produced before the field existed. It needs the internal address: a builder handed `--vault-external-addr` with no `--vault-addr` refuses the run, and does not accept the flag and write nothing. The tooltips and the page's limits note say all of this.

**Base CA certificates** are the second group, and the weakest part of the page. Add the PEM files of the certificate authorities this mesh's domains chain to. The page checks each one as you add it and refuses a bad one with the reason printed under the list, never silently. A private key, a DER file and a plain text file are each named for what they are. How deep the check goes depends on the machine. The `-----BEGIN CERTIFICATE-----` framing and a decodable body are always verified. Where the optional `python-cryptography` package is installed (it is not in `studio/requirements.txt`), the certificate is parsed for real, so PEM framing wrapped around something that is not an X.509 certificate is refused too. That same package reads the subject and expiry shown beside the file name; without it the row says so and does not guess.

The list is **recorded only**. No builder script parses a CA flag, so nothing here copies a PEM into an image, a node's trust store or a KEYS stick, and no manifest carries it. The list exists for the per-domain **Base CA** column on the Domains step, which records which authority each domain is meant to chain to (`domain_ca` in the saved config). Removing a certificate here clears it from every domain that had picked it, so no domain can name a CA the config no longer carries. A recorded path that is not readable when you return to the page, because the file moved or its volume is not mounted, is **kept and marked**, never dropped. Opening a page must not be able to destroy a recorded list, and because nothing here reaches an image, an unreadable CA path blocks no build. Remove the row yourself if you mean to. Note the step order: Domains runs BEFORE this page. On a first pass through the wizard the column offers only "None" and says where to add certificates. Return to Domains after this step and the picker offers them.

What it never does is take a token. The Vault token and unseal key are custody material and ride the KEYS stick (`vault/token`, `vault/unseal-key`; see `keys-template/vault/README.md`). They are not a wizard field, not a flag and not a byte of any image. The address must be `https://`; anything else greys Next with the reason printed under the fields. The group greys out when no image in the flow can take the flag (a worklist of only jetson or Orange Pi rows), and names the row that cannot.

The TUI has the same step and refuses the same inputs with the same sentence. Its keys: `a URL` (internal), `x URL` (external), `m NAME`, `p PATH`, `c PATH` to add a base CA certificate, `r NUMBER` to remove one, and Enter to continue. Its Domains step takes `b DOMAIN-NUMBER CERT-NUMBER` for the per-domain choice.

### Home folder, encryption & login

Always shown. The window title reads "Home Folder, Encryption, and Login". Four groups, three of them conditional.

**Home provisioning** — home mode (`create` a fresh home, `adopt` one already on the target, `archive` to bake a tarball into the image, `restore` from a backup; the page explains each), home device, home backup, per-user eCryptfs home on top of the LUKS root, seed stack code, and the archive/seed extras. **Copy This Machine's Home Folder…** is a preset: it selects `archive` mode and points you at the tarball and package-list fields. It copies nothing and runs nothing.

**External media-data device** — the Steam library and gocryptfs Vaults set. x86 only.

**Your login** — the local user and password for a desktop image.

Trap for all three: they are desktop surfaces, and the test is *every* image in the flow, not any. One node row in a mesh worklist takes all three off the screen, and the home fields are reset to their defaults on the way out. That is deliberate. The mesh base is copied onto every entry, so a desktop password offered because one row could use it would be baked into all of them.

**Root-disk encryption** is checked and disabled. It is a statement, not a choice: every image the Studio builds encrypts its installed root with LUKS2. The one exception is jetson, whose builder has no FDE path; there the box is replaced by a plain explanation. The page prints two consequences. On x86 the build also produces an installer ISO, because the installer is what creates the encrypted root. If you leave the LUKS passphrase blank, the installer asks for one interactively, which stalls an unattended fleet install. On ARM rows an encrypted root also pulls in the arm64 cross-dracut initramfs. If this host cannot supply it, the builder exits 1 at its own preflight, before any work happens. Whenever the flow carries such a row, an amber note names the affected rows and says whether this host's `qemu-aarch64` binfmt registration will satisfy it.

Two unlock factors are offered, keyfile and YubiKey. Each offers `(off)`, `boot`, and, on desktop images only, `login`. Both rows are x86-only. Read the keyfile tooltip before you choose `boot`. The build generates a random keyfile, the installer enrolls it as a second keyslot and places it on the ESP, and the ESP is unencrypted, so a stolen whole disk auto-unlocks. A recovery copy lands in the work dir.

### Review

Nothing starts here. Leaving this page commits the worklist and advances to the launch screen. The button says **Continue**. While the preflight probe runs, it reads *Checking Docker…* and stays disabled.

A plain-language summary sits at the top: how many images and which, the output directory, the backend, `--env`, parallel jobs, the artifact set, the encryption consequence, and, in mesh, whether node key folders will be generated. Below it are collapsible sections, plus the device table, which is deliberately not one of them: a hardware scan should not hide behind a closed header.

- **Build execution** — backend (`auto`, `native`, `docker`), `--env` (`test` or `prod`), output directory, parallel jobs. All four explain themselves on hover, and the explanations are worth reading. `auto` resolves to `native` only on a Gentoo host with bash, and to Docker otherwise. `--env` is *baked* into the image at `/etc/hugmesh/env` and decides which ArgoCD apps survive in it, so it is a decision about the shipped system, not about this build run. The output directory is the builder's `-w`, under which each dispatch gets its own `sessions/<session id>/`. The jobs default comes from this host's cores and available memory, not a fixed number (`HUGMESH_BUILD_JOBS` overrides it).
- **Mesh worklist** — one row per image with a facts summary, a per-image **Packages…** dialog, and **Show command**, which renders that row's exact builder command into a captioned pane directly under the table. It does not move the page or unfold anything; the page-wide *Exact builder command* fold below always holds the whole-config argv. **Generate node key-zips after each successful node build** is on by default. Turning it off means no key folders and no generated accounts.
- **Image options** — installer front-end, root image size, `--grow`, version stamp, release tag, and, outside mesh, the single-image **Packages…** button. On an x86 node the installer front-end is greyed with the reason: a node cannot build the graphical front-end, and the combo reports what the build will use and offers no choice. Root image size `0` means the role default. An explicit size below the role's measured floor is refused here, on Continue, with an inline error; otherwise it would abort hours later in the image pre-flight.
- **Artifacts & build options** — each row pairs an option with the artifact it yields. The rows are: root image; live ISO with its two modifiers (embedded binpkg cache/distfiles, and a copy-to-RAM boot entry); installer ISO; the two rpi5-only rows (installer ISO for an unencrypted image, SD-card image only); rootfs tar; source bundling; compress (with an xz preset dropdown, 0 to 9, greyed while compress is unticked); resume; skip the ISO stage; and image-only. Trap: **Resume is on by default**, so a build continues from whatever sysroot the last run left behind. Untick it for a guaranteed clean build. Source bundling is disabled, with a note, on an unaffiliated image, where it is a builder hard conflict.
- **Attached devices — flash / keys assignment** — every row defaults to `(none)`, so nothing is flashed by default. A row can be assigned as a flash target for one worklist image, or as the Keys USB, which writes through to the KEYS USB field below. The Keys USB role is offered disabled, with the reason, when the stick is not mounted or the platform's builder has no `--keys-usb` flag.
- **Secure Boot signing (x86)** — on by default with a throwaway org key. `--keys-usb` points at an *existing* fleet key directory supplying `Keys/kernel_key.{pem,der}`. This screen consumes a KEYS USB and does not create one. Browsing for the KEYS USB directory or the signing key also holds that file's content in memory for the session, so the build survives the stick being unplugged. The row shows the filename and a sha256 fingerprint. Typing a path instead of browsing does *not* hold it, and the row says so. The certificate stays a plain path because it is the public half, baked into the image for enrollment.
- **Build plumbing (advanced)** — folded unless something in it is non-default. It holds skip kernel, skip clean, distfiles cache, build subdir, seed URL, the `PENTEST=1` environment knob, the post-build QEMU device tests (available only with `--env test`), and an extra-flags box appended to the command verbatim.

The *Exact builder command (advanced)* fold sits below, showing the real per-session `-w` path. The preflight pane under it never folds, and Continue stays disabled until it is clean. **Build builder image now** appears only when the docker builder image is missing. It builds the builder, not an OS image.

This is a Qt commit page, so Back is disabled from here onward. That is why the next screen offers an explicit way out.

### Build

The launch gate. One short block states what Continue will run: the image count and ids, the backend, the output directory, whether node keys will be generated, and the ARM cross-dracut warning if an encrypted root needs it. A muted line notes that a native build needs root and will ask for your password.

Two action cards. **Continue the build** advances to the progress screen, which dispatches on arrival. **Back to the main menu** returns to the first screen with your configuration intact. At this point nothing has been dispatched, no session record exists, and nothing is written. The wizard's own Next button still works.

This page exists because the progress page starts building the moment it is reached, and Back is already disabled. It is the last place to stop.

### Building

The build runs on a worker thread, one image at a time in worklist order.

An overall bar spans the whole worklist. Under it is a drillable tree: job, then stage, then emerge group, then package. Package rows carry their own bar, their USE flags read from that package's portage log, badge columns for `USE_EXPAND`/`USE`/`KEYWORDS`/`LICENSE`, and click-to-open of that package's emerge log. A badge column appears on its own once some package supplies that flag. The **Packages ▸** control on a job row stays greyed until that job's own emerge phase begins.

Clicking any row switches the shared log pane to it. You can collapse the pane to its header or detach it into its own window; neither loses a line. The help line under it names the real log file the builder writes and gives you the `tail -F` command for it, with a Copy button, so a terminal shows the same stream.

Footer lines record the once-per-worklist steps: the mesh manifest path (written before any image is built) and one line per node key folder. **Configure view** chooses columns, and a choice made there overrides the automatic badge columns for the rest of the session. **Stop all** stops everything; to stop one image, right-click its still-running row. **Next failure** cycles through failed jobs and stages and loads each one's log slice.

The final button is **Exit**, not Finish. The build is already running, and the button only closes the Studio. It stays disabled until every row has finished, failed or stopped. Back is re-enabled at that same moment, so a failed build is not a dead end: step back to Review, fix the config, and build again.

Closing the window does not stop the build. A supervisor outside the wizard owns the run, and the tray keeps reporting it. Quitting the Studio does cancel.

After an all-ok run, any flash plan you set on the Review page runs in sequence, and each write re-checks the device's identity first. The QEMU device tests run too, if you ticked them. The **Flash to a device** panel also appears if at least one device is attached; its own Flash… button makes you type the exact device path before it erases anything. A failed run flashes nothing.

Two things to know about arriving here directly. The preflight runs again on entry, and a failure means nothing is dispatched and the page says so. And a **Restart** from the sessions screen lands straight on this page, reusing that session's recorded config and workdir. If the original run consumed a signing key held only in memory, you are prompted to re-select it, and declining aborts honestly; it does not fall back to the recorded path.

---

## Keeping this document true

It was written from `studio/hugmesh_studio/gui/pages/*.py` and checked against that source page by page. It replaces a walkthrough that had drifted badly: that one described a linear nine-page flow, which the Studio had not had for some time. The last full check was against origin/main at `cbf5d9a6` on 2026-10-07.

Two properties make drift detectable instead of silent:

- The page list here is `WIZARD_PAGE_SLUGS`, and the skip rules are `MODE_SKIPPED_PAGES`. Both are in `core/config.py`, and `wizard.py` asserts that its page constructors have not drifted from the slug list.
- Page titles and field labels quoted here come from the source, not from paraphrase, so a rename shows up as a mismatch and not as a rewording.

When you add or reorder a page, update this file in the same commit.
