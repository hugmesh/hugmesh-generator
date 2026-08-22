#!/usr/bin/env bash
# test-selinux-auditallow-generator.sh — scripts/selinux-make-auditallow.sh.
#
# The generator exists because docs/selinux-module-loading.md's narrowing plan
# cannot work as written: it says to "collect the permissive-pass AVCs to narrow
# every rule tagged INFERRED-WIDE", but an AVC DENIAL is raised for something the
# policy does NOT allow — it says what to ADD. Narrowing an over-broad `allow`
# needs what was actually EXERCISED, which is an auditallow record.
#
# Verified empirically first: six modules loaded, the full workload driven,
# permissive — ZERO denials, correctly, because a wide rule denies nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
GEN="${REPO}/scripts/selinux-make-auditallow.sh"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
[ -x "${GEN}" ] || { echo "  FAIL ${GEN} missing or not executable"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/slxaa.XXXXXX")"; trap 'rm -rf "${TMP}"' EXIT

# A stub pp converter: the real one is a compiled binary in the sysroot, so the
# generator is driven through --pp-tool. This keeps the suite hermetic AND tests
# the seam CI would use.
cat > "${TMP}/pp" <<'PPEOF'
#!/bin/sh
cat <<'CIL'
(typeattributeset cil_gen_require foo)
(allow hugmesh_authkeys_t hugmesh_authkeys_exec_t (file (entrypoint)))
(allow hugmesh_authkeys_t sshd_t (fd (use)))
(allow init_t some_other_t (file (read)))
CIL
PPEOF
chmod +x "${TMP}/pp"
: > "${TMP}/hugmesh_authkeys.pp"

out="$(bash "${GEN}" --pp-tool "${TMP}/pp" "${TMP}/hugmesh_authkeys.pp" 2>"${TMP}/err")"; rc=$?

[ "${rc}" -eq 0 ] && ok "generator succeeds on a module with hugmesh rules" \
                  || bad "generator failed (rc=${rc}): $(head -2 "${TMP}/err")"
[ "$(printf '%s' "${out}" | grep -c '^(auditallow ')" -eq 2 ] \
    && ok "every hugmesh (allow …) becomes (auditallow …)" \
    || bad "wrong auditallow count: $(printf '%s' "${out}" | grep -c '^(auditallow ')"
printf '%s' "${out}" | grep '^(allow ' >/dev/null \
    && bad "an (allow …) leaked into the output — the instrument would GRANT, not observe" \
    || ok "no (allow …) leaks through: the module grants nothing"
printf '%s' "${out}" | grep 'init_t some_other_t' >/dev/null \
    && bad "a NON-hugmesh rule was audited — that buries the signal in base-policy noise" \
    || ok "rules whose source is not a hugmesh domain are excluded"
printf '%s' "${out}" | grep 'hugmesh_authkeys_t sshd_t (fd (use))' >/dev/null \
    && ok "an interface-expanded rule (post-expansion CIL) is captured" \
    || bad "expanded rule missing — the .te-only approach it replaces would have lost it"

# REFUSE TO EMIT A USELESS INSTRUMENT. A generator that silently produces an
# empty .cil hands you a module that observes nothing, and a later "no granted
# records" reads as "the rule is unused" instead of "nothing was measured".
cat > "${TMP}/pp-empty" <<'PPEOF'
#!/bin/sh
echo "(allow init_t some_other_t (file (read)))"
PPEOF
chmod +x "${TMP}/pp-empty"
if bash "${GEN}" --pp-tool "${TMP}/pp-empty" "${TMP}/hugmesh_authkeys.pp" >/dev/null 2>&1; then
    bad "a run matching NO hugmesh rules exited 0 — an empty instrument looks like a clean result"
else
    ok "a run that would emit zero auditallow rules FAILS instead of shipping an empty instrument"
fi
if bash "${GEN}" --pp-tool /nonexistent/pp "${TMP}/hugmesh_authkeys.pp" >/dev/null 2>&1; then
    bad "a missing pp converter was accepted"
else
    ok "a missing pp converter fails loudly"
fi

echo
echo "== selinux auditallow generator: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
