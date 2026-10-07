# hugmesh-generator docs index

The doc set for the image/infra layer. State key used throughout:
**✅ shipped** (on `main`) · **🚧 in-flight** (open branch/PR) · **🔭 planned**
(design only). New operators start with [`RUNNING.md`](RUNNING.md), then read
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Operating & building

- [`RUNNING.md`](RUNNING.md) — end-to-end runbook (clone → build → keys → flash → provision → cluster).
- [`SERVE-YOUR-MESH.md`](SERVE-YOUR-MESH.md) — the end-to-end path from nothing to a reachable login page: generate a whole platform, serve it **locally**, then optionally expose it **publicly** over a Tor `.onion`, a Dynamic-DNS host, or a tunnel.
- [`NIXOS-STEAMOS.md`](NIXOS-STEAMOS.md) — launching the Studio wizard + ncurses menu on NixOS / SteamOS (Steam Deck) / Arch / Debian / Fedora: the additive Nix flake (`flake.nix`/`shell.nix`) + the portable POSIX launcher (`scripts/studio-launch.sh`) for hosts without `python3`/`make`/FHS (✅).
- [`LOCAL-TESTING.md`](LOCAL-TESTING.md) — LAN `.test` fleet testing.
- [`STUDIO-INSTALLERS.md`](STUDIO-INSTALLERS.md) — the Studio's **Windows MSI** and **Linux Flatpak**: what they package, what they still need from the host, and how a release is cut (✅).
- [`RESOURCE-LIMITS.md`](RESOURCE-LIMITS.md) — capping the **CPU / memory / GPU** that builds, the local stack, emulated meshes and kind nodes may use, so the machine stays usable while HugMesh runs (✅).
- [`LOCAL-STACK.md`](LOCAL-STACK.md) — `make stack-up` local-dev compose stack (opt-in upstream tuwunel/Mastodon for dev only).
- [`ADMIN-CONSOLES.md`](ADMIN-CONSOLES.md) — **every admin/moderation console: URL, the role that opens it, and its HONEST state** (probed live). Which panels are dark and why; what Matrix/Mastodon/forum administration can and cannot do on this mesh; how to sign in with an account that holds the roles.
- [`DEVOPS.md`](DEVOPS.md) — GitLab CI, runner, binhost, build distribution.
- [`BUILD-MATRIX.md`](BUILD-MATRIX.md) — the canonical platform×role×env build matrix, the four build channels (CLI / make / ncurses menu / Studio GUI), the **all-options-in-all-menus** rule + the `make matrix-check` harness (✅).
- [`IMAGE-INVENTORY.md`](IMAGE-INVENTORY.md) — generated full cross-product of every advertised image × every build channel (125 distinct images, 62 with a channel gap); regenerate with `scripts/emit-image-inventory.py`, gated by `make inventory-check` — do not hand-edit.
- [`SHARED-BINPKG.md`](SHARED-BINPKG.md) — the shared per-arch binpkg pools, stage3 seed cache and fleet distfiles, plus the CHOST/`-mcpu` pool-fingerprint guard (✅ mechanism + guard shipped; ⚠️ the compile-once speedup itself is still owed a real cross-build to prove).
- [`PYTHON-TARGETS-SEED-DRIFT.md`](PYTHON-TARGETS-SEED-DRIFT.md) — why `PYTHON_TARGETS`/`PYTHON_SINGLE_TARGET` are **derived from the stage3 seed** and never hardcoded: portage's make.conf-replaces vs package.use-adds semantics, the two mirror-image fleet failures a frozen `python3_NN` caused (2026-07-16 autounmask wall, 2026-07-29 `dev-python` slot conflict), and what the guard now asserts. **Read this before touching a `python3_NN` literal anywhere.**
- [`PLATFORM-BUILD-UNIFORMITY.md`](PLATFORM-BUILD-UNIFORMITY.md) — the measured survey of how the eight platforms' build structures diverge: per-platform stage ladders, the three emerge-invocation shapes, the emerge-group taxonomy, what per-package data reaches the stream vs only a log (and where the cross builds destroy it), 24 classified divergences + a proposed canonical ladder (🔭 survey; no behaviour change).
- [`STUDIO-WIZARD-FLOW.md`](STUDIO-WIZARD-FLOW.md) — the Studio image-build wizard's **4-choice → 7-step** flow (mesh node / local Docker mesh / mesh client / standalone), per-path page map, and the ncurses/CLI/web-UI **parity TODO** (✅ GUI; 🔭 other channels).
- [`RESERVED-PREFIXES.md`](RESERVED-PREFIXES.md) — reserved `ROLE_`/`DOMAIN_` and route first-segment prefixes.
- [`GO-LIVE-WIZARD.md`](GO-LIVE-WIZARD.md) — superadmin go-live wizard (bring-your-own-domain / cloudflare-tunnel / DuckDNS-DDNS / tailscale-funnel / router-portforward providers), CLI + ncurses + Studio front-ends (✅ v1 consolidated).
- [`SUPERADMIN-MESH-CLIENT.md`](SUPERADMIN-MESH-CLIENT.md) — how a platform superadmin joins the tailnet mesh and reaches nodes over SSH.
- [`IMAGE-GEN-PROGRESS.md`](IMAGE-GEN-PROGRESS.md) — the image-build worker's optional non-terminal `PROGRESS_URL` side channel (fills the web progress bar between the start frame and the terminal `COMPLETED`/`FAILED`/`ERROR` result).
- [`PACKAGE-FLAG-BADGES.md`](PACKAGE-FLAG-BADGES.md) — ground truth for the Studio's per-package flag display: every USE-flag state portage can render (re-derived from portage 3.0.81.2's own formatter), which of the four columns (USE_EXPAND / USE / KEYWORDS / LICENSE) each channel can actually source, the 100%-coverage **offline** hover-doc sources, and the badge colour+emoji mapping (🔭 semantics only — no feature code).

