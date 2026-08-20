#!/bin/bash
# assertions.sh — runs INSIDE the QEMU guest (over SSH) to verify the image
# booted, provisioned from the KEYS partition, and brought up its services.
#
# Exits non-zero if any assertion fails. Expects to run with sudo rights.
set -u

PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
# skip() counts as NOTHING. An assertion that does not apply to this node must not
# inflate the PASS total the harness scrapes ("RESULT: N passed") into the grid.
skip() { echo "  SKIP  $*"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== HugMesh RPi 5 image — boot/provision assertions =="
echo "-- identity --"
# THE BAKED HOSTNAME PASSES THE OLD TEST WITH NO PROVISIONING AT ALL.
# The old form excluded only the literals 'localhost' and 'gentoo', but both builders
# bake a role-derived name into the image before it ever boots: rpi5 sets
# HOSTNAME=gentoo-${BOARD} / ${BRAND}-${ROLE} (build-rpi5-stage4.sh:1276-1277, written
# at :3821) and x86 sets ${BRAND}-pki / -be / -fe / -host / -omnibus / ...
# (build-x86-host-stage4.sh:1241-1310, written at :4221). Every one of those clears
# both literals, so the check could not fail on any image this harness boots.
# Assert the value provisioning actually APPLIED instead: provision_identity() logs
# "Hostname set to <hn>" only after the manifest's .hostname passed RFC-1123
# validation and was written (specs/etc/keys-provision/provision.sh:477-483).
# Exactly two scripts feed this file to a guest — tests/qemu/run-qemu-test.sh:243 and
# tests/qemu/docker-entrypoint.sh:488-511 (whole-repo grep for "assertions.sh",
# 2026-08-14: every other hit is prose or matrix-assertions.sh; run-qemu-e2e.sh boots
# guests but never runs this file) — and both always put .hostname in the manifest
# (run-qemu-test.sh:169 "hugmesh-test", docker-entrypoint.sh:401
# "hugmesh-${ROLE}-qemu"), so a missing log line here means provisioning did not apply
# one. Deliberately strict: a manifest with no .hostname at all fails this too.
_hn_applied="$(sed -n 's/^.*Hostname set to \(..*\)$/\1/p' /var/log/keys-provision.log 2>/dev/null | tail -1)"
check "hostname is the one KEYS provisioning applied (log:'${_hn_applied:-<none logged>}' live:'$(hostname)')" \
    '[ -n "${_hn_applied}" ] && [ "$(hostname)" = "${_hn_applied}" ]'
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
# WHETHER THIS NODE WAS ASKED TO RUN HEADSCALE IS A MANIFEST QUESTION, NOT A
# HEADSCALE QUESTION.
#
# The old gate gave headscale a vote on whether it was ever meant to exist:
# `rc-service headscale status` OR the runlevel symlink. A node that was told to be a
# control server and never got one answers "no" to both, fell into the else branch and
# collected two ok() lines — two PASSes for exactly the failure they were written to
# catch. INTENT is resolved below from what the MANIFEST asked, strongest source first:
#
#  1. provision.json on the KEYS media, which is still attached at assertion time:
#     run-qemu-test.sh:215 and launch-pi.sh:258-261 / launch-arm.sh:309-313 /
#     launch-x86.sh:234-237 keep the
#     disk plugged in for the whole run, at the same label and layout provision.sh
#     itself mounts at boot (specs/etc/keys-provision/provision.sh:207-241). This is
#     the ONLY source that survives headscale being absent, because
#     provision_headscale() bails at provision.sh:603 on `have headscale` BEFORE it
#     ever reads .headscale.enabled — so on a binary-less node the log holds the
#     OBSERVATION "headscale not installed" and no statement of intent whatsoever.
#     That line is never read as intent here: a node asked for headscale and missing
#     the binary reaches the checks below and FAILS them.
#  2. Only if that media is unreadable (stick pulled, hand-run): the manifest DECISIONS
#     provision.sh logged. "headscale disabled in manifest" (provision.sh:607) is the
#     disabled branch; the other patterns are reachable only past that branch's
#     `return 0` at provision.sh:610. The log is append-only (provision.sh:51), so the
#     LAST decision wins and a re-provision that flipped the manifest reads the right
#     way round. This tier is PARTIAL by construction: every enabled-branch log line is
#     conditional (config staged, endpoint resolved, users/preauth keys declared), so
#     an enabled node that logged none of them lands in "unknown", not in "wanted".
#
# Unknown emits neither a PASS nor a FAIL — it is not evidence in either direction.
# Both payload generators are covered: run-qemu-test.sh:171 hardcodes enabled:true for
# EVERY role, docker-entrypoint.sh:393-396 derives it per role (pki|generic|omnibus).
_hs_want=unknown          # true = manifest asked for it | false = it did not | unknown
_hs_src=""
# Second consumer of the same mount: the SELinux mode the manifest ASKED for
# (used by the kernel-hardening section below). Captured here because this is
# the only place the KEYS media is mounted.
_slx_mode_want=""
_slx_mode_src=""
_hs_dev="$(blkid -L "${KEYS_LABEL:-KEYS}" 2>/dev/null || true)"
if [ -n "${_hs_dev}" ] && command -v jq >/dev/null 2>&1; then
    _hs_mnt="$(mktemp -d 2>/dev/null || echo '')"
    if [ -n "${_hs_mnt}" ] && { mount -o ro,nosuid,nodev,noexec "${_hs_dev}" "${_hs_mnt}" 2>/dev/null \
                                || mount -t vfat -o ro "${_hs_dev}" "${_hs_mnt}" 2>/dev/null; }; then
        # Both KEYS/ layouts provision.sh accepts (provision.sh:235-238).
        for _hs_m in "${_hs_mnt}/provision.json" "${_hs_mnt}/keys/provision.json"; do
            [ -f "${_hs_m}" ] || continue
            # tostring, not `// false`: jq's // folds a literal false into null, so the
            # two spellings happen to agree HERE only because this case folds false and
            # null into the same branch anyway. Keeping them distinct at the source means
            # the "absent" and "explicitly off" cases stay separable if this ever needs to
            # tell them apart. Either way null means "not wanted", matching
            # provision.sh:605-606.
            case "$(jq -r '.headscale.enabled | tostring' "${_hs_m}" 2>/dev/null)" in
                true)       _hs_want=true;  _hs_src="KEYS manifest" ;;
                false|null) _hs_want=false; _hs_src="KEYS manifest" ;;
            esac
            # provision_selinux() folds an absent/null .selinux.mode to
            # permissive (specs/etc/keys-provision/provision.sh:2739) — mirror
            # that default so a manifest that never mentions SELinux still
            # yields the mode provisioning actually applied.
            _slx_mode_want="$(jq -r '.selinux.mode // "permissive"' "${_hs_m}" 2>/dev/null)"
            [ -n "${_slx_mode_want}" ] && [ "${_slx_mode_want}" != "null" ] && _slx_mode_src="KEYS manifest"
            break
        done
        umount "${_hs_mnt}" 2>/dev/null || true
    fi
    [ -n "${_hs_mnt}" ] && rmdir "${_hs_mnt}" 2>/dev/null
