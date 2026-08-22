#!/usr/bin/env bash
# ── JOB-channel image-spec parity smoke (NON-GATING) ─────────────────────────────
# The web/job build channel's core invariant (design 7.1), exercised end-to-end
# through the REAL worker entrypoint docker/build-image.sh:
#
#   With the IMAGE_SPEC_JSON channel active, the builder command build-image.sh
#   assembles for a materialized ImageConfig must equal the GUI-channel command
#   the Studio's own `--print-command` prints for that same config, PLUS exactly
#   the worker's operational/tenancy overlay (server-derived --cluster-domain,
#   BUILD_ID-derived -H, worker -w/-j/--env, and the single-artifact --no-*iso/
#   --no-tar policy) appended last. Because the stage4 builders parse repeated scalar
#   flags last-wins, that appended overlay authoritatively overrides the spec on
#   the overlap — which is how tenancy DOMAIN stays server-derived (I6) while every
#   other flag rides through unchanged. ONE flag-translation source, two surfaces.
#
# This is the JOB-channel twin of tests/build-matrix/worklist-smoke.sh. It is
# deliberately NOT wired into tests/build-matrix/check.sh (WS-BUILDER owns that
# file) — a developer smoke, promoted into the gating matrix only once stable.
#
# It drives build-image.sh's BUILD_IMAGE_SH_PRINT_ONLY dev/CI escape hatch, which
# assembles + prints the builder argv (framed by __BUILDER_ARGV_*__ markers, one
# token per line) and runs no build. That env var is NOT part of the admin-bff-api
# Job contract and must never be set by image-gen-job.yaml.
#
# Usage: tests/build-image-spec-parity.sh
#   PYTHON=/path/to/python   override the interpreter (default: python3; a venv
#                            python works — --print-command is Qt-free).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/.." && pwd)"
STUDIO="$GEN/studio"
BUILD_IMAGE_SH="$GEN/docker/build-image.sh"
PY="${PYTHON:-python3}"
PY_DIR="$(cd "$(dirname "$PY")" 2>/dev/null && pwd || true)"
export PYTHONPATH="$STUDIO${PYTHONPATH:+:$PYTHONPATH}"

# build-image.sh calls a BARE `python3` internally (--print-command). Make that
# resolve to the SAME interpreter this fixture uses, so both surfaces translate
# the spec identically (host detection, quoting, everything).
if [ -n "$PY_DIR" ] && [ -x "$PY_DIR/python3" ]; then
  export PATH="$PY_DIR:$PATH"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Deterministic worker inputs so the expected overlay is exact. DOMAIN differs
# from every spec's cluster_domain below, so a passing content-parity check also
# proves the server-derived --cluster-domain override (I6) is real, not a no-op.
BUILD_ID="ABC12345-de6-7890"
DOMAIN="tenant.example"
SPEC_DOMAIN="spec.example"        # what the specs carry; MUST be overridden away
SCRATCH_PARENT="$work/scratch"
JOBS=8
TARGET_USER="acme/alice"
INGEST_URL="http://ingest.invalid"      # never contacted in PRINT_ONLY
ARTIFACT_DIR="/artifacts/build-${BUILD_ID}"
# HOSTNAME_OUT exactly as build-image.sh derives it from BUILD_ID.
HOSTNAME_OUT="sdimg-$(printf '%s' "$BUILD_ID" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9' | cut -c1-8)"

fail=0

# ── materialize the spec fixtures (one flat ImageConfig each) ────────────────
"$PY" - "$work" "$SPEC_DOMAIN" <<'PYEOF'
import sys
from hugmesh_studio.core.config import Domain, ImageConfig, User
work, dom = sys.argv[1], sys.argv[2]

# x86 node with a mesh control-plane URL (exercises the Studio's `env K=V`
# passthrough prefix) and a domain list + brand title with a space.
x = ImageConfig(mode="cloud", role="be+gpu", platform="x86", brand="acme",
                brand_title="Acme Corp", org="Acme-Inc", cluster_domain=dom,
                headscale_url="https://hs." + dom)
