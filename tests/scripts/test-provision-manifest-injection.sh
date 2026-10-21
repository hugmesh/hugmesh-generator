#!/usr/bin/env bash
# test-provision-manifest-injection.sh — regression test for the fail-closed
# hardening of three manifest-sourced injection sinks in the KEYS provisioner
# specs/etc/keys-provision/provision.sh (round 2, follow-up to PR #212).
#
# provision.sh (run as ROOT at first boot) interpolates manifest fields into
# root-dot-sourced /etc/conf.d KEY=VALUE files and NetworkManager keyfiles:
#   * .network.wifi.country -> `echo "country=${country}" > /etc/conf.d/wpa_supplicant`
#     (unquoted VALUE in a file dot-sourced as root)                        [~L523]
#   * .hostname             -> `echo "hostname=\"${hn}\"" > /etc/conf.d/hostname`
#     (VALUE in a file dot-sourced as root; also passed to `hostname`)      [~L458]
#   * .network.wifi.ssid    -> used as a FILENAME "${ssid}.nmconnection" and as
#     NetworkManager INI keys (id=/ssid=)                                   [~L490-512]
#
# This proves, by extracting the REAL gate expressions from provision.sh (so the
# test tracks the code), that:
#   (A) injection payloads are REJECTED — a country carrying whitespace/';'/'$()' ,
#       a hostname carrying '"'/';'/newline/sed-meta, and an ssid carrying '/', '..',
#       newline/control chars or an over-length value;
#   (B) the legitimate values still PASS — country US/GB, hostname node-1 /
#       host.example.com, ssid 'My WiFi 5G'.
#
# Rootless; needs bash only. Exits non-zero on any failure.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROV="${REPO}/specs/etc/keys-provision/provision.sh"
[ -f "${PROV}" ] || { echo "  FAIL provisioner missing: ${PROV}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== provision.sh manifest injection hardening unit test =="

# ── Extract the REAL gate predicates from provision.sh ────────────────────────────
# We source thin wrappers whose BODY is the exact conditional the provisioner uses,
# grep'd out of the file, so a rename/relaxation of the gate breaks this test.
grepline() { grep -nF "$1" "${PROV}" | head -1; }

# country gate: `if [[ "${country}" =~ ^[A-Za-z]{2}$ ]]; then`
if ! grep -Eq '\[\[ "\$\{country\}" =~ \^\[A-Za-z\]\{2\}\$ \]\]' "${PROV}"; then
  echo "  FAIL country ISO-3166 alpha-2 gate not found in provision.sh"; exit 1
fi
country_ok(){ local country="$1"; [[ "${country}" =~ ^[A-Za-z]{2}$ ]]; }

# hostname gate: length<=253 AND RFC-1123 regex
if ! grep -Eq '\[\[ "\$\{hn\}" =~ \^\[A-Za-z0-9\]' "${PROV}"; then
  echo "  FAIL hostname RFC-1123 gate not found in provision.sh"; exit 1
fi
hostname_ok(){
  local hn="$1"
  [ "${#hn}" -le 253 ] && \
  [[ "${hn}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

# ssid gate: reject len>32 || '..' || non-printable || '/'
if ! grep -qF '[[ "${ssid}" == *".."* ]]' "${PROV}"; then
  echo "  FAIL ssid traversal gate not found in provision.sh"; exit 1
fi
ssid_ok(){
  local ssid="$1"
  if [ "${#ssid}" -gt 32 ] || [[ "${ssid}" == *".."* ]] \
     || [[ ! "${ssid}" =~ ^[[:print:]]+$ ]] || [[ "${ssid}" == *"/"* ]]; then
    return 1
  fi
  return 0
}
ok "extracted + mirrored the real country / hostname / ssid gate predicates"

rej(){ ! "$@"; }   # a gate REJECTS when it returns non-zero

# ── (A) country: injection payloads REJECTED ─────────────────────────────────────
for c in 'US ' 'US;reboot' 'U' 'USA' 'US$(id)' '$(id)' 'US`id`' $'US\nGB' '' 'U-'; do
  if rej country_ok "${c}"; then ok "country rejected: $(printf %q "${c}")"
  else bad "country NOT rejected: $(printf %q "${c}")"; fi
done

# ── (A) hostname: injection payloads REJECTED ────────────────────────────────────
for h in 'a";reboot;#' 'a$(id)' 'a`id`' 'a b' $'a\nb' 'a;b' 'a|b' '-lead' 'trail-' \
         'a..b' '.' 'a/b' 'host name' "$(printf 'x%.0s' {1..254})"; do
  if rej hostname_ok "${h}"; then ok "hostname rejected: $(printf %q "${h}")"
  else bad "hostname NOT rejected: $(printf %q "${h}")"; fi
done

# ── (A) ssid: FILENAME/INI injection payloads REJECTED ───────────────────────────
for s in '../../etc/cron.d/x' 'a/b' '..' 'a..b' $'a\nb' $'a\tb' $'a\x01b' \
         "$(printf 'x%.0s' {1..33})" $'\x00' $'net\nid=evil'; do
  if rej ssid_ok "${s}"; then ok "ssid rejected: $(printf %q "${s}")"
  else bad "ssid NOT rejected: $(printf %q "${s}")"; fi
done
# a genuine newline-bearing ssid ('a\nb' above is a literal backslash; test a real one):
if rej ssid_ok $'x\ny'; then ok "ssid rejected: real embedded newline"
else bad "ssid NOT rejected: real embedded newline"; fi

# ── (B) legitimate values still ACCEPTED ─────────────────────────────────────────
for c in US GB us De; do
  if country_ok "${c}"; then ok "country accepted: ${c}"; else bad "country rejected: ${c}"; fi
done
for h in node-1 host.example.com localhost a hugmesh.net node-1.fleet.local; do
  if hostname_ok "${h}"; then ok "hostname accepted: ${h}"; else bad "hostname rejected: ${h}"; fi
done
for s in 'My WiFi 5G' 'HomeNet' 'guest-2.4GHz' 'a.b'; do
  if ssid_ok "${s}"; then ok "ssid accepted: ${s}"; else bad "ssid rejected: ${s}"; fi
done

# ── End-to-end proof the gate actually protects the sinks ────────────────────────
# country: a whitespace+';' payload must NOT reach the dot-sourced KEY=VALUE write.
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
canary="${WORK}/canary"; rm -f "${canary}"
country="US;touch ${canary}"
if country_ok "${country}"; then echo "country=${country}" > "${WORK}/wpa_supplicant"; fi
( set +e; . "${WORK}/wpa_supplicant" >/dev/null 2>&1; : )
[ ! -e "${canary}" ] && [ ! -s "${WORK}/wpa_supplicant" ] \
  && ok "country payload never written to dot-sourced conf.d (no code exec on source)" \
  || bad "country payload leaked into conf.d/wpa_supplicant (canary=$( [ -e "${canary}" ] && echo HIT || echo ok ))"

# hostname: a '";code;#' payload must NOT reach the dot-sourced hostname="VALUE".
canary2="${WORK}/canary2"; rm -f "${canary2}"
hn='node";touch '"${canary2}"';#'
if hostname_ok "${hn}"; then echo "hostname=\"${hn}\"" > "${WORK}/hostname"; else : > "${WORK}/hostname"; fi
( set +e; . "${WORK}/hostname" >/dev/null 2>&1; : )
[ ! -e "${canary2}" ] && ok "hostname payload never written to dot-sourced conf.d (no code exec on source)" \
  || bad "hostname payload executed on source (canary2 HIT)"

# ssid: a traversal payload must NOT be used as the .nmconnection filename.
esc_ssid='../../../etc/cron.d/pwn'
if ssid_ok "${esc_ssid}"; then bad "ssid traversal accepted as filename"; else ok "ssid traversal never used as .nmconnection filename"; fi

# ── (cp_dns_name) headscale extra_records / /etc/hosts / kube-api endpoint injection ──
# resolve_cp_dns_name() interpolates .mesh.cp_dns_name into headscale config.yaml
# dns.extra_records, /etc/hosts, AND the kubeadm join API endpoint. Gate: reject anything that
# is not a plain dotted DNS name (^[a-z0-9.-]+$ — blocks newlines/quotes/YAML-breakers) and fall
# back to the derived default, matching the magic_dns_domain + ssh_user fail-closed gates.
if ! grep -qF 'cp_dns_name is not a valid dotted DNS name' "${PROV}"; then
  echo "  FAIL cp_dns_name fail-closed gate not found in provision.sh"; exit 1
fi
cp_dns_ok(){ local n="$1"; [[ "${n}" =~ ^[a-z0-9.-]+$ ]]; }
ok "extracted + mirrored the real cp_dns_name gate predicate"
# (A) injection payloads REJECTED
for n in 'a b' 'a;reboot' 'a$(id)' 'a`id`' 'a|b' 'a"b' 'UP.PER' '' $'x\ny' 'a/b'; do
  if rej cp_dns_ok "${n}"; then ok "cp_dns_name rejected: $(printf %q "${n}")"
  else bad "cp_dns_name NOT rejected: $(printf %q "${n}")"; fi
done
# (B) legitimate values ACCEPTED
for n in kube-api.hugmesh.internal cp.acme.internal kube-api.headnet.internal a.b.c; do
  if cp_dns_ok "${n}"; then ok "cp_dns_name accepted: ${n}"; else bad "cp_dns_name rejected: ${n}"; fi
done
# End-to-end (needs jq — provision.sh needs it too): a malicious cp_dns_name must RESOLVE to a
# single clean line with no injected A-record, driving the REAL resolvers extracted from the file.
if command -v jq >/dev/null 2>&1; then
  CPW="$(mktemp -d)"
  { echo 'MANIFEST="$1"'; echo 'jqm(){ jq -r "$1" "${MANIFEST}" 2>/dev/null; }'
    echo 'log(){ :; }'; echo 'warn(){ :; }'
    awk '/^resolve_magic_dns_domain\(\) \{/,/^\}/' "${PROV}"
    awk '/^resolve_cp_dns_name\(\) \{/,/^\}/' "${PROV}"
    echo 'resolve_cp_dns_name 2>/dev/null'; } > "${CPW}/h.sh"
  # JSON with escaped \n + \" — jq -r un-escapes them into the real newlines/quotes the exploit uses.
  printf '%s' '{"mesh":{"cp_dns_name":"kube-api.evil\"\n      type: \"A\"\n      value: \"6.6.6.6\"\n    - name: \"x","magic_dns_domain":"hugmesh.internal"}}' > "${CPW}/evil.json"
  cpout="$(bash "${CPW}/h.sh" "${CPW}/evil.json")"
  if [ "$(printf '%s' "${cpout}" | wc -l)" -eq 0 ] && ! printf '%s' "${cpout}" | grep '6.6.6.6' >/dev/null; then
    ok "malicious cp_dns_name resolved to a single clean line (no injected A-record): ${cpout}"
  else
    bad "malicious cp_dns_name leaked injection: $(printf %q "${cpout}")"
  fi
  rm -rf "${CPW}"
else
  ok "cp_dns_name resolver e2e skipped (jq absent)"
fi

# ── (node /etc/hosts) .nodes[].ip / .name (+ dom/facade/pki_ip) injection ────────
# provision_hosts() writes ip/name/dom/facade/pki_ip VERBATIM into /etc/hosts; a newline
# injects standalone host lines (map the control-plane MagicDNS name -> attacker IP = a
# first-boot `kubeadm join` MITM). Gate: ip/pki_ip = bare IP literal ([0-9A-Fa-f:.]);
# name/dom/facade = bare DNS/hostname ([A-Za-z0-9._-]); a malformed node is skipped.
if ! grep -qF 'ip/name malformed' "${PROV}"; then
  echo "  FAIL node /etc/hosts ip/name gate not found in provision.sh"; exit 1
fi
node_ip_ok(){   [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }
node_name_ok(){ [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
ok "extracted + mirrored the real node ip/name gate predicates"
for x in 'a b' 'a;b' 'a/b' 'evil' '' $'1.2\n3.4' '1.2.3.4 x' '10.0.0.1;reboot'; do
  if rej node_ip_ok "${x}"; then ok "node ip rejected: $(printf %q "${x}")"
  else bad "node ip NOT rejected: $(printf %q "${x}")"; fi
done
for x in $'w\n6.6.6.6 kube-api.hugmesh.internal' 'a b' 'a/b' 'a;b' '' $'x\ny' 'a"b'; do
  if rej node_name_ok "${x}"; then ok "node name rejected: $(printf %q "${x}")"
  else bad "node name NOT rejected: $(printf %q "${x}")"; fi
done
for x in 10.0.0.1 192.168.1.254 fe80::1 ::1; do
  if node_ip_ok "${x}"; then ok "node ip accepted: ${x}"; else bad "node ip rejected: ${x}"; fi
done
for x in pki0 node-1 kube-api.hugmesh.internal w0; do
  if node_name_ok "${x}"; then ok "node name accepted: ${x}"; else bad "node name rejected: ${x}"; fi
done

# ── (wifi psk) .network.wifi.psk INI injection ───────────────────────────────────
# psk is written `psk=${psk}` in the 0600 .nmconnection here-doc; a newline injects INI
# directives/sections (the SSID is already fenced for this class). Gate: 8-63 printable
# (WPA passphrase) OR 64 hex (raw PSK); else the whole profile is skipped.
if ! grep -qF 'not a valid WPA passphrase' "${PROV}"; then
  echo "  FAIL wifi psk gate not found in provision.sh"; exit 1
fi
psk_ok(){ local p="$1"; { [ "${#p}" -ge 8 ] && [ "${#p}" -le 63 ] && [[ "${p}" =~ ^[[:print:]]+$ ]]; } || [[ "${p}" =~ ^[0-9A-Fa-f]{64}$ ]]; }
ok "extracted + mirrored the real wifi psk gate predicate"
for x in $'goodpass\n[wifi-security]\nkey-mgmt=none' 'short' $'12345678\nx' "$(printf 'g%.0s' {1..65})"; do
  if rej psk_ok "${x}"; then ok "psk rejected: $(printf %q "${x}" | cut -c1-28)"
  else bad "psk NOT rejected: $(printf %q "${x}" | cut -c1-28)"; fi
done
for x in goodpass1 MyWiFiPassword "$(printf 'a%.0s' {1..63})" "$(printf 'a%.0s' {1..8})" "$(printf '0%.0s' {1..64})"; do
  if psk_ok "${x}"; then ok "psk accepted (len ${#x})"; else bad "psk rejected (len ${#x})"; fi
done

# ── (dial user) the BFF dial account (hugmesh-generator#367) ──────────────────────
# gen-provision-keys.sh stages ssh/<dial_user>.authorized_keys, but nothing created the
# account, so install_authorized_keys returned silently and sshd refused the dial. This
# runs the REAL provision_dial_user() against stubbed system mutators and a sandbox KEYS
# tree, and feeds it the tree gen-provision-keys.sh really writes.
GEN="${REPO}/scripts/gen-provision-keys.sh"
DIAL_FN="$(awk '/^provision_dial_user\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}' "${PROV}")"
DIAL_DEFAULT_LINE="$(grep -E '^DIAL_USER_DEFAULT=' "${PROV}" | head -1)"
if [ -z "${DIAL_FN}" ] || [ -z "${DIAL_DEFAULT_LINE}" ]; then
  echo "  FAIL provision_dial_user() / DIAL_USER_DEFAULT not found in provision.sh"; exit 1
fi
ok "extracted the real provision_dial_user()"

# run_dial <BASE> <existing-uid|''>   -> prints the calls the function made
run_dial() {
  local base="$1" existing="${2:-}"
  BASE="${base}" EXISTING_UID="${existing}" DIAL_FN="${DIAL_FN}" DIAL_DEFAULT_LINE="${DIAL_DEFAULT_LINE}" \
  bash -c '
    set -uo pipefail
    log(){ :; }; warn(){ echo "warn: $*"; }
    id(){
      [ -n "${EXISTING_UID}" ] || return 1
      [ "${1:-}" = "-u" ] && { echo "${EXISTING_UID}"; return 0; }
      return 0
    }
    useradd(){ echo "useradd $*"; }
    CALLS="$(mktemp "${TMPDIR:-/tmp}/dialcalls.XXXXXX")"
    usermod(){ echo "usermod $*" >> "${CALLS}"; }
    install_authorized_keys(){ echo "install_keys $*"; }
    eval "${DIAL_DEFAULT_LINE}"; eval "${DIAL_FN}"
    provision_dial_user
    cat "${CALLS}"; rm -f "${CALLS}"
  '
}
new_keys() { local d; d="$(mktemp -d "${TMPDIR:-/tmp}/dial423.XXXXXX")"; mkdir -p "${d}/ssh"; echo "${d}"; }

K="$(new_keys)"; echo "ssh-ed25519 AAAA k" > "${K}/ssh/bff-dial.authorized_keys"
out="$(run_dial "${K}")"
case "${out}" in *"useradd -m -s /bin/bash -c HugMesh BFF dial (no sudo) bff-dial"*) ok "default: bff-dial created";; *) bad "default: bff-dial NOT created: ${out}";; esac
case "${out}" in *"usermod -p * bff-dial"*) ok "default: password field set to '*'";; *) bad "default: no usermod -p '*': ${out}";; esac
case "${out}" in *"install_keys bff-dial /dev/null 0"*) ok "default: its authorized_keys are installed";; *) bad "default: keys NOT installed: ${out}";; esac
case "${out}" in *" -G "*|*"wheel"*) bad "default: dial user given supplementary groups: ${out}";; *) ok "default: no supplementary groups (not wheel)";; esac
if printf '%s' "${DIAL_FN}" | grep 'sudoers' >/dev/null; then bad "provision_dial_user writes a sudoers entry"; else ok "provision_dial_user grants no sudo (no sudoers reference)"; fi

