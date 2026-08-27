# Running-service stats, and which versions are running

**The operator ask:** *"cannot find … how to view stats on those running services if
present, which versions of those services are running."*

**The short answer, in two halves.**

1. **Stats exist and are unfindable by design.** The Workload Console is real, rich, and
   ships behind **four independent gates**, every one of which defaults shut. Opening one
   changes nothing an operator can see. §1 maps all four with citations; §2 is the exact
   sequence to open them.
2. **Versions do not exist as a usable surface at all.** The only version signal anywhere
   in any repo is `containers[].image` on the per-pod views — and on this tree **31 of 31
   first-party image references are the moving tag `:main`, 0 are digest-pinned**, so that
   string is byte-identical for the whole first-party fleet and distinguishes no two
   builds. The field that would answer the question — the resolved digest in
   `.status.containerStatuses[].imageID` — is dropped by the shipped projection. §3 is the
   contract that fixes it; §4 is the cross-repo change that would serve it.

> **Nothing in this document was demonstrated end to end.** There is no cluster on this
> box: `docker ps -q` returns zero containers and the `kind-hugmesh-local` kubectl context
> refuses connection (`dial tcp 127.0.0.1:44977: connect: connection refused`). Every claim
> below is derived from the shipped manifests, the shipped admin-bff source, and the guard
> in `tests/workload-console/test-console-posture-and-inventory.sh`. **No stats screen and
> no version list has been observed rendering.**

---

## 1. The four gates

`docs/OPTIONAL-SERVICES.md` §7.2 calls these "three OFFs". The third is really **two**:
the DB master flag and the per-admin grant are separate rows, in separate tables, flipped
by separate endpoints, with separate lifetimes — an operator who flips the flag and stops
sees exactly as much as one who flipped nothing. They are counted separately here and by
the posture tool.

