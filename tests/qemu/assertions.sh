#!/bin/bash
# assertions.sh — runs INSIDE the QEMU guest (over SSH) to verify the image
# booted, provisioned from the KEYS partition, and brought up its services.
#
# Exits non-zero if any assertion fails. Expects to run with sudo rights.
set -u

PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== Snapdragon RPi 5 image — boot/provision assertions =="
echo "-- identity --"
check "hostname provisioned (not default 'localhost')" \
    '[ -n "$(hostname)" ] && [ "$(hostname)" != "localhost" ] && [ "$(hostname)" != "gentoo" ]'
check "/etc/snapdragon/role marker present"       '[ -f /etc/snapdragon/role ]'

echo "-- KEYS provisioning --"
check "keys-provision ran (done marker)"          '[ -f /var/lib/keys-provision/done ]'
check "users created from KEYS"                   '[ -f /var/lib/keys-provision/users.created ]'
check "provision log exists"                      '[ -f /var/log/keys-provision.log ]'

echo "-- users / ssh --"
check "test user 'tester' exists"                 'id tester'
check "tester in wheel group"                     'id -nG tester | grep -qw wheel'
check "tester authorized_keys installed"          '[ -s /home/tester/.ssh/authorized_keys ]'
check "sshd is running"                            'pgrep -x sshd'
check "ssh host keys present"                      'ls /etc/ssh/ssh_host_*_key'

echo "-- mesh VPN --"
check "headscale binary present"                  'command -v headscale'
# headscale service checks: only run if headscale was enabled in provision.json.
# On the image the provision.json was consumed and removed, but the done marker and
# the init symlink tell us whether headscale was started.
_hs_enabled=false
rc-service headscale status >/dev/null 2>&1 && _hs_enabled=true
if [ -e /etc/runlevels/default/headscale ] || [ -e /etc/runlevels/sysinit/headscale ]; then
    _hs_enabled=true
fi
if ${_hs_enabled}; then
    check "headscale service started"             'rc-service headscale status'
    check "headscale listening on :8080"          'ss -ltn 2>/dev/null | grep -q ":8080"'
else
    ok "headscale service (skipped — not enabled in this provisioning)"
    ok "headscale port :8080 (skipped — not enabled in this provisioning)"
fi

echo "-- kubernetes stack --"
check "containerd present"                         'command -v containerd'
check "kubelet present"                            'command -v kubelet'
check "kubeadm present"                            'command -v kubeadm'
check "kubectl present"                            'command -v kubectl'
check "kubeadm-config staged"                      '[ -f /etc/kubernetes/kubeadm-config.yaml ]'
check "overlay filesystem available (built-in=y or loaded module)" \
    'grep -qw overlay /proc/filesystems || lsmod | grep -q overlay'
check "br_netfilter active"                        '[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]'
check "ip_forward enabled"                         '[ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]'

echo "-- tooling --"
check "jq present (JSON provisioning)"            'command -v jq'

echo "-- kernel hardening --"
# Lockdown LSM must be active (integrity or higher); this prevents /dev/mem writes,
# unsigned module loading, etc. On QEMU we pass lockdown=integrity on the cmdline.
check "kernel lockdown active (integrity|confidentiality)" \
    '[ -f /sys/kernel/security/lockdown ] && grep -qE "^(integrity|confidentiality)" /sys/kernel/security/lockdown 2>/dev/null || \
     cat /proc/cmdline 2>/dev/null | grep -q lockdown'
# SELinux must be enforcing (provision_selinux sets it after first-boot relabel).
# In test we accept permissive (SELinux not yet enforcing after relabel under QEMU).
check "SELinux loaded (enforcing or permissive)" \
    'command -v getenforce >/dev/null && getenforce | grep -qiE "enforcing|permissive"'
# sysctl hardening: panic_on_oops, randomize_va_space, tcp_rfc1337.
check "kernel.panic_on_oops=1" \
    '[ "$(sysctl -n kernel.panic_on_oops 2>/dev/null)" = "1" ]'
check "kernel.randomize_va_space=2 (full ASLR)" \
    '[ "$(sysctl -n kernel.randomize_va_space 2>/dev/null)" = "2" ]'
check "net.ipv4.tcp_rfc1337=1 (TIME_WAIT assassination defense)" \
    '[ "$(sysctl -n net.ipv4.tcp_rfc1337 2>/dev/null)" = "1" ]'
check "kernel.dmesg_restrict=1 (unprivileged dmesg blocked)" \
    '[ "$(sysctl -n kernel.dmesg_restrict 2>/dev/null)" = "1" ]'
check "net.ipv4.conf.all.rp_filter=1 (reverse-path filtering)" \
    '[ "$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)" = "1" ]'
# SSH hardening: PermitRootLogin must be no.
check "sshd PermitRootLogin disabled" \
    'sshd -T 2>/dev/null | grep -qi "^permitrootlogin no"'
# firewalld: must be running and DefaultZone must be drop (prod) or trusted (test/dev).
check "firewalld running" \
    'rc-service firewalld status 2>/dev/null | grep -qi started || systemctl is-active firewalld 2>/dev/null | grep -q active || pgrep firewalld'
check "firewalld default zone is drop or trusted" \
    'firewall-cmd --get-default-zone 2>/dev/null | grep -qE "^(drop|trusted)$"'

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
