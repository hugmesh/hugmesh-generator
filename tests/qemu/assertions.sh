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
# Exactly two scripts feed this file to a guest — tests/qemu/run-qemu-test.sh:257 and
# tests/qemu/docker-entrypoint.sh:1011-1050 (whole-repo grep for "assertions.sh",
# re-run 2026-08-26: every other hit is prose or matrix-assertions.sh; run-qemu-e2e.sh boots
# guests but never runs this file) — and both always put .hostname in the manifest
# (run-qemu-test.sh:183 "hugmesh-test", docker-entrypoint.sh:795
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
#     run-qemu-test.sh:229 and launch-pi.sh:258-261 / launch-arm.sh:309-313 /
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
# Both payload generators are covered, and BOTH now derive the value per role
# (run-qemu-test.sh:175-178, docker-entrypoint.sh:787-790 — pki|generic|omnibus).
# run-qemu-test.sh used to hardcode enabled:true for EVERY role; the role/manifest
# cross-check below turned that stale payload into a FAIL against a correct backend
# image, so it was ported to the same derivation rather than special-cased here.
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


echo "-- role topology --"
# WHAT THE 42 EXISTING ASSERTIONS COULD NOT SEE: WHICH ROLE THIS IMAGE ACTUALLY IS.
#
# Measured 2026-08-26 by reading the ext4 root of the three 2026-08-23 rpi5 images
# WITHOUT mounting them (debugfs -R "ls /etc/runlevels/default" "<img>?offset=$((1050624*512))",
# images under out/sessions/20260822-225110-80c83a):
#
#   backend  : sshd NetworkManager cronie haveged growroot keys-provision auditd
#              hugmesh-firewall-reconcile hugmesh-coturn-firewall hugmesh-go-live-reconcile
#              containerd kubelet hugmesh-update tailscaled local netmount
#   frontend : ** BYTE-FOR-BYTE THE SAME SET **
#   pki      : the same set + headscale
#
# and the ONLY file whose CONTENT differs between backend and frontend is
# /etc/hugmesh/role. Every assertion in this file above ran on a property all three
# images share, so a build that shipped the WRONG ROLE PAYLOAD — a frontend rootfs
# stamped 'backend', or a pki rootfs stamped 'frontend' — scored a clean 42/42 PASS.
#
# IS THAT A BUG IN THE IMAGES? NO — AND THIS SECTION DELIBERATELY DOES NOT INVENT
# DIFFERENCES THAT SHOULD NOT EXIST. build-rpi5-stage4.sh:3949-4046 builds DEFAULT_SVCS
# from exactly two branches: ROLE_CLIENT (desktop) vs cluster node, and
# `ROLE = pki|generic` for headscale. Nothing else reads ROLE: the cluster GitOps tree
# is `cp -r`'d wholesale at :3898 with ROLE appearing only in the info log. That is the
# architecture — every cluster-node image is an identical k8s node (containerd+kubelet)
# carrying an identical GitOps payload, and WHICH WORKLOAD LANDS WHERE IS KUBERNETES'
# DECISION, not the image's. backend and frontend are SUPPOSED to be identical here.
#
# So the invariant worth testing is NOT "backend runs X, frontend runs Y". It is:
#   THE ROLE MARKER AND THE SERVICE TOPOLOGY MUST AGREE.
# The marker is load-bearing (provision.sh:2323 keys the maintenance-wave update cadence
# off it; the cluster labels nodes from it), so an image whose marker contradicts its own
# payload is a real defect — and headscale is the one place where the payload can
# contradict the marker. Asserted BOTH WAYS below: required where the role says control
# server, FORBIDDEN where it does not (a worker silently running a headscale control
# server is the failure the build script's own :4044 belt-and-suspenders rm -f exists to
# prevent — Pi audit finding 2026-06-13).
#
# HONEST LIMIT, STATED HERE SO NOBODY MISREADS A GREEN RUN: a backend<->frontend marker
# swap is UNDETECTABLE from inside the guest, because the two rootfs images are
# identical apart from that one file. There is nothing to cross-check it against. This
# section catches every swap that IS a payload difference (pki<->backend, pki<->frontend,
# desktop<->anything) and the manifest-vs-marker contradiction below; it cannot catch
# backend<->frontend, and no in-guest assertion can.

