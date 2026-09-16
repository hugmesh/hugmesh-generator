#!/usr/bin/env bash
# test-gitlab-ci-wellformed.sh — .gitlab-ci.yml must be a VALID pipeline config,
# not merely valid YAML.
#
# WHY THIS EXISTS. Three branches each appended a lint job to .gitlab-ci.yml at
# the same place. Every pair merged without a git conflict — and the result was
# broken: `lint:workload-console:` lost its whole body to the next job's comment
# block and became a NULL mapping value, while its `script:` line was absorbed
# into the following job. YAML still parsed, every branch's own tests still
# passed, and nothing anywhere looked at the merged file. GitLab rejects a null
# job at pipeline-creation time, so the effect is not one broken job: NO
# PIPELINE RUNS AT ALL for the repo, i.e. every gate in this file silently
# stops guarding.
#
# A null job is the signature of exactly that collision, so this test refuses
# it — plus the neighbouring shapes that are just as dead (a job with no
# script/trigger/extends, a job referencing a script file that does not exist).
# Offline: python3 + PyYAML only, no runner, no network.
#
# ── `!reference` IS PART OF THE GRAMMAR (issue #252) ─────────────────────────
# PyYAML's SafeLoader has no constructor for GitLab's `!reference [.job, key]`
# tag, so a pipeline that uses it — the DOCUMENTED way to splice an included
# template's before_script instead of replacing it (`extends:` REPLACES arrays,
# which is how hugmesh-admin-ui's DAST job came to run with no nuclei binary) —
# used to be reported here as "yaml parse error: could not determine a
# constructor for the tag '!reference'", and the trigger check then died with a
# traceback instead of a finding. Nothing in THIS repo's .gitlab-ci.yml uses the
# tag, so the gate looked green while it could not read the first onboarded repo
# that follows the template correctly (hugmesh/hugmesh-api-docs, merged PR #7:
# `- !reference [.pentest-dast-base, before_script]`).
#
# The loader below (${TMP}/ciyaml.py, shared by both checks) registers the tag
# as a marker and RESOLVES it against the loaded document before any job rule
# runs: a list-valued reference splices in place, a scalar/mapping one replaces
# the marker, nesting is bounded at GitLab's own limit of 10 hops, and a
# reference that points at nothing is a FINDING (GitLab rejects that at pipeline
# creation too), never a traceback. Resolution feeds the trigger check as well,
# so a `bash tests/...` line that arrives through `!reference` is still held to
# the rules:changes invariant — the negative controls (n7–n10) prove each half.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CI_FILE="${CI_FILE:-${REPO}/.gitlab-ci.yml}"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# Tooling is a HARD requirement, never a skip: a guard that skips in CI is a
# guard that never guards (this repo has shipped several).
if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 required (refusing to skip — a skipping gate never guards)" >&2
  exit 1
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "FATAL: PyYAML required (refusing to skip)" >&2
  exit 1
fi

echo "== .gitlab-ci.yml well-formedness: ${CI_FILE} =="

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
# Shared loader: SafeLoader + GitLab's `!reference`, resolved before the checks.
# One module, imported by both python programs below, so the two checks can never
# disagree about what the tag means.
cat > "${TMP}/ciyaml.py" <<'PY'
"""SafeLoader + GitLab `!reference` (issue #252). load(path) -> (doc, problems)."""
import yaml

MAX_HOPS = 10          # GitLab's documented nesting limit for !reference
_MARK = "__reference__"


class CiLoader(yaml.SafeLoader):
    """yaml.safe_load semantics plus the one GitLab tag a pipeline may carry."""


def _reference(loader, node):
    return {_MARK: loader.construct_sequence(node, deep=True)}


CiLoader.add_constructor("!reference", _reference)


def _is_ref(x):
    return isinstance(x, dict) and set(x) == {_MARK}


def _lookup(root, path):
    cur = root
    for seg in path:
        if not isinstance(cur, dict) or seg not in cur:
            return None, False
        cur = cur[seg]
    return cur, True


