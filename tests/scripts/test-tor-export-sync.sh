#!/usr/bin/env bash
# test-tor-export-sync.sh — the node half of hugmesh-admin-bff-api#108, offline
# (hugmesh-generator#629): specs/usr/sbin/hugmesh-tor-export-sync driven end to end
# against a sandbox node root, with curl STUBBED on PATH and the export SIGNED by a
# throwaway Ed25519 key whose public half is baked into the sandbox exactly as the key-USB
# bakes registry-pub.ed25519. openssl is REAL (a stubbed openssl would prove nothing about
# the signature path); the reconcile the agent re-runs after a write is a recording stub,
# except in the last leg, where the REAL hugmesh-tor-reconcile renders the torrc from the
# files the sync just wrote (rc-service / tor / id / chown stubbed, as the contract test
# does).
#
# WHAT IT PINS (every rule of #629, each one also mutation-proven in the PR):
#   V. tor-verify.sh reconstructs the canonical v1-tor bytes BYTE FOR BYTE against a
#      reference string (TorExportService.canonicalBytes).
#   A. verify FIRST: a good export is applied; a replay, a rolled-back generation, a
#      tampered body, an unsigned envelope, a foreign key and a foreign node fingerprint
#      (the unknown-fingerprint empty body included) change NOTHING and keep the files.
#   M. the four upstreamManaged / domainsManaged combinations, the empty upstream (file
#      removed) and the empty domain list (empty file), each touching only its own file.
#   W. atomic writes: a rename that never happens (a crash between write and rename)
#      leaves the OLD file in place and does not advance the last-applied generation;
#      a value the reconcile would ignore is refused before any write.
#   R. the report: body shape, sent after EVERY pass (accepted, refused, unchanged),
#      primary omitted when absent, stray files skipped, the X-Internal-Token header
#      only when a token file exists, a 422 logged and never fatal, the fingerprint
#      URL-encoded on the GET.
#   O. offline / missing-input fail-soft, --reset-generation (the reseed recovery).
#   E. the real hugmesh-tor-reconcile renders a stanza for a domain the sync wrote.
#
# WHAT IT CANNOT PROVE: a booted node talking to a live admin-bff (the live checks of
# #629 and #108); that is awaiting a live run.
#
#   bash tests/scripts/test-tor-export-sync.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${REPO}/specs/usr/sbin/hugmesh-tor-export-sync"
LIB="${REPO}/specs/usr/lib/hugmesh/tor-verify.sh"
RECONCILE="${REPO}/specs/usr/sbin/hugmesh-tor-reconcile"
for f in "${AGENT}" "${LIB}" "${RECONCILE}" "${REPO}/specs/usr/lib/hugmesh/registry-verify.sh"; do
    [ -f "${f}" ] || { echo "FAIL missing ${f}"; exit 1; }
done
for t in openssl jq base64 sha256sum cmp; do command -v "$t" >/dev/null || { echo "FAIL host lacks $t"; exit 1; }; done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
has()   { printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; }
hasnt() { ! has "$1" "$2"; }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# shellcheck source=/dev/null
. "${LIB}" || { echo "FAIL could not source ${LIB}"; exit 1; }
declare -F verify_sig >/dev/null || { echo "FAIL tor-verify.sh did not source registry-verify.sh"; exit 1; }

# ── keys: the baked public half + a foreign signer ──────────────────────────────────
PRIV="${WORK}/priv.pem"; PUB_B64="${WORK}/pub.b64"; FPRIV="${WORK}/foreign.pem"
openssl genpkey -algorithm ed25519 -out "${PRIV}" 2>/dev/null || { echo "SKIP: openssl has no ed25519"; exit 0; }
openssl pkey -in "${PRIV}" -pubout -outform DER 2>/dev/null | base64 -w0 > "${PUB_B64}"
openssl genpkey -algorithm ed25519 -out "${FPRIV}" 2>/dev/null

FP='nodekey:abc+/DEF123=='          # URL-hostile on purpose: '+' '/' '='
ONION_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion"
ONION_G="gggggggggggggggggggggggggggggggggggggggggggggggggggggggg.onion"
ONION_S="ssssssssssssssssssssssssssssssssssssssssssssssssssssssss.onion"

# make_export OUT PRIV GEN UM UP DM DOMAINS-JSON [NODE] — a signed envelope whose
# signature covers EXACTLY tor_canonical_bytes(body) (signed from a FILE: $(...) would
# strip the trailing newline the JVM signs).
make_export() {
    local out priv gen um up dm doms node body canonf sig
    out="$1"; priv="$2"; gen="$3"; um="$4"; up="$5"; dm="$6"; doms="$7"; node="${8-${FP}}"
    body="$(jq -nc --arg node "${node}" --argjson gen "${gen}" --argjson um "${um}" --arg up "${up}" \
                   --argjson dm "${dm}" --argjson doms "${doms}" \
        '{node:$node, generation:$gen, upstreamManaged:$um, upstream:$up, domainsManaged:$dm, domains:$doms}')"
    jq -n --argjson b "${body}" '{body:$b, contentHash:"x", signature:null, publicKey:"x", signed:false}' > "${out}"
    canonf="${WORK}/canon.$$"; tor_canonical_bytes "${out}" > "${canonf}"
    sig="$(openssl pkeyutl -sign -inkey "${priv}" -rawin -in "${canonf}" 2>/dev/null | base64 -w0)"
    jq --arg sig "${sig}" --arg h "$(sha256sum < "${canonf}" | cut -c1-64)" '.signature=$sig | .signed=true | .contentHash=$h' "${out}" > "${out}.s" && mv "${out}.s" "${out}"
    rm -f "${canonf}"
}

