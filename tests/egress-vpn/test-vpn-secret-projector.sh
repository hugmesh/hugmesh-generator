#!/usr/bin/env bash
# test-vpn-secret-projector.sh — unit test for the RUNTIME config-byte delivery
# leg: the projector loop embedded in
# specs/cluster/manifests/egress-vpn/secret-projector-daemonset.yaml.
#
# THE GAP IT COVERS: hugmesh-vpn-reconcile reads the config BYTES from
# ${VPN_SECRET_DIR}/<secretRef> on the NODE HOST (default /etc/hugmesh/vpn-secret).
# Nothing ever put them there, so the runtime (UI/BFF + ESO) delivery path always
# fell back to the key-USB config. The projector DaemonSet is that hop.
#
# ── WHY THIS FILE WAS REWRITTEN (it was guard theatre) ────────────────────────
# The first version could not fail on the three values that actually shipped
# broken. It set
#     SECRET_NS=hugmesh-egress-vpn SECRET_SEL=... SECRET_KEY=config
# in its OWN invocation env, so it tested a projector configured by the TEST, not
# the projector configured by the MANIFEST. The manifest's SECRET_KEY was
# `config` while the admin-bff writer emits the bytes under the Secret's own
# name — a total delivery break — and every assertion here stayed green, because
# the manifest's value was never read.
#
# Now: the three values are LIFTED FROM THE MANIFEST, asserted against
# specs/cluster/egress-vpn-secret-contract.env (the cross-repo source of truth),
# and then used to run the loop. The fake kubectl is contract-aware — it answers
# only for the contract namespace/selector and only for the data key the loop
# actually asks for — so a wrong value in the manifest fails BOTH statically and
# behaviourally.
#
# Proves, WITHOUT a cluster (the REAL loop body is extracted from the manifest and
# eval'd against a recording fake `kubectl` — the same tool-stub technique
# test-split-tunnel.sh uses for `ip` and test-vpn-mark.sh uses for `nft`):
#   * the manifest's SECRET_NS / SECRET_SEL / SECRET_KEY EQUAL the contract;
#   * each labelled Secret lands at ${DEST}/<secret-name> — the name IS the
#     reconcile agent's secretRef, so the filename contract holds;
#   * the projected bytes are the DECODED value of the CONTRACT data key
#     (`@name` => the Secret's own metadata.name), mode 0600;
#   * a Secret carrying only the old `config` key delivers NOTHING and truncates
#     nothing — the pre-fix world, kept red;
#   * re-runs are idempotent;
#   * a Secret that disappears is PRUNED (after a SUCCESSFUL list);
#   * FAIL-CLOSED: a failing list prunes NOTHING and keeps every last-good file
#     (an API-server blip must not strip a node of its VPN config);
#   * FAIL-CLOSED: a Secret with no/empty contract key never TRUNCATES a good file.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DS="${REPO}/specs/cluster/manifests/egress-vpn/secret-projector-daemonset.yaml"
[ -f "${DS}" ] || { echo "  FAIL projector DaemonSet missing: ${DS}"; exit 1; }
# shellcheck source=lib/contract.sh
. "${REPO}/tests/egress-vpn/lib/contract.sh"
CONTRACT="$(contract_path "${REPO}")"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== egress-vpn secret-projector delivery unit test =="

# ══════════════════════════════════════════════════════════════════════════════
# PART 1 — THE CONTRACT VALUES, READ FROM THE MANIFEST.
# No optional tooling: grep + sed only, so this half can never be skipped.
# ══════════════════════════════════════════════════════════════════════════════
C_NS="$(contract_get "${CONTRACT}" EGRESS_VPN_SECRET_NAMESPACE)"  || C_NS=""
C_SEL="$(contract_get "${CONTRACT}" EGRESS_VPN_SECRET_SELECTOR)"  || C_SEL=""
C_KEY="$(contract_get "${CONTRACT}" EGRESS_VPN_SECRET_KEY)"       || C_KEY=""
if [ -n "${C_NS}" ] && [ -n "${C_SEL}" ] && [ -n "${C_KEY}" ]; then
    ok "read the cross-repo contract (${CONTRACT##*/})"
else
    bad "could not read the cross-repo contract from ${CONTRACT}"
    echo "== RESULT: ${P} passed, ${F} failed =="; exit 1
fi

M_NS="$(manifest_env "${DS}" SECRET_NS)"   || M_NS="<unreadable>"
M_SEL="$(manifest_env "${DS}" SECRET_SEL)" || M_SEL="<unreadable>"
M_KEY="$(manifest_env "${DS}" SECRET_KEY)" || M_KEY="<unreadable>"

