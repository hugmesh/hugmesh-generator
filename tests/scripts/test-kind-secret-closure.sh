#!/usr/bin/env bash
# test-kind-secret-closure.sh — EXECUTE kind_secret_closure.py against the real
# tree and against scratch trees carrying each defect it exists to catch.
#
# THE DEFECT THIS CATCHES, verbatim (hugmesh-generator#352). On the kind lane the
# ArgoCD Application `external-secrets-config` is Degraded, permanently, with six
# ExternalSecrets in SecretSyncedError. Four of them read Vault paths
# gen-cluster-secrets.sh never writes — akkoma-admin, tuwunel-admin,
# coturn-shared-secret, mesh-bff-casdoor-client — and none of the four was
# written down anywhere as expected. An app that is red for unexplained-but-normal
# reasons is an app nobody reads, which is precisely how #349's outage stayed
# invisible for two days.
#
# The exemption list inside the checker is the deliberate half: those four tiers
# really are deployed by no kind profile (0 pods, measured on hugmesh-local), and
# writing them down with a reason turns a permanent red into a reviewable list.
#
# Offline: python3 + PyYAML. No cluster, no kubectl, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CHECKER="${HERE}/kind_secret_closure.py"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required (refusing to skip)" >&2; exit 1; }
[ -f "${CHECKER}" ] || { echo "FATAL: ${CHECKER} missing" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A scratch tree is a COPY, so a mutation can never touch the real one.
scratch() {
  s_name="$1"
  s_dir="${WORK}/${s_name}"
  mkdir -p "${s_dir}/specs/cluster/manifests" "${s_dir}/scripts"
  cp -r "${REPO}/specs/cluster/manifests/external-secrets" "${s_dir}/specs/cluster/manifests/"
  cp "${REPO}/scripts/gen-cluster-secrets.sh" "${s_dir}/scripts/"
  echo "${s_dir}"
}
run_on() { python3 "${CHECKER}" --repo "$1" 2>&1; }
rc_on()  { python3 "${CHECKER}" --repo "$1" >/dev/null 2>&1; echo $?; }

# Produce a copy of the checker with ONE exemption DELETED — not renamed.
# Renaming leaves the entry in EXEMPT, so ANTI-ROT 1 fires ("nothing references
# it any more") and the test goes red for a reason unrelated to what it claims to
# measure. Measured on 2026-09-10: with the key renamed, a mutation that stopped
# stripping comments out of the seed SURVIVED, because the rename was carrying
# the assertion instead of the thing under test.
without_exemption() {
  python3 "${HERE}/_drop_exemption.py" "${CHECKER}" "$1" "$2"
}

echo "== 1. the real tree is closed =="
out="$(python3 "${CHECKER}" --repo "${REPO}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "exit 0 on the tree as committed" || bad "the committed tree is not closed: ${out}"
case "${out}" in *"is seeded"*) ok "reports what it checked";; *) bad "no summary line";; esac

echo "== 2. an ExternalSecret reading an unseeded path is caught =="
d="$(scratch unseeded)"
python3 - "${d}" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1])/"specs/cluster/manifests/external-secrets/sso-externalsecrets.yaml"
t=p.read_text()
t += ("\n---\napiVersion: external-secrets.io/v1beta1\nkind: ExternalSecret\n"
      "metadata:\n  name: invented-thing\n  namespace: hugmesh-backend\n"
      "spec:\n  data:\n    - secretKey: x\n      remoteRef: { key: hugmesh/never-seeded-anywhere, property: x }\n")
p.write_text(t)
PY
out="$(run_on "${d}")"; rc="$(rc_on "${d}")"
[ "${rc}" -eq 1 ] && ok "exit 1 on an unseeded reference" || bad "exit ${rc}, expected 1"
case "${out}" in *"hugmesh/never-seeded-anywhere"*) ok "names the path";; *) bad "does not name the path";; esac
case "${out}" in *"invented-thing"*) ok "names the ExternalSecret";; *) bad "does not name which ExternalSecret";; esac

