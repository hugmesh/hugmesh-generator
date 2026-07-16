# Studio image-build wizard — the 4-choice → 7-step flow (v1)

> **Status: ✅ shipped in the Studio GUI.** This is the canonical reference for the
> flow-clarity redesign: the first screen offers **exactly four** clearly-distinct
> choices, and each choice walks a clear, purpose-labelled sequence of steps. The
> **emission is unchanged** — `cfg.mode` stays `{standalone, cloud, mesh}`, so
> `to_cli_args()` / `materialize()` / the builder argv the build-matrix guards are
> byte-identical for equivalent selections. This is a UI clarity pass, not a build
> change.
>
> State key: **✅ shipped** · **🚧 in-flight** · **🔭 planned / deferred**.

The wizard lives in [`studio/snapdragon_studio/gui/`](../studio/snapdragon_studio/gui/):
the page registry + mode-gated flow are in
[`gui/wizard.py`](../studio/snapdragon_studio/gui/wizard.py); one module per page in
[`gui/pages/`](../studio/snapdragon_studio/gui/pages/). The 4-choice first screen is
[`gui/pages/mode.py`](../studio/snapdragon_studio/gui/pages/mode.py).

---

## Screen 0 — Welcome

[`welcome.py`](../studio/snapdragon_studio/gui/pages/welcome.py) — the intro blurb,
config Load/Save, and the Fleet-build entry. Its subtitle names all four paths so the
first thing the user reads matches the choice screen that follows.

## STEP 1 — What do you want to build? (the four choices)

[`mode.py`](../studio/snapdragon_studio/gui/pages/mode.py) presents **exactly four**
first-screen choices. Three build an image and commit `cfg.mode`; the fourth builds no
image and runs a node locally.

| First-screen choice | `cfg.mode` | What it is |
| --- | --- | --- |
| **Mesh node** | `mesh` | Superadmin builds the server node image(s) — PKI / backend / frontend / GPU / edge-AI — that run a mesh on dedicated hardware. |
| **Local Docker mesh** | *(none — side-flow)* | Run a mesh on THIS machine in Docker, no separate server hardware. Terminates in a **running dockerized node**, not an image. |
| **Mesh desktop client** | `cloud` | A branded desktop that JOINS an existing mesh (tailnet + SSO); loads an admin key-zip / config link. |
| **Standalone Gentoo desktop** | `standalone` | A personal hardened LUKS/SELinux desktop — or a plain UNAFFILIATED Gentoo desktop with zero Snapdragon branding. No mesh, no SSO. |

**The Local Docker mesh choice is a first-class, functional choice** — not a stub. It
builds no image, so it deliberately disables Next/Finish (`isComplete()` returns
`False`) and reveals an inline **"Configure & run local mesh…"** launcher instead. The
launcher opens [`gui/pages/localmesh.py`](../studio/snapdragon_studio/gui/pages/localmesh.py)
`LocalMeshDialog`, which drives
[`core/local_mesh.py`](../studio/snapdragon_studio/core/local_mesh.py)
`LocalMeshNode` — a thin subclass of the tray's
[`core/mesh_node.py`](../studio/snapdragon_studio/core/mesh_node.py) `MeshNode`, so the
wizard's "run a node here" and the tray's "run a node here" share **one** docker-compose
lifecycle. The operator supplies a tailnet/headscale auth key (`TS_AUTHKEY`, required),
an optional node name, and an optional self-hosted headscale login-server URL; the node
joins the mesh and serves locally. It commits **nothing** to `cfg.mode` and emits nothing
into any builder argv.

---

## The 7 conceptual steps vs the physical pages

The user-facing spec is a **7-step** shape. Because the SAME physical page serves a
different conceptual step depending on the path, the pages carry **descriptive titles**
(not hard `STEP N` numbers — those were removed in this pass because they read
non-monotonically across a path). The conceptual steps:

| # | Conceptual step | Realised by |
| --- | --- | --- |
| 1 | Choose what to build (4 choices) | `mode.py` |
| 2 | Pick the target MACHINE, then the image type / per-node hardware | `role.py` (image paths — **machine-first**: machine cards → filtered image-type list → inline board/flavor + the x86 machine-profile preset) · `worklist.py` (mesh: one row per node, with a per-row Encryption column) · `hardware.py` (GPU/Wi-Fi/kernel TUNING + this-machine scan) |
| 3 | Optional cluster services | the services group on `network.py` (mesh/cloud) |
| 4 | The domain joined + tailnet/SSO login + first-login registration | `network.py` (cloud) · `users.py` (per-user registration method) |
| 5 | The orchestration superdomain + the other domains | the mesh-control-plane group on `network.py` · `domains.py` |
| 6 | Per-domain admins + named users | `domains.py` (default admin) · `users.py` |
| 7 | Network identity / egress / security + home / encryption / login / packages | `network.py` (standalone) · `system.py` · `home.py` |

