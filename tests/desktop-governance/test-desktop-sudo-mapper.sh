#!/usr/bin/env bash
# test-desktop-sudo-mapper.sh — unit test for the desktop-sudo mapper
# (specs/etc/hugmesh/desktop-governance/sudo/desktop-sudo-mapper.py.tmpl), the
# runtime that replaced the fake SSSD-OIDC conf: it verifies each session's
# deposited OIDC token against the issuer JWKS and converges local
# `desktop-sudo` group membership (the polkit gate's sole input).
#
# REAL CRYPTO, headless, NO root, NO network: the suite generates a real RSA
# keypair, signs real RS256 JWTs with openssl (RSASSA-PKCS1-v1_5/SHA-256 — the
# exact JWS alg), publishes the public key as a real JWKS (n/e), and runs the
# RENDERED mapper against it. Group mutation goes through PATH-stubbed
# getent/gpasswd/groupadd recording into a state file; sessions/JWKS/cache are
# redirected via the mapper's DSM_* seams (the DR_* override idiom).
#
# Proves (default-deny both directions):
#   * verified token (sig+iss+aud+exp+identity) with the desktop-sudo role
#     => user ADDED to the group (bare, <owner>/-qualified, and role-object
#     claim shapes all accepted); group auto-created when absent.
#   * roles WITHOUT desktop-sudo => not added.
#   * expired token => member REMOVED (IdP-revocation floor = token expiry).
#   * wrong iss / wrong aud => denied.
#   * identity binding: token `name` != the session's local user => denied.
#   * tampered payload (claims changed after signing) => denied.
#   * alg=none forgery => denied.  signature by a DIFFERENT key => denied.
#   * member logs out (token gone) => REMOVED within one run.
#   * JWKS unavailable: NO new grant ever (fail-closed); an existing member
#     holding a token is KEPT (last-good); a member with no token is still
#     removed (logout revocation works offline).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TPL="${REPO}/specs/etc/hugmesh/desktop-governance/sudo/desktop-sudo-mapper.py.tmpl"
[ -f "${TPL}" ] || { echo "  FAIL mapper template missing: ${TPL}"; exit 1; }
command -v python3 >/dev/null || { echo "  FAIL python3 required"; exit 1; }
command -v openssl >/dev/null || { echo "  FAIL openssl required"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Render exactly as provision_desktop_governance() does (sed domain substitution).
MAPPER="${WORK}/desktop-sudo-mapper"
sed 's/@@CLUSTER_DOMAIN@@/acme.example/g' "${TPL}" > "${MAPPER}"
chmod 0755 "${MAPPER}"
grep -q '@@CLUSTER_DOMAIN@@' "${MAPPER}" && { echo "  FAIL placeholder left in render"; exit 1; }

# ── Real key material ─────────────────────────────────────────────────────────
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${WORK}/key.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${WORK}/rogue.pem" 2>/dev/null
MOD="$(openssl rsa -in "${WORK}/key.pem" -noout -modulus | sed 's/^Modulus=//')"
python3 - "${MOD}" > "${WORK}/jwks.json" <<'PY'
import base64, json, sys
n = bytes.fromhex(sys.argv[1])
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
print(json.dumps({"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256",
                            "kid": "t1", "n": b64(n), "e": "AQAB"}]}))
PY

