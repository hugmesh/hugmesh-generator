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
# Proves, WITHOUT a cluster (the REAL loop body is extracted from the manifest and
# eval'd against a recording fake `kubectl` — the same tool-stub technique
# test-split-tunnel.sh uses for `ip` and test-vpn-mark.sh uses for `nft`):
#   * each labelled Secret lands at ${DEST}/<secret-name> — the name IS the
#     reconcile agent's secretRef, so the filename contract holds;
#   * the projected bytes are the DECODED `config` value, mode 0600;
#   * re-runs are idempotent;
#   * a Secret that disappears is PRUNED (after a SUCCESSFUL list);
#   * FAIL-CLOSED: a failing list prunes NOTHING and keeps every last-good file
#     (an API-server blip must not strip a node of its VPN config);
#   * FAIL-CLOSED: a Secret with no/empty `config` key never TRUNCATES a good file.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DS="${REPO}/specs/cluster/manifests/egress-vpn/secret-projector-daemonset.yaml"
[ -f "${DS}" ] || { echo "  FAIL projector DaemonSet missing: ${DS}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== egress-vpn secret-projector delivery unit test =="

# The loop body lives in the container's args[0]; pulling it out needs a YAML
# reader. Without python3 there is nothing to extract, so SKIP rather than
# pretend (the gate test SKIPs its registry assertion the same way).
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
    echo "  SKIP projector loop assertions (needs python3 + PyYAML to read the manifest)"
    echo "== RESULT: 0 passed, 0 failed =="
    exit 0
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
FIXTURES="${WORK}/fixtures"   # one file per secret name; absent => no `config` key
mkdir -p "${FIXTURES}"

# ── Fake kubectl: `get secrets -l ...` lists ${WORK}/secrets (one name per line);
# `get secret <n> -o go-template=...` prints ${FIXTURES}/<n>. A ${WORK}/fail-list
# marker makes the LIST fail (the API-outage case). ──────────────────────────────
cat > "${WORK}/bin/kubectl" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\${args}" in
    *"get secrets"*)
        [ -f "${WORK}/fail-list" ] && { echo "the server was unable to return a response" >&2; exit 1; }
        cat "${WORK}/secrets" 2>/dev/null; exit 0 ;;
    *"get secret "*)
        n=""
        while [ \$# -gt 0 ]; do
            case "\$1" in secret) n="\$2"; shift 2; continue ;; esac
            shift
        done
        [ -f "${FIXTURES}/\${n}" ] && cat "${FIXTURES}/\${n}"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "${WORK}/bin/kubectl"

# Run ONE pass of the REAL loop: `sleep` is stubbed to exit, so the script's own
# `while true` executes project_once exactly once and stops.
run_pass() {
    PATH="${WORK}/bin:${PATH}" TMPDIR="${WORK}/tmp" \
    SECRET_NS=hugmesh-egress-vpn \
    SECRET_SEL='snapdragon.systems/optional-service=egress-vpn' \
    SECRET_KEY=config DEST="${DEST}" INTERVAL=0 \
    bash -c 'sleep() { exit 0; }; source "$1"' _ "${SCRIPT}" >/dev/null 2>&1
}

# ── two labelled Secrets -> two 0600 files named after the Secrets ────────────
printf 'egress-vpn-example-com-proton-us\negress-vpn-example-com-proton-ch\n' > "${WORK}/secrets"
printf '[Interface]\nPrivateKey = AAA\n' > "${FIXTURES}/egress-vpn-example-com-proton-us"
printf 'client\nremote vpn.example 1194\n'  > "${FIXTURES}/egress-vpn-example-com-proton-ch"
run_pass

[ -f "${DEST}/egress-vpn-example-com-proton-us" ] && [ -f "${DEST}/egress-vpn-example-com-proton-ch" ] \
    && ok "each labelled Secret lands at \${DEST}/<secret-name> (== the export's secretRef)" \
    || bad "a labelled Secret was not projected"
cmp -s "${FIXTURES}/egress-vpn-example-com-proton-us" "${DEST}/egress-vpn-example-com-proton-us" \
    && ok "projected bytes are the decoded config value, byte-for-byte" || bad "projected bytes differ from the Secret"
mode="$(stat -c '%a' "${DEST}/egress-vpn-example-com-proton-us" 2>/dev/null)"
[ "${mode}" = "600" ] && ok "projected file is 0600 (the VPN-config mode the agent + provision_vpn enforce)" \
    || bad "projected file mode is ${mode:-unknown}, not 600"

# ── idempotent ────────────────────────────────────────────────────────────────
run_pass
cmp -s "${FIXTURES}/egress-vpn-example-com-proton-us" "${DEST}/egress-vpn-example-com-proton-us" \
    && ok "re-run is idempotent (same bytes, no churn)" || bad "re-run changed the projected bytes"

# ── un-assigned Secret is pruned (after a SUCCESSFUL list) ────────────────────
printf 'egress-vpn-example-com-proton-us\n' > "${WORK}/secrets"
rm -f "${FIXTURES}/egress-vpn-example-com-proton-ch"
run_pass
[ ! -f "${DEST}/egress-vpn-example-com-proton-ch" ] \
    && ok "a Secret that left the assignment is pruned from the node" || bad "stale projected config survived"
[ -f "${DEST}/egress-vpn-example-com-proton-us" ] \
    && ok "the still-assigned config is untouched by the prune" || bad "the prune took a live config with it"

# ── FAIL-CLOSED: a failing list prunes NOTHING ────────────────────────────────
: > "${WORK}/fail-list"
run_pass
[ -f "${DEST}/egress-vpn-example-com-proton-us" ] \
    && ok "FAIL-CLOSED: a failed list keeps every last-good file (no API-blip teardown)" \
    || bad "an API-server failure stripped the node of its VPN config"
rm -f "${WORK}/fail-list"

# ── FAIL-CLOSED: an empty/absent `config` key never truncates a good file ─────
: > "${FIXTURES}/egress-vpn-example-com-proton-us"      # Secret exists, no bytes
run_pass
[ -s "${DEST}/egress-vpn-example-com-proton-us" ] \
    && ok "FAIL-CLOSED: an empty 'config' key leaves the last-good file intact" \
    || bad "an empty Secret key truncated the node's working VPN config"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
