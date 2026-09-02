#!/usr/bin/env bash
# ============================================================================
# test-domain-reconcile-fuzz.sh — Phase 6 ADVERSARIAL-EXPORT FUZZ SUITE.
# ============================================================================
#
# The EXIT GATE for the mesh-node reconcile RENDER hardening. A malicious-but-
# AUTHENTIC #118 export (Ed25519-verified, monotonic — but content NOT validated)
# is the primary threat: it renders AS ROOT on the mesh node. This suite feeds a
# corpus of malicious-but-well-formed brand profiles / exports through the EXACT
# reconcile render seam and asserts EACH fails closed:
#
#   * exit!=0 / fail-closed:  the malicious tree is NEVER promoted into OUT_DIR
#     (either the generator sink _die's, the emit-time secret scanner FLAGS it, an
#     entry validator SKIPS it, or the DoS cap refuses the run) and the run-level
#     _DR_EMIT_FAILED flag is set where a content gate fired.
#   * NO file escapes the scratch CONTAINMENT dir (sentinel + find backstop).
#   * the ack WRITEBACK does NOT fire (a `curl` recorder stub in PATH must log
#     ZERO invocations for every malicious case).
#
# Corpus (spec fuzzCorpus a-f):
#   (a) sed/Handlebars-metachar + template-injection in a brand value
#   (b) path-traversal in BRAND/domain/repo name (../, absolute, '.', symlink)
#   (c) secret injected into a templated field (high-entropy + denylisted key)
#   (d) protocol-namespace override (hugmesh.net/*, X-HugMesh-Local)
#   (e) oversized / entries-loop DoS
#   (f) YAML/newline splice into an auth-relevant default
# Plus a LEGIT export POSITIVE CONTROL: it renders/scans clean, promotes, AND the
# writeback DOES fire (proves the gate is not a blanket lockout — no false positive).
#
# BUILD-HOST RUNNABLE: normal user, NO root, NO network, scratch containment dir.
# DR_SKIP_CA=1 scopes out the openssl/keytool CA loop (deferred to real-root — see
# the DEFERRED banner at the end). FAILS (exit 1) if a required tool is absent.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${REPO}/specs/usr/sbin/hugmesh-domain-reconcile"
GEN_BRAND_REPOS_SH="${REPO}/generate-brand-repos.sh"
SECRET_SCAN_SH="${REPO}/scripts/secret-scan.sh"
TOKEN_CLASSIFIER="${REPO}/scripts/tooling/token-classifier.js"

[ -r "${AGENT}" ] || { echo "FAIL agent missing: ${AGENT}"; exit 1; }
# Tool preflight is FAIL-CLOSED (tests/lib/guard-preflight.sh): a missing tool
# makes this guard exit 1, never 0. The old `SKIP … exit 0` shape turned an
# under-provisioned CI image into a green check. Deliberate local opt-out:
# GUARD_TOOLING_ALLOW_SKIP=1 — a name .gitlab-ci.yml is forbidden to contain.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-preflight.sh"
guard_require_tools jq sed realpath find

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# ── Scratch jail: CONTAIN is the ONLY dir any render may touch. Decoys under JAIL
#    are traversal landing zones — any file there means containment was breached. ──
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT
JAIL="${WORK}/jail"; CONTAIN="${JAIL}/out"
mkdir -p "${CONTAIN}" "${JAIL}/etc/cron.d" "${JAIL}/etc"
SENTINEL="${WORK}/sentinel"

# ── curl RECORDER stub: shadow curl in PATH so any ack POST is captured offline. ──
STUBBIN="${WORK}/bin"; CURL_LOG="${WORK}/curl-calls.log"
mkdir -p "${STUBBIN}"
cat > "${STUBBIN}/curl" <<EOF
#!/usr/bin/env bash
printf 'CURL %s\n' "\$*" >> "${CURL_LOG}"
exit 0
EOF
chmod +x "${STUBBIN}/curl"
export PATH="${STUBBIN}:${PATH}"
: > "${CURL_LOG}"

