# Cluster Hardening — Sequenced Rollout Plan

This page is the **sequenced, blast-radius-bounded** rollout for the
**config-sensitive** hardening items that the audit found. They are crash-loop-risky
on stateful workloads, or need **live-cluster validation** (ArgoCD / OTel /
NetworkPolicy / Vault). Roll them **one at a time** and validate each on the cluster
before the next. The status below was checked against `origin/main` on 2026-10-07.

Standards: CIS Kubernetes Benchmark 5.2/5.3/5.7, NIST SP 800-190 §4.3/§4.5,
NIST SP 800-53 Rev5 (AC-6, AC-4, SC-7, SC-8, SC-13, SC-39, CM-6, CM-7), DISA
Kubernetes STIG, FIPS 140-3 / 186-5. See also `docs/CRYPTO-AUDIT.md`,
`docs/POSTGRES-HARDENING.md`, `docs/SECURITY.md`.

## Status at a glance

| Item | State on `main` |
|---|---|
| A1 casdoor container securityContext | **planned** (no container securityContext) |
| A2 casdoor Guaranteed QoS | **planned** (requests 100m/256Mi, limits 1/768Mi: not equal) |
| A3 vault pod runAsNonRoot | **partly done** (see A3) |
| A4–A10 stateful workloads (casdoor-pg, akkoma, tuwunel, forgejo, kafka, clickhouse, uptrace-pg) | **planned** |
| B tier-wide egress default-deny | **authored, ships dark** (`tier-egress.yaml`, `db-egress.yaml`; manual-sync overlay is empty) |
| C Kyverno Audit → Enforce | **planned** (policy is Audit, `failurePolicy: Ignore`; `reportsController` off) |
| D `/dev/dri` hostPath → device plugin | **planned** (`games` and `media-poisoner` still use hostPath) |
| E node taints for sensitive tiers | **planned** (provisioning removes the control-plane taint on the pki node) |
| F local-path ClusterRole | **partly done** (no `*` verbs or resources remain; see F) |
| G akkoma digest pin | **planned** (five `:stable` refs remain) |
| H Cassandra auth | **DONE**, live (see H) |
| H Cassandra TLS | **authored, ships dark** |
| I tailscaled and the AVC workout | **no change needed** |

## What is ALREADY done (the SAFE set — do not redo)

| Area | Change | Control IDs |
|------|--------|-------------|
| Stateless web tier | `frontend` (nginx UID 101), `hugmesh-apis` (JVM UID 1000, /stores+/tmp tmpfs), `binhost` (nginx-unprivileged UID 101, hostPort kept) — container securityContext: runAsNonRoot, drop ALL, allowPrivilegeEscalation:false, readOnlyRootFilesystem + emptyDirs, seccomp RuntimeDefault | CIS K8s 5.2.5–5.2.9, 5.7.2; NIST 800-190 §4.5; 800-53 AC-6/SC-39 |
| Admission (report-only) | Kyverno `securitycontext-baseline` ClusterPolicy in **Audit** mode (`apps/16a-securitycontext-policy.yaml`) + PSA namespace labels **warn+audit** (`restricted`) in `namespaces/namespaces.yaml` | CIS K8s 5.2/5.3; DISA K8s STIG; 800-190 §4.5 |
| SSH/crypto | AEAD-only ciphers (dropped `aes256-ctr`), Ed25519-only host key + `HostKeyAlgorithms ssh-ed25519` | FIPS 186-5; 800-53 SC-8/SC-13/IA-5; DISA SSH STIG |
| Gateway chart | `automountServiceAccountToken: false` | 800-53 AC-6; 800-190 §4.5.5 |
| Image pinning | `forgejo:9` → `9.0.3`; `nginxinc/nginx-unprivileged` (untagged) → `:1.27-alpine` | 800-190 §4.3; CIS Docker 4.x |
| Tier ingress segmentation (auto-sync) | `manifests/networkpolicy/tier-ingress.yaml` (default-deny ingress per tier), plus per-pod homeserver/forum isolation (`homeserver-isolation.yaml`), applied by the auto-sync (prune + selfHeal) app `apps/08-networkpolicy.yaml` | NIST 800-53 SC-7/AC-4; CIS K8s 5.3.2 |
| Per-port DB ingress (ADR-32, live) | `manifests/networkpolicy/db-ingress.yaml`, listed in the same auto-synced kustomization. It admits only each store's real client on its real port: nine dedicated Postgres pods and `casdoor-pg` / `casdoor-games-pg` on `:5432`, and `cassandra` on `:9042` | NIST 800-53 SC-7; 800-204A |
| Per-app least-privilege Postgres roles | Nine dedicated DBs (route-access / federation / admin-bff / mod-bff / user-bff / forum-bff / wiki-bff / mesh-bff / character-forge-bff), each its own owner + non-owner `_app` role + own ESO password, SCRAM-SHA-256, `REVOKE … FROM PUBLIC` (see `initdb/00-hardening.sql` + `10-roles.sh`) | NIST 800-53 AC-6/IA-5; see `docs/POSTGRES-HARDENING.md` |
| Per-DB Vault-PKI server certs (ADR-32, ships dark) | `<db>-mtls` cert mounted at `/etc/postgres-tls`; `ssl` stays off (`PG_TLS_ENABLED=false`), so the wire path is byte-identical | NIST 800-53 SC-8; see `docs/POSTGRES-HARDENING.md` |
| Cassandra authentication (live) | `PasswordAuthenticator` + `CassandraAuthorizer` (the bitnami image defaults), superuser from the ESO Secret `cassandra-admin`, six per-app least-privilege roles and keyspaces created by `apps/00b-cassandra-init.yaml` | NIST 800-53 AC-6/IA-5 |

