# DB-hardening flips — operator runbook

Three flips are still open from the DB-hardening work. None of them is a code change and
none can be proven without a live cluster, which is why they are written down as a runbook
and a preflight instead of being done:

| Part | Flip | Where it lives | Ships |
|------|------|----------------|-------|
| A | `PG_TLS_ENABLED: "true"` on the nine dedicated Postgres Deployments | a one-line git change per DB | dark, `"false"` everywhere |
| B | Cassandra TLS (stage 2 of `CLUSTER-HARDENING-PLAN.md` §H) | `apps/00-cassandra.yaml` values + a manual-sync overlay | dark |
| C | Tier egress default-deny NetworkPolicies, per namespace, `devops` last | manual-sync overlay `manifests/networkpolicy-egress` | dark, renders zero objects |

**This document flips nothing.** Every command below that changes the cluster is one an
operator types on purpose. Re-measured on origin/main `702b590d` on 2026-10-14.

## 0. State, measured (the roadmap list was written around 2026-08-14)

| Claim | Verdict | Evidence |
|-------|---------|----------|
| "`PG_TLS_ENABLED` is `"false"` on all 9 DB deployments" | **true** | `specs/cluster/manifests/<dir>/deployment.yaml`, the `PG_TLS_ENABLED` env line: admin-bff-db:83, federation-db:83, forum-bff-db:83, mod-bff-db:82, user-bff-db:83, mesh-bff-db:82, wiki-bff-db:80, character-forge-bff-db:88, route-access/deployment.yaml:94. `tests/scripts/test-pg-tls-preflight.sh` derives the same nine from the tree. |
| "flip per DB only after each `<db>-mtls` ESO Secret materializes" | **true, and the reason is sharper than the docs say** | every Deployment mounts the Secret with `optional: true` and runs `strategy: Recreate` (e.g. admin-bff-db/deployment.yaml:33,126-131). A flip before the Secret exists starts Postgres with `ssl_cert_file` on an empty directory: it exits, and the old pod is already gone. The DB is down until the flip is reverted in git. |
| the ESO objects exist | **true for all nine** | `external-secrets/pki-externalsecrets.yaml` holds a `VaultDynamicSecret` + `ExternalSecret` per DB; `vault-pki/pki-init-configmap.yaml` has the nine issuing roles. Whether they are *Ready on a given cluster* is exactly what the preflight asks. |
| "Cassandra auth ships ON" | **true** | `apps/00-cassandra.yaml:53` `dbUser.existingSecret: cassandra-admin`; roles from `apps/00b-cassandra-init.yaml`. `CLUSTER-HARDENING-PLAN.md` §H used to say the opposite ("stays AllowAllAuthenticator"); corrected in the same change. |
| "only TLS stage 2 is open" | **true** | `apps/00a-cassandra-hardening.yaml:53` sources `cassandra-hardening-empty` (`resources: []`), manual sync. `bootstrap-job.yaml:74` `CASSANDRA_TLS_ENABLED: "false"`. See part B for what the tree does not contain. |
| "tier-egress ... manual-sync with an overlay whose `resources: []` renders zero objects" | **true** | `apps/08a-networkpolicy-egress.yaml` has no `automated:` block; `manifests/networkpolicy-egress/kustomization.yaml` `resources: []`; `kubectl kustomize` of it prints nothing. |
| "per-namespace staged enablement with the devops namespace last" | **true, but the documented enable step could not work** | The overlay header said to uncomment `- ../networkpolicy/tier-egress.yaml`. kustomize's default load restrictor rejects that (`security; file ... is not in or below ...`), and nothing in the tree sets ArgoCD's `kustomize.buildOptions`. Replaced by `scripts/netpol-egress-scope.py` (part C). |

Stale text found and corrected on the way: `POSTGRES-HARDENING.md` said "six DB pods"; the
`db-egress.yaml` and `tier-egress.yaml` comments said `db-egress.yaml` ships through the
auto-sync app (it was moved out on 2026-09-09 after one commit, PR #325, and is enabled by
nobody today, so the six Postgres pods are default-allow on Egress until part C).

