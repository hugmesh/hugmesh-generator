# XR chat — "Shadows of the Net" virtual room + the Character Forge (3D) slug

> **Status: the `character-forge` OPTIONAL service (DEFAULT-OFF, admin gate) is
> the generator-side leg of a cross-repo XR-chat track (🚧 in-flight).** A default
> build bakes NO character-forge apps and changes NOTHING: the slug must be
> explicitly selected (`--with-character-forge`, `character-forge` in
> `OPTIONAL_SERVICES`, or the `all` full set). The room/game/frontend/BFF code
> lives in the sibling repos named below — this repo only wires the platform slug
> (GitOps apps + manifests, gateway routes, route-access rows, reserved prefixes,
> build-channel parity) and documents the architecture.

## 1. What the track is

A Ghost-in-the-Shell-ep.9-style **virtual chat room**: a Godot 4 WASM scene
embedded in Matrix (tuwunel) channels and the games portal, with **3D avatars
mapped from the existing SVG VN characters** (character-studio packs), WebXR for
Meta Quest 3/3s Browser, native OpenXR for PCVR, and a **first-class no-headset
desktop mode** (keyboard/mouse + optional webcam face/lip tracking).

The pieces, by repo:

| Piece | Repo | What it is |
|---|---|---|
| **Character Forge** (3D maker) | `snapdragon-character-forge-bff-api` (DESIGN-locked name; one multi-surface repo) | Spring BFF at the root (`/bff/character-forge/**`: Char3DConfig CRUD, one-active-per-owner, cross-user lookup, VN→3D `/map`), `godot/character-forge/` (the Godot 4 maker game + the CANONICAL `character_assembler.gd`), `frontend/` (Angular native-federation remote mounted at `/character-forge`) |
| **The room** | `hugmesh.games` repo, `games/shadows-of-the-net/` | Godot WASM chat chamber; dual mode — `mode=session` (games-portal wasm-game contract) and `mode=matrix` (all I/O via the host page `Chat3D` JS bridge) |
| **Matrix integration** | `hugmesh-matrix-ui` | `systems.snapdragon.chat3d*` state events (room enable/config, scene placements, per-user avatar), room-settings section, iframe host for the room, full-mesh WebRTC audio + pose/blendshape data channels, self-hosted MediaPipe face tracking |
| **Platform slug** | THIS repo | everything in §2 |

3D realization v1 is **procedural** (parameterized primitive meshes assembled by
`character_assembler.gd` — no glTF assets), keyed off the STABLE VN
parameterization (packId / partId / headArchetype / palette regions), never SVG
geometry. The assembler's part-registry indirection leaves room for a GLB part
library later.

## 2. What THIS repo bakes — the `character-forge` slug

A MULTI-APP slug shaped like phpbb (BFF db + BFF api + UI remote), registered in
[`specs/cluster/optional-services.yaml`](../specs/cluster/optional-services.yaml)
(see [`OPTIONAL-SERVICES.md`](OPTIONAL-SERVICES.md) for the framework):

- **Apps:** `apps/38b-character-forge-bff-db.yaml` (dedicated Postgres,
  `hugmesh-backend`), `apps/39b-character-forge-bff-api.yaml` (the BFF, mTLS
  server, own Liquibase-owned `character_forge_character` table),
  `apps/49c-character-forge-ui.yaml` (the Angular remote, `hugmesh-frontend`,
  nginx-unprivileged :8080 serving the Godot WASM maker from same-origin assets).
  The Services keep the repo's DESIGN-locked `snapdragon-character-forge-*`
  names.
- **Manifests:** `manifests/character-forge{,-bff-api,-bff-db}` — unique SELinux
  MCS levels `s0:c82`/`s0:c83`/`s0:c84` per the [`SECURITY.md`](SECURITY.md) §3
  matrix, ESO secrets riding the SHARED `external-secrets` files (forum-bff
  pattern), per-pod db-ingress NetworkPolicy, inert HTTPRoute.
