#!/usr/bin/env bash
# no-openrc-virtual-shadow.sh — no builder may create a REAL OpenRC service named
# after an OpenRC VIRTUAL, or enable such a name in a runlevel.
#
# The incident this pins: build-x86-host-stage4.sh (and build-rpi5-stage4.sh)
# shipped `ln -sfn firewalld "${SYSROOT}/etc/init.d/firewall"` — but 'firewall'
# is an OpenRC VIRTUAL service (firewalld's own init script `provide firewall`s
# it; nftables/iptables scripts do the same). A real script under a virtual name
# makes EVERY first boot print, verbatim:
#     Error: firewall is the name of a real and virtual service.
# and corrupts OpenRC's first-boot dependency-cache generation — the prime
# suspect (2026-08-19 forensics, issue #60) for the nondeterministic service
# ordering that left NetworkManager "started but inactive" (no IP, dead slirp
# hostfwd, QEMU harness stuck at "Waiting for guest SSH"). Both builders also
# enabled the alias via a bare 'firewall' entry in their runlevel SVCS lists —
# dangling on ARM, where firewalld is a deliberate exclusion.
#
# The fix removed the aliases and the runlevel entries ('after firewall' deps in
# specs/etc/init.d/* target the virtual and are soft edges — no alias needed).
# This gate keeps the whole class out, for every virtual name, in every builder:
#
#   1. no creation command (ln/cp/install/touch) targeting /etc/init.d/<virtual>
#   2. no runlevel enablement: <virtual> as a word in a *SVCS*=( ... ) list, an
#      `rc-update add <virtual>`, or a link created under /etc/runlevels/*/
#
# Word boundaries deliberately treat '-' and '.' as name characters, so
# hugmesh-firewall-reconcile and net.eth0 (real, legitimate names) never trip.
#
# Pure static text checks (full-line comments stripped first). No network, no
# root. Style of tests/posix-sh-no-arrays.sh: PASS/FAIL per section + a detector
# SELF-TEST on synthetic fixtures so the patterns can never rot vacuously green.
#
#   bash tests/no-openrc-virtual-shadow.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
cd "${REPO}"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# OpenRC virtual service names that installed packages `provide` (or OpenRC
# itself defines). Extend freely — a false positive here is a 2-minute fix, a
# miss is another week of nondeterministic first boots.
VIRTUALS='firewall|net|dns|logger|cron'

# Name boundaries: NOT preceded/followed by a word char, '-' or '.', so real
# hyphen/dot-bearing service names (hugmesh-firewall-reconcile, net.eth0) pass.
L='(^|[^[:alnum:]_.-])'
R='($|[^[:alnum:]_.-])'

# 1. creation command dropping a file at <anything>/etc/init.d/<virtual>
P_CREATE="${L}(ln|cp|install|touch)[[:space:]][^#]*/etc/init\.d/(${VIRTUALS})${R}"
# 2a. virtual name as a word inside a *SVCS*=(...)/*svcs=... service list line
P_SVCS="[Ss][Vv][Cc][Ss]\+?=[^#]*${L}(${VIRTUALS})${R}"
# 2b. rc-update add <virtual>
P_RCUP="rc-update[[:space:]]+add[[:space:]]+(${VIRTUALS})${R}"
# 2c. link created under a runlevel dir with a virtual leaf name
P_RLVL="${L}(ln|cp|install|touch)[[:space:]][^#]*/etc/runlevels/[^[:space:]\"']+/(${VIRTUALS})${R}"

# strip_comments FILE — drop full-line comments (the incident narrative lives in
# comments; only executable text is gated).
strip_comments(){ grep -vE '^[[:space:]]*#' "$1"; }

# ── detector SELF-TEST (synthetic fixtures) ───────────────────────────────────
echo "== detector self-test =="
SELFTEST_BAD=(
  'ln -sfn firewalld "${SYSROOT}/etc/init.d/firewall"'
  'cp specs/etc/init.d/mine "${SYSROOT}/etc/init.d/net"'
  'DEFAULT_SVCS=(sshd firewall auditd local)'
  'SVCS+=(logger)'
  '_base_svcs="containerd dns growroot"'
  'run_root rc-update add cron default'
  'ln -sf /etc/init.d/foo "${SYSROOT}/etc/runlevels/default/firewall"'
)
SELFTEST_GOOD=(
  'ln -sfn firewalld "${SYSROOT}/etc/init.d/firewalld"'
  'cp "${SHARED_SPECS}/etc/init.d/net.eth0" "${SYSROOT}/etc/init.d/net.eth0"'
  'SVCS=(sshd NetworkManager cronie hugmesh-firewall-reconcile auditd local)'
  'DEFAULT_SVCS+=(hugmesh-firewall-reconcile hugmesh-coturn-firewall kubelet)'
  'rc-update add cronie default'
  'ln -sf "/etc/init.d/${s}" "${SYSROOT}/etc/runlevels/default/${s}"'
  'ln -sf /etc/init.d/dnsmasq "${SYSROOT}/etc/runlevels/default/dnsmasq"'
)
match_any(){ # match_any LINE -> 0 if any pattern fires
  local line="$1" pat
  for pat in "${P_CREATE}" "${P_SVCS}" "${P_RCUP}" "${P_RLVL}"; do
    printf '%s\n' "${line}" | grep -qE "${pat}" && return 0
  done
  return 1
}
for line in "${SELFTEST_BAD[@]}"; do
  if match_any "${line}"; then ok "self-test flags: ${line}"
  else bad "self-test MISSED (detector blinded): ${line}"; fi
done
for line in "${SELFTEST_GOOD[@]}"; do
  if match_any "${line}"; then bad "self-test FALSE-POSITIVE on legitimate line: ${line}"
  else ok "self-test passes: ${line}"; fi
done

# ── the real gate: every builder + shared build lib ──────────────────────────
echo "== builders =="
FILES="$(git ls-files 'build-*-stage4.sh' 'scripts/*.sh' 'docker/build-image.sh' 2>/dev/null)"
if [ -z "${FILES}" ]; then
  bad "git ls-files matched no builder scripts (gate would be vacuous)"
else
  ok "scanning $(printf '%s\n' "${FILES}" | wc -l) tracked build scripts"
fi
for f in ${FILES}; do
  hits=""
  for pat in "${P_CREATE}" "${P_SVCS}" "${P_RCUP}" "${P_RLVL}"; do
    h="$(strip_comments "${f}" | grep -nE "${pat}" || true)"
    [ -n "${h}" ] && hits="${hits}${h}"$'\n'
  done
  if [ -n "${hits}" ]; then
    bad "${f}: creates/enables a REAL service on an OpenRC VIRTUAL name (${VIRTUALS//|/, }):"
    printf '%s\n' "${hits}" | sed '/^$/d;s/^/        /'
  else
    ok "${f}: no OpenRC-virtual shadowing"
  fi
done

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
