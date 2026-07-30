#!/usr/bin/env bash
# test-catalog-discovery-gate.sh — negative-control / honesty regression test for
# scripts/validate-catalog-discovery.sh.
#
# WHY THIS EXISTS. The defect the gate exists to catch was SILENT: the catalog
# ApplicationSets filtered `pathsExist: ["snapdragon-deploy.yaml", "deploy"]` while
# 3 of the 9 adopting repos had renamed that file to `hugmesh-deploy.yaml` during
# the HugMesh rebrand. An scmProvider filter that matches no repo is not an error —
# the ApplicationSet simply generates nothing. No event, no degraded Application,
# no log line, and the three repos' own descriptors kept asserting they were
# "discovered by the catalog ApplicationSet". A gate against that failure mode is
# worth nothing unless it has been SEEN to bite, so every case below re-breaks the
# tree in a specific way and requires the specific failure.
#
# The contract this test pins, in one line: A REPO THAT THE CATALOG CANNOT SEE
# MUST NOT PRODUCE A GREEN RUN.
#
#   (a) tree as shipped              -> exit 0, clean `RESULT: PASS`
#   (b) drop the hugmesh- filter     -> exit 1, [adopter-visibility] naming
#       (the exact pre-fix state)       be-gateway / mod-bff-api / remote-fragment
#   (c) drop the snapdragon- filter  -> exit 1, naming the six legacy adopters
#   (d) only ONE generator fixed     -> exit 1, [appset-lockstep] (a tenant catalog
#                                       that accepts fewer names re-creates the bug
#                                       once per tenant)
#   (e) both names in ONE pathsExist -> exit 1, [appset-parse]: pathsExist is an
#                                       AND-list, so that "fix" demands a repo carry
#                                       BOTH files and matches nothing at all
#   (f) registry vs repo drift       -> exit 1, [registry-drift]
#   (g) unregistered adopter         -> exit 1, [unregistered-adopter]
#   (h) descriptor but no deploy/    -> exit 1, [deploy-dir]
#   (i) an accepted name not rename- -> exit 1, [rename-denylist]
#       protected
#   (j) checkouts absent             -> exit 3, `RESULT: INCOMPLETE`, never a clean PASS
#   (k) explicit opt-out             -> exit 0 allowed, but the verdict line must
#                                       stay the distinct `PASS (INCOMPLETE …)`
#   (l) CI wiring                    -> .gitlab-ci.yml's lint:catalog-descriptor-discovery
#                                       must actually clone every registered repo,
#                                       else the job is just case (j) every pipeline
#   (m) a PARTIAL adopter sweep      -> exit 1, [sweep-provenance]: the registry is
#       claiming completeness           the input to every other stage, so a sweep
#                                       that skipped repos makes the whole gate
#                                       incomplete with no failing assertion
#   (n) no provenance block at all   -> exit 1, [sweep-provenance]
#   (o) an accepted name with no      -> exit 1, [rename-coverage]: a denylist entry
#       behavioural rename case          nothing executes is protection on paper only
#
# EVERY assertion on a failure MESSAGE anchors on the literal "[FAIL] [<label>]".
# The gate prints the SAME bracket label on its OK path ("[OK]   [<label>] …"), so a
# grep for the bare label matches a PASSING run and cannot distinguish the two. Four
# assertions here originally did exactly that and kept printing PASS with the
# detection they named disabled; case (a) now pins that OK-path property so the
# reason for the anchoring is itself asserted rather than remembered.
#
# Everything is SYNTHESISED into a temp dir — the gate's inputs are staged and
# mutated there, and the adopter "checkouts" are plain directories — so this test
# needs no network, no sibling checkouts, no cluster, and it can construct states
# (a drifted repo, an unregistered adopter) that a real checkout cannot be made to
# reach on demand.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_REL="scripts/validate-catalog-discovery.sh"
CI="${REPO}/.gitlab-ci.yml"

# Every file the gate reads, relative to the repo root. Staged into each scenario
# tree so a mutation touches only that scenario.
INPUTS=(
  "${GATE_REL}"
  specs/cluster/catalog/adopters.yaml
  specs/cluster/apps/13-service-catalog.yaml
  templates/apps/13d-brand-repos.yaml.hbs
  scripts/publish-tenant-set.sh
  scripts/tooling/render-recipe.js
  tests/domain-registry/test-templating-rename-pr.sh
)

