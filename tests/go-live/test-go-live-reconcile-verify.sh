#!/usr/bin/env bash
# test-go-live-reconcile-verify.sh — offline logic test for the go-live wizard's
# fourth (web-UI) interface leg: the verify lib
# (specs/usr/lib/snapdragon/golive-verify.sh) + the agent's apply seams
# (specs/usr/sbin/snapdragon-go-live-reconcile sourced with GLR_* env seams,
# driving the REAL specs/usr/sbin/snapdragon-go-live driver sandboxed via
# GL_ETC_SNAPDRAGON).
#
# Runs ANYWHERE with bash + jq + openssl + base64 — NO live mesh, NO BFF, NO
# network, NO root. SKIPs (exit 0) only if a required tool is genuinely absent.
# Mirrors tests/domain-registry/test-domain-reconcile-verify.sh step for step
# for the verify half; the apply half is new (go-live-specific: drive the real
# commit/rollback subcommands and assert on the REAL marker file the driver
# writes, in a sandboxed --etc-snapdragon, never touching the real host /etc).
#
# Assertions:
#   (0) canonical reconstruction matches an inline reference AND an independent
#       second implementation (a pure-python re-derivation of
#       GoLiveExportService.canonicalBytes from the SAME Java source read for
#       this test's authorship — not JVM-executed, so this is NOT the
#       JVM-golden-vector rigor tests/domain-registry has; that is a follow-up
#       once a Golden.java-equivalent harness exists for go-live too).
#   (a) genuine signed export ACCEPTED by golive_verify_export against the baked pub.
#   (c) tampered body REJECTED.
#   (d) unsigned (signature=null / signed=false) REJECTED.
#   (e) foreign-key signature REJECTED.
#   (f) rollback (gen <= last-good) REJECTED; forward step ACCEPTED.
#   (b) targetState=public entry for this node's domain, no marker yet -> the
#       agent drives the REAL driver's `commit`, and the REAL marker file gets
#       written with the right provider= line.
#   (b') targetState=internal entry, marker present -> agent drives `rollback`,
#       marker removed, release-state reverted to internal.
#   (b'') no entry for this node's domain (absence contract) -> agent does
#       NOTHING — no driver invocation, marker untouched.
#   (b''') idempotency: a targetState=public entry matching the marker's
#       ALREADY-recorded provider -> agent does NOT re-invoke the driver (no
#       new driver.log line).
#   (g) defaults INERT: with no BFF_EXPORT_URL / no key, the agent keeps cache,
#       exits 0, applies nothing.
#   (g') placeholder/missing key -> fail-closed, no apply (crypto gate).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/specs/usr/lib/snapdragon/golive-verify.sh"
AGENT="${REPO}/specs/usr/sbin/snapdragon-go-live-reconcile"
DRIVER="${REPO}/specs/usr/sbin/snapdragon-go-live"
PROVIDERS_LIB="${REPO}/specs/usr/lib/snapdragon/go-live-providers.sh"

[ -r "${LIB}" ]    || { echo "  FAIL verify lib missing: ${LIB}"; exit 1; }
[ -r "${AGENT}" ]  || { echo "  FAIL agent missing: ${AGENT}"; exit 1; }
[ -r "${DRIVER}" ] || { echo "  FAIL driver missing: ${DRIVER}"; exit 1; }
for t in openssl jq base64; do command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== go-live wizard web-UI effector: verify + apply offline test =="

# ── Ephemeral signing key + the baked public half (base64 X.509 SPKI DER) ───────────
PRIV="${WORK}/priv.pem"; PUB_B64="${WORK}/registry-pub.ed25519"
openssl genpkey -algorithm ed25519 -out "${PRIV}" 2>/dev/null || { echo "SKIP: no ed25519"; exit 0; }
openssl pkey -in "${PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${PUB_B64}"
FPRIV="${WORK}/foreign.pem"
openssl genpkey -algorithm ed25519 -out "${FPRIV}" 2>/dev/null

