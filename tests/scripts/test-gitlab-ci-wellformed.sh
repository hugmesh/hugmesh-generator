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

check_file() { # <path> -> prints findings, returns 1 if any
  CI_PATH="$1" python3 - <<'PY'
import os, sys, yaml

path = os.environ["CI_PATH"]
try:
    doc = yaml.safe_load(open(path))
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
problems = []
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

# ── negative controls: the gate must actually bite ────────────────────────────
echo "-- negative controls --"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

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

echo
echo "== gitlab-ci well-formedness: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
