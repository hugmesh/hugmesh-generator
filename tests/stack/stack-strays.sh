#!/usr/bin/env bash
# stack-strays.sh — what carries the local stack's compose-project label but is
# invisible to `docker compose down -v --remove-orphans`, and (with --remove) gets
# rid of it.
#
# WHY IT EXISTS (2026-11-12). After the operator's `make stack-clean` two containers
# and three volumes of project hugmesh-local were still there:
#   * refute68-fe-main / refute68-fe-pr: an agent had `docker run` an image this
#     stack BUILT. The image's inherited labels say project=hugmesh-local,
#     service=hugmesh-fe-gateway, so they look like members, but compose did not
#     create them (no com.docker.compose.container-number / .oneoff label), so
#     `down` and `--remove-orphans` both skip them. They bind-mounted files from
#     another tree.
#   * hugmesh-local_synapse (pre-tuwunel), hugmesh-local_akkoma-static and
#     _akkoma-uploads: volumes of services no compose file declares any more, so
#     `down -v` never names them.
#
# DECLARED = every top-level `volumes:` key of every compose file this tree can
# pass (tests/stack/compose*.yaml and the Studio's generated .compose*.yaml), the
# union over EVERY profile and overlay on purpose: a volume a profile not passed
# today declares (an own-domain Casdoor, a Tor domain key) is never a stray.
#
# Usage: stack-strays.sh [--list]   report strays (read-only; the default)
#        stack-strays.sh --remove   remove stray containers and undeclared volumes
# Env:   COMPOSE_PROJECT_NAME / STACK_STRAYS_PROJECT  (default hugmesh-local)
#        STACK_STRAYS_COMPOSE_DIR  where the compose files are (default: this dir)
#        DOCKER                    the docker CLI (default docker)
# Exit 0 also when docker cannot answer (it says so): a report must never fail a stop.
# Guard: tests/stack/test-stack-strays.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME=stack-strays.sh
DOCKER="${DOCKER:-docker}"
PROJECT="${STACK_STRAYS_PROJECT:-${COMPOSE_PROJECT_NAME:-hugmesh-local}}"
DIR="${STACK_STRAYS_COMPOSE_DIR:-${HERE}}"
mode=list
case "${1:-}" in
  ""|--list) ;;
  --remove) mode=remove ;;
  *) echo "usage: ${ME} [--list|--remove]" >&2; exit 2 ;;
esac

declared_volumes() {
  local f
  for f in "${DIR}"/compose*.yaml "${DIR}"/.compose*.yaml; do
    [ -f "${f}" ] || continue
    awk '
      /^volumes:[[:space:]]*(#.*)?$/ { in_v = 1; next }
      in_v && /^[^[:space:]#]/ { in_v = 0 }
      in_v && match($0, /^  [A-Za-z0-9_.-]+:/) { v = substr($0, 3, RLENGTH - 3); print v }
    ' "${f}"
  done | sort -u
}

if ! ctrs="$("${DOCKER}" ps -a --filter "label=com.docker.compose.project=${PROJECT}" \
      --format '{{.ID}}	{{.Names}}	{{.Label "com.docker.compose.container-number"}}	{{.Label "com.docker.compose.oneoff"}}	{{.Label "com.docker.compose.service"}}	{{.Status}}' 2>&1)"; then
  echo "${ME}: docker could not list project ${PROJECT}'s containers; strays not checked." >&2
  exit 0
fi
if ! vols="$("${DOCKER}" volume ls --filter "label=com.docker.compose.project=${PROJECT}" \
      --format '{{.Name}}	{{.Label "com.docker.compose.volume"}}' 2>&1)"; then
  echo "${ME}: docker could not list project ${PROJECT}'s volumes; strays not checked." >&2
  exit 0
fi

declared="$(declared_volumes)"
n_c=0; n_v=0; failed=0
while IFS=$'\t' read -r id name num oneoff svc status; do
  [ -n "${id}" ] || continue
  [ -z "${num}" ] && [ -z "${oneoff}" ] || continue    # compose created it: down handles it
  n_c=$((n_c + 1))
  if [ "${mode}" = remove ]; then
    if "${DOCKER}" rm -f "${id}" >/dev/null 2>&1; then
      echo "==> removed stray container ${name} (label service=${svc:-?}, not created by compose)"
    else
      echo "${ME}: could not remove stray container ${name}" >&2; failed=1
    fi
  else
    echo "  stray container: ${name} (label service=${svc:-?}; ${status}) — compose did not create it, so down/--remove-orphans never touch it"
  fi
done <<< "${ctrs}"

while IFS=$'\t' read -r vname vkey; do
  [ -n "${vname}" ] || continue
  [ -n "${vkey}" ] || vkey="${vname#"${PROJECT}"_}"
  case $'\n'"${declared}"$'\n' in *$'\n'"${vkey}"$'\n'*) continue ;; esac
  n_v=$((n_v + 1))
  if [ "${mode}" = remove ]; then
    if "${DOCKER}" volume rm "${vname}" >/dev/null 2>&1; then
      echo "==> removed undeclared volume ${vname} (no compose file declares '${vkey}' any more)"
    else
      echo "${ME}: could not remove volume ${vname} (still in use?)" >&2; failed=1
    fi
  else
    echo "  undeclared volume: ${vname} — no compose file declares '${vkey}', so down -v never removes it"
  fi
done <<< "${vols}"

if [ "${mode}" = list ] && [ $((n_c + n_v)) -gt 0 ]; then
  echo "  (${n_c} stray container(s), ${n_v} undeclared volume(s) of project ${PROJECT}; make stack-clean removes them)"
fi
exit "${failed}"
