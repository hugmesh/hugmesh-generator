#!/usr/bin/env bash
# down.sh — stop the integration stack started by up.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${HERE}/.run"
for name in ui bff mastodon matrix; do
  pf="${RUN}/${name}.pid"
  if [ -f "${pf}" ]; then
    pid="$(cat "${pf}")"
    kill "${pid}" 2>/dev/null && echo "  stopped ${name} (pid ${pid})" || true
    rm -f "${pf}"
  fi
done
echo "stack down."
