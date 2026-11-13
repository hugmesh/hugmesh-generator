#!/usr/bin/env bash
# stack-owner.sh — which checkout OWNS the local stack's compose project, and a
# preflight that refuses to drive it from any other one.
#
# WHY IT EXISTS (2026-11-12). compose.local.yaml pins `name: hugmesh-local`, so EVERY
# checkout or clone of this repo that runs `make stack-up` drives the SAME project:
# the same containers, the same named volumes. The credentials those volumes were
# initialised with live PER TREE, though: the repo-root .e2e-credentials (seeded
# into Casdoor, tuwunel and Mastodon) and tests/stack/.env (the Postgres roles). A
# second clone ran stack-up + stack-seed on 11-11, so its passwords went into the
# tuwunel/phpBB/Akkoma volumes; on 11-12 the operator's checkout started the same
# project and its seed died with "matrix user e2e-mod exists ... but logs in with
# neither this run's E2E_PASSWORD nor any previous value". Nothing recorded which
# tree owned the data and nothing refused the foreign one, so the only remedy left
# was a full clean (every volume, every image, the maven registry).
#
# WHAT IT CHECKS (`check`; every make target that creates, seeds or removes the
# project runs it FIRST, before .env is touched):
#   1. AGENT TREES. An agent/automation tree (a linked `git worktree`, or
#      HUGMESH_AGENT=1 in the environment) may not use the default project
#      hugmesh-local at all: it must run its own, e.g.
#      `COMPOSE_PROJECT_NAME=hugmesh-agent-<label> make stack-up`. (The host ports
#      are fixed, so the two cannot run side by side, but the data stays apart.)
#      STACK_WORKTREE_OK=1 overrides, for a person who really works from a worktree.
#   2. LIVE OWNER. compose labels every container it creates with
#      com.docker.compose.project.working_dir (<tree>/tests/stack) and
#      ...config_files. When an existing container of the project names another
#      tree, refuse and name it. Containers compose did not create (no
#      com.docker.compose.container-number label: a `docker run` of a stack image,
#      which inherits the project label) are ignored here; `make stack-clean`
#      sweeps them (stack-strays.sh).
#   3. RECORDED OWNER. Labels vanish with the containers (`stack-halt`), the volumes
#      do not. So a successful `up` records the tree in
#      ${XDG_STATE_HOME:-~/.local/state}/hugmesh/stack-owner/<project>; while any
#      volume of the project exists, a different tree is refused on that record.
#      down -v / clean drop the volumes and the record together (`forget`).
#   STACK_ADOPT_FOREIGN=1 overrides 2 and 3: you take the project over KNOWING that
#   its data was seeded with the other tree's credentials (copy them across, or
#   reset the data: `make stack-reset-volume SVC=<service>`).
#
# Usage: stack-owner.sh check [ACTION]   exit 0 ok, 3 refused, 1 docker could not answer
#        stack-owner.sh record           record THIS tree as the owner (after an up)
#        stack-owner.sh forget           drop the record (after the volumes are gone)
#        stack-owner.sh owner [SERVICE]  print the tree the project's live containers
#                                        (only SERVICE's, when given) belong to, if any
# Env:   COMPOSE_PROJECT_NAME / STACK_OWNER_PROJECT  the project (default hugmesh-local)
#        STACK_OWNER_TREE      this tree (default: the repo this script is in)
#        STACK_OWNER_STATE_DIR where records live
#        STACK_ADOPT_FOREIGN=1, STACK_WORKTREE_OK=1, HUGMESH_AGENT=1 (see above)
#        DOCKER                the docker CLI (default docker)
# Prints no secret: only paths, names and counts.
# Guard: tests/stack/test-stack-owner.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ME=stack-owner.sh
DOCKER="${DOCKER:-docker}"
DEFAULT_PROJECT=hugmesh-local
PROJECT="${STACK_OWNER_PROJECT:-${COMPOSE_PROJECT_NAME:-${DEFAULT_PROJECT}}}"
STATE_DIR="${STACK_OWNER_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/hugmesh/stack-owner}"
RECORD="${STATE_DIR}/${PROJECT}"

