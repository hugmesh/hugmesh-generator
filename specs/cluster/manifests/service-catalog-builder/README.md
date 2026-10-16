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
admin-bff, default false; `APPSTORE_BUILDER_ENABLED` is `false` in
`specs/cluster/manifests/admin-bff-api/deployment.yaml`) and a DOCKERFILE deployment is
provisioned. The ArgoCD leg has its own flag, `app.appstore.effector.enabled` (default
false; the same deployment sets `APPSTORE_EFFECTOR_ENABLED` to `true`). The namespace and
NetworkPolicy are inert until a build lands there. Registry push creds
(`service-catalog-registry-credentials`, Opaque, key `config.json`) are ESO-materialized
into the build namespace — **never in git**
(`external-secrets/service-catalog-builder-externalsecrets.yaml`). The name and key are the
RUNTIME ones: `KanikoBuildLauncher` loads its own classpath template from the admin-bff jar,
and that is the Job that mounts the Secret.

## Known gaps before the builder flag may flip

`APPSTORE_BUILDER_ENABLED` stays `false`. Creating the push credential is necessary, not
sufficient. Read off the admin-bff runtime template (hugmesh-admin-bff-api
`src/main/resources/kaniko/service-catalog-build-job.template.yaml`) and this tree, and not
provable from here without a cluster:

1. `serviceAccountName: service-catalog-builder` — no manifest creates that ServiceAccount in
   `hugmesh-service-catalog-builds`, so the Job controller cannot create the pod.
2. The namespace enforces `pod-security.kubernetes.io/enforce: restricted`, and the runtime pod
   spec sets no `seccompProfile`, no `allowPrivilegeEscalation: false` and no
   `capabilities.drop: [ALL]`; admission should reject it.
3. The admin-bff pod runs as ServiceAccount `backups-effector`; the RBAC bound to it
   (`manifests/admin-bff-platform-capability-rbac`) is read-only probes and carries no
   rule on `jobs` in this namespace.

`tests/scripts/test-appstore-effector-flags.sh` reports 1 and 2 as NOTEs while the flag is
`false` and fails on them if it is flipped. Fixes for 1 and 2 are in the admin-bff template.

## The admin-bff side

`KanikoBuildLauncher` exists on admin-bff `main`. It renders the Job, creates it in
`app.appstore.builder.namespace` (default `hugmesh-service-catalog-builds`), waits up to
30 minutes for it to end, and returns the pushed image. `AddServiceEffector` then creates
the ArgoCD Application. Both Job template copies mount the same secret,
`service-catalog-registry-credentials`, key `config.json`, and the ESO ExternalSecret
creates it in `hugmesh-service-catalog-builds`. The mount is not `optional`, so the build
pod stays in `ContainerCreating` until that Secret exists. admin-bff's copy also binds the
extra `${DEST_IMAGE_MOVING}` placeholder.