| # | Gate | Where it lives | Default | What you see while it is shut |
|---|------|----------------|---------|-------------------------------|
| 1 | **Generator gate** — `WORKLOAD_CONSOLE_ENABLED` + the two route-access rows | `specs/cluster/manifests/admin-bff-api/workload-console-patch.yaml` (env), its one `- path:` line in `specs/cluster/manifests/admin-bff-api/kustomization.yaml`, and the two INSERT tuples in `specs/cluster/manifests/route-access/initdb/20-schema.sql` | **shut** — the `workloadConsole` slug is `default: off` (`specs/cluster/optional-services.yaml`) and is **not** part of `all` | The gateway **404s** the whole `/bff/{admin,superadmin}/workloads/**` prefix. A direct in-cluster call 404s too (`WorkloadAuthorizationFilter` denies a disabled prefix). |
| 2 | **k8s seam** — `WORKLOAD_CONSOLE_K8S_ENABLED` + both SA tokens mounted | same overlay — and the mount is **three separate facts** the posture tool checks separately, because they fail separately: the `WORKLOAD_CONSOLE_K8S_{READ,MUTATE}_TOKEN_FILE` env var that *names* the token file, the `volumeMounts` entry that *delivers* it (its `mountPath` is the file's **parent directory**, so a text search for the full path can only ever find the env var), and the `volumes:` entry naming a Secret that is really minted — plus `specs/cluster/apps/14-workload-console-rbac.yaml` and `specs/cluster/manifests/workload-console-rbac/token-secrets.yaml` which mint the Secrets | **shut** — same slug prunes all of it | The fail-closed `NoopWorkloadClient` **503s every call**; no k8s API is ever dialed. Both volumes are `optional: true`, so a missing Secret mounts **empty and the pod starts happily** — this failure is silent. |
| 3 | **DB master flag** — `workload_console_config.admin_enabled` (and `dangerous_tier_enabled`) | *cross-repo:* `hugmesh-admin-bff-api`, `src/main/resources/db/changelog/110-workload-console-grants.xml`; one row per domain plus a `' global'` sentinel | **false** | Every workloads request is refused **before** any k8s call. A fully wired cluster shows **nobody anything**. |
| 4 | **Per-admin TTL'd grant** — an active `workload_console_grant` lease | *cross-repo:* same changelog; `access_level` is `READ_ONLY` by CHECK, `log_access` a separate opt-in defaulting false, `expires_at` NOT NULL (~24 h) with an expiry sweep | **no rows** | The individual admin sees nothing, and **returns to dark automatically** when the lease expires. |

> **What the posture tool actually measures, and what it used to.** A review found the
> first version scanning the overlay's *text*, which was wrong three ways and every one
> of them printed `LIT` on a console that 503s: the token mount was never measured (only
> the env var that names it), a **later duplicate** `env` entry was invisible (a line
> scanner takes the first, the kubelet takes the **last**), and an overlay whose
> `metadata.name` matched no resource looked fine — measured with `kubectl kustomize`,
> that build **fails outright** ("no resource matches strategic merge patch"), so ArgoCD
> cannot sync the admin-bff at all. All three are now structural checks on a real YAML
> load with their own reason lines, and PyYAML is a hard dependency of the tool.
>
> Closing those three surfaced a fourth of the same family, and it is the worst of them
> because nothing anywhere goes red: if the overlay patches the right Deployment but a
> container **name** the Deployment does not have, `kustomize build` succeeds and ArgoCD
> syncs a healthy admin-bff. A strategic merge on `containers` is keyed on `name`, so an
> unmatched name is not an override — measured here with `kubectl kustomize`, it **adds a
> second container** carrying every `WORKLOAD_CONSOLE_*` var, and the real
> `hugmesh-admin-bff-api` container renders with **none** of them. Every text-level fact
> (the env is there, the mounts are there, the volumes are there) is satisfied by that
> render. The tool compares the overlay's container name against the Deployment the
> kustomization actually builds, and says so.
>
> Not measured: env delivered via `envFrom` (a ConfigMap or Secret reference) rather than
> an inline `env:` entry, and any drift between a cluster and the tree it was built from —
> there is no live mode, so a manual `kubectl set env` is invisible.

Gates 1 and 2 are pruned together by `gate_optional_services` — the `workloadConsole)`
case body in **both** `build-rpi5-stage4.sh` and `build-x86-host-stage4.sh`. Gates 3 and 4
live only in Postgres: nothing in this repo and nothing `kubectl` can reach will tell you
their state.

### Reading your own posture

```sh
# gates 1+2, measured from a rendered cluster tree (the EFFECT of the build, not its intent)
scripts/workload-console-posture.sh --tree=/path/to/rendered/specs/cluster

# all four, once you have measured the two runtime gates in Postgres
scripts/workload-console-posture.sh --tree=… --db-admin-enabled=true --active-grants=1
```

An unmeasured runtime gate reports `UNKNOWN` and the verdict stays `DARK`. That is
deliberate: an unproven gate is not an open one, and the friendlier default would report a
console nobody can see. The report **counts and names every** gate that is not open —
"2 of 4 gates are not open" — so selecting the slug never reads as "one step left".

---

## 2. What an operator must actually do today

Each step alone is insufficient. Steps 1–2 are one build; steps 3–4 are runtime and need a
SUPERADMIN with step-up.

1. **Select the slug at build time.** `OPTIONAL_SERVICES="… workloadConsole"` — it is *not*
   in `all`, and it is deliberately excluded from the CRD live-flip enum
   (`docs/OPTIONAL-SERVICES.md` §7.1), so it is **build-determined**: there is no runtime
   switch. Flash / sync. This opens **gates 1 and 2 together**.
2. **Verify the wiring before granting anyone anything.**
   ```sh
   kubectl -n hugmesh-backend get secret workload-console-read-token \
     -o jsonpath='{.data.token}' | head -c 8      # non-empty => the token was minted
   kubectl -n hugmesh-backend get deploy hugmesh-admin-bff-api -o yaml \
     | grep -c workload-console                    # mounts + volumes present
   ```
   `apps/14` and `apps/31` are separate ArgoCD Applications with **no sync-wave between
   them**, so a 503 here is most likely "you are ahead of the RBAC app's sync", not a bug.
3. **Flip the DB master flag** (gate 3), SUPERADMIN + step-up, per domain or the GLOBAL row:
   `PUT /bff/superadmin/workloads/config/{domain}` with
   `{"adminEnabled": true, "dangerousTierEnabled": false}`. Leave `dangerousTierEnabled`
   false: it is the global kill for exec / log-stream / mutations and applies **even to a
   superadmin**.
4. **Issue a TTL'd grant** (gate 4) per admin:
   `POST /bff/superadmin/workloads/grants` with
   `{"grantee": "...", "targetDomain": "...", "logAccess": false}`.

**Then, and only then, the stats surface is:**

| What | Endpoint |
|------|----------|
| pods in a namespace (phase, ready, restarts, node, containers) | `GET /bff/admin/workloads/pods/{namespace}` |
| one pod, redacted (labels, owner, service account) | `GET /bff/admin/workloads/pods/{namespace}/{name}` |
| **CPU / memory** | `GET /bff/admin/workloads/metrics/{namespace}` |
| events | `GET /bff/admin/workloads/events/{namespace}` |
| volumes / network | `GET /bff/admin/workloads/{storage,network}/{namespace}` |

**Darken in reverse:** let grants lapse or revoke them, flip the DB flags false, then
deselect the slug and rebuild. Any single step is already sufficient to go dark.

### Two caveats that will bite

* **`metrics/{namespace}` needs metrics-server.** `specs/cluster/apps/01-metrics-server.yaml`
  is in the app-of-apps, but **neither** kind profile in
  `specs/cluster/bootstrap/kind-local/bootstrap-kind.sh` applies it (nor `apps/14`), so on
  the kind lane the stats half is empty even with all four gates open. That is a fifth,
  undocumented gate for the stats half specifically, and it is *not* covered by the posture
  tool — the tool measures the console's four gates, not the cluster's metrics pipeline.
* **There is no fleet-wide view.** Every read above is **per namespace**. Seven namespaces
  are allowlisted (`WORKLOAD_CONSOLE_NAMESPACE_ALLOWLIST`), so "what is running" is seven
  calls whose results the operator merges by hand.

---

## 3. The missing surface: `fleet-inventory/v1`

**The defect, stated plainly.** `WorkloadDtos.ContainerSummary` (in `hugmesh-admin-bff-api`)
carries `String image`, populated in `Fabric8WorkloadClient` from `c.getImage()` — the
**pod spec's** image reference. On this tree every first-party image is
`registry.hugmesh.net/hugmesh/<repo>:main`. Measured over
`specs/cluster/manifests/*/kustomization.yaml`: **31 first-party refs, 31 on the moving tag
`main`, 0 digest-pinned.** The same measurement is recorded independently, and for an
unrelated reason, inside
`specs/cluster/manifests/workload-console-rbac/deploy-provenance-policy.yaml`, which had to
be narrowed from seven namespaces to one because *"every one of the 53 repo-managed
workloads in those tiers is tag-based (0 digest-pinned)"* and Kyverno was rejecting
ArgoCD's own syncs.

So the one version field the platform has says the same eleven characters for every
service, and answers the operator's question with no information whatsoever.

**What does answer it:** the pod's `.status.containerStatuses[].imageID`, the *resolved*
content digest of the image actually running. It requires **no new RBAC** — the shipped
read Role already grants `pods get/list/watch` — and it is exactly what the projection
drops.

`specs/cluster/contracts/fleet-inventory.v1.json` is the aggregate contract: one call,
every allowlisted namespace, one row per **workload** (not per pod), carrying

* `namespace`, `name` (the *top* controller, walked past the ReplicaSet), `kind`
* `replicasDesired` / `replicasReady` / `replicasUpdated`, `podsRunning` / `podsTotal`
* per container: `specImage`, `specTag`, **`resolvedDigest`** (`sha256:<64 hex>`) and
  `digestSource` (`pod-status` | `spec-digest` | `unavailable`)
* **`digestSkew`** — true when one workload's pods report **more than one** distinct
  resolved digest. Mid-rollout, a half-failed rollout, and a node that pulled a different
  build behind the same moving tag are **all invisible** today, because every pod's spec
  image string is identical.
* `versionKnown` — false when no pod reports a digest. A row whose version is unknown must
  *say* unknown; emitting the spec tag as "the version" is the defect this contract exists
  to prevent.
* `cpuMillicores` / `memoryBytes` — **nullable**, never `0`, when metrics-server is absent
  (see the kind caveat above; a `0` would read as an idle fleet).
* `buildRef` — git revision / semver, and it is `null` in v1 and expected to stay null:
  recovering it means reading OCI labels (`org.opencontainers.image.revision`) from Harbor,
  which needs a registry credential the read SA deliberately does not have. A consumer
  **must** render the digest when this is null rather than rendering nothing.

Every field is derivable from objects the shipped read Role already grants. The guard
asserts that coupling directly, and mutation-tests it by trimming `pods` out of a copy of
the Role and confirming the check goes red.

---

## 4. Cross-repo change specification (NOT applied here)

`/home/magus/Github/hugmesh-admin-bff-api` and `…-admin-ui` are **shared checkouts**. They
were read and **not modified**. The work below belongs there and is specified, not done.

### 4a. `hugmesh-admin-bff-api`

1. **Keep the resolved digest.** In `Fabric8WorkloadClient.containers(Pod)`, the loop
   already has the matching `ContainerStatus cs`. Add `cs.getImageID()`, normalised to the
   bare `sha256:…` form (fabric8 hands back `docker-pullable://repo@sha256:…` or
   `repo@sha256:…` depending on runtime), as a new `resolvedDigest` field on
   `WorkloadDtos.ContainerSummary`. **Additive only** — the DTO is a deliberate projection
   and a digest is not secret material, so this does not widen the redaction posture.
2. **Add the aggregate endpoint.** `GET /bff/admin/workloads/inventory` (own-domain,
   grant-gated exactly like `/pods/{namespace}`) and
   `GET /bff/superadmin/workloads/inventory` (cross-domain), returning
   `fleet-inventory/v1`. Implementation is a fan-out over
   `WORKLOAD_CONSOLE_NAMESPACE_ALLOWLIST` ∩ the caller's scope: list Deployments /
   StatefulSets / DaemonSets, list pods, group pods by top owner, and fold
   `containerStatuses[].imageID` per container name. `digestSkew` is
   `distinct(resolvedDigest) > 1`. A namespace whose read fails goes in `namespacesDenied`
   — **never** silently omitted.
3. **`servers` is already pinned.** `OpenApiConfig` sets
   `.servers(List.of(new Server().url("")))`, so the committed
   `src/main/resources/openapi/openapi.json` is stable under regeneration. That matters
   because this repo's BFFs rewrite `openapi.json` on every test run: a green run there
   proves the artefact was regenerated, not that the contract holds. **Pin `servers`
   before inverting any flag** — here it already is, so adding the endpoint is safe, but
   check it again if the config is ever touched.

### 4b. `hugmesh-admin-ui`

The console remote is a **hidden** federation tier (`hiddenModule`, mounted at
`/admin/workloads`), loaded only when the grant guard passes. The inventory view is one
table over `fleet-inventory/v1`. Two rendering rules are load-bearing:

* **Never render `specImage` as the version.** Render the short digest
  (`sha256:ab12cd34…`) with the full value on hover, and the tag as secondary context.
* **Surface `digestSkew` as a row-level warning**, not a footnote. It is the only signal
  that a rollout did not complete.

### 4c. Optional, and a separate decision

Digest-pinning the fleet (`newTag: main` → `digest: sha256:…` in the 31 kustomizations,
driven by CI) would make `specImage` a real version and let the deploy-provenance policy
widen back to all seven app tiers. It is a **large, independent** change with its own
rollout risk and is deliberately not proposed here. If it ever lands, the guard's measured
premise (§8 of the test) goes red **by design** — re-read this section rather than
relaxing the assertion.

---

## 5. What the guard proves, and what it does not

`tests/workload-console/test-console-posture-and-inventory.sh`.

**Proves:** the posture tool reports `LIT` only when all four gates are open (positive
control first, so a constant-`DARK` tool cannot pass); it reports `DARK` **naming and
counting every** shut gate under eight mutations of real production files — overlay
deleted, either env flipped to `false`, the kustomization `- path:` line dropped, the route
rows dropped by the builder's own `_opt_drop_rows`, the read token mount removed, the RBAC
Application removed, the token Secrets removed — each verified to have actually changed the
file first; that flipping one gate does not drag the other build-time gate down with it;
that an unmeasured runtime gate is `UNKNOWN` and never `OPEN`; that a comment-only mention
of a route pattern does **not** rescue gate 1 (the prune leaves prose behind, so a
grep-based check would be green on that exact tree); that **both** builders' real
`workloadConsole)` case bodies, executed against a sandbox, leave a tree the tool calls
dark; the structural shape of `fleet-inventory/v1`; the measured 31/0 moving-vs-pinned
premise; and that the shipped read Role still covers every read the contract needs
(mutation-controlled by trimming `pods` out of a copy).

**Does NOT prove:** that stats or versions render. No cluster exists on this box, no
gate 3 or gate 4 was ever opened against a real database, no `imageID` was ever read off a
real pod, and no controller serves `fleet-inventory/v1` in any repo. The tool measures a
**tree** and two **supplied** runtime values; it has no live mode and cannot read Postgres.
It also does not check metrics-server, so a `LIT` verdict does not promise the
`metrics/{namespace}` half returns anything.