# ── Source the agent with DR_* seams (main is BASH_SOURCE-guarded; only functions
#    load). DOMAIN_ACK_URL is set to a SENTINEL so writeback_acks WOULD POST if
#    reached — the recorder proves it is not, on malicious cases. ──
export DR_OUT_DIR="${CONTAIN}"
export DR_GEN_BRAND_REPOS="${GEN_BRAND_REPOS_SH}"
export DR_SECRET_SCAN="${SECRET_SCAN_SH}"
export DR_CACHE_DIR="${WORK}/cache"
export DR_DOMAINS_CONF="${WORK}/domains.conf"
export DR_SKIP_CA=1
export DOMAIN_ACK_URL="https://ack.sentinel.invalid/"
mkdir -p "${DR_CACHE_DIR}"
# shellcheck source=/dev/null
. "${AGENT}"   # loads functions with the DR_* config; does NOT run main()
# main() normally sets these mTLS globals from node.env; we drive functions directly,
# so define them empty (set -u would otherwise abort ack_generation on a clean run).
MTLS_CA=""; MTLS_CERT=""; MTLS_KEY=""

echo "== Phase 6 adversarial-export FUZZ SUITE (build-host: no root, no network) =="
echo "   containment dir = ${CONTAIN}"
echo

# ── helpers ──────────────────────────────────────────────────────────────────
# Write a transient brand profile EXACTLY as render_brand_repos() does (printf %q),
# so a hostile value reaches the generator sink's guards quoted, not word-split.
mkprofile() { # mkprofile OUT BRAND TITLE ORG DOMAIN HEADSCALE MESH
    local f="$1"
    { printf 'BRAND=%q\n' "$2"; printf 'BRAND_TITLE=%q\n' "$3"; printf 'ORG=%q\n' "$4"
      printf 'CLUSTER_DOMAIN=%q\n' "$5"; printf 'HEADSCALE_URL=%q\n' "$6"; printf 'MESH_TAG=%q\n' "$7"; } > "$f"
}
# Build a signed-shape export.json (unsigned — we drive the RENDER seam directly,
# which runs AFTER verify; content is the attack surface here). One entry per call.
mkexport1() { # mkexport1 OUT BRAND DOMAIN ORG MESH
    jq -n --arg b "$2" --arg d "$3" --arg o "$4" --arg m "$5" \
      '{body:{entries:[{clusterDomain:$d,brand:$b,org:$o,meshTag:$m,nsPrefix:"acme",casdoorOrg:"acme-org",caProvisioned:false,appsetRegistered:false}]}}' > "$1"
}

