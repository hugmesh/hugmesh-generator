# service-catalog-builder — in-cluster Kaniko image builder for the SUPERADMIN Service Catalog

The SUPERADMIN Service Catalog has four service sources (hugmesh-superadmin-appstore design):

| source | needs a build? | path |
| --- | --- | --- |
| **SELECT** (catalog tile, prebuilt image) | no | admin-bff effector → ArgoCD Application |
| **GIT** (repo with its own CI) | no | admin-bff effector → ArgoCD Application |
| **DOCKERFILE** (dropped Dockerfile) | **yes — Kaniko** | this builder → registry → effector |
| **ZIP** (uploaded zip-as-repo) | would need Kaniko; **not built** | `KanikoBuildLauncher` rejects it with a 400 ("ZIP source upload is not yet implemented") |

Before this builder, nothing in the cluster could build an image. The admin-bff
`AddServiceEffector` therefore **guards** DOCKERFILE and ZIP with a 400:
*"requires the in-cluster image builder (Kaniko)"*. That guard still fires when admin-bff's
`KanikoBuildLauncher` bean is absent. This directory holds the namespace and the Job
template for the builder.

## What ships here

- **`kaniko-build-job.template.yaml`** — a per-build **rootless** Kaniko `Job` TEMPLATE.
  The admin-bff `KanikoBuildLauncher` renders ONE copy per build and creates it in the
  build namespace. This directory's copy binds `${BUILD_NAME}` / `${CONTEXT}` /
  `${DOCKERFILE}` / `${DEST_IMAGE}` / `${BUILD_NAMESPACE}`.

  admin-bff renders its own copy, `src/main/resources/kaniko/service-catalog-build-job.template.yaml`.
  It binds a sixth placeholder, `${DEST_IMAGE_MOVING}`. The launcher reads its classpath
  copy, not this one.

  Kaniko builds the Dockerfile in userspace (no Docker daemon, no privileged socket) and
  pushes to the in-cluster Harbor registry (`registry.hugmesh.net` by default). The
  effector then points an ArgoCD `Application` at the pushed image. The launcher tags it
  with a random 6-character hex short-SHA
  (`registry.hugmesh.net/<brand>/<service>:<short-sha>`), not a digest.

  The security posture matches the platform sync Jobs: `runAsNonRoot`, drop `ALL` caps,
  `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem` (Kaniko workdir on
  `emptyDir`), `automountServiceAccountToken:false`, and `ttlSecondsAfterFinished` plus
  `activeDeadlineSeconds` reaping.

- **`namespace-and-netpol.yaml`** — the `hugmesh-service-catalog-builds` namespace and a
  default-deny ingress NetworkPolicy. Build pods serve nothing. Egress to the registry and
  DNS is left open, like the other tier policies. ArgoCD manages it (listed in
  `kustomization.yaml`).

## SHIPS DARK

ArgoCD does **not** apply the Job template (it is not in `kustomization.yaml`). A Job
exists only when the builder is enabled (`app.appstore.builder.enabled=true` in
admin-bff, default false) and a DOCKERFILE deployment is provisioned. The ArgoCD leg has
its own flag, `app.appstore.effector.enabled` (default false). The namespace and
NetworkPolicy are inert until a build lands there. Registry push creds
(`service-catalog-builder-registry`, `dockerconfigjson`) are ESO-materialized into the
build namespace — **never in git**.

## The admin-bff side

`KanikoBuildLauncher` exists on admin-bff `main`. It renders the Job, creates it in
`app.appstore.builder.namespace` (default `hugmesh-service-catalog-builds`), waits up to
30 minutes for it to end, and returns the pushed image. `AddServiceEffector` then creates
the ArgoCD Application. The two sides share the registry secret name
(`service-catalog-builder-registry`) and the namespace. They do not share one Job
template: admin-bff's copy has the extra `${DEST_IMAGE_MOVING}` placeholder.