canon() { # canon <path> -> absolute, symlinks resolved where they exist
  local p="$1"
  p="${p%/}"
  readlink -m -- "${p}" 2>/dev/null || printf '%s' "${p}"
}
TREE="$(canon "${STACK_OWNER_TREE:-$(cd "${HERE}/../.." && pwd -P)}")"

# tree_of <working_dir label> -> the repo root it belongs to (strip /tests/stack).
tree_of() {
  local w
  w="$(canon "$1")"
  case "${w}" in
    */tests/stack) printf '%s' "${w%/tests/stack}" ;;
    *) printf '%s' "${w}" ;;
  esac
}

is_true() { case "${1:-}" in 1|true|yes|TRUE|YES|True|Yes) return 0 ;; esac; return 1; }

is_agent_tree() { # sets AGENT_WHY
  AGENT_WHY=""
  if is_true "${HUGMESH_AGENT:-}"; then AGENT_WHY="HUGMESH_AGENT=1 is set"; return 0; fi
  local gd cd
  gd="$(git -C "${TREE}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  cd="$(git -C "${TREE}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  if [ "$(canon "${gd}")" != "$(canon "${cd}")" ]; then
    AGENT_WHY="${TREE} is a linked git worktree"
    return 0
  fi
  return 1
}

# CONTAINERS: "<working_dir>\t<container-number>\t<service>\t<config_files>" per
# container of the project, running or not. Exit 1 when docker cannot answer.
list_containers() {
  "${DOCKER}" ps -a --filter "label=com.docker.compose.project=${PROJECT}" \
    --format '{{.Label "com.docker.compose.project.working_dir"}}	{{.Label "com.docker.compose.container-number"}}	{{.Label "com.docker.compose.service"}}	{{.Label "com.docker.compose.project.config_files"}}'
}

list_volumes() {
  "${DOCKER}" volume ls -q --filter "label=com.docker.compose.project=${PROJECT}"
}

record_tree() { [ -f "${RECORD}" ] && sed -n 's/^tree=//p' "${RECORD}" | tail -1; return 0; }

cmd_owner() {
  local want="${1:-}" rows wd num svc cfg
  rows="$(list_containers 2>/dev/null)" || return 0
  while IFS=$'\t' read -r wd num svc cfg; do
    [ -n "${wd}" ] && [ -n "${num}" ] || continue
    [ -z "${want}" ] || [ "${svc}" = "${want}" ] || continue
    tree_of "${wd}"; echo
    return 0
  done <<< "${rows}"
  return 0
}

refuse() {
  echo "${ME}: REFUSED${ACTION:+ (${ACTION})}: $*" >&2
  exit 3
}

cmd_check() {
  ACTION="${1:-}"
  if [ "${PROJECT}" = "${DEFAULT_PROJECT}" ] && ! is_true "${STACK_WORKTREE_OK:-}" && is_agent_tree; then
    refuse "${AGENT_WHY}, and agent trees must not drive the operator's compose project '${DEFAULT_PROJECT}'.
  Its volumes hold the operator's data, seeded with the operator's own .e2e-credentials and
  tests/stack/.env; a stack-up/seed from here would re-seed or lock them out.
  Run your own project instead:   COMPOSE_PROJECT_NAME=hugmesh-agent-<label> make stack-up
  (the host ports are the same, so stop the other stack first), or set STACK_WORKTREE_OK=1
  if this is a person's own worktree and that is really intended."
  fi

  local rows
  if ! rows="$(list_containers 2>&1)"; then
    echo "${ME}: docker could not list the containers of project ${PROJECT}:" >&2
    printf '  %s\n' "${rows}" | head -3 >&2
    echo "  Start docker (or fix DOCKER_HOST / the docker context) and retry. Nothing was changed." >&2
    exit 1
  fi
  local wd num svc cfg owner foreign="" foreign_cfg="" n_foreign=0 n_own=0
  while IFS=$'\t' read -r wd num svc cfg; do
    [ -n "${wd}" ] && [ -n "${num}" ] || continue   # not compose-managed: stack-strays.sh
    owner="$(tree_of "${wd}")"
    if [ "${owner}" = "${TREE}" ]; then
      n_own=$((n_own + 1))
    else
      n_foreign=$((n_foreign + 1))
      case $'\n'"${foreign}"$'\n' in *$'\n'"${owner}"$'\n'*) ;; *) foreign="${foreign:+${foreign}$'\n'}${owner}"; foreign_cfg="${foreign_cfg:+${foreign_cfg}$'\n'}${cfg}" ;; esac
    fi
  done <<< "${rows}"

  if [ "${n_foreign}" -gt 0 ]; then
    if is_true "${STACK_ADOPT_FOREIGN:-}"; then
      echo "WARNING: ${ME}: STACK_ADOPT_FOREIGN=1 — taking over project ${PROJECT} from:" >&2
      printf '  %s\n' "${foreign}" >&2
      return 0
    fi
    refuse "${n_foreign} container(s) of compose project '${PROJECT}' belong to ANOTHER tree:
