# XR chat — "Shadows of the Net" virtual room + the Character Forge (3D) slug

> **Status: the `character-forge` OPTIONAL service (DEFAULT-OFF, admin gate) is the
> generator-side leg of a cross-repo XR-chat track (🚧 in-flight).** A default build bakes NO
> character-forge apps and changes NOTHING. You must select the slug: `--with-character-forge`,
> `character-forge` in `OPTIONAL_SERVICES`, or the `all` full set. The room, game, frontend and
> BFF code live in the sibling repos named below. This repo only wires the platform slug (GitOps
> apps + manifests, gateway routes, route-access rows, reserved prefixes, build-channel parity)
> and documents the architecture.

## 1. What the track is

A Ghost-in-the-Shell-ep.9-style **virtual chat room**. A Godot 4 WASM scene sits in Matrix
(tuwunel) channels and the games portal. Its **3D avatars are mapped from the existing SVG VN
characters** (character-studio packs). It runs on WebXR in the Meta Quest 3/3s Browser, on native
OpenXR for PCVR, and in a **first-class no-headset desktop mode** (keyboard/mouse + optional
webcam face/lip tracking).

The pieces, by repo:

| Piece | Repo | What it is |
|---|---|---|
| **Character Forge** (3D maker) | `hugmesh-character-forge-bff-api` (one multi-surface repo; the brand prefix was renamed by the HugMesh rebrand) | Spring BFF at the root (`/bff/character-forge/**`: Char3DConfig CRUD, one-active-per-owner, cross-user lookup, VN→3D `/map`), `godot/` (a pointer: the Godot 4 maker moved to `hugmesh-games`, `games/character-forge/`, which holds the CANONICAL `scripts/character_assembler.gd`; `godot/character-forge/build/bundle/` keeps a prebuilt web export), `frontend/` (Angular native-federation remote mounted at `/character-forge`) |
| **The room** | `hugmesh.games` repo, `games/shadows-of-the-net/` | Godot WASM chat chamber; dual mode — `mode=session` (games-portal wasm-game contract) and `mode=matrix` (all I/O via the host page `Chat3D` JS bridge) |
| **Matrix integration** | `hugmesh-matrix-ui` | `net.hugmesh.chat3d*` state events (room enable/config, scene placements, per-user avatar, stage holder; legacy `systems.hugmesh.*`/`systems.snapdragon.*` spellings still readable), room-settings section, iframe host for the room, full-mesh WebRTC audio + pose/blendshape data channels, self-hosted MediaPipe face tracking |
| **Platform slug** | THIS repo | everything in §2 |

The 3D avatar is **procedural** by default: parameterized primitive meshes assembled by
`character_assembler.gd`. It is keyed off the STABLE VN parameterization (packId / partId /
headArchetype / palette regions), never SVG geometry. Where the part registry has a vendored
CC0/CC-BY GLB or VRM model for a family or body type, the maker mounts that mesh on top (the
"mesh basis"; a user can also import their own model). A missing or over-cap asset falls back
to the procedural avatar. Source: `hugmesh-games` `games/character-forge/README.md`.

## 2. What THIS repo bakes — the `character-forge` slug

A MULTI-APP slug shaped like phpbb (BFF db + BFF api + UI remote), registered in
[`specs/cluster/optional-services.yaml`](../specs/cluster/optional-services.yaml)
(see [`OPTIONAL-SERVICES.md`](OPTIONAL-SERVICES.md) for the framework):

- **Apps:**
  - `apps/38b-character-forge-bff-db.yaml` — dedicated Postgres, `hugmesh-backend`.
  - `apps/39b-character-forge-bff-api.yaml` — the BFF, an mTLS server with its own
    Liquibase-owned `character_forge_character` table.
  - `apps/49c-character-forge-ui.yaml` — the Angular remote in `hugmesh-frontend`,
    nginx-unprivileged :8080, serving the Godot WASM maker from same-origin assets.

  The Services are named `hugmesh-character-forge-{bff-api,ui}`. The HugMesh rebrand renamed
  only the brand prefix on the repo, Service and image identifiers. The `character-forge`
  FEATURE SLUG — manifest dir names, route paths, DB/table names, the federated remote name and
  the reserved-prefix label — was NOT renamed.
- **Manifests:** `manifests/character-forge{,-bff-api,-bff-db}`. Unique SELinux MCS levels
  `s0:c82`/`s0:c83`/`s0:c84` per the [`SECURITY.md`](SECURITY.md) §3 matrix. ESO secrets ride
  the SHARED `external-secrets` files (forum-bff pattern). A per-pod db-ingress NetworkPolicy.
  An inert HTTPRoute.
