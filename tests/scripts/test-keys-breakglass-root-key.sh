#!/usr/bin/env bash
# test-keys-breakglass-root-key.sh — a worker KEYS stick's break-glass root key is
# actually installed.
#
# scripts/gen-provision-keys.sh gives a worker stick NO users.json and one
# ssh/root.authorized_keys, which it calls the worker's "break-glass SSH" key.
# keys-provision only installed root keys from inside provision_users, after its
# "No users.json" / "No .users/.root" early returns, so on exactly those sticks the
# key never reached /root/.ssh (observed on a booted worker: /root/.ssh empty).
#
# Runs keys-provision's REAL functions and its REAL main() step sequence from
# provision_users up to provision_dial_user, with /root and /etc/ssh redirected
# into a scratch dir and the account tools stubbed. No root needed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
P=0
N=0
ok()  { printf '  PASS %s\n' "$*"; P=$((P + 1)); }
bad() { printf '  FAIL %s\n' "$*"; N=$((N + 1)); }

command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }

extract_fn() { sed -n "/^$1() {/,/^}/p" "${PROV}"; }

# The step sequence main() runs from provision_users up to (not including)
# provision_dial_user, so a step added between them is exercised too.
STEPS="$(awk '/^    provision_users$/{p=1} /^    provision_dial_user/{exit} p{print}' "${PROV}")"
[ -n "${STEPS}" ] || { echo "FATAL: could not find main()'s provision_users step in ${PROV}" >&2; exit 2; }

FNS=""
for fn in desktop_governance_governed provision_users install_root_keys \
          provision_root_breakglass root_keys_ssh_reachability_note; do
    FNS="${FNS}$(extract_fn "${fn}")
"
done

KEY_A='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBreakGlassWorkerKeyForTheTestOnly000000 breakglass'
KEY_B='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRootBlockKeyFromTheManifestForTest0000 rootblock'

# run_case <name> <manifest json|""> <with root.authorized_keys: yes|no> <PermitRootLogin|"">
# -> leaves ${WORK}/<name>/{root,log}
run_case() {
    local d="${WORK}/$1"
    mkdir -p "${d}/keys/ssh" "${d}/state" "${d}/etc/ssh/sshd_config.d"
    [ -n "$2" ] && printf '%s\n' "$2" > "${d}/keys/provision.json"
    [ "$3" = yes ] && printf '%s\n' "${KEY_A}" > "${d}/keys/ssh/root.authorized_keys"
    [ -n "$4" ] && printf 'PermitRootLogin %s\n' "$4" > "${d}/etc/ssh/sshd_config.d/00-root-login.conf"
    local fns="${FNS//\/root\/.ssh/${d}/root/.ssh}"
    fns="${fns//\/etc\/ssh\//${d}/etc/ssh/}"
    fns="${fns//\/etc\/hugmesh\/desktop-governance/${d}/no-such-dir}"
    ( BASE="${d}/keys"; MANIFEST="${d}/keys/provision.json"
      STATE_DIR="${d}/state"; USERS_MARKER="${d}/state/users.created"
      log()  { echo "LOG $*"; }
      warn() { echo "WARNING: $*"; }
      passwd() { echo "STUB passwd $*"; }
      chpasswd() { cat >/dev/null; }
      eval "${fns}"
      eval "${STEPS}" ) > "${d}/log" 2>&1
}

echo "== worker stick: no users.json, ssh/root.authorized_keys only =="
run_case worker '{"hostname":"node-be-01"}' yes ""
ak="${WORK}/worker/root/.ssh/authorized_keys"
if [ -f "${ak}" ] && grep -qxF "${KEY_A}" "${ak}"; then
    ok "the break-glass key is installed for root"
else bad "the break-glass key was NOT installed (/root/.ssh/authorized_keys missing)"; fi
if [ -f "${ak}" ] && [ "$(stat -c %a "${ak}")" = 600 ] && [ "$(stat -c %a "${WORK}/worker/root/.ssh")" = 700 ]; then
    ok "/root/.ssh is 0700 and authorized_keys 0600"
else bad "wrong modes on /root/.ssh or authorized_keys"; fi

echo "== the WARNING when sshd refuses root =="
run_case refuse '{"hostname":"node-be-01"}' yes no
if grep -q "WARNING: .*PermitRootLogin no" "${WORK}/refuse/log"; then
    ok "PermitRootLogin no: keys-provision warns that the key is not usable over SSH"
else bad "PermitRootLogin no: no warning that the installed key is unusable"; fi
run_case allow '{"hostname":"node-be-01"}' yes prohibit-password
if grep -q "WARNING: .*PermitRootLogin" "${WORK}/allow/log"; then
    bad "PermitRootLogin prohibit-password: a spurious warning"
else ok "PermitRootLogin prohibit-password: no warning"; fi

echo "== a .root block keeps its own keys (no second install drops them) =="
run_case rootblock "{\"root\":{\"locked\":true,\"ssh_authorized_keys\":[\"${KEY_B}\"]}}" yes ""
ak="${WORK}/rootblock/root/.ssh/authorized_keys"
if [ -f "${ak}" ] && grep -qxF "${KEY_A}" "${ak}" && grep -qxF "${KEY_B}" "${ak}"; then
    ok "both the .root.ssh_authorized_keys key and the stick's root key are installed"
else bad "a .root block's keys were lost: $(cat "${ak}" 2>/dev/null | wc -l) line(s)"; fi

echo "== no key on the stick: nothing is created =="
run_case nokey '{"hostname":"node-be-01"}' no ""
if [ -e "${WORK}/nokey/root/.ssh" ]; then bad "/root/.ssh was created with no key to install"
else ok "no key, no /root/.ssh"; fi

echo "== test-keys-breakglass-root-key: ${P} passed, ${N} failed =="
[ "${N}" -eq 0 ]