# ── stubs on PATH: curl (records GET + POST), reconcile (records runs), logger (quiet) ──
STUB="${WORK}/stub"; mkdir -p "${STUB}"
cat > "${STUB}/curl" <<'EOF'
#!/bin/bash
# GET  …/bff/admin/tor/export  -> serve $STATE_DIR/export.json into the -o file
# POST …/bff/internal/tor/onions -> record body + headers, answer $STATE_DIR/resp-code
mode=get; out=""; body=""; hdrs=""; url=""
args=("$@")
printf '%s\n' "${args[@]}" > "${STATE_DIR}/curl-last.argv"
i=0
while [ $i -lt ${#args[@]} ]; do
    a="${args[$i]}"
    case "$a" in
        -X) i=$((i+1)); [ "${args[$i]}" = POST ] && mode=post ;;
        -o) i=$((i+1)); out="${args[$i]}" ;;
        --data-binary) i=$((i+1)); body="${args[$i]}" ;;
        -H) i=$((i+1)); h="${args[$i]}"; case "$h" in @*) h="$(cat "${h#@}")" ;; esac; hdrs="${hdrs}${h}"$'\n' ;;
        http*|https*) url="$a" ;;
    esac
    i=$((i+1))
done
[ -e "${STATE_DIR}/offline" ] && { [ "$mode" = post ] && printf '000'; exit 7; }
if [ "$mode" = get ]; then
    printf '%s\n' "${args[@]}" >> "${STATE_DIR}/curl-get.log"; echo "GET ${url}" >> "${STATE_DIR}/curl.log"
    case "$url" in */bff/admin/tor/export) ;; *) echo "BAD-GET-URL ${url}" >> "${STATE_DIR}/curl.log"; exit 22 ;; esac
    [ -e "${STATE_DIR}/http-error" ] && exit 22
    cp "${STATE_DIR}/export.json" "$out" || exit 22
    exit 0
