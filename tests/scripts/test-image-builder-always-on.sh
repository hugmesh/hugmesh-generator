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
# it does not have: measured — planting `IMAGE_APP: "snapdragon-gateway"` in .gitlab-ci.yml
# (a real [pre-rebrand] miss, negative control 9) made this helper report the LEGACY
# DESCRIPTOR EXEMPTION broken, which would send the next reader to rewrite the allowlist
# rather than the identifier. So the pristine staged copy is measured FIRST and the
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
# [pre-rebrand]. Every other control here corrupts the scanned SURFACE, and a surface
# mutation cannot reach the allowlist's own regexes — on a surface that legitimately
# carries no brand token at all (the state main has been in since 857e84d9) a rotted
# allowlist changes nothing any tree mutation can observe. These are the only controls
# that can see it.
#
# It requires the self-probe's OWN phrase, not merely the [pre-rebrand] tag. These two
# controls run the mutated checker against the REAL repo rather than a staged copy — a
# copy cannot carry the mutation, which lives in the checker — so a genuine rebrand miss
# sitting on the tree would emit that same tag and satisfy a tag-only match while the
# rotted allowlist went unobserved. That is exactly the failure mode this whole change
# exists to remove, so it must not be reintroduced one level up.
PROBE_PHRASE="allowlist self-probe"
probe_expect() {
  local checker="$1" desc="$2"
  local out rc
  out="$(python3 "${checker}" "${REPO}" 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ]; then
    neg_bad "${desc} — the mutated allowlist still PASSED"
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
# (9f) a retired brand identifier in the Application repoURL — the field that decides
#      whether ArgoCD can sync the always-on app at all. The takeover plants the RETIRED
#      REPO NAME (`snapdragon-generator`, renamed to `hugmesh-generator`) on a NEUTRAL
#      example git host: the operator's rule is that no `.systems` spelling may exist
#      anywhere in this tree except where a ban rule names what it bans, and a takeover
#      fixture is not that place — 9c/9e already pin the `…snapdragon.systems/<path>`
#      HOST shape. `git.example.internal` is reserved-for-documentation, so the control
#      still proves a foreign repoURL carrying a retired identifier is caught.
#      The org segment is matched as a WILDCARD, not pinned: forks legitimately rehome this
#      repoURL onto their own org (hugmesh, hugmesh-net, a tenant org), and pinning one
#      spelling silently turns this control into a no-op on every other tree.
expect_catch "retired repo name in the Application repoURL (foreign git host)" "[pre-rebrand]" '
  sed -i -E "s|repoURL: https://github.com/[^/]+/hugmesh-generator.git|repoURL: https://git.example.internal/hugmesh/snapdragon-generator.git|" \
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
#
#      IT NOW PLANTS THE FROZEN FORM INSTEAD OF HOPING TO FIND ONE. This control used to
#      `grep -q 'snapdragon-deploy\.yaml'` in the STAGED COPY of .gitlab-ci.yml and then
#      require the whole checker to exit 0 — i.e. it depended on the repo happening to
#      contain an occurrence, and the only one the surface ever had was a PROSE COMMENT.
#      857e84d9 reflowed that comment away and this control started failing (as did the
#      checker's own surface-count anti-vacuity check) with nothing wrong in the product.
#      A control whose subject has to pre-exist in unrelated prose is not a control. It now
#      writes the exemption's subject into the staged copy itself, so it exercises the
#      allowlist on every run whatever the tree looks like.
expect_clean_tag "legacy snapdragon-deploy.yaml descriptor filename is NOT flagged" "[pre-rebrand]" '
  printf "# LEGACY_COMPAT catalog descriptor, still shipped on disk by adopter repos:\n" \
      >> "$T/.gitlab-ci.yml"
  printf "#   pathsExist: [\"snapdragon-deploy.yaml\", \"deploy\"]\n" \
      >> "$T/.gitlab-ci.yml"
'
# (9k) THE ALLOWLIST ROTTED INTO A NEVER-MATCHING PATTERN — the NARROW direction. If the
#      pattern stops matching the live filename, the checker begins reporting a filename
#      adopter repos still ship as a rebrand miss, and the fix someone reaches for is to
#      rename a live discovery contract. Nothing in the TREE can prove this either way, so
#      the mutation is applied to a copy of the checker.
C_NARROW="${WORK}/checker-narrow.py"
if python3 - "${CHECKER}" "${C_NARROW}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
a = r"(?P<tok>snapdragon)-deploy"
assert s.count(a) == 1, "allowlist regex anchor not found: the mutation would be a no-op"
open(dst, "w", encoding="utf-8").write(s.replace(a, r"(?P<tok>snapdragon)-deployZZZ", 1))
PY
then
  probe_expect "${C_NARROW}" "allowlist narrowed into a never-matching pattern"
else
  neg_bad "9k mutation itself failed to apply"
fi
# (9l) THE ALLOWLIST WIDENED PAST THE WHOLE-FILENAME TOKEN — the opposite direction, and
#      the dangerous one, because it makes the check quieter rather than louder. Strip the
#      two anchors and `registry.snapdragon-deploy.yaml/hugmesh/…` inherits the exemption,
#      turning entry (c) into the textual blanket mute the positional form replaced. The
#      RETIRED surface-count guard could not see this at all: a widened allowlist matches
#      MORE, so its count only ever went up. This is the direction that needed a control.
C_WIDE="${WORK}/checker-wide.py"
if python3 - "${CHECKER}" "${C_WIDE}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
for a in (r"(?<![\w.-])", r"(?![\w-])"):
    assert s.count(a) == 1, "allowlist anchor not found: " + a
    s = s.replace(a, "", 1)
open(dst, "w", encoding="utf-8").write(s)
PY
then
  probe_expect "${C_WIDE}" "allowlist widened past the whole-filename token (a registry host inherits the exemption)"
else
  neg_bad "9l mutation itself failed to apply"
fi

# (9m) IS THE EXEMPTION STILL EARNED? 9d/9j/9k/9l prove the allowlist pattern still means
#      what it says. They cannot say whether it should still EXIST — and the retired
#      surface-count guard could, crudely: while the surface carried an occurrence, an
#      empty count was the signal to delete the allowlist ("if snapdragon-deploy.yaml is
#      genuinely gone fleet-wide, DELETE the allowlist and this guard"). That signal was
#      worth keeping. What was wrong was WHERE it read it from: the surface's only
#      occurrence was PROSE in .gitlab-ci.yml, so a comment reflow revoked the exemption's
#      justification without touching a line of config.
#
#      So the liveness question is asked of FUNCTIONAL CONFIG — the generator paths that
#      actually make the legacy filename discoverable — and of no comment, in this file or
#      any other. Owned fixtures answer "does the pattern still work"; these sites answer
#      "is there still anything for it to exempt". One live site earns the exemption; when
#      the last one goes, the allowlist entry, the checker's ALLOWLIST_PROBE_* fixtures and
#      controls 9d/9j/9k/9l should all be deleted together. Docs and tests that merely NAME
#      the filename are deliberately not counted: prose outliving the behaviour it
#      describes is the entire defect this control replaces.
#
#      One fixed string per site, quoted exactly as that file spells it, so this cannot be
#      satisfied by a doc comment in the same file. `-F` and a FILE argument on purpose: no
#      regex, and nothing piped into `grep -q` (a SIGPIPE there reports a found match as
#      failure, and busybox — the alpine lane's grep — trips it far below this host's knee).
legacy_site_live() {
  local rel needle
  rel="$1"; needle="$2"
  [ -f "${REPO}/${rel}" ] || return 1
  grep -F -q -e "${needle}" "${REPO}/${rel}"
}
LEGACY_LIVE=0
LEGACY_DEAD=""
while IFS='|' read -r SITE NEEDLE; do
  [ -n "${SITE}" ] || continue
  if legacy_site_live "${SITE}" "${NEEDLE}"; then
    LEGACY_LIVE=$((LEGACY_LIVE + 1))
  else
    LEGACY_DEAD="${LEGACY_DEAD} ${SITE}"
  fi
done <<'SITES'
specs/cluster/apps/13-service-catalog.yaml|            pathsExist: ["snapdragon-deploy.yaml", "deploy"]
templates/apps/13d-brand-repos.yaml.hbs|            pathsExist: ["snapdragon-deploy.yaml", "deploy"]
scripts/publish-tenant-set.sh|DESCRIPTOR_LEGACY_COMPAT="snapdragon-deploy.yaml"
scripts/tooling/render-recipe.js|  'snapdragon-deploy.yaml',
specs/cluster/catalog/adopters.yaml|      descriptor: snapdragon-deploy.yaml
SITES
if [ "${LEGACY_LIVE}" -gt 0 ]; then
  neg_ok "the exempted legacy descriptor filename is still live in ${LEGACY_LIVE} functional generator path(s) — the allowlist is still earned"
else
  neg_bad "no functional generator path accepts snapdragon-deploy.yaml any more (checked:${LEGACY_DEAD}). The allowlist entry, the checker's ALLOWLIST_PROBE_* fixtures and controls 9d/9j/9k/9l now exempt a filename nothing ships — DELETE them together rather than leaving an exemption behind."
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
echo "== image-builder always-on: PASS =="
exit 0
