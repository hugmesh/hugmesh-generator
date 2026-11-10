#!/usr/bin/env bash
# test-node-telemetry-off.sh — a mesh node does not phone home by default.
#
# Observed on an egress-isolated boot of ENV=prod Raspberry Pi 5 node images (every
# attempt was dropped, so these are counts of tries, per node):
#   * tailscaled streamed its logs to log.tailscale.io (~36-39 DNS queries each),
#     and with DNS unanswered it retried through hard-coded public bootstrap-DNS
#     addresses on TCP 443;
#   * NetworkManager's connectivity check queried nmcheck.gnome.org (~88 each).
# Neither has a reason to run on a self-hosted mesh server.
#
# Executes the REAL init script's argument logic and the REAL builder block (cut
# out of each builder) into a scratch sysroot. No root, no network.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
P=0
N=0
ok()  { printf '  PASS %s\n' "$*"; P=$((P + 1)); }
bad() { printf '  FAIL %s\n' "$*"; N=$((N + 1)); }

# tailscaled_args [conf.d assignment] -> the command_args the init script computes.
tailscaled_args() {
    # An openrc-run script is POSIX sh: source it with the conf.d value set, the way
    # openrc-run does (conf.d is read before the script body).
    sh -c '
        [ -n "$1" ] && eval "$1"
        . "$2"
        printf "%s\n" "${command_args}"
    ' sh "${1:-}" "${REPO}/specs/etc/init.d/tailscaled"
}

echo "== tailscaled: no log upload by default =="
a="$(tailscaled_args)"
case " ${a} " in
    *" --no-logs-no-support "*) ok "default command_args carry --no-logs-no-support" ;;
    *) bad "default command_args upload logs to the vendor: '${a}'" ;;
esac
case " ${a} " in
    *" --state=/var/lib/tailscale/tailscaled.state "*" --port=41641 "*) ok "the existing state/socket/port arguments are unchanged" ;;
    *) bad "the existing arguments changed: '${a}'" ;;
esac
a="$(tailscaled_args 'TAILSCALED_UPLOAD_LOGS=yes')"
case " ${a} " in
    *" --no-logs-no-support "*) bad "TAILSCALED_UPLOAD_LOGS=yes did not opt back in" ;;
    *) ok "TAILSCALED_UPLOAD_LOGS=yes opts back in to log upload" ;;
esac
a="$(tailscaled_args 'TAILSCALED_UPLOAD_LOGS=maybe')"
case " ${a} " in
    *" --no-logs-no-support "*) ok "an unrecognised TAILSCALED_UPLOAD_LOGS value keeps uploads off" ;;
    *) bad "TAILSCALED_UPLOAD_LOGS=maybe turned uploads on" ;;
esac

echo "== NetworkManager: no connectivity probe on cluster nodes =="
# The block runs at top level in each builder, so cut it out and run it.
nm_block() { # $1 builder
    awk '/^# ── NetworkManager: wait for the link before handing over `net`/{p=1} p{print} p&&/^fi$/{exit}' "$1"
}
for b in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
    src="$(nm_block "${REPO}/${b}")"
    if [ -z "${src}" ]; then bad "${b}: the cluster-node NetworkManager block was not found"; continue; fi
    for client in false true; do
        s="$(mktemp -d "${WORK}/sys.XXXXXX")"
        ( info() { :; }; SYSROOT="${s}"; ROLE_CLIENT="${client}"; eval "${src}" ) \
            || { bad "${b} ROLE_CLIENT=${client}: the block failed to run"; continue; }
        f="${s}/etc/NetworkManager/conf.d/90-hugmesh-no-connectivity-check.conf"
        if [ "${client}" = false ]; then
            # Parse it as NetworkManager does: the [connectivity] section's enabled key.
            v="$(awk -F= '/^\[/{sec=$0} sec=="[connectivity]" && $1=="enabled"{print $2}' "${f}" 2>/dev/null)"
            if [ "${v}" = "false" ]; then ok "${b}: a cluster node gets [connectivity] enabled=false"
            else bad "${b}: a cluster node keeps the connectivity probe (no [connectivity] enabled=false)"; fi
            if [ "$(cat "${s}/etc/conf.d/NetworkManager" 2>/dev/null | grep -c '^INACTIVE_TIMEOUT=60$')" = 1 ]; then
                ok "${b}: INACTIVE_TIMEOUT=60 is still written"
            else bad "${b}: INACTIVE_TIMEOUT=60 is no longer written"; fi
        else
            if [ -e "${f}" ]; then bad "${b}: a client desktop lost its connectivity check (captive portals)"
            else ok "${b}: a client desktop keeps the package's connectivity check"; fi
        fi
    done
done

echo "== test-node-telemetry-off: ${P} passed, ${N} failed =="
[ "${N}" -eq 0 ]