def _resolve(node, root, problems, hops):
    """Resolve markers in-place semantics: list-valued refs splice, others replace."""
    if _is_ref(node):
        path = node[_MARK]
        if hops >= MAX_HOPS:
            problems.append("!reference %s nests deeper than GitLab's limit of %d"
                            % (path, MAX_HOPS))
            return None
        target, found = _lookup(root, path)
        if not found:
            problems.append("!reference %s points at nothing — GitLab rejects this at "
                            "pipeline creation, so NO pipeline runs at all" % (path,))
            return None
        return _resolve(target, root, problems, hops + 1)
    if isinstance(node, list):
        out = []
        for item in node:
            if _is_ref(item):
                r = _resolve(item, root, problems, hops)
                if isinstance(r, list):
                    out.extend(r)          # a list-valued reference splices in place
                elif r is not None:
                    out.append(r)
            else:
                out.append(_resolve(item, root, problems, hops))
        return out
    if isinstance(node, dict):
        return {k: _resolve(v, root, problems, hops) for k, v in node.items()}
    return node


def load(path):
    """Parse with the CI loader and resolve every !reference. Never raises on a
    dangling reference — that is a finding in `problems`; parse errors still raise."""
    with open(path) as fh:
        doc = yaml.load(fh, Loader=CiLoader)
    problems = []
    if isinstance(doc, dict):
        doc = _resolve(doc, doc, problems, 0)
    return doc, problems
PY

check_file() { # <path> -> prints findings, returns 1 if any
  CI_PATH="$1" CI_HELPER_DIR="${TMP}" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["CI_HELPER_DIR"])
import ciyaml

path = os.environ["CI_PATH"]
try:
    doc, problems = ciyaml.load(path)      # !reference-aware; dangling refs -> problems
except Exception as e:
    print(f"    yaml parse error: {e}")
    sys.exit(1)
if not isinstance(doc, dict):
    print("    top level is not a mapping")
    sys.exit(1)

# Reserved top-level keywords are configuration, not jobs.
RESERVED = {
    "stages", "variables", "default", "include", "workflow",
    "image", "services", "before_script", "after_script", "cache",
}
for name, body in doc.items():
    if name in RESERVED or str(name).startswith("."):
        continue                      # .hidden keys are templates/anchors
    if body is None:
        problems.append(
            f"job '{name}' is NULL — its body was lost (the merge-collision signature). "
            f"GitLab rejects this at pipeline creation, so NO pipeline runs at all."
        )
        continue
    if not isinstance(body, dict):
        problems.append(f"job '{name}' is {type(body).__name__}, expected a mapping")
        continue
    if not ({"script", "trigger", "extends", "run"} & set(body)):
        problems.append(
            f"job '{name}' defines no script/trigger/extends — it can never do anything"
        )

for p in problems:
    print(f"    {p}")
sys.exit(1 if problems else 0)
PY
}

if check_file "${CI_FILE}"; then
  ok "every job is a well-formed mapping with something to run"
else
  bad "malformed job(s) above — see the header comment for how this happens"
fi

# Every `bash tests/...` a job runs must exist, or the gate is a no-op that
# fails only at runtime on a runner nobody is watching.
missing="$(grep -oE 'bash tests/[A-Za-z0-9._/-]+\.sh' "${CI_FILE}" | awk '{print $2}' | sort -u \
           | while read -r f; do [ -f "${REPO}/${f}" ] || echo "${f}"; done)"
if [ -z "${missing}" ]; then
  ok "every 'bash tests/*.sh' invocation points at a file that exists"
else
  bad "CI invokes suites that do not exist:"; printf '         %s\n' ${missing}
fi

