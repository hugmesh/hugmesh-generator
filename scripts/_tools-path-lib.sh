#!/usr/bin/env bash
# _tools-path-lib.sh — make operator-installed pinned tools findable from a plain
# terminal, not only from inside the Studio.
#
# THE PROBLEM. The Studio downloads the tools it pins (today: kind) into
#   ~/.local/share/hugmesh-studio/tools/bin
# and prepends that directory to PATH for its OWN child processes. Nothing else
# does. So `make kind-up` or `bash scripts/kind-load-images.sh` from a terminal
# dies with
#     missing required tool: kind
# on a machine where kind IS installed and where the Studio uses it happily. That
# message is actively misleading: it reads as "kind is not installed" and sends the
# reader off to install a SECOND copy, at whatever version upstream ships today,
# which is then the one a terminal run uses while the Studio keeps using its pin.
# Two kinds at two versions is a worse state than the missing-tool error.
#
# APPEND, NEVER PREPEND. If the operator already has the tool on PATH, that is an
# explicit choice and it must keep winning; this is a FALLBACK for the case where
# the only copy is the Studio's. Prepending would silently override a deliberate
# system install, which is the same class of surprise this exists to remove.
#
# Idempotent: sourcing twice does not grow PATH. Existence-guarded: a machine with
# no Studio install is untouched. HUGMESH_TOOLS_BIN overrides the location.

hugmesh_tools_path() {
  local d="${HUGMESH_TOOLS_BIN:-${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}/hugmesh-studio/tools/bin}"
  [ -d "${d}" ] || return 0
  case ":${PATH}:" in
    *":${d}:"*) return 0 ;;   # already there — do not grow PATH on re-source
  esac
  PATH="${PATH}:${d}"
  export PATH
}