## Architecture

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full topology, gateway pattern, identity, multi-tenancy/superadmin, role cascade, and the roadmap.
- [`ROUTE-ACCESS.md`](ROUTE-ACCESS.md) — `gateway_route_access` model (incl. 🔭 MFA-required fail-closed gating).
- [`HEAVY-TIER.md`](HEAVY-TIER.md) — heavy datastores (Kafka/ClickHouse/Uptrace) on the x86 worker.
- [`MESH-TEMPLATING.md`](MESH-TEMPLATING.md) — multi-tenant mesh repo-templating: Handlebars render engine, guardrails, archetype rendering, and cross-mesh foreign-base ingestion (Phases 1–7, ✅ merged).
- [`BRANDING.md`](BRANDING.md) — what a tenant's rendered generator copy rebrands (and never touches); also the render engine's `renames[]` pilot, since this file itself gets re-filed as `docs/BRANDING-<org-slug>.md` per tenant.
- [`LOGIN-THEME.md`](LOGIN-THEME.md) — `scripts/tooling/derive-theme.py`: render the login-ui `snap-theme.css` (or its `login-theme` ConfigMap) from brand colours / fonts / presets at render time, through the same `compose_login_css()` the Studio and the mesh-bootstrap CLI use.
- [`FEDERATION-EXAMPLES.md`](FEDERATION-EXAMPLES.md) — the runtime side of native-federation: how a host shell discovers and mounts remotes, walked through via the four runnable archetype example codebases (companion to `MESH-TEMPLATING.md`, which covers the render side).
- [`PHASE5-DECISIONS.md`](PHASE5-DECISIONS.md) — Phase 5 detail: the first tailnet-internal publish of rendered tenant repos to Forgejo, signed provenance, domain-reconcile writeback.

## Security & hardening

- [`SECURITY.md`](SECURITY.md) — per-app identity matrix, SELinux, mTLS, role cascade.
- [`MFA-ROLLOUT.md`](MFA-ROLLOUT.md) — operator runbook for turning on the gateway's `mfa_required` enforcement floor + admin-bff step-up: preconditions, order of operations, rollback. **Default posture today: OFF** — seeds, gateway wiring, CI gates and e2e all shipped; only the live-cluster operator flip remains.
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
- [`LORAWAN-MESH-SYNC.md`](LORAWAN-MESH-SYNC.md) — companion to `MESHTASTIC-BRIDGE.md`, covering the *other* LoRa technology: LoRaWAN WAN reach + near-mesh sync (🔭 design-only, phase 1 of 4 — nothing implemented yet).
- [`MESH-VISIBILITY.md`](MESH-VISIBILITY.md) — the `friends` decision: why a mesh device's `visibility=friends` setting behaves as `private` today (the platform has no friendship graph to enforce it against), and what has to be decided before it can ship.
- [`EGRESS-VPN.md`](EGRESS-VPN.md) — outgoing public egress via operator `.conf`.
- [`NODE-STORAGE.md`](NODE-STORAGE.md) — attach + register node-pinned storage.
- [`GAMES-APPSTORE.md`](GAMES-APPSTORE.md) — per-domain FOSS game-server catalog + instance lifecycle.
- [`EDGE-AI.md`](EDGE-AI.md) — GPU inference node serving an OpenAI-compatible model API to the mesh (DEFAULT-OFF, GPU-gated).
- [`LOCAL-AI-ASSISTANT.md`](LOCAL-AI-ASSISTANT.md) — set up Ollama on your own PC from the CLI, choose a local coding model for an 8 GB GPU, and run a code assistant on a scratch copy of the mesh code (`scripts/local-ai-bench.sh` measures the models on your machine).
- [`COTURN.md`](COTURN.md) — TURN/STUN relay for Matrix (tuwunel) audio/video (DEFAULT-OFF, runtime-only slug).
- [`TOR-HIDDEN-SERVICE.md`](TOR-HIDDEN-SERVICE.md) — Tor v3 hidden-service (onion) gateway exposure (DEFAULT-OFF).
- [`CLOUD-BACKUPS.md`](CLOUD-BACKUPS.md) — generator-side leg of per-domain + total-cloud encrypted backups.

