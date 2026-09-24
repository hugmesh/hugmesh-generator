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
rather than judged by its text. The first triage (2026-09-09) found 24 done, 19 isolated,
70 needing coordination and 59 not work. After the #323 fan-out and a re-check on
2026-09-24, it stands at:

| | Count | Meaning |
|---|---:|---|
| ✅ already done | 48 | the work landed; the comment outlived it |
| 🚧 isolated, fixable | 0 | one person, one repo, no decision needed |
| 🔭 needs coordination | 65 | spans repos, or waits on a decision |
| — not work | 59 | a marker, a legend, or a deliberate placeholder |

The full triage is in [`roadmap-todos.tsv`](roadmap-todos.tsv), one row per comment.
A row that was re-checked says so and gives its evidence in a `[re-checked <date>]`
prefix.

### Nothing isolated is left

Every isolated row has been either fixed or reclassified. The last few went like this:

- The `hugmesh-actions` token mint had already landed.
- The `hugmesh-gateway` mTLS profile was already fixed at the root. A named fail-fast is
  open in hugmesh-gateway#42.
- `bundle_source` in Studio and the `hugmesh-games` input gates 2/3 both wait on
  decisions that their own TODOs spell out, so they moved to needs-coordination.

Open fixes for needs-coordination rows are named on the row itself:

- hugmesh-admin-bff-api#113 for the registry half of #106
- hugmesh-admin-bff-api#114 for the workload exec guard
- hugmesh-admin-ui#13 for step-up forwarding
- hugmesh-admin-ui#14 for the adminGuard decision

Such a row flips to done only when its PR merges.

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
