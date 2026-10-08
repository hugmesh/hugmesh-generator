#!/usr/bin/env bash
# worker.sh — runs queued local-model jobs one at a time. Started detached by
# `scripts/local-ai.sh worker`, or by hand in any terminal multiplexer:
#   scripts/local-ai.sh worker --foreground
#
# A job is a small file in $STATE/queue/pending holding one line: `draft REPO ISSUE`.
# It moves to queue/running while it works and its result lands in queue/done as
# <name>.result (exit code, seconds, the job line). Anything else on that line is
# refused: the queue is not a way to run arbitrary commands.
#
# Every few seconds the worker rewrites $STATE/status.json (pid, heartbeat, whether
# Ollama answers, the model loaded, the job in hand) through the Studio's own reader
# module, so the shell, the Studio window and the terminal UI all read one truth. On
# SIGTERM (`scripts/local-ai.sh stop`) the job in hand goes back to pending.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_local-ai-lib.sh
. "$HERE/_local-ai-lib.sh"
la_dirs

PIDFILE=$LA_DIR/worker.pid
if other=$(la_worker_pid) && [ "$other" != "$$" ]; then
  echo "worker already running (pid $other)"
  exit 0
fi
echo $$ >"$PIDFILE"

CHILD=0
CURRENT=""
beat() { la_py write-status "$$" "$CURRENT" >/dev/null 2>&1; }

finish() {
  trap - EXIT
  if [ "$CHILD" -gt 0 ]; then
    kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
    wait "$CHILD" 2>/dev/null
  fi
  # Hand the job in hand back: it was not finished, and a stranded file under running/
  # would read as work in progress for ever.
  if [ -n "$CURRENT" ] && [ -f "$LA_DIR/queue/running/$CURRENT" ]; then
    # The draft it was working on goes back to "queued" with the job, so the Studio does
    # not list it as running and `todo` does not take it for finished.
    read -r -a held <"$LA_DIR/queue/running/$CURRENT"
    if [ "${#held[@]}" -eq 3 ] && [ "${held[0]}" = "draft" ] && la_valid_repo "${held[1]}" && la_valid_num "${held[2]}" \
       && [ -f "$LA_DIR/drafts/${held[1]}-${held[2]}/STATUS" ]; then
      case "$(head -c 40 "$LA_DIR/drafts/${held[1]}-${held[2]}/STATUS" | cut -d' ' -f1)" in
        running|interrupted) echo queued >"$LA_DIR/drafts/${held[1]}-${held[2]}/STATUS" ;;
      esac
    fi
    mv "$LA_DIR/queue/running/$CURRENT" "$LA_DIR/queue/pending/$CURRENT" 2>/dev/null
  fi
  rm -f "$PIDFILE"
  CURRENT=""
  la_py write-status 0 "" >/dev/null 2>&1      # pid 0: stopped on purpose
  echo "[$(date +%T)] worker stopped"
}
trap finish EXIT
trap 'exit 0' TERM INT

echo "[$(date +%T)] worker up (pid $$), state $LA_DIR"
while :; do
  beat
  job=$(ls -1 "$LA_DIR/queue/pending" 2>/dev/null | sort | head -n 1)
  if [ -z "$job" ]; then
    for _ in 1 2 3 4 5; do sleep 1; done
    continue
  fi
  mv "$LA_DIR/queue/pending/$job" "$LA_DIR/queue/running/$job" 2>/dev/null || continue
  CURRENT=$job
  line=$(head -n 1 "$LA_DIR/queue/running/$job")
  name=${job%.job}
  started=$SECONDS
  echo "[$(date +%T)] start $job: $line"
  read -r -a parts <<<"$line"        # no globbing: a job line is data
  if [ "${#parts[@]}" -eq 3 ] && [ "${parts[0]}" = "draft" ] \
     && la_valid_repo "${parts[1]}" && la_valid_num "${parts[2]}"; then
    "${LA_DETACH[@]}" "$LA_SELF" draft "${parts[1]}" "${parts[2]}" >"$LA_DIR/queue/logs/$name.log" 2>&1 </dev/null &
    CHILD=$!
    while kill -0 "$CHILD" 2>/dev/null; do
      beat
      for _ in 1 2 3 4 5; do kill -0 "$CHILD" 2>/dev/null || break; sleep 1; done
    done
    wait "$CHILD"
    rc=$?
    CHILD=0
  else
    echo "unsupported job line (only: draft REPO ISSUE)" >"$LA_DIR/queue/logs/$name.log"
    rc=64
  fi
  { echo "rc=$rc secs=$((SECONDS - started))"; echo "$line"; } >"$LA_DIR/queue/done/$name.result"
  rm -f "$LA_DIR/queue/running/$job"
  CURRENT=""
  echo "[$(date +%T)] done  $job rc=$rc"
done
