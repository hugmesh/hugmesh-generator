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
# Executes the REAL init script's argument logic, the REAL version-floor function,
# and the REAL builder blocks (cut out of EVERY build-*-stage4.sh) into a scratch
# sysroot. No root, no network.
# shellcheck disable=SC2034  # SKIP_*/TAILSCALE_VERSION/SYSROOT are read by the eval'd builder code
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
P=0
N=0
ok()  { printf '  PASS %s\n' "$*"; P=$((P + 1)); }
bad() { printf '  FAIL %s\n' "$*"; N=$((N + 1)); }

BUILDERS=()
for b in "${REPO}"/build-*-stage4.sh; do BUILDERS+=("$(basename "${b}")"); done
[ "${#BUILDERS[@]}" -ge 10 ] && ok "found ${#BUILDERS[@]} image builders" \
    || bad "expected at least 10 build-*-stage4.sh builders, found ${#BUILDERS[@]}"

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

echo "== tailscaled: --tailscale-version floor (the flag exists from 1.32.0) =="
# version_ok VERSION -> exit status of the REAL dlv_tailscale_version_ok.
version_ok() {
    bash -c 'source "$1/scripts/_download-lib.sh"; dlv_tailscale_version_ok "$2"' \
        _ "${REPO}" "$1" 2>/dev/null
}
for v in 1.30.2 1.31.9 1.4.0 0.99.0 latest 1.78.1-rc ''; do
    if version_ok "${v}"; then bad "the floor accepts --tailscale-version '${v}'"
    else ok "the floor refuses --tailscale-version '${v}'"; fi
done
for v in 1.32.0 1.78.1 1.100.0 2.0.0; do
    if version_ok "${v}"; then ok "the floor accepts --tailscale-version ${v}"
    else bad "the floor refuses --tailscale-version ${v}"; fi
done

