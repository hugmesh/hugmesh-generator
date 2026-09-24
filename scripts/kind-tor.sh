#!/usr/bin/env bash
# kind-tor.sh — a HOST tor daemon that publishes the kind lane's front door as a
# v3 .onion (hugmesh-generator#577, operator decision 67 = B, 2026-09-23).
#
# WHAT IT DOES. The kind node container publishes ingress-nginx-internal's :443 on
# the host as 127.0.0.1:8443 and its :80 as 127.0.0.1:8080
# (specs/cluster/bootstrap/kind-local/kind-local.yaml extraPortMappings). This
# script runs the distro `tor` binary AS THE INVOKING USER — no sudo, no system
# service, no /etc/tor — with a private DataDirectory and HiddenServiceDir under
# the gitignored tests/stack/.run/kind-tor/, and publishes
#
#     HiddenServicePort 443 127.0.0.1:8443    the TLS door (same shape as the node
#                                             contract, specs/usr/sbin/hugmesh-tor-reconcile)
#     HiddenServicePort 80  127.0.0.1:8080    the plain door; kind's fe-gateway
#                                             Ingress force-ssl-redirects it to https://<onion>/
#
# then admits the minted onion on the fe-gateway Ingress by appending ONE helm
# parameter, `ingress.extraHosts[N]=<onion>`, to the ArgoCD Application
# hugmesh-gateway-fe — N being the length of the extraHosts list the Application's
# own values already carry, so `*.hugmesh.net` (index 0 today) is kept. Without
# that rule ingress-nginx answers a request whose Host is the onion from its
# default server (404) before the gateway ever sees it.
#
# THE PATCH IS READ-MODIFY-WRITE, NEVER A LITERAL LIST. bootstrap-kind.sh patches
# spec.source.helm.parameters with `--type merge`, which REPLACES the list
# wholesale (bootstrap-kind.sh, the comment above GW_FE_PARAMS). A literal list
# here would silently drop `ingress.className=nginx-internal` (nothing routes),
# force-ssl-redirect, and MFA=1's `mfa.enabled`. So the live list is read, any
# earlier onion extraHost THIS script wrote is dropped, the current one is
# appended, and the whole list is written back in one patch. `down` reverses it
# the same way.
#
# WHAT IT DOES NOT DO.
#   * It never creates, deletes or restarts the cluster (`make kind-up` does).
#   * It never runs sudo and never touches /etc, /var/lib/tor or a system tor.
#   * It never trusts a hostname file on its own: `status`/`onion` answer only
#     while THIS tor (pidfile + /proc cmdline naming THIS torrc) is alive — a
#     leftover hostname is exactly the stale-onion trap hugmesh-generator#581
#     found on the compose lane.
#   * It does not map the onion to a domain at the gateway. hugmesh-gateway#38
#     (PR #39) fails an unmapped .onion CLOSED only once onion tenancy is
#     configured (APP_TENANCY_HOSTS_FILE set, or a literal onion in
#     APP_TENANCY_HOSTS). kind sets neither, so the gateway's DomainRegistry still
#     maps this onion to DEFAULT_DOMAIN, which is what makes this door serve the
#     primary domain. The day hugmesh-generator#582's writer sets that file on kind,
#     the kind onion needs an `<onion>=default` line too (recorded on #577).
#
# THE CERTIFICATE. The Ingress carries no TLS block on kind, so ingress-nginx
# answers :443 with its own default certificate — not one for the onion. Tor
# Browser shows a certificate warning on https://<onion>/; Playwright runs with
# ignoreHTTPSErrors (tests/e2e/playwright.config.ts). An onion address is already
# self-authenticating, so this is a warning about the name, not about the channel.
#
# Usage:
#   scripts/kind-tor.sh up       [--dry-run]   start tor (idempotent), admit the onion, probe it
#   scripts/kind-tor.sh down     [--dry-run]   stop tor, drop the onion extraHost (keys KEPT)
#   scripts/kind-tor.sh status                 exit 0 only if THIS tor is alive and the Ingress admits it
#   scripts/kind-tor.sh onion                  print the onion, refusing when this tor is not alive
#   scripts/kind-tor.sh socks                  print socks5://127.0.0.1:<port> for the client side
#                                              (the RUNNING tor's port when one is up)
#   scripts/kind-tor.sh torrc                  print the torrc this script writes (pure; starts nothing)
#   scripts/kind-tor.sh params <onion> [--remove]
#                                              read the Application JSON on stdin, print the helm
#                                              parameters list the patch would write (pure)
#
# Env (all optional):
#   KIND_TOR_STATE_DIR   default <repo>/tests/stack/.run/kind-tor (gitignored)
#   KIND_TOR_SOCKS_PORT  default 9052 — NOT 9050, which a system tor or the compose
#                        lane's tor client may hold; a busy port is refused, never shared
#   KIND_TOR_WAIT        seconds `up` waits for the onion to answer (default 300)
#   KIND_TOR_INGRESS_WAIT seconds `up` waits for the Ingress to list the onion (default 300)
#   KIND_CLUSTER_NAME    default hugmesh-local; kubectl always runs with
#                        --context kind-${KIND_CLUSTER_NAME}, so this can never patch
#                        whatever cluster the current context happens to name
#   ARGOCD_NS            default devops (bootstrap-kind.sh's value)
#   TOR_BIN              default: `command -v tor`
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${KIND_TOR_STATE_DIR:-${REPO_ROOT}/tests/stack/.run/kind-tor}"
SOCKS_PORT="${KIND_TOR_SOCKS_PORT:-9052}"
WAIT_S="${KIND_TOR_WAIT:-300}"
INGRESS_WAIT_S="${KIND_TOR_INGRESS_WAIT:-300}"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-hugmesh-local}"
KCTX="kind-${CLUSTER_NAME}"
ARGOCD_NS="${ARGOCD_NS:-devops}"
GW_APP="hugmesh-gateway-fe"
GW_NS="hugmesh-frontend"
GW_INGRESS="hugmesh-fe-gateway"

