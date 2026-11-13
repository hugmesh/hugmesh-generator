#!/usr/bin/env bash
# test-github-workflows-wellformed.sh — no .github/workflows/*.yml may carry a
# DUPLICATE mapping key.
#
# WHY THIS EXISTS. On 2026-11-12 two pull requests each set `timeout-minutes:` on
# the shell-suites `docker` job (one at 15 with the NEW-15 idp-exposure comment
# block, one at 30 with the headscale minters / embedded-DERP block). git merged
# them without a conflict: the two lines are far enough apart. GitHub rejects a
# workflow file with a duplicate key ("This run likely failed because of a
# workflow file issue"), so from that merge on, NO job in shell-suites.yml ran on
# any push or pull request: every shell suite in the file stopped guarding at
# once, and the only signal was a red run with zero jobs.
#
# PyYAML's safe_load does NOT see it: like most YAML loaders it keeps the LAST
# value for a repeated key and says nothing, so every yaml-reading suite here
# parsed the broken file happily. The loader below refuses a key typed twice in
# one mapping (before flatten_mapping, so a `<<:` merge key overridden by an
# explicit key — a legitimate idiom — is not flagged). Same approach as
# tests/scripts/test-gitlab-ci-wellformed.sh, which has guarded .gitlab-ci.yml
# against this exact shape since hugmesh-generator#386.
#
# WHERE IT RUNS. Twice, on purpose: in shell-suites.yml's debian leg AND in its
# own workflow, .github/workflows/workflows-wellformed.yml. A duplicate key in
# shell-suites.yml stops that whole workflow, so a check that lived only there
# could never report the one file it most needs to read.
#
# Offline: python3 + PyYAML only. A missing tool is a FAIL, never a skip.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
WF_DIR="${WF_DIR:-${REPO}/.github/workflows}"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 required (refusing to skip — a skipping gate never guards)" >&2
  exit 1
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "FATAL: PyYAML required (refusing to skip)" >&2
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/dupcheck.py" <<'PY'
"""Usage: dupcheck.py FILE... -> one line per problem on stdout; exit 1 if any."""
import sys

import yaml


class NoDupLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        # Scan the RAW pairs before flatten_mapping(): it expands `<<:` by
        # prepending the anchor's pairs, and an explicit key overriding one of
        # those is intentional, not a duplicate.
        if isinstance(node, yaml.MappingNode):
            seen = {}
            for key_node, _ in node.value:
                if getattr(key_node, "tag", None) == "tag:yaml.org,2002:merge":
                    continue
                try:
                    key = self.construct_object(key_node, deep=True)
                    hash(key)
                except TypeError:
                    continue
                if key in seen:
                    raise yaml.constructor.ConstructorError(
                        "while constructing a mapping", node.start_mark,
                        "found duplicate key %r: first at line %d, again at line %d "
                        "(GitHub rejects the whole workflow file)"
                        % (key, seen[key] + 1, key_node.start_mark.line + 1),
                        key_node.start_mark)
                seen[key] = key_node.start_mark.line
        return super().construct_mapping(node, deep=deep)


rc = 0
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as fh:
            docs = list(yaml.load_all(fh, Loader=NoDupLoader))
    except yaml.YAMLError as exc:
        print("%s: %s" % (path, " ".join(str(exc).split())))
        rc = 1
        continue
    if not docs or not isinstance(docs[0], dict):
        print("%s: not a mapping at the top level" % path)
        rc = 1
sys.exit(rc)
PY

check() { python3 "${TMP}/dupcheck.py" "$@"; }

echo "== GitHub workflow files: no duplicate keys (${WF_DIR}) =="