# Every builder: its pinned default passes the floor, and it calls the floor after
# the argument loop and before it fetches tailscale. The call line is cut out and
# RUN with an old version (must refuse) and with --skip-tailscale (must not).
for b in "${BUILDERS[@]}"; do
    f="${REPO}/${b}"
    pin="$(sed -n 's/^TAILSCALE_VERSION="\([^"]*\)".*/\1/p' "${f}" | head -n 1)"
    if [ -n "${pin}" ] && version_ok "${pin}"; then ok "${b}: pinned tailscale ${pin} passes the floor"
    else bad "${b}: pinned tailscale '${pin}' does not pass the floor"; fi
    call_ln="$(grep -n 'dlv_tailscale_version_ok "\${TAILSCALE_VERSION}"' "${f}" | head -n 1 | cut -d: -f1)"
    opt_ln="$(grep -n -- '--tailscale-version)' "${f}" | head -n 1 | cut -d: -f1)"
    fetch_ln="$(grep -n 'dlv_fetch_retry "\${TS_URL}"' "${f}" | head -n 1 | cut -d: -f1)"
    if [ -z "${call_ln}" ]; then bad "${b}: never checks --tailscale-version against the floor"; continue; fi
    if [ -n "${opt_ln}" ] && [ -n "${fetch_ln}" ] && [ "${call_ln}" -gt "${opt_ln}" ] && [ "${call_ln}" -lt "${fetch_ln}" ]; then
        ok "${b}: the floor runs after option parsing and before the tailscale fetch"
    else
        bad "${b}: the floor call (line ${call_ln}) is not between option parsing (${opt_ln}) and the fetch (${fetch_ln})"
    fi
    # --standalone turns tailscale off AFTER option parsing (its posture block). A floor
    # that ran before that block would refuse `--standalone --tailscale-version <old>`,
    # a build that ships no tailscaled at all.
    skip_ln="$(grep -n '^[[:space:]]*SKIP_TAILSCALE=true[[:space:]]*\(#.*\)\{0,1\}$' "${f}" | tail -n 1 | cut -d: -f1)"
    if [ -n "${skip_ln}" ] && [ "${call_ln}" -gt "${skip_ln}" ]; then
        ok "${b}: the floor runs after the --standalone posture settles SKIP_TAILSCALE"
    else
        bad "${b}: the floor call (line ${call_ln}) runs before the last SKIP_TAILSCALE=true (line ${skip_ln:-none})"
    fi
    line="$(sed -n "${call_ln}p" "${f}")"
    if ( set -u; source "${REPO}/scripts/_download-lib.sh"; SKIP_MESH=false; SKIP_TAILSCALE=false
         TAILSCALE_VERSION=1.30.2; eval "${line}" ) >/dev/null 2>&1; then
        bad "${b}: the floor line lets tailscale 1.30.2 through"
    else ok "${b}: the floor line refuses tailscale 1.30.2"; fi
    if ( set -u; source "${REPO}/scripts/_download-lib.sh"; SKIP_MESH=false; SKIP_TAILSCALE=true
         TAILSCALE_VERSION=1.30.2; eval "${line}" ) >/dev/null 2>&1; then
        ok "${b}: --skip-tailscale skips the floor"
    else bad "${b}: the floor refuses a build that does not ship tailscale"; fi
done

echo "== NetworkManager: no connectivity probe on headless and node images =="
# The decision per builder: which variable settings get the probe OFF (file written)
# and which keep the package default (no file). A builder that enables NetworkManager
# and is missing here FAILS: every new builder has to make this decision.
#   builder | block marker | settings that turn it off | settings that keep it
NM_TABLE=(
    "build-rpi5-stage4.sh|wait|ROLE_CLIENT=false|ROLE_CLIENT=true"
    "build-x86-host-stage4.sh|probe|ROLE_CLIENT=false|ROLE_CLIENT=true"
    "build-jetson-stage4.sh|probe|ROLE_CLIENT=false|ROLE_CLIENT=true"
    "build-orangepi5-stage4.sh|probe|ROLE_CLIENT=false|ROLE_CLIENT=true"
    "build-orangepi4-lts-stage4.sh|probe|ROLE_CLIENT=false|ROLE_CLIENT=true"
    "build-frite-stage4.sh|probe|DESKTOP=none|DESKTOP=light"
    "build-orangepi-zero2-stage4.sh|probe|:|"
    "build-orangepi-zero2w-stage4.sh|probe|:|"
    "build-orangepi-zero3-stage4.sh|probe|:|"
    "build-orangepi3-lts-stage4.sh|probe|:|"
)
# rpi5 writes it inside its INACTIVE_TIMEOUT=60 block (#858), which ends at its `fi`
# (rpi5 has no build-time SELinux label pass); every other builder has its own block,
# which ends at a blank line. x86's INACTIVE_TIMEOUT=60 is pinned by
# tests/qemu/mesh_client_test.sh section F1.
nm_block() { # $1 builder  $2 wait|probe
    case "$2" in
        wait)  awk '/^# ── NetworkManager: wait for the link before handing over `net`/{p=1} p{print} p&&/^fi$/{exit}' "$1" ;;
        probe) awk '/^# ── NetworkManager: no connectivity probe/{p=1} p&&/^$/{exit} p{print}' "$1" ;;
    esac
}
nm_block_line() { # $1 builder  $2 wait|probe -> line number of the block marker
    case "$2" in
        wait)  grep -n '^# ── NetworkManager: wait for the link before handing over `net`' "$1" ;;
        probe) grep -n '^# ── NetworkManager: no connectivity probe' "$1" ;;
    esac | head -n 1 | cut -d: -f1
}
# run_block BUILDER SRC SETTING -> 0 when the block wrote the file, 1 when it did not,
# 2 when it failed to run. Runs under `set -u` with ONLY the setting defined, so a
# gate on a variable the builder never sets is caught here, not in a 3-hour build.
run_block() {
    local s
    s="$(mktemp -d "${WORK}/sys.XXXXXX")"
    ( set -u; info() { :; }; SYSROOT="${s}"
      [ "$3" = ":" ] || eval "$3"
      eval "$2" ) >/dev/null 2>&1 || return 2
    RUN_FILE="${s}/etc/NetworkManager/conf.d/90-hugmesh-no-connectivity-check.conf"
    RUN_SYS="${s}"
    [ -e "${RUN_FILE}" ]
}
in_table() { local r; for r in "${NM_TABLE[@]}"; do [ "${r%%|*}" = "$1" ] && return 0; done; return 1; }

