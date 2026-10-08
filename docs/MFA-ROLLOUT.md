# MFA rollout — operator runbook (gateway `mfa_required` floor + admin-bff step-up)

**Audience:** the operator who will turn MFA enforcement on. This is not a design
doc. It gives the order of operations, the preconditions that lock you out if you
skip them, and how to roll back.

**Default posture today: enforcement is OFF on a cluster and nothing here changes
that.** Seeding the `mfa_required` rules (below) is inert until *you* flip a flag.

---

## 0. Read this first: BOTH halves have landed

> **STATUS, verified against `main` on 2026-10-07.** The feature shipped as two
> halves, and both are merged:
> - the **rows**: the `mfa_required` `UPDATE` in `20-schema.sql`, this runbook, and
>   `tests/scripts/test-mfa-required-rules.sh` (143 passed / 0 failed);
> - the **flag wiring**: the shared chart's `mfa:` values block
>   (`specs/cluster/charts/hugmesh-gateway/values.yaml`), a template that renders
>   `APP_MFA_ENABLED` / `APP_MFA_FRESHNESS_WINDOW` /
>   `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` into every gateway pod, the compose defaults
>   (`APP_MFA_ENABLED=true`), and `tests/stack/test-gateway-mfa-env.sh`
>   (`tests/stack/gateway_mfa_env.py` is its model; 114 passed / 0 failed).
>
> So **§3 step 6 and step 7 are actionable**. The hard precondition has not changed:
> enrolling every privileged operator (§2) gates the flip, and the cluster still
> ships `false` deliberately.

To check the wiring yourself, this grep exits `0` on `main`:

```console
$ grep -rn 'APP_MFA_ENABLED\|APP_MFA_ENFORCE_PRIVILEGED_FLOOR' \
    specs/cluster/charts specs/cluster/apps tests/stack/
specs/cluster/charts/hugmesh-gateway/values.yaml:...   # the mfa: values block
specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml:207: - name: APP_MFA_ENABLED
tests/stack/test-gateway-mfa-env.sh:...                # the posture pins
$ echo $?
0
```

Do **not** work around the chart by hand-adding an `extraEnv: APP_MFA_ENABLED` to a
gateway Application. `tests/scripts/test-mfa-required-rules.sh` fails the build on
that, structurally, in every ArgoCD input shape (`helm.values`, `helm.valuesObject`,
`helm.parameters`, and a `helm.valueFiles` reference it refuses to treat as
auditable).

---

## 1. What is already wired vs. what you must flip

### 1.1 Already ON — the admin-bff step-up leg

`app.casdoor.mfa.enabled` is **already `true`** in both deployment targets:

| Where | File | Value |
|---|---|---|
| Cluster | `specs/cluster/manifests/admin-bff-api/deployment.yaml` (`APP_CASDOOR_MFA_ENABLED`) | `"true"` |
| Compose dev stack | `tests/stack/compose.local.yaml` (`APP_CASDOOR_MFA_ENABLED`) | `${APP_CASDOOR_MFA_ENABLED:-true}` |

This leg lets a **fresh MFA stamp on the opaque `bff_` session** satisfy a step-up
gate (`ImageGenStepUpGate`, `PhoneLockStepUpGate`, `GoLiveStepUpGate`,
`SshKeyIssueStepUpGate`, …) as a co-equal alternative to the token-based step-up.
It is a pure additive OR. It does not gate ordinary login, and it does not gate any
route at the gateway. It also arms the enrollment/challenge API (`/bff/mfa/**`).
With the flag off, **every** `/bff/mfa/**` endpoint returns `503`.

Prerequisite for that leg, already provisioned: **`APP_MFA_FACTOR_KEY`** (see §4).

### 1.2 Already committed but INERT — the `mfa_required` route rules

`specs/cluster/manifests/route-access/initdb/20-schema.sql` ends its seed with:

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

(The gate compares this block byte for byte against the statement in
`20-schema.sql`, so it cannot drift.)

