# Final E2E sweep — the full control × role × layer matrix

This is the **authoritative enumeration** for the scaled-concurrent final sweep
(`tests/e2e/specs/24-final-e2e-sweep.spec.ts` + `swarm-driver.ts`). The spec wires
a **representative, non-truncated sample** of these rows as executable scenarios;
this document is the complete list so nothing is *silently* dropped. A row marked
**WIRED** has an executable scenario today; **DOC** rows are enumerated here and
activate as their surface lands (the framework primitive already exists for each).

## The population (procedural, deterministic)

`rbac-roles.ts → generateSwarm()` — default **120 plain users + 4 mods + 2 admins**
(overridable via `SWARM_USERS/SWARM_MODS/SWARM_ADMINS`). All share one deterministic
password (`E2E_SWARM_PASSWORD`); `seed-accounts.sh --roles --swarm N` seeds them and
**pre-mints a JWT per member** into `PREMINT_DIR` so 126 actors do not serialize at
Casdoor (`replicas: 1`) login. Mod *m* moderates the non-overlapping user block
`swarmTargetsForMod(m)` — "mods moderate those below them".

## Enforcement layers (the columns)

| layer | what it is |
|---|---|
| `casdoor` | role/claim issuance + derived-role sync (`ROLE_GAMES_ADMIN = ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD)`) |
| `gateway` | the `gateway_route_access` decision at fe/be/pki (most-specific allow row) |
| `bff` | BFF method-security / API gating (the application-layer half of a deny) |
| `homeserver` | akkoma MRF + Matrix power-levels (moderation effects) |
| `egress` | the egress NetworkPolicy + squid proxy (non-federation enforcement) |
| `ui` | rendered surface: nav visibility + **disabled controls carry helptext** |
| `sse` | per-principal action **messaging** on the live console feed |

## Concurrency invariant (applies to EVERY row)

The whole population acts **simultaneously**; `runConcurrently()` records peak
in-flight and the sweep asserts `maxInFlight >= floor`, so a run that silently
serializes (correct results, one at a time) **FAILS** — concurrency is contract.
**WIRED** — scenario (A).

## The matrix

### Plain user (`ROLE_USER`, ×120)

| # | action | casdoor | gateway | bff | homeserver | egress | ui | sse | status |
|---|---|---|---|---|---|---|---|---|---|
| U1 | read own home timeline | claim=ROLE_USER | ALLOW | ALLOW | — | — | nav shown | action ack | **WIRED** (A: the concurrent home-timeline hit) |
| U2 | hit `/api/admin/**` | — | DENY | DENY | — | — | control disabled + helptext | deny msg | **DOC** (gateway DENY is contract-locked in spec 17; helptext = E/DOC) |
| U3 | hit `/bff/admin/**` | — | DENY | DENY | — | — | hidden | deny msg | **DOC** |
| U4 | post a local toot | — | ALLOW | — | local-only if domain-locked | blocked-if-locked | — | post ack | **WIRED** via specs 19/22 (federation leg) |
| U5 | be MODERATED by its mod | — | — | (effect) | suspend/limit applies | — | state reflects | notified | **WIRED** (C, observed as the mod's ALLOW on the target) |

### Mod (`ROLE_MOD`, ×4 — SIBLING of admin, not a superset)

| # | action | casdoor | gateway | bff | homeserver | egress | ui | sse | status |
|---|---|---|---|---|---|---|---|---|---|
| M1 | moderate an assigned user (akkoma admin) | claim=ROLE_MOD | ALLOW | ALLOW | effect applied | — | panel shown | action msg | **WIRED** (B/C) |
| M2 | reach `/api/admin/**` (snapdragon admin) | — | **DENY** | **DENY** | — | — | hidden | deny msg | **WIRED** (B/C negative) |
| M3 | reach `/bff/admin/**` | — | **DENY** | **DENY** | — | — | hidden | deny msg | **WIRED** (B/C negative) |
| M4 | moderate an ADMIN or a peer mod | — | DENY (out of block) | DENY | no effect | — | disabled + helptext | deny msg | **DOC** (sibling rule under load; block scoping is M1's inverse) |
| M5 | reach infra/logs/server-admin | — | DENY (no route) | — | — | — | absent | — | **DOC** (contract-locked in spec 16) |
| M6 | Matrix/Mastodon user-floor (own use) | — | ALLOW | — | PL50 | — | shown | — | **DOC** (spec 16 ALLOW rows) |

### Admin (`ROLE_ADMIN`, ×2)

| # | action | casdoor | gateway | bff | homeserver | egress | ui | sse | status |
|---|---|---|---|---|---|---|---|---|---|
| A1 | global reconcile / announce | claim=ROLE_ADMIN | ALLOW | ALLOW | — | — | shown | **action msg over SSE** | **WIRED** (D) |
| A2 | reach the admin API + admin UI | — | ALLOW | ALLOW | — | — | shown | ack | **DOC** (spec 14 LIVE_GATEWAY) |
| A3 | reach the moderation surface (superset of mod) | — | ALLOW | ALLOW | effect | — | shown | ack | **DOC** (spec 16: admin ⊇ moderation) |
| A4 | suspend/role-assign across the population | — | ALLOW | ALLOW | effect | — | shown | targets notified | **DOC** |

### Cross-cutting (derived + denied)

| # | action | layer focus | status |
|---|---|---|---|
| X1 | `ROLE_GAMES ∩ ROLE_ADMIN` → derived `ROLE_GAMES_ADMIN` reaches `/games/admin/**` | casdoor→gateway | **DOC** (contract spec 12; gate spec 14) |
| X2 | `ROLE_GAMES` alone / `ROLE_ADMIN` alone → DENIED `/games/admin/**` | gateway | **DOC** (specs 12/16/17) |
| X3 | domain-locked user → toot/boost/announce does NOT federate; control DOES | homeserver+egress | **WIRED** (specs 19/20/21/22) |
| X4 | pending (no roles, registration incomplete) → denied every user surface | gateway+ui | **DOC** (spec 17/18) |
| X5 | every DISABLED UI control carries helptext (why-denied) | ui | **DOC** stub (E) — primitive `assertDisabledHasHelptext` ready; activates with the role-conditional host shell |

## WIRED vs DOC — why split

The gateway/bff **contract** assertions are already exhaustively covered by specs
12–18 (the `gateway_route_access` oracle). The final sweep's NEW value is the
**concurrent population** + the **per-layer + SSE + disabled-helptext** axes, so it
wires the rows that exercise *those* axes (A–D) and **documents** the rest here
rather than duplicating specs 12–18 at scale. As the role-conditional **UI** lands,
the **DOC** UI/SSE rows convert to **WIRED** by filling the spec-18-style stubs
with `assertDisabledHasHelptext` / `expectSse` — the framework primitives already
exist in `swarm-driver.ts`.
