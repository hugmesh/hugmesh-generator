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

echo "== HugMesh RPi 5 image — boot/provision assertions =="
echo "-- identity --"
check "hostname provisioned (not default 'localhost')" \
    '[ -n "$(hostname)" ] && [ "$(hostname)" != "localhost" ] && [ "$(hostname)" != "gentoo" ]'
check "/etc/hugmesh/role marker present"       '[ -f /etc/hugmesh/role ]'

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
# THE LSM STACK THE IMAGE ASKED FOR MUST BE THE ONE THE KERNEL IS RUNNING.
#
# The kernel does not diagnose an lsm= name it cannot resolve. It initializes a
# SHORTER stack and boots on, silently. That is how two LSMs rode the whole fleet
# as decoration: the 2026-08-14 x86 and Pi images both booted
#   Command line: ... lsm=lockdown,yama,selinux,bpf lockdown=integrity ...
#   LSM: initializing lsm=lockdown,capability,selinux
# (out/qemu-runs/runs/newbuild2_x86-pki/launch/console.log:11,:181 and
#  out/qemu-runs/runs/rpi5_pki/launch/console.log:79) because CONFIG_SECURITY_YAMA
# and CONFIG_BPF_LSM were never compiled in. The old lockdown check could not see
# it — and could not see much else either: it was an OR whose right arm passed on
# the mere presence of the word "lockdown" in /proc/cmdline, i.e. on the image's
# own claim about itself. Ask the kernel instead. /sys/kernel/security/lsm is its
# answer, and every name the cmdline requested has to appear in it.
_lsm_req="$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n 's/^lsm=//p' | tr ',' ' ')"
_lsm_live="$(cat /sys/kernel/security/lsm 2>/dev/null || true)"
_lsm_missing=""
for _l in ${_lsm_req}; do
    case ",${_lsm_live}," in *",${_l},"*) ;; *) _lsm_missing="${_lsm_missing} ${_l}" ;; esac
done
check "every LSM the cmdline requests is initialized (asked:${_lsm_req:-<none>} live:${_lsm_live:-<none>})" \
    '[ -n "${_lsm_req}" ] && [ -n "${_lsm_live}" ] && [ -z "${_lsm_missing}" ]'
# Lockdown (integrity or higher) prevents /dev/mem writes, unsigned module loading,
# kprobe redirection. It is requested by x86 + rpi5 only: the 8 ARM board images
# ship no lockdown= in cmdline.base and no CONFIG_SECURITY_LOCKDOWN_LSM in their
# fragments, so asserting it unconditionally would only ever grade the harness's
# own -append literal. Assert it where the image ASKS for it, from the kernel's
# report — never from the cmdline word, which is the claim under test.
_lockdown_req="$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | sed -n 's/^lockdown=//p')"
if [ -n "${_lockdown_req}" ]; then
    # securityfs marks the active level in brackets ("none [integrity] confidentiality");
    # tolerate a leading-token spelling too, and fall back to the kernel's own
    # initialized-LSM list, which is still real evidence rather than self-report.
    check "kernel lockdown active (requested ${_lockdown_req})" \
        '[ -f /sys/kernel/security/lockdown ] && grep -qE "(^|\[)(integrity|confidentiality)" /sys/kernel/security/lockdown 2>/dev/null || \
         grep -qw lockdown /sys/kernel/security/lsm 2>/dev/null'
else
    ok "kernel lockdown (skipped — this image requests none; lockdown is x86 + rpi5 only)"
fi
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
#
# GATED on whether firewalld is the ACTIVE firewall on this image — NOT on whether its
# binary happens to be installed. Two different images reach the same posture by
# different routes:
#   * ARM: firewalld is DELIBERATELY excluded from the cross-compiled images since
#     2026-08-05 (specs-rpi5/portage/packages.list:25-41 — the pygobject -> glib
#     [introspection] bootstrap does not cross-compile), so the binary is absent.
#   * x86: firewalld IS shipped (binary + /etc/init.d/firewalld) but is never added to a
#     runlevel; hugmesh-firewall-reconcile (nftables) owns the firewall exactly as on ARM.
# A `command -v firewall-cmd` gate therefore passed on ARM and FAILED on x86 for an image
# that was behaving as designed (2026-08-14: a freshly rebuilt x86 pki scored 30/32 on
# nothing but this). Keying on the runlevel/running state describes the actual intent, so
# a node that really is meant to run firewalld still gets asserted properly.
if ls /etc/runlevels/*/firewalld >/dev/null 2>&1 \
   || rc-service firewalld status >/dev/null 2>&1 \
   || pgrep -x firewalld >/dev/null 2>&1; then
    check "firewalld running" \
        'rc-service firewalld status 2>/dev/null | grep -qi started || systemctl is-active firewalld 2>/dev/null | grep -q active || pgrep firewalld'
    check "firewalld default zone is drop or trusted" \
        'firewall-cmd --get-default-zone 2>/dev/null | grep -qE "^(drop|trusted)$"'
else
    ok "firewalld (skipped — not enabled on this image; nftables owns the host firewall)"
    check "nftables present (firewalld replacement)" \
        'command -v nft'
    check "hugmesh-firewall-reconcile service started (nftables backstop reconciled)" \
        'rc-service hugmesh-firewall-reconcile status 2>/dev/null | grep -qi started'
fi

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
