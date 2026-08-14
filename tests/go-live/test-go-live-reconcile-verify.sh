#!/usr/bin/env bash
# test-go-live-reconcile-verify.sh — offline logic test for the go-live wizard's
# fourth (web-UI) interface leg: the verify lib
# (specs/usr/lib/hugmesh/golive-verify.sh) + the agent's apply seams
# (specs/usr/sbin/hugmesh-go-live-reconcile sourced with GLR_* env seams,
# driving the REAL specs/usr/sbin/hugmesh-go-live driver sandboxed via
# GL_ETC_HUGMESH).
#
# Runs ANYWHERE with bash + jq + openssl + base64 — NO live mesh, NO BFF, NO
# network, NO root. FAILS (exit 1) if a required tool is genuinely absent.
# Mirrors tests/domain-registry/test-domain-reconcile-verify.sh step for step
# for the verify half; the apply half is new (go-live-specific: drive the real
# commit/rollback subcommands and assert on the REAL marker file the driver
# writes, in a sandboxed --etc-hugmesh, never touching the real host /etc).
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
#   (n) applied-ack writeback (ack_intent(), wired into apply_entry()): a
#       successful ack POSTs the correct URL/body right after a real commit.
#   (n') a FAILING ack (non-2xx) does not fail apply_entry() nor undo the
#       already-successful posture change (best-effort writeback).
#   (n'') the ack body carries THIS ROW's own generation, not the export
#       envelope's top-level generation (a fixture where the two deliberately
#       differ would catch either one leaking into the other).
#   (n''') an already-converged (idempotent no-op) re-apply of the same entry
#       STILL re-acks (self-healing until the BFF prunes an applied intent
#       from its next export — see (o) for why this can't be suppressed).
#   (o) a brand-new intentId whose target already matches the currently-
#       converged posture IS acked on its very first cycle (regression test:
#       an earlier version of this agent skipped ack_intent() on the
#       converged-no-op path entirely, which stranded exactly this case at
#       applied=false on the BFF forever).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/specs/usr/lib/hugmesh/golive-verify.sh"
AGENT="${REPO}/specs/usr/sbin/hugmesh-go-live-reconcile"
DRIVER="${REPO}/specs/usr/sbin/hugmesh-go-live"
PROVIDERS_LIB="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh"

[ -r "${LIB}" ]    || { echo "  FAIL verify lib missing: ${LIB}"; exit 1; }
[ -r "${AGENT}" ]  || { echo "  FAIL agent missing: ${AGENT}"; exit 1; }
[ -r "${DRIVER}" ] || { echo "  FAIL driver missing: ${DRIVER}"; exit 1; }
# Tool preflight is FAIL-CLOSED (tests/lib/guard-preflight.sh): a missing tool
# makes this guard exit 1, never 0. The old `SKIP … exit 0` shape turned an
# under-provisioned CI image into a green check. Deliberate local opt-out:
# GUARD_TOOLING_ALLOW_SKIP=1 — a name .gitlab-ci.yml is forbidden to contain.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-preflight.sh"
guard_require_tools openssl jq base64

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== go-live wizard web-UI effector: verify + apply offline test =="

# ── Ephemeral signing key + the baked public half (base64 X.509 SPKI DER) ───────────
PRIV="${WORK}/priv.pem"; PUB_B64="${WORK}/registry-pub.ed25519"
openssl genpkey -algorithm ed25519 -out "${PRIV}" 2>/dev/null || guard_require_capability "openssl cannot mint ed25519 keys"
openssl pkey -in "${PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${PUB_B64}"
FPRIV="${WORK}/foreign.pem"
openssl genpkey -algorithm ed25519 -out "${FPRIV}" 2>/dev/null

# shellcheck source=/dev/null
. "${LIB}" || { echo "  FAIL could not source ${LIB}"; exit 1; }

