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
#   2. The `build:images` dispatcher's defaults still named a pre-rebrand gateway repo the
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
# The retired pre-rebrand brand stem, spelled from PARTS so this file never carries it
# whole (hugmesh repositories must not name the operator's private target). The
# mutations below plant it into staged copies only.
RB="snap""dragon"
export RB

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

CHECKER="$(dirname "${BASH_SOURCE[0]}")/image_builder_always_on.py"
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

echo "== image-builder always-on gate =="
echo "-- positive: the repo's own tree must pass every check --"
python3 "${CHECKER}" "${REPO}"
POS_RC=$?
if [ "${POS_RC}" -ne 0 ]; then
  # DELIBERATELY NOT `exit 1` HERE. This used to bail the instant the positive run found
  # anything, which meant ONE soft finding on the real tree blinded all 27 negative
  # controls below — including the very controls that say whether the check which
  # produced that finding is still wired up at all. That happened for real: 857e84d9
  # reflowed a prose comment in .gitlab-ci.yml, the old surface-count anti-vacuity check
  # went red, and the whole battery stopped running with nothing wrong in the product.
  # The run still FAILS at the end; it just reports the state of its own controls first.
  echo
  echo "  NOTE: the repo's own tree does not pass. The negative controls below still run,"
  echo "  so one finding cannot blind the battery — but read them as DIAGNOSTIC while the"
  echo "  tree is red: expect_catch only requires the named tag to appear, so a finding the"
  echo "  real tree ALREADY has can satisfy a control aimed at that same tag. This run fails"
  echo "  regardless of what they say."
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
  elif ! printf '%s' "${out}" | grep -F "${tag}" >/dev/null; then
    neg_bad "${desc} — checker failed, but not on ${tag}:"
    printf '%s\n' "${out}" | sed 's/^/        /'
  else
    neg_ok "${desc} => ${tag}"
  fi
}

# expect_clean_tag <description> <check-tag> <mutation-shell>
# The inverse of expect_catch, scoped the same way: stage a pristine copy at $T, apply a
# mutation that must be ACCEPTED, and require the checker to report no NEW finding under
# the named tag. Scoped to the tag rather than to a clean exit on purpose — a control that
# demands exit 0 is really asserting "every other check in this file is green right now
# too", so an unrelated finding turns it into a false accusation about the check it aims
# at, and (before the change above) an unrelated finding meant it never ran at all.
#
# NEW findings, not ANY finding, and that difference is load-bearing now that a red
# positive run no longer short-circuits the battery. A tag-presence test on a tree that
# ALREADY carries a finding under that tag accuses the control's own subject of a defect
# it does not have: measured — planting a retired-brand IMAGE_APP in .gitlab-ci.yml
# (a real [pre-rebrand] miss, negative control 9) made this helper report the (since
# retired) legacy descriptor exemption broken, which would send the next reader to
# rewrite the matcher rather than the identifier. So the pristine staged copy is measured FIRST and the
# mutation is judged only by what it ADDS. Line numbers are stable across these mutations
# (they append, or edit in place), so the pre-existing finding lines match exactly.
expect_clean_tag() {
  local desc="$1" tag="$2" mut="$3"
  local T="${WORK}/clean"
  rm -rf "${T}"; mkdir -p "${T}"
  cp "${REPO}/.gitlab-ci.yml" "${T}/.gitlab-ci.yml"
  mkdir -p "${T}/specs"
  cp -r "${REPO}/specs/cluster" "${T}/specs/cluster"
  export T
  local base
  base="$(python3 "${CHECKER}" "${T}" 2>&1 | grep -F "${tag}")"
  if ! ( eval "${mut}" ); then
    neg_bad "${desc} (mutation itself failed to apply)"
    return
  fi
  local after extra
  after="$(python3 "${CHECKER}" "${T}" 2>&1 | grep -F "${tag}")"
  extra="$(BASE="${base}" AFTER="${after}" python3 -c '
import os
base = set(os.environ["BASE"].splitlines())
print("\n".join(sorted(set(os.environ["AFTER"].splitlines()) - base)))')"
  if [ -n "${extra}" ]; then
    neg_bad "${desc} — the mutation ADDED a ${tag} finding:"
    printf '%s\n' "${extra}" | sed 's/^/        /'
  else
    neg_ok "${desc} => no new ${tag} finding"
  fi
}

