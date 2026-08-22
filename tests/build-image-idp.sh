#!/usr/bin/env bash
# ── JOB-channel IDP (legacy env path) regression smoke (NON-GATING) ──────────────
# Proves the web/admin-bff-api image-gen channel's identity-provider passthrough:
# the worker entrypoint maps the OPTIONAL IDP / IDP_ISSUER / IDP_CLIENT_ID /
# IDP_JWKS env onto BOTH node builders' --idp/--idp-issuer/--idp-client-id
# [--idp-jwks] flags, and stays byte-identical to pre-toggle for the casdoor
# default:
#
#   * casdoor (default) / IDP unset  -> argv carries NO --idp* (byte-identical).
#   * IDP=entra x86/rpi5 node build  -> argv carries --idp entra --idp-issuer …
#                                       --idp-client-id … (both node builders take
#                                       them, unlike the x86-only tor onion).
#   * IDP=oidc + IDP_JWKS            -> the optional --idp-jwks override rides too.
#   * IDP=entra with no IDP_ISSUER   -> rejected (external needs an https issuer).
#   * IDP=entra with no IDP_CLIENT_ID-> rejected (external needs a client id).
#   * casdoor + a stray IDP_ISSUER   -> rejected (external-only fields need an
#                                       external IDP).
#   * IDP=<not in the set>           -> rejected as a malformed value.
#
# Exercised END-TO-END through the real worker entrypoint via its
# BUILD_IMAGE_SH_PRINT_ONLY dev/CI escape hatch (the run_*_build functions route
# through dispatch_builder). The confirmation log lines can also mention the flag
# names, so the presence checks slice the tokens between the __BUILDER_ARGV_*__
# markers rather than grepping the whole output. Secrets never travel this channel.
#
# Usage: tests/build-image-idp.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/.." && pwd)"
BUILD_IMAGE_SH="$GEN/docker/build-image.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

BUILD_ID="ABC12345-de6-7890"
DOMAIN="tenant.example"
TARGET_USER="acme/alice"
INGEST_URL="http://ingest.invalid"      # never contacted in PRINT_ONLY
ARTIFACT_DIR="/artifacts/build-${BUILD_ID}"

fail=0

# run the real worker in PRINT_ONLY over the LEGACY env path. $1=IMAGE_TYPE
# $2=HARDWARE_CLASS; the rest are extra KEY=VALUE env assignments (the IDP knobs).
worker() {
  local it="$1" hw="$2"; shift 2
  env GENERATOR_DIR="$GEN" IMAGE_TYPE="$it" HARDWARE_CLASS="$hw" \
    BUILD_IMAGE_SH_PRINT_ONLY=1 BUILD_ID="$BUILD_ID" TARGET_USER="$TARGET_USER" \
    DOMAIN="$DOMAIN" INGEST_URL="$INGEST_URL" ARTIFACT_DIR="$ARTIFACT_DIR" \
    SSH_KEYS_ALLOWED=false SCRATCH_PARENT="$work/scratch" JOBS=8 \
    "$@" \
    sh "$BUILD_IMAGE_SH" >"$work/out" 2>&1
}

# argv_has NEEDLE -> exact builder-argv token between the __BUILDER_ARGV_*__ markers?
argv_has() {
  awk '/__BUILDER_ARGV_BEGIN__/{f=1;next} /__BUILDER_ARGV_END__/{f=0} f' "$work/out" \
    | grep -xF -- "$1" >/dev/null
}
argv_count() {
  # grep -c exits 1 on zero matches; tolerate it (0 is a valid answer here).
  awk '/__BUILDER_ARGV_BEGIN__/{f=1;next} /__BUILDER_ARGV_END__/{f=0} f' "$work/out" \
    | grep -cxF -- "$1" || true
}

# accept NAME WANT(present|absent) IMAGE_TYPE HARDWARE_CLASS [env...]
accept() {
  local name="$1" want="$2" it="$3" hw="$4"; shift 4
  if ! worker "$it" "$hw" "$@"; then
    echo "FAIL [$name] worker exited nonzero (expected a clean PRINT_ONLY preview)"; fail=1; return
  fi
  local n; n="$(argv_count "--idp")"
  if [ "$want" = present ]; then
    if [ "$n" -ge 1 ] && argv_has "--idp-issuer" && argv_has "--idp-client-id"; then
      echo "PASS [$name] argv carries --idp + issuer + client-id"
    else echo "FAIL [$name] expected --idp/issuer/client-id in argv (idp tokens=$n)"; fail=1; fi
  else
    if [ "$n" -eq 0 ]; then echo "PASS [$name] argv carries NO --idp (byte-identical default)"
    else echo "FAIL [$name] unexpected --idp in argv (count=$n)"; fail=1; fi
  fi
}

# reject NAME NEEDLE IMAGE_TYPE HARDWARE_CLASS [env...] — worker must die, message matches
reject() {
  local name="$1" needle="$2" it="$3" hw="$4"; shift 4
  if worker "$it" "$hw" "$@"; then
    echo "FAIL [$name] worker SUCCEEDED (expected a fail-closed rejection)"; fail=1; return
  fi
  if grep -qi -- "$needle" "$work/out"; then echo "PASS [$name] rejected ($needle)"
  else echo "FAIL [$name] rejected but message missing /$needle/"; fail=1; fi
}

ENTRA_ISS="https://login.microsoftonline.com/tenant/v2.0"

echo "── IDP legacy channel: accept/byte-identity ──"
accept "default-casdoor-x86"     absent  primary        x86
accept "default-casdoor-rpi5"    absent  mesh-extension rpi5
accept "entra-x86-node"          present primary        x86  IDP=entra IDP_ISSUER="$ENTRA_ISS" IDP_CLIENT_ID=app-mesh
accept "entra-rpi5-node"         present mesh-extension rpi5 IDP=entra IDP_ISSUER="$ENTRA_ISS" IDP_CLIENT_ID=app-mesh
accept "aws-cognito-x86"         present primary        x86  IDP=aws IDP_ISSUER=https://cognito-idp.us-east-1.amazonaws.com/pool IDP_CLIENT_ID=c1

echo "── IDP legacy channel: optional --idp-jwks override ──"
if worker primary x86 IDP=oidc IDP_ISSUER=https://oidc.example IDP_CLIENT_ID=c IDP_JWKS=https://oidc.example/keys \
   && argv_has "--idp-jwks" && argv_has "https://oidc.example/keys"; then
  echo "PASS [jwks-override] --idp-jwks rides when set"
else echo "FAIL [jwks-override] --idp-jwks did not ride"; fail=1; fi

echo "── IDP legacy channel: fail-closed rejections ──"
reject "entra-no-issuer"   "requires IDP_ISSUER"        primary x86 IDP=entra IDP_CLIENT_ID=c
reject "entra-no-client"   "requires IDP_CLIENT_ID"     primary x86 IDP=entra IDP_ISSUER="$ENTRA_ISS"
reject "entra-http-issuer" "https"                      primary x86 IDP=entra IDP_ISSUER=http://insecure.example IDP_CLIENT_ID=c
reject "casdoor-stray-iss" "require an external IDP"     primary x86 IDP_ISSUER=https://x.example
reject "unknown-idp"       "must be casdoor"            primary x86 IDP=bogus

echo
if [ "$fail" -eq 0 ]; then echo "build-image-idp: ALL PASS"; else echo "build-image-idp: FAILURES"; fi
exit "$fail"