# shellcheck source=/dev/null
. "${LIB}" || { echo "  FAIL could not source ${LIB}"; exit 1; }

NODE="mkey:abc"; GEN=7; DOM="acme.snapdragon.systems"
# Build a signed go-live export carrying ONE entry (this node's domain), signed by $1
# (priv pem) at generation $2. Sign the FILE (not a captured string — command substitution
# strips trailing newlines and would diverge from what verify_sig reads).
make_signed_export() {
    local priv="$1" gen="$2" out="$3" state="${4:-public}" provider="${5:-generic-registrar}" dom="${6:-${DOM}}"
    local body
    body="$(jq -n --argjson gen "${gen}" --arg node "${NODE}" --arg state "${state}" \
                  --arg provider "${provider}" --arg dom "${dom}" '{
        node: $node,
        generation: $gen,
        entries: (if $state == "" then [] else [
            { clusterDomain: $dom, targetState: $state,
              exposureModel: (if $state == "public" then "tunnel" else "" end),
              provider: (if $state == "public" then $provider else "" end),
              requestedBy: "superadmin@acme.snapdragon.systems", intentId: "intent-1", generation: $gen }
        ] end)
    }')"
    jq -n --argjson b "${body}" '{ body:$b, contentHash:"x", signature:null, publicKey:"advertised-ignored", signed:false }' > "${out}"
    local canonf sig
    canonf="$(mktemp)"
    golive_canonical_bytes "${out}" > "${canonf}"
    sig="$(openssl pkeyutl -sign -inkey "${priv}" -rawin -in "${canonf}" 2>/dev/null | base64 -w0)"
    rm -f "${canonf}"
    jq --arg sig "${sig}" '.signature=$sig | .signed=true' "${out}" > "${out}.s" && mv "${out}.s" "${out}"
}

# ── Case 0: canonical reconstruction matches an inline reference byte-for-byte ───────
canon_ref() {
    printf 'v1-golive\n'
    printf 'node=%s\n' "${NODE}"
    printf 'generation=%s\n' "${GEN}"
    printf 'dom=%s\tstate=%s\tmodel=%s\tprovider=%s\tby=%s\tintent=%s\tgen=%s\n' \
        "${DOM}" "public" "tunnel" "generic-registrar" "superadmin@acme.snapdragon.systems" "intent-1" "${GEN}"
}
make_signed_export "${PRIV}" "${GEN}" "${WORK}/good.json" "public" "generic-registrar" "${DOM}"
REFC="${WORK}/ref.bin"; canon_ref > "${REFC}"
RECON="${WORK}/recon.bin"; golive_canonical_bytes "${WORK}/good.json" > "${RECON}" 2>/dev/null
if cmp -s "${REFC}" "${RECON}"; then
    ok "golive_canonical_bytes matches the inline canon_ref bytes (byte-for-byte)"
else
    bad "canonical reconstruction DIVERGED from the inline reference"; echo "    want:"; od -An -tx1 "${REFC}" | head -4; echo "    got:"; od -An -tx1 "${RECON}" | head -4
fi

# ── Case 0b: independent second implementation (pure python, re-derived from the SAME
# GoLiveExportService.canonicalBytes Java source, not just re-running the jq program) ──
if command -v python3 >/dev/null 2>&1; then
    PY_HEX="$(python3 - "${WORK}/good.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
b = d["body"]
out = "v1-golive\n"
out += "node=" + (b.get("node") or "") + "\n"
out += "generation=" + str(b.get("generation") or 0) + "\n"
for e in b.get("entries") or []:
    out += (
        "dom=" + (e.get("clusterDomain") or "")
        + "\tstate=" + (e.get("targetState") or "")
        + "\tmodel=" + (e.get("exposureModel") or "")
        + "\tprovider=" + (e.get("provider") or "")
        + "\tby=" + (e.get("requestedBy") or "")
        + "\tintent=" + (e.get("intentId") or "")
        + "\tgen=" + str(e.get("generation") or 0)
        + "\n"
    )
