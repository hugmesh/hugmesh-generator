#!/bin/bash
# avc-workload.sh — runs INSIDE the QEMU guest (over SSH, as root) to EXERCISE
# every workload the hugmesh SELinux node-policy modules confine, so the AVC
# harvest that follows (tests/qemu/assertions.sh / tests/qemu/avc-workout.sh)
# actually has evidence to collect. This is the workout half of narrowing the
# rules tagged '# INFERRED-WIDE: narrow after QEMU enforcing AVC pass' in
# specs/selinux/*.te — the modules run PERMISSIVE, every denial is logged and
# nothing breaks, and those logged denials are the product.
#
# PROBE LIST — derived from what the 9 specs/selinux modules confine, one probe
# per confined workload, each gated on the surface actually existing on THIS
# image (the builders link/remove the init scripts per role, so presence IS the
# role-appropriateness test — no role table to drift):
#
#   hugmesh_authkeys.te              sshd's AuthorizedKeysCommand. The REAL
#                                    domain transition (sshd_t -> exec) only
#                                    happens on an ssh login, which the HOST
#                                    driver performs (every harness ssh is one,
#                                    and avc-workout.sh adds logins explicitly).
#                                    In-guest we additionally exec the lookup
#                                    binary directly: that runs in the caller's
#                                    domain, NOT hugmesh_authkeys_t, but still
#                                    exercises the hugmesh_authkeys_cache_t
#                                    read surface its .fc labels.
#   hugmesh_device_registry_sync.te  rc-service hugmesh-device-registry-sync
#                                    (the device-registry sync trigger).
#   hugmesh_domain_reconcile.te      rc-service hugmesh-domain-reconcile.
#   hugmesh_node_storage.te          rc-service hugmesh-node-storage-reconcile.
#   hugmesh_policy_sync.te           rc-service hugmesh-policy-sync (pki/control
#                                    images only — gated by presence).
#   hugmesh_tor.te                   rc-service hugmesh-tor-reconcile (writes
#                                    the managed torrc + reloads/starts distro tor).
#   hugmesh_vpn.te                   rc-service hugmesh-egress-vpn (runner
#                                    domain) + hugmesh-vpn-reconcile
#                                    (reconcile domain).
#   localpath_provisioner.te /       container/k8s lane: containerd + kubelet
#   otel_collector.te                service starts and `kubeadm init --dry-run`.
#                                    The two pod domains themselves only exist
#                                    inside a bootstrapped cluster; this
#                                    exercises the container-runtime AVC
#                                    surface an image can produce stand-alone.
#
# Probes NEVER fail this script: on a clusterless, meshless QEMU guest most of
# the reconcile agents exit non-zero by design (no export to fetch, fail-closed
# verify) — a non-zero rc is DATA, and the AVCs each attempt generated are the
# point. Exit code is always 0 so the driver's verdict comes from the harvest,
# not from workload exit codes.
set -u

say() { echo "[avc-workload] $*"; }

PROBES=0
run_probe() {
    # run_probe <name> <timeout-secs> <cmd...> — timeout-wrapped, never fatal.
    local name="$1" secs="$2" out rc; shift 2
    say "PROBE ${name}: $*"
    out="$(timeout -k 10 "${secs}" "$@" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        say "PROBE ${name}: rc=0"
    elif [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
        say "PROBE ${name}: TIMED OUT after ${secs}s (rc=${rc}) — partial exercise still harvested"
    else
        say "PROBE ${name}: rc=${rc} (non-zero is EXPECTED on a clusterless guest; the AVCs are the product)"
    fi
    [ -n "${out}" ] && printf '%s\n' "${out}" | tail -n 6 | sed 's/^/    | /'
    PROBES=$((PROBES+1))
    return 0
}

svc_probe() {
    # svc_probe <initd-name> <owning .te> — restart re-runs a oneshot's start.
    local svc="$1" te="$2"
    if [ -x "/etc/init.d/${svc}" ]; then
        run_probe "${svc}" 180 rc-service "${svc}" restart
    else
        say "SKIP ${svc}: /etc/init.d/${svc} not on this image (role-appropriate) — ${te} not exercised here"
    fi
    return 0
}

say "== hugmesh SELinux AVC workout: workload probes =="
say "getenforce: $(getenforce 2>/dev/null || echo '<unavailable>')"

# ── hugmesh_authkeys.te (see caveat in the header: real transition = ssh login,
#    driven by the host; this exercises the cache-read surface) ────────────────
if command -v hugmesh-authorized-keys-lookup >/dev/null 2>&1; then
    run_probe "authkeys-lookup-direct" 60 hugmesh-authorized-keys-lookup tester
else
    say "SKIP authkeys-lookup-direct: hugmesh-authorized-keys-lookup not on this image"
fi
# sshd re-reads its config tree (device-registry.conf include surface).
command -v sshd >/dev/null 2>&1 && run_probe "sshd-config-read" 60 sshd -T

# ── the Layer-A/B reconcile agents, one OpenRC probe per confined domain ─────
svc_probe hugmesh-device-registry-sync   hugmesh_device_registry_sync.te
svc_probe hugmesh-domain-reconcile       hugmesh_domain_reconcile.te
svc_probe hugmesh-node-storage-reconcile hugmesh_node_storage.te
svc_probe hugmesh-policy-sync            hugmesh_policy_sync.te
svc_probe hugmesh-tor-reconcile          hugmesh_tor.te
svc_probe hugmesh-egress-vpn             hugmesh_vpn.te
svc_probe hugmesh-vpn-reconcile          hugmesh_vpn.te

# ── container/k8s lane (localpath_provisioner.te / otel_collector.te) ────────
svc_probe containerd "container runtime (localpath_provisioner.te / otel_collector.te lane)"
svc_probe kubelet    "container runtime (localpath_provisioner.te / otel_collector.te lane)"
if command -v kubeadm >/dev/null 2>&1; then
    # --dry-run: full preflight + manifest generation, nothing persisted. Slow
    # under TCG — generous bound, and a timeout still leaves harvested AVCs.
    run_probe "kubeadm-init-dry-run" 600 kubeadm init --dry-run
else
    say "SKIP kubeadm-init-dry-run: kubeadm not on this image"
fi

say "== workload probes complete: ${PROBES} probe(s) ran =="
exit 0
