#!/usr/bin/env bash
# test-akkoma-image-pin.sh — hugmesh-akkoma: every Akkoma ref pinned to our own image
# by digest, Akkoma DEFAULT-OFF whenever that digest is a placeholder, branded meshes
# kept on the HugMesh-published image, and the release workflow kept equal to the
# mesh-node template (tests/scripts/akkoma_image_pin.py says what each check is and why).
#
# 1. the checker on the real tree must PASS (since 2026-11-12 the real tree pins the
#    published digest and has Akkoma default-on);
# 2. a battery of planted defects, each in a fresh copy of the files the checker
#    reads, must each FAIL with the expected check tag; every mutation is verified
#    to have actually changed its file, so a mutation whose sed matched nothing
#    cannot read as "caught". The default-source controls start from the pre-release
#    state (prepublish: placeholder digest, Akkoma off everywhere) and turn ONE
#    source back on, which [defaults] must name;
# 3. one positive control: that pre-release state itself must PASS, so a future image
#    can go back to a placeholder by turning every default off again;
# 4. the three builders that bake specs/cluster are driven through their real
#    rebrand_sysroot with a custom brand and org: the Akkoma refs must survive, and
#    deleting each builder's rule must be caught.
#
# Needs bash, sed, awk and python3 (stdlib only). No network, no docker.
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
if [ "${n_pass}" -eq 11 ]; then ok "the checker ran all 11 of its checks"; else bad "${n_pass} PASS lines, not 11: a check stopped running (or one was added without this pin)"; fi

FILES=(
  specs/cluster
  images/akkoma
  clients/docker-mesh-node/VERSION
  scripts/_optional-services-lib.sh
  build-x86-host-stage4.sh
  build-rpi5-stage4.sh
  build-jetson-stage4.sh
  scripts/build-menu.sh
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
AK=specs/cluster/manifests/akkoma/akkoma.yaml
AS=specs/cluster/manifests/akkoma/admin-sync-job.yaml
DL=specs/cluster/manifests/akkoma/domainlock-sync-job.yaml
PEER=specs/cluster/manifests/test-runner/akkoma-peer.yaml
REL=.github/workflows/akkoma-release.yml
CI=.github/workflows/akkoma-image-ci.yml

# The pinned ref, read from the real tree (the mutations below anchor on it, so a
# re-pin needs no edit here). [lockstep] on the real tree proves every ref carries it.
PIN="$(grep -o 'ghcr\.io/hugmesh/hugmesh-akkoma[:@][^[:space:]"]*' "${REPO}/${AK}" | head -n 1)"
DIG="${PIN##*@sha256:}"
NAMETAG="${PIN%@*}"
case "${DIG}" in
  *[!0-9a-f]*|"") echo "FATAL: no pinned hugmesh-akkoma digest in ${AK} (got '${PIN}')"; exit 2 ;;
esac
[ "${#DIG}" -eq 64 ] || { echo "FATAL: ${AK} pins '${DIG}', not a 64-hex digest"; exit 2; }
[ "${NAMETAG}" != "${PIN}" ] || { echo "FATAL: ${PIN} has no @sha256: part"; exit 2; }

# prepublish: rewrite $T back to the state before the first release (the placeholder
# digest, marked, and akkoma OFF in every default source the checker reads). The
# controls that start from it then turn exactly ONE source back on.
prepublish() {
  local f
  for f in "${AK}" "${AS}" "${DL}" "${PEER}"; do
    edit "${f}" "s.replace('${PIN}', 'ghcr.io/hugmesh/hugmesh-akkoma@sha256:${Z64}   # PLACEHOLDER digest: control')" || return 1
  done
  edit scripts/_optional-services-lib.sh "s.replace('_OPT_BUILTIN_DEFAULT_SERVICES=\"akkoma tuwunel phpbb\"', '_OPT_BUILTIN_DEFAULT_SERVICES=\"tuwunel phpbb\"', 1)" || return 1
  for f in build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh; do
    edit "${f}" "s.replace('OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}\"', 'OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-tuwunel phpbb}\"', 1)" || return 1
  done
  edit scripts/build-menu.sh "s.replace('cur=\"akkoma,tuwunel,phpbb\"', 'cur=\"tuwunel,phpbb\"', 1)" || return 1
  edit studio/hugmesh_studio/core/config.py "s.replace('BUILTIN_DEFAULT_SERVICES = (\"akkoma\", \"tuwunel\", \"phpbb\")', 'BUILTIN_DEFAULT_SERVICES = (\"tuwunel\", \"phpbb\")', 1)" || return 1
  edit specs/cluster/optional-services.yaml "re.sub(r'(- slug: akkoma\n(?:.*\n)*?\s+)default: on', r'\1default: off', s, count=1)" || return 1
  edit specs/cluster/manifests/policy/installed-services-configmap.yaml "s.replace('  akkoma: \"true\"', '  akkoma: \"false\"', 1)" || return 1
  edit specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml "re.sub(r'(slug: akkoma\n\s+)enabled: true', r'\1enabled: false', s, count=1)" || return 1
  edit specs/cluster/manifests/federation-modules-gate/sql/gate.sql "s.replace(\"enabled = true WHERE slug = 'mastodon'\", \"enabled = false WHERE slug = 'mastodon'\", 1)" || return 1
  edit specs/cluster/manifests/test-runner/kustomization.yaml "re.sub(r'(?m)^  - akkoma-peer\.yaml\n', '  # - akkoma-peer.yaml\n', s, count=1)" || return 1
}

