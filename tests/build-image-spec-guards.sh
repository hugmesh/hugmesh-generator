#!/usr/bin/env bash
# ── JOB-channel image-spec GUARD regression smoke (NON-GATING) ───────────────────
# Companion to tests/build-image-spec-parity.sh. That fixture proves the spec
# channel translates a VALID ImageConfig identically to the GUI channel; this one
# proves the two flavors of defense against the four integration gaps where it used
# to diverge from the legacy IMAGE_TYPE/HARDWARE_CLASS channel (resolve_build_target):
#
#   G2  frite/orangepi5/orangepizero2 with an UNSET flavor. Two layers now cover it:
#       (a) the Studio's resolve_platform_defaults fills an unset ARM flavor ->
#           `installer` at materialize time, so a MINIMAL ImageConfig no longer emits
#           the two-artifact `--flavor both` — the worker ACCEPTS it (positive control).
#       (b) the worker still FAILS CLOSED (defense-in-depth) if a spec explicitly
#           carries `--flavor both` (a hand-crafted / non-Studio spec): the ingest
#           contract carries a single imageRef, so `both` is rejected up front rather
#           than wasting the whole build and die-ERRORing at artifact collection.
#   G3  jetson with an off-platform/unset role. Same two layers:
#       (a) resolve_platform_defaults canonicalizes the x86 base-default role
#           (`standalone-thick`) and an unset role to a valid jetson role (`edge_ai`),
#           so a minimal jetson ImageConfig now ACCEPTS (positive control) instead of
#           relaying a role the jetson builder would hard-reject after dispatch.
#       (b) the worker still rejects a spec that explicitly carries a role outside the
#           jetson allowlist (edge_ai | gpu-host | full | desktop) — defense-in-depth.
#   G4  compress=true: the Studio emits --compress and the builder renames the
#       product to <name>.img.xz (removing the raw .img). The OLD detector globbed
#       only *.img -> 0 matches -> die ERROR on a fully-successful build, discarding
#       the deliverable. Now the detector matches *.img.xz / *.iso.xz too and
#       preserves the compound suffix.
#   G5  dial-key fallback selector: a k8s Secret volume projects each key as a
#       SYMLINK, so `find -type f` matched nothing and a build with a non-standard
#       key name shipped with NO dial pubkey while still reporting COMPLETED. Now the
#       selector follows the symlinks (-L) and skips the k8s bookkeeping entries.
#
# G2/G3 are exercised END-TO-END through the real worker entrypoint via its
# BUILD_IMAGE_SH_PRINT_ONLY dev/CI escape hatch (resolve_spec_target runs before the
# argv is printed). G4/G5 live in the post-build artifact-collection / dial-key
# phases, which PRINT_ONLY exits before reaching — so they are validated by (a)
# replaying build-image.sh's own selector expressions against a real on-disk
# scenario and (b) asserting the fixed tokens are present in the source (so a revert
# fails this test). BUILD_IMAGE_SH_PRINT_ONLY is NOT part of the admin-bff-api Job
# contract and must never be set by image-gen-job.yaml.
#
# Usage: tests/build-image-spec-guards.sh
#   PYTHON=/path/to/python  override the interpreter (default: python3; a venv
#                           python works — --print-command/--print-specs are Qt-free).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/.." && pwd)"
STUDIO="$GEN/studio"
BUILD_IMAGE_SH="$GEN/docker/build-image.sh"
PY="${PYTHON:-python3}"
PY_DIR="$(cd "$(dirname "$PY")" 2>/dev/null && pwd || true)"
export PYTHONPATH="$STUDIO${PYTHONPATH:+:$PYTHONPATH}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}"

# build-image.sh calls a BARE `python3` internally (--print-command). Make that
# resolve to the SAME interpreter this fixture uses.
if [ -n "$PY_DIR" ] && [ -x "$PY_DIR/python3" ]; then
  export PATH="$PY_DIR:$PATH"
fi

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

# materialize a flat ImageConfig (mirrors what the BFF's IMAGE_SPEC_JSON carries)
# from a minimal raw config, via the Studio's --print-specs.
materialize() {  # NAME RAW_JSON
  printf '%s' "$2" > "$work/$1.raw.json"
  "$PY" -m snapdragon_studio --print-specs \
      --config "$work/$1.raw.json" --generator-dir "$GEN" > "$work/$1.json"
}

