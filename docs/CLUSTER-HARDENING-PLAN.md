# Cluster Hardening — Sequenced Rollout Plan

Companion to the SAFE hardening already merged (branch `feat/infra-hardening-safe`).
This document is the **sequenced, blast-radius-bounded** rollout for the
**config-sensitive** items the audit surfaced that are **NOT** in the safe PR
because they are crash-loop-risky on stateful workloads or need **live-cluster
validation** (ArgoCD / OTel / NetworkPolicy / Vault). Each item is rolled
**one at a time** and validated on-cluster before the next.

Standards: CIS Kubernetes Benchmark 5.2/5.3/5.7, NIST SP 800-190 §4.3/§4.5,
NIST SP 800-53 Rev5 (AC-6, AC-4, SC-7, SC-8, SC-13, SC-39, CM-6, CM-7), DISA
Kubernetes STIG, FIPS 140-3 / 186-5. See also `docs/CRYPTO-AUDIT.md`,
`docs/POSTGRES-HARDENING.md`, `docs/SECURITY.md`.

## What is ALREADY done (the SAFE set — do not redo)

| Area | Change | Control IDs |
|------|--------|-------------|
| Stateless web tier | `frontend` (nginx UID 101), `hugmesh-apis` (JVM UID 1000, /stores+/tmp tmpfs), `binhost` (nginx-unprivileged UID 101, hostPort kept) — container securityContext: runAsNonRoot, drop ALL, allowPrivilegeEscalation:false, readOnlyRootFilesystem + emptyDirs, seccomp RuntimeDefault | CIS K8s 5.2.5–5.2.9, 5.7.2; NIST 800-190 §4.5; 800-53 AC-6/SC-39 |
| Admission (report-only) | Kyverno `securitycontext-baseline` ClusterPolicy in **Audit** mode + PSA namespace labels **warn+audit** (`restricted`) | CIS K8s 5.2/5.3; DISA K8s STIG; 800-190 §4.5 |
| SSH/crypto | AEAD-only ciphers (dropped `aes256-ctr`), Ed25519-only host key + `HostKeyAlgorithms ssh-ed25519` | FIPS 186-5; 800-53 SC-8/SC-13/IA-5; DISA SSH STIG |
| Gateway chart | `automountServiceAccountToken: false` | 800-53 AC-6; 800-190 §4.5.5 |
| Image pinning | `forgejo:9` → `9.0.3`; `nginxinc/nginx-unprivileged` (untagged) → `:1.27-alpine` | 800-190 §4.3; CIS Docker 4.x |
| Tier ingress segmentation (auto-sync) | `apps/08-networkpolicy.yaml` tier default-deny ingress auto-syncs (merged **PR #40**); per-pod homeserver/forum isolation (merged **PR #56**) | NIST 800-53 SC-7/AC-4; CIS K8s 5.3.2 |
| Per-port DB ingress (ships dark, ADR-32) | `manifests/networkpolicy/db-ingress.yaml` — admit only each store's real client on its real port (6 Postgres `:5432` + cassandra `:9042`), merged **PR #128** | NIST 800-53 SC-7; 800-204A |
| Per-app least-privilege Postgres roles | 6+ dedicated DBs (route-access / federation / admin-bff / mod-bff / user-bff / forum), each its own owner + non-owner `_app` role + own ESO password, SCRAM-SHA-256, `REVOKE … FROM PUBLIC` (see `initdb/00-hardening.sql` + `10-roles.sh`) | NIST 800-53 AC-6/IA-5; see `docs/POSTGRES-HARDENING.md` |
| Per-DB Vault-PKI server certs (ships dark, ADR-32) | `<db>-mtls` cert mounted at `/etc/postgres-tls`, `ssl=off` (wire path byte-identical), merged **PR #124** | NIST 800-53 SC-8; see `docs/POSTGRES-HARDENING.md` |

> **ADR-32** is a commit/PR convention for the DB-hardening band (#124 / #128 plus
> the held #132 / #133) — there is no standalone `docs/ADR-32` file.

---

## What REMAINS and is ⏳ LIVE-GATED (held; enabling blind risks crash-loops)

These steps are intentionally parked on held PRs / open items until they can be
validated **one workload at a time on a booted cluster** — applying them blind
risks a crash-loop or a black-holed service:

| Item | State | Why held |
|------|-------|----------|
| **Postgres `ssl=on` flip** | ⏳ held **PR #133** (do-not-merge-until-enabled) | per-DB certs already on disk (#124); flipping `ssl=on` + `sslMode=require` blind risks DB/consumer connect failure — validate per-DB live |
| **Tier EGRESS default-deny per tier** | ⏳ held **PR #132** (do-not-merge-until-live) | egress default-deny without every allow rule silently severs a service / wedges ArgoCD's own reconcile — stage per-namespace live |
| **Cassandra auth** | ⏳ **authored DARK** (`manifests/cassandra-hardening/`, MANUAL-sync app `apps/00a-cassandra-hardening.yaml` → empty overlay); flip live per **§H** | `apps/00-cassandra.yaml` still runs the bitnami chart with **no authenticator configured** (effectively AllowAll). The DARK overlay carries `PasswordAuthenticator` + `CassandraAuthorizer`, the 6 per-app least-privilege roles + GRANTs (bootstrap Job), and the ESO creds — but it is INERT (not in the auto-synced tree). Enabling is a breaking cutover (every gateway revocation/registry + federation manifest cache reconnects WITH creds at once), so it stays live-gated per §H |
| **Cassandra TLS** | ⏳ **authored DARK** (`manifests/cassandra-hardening/`, Stage 2); flip live per **§H** | inter-node + client TLS for the gateway revocation/registry store. The DARK overlay adds the `cassandra` Vault-PKI issuing role (patch), the `cassandra-mtls` cert ESO, and a PEM→JKS keystore builder feeding the chart's `tls.existingSecret`/`tls.passwordsSecret`. Follows Cassandra auth; same live-gate |

---

## Rollout principles (apply to EVERY item below)

1. **One workload at a time.** Never bulk-apply container securityContext to
   stateful pods. Apply, sync the single ArgoCD Application, watch the pod to
   `Ready`, exercise the data path, then move on.
2. **Validate before next.** `kubectl rollout status` + a functional probe
   (DB query / federation post / Vault unseal / OTel ingest) must pass.
3. **Roll back fast.** Each change is a single-file diff; `git revert` + ArgoCD
   sync restores the prior pod. Keep the prior `:dev`/digest image so the
   rollback is byte-identical.
4. **Watch the Audit report.** The Kyverno `securitycontext-baseline` Audit
   policy + the PSA `audit` annotations tell you which workloads still drift —
   work the list top-down; the report reaching **zero** is the gate for the
   Audit→Enforce flip (last item).
5. **fsGroup for volume ownership.** A non-root container that owns a
   `ReadWriteOnce` PVC almost always needs `securityContext.fsGroup: <uid>` so
   the kubelet chowns the mount; omitting it is the #1 cause of a non-root
   stateful crash-loop. Set it alongside `runAsUser`.

---

## A. Per-stateful-workload container securityContext

Each carries only **POD-level seLinuxOptions** today (the audit finding). Add the
**container-level** securityContext (and where shown, pod `runAsNonRoot`/`fsGroup`
+ writable-path emptyDirs) replicating the `media-poisoner` exemplar. UIDs below
are the image's documented non-root user; **confirm against the running image**
(`kubectl exec -- id`) before applying.

> Common change body (per container): `allowPrivilegeEscalation: false`,
> `capabilities: { drop: ["ALL"] }`, `readOnlyRootFilesystem: true` + an
> `emptyDir` for each writable path; pod adds `runAsNonRoot: true`,
> `runAsUser: <UID>`, `seccompProfile: { type: RuntimeDefault }`,
> `fsGroup: <UID>` when a PVC is owned.

### A1. casdoor (auth — HIGH blast radius, do early but ALONE)
- **File:** `specs/cluster/manifests/casdoor/deployment.yaml`
- **Control:** CIS K8s 5.2.5–5.2.9; 800-190 §4.5
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1000`, seccomp RuntimeDefault;
  container drop ALL + allowPrivilegeEscalation:false. `readOnlyRootFilesystem`
  needs a writable `/tmp`; the casdoor binary serves `conf/` read-only.
- **Writable paths:** `/tmp` (emptyDir). Confirm casdoor does not write under
  its working dir at runtime (cert cache / `files/`); if it does, emptyDir those.
- **Validation:** OIDC login as one persona in BOTH realms; JWKS reachable from
  every gateway; `casdoor-init` Job still completes.
- **Blast radius:** ALL auth — a crash-loop logs everyone out. Roll at a quiet
  window; keep the prior ReplicaSet for instant rollback.

### A2. casdoor Guaranteed QoS (pair with A1)
- **File:** `specs/cluster/manifests/casdoor/deployment.yaml`
- **Control:** 800-53 SC-6 (resource availability); CIS K8s 5.7
- **Change:** set `resources.requests == resources.limits` (cpu+memory) so the
  pod gets **Guaranteed** QoS and is last to be evicted under node pressure.
- **Validation:** `kubectl get pod -o jsonpath='{.status.qosClass}'` == `Guaranteed`;
  no OOMKill under a login load burst.
- **Blast radius:** scheduling only; if requests are set too high the pod may go
  Pending — size from observed usage first.

### A3. vault — pod runAsNonRoot (init containers already hardened)
- **File:** `specs/cluster/manifests/vault/deployment.yaml`
- **Control:** CIS K8s 5.2.6; 800-190 §4.5.3; FIPS 140-3 (Vault is the crypto core)
- **Change:** the init containers already set drop-ALL + RO-rootfs; add
  **pod** `runAsNonRoot:true`, `runAsUser:100` (the `vault` user) — pod already
  has `fsGroup:1000` (reconcile to 100 if the data PVC is vault-owned), seccomp
  RuntimeDefault; main container drop ALL + allowPrivilegeEscalation:false.
  Vault needs `IPC_LOCK` **only** if `disable_mlock=false`; the deploy sets
  `disable_mlock` so `drop: ["ALL"]` is safe — **verify the config** first.
- **Writable paths:** `/vault/tls` (already tmpfs), file-storage data PVC, `/tmp`.
- **Validation:** Vault unseals; PKI issues a cert; ESO sync still works; the
  prod-hygiene `--runtime` seal-status probe still passes.
- **Blast radius:** PKI + every ESO-synced secret. Single-replica → brief
  unavailability on restart; unseal must succeed or the cluster mTLS degrades.

### A4. casdoor-pg / casdoor-games-pg (postgres:16-alpine, UID 70)
- **File:** `specs/cluster/manifests/casdoor/pg.yaml` (+ the games variant)
- **Control:** CIS K8s 5.2.5–5.2.9; see `docs/POSTGRES-HARDENING.md`
- **Change:** pod `runAsNonRoot:true`, `runAsUser:70`, `fsGroup:70`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false.
  `readOnlyRootFilesystem` for postgres needs writable `/var/run/postgresql`
  (socket), `/tmp`, and the `PGDATA` PVC mount; leave `PGDATA` on the PVC RW.
- **Validation:** casdoor connects; `psql -c 'select 1'`; existing data intact
  (UID-70 must own the PVC files — if the volume was written as root, a one-time
  `chown` Job or `fsGroup` is required → test on a scratch PVC first).
- **Blast radius:** casdoor auth store. **PVC ownership is the trap** — validate
  on a copy before touching the live volume.

### A5. akkoma + akkoma-db (federation)
- **Files:** `specs/cluster/manifests/akkoma/akkoma.yaml` (app + `migrate`
  init), the akkoma postgres (`*-db`)
- **Control:** CIS K8s 5.2.5–5.2.9; 800-190 §4.5
- **Change:** app pod `runAsNonRoot:true`, `runAsUser:<akkoma uid>` (confirm —
  commonly 100/1000 in the upstream image), seccomp RuntimeDefault; container
  drop ALL + allowPrivilegeEscalation:false. `readOnlyRootFilesystem` needs
  writable `/tmp` and the uploads PVC; the `migrate` init container writes only
  to the DB. DB pod: same as A4 (UID 70).
- **Validation:** instance boots; a federated post in/out; MRF (force-local)
  still compiled in; `pleroma_ctl migrate` init succeeds.
- **Blast radius:** Mastodon-side federation; optional service (degrades greyed-out).

### A6. tuwunel (Matrix homeserver)
- **File:** `specs/cluster/manifests/tuwunel/` deployment (the admin-sync Job
  already runs runAsNonRoot UID 1000 — mirror it)
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1000`, `fsGroup:1000`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false.
  Writable: the RocksDB data PVC, `/tmp`.
- **Validation:** homeserver `/_matrix/client/versions`; login + send a message;
  federation if enabled.
- **Blast radius:** Matrix federation; optional service.

### A7. forgejo (UID 1000 `git`)
- **File:** `specs/cluster/manifests/forgejo/forgejo.yaml` (image now pinned 9.0.3)
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1000`, `fsGroup:1000`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false. Forgejo
  embeds OpenSSH on :22 and writes `/data`, `/tmp`; `readOnlyRootFilesystem`
  needs emptyDirs for `/tmp` and any runtime config dir, data on the PVC.
- **Validation:** web UI + git clone over HTTP and SSH; the GitLab-runner mirror
  pull still works; existing repos intact (PVC ownership trap — see A4).
- **Blast radius:** the in-cluster git host / CI source; devops only.

### A8. kafka (bitnamilegacy/kafka, UID 1001)
- **File:** `specs/cluster/manifests/analytics/kafka/deployment.yaml`
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:1001`, `fsGroup:1001`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false. Writable:
  the log-dirs PVC, `/tmp`, `/bitnami/kafka`. **KRaft formats the data dir on
  first boot as the run user** — UID mismatch on an existing PVC crash-loops.
- **Validation:** broker `Ready`; topic create/describe; the analytics discovery
  + clickhouse consumers still ingest.
- **Blast radius:** analytics pipeline only (graceful-degrades).

### A9. clickhouse (clickhouse/clickhouse-server, UID 101)
- **File:** `specs/cluster/manifests/analytics/clickhouse/deployment.yaml`
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** pod `runAsNonRoot:true`, `runAsUser:101`, `fsGroup:101`, seccomp
  RuntimeDefault; container drop ALL + allowPrivilegeEscalation:false. Writable:
  `/var/lib/clickhouse` (PVC), `/var/log/clickhouse-server`, `/tmp`.
  ClickHouse historically wants `CAP_SYS_NICE`/`CAP_IPC_LOCK` for perf — with
  `drop: ["ALL"]` it logs a warning and runs degraded-but-fine; **confirm** no
  hard failure on this version (25.3) before keeping the drop.
- **Validation:** `SELECT 1`; analytics dashboards populate; existing parts intact.
- **Blast radius:** analytics store only.

### A10. uptrace-pg (observability postgres, UID 70)
- **File:** the observability postgres under `specs/cluster/manifests/observability/`
- **Control:** CIS K8s 5.2.5–5.2.9
- **Change:** identical to A4 (postgres UID 70 + fsGroup 70 + writable socket/tmp/PGDATA).
- **Validation:** uptrace UI loads; traces/metrics query; OTel write path intact.
- **Blast radius:** observability only; non-critical to data plane.

---

## B. NetworkPolicy default-deny extension

> **Status update:** the tier **ingress** default-deny is now auto-synced (merged
> **PR #40**), per-pod homeserver/forum isolation is in (merged **PR #56**), and
> **per-port DB ingress** micro-segmentation (route-access-db / federation-db /
> admin-bff-db / mod-bff-db / user-bff-db / forum-bff-db `:5432` + cassandra
> `:9042`, only from their real clients) is DONE (merged **PR #128**, ADR-32). The
> remaining piece below — extending to `devops`/observability and the **egress**
> default-deny per tier — is ⏳ held on **PR #132** (do-not-merge-until-live).

- **File:** `specs/cluster/apps/08-networkpolicy.yaml` → extend to cover
  `devops` (ArgoCD) + the observability/OTel paths; add the matching
  `hugmesh-policy`-tier allow rules.
- **Control:** NIST 800-53 SC-7 (boundary protection), AC-4 (information flow);
  CIS K8s 5.3.2; 800-204A (microservice segmentation)
- **Change:** add a namespace-scoped `default-deny` ingress+egress, then explicit
  allow rules: gateway→BFF, BFF→homeserver/DB, ESO→Vault, **ArgoCD→repo+API**,
  **OTel collector→uptrace + workloads→collector**, DNS (kube-dns) egress, and
  the headscale/tailnet path. The existing app already warns this is
  **live-validate-only** (NetworkPolicy bugs surface only at runtime).
- **Validation (LIVE, mandatory):** after first sync, smoke-test login + each
  gateway hop + ArgoCD self-sync + OTel ingest; a missed allow rule silently
  black-holes a service. Apply default-deny to ONE namespace at a time.
- **Blast radius:** **high** — a wrong/missing allow severs a service or wedges
  ArgoCD's own reconcile. Stage per-namespace; keep a break-glass `kubectl`
  path that bypasses the mesh.
- **Status (ships dark):** the tier-wide default-deny EGRESS policy itself is now
  authored at `specs/cluster/manifests/networkpolicy/tier-egress.yaml` (all five
  per-namespace blocks with the complete allow-set: DNS, intra-tier, Postgres :5432,
  Cassandra :9042, Vault :8200, headscale, ArgoCD reconcile + kube-apiserver + git
  egress, with the per-pod-locked DB/homeserver pods excluded via the same `NotIn`
  lists as `tier-ingress.yaml`/`db-ingress.yaml`/`homeserver-egress.yaml`). It is
  **inert until an operator enables it**: it is left OUT of the auto-sync
  `apps/08-networkpolicy.yaml` (which stays ingress-only) and fronted by a separate
  **MANUAL-sync** app `apps/08a-networkpolicy-egress.yaml` over the isolated overlay
  `specs/cluster/manifests/networkpolicy-egress/` (`resources: []` by default — renders
  zero objects). **Gate: live cluster validated.** Enable per-namespace, one at a time
  (devops/ArgoCD LAST), per the staging steps in the 08a app header.
- **kube-apiserver carve-out (kind+Calico live-verify fix):** the apiserver allow is
  **TCP/6443 to the NODE network CIDRs** (RFC1918 `10/8` + `172.16/12` + `192.168/16` +
  tailnet `100.64.0.0/10`), **not** the `10.96.0.1/32` ClusterIP `:443`. kube-proxy
  DNATs the apiserver ClusterIP to the control-plane node IP:6443 and Calico evaluates
  egress **post-DNAT**, so the ClusterIP rule never matched and black-holed the API
  (wedging ArgoCD in the devops block). The node IP is per-deployment (DHCP/LAN), so the
  RFC1918+tailnet superset is the fail-safe default. **Residual (live-validate):**
  tighten this to the actual control-plane node /24 once known on the live cluster.
- **egress-proxy (Squid) dedicated policy:** the `app=egress-proxy` pods are EXCLUDED
  from the `hugmesh-backend` tier-egress `NotIn` (its allow-set has no public rule)
  and given their OWN least-privilege egress policy (`egress-proxy-egress`: DNS + public
  80/443) so akkoma/tuwunel federation keeps working without opening the whole tier.
- **Documented default-allow gap (follow-up, not in this PR):** the five `*-bff-db` /
  `federation-db` pods are excluded from tier-egress and have NO egress policy anywhere
  (db-ingress is Ingress-only), so their egress is default-allow. Low risk (DB pods are
  servers), tracked as a follow-up DNS-only egress lock — see the in-file TODO.

---

## C. Kyverno `securitycontext-baseline`: Audit → Enforce flip

- **File:** `specs/cluster/manifests/securitycontext-policy/securitycontext-baseline-policy.yaml`
- **Control:** CIS K8s 5.2/5.3; DISA K8s STIG; 800-190 §4.5
- **Change:** `validationFailureAction: Audit` → `Enforce`; `failurePolicy:
  Ignore` → `Fail`. Flip the PSA namespace labels `warn/audit` → add
  `pod-security.kubernetes.io/enforce: restricted` (or `baseline` if any
  legitimate workload still needs a relaxation) in `namespaces/namespaces.yaml`.
- **Gate (hard prerequisite):** the Kyverno PolicyReport + PSA `audit` log show
  **zero** violations across A1–A10 first. Enable the Kyverno
  `reportsController` (currently disabled in `apps/15-kyverno.yaml`) so the
  PolicyReports are queryable while you drive the drift to zero.
- **Validation:** apply to a scratch namespace; confirm a known-bad pod is
  rejected and every real workload still admits; then flip cluster-wide.
- **Blast radius:** **highest if flipped early** — Enforce blocks any
  non-conforming pod from scheduling, including a legitimate one you missed.
  Only flip after the report is clean; keep the per-namespace `enforce` rollout
  staged so one namespace can be reverted without the others.

---

## D. /dev/dri GPU device-plugin migration

- **Files:** `specs/cluster/manifests/media-poisoner/deployment.yaml`,
  `specs/cluster/manifests/games/` (both use a `/dev/dri` **hostPath**)
- **Control:** CIS K8s 5.2.4 (hostPath); 800-190 §4.5.2 (host resource exposure)
- **Change:** replace the `/dev/dri` hostPath mount with a GPU **device plugin**
  (e.g. the generic `k8s-dra-driver` / `intel-device-plugins` DRM resource) so
  the render node is a schedulable resource, not a raw host mount.
- **Validation:** the GPU workload still claims a render node and the poison/games
  compute path runs; on a Pi-only cluster the pod stays Pending (unchanged
  degradation contract).
- **Blast radius:** GPU workloads only; needs the device-plugin DaemonSet vetted
  against amdgpu/i915/nouveau (vendor-agnostic, matching today's behaviour).

---

## E. Node Taints for sensitive tiers

- **Files:** node labelling in `specs/etc/keys-provision/provision.sh` (tier
  labels) + tolerations on the sensitive workloads
- **Control:** 800-53 AC-6/SC-7; CIS K8s 5.7 (workload isolation)
- **Change:** taint the **pki** node (`snapdragon.systems/pki=true:NoSchedule`)
  and any sensitive tier so only tolerating workloads (Vault, Casdoor,
  headscale) land there; general workloads are kept off the secrets node.
- **Validation:** the intended pods still schedule (they carry the toleration —
  Vault already tolerates `control-plane`); general pods do NOT land on the
  tainted node.
- **Blast radius:** scheduling — a missing toleration leaves a pod Pending.
  Add the taint AFTER confirming every pod that must run there tolerates it.

---

## F. local-path provisioner ClusterRole tightening

- **File:** `specs/cluster/manifests/local-path/local-path.yaml`
- **Control:** CIS K8s 5.1.3 (minimize wildcard/cluster-admin); 800-53 AC-6
- **Change:** scope the provisioner's ClusterRole down from any broad
  verbs/resources to the minimum it needs (PV/PVC/StorageClass/Node read +
  PV create + event create + the helper-pod create in its own namespace).
  Remove any `*` verb or resource.
- **Validation:** dynamic provisioning of a new PVC still works (helper pod runs,
  PV binds); existing volumes unaffected.
- **Blast radius:** storage provisioning — too-tight a role fails new PVC binds
  (existing PVs keep working). Test with a throwaway PVC before keeping it.

---

## G. akkoma image digest pin (could not pin in the safe PR)

- **Files:** `specs/cluster/manifests/akkoma/akkoma.yaml` (×2),
  `akkoma/admin-sync-job.yaml`, `test-runner/akkoma-peer.yaml` — all
  `git.akkoma.dev/akkomagang/akkoma:stable`; the custom build
  `akkoma/Dockerfile` already carries `AKKOMA_BASE=...@sha256:REPLACE_WITH_PINNED_AKKOMA_DIGEST`.
- **Control:** 800-190 §4.3 (image provenance); CIS Docker 4.x
- **Why deferred:** upstream publishes only the **moving** `stable`/`develop`
  tags — there is **no** per-release version tag to pin to. The correct pin is a
  `@sha256` digest, which must be **resolved from the live registry**
  (`crane digest git.akkoma.dev/akkomagang/akkoma:stable` or
  `docker buildx imagetools inspect`) for the chosen release — it cannot be
  fabricated in a manifest. Fill `REPLACE_WITH_PINNED_AKKOMA_DIGEST` in the
  Dockerfile and replace every `:stable` ref with the SAME digest in one change.
- **Validation:** the akkoma app + migrate Job + admin-sync + test peer all pull
  the digest and boot; the rebrand `sed` is digest-neutral (no hugmesh token
  in the image ref).
- **Blast radius:** federation (optional service). Pin all five refs to the
  identical digest atomically so the app and its Jobs run the same build.

---

## H. Cassandra auth + TLS — enable order (DARK overlay, flip live)

The hardening lives in `specs/cluster/manifests/cassandra-hardening/` and ships
**DARK**: nothing in the auto-synced ArgoCD tree references it, and the wired
ArgoCD app `apps/00a-cassandra-hardening.yaml` is **MANUAL-sync** pointing at the
**empty** sibling overlay (`manifests/cassandra-hardening-empty`, `resources: []`),
so it can never auto-apply (belt-and-braces, the same idiom as held PR #132). The
default Cassandra (`apps/00-cassandra.yaml`) stays `AllowAllAuthenticator` +
plaintext, byte-identical to today, until an operator runs the steps below.
**`cqlsh` allow/deny + GRANT enforcement was validated out-of-cluster** (a Cassandra
5.0.5 container with `PasswordAuthenticator`+`CassandraAuthorizer`: a least-privilege
role connects WITH its password and is denied WITHOUT, and a non-GRANTed keyspace
read is refused) — the per-cluster roll itself is what remains live-gated.

### Stage 1 — authentication

1. **Vault**: populate `secret/hugmesh/cassandra-admin` (`user`,`password`) and
   `secret/hugmesh/cassandra-app-creds` (`admin-bff`,`pki-gateway`,`be-gateway`,
   `fe-gateway`,`superadmin-gateway`,`federation`) — e.g. `openssl rand -base64 24`
   per key (wire into `gen-cluster-secrets`).
2. Flip `apps/00a-cassandra-hardening.yaml` `source.path` →
   `specs/cluster/manifests/cassandra-hardening` and **manually sync** it, OR apply
   the overlay directly. ESO materializes `cassandra-admin` + `cassandra-app-creds`.
3. Merge the **Stage 1** values diff from
   `manifests/cassandra-hardening/cassandra-values-overlay.yaml` into
   `apps/00-cassandra.yaml` (rotate `dbUser` onto `cassandra-admin`; set
   `CASSANDRA_AUTHENTICATOR=PasswordAuthenticator` + `CASSANDRA_AUTHORIZER=
   CassandraAuthorizer` via `extraEnvVars`). Let the StatefulSet roll — it now
   starts WITH auth and the default superuser password is rotated.
4. Run the `cassandra-bootstrap-roles` Job → 6 least-privilege roles + GRANTs.
   `CassandraAuthorizer` is **deny-by-default**, so until GRANTs land a role can
   authenticate but read/write **nothing** — fail CLOSED.
5. Apply the **consumer env** from `client-credentials-patch.md` (each consumer gets
   its OWN role's `CASSANDRA_USER`/`CASSANDRA_PASSWORD` from `cassandra-app-creds`)
   and roll the 6 consumers (admin-bff, federation, 4 gateways).

### Stage 2 — TLS (follows Stage 1)

6. Apply the `cassandra` Vault-PKI role (`cassandra-pki-role.patch.txt` → add to the
   `vault-pki-init` for-app loop) and re-run the idempotent `vault-pki-init` Job.
7. Apply `cassandra-tls-externalsecret.yaml` (materializes `cassandra-mtls`) and run
   `cassandra-tls-keystore-builder` (PEM→JKS → `cassandra-tls-stores` +
   `cassandra-tls-passwords`).
8. Merge the **Stage 2** `tls:` values (`internodeEncryption: all`,
   `clientEncryption: true`, `existingSecret: cassandra-tls-stores`,
   `passwordsSecret: cassandra-tls-passwords`) into `apps/00-cassandra.yaml`; roll.
   `clientEncryption` leaves `require_client_auth` optional, so a not-yet-TLS client
   is not instantly severed — flip consumers (`CASSANDRA_SSL=true` + truststore;
   `CASSANDRA_TLS_ENABLED=true` on the bootstrap Job), confirm, then tighten to
   required.

**Rollback:** revert the values merge on `apps/00-cassandra.yaml` (back to no
authenticator / plaintext) and re-point `apps/00a-cassandra-hardening.yaml` at the
empty overlay; the overlay objects are passive (Secrets/Jobs) and harmless if left.
