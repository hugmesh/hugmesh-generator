# HugMesh tenant branding — what a tenant's generator copy rebrands (and what it never touches)

This file documents the branding surface of a tenant's copy of the generator: the
repo the mesh templating pipeline publishes to the tenant forge as
`<org-slug>/hugmesh-generator`. That is the project the `GENERATOR_ORG_GROUP`
CI-include and the 13d brand-repo ApplicationSet have always pointed at.

It is also the pipeline's `renames[]` pilot. When the `generator` archetype renders
a tenant copy, this file is re-filed as `docs/BRANDING-<org-slug>.md`, so each org's
copy carries a distinctly named branding doc. It is a deliberately safe, non-contract
file. The rename engine (scripts/tooling/render-recipe.js) refuses to rename the
contract set outright: `hugmesh-deploy.yaml`, `.hugmesh-provenance.json`,
`.hugmesh-mesh-admitted` and their marker siblings. Every adopter in
`specs/cluster/catalog/adopters.yaml` ships the one live descriptor spelling.

## Rebranded in a tenant copy (the whole list)

| Surface | Token | Where |
|---|---|---|
| README display brand ("for the … cluster") | `{{BRAND_TITLE}}` | `README.md` |
| CI include org/group (a no-op today: the generator's own `.gitlab-ci.yml` includes nothing from `hugmesh/hugmesh-generator`, and the recipe anchor tolerates that) | `{{GENERATOR_ORG_GROUP}}` | `.gitlab-ci.yml` |
| This doc's display brand + filename | `{{BRAND_TITLE}}` / `{{ORG_SLUG}}` | `docs/BRANDING.md` → `docs/BRANDING-<org-slug>.md` |

## Never rebranded (upstream code / protocol identity)

* The repo name `hugmesh-generator` and every `hugmesh` in `scripts/**`, `specs/**`
  and the builder entrypoints. This is code identity.
* `hugmesh.net/*` label keys, the `platform.hugmesh.net` CRD API group (compiled
  into `hugmesh-admin-bff-api`'s Fabric8 client), `X-HugMesh-Local` and the other
  wire headers, and the `hugmesh.device-terminal.stepup.` subprotocol prefix. These
  are frozen protocol constants (`scripts/tooling/tokens.json`
  `frozen_protocol_constants`). The renderer enforces them fail-closed, and every
  builder's `rebrand_sysroot()` protects them behind sentinels in the baked device
  tree: label keys in every structural-boundary shape, including `KEY=hugmesh.net/…`
  and the escaped-dot jsonpath spelling, and the API group in every spelling.
  `<sub>.hugmesh.net` as a host is not frozen; it rebrands to
  `<sub>.<CLUSTER_DOMAIN>`.
* The retired pre-rebrand spellings of those constants are gone from the tree
  entirely. The pre-rebrand brand may not appear anywhere in a hugmesh repository,
  and `studio/tests/test_org_export_neutrality.py` fails if it comes back in any
  tracked file. The guard spells the token from parts, so it never names it whole.
* `Makefile`, `tests/stack/compose.local.yaml` and the rest of the local-stack
  machinery. A tenant copy must keep `make stack-up` (building the local mesh)
  working byte for byte.
* `brands/` example profiles. A tenant seeds their own `brands/<their-brand>.yaml`
  in their copy; the pipeline never pre-writes one. A half-filled profile would drift
  at once against the operator's authoritative profile and make the next re-render
  fast-forward-refuse.
