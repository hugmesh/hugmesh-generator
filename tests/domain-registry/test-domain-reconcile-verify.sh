#!/usr/bin/env bash
# test-domain-reconcile-verify.sh — offline logic test for the domain-registry -> brand-repo
# bridge (#4): the verify lib (specs/usr/lib/snapdragon/domain-verify.sh) + the agent's emit
# seams (specs/usr/sbin/snapdragon-domain-reconcile sourced with DR_* env seams).
#
# Runs ANYWHERE with bash + jq + openssl + base64 — NO live mesh, NO BFF, NO network, NO root.
# SKIPs (exit 0) only if a required tool is genuinely absent. It mirrors
# tests/node-storage/test-node-agent.sh + tests/egress-vpn/test-vpn-reconcile-verify.sh step for
# step: mint a throwaway Ed25519 key, sign the EXACT bytes domain_canonical_bytes reconstructs
# from a synthetic #118 signed export, and assert the FULL fail-closed matrix.
#
# Assertions:
#   (a) genuine signed export ACCEPTED by domain_verify_export against the baked pub.
#   (b) registered-not-provisioned domain -> the agent EMITS: a synthesised domains.conf row +
#       a rendered out/<brand>-gitops/apps/ tree with {{TOKEN}}s fully substituted (CA gen is
#       scoped out via DR_SKIP_CA=1 — openssl/keytool-heavy; the row + brand render are the
#       offline-verifiable surface, mirroring how the vpn test scopes to verify-only).
#   (c) tampered body REJECTED (no artifacts).
#   (d) unsigned (signature=null / signed=false) REJECTED (no artifacts).
#   (e) foreign-key signature REJECTED (no artifacts).
#   (f) rollback (gen <= last-good) REJECTED (no artifacts).
#   (g) defaults INERT: with no BFF_EXPORT_URL / no key, the agent keeps cache, exits 0, emits
#       nothing.
# End-to-end equality with a LIVE BFF payload is a needs-node check (documented in the PR body).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/specs/usr/lib/snapdragon/domain-verify.sh"
AGENT="${REPO}/specs/usr/sbin/snapdragon-domain-reconcile"
GEN_KEYSTORES="${REPO}/scripts/gen-keystores.sh"
GEN_BRAND_REPOS="${REPO}/generate-brand-repos.sh"

[ -r "${LIB}" ]   || { echo "  FAIL verify lib missing: ${LIB}"; exit 1; }
[ -r "${AGENT}" ] || { echo "  FAIL agent missing: ${AGENT}"; exit 1; }
for t in openssl jq base64; do command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== domain-registry bridge (#4): verify + emit offline test =="

# ── Ephemeral signing key + the baked public half (base64 X.509 SPKI DER) ───────────
PRIV="${WORK}/priv.pem"; PUB_B64="${WORK}/registry-pub.ed25519"
openssl genpkey -algorithm ed25519 -out "${PRIV}" 2>/dev/null || { echo "SKIP: no ed25519"; exit 0; }
openssl pkey -in "${PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${PUB_B64}"
# A second (foreign) key for the foreign-key rejection case.
FPRIV="${WORK}/foreign.pem"
openssl genpkey -algorithm ed25519 -out "${FPRIV}" 2>/dev/null

# Source the verify lib exactly as the agent does (it sources registry-verify.sh in turn).
# shellcheck source=/dev/null
. "${LIB}" || { echo "  FAIL could not source ${LIB}"; exit 1; }

NODE="mkey:abc"; GEN=7
# Build a signed #118 domain export for ONE registered-not-provisioned domain, signed by $1
# (priv pem) at generation $2. The signature is over EXACTLY domain_canonical_bytes(body) — the
# real consumer contract (sign the FILE, not a $(...)-captured string: command substitution
# strips the trailing newline, which would diverge from what verify_sig reads).
make_signed_export() {
    local priv="$1" gen="$2" out="$3" caprov="${4:-false}" appset="${5:-false}" brand="${6:-acme}"
    local body
    body="$(jq -n --argjson gen "${gen}" --arg node "${NODE}" --argjson cp "${caprov}" \
                  --argjson as "${appset}" --arg brand "${brand}" '{
        node: $node,
        generation: $gen,
        entries: [
            { clusterDomain: "acme.test", brand: $brand, org: "Acme-Inc", caRef: "generate",
              nsPrefix: "acme", casdoorOrg: "acme-org", meshTag: "tag:acme",
              caProvisioned: $cp, appsetRegistered: $as, generation: $gen }
        ]
    }')"
    jq -n --argjson b "${body}" '{ body:$b, contentHash:"x", signature:null, publicKey:"advertised-ignored", signed:false }' > "${out}"
    local canonf sig
    canonf="$(mktemp)"
    domain_canonical_bytes "${out}" > "${canonf}"
    sig="$(openssl pkeyutl -sign -inkey "${priv}" -rawin -in "${canonf}" 2>/dev/null | base64 -w0)"
    rm -f "${canonf}"
    jq --arg sig "${sig}" '.signature=$sig | .signed=true' "${out}" > "${out}.s" && mv "${out}.s" "${out}"
}

