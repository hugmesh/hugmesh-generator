# gateway archetype

Renders the HugMesh **gateway / infra** class (gateway and actions). The Java
source holds almost no brand tokens, so this archetype templates the CI include
(recipe) plus a NEW brand-parameterized **deploy overlay** (class-A `deploy/*.hbs`,
kustomize-buildable). It does not template Java.

## What is / isn't templated

- **Source (`recipe.yaml`):** only the `.gitlab-ci.yml` `include: project:` org/group.
- **Deploy env (class-A `deploy/*.hbs` -> kustomize):** `CASDOOR_ISSUER_URI` and
  `CASDOOR_JWKS_URI` (`id.<CLUSTER_DOMAIN>`), `APP_TENANCY_ISSUERS`,
  `APP_TENANCY_HOSTS`, and the Ingress `host` (`CLUSTER_DOMAIN`).
- **Left literal:** `SPRING_APPLICATION_NAME hugmesh-<PROFILE>-gateway` (profile and
  code identity, carried per repo by the `profile` identity token), the `Path=/api/**`
  route seed, all Java, and `groupId net.hugmesh`.

## Per-repo identity (repos[].identity)

- `profile` — `be | fe | pki`. It seeds `SPRING_APPLICATION_NAME` and the resource
  names in the deploy overlay.

Validate the emitted deploy overlay with `kubectl kustomize <out>/deploy`.