fi
if [ "${_hs_want}" = unknown ] && [ -f /var/log/keys-provision.log ]; then
    _hs_line="$(grep -aE 'headscale disabled in manifest|Installed headscale config from|headscale server_url set to|headscale: staged Layer-A BOOTSTRAP policy|headscale failed to start|Created headscale (user|preauth key)|Loaded headscale ACL policy from' \
                     /var/log/keys-provision.log 2>/dev/null | tail -1)"
    case "${_hs_line}" in
        "")                                 ;;
        *"headscale disabled in manifest"*) _hs_want=false; _hs_src="provision-log manifest decision" ;;
        *)                                  _hs_want=true;  _hs_src="provision-log manifest decision" ;;
    esac
fi
if [ "${_hs_want}" = true ]; then
    check "headscale service started (asked for by ${_hs_src})"       'rc-service headscale status'
    check "headscale listening on :8080 (asked for by ${_hs_src})"    'ss -ltn 2>/dev/null | grep -q ":8080"'
elif [ "${_hs_want}" = false ]; then
    skip "headscale service — not wanted on this node (${_hs_src})"
    skip "headscale port :8080 — not wanted on this node (${_hs_src})"
else
    skip "headscale service — INTENT UNVERIFIED: no readable KEYS manifest and no manifest decision in the provision log. NOT evidence that headscale is healthy or unwanted."
    skip "headscale port :8080 — INTENT UNVERIFIED (see above)"
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
    # skip(), not ok(): a check that does not apply to this node is not evidence that the
    # node is healthy. Counting it as a PASS inflated every ARM-board row.
    skip "kernel lockdown — this image requests none; lockdown is x86 + rpi5 only"