# run the real worker in PRINT_ONLY over a spec; captures combined output to $work/out.
worker() {  # SPEC IMAGE_TYPE
  GENERATOR_DIR="$GEN" IMAGE_SPEC_JSON="$1" IMAGE_TYPE="$2" \
    BUILD_IMAGE_SH_PRINT_ONLY=1 BUILD_ID="$BUILD_ID" TARGET_USER="$TARGET_USER" \
    DOMAIN="$DOMAIN" INGEST_URL="$INGEST_URL" ARTIFACT_DIR="$ARTIFACT_DIR" \
    SSH_KEYS_ALLOWED=false SCRATCH_PARENT="$SCRATCH_PARENT" JOBS="$JOBS" \
    sh "$BUILD_IMAGE_SH" >"$work/out" 2>&1
}

# reject_case NAME SPEC IMAGE_TYPE NEEDLE -> worker must exit non-zero and the
# message must contain NEEDLE (fail-closed with a specific reason).
reject_case() {  # NAME SPEC IMAGE_TYPE NEEDLE
  local name="$1" spec="$2" it="$3" needle="$4" rc=0
  worker "$spec" "$it" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$needle" "$work/out"; then
    echo "ok  [$name] rejected (exit $rc) with expected reason"
  else
    echo "FAIL [$name] expected non-zero reject mentioning '$needle', got exit $rc"
    sed 's/^/    | /' "$work/out"
    fail=1
  fi
}

# accept_case NAME SPEC IMAGE_TYPE -> worker must exit 0 and print a builder argv
# (no FALSE reject of a valid spec).
accept_case() {  # NAME SPEC IMAGE_TYPE
  local name="$1" spec="$2" it="$3" rc=0
  worker "$spec" "$it" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q 'stage4.sh' "$work/out"; then
    echo "ok  [$name] accepted (exit 0, builder argv assembled)"
  else
    echo "FAIL [$name] valid spec was NOT accepted cleanly (exit $rc)"
    sed 's/^/    | /' "$work/out"
    fail=1
  fi
}

echo "── G2/G3 (a): the Studio pre-resolves the legacy gaps, so a minimal config now ACCEPTS ──"
# resolve_platform_defaults fills an unset ARM flavor -> installer and canonicalizes
# an unset/off-platform role, so these minimal ImageConfigs — which the OLD spec
# channel rejected (--flavor both / role=standalone-thick) — now assemble cleanly.
materialize frite_unset  '{"platform":"frite"}'
materialize op5_unset    '{"platform":"orangepi5"}'
materialize opz2_unset   '{"platform":"orangepizero2"}'
materialize jetson_unset '{"platform":"jetson"}'
accept_case frite-unset-resolved  "$work/frite_unset.json"  client
accept_case op5-unset-resolved    "$work/op5_unset.json"    client
accept_case opz2-unset-resolved   "$work/opz2_unset.json"   client
accept_case jetson-unset-resolved "$work/jetson_unset.json" primary

echo "── G2/G3 (b): the worker still FAILS CLOSED on a spec that explicitly carries the bad value ──"
# Defense-in-depth against a hand-crafted / non-Studio spec: resolve_platform_defaults
# only fills an UNSET flavor and canonicalizes the roles it recognizes, so an explicit
# `both` and an unrecognized jetson role pass through to the worker's guard unchanged.
materialize frite_both     '{"platform":"frite","flavor":"both"}'
materialize op5_both       '{"platform":"orangepi5","flavor":"both"}'
materialize opz2_both      '{"platform":"orangepizero2","flavor":"both"}'
materialize jetson_badrole '{"platform":"jetson","role":"not-a-jetson-role"}'
reject_case frite-flavor-both  "$work/frite_both.json"     client  "--flavor both"
reject_case op5-flavor-both    "$work/op5_both.json"       client  "--flavor both"
reject_case opz2-flavor-both   "$work/opz2_both.json"      client  "--flavor both"
reject_case jetson-bad-role    "$work/jetson_badrole.json" primary "edge_ai | gpu-host | full | desktop"

echo "── positive controls: valid specs still assemble (no false reject) ──"
materialize frite_ok  '{"platform":"frite","role":"frite","flavor":"installer"}'
materialize jetson_ok '{"platform":"jetson","role":"edge_ai"}'
materialize x86_ok    '{"platform":"x86","role":"be+gpu"}'
materialize rpi5_ok   '{"platform":"rpi5","role":"backend","board":"rpi5"}'
accept_case frite-installer "$work/frite_ok.json"  client
accept_case jetson-edge_ai  "$work/jetson_ok.json" primary
accept_case x86-be+gpu      "$work/x86_ok.json"    primary
accept_case rpi5-backend    "$work/rpi5_ok.json"   primary