for rel in "${INPUTS[@]}"; do
  [ -r "${REPO}/${rel}" ] || { echo "  FAIL missing gate input: ${REPO}/${rel}"; exit 1; }
done
[ -r "${CI}" ] || { echo "  FAIL missing ${CI}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
W="$(mktemp -d)"; trap 'rm -rf "${W}" 2>/dev/null' EXIT

# stage <name> -> echoes the staged tree root
stage() {
  local t="${W}/$1"
  rm -rf "${t}"
  local rel
  for rel in "${INPUTS[@]}"; do
    mkdir -p "${t}/$(dirname "${rel}")"
    cp "${REPO}/${rel}" "${t}/${rel}"
  done
  echo "${t}"
}

# synth_siblings <tree> <dir> — build "checkouts" for every repo the staged
# registry declares: <descriptor> + deploy/kustomization.yaml at the root.
# Env knobs manufacture the drift cases:
#   DROP=<repo>     omit that checkout entirely
#   FLIP=<repo>     write the OTHER descriptor spelling than the one registered
#   NODEPLOY=<repo> write the descriptor but no deploy/ dir
#   EXTRA=<repo>    also write an UNREGISTERED adopter of that name
synth_siblings() {
  local tree="$1" dir="$2"
  rm -rf "${dir}"; mkdir -p "${dir}"
  DROP="${DROP:-}" FLIP="${FLIP:-}" NODEPLOY="${NODEPLOY:-}" EXTRA="${EXTRA:-}" \
    python3 - "${tree}/specs/cluster/catalog/adopters.yaml" "${dir}" <<'PY'
import os, sys, yaml
reg, out = sys.argv[1], sys.argv[2]
drop = os.environ.get("DROP", "")
flip = os.environ.get("FLIP", "")
nodeploy = os.environ.get("NODEPLOY", "")
extra = os.environ.get("EXTRA", "")
OTHER = {"snapdragon-deploy.yaml": "hugmesh-deploy.yaml",
         "hugmesh-deploy.yaml": "snapdragon-deploy.yaml"}
spec = (yaml.safe_load(open(reg, encoding="utf-8")) or {}).get("spec") or {}


def write(repo, desc, with_deploy=True):
    root = os.path.join(out, repo)
    os.makedirs(root, exist_ok=True)
    with open(os.path.join(root, desc), "w", encoding="utf-8") as fh:
        fh.write("# synthetic deploy descriptor for the catalog-discovery gate test\n"
                 "name: %s\nnamespace: hugmesh-backend\nimage: hugmesh-systems/%s\n"
                 "port: 8080\nreplicas: 1\n" % (repo, repo))
    if with_deploy:
        os.makedirs(os.path.join(root, "deploy"), exist_ok=True)
        with open(os.path.join(root, "deploy", "kustomization.yaml"), "w",
                  encoding="utf-8") as fh:
            fh.write("apiVersion: kustomize.config.k8s.io/v1beta1\n"
                     "kind: Kustomization\nresources: []\n")


for a in spec.get("adopters") or []:
    repo, desc = a["repo"], a["descriptor"]
    if repo == drop:
        continue
    if repo == flip:
        desc = OTHER.get(desc, desc)
    write(repo, desc, with_deploy=(repo != nodeploy))
if extra:
    write(extra, "snapdragon-deploy.yaml")
PY
}

# run_gate <tree> <sibling-dir> [env assignments…] -> RC in $RC, output in ${W}/out
run_gate() {
  local tree="$1" sib="$2"; shift 2
  env "$@" CATALOG_SIBLING_ROOT="${sib}" bash "${tree}/${GATE_REL}" >"${W}/out" 2>&1
  RC=$?
}

# drop_filter <tree> <file> <descriptor-name> — delete the two-line filter entry
# that matches on <descriptor-name>, exactly as if it had never been added.
drop_filter() {
  python3 - "$1/$2" "$3" <<'PY'
import re, sys
path, name = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
pat = re.compile(r"\n[ \t]*- repositoryMatch:[^\n]*\n[ \t]*pathsExist: \[\"%s\", \"deploy\"\]"
                 % re.escape(name))
new, n = pat.subn("", src, count=1)
if n != 1:
    sys.exit("injection failed: no filter entry for %s in %s" % (name, path))
open(path, "w", encoding="utf-8").write(new)
PY
}

echo "== service-catalog discovery gate: negative-control regression =="

# ── (a) the tree as shipped, every checkout present: a real PASS ─────────────
echo "-- (a) tree as shipped --"
T="$(stage base)"; synth_siblings "${T}" "${W}/sib-base"
run_gate "${T}" "${W}/sib-base"
[ "${RC}" -eq 0 ] \
  && ok "shipped tree + all checkouts exits 0" \
  || bad "shipped tree exited ${RC}: $(tail -5 "${W}/out")"
grep -q "^RESULT: PASS — every adopting repo is visible" "${W}/out" \
  && ok "shipped tree prints the clean PASS verdict" \
  || bad "shipped tree did not print the clean PASS verdict"
grep -q "all 9 registered adopters were present and checked" "${W}/out" \
  && ok "the PASS states how many adopters were actually checked" \
  || bad "the PASS does not state that every registered adopter was checked"
# The gate prints the SAME bracket label on its passing path as on its failing one
# (`[OK]   [adopter-visibility] …` vs `[FAIL] [adopter-visibility] …`). Pinning that
# here is not decoration: it is the reason every failure assertion below greps the
# anchored "[FAIL] [<label>]" and never the bare label. Four assertions in the first
# cut of this file did grep the bare label, and all four kept printing PASS while the
# detection they named was disabled.
for lbl in adopter-visibility appset-lockstep rename-denylist rename-coverage sweep-provenance; do
  grep -qF "[OK]   [${lbl}]" "${W}/out" \
    && ok "clean run prints [OK] [${lbl}] — so a bare '${lbl}' grep proves nothing" \
    || bad "clean run does not print [OK] [${lbl}]"
done
grep -qF "[FAIL] [" "${W}/out" \
  && bad "clean run emitted a [FAIL] line: $(grep -F '[FAIL] [' "${W}/out" | head -1)" \
  || ok "clean run emits no '[FAIL] [' line at all — the anchor discriminates"

# ── (b) NEGATIVE CONTROL: the exact pre-fix state ────────────────────────────
# Point the generators at the legacy filename only — what main shipped — and the
# three rebranded repos must be named as invisible. Without this case, (a) proves
# nothing: a visibility check that always passes is green too.
echo "-- (b) negative control: drop the hugmesh-deploy.yaml filter (the shipped bug) --"
T="$(stage nohug)"
drop_filter "${T}" specs/cluster/apps/13-service-catalog.yaml hugmesh-deploy.yaml \
  && drop_filter "${T}" templates/apps/13d-brand-repos.yaml.hbs hugmesh-deploy.yaml \
  || bad "(b) injection itself failed"
synth_siblings "${T}" "${W}/sib-nohug"
run_gate "${T}" "${W}/sib-nohug"
[ "${RC}" -eq 1 ] \
  && ok "legacy-name-only generators exit 1 (FAIL), not 0/3" \
  || bad "legacy-name-only generators exited ${RC} — the visibility check is vacuous"
grep -qF "[FAIL] [adopter-visibility]" "${W}/out" \
  && ok "the FAIL is reported under [adopter-visibility]" \
  || bad "the FAIL is not reported under [adopter-visibility]"
# Anchored to the offender DETAIL line the gate prints under the [adopter-visibility]
# FAIL ("           - <repo> ships <desc>; generators accept […]"). A bare grep for
# the repo name matches stage 5's "[OK] [reality] <repo> …" line for the very same
# repo, so it passed even with the visibility check disabled.
miss=""
for r in hugmesh-be-gateway hugmesh-mod-bff-api hugmesh-remote-fragment; do
  grep -qF -- "- ${r} ships hugmesh-deploy.yaml; generators accept" "${W}/out" \
    || miss="${miss} ${r}"
done
[ -z "${miss}" ] \
  && ok "the FAIL names every invisible repo (be-gateway, mod-bff-api, remote-fragment)" \
  || bad "the FAIL does not name:${miss} — an operator cannot act on an unnamed repo"
grep -q "3 adopting repo(s) are INVISIBLE" "${W}/out" \
  && ok "the FAIL counts exactly the 3 invisible repos" \
  || bad "the FAIL does not count the invisible repos correctly"

# ── (c) NEGATIVE CONTROL: the mirror image — legacy repos must not be dropped ─
# Proves the fix is a disjunction, not a rename: removing the OLD name breaks the
# five repos that still carry it.
echo "-- (c) negative control: drop the snapdragon-deploy.yaml filter --"
T="$(stage nosnap)"
drop_filter "${T}" specs/cluster/apps/13-service-catalog.yaml snapdragon-deploy.yaml \
  && drop_filter "${T}" templates/apps/13d-brand-repos.yaml.hbs snapdragon-deploy.yaml \
  || bad "(c) injection itself failed"
synth_siblings "${T}" "${W}/sib-nosnap"
run_gate "${T}" "${W}/sib-nosnap"
[ "${RC}" -eq 1 ] \
  && ok "rebranded-name-only generators exit 1 (FAIL)" \
  || bad "rebranded-name-only generators exited ${RC} — the legacy adopters are unprotected"
grep -qF "[FAIL] [adopter-visibility]" "${W}/out" \
  && ok "(c) the FAIL is reported under [adopter-visibility]" \
  || bad "(c) the FAIL is not reported under [adopter-visibility]"
grep -q "6 adopting repo(s) are INVISIBLE" "${W}/out" \
  && ok "the FAIL counts exactly the 6 legacy adopters" \
  || bad "the FAIL does not count the 6 legacy adopters: $(grep INVISIBLE "${W}/out")"

# ── (d) only ONE generator fixed: the tenant catalog would still be broken ────
echo "-- (d) generators out of lockstep (13d left on one name) --"
T="$(stage lockstep)"
drop_filter "${T}" templates/apps/13d-brand-repos.yaml.hbs hugmesh-deploy.yaml \
  || bad "(d) injection itself failed"
synth_siblings "${T}" "${W}/sib-lockstep"
run_gate "${T}" "${W}/sib-lockstep"
[ "${RC}" -eq 1 ] \
  && ok "a one-sided fix exits 1 (FAIL)" \
  || bad "a one-sided fix exited ${RC} — every tenant would inherit the bug"
if grep -qF "[FAIL] [appset-lockstep]" "${W}/out" \
   && grep -qF "13-service-catalog=['hugmesh-deploy.yaml', 'snapdragon-deploy.yaml']" "${W}/out" \
   && grep -qF "13d-brand-repos=['snapdragon-deploy.yaml']" "${W}/out"; then
  ok "the FAIL is reported under [appset-lockstep] with both name sets"
else
  bad "the FAIL is not reported under [appset-lockstep] with both name sets"
fi

# ── (e) the plausible-but-wrong fix: both names in ONE pathsExist entry ───────
# pathsExist is an AND-list, so this demands a repo carry BOTH descriptors — it
# matches nothing at all, which is worse than the bug it tries to fix.
echo "-- (e) both names crammed into one pathsExist (AND, not OR) --"
T="$(stage andlist)"
python3 - "${T}/specs/cluster/apps/13-service-catalog.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = ('          - repositoryMatch: "^hugmesh-"\n'
       '            pathsExist: ["snapdragon-deploy.yaml", "deploy"]\n'
       '          - repositoryMatch: "^hugmesh-"\n'
       '            pathsExist: ["hugmesh-deploy.yaml", "deploy"]\n')
