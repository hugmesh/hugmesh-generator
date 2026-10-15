#!/usr/bin/env bash
# test-no-literal-vault-brand-prose.sh — specs/cluster prose must never spell the
# Vault KV base segment as the literal brand `secret/hugmesh/...` again. Issue #490.
#
# WHAT HAPPENED. ~78 comments and three operator-facing Python strings (all inside
# specs/cluster/manifests/casdoor/init-job.yaml's reconcile script) spelled the
# Vault path with the DEFAULT brand baked in — `secret/hugmesh/casdoor`,
# `secret/hugmesh/mail`, etc. — while ~55 other places in the SAME tree already
# used the neutral convention `secret/<brand>/...` (the base segment IS the brand
# slug; scripts/gen-cluster-secrets.sh writes under BASE="${BRAND:-hugmesh}"). A
# human reading the literal-hugmesh spelling on a mesh built with --brand=acme is
# told the WRONG Vault path — the annotation next to it, and the remoteRef base
# ESO actually reads (issue #285 / test-eso-remoteref-brand.sh), both follow BRAND.
# This is the prose half of that drift; test-eso-remoteref-brand.sh guards the
# live remoteRef keys and their 143-literal census and does not cover comments or
# printed strings.
#
# WHAT THIS GUARDS. No file under specs/cluster may contain the literal substring
# `secret/hugmesh/` ever again — mechanical and exact, so it cannot be argued
# around. It does NOT forbid the bare word `hugmesh` (namespaces, the frozen
# `hugmesh.net/` label-key namespace, `platform.hugmesh.net` API group, etc. all
# still say `hugmesh` correctly and are out of scope here) — only this one
# specific mis-templated path shape.
#
# Pure grep. No network, no root, no docker, no cluster, no python.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
ROOT="${VAULT_BRAND_PROSE_ROOT:-${REPO}/specs/cluster}"
PATTERN='secret/hugmesh/'

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

[ -d "${ROOT}" ] || { echo "FATAL: ${ROOT} does not exist" >&2; exit 2; }

echo "== no literal '${PATTERN}' in ${ROOT} =="

# grep -a: a NUL byte in a file must not make this guard fail OPEN (see the
# repo-wide lesson on grep-fails-open-on-NUL). -I skips binaries outright.
hits="$(grep -arIn -- "${PATTERN}" "${ROOT}" 2>/dev/null || true)"
n_hits=0
[ -n "${hits}" ] && n_hits="$(printf '%s\n' "${hits}" | wc -l)"
if [ "${n_hits}" -eq 0 ]; then
  ok "no file under ${ROOT#${REPO}/} carries the literal path '${PATTERN}'"
else
  bad "${n_hits} line(s) still carry the literal default-brand Vault path:"
  printf '%s\n' "${hits}" | sed 's/^/         /'
fi

# Non-vacuity: the scan must actually be walking real content, not an empty or
# missing tree — and the convention this guard protects must still be present in
# volume (a wholesale deletion of the prose would also read as "0 hits").
n_correct="$(grep -arIl -- 'secret/<brand>/' "${ROOT}" 2>/dev/null | wc -l)"
if [ "${n_correct}" -ge 10 ]; then
  ok "vacuity: 'secret/<brand>/' still appears in ${n_correct} file(s) — the convention is present, not just absent"
else
  bad "vacuity: only ${n_correct} file(s) carry 'secret/<brand>/' — this guard may be scanning nothing real"
fi

echo "-- negative control --"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/probe"
cat > "${T}/probe/planted.yaml" <<'YAML'
# planted (ns hugmesh-pki) <- secret/hugmesh/planted-example — must be caught
apiVersion: v1
kind: Secret
metadata: { name: planted }
YAML
planted_hits="$(grep -arIn -- "${PATTERN}" "${T}/probe" 2>/dev/null || true)"
if [ -n "${planted_hits}" ]; then
  ok "negative control: a planted literal '${PATTERN}' line is caught"
else
  bad "negative control: a planted literal '${PATTERN}' line was NOT caught — the scan itself is broken"
fi

echo
echo "== no-literal-vault-brand-prose: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