_rl_has() {  # $1=root prefix  $2=service — linked into the default runlevel?
    # -e OR -L: a DANGLING symlink still counts as "linked" here (OpenRC will try to
    # start it and fail). Dangling entries are graded separately below — the build
    # script carried exactly such a dangling 'firewall' entry once
    # (build-rpi5-stage4.sh:3945-3947).
    [ -e "$1/etc/runlevels/default/$2" ] || [ -L "$1/etc/runlevels/default/$2" ]
}
_rl_dangling() {  # $1=root prefix  $2=service — a runlevel symlink with no target
    # PREFIX-AWARE, AND IT HAS TO BE. Both builders write ABSOLUTE runlevel symlinks —
    # build-rpi5-stage4.sh:4038 and build-x86-host-stage4.sh:4526 are both
    # `ln -sf "/etc/init.d/${svc}"` — and so does OpenRC's own rc-update. The naive
    # form (`[ -L link ] && [ ! -e link ]`) resolves such a target against the HOST's
    # /etc/init.d as soon as $1 is non-empty, so under any root prefix it called every
    # entry of a PERFECTLY CORRECT image dangling — and did it NONDETERMINISTICALLY,
    # since whichever service names the host happened to have installed silently
    # "resolved". Read the target and re-root an absolute one inside the prefix.
    local _l
    local _t
    _l="$1/etc/runlevels/default/$2"
    [ -L "${_l}" ] || return 1
    _t="$(readlink "${_l}" 2>/dev/null || true)"
    case "${_t}" in
        "")  return 0 ;;               # unreadable link — nothing can start it
        /*)  [ ! -e "$1${_t}" ] ;;     # absolute: resolve INSIDE the prefix
        *)   [ ! -e "${_l}" ] ;;       # relative: already resolves inside the tree
    esac
}

assert_role_topology() {  # $1 = root prefix ("" on the live guest; a fixture root in tests)
    # bash 5.3 localises every name BEFORE assigning, so `local a=$1 b=$a` dies under
    # set -u on this box (green on CI's 5.2). Declare separately. Always.
    local _R
    local _role
    local _class
    local _hs_expect
    local _req
    local _forbid
    local _svc
    _R="${1-}"

    _role="$(sed -n '1p' "${_R}/etc/hugmesh/role" 2>/dev/null | tr -d '[:space:]')"

    # The ROLE COMES FROM THE IMAGE, never from the environment. Reading it from an env
    # var the harness also sets would make this section grade the harness's own opinion
    # of what it built instead of what came back — which is precisely the vacuous pass
    # being fixed. assertions_test.sh mutation (c) pins this.
    case "${_role}" in
        pki|generic)       _class=cluster; _hs_expect=required  ;;
        backend|frontend)  _class=cluster; _hs_expect=forbidden ;;
        desktop)           _class=client;  _hs_expect=forbidden ;;
        "") bad "/etc/hugmesh/role is missing or empty — the image cannot say which role it is, so NO role assertion below can run"
            return ;;
        *)  bad "/etc/hugmesh/role holds '${_role}', which is not one of the five roles build-rpi5-stage4.sh:1244 accepts (generic pki backend frontend desktop)"
            return ;;
    esac
    ok "role marker names a known role ('${_role}' => ${_class} node)"

    # ── The baseline every node of this class MUST run ──────────────────────
    if [ "${_class}" = cluster ]; then
        _req="sshd NetworkManager cronie haveged growroot keys-provision auditd local hugmesh-update hugmesh-firewall-reconcile hugmesh-coturn-firewall hugmesh-go-live-reconcile containerd kubelet"
        # A cluster node is HEADLESS (build-rpi5-stage4.sh:1264-1271 leaves CLIENT_USE
        # empty and never adds the desktop trio). A seat/login/display stack scheduled
        # on a k8s node means a desktop payload landed on a server image.
        _forbid="dbus elogind display-manager"
    else
        _req="sshd NetworkManager cronie haveged growroot keys-provision auditd local hugmesh-update dbus elogind display-manager"
        # --role desktop never joins the cluster: build-rpi5-stage4.sh:3896 skips the
        # GitOps tree and :3956 keeps containerd/kubelet/the firewall reconcilers out of
        # DEFAULT_SVCS entirely. Any of these on a client is a mis-built image.
        _forbid="containerd kubelet hugmesh-firewall-reconcile hugmesh-coturn-firewall hugmesh-go-live-reconcile"
    fi

    for _svc in ${_req}; do
        if _rl_has "${_R}" "${_svc}"; then
            ok "role ${_role}: ${_svc} is in the default runlevel"
        else
            bad "role ${_role}: ${_svc} MISSING from the default runlevel (required for every ${_class} node)"
        fi
    done
    for _svc in ${_forbid}; do
        if _rl_has "${_R}" "${_svc}"; then
            bad "role ${_role}: ${_svc} is in the default runlevel but MUST NOT be on a ${_class} node"
        else
            ok "role ${_role}: ${_svc} correctly absent from the default runlevel"
        fi
    done

    # ── tailscaled: required unless the image was built with no mesh client ──
    # --standalone bakes a marker (build-rpi5-stage4.sh:3892). --skip-mesh and
    # --skip-tailscale do NOT: they are pre-existing, ROLE-INDEPENDENT build options
    # (build-rpi5-stage4.sh:1055-1056 parsing; :5264 calls --skip-mesh exactly that)
    # which legitimately produce an image with no tailscale client and NO standalone
    # marker. Keying only off --standalone graded `--role pki --skip-tailscale` — a
    # correct image — as a defect, i.e. it counted a build option this section does
    # not know about as evidence, the one thing the section's own rule forbids.
    #
    # The posture is resolved FROM THE ARTIFACT, never from an env var (mutation (c)).
    # The INIT SCRIPT proves nothing: build-rpi5-stage4.sh:3670-3673 copies
    # /etc/init.d/tailscaled unconditionally, --skip-tailscale included. The BINARY
    # does: both builders install /usr/sbin/tailscaled only on the non-skipped path
    # (build-rpi5-stage4.sh:4343, build-x86-host-stage4.sh:5349) and abort the build
    # outright if that fetch fails (build-rpi5-stage4.sh:4347), so a shipped image has
    # the binary iff a mesh client was asked for. Hence: no binary => no client was
    # ever meant to be here (SKIP, not evidence); binary present but unscheduled, or
    # scheduled with no binary, => a real defect.
    if [ -f "${_R}/etc/hugmesh/standalone" ]; then
        skip "role ${_role}: tailscaled — STANDALONE image (build-rpi5-stage4.sh:3892 marker), --standalone sets SKIP_TAILSCALE"
    elif _rl_has "${_R}" tailscaled; then
        if [ -e "${_R}/usr/sbin/tailscaled" ]; then
            ok "role ${_role}: tailscaled is in the default runlevel (and /usr/sbin/tailscaled is installed)"
        else
            bad "role ${_role}: tailscaled is in the default runlevel but /usr/sbin/tailscaled is NOT installed — an inert mesh client that fails to start every boot"
        fi
    elif [ ! -e "${_R}/usr/sbin/tailscaled" ]; then
        skip "role ${_role}: tailscaled — no /usr/sbin/tailscaled in this image, so no mesh client was built into it (--skip-mesh / --skip-tailscale); NOT evidence the mesh posture is right"
    else
        bad "role ${_role}: /usr/sbin/tailscaled is installed but tailscaled is MISSING from the default runlevel — a mesh client that never starts"
    fi

    # ── THE ROLE-DISCRIMINATING ASSERTION ───────────────────────────────────
    # headscale is the ONE service whose scheduling is keyed off ROLE
    # (build-rpi5-stage4.sh:3981 links it for pki|generic; :4044 rm -f's it for every
    # other role). Both halves asserted: a missing control server on pki, and a rogue
    # control server on a worker, are both graded FAIL.
    if [ "${_hs_expect}" = required ]; then
        if _rl_has "${_R}" headscale; then
            ok "role ${_role}: headscale IS in the default runlevel (this role is the control server)"
        else
            bad "role ${_role}: headscale MISSING from the default runlevel — a pki/generic node that never starts the control server"
        fi
    else
        if _rl_has "${_R}" headscale; then
            bad "role ${_role}: headscale IS in the default runlevel but this role MUST NOT run a control server — either the wrong role payload shipped, or build-rpi5-stage4.sh:4044's rm -f did not fire on a --resume sysroot"
        else
            ok "role ${_role}: headscale correctly absent from the default runlevel (worker role)"
        fi
    fi

    # ── MARKER vs MANIFEST: two independent statements of the same intent ────
    # _hs_want was resolved far above from the KEYS manifest (the harness's request);
    # _hs_expect is resolved here from the image's own baked marker (what came back).
    # They are produced by different halves of the pipeline, so a disagreement is the
    # cleanest evidence available in-guest that the build shipped a role payload other
    # than the one that was asked for. Only graded when the manifest actually stated an
    # intent — "unknown" is not evidence in either direction (same rule as above).
    if [ "${_hs_want}" = unknown ]; then
        skip "role/manifest cross-check — the manifest stated no headscale intent (${_hs_src:-no source}); NOT evidence the role payload is correct"
    elif { [ "${_hs_want}" = true ] && [ "${_hs_expect}" = required ]; } || \
         { [ "${_hs_want}" = false ] && [ "${_hs_expect}" = forbidden ]; }; then
        ok "role/manifest cross-check: marker says '${_role}' (headscale ${_hs_expect}) and the ${_hs_src} asked headscale=${_hs_want} — they agree"
    else
        bad "role/manifest cross-check: the ${_hs_src} asked headscale=${_hs_want} but this image's marker says '${_role}' (headscale ${_hs_expect}) — the image does not match the role that was requested"
    fi

    # ── The agents that ship in EVERY image and are scheduled in NONE ────────
    # Measured 2026-08-26: all three images carry these seven init scripts and link none
    # of them at build time. That is DELIBERATE, not an oversight, and they split into
    # two kinds — so this asserts PRESENCE (the plumbing must be baked or runtime
    # activation is impossible) and deliberately does NOT assert runlevel membership
    # either way, because provisioning legitimately adds several of them at first boot:
    #
    #   RUNTIME-ACTIVATED by keys-provision when the manifest asks —
    #     hugmesh-device-registry-sync (provision.sh:1116), hugmesh-policy-sync (:1242),
    #     hugmesh-node-storage-reconcile (:1789), hugmesh-domain-reconcile (:2021).
    #   BUILD-TIME OPTIONAL, linked only when the slug is selected —
    #     hugmesh-vpn-reconcile (egress-vpn), hugmesh-tor-reconcile (tor).
    #   NEVER LINKED DIRECTLY, EVER — hugmesh-egress-vpn: its reconcile agent owns its
    #     lifecycle and rc-update adds it only once a verified assignment lands
    #     (specs/usr/sbin/hugmesh-vpn-reconcile:202). Linking it directly would bring a
    #     tunnel up on a selected-but-unassigned node. That one IS asserted, below.
    for _svc in hugmesh-device-registry-sync hugmesh-policy-sync hugmesh-node-storage-reconcile \
                hugmesh-domain-reconcile hugmesh-vpn-reconcile hugmesh-tor-reconcile hugmesh-egress-vpn; do
        if [ -f "${_R}/etc/init.d/${_svc}" ]; then
            ok "role ${_role}: ${_svc} init script is baked (activation plumbing present)"
        else
            bad "role ${_role}: ${_svc} init script NOT baked — this agent can never be activated on this node"
        fi
    done

    # hugmesh-egress-vpn must never be scheduled without the agent that owns it.
    if _rl_has "${_R}" hugmesh-egress-vpn && ! _rl_has "${_R}" hugmesh-vpn-reconcile; then
        bad "role ${_role}: hugmesh-egress-vpn is scheduled with NO hugmesh-vpn-reconcile owning it — an egress tunnel that no signed assignment can revoke"
    else
        ok "role ${_role}: no unowned hugmesh-egress-vpn in the default runlevel"
    fi

    # HALF-ACTIVATION. provision.sh enables the boot oneshot and installs the 60s/24h
    # convergence cron in two SEPARATE ifs (e.g. :1115 and :1122) — if the staged cron
    # is missing the service still gets rc-update'd and the node silently runs the sync
    # ONCE at boot with no convergence floor. Scheduled therefore implies cron-installed.
    for _svc in hugmesh-device-registry-sync hugmesh-policy-sync hugmesh-node-storage-reconcile \
                hugmesh-domain-reconcile hugmesh-vpn-reconcile hugmesh-tor-reconcile; do
        _rl_has "${_R}" "${_svc}" || continue
        if [ -f "${_R}/etc/cron.d/${_svc}" ]; then
            ok "role ${_role}: ${_svc} is scheduled AND its convergence cron is installed"
        else
            bad "role ${_role}: ${_svc} is scheduled but /etc/cron.d/${_svc} is absent — boot-once with no convergence floor"
        fi
    done

    # No entry in the default runlevel may dangle. OpenRC reports a start failure for a
    # symlink whose /etc/init.d target does not exist, and nothing else in this file
    # would notice.
    local _dangle
    _dangle=""
    for _svc in $(ls -1 "${_R}/etc/runlevels/default" 2>/dev/null); do
        _rl_dangling "${_R}" "${_svc}" && _dangle="${_dangle} ${_svc}"
    done
    if [ -z "${_dangle}" ]; then
        ok "role ${_role}: no dangling symlinks in the default runlevel"
    else
        bad "role ${_role}: dangling default-runlevel symlink(s) with no /etc/init.d target:${_dangle}"
    fi
}

assert_role_topology ""
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
# ── PRECONDITION FOR EVERY SELINUX ASSERTION BELOW ─────────────────────────
# AN UNLABELLED ROOTFS PASSES ALL ~10 SELINUX CHECKS BELOW. That is not a
# hypothetical: tests/qemu/run-qemu-test.sh used to build the stage4 rootfs with
#
#     tar --xattrs-include='*.*' -xpf "${STAGE4}" 2>/dev/null || tar -xpf "${STAGE4}"
#
# — stderr discarded, fallback unannounced — so any failure of the
# xattr-preserving extraction silently produced a rootfs with NO
# security.selinux on anything. Nothing below can see that. `getenforce` still
# says Permissive, `semodule -l` still lists every module in the manifest, the
# mode still matches the manifest, no load-failed marker is standing: a full
# sweep of green on a filesystem where SELinux is grading nothing at all. Those
# PASSes are not evidence; they are the shape evidence would have.
#
# So establish the precondition FIRST, and let it be the thing that fails.
# Note this asserts the POSTCONDITION, not the tar: labels can legitimately
# arrive either from the extraction's xattrs or from provision_selinux()'s
# first-boot `restorecon -RF /` (specs/etc/keys-provision/provision.sh:2880).
# Either route is fine. Neither having worked is what must be loud.
#
# Reader ladder, strongest first — all three read the same on-disk xattr:
#   1. getfattr (sys-apps/attr), which names the attribute explicitly;
#   2. secon (sys-apps/policycoreutils, in every specs-*/packages.list, while
#      sys-apps/attr is in NONE of them — so on a real image this is usually the
#      only rung that exists besides ls -Z);
#   3. ls -Zd (coreutils built with SELinux support).
# EACH RUNG FALLS THROUGH ON AN EMPTY ANSWER, NOT MERELY ON A MISSING TOOL. The
# first cut of this function returned unconditionally from whichever rung's
# binary happened to be installed, so a getfattr that EXISTS but cannot answer
# (EOPNOTSUPP, attr built without the security namespace, a bind-mounted path)
# produced an empty context and FAILed the assertion below on a rootfs that
# secon would have reported as perfectly labelled. Presence is not an answer.
# If none of the three can answer, this FAILS rather than skipping: on an image
# that ships getenforce and semodule — which the checks below all assume —
# being unable to read a single file's label is itself a broken SELinux
# userland, and a skip here would hand the vacuity straight back.
_slx_secon_label() { # _slx_secon_label PATH -> context via secon, or empty
    # secon takes the file as the ARGUMENT OF --file ("secon --file FILE"), so
    # the earlier "secon --file --rawcontext -- FILE" spelling made secon read a
    # file literally named --rawcontext; and the raw flag is -R/--raw, not
    # --rawcontext. Both spellings have moved across policycoreutils releases,
    # so try the raw form, then the plain one: a rejected option just exits
    # nonzero and the caller falls through to the next rung.
    local s=""
    s="$(secon --raw --file "$1" 2>/dev/null || true)"
    [ -n "${s}" ] || s="$(secon --file "$1" 2>/dev/null || true)"
    [ -n "${s}" ] || return 0
    # secon's default output is one "key: value" line per component, NOT a bare
    # context, so a naive *:*:*: match on the whole blob would "succeed" on
    # "user: ...\nrole: ..." — four colons, no context. Test the FIRST line, and
    # only accept it as a context if it holds no whitespace.
    local first="${s%%$'\n'*}"
    case "${first}" in
        *[[:space:]]*) : ;;
        *:*:*:*) printf '%s' "${first}"; return 0 ;;
    esac
    # Otherwise reassemble user:role:type:range from the labelled lines.
    printf '%s\n' "${s}" | awk '
        /^[[:space:]]*user:/  { u = $2 }
        /^[[:space:]]*role:/  { r = $2 }
        /^[[:space:]]*type:/  { t = $2 }
        /^[[:space:]]*(range|level|sensitivity):/ { if (l == "") l = $2 }
        END { if (u != "" && r != "" && t != "") printf "%s:%s:%s:%s", u, r, t, (l == "" ? "s0" : l) }'
}
_slx_label_of() {   # _slx_label_of PATH -> the file's SELinux context, or empty
    local v=""
    if command -v getfattr >/dev/null 2>&1; then
        v="$(getfattr --absolute-names --only-values -n security.selinux -- "$1" 2>/dev/null | tr -d '\000')"
        [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
    fi
    if command -v secon >/dev/null 2>&1; then
        v="$(_slx_secon_label "$1")"
        [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
    fi
    if command -v ls >/dev/null 2>&1; then
        v="$(ls -Zd -- "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[^ :]+:[^ :]+:[^ :]+:/) {print $i; exit}}')"
        [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
    fi
    return 0
}
# Probe files that come out of the stage4 tarball itself. NOT /etc/fstab and NOT
# /etc/inittab: run-qemu-test.sh writes both of those on the host after the
# untar, so their labels say nothing about whether the tarball's survived.
_slx_xattr_probe="${SELINUX_XATTR_PROBE:-/sbin/init /bin/bash /bin/sh /etc/passwd}"
_slx_probe_file=""
for _slx_f in ${_slx_xattr_probe}; do
    [ -e "${_slx_f}" ] && { _slx_probe_file="${_slx_f}"; break; }
done
_slx_probe_label=""
[ -n "${_slx_probe_file}" ] && _slx_probe_label="$(_slx_label_of "${_slx_probe_file}")"
# unlabeled_t is what an unlabelled file reports on a node whose policy IS
# loaded, so an empty answer and unlabeled_t are the same verdict here. '?' is
# what ls -Z prints when it cannot get a context at all.
_slx_labelled=0
case "${_slx_probe_label}" in
    ''|'?'|*unlabeled_t*|*unlabeled:*) _slx_labelled=0 ;;
    *:*:*:*)                           _slx_labelled=1 ;;
    *)                                 _slx_labelled=0 ;;