new = ('          - repositoryMatch: "^hugmesh-"\n'
       '            pathsExist: ["snapdragon-deploy.yaml", "hugmesh-deploy.yaml", "deploy"]\n')
if old not in s:
    sys.exit("injection failed: filter block not found verbatim")
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
[ $? -eq 0 ] || bad "(e) injection itself failed"
synth_siblings "${T}" "${W}/sib-andlist"
run_gate "${T}" "${W}/sib-andlist"
[ "${RC}" -eq 1 ] \
  && ok "two descriptor names in one pathsExist entry exits 1 (FAIL)" \
  || bad "two descriptor names in one pathsExist entry exited ${RC} — the AND-list trap is unguarded"
grep -qF "[FAIL] [appset-parse]" "${W}/out" && grep -q "EXACTLY one" "${W}/out" \
  && ok "the FAIL explains that pathsExist ANDs and the disjunction needs a 2nd entry" \
  || bad "the FAIL does not explain the AND-list semantics under [appset-parse]"

# ── (f) registry vs repo drift ───────────────────────────────────────────────
echo "-- (f) a repo ships a different descriptor than the registry claims --"
T="$(stage drift)"; FLIP=hugmesh-user-bff-api synth_siblings "${T}" "${W}/sib-drift"
run_gate "${T}" "${W}/sib-drift"
[ "${RC}" -eq 1 ] \
  && ok "a drifted registry entry exits 1 (FAIL)" \
  || bad "a drifted registry entry exited ${RC} — the registry could go stale unnoticed"
