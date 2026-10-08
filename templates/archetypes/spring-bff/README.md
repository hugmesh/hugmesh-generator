# spring-bff archetype

Renders any HugMesh **Spring Boot 4 / Java BFF** from ONE recipe, parameterized
by the per-repo `repos[].identity` row in the structured brand YAML. It was seeded
from the Phase-3 `admin-bff-api` exemplar and proven on `user-bff-api` with only
manifest identity (no new hand overlay).

Class members (the Spring-BFF block in `brands/acme.yaml`): admin / user / mod /
forum / owncast / tube / wiki-bff-api + federation-api.

## What is / isn't templated

- **Templated (brand delta, `recipe.yaml` anchored edits on the base's OWN file):**
  - `application.yml`: the OIDC issuer/JWKS host (`id.<CLUSTER_DOMAIN>`), the OIDC
    redirect host, the MFA TOTP issuer (`BRAND_TITLE`), the admin-emails host, and
    the appstore registry host. All are env-DEFAULT seams, and each anchor matches
    only if present across the class union.
  - `.gitlab-ci.yml`: only the `include: project:` org/group (`GENERATOR_ORG_GROUP`).
- **Left literal (per-repo CODE identity, NOT brand):** `spring.application.name`,
  the pom `artifactId`, springdoc `packages-to-scan`, the Casdoor OIDC application
  id, and `groupId net.hugmesh`. These make each BFF itself; rebranding them would
  emit user-bff misconfigured as admin.

## Files

- `recipe.yaml` — the anchored edits (find = upstream literal, replace = branded).
- `_identity.env` — drift oracle (exemplar admin-bff-api upstream values).
- `_skeleton/` — a RUNNABLE minimal example BFF: Spring Boot 4 WebFlux on
  `hugmesh-parent`, with a hello endpoint, a SecurityConfig that permits health and
  authenticates everything else, `${ENV:default}` config, WebTestClient tests, a
  Dockerfile, CI, and deploy. `mvn package` in a rendered tree is green. The
  base-absent fallback is a real example codebase, not a placeholder.
  - KNOWN DRIFT: the skeleton `pom.xml` names its parent
    `systems.hugmesh:hugmesh-parent`, but the published parent is
    `net.hugmesh:hugmesh-parent` (2.8.0), which the BFF repos use. The skeleton's
    Java package, `systems.hugmesh.<slug>`, predates that move too.
  - SKELETON-ONLY CONSTRAINT: the identity `app_slug` must match `[a-z0-9]+`. It
    becomes the Java package segment `systems.hugmesh.<slug>`, and packages cannot
    carry `-`. See `_skeleton/README.md.hbs` and the recipe header comment.