# ── G4: compressed-artifact detector ────────────────────────────────────────────
# PRINT_ONLY exits before the artifact-collection phase, so replay build-image.sh's
# own detector expression against an on-disk build tree, then assert the fix is in
# the source. Uses the exact patterns build-image.sh sets per platform.
echo "── G4: compressed-artifact detector matches .img.xz / .iso.xz ──"
detect() {  # LABEL WORKDIR IMG_GLOB XZ_GLOB WANT_COUNT WANT_BASENAME
  local label="$1" w="$2" ag="$3" agx="$4" wc_want="$5" bn_want="$6"
  local cnt pf bn
  cnt="$(find "$w" -maxdepth 1 -type f \( -name "$ag" -o -name "$agx" \) | wc -l | tr -d ' ')"
  pf="$(find "$w" -maxdepth 1 -type f \( -name "$ag" -o -name "$agx" \) | head -1)"
  case "$pf" in
    *.img.xz) bn="image.img.xz" ;; *.iso.xz) bn="image.iso.xz" ;;
    *.img) bn="image.img" ;; *.iso) bn="image.iso" ;; *) bn="image.${pf##*.}" ;;
  esac
  if [ "$cnt" = "$wc_want" ] && [ "$bn" = "$bn_want" ]; then
    echo "ok  [$label] match_count=$cnt basename=$bn"
  else
    echo "FAIL [$label] got count=$cnt basename=$bn (want $wc_want / $bn_want)"
    fail=1
  fi
}
wc4="$work/w-compress"; mkdir -p "$wc4"
: > "$wc4/snapdragon-x86-be+gpu-prod-ts.img.xz"
: > "$wc4/snapdragon-x86-be+gpu-prod-ts.stage4.tar.xz"   # sibling, must NOT match
: > "$wc4/snapdragon-x86-be+gpu-prod-ts.fs.tar.xz"       # sibling, must NOT match
detect x86-compressed "$wc4" '*.img' '*.img.xz' 1 image.img.xz
wc4b="$work/w-raw"; mkdir -p "$wc4b"; : > "$wc4b/snapdragon.img"
detect x86-uncompressed "$wc4b" '*.img' '*.img.xz' 1 image.img
wc4c="$work/w-iso-xz"; mkdir -p "$wc4c"; : > "$wc4c/snapdragon-frite.iso.xz"
detect frite-compressed "$wc4c" '*.iso' '*.iso.xz' 1 image.iso.xz

# ── G5: dial-key selector follows k8s Secret symlinks ────────────────────────────
echo "── G5: dial-key selector finds the symlink-projected key ──"
d5="$work/mock-secret"; mkdir -p "$d5/..2026_data"; : > "$d5/..2026_data/ssh-privatekey"
ln -s ..2026_data "$d5/..data"; ln -s ..data/ssh-privatekey "$d5/ssh-privatekey"
sel="$(find -L "$d5" -maxdepth 1 -type f ! -name '*.pub' ! -name '..*' 2>/dev/null | head -n1)"
if [ -n "$sel" ] && [ "$(basename "$sel")" = "ssh-privatekey" ]; then
  echo "ok  [dial-key-symlink] selector resolved $(basename "$sel") (bookkeeping ..data/..<ts>_data skipped)"
else
  echo "FAIL [dial-key-symlink] selector returned '$sel' (want the projected ssh-privatekey)"
  fail=1
fi

# ── anti-revert: the G4/G5 fixes must be present in the worker source ────────────
echo "── source assertions (a revert of any fix fails here) ──"
src_has() {  # LABEL PATTERN
  if grep -qF -- "$2" "$BUILD_IMAGE_SH"; then
    echo "ok  [$1] present in build-image.sh"
  else
    echo "FAIL [$1] missing from build-image.sh: $2"
    fail=1
  fi
}
src_has g4-glob-img-xz   "-o -name \"\$artifact_glob_xz\""
src_has g4-basename-imgxz 'image_basename="image.img.xz"'
src_has g4-basename-isoxz 'image_basename="image.iso.xz"'
src_has g5-find-follow    "find -L \"\$DIAL_SECRET_DIR\" -maxdepth 1 -type f ! -name '*.pub' ! -name '..*'"

if [ "$fail" -ne 0 ]; then
  echo "build-image-spec-guards: FAIL"
  exit 1
fi
echo "build-image-spec-guards: PASS"
