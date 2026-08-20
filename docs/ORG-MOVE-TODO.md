# The HugMesh GitHub org move — LANDED 2026-08-12

**Status: DONE.** The primary org is **`hugmesh`** (created as `hugmesh-net`, then
renamed in GitHub settings — same org id). Every URL in this repo points at
`github.com/hugmesh/...`, all 40 repos exist there with content (verified
per-repo via the API), and the pre-rebrand org was left in place permanently as a
secondary copy rather than renamed or deleted — so no redirect grace period was
ever load-bearing and nothing here is waiting on a browser action.

This file survives as the pointer that the `TODO(org-move)` comments elsewhere in
the tree refer to. The step-by-step rename procedure it used to carry described a
plan that was NOT the one executed (a rename of the old org), so it is gone rather
than reworded — a procedure for a move that did not happen is worse than no
procedure.

Verify the current state at any time with:

```sh
env -u GH_TOKEN gh repo list hugmesh --limit 200 --json name,defaultBranchRef
```

## Still open

* **In-cluster GitLab pull-mirrors** (`scripts/gitlab-mirror-org.sh`) import from
  `github.com/<org>/…` and are what actually feeds CI. Re-point them if any
  mirror still names an old source; nothing in this repo can verify the GitLab
  side from here.
* **GitLab runner tag registration.** The CI runner tag is `hugmesh-x86`
  throughout this tree; whether the runner is registered under that tag on the
  GitLab side is not checkable from this repo.
* **PATs scoped by org name** must be rotated if their scoping is by org rather
  than by repo.

## What is NOT covered here

The 2026-07 infra-migration plan tracked live RUNTIME identifiers the rebrand
left behind — Casdoor, k8s namespaces, Cassandra keyspaces, Postgres, Vault, the
registry. Those are runtime data, not GitHub URLs, and are out of scope for this
file. The keyspace defaults moved with the rename that added this note (see
`specs/cluster/manifests/cassandra-init/bootstrap-configmap.yaml`); an existing
mesh must reseed or copy keyspace-to-keyspace.
