# gateway archetype

Renders the HugMesh **gateway / infra** class (gateway / actions /
remote-fragment). The Java source is near-zero-token, so this archetype templates
the CI include (recipe) + a NEW brand-parameterized **deploy overlay** (class-A
`deploy/*.hbs`, kustomize-buildable), NOT Java.

## What is / isn't templated

- **Source (`recipe.yaml`):** only `.gitlab-ci.yml` `include: project:` org/group.
- **Deploy env (class-A `deploy/*.hbs` -> kustomize):** `CASDOOR_ISSUER_URI` /
  `CASDOOR_JWKS_URI` (`id.<CLUSTER_DOMAIN>`), `APP_TENANCY_ISSUERS`,
  `APP_TENANCY_HOSTS`, and the Ingress `host` (`CLUSTER_DOMAIN`).
- **Left literal:** `SPRING_APPLICATION_NAME hugmesh-<PROFILE>-gateway`
  (profile/code identity — carried per-repo via the `profile` identity token),
  `Path=/api/**` route seed, all Java, `groupId net.hugmesh`.

## Per-repo identity (repos[].identity)

- `profile` — `be | fe | pki`; seeds `SPRING_APPLICATION_NAME` +
  resource names in the deploy overlay.

Validate the emitted deploy overlay with `kubectl kustomize <out>/deploy`.