[ "${M_NS}" = "${C_NS}" ] \
    && ok "manifest SECRET_NS == contract (${C_NS})" \
    || bad "manifest SECRET_NS is '${M_NS}', contract says '${C_NS}' — the projector would list an empty namespace"
[ "${M_SEL}" = "${C_SEL}" ] \
    && ok "manifest SECRET_SEL == contract (${C_SEL})" \
    || bad "manifest SECRET_SEL is '${M_SEL}', contract says '${C_SEL}' — the projector would select nothing"
[ "${M_KEY}" = "${C_KEY}" ] \
    && ok "manifest SECRET_KEY == contract (${C_KEY})" \
    || bad "manifest SECRET_KEY is '${M_KEY}', contract says '${C_KEY}' — the projector would read zero bytes from every Secret"

# ══════════════════════════════════════════════════════════════════════════════
# PART 2 — THE REAL LOOP, RUN WITH THE MANIFEST'S OWN VALUES.
# The loop body lives in the container's args[0]; pulling it out needs a YAML
# reader. Without python3 there is nothing to extract, so SKIP rather than
# pretend (the gate test SKIPs its registry assertion the same way). Part 1 above
# has already run unconditionally.
# ══════════════════════════════════════════════════════════════════════════════
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
    echo "  SKIP projector loop assertions (needs python3 + PyYAML to read the manifest)"
    echo "== RESULT: ${P} passed, ${F} failed =="
    [ "${F}" -eq 0 ]
    exit
fi

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
SCRIPT="${WORK}/projector.sh"
python3 - "${DS}" "${SCRIPT}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
c = d["spec"]["template"]["spec"]["containers"][0]
assert c["command"] == ["/bin/bash", "-c"], c["command"]
open(sys.argv[2], "w").write(c["args"][0])
PY
[ -s "${SCRIPT}" ] && ok "extracted the real projector loop from the DaemonSet" \
    || { bad "could not extract the projector loop"; echo "== RESULT: ${P} passed, ${F} failed =="; exit 1; }

mkdir -p "${WORK}/bin" "${WORK}/dest" "${WORK}/tmp"
DEST="${WORK}/dest"
# One DIRECTORY per Secret, one FILE per data key inside it — so the fake can
# answer "that Secret has no such key", which a flat fixture per Secret could
# not, and which is the whole shape of the bug this suite missed.
FIXTURES="${WORK}/fixtures"
mkdir -p "${FIXTURES}"

# ── CONTRACT-AWARE fake kubectl. It answers ONLY for the contract namespace and
# the contract selector (a wrong namespace errors like a real apiserver; a wrong
# selector matches nothing), and for a `get` it returns bytes only for the data
# key the loop actually asked for — parsed back out of the go-template the loop
# built. It bakes in the CONTRACT values while the loop is driven by the MANIFEST
# values, so drift between them shows up as a behavioural failure too. ─────────
cat > "${WORK}/bin/kubectl" <<EOF
#!/usr/bin/env bash
WANT_NS='${C_NS}'
WANT_SEL='${C_SEL}'
ns=""; sel=""; verb=""; name=""; tmpl=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -n) ns="\$2"; shift 2; continue ;;
        -l) sel="\$2"; shift 2; continue ;;
        -o) tmpl="\$2"; shift 2; continue ;;
        secrets) verb="list" ;;
        secret)  verb="get"; name="\$2"; shift 2; continue ;;
    esac
    shift
done
if [ "\${ns}" != "\${WANT_NS}" ]; then
    echo "Error from server (NotFound): namespaces \"\${ns}\" not found" >&2; exit 1
