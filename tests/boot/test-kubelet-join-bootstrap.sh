#!/usr/bin/env bash
# test-kubelet-join-bootstrap.sh — the kubelet OpenRC init script must let
# `kubeadm join`'s TLS bootstrap complete (issue #48).
#
# WHY THIS EXISTS. specs/etc/init.d/kubelet hardcoded command_args with no
# --bootstrap-kubeconfig and never read /var/lib/kubelet/kubeadm-flags.env, so
# a joining node's kubelet could neither find the bootstrap credential kubeadm
# staged at /etc/kubernetes/bootstrap-kubelet.conf nor pick up the node-specific
# flags kubeadm wrote (--container-runtime-endpoint, --node-ip, ...). `kubeadm
# join` therefore hung forever waiting for a kubelet.conf the kubelet could
# never mint — on EVERY node, hardware included. `kubeadm init` writes
# kubelet.conf directly, which is exactly why single-node always looked fine.
#
# What is asserted (static + effect, no root, no docker, no cluster):
#   [pin]     command_args (the LIVE line, not a comment) carries
#             --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf
#             alongside the existing --kubeconfig/--config, and expands
#             KUBELET_KUBEADM_ARGS.
#   [source]  a live (non-comment) line sources /var/lib/kubelet/kubeadm-flags.env
#             guarded on its existence.
#   [effect]  the script is SOURCED in a plain POSIX sh (openrc-run scripts are
#             sh) against a sandboxed kubeadm-flags.env path:
#               - env file ABSENT  -> command_args is EXACTLY the pinned string
#                 (single-node/init behavior stays byte-identical + the additive
#                 bootstrap flag; no trailing garbage);
#               - env file PRESENT -> KUBELET_KUBEADM_ARGS lands at the end and
#                 the kubeconfig/bootstrap pins survive.
#   [shared]  the shared overlay is the ONLY copy — no specs-*/etc/init.d/kubelet
#             per-arch fork exists to diverge — and both k8s builders (x86, rpi5)
#             install it from ${SHARED_SPECS}.
#   [syntax]  sh -n parses the script (openrc-run bodies are POSIX sh).
#
# NEGATIVE CONTROLS (a guard that cannot be shown failing is not a guard): the
# whole checker re-runs against staged copies carrying one regression each —
# bootstrap flag dropped, sourcing removed, KUBELET_KUBEADM_ARGS expansion
# dropped, command_args commented out — and each MUST go red.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUBELET_INIT="${REPO}/specs/etc/init.d/kubelet"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

FLAGS_ENV_PATH="/var/lib/kubelet/kubeadm-flags.env"
BOOTSTRAP_ARG="--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf"
KUBECONFIG_ARG="--kubeconfig=/etc/kubernetes/kubelet.conf"
CONFIG_ARG="--config=/var/lib/kubelet/config.yaml"
BASE_ARGS="${CONFIG_ARG} ${KUBECONFIG_ARG} ${BOOTSTRAP_ARG} --v=2"

# check_script <path> <emit> — run every assertion against one script copy.
# emit=yes prints PASS/FAIL into the tally; emit=no is the negative-control
# mode: silent, returns non-zero iff any assertion failed.
check_script() {
  local s="$1" emit="$2" lp=0 lf=0
  _ok(){ [ "${emit}" = yes ] && ok "$@"; lp=$((lp+1)); }
  _bad(){ [ "${emit}" = yes ] && bad "$@"; lf=$((lf+1)); }

  # ── static pins (anchored to LIVE lines so comments cannot satisfy them) ──
  head -1 "${s}" | grep -q '^#!/sbin/openrc-run$' \
    && _ok "openrc: #!/sbin/openrc-run shebang" || _bad "openrc: wrong/missing shebang"
  local ca
  ca="$(grep -E '^command_args=' "${s}" || true)"
  [ -n "${ca}" ] \
    && _ok "pin: live (uncommented) command_args= line exists" || _bad "pin: no live command_args= line"
  printf '%s' "${ca}" | grep -qF -- "${BOOTSTRAP_ARG}" \
    && _ok "pin: command_args carries ${BOOTSTRAP_ARG}" || _bad "pin: command_args lost ${BOOTSTRAP_ARG} (kubeadm join TLS bootstrap can never complete — issue #48)"
  printf '%s' "${ca}" | grep -qF -- "${KUBECONFIG_ARG}" \
    && _ok "pin: command_args keeps ${KUBECONFIG_ARG}" || _bad "pin: command_args lost ${KUBECONFIG_ARG}"
  printf '%s' "${ca}" | grep -qF -- "${CONFIG_ARG}" \
    && _ok "pin: command_args keeps ${CONFIG_ARG}" || _bad "pin: command_args lost ${CONFIG_ARG}"
  printf '%s' "${ca}" | grep -q 'KUBELET_KUBEADM_ARGS' \
    && _ok "pin: command_args expands KUBELET_KUBEADM_ARGS" || _bad "pin: command_args does not expand KUBELET_KUBEADM_ARGS (kubeadm's node flags never reach the kubelet)"
  grep -Eq "^[[:space:]]*\.[[:space:]]+${FLAGS_ENV_PATH}" "${s}" \
    && _ok "source: live line sources ${FLAGS_ENV_PATH}" || _bad "source: no live line sources ${FLAGS_ENV_PATH}"
  grep -Eq "^[[:space:]]*if[[:space:]]+\[[[:space:]]+-f[[:space:]]+${FLAGS_ENV_PATH}" "${s}" \
    && _ok "source: guarded on the env file's existence" || _bad "source: not guarded on -f ${FLAGS_ENV_PATH}"

  # ── syntax: openrc-run bodies are POSIX sh ──
  sh -n "${s}" 2>/dev/null \
    && _ok "syntax: sh -n parses the script" || _bad "syntax: sh -n rejects the script"

  # ── effect: source in plain sh against a sandboxed env-file path ──
  # (openrc functions like depend() are only DEFINED at source time, never run.)
  local sandbox="${WORK}/sandbox-$$-${RANDOM}"; mkdir -p "${sandbox}"
  local copy="${sandbox}/kubelet.initd" env_file="${sandbox}/kubeadm-flags.env"
  sed "s|${FLAGS_ENV_PATH}|${env_file}|g" "${s}" > "${copy}"
  local got
  # env file ABSENT: byte-identical base args (init/single-node path).
  got="$(sh -c 'RC_SVCNAME=kubelet; . "$1" 2>/dev/null; printf %s "${command_args:-}"' sh "${copy}")"
  [ "${got}" = "${BASE_ARGS}" ] \
    && _ok "effect: env file absent -> command_args is exactly the pinned base set" \
    || _bad "effect: env file absent -> command_args diverged: '${got}'"
  # env file PRESENT: kubeadm's flags land, pins survive.
  printf 'KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///run/containerd/containerd.sock --node-ip=192.0.2.10"\n' > "${env_file}"
  got="$(sh -c 'RC_SVCNAME=kubelet; . "$1" 2>/dev/null; printf %s "${command_args:-}"' sh "${copy}")"
  [ "${got}" = "${BASE_ARGS} --container-runtime-endpoint=unix:///run/containerd/containerd.sock --node-ip=192.0.2.10" ] \
    && _ok "effect: env file present -> KUBELET_KUBEADM_ARGS appended after the pinned base set" \
    || _bad "effect: env file present -> KUBELET_KUBEADM_ARGS did not land: '${got}'"

  [ "${lf}" -eq 0 ]
}

