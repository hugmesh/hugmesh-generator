#!/usr/bin/env bash
# agent-explicit.sh AGENT MODEL BRIEF — the one place that may start a coding agent which
# is not the plain model-only draft. draft.py calls it ONLY when the person sets
# AGENT=<name> themselves; the default (plain) and AGENT=opencode never reach it.
# tests/scripts/test-local-ai-no-claude.sh lists this file as the single exemption from
# the rule that nothing under scripts/local-ai* may name the Claude program, and proves
# with a decoy on PATH that nothing else runs it.
set -u
[ "${1:-}" = "claude" ] || { echo "unknown AGENT '${1:-}': use plain (the default) or opencode" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "AGENT=claude was asked for but no claude command is installed" >&2; exit 2; }
# ollama launch points the program at the loopback Ollama; nothing is sent elsewhere.
exec ollama launch claude --model "$2" -- -p "$3"