# ── A JOB THAT NEVER RUNS IS THE SAME AS NO JOB ───────────────────────────────
# The second way this file silently stops guarding, and it has already shipped:
# `egress-vpn-node-agents` was added with `rules:` that named neither the tests
# it runs nor the default branch, so editing one of its guards could not run it
# and main never ran it at all — while its commit message said "a guard nothing
# runs is not a guard".
#
# THIS CHECK MUST LIVE HERE, not in the suite it protects: a job cannot police
# its own trigger, because a rule that stops the job from running also stops the
# check. lint:gitlab-ci-wellformed runs on every change to this file AND on the
# default branch, which is what breaks that circle.
#
# INVARIANT — for every job that runs `bash tests/<dir>/<suite>.sh`:
#   * a job with no `changes:` rule runs unconditionally: nothing to check;
#   * otherwise its `changes:` must COVER every suite it runs (the
#     `tests/<dir>/**/*` glob, or each suite path listed literally) — so editing
#     a guard runs that guard;
#   * and it must carry a `$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH` rule — so a
#     merged change is re-validated on main.
check_triggers() { # <path> -> prints findings, returns 1 if any
  CI_PATH="$1" CI_HELPER_DIR="${TMP}" python3 - <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["CI_HELPER_DIR"])
import ciyaml

try:
    doc, _ = ciyaml.load(os.environ["CI_PATH"])   # spliced !reference lines are checked too
except Exception as e:
    print(f"    yaml parse error: {e}")           # check_file already reported it as a finding
    sys.exit(1)
RESERVED = {"stages", "variables", "default", "include", "workflow",
            "image", "services", "before_script", "after_script", "cache"}

def covered(path, patterns):
    for p in patterns:
        if p == path:
            return True
        if p.endswith("/**/*") or p.endswith("/**"):
            prefix = p[:p.index("/**")] + "/"
            if path.startswith(prefix):
                return True
    return False

problems = []
for name, body in (doc or {}).items():
    if name in RESERVED or str(name).startswith(".") or not isinstance(body, dict):
        continue
    script = body.get("script") or []
    if isinstance(script, str):
        script = [script]
    suites = sorted({m.group(1) for s in script
                     for m in re.finditer(r'bash\s+(tests/[A-Za-z0-9._/-]+\.sh)', str(s))})
    # A glob loop (`for t in tests/<dir>/*.sh`) runs the whole directory.
    globs = sorted({m.group(1) for s in script
                    for m in re.finditer(r'(tests/[A-Za-z0-9._-]+)/\*\.sh', str(s))})
    if not suites and not globs:
        continue
    rules = body.get("rules")
    if not isinstance(rules, list):
        continue                      # no rules => the job always runs
    changes = [c for r in rules if isinstance(r, dict) for c in (r.get("changes") or [])]
    if not changes:
        continue                      # no changes-filter => the job always runs
    want = list(suites) + [g + "/x.sh" for g in globs]
    uncovered = [w for w in want if not covered(w, changes)]
    if uncovered:
        problems.append(
            f"job '{name}' runs {', '.join(suites + [g + '/*.sh' for g in globs])} but its "
            f"rules:changes never names it — editing one of those guards cannot run it")
    if not any(isinstance(r, dict) and "CI_DEFAULT_BRANCH" in str(r.get("if", ""))
               for r in rules):
        problems.append(
            f"job '{name}' has a changes-filter but no default-branch rule — it never runs on main")

for p in problems:
    print(f"    {p}")
sys.exit(1 if problems else 0)
PY
}

if check_triggers "${CI_FILE}"; then
  ok "every tests/ suite's job is triggered by its own guards and by the default branch"
else
  bad "job(s) above can never run when it matters — see the header comment"
fi

# ── negative controls: the gate must actually bite ────────────────────────────
echo "-- negative controls --"

# (n1) the exact defect that shipped: a job whose body was eaten by a comment.
{ printf 'stages: [lint]\nlint:eaten:\n# a comment block that swallowed the body\nlint:next:\n  stage: lint\n  script:\n    - true\n'; } > "${TMP}/null-job.yml"
if check_file "${TMP}/null-job.yml" >/dev/null 2>&1; then
  bad "negative control: a NULL job was NOT caught"
