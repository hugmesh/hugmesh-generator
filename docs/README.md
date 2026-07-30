# hugmesh-generator docs index

The doc set for the image/infra layer. State key used throughout:
**✅ shipped** (on `main`) · **🚧 in-flight** (open branch/PR) · **🔭 planned**
(design only). New operators start with [`RUNNING.md`](RUNNING.md), then read
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Operating & building

- [`RUNNING.md`](RUNNING.md) — end-to-end runbook (clone → build → keys → flash → provision → cluster).
- [`NIXOS-STEAMOS.md`](NIXOS-STEAMOS.md) — launching the Studio wizard + ncurses menu on NixOS / SteamOS (Steam Deck) / Arch / Debian / Fedora: the additive Nix flake (`flake.nix`/`shell.nix`) + the portable POSIX launcher (`scripts/studio-launch.sh`) for hosts without `python3`/`make`/FHS (✅).
- [`LOCAL-TESTING.md`](LOCAL-TESTING.md) — LAN `.test` fleet testing.
- [`LOCAL-STACK.md`](LOCAL-STACK.md) — `make stack-up` local-dev compose stack (opt-in upstream Synapse/Mastodon for dev only).
- [`DEVOPS.md`](DEVOPS.md) — GitLab CI, runner, binhost, build distribution.
- [`BUILD-MATRIX.md`](BUILD-MATRIX.md) — the canonical platform×role×env build matrix, the four build channels (CLI / make / ncurses menu / Studio GUI), the **all-options-in-all-menus** rule + the `make matrix-check` harness (✅).
- [`PYTHON-TARGETS-SEED-DRIFT.md`](PYTHON-TARGETS-SEED-DRIFT.md) — why `PYTHON_TARGETS`/`PYTHON_SINGLE_TARGET` are **derived from the stage3 seed** and never hardcoded: portage's make.conf-replaces vs package.use-adds semantics, the two mirror-image fleet failures a frozen `python3_NN` caused (2026-07-16 autounmask wall, 2026-07-29 `dev-python` slot conflict), and what the guard now asserts. **Read this before touching a `python3_NN` literal anywhere.**
- [`STUDIO-WIZARD-FLOW.md`](STUDIO-WIZARD-FLOW.md) — the Studio image-build wizard's **4-choice → 7-step** flow (mesh node / local Docker mesh / mesh client / standalone), per-path page map, and the ncurses/CLI/web-UI **parity TODO** (✅ GUI; 🔭 other channels).
- [`RESERVED-PREFIXES.md`](RESERVED-PREFIXES.md) — reserved `ROLE_`/`DOMAIN_` and route first-segment prefixes.
- [`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md) — superadmin go-live wizard (bring-your-own-domain / cloudflare-tunnel / DuckDNS-DDNS / tailscale-funnel / router-portforward providers), CLI + ncurses + Studio front-ends (✅ v1 consolidated).
- [`SUPERADMIN-MESH-CLIENT.md`](SUPERADMIN-MESH-CLIENT.md) — how a platform superadmin joins the tailnet mesh and reaches nodes over SSH.
- [`IMAGE-GEN-PROGRESS.md`](IMAGE-GEN-PROGRESS.md) — the image-build worker's optional non-terminal `PROGRESS_URL` side channel (fills the web progress bar between the start frame and the terminal `COMPLETED`/`FAILED`/`ERROR` result).

## Architecture

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full topology, gateway pattern, identity, multi-tenancy/superadmin, role cascade, and the roadmap.
- [`ROUTE-ACCESS.md`](ROUTE-ACCESS.md) — `gateway_route_access` model (incl. 🔭 MFA-required fail-closed gating).
- [`HEAVY-TIER.md`](HEAVY-TIER.md) — heavy datastores (Kafka/ClickHouse/Uptrace) on the x86 worker.
- [`MESH-TEMPLATING.md`](MESH-TEMPLATING.md) — multi-tenant mesh repo-templating: Handlebars render engine, guardrails, archetype rendering, and cross-mesh foreign-base ingestion (Phases 1–7, ✅ merged).
- [`PHASE5-DECISIONS.md`](PHASE5-DECISIONS.md) — Phase 5 detail: the first tailnet-internal publish of rendered tenant repos to Forgejo, signed provenance, domain-reconcile writeback.

## Security & hardening

- [`SECURITY.md`](SECURITY.md) — per-app identity matrix, SELinux, mTLS, role cascade.
- [`CLUSTER-HARDENING-PLAN.md`](CLUSTER-HARDENING-PLAN.md) — cluster hardening posture.
- [`CRYPTO-AUDIT.md`](CRYPTO-AUDIT.md) — crypto choices + PQC/SHA-3 readiness (🚧 supply-chain hardening roadmap).
- [`ENCRYPTION-AT-REST.md`](ENCRYPTION-AT-REST.md) — disk/FDE encryption.
- [`POSTGRES-HARDENING.md`](POSTGRES-HARDENING.md) — Postgres hardening.
- [`DOMAIN-LOCK.md`](DOMAIN-LOCK.md) — per-domain lock enforcement.
- [`USERNAME-CONFUSABLE.md`](USERNAME-CONFUSABLE.md) — confusable-username defenses.
- [`DEVICE-REGISTRY-KEY-ROTATION.md`](DEVICE-REGISTRY-KEY-ROTATION.md) — device-license registry + key rotation.
- [`PENTEST-SCHEDULES.md`](PENTEST-SCHEDULES.md) — continuous OWASP pen-test CI stage.

## Optional services & platform features

- [`OPTIONAL-SERVICES.md`](OPTIONAL-SERVICES.md) — akkoma/tuwunel/phpBB/games/owncast/tube/character-studio/character-forge add/remove framework (✅ build-time, 🚧 live cut-over).
- [`XR-CHAT.md`](XR-CHAT.md) — "Shadows of the Net" XR chat room + the Character Forge (3D) multi-app slug (DEFAULT-OFF; WebXR/Quest + desktop face-tracking architecture, coturn dependency note).
- [`MESHTASTIC-BRIDGE.md`](MESHTASTIC-BRIDGE.md) — Meshtastic LoRa mesh ↔ Matrix bridge, a DEFAULT-OFF runtime-only optional service (Matrix appservice + LoRa radio transports over USB-serial / TCP / MQTT).
- [`EGRESS-VPN.md`](EGRESS-VPN.md) — outgoing public egress via operator `.conf`.
- [`NODE-STORAGE.md`](NODE-STORAGE.md) — attach + register node-pinned storage.
- [`GAMES-APPSTORE.md`](GAMES-APPSTORE.md) — per-domain FOSS game-server catalog + instance lifecycle.
- [`EDGE-AI.md`](EDGE-AI.md) — GPU inference node serving an OpenAI-compatible model API to the mesh (DEFAULT-OFF, GPU-gated).
- [`COTURN.md`](COTURN.md) — TURN/STUN relay for Matrix (tuwunel) audio/video (DEFAULT-OFF, runtime-only slug).
- [`TOR-HIDDEN-SERVICE.md`](TOR-HIDDEN-SERVICE.md) — Tor v3 hidden-service (onion) gateway exposure (DEFAULT-OFF).
- [`CLOUD-BACKUPS.md`](CLOUD-BACKUPS.md) — generator-side leg of per-domain + total-cloud encrypted backups.

## Client images

- [`CLIENT-IMAGES.md`](CLIENT-IMAGES.md) — per-user device images (FD-04 ✅ shipped; FD-06/07/08 + desktop-app governance 🔭 deferred).
- [`MDM.md`](MDM.md) — the fourth onboarding form (✅ merged): verified GrapheneOS onto a USB-connected Pixel → attest → Headwind MDM enroll → mesh enroll → escrowed enterprise profile → device-registry ingest (`scripts/phone-wizard.sh`); real pre-deploy gaps remain (see its Deferred section).
- [`STANDALONE-DESKTOP.md`](STANDALONE-DESKTOP.md) — hardened standalone NVIDIA desktop images (not a cluster node).

## Testing

- [`TEST-ARCHITECTURE.md`](TEST-ARCHITECTURE.md) — test layering.
- [`FINAL-E2E-SWEEP-MATRIX.md`](FINAL-E2E-SWEEP-MATRIX.md) — end-to-end sweep matrix.

## Specifications

- [`selinux-module-loading.md`](selinux-module-loading.md) — SELinux node-policy module loading fleet build-script wiring spec (specification only; changes nothing by itself).

## Historical

- [`HANDOFF.md`](HANDOFF.md) — ⚠ **historical snapshot (2026-06-06)**; superseded by the per-feature docs above + git log. Do not treat its finish-list as current.