## A. Postgres in-cluster TLS (`PG_TLS_ENABLED`)

### A.1 What the flip does, and what it does not

`entrypoint/pg-tls-entrypoint.sh` appends `-c ssl=on -c ssl_cert_file=/etc/postgres-tls/tls.crt
-c ssl_key_file=/etc/postgres-tls/tls.key` when the env is `"true"`. Server `ssl=on` still
**accepts plaintext** `host` connections, so no consumer breaks and no consumer URL changes
in this step. Tightening consumers to `sslMode=require` and `pg_hba` to `hostssl` is a
separate, later change (A.6). What the flip costs is **one Recreate restart per DB**: the
database is unreachable for roughly the time Postgres takes to start (tens of seconds), and
its consumers' connection pools must reconnect.

### A.2 How a flip is made (and how it is not)

The DB Applications (`apps/06`, `28`, `30`, `32`, `34*`, `38*`; all in namespace `devops`)
are `automated: { prune: true, selfHeal: true }` against `main`. So:

* The flip is a **git change** to the literal in `deployment.yaml`, merged to `main`.
* `kubectl set env` / `kubectl edit` is **reverted by selfHeal** within seconds. Do not use
  it, except in the emergency below.
* **One DB per change.** Two flips in one merge would restart two databases at once.

### A.3 Order

Lowest blast radius first; the two on the sign-in path late; `route-access-db` last
because every gateway reads it. The order is a judgement, not a measurement.
`scripts/pg-tls-preflight.sh --list` prints it, and `tests/scripts/test-pg-tls-preflight.sh`
keeps that table equal to the manifests.

| # | DB (= ArgoCD app) | kustomize dir | namespace | consumers (Deployments) | why here |
|---|-------------------|---------------|-----------|-------------------------|----------|
| 1 | `wiki-bff-db` | `wiki-bff-db` | hugmesh-backend | hugmesh-wiki-bff-api | added late (ArgoCD wave 2), off the sign-in path: the rehearsal |
| 2 | `mesh-bff-db` | `mesh-bff-db` | hugmesh-backend | hugmesh-mesh-bff-api | same |
| 3 | `character-forge-bff-db` | `character-forge-bff-db` | hugmesh-backend | hugmesh-character-forge-bff-api | same |
| 4 | `forum-bff-db` | `forum-bff-db` | hugmesh-backend | hugmesh-forum-bff-api | user-visible, not sign-in |
| 5 | `mod-bff-db` | `mod-bff-db` | hugmesh-backend | hugmesh-mod-bff-api | moderation only |
| 6 | `user-bff-db` | `user-bff-db` | hugmesh-backend | hugmesh-user-bff-api | on the sign-in path (`/bff/internal/accounts/ensure`) |
| 7 | `federation-db` | `federation-db` | hugmesh-backend | hugmesh-federation-api; Job `federation-modules-gate` (PostSync, `PGHOST=federation-db`) | module manifest + overrides |
| 8 | `admin-bff-db` | `admin-bff-db` | hugmesh-backend | hugmesh-admin-bff-api | accounts, sessions, grants: sign-in path |
| 9 | `route-access-db` | **`route-access`** | **hugmesh-pki** | hugmesh-admin-bff-api (writer), hugmesh-pki-gateway, hugmesh-superadmin-gateway, hugmesh-be-gateway, hugmesh-fe-gateway | every gateway reads `route_access`; last, and not before 1-8 are quiet |

Do not start unless: ESO and Vault are healthy, the cluster is otherwise quiet (no rollout in
flight, no `networkpolicy-egress` cutover in progress), and you have time to watch each DB for
a few minutes. Nothing in part A depends on part B or C; do not interleave them.

### A.4 Once, before DB 1

```bash
# a clean checkout of main, and a cluster you mean to touch
git fetch origin && git switch --detach origin/main
kubectl config current-context
kubectl -n devops get applications                       # the nine DB apps Synced/Healthy
scripts/pg-tls-preflight.sh --list | while read -r db ns; do kubectl -n "$ns" get externalsecret "$db-mtls"; done
#                                                        # nine rows, each Ready; do not grep -mtls across the
#                                                        # cluster, 22 ExternalSecrets carry that suffix
# the preflight below says which one is not
scripts/pg-tls-preflight.sh                              # all nine, read-only
```