else
  ok "negative control: NULL job (the shipped defect) is caught"
fi

# (n2) a job that parses fine but can never run.
{ printf 'stages: [lint]\nlint:inert:\n  stage: lint\n  tags: [x]\n'; } > "${TMP}/no-script.yml"
if check_file "${TMP}/no-script.yml" >/dev/null 2>&1; then
  bad "negative control: a job with no script/trigger/extends was NOT caught"
else
  ok "negative control: job with nothing to run is caught"
fi

# (n3) vacuity control: a clean file must PASS, so the two controls above are
# not passing merely because the checker rejects everything.
{ printf 'stages: [lint]\nvariables:\n  FOO: "1"\n.hidden-template:\n  script: [true]\nlint:real:\n  stage: lint\n  script:\n    - true\n'; } > "${TMP}/clean.yml"
if check_file "${TMP}/clean.yml" >/dev/null 2>&1; then
  ok "vacuity control: a well-formed file passes"
else
  bad "vacuity control: a well-formed file was rejected — the checker is over-eager"
fi

# (n4) the OTHER shipped defect: a suite-running job whose rules never name the
# suite, so editing the guard cannot run the guard.
{ printf 'stages: [verify]\nverify:blind:\n  stage: verify\n  script:\n    - bash tests/foo/test-foo.sh\n  rules:\n    - if: $CI_PIPELINE_SOURCE == "merge_request_event"\n      changes:\n        - src/foo.c\n    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\n'; } > "${TMP}/untriggered.yml"
if check_triggers "${TMP}/untriggered.yml" >/dev/null 2>&1; then
  bad "negative control: a job whose rules never name the suite it runs was NOT caught"
else
  ok "negative control: suite not named in rules:changes is caught"
fi

# (n5) …and the half that kept it off main entirely.
{ printf 'stages: [verify]\nverify:mainless:\n  stage: verify\n  script:\n    - bash tests/foo/test-foo.sh\n  rules:\n    - if: $CI_PIPELINE_SOURCE == "merge_request_event"\n      changes:\n        - tests/foo/**/*\n'; } > "${TMP}/no-main.yml"
if check_triggers "${TMP}/no-main.yml" >/dev/null 2>&1; then
  bad "negative control: a changes-filtered job with no default-branch rule was NOT caught"
else
  ok "negative control: missing default-branch rule is caught"
fi

# (n6) vacuity control for the trigger check: a correctly-wired job — and an
# unconditional one, which legitimately needs no changes-filter — must PASS.
{ printf 'stages: [verify]\nverify:wired:\n  stage: verify\n  script:\n    - bash tests/foo/test-foo.sh\n  rules:\n    - if: $CI_PIPELINE_SOURCE == "merge_request_event"\n      changes:\n        - tests/foo/**/*\n    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\nverify:always:\n  stage: verify\n  script:\n    - bash tests/bar/test-bar.sh\n'; } > "${TMP}/wired.yml"
if check_triggers "${TMP}/wired.yml" >/dev/null 2>&1; then
  ok "vacuity control: correctly-wired and unconditional jobs pass"
else
  bad "vacuity control: a correctly-wired job was rejected — the trigger check is over-eager"
fi

# (n7) issue #252, the exact shape that broke the checker: hugmesh-api-docs PR #7
# PREPENDS a harness clone to the base template's before_script via !reference.
# A well-formed pipeline — it must PASS, and it used to die on the tag.
{ printf 'stages: [pentest]\n.pentest-dast-base:\n  stage: pentest\n  before_script:\n    - apk add nuclei\n    - test -x harness/run.sh || exit 1\n  script:\n    - bash harness/run.sh\ndast:\n  extends: .pentest-dast-base\n  before_script:\n    - git clone --depth 1 harness\n    - !reference [.pentest-dast-base, before_script]\n  rules:\n    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\n'; } > "${TMP}/reference.yml"
if check_file "${TMP}/reference.yml" >"${TMP}/reference.out" 2>&1; then
  ok "vacuity control: a pipeline using !reference (api-docs#7 shape) is read and passes"