- **Gateway:** two fe-gateway routes in `apps/20-gateway-fe.yaml` —
  `/character-forge/**` → the UI remote (StripPrefix=1) and
  `/bff/character-forge/**` → the BFF, declared BEFORE the `/bff/**` admin
  catch-all (Spring Cloud Gateway matches in declared order). Two
  `gateway_route_access` rows (both ROLE_USER floor; ownership is enforced
  inside the BFF — owner = jwt subject, foreign id ⇒ 404).
- **Reserved prefixes:** `character-forge` (+ games-side `games-character-forge`,
  `games-shadows-of-the-net`), revision 9 of
  [`specs/cluster/reserved-prefixes.yaml`](../specs/cluster/reserved-prefixes.yaml)
  (see [`RESERVED-PREFIXES.md`](RESERVED-PREFIXES.md)).
- **Build channels (4-channel parity):** `--with-character-forge` /
  `--no-character-forge` + the `character-forge` `--optional-services` slug on
  BOTH cluster-node builders (`build-x86-host-stage4.sh`,
  `build-rpi5-stage4.sh`); the ncurses menu toggle + services checklist entry;
  the Studio GUI tri-state (`character_forge`, x86+rpi5-gated); the
  `tests/build-matrix/check.sh` probes. When deselected,
  `gate_optional_services()` prunes the three Applications + three manifest dirs
  + both routes + both route-access rows, and the installed-services ConfigMap /
  `OptionalService` seed CR render `character-forge: "false"` so the host greys
  the entry instead of 404/502.
- **Local stack:** `tests/stack/compose.local.yaml` services
  (`character-forge-bff-db`, `snapdragon-character-forge-bff-api`,
  `snapdragon-character-forge-ui`) + the fe gateway-routes mirror +
  `scripts/clone-all-repos.sh`.

**Federation registration** (`federation_modules`, kind `remote-shell`, mounted
at `/character-forge`, ROLE_USER) lives in the separate `hugmesh-federation-api`
repo — changeset 037; see
`specs/cluster/manifests/character-forge/FEDERATION-REGISTRATION-TODO.md`.

## 3. coturn dependency note (A/V)

Room audio is a small **full-mesh WebRTC** extension of matrix-ui's existing 1:1
call signalling (per-pair `m.call.*`, deterministic initiator, audio track + a
`chat3d` RTCDataChannel per peer for pose/blendshape/speaking data). ICE uses
the homeserver's existing `GET /_matrix/client/v3/voip/turnServer` answer:

- **coturn OFF (default):** clients keep host-only ICE. Same-LAN / same-tailnet
  peers connect; cross-NAT peers MAY fail — the UI surfaces the honest
  capability note (the `turnAvailable` pattern) instead of pretending.
- **coturn ON** ([`COTURN.md`](COTURN.md), DEFAULT-OFF runtime slug): relayed
  candidates make room audio reliable across the public internet. Public
  reachability of the relay is operator work (see COTURN.md §deploy).

The mesh is capped by the room's `maxParticipants` (2..16, default 8; a mesh
warning at ≥8) — an SFU is deliberately out of v1 scope (§6).

## 4. WebXR entry paths

- **Meta Quest 3/3s Browser (WebXR):** the room requests an `immersive-vr`
  session (`local-floor` with fallbacks) ONLY on a user gesture (the host page's
  Enter-VR button → `Chat3D.enterVR()`); `sessionSupported` is checked first and
  the button hidden when absent. NOTE: Quest has **no WebXR face-tracking API**
  — headset users drive the avatar mouth via mic amplitude, not camera.
- **Desktop no-headset (first-class):** mouse/WASD orbit + click-to-sit; webcam
  face tracking (self-hosted MediaPipe FaceLandmarker in a Web Worker, camera
  opt-in, frames never leave the device) drives blink/gaze/brows/lip-sync.
  A desktop user with only a webcam gets a live face-tracked avatar.
- **PCVR (native OpenXR):** the room's desktop exports (Linux/Windows) try
  `OpenXRInterface` at boot; the same scene, no browser.