grep -qF "[FAIL] [registry-drift] hugmesh-user-bff-api:" "${W}/out" \
   && grep -qF "actually ships ['hugmesh-deploy.yaml']" "${W}/out" \
  && ok "the FAIL names the drifted repo and both filenames" \
  || bad "the FAIL does not name the drifted repo"

# ── (g) an adopter nobody declared ───────────────────────────────────────────
echo "-- (g) an unregistered repo ships a descriptor --"
T="$(stage extra)"; EXTRA=hugmesh-tube-bff-api synth_siblings "${T}" "${W}/sib-extra"
run_gate "${T}" "${W}/sib-extra"
[ "${RC}" -eq 1 ] \
  && ok "an unregistered adopter exits 1 (FAIL)" \
  || bad "an unregistered adopter exited ${RC} — a new repo could adopt a name nothing matches"
grep -qF "[FAIL] [unregistered-adopter] hugmesh-tube-bff-api ships" "${W}/out" \
  && ok "the FAIL names the unregistered adopter" \
  || bad "the FAIL does not name the unregistered adopter"

# ── (h) descriptor present, deploy/ missing ──────────────────────────────────
# Both halves of the filter are ANDed, so a descriptor without deploy/ is just as
# invisible — and the generated Application would have no source.path either.
echo "-- (h) a registered adopter with no deploy/ dir --"
T="$(stage nodeploy)"; NODEPLOY=hugmesh-forum-ui synth_siblings "${T}" "${W}/sib-nodeploy"
run_gate "${T}" "${W}/sib-nodeploy"
[ "${RC}" -eq 1 ] \
  && ok "a descriptor without deploy/ exits 1 (FAIL)" \
  || bad "a descriptor without deploy/ exited ${RC} — the other half of the AND is unchecked"
