# MFA rollout — operator runbook (gateway `mfa_required` floor + admin-bff step-up)

**Audience:** the operator who will actually turn MFA enforcement on. This is not a
design doc; it is the order of operations, the preconditions that will lock you out
if you skip them, and how to roll back.

**Default posture today: enforcement is OFF on a cluster and nothing here changes
that.** Seeding the `mfa_required` rules (below) is inert until *you* flip a flag.

---

## 0. Read this first: this change and its companion

The feature has **two halves in two commits**, and this runbook ships with the first
one. Read the table before you follow any step below, because §3 step 6 is a **no-op
until the second half lands**.

| half | what it contains | where it is |
|---|---|---|
| **rows** (this change) | the `mfa_required` `UPDATE` in `20-schema.sql`, this runbook, `tests/scripts/test-mfa-required-rules.sh` | branch `feat/mfa-required-rules` |
| **flag wiring** (companion) | the shared chart's `mfa:` values block, the chart template that renders `APP_MFA_ENABLED` / `APP_MFA_FRESHNESS_WINDOW` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` into every gateway pod, the compose-stack defaults, `tests/stack/test-gateway-mfa-env.sh` | branch `feat/gateway-mfa-env` |

**What that means concretely, on this branch alone:**

- Nothing in the chart, the gateway Applications or the compose stack mentions the
  gateway MFA env at all — no `mfa:` values block, no rendered env, no compose
  default:

  ```console
  $ grep -rn 'APP_MFA_ENABLED\|APP_MFA_ENFORCE_PRIVILEGED_FLOOR' \
      specs/cluster/charts specs/cluster/apps tests/stack/
  $ echo $?
  1
  ```

  (`20-schema.sql` and this runbook *name* those env vars in prose; nothing **sets**
  them.) `tests/stack/compose.local.yaml` carries only `APP_MFA_FACTOR_KEY` and
  `APP_CASDOOR_MFA_ENABLED` — those are the admin-bff step-up leg (§1.1), different
  flags.
- So the rows here are not merely *default-off*, they are **unreachable**: there is no
  supported knob in this repo that can make the gateway consult them.
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

Wherever a claim below is only true **after** the companion lands, it says so
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
     OR url_pattern LIKE '/bff/superadmin/%')
   AND mfa_required IS DISTINCT FROM true;
