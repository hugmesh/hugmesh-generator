# image-builder — generic in-cluster Kaniko app-image build pipeline (ALWAYS-ON namespace, builds on dispatch)

Before this directory, the `.gitlab-ci.yml` `build:images` job was an **echo stub**
(`echo "build + push container images to ${CI_REGISTRY_IMAGE}"`) and **no in-cluster build
path existed**. First-party app images (gateway, frontends, BFFs, games, …) built only in
the GitLab org mirror. This directory is the missing in-cluster path: a **reusable, generic**
rootless-Kaniko pipeline. It builds an app image from its repo and pushes it to the
in-cluster Harbor registry (`registry.hugmesh.net`; see `../../apps/03a-harbor.yaml`).
GitLab's own bundled registry no longer serves this hostname.

It is **modeled 1:1 on the [#110](../service-catalog-builder/) Service-Catalog Kaniko
builder**: the same rootless `gcr.io/kaniko-project/executor` floor, the same security
posture, the same `dockerconfigjson` push-secret contract. It is **generalized** to build
any app repo's Dockerfile, not only Service-Catalog DOCKERFILE/ZIP sources.

## What ships here

- **`kaniko-build-job.template.yaml`** — a per-build **rootless** Kaniko `Job` TEMPLATE. A
  driver renders ONE copy per build (binding `${BUILD_NAME}` / `${BUILD_NAMESPACE}` /
  `${CONTEXT}` / `${DOCKERFILE}` / `${DEST_IMAGE}` / `${DEST_IMAGE_MOVING}`) and creates it in
  the build namespace. Kaniko builds the Dockerfile in userspace (no Docker daemon, no
  privileged socket) and pushes the image to `registry.hugmesh.net`. The security posture
  matches the platform build Jobs: `runAsNonRoot`, drop `ALL` caps,
  `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem` (Kaniko workdir on `emptyDir`),
  `automountServiceAccountToken:false`, and `ttlSecondsAfterFinished` plus
  `activeDeadlineSeconds` reaping. A dedicated MCS level (`s0:c75`, distinct from #110's
  `s0:c54`) keeps build pods off the runtime-app bands.

  **Tag scheme (immutable + moving), pushed from ONE build.** The template carries TWO
  `--destination` flags, so a single Kaniko build pushes both and the layers behind each
  tag are byte-identical. This mirrors the sibling `build:image` jobs (hugmesh-gateway,
  hugmesh-forum-bff-api: `docker push :$TAG` plus `:$CI_COMMIT_REF_SLUG`).
  - `${DEST_IMAGE}` — the **immutable** ref: a release tag on a tag pipeline, else the short
    SHA (`…/<app>:<release-tag-or-sha>`). It never moves.
  - `${DEST_IMAGE_MOVING}` — the **moving** dev ref the app kustomizations track via
    `newTag: main`. The `build:images` job binds it to `IMAGE_REF` (`main`). The sibling
    `build:image` jobs use the ref slug. It is re-pointed each build. A driver that wants
    only the immutable tag binds both to the same value (Kaniko de-dups identical
    destinations).

- **`namespace-and-netpol.yaml`** — the `hugmesh-image-builds` namespace and a default-deny
  ingress NetworkPolicy. Build pods serve nothing. Egress to the registry, DNS and the
  source git remote is left open, like the other tier policies. ArgoCD manages it (listed in
  `kustomization.yaml`).

## Drivers (how a build is dispatched)

The Job template takes parameters, so any of these can instantiate it:

1. **`.gitlab-ci.yml` `build:images`** — the only driver that exists. It `sed`-renders
   the template (build context, dest images), `kubectl apply`s it into
   `hugmesh-image-builds`, then waits for the Job (1800 s). It runs on the default branch
   and on tags, has `allow_failure: true`, and builds one app: `IMAGE_APP` defaults to
   `hugmesh-gateway`.
2. **ArgoCD** — render the Job into a Sync/PostSync hook Application. Not wired.
3. **Argo-Workflows** — a `WorkflowTemplate` step, *if/when* the Workflows controller is
   installed. Not wired, and the controller is not present today. The #110 pattern is plain
   `batch/v1` Jobs, and this mirrors it.

## ALWAYS-ON — and what that does (and does not) start

- **Always synced:** the ArgoCD `Application` (`../../apps/60-image-builder.yaml`) lives in
  `specs/cluster/apps/`. The root app-of-apps recurses that directory
  (`directory.recurse: true`), so ArgoCD reconciles it continuously. It used to sit in a
  sibling `specs/cluster/apps-optional/` directory that no root recursed, so it was opt-in.
- **What it creates:** the `hugmesh-image-builds` namespace (PSS `restricted`) and its
  default-deny-ingress NetworkPolicy. That is the complete set.
- **Still ships dark:** the Kaniko Job is a TEMPLATE and is deliberately **not** in
  `kustomization.yaml`, so ArgoCD never applies it, exactly like #110. **No build pod runs
  until a driver dispatches one.** The namespace and policy do nothing on their own.
- **Downstream effect:** the `image-builder-registry` ExternalSecret targets this namespace.
  It stops being inert the moment the namespace exists. Vault `secret/<brand>/harbor-robots`
  must carry `push_name` and `push_secret`, or ESO reports a sync error against it.

The `lint:image-builder-always-on` CI gate covers this
(`../../../../tests/scripts/test-image-builder-always-on.sh`).

### Registry push credential

`image-builder-registry` is a `dockerconfigjson` with **push** scope for
`registry.hugmesh.net`. ESO materializes it into the build namespace — **never in git** —
from the `image-builder-registry` ExternalSecret
(`../external-secrets/image-builder-externalsecrets.yaml`, wired into the ESO kustomization).

- **Source.** The ExternalSecret reads Vault `secret/<brand>/harbor-robots`
  (`push_name`, `push_secret`). That is Harbor's project-scoped PUSH robot account. The
  `harbor-provision` PostSync Job mints it automatically
  (`../harbor/harbor-provision-job.yaml`).
- **Owner.** Harbor reveals a robot's secret exactly once, so that Job captures it and
  writes it to Vault the moment it is created. It therefore **owns** the path.
  `scripts/gen-cluster-secrets.sh` does not write `harbor-robots` at all by default. A
  `vault kv put` REPLACES the whole KV-v2 document, and the Job's skip is keyed on Harbor
  state, so a clobber could never be repaired.
- **Manual override.** `IMAGE_BUILDER_REGISTRY_TOKEN` in `scripts/gen-cluster-secrets.sh`
  remains as an escape hatch for local or offline testing. It now `kv patch`es in only
  `push_name` and `push_secret`, and leaves the pull robot's keys alone.
  `../../../../tests/scripts/test-harbor-robots-ownership.sh` executes both writers and
  asserts exactly that.
- **Separate from pull.** The credential is DELIBERATELY distinct from the runtime
  `harbor-registry` **pull**-scoped robot imagePullSecret (formerly `gitlab-registry`), so
  the runtime pull credential can never push.

It has the same Vault source and auth shape as `service-catalog-registry-credentials`,
which carries it as an Opaque `config.json`; this one stays a `dockerconfigjson`.

## Live validation pending

A real build **cannot be live-validated yet**: the x86 kernel netfilter gap currently blocks
bringing up a cluster. These manifests are authored **correct-by-construction** against the
#110 Kaniko contract and validated with `kubectl kustomize` / yaml parse. Live validation is
deferred to a kernel-fixed x86 image.