grep -qF "[FAIL] [deploy-dir] hugmesh-forum-ui:" "${W}/out" \
  && ok "the FAIL names the repo missing deploy/" \
  || bad "the FAIL does not name the repo missing deploy/"

# ── (i) an accepted name that a recipe could rename away ─────────────────────
echo "-- (i) an accepted descriptor name missing from the rename contract denylist --"
T="$(stage deny)"
python3 - "${T}/scripts/tooling/render-recipe.js" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "  'hugmesh-deploy.yaml',\n" not in s:
    sys.exit("injection failed: denylist entry not found")
open(p, "w", encoding="utf-8").write(s.replace("  'hugmesh-deploy.yaml',\n", "", 1))
PY
[ $? -eq 0 ] || bad "(i) injection itself failed"
synth_siblings "${T}" "${W}/sib-deny"
run_gate "${T}" "${W}/sib-deny"
[ "${RC}" -eq 1 ] \
  && ok "an unprotected accepted name exits 1 (FAIL)" \
  || bad "an unprotected accepted name exited ${RC} — a recipe could rename a live descriptor"
grep -qF "[FAIL] [rename-denylist]" "${W}/out" \
   && grep -qF "RENAME_CONTRACT_DENYLIST: ['hugmesh-deploy.yaml']" "${W}/out" \
  && ok "the FAIL is reported under [rename-denylist] naming the unprotected spelling" \
  || bad "the FAIL is not reported under [rename-denylist]"

# ── (j) checkouts absent: must NOT look like a clean pass ────────────────────
echo "-- (j) no adopter checkouts at all --"
T="$(stage empty)"; mkdir -p "${W}/sib-empty"
run_gate "${T}" "${W}/sib-empty"
[ "${RC}" -eq 3 ] \
  && ok "absent checkouts exit 3 (INCOMPLETE), not 0" \
  || bad "absent checkouts exited ${RC} — a run that skipped the reality check must not exit 0"
grep -q "RESULT: INCOMPLETE" "${W}/out" \
  && ok "absent checkouts print the distinct 'RESULT: INCOMPLETE' verdict" \
  || bad "absent checkouts did not print 'RESULT: INCOMPLETE'"
grep -q "^RESULT: PASS — every adopting repo is visible to the service catalog\.$" "${W}/out" \
  && bad "absent checkouts STILL print the clean PASS line" \
  || ok "absent checkouts never print the clean PASS line"
grep -q "\[MISSING\]" "${W}/out" \
  && ok "each unchecked adopter is reported [MISSING] with its resolved path" \
  || bad "unchecked adopters are not individually reported as [MISSING]"

