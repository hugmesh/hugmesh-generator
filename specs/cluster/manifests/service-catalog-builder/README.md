# service-catalog-builder — in-cluster Kaniko image builder for the SUPERADMIN Service Catalog

The SUPERADMIN Service Catalog has four service sources (hugmesh-superadmin-appstore design):

| source | needs a build? | path |
| --- | --- | --- |
| **SELECT** (catalog tile, prebuilt image) | no | admin-bff effector → ArgoCD Application |
| **GIT** (repo with its own CI) | no | admin-bff effector → ArgoCD Application |
| **DOCKERFILE** (dropped Dockerfile) | **yes — Kaniko** | this builder → registry → effector |
| **ZIP** (uploaded zip-as-repo) | **yes — Kaniko** | this builder → registry → effector |

Before this builder, `build:images` was an **echo stub** (`.gitlab-ci.yml`) and no in-cluster
builder existed, so the admin-bff `AddServiceEffector` **guards** DOCKERFILE/ZIP with a clear
*"requires the in-cluster image builder (Kaniko)"* 400. This directory is that builder.

## What ships here

- **`kaniko-build-job.template.yaml`** — a per-build **rootless** Kaniko `Job` TEMPLATE. The
  admin-bff `AddService` task renders ONE copy per build (binding `${BUILD_NAME}` /
  `${CONTEXT}` / `${DOCKERFILE}` / `${DEST_IMAGE}` / `${BUILD_NAMESPACE}`) and creates it in
  the build namespace. Kaniko builds the Dockerfile in userspace (no Docker daemon, no
  privileged socket) and pushes to the in-cluster Harbor registry, then the effector points an
  ArgoCD `Application` at the resulting digest-pinned image. Security posture matches the
  platform sync Jobs: `runAsNonRoot`, drop `ALL` caps, `seccompProfile: RuntimeDefault`,
  `readOnlyRootFilesystem` (Kaniko workdir on `emptyDir`), `automountServiceAccountToken:false`,
  `ttlSecondsAfterFinished` + `activeDeadlineSeconds` reaping.

- **`namespace-and-netpol.yaml`** — the `hugmesh-service-catalog-builds` namespace + a default-deny
  ingress NetworkPolicy (build pods serve nothing; egress to the registry + DNS is left open
  like the other tier policies). ArgoCD-managed (listed in `kustomization.yaml`).

## SHIPS DARK

The Job template is **not** applied by ArgoCD (it is not in `kustomization.yaml`) — it is
instantiated only when the effector is enabled (`app.appstore.effector.enabled=true` in
admin-bff) and a DOCKERFILE/ZIP deployment is provisioned. The namespace + NetworkPolicy are
inert until a build lands there. Registry push creds (`service-catalog-registry-credentials`,
Opaque, key `config.json`) are ESO-materialized into the build namespace — **never in git**
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

## What the admin-bff side still needs (follow-on, NOT in this PR)

The `AddServiceEffector` currently guards DOCKERFILE/ZIP. Wiring it to render + create this
Job (a `KanikoBuildLauncher` mirroring the games `JobLauncher` / `Fabric8` writers), wait for
completion, then proceed to the ArgoCD Application with the built digest, is the next admin-bff
increment. The contract (placeholders above + the registry secret name) is fixed here so the
two sides line up.