fi
# SELinux: a policy must be LOADED, and the RUNNING mode must be the one that
# was ASKED for — not merely "some real mode". The old check accepted either
# mode unconditionally, which is one of the two seams that let the 2026-08-14
# images ship base-policy-only and still score 33/33 (issue #45; the other seam
# — never looking at the module store — is closed in the node-policy section
# below).
check "SELinux loaded (enforcing or permissive)" \
    'command -v getenforce >/dev/null && getenforce | grep -qiE "enforcing|permissive"'
# Expected mode, strongest source first (same INTENT ladder as headscale above):
#  1. SELINUX_EXPECTED_MODE from the caller — tests/qemu/avc-workout.sh passes
#     "enforcing" when it has run `setenforce 1` itself;
#  2. the KEYS manifest's .selinux.mode (read in the mount block above);
#  3. /etc/selinux/config's SELINUX= — weaker (the image's own persisted claim)
#     but still a real cross-check of the kernel's mode against what the config
#     says the node should be running.
_slx_mode_exp="${SELINUX_EXPECTED_MODE:-}"; _slx_mode_from="caller env"
if [ -z "${_slx_mode_exp}" ] && [ -n "${_slx_mode_want}" ]; then
    _slx_mode_exp="${_slx_mode_want}"; _slx_mode_from="${_slx_mode_src}"
fi
if [ -z "${_slx_mode_exp}" ]; then
    _slx_mode_exp="$(sed -n 's/^SELINUX=//p' "${SELINUX_CONFIG:-/etc/selinux/config}" 2>/dev/null | tail -1)"
    _slx_mode_from="/etc/selinux/config"
fi
if [ -n "${_slx_mode_exp}" ]; then
    check "getenforce matches the expected mode '${_slx_mode_exp}' (from ${_slx_mode_from}; live:$(getenforce 2>/dev/null || echo '<none>'))" \
        '[ "$(getenforce 2>/dev/null | tr "[:upper:]" "[:lower:]")" = "$(printf "%s" "${_slx_mode_exp}" | tr "[:upper:]" "[:lower:]")" ]'
else
    skip "SELinux expected mode — no caller env, no readable KEYS manifest, no /etc/selinux/config"
fi
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
    # skip(), not ok(): same reason as the lockdown branch above. firewalld is disabled by
    # design on essentially every image here, so this one inflated almost every row.
    skip "firewalld — not enabled on this image; nftables owns the host firewall"
    check "nftables present (firewalld replacement)" \
        'command -v nft'
    check "hugmesh-firewall-reconcile service started (nftables backstop reconciled)" \
        'rc-service hugmesh-firewall-reconcile status 2>/dev/null | grep -qi started'
fi