b64url(){ openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# mint <payload-json> [keyfile] [header-json] -> a real signed JWT on stdout
mint() {
    local payload="$1" key="${2:-${WORK}/key.pem}" hdr="${3:-}"
    [ -n "${hdr}" ] || hdr='{"alg":"RS256","typ":"JWT","kid":"t1"}'
    local h p s
    h="$(printf '%s' "${hdr}" | b64url)"
    p="$(printf '%s' "${payload}" | b64url)"
    printf '%s.%s' "${h}" "${p}" > "${WORK}/si"
    openssl dgst -sha256 -sign "${key}" -out "${WORK}/sig.bin" "${WORK}/si"
    s="$(b64url < "${WORK}/sig.bin")"
    printf '%s.%s.%s' "${h}" "${p}" "${s}"
}

NOW="$(date +%s)"; EXP=$((NOW + 3600)); PAST=$((NOW - 3600))
payload(){ # $1=name $2=roles-json [$3=exp] [$4=iss] [$5=aud-json]
    printf '{"iss":"%s","aud":%s,"exp":%s,"name":"%s","roles":%s}' \
        "${4:-https://id.acme.example}" "${5:-[\"hugmesh-desktop\"]}" "${3:-${EXP}}" "$1" "$2"
}

# ── PATH stubs: getent/gpasswd/groupadd against a comma-list state file ───────
STUB="${WORK}/stub-bin"; mkdir -p "${STUB}"
cat > "${STUB}/getent" <<'SH'
#!/usr/bin/env bash
[ "$1" = "group" ] || exit 2
[ -f "${GROUP_STATE}" ] || exit 2
printf 'desktop-sudo:x:990:%s\n' "$(cat "${GROUP_STATE}")"
SH
cat > "${STUB}/groupadd" <<'SH'
#!/usr/bin/env bash
echo "groupadd $*" >> "${OPS_LOG}"
: > "${GROUP_STATE}"
SH
cat > "${STUB}/gpasswd" <<'SH'
#!/usr/bin/env bash
op="$1" user="$2"
echo "gpasswd $op $user $3" >> "${OPS_LOG}"
cur="$(cat "${GROUP_STATE}" 2>/dev/null)"
out=""
IFS=, read -ra members <<< "${cur}"
case "${op}" in
    -a) members+=("${user}") ;;
    -d) for i in "${!members[@]}"; do [ "${members[$i]}" = "${user}" ] && unset "members[$i]"; done ;;
    *)  exit 1 ;;
esac
for m in "${members[@]:-}"; do [ -n "${m}" ] || continue; out="${out:+${out},}${m}"; done
printf '%s' "${out}" > "${GROUP_STATE}"
SH
chmod 0755 "${STUB}"/getent "${STUB}"/groupadd "${STUB}"/gpasswd

# Fresh per-case sandbox. members: pre-seeded comma list ("" = group exists
# empty; unset GROUP_STATE file = group absent).
new_case() {
    CASE="$(mktemp -d "${WORK}/case.XXXXXX")"
    RUN="${CASE}/run-user"; GS="${CASE}/group.state"; OPS="${CASE}/ops.log"
    mkdir -p "${RUN}"; : > "${OPS}"
    if [ "$#" -gt 0 ]; then printf '%s' "$1" > "${GS}"; fi
}
deposit(){ mkdir -p "${RUN}/$1/hugmesh"; printf '%s' "$2" > "${RUN}/$1/hugmesh/oidc-token"; }
run_mapper() {
    DSM_RUN_USER_ROOT="${RUN}" DSM_JWKS_FILE="${JWKS_OVERRIDE:-${WORK}/jwks.json}" \
    DSM_CACHE_DIR="${CASE}/cache" DSM_UID_MAP="1001=alice,1002=bob,1003=carol" \
    GROUP_STATE="${GS}" OPS_LOG="${OPS}" PATH="${STUB}:${PATH}" \
    "${MAPPER}" > "${CASE}/mapper.log" 2>&1
}

echo "== desktop-sudo-mapper unit test (real RS256) =="

# ── 1. Verified token with the role => added; absent group auto-created ───────
new_case   # no GROUP_STATE file => group absent
deposit 1001 "$(mint "$(payload alice '["ROLE_USER","desktop-sudo"]')")"
run_mapper; rc=$?
[ "${rc}" -eq 0 ] && ok "grant run rc 0" || bad "grant run rc ${rc}"
grep -q '^groupadd desktop-sudo$' "${OPS}" && ok "absent desktop-sudo group auto-created" || bad "group not created"
grep -q '^gpasswd -a alice desktop-sudo$' "${OPS}" && [ "$(cat "${GS}")" = "alice" ] \
    && ok "verified desktop-sudo claim => alice added to the group" \
    || bad "alice not added (ops: $(cat "${OPS}"); log: $(cat "${CASE}/mapper.log"))"