## Cloud deploy & external services

- [`CLOUD-DEPLOY.md`](CLOUD-DEPLOY.md) — publish an already-built, cloud-packaged x86 image to AWS/Azure/OpenShift/any qcow2 host via offline-rendered plans, fronted by the Studio DeployPage / ncurses `deploy_screen` / `make deploy-*` (🚧 in-flight — every face reports "driver not found" honestly until the driver lane merges).
- [`CLOUD-IMAGE-PACKAGING.md`](CLOUD-IMAGE-PACKAGING.md) — `scripts/cloud-package.sh`: re-packages a built x86 raw `.img` as qcow2 / fixed VHD / checksummed raw for KubeVirt, Azure and AWS import. A standalone post-build operator step, not a build-matrix axis.
- [`PUBLISH-IMAGES.md`](PUBLISH-IMAGES.md) — `scripts/publish-images.sh`: exports one build session's shareable artifacts into a flat publish tree (`SHA256SUMS`, versioned `publish-manifest.json`, optional Ed25519 signature); structurally incapable of shipping key material, and refuses the whole export on the first poisoned candidate.
- [`IDENTITY-PROVIDERS.md`](IDENTITY-PROVIDERS.md) — point a node at the built-in Casdoor IdP (default) or an external OIDC provider (Azure Entra ID, AWS Cognito, generic OIDC) for token validation; offered from the Studio wizard, local-mesh bootstrap, ncurses, and the cloud-deploy flow.
- [`MANAGED-SERVICES.md`](MANAGED-SERVICES.md) — point an in-mesh backing service (a datastore/infra the mesh normally self-hosts) at a hosted cloud equivalent (AWS/Azure) instead, on a generated node image; strictly additive and opt-in, self-hosted stays byte-identical the default.

## Client images

- [`CLIENT-IMAGES.md`](CLIENT-IMAGES.md) — per-user device images (FD-04 ✅ shipped; FD-06/07/08 + desktop-app governance 🔭 deferred).
- [`MDM.md`](MDM.md) — the fourth onboarding form (✅ merged): verified GrapheneOS onto a USB-connected Pixel → attest → Headwind MDM enroll → mesh enroll → escrowed enterprise profile → device-registry ingest (`scripts/phone-wizard.sh`); real pre-deploy gaps remain (see its Deferred section).
- [`STANDALONE-DESKTOP.md`](STANDALONE-DESKTOP.md) — hardened standalone NVIDIA desktop images (not a cluster node).

## Testing

- [`TEST-ARCHITECTURE.md`](TEST-ARCHITECTURE.md) — test layering.
- [`FINAL-E2E-SWEEP-MATRIX.md`](FINAL-E2E-SWEEP-MATRIX.md) — end-to-end sweep matrix.
- [`KIND-SSO-E2E-FINDINGS.md`](KIND-SSO-E2E-FINDINGS.md) — 2026-08-05: the first real `KIND_PROFILE=sso` cluster run of the native-login e2e spec. The harness reached Casdoor and minted a session; 16 fresh-cluster blockers surfaced downstream (incl. no gateway can ever become Ready in k8s, and Casdoor's admin account still on its default password) — the current substance of the SSO kind-cluster e2e roadmap item.

## Specifications

- [`selinux-module-loading.md`](selinux-module-loading.md) — SELinux node-policy module loading fleet build-script wiring spec (specification only; changes nothing by itself).

## Historical

- [`HANDOFF.md`](HANDOFF.md) — ⚠ **historical snapshot (2026-06-06)**; superseded by the per-feature docs above + git log. Do not treat its finish-list as current.
