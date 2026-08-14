#!/usr/bin/env bash
# test-image-builder-always-on.sh — gate for the ALWAYS-ON in-cluster Kaniko
# image-build pipeline. Pure PyYAML + bash; no cluster, no kubectl, no network.
#
# WHY THIS EXISTS. Before this gate, NOTHING in CI referenced the image-builder — not
# one test in the repo mentioned it. That mattered for three reasons:
#
#   1. The pipeline's on/off switch is the DIRECTORY A FILE SITS IN. The ArgoCD root
#      app-of-apps syncs `specs/cluster/apps` with `directory.recurse: true`, so moving
#      60-image-builder.yaml from the parked `apps-optional/` sibling into `apps/` is what
#      makes ArgoCD start creating the build namespace. A plain `git mv` — or a later
#      `git mv` back, or a root whose `path:`/`recurse:` quietly changed — flips live
#      cluster behaviour with no code change and no signal.
#   2. The `build:images` dispatcher's defaults still named `snapdragon-gateway`, a repo the
#      org-wide rebrand retired. So did all 19 entries of the `sca:dependency-check` matrix,
#      whose before_script CLONES each name. Nothing checked that the repo's own CI referred
#      to repos that exist.
#   3. The Job template's `${...}` placeholder set and the dispatcher's `sed -e` bindings are
#      two independently-maintained lists. A placeholder bound by neither ships a Job with a
#      literal `${DEST_IMAGE}` in an image reference — and a placeholder bound to the WRONG
#      value silently inverts the immutable and moving push destinations.
#   4. Retiring the opt-in guard turned `build:images` into a job that can really fail, and
#      it sits in a stage BEFORE sca and dast. Neither of those declares `needs:`, so a hard
#      failure here would stop the OWASP Dependency-Check SCA and the ZAP DAST stages from
#      running on the default branch — collateral that appears nowhere in the diff.
#
# Each check below carries a NEGATIVE CONTROL: the same assertion is re-run against a
# deliberately-corrupted staged copy of the tree and MUST fail there, so a green run cannot
# be vacuous.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

CHECKER="$(dirname "${BASH_SOURCE[0]}")/image_builder_always_on.py"
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