- **Gateway:** two fe-gateway routes in `apps/20-gateway-fe.yaml`. `/character-forge/**` goes to
  the UI remote (StripPrefix=1). `/bff/character-forge/**` goes to the BFF and is declared
  BEFORE the `/bff/**` admin catch-all (Spring Cloud Gateway matches in declared order). Two
  `gateway_route_access` rows, both at the ROLE_USER floor. Ownership is enforced inside the
  BFF: owner = jwt subject, foreign id ⇒ 404.
- **Reserved prefixes:** `character-forge` (plus the games-side `games-character-forge` and
  `games-shadows-of-the-net`), revision 9 of
  [`specs/cluster/reserved-prefixes.yaml`](../specs/cluster/reserved-prefixes.yaml)
  (see [`RESERVED-PREFIXES.md`](RESERVED-PREFIXES.md)).
- **Build channels (4-channel parity):**
  - `--with-character-forge` / `--no-character-forge`, and the `character-forge`
    `--optional-services` slug, on BOTH cluster-node builders (`build-x86-host-stage4.sh`,
    `build-rpi5-stage4.sh`);
  - the ncurses menu toggle and services checklist entry;
  - the Studio GUI tri-state (`character_forge`, x86+rpi5-gated);
  - the `tests/build-matrix/check.sh` probes.

  When the slug is deselected, `gate_optional_services()` prunes the three Applications, the
  three manifest dirs, both routes and both route-access rows. The installed-services
  ConfigMap and the `OptionalService` seed CR render `character-forge: "false"`, so the host
  greys the entry instead of returning 404/502.
- **Local stack:** `tests/stack/compose.local.yaml` services (`character-forge-bff-db`,
  `hugmesh-character-forge-bff-api`, `hugmesh-character-forge-ui`), the fe gateway-routes
  mirror, and `scripts/clone-all-repos.sh`.

**Federation registration** (`federation_modules`, kind `remote-shell`, mounted at
`/character-forge`, ROLE_USER) lives in the separate `hugmesh-federation-api` repo, changeset
`038-register-character-forge-module.xml`. A follow-up,
`039-rebrand-character-forge-remote-entry.xml`, repoints `remote_entry_url`.

## 3. coturn dependency note (A/V)

Room audio is a small **full-mesh WebRTC** extension of matrix-ui's existing 1:1 call signalling
(per-pair `m.call.*`, deterministic initiator, an audio track plus a `chat3d` RTCDataChannel per
peer for pose, blendshape and speaking data). ICE uses the homeserver's existing
`GET /_matrix/client/v3/voip/turnServer` answer:

- **coturn OFF (default):** clients keep host-only ICE. Peers on the same LAN or tailnet connect;
  cross-NAT peers MAY fail. The UI says so (the `turnAvailable` pattern) and does not pretend.
- **coturn ON** ([`COTURN.md`](COTURN.md), DEFAULT-OFF runtime slug): relayed candidates make
  room audio reliable across the public internet. Making the relay publicly reachable is
  operator work (see COTURN.md §5, "Public reachability").

The room's `maxParticipants` caps the mesh (2..16, default 8; a mesh warning at ≥8). This repo
ships no SFU yet (§6).

## 4. WebXR entry paths

- **Meta Quest 3/3s Browser (WebXR):** the room requests an `immersive-vr` session
  (`local-floor` required, `bounded-floor` optional) ONLY on a user gesture. Two buttons start
  it. The in-scene Enter VR button is the reliable one; it is hidden unless `immersive-vr` is
  supported. The host page's Enter VR button calls `Chat3D.enterVR()`, stays disabled until the
  room reports ready, and the browser may refuse it. NOTE: Quest has **no WebXR face-tracking
  API**, so headset users drive the avatar mouth from mic amplitude, not the camera.
- **Desktop no-headset (first-class):** WASD/arrow walk, right-drag orbit, click to sit. Webcam
  face tracking (self-hosted MediaPipe FaceLandmarker in a Web Worker, camera opt-in, frames
  never leave the device) drives blink, gaze, brows and lip-sync. A desktop user with only a
  webcam gets a live face-tracked avatar.
- **PCVR (native OpenXR):** the room's desktop exports (Linux/Windows) try `OpenXRInterface` at
  boot. Same scene, no browser.

