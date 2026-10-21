#!/usr/bin/env bash
# draft.sh REPO ISSUE — one draft job: the local model drafts a fix for one issue in a
# scratch worktree of the repository's origin/main. Never pushes. Run by
# `scripts/local-ai.sh draft` and by the worker.
#
# Steps, in order, each leaving its result in $STATE/drafts/REPO-ISSUE/STATUS:
#   1. the issue text WITH its comments is fetched here, with the person's own gh login
#      (the model step never calls gh);
#   2. the loopback Ollama is started if it is down;
#   3. a scratch worktree of origin/main is made under $STATE/scratch and removed at the
#      end (it registers in the source checkout's .git while it exists);
#   4. draft.py runs under `env -i` with PATH, HOME, LANG, TERM and a loopback
#      OLLAMA_HOST only.
# AGENT=plain (default) | opencode | <a name agent-explicit.sh accepts>; LOCAL_AI_MODEL;
# HUGMESH_REPOS_ROOT (the folder holding the hugmesh-* checkouts; default: the folder
# that holds this one); TODO_TIMEOUT seconds (default 1500).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_local-ai-lib.sh
. "$HERE/_local-ai-lib.sh"

REPO="${1:-}"
N="${2:-}"
la_valid_repo "$REPO" && la_valid_num "$N" || { echo "usage: draft.sh REPO ISSUE_NUMBER" >&2; exit 2; }
AGENT="${AGENT:-plain}"
la_dirs
OUT=$LA_DIR/drafts/$REPO-$N
SCRATCH=$LA_DIR/scratch/$REPO-$N
mkdir -p "$OUT"
# Emptied on every run so an old diff can never sit beside a new status.
: >"$OUT/agent.log"
: >"$OUT/draft.diff"
status() { printf '%s\n' "$*" >"$OUT/STATUS"; }
note() { printf '[%s] %s\n' "$(date +%T)" "$*" >>"$OUT/agent.log"; }
status running
# Who is doing this draft. The Studio lists a draft as running only while this pid is a
# live draft.sh, so a draft killed in the middle is never shown as work in progress.
echo $$ >"$OUT/draft.pid"
TPID=0
# A stop (SIGTERM from the worker, Ctrl-C) ends the model step too and leaves a STATUS
# that says so. timeout puts its child in a process group of its own, so the group kill
# the worker sends does not reach it: it is signalled here, by pid.
interrupted() {
  trap - TERM INT HUP
  if [ "$TPID" -gt 0 ]; then kill -TERM "$TPID" 2>/dev/null; wait "$TPID" 2>/dev/null; fi
  # A finished result (the signal arrived just after it was written) is left alone.
  case "$(head -c 7 "$OUT/STATUS" 2>/dev/null)" in
    running) status "interrupted stopped before it finished; run it again" ;;
  esac
  exit 143
}
trap interrupted TERM INT HUP
trap 'rm -f "$OUT/draft.pid"' EXIT

if ! la_gh issue view "$N" --repo "$LA_ORG/$REPO" --json title,body,comments \
     | python3 "$HERE/issues.py" render >"$OUT/issue.md" 2>>"$OUT/agent.log"; then
  status "no-issue gh could not read $LA_ORG/$REPO#$N (is gh installed and signed in?)"
  exit 1
fi

if ! host=$(la_host 2>>"$OUT/agent.log"); then
  status "no-ollama OLLAMA_HOST is not a loopback address"
  exit 2
fi
if ! "$LA_SELF" up >>"$OUT/agent.log" 2>&1; then
  status "no-ollama Ollama is not answering on $host; see docs/LOCAL-AI-ASSISTANT.md"
  exit 2
fi

ROOT=${HUGMESH_REPOS_ROOT:-$(dirname "$LA_GEN")}
SRC=$ROOT/$REPO
if [ ! -e "$SRC/.git" ]; then
  status "no-checkout $SRC is not a git checkout; set HUGMESH_REPOS_ROOT to the folder that holds the hugmesh-* checkouts"
  exit 3
fi
la_git_fetch "$SRC" || note "git fetch failed; drafting from the last fetched origin"
BASE=$(git -C "$SRC" symbolic-ref -q --short refs/remotes/origin/HEAD) || BASE=origin/main
if ! git -C "$SRC" rev-parse -q --verify "$BASE^{commit}" >/dev/null; then
  status "no-checkout $SRC has no $BASE"
  exit 3
fi

# Only OUR scratch entry is ever touched. No `git worktree prune`: it would also drop the
# registration of any other worktree of this checkout whose folder is missing right now
# (an unmounted or remounted path, say), and this checkout belongs to the person.
cleanup() {
  git -C "$SRC" worktree remove --force "$SCRATCH" >/dev/null 2>&1
  rm -rf "$SCRATCH"
}
trap 'cleanup; rm -f "$OUT/draft.pid"' EXIT
cleanup
# -f: a scratch folder that a crashed run left registered but missing is taken over
if ! git -C "$SRC" worktree add -f --detach "$SCRATCH" "$BASE" >>"$OUT/agent.log" 2>&1; then
  status "error could not make a scratch worktree of $BASE"
  exit 3
fi
note "scratch worktree $SCRATCH at $(git -C "$SCRATCH" rev-parse --short HEAD) ($BASE)"

# HUGMESH_AGENT_CONTEXT: the project-context file written when the worker started
# (studio core/agent_context.py: by the Studio with its mesh's domains, or by
# `local-ai.sh start` without). It is written AGAIN here, right before this agent, from
# the inputs saved beside it, so the checkouts and code folders it lists are the ones on
# disk now. A failed refresh keeps the last file. draft.py hands its text to the agent.
if [ -n "${HUGMESH_AGENT_CONTEXT:-}" ]; then
  la_ctx refresh "$HUGMESH_AGENT_CONTEXT" >>"$OUT/agent.log" 2>&1 \
    || note "the project-context file could not be refreshed; the agent gets the last one"
fi
timeout "${TODO_TIMEOUT:-1500}" env -i PATH="$PATH" HOME="$HOME" LANG="${LANG:-C.UTF-8}" TERM=dumb \
  OLLAMA_HOST="$host" HUGMESH_AGENT_CONTEXT="${HUGMESH_AGENT_CONTEXT:-}" \
  python3 "$HERE/draft.py" --repo "$REPO" --issue "$N" --out "$OUT" --work "$SCRATCH" \
    --model "$LA_MODEL" --agent "$AGENT" --timeout "${TODO_TIMEOUT:-1500}" >>"$OUT/agent.log" 2>&1 </dev/null &
TPID=$!
wait "$TPID"
rc=$?
TPID=0
case "$(head -c 7 "$OUT/STATUS" 2>/dev/null)" in
  running) status "error the draft step ended without a result (exit $rc; see agent.log)"; exit 1 ;;
esac
exit "$rc"
