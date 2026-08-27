# HugMesh roadmap

One place for what is done, what is moving, and what is only planned.

Before this file, thirteen initiatives were restated across thirty-nine documents,
each with its own wording and its own idea of the status. Notifications appeared in
29 documents, multi-tenancy in 27, backups in 24. A reader had no way to tell which
copy was current, and neither did we.

**State convention** — the one already used across the repos, kept here:

| Mark | Means |
|---|---|
| ✅ | shipped: merged to `main` |
| 🚧 | in-flight: code on an open branch or PR, not merged |
| 🔭 | planned: designed or queued, no code yet |

A claim in this file is either **verified** — someone read the source and the line is
cited — or marked **asserted**, meaning it is carried over from a repo document and
nobody has re-checked it. Do not promote an assertion to a fact by repeating it.

## At a glance

| | Count |
|---|---|
| Documentation pages published | 279 |
| Architecture diagrams | 141 |
| Initiatives tracked here | 13 |
| TODO/FIXME comments we own | 172 across 25 repos |

Third-party TODOs are excluded from that count. The VRM and MToon Godot addons under
`hugmesh-character-forge-bff-api/godot/character-forge/addons/` carry 37 of their own,
and Emscripten output carries more. They are upstream's, not ours.

## Initiatives

### 🚧 SSO end-to-end, live and under test

The native-login model — each service's own login-ui posting to its BFF, Casdoor
reached server-to-server — is built. What is not finished is the end-to-end proof
against a running cluster.

**Verified:** the gateway's custody-swap leg ships **dark**.
`hugmesh-gateway/src/main/resources/application.yml` sets
`bff-exchange.enabled: ${HUGMESH_GATEWAY_BFF_EXCHANGE_ENABLED:false}`. The flag is
off unless an operator turns it on, so the docs saying "still ships dark" are
correct, not stale.

Restated in 14 documents.

### 🔭 Casdoor MFA — enrollment and step-up