# THE DOORS. Both are host-side ends of kind-local.yaml's extraPortMappings
# (containerPort 443 -> hostPort 8443, 80 -> 8080). tests/scripts/test-kind-tor.sh
# reads that file and fails when these stop matching it, and pins the rendered
# torrc line itself, so neither can drift on its own.
HTTPS_DOOR="127.0.0.1:8443"
HTTP_DOOR="127.0.0.1:8080"

DATA_DIR="${STATE_DIR}/data"
HS_DIR="${STATE_DIR}/hs"
TORRC="${STATE_DIR}/torrc"
PIDFILE="${STATE_DIR}/tor.pid"
TOR_LOG="${STATE_DIR}/tor.log"

ONION_RE='^[a-z2-7]{56}\.onion$'

log()  { printf '==> kind-tor: %s\n' "$*" >&2; }
die()  { printf 'kind-tor: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '/^# Usage:/,/^# Env/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

valid_onion() { [[ "$1" =~ ${ONION_RE} ]]; }

render_torrc() {
  cat <<EOF
# Written by scripts/kind-tor.sh — regenerated on every \`make kind-tor\`.
# A USER-run tor (no sudo, no User directive) fronting the kind node's host ports.
DataDirectory ${DATA_DIR}
PidFile ${PIDFILE}
RunAsDaemon 1
Log notice file ${TOR_LOG}
ControlPort 0
# Loopback only: the e2e browser and curl reach the onion through this.
SocksPort 127.0.0.1:${SOCKS_PORT}
HiddenServiceDir ${HS_DIR}
HiddenServiceVersion 3
# 443 -> the kind node's TLS door (ingress-nginx-internal :443 via kind-local.yaml).
HiddenServicePort 443 ${HTTPS_DOOR}
# 80 -> the kind node's plain door; the fe-gateway Ingress force-ssl-redirects it.
HiddenServicePort 80 ${HTTP_DOOR}
EOF
}

# params <onion> [--remove] — Application JSON on stdin -> the full parameters
# list (JSON array) the patch writes. Pure; the only place the list is computed.
params_for() {
  local onion="$1"
  local mode="${2:-add}"
  ONION="${onion}" MODE="${mode}" ONION_RE="${ONION_RE}" python3 -c '
import json, os, re, sys
import yaml
app = json.load(sys.stdin)
helm = ((app.get("spec") or {}).get("source") or {}).get("helm") or {}
params = list(helm.get("parameters") or [])
values = yaml.safe_load(helm.get("values") or "") or {}
base = ((values.get("ingress") or {}).get("extraHosts")) or []
if not isinstance(base, list):
    sys.exit("ingress.extraHosts in the Application values is not a list: %r" % (base,))
idx_re = re.compile(r"^ingress\.extraHosts\[(\d+)\]$")
onion_re = re.compile(os.environ["ONION_RE"])
kept = []
for p in params:
    m = idx_re.match(p.get("name", ""))
    if m and onion_re.match(str(p.get("value", ""))):
        continue            # an onion extraHost this script wrote earlier: drop it
    if m and int(m.group(1)) >= len(base):
        # Someone else appended past the values list. Refuse rather than guess an
        # index: two writers on one list index is how an entry silently vanishes.
        sys.exit("refusing: parameter %s=%s already extends ingress.extraHosts "
                 "past its %d committed entries" % (p["name"], p.get("value"), len(base)))
    kept.append(p)
if os.environ["MODE"] == "add":
    kept.append({"name": "ingress.extraHosts[%d]" % len(base),
                 "value": os.environ["ONION"]})
print(json.dumps(kept))
'
}

kc() { kubectl --context "${KCTX}" "$@"; }

# tor_pid — prints the pid of THIS script's tor and returns 0, or returns 1.
tor_pid() {
  local pid
  [ -s "${PIDFILE}" ] || return 1
  pid="$(tr -dc '0-9' < "${PIDFILE}")"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  # The pid must be a tor started with OUR torrc: a recycled pid, or another
  # user's tor, must not count as ours.
  tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -aF -- "${TORRC}" >/dev/null || return 1
  printf '%s\n' "${pid}"
}

current_onion() {
  local o
  [ -s "${HS_DIR}/hostname" ] || return 1
  o="$(tr -d '[:space:]' < "${HS_DIR}/hostname")"
  valid_onion "${o}" || return 1
  printf '%s\n' "${o}"
}

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# live_socks_port — the SOCKS port the RUNNING tor was started with (its torrc), so
# a changed KIND_TOR_SOCKS_PORT cannot make `socks`/`up` name a port nothing serves.
live_socks_port() {
  local p
  p="$(awk '$1=="SocksPort"{print $2; exit}' "${TORRC}" 2>/dev/null)"
  p="${p##*:}"
  [ -n "${p}" ] || return 1
  printf '%s\n' "${p}"
}

cmd_socks() {
  local p
  if tor_pid >/dev/null && p="$(live_socks_port)"; then
    printf 'socks5://127.0.0.1:%s\n' "${p}"
  else
    printf 'socks5://127.0.0.1:%s\n' "${SOCKS_PORT}"
  fi
}

ingress_hosts() {
  kc -n "${GW_NS}" get ingress "${GW_INGRESS}" -o jsonpath='{.spec.rules[*].host}' 2>/dev/null
}

patch_params() { # <onion> <add|remove>
  local app list
  app="$(kc -n "${ARGOCD_NS}" get application "${GW_APP}" -o json)" \
    || die "cannot read Application ${ARGOCD_NS}/${GW_APP} on context ${KCTX} — is the kind lane up (make kind-up)?"
  list="$(printf '%s' "${app}" | params_for "$1" "$2")" || die "computing the helm parameters failed (see above)"
  kc -n "${ARGOCD_NS}" patch application "${GW_APP}" --type merge \
    -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":${list}}}}}" >/dev/null \
    || die "patching ${GW_APP}'s helm parameters failed"
  kc -n "${ARGOCD_NS}" annotate application "${GW_APP}" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

preflight_tools() {
  local b
  for b in python3 curl kubectl; do
    command -v "${b}" >/dev/null 2>&1 || die "${b} not on PATH"
  done
  python3 -c 'import yaml' 2>/dev/null || die "python3 cannot import yaml (PyYAML) — needed to read the Application's values"
  TOR_BIN="${TOR_BIN:-$(command -v tor || true)}"
  [ -n "${TOR_BIN}" ] && [ -x "${TOR_BIN}" ] || die "no tor binary (install net-vpn/tor, or set TOR_BIN=)"
}

cmd_up() {
  local dry="$1"
  local pid onion code i deadline live_port
  if [ -n "${dry}" ]; then
    echo "# DRY RUN — nothing is started, written or patched."
    echo "# state dir: ${STATE_DIR}"
    echo "# torrc that would be written to ${TORRC}:"
    render_torrc
    echo "# then: ${TOR_BIN:-tor} -f ${TORRC}   (as $(id -un), no sudo)"
    echo "# then: kubectl --context ${KCTX} -n ${ARGOCD_NS} patch application ${GW_APP} --type merge"
    echo "#         (live helm parameters + ingress.extraHosts[N]=<minted onion>; read-modify-write)"
    echo "# then: wait for ${GW_NS}/ingress ${GW_INGRESS} to list the onion, and"
    echo "#       curl --socks5-hostname 127.0.0.1:${SOCKS_PORT} -k https://<onion>/  (up to ${WAIT_S}s)"
    return 0
  fi
  preflight_tools
  kc get --raw /readyz >/dev/null 2>&1 \
    || die "kubectl context ${KCTX} does not answer — run 'make kind-up' first (this script never creates a cluster)"
  mkdir -p "${DATA_DIR}" "${HS_DIR}" || die "cannot create ${STATE_DIR}"
  chmod 0700 "${STATE_DIR}" "${DATA_DIR}" "${HS_DIR}"

  if pid="$(tor_pid)"; then
    log "tor already running for the kind lane (pid ${pid}) — reusing it"
    live_port="$(live_socks_port)" || die "the running tor's ${TORRC} names no SocksPort"
    if [ "${live_port}" != "${SOCKS_PORT}" ]; then
      log "that tor listens on SOCKS ${live_port}, not ${SOCKS_PORT}; using ${live_port} ('make kind-tor-down && make kind-tor' moves it)"
      SOCKS_PORT="${live_port}"
    fi
  else
    port_busy "${SOCKS_PORT}" \
      && die "127.0.0.1:${SOCKS_PORT} is already in use by something that is not this script's tor — set KIND_TOR_SOCKS_PORT="
    rm -f "${PIDFILE}"
    render_torrc > "${TORRC}"
    "${TOR_BIN}" --verify-config -f "${TORRC}" >/dev/null 2>&1 \
      || die "tor rejected ${TORRC}: run '${TOR_BIN} --verify-config -f ${TORRC}' to see why"
    "${TOR_BIN}" -f "${TORRC}" >/dev/null 2>&1 \
      || die "tor failed to start (see ${TOR_LOG})"
    for i in $(seq 1 30); do pid="$(tor_pid)" && break; sleep 1; done
    pid="$(tor_pid)" || die "tor did not stay up (see ${TOR_LOG})"
    log "tor started as $(id -un) (pid ${pid}); SOCKS on 127.0.0.1:${SOCKS_PORT}"
  fi

  deadline=$(( $(date +%s) + 120 ))
  until onion="$(current_onion)"; do
    [ "$(date +%s)" -lt "${deadline}" ] || die "no onion hostname in ${HS_DIR} after 120s (see ${TOR_LOG})"
    tor_pid >/dev/null || die "tor exited while minting the onion (see ${TOR_LOG})"
    sleep 1
  done
  log "onion: ${onion}"

  patch_params "${onion}" add
  log "admitted ${onion} on the fe-gateway Ingress (helm parameter ingress.extraHosts[N]); waiting for ArgoCD to render it"
  # The door is probed only once the Ingress SERVES the rule: before that,
  # ingress-nginx answers the onion Host from its default server (404), and any
  # status line would read as "the door answered".
  deadline=$(( $(date +%s) + INGRESS_WAIT_S ))
  until ingress_hosts | tr ' ' '\n' | grep -axF -- "${onion}" >/dev/null; do
    [ "$(date +%s)" -lt "${deadline}" ] \
      || die "the Ingress ${GW_NS}/${GW_INGRESS} still does not list ${onion} after ${INGRESS_WAIT_S}s — check 'kubectl --context ${KCTX} -n ${ARGOCD_NS} get application ${GW_APP}'"
    sleep "${KIND_TOR_POLL_S:-5}"
  done
  log "Ingress ${GW_NS}/${GW_INGRESS} admits ${onion}"

  # An onion descriptor takes tens of seconds to publish (tests/stack/tor-onion-e2e.sh
  # measured 118s on this host). ANY status line is the door answering; only a
  # transport failure is "not yet".
  deadline=$(( $(date +%s) + WAIT_S ))
  while :; do
    code="$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 60 \
              --socks5-hostname "127.0.0.1:${SOCKS_PORT}" "https://${onion}/" 2>/dev/null || true)"
    if [ -n "${code}" ] && [ "${code}" != "000" ]; then
      log "https://${onion}/ answered HTTP ${code} over Tor"
      break
    fi
    [ "$(date +%s)" -lt "${deadline}" ] \
      || die "https://${onion}/ never answered over Tor within ${WAIT_S}s (tor log: ${TOR_LOG}); tor is left running — 'make kind-tor-down' stops it"
    sleep "${KIND_TOR_POLL_S:-6}"
  done
  printf '%s\n' "${onion}" > "${STATE_DIR}/onion"
  cat <<EOF
kind onion door is UP
  onion:  ${onion}
  socks:  socks5://127.0.0.1:${SOCKS_PORT}
  try:    curl --socks5-hostname 127.0.0.1:${SOCKS_PORT} -k -I https://${onion}/
  e2e:    make kind-e2e-tor
  stop:   make kind-tor-down
EOF
}

cmd_down() {
  local dry="$1"
  local pid onion i
  onion="$(current_onion || true)"
  if [ -n "${dry}" ]; then
    echo "# DRY RUN — nothing is stopped or patched."
    echo "# would stop: the tor whose pidfile is ${PIDFILE} and whose cmdline names ${TORRC}"
    echo "# would drop: ingress.extraHosts[N]=${onion:-<onion>} from ${ARGOCD_NS}/${GW_APP} (context ${KCTX})"
    echo "# would KEEP: ${HS_DIR} (the onion keys), so the next 'make kind-tor' publishes the same address"
    return 0
  fi
  if pid="$(tor_pid)"; then
    kill "${pid}" 2>/dev/null || true
    for i in $(seq 1 20); do kill -0 "${pid}" 2>/dev/null || break; sleep 0.5; done
    kill -0 "${pid}" 2>/dev/null && die "tor (pid ${pid}) did not exit on SIGTERM; left as is"
    log "tor (pid ${pid}) stopped"
  else
    log "no kind-lane tor running"
  fi
  rm -f "${PIDFILE}" "${STATE_DIR}/onion"
  if command -v kubectl >/dev/null 2>&1 && kc get --raw /readyz >/dev/null 2>&1; then
    patch_params "${onion:-x}" remove
    log "dropped the onion extraHost from ${GW_APP}"
  else
    log "context ${KCTX} does not answer — nothing to un-patch (a deleted cluster carries no parameter)"
  fi
}

cmd_status() {
  local pid onion hosts port rc=0
  if pid="$(tor_pid)"; then
    port="$(live_socks_port || echo "${SOCKS_PORT}")"
    echo "tor:     running (pid ${pid}), SOCKS 127.0.0.1:${port}"
  else echo "tor:     NOT running (no live pid in ${PIDFILE} naming ${TORRC})"; rc=1; fi
  if onion="$(current_onion)"; then echo "onion:   ${onion}"
  else echo "onion:   none minted in ${HS_DIR}"; rc=1; fi
  if [ -n "${onion:-}" ] && ! command -v kubectl >/dev/null 2>&1; then
    echo "ingress: UNCHECKED — kubectl is not on PATH, so whether the Ingress admits the onion is unknown"
    rc=1
  elif [ -n "${onion:-}" ]; then
    hosts="$(ingress_hosts || true)"
    if printf '%s\n' ${hosts} | grep -axF -- "${onion}" >/dev/null; then
      echo "ingress: ${GW_NS}/${GW_INGRESS} admits the onion"
    else
      echo "ingress: ${GW_NS}/${GW_INGRESS} does NOT admit the onion (re-run 'make kind-tor' — a 'make kind-up' rewrites the gateway's helm parameters)"
      rc=1
    fi
  fi
  return "${rc}"
}

cmd_onion() {
  local onion
  tor_pid >/dev/null || die "the kind-lane tor is not running — a leftover hostname is not a live door. Run 'make kind-tor'"
  onion="$(current_onion)" || die "tor is running but ${HS_DIR}/hostname holds no valid v3 onion yet"
  printf '%s\n' "${onion}"
}

sub="${1:-}"
[ $# -gt 0 ] && shift
DRY=""
case "${sub}" in
  up|down)
    case "${1:-}" in
      --dry-run) DRY=1 ;;
      "") ;;
      *) usage ;;
    esac ;;
esac
case "${sub}" in
  up)     cmd_up "${DRY}" ;;
  down)   cmd_down "${DRY}" ;;
  status) cmd_status ;;
  onion)  cmd_onion ;;
  socks)  cmd_socks ;;
  torrc)  render_torrc ;;
  params)
    [ $# -ge 1 ] || usage
    target="$1"
    mode=add
    [ "${2:-}" = "--remove" ] && mode=remove
    if [ "${mode}" = add ] && ! valid_onion "${target}"; then
      die "refusing '${target}': not a v3 onion hostname (56 base32 chars + .onion)"
    fi
    params_for "${target}" "${mode}" ;;
  *) usage ;;
esac