# ── (k) explicit opt-out: exit 0 allowed, clean PASS still forbidden ─────────
echo "-- (k) deliberate CATALOG_ALLOW_MISSING_REPOS=1 opt-out --"
run_gate "${T}" "${W}/sib-empty" CATALOG_ALLOW_MISSING_REPOS=1
[ "${RC}" -eq 0 ] \
  && ok "opt-out exits 0 (a local run without checkouts is still usable)" \
  || bad "opt-out exited ${RC}, expected 0"
grep -q "RESULT: PASS (INCOMPLETE" "${W}/out" \
  && ok "opt-out still prints the distinct 'PASS (INCOMPLETE …)' verdict" \
  || bad "opt-out prints an indistinguishable verdict"
grep -q "^RESULT: PASS — every adopting repo is visible to the service catalog\.$" "${W}/out" \
  && bad "opt-out prints the clean PASS line — indistinguishable from a complete run" \
  || ok "opt-out never prints the clean PASS line"

# ── (l) CI must actually supply the checkouts ────────────────────────────────
# Otherwise the gate is honest but permanently INCOMPLETE: the job would hit (j)
# on every pipeline. Also pins the clone list to the registry, so registering a
# ninth adopter without cloning it is caught here rather than by a surprise exit 3.
echo "-- (l) .gitlab-ci.yml lint:catalog-descriptor-discovery genuinely provides them --"
CI="${CI}" REG="${REPO}/specs/cluster/catalog/adopters.yaml" python3 - <<'PY' >"${W}/ci.out" 2>&1
import os, sys, yaml
ci = yaml.safe_load(open(os.environ["CI"], encoding="utf-8"))
job = ci.get("lint:catalog-descriptor-discovery")
if not job:
    print("MISSING_JOB"); sys.exit(0)
blob = yaml.safe_dump(job)
spec = (yaml.safe_load(open(os.environ["REG"], encoding="utf-8")) or {}).get("spec") or {}
declared = [a["repo"] for a in spec.get("adopters") or []]
print("DECLARED", len(declared))
missing = [r for r in declared if r not in blob]
print("NOT_CLONED", " ".join(missing) if missing else "-")
print("SETS_ROOT", "yes" if "CATALOG_SIBLING_ROOT" in blob else "no")
print("OPTS_OUT", "yes" if "CATALOG_ALLOW_MISSING_REPOS" in blob else "no")
print("HAS_PYYAML", "yes" if "pyyaml" in blob else "no")
print("RUNS_GATE", "yes" if "scripts/validate-catalog-discovery.sh" in blob else "no")
PY
if grep -q MISSING_JOB "${W}/ci.out"; then
  bad "no lint:catalog-descriptor-discovery job in .gitlab-ci.yml — the gate is not wired"
else
  grep -q "^NOT_CLONED -$" "${W}/ci.out" \
    && ok "CI clones every adopter the registry declares ($(sed -n 's/^DECLARED //p' "${W}/ci.out"))" \
    || bad "CI does not clone: $(sed -n 's/^NOT_CLONED //p' "${W}/ci.out") — the job would be INCOMPLETE every run"
  grep -q "^SETS_ROOT yes$" "${W}/ci.out" \
    && ok "CI points CATALOG_SIBLING_ROOT at the clone dir" \
    || bad "CI never sets CATALOG_SIBLING_ROOT — the clones would not be found"
  grep -q "^OPTS_OUT no$" "${W}/ci.out" \
    && ok "CI does NOT set the CATALOG_ALLOW_MISSING_REPOS escape hatch" \
    || bad "CI sets CATALOG_ALLOW_MISSING_REPOS — that re-opens the hole this gate closes"
  grep -q "^HAS_PYYAML yes$" "${W}/ci.out" \
    && ok "CI installs PyYAML (the gate FATALs exit 2 without it)" \
    || bad "CI does not install PyYAML"
  grep -q "^RUNS_GATE yes$" "${W}/ci.out" \
    && ok "CI actually runs scripts/validate-catalog-discovery.sh" \
    || bad "CI job does not run the gate script"
fi