The gateway layer merged dark (PR #40). The BFF challenge and step-up legs, WebAuthn,
TOTP and recovery codes are designed as a nine-PR plan and not yet built.

**Verified:** `app.mfa.enabled: ${APP_MFA_ENABLED:false}`. With it off the
`MFA_SATISFIED` marker is never derived and the `gateway_route_access.mfa_required`
column is inert. Every mesh this generator produces ships that posture today.

Restated in 21 documents.

### 🚧 Notifications — external channels

In-app notifications work. Matrix DM, Akkoma feed, phpBB and email delivery are the
open legs.

Restated in 29 documents — the most duplicated item in the tree.

### 🚧 Workload Console

A podman/OpenShift-like console in the host shell, with admin-bff gating in flight.

Restated in 15 documents.

### 🚧 Superadmin app-store — Tailnet-only federated remotes

The data layer (curation, app-profile) is shipped. The infra effectors and a
TAILNET-ONLY gateway posture are the open legs.

Restated in 15 documents.

### 🔭 Multi-tenancy provisioning

Domain scoping is shipped in the federation API. Materialising `domain_registry` rows
into a provisioned tenant is the open leg.

Restated in 27 documents.

### 🔭 Encrypted versioned backups

Per-domain and superadmin scope. Designed and queued.

Restated in 24 documents.

### 🔭 A/V via coturn / TURN

Matrix and Owncast audio-video is LAN-only until a TURN server lands.

Restated in 24 documents.

### 🔭 Device-license enforcement, Layer A

The registry and its signed export are shipped. Enforcement is not.

Restated in 19 documents.

### 🔭 Egress VPN and per-node attached storage

Restated in 15 documents.

### 🔭 Binhost fleet auto-update

Gentoo binhost-driven distribution across the fleet.

Restated in 10 documents.

### 🚧 Upstream supply-chain hardening

Base-image and binary checksum/GPG verification.

**Verified:** the pen-test stages are real, not aspirational.
`hugmesh-federation-api/.gitlab-ci.yml` declares
`stages: [security, dast, pentest, test, build]` with a `pentest:sca` job. Its
`allow_failure: true` is deliberate policy, not a broken gate.

Restated in 7 documents.

### 🔭 Auth-core relocation

Login, session and account logic moving out to `hugmesh-auth-core` and user-bff.
Named in one document only — the least duplicated item here, and the one most likely
to be forgotten.

## Studio: built, not yet released

The org profile called Studio "in development" and its screens "the planned
interface". That has not been true for some time.

**Verified:** `hugmesh-generator/studio/packaging/` carries the Flatpak manifest and
the WiX MSI sources, and `.github/workflows/` carries `studio-release.yml` and
`studio-tests.yml`.

**Also verified:** `studio-release.yml` has never run, and no `releases.json` exists,
so the download page has nothing to offer.

The honest status is neither shipped nor in development: **the installers are built
and tested; no release has been published.** Until the release job runs once, every
version, size and checksum on the download page is a placeholder.

## Code TODOs

172 TODO/FIXME comments across 25 repositories, each read in its surrounding source
rather than judged by its text. What came back:

| | Count | Meaning |
|---|---:|---|
| ✅ already done | 24 | the work landed; the comment outlived it |
| 🚧 isolated, fixable | 19 | one person, one repo, no decision needed |
| 🔭 needs coordination | 70 | spans repos, or waits on a decision |
| — not work | 59 | a marker, a legend, or a deliberate placeholder |

The full triage is in [`roadmap-todos.tsv`](roadmap-todos.tsv), one row per comment.

### 24 comments describe work that already shipped

These are the cheapest thing on this page: the code does the thing, and only the
comment still says otherwise. Deleting them costs nothing and stops the next reader
re-doing finished work. They cluster in `hugmesh-generator` (13) and
`hugmesh-mastodon-ui` (5).

### 19 are isolated and fixable now

| Repo | Location | Effort | What it asks for |
|---|---|---|---|
| `hugmesh-admin-bff-api` | `src/main/java/net/hugmesh/adminbff/imagegen/Fabric8ImageJobLauncher.java:76` | trivial | Suggests converting the KubernetesClient acquire/use/close inside apply() from a synchronous try-with-resources block to Mono.usingWhen for a more 'reactive' resource lifecycle |
| `hugmesh-admin-bff-api` | `src/main/java/net/hugmesh/adminbff/storage/Fabric8NodeStorageConfigMapWriter.java:65` | trivial | Suggests converting the KubernetesClient acquire/use/close inside writeAssignments() from a synchronous try-with-resources block to Mono.usingWhen for a more 'reactive' resource lifecycle |
| `hugmesh-admin-bff-api` | `src/main/java/net/hugmesh/adminbff/testreports/Fabric8JobLauncher.java:52` | trivial | Suggests converting the KubernetesClient acquire/use/close inside apply() from a synchronous try-with-resources block to Mono.usingWhen for a more 'reactive' resource lifecycle |
| `hugmesh-generator` | `tests/e2e/specs/18-rbac-phase8-10-pending.spec.ts:30` | small | Replace the test.skip() stub for 'host shell shows a ROLE_GAMES games entry-point only for games members' with a real Playwright assertion now that the host-shell UI it was waiting on has shipped |
| `hugmesh-auth-core` | `src/main/java/net/hugmesh/authcore/account/BffSession.java:26` | small | Javadoc TODO noting that neither BffSession nor Account persists the Casdoor UUID `sub`, only the folded provider:handle id, and that a consumer needing the real subject would need a new nullable casdoor_sub column plus a version bump |
| `hugmesh-mastodon-ui` | `src/app/notifications-column.component.ts:54` | small | Add auto-refresh to the notifications column — today it only re-fetches on an explicit filter switch/load-more/dismiss/clear-all, never on an interval or a push |
| `hugmesh-actions` | `e2e/scripts/bring-up-stack.sh:76` | small | The token-minting step of the e2e stack bring-up script is a stub: it logs a TODO and writes an empty {} to e2e/.tokens.json instead of actually acquiring per-role bearer JWTs from Casdoor |
| `hugmesh-gateway` | `checkstyle-suppressions.xml:18` | small | Verify whether this checkstyle-suppressions.xml is actually consumed by anything, since this repo's own pom.xml declares no checkstyle-maven-plugin/PMD/SpotBugs and deliberately opts out of the hugmesh-parent POM — then either wire checkstyle into this repo's build or remove the now-orphaned file |
| `hugmesh-generator` | `specs/cluster/manifests/networkpolicy/tier-egress.yaml:109` | small | The five *-bff-db/federation-db pods are excluded from tier-egress but have no Egress NetworkPolicy anywhere, leaving their egress default-allow; add a DNS-only egress policy for them |
| `hugmesh-games` | `docs/GODOT_DEVELOPER_GUIDE.md:7` | small | Finish the level->chapter terminology pass on this guide's prose (levels/level_id/level_assets/level_prerequisites -> chapters/chapter_id/chapter_assets/chapter_prerequisites) to match current source and CLAUDE.md's Naming section |
| `hugmesh-generator` | `.gitlab-ci.yml:1668` | medium | Make the mesh-node key-zip generation step probeable/skippable so test_mesh_node_worklist_starts_all_images can rejoin the studio-suite CI job instead of being deselected |
| `hugmesh-games` | `.gitlab-ci.yml:22` | medium | Add a real test-invocation stage (mvnw test / ng test / cargo test) to the pipeline; today build:image only compiles far enough to produce a runnable image, so a red unit/integration suite on main would not fail CI |
| `hugmesh-pki-gateway` | `README.md:206` | medium | Add the two deployed `signup-gate-signup`/`signup-gate-login` routes (with a SIGNUP_GATE_URI env-overridable default) to this repo's application-pki.yml and the Liquibase gateway_routes seed, ahead of the casdoor-* routes, matching the generator's ArgoCD Application so a stack built from only this repo's local-dev mirror doesn't bypass the confusable-username signup gate |
| `hugmesh-mod-ui` | `src/app/moderation-console.component.ts:278` | medium | Add the platform's MFA step-up gate (already shipped in admin-ui) in front of mod-ui's sensitive writes — ban/lift, domainLock/domainUnlock, and block — none of which currently require step-up MFA before submitting |
| `hugmesh-generator` | `tests/qemu/docker-entrypoint.sh:1072` | medium | Suspected OpenRC ordering bug: keys-provision's start() inline-starts headscale via `rc-service headscale start` while its own depend() also declares it must run 'before headscale', a double-start race deliberately left unfixed until captured guest logs pin the exact failure |
| `hugmesh-generator` | `tests/scripts/cluster_manifest_integrity.py:85` | medium | casdoor-pg and casdoor-games-pg are carried in the DB_ISOLATION_KNOWN_GAPS allowlist instead of getting the same per-pod NetworkPolicy + tier-ingress NotIn exclusion every other backend/pki Postgres pod already has under ADR-32 |
| `hugmesh-games` | `backend/src/main/java/games/hugmesh/bff/controller/InputEventController.java:152` | medium | Implement gates 2 and 3 (features.<kind> and game_event_support) so InputEventController.submit() checks a game's enabled event kinds before accepting an event, beyond today's (kind,type) reference-row gate |
| `hugmesh-games` | `docs/wiki/architecture/04-data-model.md:229` | medium | Implement validation gates 2 and 3 in InputEventController.submit() — checking the active game's games.features.<kind> flag and the game_event_support (game_slug, kind, type) opt-in table — so an input emit is refused (405) unless the game actually declared support for it, not just gate 1 (kind/type existing in the reference table) |
| `hugmesh-generator` | `studio/hugmesh_studio/core/config.py:1808` | large | Give `bundle_source` a tri-state unset representation (like tailscale/sso) so it stops emitting unconditionally on out-of-scope node builds, now that the sequencing exemplar it was waiting on has landed |

### Not work, and staying

59 matches are not tasks. Most are the host shell's **honest-disclosure
placeholders**: `/games` and `/games/admin` render a literal "TODO" badge rather than
fake a console that does not exist, and a spec asserts that badge is there. That is a
deliberate convention — a visitor sees an admission instead of a silent 404 — and the
grep finds it only because the word appears in the UI string. Leave them.

## Keeping this file true

Two rules, both learned the hard way:

1. **Edit the source, never the copy.** Every document on the docs site except three
   is a vendored projection of a repo. Editing the copy fails `check:integrity` and
   turns `main` red. Fix it in the repo and re-sync.
2. **Cite or mark it.** A status line with no source is an assertion. Say so, so the
   next reader knows what they are inheriting.
