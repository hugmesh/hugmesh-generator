# MFA rollout — operator runbook (gateway `mfa_required` floor + admin-bff step-up)

**Audience:** the operator who will actually turn MFA enforcement on. This is not a
design doc; it is the order of operations, the preconditions that will lock you out
if you skip them, and how to roll back.

**Default posture today: enforcement is OFF on a cluster and nothing here changes
that.** Seeding the `mfa_required` rules (below) is inert until *you* flip a flag.

---

## 0. Read this first: BOTH halves have landed

> **STATUS, verified against `main` on 2026-08-06.** This runbook was written on
> branch `feat/mfa-required-rules` while its companion `feat/gateway-mfa-env` was
> still open, and much of the text below was phrased for that moment. **Both halves
> are now merged.** The knob EXISTS: the shared chart carries an `mfa:` values block
> (`specs/cluster/charts/hugmesh-gateway/values.yaml`), its template renders
> `APP_MFA_ENABLED` / `APP_MFA_FRESHNESS_WINDOW` /
> `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` into every gateway pod, compose defaults
> `APP_MFA_ENABLED=true`, and `tests/stack/test-gateway-mfa-env.sh` pins both
> postures (101 passed / 0 failed, alongside `test-mfa-required-rules.sh` at 99/0).
> Confirmed on a live kind cluster: a running fe-gateway pod carries all three env
> vars, `APP_MFA_ENABLED=false`.
>
> So **§3 step 6 is actionable, not a no-op**, and every "needs the companion / until
> it lands there is no knob" caveat below is HISTORICAL. What has NOT changed is the
> hard precondition: enrolling every privileged operator (§2) still gates the flip,
> and the cluster still ships `false` deliberately.
>
> **Re-measured 2026-10-14 on `main` (c0c46601).** Nothing code-side is left to land:
> the chart block, the rendered env, the `mfa_required` rows (10 flipped + 1 deny row
> carrying the floor) and the posture gates are all present and green. What is left
> is the operator's live flip, and **§9 is the checklist for it, with the exact
> commands.** Two things in the older text were wrong and are corrected below rather
> than left to mislead: the flip changes **three** gate suites, not one (§3 steps 6
> and 7), and "do the floor on one gateway first" cannot be done through the chart
> (§3 step 7).

The feature shipped as **two halves in two commits**, and this runbook was written
with the first one. The table records which half contributed what.

| half | what it contains | where it is |
|---|---|---|
| **rows** (this change) | the `mfa_required` `UPDATE` in `20-schema.sql`, this runbook, `tests/scripts/test-mfa-required-rules.sh` | branch `feat/mfa-required-rules` |
| **flag wiring** (companion) | the shared chart's `mfa:` values block, the chart template that renders `APP_MFA_ENABLED` / `APP_MFA_FRESHNESS_WINDOW` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` into every gateway pod, the compose-stack defaults, `tests/stack/test-gateway-mfa-env.sh` | branch `feat/gateway-mfa-env` |

**What that meant on the authoring branch, kept for provenance:**

- **HISTORICAL (true only before the companion merged):** nothing in the chart, the
  gateway Applications or the compose stack mentioned the gateway MFA env, so the
  rows were not merely default-off but **unreachable** — no supported knob could make
  the gateway consult them. The verification command below was documented as printing
  exit `1`.

  On `main` today it prints **`0`**, and that is the correct, expected result:

  ```console
  $ grep -rn 'APP_MFA_ENABLED\|APP_MFA_ENFORCE_PRIVILEGED_FLOOR' \
      specs/cluster/charts specs/cluster/apps tests/stack/
  specs/cluster/charts/hugmesh-gateway/values.yaml:...   # the mfa: values block
  specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml:207: - name: APP_MFA_ENABLED
  tests/stack/test-gateway-mfa-env.sh:...                # the posture pins
  $ echo $?
  0
  ```

  If you are reading this on a checkout where that command still exits `1`, you are
  before the companion merge — treat the caveats below as live rather than historical.
- Do **not** work around that by hand-adding an `extraEnv: APP_MFA_ENABLED` to a
  gateway Application. That is exactly what the posture gate in
  `tests/scripts/test-mfa-required-rules.sh` fails the build on, structurally, in
  every ArgoCD input shape (`helm.values`, `helm.valuesObject`, `helm.parameters`,
  and a `helm.valueFiles` reference it refuses to treat as auditable).

**Merge order:** either order is safe — each half is inert without the other — but
they should land in the **same release**, and the two references between them only
resolve once both are in. The companion's
`specs/cluster/apps/22-gateway-superadmin.yaml` comment points at "the step-by-step
rollout runbook [that] arrives with the route-access `mfa_required` change", i.e. at
**this** file; and §1.3/§3 below point back at the companion's chart values. Merging
only the companion leaves a live flag with no row to match on (a no-op); merging only
this one leaves rows with no flag that can reach them (also a no-op). Merging neither
is today's posture.

Wherever a claim below was only true **after** the companion landed, it says so
explicitly. Nothing in this document is written as though the wiring were already here.

---

## 1. What is already wired vs. what you must flip

### 1.1 Already ON — the admin-bff step-up leg

`app.casdoor.mfa.enabled` is **already `true`** in both deployment targets:

| Where | File | Value |
|---|---|---|
| Cluster | `specs/cluster/manifests/admin-bff-api/deployment.yaml` (`APP_CASDOOR_MFA_ENABLED`) | `"true"` |
| Compose dev stack | `tests/stack/compose.local.yaml` (`APP_CASDOOR_MFA_ENABLED`) | `${APP_CASDOOR_MFA_ENABLED:-true}` |

This is the leg that lets a **fresh MFA stamp on the opaque `bff_` session** satisfy
a step-up gate (`ImageGenStepUpGate`, `PhoneLockStepUpGate`, `GoLiveStepUpGate`,
`SshKeyIssueStepUpGate`, …) as a co-equal alternative to the token-based step-up.
It is a pure additive OR — it does not gate ordinary login, and it does not gate any
route at the gateway. It also arms the enrollment/challenge API
(`/bff/mfa/**`); with the flag off, **every** `/bff/mfa/**` endpoint returns `503`.

Prerequisite for that leg, already provisioned: **`APP_MFA_FACTOR_KEY`** — see §4.

### 1.2 Already committed but INERT — the `mfa_required` route rules

`specs/cluster/manifests/route-access/initdb/20-schema.sql` now ends its seed with:

<!-- gate:doc-sql name=seed-update expect=identical-to-seed -->

```sql
UPDATE gateway_route_access
   SET mfa_required = true
 WHERE allow = true
   AND (url_pattern = '/bff/admin'
     OR url_pattern LIKE '/bff/admin/%'
     OR url_pattern = '/bff/superadmin'
     OR url_pattern LIKE '/bff/superadmin/%'
     OR (COALESCE(NULLIF(lower(trim(domain)), 'default'), '') <> ''
         AND url_pattern IN ('')))
   AND mfa_required IS DISTINCT FROM true;
```

(That block is not retyped prose: the gate compares it byte-for-byte against the
statement in `20-schema.sql`, so it cannot drift.)

The final `OR` is the **per-domain arm** (issue #47 × the casdoor-choice
schema): list a `url_pattern` in its `IN (…)` and every **domain-scoped** row
carrying it gets the same re-apply convergence the two blanket prefixes get.
It is **empty today** — the empty-string element matches no pattern, so the
flip set is exactly the 10 rows below — and §1.2a explains when (and when not)
to widen it.

That flips **10 rows** (as of this writing) across three gateways:

| gateway | url_pattern | role |
|---|---|---|
| `hugmesh-fe-gateway` | `/bff/admin/**` | `ROLE_ADMIN` |
| `hugmesh-fe-gateway` | `/bff/admin/phone-fleet/**` | `ROLE_FLEET_ADMIN`, `ROLE_ADMIN`, `ROLE_SUPERADMIN` |
| `hugmesh-fe-gateway` | `/bff/superadmin/**` | `ROLE_SUPERADMIN` |
| `hugmesh-be-gateway` | `/bff/admin/workloads/**` | `ROLE_ADMIN` |
| `hugmesh-be-gateway` | `/bff/superadmin/**` | `ROLE_SUPERADMIN` |
| `hugmesh-be-gateway` | `/bff/superadmin/games-services/**` | `ROLE_SUPERADMIN` |
| `hugmesh-be-gateway` | `/bff/superadmin/workloads/**` | `ROLE_SUPERADMIN` |
| `hugmesh-superadmin-gateway` | `/bff/superadmin/**` | `ROLE_SUPERADMIN` |

An **eleventh** row ends up at `mfa_required = true` without being flipped by this
`UPDATE`: the `hugmesh-fe-gateway` `/bff/superadmin/games-services/**` **DENY** row,
which the blanket flip cannot reach (`WHERE allow = true`) and which is seeded by its
own row-scoped `UPDATE` immediately before it. It is not in the table above because
this table is the flip's scope, not the floor's — see §5's deny-floor table for the
floor's full membership, and why a deny row carries one at all.

