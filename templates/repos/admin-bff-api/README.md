# admin-bff-api Tier-1 overlay (mesh repo-templating, Phase 3 — the hard Spring-BFF archetype)

**Overlay-primary, base REQUIRED. Fork-and-tokenize is BANNED.** This directory is
the *thin brand delta* for `snapdragon-admin-bff-api` — a compiled Spring BFF. It
contains ONLY the brand-coupled source files, never the whole repo. The fuller
running code (the Tier-2 base) is pulled **READ-ONLY** and never copied/vendored/
committed into the generator.

Unlike the login-ui pilot (a static bundle with a faithful minimal skeleton), a
compiled Spring BFF has **no buildable minimal boot**, so `_skeleton/` is a
degraded, non-buildable placeholder only: **admin-bff-api is effectively
overlay-only and the read-only Tier-2 base is REQUIRED** for a real emit.

## The brand-coupled files (Tier-1)

### Handlebars source overlays (`scripts/render-repo-tree.sh`)

| Overlay template | Base file | Token(s) | What it rebrands |
|---|---|---|---|
| `src/main/resources/application.yml.hbs` | `src/main/resources/application.yml` | `{{CLUSTER_DOMAIN}}`, `{{BRAND_TITLE}}` | ONLY the brand-coupled env-DEFAULTs (the value *after* the `:` inside `${ENV:default}`): issuer-uri, jwk-set-uri (nested issuer), `app.admin-emails`, `app.appstore.builder.registry` → `id./registry./admin@{{CLUSTER_DOMAIN}}`; `app.mfa.totp.issuer` → `{{BRAND_TITLE}}` (the otpauth/authenticator display brand). The `${ENV}` shell + all keys/comments stay byte-identical. |
| `.gitlab-ci.yml.hbs` | `.gitlab-ci.yml` | `{{GENERATOR_ORG_GROUP}}` | the CI `include:` project org/group. |

### Kustomize deploy surface — NOT here (deploy-source decision)

The deploy manifests are **NOT** part of this Handlebars overlay. The CANONICAL
deploy source is `specs/cluster/manifests/admin-bff-api/*` — the tree ArgoCD app
`specs/cluster/apps/31-admin-bff-api.yaml` points its `path:` at and
**kustomize-builds RAW at sync**. Because ArgoCD builds it raw, those manifests
are kept **literal + raw-kustomize-buildable** and are deliberately **not**
`{{token}}`-templated: per-tenant brand substitution of this tree is the EXISTING
`build-x86-host-stage4.sh` **`rebrand_sysroot`** ISO-build sed pass
(`snapdragon.systems`→CLUSTER_DOMAIN, `snapdragon-`→BRAND-, `snapdragon-systems/`→
org/, `"Snapdragon Systems"`→BRAND_TITLE). That pass already rebrands the image
registry host, the repo name, the resource/namespace names, and the effective
brand env below. Putting `{{tokens}}` in these manifests would **break the raw
ArgoCD kustomize sync** (YAML flow-map parse error) and double-brand — so the
app-repo Handlebars overlay stays limited to source files.

This overlay's deploy contribution is the effective in-cluster brand ENV added to
`specs/cluster/manifests/admin-bff-api/deployment.yaml` (literal, rebrandable):
`APP_MFA_WEBAUTHN_RP_ID`/`APP_MFA_WEBAUTHN_ORIGINS` (previously ABSENT — a latent
bug where in-cluster WebAuthn fell back to the app.yml `localhost` default),
`ADMIN_EMAILS`, `APPSTORE_BUILDER_REGISTRY`.

> **Known gap (reported):** the standalone Harbor **project** segment `/snapdragon/`
> in the image newName matches no `rebrand_sysroot` rule (neither
> `snapdragon.systems` nor `snapdragon-…`), so it does not rebrand to the tenant
> Harbor project. A `rebrand_sysroot` rule (or a first-class `HARBOR_PROJECT`
> deploy seam) is owed.

## Deliberately LEFT UNTEMPLATED (grounding)

* **Frozen protocol label KEYS** — `snapdragon.systems/build-node`,
  `snapdragon.systems/domain`, `snapdragon.systems/backend` and the whole
  `snapdragon.systems/` label-key namespace. These are compiled-in k8s label keys
  (e.g. `Fabric8PlatformCapabilityProbe.BUILD_NODE_LABEL`); relabelling would need
  per-tenant recompiles. A brand profile that tries to override one is BLOCKED at
  emit (frozen-protocol guard in the token classifier).
* **`app.kubernetes.io/part-of: snapdragon.systems`** — a grouping/selector VALUE,
  not brand.
* **Wire headers** `X-Snapdragon-Local`, `X-Internal-Token`,
  `X-Device-Terminal-StepUp`, the `snapdragon.device-terminal.stepup.`
  Sec-WebSocket-Protocol subprotocol prefix — protocol identity.
* **Java coordinates** `groupId systems.snapdragon`, `artifactId admin-bff`,
  parent `snapdragon-parent`, `spring.application.name: snapdragon-admin-bff-api`,
  `springdoc.packages-to-scan: systems.snapdragon.adminbff`, the Kafka
  `group-id snapdragon-admin-bff-api-usage` — CODE IDENTITY, not tenant brand.
* **Internal `*.svc.cluster.local` service DNS + `snapdragon-backend` namespace
  defaults** — platform topology, deploy-overridden, not tenant brand.
* **WebAuthn `rp-id`/`origins` app.yml DEFAULTS** — these are `localhost`/
  `https://localhost` (dev-safe), NOT the brand value. The brand WebAuthn value
  (`admin.<domain>`) lives ONLY in the generator Deployment env, never in app.yml.
* **k8s resource names, mTLS secret `snapdragon-admin-bff-api-mtls`, the ESO
  secret names** (`route-access-admin-bff` / `admin-bff-db-auth` /
  `admin-bff-db-app-auth`), the `backups-effector` ServiceAccount — frozen
  resource identity (per-tenant isolation is by namespace, not by name).
* every other `snapdragon` in `src/**/*.java`, comments, imports — upstream code
  identity, not tenant brand. Tier-1 is deliberately surgical (the ~5 app.yml
  default lines + 1 CI line only).

## Secret split (the point of this archetype)

Every secret-bearing field (`SVC_PASSWORD`, `SPRING_R2DBC_PASSWORD`,
`CASDOOR_ADMIN_CLIENT_SECRET`, `INTERNAL_TOKEN`, `APP_MFA_FACTOR_KEY`,
`APP_REGISTRY_SIGNING_KEY*`, the Cassandra/SSL store passwords,
`APPSTORE_ARGOCD_AUTH_TOKEN`, `CLICKHOUSE_PASSWORD`, …) is emitted ONLY as an
`${ENV}`/ESO placeholder, NEVER a literal. The token-classifier denylist blocks
any of these reaching a rendered file, and `scripts/secret-scan.sh` is the
fail-closed emit-time backstop.

## Rendering

Rendered by `render_repo_tree()` (`scripts/render-repo-tree.sh`) which pulls the
read-only base, overlays these files via the **Phase-1 real-Handlebars path**
(`scripts/tooling/render-handlebars.js`, `--extra-tokens`), and runs the Phase-1
emit-time secret scanner over the result. `_identity.env` is the drift oracle for
`scripts/validate-repo-templates.sh`.

> **Node-not-root constraint:** the Handlebars renderer needs Node and is
> **BUILD-HOST ONLY**. It must NEVER run as root on the mesh-node fail-closed
> root-cron path (Phase 6). See `docs/MESH-TEMPLATING.md`.
