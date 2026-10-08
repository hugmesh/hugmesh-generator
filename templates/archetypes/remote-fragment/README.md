# remote-fragment archetype

Renders the HugMesh **remote-fragment** class: the runtime federation-bundle
delivery pod (a Spring-Native sync sidecar plus static nginx). It pulls PUBLISHED
remote bundles from federation-api and serves them, so a tenant can mount remotes
it does not build. The only member is `hugmesh-remote-fragment`.

It used to sit under `gateway`. It has its own archetype because its `deploy/**` is
BASE-OWNED (the gateway class owns its deploy overlay as class-A files) and its
brand surface is a single CI anchor.

## What is / isn't templated

- **Class-B anchored edit (`recipe.yaml`):** only `.gitlab-ci.yml`
  `include: project:` org/group (`GENERATOR_ORG_GROUP`). It is the ONE in-source
  brand token.
- **NO class-A files, on purpose:** the base owns `deploy/**` (deployment / hpa /
  pdb / kustomization / nginx.conf) and every other path. A whole-file overlay at a
  base-owned path would have to render byte-identical forever, a standing drift trap
  for zero brand value.
- **Left literal / env-driven:** the sync loop, the Casdoor client-credentials
  machinery, nginx serving, and every runtime seam (manifest URL, token endpoint,
  cadence). The base's application.yml already drives these from `${ENV}`, and
  deploy env sets them; none is a source literal. The Casdoor `client_secret` stays
  in the fragment-sync-casdoor Secret (ESO -> Vault), never in git.

## Per-repo identity (repos[].identity)

None. The class has no per-repo render tokens.

## Base resolution

`repos[].name: remote-fragment` resolves the base as `hugmesh-remote-fragment`
(the default `hugmesh-<name>` rule in `pull-repo-base.sh`). Point
`REMOTE_FRAGMENT_BASE_DIR` at a present clone for offline renders and validation.
There is NO runnable skeleton: `_skeleton/` is a pointer README. The real base repo
IS the example codebase, and a minimal fake sync sidecar would not work. A render
with no base emits the pointer instead.

See docs/FEDERATION-EXAMPLES.md, section 1 ("The example trio (+ remote-fragment)"),
for the end-to-end flow.