echo "== 3. removing an exemption re-exposes the real gap =="
d="$(scratch noexempt)"
without_exemption "hugmesh/akkoma-admin" "${d}/checker.py" || bad "could not build the no-exemption checker"
out="$(python3 "${d}/checker.py" --repo "${REPO}" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && ok "exit 1 once akkoma-admin is no longer explained" || bad "exit ${rc}, expected 1 — the exemption is doing no work"
case "${out}" in *"hugmesh/akkoma-admin"*) ok "names the newly unexplained path";; *) bad "does not name it";; esac

echo "== 4. ANTI-ROT: an exemption nothing references any more =="
d="$(scratch stale)"
# Stop applying the coturn file: its exemption must now fail as stale.
python3 - "${d}" <<'PY'
import sys,pathlib,re
p=pathlib.Path(sys.argv[1])/"specs/cluster/manifests/external-secrets/kustomization.yaml"
t=p.read_text()
t=re.sub(r'^(\s*)- coturn-externalsecrets\.yaml', r'\1# - coturn-externalsecrets.yaml', t, flags=re.M)
p.write_text(t)
PY
out="$(run_on "${d}")"; rc="$(rc_on "${d}")"
[ "${rc}" -eq 1 ] && ok "exit 1 when an exemption stops matching" || bad "exit ${rc}, expected 1 — the list can rot"
case "${out}" in *"stale"*) ok "says the entry is stale";; *) bad "does not say stale";; esac
case "${out}" in *"coturn-shared-secret"*) ok "names the stale entry";; *) bad "does not name it";; esac

echo "== 5. ANTI-ROT: the seed starts writing an exempted path =="
d="$(scratch closed)"
printf '\nvault kv put "${VAULT_KV_MOUNT}/${BASE}/akkoma-admin" token=x\n' >> "${d}/scripts/gen-cluster-secrets.sh"
out="$(run_on "${d}")"; rc="$(rc_on "${d}")"
[ "${rc}" -eq 1 ] && ok "exit 1 when the gap is closed but the exemption remains" || bad "exit ${rc}, expected 1"
case "${out}" in *"now writes it"*) ok "says the seed now writes it";; *) bad "does not explain why it is stale";; esac

echo "== 6. a commented-out resource is NOT treated as applied =="
# azure-intune is commented out in the real kustomization and reads
# hugmesh/azure-intune, which the seed never writes. If the parser counted
# commented lines, the committed tree would be RED — test 1 already proves it is
# not, so assert the mechanism directly rather than by implication.
d="$(scratch commented)"
python3 - "${d}" <<'PY'
import sys,pathlib,re
p=pathlib.Path(sys.argv[1])/"specs/cluster/manifests/external-secrets/kustomization.yaml"
t=p.read_text()
t=re.sub(r'^\s*#\s*- azure-intune-externalsecrets\.yaml.*$', '  - azure-intune-externalsecrets.yaml', t, flags=re.M)
p.write_text(t)
PY
rc="$(rc_on "${d}")"
[ "${rc}" -eq 1 ] && ok "uncommenting azure-intune makes it RED (so comments really are excluded)" || bad "exit ${rc}: uncommenting changed nothing — comments are not being honoured"

echo "== 7. the checker refuses to pass when it cannot run =="
d="$(scratch broken-yaml)"
printf '\n\tthis: [is: not: yaml\n' >> "${d}/specs/cluster/manifests/external-secrets/sso-externalsecrets.yaml"
rc="$(rc_on "${d}")"
[ "${rc}" -eq 2 ] && ok "unparseable manifest -> exit 2, not 0" || bad "exit ${rc}, expected 2"

d="$(scratch no-seed)"; rm -f "${d}/scripts/gen-cluster-secrets.sh"
rc="$(rc_on "${d}")"
[ "${rc}" -eq 2 ] && ok "missing seed script -> exit 2, not 0" || bad "exit ${rc}, expected 2"