## Per-path physical page sequence (what the user actually clicks through)

Driven by `MODE_SKIPPED_PAGES` in
[`core/config.py`](../studio/snapdragon_studio/core/config.py) and `StudioWizard.nextId()`
in [`gui/wizard.py`](../studio/snapdragon_studio/gui/wizard.py). Only VISITED pages are
collected into `cfg`.

- **Mesh node** (`mesh`) — skips role/hardware/branding:
  `welcome → mode → worklist → network → keyzip → domains → users → system → home → build`
- **Local Docker mesh** (side-flow) — no page walk:
  `welcome → mode →` **inline `LocalMeshDialog`** (runs the dockerized node; no image)
- **Mesh desktop client** (`cloud`) — skips worklist:
  `welcome → mode → role → hardware → branding → network → keyzip → domains → users → system → home → build`
- **Standalone Gentoo desktop** (`standalone`) — skips worklist/keyzip/domains/users:
  `welcome → mode → role → hardware → branding → network → system → home → build`

`ProgressPage` terminates each image path once it lands (WS-REVIEWUI).

## What got clearer in this pass

- The first screen presents **four** usable choices; the fourth (Local Docker mesh) is
  **functional** end-to-end (was previously a crash-on-click dead end — its
  `LocalMeshConfig`/`LocalMeshDialog` modules now exist and are test-covered).
- The Welcome subtitle names **all four** paths (dropped the retired "branded cloud
  image" wording for "mesh desktop client").
- Hard `STEP N` numeric prefixes were dropped from the shared pages' subtitles/hints in
  favour of the descriptive titles they already carried, so the sequence no longer reads
  as `4 → 5/6 → 4/6` when the same page serves different conceptual steps per path.
- Per-user **first-login registration method** (discord / gmail / password / derive) is
  now a first-class column on `users.py`, backed by the additive `User.registration`
  manifest field (see the emission note below).

### Selection-clarity pass (`role.py` / `hardware.py` / `system.py` / `home.py` / `worklist.py`)

A GUI-only reorganisation — **emission is byte-identical** (the build-matrix `matrix.tsv`
+ TOTAL are unchanged; the `to_cli_args` golden tests stay green):

- **Machine-first single-image picker** (`role.py`). The user picks the **target machine
  as a card** (the platform union of `ROLE_CHOICES[mode]` — x86 / Raspberry Pi / La Frite /
  Orange Pi 5 / Orange Pi Zero 2; jetson is mesh-only, so it gets no card here), then the
  **image type** filtered to what that machine supports, with the board/flavor/desktop
  knobs inline underneath. The redundant standalone "Platform" combo is **removed** — the
  card **is** the platform. Chromebook stays an x86 *image type*, not its own card. The
  reachable `(role, platform)` set is the same catalog, merely pivoted, so `cfg.platform/
  role/board/flavor` are identical for the same intent.
- **Machine-profile preset folded onto the x86 card** (out of `hardware.py`). The target
  machine is now defined in **one** place: the profile that seeds GPU/Wi-Fi/kernel
  defaults lives with the machine card (x86-only — `profiles.json` is all-x86). The
  Hardware page keeps the GPU/Wi-Fi/Bluetooth/kernel **tuning** and the this-machine scan.
  `hw_profile` is `NON_ARGV` (never emitted); the gpu/wifi/bt it pre-fills are finalised on
  the Hardware page exactly as before, so the argv is unchanged.
- **Node fallback login** (`system.py`) is retitled *"Node fallback login (mesh nodes)"*
  with a clear WHAT/WHEN note, and is **hidden entirely** (not greyed) on flows where it
  is meaningless — hidden on the desktop standalone/cloud paths and on ARM. On the mesh
  flow the gate keys on the **worklist entries themselves** — shown iff *any* checked row
  is a node-class role on the x86 builder — never on the base config: the base role is
  just the *first* checked row (catalog order puts `rpi5-desktop` before `edge_ai`) and
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

## Emission note — the one additive manifest field

`User.registration` (default `""` = derive) is an **additive** field on the mesh
manifest / `--print-specs` surface (design WS-E7). It is manifest-only: `User` never
reaches `to_cli_args()`, so the **builder argv is byte-identical** and the build-matrix
is unchanged. `from_dict` tolerates and round-trips it. The external cluster-provisioning
consumer of `mesh_manifest` JSON is expected to ignore unknown keys (forward-compat); if
a strict byte-identity reading of the manifest is ever required, that is the one field to
account for.

### Honest note — node fallback creds are widget-scoped, not argv-gated

`--user-password` / `--root-password` are **not** role-gated in `to_cli_args()`: an x86
desktop that *explicitly* set them today would still emit them. The selection-clarity pass
**hides** the widget on desktop flows and blanks the fields there, so a desktop image can
no longer *collect* them from the GUI. This is an intentional **clarity narrowing**, not a
silent behaviour change — "node fallback creds on a personal desktop" is not a represented
or tested intent (no golden exercises it), so scoping the widget to node-class flows is
byte-identical for every guarded case.

---

## PARITY-TODO — mirror this flow in the other generator front-ends 🔭

Like the mesh-wizard redesign's web spec, the Studio GUI is the **reference**
implementation of this flow; the other build channels must mirror the same 4-choice → 7-step
shape so a user gets the same clarity regardless of front-end. **None of these are
implemented here — this section is the spec for follow-up workstreams.** The channel map
and the all-options-in-all-menus rule are in
[`docs/BUILD-MATRIX.md`](BUILD-MATRIX.md).

### ncurses console menu (`make menu` → `scripts/build-menu.sh`) 🔭
- Present the **same four top-level choices** as the opening screen (Mesh node / Local
  Docker mesh / Mesh desktop client / Standalone Gentoo desktop) rather than jumping
  straight into role/platform selection.
- Route the three image choices to the existing `OPT_*` make-composition unchanged
  (emission parity is mandatory — the build-matrix MENU column guards it).
- Add a **Local Docker mesh** screen that shells the same lifecycle as the Studio
  launcher — reuse a shared entrypoint over `core/mesh_node.py`'s compose lifecycle (a
  small `snapdragon-mesh-node` helper), prompting for `TS_AUTHKEY` (masked) + optional
  node name / login-server, so the menu does not reimplement compose.