x.domains = [Domain(name=dom, title="Acme")]
x.save(f"{work}/spec-x86.json")

# rpi5 node (installer ISO on by default -> overlay must add --no-iso --no-tar).
r = ImageConfig(mode="cloud", role="backend", platform="rpi5", board="rpi5",
                brand="acme", brand_title="Acme", org="Acme-Inc", cluster_domain=dom)
r.save(f"{work}/spec-rpi5.json")

# frite client (ISO IS the artifact -> NO --no-iso overlay, matching legacy).
f = ImageConfig(mode="standalone", role="frite", platform="frite", board="la-frite",
                flavor="installer", brand="acme", brand_title="Acme", org="Acme-Inc",
                cluster_domain=dom)
f.save(f"{work}/spec-frite.json")

# an envelope (NOT a flat image) to prove the loud reject passes through.
with open(f"{work}/envelope.json", "w") as fh:
    fh.write('{"schema": "hugmesh-worklist/v1", "base": {}, "entries": []}')
print("ok")
PYEOF

# ── helpers ──────────────────────────────────────────────────────────────────

# gui_argv SPEC -> prints the Studio's native command tokens (one per line),
# leading `sudo` (present only off-root) stripped.
gui_argv() {
  local line
  line="$("$PY" -m hugmesh_studio --print-command \
      --config "$1" --backend native --generator-dir "$GEN")"
  local arr
  eval "arr=( $line )"                    # trusted: shlex.quote output, re-tokenised
  [ "${arr[0]:-}" = "sudo" ] && arr=( "${arr[@]:1}" )
  printf '%s\n' "${arr[@]}"
}

# worker_argv SPEC IMAGE_TYPE -> the tokens build-image.sh assembles (between the
# __BUILDER_ARGV_*__ markers), driving the PRINT_ONLY spec channel.
worker_argv() {
  local raw
  raw="$(GENERATOR_DIR="$GEN" IMAGE_SPEC_JSON="$1" IMAGE_TYPE="$2" \
      BUILD_IMAGE_SH_PRINT_ONLY=1 BUILD_ID="$BUILD_ID" TARGET_USER="$TARGET_USER" \
      DOMAIN="$DOMAIN" INGEST_URL="$INGEST_URL" ARTIFACT_DIR="$ARTIFACT_DIR" \
      SCRATCH_PARENT="$SCRATCH_PARENT" JOBS="$JOBS" \
      sh "$BUILD_IMAGE_SH")"
  printf '%s\n' "$raw" \
    | sed -n '/^__BUILDER_ARGV_BEGIN__$/,/^__BUILDER_ARGV_END__$/p' \
    | sed '1d;$d'
}

# last_value FLAG -- TOKENS... -> echoes the value following the LAST occurrence
# of FLAG (last-wins, mirroring the builders' own arg parsing).
last_value() {
  local flag="$1"; shift
  local prev="" val="" t
  for t in "$@"; do
    [ "$prev" = "$flag" ] && val="$t"
    prev="$t"
  done
  printf '%s' "$val"
}

