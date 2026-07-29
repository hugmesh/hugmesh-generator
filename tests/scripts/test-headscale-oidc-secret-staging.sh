#!/usr/bin/env bash
# test-headscale-oidc-secret-staging.sh — end-to-end offline test for the
# headscale OIDC client-secret KEYS-bundle staging fix (flagged 2026-07-09 in
# PR #292, fixed 2026-07-10).
#
# Runs the REAL scripts.gen-cluster-secrets.sh -> scripts/gen-provision-keys.sh
# pipeline (no mocks) and asserts the exact value gen-cluster-secrets.sh mints
# for headscale's Casdoor app secret ends up staged, byte-for-byte, at
# <pki-bundle>/headscale/oidc_client_secret — the file
# specs/etc/keys-provision/provision.sh's provision_headscale() copies to
# /var/lib/headscale/oidc_client_secret, matching
# keys-template/headscale/config.yaml's client_secret_path exactly.
#
# Needs: openssl, python3, jq (all required by the scripts themselves).
# SKIPs (exit 0) if any are absent, or if ${REPO}/keys-out already exists (a
# developer's real local secrets bundle — never touched/moved/deleted by a
# test; this test is offline-repo-mutating by nature, so it refuses to run
# unless the working tree is clean of that gitignored directory).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GCS="${REPO}/scripts/gen-cluster-secrets.sh"
GPK="${REPO}/scripts/gen-provision-keys.sh"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
[ -f "${GCS}" ]  || { echo "  FAIL gen-cluster-secrets.sh missing: ${GCS}"; exit 1; }
[ -f "${GPK}" ]  || { echo "  FAIL gen-provision-keys.sh missing: ${GPK}"; exit 1; }
[ -f "${PROV}" ] || { echo "  FAIL provision.sh missing: ${PROV}"; exit 1; }
for t in openssl python3 jq; do command -v "${t}" >/dev/null || { echo "SKIP: need ${t}"; exit 0; }; done
if [ -e "${REPO}/keys-out" ]; then
    echo "SKIP: ${REPO}/keys-out already exists (a real local secrets bundle?) — refusing to touch it"
    exit 0
fi

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
ROLE_OUT="$(mktemp -d)"
NOBUNDLE_OUT="$(mktemp -d)"
cleanup() {
    rm -rf "${ROLE_OUT}" "${NOBUNDLE_OUT}" 2>/dev/null || true
    rm -rf "${REPO}/keys-out" 2>/dev/null || true
}
trap cleanup EXIT

echo "== headscale OIDC client-secret KEYS-bundle staging: end-to-end test =="

# ── (a) gen-cluster-secrets.sh mints the value + writes it to keys-out/vault/secrets.json ──
cd "${REPO}"
if ! GITHUB_CLIENT_ID= DISCORD_CLIENT_ID= timeout 60 "${GCS}" >/tmp/gcs-out.$$.log 2>&1; then
    bad "(a) gen-cluster-secrets.sh failed"; cat /tmp/gcs-out.$$.log; rm -f /tmp/gcs-out.$$.log
else
    rm -f /tmp/gcs-out.$$.log
    if [ -f "${REPO}/keys-out/vault/secrets.json" ]; then
        ok "(a) gen-cluster-secrets.sh ran and wrote keys-out/vault/secrets.json"
    else
        bad "(a) keys-out/vault/secrets.json not produced"
    fi
fi

MINTED="$(jq -r '
    [.[] | select(has("casdoor-app-secrets")) | .["casdoor-app-secrets"]["headscale"]][0] // empty
' "${REPO}/keys-out/vault/secrets.json" 2>/dev/null)"
if [ -n "${MINTED}" ] && [ "${#MINTED}" -ge 32 ]; then
    ok "(a) a real headscale Casdoor app secret was minted (${#MINTED} chars)"
else
    bad "(a) no usable headscale secret found in secrets.json"
fi

# ── (b) gen-provision-keys.sh -r pki carries it forward into the role bundle ──
if ! NONINTERACTIVE=1 RANDOM_PW=true timeout 60 "${GPK}" -r pki -o "${ROLE_OUT}/pki" --admin testadmin \
        >/tmp/gpk-out.$$.log 2>&1; then
    bad "(b) gen-provision-keys.sh -r pki failed"; cat /tmp/gpk-out.$$.log; rm -f /tmp/gpk-out.$$.log
else
    if grep -q "Headscale OIDC secret: staged" /tmp/gpk-out.$$.log; then
        ok "(b) gen-provision-keys.sh reported staging the headscale OIDC secret"
    else
        bad "(b) gen-provision-keys.sh did not report staging the secret"; cat /tmp/gpk-out.$$.log
    fi
    rm -f /tmp/gpk-out.$$.log
fi

