#!/usr/bin/env bash
# ============================================================================
# local-ai.sh — run work on a LOCAL model (Ollama on this machine) and watch it.
# ============================================================================
#
#   scripts/local-ai.sh up                     start the loopback Ollama if it is down
#   scripts/local-ai.sh start                  up + the queue worker, both detached
#   scripts/local-ai.sh status [--json]        server, model loaded, queue, drafts
#   scripts/local-ai.sh todo [N] [REPO...] [--watch] [--dry-run]
#                                              queue the N smallest open issues (default 6,
#                                              default repo hugmesh-generator) as draft jobs
#   scripts/local-ai.sh draft [--queue] REPO ISSUE
#                                              one draft job, now (or queued)
#   scripts/local-ai.sh queue                  what is waiting and running
#   scripts/local-ai.sh worker [--foreground]  the queue worker (detached by default)
#   scripts/local-ai.sh stop [--server]        stop the worker (and an Ollama we started)
#   scripts/local-ai.sh chat                   a prompt loop against the local model (grounded:
#                                              the HugMesh primer + the docs; /where PAGE)
#   scripts/local-ai.sh prompt TEXT...         one question, one answer (grounded, with Sources)
#   scripts/local-ai.sh docs [--page=SLUG] TEXT...   what the docs say, no model needed
#   scripts/local-ai.sh catalogue [domain|mesh|image]   every Studio option, from the code
#   scripts/local-ai.sh watch                  the live dashboard (refreshes every 5 s)
#
# The one line for a spare terminal:   scripts/local-ai.sh todo 6 --watch
#
# Everything runs on this machine. Draft jobs ask the model for a unified diff over the
# Ollama HTTP API, check it with `git apply --check` in a scratch worktree of origin/main
# and record STATUS applied / does-not-apply. Nothing the model writes is ever run, and
# nothing is pushed. AGENT=opencode runs a coding agent instead (only if its command is
# installed); see docs/LOCAL-AI-ASSISTANT.md, section 11.
#
# State (also read by the Studio's prompt dock):
#   ${HUGMESH_LOCAL_AI_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hugmesh/local-ai}
#     queue/{pending,running,done,logs}  drafts/<repo>-<n>/{issue.md,agent.log,draft.diff,STATUS}
#     status.json (the worker's heartbeat)  worker.pid  ollama.pid
#
# Environment: OLLAMA_HOST (loopback only; anything else is refused), LOCAL_AI_MODEL
# (default qwen3:8b), AGENT, HUGMESH_REPOS_ROOT, LOCAL_AI_ORG (default hugmesh).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=local-ai/_local-ai-lib.sh
. "$HERE/local-ai/_local-ai-lib.sh"

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d;s/^# \{0,1\}//'; }

cmd_up() {
  local host
  host=$(la_host) || exit 2
  if la_py ping; then echo "ollama is answering on $host"; return 0; fi
  if ! command -v ollama >/dev/null 2>&1; then
    echo "Ollama is not installed on this machine. Install it first: docs/LOCAL-AI-ASSISTANT.md, section 2." >&2
    return 1
  fi
  mkdir -p "$LA_DIR"
  # The settings docs/LOCAL-AI-ASSISTANT.md section 3 documents; the server listens on loopback only.
  OLLAMA_HOST=$host OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH:-32768} OLLAMA_FLASH_ATTENTION=1 \
    OLLAMA_KV_CACHE_TYPE=q8_0 "${LA_DETACH[@]}" ollama serve >"$LA_DIR/ollama-serve.log" 2>&1 </dev/null &
  # $! is ollama itself (the detach prefix execs it), so `stop --server` finds the right
  # process by name and ends the whole server, not a wrapper around it.
  echo $! >"$LA_DIR/ollama.pid"
  local _
  for _ in $(seq 1 30); do
    if la_py ping; then echo "ollama started on $host"; return 0; fi
    sleep 1
  done
  echo "Ollama did not answer on $host after 30 seconds (log: $LA_DIR/ollama-serve.log)" >&2
  return 1
}