d="$(scratch empty-resources)"
python3 - "${d}" <<'PY'
import sys,pathlib
p=pathlib.Path(sys.argv[1])/"specs/cluster/manifests/external-secrets/kustomization.yaml"
p.write_text("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n")
PY
rc="$(rc_on "${d}")"
[ "${rc}" -eq 2 ] && ok "empty resources: -> exit 2, refuses to report closure over nothing" || bad "exit ${rc}, expected 2"

d="$(scratch no-puts)"
python3 - "${d}" <<'PY'
import sys,pathlib,re
p=pathlib.Path(sys.argv[1])/"scripts/gen-cluster-secrets.sh"
p.write_text(re.sub(r'vault kv (put|patch)', 'vault kv NOTHING', p.read_text()))
PY
rc="$(rc_on "${d}")"
[ "${rc}" -eq 2 ] && ok "no writes found at all -> exit 2 (the extractor is broken, not the tree)" || bad "exit ${rc}, expected 2"

echo '== 8. a `vault kv put` quoted in a COMMENT does not count as a write =='
d="$(scratch comment-put)"
without_exemption "hugmesh/akkoma-admin" "${d}/checker.py" || bad "could not build the no-exemption checker"
printf '\n# vault kv put "${VAULT_KV_MOUNT}/${BASE}/akkoma-admin" token=x   # prose, not code\n' >> "${d}/scripts/gen-cluster-secrets.sh"
out="$(python3 "${d}/checker.py" --repo "${d}" 2>&1)"; rc=$?
[ "${rc}" -eq 1 ] && ok "a commented put is not a write" || bad "exit ${rc}: a commented-out put satisfied the check"

echo "== 9. a dataFrom.extract key counts as a reference =="
# An ExternalSecret can name its Vault path under dataFrom[].extract.key instead
# of data[].remoteRef.key — five of the applied manifests do. Ignoring that form
# survived the whole suite until this scenario existed.
d="$(scratch datafrom)"
python3 - "${d}" <<'PYX'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "specs/cluster/manifests/external-secrets/sso-externalsecrets.yaml"
p.write_text(p.read_text() + (
    "\n---\napiVersion: external-secrets.io/v1beta1\nkind: ExternalSecret\n"
    "metadata:\n  name: datafrom-only\n  namespace: hugmesh-backend\n"
    "spec:\n  dataFrom:\n    - extract: { key: hugmesh/only-via-datafrom }\n"))
PYX
out="$(run_on "${d}")"; rc="$(rc_on "${d}")"
[ "${rc}" -eq 1 ] && ok "a dataFrom-only reference is checked too" || bad "exit ${rc}: dataFrom keys are not being read"
case "${out}" in *"hugmesh/only-via-datafrom"*) ok "names the dataFrom path";; *) bad "does not name it";; esac

echo "== 10. a resource listed but absent is fatal, not skipped =="
# A kustomization naming a file that is not there means the applied set is not
# what the tree says it is. Skipping it would let the checker report closure over
# a smaller set than the cluster actually gets — the same class of quiet
# under-measurement as #349.
d="$(scratch missing-file)"
python3 - "${d}" <<'PYX'
import sys, pathlib
p = pathlib.Path(sys.argv[1]) / "specs/cluster/manifests/external-secrets/kustomization.yaml"
p.write_text(p.read_text() + "  - not-a-real-file.yaml\n")
PYX
out="$(run_on "${d}")"; rc="$(rc_on "${d}")"
[ "${rc}" -eq 2 ] && ok "a listed-but-absent resource -> exit 2" || bad "exit ${rc}, expected 2"
case "${out}" in *"not-a-real-file.yaml"*) ok "names the missing file";; *) bad "does not name it";; esac

echo
echo "kind secret closure: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ] || exit 1