else
  bad "a pipeline using !reference was rejected — the #252 defect is back: $(head -2 "${TMP}/reference.out" | tr '\n' ' ')"
fi
if check_triggers "${TMP}/reference.yml" >"${TMP}/reference.trig" 2>&1; then
  ok "vacuity control: the trigger check reads a !reference pipeline without a traceback"
else
  bad "the trigger check failed on a !reference pipeline: $(head -2 "${TMP}/reference.trig" | tr '\n' ' ')"
fi

# (n8) a !reference that points at nothing is what GitLab rejects at pipeline
# creation — so it must be a FINDING here (named, greppable), never a traceback.
{ printf 'stages: [lint]\nlint:dangling:\n  stage: lint\n  script:\n    - !reference [.does-not-exist, script]\n'; } > "${TMP}/dangling.yml"
if check_file "${TMP}/dangling.yml" >"${TMP}/dangling.out" 2>&1; then
  bad "negative control: a !reference to a missing anchor was NOT caught"
elif grep -q 'points at nothing' "${TMP}/dangling.out" && ! grep -q 'Traceback' "${TMP}/dangling.out"; then
  ok "negative control: a dangling !reference is a named finding, not a traceback"
else
  bad "negative control: dangling !reference failed for the wrong reason: $(head -2 "${TMP}/dangling.out" | tr '\n' ' ')"
fi

# (n9) resolution must FEED the trigger check: a suite that arrives through a
# whole-key reference (`script: !reference [...]`) is still held to rules:changes.
{ printf 'stages: [verify]\n.suite-tpl:\n  script:\n    - bash tests/foo/test-foo.sh\nverify:via-ref:\n  stage: verify\n  script: !reference [.suite-tpl, script]\n  rules:\n    - if: $CI_PIPELINE_SOURCE == "merge_request_event"\n      changes:\n        - src/foo.c\n    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\n'; } > "${TMP}/ref-untriggered.yml"
if check_triggers "${TMP}/ref-untriggered.yml" >"${TMP}/ref-untriggered.out" 2>&1; then
  bad "negative control: a suite reached only through !reference escaped the rules:changes check"
elif grep -q 'tests/foo/test-foo.sh' "${TMP}/ref-untriggered.out"; then
  ok "negative control: a suite spliced in by a whole-key !reference is still checked against rules:changes"
else
  bad "negative control: ref-untriggered failed for the wrong reason: $(head -2 "${TMP}/ref-untriggered.out" | tr '\n' ' ')"
fi

# (n10) …and through a LIST-ITEM splice (the api-docs shape), which is the case
# where the marker sits inside the array and must be expanded, not str()'d.
{ printf 'stages: [verify]\n.suite-tpl:\n  script:\n    - bash tests/foo/test-foo.sh\nverify:via-splice:\n  stage: verify\n  script:\n    - echo hi\n    - !reference [.suite-tpl, script]\n  rules:\n    - if: $CI_PIPELINE_SOURCE == "merge_request_event"\n      changes:\n        - src/foo.c\n    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH\n'; } > "${TMP}/ref-splice.yml"
if check_triggers "${TMP}/ref-splice.yml" >"${TMP}/ref-splice.out" 2>&1; then
  bad "negative control: a suite spliced in as a !reference list item escaped the rules:changes check"
elif grep -q 'tests/foo/test-foo.sh' "${TMP}/ref-splice.out"; then
  ok "negative control: a suite spliced in as a !reference list item is still checked against rules:changes"
else
  bad "negative control: ref-splice failed for the wrong reason: $(head -2 "${TMP}/ref-splice.out" | tr '\n' ' ')"
fi

echo
echo "== gitlab-ci well-formedness: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