# ── 2. Verified token WITHOUT the role => not added ───────────────────────────
new_case ""
deposit 1002 "$(mint "$(payload bob '["ROLE_USER","discover"]')")"
run_mapper
[ -z "$(cat "${GS}")" ] && ok "no desktop-sudo role => no grant (default-deny)" \
    || bad "bob granted without the role"

# ── 3. <owner>/-qualified role string + string-form aud accepted ──────────────
new_case ""
deposit 1001 "$(mint "$(payload alice '["hugmesh/desktop-sudo"]' "${EXP}" https://id.acme.example '"hugmesh-desktop"')")"
run_mapper
[ "$(cat "${GS}")" = "alice" ] && ok "owner-qualified hugmesh/desktop-sudo role accepted (string aud too)" \
    || bad "qualified role/string aud rejected: $(cat "${CASE}/mapper.log")"

# ── 4. plain-JWT role-object claim shape accepted ─────────────────────────────
new_case ""
deposit 1001 "$(mint "$(payload alice '[{"owner":"hugmesh","name":"desktop-sudo"}]')")"
run_mapper
[ "$(cat "${GS}")" = "alice" ] && ok "role-object claim shape ({name: desktop-sudo}) accepted" \
    || bad "role-object shape rejected"

# ── 5. expired token => existing member removed (revocation floor) ────────────
new_case "alice"
deposit 1001 "$(mint "$(payload alice '["desktop-sudo"]' "${PAST}")")"
run_mapper
[ -z "$(cat "${GS}")" ] && grep -q '^gpasswd -d alice desktop-sudo$' "${OPS}" \
    && ok "expired token => member removed (expiry is the revocation floor)" \
    || bad "expired token kept membership"

# ── 6. wrong issuer => denied ─────────────────────────────────────────────────
new_case ""
deposit 1001 "$(mint "$(payload alice '["desktop-sudo"]' "${EXP}" https://id.evil.example)")"
run_mapper
[ -z "$(cat "${GS}")" ] && ok "foreign-issuer token denied" || bad "foreign issuer accepted"

# ── 7. wrong audience => denied ───────────────────────────────────────────────
new_case ""
deposit 1001 "$(mint "$(payload alice '["desktop-sudo"]' "${EXP}" https://id.acme.example '["app-admin-bff"]')")"
run_mapper
[ -z "$(cat "${GS}")" ] && ok "other-client audience denied" || bad "wrong aud accepted"

# ── 8. identity binding: token name != local session user => denied ───────────
new_case ""
deposit 1001 "$(mint "$(payload carol '["desktop-sudo"]')")"   # carol's token in alice's runtime dir
run_mapper
[ -z "$(cat "${GS}")" ] && ok "replayed third-party token denied (name != local user)" \
    || bad "identity mismatch accepted"

# ── 9. tampered payload (claims edited after signing) => denied ───────────────
new_case ""
TOK="$(mint "$(payload alice '["ROLE_USER"]')")"
H="${TOK%%.*}"; REST="${TOK#*.}"; SIG="${REST#*.}"
FORGED_P="$(printf '%s' "$(payload alice '["desktop-sudo"]')" | b64url)"
deposit 1001 "${H}.${FORGED_P}.${SIG}"
run_mapper
[ -z "$(cat "${GS}")" ] && ok "tampered payload denied (signature is the authority)" \
    || bad "tampered payload accepted"

# ── 10. alg=none forgery => denied ────────────────────────────────────────────
new_case ""
HN="$(printf '%s' '{"alg":"none","typ":"JWT"}' | b64url)"
PN="$(printf '%s' "$(payload alice '["desktop-sudo"]')" | b64url)"
deposit 1001 "${HN}.${PN}."
run_mapper
[ -z "$(cat "${GS}")" ] && ok "alg=none forgery denied" || bad "alg=none accepted"

# ── 11. signature by a different (rogue) key => denied ────────────────────────
new_case ""
deposit 1001 "$(mint "$(payload alice '["desktop-sudo"]')" "${WORK}/rogue.pem")"
run_mapper
[ -z "$(cat "${GS}")" ] && ok "rogue-key signature denied" || bad "rogue-key signature accepted"

# ── 12. logout (token gone) => member removed ─────────────────────────────────
new_case "alice"
run_mapper
[ -z "$(cat "${GS}")" ] && grep -q '^gpasswd -d alice desktop-sudo$' "${OPS}" \
    && ok "no deposited token => member removed (logout revocation)" \
    || bad "logged-out member kept"

# ── 13. JWKS unavailable: no grant, keep token-holding member, drop no-token ──
new_case "alice,carol"
deposit 1001 "$(mint "$(payload alice '["desktop-sudo"]')")"   # member, has token
deposit 1002 "$(mint "$(payload bob '["desktop-sudo"]')")"     # NON-member, has token
JWKS_OVERRIDE="${WORK}/nonexistent-jwks.json" run_mapper
state="$(cat "${GS}")"
case ",${state}," in *,alice,*) a=1;; *) a=0;; esac
case ",${state}," in *,bob,*)   b=1;; *) b=0;; esac
case ",${state}," in *,carol,*) c=1;; *) c=0;; esac
[ "${a}" = 1 ] && ok "JWKS outage: token-holding member KEPT (last-good)" || bad "JWKS outage removed a token-holding member"
[ "${b}" = 0 ] && ok "JWKS outage: NO new grant (fail-closed)" || bad "JWKS outage granted bob"
[ "${c}" = 0 ] && ok "JWKS outage: no-token member still removed (offline logout revocation)" \
    || bad "JWKS outage kept a logged-out member"

