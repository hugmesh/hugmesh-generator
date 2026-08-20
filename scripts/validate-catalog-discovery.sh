#!/usr/bin/env bash
# =============================================================================
# validate-catalog-discovery.sh — service-catalog DISCOVERY guard.
# =============================================================================
# Asserts that every repo which has adopted the deploy-descriptor contract is
# actually VISIBLE to the catalog ApplicationSets, i.e.:
#
#   { descriptor filename of every adopting repo }
#        ⊆  { descriptor filename accepted by a generator `pathsExist` filter }
#
# WHY THIS EXISTS. The catalog generators discover repos by `pathsExist` on a
# FIXED descriptor filename. The HugMesh rebrand renamed that file to
# `hugmesh-deploy.yaml` repo by repo, leaving the pre-rebrand
# `snapdragon-deploy.yaml` live in the ones that had not moved yet, while both
# generators filtered on ONE name only. The unmatched repos were invisible to the
# catalog — and NOTHING reported it: an scmProvider filter that matches no repo is
# not an error, the ApplicationSet just generates no Application. No event, no
# degraded Application, no log line. All three repos' own descriptors meanwhile
# carried a header comment asserting they were "discovered by the catalog
# ApplicationSet". A silent discovery hole is exactly the class of defect a
# GitOps tree cannot afford, so it gets a gate.
#
# STAGES (each FAILs the run on a violation):
#   1) registry sanity — specs/cluster/catalog/adopters.yaml is non-empty, has no
#      duplicate repos, every descriptor name is a plausible root YAML file, and
#      its `spec.sweep` provenance block shows the adopter list was obtained by
#      sweeping the WHOLE org (sweptRepos == orgRepos). A partial sweep that claims
#      completeness is how a real adopter with no local checkout went unregistered.
#   2) generator filter parse — every scmProvider generator in the tree
#      (apps/13-service-catalog.yaml + templates/apps/13d-brand-repos.yaml.hbs)
#      must carry at least one filter, each filter must require `deploy` plus
#      EXACTLY ONE descriptor path, and the two generators must accept the SAME
#      descriptor-name set (a tenant catalog that accepts fewer names than the
#      upstream one re-creates the bug per tenant).
#   3) VISIBILITY — every registered adopter's descriptor must be accepted by a
#      filter, and its repo name must match the upstream generator's
#      `repositoryMatch`. This is the check that would have caught the shipped
#      bug; it names every invisible repo.
#   4) emitter parity — every descriptor spelling the platform's own tooling
#      emits/protects (publish-tenant-set.sh's synthesised contract, the
#      documented example file, render-recipe.js's rename contract denylist) must
#      be accepted by a filter, and the registry's `emitters` must not lie about
#      where those names live. Every accepted name must ALSO be rename-protected
#      AND carry a behavioural rename case in
#      tests/domain-registry/test-templating-rename-pr.sh — a denylist entry that
#      nothing executes is protection on paper only.
#   5) REALITY — clone/checkout each registered repo and read its ROOT tree: the
#      descriptor it actually ships must equal the one registered, it must also
#      ship `deploy/`, and a repo that ships a `*-deploy.yaml` descriptor without
#      being registered is drift. REQUIRED: every registered repo must be present
#      and read. A repo that cannot be read makes the run INCOMPLETE (exit 3),
#      never a silent PASS — the same honesty contract stage 5 of
#      scripts/validate-reserved-prefixes.sh had to be given after it spent months
#      reporting green on an assertion that had never once run.
#
# Wired into .gitlab-ci.yml (lint stage, lint:catalog-descriptor-discovery), which
# clones the registered repos so stage 5 genuinely runs. Its honesty is regression-
# tested by tests/scripts/test-catalog-discovery-gate.sh.
#
# Uses python3 + PyYAML. No cluster, no kubectl, no network of its own.
#
# EXIT CODES
#   0  PASS       — every adopter is visible, and every stage actually ran.
#   1  FAIL       — an invisible adopter / drift / divergence (offenders printed).
#   2  FATAL      — environment problem (missing input file, no python3/PyYAML).
#   3  INCOMPLETE — no violation found, but stage 5 could NOT run for one or more
#                   registered repos. Non-zero on purpose: an unrun assertion is
#                   not a pass. Point CATALOG_SIBLING_ROOT at a tree holding the
#                   checkouts, or set CATALOG_ALLOW_MISSING_REPOS=1 to opt out
#                   DELIBERATELY (exit 0, but the verdict line still says
#                   `RESULT: PASS (INCOMPLETE …)` — never a clean PASS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY="${REPO_ROOT}/specs/cluster/catalog/adopters.yaml"
CATALOG_APPSET="${REPO_ROOT}/specs/cluster/apps/13-service-catalog.yaml"
BRAND_APPSET="${REPO_ROOT}/templates/apps/13d-brand-repos.yaml.hbs"
PUBLISH_SH="${REPO_ROOT}/scripts/publish-tenant-set.sh"
RENDER_RECIPE="${REPO_ROOT}/scripts/tooling/render-recipe.js"
RENAME_TEST="${REPO_ROOT}/tests/domain-registry/test-templating-rename-pr.sh"

