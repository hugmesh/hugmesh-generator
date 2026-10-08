# Studio image-build wizard — the 4-choice → 7-step flow (v1)

> **Status: ✅ shipped in the Studio GUI.** This is the canonical reference for the
> flow-clarity redesign: the first screen offered **four** clearly-distinct choices, and
> each choice walks a clear, purpose-labelled sequence of steps. The mode menu has since
> grown to **ten cards**: the four below plus six tool cards, which
> [STUDIO-WALKTHROUGH.md](STUDIO-WALKTHROUGH.md) covers. The ncurses menu and the CLI
> still mirror the four. The **emission is unchanged** — `cfg.mode` stays
> `{standalone, cloud, mesh}`, so `to_cli_args()` / `materialize()` / the builder argv the
> build-matrix guards are byte-identical for equivalent selections. This is a UI clarity
> pass, not a build change.
>
> State key: **✅ shipped** · **🚧 in-flight** · **🔭 planned / deferred**.

The wizard lives in [`studio/hugmesh_studio/gui/`](../studio/hugmesh_studio/gui/):
the page registry + mode-gated flow are in
[`gui/wizard.py`](../studio/hugmesh_studio/gui/wizard.py); one module per page in
[`gui/pages/`](../studio/hugmesh_studio/gui/pages/). The 4-choice first screen is
[`gui/pages/mode.py`](../studio/hugmesh_studio/gui/pages/mode.py).

---

## Screen 0 — Welcome