**Godot web-export constraints (fleet-proven):** Compatibility renderer,
**threads OFF** (single-threaded — avoids COOP/COEP headers inside the Matrix
embedding; the matrix-ui nginx does NOT set COOP/COEP), Sample audio playback.
Exports are produced by the orchestrator with the official export templates —
`godot --headless` import/validation only in CI.

## 5. Quest browser notes

- Quest Browser is Chromium-based; WebXR `immersive-vr` + `local-floor` are
  supported on Quest 3/3s. Hand tracking exists but v1 uses controllers/gaze.
- The `Chat3dHostComponent` iframe carries
  `allow="xr-spatial-tracking; microphone; camera; autoplay"` — without
  `xr-spatial-tracking` the embedded WASM cannot start a session.
- Media (mic) permission prompts happen in-headset; first entry should be done
  once outside VR to accept them comfortably.
- A mesh-enrolled Quest (the MDM track, [`MDM.md`](MDM.md)) can have the
  XR-chat entry URL provisioned as a managed browser shortcut — that lane owns
  its own docs section.

## 6. Future work (documented, NOT built)

- **LiveKit / MatrixRTC SFU** as an optional service — replaces the full-mesh
  cap for larger rooms; a reserved future slot, NOT scheduled. The mesh cap 8
  stands in until then.
- **Video-as-WebGL-texture** on room surfaces (v1 = poster frame + open-in-panel).
- **GLB part library / VRM export** for the assembler (indirection is ready).
- **WebXR face tracking** — no Quest 3/3s browser API exists today.
- **Appservice-side media fan-in** (v1 is client-driven placement).

## 7. What this track is NOT

**"web" is NOT a build channel.** The BUILD-MATRIX channels remain
GUI/CLI/make/ncurses ([`BUILD-MATRIX.md`](BUILD-MATRIX.md)); the room/maker are
cluster **services** selected via the optional-services framework, not image
build options beyond the slug flag documented in §2.
# XR-CHAT — generator-side notes (thin desktop + streaming legs)

> **Scope note:** this branch (`feat/quest-mdm-setup`) carries the **Quest
> MDM + thin-desktop** legs of the XR-chat track only. The full XR-chat
> architecture document (character-forge optional service, Matrix chat3d
> rooms, WebXR entry paths, coturn dependency, LiveKit/MatrixRTC future work)
> is owned by the platform-wiring lane and merges into this same file —
> sections below are scoped to survive that merge.

## Quest headsets on the mesh

A Meta Quest 3/3S joins the mesh as an MDM-managed Android device via the
phone wizard's quest class — see [`docs/MDM.md`](MDM.md) "Quest headsets"
(`detect → mdm-enroll → enroll → ingest`, Headwind device-owner, Tailscale
sideload with the same `tun0` join verify, `--xr-chat-url` room-entry
provisioning with a VIEW-intent launch check).

## Thin desktop (Moonlight ⇄ Sunshine, tailnet-only)

A mesh-enrolled Quest can open a usable **virtual desktop of a thin-client
x86 desktop node** (e.g. a `frite`-class seat's x86 sibling) over the tailnet
only — Sunshine on the node (`build-x86-host-stage4.sh --with-sunshine`:
mesh-scoped nftables fence, loopback-only pairing UI, in-session autostart),
Moonlight on the headset (`phone-wizard.sh mdm-enroll --thin-desktop`:
signer-pinned APK sideload + managed host list + Headwind app-push runbook).
Full detail, gates, port set, pairing flow and e2e:
[`docs/MDM.md`](MDM.md) **"Thin desktop"**.

## WiVRn (native OpenXR streaming) — sibling path, stub only

The same node/headset pair can stream the **native OpenXR
shadows-of-the-net build** as room-scale VR via WiVRn instead of a flat
Moonlight panel. v1 documents it as a config stub baked next to the Sunshine
config (`/etc/hugmesh/thin-desktop/wivrn.toml.example` — TCP+UDP 9757 fenced
to the tailscale iface like the Sunshine port set); the rollout (package,
fence extension, session unit) is tracked follow-up work in
[`docs/MDM.md`](MDM.md).