fi
echo "POST ${url}" >> "${STATE_DIR}/curl.log"
case "$url" in */bff/internal/tor/onions) ;; *) echo "BAD-POST-URL ${url}" >> "${STATE_DIR}/curl.log" ;; esac
n=$(grep -c '^POST' "${STATE_DIR}/curl.log")
cp "${body#@}" "${STATE_DIR}/report.${n}.json"
printf '%s' "${hdrs}" > "${STATE_DIR}/report.${n}.headers"
cat "${STATE_DIR}/resp-body" 2>/dev/null > "$out" || printf '{"accepted":true}' > "$out"
cat "${STATE_DIR}/resp-code" 2>/dev/null || printf '200'
exit 0
EOF
printf '#!/bin/bash\necho run >> "${STATE_DIR}/reconcile.log"\nexit 0\n' > "${STUB}/hugmesh-tor-reconcile"
printf '#!/bin/bash\nexit 0\n' > "${STUB}/logger"
chmod +x "${STUB}"/*

# ── a sandbox node root ───────────────────────────────────────────────────────────────
fresh() {  # NAME — node.env + baked key + mTLS files; the primary onion already exported
    R="${WORK}/node-$1"; STATE_DIR="${WORK}/state-$1"; export STATE_DIR
    rm -rf "${R}" "${STATE_DIR}"; mkdir -p "${R}/etc/hugmesh/registry" "${R}/var/lib/hugmesh/tor" "${STATE_DIR}"
    cp "${PUB_B64}" "${R}/etc/hugmesh/registry/registry-pub.ed25519"
    : > "${R}/etc/hugmesh/registry/bff.crt"; : > "${R}/etc/hugmesh/registry/bff.key"; : > "${R}/etc/hugmesh/registry/ca.crt"
    cat > "${R}/etc/hugmesh/registry/node.env" <<EOF
# device-registry node identity + BFF transport (Layer-B)
MACHINE_KEY_FP=${FP}
MESH_ID=east-01
BFF_EXPORT_URL=https://admin-bff.test:8443/bff/admin/device-licenses/export
BFF_CLIENT_CERT=${R}/etc/hugmesh/registry/bff.crt
BFF_CLIENT_KEY=${R}/etc/hugmesh/registry/bff.key
BFF_CA=${R}/etc/hugmesh/registry/ca.crt
EOF
    echo "${ONION_A}" > "${R}/var/lib/hugmesh/tor/hostname"
}
run_sync() {  # [extra env assignments...] — the real agent, stubs first on PATH
    env -u RC_SVCNAME HUGMESH_TOR_ROOT="${R}" HUGMESH_TOR_RECONCILE="${STUB}/hugmesh-tor-reconcile" \
        STATE_DIR="${STATE_DIR}" PATH="${STUB}:${PATH}" "$@" /bin/bash "${AGENT}" > "${STATE_DIR}/out.log" 2>&1
    RC=$?
}
out()        { cat "${STATE_DIR}/out.log" 2>/dev/null; }
upstream()   { cat "${R}/etc/hugmesh/tor/upstream" 2>/dev/null; }
domains()    { cat "${R}/etc/hugmesh/tor/domains" 2>/dev/null; }
last_good()  { cat "${R}/var/lib/hugmesh/tor-export/last-good-generation" 2>/dev/null | tr -d '[:space:]'; }
reconciles() { grep -c run "${STATE_DIR}/reconcile.log" 2>/dev/null || echo 0; }
posts()      { grep -c '^POST' "${STATE_DIR}/curl.log" 2>/dev/null || echo 0; }
gets()       { grep -c '^GET' "${STATE_DIR}/curl.log" 2>/dev/null || echo 0; }
report()     { cat "${STATE_DIR}/report.$(posts).json" 2>/dev/null; }
report_hdr() { cat "${STATE_DIR}/report.$(posts).headers" 2>/dev/null; }
sum()        { sha256sum "$1" 2>/dev/null | cut -c1-64; }
tree_sum()   { ( cd "${R}/etc/hugmesh" 2>/dev/null && find . -type f -path './tor/*' | sort | xargs -r sha256sum ) 2>/dev/null; }
mode_of()    { stat -c %a "$1" 2>/dev/null; }

# ═══════════════════════ V. the canonical bytes, byte for byte ═══════════════════════
echo "== V. tor-verify.sh canonical bytes =="
make_export "${WORK}/v.json" "${PRIV}" 7 true "10.0.0.7:443" true '["games","shop"]'
printf 'v1-tor\nnode=%s\ngeneration=7\nupstream-managed=true\nupstream=10.0.0.7:443\ndomains-managed=true\ndomain=games\ndomain=shop\n' "${FP}" > "${WORK}/v.ref"
tor_canonical_bytes "${WORK}/v.json" > "${WORK}/v.got"
cmp -s "${WORK}/v.ref" "${WORK}/v.got" && ok "V canonical bytes == TorExportService.canonicalBytes reference (header, flags, upstream, one domain= line per slug, every line \\n-terminated)" \
    || { bad "V canonical reconstruction diverged"; diff "${WORK}/v.ref" "${WORK}/v.got" | sed 's/^/      | /'; }
make_export "${WORK}/v0.json" "${PRIV}" 0 false "" false '[]' ""
printf 'v1-tor\nnode=\ngeneration=0\nupstream-managed=false\nupstream=\ndomains-managed=false\n' > "${WORK}/v0.ref"
tor_canonical_bytes "${WORK}/v0.json" > "${WORK}/v0.got"
cmp -s "${WORK}/v0.ref" "${WORK}/v0.got" && ok "V the unknown-fingerprint empty body reconstructs (no domain= lines, empty node=)" || bad "V empty body reconstruction diverged"
tor_verify_export "${WORK}/v.json" "${PUB_B64}" && ok "V tor_verify_export accepts the fixture against the baked key" || bad "V genuine fixture rejected by the library"
[ "$(jq -r .contentHash "${WORK}/v.json")" = "$(sha256sum < "${WORK}/v.ref" | cut -c1-64)" ] && ok "V fixture contentHash is SHA-256 of the same bytes (RegistrySigner.contentHash)" || bad "V fixture contentHash wrong"

# ═══════════════════════ A. verify first; apply; refuse everything else ═══════════════
echo "== A. fetch -> verify -> apply =="
fresh a
make_export "${STATE_DIR}/export.json" "${PRIV}" 5 true "10.0.0.7:443" true '["games","shop"]'
run_sync
[ "${RC}" -eq 0 ] && ok "A1 exits 0" || { bad "A1 exit ${RC}"; out | sed 's/^/      | /'; }
[ "$(upstream)" = "10.0.0.7:443" ] && [ "$(wc -l < "${R}/etc/hugmesh/tor/upstream")" -eq 1 ] && ok "A1 upstreamManaged=true -> /etc/hugmesh/tor/upstream holds the ONE line" || bad "A1 upstream file: '$(upstream)'"
[ "$(domains)" = $'games\nshop' ] && ok "A1 domainsManaged=true -> /etc/hugmesh/tor/domains holds exactly the slugs, one per line" || bad "A1 domains file: '$(domains)'"
[ "$(mode_of "${R}/etc/hugmesh/tor/upstream")" = 644 ] && [ "$(mode_of "${R}/etc/hugmesh/tor/domains")" = 644 ] && ok "A1 both files 0644" || bad "A1 modes $(mode_of "${R}/etc/hugmesh/tor/upstream") $(mode_of "${R}/etc/hugmesh/tor/domains")"
[ "$(last_good)" = 5 ] && ok "A1 last-applied generation recorded = 5" || bad "A1 last-good '$(last_good)'"
[ "$(jq -r .body.generation "${R}/var/lib/hugmesh/tor-export/export.json" 2>/dev/null)" = 5 ] && ok "A1 the accepted export is cached" || bad "A1 export.json not cached"
[ "$(reconciles)" -eq 1 ] && ok "A1 hugmesh-tor-reconcile re-run exactly once after the write (same pass)" || bad "A1 reconcile runs: $(reconciles)"
[ "$(gets)" -eq 1 ] && [ "$(posts)" -eq 1 ] && ok "A1 one GET (export) + one POST (report)" || bad "A1 curl calls: $(cat "${STATE_DIR}/curl.log")"
ls "${R}/etc/hugmesh/tor/" | grep -F '.hugmesh.' >/dev/null && bad "A1 a temp file was left next to the targets" || ok "A1 no temp file left in /etc/hugmesh/tor"
has "$(out)" "applied export gen=5" && ok "A1 the log says what was applied" || bad "A1 log: $(out | tail -3 | tr '\n' ';')"
# the GET carries the fingerprint URL-encoded, never raw
getargs="$(cat "${STATE_DIR}/curl-get.log")"
has "${getargs}" "--data-urlencode" && has "${getargs}" "node=${FP}" && has "${getargs}" "--get" \
    && ok "A1 the export GET sends node=<fp> via --data-urlencode (a raw '+' would be a space server-side)" || bad "A1 GET argv: $(printf '%s ' ${getargs})"
hasnt "${getargs}" "export?node=" && ok "A1 the fingerprint is not spliced raw into the URL" || bad "A1 fp spliced raw into the URL"
has "${getargs}" "--cert" && has "${getargs}" "--key" && has "${getargs}" "--cacert" && has "${getargs}" "--fail" && ok "A1 the GET presents the node's mTLS identity + CA (the vpn-reconcile transport)" || bad "A1 GET transport flags missing"

# A2 replay: the same generation again — refused, nothing changes, report still sent
before="$(tree_sum)"; run_sync
[ "$(tree_sum)" = "${before}" ] && [ "$(reconciles)" -eq 1 ] && ok "A2 replay of gen=5 -> refused: files byte-identical, no reconcile" || bad "A2 replay changed something (reconciles=$(reconciles))"
has "$(out)" "REFUSED" && has "$(out)" "not above the last applied" && ok "A2 the refusal names the generation rule" || bad "A2 log: $(out | grep -i refus | head -2 | tr '\n' ';')"
[ "$(posts)" -eq 2 ] && ok "A2 the report is STILL sent after a refused export" || bad "A2 posts=$(posts) after a refused export"

# A3 rollback: gen 4 < 5
make_export "${STATE_DIR}/export.json" "${PRIV}" 4 true "10.9.9.9:443" true '["evil"]'
run_sync
[ "$(tree_sum)" = "${before}" ] && [ "$(last_good)" = 5 ] && ok "A3 rolled-back gen=4 -> refused, files + last-good kept" || bad "A3 rollback applied: upstream='$(upstream)' lg=$(last_good)"

# A4 tampered body: signed for gen 6 with upstream X, then the body edited
make_export "${STATE_DIR}/export.json" "${PRIV}" 6 true "10.0.0.7:443" true '["games","shop"]'
jq '.body.upstream="10.9.9.9:443"' "${STATE_DIR}/export.json" > "${STATE_DIR}/t.json" && mv "${STATE_DIR}/t.json" "${STATE_DIR}/export.json"
run_sync
[ "$(tree_sum)" = "${before}" ] && [ "$(last_good)" = 5 ] && ok "A4 tampered body (upstream edited after signing) -> refused, nothing changed" || bad "A4 tampered export applied: '$(upstream)'"
# A5 unsigned
make_export "${STATE_DIR}/export.json" "${PRIV}" 6 true "10.9.9.9:443" true '["evil"]'
jq '.signed=false | .signature=null' "${STATE_DIR}/export.json" > "${STATE_DIR}/t.json" && mv "${STATE_DIR}/t.json" "${STATE_DIR}/export.json"
run_sync
[ "$(tree_sum)" = "${before}" ] && [ "$(last_good)" = 5 ] && ok "A5 unsigned envelope (signed=false, signature=null) -> refused" || bad "A5 unsigned export applied"
# A5b signed=false but a signature that would verify: the flag is part of the contract
make_export "${STATE_DIR}/export.json" "${PRIV}" 6 true "10.9.9.9:443" true '["evil"]'
jq '.signed=false' "${STATE_DIR}/export.json" > "${STATE_DIR}/t.json" && mv "${STATE_DIR}/t.json" "${STATE_DIR}/export.json"
run_sync
[ "$(tree_sum)" = "${before}" ] && [ "$(last_good)" = 5 ] && ok "A5b signed=false with a valid signature attached -> still refused (the envelope's own claim is honoured)" || bad "A5b signed=false export applied"
# A6 foreign key
make_export "${STATE_DIR}/export.json" "${FPRIV}" 6 true "10.9.9.9:443" true '["evil"]'
run_sync
[ "$(tree_sum)" = "${before}" ] && [ "$(last_good)" = 5 ] && ok "A6 signed by a key that is not the baked one -> refused" || bad "A6 foreign-key export applied"
# A7 foreign node: a valid signature, higher generation, somebody else's fingerprint
make_export "${STATE_DIR}/export.json" "${PRIV}" 6 true "10.9.9.9:443" true '["evil"]' "nodekey:SOMEONE-ELSE"
run_sync
[ "$(tree_sum)" = "${before}" ] && [ "$(last_good)" = 5 ] && ok "A7 export bound to another node's fingerprint -> refused (node guard after verify), last-good kept" || bad "A7 foreign-node export applied: '$(upstream)' lg=$(last_good)"
has "$(out)" "not this node" && ok "A7 the log names the node mismatch" || bad "A7 log: $(out | grep -i refus | tr '\n' ';')"
# A8 unknown fingerprint: the fail-closed empty body on a FRESH node (no last-good)
fresh a8; mkdir -p "${R}/etc/hugmesh/tor"; echo "127.0.0.1:8443" > "${R}/etc/hugmesh/tor/upstream"
make_export "${STATE_DIR}/export.json" "${PRIV}" 0 false "" false '[]' ""
run_sync
[ "$(upstream)" = "127.0.0.1:8443" ] && [ -z "$(last_good)" ] && [ "$(reconciles)" -eq 0 ] && ok "A8 unknown-fingerprint export (empty node, gen 0, nothing managed) -> nothing written, no generation recorded, no reconcile" || bad "A8 empty export acted: '$(upstream)' lg='$(last_good)'"
[ "$(posts)" -eq 1 ] && ok "A8 the report is still sent" || bad "A8 posts=$(posts)"

# ═══════════════════════ M. the managed flags, one file each ══════════════════════════
echo "== M. upstreamManaged / domainsManaged combinations =="
seed_baked() {  # a node whose image baked both files
    fresh "$1"; mkdir -p "${R}/etc/hugmesh/tor"
    printf '# baked by the image\n10.0.0.2:443\n' > "${R}/etc/hugmesh/tor/upstream"
    printf '# baked list\nbaked-a\nbaked-b\n' > "${R}/etc/hugmesh/tor/domains"
    UP0="$(sum "${R}/etc/hugmesh/tor/upstream")"; DM0="$(sum "${R}/etc/hugmesh/tor/domains")"
}
# M1 false/false: both left alone, generation still advances, no reconcile, report sent
seed_baked m1; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 false "" false '[]'
run_sync
[ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && [ "$(sum "${R}/etc/hugmesh/tor/domains")" = "${DM0}" ] && ok "M1 upstreamManaged=false + domainsManaged=false -> both baked files byte-identical (comments included)" || bad "M1 an unmanaged file was touched"
[ "$(last_good)" = 3 ] && [ "$(reconciles)" -eq 0 ] && [ "$(posts)" -eq 1 ] && ok "M1 nothing changed -> generation recorded, NO reconcile, report sent" || bad "M1 lg=$(last_good) reconciles=$(reconciles) posts=$(posts)"
has "$(out)" "nothing changed" && ok "M1 the log says nothing changed" || bad "M1 log: $(out | tail -2 | tr '\n' ';')"
# M2 true/false: upstream written, domains untouched
seed_baked m2; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 true "[fd00::7]:8443" false '[]'
run_sync
[ "$(upstream)" = "[fd00::7]:8443" ] && [ "$(sum "${R}/etc/hugmesh/tor/domains")" = "${DM0}" ] && [ "$(reconciles)" -eq 1 ] && ok "M2 upstreamManaged=true + domainsManaged=false -> upstream rewritten (IPv6 ok), baked domains untouched, one reconcile" || bad "M2 upstream='$(upstream)' domains-sum-same=$([ "$(sum "${R}/etc/hugmesh/tor/domains")" = "${DM0}" ] && echo yes || echo no)"
# M3 false/true: domains written, upstream untouched
seed_baked m3; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 false "" true '["games"]'
run_sync
[ "$(domains)" = "games" ] && [ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && [ "$(reconciles)" -eq 1 ] && ok "M3 upstreamManaged=false + domainsManaged=true -> domains rewritten, baked upstream untouched, one reconcile" || bad "M3 domains='$(domains)'"
# M4 true/true with an EMPTY upstream and an EMPTY list
seed_baked m4; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 true "" true '[]'
run_sync
[ ! -e "${R}/etc/hugmesh/tor/upstream" ] && ok "M4 upstreamManaged=true + upstream='' -> the file is REMOVED (the agent default 127.0.0.1:443 applies)" || bad "M4 upstream file still present: '$(upstream)'"
[ -f "${R}/etc/hugmesh/tor/domains" ] && [ ! -s "${R}/etc/hugmesh/tor/domains" ] && ok "M4 domainsManaged=true + [] -> an EMPTY domains file (withdraws every per-domain onion)" || bad "M4 domains file: exists=$([ -f "${R}/etc/hugmesh/tor/domains" ] && echo yes || echo no) size=$(stat -c %s "${R}/etc/hugmesh/tor/domains" 2>/dev/null)"
[ "$(reconciles)" -eq 1 ] && ok "M4 one reconcile after the two changes" || bad "M4 reconciles=$(reconciles)"
has "$(out)" "removed /etc/hugmesh/tor/upstream" && has "$(out)" "empty file withdraws" && ok "M4 the log says both (no sandbox prefix in the paths)" || bad "M4 log: $(out | grep -E 'removed|wrote' | tr '\n' ';')"
# M5 idempotent: the same managed state re-applied at a higher generation changes nothing
make_export "${STATE_DIR}/export.json" "${PRIV}" 4 true "" true '[]'
run_sync
[ "$(reconciles)" -eq 1 ] && [ "$(last_good)" = 4 ] && ok "M5 re-applying the same state at gen=4 -> no write, no reconcile, generation advances" || bad "M5 reconciles=$(reconciles) lg=$(last_good)"
# M6 withdrawing one slug of two
fresh m6; make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" true '["games","shop"]'; run_sync
make_export "${STATE_DIR}/export.json" "${PRIV}" 2 false "" true '["games"]'; run_sync
[ "$(domains)" = "games" ] && [ "$(reconciles)" -eq 2 ] && ok "M6 a slug dropped from the export drops out of the file (the reconcile withdraws its onion export)" || bad "M6 domains='$(domains)' reconciles=$(reconciles)"

# ═══════════════════════ W. atomic writes + refused values ═══════════════════════════
echo "== W. atomic writes =="
seed_baked w1; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 true "10.0.0.7:443" true '["games"]'
NOMV="${WORK}/nomv"; mkdir -p "${NOMV}"; printf '#!/bin/bash\necho "mv $*" >> "${STATE_DIR}/mv.log"\nexit 1\n' > "${NOMV}/mv"; chmod +x "${NOMV}/mv"
env -u RC_SVCNAME HUGMESH_TOR_ROOT="${R}" HUGMESH_TOR_RECONCILE="${STUB}/hugmesh-tor-reconcile" STATE_DIR="${STATE_DIR}" \
    PATH="${NOMV}:${STUB}:${PATH}" /bin/bash "${AGENT}" > "${STATE_DIR}/out.log" 2>&1; RC=$?
[ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && [ "$(sum "${R}/etc/hugmesh/tor/domains")" = "${DM0}" ] \
    && ok "W1 the rename never happens (crash between write and rename) -> BOTH old files intact" || bad "W1 a target was modified without a rename: upstream='$(upstream)' domains='$(domains)'"
grep -E '^mv .*/etc/hugmesh/tor/upstream\.hugmesh\.[A-Za-z0-9]+ .*/etc/hugmesh/tor/upstream$' "${STATE_DIR}/mv.log" >/dev/null \
    && ok "W1 the write goes temp-in-the-same-directory -> rename over the target" || bad "W1 mv calls: $(cat "${STATE_DIR}/mv.log" 2>/dev/null | tr '\n' ';')"
