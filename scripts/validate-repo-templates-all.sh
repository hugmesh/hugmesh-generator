#!/usr/bin/env bash
# ============================================================================
# validate-repo-templates-all.sh — the archetype drift gate over EVERY archetype.
# ============================================================================
#
# scripts/validate-repo-templates.sh grades ONE archetype per invocation, and for
# its whole life exactly one automated invocation existed: case B8 of
# tests/domain-registry/test-templating-rename-pr.sh, `--archetype generator`. The
# gate was wired into NO CI job at all, so the other five overlays rotted unwatched:
# the repair that took the tree from "3 drifts" to "0 drift" was scoped to
# `--archetype angular-mfe` only, and spring-bff / angular-host / remote-fragment
# each still carried a drift no pipeline could see.
#
# That matters because these are CLASS-A templates: the generator OVERWRITES them
# WHOLESALE in every rendered tenant, so a stale one silently strips content from
# every tenant on the next render — one earlier drift would have removed a 35-line
# i18n fleet invariant from every generated tenant.
#
# ENUMERATED, NEVER LISTED. The archetype set is whatever templates/archetypes/*/
# holds, so a seventh archetype is gated the day it lands, not the day someone
# remembers to extend a hardcoded list — a hardcoded list is how this gate came to
# cover one archetype in the first place.
#
# EVERY archetype runs. The first failure does NOT stop the sweep (a report that
# stops at the first drift is how the second one hides), and the exit status is
# non-zero if ANY archetype drifted OR could not be checked at all — an unrunnable
# gate is the same vacuous green as a missing one.
#
# Base resolution is per archetype, exactly as the single-archetype gate does it
# (pull-repo-base.sh from the exemplar member; <NAME>_BASE_DIR / GIT_BASE / GIT_REF
# / OFFLINE all still apply). The one default this adds: the `generator` archetype's
# exemplar member IS this repository, so its base defaults to THIS CHECKOUT rather
# than a fresh clone of the default branch — that is what makes the gate grade the
# change under review, and it is what case B8 already passes by hand.
#
# Usage:
#   scripts/validate-repo-templates-all.sh          # or: make template-drift-check
#
# Exit: 0 every archetype in sync; 1 at least one DRIFTED or could not be checked.
# BUILD-HOST ONLY (node + handlebars; see the node-not-root rule in
# docs/MESH-TEMPLATING.md).
set -uo pipefail

_die() { echo "[validate-repo-templates-all] FATAL: $*" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GATE="${SCRIPT_DIR}/validate-repo-templates.sh"
ARCH_ROOT="${REPO_ROOT}/templates/archetypes"

[[ -f "$GATE" ]]       || _die "missing the single-archetype gate: ${GATE}"
[[ -d "$ARCH_ROOT" ]]  || _die "no archetype overlays at ${ARCH_ROOT}"

ARCHETYPES=()
while IFS= read -r d; do ARCHETYPES+=("$(basename "$d")"); done \
  < <(find "$ARCH_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
[[ ${#ARCHETYPES[@]} -gt 0 ]] || _die "no archetype directories under ${ARCH_ROOT}"

# See the header: the generator's exemplar member is this repo itself.
export GENERATOR_BASE_DIR="${GENERATOR_BASE_DIR:-${REPO_ROOT}}"

echo "== archetype drift sweep: ${#ARCHETYPES[@]} archetype(s) from ${ARCH_ROOT} =="

RC=0
RESULTS=()
for a in "${ARCHETYPES[@]}"; do
  printf '\n───── archetype: %s ─────────────────────────────────────────\n' "$a"
  if bash "$GATE" --archetype "$a"; then
    RESULTS+=("PASS  ${a}")
  else
    rc=$?
    # 1 = drifted (the gate ran and bit); anything else = the gate could not run
    # (missing handlebars, unresolvable base, absent _identity.env). Both are RED.
    case "$rc" in
      1) RESULTS+=("DRIFT ${a}") ;;
      *) RESULTS+=("ERROR ${a} — gate exit ${rc}, it did not grade this archetype") ;;
    esac
    RC=1
  fi
done

printf '\n== archetype drift summary (%d archetype(s)) ==\n' "${#ARCHETYPES[@]}"
printf '  %s\n' "${RESULTS[@]}"
if [[ $RC -eq 0 ]]; then
  echo "RESULT: PASS — every archetype overlay is in sync with its exemplar base."
else
  echo "RESULT: FAIL — at least one archetype drifted or could not be checked." >&2
  echo "These are class-A templates: the generator overwrites them wholesale in every" >&2
  echo "rendered tenant, so a stale one strips content from every tenant on the next render." >&2
fi
exit "$RC"