> **ADR-32** is a commit convention for the DB-hardening band (DB ingress, per-DB
> certs, DB egress, Cassandra). There is no standalone `docs/ADR-32` file. Earlier
> versions of this page cited "merged PR #40 / #56 / #124 / #128" and "held PR
> #132 / #133". Those numbers belong to an earlier history. In this repository they
> name unrelated PRs, so this page names files instead.

---

## What REMAINS and is ⏳ LIVE-GATED (held; enabling blind risks crash-loops)

These steps are parked until they can be validated **one workload at a time on a
booted cluster**. Applying them blind risks a crash-loop or a black-holed service.

| Item | State | Why held |
|------|-------|----------|
| **Postgres `ssl=on` flip** | ⏳ shipped dark: `PG_TLS_ENABLED="false"` in the nine DB Deployments | per-DB certs are on disk, but flipping `ssl=on` and `sslMode=require` blind risks DB/consumer connect failure. Validate per DB on the cluster |
| **Tier EGRESS default-deny per tier** | ⏳ authored, ships dark (`manifests/networkpolicy/tier-egress.yaml`, `db-egress.yaml`); the overlay that would apply them is empty | egress default-deny without every allow rule silently severs a service or wedges ArgoCD's own reconcile. Stage per namespace on the cluster |
| **Cassandra TLS** | ⏳ **authored dark** (`manifests/cassandra-hardening/`, Stage 2); flip live per **§H** | inter-node and client TLS for the gateway revocation/registry store. The dark overlay adds the `cassandra` Vault-PKI issuing role (patch), the `cassandra-mtls` cert ESO, and a PEM→JKS keystore builder feeding the chart's `tls.existingSecret`/`tls.passwordsSecret`. It is a breaking cutover for every Cassandra client, so it stays live-gated |

---

## Rollout principles (apply to EVERY item below)

1. **One workload at a time.** Never bulk-apply container securityContext to
   stateful pods. Apply, sync the single ArgoCD Application, watch the pod to
   `Ready`, exercise the data path, then move on.
2. **Validate before the next.** `kubectl rollout status` plus a functional probe
   (DB query / federation post / Vault unseal / OTel ingest) must pass.
3. **Roll back fast.** Each change is a single-file diff. `git revert` plus an
   ArgoCD sync restores the prior pod. Keep the prior `:dev`/digest image so the
   rollback is byte-identical.
4. **Watch the Audit report.** The Kyverno `securitycontext-baseline` Audit policy
   and the PSA `audit` annotations tell you which workloads still drift. Work the
   list top-down. The report reaching **zero** is the gate for the Audit→Enforce
   flip (last item).
5. **fsGroup for volume ownership.** A non-root container that owns a
   `ReadWriteOnce` PVC almost always needs `securityContext.fsGroup: <uid>`, so the
   kubelet chowns the mount. Omitting it is the #1 cause of a non-root stateful
   crash-loop. Set it alongside `runAsUser`.

---

## A. Per-stateful-workload container securityContext

Each workload carries only **pod-level seLinuxOptions** today (the audit finding).
Add the **container-level** securityContext (and where shown, pod
`runAsNonRoot`/`fsGroup` plus writable-path emptyDirs), copying the `media-poisoner`
exemplar. The UIDs below are the image's documented non-root user. **Confirm them
against the running image** (`kubectl exec -- id`) before you apply.

> Common change body (per container): `allowPrivilegeEscalation: false`,
> `capabilities: { drop: ["ALL"] }`, `readOnlyRootFilesystem: true` plus an
> `emptyDir` for each writable path. The pod adds `runAsNonRoot: true`,
> `runAsUser: <UID>`, `seccompProfile: { type: RuntimeDefault }`, and
> `fsGroup: <UID>` when it owns a PVC.