# cmd_worker [--restart-if-changed] [--foreground]
# --restart-if-changed (what `start` passes): a worker that is already running but was
# started with another Ollama address, context file or checkouts folder is stopped and
# started again, so a changed choice (the Studio's system/Docker Ollama switch, say)
# reaches the drafts it runs. The job in hand goes back to the queue (worker.sh finish).
cmd_worker() {
  local pid
  local restart=0
  local want
  local have
  la_dirs
  if [ "${1:-}" = "--restart-if-changed" ]; then restart=1; shift; fi
  if [ "${1:-}" = "--foreground" ]; then la_worker_env; exec "$HERE/local-ai/worker.sh"; fi
  if pid=$(la_worker_pid); then
    if [ "$restart" = 0 ]; then echo "worker already running (pid $pid)"; return 0; fi
    want=$(la_worker_signature) || return 1
    have=$(cat "$LA_DIR/worker.env" 2>/dev/null)
    if [ "$want" = "$have" ]; then echo "worker already running (pid $pid)"; return 0; fi
    echo "the worker (pid $pid) runs with other settings; restarting it (a job in hand goes back to the queue)"
    echo "  was: $(printf '%s' "${have:-not recorded}" | tr '\n' ' ')"
    echo "  now: $(printf '%s' "$want" | tr '\n' ' ')"
    cmd_stop >/dev/null
    if pid=$(la_worker_pid); then
      echo "the worker (pid $pid) did not stop; it keeps its old settings" >&2
      return 1
    fi
  fi
  la_worker_env
  "${LA_DETACH[@]}" "$HERE/local-ai/worker.sh" >>"$LA_DIR/worker.log" 2>&1 </dev/null &
  local _
  for _ in $(seq 1 20); do
    if pid=$(la_worker_pid); then echo "worker started (pid $pid)"; return 0; fi
    sleep 0.5
  done
  echo "the worker did not start; see $LA_DIR/worker.log" >&2
  return 1
}

cmd_stop() {
  local pid
  local _
  if pid=$(la_worker_pid); then
    kill -TERM "$pid" 2>/dev/null
    for _ in $(seq 1 20); do la_proc_is "$pid" "local-ai/worker.sh" || break; sleep 0.5; done
    if la_proc_is "$pid" "local-ai/worker.sh"; then
      echo "worker (pid $pid) did not stop within 10 seconds" >&2
    else
      echo "worker stopped"
    fi
  else
    echo "no worker is running"
  fi
  if [ "${1:-}" = "--server" ]; then
    pid=$(cat "$LA_DIR/ollama.pid" 2>/dev/null)
    if la_proc_is "$pid" "ollama"; then
      kill -TERM "$pid" 2>/dev/null
      echo "stopped the Ollama this script started (pid $pid)"
    else
      echo "no Ollama started by this script is running; leaving any other one alone"
    fi
  fi
  return 0
}