sys.stdout.write(out.encode("utf-8").hex())
PY
)"
    RECON_HEX="$(od -An -tx1 "${RECON}" | tr -d '[:space:]')"
    if [ -n "${PY_HEX}" ] && [ "${PY_HEX}" = "${RECON_HEX}" ]; then
        ok "(0b) golive_canonical_bytes byte-equals an INDEPENDENT python re-derivation"
    else
        bad "(0b) bash/jq reconstruction diverged from the independent python re-derivation"
        echo "    python: ${PY_HEX}"; echo "    bash:   ${RECON_HEX}"
    fi
else
    echo "  SKIP (0b) needs python3"
fi

# ── Case (a): genuine signed export ACCEPTED ────────────────────────────────────────
if golive_verify_export "${WORK}/good.json" "${PUB_B64}"; then ok "(a) genuine signed export ACCEPTED"; else bad "(a) rejected a valid export"; fi

# ── Case (c): tampered body REJECTED ────────────────────────────────────────────────
jq '.body.entries[0].provider="EVIL"' "${WORK}/good.json" > "${WORK}/tamper.json"
if golive_verify_export "${WORK}/tamper.json" "${PUB_B64}"; then bad "(c) ACCEPTED a tampered body (LEAK)"; else ok "(c) tampered body REJECTED"; fi

# ── Case (d): unsigned REJECTED (fail-closed) ───────────────────────────────────────
jq '.signed=false | .signature=null' "${WORK}/good.json" > "${WORK}/unsigned.json"
if golive_verify_export "${WORK}/unsigned.json" "${PUB_B64}"; then bad "(d) ACCEPTED an unsigned export"; else ok "(d) unsigned export REJECTED (fail-closed)"; fi

# ── Case (e): foreign-key signature REJECTED ────────────────────────────────────────
make_signed_export "${FPRIV}" "${GEN}" "${WORK}/foreign.json" "public" "generic-registrar" "${DOM}"
if golive_verify_export "${WORK}/foreign.json" "${PUB_B64}"; then bad "(e) ACCEPTED a foreign-key signature"; else ok "(e) foreign-key signature REJECTED"; fi

# ── Case (f): rollback REJECTED + forward step ACCEPTED (strict-monotonic guard) ─────
LG="${WORK}/last-good"; printf '5' > "${LG}"
if golive_verify_export "${WORK}/good.json" "${PUB_B64}" "${LG}"; then ok "(f) ACCEPT gen=7 > last-good=5 (forward step)"; else bad "(f) rejected a valid forward generation"; fi
printf '7' > "${LG}"
if golive_verify_export "${WORK}/good.json" "${PUB_B64}" "${LG}"; then bad "(f) ACCEPTED gen==last-good (replay)"; else ok "(f) REJECT gen==last-good (replay)"; fi
printf '9' > "${LG}"
if golive_verify_export "${WORK}/good.json" "${PUB_B64}" "${LG}"; then bad "(f) ACCEPTED gen<last-good (rollback)"; else ok "(f) REJECT gen<last-good (rollback)"; fi

# ────────────────────────────────────────────────────────────────────────────────────
# APPLY-SIDE TESTS — source the agent with GLR_* seams (the main guard prevents auto-run),
# driving the REAL driver against a sandboxed GL_ETC_SNAPDRAGON (never the real host /etc).
# ────────────────────────────────────────────────────────────────────────────────────
SANDBOX_ETC="${WORK}/etc-snapdragon"
mkdir -p "${SANDBOX_ETC}"
printf '%s' "${DOM}" > "${SANDBOX_ETC}/cluster-domain"