- Drop hard step numbers in the screen headers in favour of the descriptive titles, same
  rationale as the GUI.
- Mirror the Studio's **machine-first** step-2 shape: pick the target machine first, then
  the image type it supports (not a role list with a separate platform sub-menu), fold the
  x86 machine-profile preset in with the machine choice, and surface the mesh worklist's
  **per-node encryption** column + the "one LUKS passphrase for the whole fleet" note.
  Offer the node-fallback-login prompt with the same worklist-keyed rule (only when some
  selected image is an x86 node — never keyed to whichever image happens to be listed
  first). Emission parity is mandatory (the MENU column guards it) — this is menu shape
  only.

### CLI (`build-image.sh` / `make <role>`) 🔭
- The CLI already emits every image path; the parity gap is **discoverability**, not
  emission. Add a short `--help` / guided preamble that frames the same four intents and
  points at the flags each maps to (`--role`/worklist for mesh node, the client SSO/keyzip
  flags for mesh desktop client, `--encrypt-root`/home flags for standalone).
- Document the **Local Docker mesh** as an explicit non-build subcommand
  (e.g. `snapdragon-mesh-node up --authkey-file …`) so the CLI channel has a first-class
  face for the fourth choice instead of only the image builds.

### Admin web-UI generator (image-gen BFF modal) 🔭
- Mirror the four choices as the top-level selector in the admin image-gen modal, exactly
  as the go-live web effector mirrors its CLI/ncurses/Studio front-ends
  ([`docs/GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md) "4-interface parity").
- The three image choices map to the same generator request the modal already emits —
  **no new build semantics**; this is a labelling/grouping change plus surfacing the
  per-user `registration` field the manifest already carries.
- **Local Docker mesh is host-local by nature** (it runs docker on the operator's
  machine): the web-UI cannot run it inside a cluster pod. Follow the go-live precedent —
  either omit it from the web selector with an explicit "use the desktop Studio / console
  for a local node" hint, or, if a hosted equivalent is ever wanted, drive it through a
  node-local reconcile agent rather than reimplementing compose in the BFF.

### Parity enforcement 🔭
- Extend the build-matrix / all-menus parity checks so the **four-choice taxonomy** and
  the per-user `registration` option are asserted present in every channel that claims to
  offer them (the code-copy assertion idiom used elsewhere in
  [`docs/BUILD-MATRIX.md`](BUILD-MATRIX.md)).
