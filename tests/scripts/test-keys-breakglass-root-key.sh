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
          provision_root_breakglass root_keys_ssh_reachability_note \
          sshd_global_value device_registry_owner_type; do
    FNS="${FNS}$(extract_fn "${fn}")
"
done

KEY_A='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBreakGlassWorkerKeyForTheTestOnly000000 breakglass'
KEY_B='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRootBlockKeyFromTheManifestForTest0000 rootblock'

SSHD_D="${REPO}/specs/etc/ssh/sshd_config.d"

# run_case <name> <manifest json|""> <with root.authorized_keys: yes|no> <PermitRootLogin|"">
#          [setup-fn: called with the case dir, to lay down extra sshd config]
# -> leaves ${WORK}/<name>/{root,log}. STANDALONE_IMG passes through from the caller.
run_case() {
    local d="${WORK}/$1"
    mkdir -p "${d}/keys/ssh" "${d}/state" "${d}/etc/ssh/sshd_config.d"
    [ -n "$2" ] && printf '%s\n' "$2" > "${d}/keys/provision.json"
    [ "$3" = yes ] && printf '%s\n' "${KEY_A}" > "${d}/keys/ssh/root.authorized_keys"
    [ -n "$4" ] && printf 'PermitRootLogin %s\n' "$4" > "${d}/etc/ssh/sshd_config.d/00-root-login.conf"
    [ -n "${5:-}" ] && "$5" "${d}"
    local fns="${FNS//\/root\/.ssh/${d}/root/.ssh}"
    fns="${fns//\/etc\/ssh\//${d}/etc/ssh/}"
    fns="${fns//\/etc\/hugmesh\/desktop-governance/${d}/no-such-dir}"
    ( BASE="${d}/keys"; MANIFEST="${d}/keys/provision.json"
      STATE_DIR="${d}/state"; USERS_MARKER="${d}/state/users.created"
      log()  { echo "LOG $*"; }
      warn() { echo "WARNING: $*"; }
      passwd() { echo "STUB passwd $*"; }
      chpasswd() { cat >/dev/null; }
      jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
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
if grep -q "installing the break-glass" "${WORK}/nokey/log"; then
    bad "no key on the stick, yet the log claims a break-glass key is being installed"
else ok "no key, no 'installing the break-glass' claim in the log"; fi

echo "== sshd's other PermitRootLogin spellings =="
eq_tight()  { printf 'PermitRootLogin=no\n'    > "$1/etc/ssh/sshd_config.d/00-root-login.conf"; }
eq_spaced() { printf '  permitrootlogin = "no"\n' > "$1/etc/ssh/sshd_config.d/00-root-login.conf"; }
run_case eqtight '{"hostname":"node-be-01"}' yes "" eq_tight
if grep -q "WARNING: .*PermitRootLogin no" "${WORK}/eqtight/log"; then
    ok "PermitRootLogin=no: warned"
else bad "PermitRootLogin=no: no warning (the '=' spelling was not read)"; fi
run_case eqspaced '{"hostname":"node-be-01"}' yes "" eq_spaced
if grep -q "WARNING: .*PermitRootLogin no" "${WORK}/eqspaced/log"; then
    ok "'permitrootlogin = \"no\"' (indented, any case, quoted): warned"
else bad "'permitrootlogin = \"no\"': no warning"; fi
# sshd matches multistate VALUES case-insensitively too (servconf.c strcasecmp).
val_case() { printf 'PermitRootLogin No\n' > "$1/etc/ssh/sshd_config.d/00-root-login.conf"; }
run_case valcase '{"hostname":"node-be-01"}' yes "" val_case
if grep -q "WARNING: .*PermitRootLogin no" "${WORK}/valcase/log"; then
    ok "'PermitRootLogin No' (value in another case): warned"
else bad "'PermitRootLogin No': no warning (the value was compared case-sensitively)"; fi

# sshd keeps the FIRST value even within one file (sshd_config itself, say).
two_in_one() { printf 'PermitRootLogin no\nPermitRootLogin prohibit-password\n' > "$1/etc/ssh/sshd_config"; }
run_case twoinone '{"hostname":"node-be-01"}' yes "" two_in_one
if grep -q "WARNING: .*PermitRootLogin no" "${WORK}/twoinone/log"; then
    ok "two PermitRootLogin lines in one file: the first ('no') wins and is warned about"
else bad "two PermitRootLogin lines in one file: the first value did not win"; fi

echo "== a Match block is not the global setting =="
# A drop-in that sorts FIRST but sets PermitRootLogin only inside a Match: sshd's
# global value is the later prohibit-password, so no warning.
match_first() {
    printf 'Match Address 192.0.2.1\n    PermitRootLogin no\n' > "$1/etc/ssh/sshd_config.d/00-a-match.conf"
    printf 'PermitRootLogin prohibit-password\n' > "$1/etc/ssh/sshd_config.d/10-root-login.conf"
}
run_case matchfirst '{"hostname":"node-be-01"}' yes "" match_first
if grep -q "WARNING: .*PermitRootLogin" "${WORK}/matchfirst/log"; then
    bad "a Match-scoped 'PermitRootLogin no' was taken as the global value"
else ok "a Match-scoped 'PermitRootLogin no' does not decide the global value"; fi

echo "== registry enforcement: 'AuthorizedKeysFile none' =="
# The REAL drop-ins as a flipped registry-enforced node has them: break-glass.conf
# sorts first and its AuthorizedKeysFile is inside a loopback Match, so the global
# value is device-registry.conf's `none`.
registry_live() {
    cp "${SSHD_D}/break-glass.conf" "${SSHD_D}/device-registry.conf" "$1/etc/ssh/sshd_config.d/"
}
run_case reglive '{"hostname":"node-be-01"}' yes prohibit-password registry_live
if grep -q "WARNING: .*AuthorizedKeysFile none" "${WORK}/reglive/log"; then
    ok "live device-registry.conf: warned that root's authorized_keys is not consulted"
else bad "live device-registry.conf (AuthorizedKeysFile none): no warning, the log says the key is usable"; fi
if grep -q "the root key is usable over SSH" "${WORK}/reglive/log"; then
    bad "live device-registry.conf: the log still claims the root key is usable"
else ok "live device-registry.conf: no 'usable' claim"; fi

# Before the first verified sync device-registry.conf is only STAGED, so the
# manifest decides: a mesh-extension (owner ADMIN) node is about to lose the key.
run_case regpending '{"hostname":"node-be-01","device_registry":{"image_type":"mesh-extension"}}' yes prohibit-password
if grep -q "WARNING: .*registry-enforced" "${WORK}/regpending/log"; then
    ok "mesh-extension manifest: warned that the key stops working once the registry gate flips"
else bad "mesh-extension manifest: no warning that the registry gate will retire the root key"; fi
run_case regowner '{"hostname":"node-be-01","device_registry":{"owner_type":"ADMIN"}}' yes prohibit-password
if grep -q "WARNING: .*registry-enforced" "${WORK}/regowner/log"; then
    ok "owner_type ADMIN: warned"
else bad "owner_type ADMIN: no registry warning"; fi
run_case regcore '{"hostname":"node-be-01","device_registry":{"image_type":"mesh-extension","owner_type":"SUPERADMIN"}}' yes prohibit-password
if grep -q "WARNING:" "${WORK}/regcore/log"; then
    bad "owner_type SUPERADMIN (core node): a spurious warning"
else ok "owner_type SUPERADMIN wins over image_type: no warning"; fi
STANDALONE_IMG=true run_case regstandalone '{"hostname":"node-be-01","device_registry":{"image_type":"mesh-extension"}}' yes prohibit-password
if grep -q "WARNING:" "${WORK}/regstandalone/log"; then
    bad "standalone image: a registry warning although provision_device_registry never runs there"
else ok "standalone image: no registry warning (registry enforcement is never installed)"; fi

echo "== test-keys-breakglass-root-key: ${P} passed, ${N} failed =="
[ "${N}" -eq 0 ]
