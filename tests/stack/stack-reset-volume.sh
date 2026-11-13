#!/usr/bin/env bash
# stack-reset-volume.sh — drop ONE service's data volume(s) and bring that service
# back empty, keeping every other volume, every image and the maven registry.
#
# WHY IT EXISTS (2026-11-12). The seed's UNMET DEPENDENCY for a Matrix lockout said
# "recreate the tuwunel volume", and nothing could: the only Studio action near it
# was 'Stop and clean', which also drops identity, every database, the ~28 built
# images and the private-maven registry, so the next start was a cold build of more
# than an hour. This is the targeted remedy the message now names:
#     make stack-reset-volume SVC=tuwunel
#
# WHAT IT DOES, in order (make has already run the ownership preflight):
#   1. finds SVC's container in the project; refuses when there is none (start the
#      stack with the knobs you use first — then the volumes are known, not guessed);
#   2. reads the NAMED volumes it mounts (anonymous volumes and bind mounts are left);
#      refuses when it has none (nothing to reset) or when another container of the
#      project also mounts one (it would lose its data too);
#   3. stops and removes SVC's container(s), removes those volumes, and starts SVC
#      again with `up -d --no-deps` (its dependencies are not touched).
# The re-seed is make's next step (stack-reset-volume), not this script's.
#
# Usage: stack-reset-volume.sh SVC -- <compose command and its -f/--profile flags...>
#   e.g. stack-reset-volume.sh tuwunel -- docker compose -f tests/stack/compose.local.yaml --profile social
# Env:   COMPOSE_PROJECT_NAME (default hugmesh-local), DOCKER (default docker)
# Guard: tests/stack/test-stack-reset-volume.sh
set -euo pipefail

ME=stack-reset-volume.sh
DOCKER="${DOCKER:-docker}"
PROJECT="${COMPOSE_PROJECT_NAME:-hugmesh-local}"
SVC="${1:-}"
[ -n "${SVC}" ] && [ "${2:-}" = "--" ] && [ $# -ge 3 ] || {
  echo "usage: ${ME} SVC -- <compose command...>   (make stack-reset-volume SVC=<service>)" >&2; exit 2; }
shift 2
case "${SVC}" in *[!A-Za-z0-9_.-]*) echo "${ME}: '${SVC}' is not a compose service name" >&2; exit 2 ;; esac

ids="$("${DOCKER}" ps -a -q --filter "label=com.docker.compose.project=${PROJECT}" \
        --filter "label=com.docker.compose.service=${SVC}")" || {
  echo "${ME}: docker could not list project ${PROJECT}. Nothing was changed." >&2; exit 1; }
if [ -z "${ids}" ]; then
  echo "${ME}: project ${PROJECT} has no '${SVC}' container. Start the stack with the knobs" >&2
  echo "  you normally use (e.g. make stack-up SOCIAL=1 for tuwunel) and retry. Nothing was changed." >&2
  exit 3
fi

vols=""
for id in ${ids}; do
  v="$("${DOCKER}" inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "${id}")"
  for name in ${v}; do
    case "${name}" in "${PROJECT}_"*) ;; *) continue ;; esac   # anonymous / foreign: not ours to drop
    case " ${vols} " in *" ${name} "*) ;; *) vols="${vols:+${vols} }${name}" ;; esac
  done
done
if [ -z "${vols}" ]; then
  echo "${ME}: '${SVC}' mounts no named volume of ${PROJECT}: it keeps no data to reset. Nothing was changed." >&2
  exit 3
fi

for name in ${vols}; do
  users="$("${DOCKER}" ps -a -q --filter "volume=${name}")"
  for u in ${users}; do
    case " ${ids//$'\n'/ } " in *" ${u} "*) continue ;; esac
    other="$("${DOCKER}" inspect -f '{{.Name}}' "${u}" 2>/dev/null || echo "${u}")"
    echo "${ME}: volume ${name} is ALSO mounted by ${other#/}; resetting it would drop that" >&2
    echo "  container's data too. Stop it first, or reset that service instead. Nothing was changed." >&2
    exit 3
  done
done

echo "==> Resetting ${SVC}'s data in project ${PROJECT}: ${vols}"
echo "    (every other volume, the images and the maven registry are kept)"
"$@" stop "${SVC}"
"$@" rm -f "${SVC}"
for name in ${vols}; do
  "${DOCKER}" volume rm "${name}" >/dev/null
  echo "==> removed volume ${name}"
done
"$@" up -d --no-deps "${SVC}"
echo "==> ${SVC} is back with EMPTY data."