The final `OR` is the **per-domain arm** (issue #47 × the casdoor-choice schema).
List a `url_pattern` in its `IN (…)` and every **domain-scoped** row that carries it
gets the same re-apply convergence the two blanket prefixes get. The arm is
**empty today**: the empty-string element matches no pattern, so the flip set is
exactly the 10 rows below. §1.2a says when, and when not, to widen it.

That flips **10 rows** across three gateways:

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

(Eight lines, ten rows: the `phone-fleet` line is three rows, one per role.)

An **eleventh** row ends up at `mfa_required = true` without being flipped by this
`UPDATE`: the `hugmesh-fe-gateway` `/bff/superadmin/games-services/**` **DENY** row.
The blanket flip cannot reach it (`WHERE allow = true`), so its own row-scoped
`UPDATE` seeds it immediately before. It is not in the table above because this
table is the flip's scope, not the floor's. §3 step 4's deny-floor table gives the
floor's full membership and says why a deny row carries one.

Read that table twice. `/bff/superadmin/**` is governed on **three** gateways:
`hugmesh-fe-gateway` joined the be and superadmin gateways when #244 was answered
ACCEPT. `/bff/admin/…` is governed on **two**. The write is prefix-based and
gateway-blind on purpose, because scoping it to one gateway name would leave the
other as an un-MFA'd second door to the same paths. Matching is
**longest-pattern-wins**, so flipping only the two `/**` floors would leave every
longer sub-path row as the *deciding* rule with `mfa_required=false`. That is a
bypass on exactly the highest-value surfaces (`phone-fleet`, `workloads`,
`games-services`).

`tests/scripts/test-mfa-required-rules.sh` pins all of this, with negative controls.
Every **behavioural** verdict there is read back from a real SQL engine after
replaying the file's own statements in file order. None is inferred from the text of
one statement. So a later statement that un-flips, deletes or partly reverts one of
these rows is caught by the *result*, in any spelling. A handful of *intent* checks
are still textual: the `UPDATE` is gateway-blind, allow-only, and says
`IS DISTINCT FROM true`. The engine is sqlite3. Postgres is not installed in CI, so
**these rules have never been executed on Postgres**. The gate says so on every run.

### 1.2a Scope: exactly two prefixes — and what that leaves OUT

The authorised scope is the **two path prefixes** `/bff/admin…` and
`/bff/superadmin…`, blanket *within* them. It is **not** "every admin surface". The
difference matters if you are reasoning about what an attacker can still reach with
a stolen session and no second factor. Seven other admin-ish `/bff/` rows are
deliberately left `mfa_required=false`:

| gateway | url_pattern | role | why it is out of scope |
|---|---|---|---|
| `hugmesh-fe-gateway` | `/bff/forum/admin/**` | `ROLE_ADMIN` | per-service admin console seam behind its **own** service-BFF prefix, not under `/bff/admin`. Covering it needs a different predicate *shape* (`LIKE '/bff/%/admin/%'`) |
| `hugmesh-fe-gateway` | `/bff/wiki/admin/**` | `ROLE_ADMIN` | ditto |
| `hugmesh-fe-gateway` | `/bff/wiki/superadmin/**` | `ROLE_SUPERADMIN` | ditto — and the **most privileged** of the seven. Governed at the SUPERADMIN floor by #329 (so a plain `ROLE_WIKI` is refused at the front door), but **not** MFA-gated by the seed: it is behind the wiki-bff's own service prefix, so the `UPDATE` cannot reach it without a new predicate *shape*. Flipping the per-service seams is the open operator decision. The gateway's baked fallback seed already marks this row and `/bff/wiki/admin/**` `mfa_required` (decision 80b in `CanonicalSeed`), so the two disagree: Postgres rows say `false`, the fallback says `true` |
| `hugmesh-fe-gateway` | `/bff/owncast/admin/**` | `ROLE_ADMIN` | ditto |
| `hugmesh-fe-gateway` | `/bff/mod/**` | `ROLE_ADMIN` | a **moderation** surface; `ROLE_ADMIN` is paired on it only as a superset of `ROLE_MOD`, so gating it would gate moderation, not administration |
| `hugmesh-be-gateway` | `/bff/image-builds/arch/**` | `ROLE_SUPERADMIN` | privileged by **role**, not by path — a prefix predicate cannot express it |
| `hugmesh-be-gateway` | `/bff/games-services/instances/**` | `ROLE_GAMES_SERVICES_ADMIN` | ditto (derived `games-services ∩ (admin\|mod)` role) |

Each of these would be a **new scope decision**, not a bug fix. Widening enlarges the
§3 step-7 lockout blast radius, so it is the operator's call. If you do widen,
widen the prose in the same commit. The gate enumerates admin-ish surfaces
*independently* of the `UPDATE`'s own prefixes and cross-checks them against exactly
this list. So an **eighth** admin-ish `/bff/` row appearing later fails the build
until someone decides consciously, and a stale entry in the list fails it too.

#### Per-domain MFA scope (several local domains behind the same gateways — issue #47)

`gateway_route_access` rows carry a per-row `domain`, and the casdoor-choice schema
(PR #71, `Domain.idp`) makes several local domains behind one set of gateways a
first-class shape. What a domain-scoped row can and cannot express for MFA is fixed
by `GatewayRouteAccessService.decide()` in `hugmesh-gateway` (**verified against the
source, not assumed**). Among the rows at the longest matching `url_pattern`,
`decide()` ORs `mfa_required` across *every* row that grants the principal and
domain-applies. An **unscoped** row (`NULL`/blank/`default`, case-insensitive,
trimmed) domain-applies to **every** domain. Hence this scope table:

| you want | expressible? | how / why not |
|---|---|---|
| the blanket (two prefixes) on every domain, **including** rows someone scoped to one domain under them | **yes — enforced** | the seed `UPDATE` is **domain-blind**, deliberately, like it is gateway-blind. A scoped `mfa_required=false` row under the prefixes is a **phantom exemption**: the unscoped canonical row still applies to that domain and still pulls the MFA floor up, so the false row exempts nothing — the seed re-flips it to make the table say what the gateway does. And a scoped-**only** allow row (a per-domain admin surface with no unscoped twin) must not ship un-MFA'd inside the blanket |
| require a second factor on **one domain only**, on a surface outside the blanket (per-domain **tightening**) | **yes** | insert a domain-scoped sibling row — same `gateway`/`url_pattern`/`role`, its own `domain`, `allow=true`, `mfa_required=true`. `domainApplies()` keeps it off every other domain. To give it the same re-apply convergence the blanket has, also list its `url_pattern` in the `UPDATE`'s per-domain arm (§1.2) **and** in the gate's `PER_DOMAIN_SCOPE` set — the gate cross-checks the two in both directions |
| **exempt** one domain from the blanket | **no** | not by a row (see the phantom-exemption note — `decide()` is a sticky OR), and not by the predicate (the blanket rows are **unscoped**, and unscoped rows apply to every domain). A real per-domain exemption means splitting the canonical rows per domain — a new scope decision with the full §3 step-7 blast-radius conversation attached |
| an **own-IdP domain** (`Domain.idp: own`, PR #71) satisfying MFA | **no (today)** — see the source chain below | its principals authenticate against the domain-local Casdoor and can never carry `MFA_SATISFIED`. On a shared-gateway mesh, treat that whole population like the §2.4 machine callers: enumerate own-IdP domains **before** §3 step 6, or their non-privileged holders (e.g. a pure `ROLE_FLEET_ADMIN`) are 403'd on every `mfa_required` surface with no way to enroll |

##### Why an own-IdP principal cannot satisfy MFA — both legs, from the source

Re-verified 2026-10-07. §2.4 lists two carriers that CAN satisfy an `mfa_required`
route. An `idp: own` principal is closed out of **both**, and the two closures are
independent. Fixing either one alone changes nothing:

1. **The opaque `bff_` session leg is unreachable.** `/bff/login` is bound to ONE
   Casdoor. `CasdoorLoginConfig` (hugmesh-user-bff-api) builds the single
   `CasdoorLoginClient` from `app.bff.oidc.login-base` + `app.bff.oidc.organization`,
   with no per-domain routing anywhere on that path. A user who exists only in the
   domain-local Casdoor never gets a `bff_session` row at all.
2. **The raw-JWT leg never gets a stamp written.** `mfa_satisfied_at` is a user
   Property. `CasdoorAdminClient.writeMfaProperty` (hugmesh-auth-core) writes it
   through the **superdomain's** admin client, never the domain-local Casdoor, so the
   claim cannot appear in a token minted by the domain's own issuer.

The tighter fact, and the reason raising the freshness window or pointing an admin
client at the tenant Casdoor would not be enough on its own: the `bff_session` row
is a **hard precondition for the Property write too**.
`MfaChallengeService.onSessionStamped` returns `false` and **skips the advisory
Property leg entirely** when the authoritative session stamp updates zero rows. So
for a principal with no `bff_session`, `POST /bff/mfa/challenge` cannot succeed and
`mfa_satisfied_at` is never written **in any Casdoor**. The blocker is the login
binding in (1), not only the Property's location in (2).

> **Cross-repo, and therefore NOT gate-pinned.** Everything above lives in
> hugmesh-user-bff-api and hugmesh-auth-core. The generator's gates cannot see
> either, so nothing here fails the build when one of those classes changes.
> Re-read all three call sites named above before §3 step 6 on any mesh that hosts
> an `idp: own` domain.

The uniqueness key makes the sibling-row idiom safe. `uq_route_access_row` keys its
domain leg on the **gateway's own scope equivalence**
(`COALESCE(NULLIF(lower(trim(domain)), 'default'), '')`), so a `'Default'` or
case/whitespace alias **collides** with the row it aliases instead of duplicating
it, while a genuinely scoped sibling keys differently and lands. The tightening row
shape, concretely. The gate **executes** this block against the replayed seed
(inserts it, then re-applies the whole seed over it) to prove the row survives with
`mfa_required=true` while its unscoped twin stays `false`:

<!-- gate:doc-sql name=tightening expect=per-domain-tightening -->

```sql
INSERT INTO gateway_route_access (gateway, url_pattern, role, allow, domain, mfa_required)
VALUES ('hugmesh-fe-gateway', '/bff/wiki/admin/**', 'ROLE_ADMIN', true, 'brand-x.example', true)
ON CONFLICT (gateway, url_pattern, role, COALESCE(casdoor_user, ''), COALESCE(NULLIF(lower(trim(domain)), 'default'), '')) DO NOTHING;
```

Such rows are **provisioning/CRUD data, not canonical seed rows**. The canonical
seed stays domain-free because the reference mesh defines no extra local domains.
`brand-x.example` above is a placeholder. A real tightening row carries the real
domain and goes in through the admin-bff CRUD or a per-mesh provisioning step, with
the `url_pattern` listed in the per-domain arm in the same change.

**These rows do nothing until a gateway flag is on.**
`GatewayRouteAccessService.decide()` consults `mfa_required` only when
`app.mfa.enabled` is true. The converse matters just as much: **`enabled: true`
alone is a NO-OP without these rows**, because nothing else in the platform writes
`mfa_required=true`. The flag and the rules are two halves of one feature.

### 1.3 What YOU must flip — the gateway trio

The **`hugmesh-gateway` image** reads three properties (its own
`src/main/resources/application.yml`), all default-off in the image itself:

| property | env | image default (cross-repo) |
|---|---|---|
| `app.mfa.enabled` | `APP_MFA_ENABLED` | **`false`** (`${APP_MFA_ENABLED:false}`) |
| `app.mfa.freshness-window` | `APP_MFA_FRESHNESS_WINDOW` | `600000` (10 min) |
| `app.mfa.enforce-privileged-floor` | `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` | **`false`** |

The shared chart `specs/cluster/charts/hugmesh-gateway` (used by **all four**
gateway Applications: `specs/cluster/apps/20-gateway-{pki,be,fe}.yaml` and
`specs/cluster/apps/22-gateway-superadmin.yaml`) carries an `mfa:` values block,
and its `templates/deployment.yaml` renders all three into every gateway pod. Verify
that yourself rather than trusting this sentence: the grep exits 0, and a live pod
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

The three are chart values, `mfa.enabled` / `mfa.freshnessWindow` /
`mfa.enforcePrivilegedFloor` in `specs/cluster/charts/hugmesh-gateway/values.yaml`.
There is a deliberate asymmetry. The **cluster** chart default stays `false`, while
the **compose dev stack** (`tests/stack/compose.local.yaml`, the `gateway-pki` /
`gateway-be` / `gateway-fe` services) defaults `APP_MFA_ENABLED=true`. So the
enforcement leg can be exercised end to end locally while a cluster ships dark. The
privileged floor is `false` on **both** sides.

> **Never turn gateway MFA on from a `specs/cluster/apps/*.yaml`.** Turning it on is
> an explicit, deliberate operator action taken *after* §2. The privileged floor is
> **not exempt for SUPERADMIN**, so enabling enforcement before operators hold a
> second factor locks you out of the privileged plane, with no in-band way back in.
> `tests/scripts/test-mfa-required-rules.sh` fails the build if any gateway
> Application sets it. It checks that **structurally**, not by grep. It parses
> `spec.source[s].helm.values` (a YAML *string*, block or flow style, comments and
> all), `helm.valuesObject`, and `helm.parameters` (including indexed names like
> `extraEnv[0].name`), for **both** spellings: the chart's `mfa.enabled` /
> `mfa.enforcePrivilegedFloor`, and a raw `APP_MFA_*` container env injected through
> `extraEnv`. A `helm.valueFiles` / `helm.fileParameters` reference, or an
> `APP_MFA_*` env sourced from a Secret, **fails the gate as un-auditable** rather
> than quietly reading as a pass. The chart's own `mfa:` defaults are asserted too.
>
> That parse covers only `specs/cluster/apps/*.yaml`. A **second sweep** covers every
> other file under `specs/` plus `tests/stack/compose.local.yaml` for a hardcoded
> `APP_MFA_ENABLED` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR`. It is shape-aware, not a
> grep, because the file that renders env into **all four** gateway pods is a *Helm
> template* and not parseable as YAML. It understands the Kubernetes env-list form
> (`- name:` and `value:` on separate lines, in either order), plain mapping keys,
> `[export] KEY=value`, and flow mappings. A `valueFrom` reference, or a literal
> `true` inside an open Helm `{{ if }}` block, is reported as **undecidable and
> fails**. A value that defers to a chart value (`{{ .Values.mfa.enabled | quote }}`)
> is left to the chart-values check above. The predecessor of this sweep was a
> two-stage grep that looked for the variable name on a line and then tested *that
> same line* for a true value, which the k8s env-list form defeats by construction.
> It would have passed while the shared chart template turned the privileged floor
> on for every gateway.

---

## 2. Hard precondition: ENROLL BEFORE YOU ENFORCE

**Every operator who holds `ROLE_SUPERADMIN`, `ROLE_ADMIN` or `ROLE_GAME-MASTER`
must have a working second factor enrolled, and must have verified they can produce
a fresh stamp, BEFORE `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` is turned on anywhere.**

Why this is not negotiable, from `GatewayRouteAccessFilter`:

- The privileged MFA floor runs **above** the `ROLE_SUPERADMIN` cross-domain bypass
  and the `ROLE_ADMIN`/`ROLE_GAME-MASTER` own-domain bypass. Those bypasses
  `return chain.filter(...)` *before* `decide()` is ever consulted, so the floor has
  to sit above them or the very roles whose MFA matters would never be gated.
  **SUPERADMIN is explicitly not exempt.**
- The floor **fails CLOSED on cold start**. Before route-access has been primed from
  the datastore the gateway cannot know whether a path is an `mfa_required` surface,
  so every privileged request is held with **`503` + `Retry-After: 5`**. On a
  gateway restart your admin plane is briefly 503 for privileged callers, by design.
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
| `POST /bff/mfa/assert/webauthn/options` | begin a WebAuthn assertion (challenge options) |
| `GET /bff/mfa/factors` | list enrolled factors |
| `DELETE /bff/mfa/factors/{id}` | remove a factor (**step-up gated**) |
| `POST /bff/mfa/recovery/regenerate` | new recovery set (**step-up gated**) |
| `POST /bff/mfa/challenge` | produce the MFA stamp that satisfies the floor |

Enrollment stays reachable while the floor is on. `/bff/mfa/**` has **no**
`gateway_route_access` row (neither in this seed nor in the gateway's baked
`CanonicalSeed`), and `hugmesh-fe-gateway` has no `/bff/**` floor row, so `decide()`
returns `NO_RULE` and the gateway forwards on the coarse `authenticated()` floor.
⚠ **If anyone ever adds a `/bff/**` floor row to the seed, re-check this.** A
`/bff/**` row would become the deciding rule for `/bff/mfa/**` and could make
enrollment unreachable exactly when it is needed.

### 2.2 The WebAuthn-only recovery-code lockout hazard

**Enroll TOTP first, or at least alongside WebAuthn. Do not enroll WebAuthn only.**

Recovery codes are issued *only* on the TOTP path (`MfaEnrollmentService.verifyTotpEnroll`
→ `enableTotpAndIssueRecovery` → `regenerateRecoveryCodesInternal`).
`verifyWebAuthnEnroll` → `storeWebAuthnCredential` issues **none**. And
`POST /bff/mfa/recovery/regenerate` is itself step-up gated: it needs a fresh stamp,
which needs the factor you just lost.

So: **WebAuthn-only operator + lost or broken security key = no self-service
recovery path.** Once the privileged floor is on, that operator is locked out of
`/bff/admin/**` and `/bff/superadmin/**`, and the only way back is the out-of-band
break-glass in §6.

Capture the recovery codes at enroll time. They are shown **once** (only hashes are
stored), and a regenerate invalidates the previous set.

### 2.3 The 10-minute freshness window vs. the blanket prefixes

The rules use the operator-chosen **blanket** scope *within* the two prefixes
(§1.2a): every `/bff/admin…` and `/bff/superadmin…` allow row, not just the
dangerous verbs. Combined with the freshness window that means:

- Gateway window: `app.mfa.freshness-window`, default **600000 ms = 10 min**. A
  `mfa_satisfied_at` stamp older than that (or in the future) yields no
  `MFA_SATISFIED` marker.
- Native-login (opaque `bff_` session) callers: admin-bff applies
  `app.casdoor.mfa.freshness` (default **`PT10M`**) before reporting
  `mfaSatisfied`, and the gateway's `BffSessionAuthFilter` mirrors that boolean into
  the `MFA_SATISFIED` authority.

**Practical effect:** *all* work under those two prefixes (reading a dashboard,
listing announcements, paging through audit rows) needs a stamp taken within the
last 10 minutes. A long admin session will be interrupted roughly every 10 minutes.
The operator accepted this when choosing blanket scope. If it proves intolerable,
the two supported adjustments are:
- (a) raise `APP_MFA_FRESHNESS_WINDOW` **and** `APP_CASDOOR_MFA_FRESHNESS` together.
  They must agree, or the JWT and opaque-session legs will disagree about who is
  fresh;
- (b) narrow the `WHERE` predicate in `20-schema.sql`.

Do **not** hand-edit individual rows (see §5).

### 2.4 Which callers can satisfy MFA, and the one population that cannot

§2.3 describes the freshness window without saying how each carrier obtains a stamp.
The three carriers behave differently, and only one of them is genuinely stuck:

| carrier | how it obtains `MFA_SATISFIED` | can it satisfy an `mfa_required` route? |
|---|---|---|
| opaque `bff_` session (native web login) | `BffSessionAuthFilter` mirrors admin-bff's introspect `mfaSatisfied`; the session row is stamped **synchronously** by `MfaChallengeService`. | **Yes, immediately.** |
| raw Casdoor JWT for a **human** (desktop/PKCE `hugmesh-desktop`, or any password-grant client) | `CasdoorAuthorities` -> `Roles.isMfaSatisfied(jwt, now, 600000)` against the `mfa_satisfied_at` claim. The claim is a Casdoor **user Property**, so it enters a token only at MINT time — but these clients can **re-mint on demand** (`refresh_token`, `device_code`, `password`). | **Yes** — complete MFA through the BFF (which writes the Property), then re-mint/refresh **within the 10-minute window**. |
| raw Casdoor JWT from `client_credentials` (pure machine, no human behind it) | same path — but `mfa_satisfied_at` is a **user** Property and a client-credentials token has **no user subject**, so there is nothing to stamp. `POST /bff/mfa/challenge` also fails closed without an opaque session row and an enrolled factor. | **No. Not under any configuration — there is no second factor for a machine.** |

**⚠ Do not mistake "mint-time only" for "rarely".** An earlier draft of this section
claimed no raw-JWT caller could ever be fresh, reasoning that the claim lands only at
mint and the seeded `expireInHours` is 168 (4 for `user-bff`) against a 10-minute
window. That reasoning was **wrong**: `expireInHours` bounds how long a *stale* token
stays valid, not how soon a client may request a new one. `hugmesh-desktop` is seeded
as a **public** PKCE client with `refresh_token`, and its own seed comment states the
intent: *"refresh_token so the device can refresh after the BFF stamps the MFA
Property"*. That flow works.

**The defect that was here is gone, and the practical consequence stays.**
`MfaChallengeService` used to call `RawJwtRefreshService.forceRefresh(subject, null)`
with a **literal `null`** refresh token at its only call site. The call always took
its no-op branch, and it discarded the token it would have minted, so the seam never
did what it named. hugmesh-auth-core removed `RawJwtRefreshService` on 2026-08-06
(auth-core #44); `MfaChallengeService` now has two legs, the authoritative session
stamp and the advisory Property write. It does not re-mint. So after completing MFA a
raw-JWT human must **actively** re-mint inside the 10-minute window. Nothing does it
for them, and a client that keeps using its existing token keeps being denied until
it refreshes. That is a usability trap, not a lockout. For the gateway's `bff-exchange`
path, auth-core's javadoc says admin-bff's `/bff/internal/session/exchange` re-mints
the custody JWT whenever `custody_updated_at` is older than the stamped
`mfa_satisfied_at`. (UNVERIFIED here: that comparison is in admin-bff, and I did not
find it in `InternalAccountController.java`.) A second re-mint path also exists:
admin-bff `InternalAccountController.exchangeSessionRow()` calls
`oidcExchange.refresh(...)` directly when custody is near expiry.

> `RawJwtRefreshService`'s javadoc justified the no-op by claiming "GEN2 lowers the
> privileged-app `expireInHours` precisely so this natural-lifetime gap stays SHORTER than
> the MFA freshness window". **There is no such GEN2 change** (`git grep GEN2` finds an
> unrelated CI comment and a disk-partitioning note), and no seeded expiry is anywhere near
> 10 minutes. Corrected in hugmesh-auth-core #43 — do not restore that reasoning.

**What this means at the §3 step-6 / step-7 flip.** Human operators are fine on both
carriers. The population to enumerate first is **machine `client_credentials`
traffic** on `/bff/admin…` and `/bff/superadmin…`. It has no supported path to a
second factor, so once `APP_MFA_ENABLED=true` it is denied there permanently, and
the step-7 privileged floor denies it outright (**`ROLE_SUPERADMIN` is not exempt**).
If any exists, the options are to leave the floor off, narrow the rows (§2.3 (b)), or
move that caller to a service account driving an opaque session. Raising
`APP_MFA_FRESHNESS_WINDOW` does not help it at all: the claim is absent, not stale.

**That enumeration was re-run on 2026-10-07 (static half) and came back CLEAN.** The
first run was 2026-08-06, and its empirical half is not repeated here. Both are
point-in-time results, so a new service could invalidate them. Re-run them with the
commands below.

*Static, 2026-10-07, across all 43 `hugmesh-*` repos on `origin/main`.* A `git grep`
for the string literals `"/bff/admin` and `"/bff/superadmin` in `src/main/java`
(excluding `@*Mapping`) finds only: admin-bff's own security matchers and route
classes; the gateway's `CanonicalSeed`; and two server-side callers, both in
mod-bff. Those are `AdminDomainLockClient` (`POST`/`DELETE
/bff/admin/domain-lock/{platform}/{user}`) and `AdminSuspensionClient`
(`/bff/admin/access-roles/{role}/{user}`). Neither is machine traffic.
`AdminApiConfig` builds their shared WebClient with
`BearerForwardingFilter.forwardCallerToken(...)`, so it carries the **human
moderator's** token, and it dials admin-bff directly over cluster DNS
(`admin-bff.base-url`, default `http://hugmesh-admin-bff-api.hugmesh-backend.svc.cluster.local:8080`),
not through a gateway. Either reason alone puts it outside the floor. The
`client_credentials` token clients (in actions, admin-bff, auth-core, mesh-bff,
remote-fragment and user-bff) name no `/bff/admin…` or `/bff/superadmin…` literal.
A path assembled from configuration would not show up in this grep.

*Empirical, 2026-08-06, against the live kind cluster (not repeated).* Casdoor had
issued **80 tokens, 100 % of them user-bound, zero machine tokens**: `app-built-in`
48 (`profile`) and `app-user-bff` 32 (`openid profile email`).

```console
# static: any machine caller of the two gated prefixes?
$ git grep -nE '"/bff/(admin|superadmin)' -- src/main/java     # per repo; exclude @*Mapping
# empirical: has any machine (user-less) token ever been issued?
$ kubectl exec -n hugmesh-pki <casdoor-pg-pod> -- psql -U casdoor -d casdoor -tAc \
    "SELECT application, CASE WHEN COALESCE(\"user\",'')='' THEN 'machine' ELSE 'user-bound' END,
            count(*) FROM token GROUP BY 1,2;"
```

**So step 6 is clear on this precondition today.** Re-run both checks if a new
service is added, if an existing one starts calling those prefixes, or if any caller
is moved behind a gateway instead of cluster DNS.

**One knob that moves a `bff_` carrier onto the JWT path.**
`hugmesh.gateway.bff-exchange.enabled` (default **false**, set in no manifest) makes
`BffJwtExchangeWebFilter` rewrite `Authorization: bff_…` into the custody Casdoor JWT
*before* Spring Security. With it on, an opaque carrier reaches the gateway as a
`Jwt` principal and takes the mint-time path in row 2 instead of the synchronous
row 1. Turn it on only together with a re-read of this section.

`tests/scripts/test-mfa-raw-jwt-posture.sh` pins this taxonomy to the seed. It
derives each seeded app's grant types and classifies which can re-mint. It fails if
a caller that cannot re-mint appears without this section naming that population,
or if the debunked bounded-gap reasoning is reintroduced anywhere.

---

## 3. Order of operations

Do these in order. Do not batch them. **All seven steps are actionable on `main`.**

1. **Verify the factor key exists** (§4). Without it TOTP enroll refuses, so nobody
   can enroll and step 3 would be a lockout.
2. **Fix WebAuthn RP-ID / origins for your real domain** (§4). Otherwise
   `navigator.credentials.create()` fails in the browser and only TOTP works.
3. **Enroll every privileged operator** (§2). TOTP at minimum. Record recovery
   codes. Have each operator prove they can complete `POST /bff/mfa/challenge` and
   then reach an admin page. Do this while enforcement is still off. The enrollment
   API is already armed because `APP_CASDOOR_MFA_ENABLED=true`.
4. **Seed the rules.** They ship in `20-schema.sql`. On a fresh cluster the
   route-access-db initdb applies them. On an existing cluster, re-apply that file
   against `route-access-db`. The `UPDATE` is idempotent
   (`mfa_required IS DISTINCT FROM true`) and converges in both cases. An `INSERT`
   would not, because `ON CONFLICT DO NOTHING` skips rows that already exist and
   would leave `mfa_required=false`. Re-applying the file on an existing cluster also
   repairs the column shape. `mfa_required` was first added by an `ALTER … ADD
   COLUMN` that was **nullable**, while the `CREATE TABLE` declares it `NOT NULL`, so
   an upgraded cluster could hold `mfa_required = NULL`, a third state the gateway's
   boolean read path is not written for. The file now backfills the NULLs and
   re-asserts `DEFAULT false` / `NOT NULL`. All of that is a no-op on a cluster that
   is already correct. Verify with:

   <!-- gate:doc-sql name=verify expect=flipped -->

   ```sql
   SELECT gateway, url_pattern, role, mfa_required
     FROM gateway_route_access
    WHERE allow = true
      AND (url_pattern LIKE '/bff/admin%'
        OR url_pattern LIKE '/bff/superadmin%')
    ORDER BY 1, 2, 3;
   ```

   Expect the 10 rows in §1.2 at `true`. Read what this query does **not** show you
   before you act on it. The `allow = true` clause is not cosmetic: it is the
   **same predicate the flip `UPDATE` uses**, so this query and that `UPDATE` agree
   on scope by construction. That scoping also **hides one row**. The seed carries an
   `allow = false` row under the superadmin prefix, `hugmesh-fe-gateway`
   `/bff/superadmin/games-services/**`, reinstated by operator decision 28 = **D**
   (hugmesh-generator#347), and that row carries the floor **too**. **Eleven** rows
   end up at `mfa_required = true`; this query returns ten of them. A deny row
   denies at the longest match regardless of MFA, which is why the flip leaves it
   alone. It is also why an operator reading an un-filtered result would see a
   `false` under a "fully flipped" prefix and think the rollout had failed. Do not
   make the opposite mistake either: the eleventh row is **not** missing from the
   rollout, and the step-up floor is **not** off for the games app-store subtree. To
   audit the **floor** rather than the flip, use:

   <!-- gate:doc-sql name=floor expect=every-floor-row -->

   ```sql
   SELECT gateway, url_pattern, role, allow, mfa_required
     FROM gateway_route_access
    WHERE mfa_required = true
    ORDER BY allow, 1, 2, 3;
   ```

   Expect **11** rows: the 10 above at `allow = true`, plus the one `allow = false`
   row in the table below. That row **keeps** the floor over its whole subtree. The
   gateway computes the privileged step-up floor with
   `GatewayRouteAccessService.isMfaRequiredSurface()`: the longest matching
   `url_pattern`, then `if (r.mfaRequired()) return true;`, with **no** `allow` test
   and **no** role test. It does not use `decide()`, whose MFA leg is raised only on
   the arms that GRANT the principal. The blanket flip (`WHERE allow = true`) can
   never reach a deny row, so this one is seeded by its own row-scoped `UPDATE` in
   `20-schema.sql`, placed immediately before the flip.

   <!-- gate:deny-floor -->

   | gateway | url_pattern | role | why it carries the floor while denying |
   |---|---|---|---|
   | `hugmesh-fe-gateway` | `/bff/superadmin/games-services/**` | `ROLE_SUPERADMIN` | #347 decision 28 = D — the games app-store control plane is walled at the public browser door **and** stays inside the privileged step-up floor. |

   Any other `allow = false` row at `mfa_required = true` is a defect, and the
   reverse is a lie. `tests/scripts/test-mfa-required-rules.sh` fails on a deny row
   at `true` that is not in this table (`DENY_TRUE_UNDECLARED`), on a table row the
   seed does not carry (`DOC_DENY_MISSING` / `DENY_DECLARED_MISSING`), and on this
   table disappearing.

   > Settled, 2026-09-17: operator decision 28 = **D** (hugmesh-generator#347),
   > landed by hugmesh-generator#484. History, because this note has said both
   > things. `integrate/superadmin` added the `allow = true` clause **and** the deny
   > row that motivated it (`hugmesh-fe-gateway` `/bff/superadmin/games-services/**`).
   > On the 2026-09-16 merge the clause landed and the row did not: operator decision
   > 8 (#244 ACCEPT) is SPECIFIC to that row and was answered "without the
   > games-services deny row", while decision 20 ("land the whole branch") is the
   > LATER, GENERAL one. Recency argued for the row, specificity against it. The
   > specific answer was applied and the choice was parked for the operator as
   > decision 28. Decision 28 answers it: the row goes back in, with `mfa_required`
   > seeded true on the row itself. That 2026-09-16 note also said the row "strips
   > the floor". **That was read off the wrong function**: `decide()`, whose MFA leg
   > is grant-scoped, instead of `isMfaRequiredSurface()`, which the privileged floor
   > actually calls. It is why leaving the row out looked forced. See the paragraph
   > above the table. The `integrate/superadmin` branch also wrote "every row" in
   > place of "the 10 rows" here, before the count became 10 under the same ACCEPT.

   To see the **scope boundary** instead, meaning the 10 gated rows *and* the seven
   §1.2a rows that are `false` by design, use this query. It is the same admin-ish
   enumeration the gate itself performs (path segment `admin`/`superadmin` **or** an
   `*_ADMIN`/`SUPERADMIN` role, which is how the three role-privileged exclusions get
   in at all):

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
   ⚠ Do **not** use `LIKE '/bff/%admin%'` for this. An earlier revision of this
   runbook said that form "also returns the six §1.2a rows". It does not. It returns
   **four** of the seven, because `/bff/mod/**`, `/bff/image-builds/arch/**` and
   `/bff/games-services/instances/**` have no `admin` substring in `url_pattern` at
   all and are excluded by **role**. An operator reading that output would conclude
   those three privileged surfaces were inside the gate. The gate now *executes*
   these blocks (`tests/scripts/test-mfa-required-rules.sh`) against the replayed
   seed and compares them with the real row sets, so neither can drift back into
   prose that is merely plausible. **Still no behaviour change at this point.**
5. **Exercise it in the compose dev stack first.** Compose mounts the *same* seed
   file (`tests/stack/compose.local.yaml` mounts
   `specs/cluster/manifests/route-access/initdb/20-schema.sql` into
   `/docker-entrypoint-initdb.d/`), so a `make stack-up` on a fresh `route-access-pg`
   volume seeds the rows locally. Compose also sets `APP_MFA_ENABLED=true` on the
   gateways, so you get the real enforcement leg for the non-privileged case (§3.1).
   You can rehearse step 7's privileged floor itself, per run and lockout-free, with
   `make stack-up MFA_FLOOR=1`. That is a Makefile variable. It threads
   `APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true` into the compose gateways for that run
   only, and expands to nothing otherwise, so the committed compose default stays
   `false` and a plain `make stack-up` is byte-identical.

   `tests/e2e/specs/29-mfa-privileged-floor.spec.ts` is the end-to-end proof for both
   modes. Run it **twice**:

   | stack | run as | what it proves |
   |---|---|---|
   | `make stack-up` | `npx playwright test 29-mfa-privileged-floor` | a pure `ROLE_FLEET_ADMIN` is 403'd on `/bff/admin/phone-fleet/**` without a stamp, and — §3.1's small print — the *same* admin on the *same* blanket is **not** gated |
   | `make stack-up MFA_FLOOR=1` | `MFA_FLOOR=1 npx playwright test 29-mfa-privileged-floor` | the floor: admin 403 without a fresh factor, a real TOTP enroll + step-up challenge driven through the shipped login-ui pages, the same route then passing, and a non-`mfa_required` surface untouched |

   The floor legs are the ONLY thing `MFA_FLOOR=1` un-gates in that spec. Every other
   precondition FAILS loudly rather than skipping. Two are worth knowing before you
   blame the code:
   * the seed rows land through **initdb**, which runs only on a *fresh*
     `route-access-pg` volume. Run `make stack-clean` before `make stack-up`, or an
     older volume will enforce nothing;
   * the enroll leg needs the admin-bff MFA surface live
     (`APP_CASDOOR_MFA_ENABLED=true` **and** `APP_MFA_FACTOR_KEY`, both already
     defaulted in `compose.local.yaml`), and the `e2e-fleet` persona from
     `tests/stack/seed-e2e.sh`. That persona is a deliberate `ROLE_FLEET_ADMIN` +
     `ROLE_USER` account with **no** `ROLE_ADMIN`, since an admin would bypass
     `decide()` and the fleet leg would prove nothing.

   Compose has **no** superadmin gateway, only pki/be/fe.
6. **Turn on `APP_MFA_ENABLED` for the cluster gateways.** Hand-adding an
   `extraEnv: APP_MFA_ENABLED` to a gateway Application still fails the posture gate
   on purpose. Set the shared chart's `mfa.enabled` value. All four gateway
   Applications point at the one chart, so a chart-level default reaches all four.
   Keep it out of the per-app manifests (the gate enforces that). Watch for 403s
   from non-privileged holders of `ROLE_FLEET_ADMIN`.
   ⚠ **This is the step that permanently denies machine `client_credentials` traffic.**
   A client-credentials token has no user subject, and `mfa_satisfied_at` is a
   Casdoor *user* Property, so there is nothing to stamp and no second factor to
   enrol. Enumerate any such caller on `/bff/admin…` / `/bff/superadmin…` **before**
   this flip. Human callers are fine on both carriers, but a raw-JWT human must
   **re-mint** after completing MFA (nothing does it for them). Read §2.4 before
   flipping.
   ⚠ **The flip commit must also move the gate's expectation pin, in the same
   change.** `tests/stack/test-gateway-mfa-env.sh` hard-pins the cluster posture OFF
   in an `EXPECT_*` table near the top of the file:

   ```sh
   EXPECT_APP_MFA_ENABLED="false"                    # cluster/chart
   EXPECT_APP_MFA_FRESHNESS_WINDOW="600000"
   EXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR="false"
   CEXPECT_APP_MFA_ENABLED="true"                    # compose dev stack
   CEXPECT_APP_MFA_FRESHNESS_WINDOW="600000"
   CEXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR="false"
   ```

   Every rendered gateway release is asserted against the `EXPECT_*` half. A flip
   commit that changes the chart but not `EXPECT_APP_MFA_ENABLED` turns that lint
   gate red. That is by design: the pin exists so the posture can never drift
   silently, and the red is telling you to move the pin **deliberately**, not to
   delete the gate. That commit has one more thing to face in the open. The script
   has a self-check that refuses to run at all when `EXPECT_APP_MFA_ENABLED` and
   `CEXPECT_APP_MFA_ENABLED` agree, because the two tables exist precisely because
   that pair is asymmetric. So flipping the cluster to `true` while compose is also
   `true` means rethinking that guard in the same review. (The self-check covers
   `APP_MFA_ENABLED` only. The floor pins in step 7 are `false` on both sides and
   are not subject to it.)
7. **Only then consider `APP_MFA_ENFORCE_PRIVILEGED_FLOOR`** — the same chart value.
   This is the step that actually gates admins and superadmins. Expect 503s during
   each gateway's cold-start priming window. Do it on one gateway first (the fe
   gateway, which carries `/bff/admin/**`) and keep a second authenticated
   superadmin session open on another browser as a canary before touching the
   superadmin gateway.
   ⚠ Same pin rule as step 6, on the floor row of the table shown there:
   `tests/stack/test-gateway-mfa-env.sh` pins
   `EXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR="false"` (cluster) **and**
   `CEXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR="false"` (compose; the dev stack floor
   stays off in the committed file, and `make stack-up MFA_FLOOR=1` is the supported
   per-run override, see step 5, which does not touch the pin). A cluster floor flip
   must move `EXPECT_APP_MFA_ENFORCE_PRIVILEGED_FLOOR` in the same change or the gate
   goes red. Rehearse it on compose with `MFA_FLOOR=1` +
   `tests/e2e/specs/29-mfa-privileged-floor.spec.ts` first. That is the only place the
   floor's behaviour is exercised end to end.

### 3.1 What actually changes at each step (be honest about the small print)

With `enabled=true` but `enforce-privileged-floor=false` (the recommended
intermediate state), `ROLE_SUPERADMIN`, `ROLE_ADMIN` and `ROLE_GAME-MASTER`
short-circuit in `GatewayRouteAccessFilter` **before** `decide()` runs. So of the 10
flipped rows, the only ones that change behaviour are the
**`/bff/admin/phone-fleet/** → ROLE_FLEET_ADMIN`** row. A pure fleet owner is not
privileged, so it reaches `decide()`, and without a fresh `MFA_SATISFIED` marker it
gets a 403.

That is the whole point of the two-flag design. It also means: **do not read a quiet
cluster after step 6 as evidence that admin MFA works.** It does not gate admins
until step 7.

---

## 4. Preconditions in detail

### 4.1 Factor key (`APP_MFA_FACTOR_KEY` / `app.mfa.factor-key`)

A 256-bit AES-GCM data key. `MfaSecretCipher` uses it to encrypt every enrolled TOTP
secret at rest, and it keys the recovery-code HMAC.

- Cluster: `specs/cluster/manifests/admin-bff-api/deployment.yaml` reads it from the
  ESO Secret `admin-bff-mfa`, key `factor-key`. The ref is **REQUIRED** (no
  `optional:`). The ExternalSecret is in
  `specs/cluster/manifests/external-secrets/secretstore.yaml`. The value is minted by
  `scripts/gen-cluster-secrets.sh` (`openssl rand -base64 32`) into Vault at
  `secret/<brand>/admin-bff-mfa.factor_key`.
- Compose: `tests/stack/compose.local.yaml` `APP_MFA_FACTOR_KEY` has a dev default.
  **It is a committed dev value — never reuse it outside compose.**
- An absent Secret **blocks pod start** at the Kubernetes layer
  (`CreateContainerConfigError` naming `admin-bff-mfa`). The alternative is a pod
  whose cipher is INERT and whose TOTP enroll and recovery generation silently
  **refuse** (no plaintext fallback). That silent failure is why the ref used to be
  `optional: true`. With `app.casdoor.mfa.enabled` armed in-cluster the key is
  load-bearing, so a missing key is now a loud scheduling failure with a clear
  reason. It is still step 1, but you find out from `kubectl get pods`, not from a
  user's failed enrollment. `test-cluster-manifest-integrity.sh` pins both the
  required posture and that the ref's `name`/`key` match what the ExternalSecret
  materializes.
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

For your own domain these must be rewritten. The `rebrand_sysroot` path rewrites
`admin.hugmesh.net` → `admin.<domain>` per tenant (`build-x86-host-stage4.sh`);
confirm it did. Rules:

- RP-ID must be the registrable suffix of every origin the admin UI is served from.
  A credential registered under one RP-ID **cannot** be asserted under another, so
  changing RP-ID later invalidates every enrolled key.
- Origins must be the exact `https://host[:port]` strings the browser sends,
  including every alias operators actually use. HTTPS is mandatory (except
  `http://localhost`).
- If operators reach the console over the tailnet on a different hostname than
  `admin.<domain>`, that origin must be listed too. Otherwise WebAuthn silently fails
  there and only TOTP works.

---

## 5. Do not hand-edit rows

The admin-bff is the CRUD writer for `gateway_route_access`, so you *can* flip an
individual row's `mfa_required` through the admin API. Don't use that to carve out
exemptions:

- The seed converges. Re-applying `20-schema.sql` re-flips anything under
  `/bff/admin/…` or `/bff/superadmin/…` back to `true`, exactly as the `INSERT`
  above it re-creates deleted seed rows. Your exemption disappears at the next
  in-place apply.
- Exempt a surface by changing the `WHERE` predicate in `20-schema.sql`, so the
  exemption is reviewable, testable and survives a re-apply. **Narrow the predicate.
  Do not append a second `UPDATE … SET mfa_required = false`.** An appended un-flip
  leaves the file's net effect un-gated while every statement in it still *looks*
  right. `tests/scripts/test-mfa-required-rules.sh` replays the whole file on a real
  SQL engine and fails on exactly that. It also fails if any statement **other than
  that one `UPDATE`** writes the column. The single exception is the in-place-upgrade
  `WHERE mfa_required IS NULL` repair near the top of the file, which is matched as
  a *whole statement* (so a second predicate cannot be smuggled into it) and which
  must stay ahead of the flip. It recognises the write in every spelling Postgres
  accepts: bare, `public.`-qualified, `"double-quoted"`, or led by a CTE. It also
  refuses to run at all if the file contains a statement of a *kind* it cannot
  classify. That last part matters: while the matcher demanded a bare table name, an
  appended `DELETE FROM public.gateway_route_access WHERE url_pattern LIKE
  '/bff/superadmin%'` wiped every superadmin row and the gate still reported a clean
  pass. Update §1.2 / §1.2a in the same commit. The gate cross-checks the documented
  exclusion list against the real rows in both directions, so prose and predicate
  cannot drift apart.
- Adding a **parallel** row that differs only in `mfa_required` does nothing.
  `mfa_required` is not part of `uq_route_access_row`
  `(gateway, url_pattern, role, COALESCE(casdoor_user,''),
  COALESCE(NULLIF(lower(trim(domain)),'default'),''))`, so the row collides and
  `ON CONFLICT DO NOTHING` silently drops it. This is the easiest way to *think* you
  have enabled MFA on a surface while enabling nothing. The domain leg is the
  **gateway's scope equivalence**, not the raw text, so a `'Default'` or
  case/whitespace re-spelling of an existing row's domain collides too. A row that
  differs in `domain` **for real** is the one legal sibling shape: per-domain
  tightening, §1.2a.

### 5.1 Known gap: MFA is not enforced during a dual-datastore outage

During a dual-datastore outage MFA is enforced on fewer surfaces than the Postgres
seed names, and on two surfaces the seed leaves open.

If both Postgres and the Cassandra mirror are unreachable, the gateway falls back to
its **baked-in** `CanonicalSeed`. That fallback is **not** the Postgres seed:
- it bakes `mfaRequired=true` on exactly eight rows, listed in
  `MFA_REQUIRED_FALLBACK_ROWS` in `hugmesh-gateway` (decision 56, widened by
  decision 80b): be `/bff/superadmin/**`; fe `/bff/admin/phone-fleet/**` (three
  roles), `/bff/admin/**`, `/bff/superadmin/**`; and fe `/bff/wiki/admin/**` and
  `/bff/wiki/superadmin/**`. Every other baked row is `false`;
- it does **not** carry `mfa_required` on the be `/bff/admin/workloads/**`,
  `/bff/superadmin/games-services/**` and `/bff/superadmin/workloads/**` rows, on the
  superadmin-gateway row, or on the fe games-services DENY row. During a full
  datastore outage those surfaces lose the second-factor requirement, and the
  role gating alone applies;
- it requires one on the two wiki console rows, which the Postgres seed leaves
  `false` (§1.2a). So an outage briefly tightens those two surfaces.

The choice to keep most rows `false` is deliberate in `hugmesh-gateway`: a datastore
outage must not lock the privileged plane out on the bare floor, and the lock-out
risk stays bounded to rows an operator can name. The gateway pins the set with its
own test. A gateway with an unknown name falls back to a closed floor (only
`ROLE_ADMIN` reaches anything). The dual-write trio (gateway fallback set, this
Postgres seed, the admin-bff copy) is kept aligned by hand in three repos. Change it
in `hugmesh-gateway`; this repo cannot fix it.

---

## 6. Rollback

Roll back in the reverse of §3. Only the flags are hot. The rules are data.

1. **Immediate relief for a privileged lockout:** set
   `APP_MFA_ENFORCE_PRIVILEGED_FLOOR=false` on the affected gateway(s) and restart.
   The privileged bypasses come back, and admins/superadmins reach the admin plane
   again without a factor. Try this first. It needs no DB access.
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
   row is left `mfa_required=true` afterwards. A rollback that silently stopped
   covering one of the prefixes fails the build.) The gateways pick this up on
   their next route-access refresh (`app.route-access.refresh-interval-ms`, default
   5 s), with no restart. This is undone the next time `20-schema.sql` is applied.
   To make it permanent, revert the `UPDATE` block in that file.
4. **If both flags are off and privileged callers still 503:** that is the
   cold-start hold, and it only runs under `enforce-privileged-floor`. If you see it
   with the flag off, the flag did not actually reach the pod. Check the rendered
   env, not the chart values.
5. **Break-glass for a locked-out operator with no factor:** there is no in-band path
   (the recovery-regenerate endpoint is itself step-up gated). Use cluster access:
   `kubectl exec` to the admin-bff's Postgres and delete that subject's rows from the
   MFA factor tables (changelogs `150-mfa-substrate.xml`, `151-mfa-factors.xml`), or
   roll back per step 1. Then re-enroll. If you have no cluster access either, you
   are relying on someone who does. Make sure that person exists and is not the same
   single operator before step 7.

---

## 7. Files this runbook refers to

| path | what |
|---|---|
| `specs/cluster/manifests/route-access/initdb/20-schema.sql` | the `gateway_route_access` table + canonical seed + the `mfa_required` `UPDATE` |
| `tests/scripts/test-mfa-required-rules.sh` | the gate over the rules (net-effect replay) + the enablement posture (structured ArgoCD parse **and** the shape-aware `APP_MFA_*` sweep over all of `specs/` + the compose stack) + the six SQL blocks in **this** runbook, which it executes against the replayed seed |
| `tests/scripts/test-cluster-manifest-integrity.sh` | verifies every seeded `gateway` id is a deployed gateway |
| `specs/cluster/apps/20-gateway-{pki,be,fe}.yaml`, `specs/cluster/apps/22-gateway-superadmin.yaml` | the four gateway Applications; `instance.name` here is the `gateway` column value each pod loads |
| `specs/cluster/manifests/admin-bff-api/deployment.yaml` | `APP_CASDOOR_MFA_ENABLED`, `APP_MFA_FACTOR_KEY`, `APP_MFA_WEBAUTHN_RP_ID`, `APP_MFA_WEBAUTHN_ORIGINS` |
| `specs/cluster/manifests/external-secrets/secretstore.yaml` | the `admin-bff-mfa` ExternalSecret |
| `scripts/gen-cluster-secrets.sh` | mints the factor key into Vault |
| `tests/stack/compose.local.yaml` | dev stack: gateway `SPRING_APPLICATION_NAME`s, `APP_CASDOOR_MFA_ENABLED`, `APP_MFA_FACTOR_KEY`, the initdb mount of the seed, AND the gateway `APP_MFA_*` trio (`APP_MFA_ENABLED=true` — the deliberate dev-vs-cluster asymmetry) |
| `specs/cluster/charts/hugmesh-gateway/values.yaml` | shared gateway chart; carries the `mfa:` block (`enabled: false`) reaching all four gateways |
| `specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml` | renders `APP_MFA_ENABLED` / `APP_MFA_FRESHNESS_WINDOW` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` into every gateway pod. The sweep in §1.3 watches this file specifically, because it is the one place a single edit reaches all four gateways |
| `tests/stack/test-gateway-mfa-env.sh`, `tests/stack/gateway_mfa_env.py` | the gate over that wiring: pins BOTH postures (cluster `false` / compose `true`) and refuses to run if that asymmetry disappears. Its posture parser overlaps the rules gate's, and the two could be collapsed into one shared helper |

Cross-repo (not changeable from here):
`hugmesh-gateway` `filter/GatewayRouteAccessFilter.java`,
`cache/GatewayRouteAccessService.java`, `cache/CanonicalSeed.java`,
`config/CasdoorAuthorities.java`, `filter/BffSessionAuthFilter.java`;
`hugmesh-auth-core` `mfa/MfaEnrollmentService.java`, `mfa/RecoveryCodeService.java`,
`casdoor/MfaChallengeController.java`, `casdoor/MfaChallengeService.java`.

---

## 8. `MFA=1` — the operational flip switch (issue #47)

Everything above describes WHAT to flip. This section is the ONE switch that
performs the flip, per lane, following the `PHPBB=1` / `AKKOMA=1` knob precedent. It
flips **only `app.mfa.enabled`**. The freshness window keeps its default (600000)
everywhere, and the privileged floor is **not reachable from this switch on any
lane**. `MFA_FLOOR=1` (§3 step 5) stays its own deliberate, compose-only rehearsal
knob, and a cluster floor flip stays the hand-executed §3 step 7. **Every
precondition in §2 (enroll before you enforce, the machine-caller census in §2.4)
binds on every lane below.** Nothing here changes a committed default: the chart
stays `false`, no `specs/cluster/apps/*.yaml` flips it, and the posture gates
(`tests/stack/test-gateway-mfa-env.sh`, `tests/scripts/test-mfa-required-rules.sh`)
keep enforcing that.

| lane | invocation | mechanism | scope |
|---|---|---|---|
| compose dev stack | `make stack-up MFA=1` | threads an EXPLICIT `APP_MFA_ENABLED='true'` into every compose invocation (`STACK_MFA_ENV` in the Makefile), overriding even an operator shell that exports `APP_MFA_ENABLED=false`. A plain `make stack-up` stays byte-identical (the dev default is already `true`, §1.3). | the run |
| kind SSO slice | `make kind-up MFA=1` | `bootstrap-kind.sh` appends a `mfa.enabled=true` **helm parameter** to every gateway Application it applies (today: `hugmesh-gateway-fe`) — the same runtime-patch mechanism as its `ingress.className` override, so the committed chart/apps stay untouched. Fails loudly under `KIND_PROFILE=core` (no gateway is applied there) and on any unrecognised `MFA` spelling. With it on, spec 27's cluster carries live route-level enforcement for the non-privileged case, same as compose (§3.1). | the kind cluster |
| per-domain / tenant | `MFA=1` in `brands/<brand>.conf`, then `./generate-brand-repos.sh brands/<brand>.conf` | renders `mfa: {enabled: true}` into **that brand's** gateway Applications via the `{{MFA_ENABLED}}` token (both render engines; parity-proven). Conf-only by design: an ambient exported `MFA=1` does NOT leak into a render whose profile never set it (root-cron reconcile safety). | one `CLUSTER_DOMAIN` |

**The reference cluster (specs/cluster) is deliberately NOT a lane.** Its flip stays
§3 step 6: a reviewed commit that sets the shared chart's `mfa.enabled` and moves
the `EXPECT_*` pins in the same change. `MFA=1` gives you the rehearsal (compose),
the integration proof (kind), and the tenant rollout (brands). It never silently
changes the posture a cluster ships with.

**Per-domain WITHIN one mesh** (several local domains behind the same gateways) is
expressible. The casdoor-choice schema landed (PR #71) and the join point named here
was implemented: `uq_route_access_row`'s domain leg is keyed on the gateway's own
scope equivalence, the seed's `UPDATE` carries a per-domain arm (empty today), and
§1.2a's scope table says exactly what a domain-scoped row can express (per-domain
**tightening**), cannot express (per-domain **exemption**, because `decide()` is a
sticky OR and the blanket rows are unscoped), and what an **own-IdP** domain means
for a `MFA=1` flip (its principals cannot enroll, so enumerate them before §3 step
6).

Wiring proof: `tests/stack/test-mfa-flip-wiring.sh` (CI `lint:mfa-flip-wiring`)
re-derives every consumer of the trio per lane from the artifacts themselves and
fails if any consumer stops receiving the switch. That is the inert-toggle failure
mode (a flag wiring only half its consumers has shipped dark twice in this repo). All
of its checks are mutation-tested on staged copies (34 passed / 0 failed on
2026-10-07).

### 8.1 Observing the flip on the kind lane

```console
$ make kind-mfa-posture      # what the RUNNING gateway pod actually has
APP_MFA_ENABLED=false
$ make kind-e2e-mfa          # spec 29 against the cluster, at that live posture
```

`kind-e2e` runs spec 27 only, so `kind-e2e-mfa` exists to run the MFA spec against
whichever posture the kind cluster holds. The target reads `APP_MFA_ENABLED` back
off the gateway Deployment (`scripts/kind-mfa-posture.sh`) and hands it to spec 29,
which **selects** between its two stack blocks on that value. `false` runs the
OFF-posture block (the seeded `mfa_required` rows are inert, the role wall on the
same rows is not, an un-enrolled admin is never challenged). Anything else runs the
per-row enforcement block.

The posture is read live, never guessed, and never threaded from `$(MFA)`,
deliberately. `kind-up` is a separate invocation and the cluster outlives it, so the
caller's shell describes a cluster it may never have flipped. The repo cannot answer
either, because `kind-up MFA=1` flips through an ArgoCD **helm parameter**, leaving
the committed chart reading `mfa.enabled: false` on a cluster that is enforcing. The
helper is fail-closed: an unreachable cluster is an error, not an "assume off" that
would report a clean pass for the posture the cluster is **not** holding.

**What the flip changes, concretely** (verified on the kind SSO slice, 2026-08-20,
when 9 `mfa_required` rows were seeded and `hugmesh-gateway-fe` held
`APP_MFA_ENABLED=false`; the seed now flips 10 and floors 11): `make kind-up MFA=1`
appends `{"name":"mfa.enabled","value":"true"}` to the `hugmesh-gateway-fe`
Application's helm parameters, the chart re-renders `APP_MFA_ENABLED=true` into the
gateway container, and the pod rolls. Nothing else moves: `APP_MFA_FRESHNESS_WINDOW`
stays 600000 and `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` stays `false` (§3 step 7 is
still a hand-executed step). The observable difference is that a pure
`ROLE_FLEET_ADMIN` on `/bff/admin/phone-fleet/**` goes from "reaches admin-bff" to
the gateway's 403 + `X-Route-Denied`. Privileged roles are unchanged until the
floor is on (§3.1).

⚠ The equivalent one-shot `kubectl patch` must carry **both** parameters.
`--type merge` replaces `spec.source.helm.parameters` wholesale, so a patch that
sets only `mfa.enabled` drops the kind lane's `ingress.className: nginx-internal`
override and nothing routes.
