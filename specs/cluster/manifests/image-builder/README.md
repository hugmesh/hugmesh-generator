# image-builder — generic in-cluster Kaniko app-image build pipeline (OPT-IN)

Before this directory, the `.gitlab-ci.yml` `build:images` job was an **echo stub**
(`echo "build + push container images to ${CI_REGISTRY_IMAGE}"`) and **no in-cluster build
path existed** — first-party app images (gateway, frontends, BFFs, games, …) built only in
the GitLab org mirror. This directory is that missing in-cluster path: a **reusable, generic**
rootless-Kaniko build pipeline that builds an app image from its repo and pushes it to the
in-cluster GitLab registry (`registry.snapdragon.systems`).

It is **modeled 1:1 on the proven [#110](../service-catalog-builder/) Service-Catalog Kaniko
builder** — same rootless `gcr.io/kaniko-project/executor` floor, same security posture, same
`dockerconfigjson` push-secret contract — but **generalized** to build any app repo's
Dockerfile rather than only Service-Catalog DOCKERFILE/ZIP sources.

## What ships here

- **`kaniko-build-job.template.yaml`** — a per-build **rootless** Kaniko `Job` TEMPLATE. A
  driver renders ONE copy per build (binding `${BUILD_NAME}` / `${BUILD_NAMESPACE}` /
  `${CONTEXT}` / `${DOCKERFILE}` / `${DEST_IMAGE}` / `${DEST_IMAGE_MOVING}`) and creates it in
  the build namespace. Kaniko builds the Dockerfile in userspace (no Docker daemon, no
  privileged socket) and pushes the image to `registry.snapdragon.systems`. Security posture
  matches the platform build Jobs: `runAsNonRoot`, drop `ALL` caps, `seccompProfile: RuntimeDefault`,
  `readOnlyRootFilesystem` (Kaniko workdir on `emptyDir`), `automountServiceAccountToken:false`,
  `ttlSecondsAfterFinished` + `activeDeadlineSeconds` reaping. A dedicated MCS level
  (`s0:c55`, distinct from #110's `s0:c54`) keeps build pods off the runtime-app bands.

  **Tag scheme (immutable + moving), pushed from ONE build.** The template carries TWO
  `--destination` flags so a single Kaniko build pushes both, guaranteeing byte-identical
  layers behind each tag — mirroring the canonical sibling `build:image`
  (snapdragon-gateway / snapdragon-forum-bff-api `docker push :$TAG` + `:$CI_COMMIT_REF_SLUG`):
  - `${DEST_IMAGE}` — the **immutable** ref: a release tag on a tag pipeline, else the short
    SHA (`…/<app>:<release-tag-or-sha>`). Never moves.
  - `${DEST_IMAGE_MOVING}` — the **moving** dev ref the app kustomizations track via
    `newTag: main` (`…/<app>:<ref-slug>`; the default branch resolves to `:main`). Re-pointed
    each build. A driver wanting only the immutable tag binds both to the same value (Kaniko
    de-dups identical destinations).

- **`namespace-and-netpol.yaml`** — the `snapdragon-image-builds` namespace + a default-deny
  ingress NetworkPolicy (build pods serve nothing; egress to the registry + DNS + the source
  git remote is left open like the other tier policies). ArgoCD-managed (listed in
  `kustomization.yaml`).

## Drivers (how a build is dispatched)

The Job template is parameterized so it can be instantiated by any of:

1. **`.gitlab-ci.yml` `build:images`** — the stub is replaced by a documented dispatch that
   renders the template (substituting the build context / dest image) and `kubectl apply`s it
   into `snapdragon-image-builds` on the in-cluster runner. This is the in-cluster build path.
2. **ArgoCD** — render the Job into a Sync/PostSync hook Application.
3. **Argo-Workflows** — a `WorkflowTemplate` step, *if/when* the Workflows controller is
   installed (it is not present today; the proven #110 pattern is plain `batch/v1` Jobs, which
   this mirrors).

## SHIPS DARK + OPT-IN (merging changes nothing live)

Two layers of inertness:

- **Ships dark:** the Job template is **not** in `kustomization.yaml`, so ArgoCD never applies
  it — exactly like #110. Only the namespace + NetworkPolicy are ArgoCD-managed, and those are
  inert until a build lands.
- **Opt-in / default-off:** the ArgoCD `Application`
  (`../../apps-optional/60-image-builder.yaml`) lives in `specs/cluster/apps-optional/`, a
  directory the root app-of-apps does **not** recurse (the root recurses only
  `specs/cluster/apps/`). So the Application is never synced until an operator copies it into
  `specs/cluster/apps/`. **Merging this PR therefore changes nothing live.**

Registry push creds (`image-builder-registry`, a `dockerconfigjson` with **push**
(`write_registry`) scope for `registry.snapdragon.systems`) are **ESO-materialized** into the
build namespace — **never in git** — by the `image-builder-registry` ExternalSecret
(`../external-secrets/image-builder-externalsecrets.yaml`, wired into the ESO kustomization).
It sources Vault `secret/<brand>/image-builder-registry` (`username`/`token`), seeded with a
placeholder by `scripts/gen-cluster-secrets.sh` that the operator replaces post-bootstrap with
a real **`write_registry`** group deploy token. It is DELIBERATELY distinct from the runtime
`gitlab-registry` **pull** (`read_registry`) imagePullSecret so the runtime pull credential can
never push. Mirrors the #110 `service-catalog-builder-registry` contract.

## Live validation pending

A real build **cannot be live-validated yet**: the x86 kernel netfilter gap currently blocks
bringing up a cluster. These manifests are authored **correct-by-construction** against the
#110 Kaniko contract and validated with `kubectl kustomize` / yaml parse. Live validation is
deferred to a kernel-fixed x86 image.
