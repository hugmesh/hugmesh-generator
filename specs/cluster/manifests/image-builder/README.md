# image-builder — generic in-cluster Kaniko app-image build pipeline (OPT-IN)

Before this directory, the `.gitlab-ci.yml` `build:images` job was an **echo stub**
(`echo "build + push container images to ${CI_REGISTRY_IMAGE}"`) and **no in-cluster build
path existed** — first-party app images (gateway, frontends, BFFs, games, …) built only in
the GitLab org mirror. This directory is that missing in-cluster path: a **reusable, generic**
rootless-Kaniko build pipeline that builds an app image from its repo and pushes it to the
in-cluster Harbor registry (`registry.hugmesh.net`; see `../../apps/03a-harbor.yaml` —
GitLab's own bundled registry no longer serves this hostname).

It is **modeled 1:1 on the proven [#110](../service-catalog-builder/) Service-Catalog Kaniko
builder** — same rootless `gcr.io/kaniko-project/executor` floor, same security posture, same
`dockerconfigjson` push-secret contract — but **generalized** to build any app repo's
Dockerfile rather than only Service-Catalog DOCKERFILE/ZIP sources.

## What ships here

- **`kaniko-build-job.template.yaml`** — a per-build **rootless** Kaniko `Job` TEMPLATE. A
  driver renders ONE copy per build (binding `${BUILD_NAME}` / `${BUILD_NAMESPACE}` /
  `${CONTEXT}` / `${DOCKERFILE}` / `${DEST_IMAGE}` / `${DEST_IMAGE_MOVING}`) and creates it in
  the build namespace. Kaniko builds the Dockerfile in userspace (no Docker daemon, no
  privileged socket) and pushes the image to `registry.hugmesh.net`. Security posture
  matches the platform build Jobs: `runAsNonRoot`, drop `ALL` caps, `seccompProfile: RuntimeDefault`,
  `readOnlyRootFilesystem` (Kaniko workdir on `emptyDir`), `automountServiceAccountToken:false`,
  `ttlSecondsAfterFinished` + `activeDeadlineSeconds` reaping. A dedicated MCS level
  (`s0:c75`, distinct from #110's `s0:c54`) keeps build pods off the runtime-app bands.

  **Tag scheme (immutable + moving), pushed from ONE build.** The template carries TWO
  `--destination` flags so a single Kaniko build pushes both, guaranteeing byte-identical
  layers behind each tag — mirroring the canonical sibling `build:image`
  (hugmesh-gateway / hugmesh-forum-bff-api `docker push :$TAG` + `:$CI_COMMIT_REF_SLUG`):
  - `${DEST_IMAGE}` — the **immutable** ref: a release tag on a tag pipeline, else the short
    SHA (`…/<app>:<release-tag-or-sha>`). Never moves.
  - `${DEST_IMAGE_MOVING}` — the **moving** dev ref the app kustomizations track via
    `newTag: main` (`…/<app>:<ref-slug>`; the default branch resolves to `:main`). Re-pointed
    each build. A driver wanting only the immutable tag binds both to the same value (Kaniko
    de-dups identical destinations).

- **`namespace-and-netpol.yaml`** — the `hugmesh-image-builds` namespace + a default-deny
  ingress NetworkPolicy (build pods serve nothing; egress to the registry + DNS + the source
  git remote is left open like the other tier policies). ArgoCD-managed (listed in
  `kustomization.yaml`).

## Drivers (how a build is dispatched)

The Job template is parameterized so it can be instantiated by any of:

1. **`.gitlab-ci.yml` `build:images`** — the stub is replaced by a documented dispatch that
   renders the template (substituting the build context / dest image) and `kubectl apply`s it
   into `hugmesh-image-builds` on the in-cluster runner. This is the in-cluster build path.
2. **ArgoCD** — render the Job into a Sync/PostSync hook Application.
3. **Argo-Workflows** — a `WorkflowTemplate` step, *if/when* the Workflows controller is
   installed (it is not present today; the proven #110 pattern is plain `batch/v1` Jobs, which
   this mirrors).

## ALWAYS-ON — and what that does (and does not) start

- **Always synced:** the ArgoCD `Application` (`../../apps/60-image-builder.yaml`) lives in
  `specs/cluster/apps/`, which the root app-of-apps recurses (`directory.recurse: true`), so
  ArgoCD reconciles it continuously. This replaces the previous opt-in posture, where the file
  was parked in a sibling `specs/cluster/apps-optional/` directory that no root recursed.
- **What it creates:** the `hugmesh-image-builds` namespace (PSS `restricted`) and its
  default-deny-ingress NetworkPolicy. That is the complete set.
- **Still ships dark:** the Kaniko Job is a TEMPLATE and is deliberately **not** in
  `kustomization.yaml`, so ArgoCD never applies it — exactly like #110. **No build pod runs
  until a driver dispatches one**; the namespace and policy are inert on their own.
- **Downstream effect:** the `image-builder-registry` ExternalSecret targets this namespace, so
  it stops being inert the moment the namespace exists — Vault `secret/<brand>/harbor-robots`
  must carry `push_name`/`push_secret` or ESO will report a sync error against it.

Covered by the `lint:image-builder-always-on` CI gate
(`../../../../tests/scripts/test-image-builder-always-on.sh`).

Registry push creds (`image-builder-registry`, a `dockerconfigjson` with **push** scope for
`registry.hugmesh.net`) are **ESO-materialized** into the build namespace — **never in
git** — by the `image-builder-registry` ExternalSecret
(`../external-secrets/image-builder-externalsecrets.yaml`, wired into the ESO kustomization).
It sources Vault `secret/<brand>/harbor-robots` (`push_name`/`push_secret`) — Harbor's
project-scoped PUSH robot account, minted automatically by the `harbor-provision` PostSync Job
(`../harbor/harbor-provision-job.yaml`; Harbor reveals a robot's secret exactly once, so that
Job captures and writes it to Vault the moment it's created — and **owns** that path in
consequence: `scripts/gen-cluster-secrets.sh` does not write `harbor-robots` at all by default,
because a `vault kv put` REPLACES the whole KV-v2 document and the Job's skip is keyed on
Harbor state, so a clobber can never be repaired). `scripts/gen-cluster-secrets.sh`'s
`IMAGE_BUILDER_REGISTRY_TOKEN` remains only as a manual-override escape hatch for local/offline
testing, and now `kv patch`es in only `push_name`/`push_secret`, leaving the pull robot's keys
alone (`../../../../tests/scripts/test-harbor-robots-ownership.sh` executes both writers and
asserts exactly that). It is DELIBERATELY distinct from the runtime `harbor-registry` **pull**-scoped robot
imagePullSecret (formerly `gitlab-registry`) so the runtime pull credential can never push.
Same Vault source and auth shape as `service-catalog-registry-credentials` (which carries it as an Opaque `config.json`; this one stays a dockerconfigjson).

## Live validation pending

A real build **cannot be live-validated yet**: the x86 kernel netfilter gap currently blocks
bringing up a cluster. These manifests are authored **correct-by-construction** against the
#110 Kaniko contract and validated with `kubectl kustomize` / yaml parse. Live validation is
deferred to a kernel-fixed x86 image.
