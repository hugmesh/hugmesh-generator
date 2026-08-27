# HugMesh tenant branding — what a tenant's generator copy rebrands (and what it never touches)

This file documents the branding surface of a TENANT'S copy of the generator —
the repo the mesh templating pipeline publishes to the tenant forge as
`<org-slug>/hugmesh-generator` (the project the `GENERATOR_ORG_GROUP`
CI-include and the 13d brand-repo ApplicationSet have always pointed at).

It is also the pipeline's **renames[] pilot**: when the `generator` archetype
renders a tenant copy, this very file is re-filed as
`docs/BRANDING-<org-slug>.md`, so each org's copy carries a distinctly-named
branding doc. It is a deliberately safe, **non-contract** file — the rename
engine (scripts/tooling/render-recipe.js) refuses to rename the contract set
(`hugmesh-deploy.yaml`, `.hugmesh-provenance.json`, `.hugmesh-mesh-admitted`,
their marker siblings, **and** the LEGACY_COMPAT pre-rebrand spellings of all
three — still live on adopter repos' and other meshes' disks, see
`specs/cluster/catalog/adopters.yaml`) outright.

## Rebranded in a tenant copy (the whole list)

| Surface | Token | Where |
|---|---|---|
| README display brand ("for the … cluster") | `{{BRAND_TITLE}}` | `README.md` |
| CI pentest-stage include org/group | `{{GENERATOR_ORG_GROUP}}` | `.gitlab-ci.yml` |
| This doc's display brand + filename | `{{BRAND_TITLE}}` / `{{ORG_SLUG}}` | `docs/BRANDING.md` → `docs/BRANDING-<org-slug>.md` |

## Never rebranded (upstream code / protocol identity)

* the repo name `hugmesh-generator` and every `hugmesh` in
  `scripts/**`, `specs/**`, builder entrypoints — code identity;
* `hugmesh.net/*` label KEYS, the `platform.hugmesh.net` CRD API group
  (compiled into `hugmesh-admin-bff-api`'s Fabric8 client), `X-HugMesh-Local`
  and the other wire headers, the `hugmesh.device-terminal.stepup.`
  subprotocol prefix — FROZEN protocol constants (`scripts/tooling/tokens.json`
  `frozen_protocol_constants`), enforced fail-closed at render, and protected
  behind sentinels by every builder's `rebrand_sysroot()` in the baked device
  tree (label keys in every structural-boundary shape incl. `KEY=hugmesh.net/…`
  and the escaped-dot jsonpath spelling; the API group in every spelling).
  `<sub>.hugmesh.net` as a HOST is not frozen — it rebrands to
  `<sub>.<CLUSTER_DOMAIN>`;
* …and their RETIRED pre-rebrand spellings are BANNED, not merely un-frozen:
  `scripts/tooling/tokens.json` `retired_protocol_constants` names them, and
  `token-classifier.isFrozen()` refuses them at emit exactly like the live ones,
  so the templating path can never re-introduce a dead protocol token. That
  block and the drift guards are the only places in the tree licensed to spell
  them out — a ban rule has to name what it bans;
* `Makefile`, `tests/stack/compose.local.yaml` and the rest of the local-stack
  machinery — a tenant copy must keep `make stack-up` (building the local mesh)
  working byte-for-byte;
* `brands/` example profiles — a tenant seeds their OWN
  `brands/<their-brand>.yaml` in their copy; the pipeline never pre-writes one
  (a half-filled profile would immediately drift against the operator's
  authoritative profile and ff-refuse the next re-render).