fi
case "\${verb}" in
    list)
        [ -f "${WORK}/fail-list" ] && { echo "the server was unable to return a response" >&2; exit 1; }
        [ "\${sel}" = "\${WANT_SEL}" ] || exit 0
        cat "${WORK}/secrets" 2>/dev/null; exit 0 ;;
    get)
        key="\$(printf '%s' "\${tmpl}" | sed -n 's/.*index \\.data "\\([^"]*\\)".*/\\1/p' | head -1)"
        [ -n "\${key}" ] || exit 0
        [ -f "${FIXTURES}/\${name}/\${key}" ] && cat "${FIXTURES}/\${name}/\${key}"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/kubectl"

# Write a Secret fixture from stdin: seed_secret <name> <data-key>
seed_secret() {
    local n="$1" k="$2"
    mkdir -p "${FIXTURES}/${n}"
    cat > "${FIXTURES}/${n}/${k}"
}
# The data key the CONTRACT says a Secret named $1 carries.
contract_key_for() {
    if [ "${C_KEY}" = "@name" ]; then printf '%s\n' "$1"; else printf '%s\n' "${C_KEY}"; fi
}

# Run ONE pass of the REAL loop with the MANIFEST's env values (NOT values chosen
# here — that substitution is what made the old version of this test blind).
# `sleep` is stubbed to exit, so the script's own `while true` executes
# project_once exactly once and stops.
run_pass() {
    PATH="${WORK}/bin:${PATH}" TMPDIR="${WORK}/tmp" \
    SECRET_NS="${M_NS}" SECRET_SEL="${M_SEL}" SECRET_KEY="${M_KEY}" \
    DEST="${DEST}" INTERVAL=0 \
    bash -c 'sleep() { exit 0; }; source "$1"' _ "${SCRIPT}" >/dev/null 2>&1
}

A=egress-vpn-example-com-proton-us
B=egress-vpn-example-com-proton-ch

# ── two labelled Secrets -> two 0600 files named after the Secrets ────────────
printf '%s\n%s\n' "${A}" "${B}" > "${WORK}/secrets"
printf '[Interface]\nPrivateKey = AAA\n'   | seed_secret "${A}" "$(contract_key_for "${A}")"
printf 'client\nremote vpn.example 1194\n' | seed_secret "${B}" "$(contract_key_for "${B}")"
run_pass

[ -f "${DEST}/${A}" ] && [ -f "${DEST}/${B}" ] \
    && ok "each labelled Secret lands at \${DEST}/<secret-name> (== the export's secretRef)" \
    || bad "a labelled Secret was not projected"
cmp -s "${FIXTURES}/${A}/$(contract_key_for "${A}")" "${DEST}/${A}" \
    && ok "projected bytes are the decoded contract-key value, byte-for-byte" || bad "projected bytes differ from the Secret"
mode="$(stat -c '%a' "${DEST}/${A}" 2>/dev/null)"
[ "${mode}" = "600" ] && ok "projected file is 0600 (the VPN-config mode the agent + provision_vpn enforce)" \
    || bad "projected file mode is ${mode:-unknown}, not 600"

# ── idempotent ────────────────────────────────────────────────────────────────
run_pass
cmp -s "${FIXTURES}/${A}/$(contract_key_for "${A}")" "${DEST}/${A}" \
    && ok "re-run is idempotent (same bytes, no churn)" || bad "re-run changed the projected bytes"

# ── un-assigned Secret is pruned (after a SUCCESSFUL list) ────────────────────
printf '%s\n' "${A}" > "${WORK}/secrets"
rm -rf "${FIXTURES:?}/${B}"
run_pass
[ ! -f "${DEST}/${B}" ] \
    && ok "a Secret that left the assignment is pruned from the node" || bad "stale projected config survived"
[ -f "${DEST}/${A}" ] \
    && ok "the still-assigned config is untouched by the prune" || bad "the prune took a live config with it"

# ── FAIL-CLOSED: a failing list prunes NOTHING ────────────────────────────────
: > "${WORK}/fail-list"
run_pass
[ -f "${DEST}/${A}" ] \
    && ok "FAIL-CLOSED: a failed list keeps every last-good file (no API-blip teardown)" \
    || bad "an API-server failure stripped the node of its VPN config"
rm -f "${WORK}/fail-list"

# ── THE SHIPPED BUG, KEPT RED: a Secret carrying only the old `config` key ────
# This is the exact shape a `SECRET_KEY: config` projector would need, and the
# shape the admin-bff writer never produces. It must deliver NOTHING — and, being
# fail-closed, must not truncate the last-good file beside it either.
NEW=egress-vpn-example-com-proton-de
printf '%s\n%s\n' "${A}" "${NEW}" > "${WORK}/secrets"
printf '[Interface]\nPrivateKey = NEVER-DELIVERED\n' | seed_secret "${NEW}" config
run_pass
if [ -f "${DEST}/${NEW}" ]; then
    bad "a Secret whose only data key is 'config' was projected — the reader is not on the contract key"
else
    ok "a Secret carrying only the old 'config' key delivers nothing (the shipped mismatch stays visible)"
fi
[ -s "${DEST}/${A}" ] \
    && ok "…and it did not truncate the working config beside it" \
    || bad "the unreadable Secret damaged a good projected config"
rm -rf "${FIXTURES:?}/${NEW}"; rm -f "${DEST}/${NEW}"

# ── FAIL-CLOSED: an empty/absent contract key never truncates a good file ─────
printf '%s\n' "${A}" > "${WORK}/secrets"
: > "${FIXTURES}/${A}/$(contract_key_for "${A}")"      # Secret exists, no bytes
run_pass
[ -s "${DEST}/${A}" ] \
    && ok "FAIL-CLOSED: an empty contract key leaves the last-good file intact" \
    || bad "an empty Secret key truncated the node's working VPN config"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