### A1. casdoor (auth — HIGH blast radius, do early but ALONE)
- **File:** `specs/cluster/manifests/casdoor/deployment.yaml`
- **Control:** CIS K8s 5.2.5–5.2.9; 800-190 §4.5
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1000`, seccomp RuntimeDefault;
  container drop ALL + allowPrivilegeEscalation:false. `readOnlyRootFilesystem`
  needs a writable `/tmp`; the casdoor binary serves `conf/` read-only.
- **Writable paths:** `/tmp` (emptyDir). Confirm casdoor does not write under its
  working dir at runtime (cert cache / `files/`). If it does, add emptyDirs for those.
- **Validation:** OIDC login as one persona in BOTH realms; JWKS reachable from
  every gateway; the `casdoor-init` Job still completes.
- **Blast radius:** ALL auth. A crash-loop logs everyone out. Roll at a quiet
  window and keep the prior ReplicaSet for instant rollback.

### A2. casdoor Guaranteed QoS (pair with A1)
- **File:** `specs/cluster/manifests/casdoor/deployment.yaml`
- **Control:** 800-53 SC-6 (resource availability); CIS K8s 5.7
- **Change:** set `resources.requests == resources.limits` (cpu + memory), so the
  pod gets **Guaranteed** QoS and is last to be evicted under node pressure. Today
  the requests are `100m` / `256Mi` and the limits `1` / `768Mi`.
- **Validation:** `kubectl get pod -o jsonpath='{.status.qosClass}'` is `Guaranteed`;
  no OOMKill under a login load burst.
- **Blast radius:** scheduling only. If requests are set too high the pod may go
  Pending, so size them from observed usage first.

### A3. vault — pod runAsNonRoot (init containers already hardened)
- **File:** `specs/cluster/manifests/vault/deployment.yaml` (**partly done**: see below)
- **Control:** CIS K8s 5.2.6; 800-190 §4.5.3; FIPS 140-3 (Vault is the crypto core)
- **Already in place:** the TLS-init init container sets drop ALL,
  allowPrivilegeEscalation false and a read-only root filesystem. The `vault` main
  container runs as `runAsUser: 100` / `runAsGroup: 1000` (the image's `vault` user),
  with `allowPrivilegeEscalation: false` and `capabilities: { add: ["IPC_LOCK"],
  drop: ["ALL"] }`. The pod has `fsGroup: 1000`. The config sets
  `disable_mlock = true`, and `IPC_LOCK` is added anyway.
- **Still to do:** pod-level `runAsNonRoot: true` and seccomp RuntimeDefault, and
  `readOnlyRootFilesystem` on the main container. The data volume is a **Raft**
  integrated-storage PVC (`/vault/data`), so confirm the `fsGroup` still matches the
  volume owner.
- **Writable paths:** `/vault/tls` (already tmpfs), the Raft data PVC, `/tmp`.
- **Validation:** Vault unseals; PKI issues a cert; ESO sync still works; the
  prod-hygiene `--runtime` seal-status probe still passes.
- **Blast radius:** PKI and every ESO-synced secret. Single replica, so there is
  brief unavailability on restart. Unseal must succeed or the cluster mTLS degrades.

### A4. casdoor-pg / casdoor-games-pg (postgres:16-alpine, UID 70)
- **File:** `specs/cluster/manifests/casdoor/pg.yaml` (and the games variant)
- **Control:** CIS K8s 5.2.5–5.2.9; see `docs/POSTGRES-HARDENING.md`
- **Change:** pod `runAsNonRoot:true`, `runAsUser:70`, `fsGroup:70`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false.
  `readOnlyRootFilesystem` for postgres needs a writable `/var/run/postgresql`
  (socket), `/tmp`, and the `PGDATA` PVC mount. Leave `PGDATA` on the PVC, writable.
- **Validation:** casdoor connects; `psql -c 'select 1'`; existing data is intact.
  UID 70 must own the PVC files. If the volume was written as root, a one-time
  `chown` Job or `fsGroup` is required, so test on a scratch PVC first.
- **Blast radius:** the casdoor auth store. **PVC ownership is the trap.** Validate
  on a copy before you touch the live volume.

### A5. akkoma + akkoma-db (federation)
- **Files:** `specs/cluster/manifests/akkoma/akkoma.yaml` (app + `migrate` init),
  the akkoma postgres (`*-db`)
- **Control:** CIS K8s 5.2.5–5.2.9; 800-190 §4.5
- **Change:** app pod `runAsNonRoot:true`, `runAsUser:<akkoma uid>` (confirm; commonly
  100 or 1000 in the upstream image), seccomp RuntimeDefault; container drop ALL +
  allowPrivilegeEscalation:false. `readOnlyRootFilesystem` needs a writable `/tmp`
  and the uploads PVC. The `migrate` init container writes only to the DB. DB pod:
  same as A4 (UID 70).
- **Validation:** the instance boots; a federated post in and out; MRF (force-local)
  still compiled in; the `pleroma_ctl migrate` init succeeds.
- **Blast radius:** Mastodon-side federation. Optional service (degrades greyed out).

### A6. tuwunel (Matrix homeserver)
- **File:** `specs/cluster/manifests/tuwunel/tuwunel.yaml` (the admin-sync Job already
  runs runAsNonRoot UID 1000 — mirror it)
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1000`, `fsGroup:1000`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false.
  Writable: the RocksDB data PVC, `/tmp`.