# ── 14. hostile token path: symlink is not followed, and no grant results ─────
# /run/user/<uid>/** is USER-writable while the mapper runs as ROOT. A symlinked
# oidc-token must not make root read an arbitrary file (and its content must
# never become a grant).
new_case ""
mkdir -p "${RUN}/1001/hugmesh"
# The symlink target is a FULLY VALID token, so only O_NOFOLLOW can deny it —
# a naive open() would read outside the session dir and grant.
printf '%s' "$(mint "$(payload alice '["desktop-sudo"]')")" > "${CASE}/outside-token"
ln -s "${CASE}/outside-token" "${RUN}/1001/hugmesh/oidc-token"
run_mapper; rc=$?
[ "${rc}" -eq 0 ] && [ -z "$(cat "${GS}")" ] \
    && ok "symlinked token path not followed (no grant, run still converges)" \
    || bad "symlinked token path granted or crashed the run (rc ${rc})"

# Same for a symlinked hugmesh/ DIRECTORY component.
new_case ""
mkdir -p "${RUN}/1001" "${CASE}/elsewhere"
printf '%s' "$(mint "$(payload alice '["desktop-sudo"]')")" > "${CASE}/elsewhere/oidc-token"
ln -s "${CASE}/elsewhere" "${RUN}/1001/hugmesh"
run_mapper
[ -z "$(cat "${GS}")" ] && ok "symlinked hugmesh/ dir not followed (no grant)" \
    || bad "symlinked directory component followed"

# ── 15. hostile token path: a FIFO must not wedge the run ─────────────────────
# A blocking open() on a user-planted FIFO would hang the cron job forever — and
# a wedged mapper stops EVERY revocation, not just this user's. Prove the run
# still finishes and still revokes the OTHER user who logged out.
new_case "carol"
mkdir -p "${RUN}/1001/hugmesh"
mkfifo "${RUN}/1001/hugmesh/oidc-token"
timeout 20 env DSM_RUN_USER_ROOT="${RUN}" DSM_JWKS_FILE="${WORK}/jwks.json" \
    DSM_CACHE_DIR="${CASE}/cache" DSM_UID_MAP="1001=alice,1002=bob,1003=carol" \
    GROUP_STATE="${GS}" OPS_LOG="${OPS}" PATH="${STUB}:${PATH}" \
    "${MAPPER}" > "${CASE}/mapper.log" 2>&1
rc=$?
[ "${rc}" -eq 0 ] && ok "FIFO token does not wedge the mapper (run completes, rc 0)" \
    || bad "FIFO token wedged/failed the run (rc ${rc} — 124 = timed out)"
[ -z "$(cat "${GS}")" ] && ok "FIFO token grants nothing AND the logged-out member is still revoked" \
    || bad "FIFO run left membership unconverged: $(cat "${GS}")"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