NODE="mkey:abc"; GEN=7; DOM="acme.hugmesh.net"
# Build a signed go-live export carrying ONE entry (this node's domain), signed by $1
# (priv pem) at generation $2. Sign the FILE (not a captured string — command substitution
# strips trailing newlines and would diverge from what verify_sig reads).
make_signed_export() {
    local priv="$1" gen="$2" out="$3" state="${4:-public}" provider="${5:-byo-domain}" dom="${6:-${DOM}}"
    local body
    body="$(jq -n --argjson gen "${gen}" --arg node "${NODE}" --arg state "${state}" \
                  --arg provider "${provider}" --arg dom "${dom}" '{
        node: $node,
        generation: $gen,
        entries: (if $state == "" then [] else [
            { clusterDomain: $dom, targetState: $state,
              exposureModel: (if $state == "public" then "tunnel" else "" end),
              provider: (if $state == "public" then $provider else "" end),
              requestedBy: "superadmin@acme.hugmesh.net", intentId: "intent-1", generation: $gen }
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
        "${DOM}" "public" "tunnel" "generic-registrar" "superadmin@acme.hugmesh.net" "intent-1" "${GEN}"
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
# driving the REAL driver against a sandboxed GL_ETC_HUGMESH (never the real host /etc).
# ────────────────────────────────────────────────────────────────────────────────────
SANDBOX_ETC="${WORK}/etc-hugmesh"
mkdir -p "${SANDBOX_ETC}"
printf '%s' "${DOM}" > "${SANDBOX_ETC}/cluster-domain"

GLR_NODE_ENV="${WORK}/node.env"
GLR_PUB_KEY="${PUB_B64}"
GLR_CACHE_DIR="${WORK}/cache"
GLR_VERIFY_LIB="${LIB}"
GLR_DRIVER="${DRIVER}"
GL_ETC_HUGMESH="${SANDBOX_ETC}"
GL_PROVIDERS_LIB="${PROVIDERS_LIB}"
export GLR_NODE_ENV GLR_PUB_KEY GLR_CACHE_DIR GLR_VERIFY_LIB GLR_DRIVER GL_ETC_HUGMESH GL_PROVIDERS_LIB
mkdir -p "${GLR_CACHE_DIR}"
# shellcheck source=/dev/null
. "${AGENT}"   # main is guarded; this just loads the functions with the GLR_* config

# ── Case (b): targetState=public, no marker yet -> agent drives REAL commit ──────────
# The export deliberately carries the LEGACY BFF key "generic-registrar" — the
# value pre-rename node images / cached exports / un-re-keyed go_live_intent rows
# still emit after the BFF renamed its catalog key to "byo-domain". It must still
# map to the shell-side id "byo-domain" (GO_LIVE_PROVIDER_IDS's vocabulary, what
# glp_known() validates) via the RETAINED legacy alias — this is the fleet-skew
# backward-compat path under test (the post-rename identity path is exercised by
# the "byo-domain" end-to-end case under (m) below).
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
make_signed_export "${PRIV}" 9 "${WORK}/other-domain.json" "public" "generic-registrar" "other-brand.hugmesh.net"
NO_ENTRY="$(gv_entry_for_domain "${WORK}/other-domain.json" "${DOM}")"
if [ -z "${NO_ENTRY}" ]; then
    ok "(b'') absence contract: no entry found for this node's own domain in a foreign-domain export"
else
    bad "(b'') incorrectly matched an entry for a different domain"
fi
[ -e "${MARKER}" ] || ok "(b'') marker correctly stays absent (no entry means no-op, not a rollback)"

# ── Case (m): BFF-to-shell provider-catalog mapping (map_bff_provider) ───────────────
# admin-bff-api's GoLiveProviderCatalog and the shell registry's
# GO_LIVE_PROVIDER_IDS diverged the same day they were both written; the drift
# is now RECONCILED BY IDENTITY — the BFF renamed its `generic-registrar` row to
# `byo-domain` to match the shell registry (see docs/GO-LIVE-WIZARD.md). This
# table therefore asserts BOTH: (1) every CURRENT BFF catalog key (with the
# renamed `byo-domain`) maps to a shell id glp_known() accepts, AND (2) the
# retained LEGACY ALIAS `generic-registrar` still resolves to `byo-domain` so
# pre-rename node images / cached exports / un-re-keyed DB rows keep applying.
# `cloudflare-ddns` is NOT part of the rename — it is the deliberate
# duckdns --ddns-service=cloudflare driver-suboption collapse (case (b) above
# drives the legacy alias end-to-end; the byo-domain identity case below drives
# the post-rename value end-to-end).
declare -A BFF_TO_SHELL=(
    [cloudflare-tunnel]=cloudflare-tunnel
    [byo-domain]=byo-domain          # post-rename identity (the norm going forward)
    [generic-registrar]=byo-domain   # retained LEGACY ALIAS (pre-rename images/exports/rows)
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
[ "${MAP_ALL_OK}" = "1" ] && ok "(m) all 7 provider keys (6 current BFF keys incl. renamed byo-domain + the retained generic-registrar legacy alias) map to a shell id known to the REAL provider registry"

# End-to-end: an export carrying the POST-RENAME identity key "byo-domain" (what
# the BFF now emits after generic-registrar -> byo-domain) applies and stamps the
# marker with provider=byo-domain — the identity path, complementing case (b)'s
# legacy-alias path.
make_signed_export "${PRIV}" 10 "${WORK}/byo.json" "public" "byo-domain" "${DOM}"
entry_byo="$(jq -c '.body.entries[0]' "${WORK}/byo.json")"
rm -f "${MARKER}" "${SANDBOX_ETC}/release-state"
apply_entry "${entry_byo}"
if [ -e "${MARKER}" ] && grep -qE '^provider=byo-domain$' "${MARKER}"; then
    ok "(m) a POST-RENAME export for the identity key 'byo-domain' applies end-to-end — marker provider=byo-domain"
else
    bad "(m) 'byo-domain' identity entry failed to apply end-to-end"; [ -e "${MARKER}" ] && cat "${MARKER}"
fi

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

# ────────────────────────────────────────────────────────────────────────────────────
# APPLIED-ACK TESTS — ack_intent(), wired into apply_entry() right after a REAL
# commit/rollback it drove. A stub `curl` is installed on PATH ONLY for the
# duration of each apply_entry() call below (`PATH=... VAR=... apply_entry`,
# bash's per-command environment-override idiom — verified to revert after the
# call returns, so it can never leak into a later case), so it intercepts ONLY
# the ack POST (apply_entry()'s only other subprocess is the REAL driver via
# `bash "${DRIVER}" ...`, which never calls curl). It logs every request's URL
# + -d body to ACK_STUB_DIR/requests.log and exits 0 or 22 (mirroring curl
# --fail's own exit code on an HTTP error response) per ACK_STUB_DIR/mode.
# ────────────────────────────────────────────────────────────────────────────────────
ACK_STUB_DIR="${WORK}/ack-stub"; mkdir -p "${ACK_STUB_DIR}/bin"
cat > "${ACK_STUB_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
dir="${ACK_STUB_DIR:?ACK_STUB_DIR unset}"
mode="success"
[ -r "${dir}/mode" ] && mode="$(cat "${dir}/mode")"
url="${@: -1}"
body=""
prev=""
for a in "$@"; do
    [ "${prev}" = "-d" ] && body="${a}"
    prev="${a}"
done
{
    printf 'URL=%s\n' "${url}"
    printf 'BODY=%s\n' "${body}"
    printf -- '---\n'
} >> "${dir}/requests.log"
[ "${mode}" = "fail" ] && exit 22
exit 0
EOF
chmod +x "${ACK_STUB_DIR}/bin/curl"
export ACK_STUB_DIR
printf 'success\n' > "${ACK_STUB_DIR}/mode"
ACK_NODE_FP="mkey:ack-node-test"
ACK_BFF="https://bff.ack-test.invalid"
CERT_FILE="${WORK}/mtls-cert.pem"; KEY_FILE="${WORK}/mtls-key.pem"
printf 'dummy-cert\n' > "${CERT_FILE}"; printf 'dummy-key\n' > "${KEY_FILE}"

# ── Case (n): successful ack fires with the correct URL/body right after a REAL commit ──
rm -f "${MARKER}" "${SANDBOX_ETC}/release-state" "${ACK_STUB_DIR}/requests.log"
entry_ack_ok="$(jq -nc --arg dom "${DOM}" '{
    clusterDomain:$dom, targetState:"public", exposureModel:"tunnel",
    provider:"generic-registrar", requestedBy:"superadmin@acme.hugmesh.net",
    intentId:"intent-ack-ok", generation:321
}')"
PATH="${ACK_STUB_DIR}/bin:${PATH}" MACHINE_KEY_FP="${ACK_NODE_FP}" BFF_URL="${ACK_BFF}" \
    MTLS_CERT="${CERT_FILE}" MTLS_KEY="${KEY_FILE}" MTLS_CA="/nonexistent-ca" \
    apply_entry "${entry_ack_ok}"
REQ_COUNT="$(grep -c '^URL=' "${ACK_STUB_DIR}/requests.log" 2>/dev/null || echo 0)"
REQ_LINE="$(grep '^URL=' "${ACK_STUB_DIR}/requests.log" | tail -1)"
BODY_LINE="$(grep '^BODY=' "${ACK_STUB_DIR}/requests.log" | tail -1)"
if [ "${REQ_COUNT}" = "1" ] && [ "${REQ_LINE}" = "URL=${ACK_BFF}/bff/internal/go-live/intent-ack-ok/applied-ack" ]; then
    ok "(n) ack POSTed to the correct URL (derived from BFF_URL) right after a real commit"
else
    bad "(n) ack URL wrong or missing (count=${REQ_COUNT}): '${REQ_LINE}'"
fi
EXPECT_BODY="BODY={\"generation\":321,\"appliedBy\":\"${ACK_NODE_FP}\"}"
if [ "${BODY_LINE}" = "${EXPECT_BODY}" ]; then
    ok "(n) ack body carries this entry's own generation + this node's appliedBy fingerprint"
else
    bad "(n) ack body wrong: got '${BODY_LINE}', want '${EXPECT_BODY}'"
fi

# ── Case (n'): a FAILING ack (non-2xx) does not fail apply_entry() nor the posture change ─
rm -f "${MARKER}" "${SANDBOX_ETC}/release-state" "${ACK_STUB_DIR}/requests.log"
printf 'fail\n' > "${ACK_STUB_DIR}/mode"
entry_ack_fail="$(jq -nc --arg dom "${DOM}" '{
    clusterDomain:$dom, targetState:"public", exposureModel:"tunnel",
    provider:"generic-registrar", requestedBy:"superadmin@acme.hugmesh.net",
    intentId:"intent-ack-fail", generation:322
}')"
RC=0
PATH="${ACK_STUB_DIR}/bin:${PATH}" MACHINE_KEY_FP="${ACK_NODE_FP}" BFF_URL="${ACK_BFF}" \
    MTLS_CERT="${CERT_FILE}" MTLS_KEY="${KEY_FILE}" MTLS_CA="/nonexistent-ca" \
    apply_entry "${entry_ack_fail}" || RC=$?
if [ "${RC}" -eq 0 ]; then
    ok "(n') apply_entry() still returns success when the ack POST fails (non-2xx)"
else
    bad "(n') apply_entry() returned failure (rc=${RC}) just because the ack POST failed"
fi
if [ -e "${MARKER}" ] && grep -qE '^provider=byo-domain$' "${MARKER}"; then
    ok "(n') the posture change (marker write) landed regardless of the ack failure"
else
    bad "(n') marker missing/wrong after a commit whose ack POST failed"
fi
REQ_COUNT2="$(grep -c '^URL=' "${ACK_STUB_DIR}/requests.log" 2>/dev/null || echo 0)"
if [ "${REQ_COUNT2}" = "1" ]; then
    ok "(n') the failing ack was still attempted exactly once (best-effort, not silently skipped)"
else
    bad "(n') expected exactly one ack attempt, saw ${REQ_COUNT2}"
fi
printf 'success\n' > "${ACK_STUB_DIR}/mode"

# ── Case (n''): the ROW's own generation is acked, NOT the export envelope's ────────
# top-level generation. Build a FULL signed export where body.generation (the
# envelope, a max-over-all-rows value per golive-verify.sh's own doc) and
# body.entries[0].generation (THIS row's own stamp) are deliberately DIFFERENT
# numbers, so a bug that threaded the envelope's rv_gen (or any other outer
# generation) into the ack body instead of this entry's own .generation field
# would be caught here, not silently pass because the two usually coincide.
ENVELOPE_GEN=8000
ROW_GEN=42
ACK_SPLIT_INTENT="intent-split-gen"
split_body="$(jq -n --argjson envgen "${ENVELOPE_GEN}" --argjson rowgen "${ROW_GEN}" \
    --arg node "${NODE}" --arg dom "${DOM}" --arg intent "${ACK_SPLIT_INTENT}" '{
    node:$node, generation:$envgen,
    entries: [ { clusterDomain:$dom, targetState:"public", exposureModel:"tunnel",
                 provider:"generic-registrar", requestedBy:"superadmin@acme.hugmesh.net",
                 intentId:$intent, generation:$rowgen } ]
}')"
jq -n --argjson b "${split_body}" '{ body:$b, contentHash:"x", signature:null, publicKey:"advertised-ignored", signed:false }' > "${WORK}/split-gen.json"
split_canon="$(mktemp)"; golive_canonical_bytes "${WORK}/split-gen.json" > "${split_canon}"
split_sig="$(openssl pkeyutl -sign -inkey "${PRIV}" -rawin -in "${split_canon}" 2>/dev/null | base64 -w0)"
rm -f "${split_canon}"
jq --arg sig "${split_sig}" '.signature=$sig | .signed=true' "${WORK}/split-gen.json" > "${WORK}/split-gen.json.s" && mv "${WORK}/split-gen.json.s" "${WORK}/split-gen.json"
if golive_verify_export "${WORK}/split-gen.json" "${PUB_B64}"; then
    ok "(n'') split-generation fixture (envelope=${ENVELOPE_GEN} != row=${ROW_GEN}) verifies fine (envelope-vs-row is a semantic distinction, not a crypto one)"
else
    bad "(n'') split-generation fixture unexpectedly FAILED verification"
fi
entry_split="$(gv_entry_for_domain "${WORK}/split-gen.json" "${DOM}")"
rm -f "${MARKER}" "${SANDBOX_ETC}/release-state" "${ACK_STUB_DIR}/requests.log"
PATH="${ACK_STUB_DIR}/bin:${PATH}" MACHINE_KEY_FP="${ACK_NODE_FP}" BFF_URL="${ACK_BFF}" \
    MTLS_CERT="${CERT_FILE}" MTLS_KEY="${KEY_FILE}" MTLS_CA="/nonexistent-ca" \
    apply_entry "${entry_split}"
BODY_SPLIT="$(grep '^BODY=' "${ACK_STUB_DIR}/requests.log" | tail -1)"
EXPECT_SPLIT="BODY={\"generation\":${ROW_GEN},\"appliedBy\":\"${ACK_NODE_FP}\"}"
WRONG_SPLIT="BODY={\"generation\":${ENVELOPE_GEN},\"appliedBy\":\"${ACK_NODE_FP}\"}"
if [ "${BODY_SPLIT}" = "${EXPECT_SPLIT}" ]; then
    ok "(n'') ack body's generation is the ROW's own gen=${ROW_GEN}, not the envelope's gen=${ENVELOPE_GEN}"
elif [ "${BODY_SPLIT}" = "${WRONG_SPLIT}" ]; then
    bad "(n'') ack body carried the ENVELOPE's top-level generation (${ENVELOPE_GEN}) instead of this row's own (${ROW_GEN}) — would CAS-mismatch on the BFF side"
else
    bad "(n'') ack body unexpected: '${BODY_SPLIT}'"
fi

# ── Case (n'''): an already-converged (idempotent no-op) cycle DOES still re-ack ────
# apply_entry() calls ack_intent() from the converged-no-op branches too, not
# just the branches that actually drove the driver. This is a DELIBERATE
# correctness-over-cheapness trade-off: an earlier version suppressed the ack
# on the converged path, on the theory that "already converged" implies
# "already acked" — but that's false for a *freshly recorded* intent whose
# target happens to already match the currently-converged host posture (a
# re-affirmation, a UI double-submit, or re-recording after a withdraw): that
# intent's driver call is correctly skipped as a no-op, but it had NEVER been
# acked before, so skipping the ack too left its BFF row stuck at
# status=recorded/applied=false forever, with no automatic recovery (see case
# (o) below, which reproduces exactly that scenario).
#
# The safety argument against "unbounded ack load every 60s forever" is NOT
# client-side suppression — it's the BFF's own absence contract
# (GoLiveExportModels.java): a successful ack flips the row to status=applied
# server-side, which removes that entry from the NEXT signed export. Once
# acked, this node's next reconcile cycle never sees the entry at all, so
# apply_entry() is never even called for it again. The only case where this
# script re-acks an already-applied intent is if the ack itself keeps failing
# (see (n') — best-effort, retried every cycle until it lands, which is the
# desired self-healing behavior, not a bug) or if the BFF is slow to prune.
REQ_COUNT_BEFORE="$(grep -c '^URL=' "${ACK_STUB_DIR}/requests.log" 2>/dev/null || echo 0)"
PATH="${ACK_STUB_DIR}/bin:${PATH}" MACHINE_KEY_FP="${ACK_NODE_FP}" BFF_URL="${ACK_BFF}" \
    MTLS_CERT="${CERT_FILE}" MTLS_KEY="${KEY_FILE}" MTLS_CA="/nonexistent-ca" \
    apply_entry "${entry_split}"
REQ_COUNT_AFTER="$(grep -c '^URL=' "${ACK_STUB_DIR}/requests.log" 2>/dev/null || echo 0)"
if [ "${REQ_COUNT_AFTER}" = "$(( REQ_COUNT_BEFORE + 1 ))" ]; then
    ok "(n''') a converged no-op re-apply of the SAME entry still re-acks (count ${REQ_COUNT_BEFORE} -> ${REQ_COUNT_AFTER}) — self-healing until the BFF prunes it from the export"
else
    bad "(n''') expected exactly one new ack POST on a converged no-op re-apply (count ${REQ_COUNT_BEFORE} -> ${REQ_COUNT_AFTER})"
fi

# ── Case (o): a BRAND-NEW intentId whose target ALREADY matches the currently- ──────
# converged posture IS acked on its very first cycle (regression test for the
# bug this fix closes: the converged-path early-return used to skip
# ack_intent() entirely, so a fresh intent recorded for a state that happened
# to already be live would sit at applied=false on the BFF forever — and
# re-recording it did NOT help, since the replacement intent lands in exactly
# the same already-converged state).
entry_new_but_converged="$(jq -nc --arg dom "${DOM}" '{
    clusterDomain:$dom, targetState:"public", exposureModel:"tunnel",
    provider:"generic-registrar", requestedBy:"superadmin@acme.hugmesh.net",
    intentId:"intent-new-never-seen-before", generation:999
}')"
REQ_COUNT_BEFORE_O="$(grep -c '^URL=' "${ACK_STUB_DIR}/requests.log" 2>/dev/null || echo 0)"
PATH="${ACK_STUB_DIR}/bin:${PATH}" MACHINE_KEY_FP="${ACK_NODE_FP}" BFF_URL="${ACK_BFF}" \
    MTLS_CERT="${CERT_FILE}" MTLS_KEY="${KEY_FILE}" MTLS_CA="/nonexistent-ca" \
    apply_entry "${entry_new_but_converged}"