STAGED_FILE="${ROLE_OUT}/pki/headscale/oidc_client_secret"
if [ -f "${STAGED_FILE}" ]; then
    ok "(b) staged file exists at the exact path provision_headscale() expects: headscale/oidc_client_secret"
else
    bad "(b) staged file missing: ${STAGED_FILE}"
fi

STAGED_VALUE="$(cat "${STAGED_FILE}" 2>/dev/null || echo "")"
if [ -n "${MINTED}" ] && [ "${STAGED_VALUE}" = "${MINTED}" ]; then
    ok "(b) staged value byte-for-byte equals the minted secrets.json value (no re-minting, no truncation)"
else
    bad "(b) staged value diverged from the minted value"
    echo "    minted: ${MINTED}"; echo "    staged: ${STAGED_VALUE}"
fi

if [ -f "${STAGED_FILE}" ]; then
    PERMS="$(stat -c '%a' "${STAGED_FILE}" 2>/dev/null || stat -f '%Lp' "${STAGED_FILE}" 2>/dev/null)"
    [ "${PERMS}" = "600" ] && ok "(b) staged file is chmod 600" || bad "(b) staged file has wrong perms: ${PERMS} (want 600)"
fi

# No trailing newline: a raw secret-file convention (mirrors Docker/K8s secret
# mounts) — a stray \n baked into the file could corrupt the literal string
# headscale sends as the OAuth2 client_secret. Assert this explicitly since
# it's easy to regress via an errant `echo` (adds \n) replacing `printf '%s'`.
# Must also assert non-empty first: on a zero-length file, `tail -c1 | od` etc.
# all produce an empty LAST_BYTE, which != "0a" too — a naive check would give
# a false PASS on an empty (i.e. broken) staged file instead of catching it.
if [ -f "${STAGED_FILE}" ]; then
    if [ -s "${STAGED_FILE}" ]; then
        LAST_BYTE="$(tail -c1 "${STAGED_FILE}" | od -An -tx1 | tr -d ' \n')"
        [ "${LAST_BYTE}" != "0a" ] && ok "(b) staged file is non-empty with NO trailing newline (raw-secret convention)" \
            || bad "(b) staged file has a trailing newline — could corrupt the literal secret headscale reads"
    else
        bad "(b) staged file is EMPTY — extraction silently produced nothing usable"
    fi
fi

# ── (c) provision_headscale()'s explicit copy for this exact file exists ─────────
# Static check (no root, no headscale binary needed): the exact cp line for
# oidc_client_secret must exist, gated on the file's presence, separate from
# the generic *.key glob (proven insufficient in PR #292's own investigation).
if grep -qE 'cp -f "\$\{BASE\}/headscale/oidc_client_secret" /var/lib/headscale/oidc_client_secret' "${PROV}"; then
    ok "(c) provision_headscale() has an explicit copy for oidc_client_secret (not relying on the *.key glob)"
else
    bad "(c) provision_headscale() is missing the explicit oidc_client_secret copy"
fi

# ── (d) absent-bundle path fails soft, not hard — gen-provision-keys.sh must
# still succeed (other bundle contents matter even without headscale wired) ──
if ! NONINTERACTIVE=1 RANDOM_PW=true timeout 60 env -u REPO "${GPK}" -r pki -o "${NOBUNDLE_OUT}/pki" --admin testadmin \
        >/tmp/gpk-nb.$$.log 2>&1; then
    : # covered below via keys-out presence check; a real run always has keys-out present at this point in the test, see note
fi
# The no-bundle case is exercised by TEMPORARILY moving keys-out aside within
# this same repo checkout (safe: this test already asserted keys-out did not
# pre-exist, and the trap restores/removes it regardless of outcome).
mv "${REPO}/keys-out" "${REPO}/keys-out.testmoved"
if NONINTERACTIVE=1 RANDOM_PW=true timeout 60 "${GPK}" -r pki -o "${NOBUNDLE_OUT}/pki2" --admin testadmin \
        >/tmp/gpk-nb2.$$.log 2>&1; then
    if grep -q "Headscale OIDC secret: SKIPPED" /tmp/gpk-nb2.$$.log && [ ! -e "${NOBUNDLE_OUT}/pki2/headscale/oidc_client_secret" ]; then
        ok "(d) absent vault bundle: skips the secret cleanly (warns, does not fabricate a value) and the rest of the run still succeeds"
    else
        bad "(d) absent-bundle behavior unexpected"; cat /tmp/gpk-nb2.$$.log
    fi
else
    bad "(d) gen-provision-keys.sh -r pki exited non-zero with no vault bundle present (should soft-fail only the headscale step, not the whole run)"
    cat /tmp/gpk-nb2.$$.log
fi
rm -f /tmp/gpk-nb.$$.log /tmp/gpk-nb2.$$.log
mv "${REPO}/keys-out.testmoved" "${REPO}/keys-out"

echo
echo "== headscale OIDC client-secret staging: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