**Godot web-export constraints (fleet-proven):** Compatibility renderer; **threads OFF**
(single-threaded, which avoids COOP/COEP headers inside the Matrix embedding; the matrix-ui
nginx does NOT set COOP/COEP); Sample audio playback. The orchestrator produces exports with the
official export templates. `godot --headless` import and validation run only in CI.

## 5. Quest browser notes

- Quest Browser is Chromium-based. WebXR `immersive-vr` and `local-floor` work on Quest 3/3s.
  Hand tracking exists, but v1 uses controllers and gaze.
- The `Chat3dHostComponent` iframe carries
  `allow="xr-spatial-tracking; microphone; camera; autoplay"`. Without `xr-spatial-tracking` the
  embedded WASM cannot start a session.
- Media (mic) permission prompts appear in the headset. Do the first entry once outside VR and
  accept them there.
- A mesh-enrolled Quest (the MDM track, [`MDM.md`](MDM.md) "Quest headsets") can have the
  XR-chat entry URL (`--xr-chat-url`, https only) provisioned as a Headwind web-page
  application. The wizard prints the console runbook and fires a `VIEW` intent so the operator
  can check that the room loads.

## 6. Future work (documented, NOT built)

- **LiveKit / MatrixRTC SFU** as an optional service. It would replace the full-mesh cap for
  larger rooms. The technology is chosen and the work is scheduled for launch (decisions 102a
  and 102b, hugmesh-admin-bff-api#98), but this repo has no such service yet: the design and
  staged plan are in [`GROUP-CALL-SFU.md`](GROUP-CALL-SFU.md).
  `hugmesh-matrix-ui` carries a client path behind a dark MatrixRTC flag (default off). Above
  `maxParticipants` it asks the homeserver for a LiveKit focus and moves voice onto it if one is
  advertised. Without a focus the mesh cap stands.
- **Video-as-WebGL-texture** on room surfaces (v1 = poster frame + open-in-panel).
- **VRM export** from the assembler. (The GLB/VRM mesh basis, §1, is built; export is not.)
- **WebXR face tracking** — no Quest 3/3s browser API exists today.
- **Appservice-side media fan-in** (v1 is client-driven placement).

## 7. What this track is NOT

**"web" is NOT a build channel.** The BUILD-MATRIX channels remain GUI/CLI/make/ncurses
([`BUILD-MATRIX.md`](BUILD-MATRIX.md)). The room and the maker are cluster **services**, chosen
through the optional-services framework. They are not image build options beyond the slug flag
documented in §2.


# XR-CHAT — generator-side notes (thin desktop + streaming legs)

> **Scope note:** this part covers the **Quest MDM + thin-desktop** legs of the XR-chat track.
> The architecture above (character-forge optional service, Matrix chat3d rooms, WebXR entry
> paths, coturn dependency, future work) is the other half of this same file.

## Quest headsets on the mesh

A Meta Quest 3/3S joins the mesh as an MDM-managed Android device, through the phone wizard's
quest class. See [`docs/MDM.md`](MDM.md) "Quest headsets":
`detect → mdm-enroll → enroll → ingest`, Headwind device-owner, Tailscale sideload with the
same `tun0` join verify, and `--xr-chat-url` room-entry provisioning with a VIEW-intent launch
check.

## Thin desktop (Moonlight ⇄ Sunshine, tailnet-only)

A mesh-enrolled Quest can open a usable **virtual desktop of a thin-client x86 desktop node**
(e.g. a `frite`-class seat's x86 sibling), over the tailnet only.

- Sunshine runs on the node: `build-x86-host-stage4.sh --with-sunshine` (mesh-scoped nftables
  fence, loopback-only pairing UI, in-session autostart).
- Moonlight runs on the headset: `phone-wizard.sh mdm-enroll --thin-desktop` (signer-pinned APK
  sideload, managed host list, Headwind app-push runbook).

Full detail, gates, port set, pairing flow and e2e: [`docs/MDM.md`](MDM.md) **"Thin desktop"**.

## WiVRn (native OpenXR streaming) — sibling path, stub only

The same node and headset can stream the **native OpenXR shadows-of-the-net build** as
room-scale VR through WiVRn, instead of a flat Moonlight panel. v1 documents this as a config
stub baked next to the Sunshine config (`/etc/hugmesh/thin-desktop/wivrn.toml.example`; TCP+UDP
9757, fenced to the tailscale iface like the Sunshine port set). The rollout (package, fence
extension, session unit) is tracked follow-up work in [`docs/MDM.md`](MDM.md).
