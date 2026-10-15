#!/usr/bin/env bash
# ── image-gen ingest: dial identity reported back (hugmesh-generator#368) ────────
# The BFF mints DEVICE_ID and VAULT_REF, hands both to the Job in its env, and seeds
# a device_ssh_dial row only when the terminal report carries the SAME two values
# (and derives the per-device Secret name itself, ignoring k8sSecretName). This test
# runs the real docker/build-image.sh end to end (fake root `id`, fake builders, a
# fake `curl` that captures the POST body) and asserts, on the body actually sent:
#
#   1  DEVICE_ID / VAULT_REF from the Job env come back verbatim, in the ingest body
#      and in the keys-bundle metadata.json.
#   2  With DEVICE_ID unset the worker still derives dev-<12 alnum of BUILD_ID>, and
#      VAULT_REF stays null (no invented Vault path).
#   3  The body carries no k8sSecretName key.
#   4  With SSH_KEYS_ALLOWED=false neither value is reported (no dial key, no row).
#
# No root, no network, no writes outside mktemp. Needs python3 and ssh-keygen.
# Usage: tests/build-image-dial-identity.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/.." && pwd)"
BUILD_IMAGE_SH="$GEN/docker/build-image.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
ok()  { echo "ok  [$1] $2"; }
bad() { echo "FAIL [$1] $2"; fail=1; }

# fake generator tree: every builder the worker checks for, x86 drops one .img
fakegen="$work/gen"; mkdir -p "$fakegen"
for f in build-x86-host-stage4.sh build-rpi5-stage4.sh build-frite-stage4.sh build-jetson-stage4.sh \
         build-orangepi5-stage4.sh build-orangepi-zero2-stage4.sh build-orangepi-zero2w-stage4.sh \
         build-orangepi-zero3-stage4.sh build-orangepi3-lts-stage4.sh build-orangepi4-lts-stage4.sh; do
  cat >"$fakegen/$f" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = "-w" ]; then mkdir -p "$2"; : >"$2/fake.img"; fi
  shift
done
exit 0
STUB
  chmod +x "$fakegen/$f"
done

# the worker sources scripts/ and calls studio/ from GENERATOR_DIR: link the real ones
for d in scripts studio docker; do ln -s "$GEN/$d" "$fakegen/$d"; done

# fake PATH shims: root `id`, and a `curl` that keeps the --data-binary body
bin="$work/bin"; mkdir -p "$bin"
cat >"$bin/id" <<'SH'
#!/bin/sh
[ "$1" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
cat >"$bin/curl" <<'SH'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) cp "${2#@}" "$CAPTURE_BODY" ;;
  esac
  shift
done
printf 200
SH
chmod +x "$bin/id" "$bin/curl"

# The worker pins ARTIFACT_DIR to the Job's /artifacts mount, which a non-root test
# cannot create. Run a copy whose ONLY difference is that one pin pointing under mktemp.
worker_sh="$work/build-image.sh"
sed "s#^expected_artifact_dir=\"/artifacts/#expected_artifact_dir=\"$work/artifacts-root/#" \
  "$BUILD_IMAGE_SH" >"$worker_sh"
[ "$(diff "$BUILD_IMAGE_SH" "$worker_sh" | grep -c '^>')" = "1" ] \
  || { echo "FAIL [setup] the ARTIFACT_DIR pin was not found exactly once in $BUILD_IMAGE_SH"; exit 1; }

dial="$work/dial"; mkdir -p "$dial"
ssh-keygen -q -t ed25519 -N '' -f "$dial/dial_private_key" -C test >/dev/null

BUILD_ID="ABC12345-de6-7890"

# run_worker NAME SSH_KEYS_ALLOWED [KEY=VALUE env...] -> $work/NAME.body, NAME.meta
run_worker() {
  local name="$1" ssh="$2"; shift 2
  local art="$work/artifacts-root/build-${BUILD_ID}"; rm -rf "$art"
  mkdir -p "$art"
  if ! env -u DEVICE_ID -u VAULT_REF PATH="$bin:$PATH" CAPTURE_BODY="$work/$name.body" \
      GENERATOR_DIR="$fakegen" SCRATCH_PARENT="$work/$name/scratch" ARTIFACT_DIR="$art" \
      DIAL_SECRET_DIR="$dial" BUILD_ID="$BUILD_ID" TARGET_USER="alice" DOMAIN="tenant.example" \
      IMAGE_TYPE=primary HARDWARE_CLASS="" SSH_KEYS_ALLOWED="$ssh" \
      INGEST_URL="http://ingest.invalid" JOBS=1 "$@" \
      sh "$worker_sh" >"$work/$name.log" 2>&1; then
    bad "$name" "worker exited nonzero: $(tail -n 5 "$work/$name.log" | tr '\n' ' ')"
    return 1
  fi
  [ -s "$work/$name.body" ] || { bad "$name" "no ingest body captured"; return 1; }
  tar -xOf "$art/keys.tar" ./metadata.json >"$work/$name.meta" 2>/dev/null || : >"$work/$name.meta"
}

# jget FILE KEY -> JSON value as text ("null" for null, "<absent>" when the key is missing)
jget() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(d[sys.argv[2]]) if sys.argv[2] in d else "<absent>")
PY
}

check() { # NAME FILE KEY WANT
  local got; got="$(jget "$2" "$3")"
  if [ "$got" = "$4" ]; then ok "$1" "$3 = $4"; else bad "$1" "$3: want $4, got $got"; fi
}

# 1: env values come back verbatim
if run_worker env-passthrough true DEVICE_ID=dev-bff-minted-1 VAULT_REF=hugmesh/device/dev-bff-minted-1/ssh; then
  check env-passthrough "$work/env-passthrough.body" deviceId '"dev-bff-minted-1"'
  check env-passthrough "$work/env-passthrough.body" vaultRef '"hugmesh/device/dev-bff-minted-1/ssh"'
  check env-passthrough "$work/env-passthrough.meta" deviceId '"dev-bff-minted-1"'
  check env-passthrough "$work/env-passthrough.meta" vaultRef '"hugmesh/device/dev-bff-minted-1/ssh"'
  check env-passthrough "$work/env-passthrough.body" k8sSecretName '<absent>'
fi

# 2: no env -> derived device id, null vault ref
if run_worker derived true; then
  check derived "$work/derived.body" deviceId '"dev-abc12345de67"'
  check derived "$work/derived.body" vaultRef 'null'
  check derived "$work/derived.body" k8sSecretName '<absent>'
fi

# 4: no dial key requested -> neither value reported
if run_worker no-dial false DEVICE_ID=dev-bff-minted-1 VAULT_REF=hugmesh/device/dev-bff-minted-1/ssh; then
  check no-dial "$work/no-dial.body" deviceId 'null'
  check no-dial "$work/no-dial.body" vaultRef 'null'
fi

[ "$fail" -eq 0 ] && echo "PASS build-image-dial-identity" || { echo "FAILED build-image-dial-identity"; exit 1; }