esac
check "rootfs carries SELinux labels on disk — every SELinux check below is vacuous without this (probe:'${_slx_probe_file:-<none of ${_slx_xattr_probe}>}' label:'${_slx_probe_label:-<none>}')" \
    '[ "${_slx_labelled}" = 1 ]'
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
#
# STDIN MUST BE /dev/null HERE, AND THIS IS THE LINE THAT FALSIFIED SIX VERDICTS.
# This whole file is STREAMED into the guest — docker-entrypoint.sh runs
# `ssh ... 'sudo bash -s' < assertions.sh` — so at any point during execution,
# bash's stdin IS the remainder of this script. ausearch reads audit records
# from stdin whenever stdin is not a tty, so on every image that ships auditd
# it swallowed everything from here down: the RESULT line never printed, bash
# hit EOF and exited 0, and the harness graded the row PASS. All six
# 2026-08-19 "PASS" logs truncate at the '-- AVC harvest' header above while
# holding 9-12 real FAILs each. --input-logs pins ausearch to the audit log
# files (the thing actually being harvested) and </dev/null makes stdin
# unswallowable even for an ausearch too old to know the flag; the dmesg
# fallback gets the same guard because it runs in exactly the same stream.
AVC_REPORT_GUEST="${AVC_REPORT_GUEST:-/var/log/hugmesh-avc-report.txt}"
_avc_src=""; _avc_raw=""
if command -v ausearch >/dev/null 2>&1 && _avc_raw="$(ausearch -m AVC,USER_AVC -ts boot --input-logs </dev/null 2>/dev/null)"; then
    _avc_src="ausearch -m AVC,USER_AVC -ts boot --input-logs"
else
    _avc_raw="$(dmesg </dev/null 2>/dev/null | grep -E 'type=1400|type=1107|avc: *denied' || true)"
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