echo "== image-builder always-on gate =="
echo "-- positive: the repo's own tree must pass every check --"
python3 "${CHECKER}" "${REPO}"
RC=$?
if [ "${RC}" -ne 0 ]; then
  echo
  echo "== image-builder always-on: FAIL (see above) =="
  exit 1
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Stage a copy of the surface, inject ONE defect of each class, and require the
# corresponding check to bite. Without these the whole gate could be a no-op.
echo
echo "-- negative controls: each injected defect must be caught --"
NEG_P=0; NEG_F=0
neg_ok(){ echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad(){ echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# expect_catch <description> <expected-check-tag> <mutation-shell>
# Stages a pristine copy at $T, runs the mutation, and requires the checker to fail
# WITH the named tag (not merely to fail — a mutation that trips an unrelated check
# would otherwise look like proof).
expect_catch() {
  local desc="$1" tag="$2" mut="$3"
  local T="${WORK}/t"
  rm -rf "${T}"; mkdir -p "${T}"
  cp "${REPO}/.gitlab-ci.yml" "${T}/.gitlab-ci.yml"
  mkdir -p "${T}/specs"
  cp -r "${REPO}/specs/cluster" "${T}/specs/cluster"
  export T
  if ! ( eval "${mut}" ); then
    neg_bad "${desc} (mutation itself failed to apply)"
    return
  fi
  local out rc
  out="$(python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ]; then
    neg_bad "${desc} — checker still PASSED"
  elif ! printf '%s' "${out}" | grep -qF "${tag}"; then
    neg_bad "${desc} — checker failed, but not on ${tag}:"
    printf '%s\n' "${out}" | sed 's/^/        /'
  else
    neg_ok "${desc} => ${tag}"
  fi
}

# (1) THE FLIP ITSELF, REVERSED: park the Application back in apps-optional/, the
#     directory no ArgoCD root recurses. This is exactly the state before this change,
#     and the single most important thing this gate exists to notice.
expect_catch "Application moved back to apps-optional/ (ships dark again)" "[app-location]" '
  mkdir -p "$T/specs/cluster/apps-optional"
  mv "$T/specs/cluster/apps/60-image-builder.yaml" \
     "$T/specs/cluster/apps-optional/60-image-builder.yaml"
'
# (1b) a copy left in BOTH directories — two Applications of the same name.
expect_catch "Application duplicated into apps-optional/" "[app-location]" '
  mkdir -p "$T/specs/cluster/apps-optional"
  cp "$T/specs/cluster/apps/60-image-builder.yaml" \
     "$T/specs/cluster/apps-optional/60-image-builder.yaml"
'
# (2) the root stops recursing — apps/ is no longer the always-synced set, so the
#     file being in apps/ would no longer mean anything.
expect_catch "root app-of-apps stops recursing apps/" "[always-synced]" '
  sed -i "s/      recurse: true/      recurse: false/" "$T/specs/cluster/app-of-apps.yaml"
'
# (2b) the waved alternative root excludes it.
expect_catch "waved root excludes 60-image-builder.yaml" "[always-synced]" '
  sed -i "s/exclude: .{00-app-of-apps-waved.yaml}./exclude: \x27{00-app-of-apps-waved.yaml,60-image-builder.yaml}\x27/" \
      "$T/specs/cluster/apps/00-app-of-apps-waved.yaml"
'
# (3) the Application points at a manifest directory that does not exist.
expect_catch "Application source.path points nowhere" "[app-structure]" '
  sed -i "s|path: specs/cluster/manifests/image-builder|path: specs/cluster/manifests/image-builder-TYPO|" \
      "$T/specs/cluster/apps/60-image-builder.yaml"
'
# (3b) CreateNamespace=false dropped — ArgoCD and the kustomization both try to own
#      the namespace.
expect_catch "Application drops syncOptions CreateNamespace=false" "[app-structure]" '
  sed -i "s/    syncOptions: \[CreateNamespace=false\]/    syncOptions: [CreateNamespace=true]/" \
      "$T/specs/cluster/apps/60-image-builder.yaml"
'
# (4) the synced namespace stops enforcing PSS restricted — build pods run arbitrary
#     Dockerfiles, so this is the containment boundary.
expect_catch "build namespace drops Pod Security restricted" "[manifests]" '
  sed -i "s|pod-security.kubernetes.io/enforce: restricted|pod-security.kubernetes.io/enforce: baseline|" \
      "$T/specs/cluster/manifests/image-builder/namespace-and-netpol.yaml"
'
# (4b) the default-deny ingress policy gains an allow rule.
expect_catch "build namespace NetworkPolicy stops being default-deny ingress" "[manifests]" '
  python3 - "$T" <<'"'"'PY'"'"'
import sys
p=sys.argv[1]+"/specs/cluster/manifests/image-builder/namespace-and-netpol.yaml"
s=open(p,encoding="utf-8").read()
anchor="  policyTypes: [Ingress]\n  ingress: []"
assert s.count(anchor)==1, "anchor not found: mutation would be a no-op"
s=s.replace(anchor,"  policyTypes: [Ingress]\n  ingress:\n    - {}",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (5) the Kaniko Job template gets added to the kustomization — ArgoCD would apply an
#     UNRENDERED Job (literal ${...} in the image ref) on every sync.
expect_catch "Job template added to the kustomization (stops shipping dark)" "[ships-dark]" '
  printf "  - kaniko-build-job.template.yaml\n" \
      >> "$T/specs/cluster/manifests/image-builder/kustomization.yaml"
'
# (6) the ESO push credential targets a namespace nothing creates.
expect_catch "push-credential ExternalSecret targets the wrong namespace" "[eso]" '
  sed -i "s/  namespace: hugmesh-image-builds/  namespace: hugmesh-image-builds-TYPO/" \
      "$T/specs/cluster/manifests/external-secrets/image-builder-externalsecrets.yaml"
'
# (7) THE GUARD, REINSTATED: the opt-in early-exit comes back, so every dispatched
#     build silently no-ops while the pipeline stays green.
#     NB the heredoc delimiter is QUOTED: an unquoted <<PY would let the shell expand
#     ${IMAGE_BUILDER_ENABLED:-} to nothing before Python ever saw it, injecting a guard
#     with the token stripped out — a mutation that applies cleanly and proves nothing.
expect_catch "IMAGE_BUILDER_ENABLED opt-in guard reinstated" "[ci-guard]" '
  python3 - "$T" <<'"'"'PY'"'"'
import sys
p=sys.argv[1]+"/.gitlab-ci.yml"
s=open(p,encoding="utf-8").read()
anchor="  script:\n    - |\n      # TAG SCHEME"
assert s.count(anchor)==1, "anchor not found: mutation would be a no-op"
s=s.replace(anchor,
            "  script:\n    - |\n      if [ -z \"${IMAGE_BUILDER_ENABLED:-}\" ]; then exit 0; fi\n      # TAG SCHEME",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (8) the CI dispatcher and the synced namespace drift apart.
expect_catch "build:images BUILD_NAMESPACE drifts from the synced Namespace" "[ci-contract]" '
  sed -i "s/    BUILD_NAMESPACE: \"hugmesh-image-builds\"/    BUILD_NAMESPACE: \"hugmesh-image-builds-old\"/" \
      "$T/.gitlab-ci.yml"
'
# (8b) a sed binding is dropped — the applied Job carries a literal ${DOCKERFILE}.
expect_catch "a sed placeholder binding is dropped from build:images" "[ci-contract]" '
  sed -i "/s|\\\\\${DOCKERFILE}|/d" "$T/.gitlab-ci.yml"
'
# (8c) the git context goes back to this repo'"'"'s CI_COMMIT_SHA, which is not a ref in
#      the app repo being built — every build fails in Kaniko'"'"'s clone.
expect_catch "IMAGE_CONTEXT pinned to this repo's CI_COMMIT_SHA" "[ci-contract]" '
  sed -i "s|hugmesh-gateway.git#\${IMAGE_REF}|hugmesh-gateway.git#\${CI_COMMIT_SHA}|" \
      "$T/.gitlab-ci.yml"
'
# (8d) THE BINDING INVERTED rather than dropped: the sed REPLACEMENT expressions for
#      ${DEST_IMAGE} and ${DEST_IMAGE_MOVING} are swapped. The pattern side — all this
#      check originally scraped — stays byte-identical, so the placeholder/binding set
#      comparison still balances; but the rendered Job pushes the moving tag twice and
#      never pushes the immutable one. This mutation PASSED before both sides were checked.
expect_catch "sed replacements for \${DEST_IMAGE} / \${DEST_IMAGE_MOVING} swapped" "[ci-contract]" '
  python3 - "$T" <<'"'"'PY'"'"'
import sys
p=sys.argv[1]+"/.gitlab-ci.yml"
s=open(p,encoding="utf-8").read()
a=r"s|\${DEST_IMAGE_MOVING}|${DEST_IMAGE_MOVING}|g"
b=r"s|\${DEST_IMAGE}|${DEST_IMAGE}|g"
assert s.count(a)==1 and s.count(b)==1, "anchors not found: mutation would be a no-op"
s=s.replace(a,"@@SWAP@@").replace(b,r"s|\${DEST_IMAGE}|${DEST_IMAGE_MOVING}|g")
s=s.replace("@@SWAP@@",r"s|\${DEST_IMAGE_MOVING}|${DEST_IMAGE}|g")
open(p,"w",encoding="utf-8").write(s)
PY
'
# (8e) THE PIPELINE COLLATERAL: allow_failure is dropped from build:images. The job then
#      hard-fails on every default-branch pipeline (it dispatches into a cluster that does
#      not exist yet), and because sca/dast/load declare no `needs:`, plain stage ordering
#      stops the OWASP Dependency-Check SCA and the ZAP DAST security stages from running
#      on main at all. Nothing in the diff would show that.
expect_catch "build:images can block the later sca/dast stages" "[ci-pipeline]" '
  python3 - "$T" <<'"'"'PY'"'"'
import sys
p=sys.argv[1]+"/.gitlab-ci.yml"
s=open(p,encoding="utf-8").read()
anchor="  allow_failure: true\n  rules:\n    - if: \x27$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\x27"
assert s.count(anchor)==1, "anchor not found: mutation would be a no-op"
s=s.replace(anchor,"  rules:\n    - if: \x27$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\x27",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (8f) ANTI-VACUITY for 8e: the ordering check must measure the real GitLab rule, not just
#      "allow_failure is present". Remove allow_failure AND give every later-stage job its
#      own `needs: []` — that genuinely decouples them, so the checker must go GREEN. If it
#      still failed, 8e would be proving nothing but the presence of a token.
T="${WORK}/needs-escape"; rm -rf "${T}"; mkdir -p "${T}/specs"
cp "${REPO}/.gitlab-ci.yml" "${T}/.gitlab-ci.yml"
cp -r "${REPO}/specs/cluster" "${T}/specs/cluster"
if python3 - "${T}" <<'PY'
import sys
p=sys.argv[1]+"/.gitlab-ci.yml"
s=open(p,encoding="utf-8").read()
anchor="  allow_failure: true\n  rules:\n    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'"
assert s.count(anchor)==1, "allow_failure anchor not found"
s=s.replace(anchor,"  rules:\n    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'",1)
for a in ("sca:dependency-check:\n  stage: sca\n",".dast-base:\n  stage: dast\n",".load-base:\n  stage: load\n"):
    assert s.count(a)==1, "stage anchor not found: "+a
    s=s.replace(a,a+"  needs: []\n",1)
open(p,"w",encoding="utf-8").write(s)
PY
then
  if python3 "${CHECKER}" "${T}" >/dev/null 2>&1; then
    neg_ok "a real \`needs: []\` decoupling is accepted without allow_failure (8e is not token-matching)"
  else
    neg_bad "the ordering check rejects a genuine \`needs: []\` decoupling — it is matching on allow_failure, not on blocking"
  fi
else
  neg_bad "8f mutation itself failed to apply"
fi
# (8g) ANTI-VACUITY for the job walk: without `stages:` the ordering check cannot mean
#      anything, so it must say so rather than pass by default.
expect_catch "stages: list removed (ordering check would be vacuous)" "[ci-pipeline]" '
  sed -i "/^stages: \[/d" "$T/.gitlab-ci.yml"
'
# (9) A PRE-REBRAND IDENTIFIER, REINSTATED: the retired repo name comes back in the
#     dispatcher defaults.
expect_catch "stale snapdragon-gateway repo name reinstated in build:images" "[pre-rebrand]" '
  sed -i "s|    IMAGE_APP: \"hugmesh-gateway\"|    IMAGE_APP: \"snapdragon-gateway\"|" \
      "$T/.gitlab-ci.yml"
'
# (9b) a retired name reinstated in the SCA clone matrix (the class that broke all 19).
expect_catch "stale repo name reinstated in the sca:dependency-check matrix" "[pre-rebrand]" '
  sed -i "s|          - hugmesh-admin-ui|          - snapdragon-admin-ui|" "$T/.gitlab-ci.yml"
'
# ── 9c-9h: THE FUNCTIONAL `snapdragon.systems/<path>` SHAPE ───────────────────────────
# The old brand survives legitimately in exactly two syntactic positions (see 9d). The
# check used to enforce that by DELETING those two literals from each line before scanning
# it — which also deleted them from every functional identifier that merely contains them,
# because a registry host, a git host and a repoURL all take the form
# `<host-or-scheme>snapdragon.systems/<path>`. Every mutation below passed the gate with
# exit 0 until the allowlist became positional. 9c used to plant
# `registry.snapdragon.systems;` — a form with a SEMICOLON and no trailing slash, which the
# strip therefore never touched — so it bit while appearing to cover this whole class.
#
# (9c) the retired brand as the REGISTRY HOST in the synced Job template: where every image
#      this pipeline builds gets pushed.
expect_catch "retired brand as the registry host in the Job template" "[pre-rebrand]" '
  sed -i "s|registry.hugmesh.net/hugmesh/|registry.snapdragon.systems/hugmesh/|g" \
      "$T/specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml"
'
# (9e) the retired brand as the registry host in the dispatcher'"'"'s PUSH destination.
expect_catch "retired brand as the registry host in build:images DEST_REPO" "[pre-rebrand]" '
  sed -i "s|DEST_REPO: \"registry.hugmesh.net/|DEST_REPO: \"registry.snapdragon.systems/|" \
      "$T/.gitlab-ci.yml"
'
# (9f) the retired brand as the GIT HOST in the Application repoURL — the field that decides
#      whether ArgoCD can sync the always-on app at all.
#      The org segment is matched as a WILDCARD, not pinned: forks legitimately rehome this
#      repoURL onto their own org (hugmesh, hugmesh-net, a tenant org), and pinning one
#      spelling silently turns this control into a no-op on every other tree.
expect_catch "retired brand as the git host in the Application repoURL" "[pre-rebrand]" '
  sed -i -E "s|repoURL: https://github.com/[^/]+/hugmesh-generator.git|repoURL: https://git.snapdragon.systems/hugmesh/hugmesh-generator.git|" \
      "$T/specs/cluster/apps/60-image-builder.yaml"
'
# (9g) the RETIRED label-KEY namespace. `snapdragon.systems/<name>:` in mapping-KEY position
#      used to be exempt as frozen wire identity. The label keys have since migrated to
#      `hugmesh.net/<name>` (hugmesh carries no .systems token at all), so that exemption is
#      gone and the old key must now be caught EVEN IN the position that used to make it
#      exempt. This is the inverse of the old 9g: it pins the REMOVAL of the exemption, so
#      re-adding entry (a) would fail this control.
expect_catch "retired label-key namespace in the mapping-key position it used to be exempt in" "[pre-rebrand]" '
  sed -i "s|    hugmesh.net/image-build:|    snapdragon.systems/image-build:|g" \
      "$T/specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml"
'
# (9h) the RETIRED org segment: `github.com/Snapdragon-Systems/` used to be allowlisted as
#      the live org path. Git hosting moved to github.com/hugmesh/, so that exemption is
#      gone and the old org path must now be caught ANYWHERE — including under the very
#      github.com host that used to make it exempt. This is the inverse of the old 9h:
#      it pins the REMOVAL of the exemption, so restoring it would fail this control.
expect_catch "retired org segment under the github.com host it used to be exempt under" "[pre-rebrand]" '
  sed -i -E "s|repoURL: https://github.com/[^/]+/hugmesh-generator.git|repoURL: https://github.com/Snapdragon-Systems/hugmesh-generator.git|" \
      "$T/specs/cluster/apps/60-image-builder.yaml"
'
# (9i) RETIRED WITH ENTRY (a). This used to prove that entry (a)'"'"'s label-NAME charset
#      admitted no second slash, so a `host/project/repo` identifier could not be smuggled
#      into mapping-key position to inherit the frozen prefix'"'"'s exemption. With entry (a)
#      deleted there is no prefix left to borrow — any snapdragon.systems spelling is caught
#      in every position, which 9g now proves directly — so the control has no subject.
#      Deliberately not replaced with a weaker variant: a control that cannot fail is worse
#      than no control, because it reads as coverage.
# (9j) THIRD ALLOWLIST ANCHOR, same test: the legacy `snapdragon-deploy.yaml` descriptor
#      filename is exempt only as a WHOLE filename token. Re-used as a registry HOST it is
#      an ordinary stale identifier and must be caught, or entry (c) becomes a textual
#      blanket mute for anything containing that string.
expect_catch "legacy deploy-descriptor filename re-used as a registry host" "[pre-rebrand]" '
  sed -i "s|DEST_REPO: \"registry.hugmesh.net/|DEST_REPO: \"registry.snapdragon-deploy.yaml/|" \
      "$T/.gitlab-ci.yml"
'
# (9d) POSITIVE CONTROL for the ONE surviving allowlist entry: the legacy
#      `snapdragon-deploy.yaml` descriptor FILENAME must NOT be flagged. It is still shipped
#      on disk by 6 of the 9 adopting repos and both catalog generators deliberately accept
#      it, so flagging it would push someone to "fix" a live filename and make those repos
#      invisible to the catalog. Together with 9j (same filename re-used as a registry HOST
#      must be caught) this pins the exemption to the POSITION, not the spelling.
#      Both other halves of this control are gone: entry (a) (label keys) and entry (b)
#      (the GitHub org path) were retired, and 9g/9h now assert the OPPOSITE for those two —
#      that they ARE caught — so asserting their exemption here would contradict them.
T="${WORK}/allowlist"; rm -rf "${T}"; mkdir -p "${T}/specs"
cp "${REPO}/.gitlab-ci.yml" "${T}/.gitlab-ci.yml"
cp -r "${REPO}/specs/cluster" "${T}/specs/cluster"
if grep -q 'snapdragon-deploy\.yaml' "${T}/.gitlab-ci.yml" \
   && python3 "${CHECKER}" "${T}" >/dev/null 2>&1; then
  neg_ok "legacy snapdragon-deploy.yaml descriptor filename is NOT flagged"
else
  neg_bad "allowlist positive control: the legacy descriptor filename was absent or wrongly flagged"
fi

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
[ "${NEG_F}" -eq 0 ] || exit 1
echo "== image-builder always-on: PASS =="
exit 0