[ -z "$(last_good)" ] && ok "W1 a failed write never advances the last-applied generation (retried next cycle)" || bad "W1 last-good advanced to '$(last_good)' on a failed write"
[ "$(reconciles)" -eq 0 ] && [ "${RC}" -eq 0 ] && ok "W1 no reconcile after a failed write; still exits 0 (fail-soft)" || bad "W1 reconciles=$(reconciles) rc=${RC}"
has "$(out)" "only partly applied" && ok "W1 the log says the export was only partly applied" || bad "W1 log: $(out | tail -3 | tr '\n' ';')"
# W1b the target directory cannot take a temp file (the cache dir still can): the
# generation must not be recorded before the writes
if [ "$(id -u)" -ne 0 ]; then
    seed_baked w1b; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 true "10.0.0.7:443" true '["games"]'
    chmod 0555 "${R}/etc/hugmesh/tor"; run_sync; chmod 0755 "${R}/etc/hugmesh/tor"
    [ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && [ -z "$(last_good)" ] && [ ! -e "${R}/var/lib/hugmesh/tor-export/export.json" ] \
        && ok "W1b a write that fails on the target directory alone -> no generation recorded, no cache (the cache dir was writable)" \
        || bad "W1b lg='$(last_good)' cached=$([ -e "${R}/var/lib/hugmesh/tor-export/export.json" ] && echo yes || echo no) upstream='$(upstream)'"
    has "$(out)" "could not write /etc/hugmesh/tor/upstream" && ok "W1b the failed write is named" || bad "W1b log: $(out | grep -i 'could not' | tr '\n' ';')"
else
    echo "  SKIP W1b (root ignores directory modes)"
fi
# W2 a value the reconcile would ignore is refused before any write (depth; admin-bff checks too)
for bogus in '10.0.0.7 :443' 'host:443;HiddenServiceDir' '1.2.3.4'; do
    seed_baked w2; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 true "${bogus}" true '["games"]'
    run_sync
    [ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && [ "$(sum "${R}/etc/hugmesh/tor/domains")" = "${DM0}" ] && [ -z "$(last_good)" ] \
        && ok "W2 malformed upstream '${bogus}' -> refused before any write (domains untouched too)" || bad "W2 '${bogus}' got through: '$(upstream)' / '$(domains)'"
done
seed_baked w3; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 false "" true '["games","Bad_Slug"]'
run_sync
[ "$(sum "${R}/etc/hugmesh/tor/domains")" = "${DM0}" ] && [ -z "$(last_good)" ] && ok "W3 an invalid slug in the list -> the whole export refused, file untouched" || bad "W3 invalid slug written: '$(domains)'"
seed_baked w4; make_export "${STATE_DIR}/export.json" "${PRIV}" 3 false "" true '["games\nshop"]'
run_sync
[ "$(sum "${R}/etc/hugmesh/tor/domains")" = "${DM0}" ] && ok "W4 a slug smuggling a newline (two lines from one entry) -> refused" || bad "W4 newline slug written: '$(domains)'"

# ═══════════════════════ R. the onion report ═══════════════════════════════════════════
echo "== R. the onion report =="
fresh r1; mkdir -p "${R}/etc/hugmesh/tor"
echo "${ONION_G}" > "${R}/var/lib/hugmesh/tor/games.hostname"; printf '  %s\n' "${ONION_S}" > "${R}/var/lib/hugmesh/tor/shop.hostname"
echo "not-an-onion" > "${R}/var/lib/hugmesh/tor/junk.hostname"; echo "${ONION_G}" > "${R}/var/lib/hugmesh/tor/Bad_Slug.hostname"
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" false '[]'
run_sync
rep="$(report)"
printf '%s' "${rep}" | jq -e --arg fp "${FP}" '.machineKeyFp == $fp' >/dev/null && ok "R1 body.machineKeyFp is the baked fingerprint byte-for-byte" || bad "R1 fp in body: $(printf '%s' "${rep}" | jq -r .machineKeyFp)"
[ "$(printf '%s' "${rep}" | jq -r .primary)" = "${ONION_A}" ] && ok "R1 body.primary = /var/lib/hugmesh/tor/hostname" || bad "R1 primary: $(printf '%s' "${rep}" | jq -r .primary)"
[ "$(printf '%s' "${rep}" | jq -c '.domains')" = "{\"games\":\"${ONION_G}\",\"shop\":\"${ONION_S}\"}" ] \
    && ok "R1 body.domains = {slug: onion} from <slug>.hostname (trimmed); the garbage file and the invalid-slug file are skipped, not sent" || bad "R1 domains: $(printf '%s' "${rep}" | jq -c .domains)"
[ "$(printf '%s' "${rep}" | jq -r 'keys | join(",")')" = "domains,machineKeyFp,primary" ] && ok "R1 the body carries exactly machineKeyFp, primary, domains" || bad "R1 keys: $(printf '%s' "${rep}" | jq -r 'keys|join(",")')"
has "$(out)" "'not-an-onion'" && has "$(out)" "invalid slug" && ok "R1 both skipped files are logged" || bad "R1 skipped files not logged"
hasnt "$(report_hdr)" "X-Internal-Token" && has "$(out)" "no internal service token" && has "$(out)" "ARMED admin-bff answers 401" \
    && ok "R1 no token file -> no X-Internal-Token header, and the log says an armed BFF will answer 401" || bad "R1 header/log without a token: '$(report_hdr)'"
postargs="$(cat "${STATE_DIR}/curl-last.argv")"
has "${postargs}" "--cert" && has "${postargs}" "--key" && has "${postargs}" "--cacert" && has "${postargs}" "Content-Type: application/json" && hasnt "${postargs}" "Authorization" \
    && ok "R1 the POST rides mTLS + JSON, no JWT (the enrollment-report channel)" || bad "R1 POST argv: $(printf '%s ' ${postargs})"
# R2 the internal token, from the file node.env names
fresh r2; echo "BFF_INTERNAL_TOKEN_FILE=/etc/hugmesh/registry/svc.token" >> "${R}/etc/hugmesh/registry/node.env"
printf 'sekrit-token-123\n' > "${R}/etc/hugmesh/registry/svc.token"
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" false '[]'; run_sync
has "$(report_hdr)" "X-Internal-Token: sekrit-token-123" && ok "R2 token file named in node.env -> X-Internal-Token header sent (trimmed)" || bad "R2 header: '$(report_hdr)'"
hasnt "$(cat "${STATE_DIR}/curl-last.argv")" "sekrit-token-123" && ok "R2 the token never appears on the curl command line (header file)" || bad "R2 token on the command line"
hasnt "$(out)" "no internal service token" && ok "R2 no missing-token warning" || bad "R2 warned although the token exists"
# R3 the default token path when node.env names none
fresh r3; printf 'dflt-token\n' > "${R}/etc/hugmesh/registry/internal-token"
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" false '[]'; run_sync
has "$(report_hdr)" "X-Internal-Token: dflt-token" && ok "R3 default /etc/hugmesh/registry/internal-token is read when node.env names no file" || bad "R3 header: '$(report_hdr)'"
# R4 primary omitted when not minted yet; domains {} when none
fresh r4; rm -f "${R}/var/lib/hugmesh/tor/hostname"
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" false '[]'; run_sync
[ "$(report | jq -c .)" = "{\"machineKeyFp\":\"${FP}\",\"domains\":{}}" ] && ok "R4 no primary yet -> 'primary' OMITTED (not null, not empty); no domains -> {}" || bad "R4 body: $(report | jq -c .)"
# R5 a 422 is logged with the answer and never aborts
fresh r5; printf '422' > "${STATE_DIR}/resp-code"; printf '{"error":"primary is not a v3 onion"}' > "${STATE_DIR}/resp-body"
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 true "10.0.0.7:443" false '[]'; run_sync
[ "${RC}" -eq 0 ] && has "$(out)" "HTTP 422" && has "$(out)" "primary is not a v3 onion" && has "$(out)" "sync complete" \
    && ok "R5 a 422 answer is logged WITH the BFF's message and the agent finishes, exit 0" || bad "R5 rc=${RC} log: $(out | grep -E '422|complete' | tr '\n' ';')"
[ "$(upstream)" = "10.0.0.7:443" ] && [ "$(last_good)" = 1 ] && ok "R5 the export applied in the same pass is unaffected by the refused report" || bad "R5 export state after a 422: '$(upstream)' lg=$(last_good)"
fresh r6; printf '401' > "${STATE_DIR}/resp-code"; make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" false '[]'; run_sync
has "$(out)" "HTTP 401" && has "$(out)" "X-Internal-Token" && [ "${RC}" -eq 0 ] && ok "R6 a 401 names the missing service credential, exit 0" || bad "R6 log: $(out | grep 401 | tr '\n' ';')"
# R7 the primary that is not a v3 onion is not reported (the BFF would refuse the whole report)
fresh r7; echo "garbage" > "${R}/var/lib/hugmesh/tor/hostname"; echo "${ONION_G}" > "${R}/var/lib/hugmesh/tor/games.hostname"
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" false '[]'; run_sync
[ "$(report | jq -c .)" = "{\"machineKeyFp\":\"${FP}\",\"domains\":{\"games\":\"${ONION_G}\"}}" ] && has "$(out)" "not a v3 onion" \
    && ok "R7 a non-onion primary is dropped from the report (logged); the valid domain is still reported" || bad "R7 body: $(report | jq -c .)"
# R8 more than 64 domain exports: the 65th is not sent
fresh r8; for i in $(seq -w 1 65); do echo "${ONION_G}" > "${R}/var/lib/hugmesh/tor/d${i}.hostname"; done
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 false "" false '[]'; run_sync
[ "$(report | jq '.domains | length')" -eq 64 ] && has "$(out)" "more than 64" && ok "R8 at most 64 domains reported (the 65th logged, not sent)" || bad "R8 domains sent: $(report | jq '.domains|length')"

# ═══════════════════════ O. fail-soft inputs + the reseed recovery ═══════════════════
echo "== O. offline, missing inputs, --reset-generation =="
seed_baked o1; make_export "${STATE_DIR}/export.json" "${PRIV}" 9 true "10.0.0.7:443" true '["games"]'; touch "${STATE_DIR}/offline"
run_sync
[ "${RC}" -eq 0 ] && [ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && [ -z "$(last_good)" ] && [ "$(reconciles)" -eq 0 ] \
    && ok "O1 BFF unreachable -> exit 0, files kept, no generation recorded, no reconcile" || bad "O1 offline: rc=${RC} upstream='$(upstream)'"
has "$(out)" "fetch failed" && has "$(out)" "could not reach" && ok "O1 both calls log the outage" || bad "O1 log: $(out | tr '\n' ';')"
seed_baked o2; rm -f "${R}/etc/hugmesh/registry/registry-pub.ed25519"; make_export "${STATE_DIR}/export.json" "${PRIV}" 9 true "10.0.0.7:443" true '["games"]'
run_sync
[ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && [ -z "$(last_good)" ] && has "$(out)" "baked public key missing" && [ "$(posts)" -eq 1 ] \
    && ok "O2 no baked public key -> export step skipped (fail-closed), files kept, report still sent" || bad "O2 no-key: upstream='$(upstream)' posts=$(posts)"
seed_baked o3; rm -f "${R}/etc/hugmesh/registry/node.env"; run_sync
[ "${RC}" -eq 0 ] && [ "$(gets)" -eq 0 ] && [ "$(posts)" -eq 0 ] && has "$(out)" "node.env missing" && ok "O3 no node.env -> nothing called, exit 0 (not a mesh node)" || bad "O3 rc=${RC} calls: $(cat "${STATE_DIR}/curl.log" 2>/dev/null)"
seed_baked o4; rm -f "${R}/etc/hugmesh/registry/bff.key"; run_sync
[ "$(gets)" -eq 0 ] && [ "$(posts)" -eq 0 ] && has "$(out)" "mTLS client cert/key not present" && ok "O4 no mTLS key -> neither call attempted" || bad "O4 calls made without mTLS: $(cat "${STATE_DIR}/curl.log" 2>/dev/null)"
seed_baked o5; make_export "${STATE_DIR}/export.json" "${PRIV}" 9 true "10.0.0.7:443" true '["games"]'
env -u RC_SVCNAME HUGMESH_TOR_ROOT="${R}" HUGMESH_TOR_RECONCILE="${STUB}/hugmesh-tor-reconcile" HUGMESH_TOR_VERIFY_LIB="${WORK}/does-not-exist.sh" \
    STATE_DIR="${STATE_DIR}" PATH="${STUB}:${PATH}" /bin/bash "${AGENT}" > "${STATE_DIR}/out.log" 2>&1; RC=$?
[ "$(sum "${R}/etc/hugmesh/tor/upstream")" = "${UP0}" ] && has "$(out)" "verify library missing" && ok "O5 no verify library -> export skipped (fail-closed), files kept" || bad "O5 applied without the library"
# the reseed recovery: a lower generation is refused until the operator forgets the stored one
fresh o6; make_export "${STATE_DIR}/export.json" "${PRIV}" 50 true "10.0.0.7:443" false '[]'; run_sync
make_export "${STATE_DIR}/export.json" "${PRIV}" 2 true "10.0.0.8:443" false '[]'; run_sync
[ "$(upstream)" = "10.0.0.7:443" ] && [ "$(last_good)" = 50 ] && ok "O6 after a reseed the low generation (2 < 50) is refused — never accepted silently" || bad "O6 low gen accepted: '$(upstream)'"
env HUGMESH_TOR_ROOT="${R}" PATH="${STUB}:${PATH}" STATE_DIR="${STATE_DIR}" /bin/bash "${AGENT}" --reset-generation > "${STATE_DIR}/reset.log" 2>&1; rrc=$?
[ "${rrc}" -eq 0 ] && [ -z "$(last_good)" ] && has "$(cat "${STATE_DIR}/reset.log")" "forgot the last-applied export generation (50)" \
    && ok "O6 --reset-generation forgets the stored generation (and says which), exit 0" || bad "O6 reset: rc=${rrc} lg='$(last_good)' $(cat "${STATE_DIR}/reset.log")"
[ "$(upstream)" = "10.0.0.7:443" ] && [ "$(gets)" -eq 2 ] && ok "O6 the reset touches nothing else (no fetch, files kept)" || bad "O6 reset fetched or wrote: gets=$(gets) upstream='$(upstream)'"
run_sync
[ "$(upstream)" = "10.0.0.8:443" ] && [ "$(last_good)" = 2 ] && ok "O6 after the reset the gen=2 export is accepted once it verifies" || bad "O6 post-reset: '$(upstream)' lg=$(last_good)"
make_export "${STATE_DIR}/export.json" "${FPRIV}" 3 true "10.9.9.9:443" false '[]'; run_sync
[ "$(upstream)" = "10.0.0.8:443" ] && ok "O6 the reset does not weaken the signature check (foreign key still refused)" || bad "O6 foreign key accepted after a reset"
env HUGMESH_TOR_ROOT="${R}" PATH="${STUB}:${PATH}" STATE_DIR="${STATE_DIR}" /bin/bash "${AGENT}" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "O7 an unknown argument exits 2 (usage)" || bad "O7 unknown argument not refused"

# ═══════════════════════ E. the REAL reconcile renders what the sync wrote ════════════
echo "== E. hugmesh-tor-export-sync -> hugmesh-tor-reconcile (real) =="
fresh e1; mkdir -p "${R}/var/lib/tor/hugmesh-onion" "${R}/var/log"; echo "${ONION_A}" > "${R}/var/lib/tor/hugmesh-onion/hostname"
RST="${WORK}/rstub"; mkdir -p "${RST}"
printf '#!/bin/bash\necho "$*" >> "${STATE_DIR}/rc.log"\n[ "$2" = status ] && exit 0\nexit 0\n' > "${RST}/rc-service"
printf '#!/bin/bash\nexit 0\n' > "${RST}/tor"; printf '#!/bin/bash\nexit 0\n' > "${RST}/id"; printf '#!/bin/bash\nexit 0\n' > "${RST}/chown"
printf '#!/bin/bash\nexit 0\n' > "${RST}/sleep"; chmod +x "${RST}"/*
make_export "${STATE_DIR}/export.json" "${PRIV}" 1 true "10.0.0.7:443" true '["games"]'
# the builders chmod +x the agent when they bake it; the repo copy is plain 0644
cp "${RECONCILE}" "${WORK}/hugmesh-tor-reconcile"; chmod +x "${WORK}/hugmesh-tor-reconcile"
env -u RC_SVCNAME HUGMESH_TOR_ROOT="${R}" HUGMESH_TOR_RECONCILE="${WORK}/hugmesh-tor-reconcile" HUGMESH_TOR_WAIT_TRIES=1 STATE_DIR="${STATE_DIR}" \
    PATH="${RST}:${STUB}:${PATH}" /bin/bash "${AGENT}" > "${STATE_DIR}/out.log" 2>&1; RC=$?
torrc="$(cat "${R}/etc/tor/torrc" 2>/dev/null)"
has "${torrc}" "HiddenServiceDir /var/lib/tor/hugmesh-onion.d/games" && has "${torrc}" "HiddenServicePort 443 10.0.0.7:443" && [ "$(printf '%s\n' "${torrc}" | grep -c '^HiddenServicePort 443 10.0.0.7:443$')" -eq 2 ] \
    && ok "E1 the real reconcile, run by the sync in the same pass, renders the games stanza and the written upstream (primary + domain, same upstream)" || { bad "E1 torrc after the sync:"; printf '%s\n' "${torrc}" | grep '^HiddenService' | sed 's/^/      | /'; out | tail -4 | sed 's/^/      | /'; }
has "$(cat "${STATE_DIR}/rc.log" 2>/dev/null)" "tor reload" && ok "E1 a running tor is reloaded for the new stanza" || bad "E1 rc calls: $(cat "${STATE_DIR}/rc.log" 2>/dev/null | tr '\n' ';')"
has "$(out)" "re-rendered the torrc" && ok "E1 the sync logs the re-render" || bad "E1 log: $(out | tail -3 | tr '\n' ';')"
[ -s "${R}/var/log/hugmesh-tor-reconcile.log" ] && ok "E1 the reconcile wrote its own log under the same root" || bad "E1 no reconcile log"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
