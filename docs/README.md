# snapdragon-generator docs index

The doc set for the image/infra layer. State key used throughout:
**✅ shipped** (on `main`) · **🚧 in-flight** (open branch/PR) · **🔭 planned**
(design only). New operators start with [`RUNNING.md`](RUNNING.md), then read
[`ARCHITECTURE.md`](ARCHITECTURE.md).

## Operating & building

- [`RUNNING.md`](RUNNING.md) — end-to-end runbook (clone → build → keys → flash → provision → cluster).
- [`LOCAL-TESTING.md`](LOCAL-TESTING.md) — LAN `.test` fleet testing.
- [`LOCAL-STACK.md`](LOCAL-STACK.md) — `make stack-up` local-dev compose stack (opt-in upstream Synapse/Mastodon for dev only).
- [`DEVOPS.md`](DEVOPS.md) — GitLab CI, runner, binhost, build distribution.
- [`RESERVED-PREFIXES.md`](RESERVED-PREFIXES.md) — reserved `ROLE_`/`DOMAIN_` and route first-segment prefixes.

## Architecture

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full topology, gateway pattern, identity, multi-tenancy/superadmin, role cascade, and the roadmap.
- [`ROUTE-ACCESS.md`](ROUTE-ACCESS.md) — `gateway_route_access` model (incl. 🔭 MFA-required fail-closed gating).
- [`HEAVY-TIER.md`](HEAVY-TIER.md) — heavy datastores (Kafka/ClickHouse/Uptrace) on the x86 worker.

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

- [`OPTIONAL-SERVICES.md`](OPTIONAL-SERVICES.md) — akkoma/tuwunel/phpBB/games add/remove framework (✅ build-time, 🚧 live cut-over).
- [`EGRESS-VPN.md`](EGRESS-VPN.md) — outgoing public egress via operator `.conf`.
- [`NODE-STORAGE.md`](NODE-STORAGE.md) — attach + register node-pinned storage.
- [`GAMES-APPSTORE.md`](GAMES-APPSTORE.md) — per-domain FOSS game-server catalog + instance lifecycle.

## Client images

- [`CLIENT-IMAGES.md`](CLIENT-IMAGES.md) — per-user device images (FD-04 ✅ shipped; FD-06/07/08 + desktop-app governance 🔭 deferred).

## Testing

- [`TEST-ARCHITECTURE.md`](TEST-ARCHITECTURE.md) — test layering.
- [`FINAL-E2E-SWEEP-MATRIX.md`](FINAL-E2E-SWEEP-MATRIX.md) — end-to-end sweep matrix.

## Historical

- [`HANDOFF.md`](HANDOFF.md) — ⚠ **historical snapshot (2026-06-06)**; superseded by the per-feature docs above + git log. Do not treat its finish-list as current.
