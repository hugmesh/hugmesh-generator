#!/usr/bin/env bash
# test-akkoma-image-pin.sh — hugmesh-akkoma: every Akkoma ref pinned to our own image
# by digest, Akkoma DEFAULT-OFF while that digest is the placeholder, and the release
# workflow kept equal to the mesh-node template (tests/scripts/akkoma_image_pin.py
# says what each check is and why).
#
# 1. the checker on the real tree must PASS;
# 2. a battery of planted defects, each in a fresh copy of the files the checker
#    reads, must each FAIL with the expected check tag; every mutation is verified
#    to have actually changed its file, so a mutation whose sed matched nothing
#    cannot read as "caught";
# 3. one positive control: a REAL digest with Akkoma default-on must PASS, so the
#    guard allows flipping the default back once the image is published.
#
# Needs bash and python3 (stdlib only). No network, no docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CHECK="${HERE}/akkoma_image_pin.py"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is not installed; this suite cannot run (it must not pass vacuously)"; exit 2; }
[ -f "${CHECK}" ] || { echo "FATAL: ${CHECK} missing"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-akkoma-image-pin.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

echo "== akkoma image pin: the real tree =="
out="$(python3 -I "${CHECK}" "${REPO}" 2>&1)"; rc=$?
printf '%s\n' "${out}"
if [ "${rc}" = 0 ]; then ok "the real tree passes every check"; else bad "the real tree fails (rc ${rc})"; fi
n_pass="$(printf '%s\n' "${out}" | grep -c '^  PASS \[' || true)"
if [ "${n_pass}" -eq 10 ]; then ok "the checker ran all 10 of its checks"; else bad "${n_pass} PASS lines, not 10: a check stopped running (or one was added without this pin)"; fi

FILES=(
  specs/cluster
  images/akkoma
  clients/docker-mesh-node/VERSION
  scripts/_optional-services-lib.sh
  build-x86-host-stage4.sh
  build-rpi5-stage4.sh
  studio/hugmesh_studio/core/config.py
  .github/workflows/akkoma-release.yml
  .github/workflows/akkoma-image-ci.yml
  .github/workflows/mesh-node-release.yml
)
fresh() { # fresh NAME -> a copy of the files the checker reads, at $T
  T="${TMP}/$1"
  mkdir -p "${T}"
  local f
  for f in "${FILES[@]}"; do
    mkdir -p "${T}/$(dirname "${f}")"
    cp -R "${REPO}/${f}" "${T}/${f}"
  done
}

# edit FILE PYTHON-EXPR: rewrite $T/FILE with s = <expr over s>; refuse a no-op. The
# expressions are the literal mutations written in THIS file, never external input.
edit() {
  python3 -I - "${T}/$1" "$2" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
new = eval(expr, {"s": s, "re": __import__("re")})
if new == s:
    sys.exit("mutation did not change " + p)
open(p, "w").write(new)
PY
}

Z64="0000000000000000000000000000000000000000000000000000000000000000"
R64="9f1c2e3d4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"
R64B="1111111111111111111111111111111111111111111111111111111111111112"
AK=specs/cluster/manifests/akkoma/akkoma.yaml
AS=specs/cluster/manifests/akkoma/admin-sync-job.yaml
PEER=specs/cluster/manifests/test-runner/akkoma-peer.yaml
REL=.github/workflows/akkoma-release.yml
CI=.github/workflows/akkoma-image-ci.yml

# expect NAME TAG FILE EXPR [FILE EXPR ...]: the mutated copy must fail with [TAG].
expect() {
  local name="$1" tag="$2"; shift 2
  fresh "m$((pass + fail))"
  while [ $# -gt 0 ]; do
    if ! edit "$1" "$2" 2>"${T}.err"; then bad "control '${name}': $(cat "${T}.err")"; return; fi
    shift 2
  done
  local o rc=0
  o="$(python3 -I "${CHECK}" "${T}" 2>&1)" || rc=$?
  if [ "${rc}" != 0 ] && printf '%s\n' "${o}" | grep -F "  FAIL [${tag}]" >/dev/null; then
    ok "control '${name}' -> caught by [${tag}]"
  else
    bad "control '${name}' -> NOT caught by [${tag}] (rc ${rc}): $(printf '%s\n' "${o}" | grep FAIL | head -3 | tr '\n' ';')"
  fi
}

echo "== negative controls: each planted defect must fail =="
expect "the dead registry host is back in akkoma.yaml" dead-host \
  "${AK}" "s.replace('image: ghcr.io/hugmesh/hugmesh-akkoma@', 'image: git.akkoma.dev/akkomagang/akkoma@', 1)"
expect "the unofficial compose-lane image in a manifest" dead-host \
  "${PEER}" "s.replace('ghcr.io/hugmesh/hugmesh-akkoma@sha256:${Z64}', 'teslamint/akkoma:v3.20.0', 1)"
expect "a ref pinned by tag only" refs \
  "${AS}" "s.replace('hugmesh-akkoma@sha256:${Z64}', 'hugmesh-akkoma:0.4.0-beta.1', 1)"
expect "a ref on another registry" refs \
  "${AS}" "s.replace('ghcr.io/hugmesh/hugmesh-akkoma@', 'docker.io/hugmesh/hugmesh-akkoma@', 1)"
expect "a new Akkoma ref in a new file, tag only" refs \
  specs/cluster/manifests/akkoma/kustomization.yaml "s + '\n# extra\n---\n# x\n' + 'images:\n  - name: foo\n    newName: hugmesh/akkoma-extra\n'"
expect "both test-runner refs dropped" sites \
  "${PEER}" "s.replace('image: ghcr.io/hugmesh/hugmesh-akkoma@sha256:${Z64}', 'image: busybox')"
expect "two different digests" lockstep \
  "${AK}" "s.replace('@sha256:${Z64}', '@sha256:${R64}', 1)"
expect "the placeholder line lost its marker" placeholder \
  "${AS}" "re.sub(r'(hugmesh-akkoma@sha256:0+)\s+# PLACEHOLDER digest[^\n]*', r'\1', s, count=1)"
expect "a real digest that still says PLACEHOLDER" placeholder \
  "${AK}" "s.replace('${Z64}', '${R64}')" \
  "${AS}" "s.replace('${Z64}', '${R64}')" \
  specs/cluster/manifests/akkoma/domainlock-sync-job.yaml "s.replace('${Z64}', '${R64}')" \
  "${PEER}" "s.replace('${Z64}', '${R64}')"
expect "akkoma back in the builder lib default" defaults \
  scripts/_optional-services-lib.sh "s.replace('_OPT_BUILTIN_DEFAULT_SERVICES=\"tuwunel phpbb\"', '_OPT_BUILTIN_DEFAULT_SERVICES=\"akkoma tuwunel phpbb\"', 1)"
expect "akkoma back in the x86 builder default" defaults \
  build-x86-host-stage4.sh "s.replace('OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-tuwunel phpbb}\"', 'OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}\"', 1)"
expect "akkoma back in the rpi5 builder default" defaults \
  build-rpi5-stage4.sh "s.replace('OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-tuwunel phpbb}\"', 'OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}\"', 1)"
expect "akkoma back in Studio's BUILTIN_DEFAULT_SERVICES" defaults \
  studio/hugmesh_studio/core/config.py "s.replace('BUILTIN_DEFAULT_SERVICES = (\"tuwunel\", \"phpbb\")', 'BUILTIN_DEFAULT_SERVICES = (\"akkoma\", \"tuwunel\", \"phpbb\")', 1)"
expect "registry akkoma default: on" defaults \
  specs/cluster/optional-services.yaml "re.sub(r'(- slug: akkoma\n(?:.*\n)*?\s+)default: off', r'\1default: on', s, count=1)"
expect "installed-services baseline akkoma true" defaults \
  specs/cluster/manifests/policy/installed-services-configmap.yaml "s.replace('  akkoma: \"false\"', '  akkoma: \"true\"', 1)"
expect "seed OptionalService akkoma enabled" defaults \
  specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml "re.sub(r'(slug: akkoma\n\s+)enabled: false', r'\1enabled: true', s, count=1)"
expect "federation gate.sql mastodon on" defaults \
  specs/cluster/manifests/federation-modules-gate/sql/gate.sql "s.replace(\"enabled = false WHERE slug = 'mastodon'\", \"enabled = true WHERE slug = 'mastodon'\", 1)"
expect "an unreadable default source fails closed" defaults \
  scripts/_optional-services-lib.sh "s.replace('_OPT_BUILTIN_DEFAULT_SERVICES=', '_OPT_DEFAULTS=', 1)"
expect "runtime base unpinned" dockerfile \
  images/akkoma/Dockerfile "re.sub(r'(ARG RUNTIME_IMAGE=[^@\n]*)@sha256:[0-9a-f]{64}', r'\1', s, count=1)"
expect "a stage FROM an unpinned image" dockerfile \
  images/akkoma/Dockerfile "s.replace('FROM \${RUNTIME_IMAGE}', 'FROM debian:trixie-slim', 1)"
expect "the stages build different commits" dockerfile \
  images/akkoma/Dockerfile "s.replace('ARG AKKOMA_COMMIT=98dd95', 'ARG AKKOMA_COMMIT=98fccc', 1)"
expect "the fetched commit is no longer checked" dockerfile \
  images/akkoma/Dockerfile "s.replace('test \"\$(git rev-parse HEAD)\" = \"\$AKKOMA_COMMIT\"', 'true', 1)"
expect "the baked Erlang cookie is kept" dockerfile \
  images/akkoma/Dockerfile "s.replace('rm -f /opt/akkoma/releases/COOKIE', 'true', 1)"
expect "the image runs as root" dockerfile \
  images/akkoma/Dockerfile "s.replace('USER 1000:1000', 'USER root', 1)"
expect "the image version leaves the repository's release line" version \
  images/akkoma/VERSION "'9.9.0-beta.1\n'"
expect "the release workflow gains a pull_request trigger" release-wf \
  "${REL}" "s.replace('  workflow_dispatch: {}', '  workflow_dispatch: {}\n  pull_request: {}', 1)"
expect "the release workflow publishes mesh-node-v tags" release-wf \
  "${REL}" "s.replace(\"tags: ['akkoma-v*']\", \"tags: ['mesh-node-v*']\", 1)"
expect "the overwrite guard drifts from the template" release-wf \
  "${REL}" "s.replace('out=\"\$(docker buildx imagetools inspect \"\$ref\" 2>&1)\" || rc=\$?', 'out=\"\$(docker buildx imagetools inspect \"\$ref\" 2>&1)\"', 1)"
expect "the signing step drifts from the template" release-wf \
  "${REL}" "s.replace('run: cosign sign --yes \"\$REF\"', 'run: cosign sign --yes --tlog-upload=false \"\$REF\"', 1)"
expect "the boot test moves after the tag decision" release-wf \
  "${REL}" "re.sub(r'(\n      # The image about to be pushed.*?)(\n      - name: Compute tags and labels.*?)(\n      - name: Build and push image)', r'\2\1\3', s, count=1, flags=re.S)"
expect "the first build pushes" release-wf \
  "${REL}" "re.sub(r'(- name: Build the image \(no push\)(?:.*\n)*?\s+)push: false', r'\1push: true', s, count=1)"
expect "the PR build gains packages: write" pr-wf \
  "${CI}" "s.replace('permissions:\n  contents: read', 'permissions:\n  contents: read\n  packages: write', 1)"
expect "the PR build logs in to a registry" pr-wf \
  "${CI}" "s.replace('      - name: Set up Docker Buildx', '      - uses: docker/login-action@v3\n      - name: Set up Docker Buildx', 1)"
expect "the PR build also runs on push" pr-wf \
  "${CI}" "s.replace('on:\n  pull_request:', 'on:\n  push:\n    branches: [main]\n  pull_request:', 1)"

echo "== positive control: a real digest may be default-on =="
fresh positive
for f in "${AK}" "${AS}" specs/cluster/manifests/akkoma/domainlock-sync-job.yaml "${PEER}"; do
  edit "${f}" "re.sub(r'@sha256:0{64}\s+# PLACEHOLDER digest[^\n]*', '@sha256:${R64B}', s)" || bad "positive control: could not rewrite ${f}"
done
edit scripts/_optional-services-lib.sh "s.replace('_OPT_BUILTIN_DEFAULT_SERVICES=\"tuwunel phpbb\"', '_OPT_BUILTIN_DEFAULT_SERVICES=\"akkoma tuwunel phpbb\"', 1)" \
  || bad "positive control: could not flip the lib default"
o="$(python3 -I "${CHECK}" "${T}" 2>&1)"; rc=$?
if [ "${rc}" = 0 ]; then
  ok "a real digest with akkoma default-on passes (the guard does not block the follow-up)"
else
  bad "a real digest with akkoma default-on was refused: $(printf '%s\n' "${o}" | grep FAIL | head -3 | tr '\n' ';')"
fi

echo "== test-akkoma-image-pin.sh: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
