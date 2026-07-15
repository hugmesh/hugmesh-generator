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
| 2 | Pick the role / per-node hardware | `role.py` (image paths) · `worklist.py` (mesh: one row per node) · `hardware.py` |
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

## Emission note — the one additive manifest field

`User.registration` (default `""` = derive) is an **additive** field on the mesh
manifest / `--print-specs` surface (design WS-E7). It is manifest-only: `User` never
reaches `to_cli_args()`, so the **builder argv is byte-identical** and the build-matrix
is unchanged. `from_dict` tolerates and round-trips it. The external cluster-provisioning
consumer of `mesh_manifest` JSON is expected to ignore unknown keys (forward-compat); if
a strict byte-identity reading of the manifest is ever required, that is the one field to
account for.

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