GLR_NODE_ENV="${WORK}/node.env"
GLR_PUB_KEY="${PUB_B64}"
GLR_CACHE_DIR="${WORK}/cache"
GLR_VERIFY_LIB="${LIB}"
GLR_DRIVER="${DRIVER}"
GL_ETC_SNAPDRAGON="${SANDBOX_ETC}"
GL_PROVIDERS_LIB="${PROVIDERS_LIB}"
export GLR_NODE_ENV GLR_PUB_KEY GLR_CACHE_DIR GLR_VERIFY_LIB GLR_DRIVER GL_ETC_SNAPDRAGON GL_PROVIDERS_LIB
mkdir -p "${GLR_CACHE_DIR}"
# shellcheck source=/dev/null
. "${AGENT}"   # main is guarded; this just loads the functions with the GLR_* config

# ── Case (b): targetState=public, no marker yet -> agent drives REAL commit ──────────
# The export carries the BFF-side key "generic-registrar" (GoLiveProviderCatalog's
# vocabulary); the marker must show the MAPPED shell-side id "byo-domain"
# (GO_LIVE_PROVIDER_IDS's vocabulary, what glp_known() actually validates) — this
# IS the map_bff_provider() translation under test, not a bug if they differ.
entry_public="$(jq -c '.body.entries[0]' "${WORK}/good.json")"
apply_entry "${entry_public}"
MARKER="${SANDBOX_ETC}/go-live"
if [ -e "${MARKER}" ] && grep -qE '^provider=byo-domain$' "${MARKER}"; then
    ok "(b) agent drove the REAL driver's commit — marker written with the MAPPED shell provider byo-domain (export said generic-registrar)"
else
    bad "(b) marker not written as expected"; [ -e "${MARKER}" ] && cat "${MARKER}"
fi
if grep -qE '^public$' "${SANDBOX_ETC}/release-state" 2>/dev/null; then
    ok "(b) --persist-public also persisted release-state=public"
else
    bad "(b) release-state was not persisted to public"
fi

# ── Case (b'''): idempotency — same public entry again -> NO new driver invocation ───
LOG_LINES_BEFORE="$(wc -l < "${GLR_CACHE_DIR}/driver.log" 2>/dev/null || echo 0)"
apply_entry "${entry_public}"
LOG_LINES_AFTER="$(wc -l < "${GLR_CACHE_DIR}/driver.log" 2>/dev/null || echo 0)"
if [ "${LOG_LINES_BEFORE}" = "${LOG_LINES_AFTER}" ]; then
    ok "(b''') idempotent: an already-converged public entry did NOT re-invoke the driver"
else
    bad "(b''') driver was re-invoked for an already-converged entry (log grew ${LOG_LINES_BEFORE} -> ${LOG_LINES_AFTER})"
fi

# ── Case (b'): targetState=internal, marker present -> agent drives REAL rollback ────
make_signed_export "${PRIV}" 8 "${WORK}/rollback.json" "internal" "" "${DOM}"
entry_internal="$(jq -c '.body.entries[0]' "${WORK}/rollback.json")"
apply_entry "${entry_internal}"
if [ ! -e "${MARKER}" ]; then
    ok "(b') agent drove the REAL driver's rollback — marker removed"
else
    bad "(b') marker still present after a targetState=internal apply"
fi
if grep -qE '^internal$' "${SANDBOX_ETC}/release-state" 2>/dev/null; then
    ok "(b') --revert-release-state reverted release-state to internal"
else
    bad "(b') release-state was not reverted to internal"
fi

# ── Case (b''''): rollback convergence checks EFFECTIVE posture, not marker-only ─────
# Regression case: an earlier version of apply_entry() treated "marker absent" as
# "already internal" and skipped rollback — even when release-state=public was
# STILL set (e.g. a prior --persist-public survived a marker deleted out of
# band). That silently stranded the host in a released-public state forever
# against an explicit rollback intent, with no signal to the superadmin (the ack
# path is inert). Reproduce exactly that stranded state and assert the agent
# still drives a real rollback to close it out.
printf 'public\n' > "${SANDBOX_ETC}/release-state"
rm -f "${MARKER}"
apply_entry "${entry_internal}"
if grep -qE '^internal$' "${SANDBOX_ETC}/release-state" 2>/dev/null; then
    ok "(b'''') rollback convergence checks effective posture: marker-absent-but-release-state=public still triggers a real rollback"