# case_parity NAME SPEC PLATFORM IMAGE_TYPE
case_parity() {
  local name="$1" spec="$2" platform="$3" imagetype="$4"
  local -a gui actual expected overlay
  mapfile -t gui     < <(gui_argv "$spec")
  mapfile -t actual  < <(worker_argv "$spec" "$imagetype")

  # the exact worker overlay (must mirror run_spec_build in build-image.sh).
  overlay=( -w "$SCRATCH_PARENT/$BUILD_ID/work" -j "$JOBS" --env prod \
            --cluster-domain "$DOMAIN" -H "$HOSTNAME_OUT" )
  case "$platform" in
    x86)  overlay+=( --no-live-iso --no-tar ) ;;
    rpi5) overlay+=( --no-iso --no-tar ) ;;
  esac
  expected=( "${gui[@]}" "${overlay[@]}" )

  local ok=1

  # 1. exact token-for-token equality: spec content (== GUI channel) + overlay.
  if [ "${#expected[@]}" -ne "${#actual[@]}" ]; then
    echo "  [$name] LENGTH MISMATCH: expected ${#expected[@]} tokens, worker emitted ${#actual[@]}"
    ok=0
  else
    local i
    for i in "${!expected[@]}"; do
      if [ "${expected[$i]}" != "${actual[$i]}" ]; then
        echo "  [$name] TOKEN $i MISMATCH: expected '${expected[$i]}' got '${actual[$i]}'"
        ok=0
      fi
    done
  fi

  # 2. server-derived --cluster-domain wins (I6): the LAST one is DOMAIN, and the
  #    spec's own cluster_domain is present earlier but overridden.
  local cd_last; cd_last="$(last_value --cluster-domain "${actual[@]}")"
  if [ "$cd_last" != "$DOMAIN" ]; then
    echo "  [$name] --cluster-domain not server-derived: last='$cd_last' (want '$DOMAIN')"
    ok=0
  fi
  if ! printf '%s\n' "${actual[@]}" | grep -x "$SPEC_DOMAIN" >/dev/null; then
    echo "  [$name] spec cluster_domain '$SPEC_DOMAIN' absent — override test is not meaningful"
    ok=0
  fi

  # 3. fail-secure hardening tier wins: the LAST --env is prod (spec carried test).
  local env_last; env_last="$(last_value --env "${actual[@]}")"
  if [ "$env_last" != "prod" ]; then
    echo "  [$name] --env not fail-secure: last='$env_last' (want 'prod')"
    ok=0
  fi

  # 4. the worker owns -w (scratch) and -H (BUILD_ID hostname) on the overlap.
  local w_last h_last; w_last="$(last_value -w "${actual[@]}")"; h_last="$(last_value -H "${actual[@]}")"
  if [ "$w_last" != "$SCRATCH_PARENT/$BUILD_ID/work" ]; then
    echo "  [$name] -w not worker scratch: last='$w_last'"
    ok=0
  fi
  if [ "$h_last" != "$HOSTNAME_OUT" ]; then
    echo "  [$name] -H not BUILD_ID hostname: last='$h_last'"
    ok=0
  fi

  # 5. the correct builder script is present.
  if ! printf '%s\n' "${actual[@]}" | grep "build-.*stage4.sh" >/dev/null; then
    echo "  [$name] no generator build script token in the assembled command"
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    echo "ok  [$name] parity: ${#actual[@]} tokens (spec content == GUI channel; overlay authoritative)"
  else
    echo "FAIL [$name]"
    echo "  gui:      ${gui[*]}"
    echo "  overlay:  ${overlay[*]}"
    echo "  worker:   ${actual[*]}"
    fail=1
  fi
}

# reject_case NAME SPEC -> build-image.sh must exit non-zero (loud reject), fast.
reject_case() {
  local name="$1" spec="$2" rc=0
  GENERATOR_DIR="$GEN" IMAGE_SPEC_JSON="$spec" IMAGE_TYPE="primary" \
    BUILD_IMAGE_SH_PRINT_ONLY=1 BUILD_ID="$BUILD_ID" TARGET_USER="$TARGET_USER" \
    DOMAIN="$DOMAIN" INGEST_URL="$INGEST_URL" ARTIFACT_DIR="$ARTIFACT_DIR" \
    SCRATCH_PARENT="$SCRATCH_PARENT" JOBS="$JOBS" \
    sh "$BUILD_IMAGE_SH" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ok  [$name] rejected (exit $rc)"
  else
    echo "FAIL [$name] expected a non-zero reject, got exit 0"
    fail=1
  fi
}

echo "── image-spec parity ──"
case_parity  x86    "$work/spec-x86.json"    x86    primary
case_parity  rpi5   "$work/spec-rpi5.json"   rpi5   primary
case_parity  frite  "$work/spec-frite.json"  frite  client
echo "── loud rejects ──"
reject_case  envelope   "$work/envelope.json"
reject_case  missing    "$work/does-not-exist.json"

if [ "$fail" -ne 0 ]; then
  echo "build-image-spec-parity: FAIL"
  exit 1
fi
echo "build-image-spec-parity: PASS"