A red `external-secrets-config` Application is **not** by itself a reason to stop (it has
carried unrelated `SecretSyncedError`s, see issue #352); the preflight reads the nine
`<db>-mtls` objects directly, which is the question that matters.

### A.5 Per DB (repeat for rows 1 to 9, in order)

```bash
# --- set the row, e.g. row 1 -------------------------------------------------------------
DB=wiki-bff-db; DIR=wiki-bff-db; NS=hugmesh-backend; CONSUMER=hugmesh-wiki-bff-api; CNS=hugmesh-backend
# row 9 is:  DB=route-access-db; DIR=route-access; NS=hugmesh-pki; CONSUMER=hugmesh-admin-bff-api; CNS=hugmesh-backend
#            and ALSO watch the four gateways (pki + superadmin in hugmesh-pki, be, fe):
#            kubectl -n hugmesh-pki get deploy; kubectl -n hugmesh-backend get deploy; kubectl -n hugmesh-frontend get deploy

# 1. PREFLIGHT. Must print READY and exit 0. Anything else: stop, do not flip.
scripts/pg-tls-preflight.sh --db "$DB"
#    exit 1 = a check failed (the line says which), 3 = openssl missing (install it, re-run)

# 2. BASELINE. The DB is 1/1 and its consumer is healthy BEFORE you touch it.
kubectl -n "$NS" get deploy "$DB"; kubectl -n "$CNS" get deploy "$CONSUMER"
kubectl -n "$CNS" logs deploy/"$CONSUMER" --since=10m | grep -ciE 'too many connections|connection refused|Failed to obtain R2DBC'
#    that count should already be 0; if not, fix that first

# 3. (recommended) a logical dump to your workstation (it holds the DB's data: keep it
#    private and delete it when the soak is over). The PVC is reused by the Recreate
#    restart, so this is insurance against a surprise, not a step the flip needs.
kubectl -n "$NS" exec deploy/"$DB" -- sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > "$DB-pre-tls.dump"

# 4. THE CHANGE. One line, one file, a branch, a pull request. Merge it yourself.
git switch -c "ops/pg-tls-$DB" origin/main
sed -i 's/{ name: PG_TLS_ENABLED, value: "false" }/{ name: PG_TLS_ENABLED, value: "true" }/' \
  "specs/cluster/manifests/$DIR/deployment.yaml"
git diff --numstat                      # must print exactly:  1  1  specs/cluster/manifests/<dir>/deployment.yaml
git commit -am "$DB: serve TLS (PG_TLS_ENABLED=true)"
git push -u origin "ops/pg-tls-$DB"     # then open the PR and merge it
MERGE_TIME="$(date -u +%FT%TZ)"

# 5. SYNC. selfHeal picks the merge up on its own; this just does not wait for the poll.
kubectl -n devops annotate application "$DB" argocd.argoproj.io/refresh=hard --overwrite
kubectl -n devops get application "$DB" -o jsonpath='{.status.sync.status} {.status.health.status} {.status.sync.revision}{"\n"}'
#    want:  Synced Healthy <the merge commit>
kubectl -n "$NS" rollout status deployment/"$DB" --timeout=240s

# 6. POST-FLIP CHECK. Gate is "true", 1/1 ready, the wrapper logged ssl=on, `show ssl` = on.
scripts/pg-tls-preflight.sh --post --db "$DB"

# 7. CONSUMERS. Their pools reconnect on their own; the errors below should stop within a
#    minute or two of the restart and then stay at zero.
kubectl -n "$CNS" rollout status deployment/"$CONSUMER" --timeout=120s
kubectl -n "$CNS" logs deploy/"$CONSUMER" --since-time="$MERGE_TIME" | grep -ciE 'too many connections|connection refused|Failed to obtain R2DBC'
#    still failing after ~5 minutes: kubectl -n "$CNS" rollout restart deployment/"$CONSUMER"

# 8. SOAK before the next row (a judgement: a few minutes for rows 1-5, longer for 6-9).
```

`pg_stat_ssl` will show `ssl = f` for every consumer connection after the flip. That is
expected: the consumers have not been told to negotiate TLS (A.6).

**Rollback (any step).** Revert the pull request and let ArgoCD sync it; the Recreate restart
returns the DB to `ssl=off` on the same PVC. Nothing in the data directory changed.

```bash
git switch -c "ops/pg-tls-$DB-revert" origin/main && git revert --no-edit <flip-commit>   # then PR + merge
# a DB that is crash-looping tells you why:
kubectl -n "$NS" logs deploy/"$DB" --previous | tail -20
#   could not load server certificate file  -> the Secret is absent/empty (the preflight would have said)
#   private key file ... has group or world access -> fsGroup is not 70 on the pod
```

*Emergency only, DB down and the merge not yet possible:* stop selfHeal on that one app so a
manual edit survives, put the gate back, and re-enable auto-sync as soon as the revert has
merged. The root app (`hugmesh-root`, also selfHeal) may re-assert the Application's
`syncPolicy` underneath you; watch for that.

```bash
kubectl -n devops patch application "$DB" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n "$NS" set env deployment/"$DB" PG_TLS_ENABLED=false
# ... merge the revert, then:
kubectl -n devops patch application "$DB" --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

### A.6 After all nine: not part of this flip

* **Consumer `sslMode=require`** (R2DBC) / `sslmode=require` (JDBC) in each `*-api`
  Deployment, and **`pg_hba` to `hostssl`**, one consumer at a time. Server-only TLS with
  `require` encrypts but does not authenticate the server; `verify-full` needs the cluster CA
  in each consumer's truststore, which is more work and is not scoped here.
* **Certificate reload.** The ESO `ExternalSecret` refreshes every 168h and the Vault role
  issues 720h certificates, but Postgres reads `ssl_cert_file` at start (or on `pg_ctl reload`).
  Nothing in the tree reloads or restarts a DB when the Secret rotates (no reloader
  annotation anywhere in `specs/cluster`). Before a certificate gets near expiry, `kubectl -n
  "$NS" rollout restart deployment/"$DB"` (or reload). `scripts/pg-tls-preflight.sh --min-days N`
  shows the Secret's remaining life, not the life of the certificate Postgres is actually
  serving. A `pg-tls-rotation` follow-up is warranted; it is not written.
* Out of scope by the original design: casdoor / casdoor-games Postgres, akkoma-db, the phpBB
  Postgres and observability Postgres have no dark-TLS certificate mounted.

## B. Cassandra TLS (stage 2)

Stage 1 (authentication) is live; this is TLS only. The ordered steps are in
`CLUSTER-HARDENING-PLAN.md` §H "Stage 2". What follows is what to check first and what the
tree does **not** contain. This part needs a live cluster and was not exercised here.

1. **Vault role.** Apply `cassandra-hardening/cassandra-pki-role.patch.txt` to
   `vault-pki/pki-init-configmap.yaml` and re-run the idempotent `vault-pki-init` Job
   (a failed PostSync hook is not re-run by a re-bootstrap; patch `.operation`). The SAN
   guard `tests/scripts/test-pki-role-san-coverage.sh` should stay green.
2. **Point the manual-sync app at the real overlay**: `apps/00a-cassandra-hardening.yaml`
   `source.path` from `cassandra-hardening-empty` to `cassandra-hardening`, then
   `kubectl -n devops patch application cassandra-hardening --type merge -p '{"operation":{"sync":{"revision":"main"}}}'`.
   Wait for `kubectl -n hugmesh-pki get externalsecret cassandra-mtls` Ready and the
   `cassandra-tls-keystore-builder` Job to produce `cassandra-tls-stores` and
   `cassandra-tls-passwords`.
3. **Check the server flag before you flip.** §H says `clientEncryption` "leaves
   `require_client_auth` optional, so a not-yet-TLS client is not instantly severed".
   `require_client_auth` is mutual TLS; whether *plaintext* clients are still accepted is the
   separate `optional` flag in `client_encryption_options`. Read it off the rendered chart
   (`helm template` of bitnami/cassandra 12.3.11 with the stage-2 values, or `kubectl -n
   hugmesh-pki exec cassandra-0 -- grep -A8 client_encryption_options /opt/bitnami/cassandra/conf/cassandra.yaml`
   after the roll). **Unverified.** If plaintext is refused, step 4 is not optional and every
   consumer is down between the roll and its own change.
4. **Consumers.** I found no Cassandra TLS client wiring for the gateways, admin-bff or
   federation-api in `specs/cluster/manifests` (only the bootstrap Job has a switch,
   `CASSANDRA_TLS_ENABLED`, `bootstrap-job.yaml:74`, and a truststore mount). The gateways are
   Helm charts in other repositories. So "flip every client" is **not config-only from this
   repo**; each consumer needs its driver's SSL settings and a truststore built from the
   cluster CA before the server side moves.
5. **Roll** `apps/00-cassandra.yaml` with the stage-2 `tls:` values
   (`cassandra-hardening/cassandra-values-overlay.yaml`). `internodeEncryption: all` on a
   single replica is harmless; `clientEncryption: true` is the breaking half.
6. Verify, then rollback is the reverse: revert the values merge and re-point 00a at the
   empty overlay.

Because steps 3 and 4 are open, Cassandra TLS is **not ready to flip** and there is no
preflight for it here; writing one before the consumer wiring exists would only certify the
half that is already in the tree.

## C. Egress default-deny, one namespace at a time, `devops` last

### C.1 What exists

`manifests/networkpolicy/tier-egress.yaml` holds six `NetworkPolicy` objects:
`tier-egress` in each of `hugmesh-frontend`, `hugmesh-backend`, `hugmesh-pki`, `hugmesh-games`
and `devops`, plus `egress-proxy-egress` in `hugmesh-backend`.
`manifests/networkpolicy/db-egress.yaml` holds six per-DB-pod DNS-only locks: five in
`hugmesh-backend` (admin-bff, mod-bff, user-bff, federation, forum-bff) and one in
`hugmesh-pki` (route-access-db). Neither file is in the auto-sync kustomization, and the
overlay `manifests/networkpolicy-egress` lists nothing. wiki-bff-db, mesh-bff-db and
character-forge-bff-db are selected by the backend `tier-egress`, not by `db-egress`.

Until the backend and pki namespaces are cut over **with** `--with-db-egress`, the six
Postgres pods are default-allow on Egress, and Cassandra stays default-allow regardless
(its allow-set cannot be derived from the tree; see the head of `db-egress.yaml`).

### C.2 Order and why

1. `hugmesh-games` (leaf)
2. `hugmesh-frontend`
3. `hugmesh-backend` **with** `--with-db-egress`, so the five DB locks and `egress-proxy-egress` land with it
4. `hugmesh-pki` **with** `--with-db-egress` (gateways, Casdoor, Cassandra, route-access-db)
5. `devops` **last**: it carries ArgoCD itself. A wrong allow there stops ArgoCD reconciling,
   and no GitOps change can undo that; only `kubectl` can.

Stop between namespaces. Never carve two in one change. The apiserver rule in the `devops`
block is the RFC1918 + tailnet superset on 6443; the plan file asks you to tighten it to the
real control-plane network before enabling. If ArgoCD reaches the git repo over the tailnet
rather than public 443, add that allow first (the block's own comment says so).

### C.3 Per namespace

```bash
NS=hugmesh-games      # then hugmesh-frontend, hugmesh-backend, hugmesh-pki, devops
git fetch origin && git switch -c "ops/egress-$NS" origin/main

# 1. carve ONE namespace into the overlay directory (the old "uncomment ../networkpolicy/..."
#    step fails under kustomize's load restrictor). Add --with-db-egress for backend and pki.
scripts/netpol-egress-scope.py --list
scripts/netpol-egress-scope.py "$NS" [--with-db-egress]

# 2. list the printed file(s) under `resources:` in
#    specs/cluster/manifests/networkpolicy-egress/kustomization.yaml, and prove it renders
kubectl kustomize specs/cluster/manifests/networkpolicy-egress | grep -E '^  (name|namespace):'

# 3. commit the carved file(s) and the kustomization edit, PR, merge.

# 4. MANUAL sync (the app has no automated block)
kubectl -n devops patch application networkpolicy-egress --type merge \
  -p '{"operation":{"sync":{"revision":"main","prune":true}}}'
kubectl -n devops get application networkpolicy-egress -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
kubectl -n "$NS" get networkpolicy

# 5. SMOKE, immediately. All of the following, for that namespace:
kubectl -n "$NS" get pods                                   # nothing newly NotReady / restarting
kubectl -n devops get applications                          # still Synced/Healthy; ArgoCD still reconciles
kubectl get externalsecret -A                               # ESO still reaches Vault (known reds only)
#   DNS from a pod in the namespace that has a resolver tool (image-dependent):
kubectl -n "$NS" exec deploy/<some-deploy> -- nslookup kubernetes.default.svc.cluster.local
#   backend: each BFF reaches its DB; pki: every gateway hop and sign-in still works:
kubectl -n hugmesh-backend logs deploy/hugmesh-user-bff-api --since=3m | grep -ciE 'timed out|connection refused|UnknownHost'
```

For `devops` add the canary that ArgoCD can still do its job *after* the policy is in:

```bash
kubectl -n devops annotate application networkpolicy-egress argocd.argoproj.io/refresh=hard --overwrite
# within ~2 minutes the app must refresh and compare against git. If it does not, ArgoCD is
# wedged and only the next command recovers it.
```

**Rollback, and the break-glass that bypasses ArgoCD:**

```bash
kubectl -n "$NS" delete networkpolicy tier-egress               # frees Egress immediately
kubectl -n hugmesh-backend delete networkpolicy egress-proxy-egress   # backend only
kubectl -n hugmesh-backend delete networkpolicy db-egress-admin-bff-db   # one DB lock; names from `get networkpolicy`
```

then remove the line from the overlay's `kustomization.yaml`, merge, and repeat step 4 (it
carries `prune: true`; `apps/08a` has no `prune` sync option of its own, so a plain sync of the
shortened list would leave the policy in the cluster as OutOfSync), so Git and the cluster
agree again. Keep a `kubectl` context that reaches the apiserver directly (not via a
route that goes through anything in the namespace you are cutting) open for the whole
operation, and do the `devops` step from a shell that does not need ArgoCD to be working.

## D. What was and was not verified

Verified offline on this workstation (no cluster, no root, no image build):

* the nine-DB table, namespaces, Secret names, `fsGroup: 70`, `optional: true`, `Recreate`,
  the ESO and Vault-role pairing: `bash tests/scripts/test-pg-tls-preflight.sh`
* the preflight's jsonpath against the **real** kubectl evaluator (`kubectl label --local`) on
  all nine rendered manifests, and the preflight's behaviour against a stub kubectl with real
  openssl certificates (missing Secret, ES not Ready, expiring cert, wrong SAN, key mismatch,
  foreign CA, and so on), with a mutation battery
* the egress carve renders under kustomize's default restrictor, covers `tier-egress.yaml`
  exactly once, and the shipped overlay still renders zero objects:
  `bash tests/scripts/test-netpol-egress-scope.sh`

**Not verified, because it needs a live cluster or a secret:** that any `<db>-mtls` Secret
materializes on a given mesh; that Postgres 16 serves TLS from those Secrets (`CLUSTER-
HARDENING-PLAN`/`POSTGRES-HARDENING` record a live container verify of the `fsGroup` fix; I did
not repeat it); consumer behaviour across the Recreate restart; the Cassandra
`client_encryption_options.optional` question (B.3) and the consumer-side TLS wiring (B.4);
the ArgoCD `kustomize.buildOptions` setting on the real cluster (if it already sets
`--load-restrictor LoadRestrictionsNone` the old overlay step would have rendered, but it
would still have enabled all five namespaces at once); every egress smoke test.