else
    bad "(b'''') release-state=public with an absent marker was wrongly treated as already-converged — rollback never applied (regression)"
fi

# ── Case (b''): absence contract — no entry for this node's domain -> no-op ──────────
make_signed_export "${PRIV}" 9 "${WORK}/other-domain.json" "public" "generic-registrar" "other-brand.snapdragon.systems"
NO_ENTRY="$(gv_entry_for_domain "${WORK}/other-domain.json" "${DOM}")"
if [ -z "${NO_ENTRY}" ]; then
    ok "(b'') absence contract: no entry found for this node's own domain in a foreign-domain export"
else
    bad "(b'') incorrectly matched an entry for a different domain"
fi
[ -e "${MARKER}" ] || ok "(b'') marker correctly stays absent (no entry means no-op, not a rollback)"

# ── Case (m): BFF-to-shell provider-catalog mapping (map_bff_provider) ───────────────
# admin-bff-api's GoLiveProviderCatalog (6 keys) and the shell registry's
# GO_LIVE_PROVIDER_IDS (5 keys) diverged the same day they were both written and
# were never reconciled (see docs/GO-LIVE-WIZARD.md + the platform TODO queue).
# Assert every real BFF key maps to a shell id glp_known() actually accepts, AND
# that commit --provider <mapped-id> succeeds against the REAL provider registry
# for every single one — not just byo-domain/generic-registrar (case (b) above).
declare -A BFF_TO_SHELL=(
    [cloudflare-tunnel]=cloudflare-tunnel
    [generic-registrar]=byo-domain
    [duckdns]=duckdns
    [cloudflare-ddns]=duckdns
    [tailscale-funnel]=tailscale-funnel
    [router-portforward]=router-portforward
)
MAP_ALL_OK=1
for bff_key in "${!BFF_TO_SHELL[@]}"; do
    want="${BFF_TO_SHELL[${bff_key}]}"
    got="$(map_bff_provider "${bff_key}")"
    if [ "${got}" != "${want}" ]; then
        bad "(m) map_bff_provider(${bff_key}) = '${got}', want '${want}'"
        MAP_ALL_OK=0
    fi
    # glp_known() is the REAL gate cmd_commit() enforces — assert the mapped id
    # is actually known to the real, current provider registry, not just that
    # the mapping table's RHS looks right.
    if ! ( . "${PROVIDERS_LIB}"; glp_known "${want}" ); then
        bad "(m) mapped shell id '${want}' (for BFF key ${bff_key}) is NOT known to the real go-live-providers.sh registry — mapping is stale"
        MAP_ALL_OK=0
    fi
done
[ "${MAP_ALL_OK}" = "1" ] && ok "(m) all 6 BFF provider keys map to a shell id known to the REAL provider registry"

# End-to-end: an export recorded with the BFF key "cloudflare-ddns" (which does
# NOT exist in the shell registry at all) must still successfully trip commit,
# proving this isn't just a table lookup but actually unblocks the intent.
make_signed_export "${PRIV}" 10 "${WORK}/ddns.json" "public" "cloudflare-ddns" "${DOM}"
entry_ddns="$(jq -c '.body.entries[0]' "${WORK}/ddns.json")"
rm -f "${MARKER}"
apply_entry "${entry_ddns}"
if [ -e "${MARKER}" ] && grep -qE '^provider=duckdns$' "${MARKER}"; then
    ok "(m) an export for the BFF-only key 'cloudflare-ddns' (no shell equivalent) still applies — mapped to duckdns"
else
    bad "(m) 'cloudflare-ddns' entry failed to apply end-to-end"; [ -e "${MARKER}" ] && cat "${MARKER}"