- **Validation:** homeserver `/_matrix/client/versions`; login and send a message;
  federation if enabled.
- **Blast radius:** Matrix federation. Optional service.

### A7. forgejo (UID 1000 `git`)
- **File:** `specs/cluster/manifests/forgejo/forgejo.yaml` (a StatefulSet; image pinned
  to 9.0.3; the pod has `fsGroup: 1000` and `seLinuxOptions` only)
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1000`, seccomp RuntimeDefault;
  container drop ALL + allowPrivilegeEscalation:false. Forgejo embeds OpenSSH on :22
  and writes `/data` and `/tmp`. `readOnlyRootFilesystem` needs emptyDirs for `/tmp`
  and any runtime config dir, with data on the PVC.
- **Validation:** web UI and git clone over HTTP and SSH; the GitLab-runner mirror
  pull still works; existing repos are intact (PVC ownership trap, see A4).
- **Blast radius:** the in-cluster git host / CI source. Devops only.

### A8. kafka (bitnamilegacy/kafka, UID 1001)
- **File:** `specs/cluster/manifests/analytics/kafka/deployment.yaml` (image `bitnamilegacy/kafka:3.7.1-debian-12-r9`)
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1001`, `fsGroup:1001`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false. Writable: the
  log-dirs PVC, `/tmp`, `/bitnami/kafka`. **KRaft formats the data dir on first boot
  as the run user**, so a UID mismatch on an existing PVC crash-loops.
- **Validation:** broker `Ready`; topic create/describe; the analytics discovery and
  clickhouse consumers still ingest.
- **Blast radius:** the analytics pipeline only (degrades gracefully).

