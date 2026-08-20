# spring-bff archetype

Renders any HugMesh **Spring Boot 4 / Java BFF** from ONE recipe, parameterized
by the per-repo `repos[].identity` row in the structured brand YAML. Seeded from
the Phase-3 `admin-bff-api` exemplar; proven on `user-bff-api` with only manifest
identity (no new hand overlay).

Class members (see phase4-repo-archetypes.md): admin / user / mod / forum /
owncast / tube / wiki-bff-api + federation-api.

## What is / isn't templated

- **Templated (brand delta, `recipe.yaml` anchored edits on the base's OWN file):**
  - `application.yml`: OIDC issuer/JWKS host (`id.<CLUSTER_DOMAIN>`), OIDC redirect
    host, MFA TOTP issuer (`BRAND_TITLE`), admin-emails host, appstore registry host
    — all env-DEFAULT seams, presence-tolerant over the class union.
  - `.gitlab-ci.yml`: only the `include: project:` org/group (`GENERATOR_ORG_GROUP`).
- **Left literal (per-repo CODE identity, NOT brand):** `spring.application.name`,
  pom `artifactId`, springdoc `packages-to-scan`, Casdoor OIDC application id,
  `groupId systems.hugmesh`. These make each BFF itself; rebranding them would
  emit user-bff misconfigured as admin.

## Files

- `recipe.yaml` — the anchored edits (find = upstream literal, replace = branded).
- `_identity.env` — drift oracle (exemplar admin-bff-api upstream values).
- `_skeleton/` — a RUNNABLE minimal example BFF (Spring Boot 4 WebFlux on
  `hugmesh-parent`: hello endpoint, permitAll-health/authenticated-elsewhere
  SecurityConfig, `${ENV:default}` config, WebTestClient tests, Dockerfile, CI,
  deploy). `mvn package` in a rendered tree is green — the base-absent fallback
  is now a real example codebase, not a placeholder. SKELETON-ONLY CONSTRAINT:
  the identity `app_slug` must match `[a-z0-9]+` (it becomes the Java package
  segment `systems.hugmesh.<slug>`; packages cannot carry `-`). See
  `_skeleton/README.md.hbs` + the recipe header comment.