```

(That block is not retyped prose: the gate compares it byte-for-byte against the
statement in `20-schema.sql`, so it cannot drift.)

That flips **9 rows** (as of this writing) across three gateways:

| gateway | url_pattern | role |
|---|---|---|
| `hugmesh-fe-gateway` | `/bff/admin/**` | `ROLE_ADMIN` |
| `hugmesh-fe-gateway` | `/bff/admin/phone-fleet/**` | `ROLE_FLEET_ADMIN`, `ROLE_ADMIN`, `ROLE_SUPERADMIN` |
| `hugmesh-be-gateway` | `/bff/admin/workloads/**` | `ROLE_ADMIN` |
| `hugmesh-be-gateway` | `/bff/superadmin/**` | `ROLE_SUPERADMIN` |
| `hugmesh-be-gateway` | `/bff/superadmin/games-services/**` | `ROLE_SUPERADMIN` |
| `hugmesh-be-gateway` | `/bff/superadmin/workloads/**` | `ROLE_SUPERADMIN` |
| `hugmesh-superadmin-gateway` | `/bff/superadmin/**` | `ROLE_SUPERADMIN` |

Read that table twice. `/bff/superadmin/**` is governed on **two** gateways and
`/bff/admin/…` on **two** gateways; the write is prefix-based and gateway-blind on
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
`IS DISTINCT FROM true` — but nothing about the file's net effect is.) The engine is
sqlite3: Postgres is not installed in CI, so **these rules have never been executed
on Postgres**; the gate says so on every run.

### 1.2a Scope: exactly two prefixes — and what that leaves OUT

The authorised scope is the **two path prefixes** `/bff/admin…` and
`/bff/superadmin…`, blanket *within* them. It is **not** "every admin surface", and
the difference matters if you are reasoning about what an attacker can still reach
with a stolen session and no second factor. Six other admin-ish `/bff/` rows are
deliberately left `mfa_required=false`:

| gateway | url_pattern | role | why it is out of scope |
|---|---|---|---|
| `hugmesh-fe-gateway` | `/bff/forum/admin/**` | `ROLE_ADMIN` | per-service admin console seam behind its **own** service-BFF prefix, not under `/bff/admin`. Covering it needs a different predicate *shape* (`LIKE '/bff/%/admin/%'`) |
| `hugmesh-fe-gateway` | `/bff/wiki/admin/**` | `ROLE_ADMIN` | ditto |
| `hugmesh-fe-gateway` | `/bff/owncast/admin/**` | `ROLE_ADMIN` | ditto |
| `hugmesh-fe-gateway` | `/bff/mod/**` | `ROLE_ADMIN` | a **moderation** surface; `ROLE_ADMIN` is paired on it only as a superset of `ROLE_MOD`, so gating it would gate moderation, not administration |
| `hugmesh-be-gateway` | `/bff/image-builds/arch/**` | `ROLE_SUPERADMIN` | privileged by **role**, not by path — a prefix predicate cannot express it |
| `hugmesh-be-gateway` | `/bff/games-services/instances/**` | `ROLE_GAMES_SERVICES_ADMIN` | ditto (derived `games-services ∩ (admin\|mod)` role) |

Each of the three shapes above would be a **new scope decision**, not a bug fix:
widening enlarges the §3 step-7 lockout blast radius, so it is the operator's call.
If you do widen, widen the prose in the same commit — and note that the gate
enumerates admin-ish surfaces *independently* of the `UPDATE`'s own prefixes and
cross-checks them against exactly this list, so a **seventh** admin-ish `/bff/` row
appearing later fails the build until someone decides consciously (and a stale entry
in the list fails it too).

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

**⚠ On this branch nothing in this repo sets any of those three.** The shared chart
`specs/cluster/charts/hugmesh-gateway` (used by **all four** gateway Applications:
`specs/cluster/apps/20-gateway-{pki,be,fe}.yaml` and
`specs/cluster/apps/22-gateway-superadmin.yaml`) has **no `mfa:` values block yet**,
and no template renders the env into a pod. Verify that yourself rather than trusting
this sentence:

```console
$ grep -rn 'APP_MFA_ENABLED\|APP_MFA_ENFORCE_PRIVILEGED_FLOOR' \
    specs/cluster/charts specs/cluster/apps tests/stack/
$ echo $?
1
```

**After the companion change (§0) lands**, the three become chart values —
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
> `extraEnv`, which is the only mechanism the chart supports until the companion
> lands. A `helm.valueFiles` / `helm.fileParameters` reference, or an `APP_MFA_*`
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

---

## 3. Order of operations

Do these in order. Do not batch them. **Steps 1–5 are actionable on this branch;
steps 6–7 need the companion change from §0** and say so again where they appear.

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
    WHERE url_pattern LIKE '/bff/admin%'
       OR url_pattern LIKE '/bff/superadmin%'
    ORDER BY 1, 2, 3;
   ```

   Expect the 9 rows in §1.2 at `true`, and nothing else.

   To see the **scope boundary** instead — the 9 gated rows *and* the six §1.2a
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

   Expect **15** rows: the 9 at `true`, then the 6 §1.2a exclusions at `false`.
   ⚠ Do **not** use `LIKE '/bff/%admin%'` for this — an earlier revision of this
   runbook said that form "also returns the six §1.2a rows". It does not: it
   returns **three** of them, because `/bff/mod/**`,
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
   enforcement leg for the non-privileged case (see §3.1). Note compose has **no**
   superadmin gateway — only pki/be/fe.
6. **Turn on `APP_MFA_ENABLED` for the cluster gateways** — ⚠ **needs the companion
   change (§0)**; until it lands there is no knob, and hand-adding an
   `extraEnv: APP_MFA_ENABLED` to a gateway Application fails the posture gate on
   purpose. Once it is in, set the shared chart's `mfa.enabled` value: all four
   gateway Applications point at the one chart, so a chart-level default reaches all
   four; keep it out of the per-app manifests (the gate enforces that). Watch for
   403s from non-privileged holders of `ROLE_FLEET_ADMIN`.
7. **Only then consider `APP_MFA_ENFORCE_PRIVILEGED_FLOOR`** — same companion
   dependency. This is the step that actually gates admins and superadmins. Expect
   503s during each gateway's cold-start priming window. Do it on one gateway first
   (the fe gateway, which carries `/bff/admin/**`) and keep a second authenticated
   superadmin session open on another browser as a canary before touching the
   superadmin gateway.

### 3.1 What actually changes at each step (be honest about the small print)

With `enabled=true` but `enforce-privileged-floor=false` — the recommended
intermediate state — `ROLE_SUPERADMIN`, `ROLE_ADMIN` and `ROLE_GAME-MASTER`
short-circuit in `GatewayRouteAccessFilter` **before** `decide()` runs. So of the 9
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
  value: "admin.hugmesh.systems"
- name: APP_MFA_WEBAUTHN_ORIGINS
  value: "https://admin.hugmesh.systems"
```

For your own domain these must be rewritten (the `rebrand_sysroot` path rewrites
`admin.hugmesh.systems` → `admin.<domain>` per tenant — confirm it did). Rules:

- RP-ID must be the registrable suffix of every origin the admin UI is served from.
  A credential registered under one RP-ID **cannot** be asserted under another —
  changing RP-ID later invalidates every enrolled key.
- Origins must be the exact `https://host[:port]` strings the browser sends,
  including every alias operators actually use. HTTPS is mandatory (except
  `http://localhost`).
- If operators reach the console over the tailnet on a different hostname than
  `admin.<domain>`, that origin must be listed too, or WebAuthn silently fails
  there and only TOTP works.

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
  `(gateway, url_pattern, role, COALESCE(casdoor_user,''), COALESCE(domain,''))`,
  so the row collides and `ON CONFLICT DO NOTHING` silently drops it. This is the
  single easiest way to *think* you have enabled MFA on a surface while enabling
  nothing.

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
   access — `kubectl exec` to the admin-bff's Postgres and delete that subject's
   rows from the MFA factor tables (changelogs `150-mfa-substrate.xml`,
   `151-mfa-factors.xml`), or roll back per step 1 — then re-enroll. If you have no
   cluster access either, you are relying on someone who does; make sure that
   person exists and is not the same single operator before step 7.

---

## 7. Files this runbook refers to

| path | on this branch? | what |
|---|---|---|
| `specs/cluster/manifests/route-access/initdb/20-schema.sql` | **yes** | the `gateway_route_access` table + canonical seed + the `mfa_required` `UPDATE` |
| `tests/scripts/test-mfa-required-rules.sh` | **yes** | the gate over the rules (net-effect replay) + the enablement posture (structured ArgoCD parse **and** the shape-aware `APP_MFA_*` sweep over all of `specs/` + the compose stack) + the four SQL blocks in **this** runbook, which it executes against the replayed seed |
| `tests/scripts/test-cluster-manifest-integrity.sh` | **yes** | verifies every seeded `gateway` id is a deployed gateway |
| `specs/cluster/apps/20-gateway-{pki,be,fe}.yaml`, `specs/cluster/apps/22-gateway-superadmin.yaml` | **yes** | the four gateway Applications; `instance.name` here is the `gateway` column value each pod loads |
| `specs/cluster/manifests/admin-bff-api/deployment.yaml` | **yes** | `APP_CASDOOR_MFA_ENABLED`, `APP_MFA_FACTOR_KEY`, `APP_MFA_WEBAUTHN_RP_ID`, `APP_MFA_WEBAUTHN_ORIGINS` |
| `specs/cluster/manifests/external-secrets/secretstore.yaml` | **yes** | the `admin-bff-mfa` ExternalSecret |
| `scripts/gen-cluster-secrets.sh` | **yes** | mints the factor key into Vault |
| `tests/stack/compose.local.yaml` | **partly** | dev stack: gateway `SPRING_APPLICATION_NAME`s, `APP_CASDOOR_MFA_ENABLED`, `APP_MFA_FACTOR_KEY`, and the initdb mount of the seed. The gateway `APP_MFA_*` trio arrives with the companion (§0) |
| `specs/cluster/charts/hugmesh-gateway/values.yaml` | **no — companion (§0)** | shared gateway chart; gains the `mfa:` block reaching all four gateways |
| `specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml` | file exists; the MFA env is **no — companion (§0)** | will render `APP_MFA_ENABLED` / `APP_MFA_FRESHNESS_WINDOW` / `APP_MFA_ENFORCE_PRIVILEGED_FLOOR` into every gateway pod. Today it renders none of them, and the sweep in §1.3 watches this file specifically — it is the one place a single edit reaches all four gateways |
| `tests/stack/test-gateway-mfa-env.sh`, `tests/stack/gateway_mfa_env.py` | **no — companion (§0)** | the companion's own gate over that wiring. Its posture parser overlaps this branch's; **collapse the two into one shared helper once both have landed** (deliberately not shared now — importing across an unmerged branch would break CI) |

Cross-repo (not changeable from here):
`hugmesh-gateway` `filter/GatewayRouteAccessFilter.java`,
`cache/GatewayRouteAccessService.java`, `cache/CanonicalSeed.java`,
`config/CasdoorAuthorities.java`, `filter/BffSessionAuthFilter.java`;
`hugmesh-auth-core` `mfa/MfaEnrollmentService.java`, `mfa/RecoveryCodeService.java`,
`casdoor/MfaChallengeController.java`.