# probe_expect <mutated-checker> <description>
# Mutation-tests THE CHECKER rather than the tree: runs a deliberately-rotted copy of
# image_builder_always_on.py against the REAL repo and requires it to fail on
# [pre-rebrand]. Every other control here corrupts the scanned SURFACE; on a surface that
# legitimately carries no brand token at all, a rotted matcher changes nothing any tree
# mutation can observe. This is the only kind of control that can see it.
#
# It requires the self-probe's OWN phrase, not merely the [pre-rebrand] tag: a genuine
# rebrand miss sitting on the real tree would emit that same tag and satisfy a tag-only
# match while the rotted matcher went unobserved.
PROBE_PHRASE="matcher self-probe"
probe_expect() {
  local checker="$1" desc="$2"
  local out rc
  out="$(python3 "${checker}" "${REPO}" 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ]; then
    neg_bad "${desc} — the mutated matcher still PASSED"
  elif ! printf '%s' "${out}" | grep -F "[pre-rebrand]" >/dev/null; then
    neg_bad "${desc} — failed, but not on [pre-rebrand]:"
    printf '%s\n' "${out}" | sed 's/^/        /'
  elif ! printf '%s' "${out}" | grep -F "${PROBE_PHRASE}" >/dev/null; then
    neg_bad "${desc} — [pre-rebrand] was reported, but not by the self-probe (so this control would pass on any red tree):"
    printf '%s\n' "${out}" | sed 's/^/        /'
  else
    neg_ok "${desc} => [pre-rebrand] ${PROBE_PHRASE}"
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
#      Routed through expect_clean_tag for the same reason that helper exists: this is an
#      ACCEPTANCE control, and a bare "[ci-pipeline] appears anywhere" reading of a red
#      tree would accuse the ordering check of a defect it does not have. Judged on what
#      the mutation ADDS, so it stays honest whatever else is red.
expect_clean_tag "a real \`needs: []\` decoupling is accepted without allow_failure (8e is not token-matching)" "[ci-pipeline]" '
  python3 - "$T" <<'"'"'PY'"'"'
import sys
p=sys.argv[1]+"/.gitlab-ci.yml"
s=open(p,encoding="utf-8").read()
anchor="  allow_failure: true\n  rules:\n    - if: \x27$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\x27"
assert s.count(anchor)==1, "allow_failure anchor not found"
s=s.replace(anchor,"  rules:\n    - if: \x27$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\x27",1)
for a in ("sca:dependency-check:\n  stage: sca\n",".dast-base:\n  stage: dast\n",".load-base:\n  stage: load\n"):
    assert s.count(a)==1, "stage anchor not found: "+a
    s=s.replace(a,a+"  needs: []\n",1)
open(p,"w",encoding="utf-8").write(s)
PY
'
# (8g) ANTI-VACUITY for the job walk: without `stages:` the ordering check cannot mean
#      anything, so it must say so rather than pass by default.
expect_catch "stages: list removed (ordering check would be vacuous)" "[ci-pipeline]" '
  sed -i "/^stages: \[/d" "$T/.gitlab-ci.yml"
'
# (9) A PRE-REBRAND IDENTIFIER, REINSTATED: the retired repo name comes back in the
#     dispatcher defaults.
expect_catch "stale pre-rebrand gateway repo name reinstated in build:images" "[pre-rebrand]" '
  sed -i "s|    IMAGE_APP: \"hugmesh-gateway\"|    IMAGE_APP: \"${RB}-gateway\"|" \
      "$T/.gitlab-ci.yml"
  grep -F "${RB}-gateway" "$T/.gitlab-ci.yml" >/dev/null
'
# (9b) a retired name reinstated in the SCA clone matrix (the class that broke all 19).
expect_catch "stale repo name reinstated in the sca:dependency-check matrix" "[pre-rebrand]" '
  sed -i "s|          - hugmesh-admin-ui|          - ${RB}-admin-ui|" "$T/.gitlab-ci.yml"
  grep -F "${RB}-admin-ui" "$T/.gitlab-ci.yml" >/dev/null
'
# ── 9c-9h: THE FUNCTIONAL `<host-or-scheme><brand>…/<path>` SHAPE ─────────────────────
# The check used to exempt a few frozen spellings by DELETING them from each line before
# scanning it — which also deleted them from every functional identifier that merely
# contains them (a registry host, a git host, a repoURL). Every mutation below passed the
# gate with exit 0 until that strip went. Hosts are planted on the reserved `.example`
# TLD: the point is the brand token in the identifier, not any real domain.
#
# (9c) the retired brand as the REGISTRY HOST in the synced Job template: where every image
#      this pipeline builds gets pushed.
expect_catch "retired brand as the registry host in the Job template" "[pre-rebrand]" '
  sed -i "s|registry.hugmesh.net/hugmesh/|registry.${RB}.example/hugmesh/|g" \
      "$T/specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml"
  grep -F "registry.${RB}.example/" "$T/specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml" >/dev/null
'
# (9e) the retired brand as the registry host in the dispatcher'"'"'s PUSH destination.
expect_catch "retired brand as the registry host in build:images DEST_REPO" "[pre-rebrand]" '
  sed -i "s|DEST_REPO: \"registry.hugmesh.net/|DEST_REPO: \"registry.${RB}.example/|" \
      "$T/.gitlab-ci.yml"
  grep -F "DEST_REPO: \"registry.${RB}.example/" "$T/.gitlab-ci.yml" >/dev/null
'
# (9f) a retired brand identifier in the Application repoURL — the field that decides
#      whether ArgoCD can sync the always-on app at all — on a NEUTRAL example git host.
#      The org segment is matched as a WILDCARD, not pinned: forks legitimately rehome this
#      repoURL onto their own org, and pinning one spelling silently turns this control
#      into a no-op on every other tree.
expect_catch "retired repo name in the Application repoURL (foreign git host)" "[pre-rebrand]" '
  sed -i -E "s|repoURL: https://github.com/[^/]+/hugmesh-generator.git|repoURL: https://git.example.internal/hugmesh/${RB}-generator.git|" \
      "$T/specs/cluster/apps/60-image-builder.yaml"
  grep -F "${RB}-generator.git" "$T/specs/cluster/apps/60-image-builder.yaml" >/dev/null
'
# (9g) the retired brand as a label-KEY namespace in mapping-key position — the position
#      an old allowlist entry used to exempt. Label keys live under `hugmesh.net/<name>`
#      now, so this pins the REMOVAL of that exemption.
expect_catch "retired brand as a label-key namespace in mapping-key position" "[pre-rebrand]" '
  sed -i "s|    hugmesh.net/image-build:|    ${RB}.example/image-build:|g" \
      "$T/specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml"
  grep -F "${RB}.example/image-build:" "$T/specs/cluster/manifests/image-builder/kaniko-build-job.template.yaml" >/dev/null
'
# (9h) the retired brand as a MIXED-CASE org segment under the github.com host — the
#      position another old allowlist entry used to exempt. Also pins case-insensitivity.
expect_catch "retired brand as a mixed-case org segment under github.com" "[pre-rebrand]" '
  sed -i -E "s|repoURL: https://github.com/[^/]+/hugmesh-generator.git|repoURL: https://github.com/${RB^}-Org/hugmesh-generator.git|" \
      "$T/specs/cluster/apps/60-image-builder.yaml"
  grep -F "github.com/${RB^}-Org/" "$T/specs/cluster/apps/60-image-builder.yaml" >/dev/null
'
# (9d) the RETIRED deploy-descriptor filename. It used to be the last exemption (adopter
#      repos shipped it and the catalog generators accepted it); it was retired before
#      the public release, so it is now caught like any other spelling — even in the
#      `pathsExist` shape it used to be exempt in.
expect_catch "retired deploy-descriptor filename in a pathsExist filter" "[pre-rebrand]" '
  printf "#   pathsExist: [\"%s-deploy.yaml\", \"deploy\"]\n" "${RB}" >> "$T/.gitlab-ci.yml"
  grep -F "${RB}-deploy.yaml" "$T/.gitlab-ci.yml" >/dev/null
'
# (9k) THE MATCHER ROTTED INTO A NEVER-MATCHING PATTERN. Nothing in the TREE can prove
#      this either way (a clean surface looks the same), so the mutation is applied to a
#      copy of the checker and the checker's own self-probe must report it.
C_NARROW="${WORK}/checker-narrow.py"
if python3 - "${CHECKER}" "${C_NARROW}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
a = 'BRAND_RE = re.compile(re.escape(_RETIRED_BRAND), re.IGNORECASE)'
assert s.count(a) == 1, "matcher line not found: the mutation would be a no-op"
open(dst, "w", encoding="utf-8").write(
    s.replace(a, 'BRAND_RE = re.compile(re.escape(_RETIRED_BRAND) + "ZZZ", re.IGNORECASE)', 1))
PY
then
  probe_expect "${C_NARROW}" "matcher rotted into a never-matching pattern"
else
  neg_bad "9k mutation itself failed to apply"
fi
# (9l) THE MATCHER LOST case-insensitivity: the mixed-case org-segment fixture must still
#      be reported by the self-probe.
C_CASE="${WORK}/checker-case.py"
if python3 - "${CHECKER}" "${C_CASE}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
a = 'BRAND_RE = re.compile(re.escape(_RETIRED_BRAND), re.IGNORECASE)'
assert s.count(a) == 1, "matcher line not found: the mutation would be a no-op"
open(dst, "w", encoding="utf-8").write(s.replace(a, 'BRAND_RE = re.compile(re.escape(_RETIRED_BRAND))', 1))
PY
then
  probe_expect "${C_CASE}" "matcher lost case-insensitivity"
else
  neg_bad "9l mutation itself failed to apply"
fi

# ── 10: THE WHOLE TRACKED TREE, not only the image-builder surface ──────────────────
# Check 9 bans the retired brand in the image-builder surface only. The repository is
# public, so the same stem must not appear in ANY tracked file — and the only whole-repo
# scan, studio/tests/test_org_export_neutrality.py, runs in a workflow that fires only
# when studio/** changes. A docs, fixture or certificate change outside studio/ could
# reintroduce the name and pass every PR check. This suite runs on every PR, so the
# whole-tree scan rides here, next to the check it extends. It reads every tracked file
# as bytes (plain, UTF-16, hex, base64 at every alignment, PNG text chunks); it cannot
# read text drawn as pixels — a committed screenshot needs an eye or an OCR pass.
TREE_CHECKER="$(dirname "${BASH_SOURCE[0]}")/private_name_neutrality.py"
echo
echo "-- whole tracked tree: no file may name the retired private target --"
TREE_RC=1
if [ -f "${TREE_CHECKER}" ]; then
  python3 "${TREE_CHECKER}" "${REPO}"; TREE_RC=$?
else
  echo "  FAIL missing checker: ${TREE_CHECKER}"
fi

# tree_expect <description> <expected rc> <tag or ""> <checker> <dir> [--min-files N]
# Runs the tree checker on a small staged git tree and requires the exact exit status
# and, for a hit, the named shape tag.
tree_expect() {
  local desc="$1" want="$2" tag="$3" checker="$4" dir="$5"; shift 5
  local out rc
  out="$(python3 "${checker}" "${dir}" "$@" 2>&1)"; rc=$?
  if [ "${rc}" -ne "${want}" ]; then
    neg_bad "${desc} — exit ${rc}, wanted ${want}:"
    printf '%s\n' "${out}" | sed 's/^/        /'
  elif [ -n "${tag}" ] && ! printf '%s' "${out}" | grep -F -- "${tag}" >/dev/null; then
    neg_bad "${desc} — exit ${rc}, but no '${tag}' in the report:"
    printf '%s\n' "${out}" | sed 's/^/        /'
  else
    neg_ok "${desc} => exit ${rc}${tag:+ ${tag}}"
  fi
}
# stage_tree <dir>: a small git tree of neutral files, tracked (index only, no commit).
stage_tree() {
  local d="$1"
  rm -rf "${d}"; mkdir -p "${d}/docs"
  printf 'domain: mesh.example\norg: exampleorg\n' > "${d}/docs/a.yaml"
  printf 'snap dragon snapper dragonfly\n' > "${d}/docs/near-miss.txt"
  git -C "${d}" init -q && git -C "${d}" add -A
}
TT="${WORK}/tree"
# (10a) a clean staged tree passes — the near-miss words alone are not a hit.
stage_tree "${TT}" && tree_expect "clean staged tree is accepted" 0 "" "${TREE_CHECKER}" "${TT}" --min-files 1
# (10b) the stem, mixed case, in a tracked doc OUTSIDE studio/ and outside the
#       image-builder surface: the hole this section closes.
stage_tree "${TT}" && printf 'see https://id.%s.example/\n' "${RB^}" > "${TT}/docs/b.md" \
  && git -C "${TT}" add -A \
  && tree_expect "stem in a tracked doc outside studio/" 1 "docs/b.md: plain" "${TREE_CHECKER}" "${TT}" --min-files 1
# (10c) the stem hidden inside a base64 dev key (the shape that hid in compose).
stage_tree "${TT}" && printf 'KEY: ${KEY:-%s}\n' "$(printf 'x%s-dev-key-32byte' "${RB}" | base64 -w0)" > "${TT}/docs/c.env" \
  && git -C "${TT}" add -A \
  && tree_expect "stem inside a base64 dev key" 1 "docs/c.env: base64" "${TREE_CHECKER}" "${TT}" --min-files 1
# (10d) the stem in a PNG's compressed zTXt metadata chunk.
stage_tree "${TT}" && python3 - "${TT}/docs/d.png" <<'PY' && git -C "${TT}" add -A \
  && tree_expect "stem in a PNG zTXt chunk" 1 "docs/d.png: png-text" "${TREE_CHECKER}" "${TT}" --min-files 1
import os, struct, sys, zlib
def chunk(t, b):
    return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
payload = b"Comment\0\0" + zlib.compress(("admin@" + os.environ["RB"] + ".example").encode())
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"zTXt", payload) + chunk(b"IEND", b""))
PY
# (10e) an UNTRACKED file is not the repository's business — and the same file once
#       added is. Pins that the scan reads what git tracks, not the working directory.
stage_tree "${TT}" && printf '%s\n' "${RB}" > "${TT}/docs/untracked.txt" \
  && tree_expect "untracked file is ignored" 0 "" "${TREE_CHECKER}" "${TT}" --min-files 1 \
  && git -C "${TT}" add -A \
  && tree_expect "the same file once tracked is caught" 1 "docs/untracked.txt: plain" "${TREE_CHECKER}" "${TT}" --min-files 1