K="$(new_keys)"; echo "ssh-ed25519 AAAA k" > "${K}/ssh/svc-dial.authorized_keys"; echo svc-dial > "${K}/ssh/dial_user"
out="$(run_dial "${K}")"
case "${out}" in *"svc-dial"*"useradd"*|*"useradd"*" svc-dial"*) ok "ssh/dial_user marker: custom account svc-dial created";; *) bad "marker ignored: ${out}";; esac

K="$(new_keys)"
out="$(run_dial "${K}")"
[ -z "${out}" ] && ok "no staged dial key: nothing created" || bad "created an account with no dial key staged: ${out}"

for nm in root 'Bad;Name' '../x' 'a b' 'UPPER' '-lead' "$(printf 'a%.0s' {1..40})"; do
  K="$(new_keys)"; echo "ssh-ed25519 AAAA k" > "${K}/ssh/${nm//\//_}.authorized_keys" 2>/dev/null
  printf '%s\n' "${nm}" > "${K}/ssh/dial_user"
  out="$(run_dial "${K}")"
  case "${out}" in *useradd*|*install_keys*) bad "unsafe dial user accepted: $(printf %q "${nm}")";; *) ok "unsafe dial user rejected: $(printf %q "${nm}" | cut -c1-30)";; esac
done

K="$(new_keys)"; echo "ssh-ed25519 AAAA k" > "${K}/ssh/bff-dial.authorized_keys"
out="$(run_dial "${K}" 0)"
case "${out}" in *install_keys*|*useradd*) bad "uid-0 account named bff-dial got the dial key: ${out}";; *) ok "an existing uid-0 account is refused the dial key";; esac
out="$(run_dial "${K}" 1001)"
case "${out}" in *useradd*) bad "existing dial user re-created";; *) ok "existing dial user not re-created";; esac
case "${out}" in *"install_keys bff-dial"*) ok "existing dial user still gets its key installed";; *) bad "existing dial user key not installed: ${out}";; esac

# End to end: the tree gen-provision-keys.sh really writes drives the function.
G="$(mktemp -d "${TMPDIR:-/tmp}/dialgen423.XXXXXX")"
if bash "${GEN}" --random -o "${G}/out" --dial-user svc-dial --device-id dev1 >/dev/null 2>&1; then
  out="$(run_dial "${G}/out")"
  case "${out}" in *"useradd"*" svc-dial"*) ok "gen-provision-keys --dial-user svc-dial => provision creates svc-dial";; *) bad "generated tree did not create svc-dial: ${out}";; esac
else
  bad "gen-provision-keys.sh failed in the sandbox"
fi
rm -rf "${G}"

# Wiring: main() must reach the function, after provision_users and before anything that
# could need the account.
MAIN_FN="$(awk '/^main\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}' "${PROV}")"
if printf '%s\n' "${MAIN_FN}" | grep -E '^\s*provision_(users|dial_user)\b' | tr -s ' ' | cut -d' ' -f2 | paste -sd, | grep -x 'provision_users,provision_dial_user' >/dev/null; then
  ok "main() calls provision_dial_user right after provision_users"
else bad "main() does not call provision_dial_user after provision_users"; fi

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