### A9. clickhouse (clickhouse/clickhouse-server, UID 101)
- **File:** `specs/cluster/manifests/analytics/clickhouse/deployment.yaml` (image `clickhouse/clickhouse-server:25.3-alpine`)
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:101`, `fsGroup:101`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false. Writable:
  `/var/lib/clickhouse` (PVC), `/var/log/clickhouse-server`, `/tmp`. ClickHouse
  historically wants `CAP_SYS_NICE`/`CAP_IPC_LOCK` for performance. With
  `drop: ["ALL"]` it logs a warning and runs degraded but fine. **Confirm** there is
  no hard failure on this version (25.3) before you keep the drop.
- **Validation:** `SELECT 1`; analytics dashboards populate; existing parts are intact.
- **Blast radius:** the analytics store only.

### A10. uptrace-pg (observability postgres, UID 70)
- **File:** the observability postgres in `specs/cluster/manifests/observability/deployment.yaml`
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** identical to A4 (postgres UID 70, fsGroup 70, writable socket/tmp/PGDATA).
- **Validation:** the uptrace UI loads; traces/metrics query; the OTel write path is intact.
- **Blast radius:** observability only. Non-critical to the data plane.

---

## B. NetworkPolicy default-deny extension

> **Status:** the tier **ingress** default-deny is live (auto-synced, `apps/08-networkpolicy.yaml`).
> Per-pod homeserver/forum isolation is in. **Per-port DB ingress** micro-segmentation
> (`db-ingress.yaml`) is live. A narrow per-pod egress backstop for akkoma, akkoma-db
> and tuwunel (`homeserver-egress.yaml`) is also live. The tier-wide **egress**
> default-deny and the per-DB egress lock are authored but dark (below).

- **File:** `specs/cluster/apps/08-networkpolicy.yaml` (ingress, auto-sync) and
  `specs/cluster/apps/08a-networkpolicy-egress.yaml` (egress, manual sync).
- **Control:** NIST 800-53 SC-7 (boundary protection), AC-4 (information flow);
  CIS K8s 5.3.2; 800-204A (microservice segmentation)
- **Change:** a namespace-scoped `default-deny` egress with explicit allow rules:
  gateway→BFF, BFF→homeserver/DB, ESO→Vault, **ArgoCD→repo+API**,
  **OTel collector→uptrace + workloads→collector**, DNS (kube-dns) egress, and the
  headscale/tailnet path. NetworkPolicy bugs surface only at runtime, so this is
  **live-validate-only**.
- **Validation (LIVE, mandatory):** after the first sync, smoke-test login, each
  gateway hop, ArgoCD self-sync and OTel ingest. A missed allow rule silently
  black-holes a service. Apply default-deny to ONE namespace at a time.
- **Blast radius:** **high.** A wrong or missing allow severs a service or wedges
  ArgoCD's own reconcile. Stage per namespace and keep a break-glass `kubectl` path
  that bypasses the mesh.
- **Status (ships dark):** `specs/cluster/manifests/networkpolicy/tier-egress.yaml`
  holds one `tier-egress` policy for each of five namespaces (`hugmesh-frontend`,
  `hugmesh-backend`, `hugmesh-pki`, `hugmesh-games`, `devops`) with the allow-set:
  DNS, intra-tier, Postgres :5432, Cassandra :9042, Vault :8200, headscale, ArgoCD
  reconcile, kube-apiserver and git egress. The per-pod-locked DB and homeserver pods
  are excluded with the same `NotIn` lists as `tier-ingress.yaml`, `db-ingress.yaml`
  and `homeserver-egress.yaml`. It is **inert until an operator enables it**. It is
  left OUT of the auto-sync `apps/08-networkpolicy.yaml` and fronted by a separate
  **MANUAL-sync** app `apps/08a-networkpolicy-egress.yaml` over the isolated overlay
  `specs/cluster/manifests/networkpolicy-egress/`, whose `resources: []` renders zero
  objects. **Gate: live cluster validated.** Enable one namespace at a time (devops
  and ArgoCD LAST): carve that namespace into the overlay with
  `scripts/netpol-egress-scope.py <namespace>`, list the generated file under the
  overlay's `resources:`, merge, then manual-sync 08a. The order, smoke tests and
  rollback are in `docs/DB-HARDENING-RUNBOOK.md` part C.
- **kube-apiserver carve-out (kind + Calico live-verify fix):** the apiserver allow is
  **TCP/6443 to the NODE network CIDRs** (RFC1918 `10/8` + `172.16/12` + `192.168/16`
  + tailnet `100.64.0.0/10`), **not** the `10.96.0.1/32` ClusterIP `:443`. kube-proxy
  DNATs the apiserver ClusterIP to the control-plane node IP:6443, and Calico
  evaluates egress **after** DNAT. The ClusterIP rule therefore never matched and
  black-holed the API (wedging ArgoCD in the devops block). The node IP is
  per-deployment (DHCP/LAN), so the RFC1918 + tailnet superset is the fail-safe
  default. **Residual (live-validate):** tighten it to the actual control-plane node
  /24 once that is known on the live cluster.
- **egress-proxy (Squid) dedicated policy:** the `app=egress-proxy` pods are EXCLUDED
  from the `hugmesh-backend` tier-egress `NotIn` (its allow-set has no public rule).
  They get their OWN least-privilege egress policy, `egress-proxy-egress` (DNS +
  public 80/443), so akkoma/tuwunel federation keeps working without opening the
  whole tier.
- **Per-DB egress lock (ships dark):** `manifests/networkpolicy/db-egress.yaml`
  gives the six Postgres pods that `tier-egress.yaml` excludes (`admin-bff-db`,
  `mod-bff-db`, `user-bff-db`, `federation-db`, `forum-bff-db`, `route-access-db`) a
  DNS-only egress policy. It is enabled the same way, carved per namespace with
  `scripts/netpol-egress-scope.py <namespace> --with-db-egress` (backend and pki). **Open gap:** `cassandra` is excluded from
  tier-egress too, and no other policy covers it, so its egress stays default-allow.
  It gossips and its pod spec is rendered by the bitnami chart, so its real allow-set
  cannot be derived from this tree. Close it only after reading the rendered
  StatefulSet off a live cluster.

---

## C. Kyverno `securitycontext-baseline`: Audit → Enforce flip

- **File:** `specs/cluster/manifests/securitycontext-policy/securitycontext-baseline-policy.yaml`
- **Control:** CIS K8s 5.2/5.3; DISA K8s STIG; 800-190 §4.5
- **Change:** `validationFailureAction: Audit` → `Enforce`; `failurePolicy: Ignore` →
  `Fail`. Flip the PSA namespace labels from `warn/audit` by adding
  `pod-security.kubernetes.io/enforce: restricted` (or `baseline` if a legitimate
  workload still needs a relaxation) in `namespaces/namespaces.yaml`.
- **Gate (hard prerequisite):** the Kyverno PolicyReport and the PSA `audit` log show
  **zero** violations across A1–A10 first. Enable the Kyverno `reportsController`
  (currently `enabled: false` in `apps/15-kyverno.yaml`) so the PolicyReports can be
  queried while you drive the drift to zero.
- **Validation:** apply to a scratch namespace; confirm a known-bad pod is rejected
  and every real workload still admits; then flip cluster-wide.
- **Blast radius:** **highest if flipped early.** Enforce blocks any non-conforming
  pod from scheduling, including a legitimate one you missed. Flip only after the
  report is clean, and keep the per-namespace `enforce` rollout staged so one
  namespace can be reverted without the others.

---

## D. /dev/dri GPU device-plugin migration

- **Files:** `specs/cluster/manifests/media-poisoner/deployment.yaml`,
  `specs/cluster/manifests/games/deployment.yaml` (both use a `/dev/dri` **hostPath**)
- **Control:** CIS K8s 5.2.4 (hostPath); 800-190 §4.5.2 (host resource exposure)
- **Change:** replace the `/dev/dri` hostPath mount with a GPU **device plugin** (for
  example the generic `k8s-dra-driver` / `intel-device-plugins` DRM resource), so the
  render node is a schedulable resource and not a raw host mount.
- **Validation:** the GPU workload still claims a render node and the poison/games
  compute path runs. On a Pi-only cluster the pod stays Pending (unchanged
  degradation contract).
- **Blast radius:** GPU workloads only. The device-plugin DaemonSet needs vetting
  against amdgpu/i915/nouveau (vendor-agnostic, matching today's behaviour).

---

## E. Node Taints for sensitive tiers

- **Files:** node labelling in `specs/etc/keys-provision/provision.sh`
  (`_label_control_plane` sets `hugmesh.net/role=<role>`, default `pki`) plus
  tolerations on the sensitive workloads
- **Control:** 800-53 AC-6/SC-7; CIS K8s 5.7 (workload isolation)
- **Today:** `_label_control_plane` **removes** the `node-role.kubernetes.io/control-plane`
  taint from the pki node, so the pki-tier workloads (Vault, Casdoor, Cassandra,
  headscale) can schedule there. Nothing keeps general workloads off it.
- **Change:** taint the **pki** node (for example `hugmesh.net/pki=true:NoSchedule`)
  and any sensitive tier, so only tolerating workloads (Vault, Casdoor, headscale)
  land there. General workloads stay off the secrets node.
- **Validation:** the intended pods still schedule (they carry the toleration; Vault
  already tolerates `control-plane`); general pods do NOT land on the tainted node.
- **Blast radius:** scheduling. A missing toleration leaves a pod Pending. Add the
  taint AFTER you confirm every pod that must run there tolerates it.

---

## F. local-path provisioner ClusterRole tightening

- **File:** `specs/cluster/manifests/local-path/local-path.yaml`
- **Control:** CIS K8s 5.1.3 (minimize wildcard/cluster-admin); 800-53 AC-6
- **Today:** the `local-path-provisioner` ClusterRole has no `*` verb or resource. It
  grants cluster-wide `get/list/watch` on nodes, PVCs, configmaps, pods and
  `pods/log`, full verbs on PVs, `create/patch` on events, and read on StorageClasses.
  The DaemonSet pod runs with `seLinuxOptions.type: spc_t`.
- **Change:** confirm the minimum the provisioner needs (PV/PVC/StorageClass/Node
  read, PV create, event create, the helper-pod create in its own namespace) and
  drop the rest, for example the cluster-wide `configmaps`, `pods` and `pods/log`
  reads if they are not needed.
- **Validation:** dynamic provisioning of a new PVC still works (the helper pod runs
  and the PV binds); existing volumes are unaffected.
- **Blast radius:** storage provisioning. A role that is too tight fails new PVC
  binds (existing PVs keep working). Test with a throwaway PVC before you keep it.

---

## G. akkoma image digest pin (could not pin in the safe PR)

- **Files:** `specs/cluster/manifests/akkoma/akkoma.yaml` (×2),
  `akkoma/admin-sync-job.yaml`, `test-runner/akkoma-peer.yaml` (×2), all
  `git.akkoma.dev/akkomagang/akkoma:stable`. The custom build `akkoma/Dockerfile`
  carries `AKKOMA_BASE=...@sha256:REPLACE_WITH_PINNED_AKKOMA_DIGEST` and
  `AKKOMA_SOURCE_REF=REPLACE_WITH_AKKOMA_GIT_TAG`.
- **Control:** 800-190 §4.3 (image provenance); CIS Docker 4.x
- **Why deferred:** upstream publishes only the **moving** `stable`/`develop` tags,
  and there is **no** per-release version tag to pin to. The correct pin is a
  `@sha256` digest. It must be **resolved from the live registry**
  (`crane digest git.akkoma.dev/akkomagang/akkoma:stable` or
  `docker buildx imagetools inspect`) for the chosen release. It cannot be fabricated
  in a manifest. Fill `REPLACE_WITH_PINNED_AKKOMA_DIGEST` in the Dockerfile and
  replace every `:stable` ref with the SAME digest in one change.
- **Validation:** the akkoma app, migrate Job, admin-sync and test peer all pull the
  digest and boot. The rebrand `sed` is digest-neutral (no hugmesh token in the
  image ref).
- **Blast radius:** federation (optional service). Pin all five refs to the identical
  digest atomically, so the app and its Jobs run the same build.

---

## H. Cassandra auth + TLS — enable order (DARK overlay, flip live)

Status in one line: authentication (Stage 1) is **live**. TLS (Stage 2) is still
**authored dark** and needs the live flip below; `docs/DB-HARDENING-RUNBOOK.md` part B
says what is and is not in the tree for it.

### Stage 1 — authentication

**Shipped; live on `main`.** The bitnami image defaults
`CASSANDRA_AUTHENTICATOR=PasswordAuthenticator` and
`CASSANDRA_AUTHORIZER=CassandraAuthorizer`, so this cluster has always required a
password. An earlier version of this page said `apps/00-cassandra.yaml` ran with no
authenticator (effectively AllowAll) and listed a five-step "breaking cutover". That
premise was wrong, and `cassandra-values-overlay.yaml` says so too. Do not re-apply
those steps. The pieces now in place:
- `apps/00-cassandra.yaml` takes the superuser from the ESO Secret `cassandra-admin`
  (`dbUser.existingSecret`, Vault `secret/<brand>/cassandra-admin`).
- `manifests/external-secrets/cassandra-externalsecrets.yaml` materializes
  `cassandra-admin` and `cassandra-app-creds` (Vault `secret/<brand>/cassandra-app-creds`:
  `admin-bff`, `pki-gateway`, `be-gateway`, `fe-gateway`, `superadmin-gateway`,
  `federation`), with each namespace getting only its own keys.
- `apps/00b-cassandra-init.yaml` (`manifests/cassandra-init/`) is a PostSync Job. It
  creates the keyspaces `hugmesh_gateway` and `hugmesh_federation`, the six roles
  `admin_bff_cass`, `pki_gw_cass`, `be_gw_cass`, `fe_gw_cass`, `sa_gw_cass`,
  `federation_cass`, and their GRANTs. `CassandraAuthorizer` is **deny-by-default**,
  so a role with no GRANT authenticates but reads and writes **nothing**: fail CLOSED.
- `manifests/cassandra-hardening/cassandra-auth-config.yaml` is only a record of the
  two settings. Nothing consumes it at render time. Its remaining live note is that
  on a multi-node cluster `system_auth` must have RF>1.
- Validated out of cluster: a Cassandra 5.0.5 container with
  `PasswordAuthenticator` + `CassandraAuthorizer` connects a least-privilege role
  WITH its password, denies it WITHOUT, and refuses a read of a non-GRANTed keyspace.

### Stage 2 — TLS (follows Stage 1)

**Ships dark.** `specs/cluster/manifests/cassandra-hardening/` is wired by
`apps/00a-cassandra-hardening.yaml`, which is **MANUAL-sync** and points at the
**empty** sibling overlay `manifests/cassandra-hardening-empty` (`resources: []`), so
it can never auto-apply. Cassandra (`apps/00-cassandra.yaml`) stays plaintext until
an operator runs the steps below. The overlay's `kustomization.yaml` lists
`cassandra-auth-config.yaml`, `cassandra-tls-externalsecret.yaml` and
`cassandra-tls-keystore-builder.yaml`. `cassandra-values-overlay.yaml` and
`cassandra-pki-role.patch.txt` are flip-time reference files.

1. Apply the `cassandra` Vault-PKI role (`cassandra-pki-role.patch.txt`: add it to the
   `vault-pki-init` for-app loop) and re-run the idempotent `vault-pki-init` Job.
2. Flip `apps/00a-cassandra-hardening.yaml` `source.path` →
   `specs/cluster/manifests/cassandra-hardening` and **manually sync** it, or apply
   the overlay directly. Apply `cassandra-tls-externalsecret.yaml` (it materializes
   `cassandra-mtls`) and run `cassandra-tls-keystore-builder` (PEM→JKS →
   `cassandra-tls-stores` + `cassandra-tls-passwords`).
3. Merge the **Stage 2** `tls:` values from `cassandra-values-overlay.yaml`
   (`internodeEncryption: all`, `clientEncryption: true`,
   `existingSecret: cassandra-tls-stores`, `passwordsSecret: cassandra-tls-passwords`)
   into `apps/00-cassandra.yaml`, and roll. `clientEncryption` leaves
   `require_client_auth` optional, so a client that is not yet on TLS is not severed
   at once. Flip the consumers (`CASSANDRA_SSL=true` plus truststore;
   `CASSANDRA_TLS_ENABLED=true` on the bootstrap Job), confirm, then tighten to
   required. (Unverified: `require_client_auth` is mutual TLS, and whether plaintext
   clients are still accepted is the separate `optional` flag in
   `client_encryption_options`; see `DB-HARDENING-RUNBOOK.md` B.3.)

**Rollback:** revert the values merge on `apps/00-cassandra.yaml` (back to plaintext)
and re-point `apps/00a-cassandra-hardening.yaml` at the empty overlay. The overlay
objects are passive (Secrets/Jobs) and harmless if left.

---

## I. Node SELinux AVC workout — `tailscaled` is deliberately OUT of scope (#330)

**Status: no change needed. The workout and the runlevel already agree.** This
section exists so nobody re-opens the question from the same wrong premise.

Issue #330 reported that "`tailscaled` is in no default runlevel for any image, yet
the QEMU AVC workout exercises it — the SELinux policy is being tuned against a
service a real boot never starts". It asked for one of two things: add
`rc-update add tailscaled default` for the roles that want it, or drop it from the
workout and record that here. Measured against this tree on 2026-09-09 (and rechecked
2026-10-07), **both halves of the premise are false**, so neither branch applies:

1. **The AVC workout does not exercise `tailscaled`.** The in-guest probe list is
   `tests/qemu/avc-workload.sh`, and it contains *zero* tailscale references. It
   covers all nine `.te` modules: `hugmesh_authkeys` (ssh logins and a direct
   `hugmesh-authorized-keys-lookup`, plus `sshd -T`), then `svc_probe` for
   `hugmesh-device-registry-sync`, `hugmesh-domain-reconcile`,
   `hugmesh-node-storage-reconcile`, `hugmesh-policy-sync`, `hugmesh-tor-reconcile`
   and `hugmesh-egress-vpn` / `hugmesh-vpn-reconcile`, and finally `containerd` /
   `kubelet` / `kubeadm init --dry-run` for the `localpath_provisioner.te` +
   `otel_collector.te` lane. `tests/qemu/avc-workout.sh` mentions tailscale on
   exactly one line (:208), and that line *disables* it: `"tailscale": { "enabled":
   false }` in the KEYS manifest it builds, matching `run-qemu-test.sh:224`,
   `mesh-cluster.sh:473` and `docker-entrypoint.sh:1040`. Phase 2 is a LAN cluster
   with headscale/tailscale off by design.

2. **No SELinux policy is being tuned against it.** `specs/selinux/` holds nine `.te`
   modules: `hugmesh_authkeys`, `hugmesh_device_registry_sync`,
   `hugmesh_domain_reconcile`, `hugmesh_node_storage`, `hugmesh_policy_sync`,
   `hugmesh_tor`, `hugmesh_vpn`, `localpath_provisioner`, `otel_collector`. **None
   mentions tailscale** (`grep -rli tailscal specs/selinux/` returns nothing). There is
   no tailscaled module to narrow, so no `INFERRED-WIDE` rule anywhere depends on a
   tailscaled AVC.

3. **`rc-update add tailscaled default` does exist**, in `provision_tailscale()` in
   `specs/etc/keys-provision/provision.sh`, a few lines after the matching
   `rc-update del tailscaled default`. It is *manifest-driven, at
   first boot*, and not baked at build time. The function reads `.tailscale.enabled`
   and adds the service to the default runlevel when true, or removes it when false.
   No builder links it. The grep that reads as "no image ever enables it" was run
   against the build scripts, which is why the premise looked true.

**Consequence for the runlevel question:** which roles "want" tailscaled is a
per-deployment manifest choice, not a spec constant, so there is nothing to add to a
role spec. Every harness payload sets `enabled: false`, so provisioning unschedules
it and the workout never probes it. This is consistent end to end.

**One genuine loose end, filed as #343 (open, NOT fixed here).**
`tests/qemu/assertions.sh` (the `tailscaled` block) grades
"`/usr/sbin/tailscaled` installed but not in the default runlevel" as a defect, and is
deliberately manifest-blind for tailscaled (it reads the KEYS manifest only for
`.headscale.enabled` and the SELinux mode). That is exactly the state
`provision_tailscale()` produces on any image built *with* the mesh client whose
manifest sets `enabled: false`, which is every harness payload. Confirming whether it
fires needs a live QEMU boot, which that run's brief forbade outright (a standing
rule, not a RAM verdict: 13-17 GiB stayed available throughout). Stale builder abort
messages point the same way and should be corrected with it: the `tailscale fetch
failed` error in `build-x86-host-stage4.sh` and in the Frite, Jetson and Orange Pi
builders says "tailscaled is enabled in the runlevel", which no builder does.