# Where to look for the adopter checkouts (stage 5). Default: sibling checkouts
# next to this repo (…/GitHub/<repo>). CI clones them into a temp dir and points
# this at it. An unreadable repo makes the run INCOMPLETE (exit 3).
SIBLING_ROOT="${CATALOG_SIBLING_ROOT:-$(cd "${REPO_ROOT}/.." && pwd)}"

# Which ref of each checkout to read. CI's `git clone --depth 1` leaves the default
# branch checked out; a developer's tree may be mid-work on a feature branch, so the
# remote-tracking ref is preferred and the working tree is the last resort.
SIBLING_REF="${CATALOG_SIBLING_REF:-origin/main}"

# Deliberate opt-out for a working copy with no sibling checkouts. Downgrades
# INCOMPLETE (exit 3) to exit 0 — the verdict line still says PASS (INCOMPLETE …).
# NEVER set this in CI: the whole point of the CI clone is that stage 5 runs.
ALLOW_MISSING_REPOS="${CATALOG_ALLOW_MISSING_REPOS:-0}"

for f in "$REGISTRY" "$CATALOG_APPSET" "$BRAND_APPSET" "$PUBLISH_SH" "$RENDER_RECIPE"; do
  [[ -f "$f" ]] || { echo "FATAL: missing required file: $f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not available" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML not available (pip install pyyaml)" >&2; exit 2; }

export REGISTRY CATALOG_APPSET BRAND_APPSET PUBLISH_SH RENDER_RECIPE RENAME_TEST
export REPO_ROOT
export SIBLING_ROOT SIBLING_REF ALLOW_MISSING_REPOS

python3 - <<'PY'
import os
import re
import subprocess
import sys

import yaml

REGISTRY = os.environ["REGISTRY"]
CATALOG_APPSET = os.environ["CATALOG_APPSET"]
BRAND_APPSET = os.environ["BRAND_APPSET"]
PUBLISH_SH = os.environ["PUBLISH_SH"]
RENDER_RECIPE = os.environ["RENDER_RECIPE"]
RENAME_TEST = os.environ["RENAME_TEST"]
REPO_ROOT = os.environ["REPO_ROOT"]
SIBLING_ROOT = os.environ["SIBLING_ROOT"]
SIBLING_REF = os.environ["SIBLING_REF"]
ALLOW_MISSING_REPOS = os.environ["ALLOW_MISSING_REPOS"] == "1"

failed = False


def fail(stage, msg):
    global failed
    failed = True
    print(f"  [FAIL] {stage} {msg}", file=sys.stderr)


def ok(stage, msg):
    print(f"  [OK]   {stage} {msg}")


# A deploy descriptor is a root-level "<something>-deploy.yaml". Kept as one
# regex so stage 5 can DISCOVER an unregistered spelling instead of only checking
# the two the tree happens to know about today.
DESCRIPTOR_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*-deploy\.ya?ml$")

# The path every filter must require alongside the descriptor: without a deploy/
# kustomize dir the generated Application has no source.path to sync.
DEPLOY_DIR = "deploy"


def load_yaml(path, detokenize=False):
    text = open(path, encoding="utf-8").read()
    if detokenize:
        # 13d is a handlebars/sed template: `name: {{BRAND}}-brand-repos` is a
        # YAML flow-mapping start, not a string. Substitute every {{TOKEN}} with an
        # inert placeholder so the structure can be parsed. The placeholder keeps
        # regex validity for repositoryMatch ("^{{BRAND}}-" -> "^TOKEN_BRAND-").
        text = re.sub(r"\{\{\s*([A-Za-z0-9_]+)\s*\}\}", r"TOKEN_\1", text)
    return list(yaml.safe_load_all(text))


# ── stage 1: registry sanity ─────────────────────────────────────────────────
print("== stage 1: adopter registry sanity ==")
reg = yaml.safe_load(open(REGISTRY, encoding="utf-8")) or {}
spec = reg.get("spec") or {}
adopters = spec.get("adopters") or []
emitters = spec.get("emitters") or []
org = spec.get("org") or ""
sweep = spec.get("sweep") or {}

# PROVENANCE. The adopter list is only as trustworthy as the sweep that produced
# it, and a sweep is only trustworthy if it covered the whole ORG. The first cut of
# this registry was built from 33 local checkouts while the org had 38 repos and
# silently missed a real adopter that had no local clone, so the registry has to
# declare both numbers and they have to agree.
if not isinstance(sweep, dict) or not sweep:
    fail("[sweep-provenance]",
         "registry declares no `spec.sweep` block — an adopter list with no recorded "
         "provenance cannot be distinguished from one built off a partial tree")
else:
    org_repos = sweep.get("orgRepos")
    swept = sweep.get("sweptRepos")
    if not isinstance(org_repos, int) or not isinstance(swept, int) \
            or org_repos <= 0 or swept <= 0:
        fail("[sweep-provenance]",
             f"spec.sweep.orgRepos / spec.sweep.sweptRepos must both be positive "
             f"integers, got {org_repos!r} / {swept!r}")
    elif swept < org_repos:
        fail("[sweep-provenance]",
             f"the adopter sweep covered only {swept} of the org's {org_repos} repos "
             f"— {org_repos - swept} repo(s) were never looked at, so an adopter "
             "among them is invisible to this registry AND to every check built on "
             "it. Re-sweep the ORG (spec.sweep.method), not your local checkouts.")
    elif swept > org_repos:
        fail("[sweep-provenance]",
             f"spec.sweep.sweptRepos ({swept}) exceeds spec.sweep.orgRepos "
             f"({org_repos}) — the provenance block is internally inconsistent")
    elif not str(sweep.get("method") or "").strip():
        fail("[sweep-provenance]", "spec.sweep.method is empty — record HOW the org "
                                   "was enumerated so the sweep can be re-run")
    elif len(adopters) > swept:
        fail("[sweep-provenance]",
             f"{len(adopters)} adopters declared but only {swept} repos swept")
    else:
        ok("[sweep-provenance]",
           f"sweep {sweep.get('date', '(undated)')} via {sweep.get('method')} covered "
           f"{swept}/{org_repos} org repos")

if not adopters:
    fail("[registry]", f"{REGISTRY} declares no adopters — the registry is the "
                       "input to every other stage; an empty one makes this gate vacuous")
seen = {}
registered = {}          # repo -> descriptor
for i, a in enumerate(adopters):
    if not isinstance(a, dict) or "repo" not in a or "descriptor" not in a:
        fail("[registry]", f"adopters[{i}] must be a mapping with `repo` and `descriptor`: {a!r}")
        continue
    repo, desc = str(a["repo"]), str(a["descriptor"])
    if repo in seen:
        fail("[registry]", f"duplicate adopter entry for {repo}")
    seen[repo] = True
    if not DESCRIPTOR_RE.match(desc):
        fail("[registry]", f"{repo}: descriptor {desc!r} is not a root <name>-deploy.yaml file")
    registered[repo] = desc
if registered:
    ok("[registry]", f"{len(registered)} adopters declared, org={org or '(unset)'}, no duplicates")

# ── stage 2: generator filter parse + lockstep ───────────────────────────────
print()
print("== stage 2: catalog generator filters ==")


def generator_filters(path, label, detokenize=False):
    """-> (accepted descriptor names, repositoryMatch patterns) for one appset."""
    global failed
    before = failed
    accepted, matches = set(), []
    docs = [d for d in load_yaml(path, detokenize) if isinstance(d, dict)]
    appsets = [d for d in docs if d.get("kind") == "ApplicationSet"]
    if not appsets:
        fail("[appset-parse]", f"{label}: no ApplicationSet document found")
        return accepted, matches
    nfilters = 0
    for doc in appsets:
        for gen in (doc.get("spec") or {}).get("generators") or []:
            scm = gen.get("scmProvider") if isinstance(gen, dict) else None
            if not scm:
                continue
            filters = scm.get("filters") or []
            if not filters:
                fail("[appset-parse]", f"{label}: scmProvider generator has NO filters — it "
                                       "would generate an Application for every repo in the org")
                continue
            for f in filters:
                nfilters += 1
                paths = list(f.get("pathsExist") or [])
                if DEPLOY_DIR not in paths:
                    fail("[appset-parse]", f"{label}: filter {f!r} does not require "
                                           f"`{DEPLOY_DIR}` — the generated Application's "
                                           "source.path would not exist")
                descs = [p for p in paths if p != DEPLOY_DIR]
                if len(descs) != 1:
                    fail("[appset-parse]", f"{label}: filter {f!r} must require EXACTLY one "
                                           "descriptor path beside `deploy` (pathsExist is an "
                                           "AND-list: two descriptor names in ONE entry means a "
                                           "repo must carry BOTH, which no repo does — the "
                                           "disjunction goes in a SECOND filter entry)")
                    continue
                if not DESCRIPTOR_RE.match(descs[0]):
                    fail("[appset-parse]", f"{label}: filter descriptor {descs[0]!r} is not a "
                                           "root <name>-deploy.yaml file")
                accepted.add(descs[0])
                if f.get("repositoryMatch"):
                    matches.append(str(f["repositoryMatch"]))
    if failed == before:
        ok("[appset-parse]", f"{label}: {nfilters} filter(s), accepts {sorted(accepted)}")
    return accepted, matches


catalog_accepted, catalog_matches = generator_filters(CATALOG_APPSET, "13-service-catalog")
brand_accepted, _ = generator_filters(BRAND_APPSET, "13d-brand-repos", detokenize=True)

if catalog_accepted and brand_accepted and catalog_accepted != brand_accepted:
    fail("[appset-lockstep]",
         "the two catalog generators accept DIFFERENT descriptor names — a tenant "
         "catalog that accepts fewer names re-creates the invisibility bug per "
         f"tenant. 13-service-catalog={sorted(catalog_accepted)} "
         f"13d-brand-repos={sorted(brand_accepted)}")
elif catalog_accepted:
    ok("[appset-lockstep]", f"both generators accept the same set {sorted(catalog_accepted)}")

accepted = set(catalog_accepted)

# ── stage 3: VISIBILITY (the check the shipped bug needed) ───────────────────
print()
print("== stage 3: adopter visibility ==")
invisible = []
for repo, desc in sorted(registered.items()):
    if desc not in accepted:
        invisible.append((repo, desc))
        continue
    if catalog_matches and not any(re.search(m, repo) for m in catalog_matches):
        fail("[repository-match]",
             f"{repo}: descriptor is accepted but the repo NAME matches no "
             f"repositoryMatch of 13-service-catalog ({catalog_matches}) — it is "
             "still invisible to the catalog")
if invisible:
    fail("[adopter-visibility]",
         f"{len(invisible)} adopting repo(s) are INVISIBLE to the service catalog: "
         "they ship a deploy descriptor that NO generator filter matches, so the "
         "ApplicationSet silently generates nothing for them.")
    for repo, desc in invisible:
        print(f"           - {repo} ships {desc}; generators accept {sorted(accepted)}",
              file=sys.stderr)
    print("         Fix by adding a filter entry for that filename to BOTH "
          "specs/cluster/apps/13-service-catalog.yaml and "
          "templates/apps/13d-brand-repos.yaml.hbs.", file=sys.stderr)
else:
    ok("[adopter-visibility]",
       f"all {len(registered)} registered adopters are matched by a generator filter")

# ── stage 4: emitter parity ──────────────────────────────────────────────────
print()
print("== stage 4: emitter parity ==")
emitted = set()
for i, e in enumerate(emitters):
    if not isinstance(e, dict) or "name" not in e or "where" not in e:
        fail("[emitters]", f"emitters[{i}] must be a mapping with `name` and `where`: {e!r}")
        continue
    emitted.add(str(e["name"]))
unaccepted = sorted(emitted - accepted)
if unaccepted:
    fail("[emitter-parity]",
         f"the platform's own tooling emits/protects descriptor name(s) no generator "
         f"accepts: {unaccepted}. A name this tree can PRODUCE must be a name the "
         "catalog can SEE.")
elif emitted:
    ok("[emitter-parity]", f"every emitted/protected name {sorted(emitted)} is accepted")

# The registry's `emitters` list must not lie: each declared name has to be
# findable in the tooling this repo actually ships.
publish_text = open(PUBLISH_SH, encoding="utf-8").read()
recipe_text = open(RENDER_RECIPE, encoding="utf-8").read()
denylist_m = re.search(r"RENAME_CONTRACT_DENYLIST\s*=\s*new Set\(\[(.*?)\]\)", recipe_text, re.S)
if not denylist_m:
    fail("[emitters]", "could not parse RENAME_CONTRACT_DENYLIST from render-recipe.js")
    denylisted = set()
else:
    body = re.sub(r"//[^\n]*", "", denylist_m.group(1))
    denylisted = {s for s in re.findall(r"'([^']+)'", body) if DESCRIPTOR_RE.match(s)}

for name in sorted(emitted):
    if name not in publish_text and name not in denylisted:
        fail("[emitters]", f"registry declares {name} as emitted/protected, but it appears "
                           "in neither publish-tenant-set.sh nor render-recipe.js's "
                           "RENAME_CONTRACT_DENYLIST")

# The rename denylist is the tree's own promise that a descriptor never moves.
# Every ACCEPTED spelling must be in it, or a tenant render could rename a live
# repo's descriptor out from under the filter that matches it.
missing_deny = sorted(accepted - denylisted)
if missing_deny:
    fail("[rename-denylist]",
         f"descriptor name(s) accepted by a generator but NOT in render-recipe.js's "
         f"RENAME_CONTRACT_DENYLIST: {missing_deny} — a recipe could rename them and "
         "silently un-discover the repo")
elif denylisted:
    ok("[rename-denylist]", f"every accepted name is rename-protected {sorted(denylisted)}")

# …and being IN the denylist is only a promise until something executes it.
# tests/domain-registry/test-templating-rename-pr.sh (cases A9*) is the only place
# the denylist is exercised BEHAVIOURALLY — everything here is static parsing — so
# a spelling added to the Set with no case there is protected on paper only.
if os.path.isfile(RENAME_TEST):
    rename_test_text = open(RENAME_TEST, encoding="utf-8").read()
    uncovered = sorted(n for n in accepted if n not in rename_test_text)
    if uncovered:
        fail("[rename-coverage]",
             f"accepted descriptor name(s) with no case in "
             f"{os.path.relpath(RENAME_TEST, REPO_ROOT)}: {uncovered} — the denylist "
             "entry is never executed, so nothing would notice if it stopped "
             "refusing. Add a rename case for it on BOTH the from and to side.")
    elif accepted:
        ok("[rename-coverage]",
           f"every accepted name has a behavioural rename case {sorted(accepted)}")
else:
    fail("[rename-coverage]", f"missing {RENAME_TEST} — the only behavioural test of "
                              "the rename contract denylist")

# ── stage 5: REALITY — what the repos actually ship ──────────────────────────
print()
print("== stage 5: adopter repo reality check ==")
print(f"sibling search root : {SIBLING_ROOT}")
print(f"ref preference      : {SIBLING_REF} -> main -> HEAD -> working tree")


def root_entries(path):
    """Root-level names of a checkout. Prefers a remote-tracking ref (a developer
    tree may be mid-work on a feature branch); falls back to the working tree so a
    synthesised / non-git directory still reads. Returns None if unreadable."""
    if not os.path.isdir(path):
        return None
    if os.path.isdir(os.path.join(path, ".git")) or os.path.isfile(os.path.join(path, ".git")):
        for ref in (SIBLING_REF, "main", "HEAD"):
            try:
                out = subprocess.run(["git", "-C", path, "ls-tree", "--name-only", ref],
                                     capture_output=True, text=True, timeout=60)
            except Exception:
                break
            if out.returncode == 0:
                names = [n for n in out.stdout.splitlines() if n]
                if names:
                    return names
    try:
        return sorted(os.listdir(path))
    except OSError:
        return None


missing_repos = []
reality = {}
for repo in sorted(registered):
    names = root_entries(os.path.join(SIBLING_ROOT, repo))
    if names is None:
        missing_repos.append(repo)
        print(f"  [MISSING] {repo:<30} NOT CHECKED — no such checkout: "
              f"{os.path.join(SIBLING_ROOT, repo)}")
        continue
    reality[repo] = names
    descs = sorted(n for n in names if DESCRIPTOR_RE.match(n))
    want = registered[repo]
    if descs != [want]:
        fail("[registry-drift]",
             f"{repo}: registry says {want}, repo root actually ships "
             f"{descs if descs else '(no descriptor)'}")
        continue
    if DEPLOY_DIR not in names:
        fail("[deploy-dir]",
             f"{repo}: ships {want} but NO `{DEPLOY_DIR}/` — every filter ANDs the "
             "descriptor with `deploy`, so the repo is invisible anyway (and the "
             "Application would have no source.path)")
        continue
    ok("[reality]", f"{repo:<30} {want} + {DEPLOY_DIR}/")

# Any checkout under the search root that ships a descriptor but is NOT registered
# is an adopter nobody declared — the exact way a new repo drifts into the
# invisible set. Only meaningful when the root holds more than the cloned set
# (a developer's ~/GitHub); in CI the root holds exactly the registered clones.
#
# SCOPED to directory names the upstream generator would actually scan
# (`repositoryMatch`): a tree the catalog never looks at cannot be an invisible
# adopter, and an unscoped sweep false-flags every scratch/verify copy sitting
# next to the real checkouts.
try:
    candidates = sorted(d for d in os.listdir(SIBLING_ROOT)
                        if os.path.isdir(os.path.join(SIBLING_ROOT, d))
                        and (not catalog_matches
                             or any(re.search(m, d) for m in catalog_matches)))
except OSError:
    candidates = []
for d in candidates:
    if d in registered:
        continue
    names = root_entries(os.path.join(SIBLING_ROOT, d))
    if not names:
        continue
    descs = sorted(n for n in names if DESCRIPTOR_RE.match(n))
    if descs:
        fail("[unregistered-adopter]",
             f"{d} ships {descs} but is NOT in specs/cluster/catalog/adopters.yaml "
             "— an adopter nobody declared is an adopter nobody checked for visibility")

incomplete = bool(missing_repos)
if incomplete:
    print()
    print(f"INCOMPLETE: the reality check could NOT run for {len(missing_repos)} of "
          f"{len(registered)} registered adopters:", file=sys.stderr)
    for repo in missing_repos:
        print(f"  - {repo} -> {os.path.join(SIBLING_ROOT, repo)}", file=sys.stderr)
    print(file=sys.stderr)
    print("Stage 5 is what mechanically proves the registry still matches what the", file=sys.stderr)
    print("repos ship; an unrun assertion is NOT a pass. Fix by either:", file=sys.stderr)
    print(f"  * checking the repos out under the sibling root ({SIBLING_ROOT}), or", file=sys.stderr)
    print("  * CATALOG_SIBLING_ROOT=/path/to/tree scripts/validate-catalog-discovery.sh, or",
          file=sys.stderr)
    print("  * CATALOG_ALLOW_MISSING_REPOS=1 to accept an INCOMPLETE run on purpose",
          file=sys.stderr)
    print("    (never in CI — .gitlab-ci.yml's lint:catalog-descriptor-discovery clones them).",
          file=sys.stderr)
else:
    print(f"  all {len(registered)} registered adopters were present and checked.")

# ── final verdict ────────────────────────────────────────────────────────────
print()
if failed:
    print("RESULT: FAIL — see the violations above.", file=sys.stderr)
    sys.exit(1)
if incomplete:
    if ALLOW_MISSING_REPOS:
        print("RESULT: PASS (INCOMPLETE — reality check SKIPPED for "
              f"{len(missing_repos)}/{len(registered)} adopters; exit 0 forced by "
              "CATALOG_ALLOW_MISSING_REPOS=1). The other stages are consistent; the "
              "repo trees were NOT verified.")
        sys.exit(0)
    print("RESULT: INCOMPLETE — no violation found in the stages that ran, but the "
          f"reality check did NOT run ({len(missing_repos)}/{len(registered)} adopters "
          "absent). NOT a pass.", file=sys.stderr)
    sys.exit(3)
print("RESULT: PASS — every adopting repo is visible to the service catalog.")
sys.exit(0)
PY