fi

# An unrecognized/future BFF key must fail closed (skip, retry next cycle) —
# NOT crash the agent or fall through to calling the driver with a garbage
# --provider value.
make_signed_export "${PRIV}" 11 "${WORK}/unknown-provider.json" "public" "some-future-provider-nobody-mapped-yet" "${DOM}"
entry_unknown="$(jq -c '.body.entries[0]' "${WORK}/unknown-provider.json")"
BEFORE_LOG="$(wc -l < "${GLR_CACHE_DIR}/driver.log" 2>/dev/null || echo 0)"
if apply_entry "${entry_unknown}"; then
    bad "(m) apply_entry succeeded for an unmapped provider key (should fail closed)"
else
    AFTER_LOG="$(wc -l < "${GLR_CACHE_DIR}/driver.log" 2>/dev/null || echo 0)"
    if [ "${BEFORE_LOG}" = "${AFTER_LOG}" ]; then
        ok "(m) an unrecognized BFF provider key fails closed — no driver invocation, no crash"
    else
        bad "(m) an unrecognized BFF provider key still invoked the driver (log grew)"
    fi
fi

# ── Case (g): defaults INERT — no transport, no key -> keep cache, exit 0, apply nothing ─
G_MARKER_ETC="${WORK}/inert-etc"; mkdir -p "${G_MARKER_ETC}"
printf '%s' "${DOM}" > "${G_MARKER_ETC}/cluster-domain"
printf 'MACHINE_KEY_FP=mkey:abc\nBFF_EXPORT_URL=\nBFF_CLIENT_CERT=\nBFF_CLIENT_KEY=\n' > "${WORK}/node-empty.env"
env GLR_NODE_ENV="${WORK}/node-empty.env" GLR_PUB_KEY="${PUB_B64}" GLR_CACHE_DIR="${WORK}/inert-cache" \
    GLR_VERIFY_LIB="${LIB}" GLR_DRIVER="${DRIVER}" GL_ETC_SNAPDRAGON="${G_MARKER_ETC}" GL_PROVIDERS_LIB="${PROVIDERS_LIB}" \
    bash "${AGENT}" >/dev/null 2>&1
RC=$?
if [ "${RC}" -eq 0 ] && [ ! -e "${G_MARKER_ETC}/go-live" ]; then
    ok "(g) defaults INERT: no BFF URL -> exit 0, marker untouched"
else
    bad "(g) agent was NOT inert at defaults (rc=${RC})"
fi

# ── Case (g'): placeholder/missing key -> fail-closed, no apply (crypto gate) ────────
G2_ETC="${WORK}/inert2-etc"; mkdir -p "${G2_ETC}"
printf '%s' "${DOM}" > "${G2_ETC}/cluster-domain"
printf 'MACHINE_KEY_FP=mkey:abc\nBFF_EXPORT_URL=https://api.example.test\nBFF_CLIENT_CERT=/nonexistent\nBFF_CLIENT_KEY=/nonexistent\n' > "${WORK}/node-keyless.env"
env GLR_NODE_ENV="${WORK}/node-keyless.env" GLR_PUB_KEY="/nonexistent-placeholder-key" GLR_CACHE_DIR="${WORK}/inert2-cache" \
    GLR_VERIFY_LIB="${LIB}" GLR_DRIVER="${DRIVER}" GL_ETC_SNAPDRAGON="${G2_ETC}" GL_PROVIDERS_LIB="${PROVIDERS_LIB}" \
    bash "${AGENT}" >/dev/null 2>&1
RC2=$?
if [ "${RC2}" -eq 0 ] && [ ! -e "${G2_ETC}/go-live" ]; then
    ok "(g') missing baked pubkey -> fail-closed exit 0, marker untouched (crypto gate)"
else
    bad "(g') keyless agent applied a state change (rc=${RC2})"
fi

echo
echo "== go-live web-UI effector: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