# (10f) VACUITY: a tree too small for the default floor is INCOMPLETE (exit 2), never clean.
stage_tree "${TT}" && tree_expect "too few tracked files is incomplete, not clean" 2 "[neutrality-incomplete]" "${TREE_CHECKER}" "${TT}"
# (10g) THE MATCHER ROTTED: a copy of the checker whose stem never matches must fail its
#       own self-probe (exit 2), whatever the tree holds.
TC_NARROW="${WORK}/tree-checker-narrow.py"
if python3 - "${TREE_CHECKER}" "${TC_NARROW}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
a = '_STEM = "snap" + "dragon"'
assert s.count(a) == 1, "stem line not found: the mutation would be a no-op"
open(dst, "w", encoding="utf-8").write(s.replace(a, '_STEM = "snap" + "dragon" + "ZZZ"', 1))
PY
then
  stage_tree "${TT}" && tree_expect "tree matcher rotted into a never-matching stem" 2 "[neutrality-probe]" "${TC_NARROW}" "${TT}" --min-files 1
else
  neg_bad "10g mutation itself failed to apply"
fi
# (10h) THE MATCHER LOST case-insensitivity on the plain shape.
TC_CASE="${WORK}/tree-checker-case.py"
if python3 - "${TREE_CHECKER}" "${TC_CASE}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
a = "        low = data.lower()\n        shapes: list[str] = []"
assert s.count(a) == 1, "lowercasing line not found: the mutation would be a no-op"
open(dst, "w", encoding="utf-8").write(s.replace(a, "        low = data\n        shapes: list[str] = []", 1))
PY
then
  stage_tree "${TT}" && tree_expect "tree matcher lost case-insensitivity" 2 "[neutrality-probe]" "${TC_CASE}" "${TT}" --min-files 1
else
  neg_bad "10h mutation itself failed to apply"
fi

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
[ "${NEG_F}" -eq 0 ] || exit 1
if [ "${POS_RC}" -ne 0 ]; then
  echo "== image-builder always-on: FAIL — the repo's own tree does not pass. The finding is"
  echo "   at the top of this run; the ${NEG_P} negative controls above are all green, so the"
  echo "   guard is intact and the finding is a real one. =="
  exit 1
fi
if [ "${TREE_RC}" -ne 0 ]; then
  echo "== image-builder always-on: FAIL — a tracked file names the retired private target"
  echo "   (or the whole-tree scan could not run); see the whole-tree section above. =="
  exit 1
fi
echo "== image-builder always-on: PASS =="
exit 0