# ── Case 0: canonical reconstruction matches a hand-built reference byte-for-byte ────
# v1-domain\n node=..\n generation=..\n then one dom= line (the JVM order from §2c).
canon_ref() {
    printf 'v1-domain\n'
    printf 'node=%s\n' "${NODE}"
    printf 'generation=%s\n' "${GEN}"
    printf 'dom=%s\tbrand=%s\torg=%s\tca=%s\tns=%s\tcasdoor=%s\tmesh=%s\tca_prov=%s\tappset=%s\tgen=%s\n' \
        "acme.test" "acme" "Acme-Inc" "generate" "acme" "acme-org" "tag:acme" "false" "false" "${GEN}"
}
make_signed_export "${PRIV}" "${GEN}" "${WORK}/good.json" "false" "false" "acme"
REFC="${WORK}/ref.bin"; canon_ref > "${REFC}"
RECON="${WORK}/recon.bin"; domain_canonical_bytes "${WORK}/good.json" > "${RECON}" 2>/dev/null
if cmp -s "${REFC}" "${RECON}"; then
    ok "domain_canonical_bytes matches the inline canon_ref bytes (byte-for-byte)"
else
    bad "canonical reconstruction DIVERGED from the inline reference"; echo "    want:"; od -An -tx1 "${REFC}" | head -4; echo "    got:"; od -An -tx1 "${RECON}" | head -4
fi

# ── Case 0b: EXTERNAL golden anchor — bash domain_canonical_bytes (hex) MUST byte-equal the
# COMMITTED, JVM-DERIVED golden vector (tests/domain-registry/canonical-golden.hex). This breaks
# the residual circularity: the ACCEPT/REJECT cases sign whatever domain_canonical_bytes emits and
# verify the same recomputation, so they would pass even with a self-consistent WRONG layout, and
# canon_ref() lives next to the code so it could co-drift on a future edit. The golden hex is
# derived INDEPENDENTLY from the authoritative admin-bff signer
# (DomainRegistryExportService.canonicalBytes, #118) via tests/domain-registry/Golden.java and
# cross-checked against a python3 byte-assembly — see the file header. This assertion FAILS LOUDLY
# if domain_canonical_bytes ever diverges from that committed external anchor.
GOLDEN_HEX_FILE="${REPO}/tests/domain-registry/canonical-golden.hex"
if [ -r "${GOLDEN_HEX_FILE}" ]; then
    # The committed vector is the single non-comment, non-blank line (lowercase hex, no spaces).
    GOLDEN_HEX="$(grep -vE '^[[:space:]]*(#|$)' "${GOLDEN_HEX_FILE}" | tr -d '[:space:]')"
    RECON_HEX="$(od -An -tx1 "${RECON}" | tr -d '[:space:]')"
    if [ -n "${GOLDEN_HEX}" ] && [ "${RECON_HEX}" = "${GOLDEN_HEX}" ]; then
        ok "domain_canonical_bytes byte-equals the COMMITTED JVM-derived golden vector (external anchor)"
    else
        bad "domain_canonical_bytes DIVERGED from the committed golden vector (canonical-golden.hex)"
        echo "    golden: ${GOLDEN_HEX}"
        echo "    got:    ${RECON_HEX}"
    fi
else
    bad "committed golden vector missing/unreadable: ${GOLDEN_HEX_FILE}"
fi

# ── Case (a): genuine signed export ACCEPTED ────────────────────────────────────────
if domain_verify_export "${WORK}/good.json" "${PUB_B64}"; then ok "(a) genuine signed export ACCEPTED"; else bad "(a) rejected a valid export"; fi