cmd_queue() {
  local f
  la_dirs
  echo "pending: $(ls "$LA_DIR/queue/pending" | wc -l | tr -d ' ')  running: $(ls "$LA_DIR/queue/running" | wc -l | tr -d ' ')  done: $(ls "$LA_DIR/queue/done" | wc -l | tr -d ' ')"
  for f in "$LA_DIR"/queue/running/*.job; do [ -f "$f" ] && echo "  running  $(basename "$f")  $(head -n 1 "$f")"; done
  for f in "$LA_DIR"/queue/pending/*.job; do [ -f "$f" ] && echo "  pending  $(basename "$f")  $(head -n 1 "$f")"; done
  return 0
}

cmd_draft() {
  local queue=0
  if [ "${1:-}" = "--queue" ]; then queue=1; shift; fi
  la_valid_repo "${1:-}" && la_valid_num "${2:-}" || { echo "usage: local-ai.sh draft [--queue] REPO ISSUE_NUMBER" >&2; return 2; }
  if [ "$queue" = 1 ]; then la_enqueue_draft "$1" "$2"; return 0; fi
  exec "$HERE/local-ai/draft.sh" "$1" "$2"
}

cmd_todo() {
  local n=6 watch=0 dry=0 failed=0
  local repos=()
  local r json picks num size title queued=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --watch) watch=1 ;;
      --dry-run) dry=1 ;;
      -*) usage; return 2 ;;
      "") echo "todo: an empty argument; give a number of issues or a repository name" >&2; return 2 ;;
      *[!0-9]*) la_valid_repo "$1" || { echo "not a repository name: $1" >&2; return 2; }; repos+=("$1") ;;
      *) n=$1 ;;
    esac
    shift
  done
  if [ "${#repos[@]}" -eq 0 ]; then repos=(hugmesh-generator); fi
  la_dirs
  for r in "${repos[@]}"; do
    if ! json=$(la_gh issue list --repo "$LA_ORG/$r" --state open --limit 80 --json number,title,body,labels); then
      echo "could not list the open issues of $LA_ORG/$r with gh (is gh installed and signed in?)" >&2
      failed=1
      continue
    fi
    picks=$(printf '%s' "$json" | python3 "$HERE/local-ai/issues.py" pick "$n") || { failed=1; continue; }
    while IFS=$'\t' read -r num size title; do
      [ -n "$num" ] || continue
      # A draft that says "running" but has no live draft.sh behind it (the machine was
      # restarted, or it was killed) is not done: it is queued again, never skipped.
      if [ -e "$LA_DIR/drafts/$r-$num/STATUS" ] && ! la_draft_stranded "$LA_DIR/drafts/$r-$num"; then
        echo "skip $r#$num (already drafted or queued)"; continue
      fi
      if [ "$dry" = 1 ]; then echo "would queue $r#$num  $title"; continue; fi
      mkdir -p "$LA_DIR/drafts/$r-$num"
      printf '# %s\n' "$title" >"$LA_DIR/drafts/$r-$num/issue.md"
      echo queued >"$LA_DIR/drafts/$r-$num/STATUS"
      la_enqueue_draft "$r" "$num" >/dev/null
      echo "queued $r#$num  $title"
      queued=$((queued + 1))
    done <<<"$picks"
  done
  if [ "$queued" -gt 0 ]; then
    cmd_up || echo "warning: Ollama is not up, so the queued jobs will wait" >&2
    cmd_worker || true
  fi
  if [ "$watch" = 1 ]; then cmd_watch; fi
  return "$failed"
}

cmd_watch() {
  local every=${LOCAL_AI_INTERVAL:-5}
  echo "Ctrl-C leaves; the worker keeps going (scripts/local-ai.sh stop ends it)."
  if command -v watch >/dev/null 2>&1; then
    exec watch -t -n "$every" "bash '$LA_SELF' status"
  fi
  while :; do
    clear 2>/dev/null || printf '\n\n'
    date '+%F %T'
    "$LA_SELF" status
    sleep "$every"
  done
}

case "${1:-help}" in
  up)            shift; cmd_up "$@" ;;
  start)         cmd_up && cmd_worker --restart-if-changed; rc=$?; la_py status --brief; exit "$rc" ;;
  status)        shift; la_py status "$@" ;;
  todo)          shift; cmd_todo "$@" ;;
  draft)         shift; cmd_draft "$@" ;;
  queue)         shift; cmd_queue "$@" ;;
  worker)        shift; cmd_worker "$@" ;;
  stop)          shift; cmd_stop "$@" ;;
  chat)          shift; LOCAL_AI_GROUNDED=1 la_py chat ;;
  prompt)        shift; LOCAL_AI_GROUNDED=1 la_py prompt "$@" ;;
  docs)          shift; la_py docs "$@" ;;
  catalogue)     shift; la_py catalogue "$@" ;;
  watch)         shift; cmd_watch ;;
  help|-h|--help) usage ;;
  *)             echo "unknown command: $1" >&2; usage >&2; exit 2 ;;
esac