echo "-- SELinux node policy (build manifest -> kernel module store) --"
# THE MANIFEST IS THE CONTRACT (scripts/_selinux-policy-lib.sh): every module
# the build recorded in /usr/share/hugmesh/selinux-modules.list must be IN the
# store `semodule -l` reports, or first boot shipped a node running a policy
# set it was not built with. This is exactly the check whose absence let the
# 2026-08-14 runs go green while every hugmesh module failed to load (the
# provision log said so — "hugmesh node-policy modules failed to load" — and
# nothing here read it).
# Paths overridable via env — the same seam the enforce-gate carries so
# tests/qemu/avc-workout_test.sh can execute this section for real against
# fixtures (with getenforce/semodule stubbed on PATH) instead of merely
# grepping it. In the guest the defaults are always what runs.
_slx_manifest="${SELINUX_MODULES_LIST:-/usr/share/hugmesh/selinux-modules.list}"
if [ -f "${_slx_manifest}" ]; then
    _slx_type="$(sed -n 's/^SELINUXTYPE=//p' "${SELINUX_CONFIG:-/etc/selinux/config}" 2>/dev/null | tail -1)"
    [ -n "${_slx_type}" ] || _slx_type=mcs
    _slx_l="$(semodule -s "${_slx_type}" -l 2>/dev/null || true)"
    while read -r _slx_m; do
        case "${_slx_m}" in ''|'#'*) continue ;; esac
        check "node-policy module '${_slx_m}' loaded (semodule -s ${_slx_type} -l)" \
            'printf "%s\n" "${_slx_l}" | grep -q "^${_slx_m}\b"'
    done < "${_slx_manifest}"
    # provision_selinux()'s own per-module verdict must agree: the status file
    # is written on every provision run since the #45 per-module layer, one
    # '<module> loaded|failed|missing-pp' line per manifest module.
    _slx_status="${SELINUX_MODULES_STATUS:-/var/lib/keys-provision/selinux-modules.status}"
    if [ -f "${_slx_status}" ]; then
        check "provision recorded every manifest module as loaded (${_slx_status})" \
            '! grep -qE " (failed|missing-pp)$" "${_slx_status}"'
    else
        skip "selinux-modules.status — image predates the per-module load verdicts (#45)"
    fi
    # The whole-policy postcondition marker (PR #53): a selinux-aware image
    # whose first boot ended without a working policy load records
    # selinux-load-failed, and the enforce-gate refuses on it. It must not
    # be standing on a healthy node.
    _slx_built="${SELINUX_BUILT_MARKER:-/usr/share/hugmesh/selinux-built}"
    _slx_loadfail="${SELINUX_LOAD_FAILED_MARKER:-/var/lib/keys-provision/selinux-load-failed}"
    if [ -f "${_slx_built}" ]; then
        check "no selinux-load-failed marker (first-boot policy-load postcondition held)" \
            '[ ! -e "${_slx_loadfail}" ]'
    else
        skip "selinux-load-failed marker — image not marked selinux-built"
    fi
else
    skip "SELinux node-policy modules — no ${_slx_manifest} (image predates the policy-module install step)"
fi

echo "-- AVC harvest (data, not verdicts) --"
# HARVEST, never assert: on a permissive node every denial is logged and
# nothing breaks — those lines are exactly the input the rules tagged
# '# INFERRED-WIDE: narrow after QEMU enforcing AVC pass' in specs/selinux/*.te
# are waiting on. The full harvest is written to ${AVC_REPORT_GUEST} (pulled
# off the guest by tests/qemu/avc-workout.sh and fed to avc-report.sh) and
# echoed inline between the BEGIN/END markers below so it also lands verbatim
# in the assertions.log artifact both harness drivers already tee per run.
# ausearch is preferred (structured, survives ring-buffer wrap); dmesg is the
# fallback when ausearch/auditd is absent or holds no audit log.
AVC_REPORT_GUEST="${AVC_REPORT_GUEST:-/var/log/hugmesh-avc-report.txt}"
_avc_src=""; _avc_raw=""
if command -v ausearch >/dev/null 2>&1 && _avc_raw="$(ausearch -m AVC,USER_AVC -ts boot 2>/dev/null)"; then
    _avc_src="ausearch -m AVC,USER_AVC -ts boot"
else
    _avc_raw="$(dmesg 2>/dev/null | grep -E 'type=1400|type=1107|avc: *denied' || true)"
    _avc_src="dmesg grep (ausearch/auditd absent, or no audit log to search)"
fi
{
    echo "# AVC harvest $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) getenforce=$(getenforce 2>/dev/null || echo unknown)"
    echo "# source: ${_avc_src}"
    printf '%s\n' "${_avc_raw}"
} > "${AVC_REPORT_GUEST}" 2>/dev/null || true
_avc_n="$(printf '%s\n' "${_avc_raw}" | grep -cE 'avc: *denied|type=1400' || true)"
echo "  INFO  AVC harvest: ${_avc_n:-0} denial line(s) via ${_avc_src} -> ${AVC_REPORT_GUEST}"
echo "-- AVC HARVEST BEGIN --"
printf '%s\n' "${_avc_raw}" | sed -n '1,400p'
[ "$(printf '%s\n' "${_avc_raw}" | wc -l)" -gt 400 ] && \
    echo "... truncated inline at 400 lines; the full harvest is in ${AVC_REPORT_GUEST} on the guest"
echo "-- AVC HARVEST END --"

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "${FAIL}" -eq 0 ]
