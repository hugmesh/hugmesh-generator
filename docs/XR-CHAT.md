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
