#!/usr/bin/env bash
# ── JOB-channel TOR_ONION (legacy env path) regression smoke (NON-GATING) ────────
# Proves the web/admin-bff-api image-gen channel's Tor-onion toggle: the worker
# entrypoint maps the OPTIONAL TOR_ONION=true env onto the x86 builder's additive
# --with-tor flag for an x86 NODE build, and FAILS CLOSED everywhere the onion can
# not be expressed through the minimal legacy IMAGE_TYPE/HARDWARE_CLASS channel:
#
#   * x86 primary/mesh-extension + TOR_ONION=true  -> argv carries --with-tor.
#   * TOR_ONION=false / unset (default)            -> argv carries NO --with-tor
#                                                     (the legacy path stays
#                                                     byte-identical to pre-toggle).
#   * imageType=client + TOR_ONION=true            -> rejected: the onion is a
#                                                     cluster NODE service.
#   * a non-x86 resolved platform (rpi5) + true    -> rejected, pointing at the
#                                                     IMAGE_SPEC_JSON channel (rpi5
#                                                     tor rides --optional-services,
#                                                     which the legacy path cannot add
#                                                     without clobbering the default
#                                                     service set — that is the rich
#                                                     channel's job).
#   * TOR_ONION=<not true/false>                   -> rejected as a malformed literal.
#
# Exercised END-TO-END through the real worker entrypoint via its
# BUILD_IMAGE_SH_PRINT_ONLY dev/CI escape hatch, which now previews the LEGACY
# command too (the six run_*_build functions route through dispatch_builder). The
# x86 confirmation log line ALSO contains the literal "--with-tor", so the argv
# presence check slices the tokens between the __BUILDER_ARGV_*__ markers rather than
# grepping the whole output. BUILD_IMAGE_SH_PRINT_ONLY is NOT part of the
# admin-bff-api Job contract and must never be set by image-gen-job.yaml.
#
# Usage: tests/build-image-tor-onion.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/.." && pwd)"
BUILD_IMAGE_SH="$GEN/docker/build-image.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

BUILD_ID="ABC12345-de6-7890"
DOMAIN="tenant.example"
SCRATCH_PARENT="$work/scratch"
JOBS=8
TARGET_USER="acme/alice"
INGEST_URL="http://ingest.invalid"      # never contacted in PRINT_ONLY
ARTIFACT_DIR="/artifacts/build-${BUILD_ID}"

fail=0

# run the real worker in PRINT_ONLY over the LEGACY env path (no IMAGE_SPEC_JSON);
# captures combined output to $work/out. $1=IMAGE_TYPE $2=HARDWARE_CLASS $3=TOR_ONION
# ("" -> leave TOR_ONION unset entirely, exercising the default).
worker() {
  local it="$1" hw="$2" tor="$3"
  local -a extra=()
  [ -n "$tor" ] && extra=(TOR_ONION="$tor")
  env GENERATOR_DIR="$GEN" IMAGE_TYPE="$it" HARDWARE_CLASS="$hw" \
    BUILD_IMAGE_SH_PRINT_ONLY=1 BUILD_ID="$BUILD_ID" TARGET_USER="$TARGET_USER" \
    DOMAIN="$DOMAIN" INGEST_URL="$INGEST_URL" ARTIFACT_DIR="$ARTIFACT_DIR" \
    SSH_KEYS_ALLOWED=false SCRATCH_PARENT="$SCRATCH_PARENT" JOBS="$JOBS" \
    "${extra[@]}" \
    sh "$BUILD_IMAGE_SH" >"$work/out" 2>&1
}

# argv_has NEEDLE -> is NEEDLE an exact builder-argv token (one token per line
# between the __BUILDER_ARGV_*__ markers)? Slicing avoids matching the confirmation
# LOG line, which also contains "--with-tor".
argv_has() {
  awk '/__BUILDER_ARGV_BEGIN__/{f=1;next} /__BUILDER_ARGV_END__/{f=0} f' "$work/out" \
    | grep -qxF -- "$1"
}

# accept_tor NAME IMAGE_TYPE HARDWARE_CLASS TOR_ONION WANT(present|absent)
accept_tor() {
  local name="$1" it="$2" hw="$3" tor="$4" want="$5" rc=0
  worker "$it" "$hw" "$tor" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$name] worker exited $rc (expected a clean PRINT_ONLY preview)"
    sed 's/^/    | /' "$work/out"; fail=1; return
  fi
  if ! grep -q 'build-x86-host-stage4.sh' "$work/out"; then
    echo "FAIL [$name] no x86 builder argv assembled"
    sed 's/^/    | /' "$work/out"; fail=1; return
  fi
  if [ "$want" = "present" ]; then
    if argv_has '--with-tor'; then
      echo "ok  [$name] --with-tor present in the x86 builder argv"
    else
      echo "FAIL [$name] expected --with-tor in the argv, absent"
      sed 's/^/    | /' "$work/out"; fail=1
    fi
  else
    if argv_has '--with-tor'; then
      echo "FAIL [$name] --with-tor unexpectedly present in the argv"
      sed 's/^/    | /' "$work/out"; fail=1
    else
      echo "ok  [$name] --with-tor absent from the argv (as expected)"
    fi
  fi
}

# reject_tor NAME IMAGE_TYPE HARDWARE_CLASS TOR_ONION NEEDLE
reject_tor() {
  local name="$1" it="$2" hw="$3" tor="$4" needle="$5" rc=0
  worker "$it" "$hw" "$tor" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$needle" "$work/out"; then
    echo "ok  [$name] rejected (exit $rc) with expected reason"
  else
    echo "FAIL [$name] expected non-zero reject mentioning '$needle', got exit $rc"
    sed 's/^/    | /' "$work/out"; fail=1
  fi
}

echo "── x86 node builds: TOR_ONION=true -> --with-tor; false/unset -> none ──"
accept_tor x86-primary-tor-on     primary        ""        true  present
accept_tor x86-primary-tor-off    primary        ""        false absent
accept_tor x86-primary-tor-unset  primary        ""        ""    absent
accept_tor x86-mesh-tor-on        mesh-extension ""        true  present
accept_tor x86-be-explicit-tor-on primary        x86.be    true  present

echo "── fail-closed: onion cannot be expressed here ──"
reject_tor client-tor        client "" true "invalid for imageType=client"
reject_tor rpi5-tor          primary rpi5.backend true "only supported for x86 node builds"
reject_tor bad-literal       primary "" maybe "must be the literal string 'true' or 'false'"

echo "── anti-revert: the toggle must be present in the worker source ──"
src_has() {  # LABEL PATTERN
  if grep -qF -- "$2" "$BUILD_IMAGE_SH"; then
    echo "ok  [$1] present in build-image.sh"
  else
    echo "FAIL [$1] missing from build-image.sh: $2"; fail=1
  fi
}
src_has tor-with-flag  'set -- "$@" --with-tor'
# dispatch_node_builder, not dispatch_builder: the x86 node builder is dispatched
# through the POSIX-sh IdP-appending wrapper (the bash-array IDP_EXTRA_ARGS fix —
# see tests/posix-sh-no-arrays.sh); --with-tor still rides the same "$@".
src_has tor-dispatch   'dispatch_node_builder ./build-x86-host-stage4.sh "$@"'
src_has tor-gate-x86   "TOR_ONION=true is only supported for x86 node builds"
src_has tor-gate-client "TOR_ONION=true is invalid for imageType=client"

if [ "$fail" -ne 0 ]; then
  echo "build-image-tor-onion: FAIL"
  exit 1
fi
echo "build-image-tor-onion: PASS"