shopt -s nullglob
files=("${WF_DIR}"/*.yml "${WF_DIR}"/*.yaml)
shopt -u nullglob
# Vacuity floor: a glob that matches nothing must not read as "all clean".
if [ "${#files[@]}" -ge 5 ]; then
  ok "found ${#files[@]} workflow files to read"
else
  bad "found only ${#files[@]} workflow files under ${WF_DIR} — the glob is not reading the tree"
fi

for f in "${files[@]}"; do
  out="$(check "$f")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "${f#"${REPO}/"}"
  else
    bad "${f#"${REPO}/"}: ${out}"
  fi
done

# ── negative controls: the checker must go RED on each planted shape ─────────
echo "== negative controls =="
# n1: the 2026-11-12 shape — the same key twice in one job, comments between.
cat > "${TMP}/n1.yml" <<'Y'
name: n1
on: pull_request
jobs:
  docker:
    runs-on: ubuntu-latest
    # suite A
    timeout-minutes: 15
    # suite B
    timeout-minutes: 30
    steps:
      - run: true
Y
# n2: a duplicate top-level key (two `on:` blocks, say).
cat > "${TMP}/n2.yml" <<'Y'
name: n2
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: true
on: push
Y
# n3: a duplicate deep in a step (two `env:` keys under one `with:`).
cat > "${TMP}/n3.yml" <<'Y'
name: n3
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-depth: 1
Y
# n4: two jobs with the same id (two merges each appending a job).
cat > "${TMP}/n4.yml" <<'Y'
name: n4
on: pull_request
jobs:
  a:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  a:
    runs-on: ubuntu-latest
    steps: [{run: "false"}]
Y
for n in n1 n2 n3 n4; do
  # A control is only meaningful if plain safe_load ACCEPTS the file: that is the
  # whole defect. Prove it, then prove the checker refuses it.
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "${TMP}/${n}.yml" 2>/dev/null; then
    if out="$(check "${TMP}/${n}.yml")"; then
      bad "${n}: planted duplicate key was NOT caught"
    else
      case "$out" in
        *"found duplicate key"*) ok "${n}: caught (${out##*found })" ;;
        *) bad "${n}: failed, but not for the duplicate key: ${out}" ;;
      esac
    fi
  else
    bad "${n}: plain yaml.safe_load rejected the fixture, so it proves nothing"
  fi
done

# p1: positive control — a `<<:` merge overridden by an explicit key is legal.
cat > "${TMP}/p1.yml" <<'Y'
name: p1
on: pull_request
x-base: &base
  runs-on: ubuntu-latest
  timeout-minutes: 10
jobs:
  a:
    <<: *base
    timeout-minutes: 20
    steps: [{run: "true"}]
Y
if out="$(check "${TMP}/p1.yml")"; then
  ok "p1: a merge-key override is not a duplicate"
else
  bad "p1: a merge-key override was flagged: ${out}"
fi

# n5: the real tree's shell-suites.yml with the 2026-11-12 duplicate put back.
real="${WF_DIR}/shell-suites.yml"
if [ -f "$real" ]; then
  python3 - "$real" "${TMP}/n5.yml" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# Repeat the FIRST job-level timeout-minutes line right after itself.
m = re.search(r"^(    timeout-minutes: \d+\n)", src, re.M)
if not m:
    sys.exit(3)
open(sys.argv[2], "w", encoding="utf-8").write(src[:m.end()] + m.group(1) + src[m.end():])
PY
  prc=$?
  if [ "$prc" -ne 0 ]; then
    bad "n5: could not plant a duplicate into shell-suites.yml (no job-level timeout-minutes?)"
  elif cmp -s "$real" "${TMP}/n5.yml"; then
    bad "n5: the planted copy is identical to the original — nothing was planted"
  elif check "${TMP}/n5.yml" >/dev/null; then
    bad "n5: duplicate planted into the real shell-suites.yml was NOT caught"
  else
    ok "n5: duplicate planted into the real shell-suites.yml is caught"
  fi
else
  bad "n5: ${real} is missing"
fi

echo
echo "── ${pass} passed / ${fail} failed ──"
[ "$fail" -eq 0 ]