# Assert nothing was written OUTSIDE the containment dir since the sentinel.
assert_contained() { # assert_contained CASE
    local escaped
    escaped="$(find "${JAIL}" -newer "${SENTINEL}" -type f ! -path "${CONTAIN}/*" 2>/dev/null)"
    if [ -z "${escaped}" ]; then ok "$1: no file escaped the containment dir"
    else bad "$1: FILE(S) ESCAPED CONTAINMENT:"; printf '        %s\n' ${escaped}; fi
}
# Assert the malicious brand tree was NOT promoted into the published OUT_DIR.
assert_not_promoted() { # assert_not_promoted CASE BRAND
    if [ -e "${CONTAIN}/$2-gitops" ]; then bad "$1: malicious tree PROMOTED to OUT_DIR/$2-gitops (should be quarantined/absent)"
    else ok "$1: malicious tree not promoted (OUT_DIR/$2-gitops absent)"; fi
}
# Assert the writeback did NOT fire: replay main()'s decision + the writeback re-gate
# with the curl recorder armed, then assert ZERO curl calls.
assert_no_writeback() { # assert_no_writeback CASE [EXPORT_JSON]
    : > "${CURL_LOG}"
    if [ -n "${_DR_EMIT_FAILED:-}" ]; then
        :   # main() aborts before writeback_acks entirely (quarantined)
    elif [ -n "${2:-}" ]; then
        writeback_acks "$2" 7 >/dev/null 2>&1 || true   # entries were skipped -> re-gate must not ack
    fi
    if [ ! -s "${CURL_LOG}" ]; then ok "$1: writeback did NOT fire (0 ack POSTs)"
    else bad "$1: writeback FIRED (curl invoked):"; sed 's/^/        /' "${CURL_LOG}"; fi
}
new_case() { _DR_EMIT_FAILED=""; rm -rf "${CONTAIN:?}/"* 2>/dev/null || true; sleep 0.01; : > "${SENTINEL}"; sleep 0.01; }

# ── (a) sed/Handlebars-metachar + template-injection in a brand value ──────────
echo "-- (a) metachar / template-injection in a brand value --"
for payload in '{{HARBOR_PROJECT}}' 'x|s/a/b/g & id' 'back\slash'; do
    new_case
    mkprofile "${WORK}/a.conf" acme "${payload}" Acme-Inc acme.test https://headscale.acme.test tag:acme
    render_and_scan_profile "${WORK}/a.conf" acme "${CONTAIN}" >/dev/null 2>&1
    rc=$?
    if [ "${rc}" -ne 0 ] && [ -n "${_DR_EMIT_FAILED:-}" ]; then ok "(a) BRAND_TITLE=<${payload}> failed closed (gate fired, rc=${rc})"
    else bad "(a) BRAND_TITLE=<${payload}> did NOT fail closed (rc=${rc})"; fi
    assert_not_promoted "(a)" acme
    assert_contained "(a)"
    assert_no_writeback "(a)"
done
echo

# ── (b) path-traversal in BRAND / domain ───────────────────────────────────────
echo "-- (b) path-traversal in BRAND/domain/repo (../, absolute, '.', symlink) --"
# b1: via the reconcile export path (entry_fields_ok DNS-label gate skips the entry).
for badbrand in '../../etc/cron.d/x' '/etc/passwd' '.' 'UP__PER'; do
    new_case
    mkexport1 "${WORK}/b.json" "${badbrand}" acme.test Acme-Inc tag:acme
    render_brand_repos "${WORK}/b.json" >/dev/null 2>&1
    assert_not_promoted "(b brand='${badbrand}')" "${badbrand}"
    assert_contained "(b brand='${badbrand}')"
    assert_no_writeback "(b brand='${badbrand}')" "${WORK}/b.json"
done
# b2: traversal clusterDomain via export.
new_case
mkexport1 "${WORK}/b2.json" acme '../evil' Acme-Inc tag:acme
render_brand_repos "${WORK}/b2.json" >/dev/null 2>&1
assert_contained "(b clusterDomain='../evil')"
assert_no_writeback "(b clusterDomain='../evil')" "${WORK}/b2.json"
# b3: drive the generator SINK directly with a traversal BRAND -> _die (DNS label + realpath).
new_case
mkprofile "${WORK}/b3.conf" '../../etc/cron.d/x' Title Acme-Inc acme.test https://headscale.acme.test tag:acme
if OFFLINE=1 bash "${GEN_BRAND_REPOS_SH}" "${WORK}/b3.conf" --out-dir "${CONTAIN}" >/dev/null 2>&1; then
    bad "(b sink) generate-brand-repos.sh ACCEPTED a traversal BRAND"
else ok "(b sink) generate-brand-repos.sh _die'd on traversal BRAND (exit!=0)"; fi
assert_contained "(b sink)"
# b4: SYMLINK backstop — plant OUT_DIR/evil-gitops -> JAIL/etc, then BRAND=evil.
# realpath -m resolves through the existing symlink; BRAND_OUT escapes OUT_DIR ->
# the realpath containment case-match _die's BEFORE any rm -rf/mkdir.
new_case
ln -s "${JAIL}/etc" "${CONTAIN}/evil-gitops"
mkprofile "${WORK}/b4.conf" evil Title Acme-Inc acme.test https://headscale.acme.test tag:acme
if OFFLINE=1 bash "${GEN_BRAND_REPOS_SH}" "${WORK}/b4.conf" --out-dir "${CONTAIN}" >/dev/null 2>&1; then
    bad "(b symlink) generate-brand-repos.sh followed a planted symlink out of OUT_DIR"
else ok "(b symlink) realpath containment refused the planted symlink escape (exit!=0)"; fi
rm -f "${CONTAIN}/evil-gitops" 2>/dev/null || true
assert_contained "(b symlink)"
echo

# ── (c) secret injected into a templated field (denylist + high-entropy) ───────
echo "-- (c) secret in a templated field (high-entropy bearer + denylisted key) --"
for payload in \
    'Bearer BqYq2wYQ0Km7v8Nx3Rd1Yh0Jc5UgKx9fQp2Lm7Vb8' \
    'CASDOOR_ADMIN_CLIENT_SECRET=s3cr3t-Kx9fQp2Lm7Vb8Nz4Wt6'; do
    new_case
    mkprofile "${WORK}/c.conf" acme "${payload}" Acme-Inc acme.test https://headscale.acme.test tag:acme
    render_and_scan_profile "${WORK}/c.conf" acme "${CONTAIN}" >/dev/null 2>&1
    rc=$?
    if [ "${rc}" -ne 0 ] && [ -n "${_DR_EMIT_FAILED:-}" ]; then ok "(c) secret-in-BRAND_TITLE flagged by emit scan, quarantined (rc=${rc})"
    else bad "(c) secret payload <${payload}> NOT caught by the emit gate (rc=${rc})"; fi
    assert_not_promoted "(c)" acme
    assert_contained "(c)"
    assert_no_writeback "(c)"
done
echo

# ── (d) protocol-namespace override ────────────────────────────────────────────
echo "-- (d) protocol-namespace override (hugmesh.net/*, X-HugMesh-Local) --"
# d1: dotted/slashed brand/org/mesh -> validators reject on the reconcile path.
new_case
mkexport1 "${WORK}/d.json" 'hugmesh.net/domain' acme.test 'hugmesh.net/domain' 'tag:hugmesh.net'
render_brand_repos "${WORK}/d.json" >/dev/null 2>&1
assert_not_promoted "(d)" 'hugmesh.net/domain'
assert_contained "(d)"
assert_no_writeback "(d)" "${WORK}/d.json"
# d2: token-classifier.isFrozen()/isDenied() reject the frozen protocol constants.
if command -v node >/dev/null && [ -r "${TOKEN_CLASSIFIER}" ]; then
    if node -e '
      const c = require(process.argv[1]);
      // Genuine frozen protocol CONSTANTS: label-key namespace (with slash), wire
      // header, subprotocol prefix. (The tag:hugmesh.net mesh form is rejected
      // by the DNS/mesh VALIDATOR on the reconcile path — asserted in d1 above — not
      // by isFrozen, whose label-ns match is the slashed 'hugmesh.net/' key.)
      // + the CRD API group (tokens.json api_groups), in the bare spelling the
      // label-ns substring match cannot see (no slash): compiled into admin-bff.
      const frozen = ["hugmesh.net/domain","X-HugMesh-Local","hugmesh.device-terminal.stepup.x","platform.hugmesh.net"];
      // THE BAN SIDE (tokens.json retired_protocol_constants): the spellings the
      // HugMesh rebrand RETIRED must still be refused at emit, or the templating
      // path silently becomes the way the dead token comes back.
      const retired = ["snapdragon.systems/image-build","X-Snapdragon-Local","snapdragon.device-terminal.stepup.x"];
      const denied = ["CASDOOR_ADMIN_CLIENT_SECRET","ROOT_PASS","APP_REGISTRY_SIGNING_KEY"];
      for (const t of frozen) if (!c.isFrozen(t)) { console.error("NOT frozen:", t); process.exit(1); }
      for (const t of frozen) if (c.isRetired(t)) { console.error("live constant wrongly RETIRED:", t); process.exit(1); }
      for (const t of retired) if (!c.isFrozen(t)) { console.error("retired constant NOT refused:", t); process.exit(1); }
      for (const t of retired) if (!c.isRetired(t)) { console.error("retired constant not flagged:", t); process.exit(1); }
      for (const t of denied) if (!c.isDenied(t)) { console.error("NOT denied:", t); process.exit(1); }
      if (c.isAllowed("hugmesh.net/domain")) { console.error("frozen ns wrongly ALLOWED"); process.exit(1); }
      process.exit(0);
    ' "${TOKEN_CLASSIFIER}" >/dev/null 2>&1; then
        ok "(d) token-classifier isFrozen()/isDenied() reject hugmesh.net/* + wire headers + secret keys + the RETIRED spellings"
    else bad "(d) token-classifier did NOT reject a frozen/retired/denied protocol constant"; fi
else
    echo "  SKIP (d) node/token-classifier unavailable (Handlebars-path assertion)"
fi
# d3: THE SPEC SHAPE ITSELF — d2's blind spot. Every block in tokens.json is read
# through `|| {}` / `|| []` at its call site, which is exactly what makes a DELETED
# top-level block indistinguishable from an empty one: the unions collapse and
# isFrozen()/isRetired()/isThemeContract()/isRenameContractFile() start returning
# false for everything they used to refuse — require() succeeds, exit 0, no
# diagnostic, guard gone. NOT hypothetical: a38208e6 ("Update tokens.json", a
# direct-to-main web-editor push, 2026-08-28) deleted BOTH
# retired_protocol_constants and theme_contract_constants in one 14-line edit and
# the engine said nothing at all. What went red was behavioural — d2 above, and ten
# A9* cases in test-templating-rename-pr.sh — and only for the spellings those
# cases happen to ENUMERATE, which is why a whole contract family can be dropped
# and only the enumerated half of it is noticed. So this case asserts the SHAPE:
# plant that exact deletion in an ISOLATED copy of the tooling and require the
# classifier to REFUSE TO LOAD and to NAME the missing block, rather than degrade
# into a permissive empty set. Isolated copy, never the real tree: the classifier
# resolves tokens.json from its own __dirname, and a suite that mutated
# scripts/tooling/ in place would leave a live checkout broken if it were killed
# between the mutation and the restore.
if command -v node >/dev/null && [ -r "${TOKEN_CLASSIFIER}" ]; then
    SPECDIR="${WORK}/specshape"
    mkdir -p "${SPECDIR}"
    cp "${TOKEN_CLASSIFIER}" "${SPECDIR}/token-classifier.js"
    cp "${REPO}/scripts/tooling/tokens.json" "${SPECDIR}/tokens.json"
    # POSITIVE CONTROL FIRST. Without it, a copy that cannot load for an unrelated
    # reason (a bad path, a syntax error) would make every mutation below report
    # "refused" and the whole case would pass while asserting nothing.
    if node -e 'require(process.argv[1])' "${SPECDIR}/token-classifier.js" >"${WORK}/d3-control.err" 2>&1; then
        ok "(d3) control: the isolated tooling copy loads against the REAL spec"
        for _blk in retired_protocol_constants theme_contract_constants frozen_protocol_constants; do
            node -e '
              const fs = require("fs");
              const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
              delete s[process.argv[2]];
              fs.writeFileSync(process.argv[1], JSON.stringify(s, null, 2));
            ' "${SPECDIR}/tokens.json" "${_blk}"
            # Prove the mutation actually changed the file before judging the guard.
            if cmp -s "${REPO}/scripts/tooling/tokens.json" "${SPECDIR}/tokens.json"; then
                bad "(d3) mutation for ${_blk} did not change tokens.json (block absent upstream?)"
            else
                node -e 'require(process.argv[1])' "${SPECDIR}/token-classifier.js" >"${WORK}/d3-${_blk}.err" 2>&1
                _rc=$?
                # grep the FILE, never a pipe: `| grep -q` under pipefail turns a
                # found match into a SIGPIPE failure (certain under busybox).
                if [ "${_rc}" -ne 0 ] && grep -F "${_blk}" "${WORK}/d3-${_blk}.err" >/dev/null 2>&1; then
                    ok "(d3) tokens.json ${_blk} deleted -> classifier refuses to load and NAMES the block"
                else
                    bad "(d3) tokens.json ${_blk} deleted but the classifier LOADED (rc=${_rc}) — the guard silently degraded to an empty set"
                fi
            fi
            cp "${REPO}/scripts/tooling/tokens.json" "${SPECDIR}/tokens.json"
        done
    else
        bad "(d3) control: the isolated tooling copy does NOT load against the real spec — harness broken, guard unproven"
    fi
else
    echo "  SKIP (d3) node/token-classifier unavailable (spec-shape assertion)"
fi
echo

# ── (e) oversized / entries-loop DoS ───────────────────────────────────────────
echo "-- (e) oversized / entries-loop DoS --"
# e1: 129-char BRAND_TITLE -> generator length guard.
new_case
mkprofile "${WORK}/e1.conf" acme "$(printf 'A%.0s' {1..129})" Acme-Inc acme.test https://headscale.acme.test tag:acme
render_and_scan_profile "${WORK}/e1.conf" acme "${CONTAIN}" >/dev/null 2>&1; rc=$?
{ [ "${rc}" -ne 0 ] && [ -n "${_DR_EMIT_FAILED:-}" ]; } && ok "(e) 129-char BRAND_TITLE rejected (len guard, rc=${rc})" || bad "(e) 129-char BRAND_TITLE NOT rejected (rc=${rc})"
assert_not_promoted "(e len129)" acme; assert_contained "(e len129)"; assert_no_writeback "(e len129)"
# e2: 64-char BRAND (label max 63) -> generator label guard.
new_case
mkprofile "${WORK}/e2.conf" "$(printf 'a%.0s' {1..64})" Title Acme-Inc acme.test https://headscale.acme.test tag:acme
OFFLINE=1 bash "${GEN_BRAND_REPOS_SH}" "${WORK}/e2.conf" --out-dir "${CONTAIN}" >/dev/null 2>&1 \
  && bad "(e) 64-char BRAND accepted (label max 63)" || ok "(e) 64-char BRAND rejected (label-length guard, exit!=0)"
assert_contained "(e brand64)"
# e3: 10MB single BRAND_TITLE -> bounded reject by the length guard.
new_case
python3 - "${WORK}/e3.conf" <<'PY' 2>/dev/null || printf 'BRAND=acme\nBRAND_TITLE=%s\nORG=Acme-Inc\nCLUSTER_DOMAIN=acme.test\nHEADSCALE_URL=https://headscale.acme.test\nMESH_TAG=tag:acme\n' "$(head -c 10485760 /dev/zero | tr '\0' A)" > "${WORK}/e3.conf"
import sys
f=sys.argv[1]
open(f,'w').write("BRAND=acme\nBRAND_TITLE=%s\nORG=Acme-Inc\nCLUSTER_DOMAIN=acme.test\nHEADSCALE_URL=https://headscale.acme.test\nMESH_TAG=tag:acme\n" % ("A"*10485760))
PY
t0=$(date +%s)
OFFLINE=1 bash "${GEN_BRAND_REPOS_SH}" "${WORK}/e3.conf" --out-dir "${CONTAIN}" >/dev/null 2>&1 \
  && bad "(e) 10MB BRAND_TITLE accepted" || ok "(e) 10MB BRAND_TITLE rejected (len guard, bounded)"
t1=$(date +%s); [ $((t1-t0)) -le 10 ] && ok "(e) 10MB reject bounded wall-clock ($((t1-t0))s)" || bad "(e) 10MB reject slow ($((t1-t0))s)"
assert_contained "(e 10MB)"
# e4: 50000-entry export -> DR_MAX_ENTRIES cap refuses the WHOLE run (no 50k forks).
new_case
jq -n '{body:{entries:[range(50000)|{clusterDomain:"acme.test",brand:"acme",org:"Acme-Inc",meshTag:"tag:acme",caProvisioned:false,appsetRegistered:false}]}}' > "${WORK}/e4.json"
t0=$(date +%s)
render_brand_repos "${WORK}/e4.json" >/dev/null 2>&1; rc=$?
t1=$(date +%s)
{ [ "${rc}" -ne 0 ] && [ -n "${_DR_EMIT_FAILED:-}" ]; } && ok "(e) 50000 entries > DR_MAX_ENTRIES cap -> whole run refused (rc=${rc})" || bad "(e) 50000-entry cap did NOT fire (rc=${rc})"
[ $((t1-t0)) -le 10 ] && ok "(e) DoS cap check bounded ($((t1-t0))s, no per-entry fork)" || bad "(e) DoS cap slow ($((t1-t0))s)"
assert_not_promoted "(e 50k)" acme; assert_contained "(e 50k)"; assert_no_writeback "(e 50k)"
# e5: drive the REAL main() ORDERING (not render_brand_repos in isolation). main() runs
# build_domains_conf() + run_ca_loop() FIRST — both iterate ALL entries — and only THEN
# render_brand_repos(). The cap MUST fire before build_domains_conf, or a 50k export forks
# ~250k jq / 50k openssl as root before render_brand_repos()'s cap is ever reached. We run
# the actual agent as a SUBPROCESS through main() (verify STUBBED to pass — authenticity is
# not the surface here, content is) and assert: exit!=0, quarantined, build_domains_conf
# NEVER synthesised its domains.conf (proves the cap fired BEFORE it), no writeback, bounded.
if command -v openssl >/dev/null 2>&1; then
    new_case
    M5="${WORK}/e5"; mkdir -p "${M5}/cache" "${M5}/bin" "${M5}/out"
    # 50k-entry authentic-SHAPE export (verify stub passes it through to the EMIT block).
    jq -n '{body:{entries:[range(50000)|{clusterDomain:"acme.test",brand:"acme",org:"Acme-Inc",meshTag:"tag:acme",caProvisioned:false,appsetRegistered:false}],generation:9}}' > "${M5}/export.json"
    # Stub verify lib: pass authenticity, return a monotone gen. (Ed25519/rollback is proven
    # in the verify test, not here — this case isolates the DoS ORDERING on the render path.)
    printf 'domain_verify_export() { return 0; }\nrv_gen() { echo 9; }\n' > "${M5}/verify.sh"
    # node.env: machine fp + a (stub) transport + the sentinel ACK URL so a writeback WOULD
    # fire if main() ever reached it past the cap — the recorder proves it does not.
    { printf 'MACHINE_KEY_FP=deadbeef\n'; printf 'BFF_EXPORT_URL=https://bff.invalid\n'
      printf 'BFF_CLIENT_CERT=%s/c.pem\n' "${M5}"; printf 'BFF_CLIENT_KEY=%s/k.pem\n' "${M5}"
      printf 'BFF_CA=%s/ca.pem\n' "${M5}"; printf 'BFF_ACK_URL=https://ack.sentinel.invalid/\n'; } > "${M5}/node.env"
    : > "${M5}/c.pem"; : > "${M5}/k.pem"; : > "${M5}/ca.pem"; : > "${M5}/pub.ed25519"
    # curl stub for this subprocess: on the fetch (-o OUT) copy the fixture; on the ack POST,
    # append to the shared recorder so a writeback would be caught.
    cat > "${M5}/bin/curl" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
if [ -n "\$out" ]; then cp "${M5}/export.json" "\$out"; exit 0; fi
printf 'CURL %s\n' "\$*" >> "${CURL_LOG}"
exit 0
EOF
    chmod +x "${M5}/bin/curl"
    : > "${CURL_LOG}"
    t0=$(date +%s)
    PATH="${M5}/bin:${PATH}" \
      DR_NODE_ENV="${M5}/node.env" DR_PUB_KEY="${M5}/pub.ed25519" DR_VERIFY_LIB="${M5}/verify.sh" \
      DR_CACHE_DIR="${M5}/cache" DR_OUT_DIR="${M5}/out" DR_DOMAINS_CONF="${M5}/cache/domains.conf" \
      DR_GEN_BRAND_REPOS="${GEN_BRAND_REPOS_SH}" DR_SECRET_SCAN="${SECRET_SCAN_SH}" DR_SKIP_CA=1 \
      bash "${AGENT}" >/dev/null 2>&1
    rc=$?
    t1=$(date +%s)
    [ "${rc}" -ne 0 ] && ok "(e main) real main() refused the 50k export (exit=${rc}!=0)" || bad "(e main) real main() did NOT fail (exit=${rc})"
    if [ ! -e "${M5}/cache/domains.conf" ]; then ok "(e main) cap fired BEFORE build_domains_conf (no domains.conf synthesised)"
    else bad "(e main) build_domains_conf RAN before the cap (domains.conf: $(grep -cvE '^[[:space:]]*(#|$)' "${M5}/cache/domains.conf" 2>/dev/null) rows) — cap in wrong place"; fi
    [ "$(cat "${M5}/cache/state" 2>/dev/null)" = "quarantined" ] && ok "(e main) reconcile_state=quarantined (fail-closed decision point)" || bad "(e main) state != quarantined ($(cat "${M5}/cache/state" 2>/dev/null))"
    [ ! -s "${CURL_LOG}" ] && ok "(e main) writeback did NOT fire via real main() (0 ack POSTs)" || { bad "(e main) writeback FIRED via main():"; sed 's/^/        /' "${CURL_LOG}"; }
    [ $((t1-t0)) -le 15 ] && ok "(e main) bounded wall-clock through main() ($((t1-t0))s, no 50k fork storm)" || bad "(e main) main() DoS path slow ($((t1-t0))s)"
    # No file escaped containment during the subprocess run (its OUT_DIR is under JAIL sibling M5).
    esc="$(find "${M5}" -newer "${SENTINEL}" -type f -path '*/out/*-gitops/*' 2>/dev/null)"
    [ -z "${esc}" ] && ok "(e main) no brand tree promoted under main()'s OUT_DIR" || { bad "(e main) tree promoted under OUT_DIR:"; printf '        %s\n' ${esc}; }
else
    echo "  SKIP (e main) openssl unavailable — main() has a hard 'have openssl' pre-flight"
fi
echo

# ── (f) YAML/newline splice into an auth-relevant default ──────────────────────
echo "-- (f) YAML/newline splice into an auth-relevant default --"
declare -a fpay=(
  "domain|acme.test"$'\n'"ADMIN_EMAILS: attacker@evil"
  "title|Acme"$'\n'"leaked-issuer: http://evil"
  "headscale|https://h"$'\n'"x: y"
)
for spec in "${fpay[@]}"; do
    field="${spec%%|*}"; val="${spec#*|}"
    new_case
    case "${field}" in
      domain)    mkprofile "${WORK}/f.conf" acme Title Acme-Inc "${val}" https://headscale.acme.test tag:acme ;;
      title)     mkprofile "${WORK}/f.conf" acme "${val}" Acme-Inc acme.test https://headscale.acme.test tag:acme ;;
      headscale) mkprofile "${WORK}/f.conf" acme Title Acme-Inc acme.test "${val}" tag:acme ;;
    esac
    render_and_scan_profile "${WORK}/f.conf" acme "${CONTAIN}" >/dev/null 2>&1; rc=$?
    { [ "${rc}" -ne 0 ] && [ -n "${_DR_EMIT_FAILED:-}" ]; } && ok "(f) newline-splice in ${field} rejected (single-line/DNS/URL guard, rc=${rc})" || bad "(f) newline-splice in ${field} NOT rejected (rc=${rc})"
    # No spliced key must appear anywhere under containment.
    if grep -rq 'ADMIN_EMAILS: attacker@evil\|leaked-issuer: http://evil\|^x: y' "${CONTAIN}" 2>/dev/null; then
        bad "(f) spliced line LANDED in an emitted file under containment"
    else ok "(f) no spliced key/line emitted for ${field}"; fi
    assert_not_promoted "(f ${field})" acme
    assert_contained "(f ${field})"
    assert_no_writeback "(f ${field})"
done
echo

# ── POSITIVE CONTROL: a LEGIT export renders, scans clean, PROMOTES, and DOES ack.
echo "-- POSITIVE CONTROL: legit export still reconciles/renders (no false-positive lockout) --"
new_case
mkexport1 "${WORK}/legit.json" acme acme.test Acme-Inc tag:acme
render_brand_repos "${WORK}/legit.json" >/dev/null 2>&1; rc=$?
if [ "${rc}" -eq 0 ] && [ -z "${_DR_EMIT_FAILED:-}" ]; then ok "(legit) render_brand_repos succeeded, run NOT failed"
else bad "(legit) legit export failed the gate (rc=${rc}, _DR_EMIT_FAILED='${_DR_EMIT_FAILED:-}') — FALSE POSITIVE"; fi
if [ -d "${CONTAIN}/acme-gitops/apps" ] && [ -n "$(ls -A "${CONTAIN}/acme-gitops/apps" 2>/dev/null)" ]; then
    ok "(legit) promoted OUT_DIR/acme-gitops/apps/ ($(ls "${CONTAIN}/acme-gitops/apps" | wc -l) CRDs)"
    if grep -rqE '\{\{[A-Z_]+\}\}' "${CONTAIN}/acme-gitops/apps" 2>/dev/null; then bad "(legit) unsubstituted {{TOKEN}} remains"
    else ok "(legit) every {{TOKEN}} substituted"; fi
    if grep -rq 'acme.test' "${CONTAIN}/acme-gitops/apps" 2>/dev/null; then ok "(legit) rendered CRDs carry CLUSTER_DOMAIN acme.test"; else bad "(legit) missing brand domain"; fi
    # No frozen namespace was rewritten (sed path keeps hugmesh.net/* literal).
    if grep -rq 'hugmesh.net/' "${CONTAIN}/acme-gitops" 2>/dev/null; then ok "(legit) frozen hugmesh.net/* label keys preserved literal (not rebranded)"; fi
else bad "(legit) no promoted apps/ tree"; fi
# Writeback POSITIVE: on a clean run main() reaches writeback_acks; with a valid
# acted-on entry + the sentinel ACK URL the curl recorder MUST log the POST.
: > "${CURL_LOG}"
writeback_acks "${WORK}/legit.json" 7 >/dev/null 2>&1 || true
if [ -s "${CURL_LOG}" ]; then ok "(legit) writeback FIRES on a clean run (ack POST recorded) — gate is not a blanket lockout"
else bad "(legit) writeback did not fire on a clean run (ack wiring broken?)"; fi
echo

echo "== FUZZ SUITE: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