nm_count=0
for b in "${BUILDERS[@]}"; do
    # Fail closed: ANY mention of NetworkManager (a runlevel array, a `+=`, an
    # rc-update, a package set) counts as shipping it, not only the one-line
    # DEFAULT_SVCS=( ... ) shape every builder uses today.
    if grep -q 'NetworkManager' "${REPO}/${b}"; then
        nm_count=$((nm_count + 1))
        in_table "${b}" && ok "${b}: ships NetworkManager and has a connectivity-probe decision" \
            || bad "${b}: ships NetworkManager but has no connectivity-probe decision in this test"
    fi
done
[ "${nm_count}" -ge 10 ] && ok "${nm_count} builders ship NetworkManager and every one was checked" \
    || bad "only ${nm_count} builders detected as shipping NetworkManager (expected at least 10): the detection went blind"

for row in "${NM_TABLE[@]}"; do
    IFS='|' read -r b kind off keep <<<"${row}"
    f="${REPO}/${b}"
    [ -f "${f}" ] || { bad "${b}: listed in the decision table but missing"; continue; }
    src="$(nm_block "${f}" "${kind}")"
    if [ -z "${src}" ] || ! grep -q '90-hugmesh-no-connectivity-check.conf' <<<"${src}"; then
        bad "${b}: the NetworkManager connectivity-probe block was not found"; continue
    fi
    # Placement: in the sysroot before it is packaged (and so before the live/installer
    # squashfs is cut from it), and, on a builder that labels at build time (frite,
    # x86), BEFORE that label pass: the file is a new inode, so written after setfiles
    # it would ship in the stage4 with no SELinux label.
    bl="$(nm_block_line "${f}" "${kind}")"
    pk="$(grep -n '^banner "Packaging stage4 tarball"' "${f}" | head -n 1 | cut -d: -f1)"
    lb="$(grep -n 'slx_label_tree "\${SYSROOT}"' "${f}" | head -n 1 | cut -d: -f1)"
    if [ -n "${pk}" ] && [ "${bl}" -lt "${pk}" ]; then ok "${b}: written before the stage4 is packaged"
    else bad "${b}: the block (line ${bl}) is not before the packaging banner (line ${pk:-none})"; fi
    case "${b}" in
        build-frite-stage4.sh|build-x86-host-stage4.sh)
            [ -n "${lb}" ] || bad "${b}: its build-time SELinux label pass (slx_label_tree \"\${SYSROOT}\") was not found" ;;
    esac
    if [ -n "${lb}" ]; then
        if [ "${bl}" -lt "${lb}" ]; then ok "${b}: written before the build-time SELinux labelling"
        else bad "${b}: written after the build-time SELinux labelling (line ${lb}), so it ships unlabelled"; fi
    fi
    run_block "${b}" "${src}" "${off}"; rc=$?
    if [ "${rc}" -eq 2 ]; then bad "${b} (${off}): the block failed to run under set -u"
    elif [ "${rc}" -eq 1 ]; then bad "${b} (${off}): keeps the connectivity probe (no file written)"
    else
        # Parse it as NetworkManager does: the [connectivity] section's enabled key.
        v="$(awk -F= '/^\[/{sec=$0} sec=="[connectivity]" && $1=="enabled"{print $2}' "${RUN_FILE}")"
        if [ "${v}" = "false" ]; then ok "${b} (${off}): gets [connectivity] enabled=false"
        else bad "${b} (${off}): the file does not set [connectivity] enabled=false"; fi
        if [ "${kind}" = wait ]; then
            if [ "$(grep -c '^INACTIVE_TIMEOUT=60$' "${RUN_SYS}/etc/conf.d/NetworkManager" 2>/dev/null)" = 1 ]; then
                ok "${b}: INACTIVE_TIMEOUT=60 is still written"
            else bad "${b}: INACTIVE_TIMEOUT=60 is no longer written"; fi
        fi
    fi
    if [ -n "${keep}" ]; then
        run_block "${b}" "${src}" "${keep}"; rc=$?
        if [ "${rc}" -eq 2 ]; then bad "${b} (${keep}): the block failed to run under set -u"
        elif [ "${rc}" -eq 0 ]; then bad "${b} (${keep}): a desktop lost its connectivity check (captive portals)"
        else ok "${b} (${keep}): a desktop keeps the package's connectivity check"; fi
    fi
done

echo "== test-node-telemetry-off: ${P} passed, ${N} failed =="
[ "${N}" -eq 0 ]
