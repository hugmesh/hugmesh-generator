# shellcheck shell=bash
# _local-ai-lib.sh — helpers shared by scripts/local-ai.sh and the scripts beside it.
# Sourced, never run. Nothing here talks to anything but this machine, except the
# read-only `gh` and `git fetch` calls that bring an issue's text and the latest main.

LA_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LA_GEN=$(cd "$LA_LIB_DIR/../.." && pwd)
LA_SELF=$LA_GEN/scripts/local-ai.sh
# One state directory, read by the Studio too (studio/hugmesh_studio/core/local_ai_status.py
# resolves it by the same rule; the local-ai guard under tests/scripts checks they agree).
LA_DIR=${HUGMESH_LOCAL_AI_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hugmesh/local-ai}
LA_ORG=${LOCAL_AI_ORG:-hugmesh}
LA_MODEL=${LOCAL_AI_MODEL:-qwen3:8b}

la_die() { echo "local-ai: $*" >&2; exit 1; }

la_dirs() { mkdir -p "$LA_DIR"/queue/pending "$LA_DIR"/queue/running "$LA_DIR"/queue/done \
                     "$LA_DIR"/queue/logs "$LA_DIR"/drafts "$LA_DIR"/scratch; }

# The Studio's Qt-free core module, run as a command: status, prompt, chat, host, ping.
la_py() {
  PYTHONPATH="$LA_GEN/studio${PYTHONPATH:+:$PYTHONPATH}" python3 -m hugmesh_studio.core.local_ai_status "$@"
}

# The project-context module (studio core/agent_context.py), run as a command:
#   env -> HUGMESH_AGENT_CONTEXT=... and HUGMESH_REPOS_ROOT=... lines   root   refresh PATH
la_ctx() {
  PYTHONPATH="$LA_GEN/studio${PYTHONPATH:+:$PYTHONPATH}" python3 -m hugmesh_studio.core.agent_context "$@"
}

# Export the two variables every worker is started with. A caller that passed
# HUGMESH_AGENT_CONTEXT (the Studio, which wrote the file with its mesh's domains) keeps
# its file; otherwise the context is written now, without domains. Never fatal: a worker
# without a context still drafts.
la_worker_env() {
  local line
  local out
  out=$(la_ctx env 2>>"$LA_DIR/worker.log") || { echo "warning: no project context for the worker's agents (see $LA_DIR/worker.log)" >&2; return 0; }
  while IFS= read -r line; do
    case "$line" in
      HUGMESH_AGENT_CONTEXT=*|HUGMESH_REPOS_ROOT=*) export "${line?}" ;;
    esac
  done <<<"$out"
  return 0
}

# What a worker started now would run with, one NAME=value per line. worker.sh writes the
# same lines to $LA_DIR/worker.env when it starts, so `start` can tell a worker that runs
# with other settings (another Ollama, another context file or checkouts folder).
la_worker_signature() {
  local host
  local root
  host=$(la_host) || return 1
  root=${HUGMESH_REPOS_ROOT:-$(la_ctx root 2>/dev/null)}
  printf 'OLLAMA_HOST=%s\nHUGMESH_AGENT_CONTEXT=%s\nHUGMESH_REPOS_ROOT=%s\n' \
    "$host" "${HUGMESH_AGENT_CONTEXT:-$LA_DIR/HUGMESH-CONTEXT.md}" "$root"
}

# host:port of the Ollama to use. Fails (status 2, sentence on stderr) when OLLAMA_HOST is
# not a loopback address, so nothing below can be pointed at another machine.
la_host() { la_py host; }

la_valid_repo() {
  case "$1" in
    ""|-*|*..*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}
la_valid_num() { case "$1" in ""|*[!0-9]*) return 1 ;; esac; return 0; }

# The prefix that detaches a background command from the terminal and the shell that
# started it. It is a list, not a function, on purpose: the caller writes
#   "${LA_DETACH[@]}" cmd args >log 2>&1 </dev/null &
# so that $! is the pid of the command itself. Backgrounding a shell FUNCTION makes $! the
# pid of a wrapper subshell instead, and then a group kill (kill -- -$!) finds no such
# group and the pid files point at a process that is not the one doing the work.
if command -v setsid >/dev/null 2>&1; then LA_DETACH=(setsid); else LA_DETACH=(nohup); fi

# la_proc_is PID NEEDLE — PID is alive AND its command line contains NEEDLE. Process ids
# are reused, so a pidfile alone is not allowed to decide whether to signal anything.
la_proc_is() {
  local pid="$1"
  local needle="$2"
  local cmd
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    case "$cmd" in *"$needle"*) return 0 ;; *) return 1 ;; esac
  fi
  return 0
}

# The worker's pid when it is really running, else nothing and status 1.
la_worker_pid() {
  local pid
  pid=$(cat "$LA_DIR/worker.pid" 2>/dev/null) || return 1
  la_proc_is "$pid" "local-ai/worker.sh" || return 1
  echo "$pid"
}

# Read-only gh. The person's own login is used. A token left in the environment that gh
# rejects is retried once without it, so a stale GH_TOKEN does not look like "no issues".
la_gh() {
  local out
  command -v gh >/dev/null 2>&1 || return 127
  if out=$(gh "$@" 2>/dev/null); then printf '%s\n' "$out"; return 0; fi
  out=$(env -u GH_TOKEN -u GITHUB_TOKEN gh "$@" 2>/dev/null) || return 1
  printf '%s\n' "$out"
}

# Fetch origin for a checkout, quietly; false when the network or login refuses.
la_git_fetch() {
  GIT_TERMINAL_PROMPT=0 git -C "$1" fetch -q origin 2>/dev/null && return 0
  command -v gh >/dev/null 2>&1 || return 1
  GIT_TERMINAL_PROMPT=0 env -u GH_TOKEN -u GITHUB_TOKEN git -C "$1" -c credential.helper= \
    -c credential.helper='!gh auth git-credential' fetch -q origin 2>/dev/null
}

# Queue one draft job. Prints the job file name; does nothing when the same job is waiting.
la_enqueue_draft() {
  local repo="$1"
  local num="$2"
  local want="draft $repo $num"
  local f
  la_dirs
  # A job under running/ counts only while a live worker holds it; after a crash it is a
  # leftover that the next worker moves back to pending, so it must not stop a new job
  # from being queued.
  local watch=("$LA_DIR"/queue/pending/*.job)
  if la_worker_pid >/dev/null; then watch+=("$LA_DIR"/queue/running/*.job); fi
  for f in "${watch[@]}"; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f")" = "$want" ]; then echo "already queued: $(basename "$f")"; return 0; fi
  done
  f="$LA_DIR/queue/pending/$(date +%Y%m%d-%H%M%S)-draft-$repo-$num.job"
  printf '%s\n' "$want" >"$f"
  echo "queued $(basename "$f")"
}

# la_draft_stranded DIR — the draft in DIR says it is running or was interrupted, but no
# live draft.sh holds it. Such a draft is neither work in progress nor finished, so
# `todo` queues it again instead of skipping it as "already drafted".
la_draft_stranded() {
  local d="$1"
  local word
  word=$(head -c 40 "$d/STATUS" 2>/dev/null | cut -d' ' -f1)
  case "$word" in
    interrupted) return 0 ;;
    running) la_proc_is "$(cat "$d/draft.pid" 2>/dev/null)" "local-ai/draft.sh" && return 1; return 0 ;;
  esac
  return 1
}
