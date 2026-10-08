# remote-fragment archetype

Renders the HugMesh **remote-fragment** class: the runtime federation-bundle
delivery pod (Spring-Native sync sidecar + static nginx) that pulls PUBLISHED
remote bundles from federation-api and serves them so a tenant can mount remotes
it does not build. Exemplar (and only) member = `hugmesh-remote-fragment`.
Previously bucketed under `gateway`; split out because its deploy/** is
BASE-OWNED (unlike the gateway class, whose deploy overlay is archetype
class-A) and its brand surface is a single CI anchor.

## What is / isn't templated

- **Class-B anchored edit (`recipe.yaml`):** only `.gitlab-ci.yml`
  `include: project:` org/group (`GENERATOR_ORG_GROUP`) — the ONE in-source
  brand token.
- **NO class-A files, deliberately:** the base owns `deploy/**` (deployment /
  hpa / pdb / kustomization / nginx.conf) and every other path. An archetype
  whole-file at a base-owned path would have to render byte-identical forever
  (a standing drift trap) for zero brand value.
- **Left literal / env-driven:** the sync loop, Casdoor client-credentials
  machinery, nginx serving, and every runtime seam (manifest URL, token
  endpoint, cadence) — already `${ENV}`-driven in the base's application.yml
  and set by deploy env, never source literals. The Casdoor `client_secret`
  stays in the fragment-sync-casdoor Secret (ESO -> Vault), never in git.

## Per-repo identity (repos[].identity)

None — the class has no per-repo render tokens.

## Base resolution

`repos[].name: remote-fragment` resolves the base as
`hugmesh-remote-fragment` (pull-repo-base.sh's default `hugmesh-<name>` rule);
point `REMOTE_FRAGMENT_BASE_DIR` at a present clone for offline renders/validate.
There is NO runnable skeleton (`_skeleton/` is a pointer README): the real base
repo IS the example codebase — a minimal fake sync-sidecar would be a
non-functional lie, so a base-absent render emits the pointer instead.

See docs/FEDERATION-EXAMPLES.md, section 1 ("The example trio (+ remote-fragment)"),
for the end-to-end flow.
