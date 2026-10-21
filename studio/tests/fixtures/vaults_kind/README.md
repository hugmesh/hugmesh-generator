# Vault-on-kind fixtures for tests/test_vaults.py

Recorded LIVE, read-only, from `kind-hugmesh-local` on 2026-10-21 while the DevOps
lane was halted (no secret values involved):

* `sts-replicas-halted.txt` — `kubectl -n vault get statefulset vault -o jsonpath={.spec.replicas}`
* `halt-record-completed.json` — `kubectl -n devops get configmap hugmesh-kind-halt -o jsonpath={.data.halt\.json}`,
  trimmed to the scalar fields the Studio reads (the workload list is dropped).
* `pod-vault-0-notfound.stderr` — `kubectl -n vault get pod vault-0` on the halted lane.

HAND-BUILT in kubectl's output shape, because vault-0 did not exist that day
(the lane was halted) so a running pod could not be recorded:

* `pod-vault-0-ready.json`, `pod-vault-0-sealed.json`, `pod-vault-0-crashloop.json`
* `kv-list-*.json` — `vault kv list -format=json <path>` answers (paths only, no values)
* `kv-list-empty.stderr` — what `vault kv list` (table format) prints for an empty path

MEASURED 2026-10-21 against a throwaway `hashicorp/vault:1.21.4` dev container (the kind
lane's image) through the same in-pod shell the Studio uses:

* `kv-list-empty-json.stdout` — `vault kv list -format=json` on an empty path: exit 2, `{}`, empty stderr
* `kv-list-403.stderr` — the same call with a wrong token (URL scheme changed to the pod's https)