# expect NAME TAG FILE EXPR [FILE EXPR ...]: the mutated copy must fail with [TAG].
# PRE=prepublish starts from the pre-release state instead of the real tree; NEED=<text>
# also requires a FAIL [TAG] line to contain <text> (the source the check must name).
expect() {
  local name="$1" tag="$2"; shift 2
  fresh "m$((pass + fail))"
  if [ -n "${PRE:-}" ] && ! "${PRE}" 2>"${T}.err"; then bad "control '${name}': ${PRE}: $(cat "${T}.err")"; return; fi
  while [ $# -gt 0 ]; do
    if ! edit "$1" "$2" 2>"${T}.err"; then bad "control '${name}': $(cat "${T}.err")"; return; fi
    shift 2
  done
  local o rc=0
  o="$(python3 -I "${CHECK}" "${T}" 2>&1)" || rc=$?
  if [ "${rc}" != 0 ] && printf '%s\n' "${o}" | grep -F "  FAIL [${tag}]" | grep -F -- "${NEED:-  FAIL}" >/dev/null; then
    ok "control '${name}' -> caught by [${tag}]${NEED:+ naming ${NEED}}"
  else
    bad "control '${name}' -> NOT caught by [${tag}]${NEED:+ naming ${NEED}} (rc ${rc}): $(printf '%s\n' "${o}" | grep FAIL | head -3 | tr '\n' ';')"
  fi
}

echo "== negative controls: each planted defect must fail =="
expect "the dead registry host is back in akkoma.yaml" dead-host \
  "${AK}" "s.replace('image: ${NAMETAG}', 'image: git.akkoma.dev/akkomagang/akkoma:stable', 1)"
expect "the unofficial compose-lane image in a manifest" dead-host \
  "${PEER}" "s.replace('${PIN}', 'teslamint/akkoma:v3.20.0', 1)"
expect "a ref pinned by tag only" refs \
  "${AS}" "s.replace('${PIN}', '${NAMETAG}', 1)"
expect "a ref on another registry" refs \
  "${AS}" "s.replace('ghcr.io/hugmesh/hugmesh-akkoma', 'docker.io/hugmesh/hugmesh-akkoma', 1)"
expect "a new Akkoma ref in a new file, tag only" refs \
  specs/cluster/manifests/akkoma/kustomization.yaml "s + '\n# extra\n---\n# x\n' + 'images:\n  - name: foo\n    newName: hugmesh/akkoma-extra\n'"
expect "both test-runner refs dropped" sites \
  "${PEER}" "s.replace('image: ${PIN}', 'image: busybox')"
expect "two different digests" lockstep \
  "${AK}" "s.replace('@sha256:${DIG}', '@sha256:${R64}', 1)"
expect "a real digest that still says PLACEHOLDER" placeholder \
  "${AK}" "s.replace('${PIN}', '${PIN}   # PLACEHOLDER digest: stale', 1)"
PRE=prepublish expect "the placeholder line lost its marker" placeholder \
  "${AS}" "re.sub(r'(hugmesh-akkoma@sha256:0+)\s+# PLACEHOLDER digest[^\n]*', r'\1', s, count=1)"
# Each default source on its own, with the placeholder back: [defaults] must name it.
PRE=prepublish NEED=_optional-services-lib.sh expect "placeholder + akkoma in the builder lib default" defaults \
  scripts/_optional-services-lib.sh "s.replace('_OPT_BUILTIN_DEFAULT_SERVICES=\"tuwunel phpbb\"', '_OPT_BUILTIN_DEFAULT_SERVICES=\"akkoma tuwunel phpbb\"', 1)"
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh; do
  PRE=prepublish NEED="${b}" expect "placeholder + akkoma in the ${b} default" defaults \
    "${b}" "s.replace('OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-tuwunel phpbb}\"', 'OPTIONAL_SERVICES=\"\${OPTIONAL_SERVICES:-akkoma tuwunel phpbb}\"', 1)"
done
PRE=prepublish NEED='scripts/build-menu.sh: if [ -z' expect "placeholder + build-menu pre-ticks akkoma" defaults \
  scripts/build-menu.sh "s.replace('cur=\"tuwunel,phpbb\"', 'cur=\"akkoma,tuwunel,phpbb\"', 1)"
PRE=prepublish NEED='OPT_SERVICES="akkoma' expect "placeholder + build-menu's OPT_SERVICES default names akkoma" defaults \
  scripts/build-menu.sh "re.sub(r'(?m)^OPT_SERVICES=\"\"', 'OPT_SERVICES=\"akkoma,tuwunel,phpbb\"', s, count=1)"
PRE=prepublish NEED=config.py expect "placeholder + akkoma in Studio's BUILTIN_DEFAULT_SERVICES" defaults \
  studio/hugmesh_studio/core/config.py "s.replace('BUILTIN_DEFAULT_SERVICES = (\"tuwunel\", \"phpbb\")', 'BUILTIN_DEFAULT_SERVICES = (\"akkoma\", \"tuwunel\", \"phpbb\")', 1)"
PRE=prepublish NEED=optional-services.yaml expect "placeholder + registry akkoma default: on" defaults \
  specs/cluster/optional-services.yaml "re.sub(r'(- slug: akkoma\n(?:.*\n)*?\s+)default: off', r'\1default: on', s, count=1)"
PRE=prepublish NEED=installed-services-configmap.yaml expect "placeholder + installed-services baseline akkoma true" defaults \
  specs/cluster/manifests/policy/installed-services-configmap.yaml "s.replace('  akkoma: \"false\"', '  akkoma: \"true\"', 1)"
PRE=prepublish NEED=seed-optionalservices.yaml expect "placeholder + seed OptionalService akkoma enabled" defaults \
  specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml "re.sub(r'(slug: akkoma\n\s+)enabled: false', r'\1enabled: true', s, count=1)"
PRE=prepublish NEED=gate.sql expect "placeholder + federation gate.sql mastodon on" defaults \
  specs/cluster/manifests/federation-modules-gate/sql/gate.sql "s.replace(\"enabled = false WHERE slug = 'mastodon'\", \"enabled = true WHERE slug = 'mastodon'\", 1)"
PRE=prepublish NEED=kustomization.yaml expect "placeholder + the test-runner bundle wires akkoma-peer" defaults \
  specs/cluster/manifests/test-runner/kustomization.yaml "s.replace('  # - akkoma-peer.yaml\n', '  - akkoma-peer.yaml\n', 1)"
expect "an unreadable default source fails closed" defaults \
  scripts/_optional-services-lib.sh "s.replace('_OPT_BUILTIN_DEFAULT_SERVICES=', '_OPT_DEFAULTS=', 1)"
expect "akkoma-config loses its upload base_url" config \
  "${AK}" "re.sub(r'(?m)^    config :pleroma, Pleroma\.Upload, base_url: [^\n]*\n', '', s, count=1)"
expect "akkoma-config's base_url only in a comment" config \
  "${AK}" "re.sub(r'(?m)^    (config :pleroma, Pleroma\.Upload, base_url:)', r'    # \1', s, count=1)"
expect "the test-runner peer loses its upload base_url" config \
  "${PEER}" "re.sub(r'(?m)^    config :pleroma, Pleroma\.Upload, base_url: [^\n]*\n', '', s, count=1)"
expect "the smoke test stops booting the cluster's own akkoma-config" config \
  images/akkoma/smoke-test.sh "s.replace('\"akkoma-config|\$akkoma_manifest\" ', '', 1)"
expect "deps.get without --check-locked" dockerfile \
  images/akkoma/Dockerfile "s.replace('mix deps.get --only prod --check-locked', 'mix deps.get --only prod', 1)"
expect "rebar3 back to whatever hex lists newest" dockerfile \
  images/akkoma/Dockerfile "s.replace('mix local.rebar rebar3 \"\$REBAR3_URL\" --sha512 \"\$REBAR3_SHA512\" --force', 'mix local.rebar --force', 1)"
expect "the rebar3 checksum is not a SHA-512" dockerfile \
  images/akkoma/Dockerfile "re.sub(r'(ARG REBAR3_SHA512=)[0-9a-f]{128}', r'\1deadbeef', s, count=1)"
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
expect "the release drops arm64" release-wf \
  "${REL}" "s.replace('platforms: linux/amd64,linux/arm64\n          pull: true\n          push: true', 'platforms: linux/amd64\n          pull: true\n          push: true', 1)"
expect "the publishing job moves to a self-hosted runner" release-wf \
  "${REL}" "s.replace('  image:\n    needs: version\n    runs-on: ubuntu-latest', '  image:\n    needs: version\n    runs-on: self-hosted', 1)"
expect "the release boot test is switched off" release-wf \
  "${REL}" "s.replace(\"      - name: Boot-test the image before pushing it\n        if: steps.exists.outputs.skip != 'true'\n\", \"      - name: Boot-test the image before pushing it\n        if: false\n\", 1)"
expect "the release boot test may fail and the push goes on" release-wf \
  "${REL}" "s.replace(\"      - name: Boot-test the image before pushing it\n        if: steps.exists.outputs.skip != 'true'\n\", \"      - name: Boot-test the image before pushing it\n        if: steps.exists.outputs.skip != 'true'\n        continue-on-error: true\n\", 1)"
expect "the PR boot test is switched off" pr-wf \
  "${CI}" "s.replace('      - name: Boot-test the image\n', '      - name: Boot-test the image\n        if: false\n', 1)"
expect "the PR build no longer runs when akkoma.yaml changes" pr-wf \
  "${CI}" "s.replace(\"      - 'specs/cluster/manifests/akkoma/akkoma.yaml'\n\", '', 1)"
expect "the PR build moves to a self-hosted runner" pr-wf \
  "${CI}" "s.replace('runner: ubuntu-latest', 'runner: self-hosted', 1)"
expect "the PR build loses its native arm64 leg" pr-wf \
  "${CI}" "s.replace('runner: ubuntu-24.04-arm', 'runner: ubuntu-latest', 1)"
expect "the PR build gains packages: write" pr-wf \
  "${CI}" "s.replace('permissions:\n  contents: read', 'permissions:\n  contents: read\n  packages: write', 1)"
expect "the PR build logs in to a registry" pr-wf \
  "${CI}" "s.replace('      - name: Set up Docker Buildx', '      - uses: docker/login-action@v3\n      - name: Set up Docker Buildx', 1)"
expect "the PR build also runs on push" pr-wf \
  "${CI}" "s.replace('on:\n  pull_request:', 'on:\n  push:\n    branches: [main]\n  pull_request:', 1)"

echo "== positive control: the pre-release state (placeholder, akkoma off everywhere) passes =="
# The real tree (above) is the published digest with akkoma default-on. This is the
# state before the first release; it must stay legal, so a future image that has to go
# back to a placeholder can, by turning every default off again.
fresh positive
if prepublish 2>"${T}.err"; then
  o="$(python3 -I "${CHECK}" "${T}" 2>&1)"; rc=$?
  if [ "${rc}" = 0 ] && printf '%s\n' "${o}" | grep -F '  PASS [placeholder] the digest is the PLACEHOLDER' >/dev/null; then
    ok "the placeholder with akkoma off in every default source passes"
  else
    bad "the pre-release state was refused (rc ${rc}): $(printf '%s\n' "${o}" | grep FAIL | head -3 | tr '\n' ';')"
  fi
else
  bad "positive control: prepublish could not rewrite the copy: $(cat "${T}.err")"
fi

# ── branded meshes keep the HugMesh-published image ─────────────────────────
# rebrand_sysroot rewrites `hugmesh-` to `<brand>-` and `hugmesh` to `<org>` across the
# baked cluster tree. Without its @@SDSYSAKKOMAIMG@@ rule every Akkoma ref became
# ghcr.io/<org>/<brand>-akkoma@<this digest>, a name that holds no such image. Each of
# the three builders that bake specs/cluster is driven here with a custom brand and
# org: the Akkoma refs must survive byte for byte, a neighbouring HugMesh image must
# still rebrand (the rule must not over-protect), and no sentinel may leak. Then the
# rule is deleted from each builder's copy and the same run must notice.
echo "== branded meshes: rebrand_sysroot keeps ghcr.io/hugmesh/hugmesh-akkoma =="
extract_fn() { awk "/^$1\\(\\) \\{/{p=1} p{print} /^\\}/{if(p){exit}}" "$2"; }
rebrand_run() { # builder-file sysroot -> rebrands the sysroot with a custom brand/org
  (
    info() { :; }; warn() { :; }; banner() { :; }
    eval "$(extract_fn _sed_rep_escape "$1")"
    eval "$(extract_fn rebrand_sysroot "$1")"
    BRAND=acme BRAND_TITLE="Acme Mesh" CLUSTER_DOMAIN=example.org ORG=acmeorg \
      GAMES_DOMAIN=games.example.org HARBOR_PROJECT="" SYSROOT="$2"
    rebrand_sysroot
  )
}
brand_case() { # builder-file label -> prints PASS/FAIL detail on stdout, rc 0 = the Akkoma refs survived
  local b="$1" sr="${TMP}/brand-$2" d
  rm -rf "${sr}"
  d="${sr}/var/lib/hugmesh/cluster/manifests"
  mkdir -p "${d}/akkoma" "${d}/test-runner" "${d}/probe"
  cp "${REPO}/${AK}" "${REPO}/${AS}" "${REPO}/${DL}" "${d}/akkoma/"
  cp "${REPO}/${PEER}" "${d}/test-runner/"
  printf 'image: ghcr.io/hugmesh/hugmesh-mesh-node:main\n' > "${d}/probe/neighbour.yaml"
  rebrand_run "${b}" "${sr}" >/dev/null 2>&1
  local want got neighbour leak
  want="$(cd "${REPO}" && grep -h 'ghcr\.io/hugmesh/hugmesh-akkoma' "${AK}" "${AS}" "${DL}" "${PEER}" | sort)"
  got="$(grep -rh 'ghcr\.io/hugmesh/hugmesh-akkoma' "${d}/akkoma" "${d}/test-runner" | sort)"
  neighbour="$(cat "${d}/probe/neighbour.yaml")"
  leak="$(grep -rl '@@SDSYS' "${sr}" || true)"
  if [ -z "${want}" ]; then echo "no Akkoma ref in the real manifests"; return 2; fi
  if [ "${neighbour}" != "image: ghcr.io/acmeorg/acme-mesh-node:main" ]; then
    echo "the rebrand did not run (neighbour HugMesh image is '${neighbour}')"; return 2
  fi
  if [ -n "${leak}" ]; then echo "a sentinel leaked into: ${leak}"; return 1; fi
  if [ "${got}" != "${want}" ]; then echo "Akkoma refs became: $(printf '%s' "${got}" | head -n 2 | tr '\n' ';')"; return 1; fi
  echo "$(printf '%s\n' "${want}" | wc -l) lines naming the image unchanged, neighbour rebranded to ghcr.io/acmeorg/acme-mesh-node"
}
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh build-jetson-stage4.sh; do
  msg="$(brand_case "${REPO}/${b}" "${b%%-stage4.sh}")"; rc=$?
  if [ "${rc}" = 0 ]; then ok "${b}: ${msg}"; else bad "${b}: ${msg}"; fi
  # control: the same builder without the rule must lose the refs
  cp "${REPO}/${b}" "${TMP}/${b}"
  sed -i '/@@SDSYSAKKOMAIMG@@/d' "${TMP}/${b}"
  if cmp -s "${REPO}/${b}" "${TMP}/${b}"; then
    bad "control '${b} without its Akkoma rule': the mutation changed nothing"
  else
    msg="$(brand_case "${TMP}/${b}" "${b%%-stage4.sh}-ctl")"; rc=$?
    if [ "${rc}" = 1 ]; then ok "control '${b} without its Akkoma rule' -> refs rebranded, caught"
    else bad "control '${b} without its Akkoma rule' -> NOT caught (rc ${rc}): ${msg}"; fi
  fi
done

echo "== test-akkoma-image-pin.sh: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