Read that table twice. `/bff/superadmin/**` is governed on **three** gateways —
`hugmesh-fe-gateway` joined the be and superadmin gateways when #244 was answered
ACCEPT — and `/bff/admin/…` on **two**; the write is prefix-based and gateway-blind on
purpose, because scoping it to one gateway name would leave the other as an
un-MFA'd second door to the same paths. Matching is **longest-pattern-wins**, so
flipping only the two `/**` floors would leave every longer sub-path row as the
*deciding* rule with `mfa_required=false` — a bypass on exactly the
highest-value surfaces (`phone-fleet`, `workloads`, `games-services`).
`tests/scripts/test-mfa-required-rules.sh` pins all of that, with negative controls.
Every **behavioural** verdict there is read back from a real SQL engine after
replaying the file's own statements in file order, never inferred from the text of
one statement — so a later statement that un-flips, deletes or partially reverts one
of these rows is caught by the *result*, in any spelling. (A handful of *intent*
checks are still textual — that the `UPDATE` is gateway-blind, allow-only, and says
`IS DISTINCT FROM true` — but nothing about the file's net effect is.) The default
engine is sqlite3, and a plain local run says so. Since leg 1c the seed is **also**
replayed verbatim on a real Postgres — twice, under `ON_ERROR_STOP`, nothing
translated or skipped — whenever `POSTGRES_HOST` is set, and `.gitlab-ci.yml`'s
`lint:mfa-required-rules` always sets it (a `postgres:16-alpine` service container).
That leg replays the **seed**; the runbook's own SQL blocks (§3 step 4, §9) are still
executed on sqlite only, so their first contact with Postgres is the operator's.
(Whether that CI job is running at all is not something this file can tell you.)

### 1.2a Scope: exactly two prefixes — and what that leaves OUT

The authorised scope is the **two path prefixes** `/bff/admin…` and
`/bff/superadmin…`, blanket *within* them. It is **not** "every admin surface", and
the difference matters if you are reasoning about what an attacker can still reach
with a stolen session and no second factor. Seven other admin-ish `/bff/` rows are
deliberately left `mfa_required=false`:

| gateway | url_pattern | role | why it is out of scope |
|---|---|---|---|
| `hugmesh-fe-gateway` | `/bff/forum/admin/**` | `ROLE_ADMIN` | per-service admin console seam behind its **own** service-BFF prefix, not under `/bff/admin`. Covering it needs a different predicate *shape* (`LIKE '/bff/%/admin/%'`) |
| `hugmesh-fe-gateway` | `/bff/wiki/admin/**` | `ROLE_ADMIN` | ditto |
| `hugmesh-fe-gateway` | `/bff/wiki/superadmin/**` | `ROLE_SUPERADMIN` | ditto — and the **most privileged** of the seven. Governed at the SUPERADMIN floor by #329 (so a plain `ROLE_WIKI` is now refused at the front door), but **not** MFA-gated: it is behind the wiki-bff's own service prefix, so the `UPDATE` cannot reach it without a new predicate *shape*. Flipping the per-service seams is the open operator decision |
| `hugmesh-fe-gateway` | `/bff/owncast/admin/**` | `ROLE_ADMIN` | ditto |
| `hugmesh-fe-gateway` | `/bff/mod/**` | `ROLE_ADMIN` | a **moderation** surface; `ROLE_ADMIN` is paired on it only as a superset of `ROLE_MOD`, so gating it would gate moderation, not administration |
| `hugmesh-be-gateway` | `/bff/image-builds/arch/**` | `ROLE_SUPERADMIN` | privileged by **role**, not by path — a prefix predicate cannot express it |
| `hugmesh-be-gateway` | `/bff/games-services/instances/**` | `ROLE_GAMES_SERVICES_ADMIN` | ditto (derived `games-services ∩ (admin\|mod)` role) |

Each of the three shapes above would be a **new scope decision**, not a bug fix:
widening enlarges the §3 step-7 lockout blast radius, so it is the operator's call.
If you do widen, widen the prose in the same commit — and note that the gate
enumerates admin-ish surfaces *independently* of the `UPDATE`'s own prefixes and
cross-checks them against exactly this list, so an **eighth** admin-ish `/bff/` row
appearing later fails the build until someone decides consciously (and a stale entry
in the list fails it too).

#### Per-domain MFA scope (several local domains behind the same gateways — issue #47)

`gateway_route_access` rows carry a per-row `domain`, and the casdoor-choice
schema (PR #71, `Domain.idp`) makes multiple local domains behind one set of
gateways a first-class shape. What a domain-scoped row can and cannot express
for MFA is fixed by `GatewayRouteAccessService.decide()` in `hugmesh-gateway`
— **verified against the source, not assumed**: among the rows at the longest
matching `url_pattern`, `decide()` ORs `mfa_required` across *every* row that
grants the principal and domain-applies, and an **unscoped** row
(`NULL`/blank/`default`, case-insensitive, trimmed) domain-applies to **every**
domain. Hence this scope table:

| you want | expressible? | how / why not |
|---|---|---|
| the blanket (two prefixes) on every domain, **including** rows someone scoped to one domain under them | **yes — enforced** | the seed `UPDATE` is **domain-blind**, deliberately, like it is gateway-blind. A scoped `mfa_required=false` row under the prefixes is a **phantom exemption**: the unscoped canonical row still applies to that domain and still pulls the MFA floor up, so the false row exempts nothing — the seed re-flips it to make the table say what the gateway does. And a scoped-**only** allow row (a per-domain admin surface with no unscoped twin) must not ship un-MFA'd inside the blanket |
| require a second factor on **one domain only**, on a surface outside the blanket (per-domain **tightening**) | **yes** | insert a domain-scoped sibling row — same `gateway`/`url_pattern`/`role`, its own `domain`, `allow=true`, `mfa_required=true`. `domainApplies()` keeps it off every other domain. To give it the same re-apply convergence the blanket has, also list its `url_pattern` in the `UPDATE`'s per-domain arm (§1.2) **and** in the gate's `PER_DOMAIN_SCOPE` set — the gate cross-checks the two in both directions |
| **exempt** one domain from the blanket | **no** | not by a row (see the phantom-exemption note — `decide()` is a sticky OR), and not by the predicate (the blanket rows are **unscoped**, and unscoped rows apply to every domain). A real per-domain exemption means splitting the canonical rows per domain — a new scope decision with the full §3 step-7 blast-radius conversation attached |
| an **own-IdP domain** (`Domain.idp: own`, PR #71) satisfying MFA | **no (today)** — see the source chain below | its principals authenticate against the domain-local Casdoor and can never carry `MFA_SATISFIED`. On a shared-gateway mesh, treat that whole population like the §2.4 machine callers: enumerate own-IdP domains **before** §3 step 6, or their non-privileged holders (e.g. a pure `ROLE_FLEET_ADMIN`) are 403'd on every `mfa_required` surface with no way to enroll |

##### Why an own-IdP principal cannot satisfy MFA — both legs, from the source

Re-verified 2026-08-20. §2.4 lists two carriers that CAN satisfy an `mfa_required`
route. An `idp: own` principal is closed out of **both**, and the two closures are
independent — fixing either one alone changes nothing:

1. **The opaque `bff_` session leg is unreachable.** `/bff/login` is bound to ONE
   Casdoor: `CasdoorLoginConfig` (hugmesh-user-bff-api) builds the single
   `CasdoorLoginClient` from `app.bff.oidc.login-base` + `app.bff.oidc.organization`,
   with no per-domain routing anywhere on that path. A user who exists only in the
   domain-local Casdoor therefore never gets a `bff_session` row at all.
2. **The raw-JWT leg never gets a stamp written.** `mfa_satisfied_at` is a user
   Property, and `CasdoorAdminClient.writeMfaProperty` (hugmesh-auth-core) writes it
   through the **superdomain's** admin client — never the domain-local Casdoor — so
   the claim cannot appear in a token minted by the domain's own issuer.

The tighter fact, and the reason raising the freshness window or pointing an admin
client at the tenant Casdoor would not be enough on its own: the `bff_session` row is
a **hard precondition for the Property write too**.
`MfaChallengeService.onSessionStamped` returns `false` and **skips the advisory
Property leg entirely** when the authoritative session stamp updates zero rows. So for
a principal with no `bff_session`, `POST /bff/mfa/challenge` cannot succeed and
`mfa_satisfied_at` is never written **in any Casdoor**. The blocker is the login
binding in (1), not only the Property's location in (2).

> **Cross-repo, and therefore NOT gate-pinned.** Everything above lives in
> hugmesh-user-bff-api and hugmesh-auth-core; the generator's gates cannot see either,
> so nothing here fails the build when one of those classes changes. Re-read all three
> call sites named above before §3 step 6 on any mesh that hosts an `idp: own` domain.

The uniqueness key makes the sibling-row idiom safe: `uq_route_access_row`
keys its domain leg on the **gateway's own scope equivalence**
(`COALESCE(NULLIF(lower(trim(domain)), 'default'), '')`), so a `'Default'` or
case/whitespace alias **collides** with the row it aliases instead of
duplicating it, while a genuinely scoped sibling keys differently and lands.
The tightening row shape, concretely — and this block is **executed** by the
gate against the replayed seed (inserted, then the whole seed re-applied over
it) to prove the row survives with `mfa_required=true` while its unscoped twin
stays `false`:

<!-- gate:doc-sql name=tightening expect=per-domain-tightening -->

```sql
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain, mfa_required)
VALUES ('hugmesh-fe-gateway', '/bff/wiki/admin/**', 'ROLE_ADMIN', true, 'brand-x.example', true)
ON CONFLICT (gateway, url_pattern, role, COALESCE(casdoor_user, ''), COALESCE(NULLIF(lower(trim(domain)), 'default'), '')) DO NOTHING;
```

Such rows are **provisioning/CRUD data, not canonical seed rows** — the
canonical seed stays domain-free because the reference mesh defines no extra
local domains. `brand-x.example` above is a placeholder; a real tightening row
carries the real domain and goes in through the admin-bff CRUD or a per-mesh
provisioning step, with the `url_pattern` listed in the per-domain arm in the
same change.

**These rows do nothing until a gateway flag is on.**
`GatewayRouteAccessService.decide()` consults `mfa_required` only when
`app.mfa.enabled` is true. And the converse is just as important: **`enabled: true`
alone was a NO-OP before these rows existed** — nothing else in the platform ever
wrote `mfa_required=true`, so the flag had nothing to match on. The flag and the
rules are two halves of one feature.

### 1.3 What YOU must flip — the gateway trio

The **`hugmesh-gateway` image** reads three properties (its own
`src/main/resources/application.yml`), all default-off in the image itself. That is
the operator-facing contract, and it is true today:

| property | env | image default (today, cross-repo) |
|---|---|---|
| `app.mfa.enabled` | `APP_MFA_ENABLED` | **`false`** (`${APP_MFA_ENABLED:false}`) |
| `app.mfa.freshness-window` | `APP_MFA_FRESHNESS_WINDOW` | `600000` (10 min) |
| `app.mfa.enforce-privileged-floor` | `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` | **`false`** |

**✅ The knob now EXISTS (companion merged — see §0).** The shared chart
`specs/cluster/charts/hugmesh-gateway` (used by **all four** gateway Applications:
`specs/cluster/apps/20-gateway-{pki,be,fe}.yaml` and
`specs/cluster/apps/22-gateway-superadmin.yaml`) carries an `mfa:` values block, and
its `templates/deployment.yaml` renders all three into every gateway pod. Verify that
yourself rather than trusting this sentence — the grep now EXITS 0, and a live pod
carries the env:

```console
$ grep -rn 'APP_MFA_ENABLED\|APP_MFA_ENFORCE_PRIVILEGED_FLOOR' \
    specs/cluster/charts specs/cluster/apps tests/stack/
$ echo $?
0

$ kubectl exec -n hugmesh-frontend deploy/hugmesh-fe-gateway -c gateway -- env | grep MFA
APP_MFA_ENABLED=false
APP_MFA_ENFORCE_PRIVILEGED_FLOOR=false
APP_MFA_FRESHNESS_WINDOW=600000
```

An earlier revision of this section asserted the opposite and told you to expect exit
`1`. That was true on the authoring branch and is now wrong; it is corrected rather
than deleted because an operator who hit the contradiction would reasonably have gone
looking for an unmerged companion that is in fact already in.

**Since the companion change (§0) landed**, the three are chart values —
`mfa.enabled` / `mfa.freshnessWindow` / `mfa.enforcePrivilegedFloor` in
`specs/cluster/charts/hugmesh-gateway/values.yaml`, rendered into every gateway pod —
with a deliberate asymmetry: the **cluster** chart default stays `false` while the
**compose dev stack** (`tests/stack/compose.local.yaml`, the `gateway-pki` /
`gateway-be` / `gateway-fe` services) defaults `APP_MFA_ENABLED=true`, so the
enforcement leg is exercisable end-to-end locally while a cluster ships dark. The
privileged floor is `false` on **both** sides.

> **Never turn gateway MFA on from a `specs/cluster/apps/*.yaml`.** Turning it on is
> an explicit, deliberate operator action taken *after* §2. The privileged floor is
> **not exempt for SUPERADMIN**, so enabling enforcement before operators hold a
> second factor locks you out of the privileged plane — with no in-band way back in.
> `tests/scripts/test-mfa-required-rules.sh` fails the build if any gateway
> Application sets it, and it checks that **structurally** rather than by grep: it
> parses `spec.source[s].helm.values` (a YAML *string*, block or flow style, comments
> and all), `helm.valuesObject`, and `helm.parameters` (including indexed names like
> `extraEnv[0].name`), for **both** spellings — the chart's `mfa.enabled` /
> `mfa.enforcePrivilegedFloor` and a raw `APP_MFA_*` container env injected through
> `extraEnv`, the raw escape hatch that bypasses the chart's `mfa:` block (it was the
> only mechanism before the companion landed; it is audited because it still works).
> A `helm.valueFiles` / `helm.fileParameters` reference, or an `APP_MFA_*`
> env sourced from a Secret, **fails the gate as un-auditable** rather than quietly
> reading as a pass. The chart's own `mfa:` defaults are asserted too, the moment
> that block exists.
>
> That parse only covers `specs/cluster/apps/*.yaml`, so a **second, separate sweep**
> covers everything else — every file under `specs/` plus `tests/stack/compose.local.yaml`
> — for a hardcoded `APP_MFA_ENABLED` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR`. It is
> shape-aware rather than a grep, because the file that renders env into **all four**
> gateway pods is a *Helm template* and therefore not parseable as YAML: it
> understands the Kubernetes env-list form (`- name:` and `value:` on separate
> lines, in either order), plain mapping keys, `[export] KEY=value`, and flow
> mappings. A `valueFrom` reference, or a literal `true` inside an open Helm
> `{{ if }}` block, is reported as **undecidable and fails** — while a value that
> simply defers to a chart value (`{{ .Values.mfa.enabled | quote }}`, i.e. what the
> companion change will look like) is left to the chart-values check above. The
> predecessor of this sweep was a two-stage grep that looked for the variable name
> on a line and then tested *that same line* for a true value, which the k8s
> env-list form defeats by construction; it would have passed while the shared chart
> template turned the privileged floor on for every gateway.

---

## 2. Hard precondition: ENROLL BEFORE YOU ENFORCE

**Every operator who holds `ROLE_SUPERADMIN`, `ROLE_ADMIN` or
`ROLE_GAME-MASTER` must have a working second factor enrolled, and must have
verified they can produce a fresh stamp, BEFORE `APP_MFA_ENFORCE_PRIVILEGED_FLOOR`
is turned on anywhere.**

Why this is not negotiable, from `GatewayRouteAccessFilter`:

- The privileged MFA floor runs **above** the `ROLE_SUPERADMIN` cross-domain bypass
  and the `ROLE_ADMIN`/`ROLE_GAME-MASTER` own-domain bypass. Those bypasses
  `return chain.filter(...)` *before* `decide()` is ever consulted, so the floor has
  to sit above them or the very roles whose MFA matters would never be gated.
  **SUPERADMIN is explicitly not exempt.**
- The floor **fails CLOSED on cold start**: before route-access has been primed from
  the datastore the gateway cannot know whether a path is an `mfa_required` surface,
  so every privileged request is held with **`503` + `Retry-After: 5`**. On a gateway
  restart your admin plane is briefly 503 for privileged callers by design.
- A privileged principal on an `mfa_required` surface without a fresh factor gets
  **`403`** with an `X-Route-Denied` response header.
- ⚠ **`enforce-privileged-floor` is NOT a sub-flag of `enabled`.** The filter checks
  it without consulting `app.mfa.enabled`, and `isMfaRequiredSurface()` has no
  enabled-guard either. Setting `APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true` makes the
  floor live **on its own**, even with `app.mfa.enabled=false`. Treat it as the
  single most dangerous flag in this runbook.

### 2.1 Enrolling

`/bff/mfa/**` (auth-core `MfaEnrollmentController`, `MfaChallengeController`):

| endpoint | purpose |
|---|---|
| `POST /bff/mfa/enroll/totp` | begin TOTP: returns the secret/QS to add to an authenticator |
| `POST /bff/mfa/enroll/totp/verify` | finish TOTP — **returns the recovery-code set ONCE** |
| `POST /bff/mfa/enroll/webauthn/options` → `POST /bff/mfa/enroll/webauthn/verify` | register a security key / platform authenticator |
| `GET /bff/mfa/factors` | list enrolled factors |
| `DELETE /bff/mfa/factors/{id}` | remove a factor (**step-up gated**) |
| `POST /bff/mfa/recovery/regenerate` | new recovery set (**step-up gated**) |
| `POST /bff/mfa/challenge` | produce the MFA stamp that satisfies the floor |

Enrollment is reachable while the floor is on: `/bff/mfa/**` has **no**
`gateway_route_access` row (neither in this seed nor in the gateway's baked
`CanonicalSeed`), and `hugmesh-fe-gateway` has no `/bff/**` floor row, so `decide()`
returns `NO_RULE` and the gateway forwards on the coarse `authenticated()` floor.
⚠ **If anyone ever adds a `/bff/**` floor row to the seed, re-check this** — a
`/bff/**` row would become the deciding rule for `/bff/mfa/**` and could make
enrollment unreachable exactly when it is needed.

### 2.2 The WebAuthn-only recovery-code lockout hazard

**Enroll TOTP first, or at least alongside WebAuthn. Do not enroll WebAuthn only.**

Recovery codes are issued *only* on the TOTP path
(`MfaEnrollmentService.verifyTotpEnroll` → `enableTotpAndIssueRecovery` →
`regenerateRecoveryCodesInternal`). `verifyWebAuthnEnroll` → `storeWebAuthnCredential`
issues **none**. And `POST /bff/mfa/recovery/regenerate` is itself step-up gated —
it requires a fresh stamp, which requires the factor you just lost.

So: **WebAuthn-only operator + lost/broken security key = no self-service recovery
path.** Once the privileged floor is on, that operator is locked out of
`/bff/admin/**` and `/bff/superadmin/**` and the only way back is the out-of-band
break-glass in §6.

Also capture the recovery codes at enroll time. They are shown **once** (hashes
only are stored) and a regenerate invalidates the previous set.

### 2.3 The 10-minute freshness window vs. the blanket prefixes

The rules use the operator-chosen **blanket** scope *within* the two prefixes
(§1.2a): every `/bff/admin…` and `/bff/superadmin…` allow row, not just the dangerous
verbs. Combined with the freshness window that means:

- Gateway window: `app.mfa.freshness-window`, default **600000 ms = 10 min**. A
  `mfa_satisfied_at` stamp older than that (or in the future) yields no
  `MFA_SATISFIED` marker.
- Native-login (opaque `bff_` session) callers: admin-bff applies
  `app.casdoor.mfa.freshness` (default **`PT10M`**) before reporting
  `mfaSatisfied`, and the gateway's `BffSessionAuthFilter` simply mirrors that
  boolean into the `MFA_SATISFIED` authority.

**Practical effect:** *all* work under those two prefixes — reading a dashboard,
listing announcements,
paging through audit rows — needs a stamp taken within the last 10 minutes, and a
long admin session will be interrupted roughly every 10 minutes. The operator
accepted this when choosing blanket scope. If it proves intolerable, the two
supported adjustments are (a) raise `APP_MFA_FRESHNESS_WINDOW` **and**
`APP_CASDOOR_MFA_FRESHNESS` together — they must agree, or the JWT and
opaque-session legs will disagree about who is fresh — or (b) narrow the `WHERE`
predicate in `20-schema.sql`. Do **not** hand-edit individual rows: see §5.

### 2.4 Which callers can satisfy MFA, and the one population that cannot

§2.3 describes the freshness window without saying how each carrier actually obtains a
stamp. The three carriers behave differently, and only one of them is genuinely stuck:

| carrier | how it obtains `MFA_SATISFIED` | can it satisfy an `mfa_required` route? |
|---|---|---|
| opaque `bff_` session (native web login) | `BffSessionAuthFilter` mirrors admin-bff's introspect `mfaSatisfied`; the session row is stamped **synchronously** by `MfaChallengeService`. | **Yes, immediately.** |
| raw Casdoor JWT for a **human** (desktop/PKCE `hugmesh-desktop`, or any password-grant client) | `CasdoorAuthorities` -> `Roles.isMfaSatisfied(jwt, now, 600000)` against the `mfa_satisfied_at` claim. The claim is a Casdoor **user Property**, so it enters a token only at MINT time — but these clients can **re-mint on demand** (`refresh_token`, `device_code`, `password`). | **Yes** — complete MFA through the BFF (which writes the Property), then re-mint/refresh **within the 10-minute window**. |
| raw Casdoor JWT from `client_credentials` (pure machine, no human behind it) | same path — but `mfa_satisfied_at` is a **user** Property and a client-credentials token has **no user subject**, so there is nothing to stamp. `POST /bff/mfa/challenge` also fails closed without an opaque session row and an enrolled factor. | **No. Not under any configuration — there is no second factor for a machine.** |

**⚠ Do not mistake "mint-time only" for "rarely".** An earlier draft of this section claimed
no raw-JWT caller could ever be fresh, reasoning that the claim lands only at mint and the
seeded `expireInHours` is 168 (4 for `user-bff`) against a 10-minute window. That reasoning
was **wrong**: `expireInHours` bounds how long a *stale* token stays valid, not how soon a
client may request a new one. `hugmesh-desktop` is seeded as a **public** PKCE client with
`refresh_token`, and its own seed comment states the intent — *"refresh_token so the device
can refresh after the BFF stamps the MFA Property"*. That flow works.

**What IS broken.** The seam that was supposed to make the stamp appear without the client
doing anything never runs: `MfaChallengeService` calls
`RawJwtRefreshService.forceRefresh(subject, null)` with a **literal `null`** refresh-token at
the only call site, so it always takes its no-op fallback branch. (`app.bff.oidc.enabled` is
`true` on the live pods, so the bean's presence is *not* the blocker — the argument is.) The
practical consequence is a usability trap, not a lockout: after completing MFA a raw-JWT
holder must **actively** re-mint inside the 10-minute window; nothing does it for them, and
a client that simply keeps using its existing token will keep being denied until it happens
to refresh. Note also a second re-mint path that bypasses `RawJwtRefreshService` entirely —
admin-bff `InternalAccountController.exchangeSessionRow()` calls `oidcExchange.refresh(...)`
directly when custody is near expiry.

> `RawJwtRefreshService`'s javadoc justified the no-op by claiming "GEN2 lowers the
> privileged-app `expireInHours` precisely so this natural-lifetime gap stays SHORTER than
> the MFA freshness window". **There is no such GEN2 change** (`git grep GEN2` finds an
> unrelated CI comment and a disk-partitioning note), and no seeded expiry is anywhere near
> 10 minutes. Corrected in hugmesh-auth-core #43 — do not restore that reasoning.

**What this means at the §3 step-6 / step-7 flip.** Human operators are fine on both
carriers. The population to enumerate first is **machine `client_credentials` traffic** on
`/bff/admin…` and `/bff/superadmin…`: it has no supported path to a second factor, so once
`APP_MFA_ENABLED=true` it is denied there permanently, and the step-7 privileged floor denies
it outright (**`ROLE_SUPERADMIN` is not exempt**). If any exists, the options are to leave the
floor off, narrow the rows (§2.3 (b)), or move that caller to a service account driving an
opaque session. Raising `APP_MFA_FRESHNESS_WINDOW` does not help it at all — the claim is
absent, not stale.

**That enumeration has been done once — 2026-08-06, and it came back CLEAN.** Recorded here
so the operator inherits the answer rather than the chore, with the commands to re-run it,
because it is a point-in-time result and a new service could invalidate it.

*Static, across all 38 repos.* Seven code sites use the `client_credentials` grant
(admin-bff `FederationOverrideClearClient` / `FederationResolvedFindingsClient` /
`UserBffCharacterModerationClient`, mesh-bff `UserBffMeshDeviceClient`, actions
`FederationUsernameClientConfig`, user-bff `ServiceTokenBroker`, remote-fragment
`CasdoorTokenClient`). **None targets `/bff/admin…` or `/bff/superadmin…`**, and every one
dials its peer **directly** over cluster DNS (`…svc.cluster.local:8080`, or the Matrix /
Mastodon homeserver) rather than through a gateway — so gateway route-access, and therefore
the MFA floor, never applies to that hop at all.

Exactly one server-side caller anywhere touches a gated prefix: mod-bff's
`AdminDomainLockClient` (`POST`/`DELETE /bff/admin/domain-lock/{platform}/{user}`). It is
**not** machine traffic — `AdminApiConfig` builds it with
`BearerForwardingFilter.forwardCallerToken(...)`, so it carries the **human moderator's**
token, and it also dials admin-bff directly. Both reasons independently put it outside the
floor. The only other two hits (`auth-core GatewayRevocationClient`, forum-bff
`PhpbbAdminClient`) are javadoc prose, not calls.

*Empirical, against the live kind cluster.* Casdoor has issued **80 tokens, 100 % of them
user-bound, zero machine tokens** — `app-built-in` 48 (`profile`) and `app-user-bff` 32
(`openid profile email`).

```console
# static: any machine caller of the two gated prefixes?
$ git grep -nE '"/bff/(admin|superadmin)' -- src/main/java     # per repo; exclude @*Mapping
# empirical: has any machine (user-less) token ever been issued?
$ kubectl exec -n hugmesh-pki <casdoor-pg-pod> -- psql -U casdoor -d casdoor -tAc \
    "SELECT application, CASE WHEN COALESCE(\"user\",'')='' THEN 'machine' ELSE 'user-bound' END,
            count(*) FROM token GROUP BY 1,2;"
```

**So step 6 is clear on this precondition today.** Re-run both checks if a new service is
added, if an existing one starts calling those prefixes, or if any caller is moved behind a
gateway instead of cluster-DNS.

**One knob that moves a `bff_` carrier onto the JWT path.**
`hugmesh.gateway.bff-exchange.enabled` (default **false**, set in no manifest) makes
`BffJwtExchangeWebFilter` rewrite `Authorization: bff_…` into the custody Casdoor JWT
*before* Spring Security. With it on, an opaque carrier reaches the gateway as a `Jwt`
principal and takes the mint-time path in row 2 instead of the synchronous row 1. Turn it on
only together with a re-read of this section.

`tests/scripts/test-mfa-raw-jwt-posture.sh` pins this taxonomy to the seed: it derives each
seeded app's grant types, classifies which can re-mint, and fails if a caller that cannot
re-mint appears without this section naming that population — or if the debunked
bounded-gap reasoning is reintroduced anywhere.

---

## 3. Order of operations

Do these in order. Do not batch them. **All seven steps are actionable on `main`
today** — steps 6–7 were gated on the companion change from §0, which has merged.

1. **Verify the factor key exists** (§4). Without it TOTP enroll refuses, so nobody
   can enroll and step 3 would be a lockout.
2. **Fix WebAuthn RP-ID / origins for your real domain** (§4) — otherwise
   `navigator.credentials.create()` fails in the browser and only TOTP works.
3. **Enroll every privileged operator** (§2). TOTP at minimum. Record recovery
   codes. Have each operator prove they can complete `POST /bff/mfa/challenge` and
   then reach an admin page. Do this while enforcement is still off — the
   enrollment API is already armed because `APP_CASDOOR_MFA_ENABLED=true`.
4. **Seed the rules.** They ship in `20-schema.sql`. On a fresh cluster the
   route-access-db initdb applies them; on an existing cluster re-apply that file
   against `route-access-db`. The `UPDATE` is idempotent
   (`mfa_required IS DISTINCT FROM true`) and converges for both cases — an
   `INSERT` would not, because `ON CONFLICT DO NOTHING` skips rows that already
   exist and would leave `mfa_required=false`. Re-applying the file on an existing
   cluster also repairs the column shape: `mfa_required` was first added by an
   `ALTER … ADD COLUMN` that was **nullable** while the `CREATE TABLE` declares it
   `NOT NULL`, so an upgraded cluster could hold `mfa_required = NULL` — a third
   state the gateway's boolean read path is not written for. The file now
   backfills the NULLs and re-asserts `DEFAULT false` / `NOT NULL`; all of that is
   a no-op on a cluster that is already correct. Verify with:

   <!-- gate:doc-sql name=verify expect=flipped -->

   ```sql
   SELECT gateway, url_pattern, role, mfa_required
     FROM gateway_route_access
    WHERE allow = true
      AND (url_pattern LIKE '/bff/admin%'
        OR url_pattern LIKE '/bff/superadmin%')
    ORDER BY 1, 2, 3;
   ```

   Expect the 10 rows in §1.2 at `true` — and read what this query does **not**
   show you before you act on it. The `allow = true` clause is not cosmetic: it is
   the **same predicate the flip `UPDATE` uses**, so this query and that `UPDATE`
   agree on scope by construction rather than by coincidence. Since 2026-09-17 that
   scoping also **hides one row**. The seed now carries an `allow = false` row under
   the superadmin prefix — `hugmesh-fe-gateway` `/bff/superadmin/games-services/**`,
   reinstated by operator decision 28 = **D** (hugmesh-generator#347) — and that row
   carries the floor **too**. **Eleven** rows end up at `mfa_required = true`; this
   query returns ten of them. A deny row denies at the longest match regardless of
   MFA, which is why the flip leaves it alone, and why an operator reading an
   un-filtered result would see a `false` under a "fully flipped" prefix and think
   the rollout had failed. Do not now make the opposite mistake: the eleventh row is
   **not** missing from the rollout, and the step-up floor is **not** off for the
   games app-store subtree. To audit the **floor** rather than the flip, use:

   <!-- gate:doc-sql name=floor expect=every-floor-row -->

   ```sql
   SELECT gateway, url_pattern, role, allow, mfa_required
     FROM gateway_route_access
    WHERE mfa_required = true
    ORDER BY allow, 1, 2, 3;
   ```

   Expect **11** rows: the 10 above at `allow = true`, plus the one `allow = false`
   row in the table below. That row **keeps** the floor over its whole subtree
   rather than removing it, because the gateway computes the privileged step-up
   floor with `GatewayRouteAccessService.isMfaRequiredSurface()` — longest matching
   `url_pattern`, then `if (r.mfaRequired()) return true;`, with **no** `allow` test
   and **no** role test — and not with `decide()`, whose MFA leg is raised only on
   the arms that GRANT the principal. The blanket flip (`WHERE allow = true`) can
   never reach a deny row, so this one is seeded by its own row-scoped `UPDATE` in
   `20-schema.sql`, placed immediately before the flip.

   <!-- gate:deny-floor -->

   | gateway | url_pattern | role | why it carries the floor while denying |
   |---|---|---|---|
   | `hugmesh-fe-gateway` | `/bff/superadmin/games-services/**` | `ROLE_SUPERADMIN` | #347 decision 28 = D — the games app-store control plane is walled at the public browser door **and** stays inside the privileged step-up floor. |

   Any other `allow = false` row at `mfa_required = true` is a defect, and the
   reverse is a lie: `tests/scripts/test-mfa-required-rules.sh` fails on a deny row
   at `true` that is not in this table (`DENY_TRUE_UNDECLARED`), on a table row the
   seed does not carry (`DOC_DENY_MISSING` / `DENY_DECLARED_MISSING`), and on this
   table disappearing.

   > Settled, 2026-09-17 — operator decision 28 = **D** (hugmesh-generator#347),
   > landed by hugmesh-generator#484. History, because this note has now said both
   > things. `integrate/superadmin` added the `allow = true` clause **and** the deny
   > row that motivated it (`hugmesh-fe-gateway`
   > `/bff/superadmin/games-services/**`). On the 2026-09-16 merge the clause landed
   > and the row did not: operator decision 8 (#244 ACCEPT) is SPECIFIC to that row
   > and was answered "without the games-services deny row", while decision 20
   > ("land the whole branch") is the LATER, GENERAL one — recency argued for the
   > row, specificity against it, the specific answer was applied and the choice was
   > parked for the operator as decision 28. Decision 28 answers it: the row goes
   > back in, with `mfa_required` seeded true on the row itself. That 2026-09-16 note
   > also said the row "strips the floor". **That was read off the wrong function** —
   > `decide()`, whose MFA leg is grant-scoped, rather than
   > `isMfaRequiredSurface()`, which the privileged floor actually calls — and it is
   > why leaving the row out looked forced. See the paragraph above the table. The
   > `integrate/superadmin` branch also wrote "every row" in place of "the 10 rows"
   > here, predating the count becoming 10 under the same ACCEPT.

   To see the **scope boundary** instead — the 10 gated rows *and* the seven §1.2a
   rows that are `false` by design — use this, which is the same admin-ish
   enumeration the gate itself performs (path segment `admin`/`superadmin` **or**
   an `*_ADMIN`/`SUPERADMIN` role, which is how the three role-privileged
   exclusions get in at all):

   <!-- gate:doc-sql name=boundary expect=adminish -->

   ```sql
   SELECT gateway, url_pattern, role, mfa_required
     FROM gateway_route_access
    WHERE allow = true
      AND url_pattern LIKE '/bff/%'
      AND (url_pattern LIKE '%admin%' OR role LIKE '%ADMIN%')
    ORDER BY mfa_required, 1, 2, 3;
   ```

   Expect **17** rows: the 10 at `true`, then the 7 §1.2a exclusions at `false`.
   ⚠ Do **not** use `LIKE '/bff/%admin%'` for this — an earlier revision of this
   runbook said that form "also returns the six §1.2a rows". It does not: it
   returns **four** of the seven, because `/bff/mod/**`,
   `/bff/image-builds/arch/**` and `/bff/games-services/instances/**` have no
   `admin` substring in `url_pattern` at all and are excluded by **role**. An
   operator reading that output would conclude those three privileged surfaces
   were inside the gate. Both blocks above are now *executed* by
   `tests/scripts/test-mfa-required-rules.sh` against the replayed seed and
   compared against the real row sets, so neither can drift back into prose that
   is merely plausible. **Still no behaviour change at this point.**
5. **Exercise it in the compose dev stack first.** Compose mounts the *same* seed
   file (`tests/stack/compose.local.yaml` mounts
   `specs/cluster/manifests/route-access/initdb/20-schema.sql` into
   `/docker-entrypoint-initdb.d/`), so a `make stack-up` on a fresh
   `route-access-pg` volume seeds the rows locally. ⚠ **The enforcement leg is only
   exercisable once the companion change (§0) has landed** — that is what sets
   `APP_MFA_ENABLED=true` on the compose gateways. Before then compose seeds the rows
   and ignores them, exactly like a cluster. After it lands you get the real
   enforcement leg for the non-privileged case (see §3.1) — and you can rehearse
   step 7's privileged floor itself, per run and lockout-free, with
   `make stack-up MFA_FLOOR=1` (a Makefile variable; it threads
   `APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true` into the compose gateways for that
   run only, and expands to nothing otherwise, so the committed compose default
   stays `false` and a plain `make stack-up` is byte-identical).

   `tests/e2e/specs/29-mfa-privileged-floor.spec.ts` is the end-to-end proof for
   both modes. Run it **twice**:

   | stack | run as | what it proves |
   |---|---|---|
   | `make stack-up` | `npx playwright test 29-mfa-privileged-floor` | a pure `ROLE_FLEET_ADMIN` is 403'd on `/bff/admin/phone-fleet/**` without a stamp, and — §3.1's small print — the *same* admin on the *same* blanket is **not** gated |
   | `make stack-up MFA_FLOOR=1` | `MFA_FLOOR=1 npx playwright test 29-mfa-privileged-floor` | the floor: admin 403 without a fresh factor, a real TOTP enroll + step-up challenge driven through the shipped login-ui pages, the same route then passing, and a non-`mfa_required` surface untouched |

   The floor legs are the ONLY thing `MFA_FLOOR=1` un-gates in that spec; every
   other precondition FAILS loudly rather than skipping. Two of those are worth
   knowing before you blame the code:
   * the seed rows land through **initdb**, which runs only on a *fresh*
     `route-access-pg` volume — `make stack-clean` before `make stack-up`, or an
     older volume will enforce nothing;
   * the enroll leg needs the admin-bff MFA surface live
     (`APP_CASDOOR_MFA_ENABLED=true` **and** `APP_MFA_FACTOR_KEY`, both already
     defaulted in `compose.local.yaml`), and the `e2e-fleet` persona from
     `tests/stack/seed-e2e.sh` — a deliberate `ROLE_FLEET_ADMIN` + `ROLE_USER`
     account with **no** `ROLE_ADMIN`, since an admin would bypass `decide()` and
     the fleet leg would prove nothing.

   Note compose has **no** superadmin gateway — only pki/be/fe.
6. **Turn on `APP_MFA_ENABLED` for the cluster gateways** — the companion (§0) has
   landed, so this step is **actionable today**. Hand-adding an
   `extraEnv: APP_MFA_ENABLED` to a gateway Application still fails the posture gate
   on purpose. Set the shared chart's `mfa.enabled` value: all four
   gateway Applications point at the one chart, so a chart-level default reaches all
   four; keep it out of the per-app manifests (the gate enforces that). Watch for
   403s from non-privileged holders of `ROLE_FLEET_ADMIN`.
   ⚠ **This is the step that permanently denies machine `client_credentials` traffic.**
   A client-credentials token has no user subject, and `mfa_satisfied_at` is a Casdoor
   *user* Property — so there is nothing to stamp and no second factor to enrol.
   Enumerate any such caller on `/bff/admin…` / `/bff/superadmin…` **before** this flip.
   Human callers are fine on both carriers, but a raw-JWT human must **re-mint** after
   completing MFA (nothing does it for them). Read §2.4 before flipping.

   ⚠ **The flip commit changes THREE gate suites, not one.** An earlier revision of
   this step named only `tests/stack/test-gateway-mfa-env.sh`. Measured 2026-10-14 on
   `main` (c0c46601) by setting `mfa.enabled: true` in the shared chart's
   `values.yaml` and nothing else, then running every MFA suite
   (`tests/scripts/test-mfa-required-rules.sh`, `tests/scripts/test-mfa-raw-jwt-posture.sh`,
   `tests/stack/test-gateway-mfa-env.sh`, `tests/stack/test-mfa-flip-wiring.sh`):

   | suite | result | what goes red | what the flip commit has to do |
   |---|---|---|---|
   | `tests/stack/test-gateway-mfa-env.sh` | **8 FAIL** | (2) chart value is not boolean `false`; (4) ×5 — each of the four rendered releases **and** the bare chart defaults emit `APP_MFA_ENABLED=true` against the pin; (6) `ASYMMETRY LOST: compose='true' cluster='true'`; (8a) `MUTATOR DID NOT LAND` | set `EXPECT_APP_MFA_ENABLED="true"` (the `EXPECT_*` table near the top); then decide what (6) means once both sides are `true` (the script refuses to run when `EXPECT_APP_MFA_ENABLED` and `CEXPECT_APP_MFA_ENABLED` agree — replace the asymmetry self-check with an explicit "cluster and compose are both ON" pin, do not delete it); and invert (8a)'s mutator, which today rewrites `enabled: false` to `true` and therefore finds nothing to mutate |
   | `tests/scripts/test-mfa-required-rules.sh` | **1 FAIL** | the posture block: *"the shared chart's mfa: block defaults BOTH enabled and enforcePrivilegedFloor off"* | this check has **no `EXPECT_*` table** — the OFF state is hard-coded in the `case "$(q CHART_MFA_BLOCK)"` arm (`CHART_MFA_ENABLED` must be `not-true`). Change the `enabled` half to `true`, keep the floor half `not-true`, and reword the message |
   | `tests/stack/test-mfa-flip-wiring.sh` | **1 FAIL** | (5a) `chart values mfa.enabled changed` — the chart default is hard-coded `false` there too | change the (5a) pin to `true` and its message |
   | `tests/scripts/test-mfa-raw-jwt-posture.sh` | green | — | nothing; it pins the §2.4 taxonomy, not the posture |

   All three red suites are the *posture* pins the operator chose on purpose; red is
   the signal to move them **deliberately in the same reviewed commit**, not to
   delete a gate. Do **not** put the flip in a branch that only touches
   `values.yaml`: CI will be red for three independent reasons and the reviewer has
   no list. `.github/workflows/shell-suites.yml` and `.gitlab-ci.yml` wire these
   suites by path, so none of those files needs an edit for the flip itself.
7. **Only then consider `APP_MFA_ENFORCE_PRIVILEGED_FLOOR`** — same chart value
   (`mfa.enforcePrivilegedFloor`), also available today. This is the step that
   actually gates admins and superadmins. Expect 503s during each gateway's
   cold-start priming window, and keep a second authenticated superadmin session open
   on another browser as a canary.

   ⚠ **Pin rule, measured the same way (2026-10-14: `mfa.enforcePrivilegedFloor:
   true` alone).** Two suites go red; `test-mfa-flip-wiring.sh` and
   `test-mfa-raw-jwt-posture.sh` stay green:

   | suite | result | what goes red | what the flip commit has to do |
   |---|---|---|---|
   | `tests/stack/test-gateway-mfa-env.sh` | **6 FAIL** | (2) `mfa.enforcePrivilegedFloor wrong`; (4) ×5 — four releases + chart defaults emit `APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true` | `EXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR="true"` (cluster only — `CEXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR` stays `"false"`: the dev stack floor stays off in the committed file and `make stack-up MFA_FLOOR=1` is the per-run override that does not touch the pin) |
   | `tests/scripts/test-mfa-required-rules.sh` | **1 FAIL** | the same posture-block check as step 6, floor half | change the floor half of that arm to `true`; the no-app-manifest-turns-the-floor-on check stays as is |

   Rehearse it first on compose with `make stack-up MFA_FLOOR=1` +
   `tests/e2e/specs/29-mfa-privileged-floor.spec.ts` — the only place the floor's
   behaviour is exercised end to end.

   ⚠ **"Do the floor on one gateway first" cannot be done through the chart, and an
   earlier revision of this step told you to.** Verified from the manifests:
   * all four gateway Applications render the **one** chart, so a chart value reaches
     all four at once;
   * a per-Application override in `specs/cluster/apps/*.yaml` is exactly what the
     posture gate fails the build on (§1.3), in every spelling;
   * both the root Application (`specs/cluster/app-of-apps.yaml`: `recurse: true`,
     `automated: {prune: true, selfHeal: true}`) **and** each gateway Application
     (`syncPolicy.automated: {prune: true, selfHeal: true}`) revert a hand-patch of the
     Application or of the Deployment env, so `kubectl set env` and `kubectl patch app`
     last until the next reconcile.
   The honest options are: **(a)** flip all four from one reviewed commit and rely on
   the canary session plus §6's rollback (the default, and what §9 phase E gives
   commands for); **(b)** a deliberate, temporary GitOps bypass for a single gateway
   (§9 phase E-bypass — it works only while auto-sync is suspended and leaves drift
   that must be reverted); or **(c)** a gate change that lets a named gateway
   Application carry its own pin — a new scope decision for the operator, not
   something the runbook can assume exists. Note which paths each gateway owns before
   choosing: `hugmesh-fe-gateway` carries `/bff/admin/**`, `phone-fleet` and
   `/bff/superadmin/**`; `hugmesh-be-gateway` carries `/bff/admin/workloads/**` and
   `/bff/superadmin/**`; `hugmesh-superadmin-gateway` carries `/bff/superadmin/**`
   (§1.2). A floor on `fe` alone leaves the `be` and `superadmin` doors un-floored.

### 3.1 What actually changes at each step (be honest about the small print)

With `enabled=true` but `enforce-privileged-floor=false` — the recommended
intermediate state — `ROLE_SUPERADMIN`, `ROLE_ADMIN` and `ROLE_GAME-MASTER`
short-circuit in `GatewayRouteAccessFilter` **before** `decide()` runs. So of the 10
flipped rows, the only one that changes behaviour is
**`/bff/admin/phone-fleet/** → ROLE_FLEET_ADMIN`**: a pure fleet owner is not
privileged, so it reaches `decide()`, and without a fresh `MFA_SATISFIED` marker it
gets a 403.

That is the whole point of the two-flag design, but it means: **do not read a quiet
cluster after step 6 as evidence that admin MFA works.** It does not gate admins
until step 7.

---

## 4. Preconditions in detail

### 4.1 Factor key (`APP_MFA_FACTOR_KEY` / `app.mfa.factor-key`)

A 256-bit AES-GCM data key. `MfaSecretCipher` uses it to encrypt every enrolled TOTP
secret at rest, and it keys the recovery-code HMAC.

- Cluster: `specs/cluster/manifests/admin-bff-api/deployment.yaml` reads it from ESO
  Secret `admin-bff-mfa`, key `factor-key` — the ref is **REQUIRED** (no `optional:`).
  The ExternalSecret is in
  `specs/cluster/manifests/external-secrets/secretstore.yaml`; the value is minted
  by `scripts/gen-cluster-secrets.sh` (`openssl rand -base64 32`) into Vault at
  `secret/<brand>/admin-bff-mfa.factor_key`.
- Compose: `tests/stack/compose.local.yaml` `APP_MFA_FACTOR_KEY` has a dev default.
  **It is a committed dev value — never reuse it outside compose.**
- An absent Secret now **blocks pod start** at the Kubernetes layer
  (`CreateContainerConfigError` naming `admin-bff-mfa`), instead of booting a pod
  whose cipher is INERT and whose TOTP enroll / recovery generation silently
  **refuse** (no plaintext fallback). That silent-enrollment-failure mode was why
  the ref used to be `optional: true`; with `app.casdoor.mfa.enabled` armed
  in-cluster the key is load-bearing, so a missing key is now a loud scheduling
  failure with a clear reason — still step 1, but you find out from `kubectl get
  pods`, not from a user's failed enrollment. `test-cluster-manifest-integrity.sh`
  pins both the required posture and that the ref's `name`/`key` match what the
  ExternalSecret actually materializes.
- Rotating this key **orphans every enrolled TOTP secret and every recovery-code
  hash.** Treat it as unrotatable without a re-enrollment campaign.

### 4.2 WebAuthn RP-ID and origins

WebAuthn binds a credential to an **RP-ID** (a registrable domain) and an exact
origin. The auth-core defaults are localhost-shaped and wrong for any real deploy.

`specs/cluster/manifests/admin-bff-api/deployment.yaml` sets them explicitly:

```yaml
- name: APP_MFA_WEBAUTHN_RP_ID
  value: "admin.hugmesh.net"
- name: APP_MFA_WEBAUTHN_ORIGINS
  value: "https://admin.hugmesh.net"
```

For your own domain these must be rewritten (the `rebrand_sysroot` path rewrites
`admin.hugmesh.net` → `admin.<domain>` per tenant — confirm it did). Rules:

- RP-ID must be the registrable suffix of every origin the admin UI is served from.
  A credential registered under one RP-ID **cannot** be asserted under another —
  changing RP-ID later invalidates every enrolled key.
- Origins must be the exact `https://host[:port]` strings the browser sends,
  including every alias operators actually use. HTTPS is mandatory (except
  `http://localhost`).
- If operators reach the console over the tailnet on a different hostname than
  `admin.<domain>`, that origin must be listed too, or WebAuthn silently fails
  there and only TOTP works.

### 4.3 Two things that look like levers and are not (re-read 2026-10-14)

* **`role_mfa_policy` enforces nothing.** admin-bff carries a per-`(domain, role)`
  `role_mfa_policy` table with an admin write path (`RoleMfaPolicyService`,
  `RoleMfaPolicyController`; changelog `150-mfa-substrate.xml`). Its own javadoc is
  explicit that "nothing in the request pipeline consults it yet" — `/bff/login`,
  `/bff/session`, the introspect leg and the step-up gates behave as before, and the
  gateway's route-level enforcement stays behind `app.mfa.enabled`. Editing a row
  there will not gate anyone and is not part of this rollout. (The service pins
  `superadmin` and `admin` to `required=true` regardless of any row, mirroring §2.)
  Cross-repo, so not gate-pinned.
* **`MfaPreconditionBootGuard` (auth-core) only WARNs by default.** It reports a
  missing factor key and a loopback WebAuthn RP-ID/origin allowlist (§4.1, §4.2) with
  a `*** MFA MISCONFIGURED ***` banner in the admin-bff log, and aborts the boot only
  if `APP_MFA_PRECONDITIONS_FAIL_FAST=true` is set — which no manifest here sets.
  Absence of the banner is a useful signal (§9 phase C2 greps for it) but not a gate;
  whether the **deployed** admin-bff image carries the guard depends on its pinned
  version, which this repo cannot see.

---

## 5. Do not hand-edit rows

The admin-bff is the CRUD writer for `gateway_route_access`, so you *can* flip an
individual row's `mfa_required` through the admin API. Don't use that to carve out
exemptions:

- The seed converges. Re-applying `20-schema.sql` re-flips anything under
  `/bff/admin/…` or `/bff/superadmin/…` back to `true` — exactly as the `INSERT`
  above it re-creates deleted seed rows. Your exemption disappears at the next
  in-place apply.
- Exempt a surface by changing the `WHERE` predicate in `20-schema.sql`, so the
  exemption is reviewable, testable and survives a re-apply. **Narrow the predicate
  — do not append a second `UPDATE … SET mfa_required = false`.** An appended un-flip
  leaves the file's net effect un-gated while every statement in it still *looks*
  right; `tests/scripts/test-mfa-required-rules.sh` replays the whole file on a real
  SQL engine and will fail on exactly that. It also fails if any statement **other
  than that one `UPDATE`** writes the column — the single exception being the
  in-place-upgrade `WHERE mfa_required IS NULL` repair near the top of the file,
  which is matched as a *whole statement*, so a second predicate cannot be smuggled
  into it, and which must stay ahead of the flip. And it recognises the write in
  every spelling Postgres accepts — bare, `public.`-qualified, `"double-quoted"`, or
  led by a CTE — plus it now refuses to run at all if the file contains a statement
  of a *kind* it cannot classify. That last part matters: while the matcher demanded
  a bare table name, an appended
  `DELETE FROM public.gateway_route_access WHERE url_pattern LIKE '/bff/superadmin%'`
  wiped every superadmin row and this gate still reported a clean pass.
  And update §1.2 / §1.2a in the same commit: the gate
  cross-checks the documented exclusion list against the real rows in both
  directions, so prose and predicate cannot drift apart.
- Adding a **parallel** row that differs only in `mfa_required` does nothing:
  `mfa_required` is not part of `uq_route_access_row`
  `(gateway, url_pattern, role, COALESCE(casdoor_user,''),
  COALESCE(NULLIF(lower(trim(domain)),'default'),''))`,
  so the row collides and `ON CONFLICT DO NOTHING` silently drops it. This is the
  single easiest way to *think* you have enabled MFA on a surface while enabling
  nothing. Note the domain leg is the **gateway's scope equivalence**, not the
  raw text — a `'Default'` or case/whitespace re-spelling of an existing row's
  domain collides too. A row that differs in `domain` **for real** is the one
  legal sibling shape: per-domain tightening, §1.2a.

### 5.1 Known gap: MFA is not enforced during a dual-datastore outage

If both Postgres and the Cassandra mirror are unreachable, the gateway falls back to
its **baked-in** `CanonicalSeed`, whose every row is hard-coded `mfaRequired=false`
— a deliberate choice in `hugmesh-gateway` so a datastore outage cannot lock the
privileged plane out on the bare floor. Role gating still applies (and the seed is
closed-by-default for an unknown gateway name), but **the second-factor requirement
silently disappears for the duration of the outage**. Accept it or change it in
`hugmesh-gateway`; it cannot be fixed from this repo.

---

## 6. Rollback

Roll back in the reverse of §3, and note that only the flags are hot — the rules are
data.

1. **Immediate relief for a privileged lockout:** set
   `APP_MFA_ENFORCE_PRIVILEGED_FLOOR=false` on the affected gateway(s) and restart.
   The privileged bypasses come back and admins/superadmins reach the admin plane
   again without a factor. This is the first thing to try; it needs no DB access.
   ⚠ **On a cluster that auto-syncs, "set it" means one of two things, and only the
   first is durable.** (i) Revert the flip commit (set `mfa.enforcePrivilegedFloor`
   back to `false` in the shared chart) and let ArgoCD sync — the root Application and
   every gateway Application run `automated: {prune: true, selfHeal: true}`, so a
   `kubectl set env` or `kubectl patch` is **reverted by the next reconcile**.
   (ii) For minutes-matter relief, suspend auto-sync first, then change the env —
   exact commands are §9 phase G, and they leave drift you must reconcile afterwards.
2. **Full disable:** set `APP_MFA_ENABLED=false` as well. `decide()` then ignores
   `mfa_required` entirely and `MFA_SATISFIED` is no longer even derived, so every
   flipped row is inert again. The authority set returns to the legacy shape.
3. **Only if you want the data gone too:**

   <!-- gate:doc-sql name=rollback expect=none-flipped -->

   ```sql
   UPDATE gateway_route_access SET mfa_required = false
    WHERE url_pattern LIKE '/bff/admin/%' OR url_pattern LIKE '/bff/superadmin/%'
       OR url_pattern IN ('/bff/admin', '/bff/superadmin');
   ```

   (The gate runs this one too, against the replayed seed, and asserts that **no**
   row is left `mfa_required=true` afterwards — so a rollback that silently stopped
   covering one of the prefixes fails the build.)
   The gateways pick this up on their next route-access refresh
   (`app.route-access.refresh-interval-ms`, default 5 s) — no restart needed. Note
   this is undone the next time `20-schema.sql` is applied; to make it permanent,
   revert the `UPDATE` block in that file.
4. **If both flags are off and privileged callers still 503:** that is the
   cold-start hold, and it only runs under `enforce-privileged-floor`. If you are
   seeing it with the flag off, the flag did not actually reach the pod — check the
   rendered env, not the chart values.
5. **Break-glass for a locked-out operator with no factor:** there is no in-band
   path (the recovery-regenerate endpoint is itself step-up gated). Use cluster
   access — `kubectl exec` to the admin-bff's Postgres
   (`deploy/admin-bff-db`, namespace `hugmesh-backend`, database/user `adminbff`) and
   delete that subject's rows from the MFA factor **tables** `mfa_factor`,
   `mfa_recovery_code` and `webauthn_credential` (created by changelogs
   `151-mfa-factors.xml`; `owner_subject` is the key — see §9 phase C for which value
   that is per carrier), or roll back per step 1 — then re-enroll. The exact
   commands are §9 phase G. If you have no
   cluster access either, you are relying on someone who does; make sure that
   person exists and is not the same single operator before step 7.

---

## 7. Files this runbook refers to

| path | present on `main`? | what |
|---|---|---|
| `specs/cluster/manifests/route-access/initdb/20-schema.sql` | **yes** | the `gateway_route_access` table + canonical seed + the `mfa_required` `UPDATE` |
| `tests/scripts/test-mfa-required-rules.sh` | **yes** | the gate over the rules (net-effect replay) + the enablement posture (structured ArgoCD parse **and** the shape-aware `APP_MFA_*` sweep over all of `specs/` + the compose stack) + the four SQL blocks in **this** runbook, which it executes against the replayed seed |
| `tests/scripts/test-cluster-manifest-integrity.sh` | **yes** | verifies every seeded `gateway` id is a deployed gateway |
| `specs/cluster/apps/20-gateway-{pki,be,fe}.yaml`, `specs/cluster/apps/22-gateway-superadmin.yaml` | **yes** | the four gateway Applications; `instance.name` here is the `gateway` column value each pod loads |
| `specs/cluster/manifests/admin-bff-api/deployment.yaml` | **yes** | `APP_CASDOOR_MFA_ENABLED`, `APP_MFA_FACTOR_KEY`, `APP_MFA_WEBAUTHN_RP_ID`, `APP_MFA_WEBAUTHN_ORIGINS` |
| `specs/cluster/manifests/external-secrets/secretstore.yaml` | **yes** | the `admin-bff-mfa` ExternalSecret |
| `scripts/gen-cluster-secrets.sh` | **yes** | mints the factor key into Vault |
| `tests/stack/compose.local.yaml` | **yes** | dev stack: gateway `SPRING_APPLICATION_NAME`s, `APP_CASDOOR_MFA_ENABLED`, `APP_MFA_FACTOR_KEY`, the initdb mount of the seed, AND the gateway `APP_MFA_*` trio (`APP_MFA_ENABLED=true` — the deliberate dev-vs-cluster asymmetry) |
| `specs/cluster/charts/hugmesh-gateway/values.yaml` | **yes** | shared gateway chart; carries the `mfa:` block (`enabled: false`) reaching all four gateways, rendered by `templates/deployment.yaml` |
| `tests/stack/test-gateway-mfa-env.sh` | **yes** | pins BOTH postures (cluster `false` / compose `true`) and refuses to run if that asymmetry disappears |
| `specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml` | **yes** | renders `APP_MFA_ENABLED` / `APP_MFA_FRESHNESS_WINDOW` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` (from `.Values.mfa.*`) into every gateway pod; the sweep in §1.3 watches this file specifically — it is the one place a single edit reaches all four gateways |
| `tests/stack/gateway_mfa_env.py` | **yes** | the helper behind `test-gateway-mfa-env.sh`; its posture parser overlaps `test-mfa-required-rules.sh`'s and the two have not been collapsed into one shared helper |
| `tests/stack/test-mfa-flip-wiring.sh` | **yes** | pins the `MFA=1` switch per lane (§8) and the chart default `mfa.enabled: false` (its check (5a)) — one of the three posture suites a cluster flip must move (§3 step 6) |
| `scripts/kind-mfa-posture.sh` | **yes** | reads `APP_MFA_ENABLED` back off the kind fe-gateway pod (§8.1); §9 phase B generalises the same read to all four gateways and all three variables |

Cross-repo (not changeable from here):
`hugmesh-gateway` `filter/GatewayRouteAccessFilter.java`,
`cache/GatewayRouteAccessService.java`, `cache/CanonicalSeed.java`,
`config/CasdoorAuthorities.java`, `filter/BffSessionAuthFilter.java`;
`hugmesh-auth-core` `mfa/MfaEnrollmentService.java`, `mfa/RecoveryCodeService.java`,
`casdoor/MfaChallengeController.java`.

---

## 8. `MFA=1` — the operational flip switch (issue #47)

Everything above describes WHAT to flip; this section is the ONE switch that
performs the flip, per lane, following the `PHPBB=1`/`AKKOMA=1` knob precedent.
It flips **only `app.mfa.enabled`**: the freshness window keeps its default
(600000) everywhere, and the privileged floor is **not reachable from this
switch on any lane** — `MFA_FLOOR=1` (§3 step 5) stays its own deliberate,
compose-only rehearsal knob, and a cluster floor flip stays the hand-executed §3
step 7. **Every precondition in §2 (enroll before you enforce, the machine-caller
census in §2.4) binds on every lane below.** Nothing here changes a committed
default: the chart stays `false`, no `specs/cluster/apps/*.yaml` flips it, and
the posture gates (`tests/stack/test-gateway-mfa-env.sh`,
`tests/scripts/test-mfa-required-rules.sh`) keep enforcing that.

| lane | invocation | mechanism | scope |
|---|---|---|---|
| compose dev stack | `make stack-up MFA=1` | threads an EXPLICIT `APP_MFA_ENABLED='true'` into every compose invocation (`STACK_MFA_ENV` in the Makefile), overriding even an operator shell that exports `APP_MFA_ENABLED=false`. A plain `make stack-up` stays byte-identical (the dev default is already `true`, §1.3). | the run |
| kind SSO slice | `make kind-up MFA=1` | `bootstrap-kind.sh` appends a `mfa.enabled=true` **helm parameter** to every gateway Application it applies (today: `hugmesh-gateway-fe`) — the same runtime-patch mechanism as its `ingress.className` override, so the committed chart/apps stay untouched. Fails loudly under `KIND_PROFILE=core` (no gateway is applied there) and on any unrecognised `MFA` spelling. With it on, spec 27's cluster carries live route-level enforcement for the non-privileged case, same as compose (§3.1). | the kind cluster |
| per-domain / tenant | `MFA=1` in `brands/<brand>.conf`, then `./generate-brand-repos.sh brands/<brand>.conf` | renders `mfa: {enabled: true}` into **that brand's** gateway Applications via the `{{MFA_ENABLED}}` token (both render engines; parity-proven). Conf-only by design: an ambient exported `MFA=1` does NOT leak into a render whose profile never set it (root-cron reconcile safety). | one `CLUSTER_DOMAIN` |

**The reference cluster (specs/cluster) is deliberately NOT a lane.** Its flip
remains §3 step 6 — a reviewed commit that sets the shared chart's `mfa.enabled`
and moves the `EXPECT_*` pins in the same change. `MFA=1` gives you the
rehearsal (compose), the integration proof (kind), and the tenant rollout
(brands); it never silently changes the posture a cluster ships with.

**Per-domain WITHIN one mesh** (several local domains behind the same gateways)
**is now expressible** — the casdoor-choice schema landed (PR #71) and the join
point named here was implemented: `uq_route_access_row`'s domain leg is keyed
on the gateway's own scope equivalence, the seed's `UPDATE` carries a
per-domain arm (empty today), and §1.2a's scope table says exactly what a
domain-scoped row can express (per-domain **tightening**), cannot express
(per-domain **exemption** — `decide()` is a sticky OR and the blanket rows are
unscoped), and what an **own-IdP** domain means for a `MFA=1` flip (its
principals cannot enroll — enumerate them before §3 step 6).

Wiring proof: `tests/stack/test-mfa-flip-wiring.sh` (CI `lint:mfa-flip-wiring`)
re-derives every consumer of the trio per lane from the artifacts themselves and
fails if any consumer stops receiving the switch — the inert-toggle failure mode
(a flag wiring only half its consumers has shipped dark twice in this repo). All
of its checks are mutation-tested on staged copies.

### 8.1 Observing the flip on the kind lane

```console
$ make kind-mfa-posture      # what the RUNNING gateway pod actually has
APP_MFA_ENABLED=false
$ make kind-e2e-mfa          # spec 29 against the cluster, at that live posture
```

`kind-e2e` runs spec 27 only, so before `kind-e2e-mfa` the kind lane could flip MFA
on and had no way to run the MFA spec against **either** posture. The target reads
`APP_MFA_ENABLED` back off the gateway Deployment (`scripts/kind-mfa-posture.sh`) and
hands it to spec 29, which **selects** between its two stack blocks on that value:
`false` runs the OFF-posture block (the seeded `mfa_required` rows are inert, the role
wall on the same rows is not, an un-enrolled admin is never challenged) and anything
else runs the per-row enforcement block.

Read live, never guessed, and never threaded from `$(MFA)` — deliberately. `kind-up`
is a separate invocation and the cluster outlives it, so the caller's shell describes
a cluster it may never have flipped; and the repo cannot answer either, because
`kind-up MFA=1` flips through an ArgoCD **helm parameter**, leaving the committed
chart reading `mfa.enabled: false` on a cluster that is enforcing. The helper is
fail-closed: an unreachable cluster is an error, not an "assume off" that would report
a clean pass for the posture the cluster is **not** holding.

**What the flip changes, concretely** (verified on the kind SSO slice, 2026-08-20 —
9 `mfa_required` rows seeded, `hugmesh-gateway-fe` holding `APP_MFA_ENABLED=false`):
`make kind-up MFA=1` appends `{"name":"mfa.enabled","value":"true"}` to the
`hugmesh-gateway-fe` Application's helm parameters, the chart re-renders
`APP_MFA_ENABLED=true` into the gateway container, and the pod rolls. Nothing else
moves — `APP_MFA_FRESHNESS_WINDOW` stays 600000 and
`APP_MFA_ENFORCE_PRIVILEGED_FLOOR` stays `false` (§3 step 7 is still a hand-executed
step). The observable difference is that a pure `ROLE_FLEET_ADMIN` on
`/bff/admin/phone-fleet/**` goes from "reaches admin-bff" to the gateway's 403 +
`X-Route-Denied`; privileged roles are unchanged until the floor is on (§3.1).

⚠ The equivalent one-shot `kubectl patch` must carry **both** parameters —
`--type merge` replaces `spec.source.helm.parameters` wholesale, so a patch that sets
only `mfa.enabled` drops the kind lane's `ingress.className: nginx-internal` override
and nothing routes.

---

## 9. Operator checklist — the live flip, with the exact commands

Everything before this section says *why*; this is the order and the commands. It
exists because the only thing left on the MFA privileged floor is a live action on a
real cluster, and the earlier text spread its commands over eight sections. **None of
this has been run against a live cluster by the person who wrote it** — the commands
are derived from the committed manifests (every namespace, Deployment, container,
database and Secret name below is cited to one) and the SQL that is marked is
*executed* by `tests/scripts/test-mfa-required-rules.sh`, but a command that has
never met your cluster can still be wrong. Each phase says what it proves; stop at
the first phase that does not come back as stated.

Conventions: `$KC` is `kubectl` pointed at the **operator's** cluster context, checked
with `kubectl config current-context` first. Nothing below is for the kind lane
(§8.1 covers that). The runbook's own SQL blocks are fed to `psql` through
`scripts/mfa-runbook-sql.sh <name>`, which prints the block **byte-for-byte as the
gate ran it** (`--list` shows the names); never retype them.

The four gateways, from `specs/cluster/apps/20-gateway-*.yaml` and
`22-gateway-superadmin.yaml` (Deployment name = `instance.name`, container `gateway`):

| gateway Deployment | namespace | ArgoCD Application (ns `devops`) |
|---|---|---|
| `hugmesh-pki-gateway` | `hugmesh-pki` | `hugmesh-gateway-pki` |
| `hugmesh-be-gateway` | `hugmesh-backend` | `hugmesh-gateway-be` |
| `hugmesh-fe-gateway` | `hugmesh-frontend` | `hugmesh-gateway-fe` |
| `hugmesh-superadmin-gateway` | `hugmesh-pki` | `hugmesh-gateway-superadmin` |

### Phase A — the repo side is green (workstation, no cluster)

```console
$ git fetch origin && git status -sb          # you are reviewing the commit you will deploy
$ for t in tests/scripts/test-mfa-required-rules.sh \
           tests/scripts/test-mfa-raw-jwt-posture.sh \
           tests/stack/test-gateway-mfa-env.sh \
           tests/stack/test-mfa-flip-wiring.sh; do bash "$t" >/dev/null 2>&1; echo "$? $t"; done
0 tests/scripts/test-mfa-required-rules.sh
0 tests/scripts/test-mfa-raw-jwt-posture.sh
0 tests/stack/test-gateway-mfa-env.sh
0 tests/stack/test-mfa-flip-wiring.sh
```

All four must print `0` **before** the flip commit (a gate that is already red proves
nothing about your change). The flip commit then turns three of them red until their
pins move (§3 steps 6 and 7) and must leave all four green again.
`tests/stack/test-gateway-mfa-env.sh` cross-checks its model against a real `helm
template` when `helm` is on `PATH` and prints `SKIP (9)` when it is not — run it with
`REQUIRE_HELM=1` so a missing helm is a failure, not a quieter green.
`tests/scripts/test-mfa-required-rules.sh` needs only `python3` (it replays the seed on
the stdlib `sqlite3` engine; set `POSTGRES_HOST` to replay it on a real Postgres too).

### Phase B — read the LIVE posture, per gateway (proves: you know the starting state)

The committed chart says `false`; the pod is the truth (§6 item 4). Read the env the
**process** carries, on all four, all three variables:

```console
$ for gw in hugmesh-pki-gateway:hugmesh-pki hugmesh-be-gateway:hugmesh-backend \
            hugmesh-fe-gateway:hugmesh-frontend hugmesh-superadmin-gateway:hugmesh-pki; do
    d=${gw%%:*}; ns=${gw##*:}; echo "== $d ($ns)"
    $KC -n "$ns" exec "deploy/$d" -c gateway -- env | grep '^APP_MFA_' | sort
  done
== hugmesh-pki-gateway (hugmesh-pki)
APP_MFA_ENABLED=false
APP_MFA_ENFORCE_PRIVILEGED_FLOOR=false
APP_MFA_FRESHNESS_WINDOW=600000
... (the same three lines for each of the other three)
```

Expect `false` / `false` / `600000` four times. Anything else means somebody already
flipped something outside git — resolve that **before** going on. Also confirm what
ArgoCD thinks is deployed:

```console
$ $KC -n devops get app hugmesh-root hugmesh-gateway-pki hugmesh-gateway-be \
      hugmesh-gateway-fe hugmesh-gateway-superadmin \
      -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision
```

Expect `Synced` / `Healthy`, and `REV` equal to the commit you reviewed in phase A.

### Phase C — the preconditions that lock you out if skipped (reads only)

All of C is read-only. Every command here can be run today, with enforcement off.

**C1. The factor key exists and is non-empty** (§4.1; Secret `admin-bff-mfa`, key
`factor-key`, from `specs/cluster/manifests/admin-bff-api/deployment.yaml`). The value
is **not** printed:

```console
$ $KC -n hugmesh-backend get secret admin-bff-mfa -o jsonpath='{.data.factor-key}' | wc -c
```

Expect a number well above `0` (a base64 256-bit key is 44). `0` or `No resources`
means step 1 of §3 is not done and nobody can enrol TOTP.

**C2. WebAuthn RP-ID and origins are your real domain** (§4.2):

```console
$ for v in APP_MFA_WEBAUTHN_RP_ID APP_MFA_WEBAUTHN_ORIGINS APP_CASDOOR_MFA_ENABLED; do
    printf '%s=' "$v"
    $KC -n hugmesh-backend get deploy hugmesh-admin-bff-api \
      -o jsonpath="{.spec.template.spec.containers[*].env[?(@.name==\"$v\")].value}"; echo
  done
$ $KC -n hugmesh-backend logs deploy/hugmesh-admin-bff-api --since=24h | grep -c 'MFA MISCONFIGURED'
```

Expect your own domain on the first two (not `admin.hugmesh.net` unless that *is* your
domain, and never `localhost`), `true` on the third, and `0` from the grep (the boot
guard's banner, §4.3 — absence is only meaningful if that image carries the guard).

**C3. The seeded rules are what §1.2 says** — 10 flipped, 11 carrying the floor. Run
the two runbook blocks, unmodified, against the route-access database
(`deploy/route-access-db`, namespace `hugmesh-pki`, database and owner role
`gateway`, password from the pod's own `POSTGRES_PASSWORD`, per
`specs/cluster/manifests/route-access/deployment.yaml`):

```console
$ for b in verify floor; do
    echo "== $b"
    scripts/mfa-runbook-sql.sh "$b" | $KC -n hugmesh-pki exec -i deploy/route-access-db -- \
      sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -U gateway -d gateway'
  done
```

Expect `(10 rows)` for `verify`, all `mfa_required = t`, and `(11 rows)` for `floor`
(the extra one is the `allow = f` games-services row, §3 step 4). If the cluster was
upgraded in place and these come back short, re-apply `20-schema.sql` (§3 step 4);
do **not** hand-edit rows (§5).

**C4. The machine-caller census (§2.4) — re-run it, it is a point-in-time answer.**
The §2.4 result is from 2026-08-06; the static half is a `git grep` per repo and the
empirical half is:

```console
$ $KC -n hugmesh-pki exec -i deploy/casdoor-pg -- sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -U "$POSTGRES_USER" -d casdoor -tA' <<'SQL'
SELECT application,
       CASE WHEN COALESCE("user", '') = '' THEN 'machine' ELSE 'user-bound' END,
       count(*)
  FROM token GROUP BY 1, 2;
SQL
```

Expect **no `machine` rows**. Any `machine` row on `/bff/admin…` or `/bff/superadmin…`
traffic is a §2.4 stop: it is denied permanently the moment step 6 lands. (The table
and column names are Casdoor's, not this repo's, and were not re-checked here; the
casdoor Deployment is `casdoor-pg` in `hugmesh-pki` per
`specs/cluster/manifests/casdoor/pg.yaml`.)

**C5. Every privileged operator has an ENABLED TOTP factor** — the census the runbook
had no command for. The query below lists **every** account whose cached roles include
`superadmin`, `admin` or `game-master`, with whether it holds an enabled TOTP and/or
WebAuthn factor. TOTP specifically, not "any factor", because only the TOTP path issues
recovery codes (§2.2). It is executed by the gate against a fixture schema that
mirrors changelogs `004-account.xml` and `151-mfa-factors.xml`.

<!-- gate:doc-sql name=census expect=mfa-census -->

```sql
SELECT a.id,
       a.roles,
       EXISTS (SELECT 1 FROM mfa_factor f
                WHERE f.owner_subject = a.id AND f.enabled AND f.type = 'TOTP')     AS totp,
       EXISTS (SELECT 1 FROM mfa_factor f
                WHERE f.owner_subject = a.id AND f.enabled AND f.type = 'WEBAUTHN') AS webauthn
  FROM account a
 WHERE ',' || replace(a.roles, ' ', '') || ',' LIKE '%,superadmin,%'
    OR ',' || replace(a.roles, ' ', '') || ',' LIKE '%,admin,%'
    OR ',' || replace(a.roles, ' ', '') || ',' LIKE '%,game-master,%'
 ORDER BY 3, 1;
```

```console
$ scripts/mfa-runbook-sql.sh census | $KC -n hugmesh-backend exec -i deploy/admin-bff-db -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -U adminbff -d adminbff'
```

(`deploy/admin-bff-db`, namespace `hugmesh-backend`, database and owner role
`adminbff`, from `specs/cluster/manifests/admin-bff-db/deployment.yaml`.) Rows are
sorted un-enrolled first. **Every row must show `totp = t`.** A row with `totp = f` and
`webauthn = t` is the §2.2 hazard (WebAuthn-only, no recovery codes) and is **not**
ready. The census is only as complete as what it can see, and three blind spots matter:

* `account.roles` is a **cached copy** that admin-bff re-syncs from the Casdoor
  id_token on every native login (changelog `260-account-roles-check-relax.xml`). A
  privileged Casdoor user who has **never logged in through `/bff/login`** has no
  `account` row, therefore no opaque session, therefore **cannot enrol at all**, and is
  invisible here. Compare against Casdoor's own role membership (Casdoor admin UI →
  Roles → `superadmin`, `admin`, `game-master`) and have each missing person log in
  once. *No SQL is given for the Casdoor side: its `role` table layout was not
  verified from this repo.*
* `owner_subject` is **carrier-dependent** (auth-core `MfaEnrollmentController.subjectOf`):
  an opaque `bff_` session enrols under `account.id` (`casdoor:<handle>`), a raw JWT
  under the Casdoor `sub` UUID. The join above is correct for the native-login web
  console, which is the only carrier that can complete `POST /bff/mfa/challenge`
  (§2.4). Look at what is **not** matched:

  ```console
  $ echo "SELECT owner_subject, type, enabled FROM mfa_factor ORDER BY 1,2;" | \
      $KC -n hugmesh-backend exec -i deploy/admin-bff-db -- \
      sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -U adminbff -d adminbff'
  ```

  An `owner_subject` that looks like a bare UUID is a raw-JWT enrolment keyed under
  the `sub`; it will not appear in the census and its holder must be checked by hand.
* An `idp: own` domain's principals cannot enrol at all (§1.2a); enumerate those
  domains separately.

**C6. Each operator PROVES a fresh stamp — a human step, no command can do it for
them.** For every row from C5: sign in at the real console, open the login-ui security
page, complete the TOTP challenge (`POST /bff/mfa/challenge`, body
`{"factor":"totp","credential":"<code>"}`, driven by the page), then reach an
`/bff/admin…` page **within 10 minutes**. Afterwards you can read the stamp back
(token column deliberately not selected):

```console
$ echo "SELECT account_id, mfa_satisfied, mfa_satisfied_at, now() - mfa_satisfied_at AS age
          FROM bff_session
         WHERE mfa_satisfied AND expires_at > now()
         ORDER BY mfa_satisfied_at DESC;" | \
    $KC -n hugmesh-backend exec -i deploy/admin-bff-db -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -U adminbff -d adminbff'
```

Every privileged `account_id` from C5 must appear at least once with `mfa_satisfied =
t`. Record each operator's recovery codes at enrol time (shown once, §2.2). Do **not**
go on until C5 is fully `totp = t` **and** every row has appeared here.

**C7. Two people hold cluster access.** §6 item 5's break-glass needs `kubectl` on the
admin-bff database; if the only person who can do it is the one being locked out,
there is no way back. Name the second person now.

### Phase D — decide the shape of the floor flip (a decision, not a command)

§3 step 7 cannot canary one gateway through git (§3 step 7's warning). Decide, in
writing, before phase E: **(a)** all four at once from one commit, **(b)** the
temporary bypass in phase E on `hugmesh-fe-gateway` first, or **(c)** extend the gate
to allow a per-gateway pin. This section implements (a) and (b).

### Phase E — flip, one flag at a time, one reviewed commit each

**E1. Step 6 (`mfa.enabled`).** One commit that changes, together: the chart value
`specs/cluster/charts/hugmesh-gateway/values.yaml` `mfa.enabled: true`, and the three
suites' pins exactly as §3 step 6's table lists (`test-gateway-mfa-env.sh`,
`test-mfa-required-rules.sh`, `test-mfa-flip-wiring.sh`). Re-run phase A: all four
`0`. Merge, let ArgoCD sync, then re-run **phase B**: `APP_MFA_ENABLED=true` on all
four, floor still `false`, window still `600000`. Wait for rollouts:

```console
$ for gw in hugmesh-pki-gateway:hugmesh-pki hugmesh-be-gateway:hugmesh-backend \
            hugmesh-fe-gateway:hugmesh-frontend hugmesh-superadmin-gateway:hugmesh-pki; do
    $KC -n "${gw##*:}" rollout status "deploy/${gw%%:*}" --timeout=300s
  done
```

What you should and should **not** see (§3.1): a pure `ROLE_FLEET_ADMIN` without a
stamp now gets `403` with `X-Route-Denied` on `/bff/admin/phone-fleet/**`; admins and
superadmins are unchanged. **A quiet cluster is not evidence that admin MFA works.**
Soak here as long as you like; this state is the recommended resting point.

**E2. Step 7 (`mfa.enforcePrivilegedFloor`) — option (a).** Rehearse on compose first
(`make stack-up MFA_FLOOR=1`, then `MFA_FLOOR=1 npx playwright test
29-mfa-privileged-floor` from `tests/e2e`). Have **two** superadmin sessions open on
two browsers, each with a stamp taken in the last few minutes, and the C7 person on
call. One commit: `mfa.enforcePrivilegedFloor: true` plus the two suite pins from §3
step 7's table. Merge, sync, re-run phase B (`APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true`
everywhere), and expect `503` + `Retry-After: 5` for privileged callers during each
gateway's cold start (§2). Then, from a session whose stamp is **older than 10
minutes**, load an `/bff/admin…` page: expect `403` + `X-Route-Denied`; complete the
challenge on the security page and reload: expect it to pass. A page outside the floor
(for example `/bff/forum/admin/**`, §1.2a) must be untouched.

**E-bypass. Option (b): the floor on `hugmesh-fe-gateway` only, temporarily, outside
git.** Auto-sync must be suspended or it reverts you within a reconcile (§3 step 7).
This is a **drift you create on purpose and must undo**:

```console
$ $KC -n devops patch app hugmesh-root          --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
$ $KC -n devops patch app hugmesh-gateway-fe    --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
$ $KC -n hugmesh-frontend set env deploy/hugmesh-fe-gateway -c gateway APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true
$ $KC -n hugmesh-frontend rollout status deploy/hugmesh-fe-gateway --timeout=300s
```

Undo it by re-enabling auto-sync on the root (`{"spec":{"syncPolicy":{"automated":
{"prune":true,"selfHeal":true}}}}`), which re-applies the Application specs from git,
then confirming phase B shows the value git says. **Until you do, every other
reconcile-driven fix on those four gateways is frozen.** Not run against a live
cluster; ArgoCD behaviour here is read from the manifests only.

### Phase F — after each flip

Re-run phase B, the C3 `floor` block (still `(11 rows)` — a flip must not move data),
and the C5/C6 queries. Watch the four gateways' logs for a burst of `403` /
`X-Route-Denied` from principals you did not expect; each is either an operator who
missed C6 or a caller the §2.4 census did not know about.

### Phase G — rollback and break-glass, commands

Order is §6: floor first, then `enabled`, data last. **The durable rollback is a git
revert** of the flip commit (its pins revert with it). The fast path, when minutes
matter, is to suspend auto-sync and change the env, then reconcile afterwards:

```console
$ $KC -n devops patch app hugmesh-root          --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
$ $KC -n devops patch app hugmesh-gateway-fe    --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
$ $KC -n hugmesh-frontend set env deploy/hugmesh-fe-gateway -c gateway APP_MFA_ENFORCE_PRIVILEGED_FLOOR=false
$ $KC -n hugmesh-frontend rollout status deploy/hugmesh-fe-gateway --timeout=300s
```

(Repeat the last two lines for each affected gateway from the table above; for a full
disable add `APP_MFA_ENABLED=false`.) **Break-glass for one operator with no usable
factor** — look first, delete second, inside one transaction you read before you
commit. `<owner_subject>` is the value from the C5 `id` column:

```console
$ $KC -n hugmesh-backend exec -i deploy/admin-bff-db -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -U adminbff -d adminbff' <<'SQL'
BEGIN;
SELECT 'mfa_factor', count(*) FROM mfa_factor WHERE owner_subject = '<owner_subject>'
UNION ALL SELECT 'mfa_recovery_code', count(*) FROM mfa_recovery_code WHERE owner_subject = '<owner_subject>'
UNION ALL SELECT 'webauthn_credential', count(*) FROM webauthn_credential WHERE owner_subject = '<owner_subject>';
DELETE FROM mfa_recovery_code   WHERE owner_subject = '<owner_subject>';
DELETE FROM webauthn_credential WHERE owner_subject = '<owner_subject>';
DELETE FROM mfa_factor          WHERE owner_subject = '<owner_subject>';
COMMIT;
SQL
```

That operator can then sign in again and re-enrol **TOTP first** (§2.2) —
enrolment is reachable with the floor on (§2.1: `/bff/mfa/**` has no route row), and
only the *removal* of a factor and the recovery-code regeneration are step-up gated.
The data rollback (§6 step 3) is `scripts/mfa-runbook-sql.sh rollback | …psql…` against
`route-access-db`, exactly as in C3.

### What this checklist does not prove

It does not prove that Postgres executes the runbook's SQL **blocks** (the gate runs
those on sqlite; only the seed has a Postgres leg, §1.2) — C3 and C5 are their first
contact with Postgres. It does not enumerate
privileged Casdoor users who never logged in (C5, first bullet). It does not prove the
suspended-auto-sync commands against your ArgoCD version. And it cannot make an
operator enrol: C6 is a person at a keyboard.