# ── (m) a registry built from a PARTIAL sweep that claims to be complete ──────
# The real regression: the first cut of adopters.yaml was swept over the operator's
# 33 local checkouts while the org had 38 repos, and it silently missed
# hugmesh-character-forge-bff-api — an adopter with a `snapdragon-deploy.yaml` and a
# `deploy/` tree on main, absent from the registry, absent from the CI clone list,
# and therefore checked by nothing. Every other stage of this gate reads FROM the
# registry, so an incomplete registry makes the whole gate incomplete without a
# single failing assertion. `spec.sweep` records the provenance and stage 1 requires
# sweptRepos == orgRepos.
echo "-- (m) the adopter sweep covered fewer repos than the org has --"
T="$(stage sweep)"
python3 - "${T}/specs/cluster/catalog/adopters.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "    sweptRepos: 38\n" not in s:
    sys.exit("injection failed: sweptRepos: 38 not found")
open(p, "w", encoding="utf-8").write(s.replace("    sweptRepos: 38\n", "    sweptRepos: 33\n", 1))
PY
[ $? -eq 0 ] || bad "(m) injection itself failed"
synth_siblings "${T}" "${W}/sib-sweep"
run_gate "${T}" "${W}/sib-sweep"
[ "${RC}" -eq 1 ] \
  && ok "a registry swept over 33 of 38 org repos exits 1 (FAIL)" \
  || bad "a partial sweep exited ${RC} — an unregistered adopter would be checked by nothing"
grep -qF "[FAIL] [sweep-provenance]" "${W}/out" \
   && grep -qF "covered only 33 of the org's 38 repos" "${W}/out" \
  && ok "the FAIL is reported under [sweep-provenance] with both counts" \
  || bad "the FAIL is not reported under [sweep-provenance] with both counts"

# ── (n) no provenance block at all ───────────────────────────────────────────
echo "-- (n) the registry records no sweep provenance --"
T="$(stage nosweep)"
python3 - "${T}/specs/cluster/catalog/adopters.yaml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
new, n = re.subn(r"\n  sweep:\n(?:    [^\n]*\n|    #[^\n]*\n|\n)+", "\n", s, count=1)
if n != 1:
    sys.exit("injection failed: sweep block not found")
import yaml
if (yaml.safe_load(new).get("spec") or {}).get("sweep") is not None:
    sys.exit("injection failed: sweep block survived")
open(p, "w", encoding="utf-8").write(new)
PY
[ $? -eq 0 ] || bad "(n) injection itself failed"
synth_siblings "${T}" "${W}/sib-nosweep"
run_gate "${T}" "${W}/sib-nosweep"
[ "${RC}" -eq 1 ] \
  && ok "a registry with no sweep provenance exits 1 (FAIL)" \
  || bad "a registry with no sweep provenance exited ${RC} — an undocumented sweep is unauditable"
grep -qF "[FAIL] [sweep-provenance]" "${W}/out" \
   && grep -q "declares no .spec.sweep. block" "${W}/out" \
  && ok "the FAIL is reported under [sweep-provenance] and says the block is absent" \
  || bad "the FAIL does not name the absent provenance block"

# ── (o) an accepted name whose denylist entry nothing ever executes ──────────
# Being in RENAME_CONTRACT_DENYLIST is a promise; tests/domain-registry/
# test-templating-rename-pr.sh (cases A9*) is the only thing that EXECUTES it.
# A spelling added to the Set with no case there is protected on paper only —
# nothing would notice if it stopped refusing.
echo "-- (o) an accepted name with no behavioural rename case --"
T="$(stage cover)"
python3 - "${T}/tests/domain-registry/test-templating-rename-pr.sh" <<'PYCOVER'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "hugmesh-deploy.yaml" not in s:
    sys.exit("injection failed: no hugmesh-deploy.yaml case to remove")
open(p, "w", encoding="utf-8").write(s.replace("hugmesh-deploy.yaml", "some-other.yaml"))
PYCOVER
[ $? -eq 0 ] || bad "(o) injection itself failed"
synth_siblings "${T}" "${W}/sib-cover"
run_gate "${T}" "${W}/sib-cover"
[ "${RC}" -eq 1 ] \
  && ok "an accepted name with no rename case exits 1 (FAIL)" \
  || bad "an unexercised denylist entry exited ${RC} — the protection is paper only"
grep -qF "[FAIL] [rename-coverage]" "${W}/out" \
   && grep -qF "['hugmesh-deploy.yaml']" "${W}/out" \
  && ok "the FAIL is reported under [rename-coverage] naming the uncovered spelling" \
  || bad "the FAIL does not name the uncovered spelling under [rename-coverage]"

echo ""
echo "== catalog discovery gate regression: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
