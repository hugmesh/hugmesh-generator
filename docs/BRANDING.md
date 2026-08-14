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
(`snapdragon-deploy.yaml` **and** `hugmesh-deploy.yaml` — both descriptor
spellings are live in the org, see `specs/cluster/catalog/adopters.yaml` —
`.snapdragon-provenance.json`, `.snapdragon-mesh-admitted`, and their marker
siblings) outright.

## Rebranded in a tenant copy (the whole list)

| Surface | Token | Where |
|---|---|---|
| README display brand ("for the … cluster") | `{{BRAND_TITLE}}` | `README.md` |
| CI pentest-stage include org/group | `{{GENERATOR_ORG_GROUP}}` | `.gitlab-ci.yml` |
| This doc's display brand + filename | `{{BRAND_TITLE}}` / `{{ORG_SLUG}}` | `docs/BRANDING.md` → `docs/BRANDING-<org-slug>.md` |

## Never rebranded (upstream code / protocol identity)

* the repo name `hugmesh-generator` and every `hugmesh` in
  `scripts/**`, `specs/**`, builder entrypoints — code identity;
* `hugmesh.net/*` label KEYS, `X-HugMesh-Local` and the other wire
  headers, the step-up subprotocol prefix — FROZEN protocol constants
  (`scripts/tooling/tokens.json`), enforced fail-closed at render;
* `Makefile`, `tests/stack/compose.local.yaml` and the rest of the local-stack
  machinery — a tenant copy must keep `make stack-up` (building the local mesh)
  working byte-for-byte;
* `brands/` example profiles — a tenant seeds their OWN
  `brands/<their-brand>.yaml` in their copy; the pipeline never pre-writes one
  (a half-filled profile would immediately drift against the operator's
  authoritative profile and ff-refuse the next re-render).