[`welcome.py`](../studio/hugmesh_studio/gui/pages/welcome.py) — the hugmesh explainer
(with the README getting-started link) plus TWO large icon buttons (issue #50):
**Start building** (→ the mode menu below, journey-ordered) and **Review prior
sessions** (→ Screen 0b).

The third card, **Start a local mesh**, was removed on **2026-08-26**. It routed to the
same `LocalMeshPage` as the mode menu's own "Local Docker mesh" card, raising the same
transient `wiz.localmesh_selected` flag — two doors onto one flow, and one of the
duplicates behind the operator's report that the wizard "is asking same questions
seemingly multiple times". The mode menu keeps the card; welcome carries no routing
target for it, because a target for a card nobody can pick is an unreachable branch in
`nextId()`. `WelcomePage.validatePage` still lowers the flag unconditionally, so a Back
navigation out of the mode menu cannot strand a stale `True`. The TUI
(`tui/journey.py`, `WELCOME_CHOICES`/`WELCOME_TARGET`) dropped the same entry and is
parity-pinned against this page.

## Screen 0b — Prior sessions

[`sessions.py`](../studio/hugmesh_studio/gui/pages/sessions.py) — the screen the
Studio used to open on: config Load/Save, the Fleet-build entry (expert mode), and
the Previous-builds manager
([`sessions_widget.py`](../studio/hugmesh_studio/gui/pages/sessions_widget.py)).
Reached only via the Welcome card; its own Next continues into the mode menu.

## STEP 1 — What do you want to build? (the four choices)

[`mode.py`](../studio/hugmesh_studio/gui/pages/mode.py) presents **ten** cards. Four are the
original choices below: three build an image and commit `cfg.mode`; the fourth builds no
image and runs a mesh locally.

| First-screen choice | `cfg.mode` | What it is |
| --- | --- | --- |
| **Mesh node** | `mesh` | Superadmin builds the server node image(s) — PKI / backend / frontend / GPU / edge-AI — that run a mesh on dedicated hardware. |
| **Local Docker mesh** | *(none — side-flow)* | Run a mesh on THIS machine in Docker, no separate server hardware. Terminates in a **running dockerized node**, not an image. |
| **Mesh desktop client** | `cloud` | A branded desktop that JOINS an existing mesh (tailnet + SSO); loads an admin key-zip / config link. |
| **Standalone Gentoo desktop** | `standalone` | A personal hardened LUKS/SELinux desktop — or a plain UNAFFILIATED Gentoo desktop with zero HugMesh branding. No mesh, no SSO. |

The other six cards are tools. None of them commits a `cfg.mode`: **Create nodes for local
cloud** (a gate that rejoins the image flow as an abbreviated mesh wizard), **Run e2e
tests**, **Mesh emulation**, **Cloud deploy**, **MDM phone** and **MDM Quest headset**.

**The Local Docker mesh choice is a first-class, functional choice** — not a stub. It
builds no image. Next flows into
[`gui/pages/localmesh_choice.py`](../studio/hugmesh_studio/gui/pages/localmesh_choice.py),
which offers two cards: **Join an existing mesh with a key** (the default) and **Generate a
new mesh**. Both branches end the path, so their final button reads **Exit**, not Finish —
see `_widgets.label_finish_as_exit`. The old inline **"Configure & run local mesh…"** popout
launcher is gone; `LocalMeshDialog` survives only as a standalone-host shim around the same
[`gui/pages/localmesh.py`](../studio/hugmesh_studio/gui/pages/localmesh.py) `LocalMeshPage`.

- **Join** drives [`core/local_mesh.py`](../studio/hugmesh_studio/core/local_mesh.py)
  `LocalMeshNode`, a thin subclass of the tray's
  [`core/mesh_node.py`](../studio/hugmesh_studio/core/mesh_node.py) `MeshNode`. The
  wizard's "run a node here" and the tray's "run a node here" share **one** docker-compose
  lifecycle. The operator supplies a tailnet/headscale auth key (`TS_AUTHKEY`, required), an
  optional node name, and an optional self-hosted headscale login-server URL; the node joins
  the mesh and serves locally.
- **Generate** walks nine bring-up steps and mints every credential itself. The steps are
  listed in the per-path sequences below.

Neither branch commits anything to `cfg.mode` or emits anything into any builder argv.

---

## The 7 conceptual steps vs the physical pages

The user-facing spec is a **7-step** shape. Because the SAME physical page serves a
different conceptual step depending on the path, the pages carry **descriptive titles**
(not hard `STEP N` numbers — those were removed in this pass because they read
non-monotonically across a path). The conceptual steps:

| # | Conceptual step | Realised by |
| --- | --- | --- |
| 1 | Choose what to build (4 choices) | `mode.py` |
| 2 | Pick the target MACHINE, then the image type / per-node hardware | `role.py` (image paths — **arch-first**: architecture selector → family-grouped searchable device browser (status badges) → the device's derived image-type list → inline board/flavor + the x86 machine-profile preset) · `worklist.py` (mesh: one row per node, with a per-row Encryption column) · `hardware.py` (GPU/Wi-Fi/kernel TUNING + this-machine scan) |
| 3 | Optional cluster services | the services group on `network.py` (mesh/cloud) |
| 4 | The domain joined + tailnet/SSO login + first-login registration | `network.py` (cloud) · `users.py` (per-user registration method) |
| 5 | The Tailscale root domain + the other domains | the Headscale / mesh-networking group on `network.py` · `domains_choice.py` · `domains.py` · `domain_services.py` (each domain's services) |
| 6 | Per-domain admins + named users | `domains.py` (default admin) · `users_choice.py` · `users.py` |
| 7 | Network identity / egress / security + home / encryption / login / packages | `network.py` (standalone) · `system.py` · `vault.py` (mesh) · `home.py` |

## Per-path physical page sequence (what the user actually clicks through)

Driven by `MODE_SKIPPED_PAGES` in
[`core/config.py`](../studio/hugmesh_studio/core/config.py) and `StudioWizard.nextId()`
in [`gui/wizard.py`](../studio/hugmesh_studio/gui/wizard.py). Only VISITED pages are
collected into `cfg`.

- **Mesh node** (`mesh`) — skips role/hardware (branding is no longer skipped: it
  also hosts the mesh web-login theme):
  `welcome → mode → idp → worklist → branding → network → keyzip → domains_choice → domains → domain_services → users_choice → users → system → vault → home → build → launch → progress`
  (`domains` shows only if the Domains choice screen asked for more domains, and `users`
  only if the Users choice screen asked to name users. `domain_services` shows on every mesh
  flow, because the mesh's own domain always gets a services page.)
- **Local Docker mesh** (side-flow) — no image build. `welcome → mode → localmesh_choice`,
  then either the **join** branch, `localmesh_join`, or the **generate** branch:
  `localmesh_env → localmesh_domains → localmesh_domain_services → localmesh_source → localmesh_services → localmesh_idp → localmesh_overlay → localmesh_review → localmesh`
  (`localmesh_overlay` is prod only. The `_LOCALMESH_STEPS` tuple in `gui/wizard.py` is the
  one place this order is declared; `LocalMeshPage` is last because it is both the
  bring-up-and-monitor step and the controller that owns every widget on the branch.
  `LocalMeshDialog` only survives as a standalone-host shim around the same page, not the
  flow's launcher. **Exit** ends the branch, `isFinalPage()`; the mesh keeps running in
  Docker after the Studio closes.)
- **Mesh desktop client** (`cloud`) — skips idp, worklist, the two choice screens and the
  secrets store:
  `welcome → mode → role → hardware → branding → network → keyzip → domains → domain_services → users → system → home → build → launch → progress`
- **Standalone Gentoo desktop** (`standalone`) — skips idp/worklist/keyzip, the whole
  domains and users group, and the secrets store:
  `welcome → mode → role → hardware → branding → network → system → home → build → launch → progress`
  **The unaffiliated role walks the identical
  sequence.** It used to be this same walk *minus* `branding`, because
  `BrandingPage.applies_to` removed the page for that role; the 2026-08-26
  identity/look split put the page back (see below), so there is no longer any
  page-level difference between an unaffiliated and a branded standalone image —
  the difference moved inside the branding screen, to two hidden identity widgets.

Any path may pass through `sessions` between `welcome` and `mode`, if the Welcome page's
second card was picked.

`ProgressPage` terminates each image path once it lands (WS-REVIEWUI).

## Duplicate-question collapse (2026-08-26)

Operator report, against session `20260826-151356-64070a`
(`role=standalone-unaffiliated`, `platform=x86`):

> "standalone menu is asking same questions seemingly multiple times when nothing
> should be an image there related to the mesh or domain at all. There should also be
> no inbetween menu for configuring domain. There should be the menu for adding the
> themes as in the branded images"

No page was ever visited twice — the repeats were the *same question asked by different
widgets on different screens*. Each was collapsed to a single asker. Every hide below is
**emission-neutral**: the widget is hidden *and* its field reset to the `ImageConfig`
dataclass default, and the gate is re-evaluated on every `initializePage` so a field that
becomes applicable again is both reachable and emitted.

| Duplicate | Kept | Removed from |
|---|---|---|
| "Identity & Domain" (apex domain / games domain / release state) | cloud + mesh, and every ARM platform | `network.py` on a standalone x86 image — the "in-between menu for configuring domain" (`cluster_identity_applies`) |
| Default account | `home.py` "Local user" | `system.py` "Default user" on desktop-class flows (`default_user_is_local_user`) |
| Machine hardware scan | `hardware.py` | the synthetic `this-machine-scan` profile row on `role.py` |
| "Themes" (web login) vs "Desktop theme" | both, retitled | the bare "Themes" label — the web group is now "Web login theme", and is mesh-only |
| "Seed stack code" | branded images | `home.py` on an unaffiliated image |
| Image posture / `--capable` / desktop weight | roles where they genuinely compose | roles whose builder arm already pins them (`role_presets_standalone` / `role_presets_capable`) |
| Sunshine | tailnet client desktops | standalone mode |
| "Unaffiliated" | the role ROW | the composable checkbox, on the `standalone-unaffiliated` role only (it stays on the other standalone roles, and greys out with a reason in cloud mode) |
| "Start a local mesh" | the mode menu | the welcome screen |

Two hides are deliberately **not** paired with a clear. `--standalone` and `--capable` on a
role whose builder arm already sets them are *redundant*, not inapplicable: the image is
byte-identical either way, and clearing would silently rewrite a loaded config on a mere
page visit. Inapplicable hides (Sunshine, the composable unaffiliated flag) do clear.

### Identity vs look on an unaffiliated image

The third ask reverses part of an earlier fix. `BrandingPage` used to delete itself for
`standalone-unaffiliated`, which was correct while *every* branding flag was a builder
hard conflict — the screen could only render greyed behind an apology note. The rule is
now split: **a brand names whose image this is; a wallpaper names nobody.**

- **Identity — still refused**: `--brand`, `--brand-title`, `--org`, `--brand-logo`,
  `--brand-locked`, and a `--config` brand profile.
- **Look — now allowed**: `--theme`, `--branding-dir`, `--wallpaper`,
  `--grub-background`, `--grub-theme`, `--login-background`, `--accent-color`,
  `--color-scheme`, baked under neutral artefact names (`/etc/gentoo/branding`,
  `/usr/sbin/branding`, `gentoo-background.png`).

So the page is back in the flow and only its two identity widgets (the brand-logo row and
"Lock branding") are hidden and cleared. `--brand-logo` stays on the identity side because
the logo *is* the mark — the applier installs it as the greeter's default-user-image — and
because every `--theme` preset ships one, the unaffiliated bake removes `logo.png` from the
assembled brand dir so the conflict cannot be walked around through a preset.

## What got clearer in this pass

- The first screen presents **two** cards (was three — see Screen 0). The mode menu it
  opens presents **ten** cards, four of them the original choices; the Local Docker mesh
  card is **functional** end-to-end (it was a crash-on-click dead end; its
  `LocalMeshConfig`/`LocalMeshDialog` modules now exist and are test-covered).
- The Welcome page's **Start building** card names the paths it opens: a mesh node, a local
  Docker mesh, a desktop image, MDM devices, a cloud publish and the end-to-end test suite.
  The retired "branded cloud image" wording is now "mesh desktop client".
- Hard `STEP N` numeric prefixes were dropped from the shared pages' subtitles/hints in
  favour of the descriptive titles they already carried, so the sequence no longer reads
  as `4 → 5/6 → 4/6` when the same page serves different conceptual steps per path.
- Per-user **first-login registration method** (discord / gmail / password / derive) is
  now a first-class column on `users.py`, backed by the additive `User.registration`
  manifest field (see the emission note below).

### Selection-clarity pass (`role.py` / `hardware.py` / `system.py` / `home.py` / `worklist.py`)

A GUI-only reorganisation — **emission is byte-identical** (the build-matrix `matrix.tsv`
+ TOTAL are unchanged; the `to_cli_args` golden tests stay green):

- **Machine-first single-image picker** (`role.py`). The user picks the **target machine**
  first. It is an architecture selector over a family-grouped, searchable device browser
  (see "Arch-first device taxonomy" below), not a row of platform cards as in the first cut.
  Then comes the **image type**, filtered to what that machine supports, with the
  board/flavor/desktop knobs inline underneath. The redundant standalone "Platform" combo is
  **removed**; the device **is** the platform. Chromebook stays an x86 *image type*, not its
  own device. The reachable `(role, platform)` set is the same catalog, merely pivoted, so
  `cfg.platform/role/board/flavor` are identical for the same intent.
- **Machine-profile preset folded onto the x86 machine choice** (out of `hardware.py`). The target
  machine is now defined in **one** place: the profile that seeds GPU/Wi-Fi/kernel
  defaults lives with the machine choice (x86-only — `profiles.json` is all-x86). The
  Hardware page keeps the GPU/Wi-Fi/Bluetooth/kernel **tuning** and the this-machine scan.
  `hw_profile` is `NON_ARGV` (never emitted); the gpu/wifi/bt it pre-fills are finalised on
  the Hardware page exactly as before, so the argv is unchanged.
- **Node fallback login** (`system.py`) is retitled *"Node fallback login (mesh nodes)"*
  with a clear WHAT/WHEN note, and is **hidden entirely** (not greyed) on flows where it
  is meaningless — hidden on the desktop standalone/cloud paths and on ARM. On the mesh
  flow the gate keys on the **worklist entries themselves** — shown iff *any* checked row
  is a node-class role on the x86 builder — never on the base config: the base role is
  just the *first* checked row (catalog order puts `rpi5-desktop` before `edge-ai`) and
  the base platform is forced `x86` for the shared option-superset pages, so a base-keyed
  gate would hide+clear creds an x86 node row still consumes (emission loss) and show
  them on an all-ARM worklist that consumes them nowhere. The creds are blanked only when
  **no** checked entry consumes them. Narrowing the widget to node-class flows is
  emission-safe (see the honest note below).
- **Standalone account & disk encryption** (`home.py`) is framed as the primary standalone
  action (retitled groups + a helper line). A device that cannot do full-disk encryption
  (jetson's single boot+root partition) **hides** the `--encrypt-root` checkbox and shows
  the reason (`luks_pass` is `_ALL_PLATFORMS` and is left untouched). This branch is dormant
  in standalone (jetson is not a standalone platform) but correct if reached.
- **Per-node encryption scoping** (`worklist.py`). The mesh worklist gains a per-row
  **Encryption** column (`default` / `on` / `off` → `WorklistEntry.encrypt_root`), so the
  previously-ambiguous "which device gets encrypted?" is answered per node; jetson rows
  show a disabled *"off — jetson cannot encrypt"* cell. A hint spells out that the
  unattended LUKS passphrase (set once on the Home step) applies to **every** encrypted node.
  The column is additive and defaults to `default` (inherit the base), so an untouched
  worklist is byte-identical to before.
- **Per-image hostname** (`system.py` / `core/worklist.py`; issue #229). System identity
  was one image-config setting even when generating several images — fine for the
  timezone and the default account, which stay mesh-wide, but a hostname shared by every
  node is a collision, not a setting. `WorklistEntry.hostname` is the per-image
  `-H/--hostname` (`""` = inherit the base, and a blank base lets the builder derive the
  role name; `materialize()` fails loudly if two images would bake the same name). Two
  collisions, both refused by `core/worklist.py::duplicate_hostnames` so all three
  channels are equally strict: two rows carrying the same **typed** name, and a typed
  name equal to what a **blank** sibling's role switch derives — the second emits one
  `--hostname` and nothing on the other row, so the argv reads clean and both nodes
  still boot as that name. Blank-vs-blank is not refused: the builder's own role tables
  assign those names and always have, so the UIs say it out loud in a note instead.
  `derived_hostname(entry, brand)` is the single implementation of "what this row bakes
  when left blank" — the GUI placeholders, the TUI *if blank* column and the model's own
  refusal all call it, so a shown name cannot disagree with a refused one.
  On the System step a **multi-row** mesh worklist withdraws the single Hostname
  row and shows one editor per image, placeholdered with the name that node derives when
  left blank; a one-row worklist keeps the plain field but writes the entry; both blank
  the base so one value can never ride onto every node again. Refusals (duplicate name,
  a name the identity allowlist rejects) are inline, never modal — and the allowlist
  check runs on **every** path through the page, the single field included, so a bad
  name is refused where it was typed instead of one page later as *"Cannot assemble the
  worklist"*. The TUI's System step
  (`tui/journey.py::SystemScreen`) hosts the same per-image table (`N NAME` / `N -`);
  headlessly it is `entries[].hostname` in the envelope, and `--print-commands` emits
  each image's own `--hostname`. An untouched worklist still emits no `--hostname`.

## Emission note — the additive manifest fields

`User.registration` (default `""` = derive) is an **additive** field on the mesh
manifest / `--print-specs` surface (design WS-E7). It is manifest-only: `User` never
reaches `to_cli_args()`, so the **builder argv is byte-identical** and the build-matrix
is unchanged. `from_dict` tolerates and round-trips it. The external cluster-provisioning
consumer of `mesh_manifest` JSON is expected to ignore unknown keys (forward-compat); if
a strict byte-identity reading of the manifest is ever required, that is the one field to
account for.

The second one is the manifest v2 image record's `hostname` (issue #229): the explicit
per-image name that build bakes (`""` = the builder derives the role name), so a
provisioning consumer can tell the nodes apart by the name each actually boots with.
Additive in the same sense — absent before, ignorable by a consumer that does not read it.

### Honest note — node fallback creds are widget-scoped, not argv-gated

`--user-password` / `--root-password` are **not** role-gated in `to_cli_args()`: an x86
desktop that *explicitly* set them today would still emit them. The selection-clarity pass
**hides** the widget on desktop flows and blanks the fields there, so a desktop image can
no longer *collect* them from the GUI. This is an intentional **clarity narrowing**, not a
silent behaviour change — "node fallback creds on a personal desktop" is not a represented
or tested intent (no golden exercises it), so scoping the widget to node-class flows is
byte-identical for every guarded case.

---

## PARITY-TODO — mirror this flow in the other generator front-ends

Like the mesh-wizard redesign's web spec, the Studio GUI is the **reference**
implementation of this flow; the other build channels must mirror the same 4-choice → 7-step
shape so a user gets the same clarity regardless of front-end. The channel map
and the all-options-in-all-menus rule are in
[`docs/BUILD-MATRIX.md`](BUILD-MATRIX.md).

**Status (2026-07-16) — most of this section has shipped.** The **ncurses menu** and
**CLI** four-choice parity, the **Local Docker mesh** face on both channels, and the
**parity-enforcement** gate all landed in
[#342](https://github.com/hugmesh/hugmesh-generator/pull/342); the ncurses
Local-mesh screen was later extended with the from-scratch bootstrapper (#346) and the
RPi/Chromebook desktop surfacing (#351). The build-matrix `TAXO` bucket
(`tests/build-matrix/check.sh` → `run_parity_taxonomy_checks`) proves all three
front-ends carry the same four golden choices — **16/16 green**, emission byte-identical
(CLI/MAKE/MENU/GUI/JOB 118 each, 0 failed). **Two items remain deferred (🔭):** the
admin web-UI modal (a cross-repo BFF concern, out of scope for the generator repo) and
the deeper ncurses **machine-first step-2 reshape** (a design-heavy TUI redesign — see
the marked bullet below). Per-subsection status is inline below:
**✅ shipped** · **🔭 planned / deferred**.

### ncurses console menu (`make menu` → `scripts/build-menu.sh`) — ✅ mostly shipped (#342/#346/#351); one 🔭 residual
- **✅ #342** Present the **same four top-level choices** as the opening screen (Mesh node /
  Local Docker mesh / Mesh desktop client / Standalone Gentoo desktop) rather than jumping
  straight into role/platform selection. — realised by `mode_screen()`, a thin clarity/router
  layer on top of the existing screens.
- **✅ #342** Route the three image choices to the existing `OPT_*` make-composition unchanged
  (emission parity is mandatory — the build-matrix MENU column guards it). — the three image
  choices funnel into `build_screen` / `single_role_screen` / `standalone_screen` verbatim;
  MENU column stays 118/0.
- **✅ #342 (+ #346)** Add a **Local Docker mesh** screen that shells the same lifecycle as the
  Studio launcher — reuse a shared entrypoint over `core/mesh_node.py`'s compose lifecycle (a
  small `hugmesh-mesh-node` helper), prompting for `TS_AUTHKEY` (masked) + optional
  node name / login-server, so the menu does not reimplement compose. — realised by
  `local_mesh_screen()` (shells `python3 -m hugmesh_studio.core.local_mesh`; masked
  auth key via `ui_password`, node name, login server, up/down/status/logs); #346 added the
  from-scratch bootstrapper sub-screen.
- **✅ #342** Drop hard step numbers in the screen headers in favour of the descriptive titles,
  same rationale as the GUI. — the menu's user-facing screen titles are descriptive
  ("What do you want to build?", etc.); the only `STEP 1` token is a source comment, not a
  header.
- **🔭 RESIDUAL (still deferred — design-heavy TUI redesign):** Mirror the Studio's
  **machine-first** step-2 shape: pick the target machine first, then
  the image type it supports (not a role list with a separate platform sub-menu), fold the
  x86 machine-profile preset in with the machine choice, and surface the mesh worklist's
  **per-node encryption** column + the "one LUKS passphrase for the whole fleet" note.
  Offer the node-fallback-login prompt with the same worklist-keyed rule (only when some
  selected image is an x86 node — never keyed to whichever image happens to be listed
  first). Emission parity is mandatory (the MENU column guards it) — this is menu shape
  only. — **NOTE:** `single_role_screen()` is already architecture-first (machine → role →
  board), so the ordering half is partly present; what is NOT done is the GUI-specific
  reshape — folding the `profiles.json` x86 machine-profile preset onto the machine choice,
  a per-node **encryption** column on a menu worklist (the menu has no per-node worklist
  table; `build_screen` offers whole-fleet targets, not a per-row table), and a
  worklist-keyed node-fallback-login prompt. These are genuine console-TUI design calls
  (how a GUI table maps onto linear `dialog`/`whiptail` menus) and should be designed
  deliberately, not guessed.

### CLI (`build-image.sh` / `make <role>`) — ✅ shipped (#342)
- **✅ #342** The CLI already emits every image path; the parity gap is **discoverability**, not
  emission. Add a short `--help` / guided preamble that frames the same four intents and
  points at the flags each maps to (`--role`/worklist for mesh node, the client SSO/keyzip
  flags for mesh desktop client, `--encrypt-root`/home flags for standalone). — realised by
  `print_intents_guide()` in `docker/build-image.sh` (fires on `-h`/`--help`/`help`; the real
  env-driven Job path is byte-identical).
- **✅ #342** Document the **Local Docker mesh** as an explicit non-build subcommand
  (e.g. `hugmesh-mesh-node up --authkey-file …`) so the CLI channel has a first-class
  face for the fourth choice instead of only the image builds. — realised by the
  `core/local_mesh.py` argparse CLI (`up`/`down`/`status`/`logs`, `--authkey-file`) and the
  Makefile `mesh-node-up` / `mesh-node-down` / `mesh-node-status` / `mesh-node-logs` targets;
  the intents guide points at both.

### Arch-first device taxonomy (ncurses + CLI) 🔭
- The Studio's step-2 machine tier is now **arch-first**: an architecture selector
  (x86-64 / ARM64 — extensible enum) over a **family-grouped, searchable device
  browser** sourced from
  [`core/device_catalog.py`](../studio/hugmesh_studio/core/device_catalog.py) +
  `core/device-catalog.json`, with the #351 honesty statuses on every row
  (SUPPORTED / EXPERIMENTAL labelled + fail-loud / UNSUPPORTED visible-but-unselectable
  with the reason shown). A device IS a `(platform, board)` pair and its roles are
  **derived** from `ROLE_CHOICES` + `rpi_boards_for_role()` — never stored, never
  invented.
- **The Next button is device-gated** (the #351 gate at the button): `isComplete()`
  and `validatePage()` both require a real, SELECTABLE catalog device to be current.
  Keyboard navigation stopping on a family **header** row, or an architecture whose
  devices are all UNSUPPORTED (ARMv7 / RISC-V today), disarms the image-type list and
  disables Next — there is **no fallback platform**, so a stale role can never pair
  with the wrong builder. Landing back on a device re-arms the list (the in-visit role
  choice is preserved).
- A committed **EXPERIMENTAL alias** (e.g. Pi 400 → the Pi 4's `(rpi5, rpi4)` axes) is
  restored **as itself** on Back-navigation — the label and fail-loud note survive the
  round-trip instead of folding to the supported sibling.
- The ncurses menu and the CLI guided help should render the **same
  arch → family → device → role hierarchy**. The machine-readable source is the
  committed web catalog's `archs` / `families` / `devices` keys
  ([`docs/catalog/image-catalog.json`](catalog/image-catalog.json), emitted by
  [`scripts/emit-image-catalog.py`](../scripts/emit-image-catalog.py) and drift-guarded
  by the build-matrix `CAT` bucket) — render from it, do not re-declare the device
  list. Emission stays byte-identical (a device only pins the `--board`/platform values
  the channels already accept; the MENU/CLI columns guard it).

### Admin web-UI generator (image-gen BFF modal) — 🔭 deferred (cross-repo; out of scope for the generator repo)
- Mirror the four choices as the top-level selector in the admin image-gen modal, exactly
  as the go-live web effector mirrors its CLI/ncurses/Studio front-ends
  ([`docs/GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md) "4-interface parity"). This surface lives
  in a different repo (the image-gen BFF), so nothing to mirror exists in this repo yet.
- The three image choices map to the same generator request the modal already emits —
  **no new build semantics**; this is a labelling/grouping change plus surfacing the
  per-user `registration` field the manifest already carries.
- **Local Docker mesh is host-local by nature** (it runs docker on the operator's
  machine): the web-UI cannot run it inside a cluster pod. Follow the go-live precedent —
  either omit it from the web selector with an explicit "use the desktop Studio / console
  for a local node" hint, or, if a hosted equivalent is ever wanted, drive it through a
  node-local reconcile agent rather than reimplementing compose in the BFF.

### Parity enforcement — ✅ shipped (#342)
- **✅ #342** Extend the build-matrix / all-menus parity checks so the **four-choice taxonomy** and
  the per-user `registration` option are asserted present in every channel that claims to
  offer them (the code-copy assertion idiom used elsewhere in
  [`docs/BUILD-MATRIX.md`](BUILD-MATRIX.md)). — realised by the `TAXO` bucket
  (`run_parity_taxonomy_checks` in `tests/build-matrix/check.sh`): 12 taxonomy assertions
  (4 `mode.py` + 4 menu + 4 cli) + 4 `registration` tokens = **16 expected**, each anchored
  **non-vacuously** to the real opening-item shape per channel (menu `ui_menu` item line;
  cli numbered intent) so dropping any choice is a genuine grep miss, not a false pass.