# ── Case (c): tampered body REJECTED ────────────────────────────────────────────────
jq '.body.entries[0].brand="EVIL"' "${WORK}/good.json" > "${WORK}/tamper.json"
if domain_verify_export "${WORK}/tamper.json" "${PUB_B64}"; then bad "(c) ACCEPTED a tampered body (LEAK)"; else ok "(c) tampered body REJECTED"; fi

# ── Case (d): unsigned REJECTED (fail-closed) ───────────────────────────────────────
jq '.signed=false | .signature=null' "${WORK}/good.json" > "${WORK}/unsigned.json"
if domain_verify_export "${WORK}/unsigned.json" "${PUB_B64}"; then bad "(d) ACCEPTED an unsigned export"; else ok "(d) unsigned export REJECTED (fail-closed)"; fi

# ── Case (e): foreign-key signature REJECTED ────────────────────────────────────────
make_signed_export "${FPRIV}" "${GEN}" "${WORK}/foreign.json" "false" "false" "acme"
if domain_verify_export "${WORK}/foreign.json" "${PUB_B64}"; then bad "(e) ACCEPTED a foreign-key signature"; else ok "(e) foreign-key signature REJECTED"; fi

# ── Case (f): rollback REJECTED + forward step ACCEPTED (strict-monotonic guard) ─────
LG="${WORK}/last-good"; printf '5' > "${LG}"
if domain_verify_export "${WORK}/good.json" "${PUB_B64}" "${LG}"; then ok "(f) ACCEPT gen=7 > last-good=5 (forward step)"; else bad "(f) rejected a valid forward generation"; fi
printf '7' > "${LG}"
if domain_verify_export "${WORK}/good.json" "${PUB_B64}" "${LG}"; then bad "(f) ACCEPTED gen==last-good (replay)"; else ok "(f) REJECT gen==last-good (replay)"; fi
printf '9' > "${LG}"
if domain_verify_export "${WORK}/good.json" "${PUB_B64}" "${LG}"; then bad "(f) ACCEPTED gen<last-good (rollback)"; else ok "(f) REJECT gen<last-good (rollback)"; fi

# ────────────────────────────────────────────────────────────────────────────────────
# EMIT-SIDE TESTS — source the agent with DR_* seams (the main guard prevents auto-run).
# ────────────────────────────────────────────────────────────────────────────────────
DR_NODE_ENV="${WORK}/node.env"
DR_PUB_KEY="${PUB_B64}"
DR_CACHE_DIR="${WORK}/cache"
DR_OUT_DIR="${WORK}/out"
DR_DOMAINS_CONF="${WORK}/domains.conf"
DR_VERIFY_LIB="${LIB}"
DR_GEN_KEYSTORES="${GEN_KEYSTORES}"
DR_GEN_BRAND_REPOS="${GEN_BRAND_REPOS}"
# Phase 6: the reconcile render path now runs the emit-time secret scanner as a HARD
# fail-closed gate before promoting/acking. Point the seam at the repo copy (mirrors
# the DR_GEN_* overrides) so the build-host test drives the real gate.
DR_SECRET_SCAN="${REPO}/scripts/secret-scan.sh"
DR_SKIP_CA=1
export DR_NODE_ENV DR_PUB_KEY DR_CACHE_DIR DR_OUT_DIR DR_DOMAINS_CONF DR_VERIFY_LIB \
       DR_GEN_KEYSTORES DR_GEN_BRAND_REPOS DR_SECRET_SCAN DR_SKIP_CA
mkdir -p "${DR_CACHE_DIR}"
# shellcheck source=/dev/null
. "${AGENT}"   # main is guarded; this just loads the functions with the DR_* config

# ── Case (b): registered-not-provisioned domain -> emits a row + a rendered brand repo ─
cp -f "${WORK}/good.json" "${DR_CACHE_DIR}/export.json"
if build_domains_conf "${DR_CACHE_DIR}/export.json"; then
    if grep -qE '^acme\.test[[:space:]]+acme$' "${DR_DOMAINS_CONF}"; then
        ok "(b) synthesised a domains.conf row for the registered-not-provisioned domain (self-signed/generate)"
    else
        bad "(b) domains.conf row missing/wrong"; echo "    ---"; cat "${DR_DOMAINS_CONF}"; echo "    ---"
    fi
else
    bad "(b) build_domains_conf returned non-zero"
