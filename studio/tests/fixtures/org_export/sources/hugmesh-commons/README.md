# hugmesh-commons

The shared, **canonical** HugMesh security / tenancy / config / web building
blocks. The classes in this library were previously duplicated — with only package names
and access modifiers changed — into every reactive BFF (`hugmesh-federation-api`,
`hugmesh-admin-bff-api`, `hugmesh-user-bff-api`, `hugmesh-owncast-bff-api`,
…) and the gateway. This library is the single source of truth for the reactive
BFFs, whose per-repo copies have been replaced by a compile dependency on it. The
gateway is the one exception — it deliberately keeps its own vendored copies; see
below.

It sits at the bottom of the shared-artifact stack. `hugmesh-auth-core` — the
shared account / session / MFA / Casdoor-admin infrastructure consumed by
`hugmesh-user-bff-api` and `hugmesh-admin-bff-api` — depends on **this** library
for its security and tenancy primitives. Every reactive BFF also depends on it
directly for the security / tenancy / web classes described below. The gateway
takes a direct, explicitly-versioned dependency on commons too, but only to pin
the Boot-4 / Security-7 binary-compat milestone: it deliberately keeps its own
vendored `Roles` / `DomainRegistry` / `CasdoorAuthorities` /
`TenancyResourceServerConfig`, because a class-by-class diff found the gateway's
copies are supersets carrying methods this library lacks and the gateway depends on
(see the native-login sequence diagram under [Current State](#current-state)).

```mermaid
flowchart TB
    commons["hugmesh-commons\n(this library)\nsecurity · tenancy · web"]
    auth_core["hugmesh-auth-core\naccount · session · MFA\nCasdoor-admin infra"]
    gateway["gateway\n(JWT resource server)"]
    federation["hugmesh-federation-api"]
    user_bff["hugmesh-user-bff-api"]
    admin_bff["hugmesh-admin-bff-api"]
    owncast_bff["hugmesh-owncast-bff-api"]
    forum_bff["hugmesh-forum-bff-api"]

    commons --> auth_core
    commons -.->|version pin only| gateway
    commons --> federation
    commons --> user_bff
    commons --> admin_bff
    commons --> owncast_bff
    commons --> forum_bff
    auth_core --> user_bff
    auth_core --> admin_bff
```

## Coordinates

```
groupId:    net.hugmesh
artifactId: hugmesh-commons
version:    2.1.0
packaging:  jar
```

Child of `net.hugmesh:hugmesh-parent:2.8.0` (the metapom), which pins the
ecosystem baseline: **Spring Boot 4.0.7 / Spring Cloud 2025.1.2** on **Java 25 LTS**
(eclipse-temurin:25), with Testcontainers 2.0.5.

## Contents

| Class | Package | Role |
|-------|---------|------|
| `Roles` | `net.hugmesh.commons.security` | JWT role / domain / MFA-stamp extraction. |
| `RoleName` | `net.hugmesh.commons.security` | closed enum of the four base Casdoor role tokens (`user`/`mod`/`admin`/`superadmin`); fail-closed `fromWire`/`require`/`isBaseRole` with the lowercase on-the-wire value preserved as a live contract. |
| `CasdoorAuthorities` | `net.hugmesh.commons.security` | Casdoor JWT → Spring authorities converter (the RESERVED-PREFIX injection guard lives here). |
| `DomainRegistry` | `net.hugmesh.commons.security` | issuer-URI → brand/domain map; single-issuer back-compat + multi-brand fail-closed; `knownDomains`/`isKnownDomain` validation. |
| `PrincipalDomain` | `net.hugmesh.commons.security` | instance-based, SUPERADMIN-aware per-request tenant scope (was the federation/admin `DomainScope`). |
| `DomainScope` | `net.hugmesh.commons.tenancy` | static SQL-predicate utility (`andPredicate`/`isUnscoped`) for per-domain repositories (was the user/owncast `DomainScope`). |
| `TenancyResourceServerConfig` | `net.hugmesh.commons.config` | config-gated, backward-compatible multi-issuer (per-brand Casdoor) resource-server wiring. |
| `ApiException` | `net.hugmesh.commons.web` | the BFF `{"error": msg}` exception with the full union of HTTP-status factories. |

## Preserved security behaviours

1. JWT `roles` claim → `ROLE_` authorities, via `Roles.fromJwt` and `CasdoorAuthorities`.
2. `isAdmin` claim (boolean or string, including the Casdoor legacy form) → `ROLE_ADMIN`.
3. `DOMAIN_<x>` authority is derived **only** from the cryptographically-validated JWT
   issuer URI — never from user-supplied claim values.
4. **RESERVED_PREFIXES guard** — any permission string beginning with `ROLE_`,
   `DOMAIN_`, or `MFA_SATISFIED` that arrives in a user-controlled claim is silently
   dropped, preventing authority injection, cross-tenant escalation, and MFA forgery.
5. **Fail-closed domain resolution** — an unknown issuer resolves to `null` (not a
   default domain). `domainOf(authorities)` also returns `null` when zero or more than
   one `DOMAIN_` authority is present, because multiple domain authorities are a sign of
   token manipulation.
6. SUPERADMIN principals are exempt from per-domain scoping. This is enforced uniformly
   via `Roles.isSuperadmin` and `PrincipalDomain`.
7. `MFA_SATISFIED` is derived only from a fresh `mfa_satisfied_at` stamp written by the
   BFF after a successful MFA challenge. Stamps set in the future, older than the
   acceptable window, or malformed are rejected. This authority ships disabled by
   default until MFA is enabled in the deployment.
8. Multi-issuer support (for per-brand Casdoor deployments) is opt-in and
   backward-compatible, controlled by `isMultiIssuer()` /
   `@ConditionalOnExpression`.

All eight are covered by the unit tests under `src/test/java`.

## What stays per-repo

`SecurityConfig` stays in each service: its `authorizeExchange` route matchers
(`/bff/admin/**`, `/bff/user/**`, `/bff/owncast/**`, `/api/federation/**`) and CSRF /
cookie handling differ between services and cannot be centralised. Each repo's
`SecurityConfig` wires the shared `CasdoorAuthorities` / `DomainRegistry` and,
optionally, `TenancyResourceServerConfig`, then declares its own route authorisation
rules. The per-repo security-slice test scaffold (`SecuritySliceSupport`) also stays
per-repo because it must construct the per-repo `SecurityConfig`.

## Using it

```xml
<dependency>
  <groupId>net.hugmesh</groupId>
  <artifactId>hugmesh-commons</artifactId>
  <!-- version managed by hugmesh-parent -->
</dependency>
```

Then delete the repo-local copies of the classes above and update the import
statements. The package root changes from the repo-specific prefix to
`net.hugmesh.commons.*`:

```
# Before (example from federation-api)
import net.hugmesh.federation.security.Roles;
import net.hugmesh.federation.security.DomainRegistry;

# After
import net.hugmesh.commons.security.Roles;
import net.hugmesh.commons.security.DomainRegistry;
```

**Method rename:** Two overloads of `Roles` that accepted `Set<String>` (raw authority
name strings rather than `GrantedAuthority` objects) were renamed to avoid an ambiguity
that the Java compiler cannot resolve at the call site when generics are erased:

| Old name (federation form) | New name |
|---|---|
| `Roles.isSuperadmin(Set<String>)` | `Roles.isSuperadminNames(Set<String>)` |
| `Roles.domainOf(Set<String>)` | `Roles.domainOfNames(Set<String>)` |

Calls that pass a `Collection<GrantedAuthority>` use the existing overloads unchanged.

## Shared test base (published test-jar)

Alongside the main jar, the `maven-jar-plugin` `test-jar` goal publishes
`net.hugmesh.commons.testsupport.PostgresTestSupport`
(`src/test/java/net/hugmesh/commons/testsupport/PostgresTestSupport.java`) as
`net.hugmesh:hugmesh-commons:2.1.0:tests` (test scope). Consumers extend it
to get ONE shared Testcontainers-Postgres base for the whole org instead of
re-copying the container/Liquibase/R2DBC wiring per repo:

```xml
<dependency>
  <groupId>net.hugmesh</groupId>
  <artifactId>hugmesh-commons</artifactId>
  <classifier>tests</classifier>
  <scope>test</scope>
  <!-- version managed by hugmesh-parent -->
</dependency>
```

```java
class MySliceTest extends PostgresTestSupport { /* ... */ }
```

Key properties: a single static Postgres container reused across the whole test JVM
(started once, not per-class), a fresh `cmtest_<n>` database created per test class so
Liquibase seeds never leak across classes, and an overridable `jsonTypeOverride()`
(defaults to `"text"`) for repos whose changelogs reference `${json.type}` against a
real `jsonb` column.

## Build / publish

| Goal | Command |
|---|---|
| Compile and run unit tests | `./mvnw verify` |
| Install to local Maven cache (`~/.m2`) for offline sibling-repo use | `./mvnw install` |
| Publish to GitLab Maven Package Registry (CI only) | `./mvnw deploy -s settings.xml` |

`./mvnw verify` also publishes the **test-jar** described in [Shared test base
(published test-jar)](#shared-test-base-published-test-jar) above, alongside the main
jar.

CI publishes the jar on the default branch and on version tags. The deploy step
authenticates using the GitLab-injected `CI_JOB_TOKEN` — no secret is committed to the
repository. HugMesh CI runs on GitLab; there are no GitHub Actions in this repo.

## Current State

- **At `2.1.0` on the unified ecosystem baseline** — Spring Boot 4.0.7 / Spring Cloud
  2025.1.2 on Java 25 LTS, Testcontainers 2.0.5, child of `hugmesh-parent:2.8.0`
  (`hugmesh-federation-api` is the migrated exemplar). The groupId is `net.hugmesh`,
  the reverse of `hugmesh.net`, for this artifact and its parent alike. The artifact's
  own `2.1.0` and the inherited `hugmesh-parent:2.8.0` are two different version
  numbers that are not expected to track each other — see
  [Coordinates](#coordinates) and `pom.xml`.
- **Bottom of the shared-artifact stack.** `hugmesh-auth-core` (the shared
  account / session / MFA / Casdoor-admin infrastructure) depends on this library;
  `hugmesh-auth-core` is in turn consumed by `hugmesh-user-bff-api` and
  `hugmesh-admin-bff-api`. All reactive BFFs depend on commons directly for the
  security / tenancy / config / web primitives above. The gateway takes a direct,
  explicitly-versioned dependency on commons too, but only to pin the Boot-4 /
  Security-7 binary-compat milestone — it deliberately keeps its own vendored
  `Roles` / `DomainRegistry` / `CasdoorAuthorities` / `TenancyResourceServerConfig`,
  since a class-by-class diff found the gateway's copies are supersets carrying
  methods this library lacks and the gateway depends on (e.g. `isGameMaster`, `usernameOf`,
  `namesOf`, `domainForHost`). The commons dependency makes the shared types
  available to the gateway for future use, not current use.
- **Auth-model alignment.** The current native-login design keeps the Casdoor JWT
  entirely server-side and Casdoor internal-only — it never redirects the browser.
  `login-ui` renders a first-party login form that POSTs credentials straight to
  `/bff/login` (via the gateway); `user-bff` runs the entire OIDC/PKCE handshake with
  Casdoor itself (generating the PKCE verifier/challenge and state, hitting Casdoor's
  internal `/api/login`, and exchanging the code for a JWT), then holds that JWT in
  server-side session storage. The browser never sees a Casdoor URL, authorization code,
  or JWT — it receives only an opaque `bff_`-prefixed session cookie. At the gateway, a
  pre-security exchange filter resolves the `bff_` cookie to the server-held Casdoor JWT, so
  JWT validation, role extraction, and domain resolution — implemented in the
  gateway's own vendored `Roles` / `DomainRegistry` / `CasdoorAuthorities` (see
  above) — run without modification.

  ```mermaid
  sequenceDiagram
      participant Browser
      participant login-ui
      participant gateway
      participant user-bff
      participant Casdoor

      Browser->>login-ui: fill native login form
      login-ui->>gateway: POST /bff/login (credentials)
      gateway->>user-bff: route to user-bff (permitAll)
      user-bff->>Casdoor: internal /api/login + PKCE code exchange
      Casdoor-->>user-bff: Casdoor JWT (held server-side)
      user-bff-->>Browser: Set-Cookie: bff_<opaque>
      Browser->>gateway: API request + bff_ cookie
      gateway->>user-bff: resolve bff_ → JWT
      user-bff-->>gateway: internal custody JWT
      gateway->>gateway: own (vendored) CasdoorAuthorities / Roles / DomainRegistry
      gateway-->>Browser: authorised response
  ```

  Login / session / account logic is being relocated from `admin-bff` to `user-bff`,
  with the shared core extracted to `hugmesh-auth-core`. This library is unchanged
  by that move — it remains the JWT→authorities and tenancy substrate underneath both.
- **MFA enforcement depends on `MFA_SATISFIED`.** Behaviour 7 — deriving `MFA_SATISFIED` from a
  fresh `mfa_satisfied_at` stamp written by the BFF, with the reserved-prefix guard
  blocking forgery — is how BFF-driven MFA challenges are enforced even when the
  gateway sees only an opaque `bff_` session. The authority ships disabled by default
  until MFA is enabled in the deployment.
- All eight preserved security behaviours remain covered by unit tests; the GitLab CI
  publish path to the Maven Package Registry is in place.

## Roadmap

This library underpins several in-flight and planned platform initiatives. New shared
primitives land here as they are generalised across services:

- **SSO end-to-end live + e2e** — the opaque `bff_` ↔ server-held-JWT bridge has been
  verified through the gateway resource server against its own vendored
  `CasdoorAuthorities` / `DomainRegistry` path (see [Current
  State](#current-state) for why the gateway keeps vendored copies rather than
  depending on this library's). Full end-to-end test coverage is in progress.
- **MFA** (WebAuthn + TOTP + recovery, per-role defaults, step-up) — builds directly
  on the `MFA_SATISFIED` stamp derivation (behaviour 7) and the reserved-prefix guard
  already present in this library.
- **Multi-tenancy / multi-brand superadmin** — per-domain CA with per-brand
  gateway / BFF / UI instances. This exercises the opt-in multi-issuer path
  (`TenancyResourceServerConfig`) and the fail-closed domain resolution already
  implemented here.
- **Downstream platform work** that consumes these primitives without requiring changes
  to them: data-driven gateway route authorisation (`gateway_route_access`), encrypted
  versioned backups, egress VPN drop-in, per-node attached storage, desktop app
  governance, workload console, device-license registry, games app-store, audio/video
  relay via coturn/TURN, and OWASP pen-test + nuclei integration in CI.