REQ_COUNT_AFTER_O="$(grep -c '^URL=' "${ACK_STUB_DIR}/requests.log" 2>/dev/null || echo 0)"
REQ_LINE_O="$(grep '^URL=' "${ACK_STUB_DIR}/requests.log" | tail -1)"
if [ "${REQ_COUNT_AFTER_O}" = "$(( REQ_COUNT_BEFORE_O + 1 ))" ] \
    && [ "${REQ_LINE_O}" = "URL=${ACK_BFF}/bff/internal/go-live/intent-new-never-seen-before/applied-ack" ]; then
    ok "(o) a brand-new intentId whose target already matches converged posture IS acked on its first cycle"
else
    bad "(o) a brand-new already-converged intentId was NOT acked (count ${REQ_COUNT_BEFORE_O} -> ${REQ_COUNT_AFTER_O}) — would strand this intent's BFF row at applied=false forever"
fi
rm -f "${MARKER}"; printf 'internal\n' > "${SANDBOX_ETC}/release-state" 2>/dev/null || true

# ── Case (g): defaults INERT — no transport, no key -> keep cache, exit 0, apply nothing ─
G_MARKER_ETC="${WORK}/inert-etc"; mkdir -p "${G_MARKER_ETC}"
printf '%s' "${DOM}" > "${G_MARKER_ETC}/cluster-domain"
printf 'MACHINE_KEY_FP=mkey:abc\nBFF_EXPORT_URL=\nBFF_CLIENT_CERT=\nBFF_CLIENT_KEY=\n' > "${WORK}/node-empty.env"
env GLR_NODE_ENV="${WORK}/node-empty.env" GLR_PUB_KEY="${PUB_B64}" GLR_CACHE_DIR="${WORK}/inert-cache" \
    GLR_VERIFY_LIB="${LIB}" GLR_DRIVER="${DRIVER}" GL_ETC_HUGMESH="${G_MARKER_ETC}" GL_PROVIDERS_LIB="${PROVIDERS_LIB}" \
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
    GLR_VERIFY_LIB="${LIB}" GLR_DRIVER="${DRIVER}" GL_ETC_HUGMESH="${G2_ETC}" GL_PROVIDERS_LIB="${PROVIDERS_LIB}" \
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