fi
if command -v sed >/dev/null && command -v git >/dev/null; then
    render_brand_repos "${DR_CACHE_DIR}/export.json" >/dev/null 2>&1 || true
    APPS="${DR_OUT_DIR}/acme-gitops/apps"
    if [ -d "${APPS}" ] && [ -n "$(ls -A "${APPS}" 2>/dev/null)" ]; then
        ok "(b) rendered out/acme-gitops/apps/ ($(ls "${APPS}" | wc -l) Application CRDs)"
        if grep -rqE '\{\{[A-Z_]+\}\}' "${APPS}" 2>/dev/null; then
            bad "(b) rendered CRDs still contain unsubstituted {{TOKEN}}s"
        else
            ok "(b) every {{TOKEN}} fully substituted in the rendered CRDs"
        fi
        if grep -rq 'acme.test' "${APPS}" 2>/dev/null; then
            ok "(b) rendered CRDs carry the derived CLUSTER_DOMAIN (acme.test)"
        else
            bad "(b) rendered CRDs missing the brand domain"
        fi
    else
        bad "(b) no rendered brand-repo apps/ tree produced"
    fi
else
    echo "  SKIP (b) brand-repo render needs sed + git"
fi

# ── Case (b'): a fully-provisioned domain (caProvisioned && appsetRegistered) -> NO row ─
make_signed_export "${PRIV}" 8 "${WORK}/done.json" "true" "true" "beta"
build_domains_conf "${WORK}/done.json" >/dev/null 2>&1 || true
if grep -qvE '^[[:space:]]*(#|$)' "${DR_DOMAINS_CONF}" 2>/dev/null && grep -qE '^beta' "${DR_DOMAINS_CONF}" 2>/dev/null; then
    bad "(b') emitted a row for an already-provisioned domain (should be skipped)"
else
    ok "(b') fully-provisioned domain (ca_prov+appset true) emits NO row (no churn)"
fi

# ── Case (g): defaults INERT — no transport, no key -> keep cache, exit 0, emit nothing ─
G_CACHE="${WORK}/inert-cache"; G_OUT="${WORK}/inert-out"
printf 'MACHINE_KEY_FP=mkey:abc\nBFF_EXPORT_URL=\nBFF_CLIENT_CERT=\nBFF_CLIENT_KEY=\n' > "${WORK}/node-empty.env"
env DR_NODE_ENV="${WORK}/node-empty.env" DR_PUB_KEY="${PUB_B64}" DR_CACHE_DIR="${G_CACHE}" \
    DR_OUT_DIR="${G_OUT}" DR_DOMAINS_CONF="${WORK}/inert-domains.conf" DR_VERIFY_LIB="${LIB}" \
    bash "${AGENT}" >/dev/null 2>&1
RC=$?
if [ "${RC}" -eq 0 ] && [ ! -d "${G_OUT}" ] && [ ! -f "${G_CACHE}/export.json" ]; then
    ok "(g) defaults INERT: no BFF URL -> exit 0, no cache write, no emitted artifacts"
else
    bad "(g) agent was NOT inert at defaults (rc=${RC}, out-dir present=$( [ -d "${G_OUT}" ] && echo yes || echo no ))"
fi

# ── Case (g'): placeholder/missing key -> fail-closed, no emit (crypto gate) ─────────
G2_CACHE="${WORK}/inert2-cache"; G2_OUT="${WORK}/inert2-out"
printf 'MACHINE_KEY_FP=mkey:abc\nBFF_EXPORT_URL=https://api.example.test\nBFF_CLIENT_CERT=/nonexistent\nBFF_CLIENT_KEY=/nonexistent\n' > "${WORK}/node-keyless.env"
env DR_NODE_ENV="${WORK}/node-keyless.env" DR_PUB_KEY="/nonexistent-placeholder-key" DR_CACHE_DIR="${G2_CACHE}" \
    DR_OUT_DIR="${G2_OUT}" DR_DOMAINS_CONF="${WORK}/inert2-domains.conf" DR_VERIFY_LIB="${LIB}" \
    bash "${AGENT}" >/dev/null 2>&1
RC2=$?
if [ "${RC2}" -eq 0 ] && [ ! -d "${G2_OUT}" ]; then
    ok "(g') missing baked pubkey -> fail-closed exit 0, nothing emitted (crypto gate)"
else
    bad "(g') keyless agent emitted artifacts (rc=${RC2})"
fi

echo
echo "== domain-registry bridge: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