$(printf '    %s\n' "${foreign}")
  (compose files: $(printf '%s' "${foreign_cfg}" | tr '\n' ' '))
  This tree is ${TREE}. Its volumes were created and seeded from that tree, with
  THAT tree's .e2e-credentials and tests/stack/.env, so from here the seed and the
  databases cannot sign in. Do one of:
    * drive the stack from the tree that owns it (cd there, make ...);
    * stop it from there (make stack-halt keeps the data), then start it here only
      after its owner has run make stack-down, which drops its data; or
    * take it over knowingly: STACK_ADOPT_FOREIGN=1 make <target>, then copy that
      tree's .e2e-credentials and tests/stack/.env here, or reset the data one
      service at a time: make stack-reset-volume SVC=<service>."
  fi

  if [ "${n_own}" -eq 0 ]; then
    # No live container: the record is the only witness, and only while data is left.
    local vols rec
    if ! vols="$(list_volumes 2>&1)"; then
      echo "${ME}: docker could not list the volumes of project ${PROJECT}. Nothing was changed." >&2
      exit 1
    fi
    rec="$(record_tree)"
    if [ -z "${vols}" ]; then
      [ -z "${rec}" ] || rm -f "${RECORD}"   # nothing left to own: a stale record
      return 0
    fi
    if [ -n "${rec}" ] && [ "$(canon "${rec}")" != "${TREE}" ]; then
      if is_true "${STACK_ADOPT_FOREIGN:-}"; then
        echo "WARNING: ${ME}: STACK_ADOPT_FOREIGN=1 — adopting the halted data of ${rec}" >&2
        return 0
      fi
      refuse "project '${PROJECT}' has no containers, but $(printf '%s\n' "${vols}" | wc -l | tr -d ' ') volume(s)
  that were last brought up from ANOTHER tree (recorded in ${RECORD}):
    ${rec}$( [ -d "${rec}" ] || printf ' (that tree no longer exists)')
  This tree is ${TREE}. That data was seeded with the other tree's credentials.
  Start it from its owner, or take it over knowingly with STACK_ADOPT_FOREIGN=1
  (then copy that tree's .e2e-credentials and tests/stack/.env here, or reset the
  data: make stack-reset-volume SVC=<service>; make stack-down drops all of it)."
    fi
  fi
  return 0
}

case "${1:-}" in
  check)  shift; cmd_check "${1:-}" ;;
  owner)  shift; cmd_owner "${1:-}" ;;
  record)
    mkdir -p "${STATE_DIR}"
    tmp="$(mktemp "${RECORD}.tmp.XXXXXX")"
    printf 'tree=%s\nrecorded=%s\n' "${TREE}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${tmp}"
    mv -f "${tmp}" "${RECORD}"
    ;;
  forget) rm -f "${RECORD}" ;;
  *) echo "usage: ${ME} check [ACTION] | owner [SERVICE] | record | forget" >&2; exit 2 ;;
esac