echo "== kubelet join/TLS-bootstrap gate: ${KUBELET_INIT#${REPO}/} =="
[ -f "${KUBELET_INIT}" ] && ok "shared overlay ships specs/etc/init.d/kubelet" \
                         || { bad "specs/etc/init.d/kubelet missing"; echo "FAIL (${F})"; exit 1; }
[ -x "${KUBELET_INIT}" ] && ok "init script is executable" || bad "init script not executable"
check_script "${KUBELET_INIT}" yes || true

# ── shared-overlay uniqueness: no per-arch fork can diverge ──
forks="$(find "${REPO}"/specs-* -path '*/etc/init.d/kubelet' -print 2>/dev/null || true)"
[ -z "${forks}" ] \
  && ok "no per-arch specs-*/etc/init.d/kubelet fork exists (shared overlay is the single source)" \
  || bad "per-arch kubelet init fork(s) exist and can diverge from the fixed shared copy: ${forks}"

# ── both k8s builders install the kubelet service from ${SHARED_SPECS} ──
# x86: kubelet sits in the _base_svcs list cp'd from ${SHARED_SPECS}/etc/init.d;
# rpi5: kubelet sits in the cluster-node `for svc in containerd kubelet` loop.
grep -Eq '_base_svcs="[^"]*\bkubelet\b[^"]*"' "${REPO}/build-x86-host-stage4.sh" \
  && ok "x86 builder: kubelet in the shared init-script install list" \
  || bad "x86 builder: kubelet missing from the shared init-script install list"
grep -Eq '^[[:space:]]*for svc in [^;]*\bkubelet\b' "${REPO}/build-rpi5-stage4.sh" \
  && ok "rpi5 builder: kubelet in the shared init-script install loop" \
  || bad "rpi5 builder: kubelet missing from the shared init-script install loop"

# ── negative controls: each staged regression MUST turn the checker red ──
mutate() { # NAME SED_EXPR — stage a mutated copy, expect check_script to fail
  local name="$1" expr="$2"
  local m="${WORK}/mut-${name}"
  sed -e "${expr}" "${KUBELET_INIT}" > "${m}"
  if cmp -s "${m}" "${KUBELET_INIT}"; then
    bad "control[${name}]: mutation did not apply (sed expression matched nothing)"
    return
  fi
  if check_script "${m}" no; then
    bad "control[${name}]: checker stayed GREEN on a copy carrying the regression"
  else
    ok "control[${name}]: checker goes red on the staged regression"
  fi
}
mutate drop-bootstrap-flag 's| --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet\.conf||'
mutate drop-env-sourcing   's|^\([[:space:]]*\)\. /var/lib/kubelet/kubeadm-flags\.env|\1:|'
mutate drop-kubeadm-args   's|\${KUBELET_KUBEADM_ARGS:+ \${KUBELET_KUBEADM_ARGS}}||'
mutate comment-command-args 's|^command_args=|#command_args=|'
mutate revert-to-pre-48    's|^command_args=.*|command_args="--config=/var/lib/kubelet/config.yaml --kubeconfig=/etc/kubernetes/kubelet.conf --v=2"|'

echo "== kubelet join/TLS-bootstrap gate: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
