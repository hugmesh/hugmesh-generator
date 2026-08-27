#!/usr/bin/env bash
# test-e2e-reporter-shape.sh — the gate over what the e2e reporter EMITS.
#
# WHAT WAS WRONG. tests/e2e/reporters/hugmesh-reporter.ts pivoted summary.json by
# ROLE and by LAYER and by nothing else. There was no per-spec-file record, no
# per-test record and no attachment anywhere in it, so a consumer could learn
# that "ROLE_MOD skipped 7" and could not learn WHICH FEATURE that was, which
# test, or where its screenshot went — the Studio's feature tree cannot be
# rendered from a report shaped like that. And of the 62 skipped results in the
# run of 2026-08-22, none carried a machine-readable reason into summary.json at
# all, so every grey row was a mystery grey row.
#
# WHAT THIS ASSERTS
#   1. SHAPE. The emitted summary.json validates against
#      tests/e2e/reporters/summary.schema.json — a document the reporter cannot
#      reach. Running the suite and reading summary.json back would only prove
#      the writer agrees with itself; the schema is the independent half.
#   2. CONTENT. Every count, file, test, attachment and skip reason in the output
#      is recomputed from the replayed run by tests/scripts/e2e_reporter_shape_check.py,
#      which shares no code with the reporter.
#   3. BACKWARD COMPATIBILITY. The legacy per-RESULT totals and the role/layer
#      pivots still come out exactly as before — hugmesh_studio's parse_summary()
#      and the admin-ui console both read them.
#   4. NO SILENT LEAK. The synthetic fixture carries real-shaped credentials in an
#      error, a skip reason, a title and an attachment path; none of them may
#      survive into the report. scrub() is measured, not assumed.
#   5. NEGATIVE CONTROLS. Every one of the mutations in
#      tests/scripts/e2e_reporter_mutate.py is applied to a COPY of the reporter
#      and must make the checks go RED. A surviving control is named in the
#      output.
#
# HOW IT RUNS IT. It does NOT run the e2e suite: that needs a live stack, a
# browser and about forty minutes, and it would be circular besides.
# tests/scripts/e2e-reporter-replay.mjs hands the real reporter the same
# onBegin/onTestEnd/onEnd calls a real run made — the recorded fixture is the
# 2026-08-22 run's report.json flattened back into the calls that produced it.
#
# OFFLINE, NO STACK, NO ROOT, NO node_modules. The reporter imports node builtins,
# specs/report-tags.ts and TYPES only, so bare `node` runs it on a checkout that
# has never had `npm ci`. Needs node + python3, and says so loudly (exit 2) when
# either is missing rather than exiting 0 having checked nothing.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
E2E="${REPO}/tests/e2e"
REPORTER="${E2E}/reporters/hugmesh-reporter.ts"
SCHEMA="${E2E}/reporters/summary.schema.json"
FIXTURES="${E2E}/reporters/fixtures"
REPLAY="${HERE}/e2e-reporter-replay.mjs"
SHAPE_CHECK="${HERE}/e2e_reporter_shape_check.py"
SCHEMA_CHECK="${HERE}/jsonschema_min.py"
MUTATE="${HERE}/e2e_reporter_mutate.py"

# MODULE_TYPELESS_PACKAGE_JSON: tests/e2e/package.json has no "type" field, so
# node prints a reparse warning for every .ts import. Silencing the warning is
# not silencing a check; adding "type":"module" to that package.json would change
# how PLAYWRIGHT loads the suite, which is not this guard's business.
NODE_FLAGS="--disable-warning=MODULE_TYPELESS_PACKAGE_JSON"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e reporter: summary.json is shaped so a feature tree can render it =="

# ── preconditions: refuse to be vacuous ──────────────────────────────────────
for t in node python3; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    echo "Exiting 2 rather than 0." >&2
    exit 2
  }
done
# Node must be able to load TypeScript directly (type stripping, unflagged since
# node 23.6). Without it the reporter cannot be replayed at all, and a guard that
# quietly stops replaying is worse than one that says it cannot.
if ! node ${NODE_FLAGS} -e "process.exit(0)" 2>/dev/null; then
  echo "SKIPPED-LOUDLY: this node does not accept ${NODE_FLAGS} — need node >= 22." >&2
  exit 2
fi
for f in "${REPORTER}" "${SCHEMA}" "${REPLAY}" "${SHAPE_CHECK}" "${SCHEMA_CHECK}" "${MUTATE}"; do
  [ -f "${f}" ] || { echo "SKIPPED-LOUDLY: missing ${f}" >&2; exit 2; }
done

FIXTURE_FILES="$(find "${FIXTURES}" -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort)"
if [ -z "${FIXTURE_FILES}" ]; then
  echo "SKIPPED-LOUDLY: no fixtures under ${FIXTURES} — nothing to replay." >&2
  exit 2
fi

SCRATCH="${TMPDIR:-/var/tmp/portage}/e2e-reporter-guard.$$"
mkdir -p "${SCRATCH}" || { echo "SKIPPED-LOUDLY: cannot create ${SCRATCH}" >&2; exit 2; }
cleanup() { rm -rf "${SCRATCH}"; }
trap cleanup EXIT

# replay_and_check <fixture> <out-dir> <reporter.ts> <log>
#   0 = the emitted summary.json passed BOTH the schema and the content check.
#   1 = schema red, 2 = content red, 3 = both, 9 = the replay itself crashed.
#   The codes are ORTHOGONAL on purpose: 1+2 must not collide with the crash
#   code, or a mutation caught by both halves gets reported as a crash - which
#   it did, until it was measured.
replay_and_check() {
  FX="$1"; OUT="$2"; REP="$3"; LOG="$4"
  rm -rf "${OUT}"
  : > "${LOG}"
  if ! node ${NODE_FLAGS} "${REPLAY}" "${FX}" "${OUT}" "${REP}" >>"${LOG}" 2>&1; then
    echo "REPLAY-FAILED" >>"${LOG}"
    return 9
  fi
  RC=0
  echo "--- schema ---" >>"${LOG}"
  python3 "${SCHEMA_CHECK}" "${SCHEMA}" "${OUT}/summary.json" >>"${LOG}" 2>&1 || RC=1
  echo "--- content ---" >>"${LOG}"
  python3 "${SHAPE_CHECK}" "${FX}" "${OUT}/summary.json" >>"${LOG}" 2>&1 || RC=$((RC + 2))
  return ${RC}
}

# ── 1) the real reporter, over every recorded fixture ────────────────────────
echo
echo "-- 1) the real reporter emits a report that validates and adds up --"
for FX in ${FIXTURE_FILES}; do
  NAME="$(basename "${FX}" .json)"
  LOG="${SCRATCH}/${NAME}.log"
  replay_and_check "${FX}" "${SCRATCH}/out-${NAME}" "${REPORTER}" "${LOG}"
  RC=$?
  if [ "${RC}" -eq 0 ]; then
    ok "${NAME}: summary.json matches the schema and the run it came from"
    sed 's/^/         /' "${LOG}" | grep -E 'PASS|n/a' || true
  else
    bad "${NAME}: rc=${RC} (1=schema 2=content 3=both 9=replay crashed)"
    sed 's/^/         /' "${LOG}"
  fi
done

# ── 2) the pieces the tree needs are actually THERE ──────────────────────────
# The checks above compare the report against the run. This one asserts the
# report is worth rendering at all: a summary that agrees with a run in which
# nothing was skipped, attached or pivoted would pass check 1 and be useless.
echo
echo "-- 2) the emitted report can actually drive a feature tree --"
SUM="${SCRATCH}/out-recorded-run/summary.json"
if [ ! -f "${SUM}" ]; then
  bad "no summary.json from the recorded fixture — check 1 never produced one"
else
  SUMMARY_PATH="${SUM}" python3 - <<'PY'
import json, os, sys
s = json.load(open(os.environ["SUMMARY_PATH"], encoding="utf-8"))
fails = []
if len(s.get("perSpec") or []) < 2:
    fails.append("perSpec has fewer than 2 spec files")
if not s.get("tests"):
    fails.append("tests[] is empty")
if not any(t.get("attachments") for t in s.get("tests") or []):
    fails.append("not one test carries an attachment — a failure with no screenshot "
                 "path is a row nobody can investigate")
if not any(t["status"] == "skipped" and t["skipReasonKnown"] for t in s.get("tests") or []):
    fails.append("no skipped test carries the suite's own reason")
if not any(t["status"] == "skipped" and not t["skipReasonKnown"] for t in s.get("tests") or []):
    fails.append("no skipped test is marked unexplained — the recorded run has 3")
for t in s.get("tests") or []:
    if t["status"] == "skipped" and not str(t.get("skipReason") or "").strip():
        fails.append(f"skipped test with a blank reason: {t['title'][:50]!r}")
files = {t["specFile"] for t in s.get("tests") or []}
pivot = {p["file"] for p in s.get("perSpec") or []}
if files != pivot:
    fails.append(f"tests[] and perSpec disagree about the file set: {files ^ pivot}")
for f in fails:
    print(f"  FAIL {f}")
sys.exit(1 if fails else 0)
PY
  if [ $? -eq 0 ]; then
    ok "per-spec pivot, per-test rows, attachments, explained AND unexplained skips are all present"
  else
    bad "the emitted report is missing something a tree must render (above)"
  fi
fi

# ── 3) negative controls: break the reporter, prove the checks bite ──────────
echo
echo "-- 3) negative controls: every mutation must make this guard go RED --"
SURVIVORS=""
CONTROLS=0
for M in $(python3 "${MUTATE}" --list); do
  CONTROLS=$((CONTROLS + 1))
  CTRL="${SCRATCH}/ctrl-${M}"
  mkdir -p "${CTRL}/reporters" "${CTRL}/specs"
  cp "${REPORTER}" "${CTRL}/reporters/hugmesh-reporter.ts"
  cp "${E2E}/specs/report-tags.ts" "${CTRL}/specs/report-tags.ts"
  DECL="$(python3 "${MUTATE}" --apply "${M}" "${CTRL}/reporters/hugmesh-reporter.ts" 2>"${SCRATCH}/mut-${M}.err")"
  if [ $? -ne 0 ]; then
    bad "CONTROL ${M}: could not be applied — it is not controlling anything:"
    sed 's/^/         /' "${SCRATCH}/mut-${M}.err"
    continue
  fi
  # The house rule: prove production actually changed before believing the RED.
  if cmp -s "${REPORTER}" "${CTRL}/reporters/hugmesh-reporter.ts"; then
    bad "CONTROL ${M}: the mutated copy is IDENTICAL to the original"
    continue
  fi
  WANT="$(printf '%s' "${DECL}" | cut -f1)"
  WHAT="$(printf '%s' "${DECL}" | cut -f2)"
  CAUGHT=""
  for FX in ${FIXTURE_FILES}; do
    NAME="$(basename "${FX}" .json)"
    replay_and_check "${FX}" "${CTRL}/out-${NAME}" \
      "${CTRL}/reporters/hugmesh-reporter.ts" "${CTRL}/${NAME}.log"
    RC=$?
    case "${RC}" in
      0) ;;
      9) CAUGHT="${CAUGHT} crash(${NAME})" ;;
      1) CAUGHT="${CAUGHT} schema(${NAME})" ;;
      2) CAUGHT="${CAUGHT} check(${NAME})" ;;
      3) CAUGHT="${CAUGHT} schema(${NAME}) check(${NAME})" ;;
      *) CAUGHT="${CAUGHT} unexpected-rc-${RC}(${NAME})" ;;
    esac
  done
  if [ -z "${CAUGHT}" ]; then
    bad "CONTROL ${M} SURVIVED — ${WHAT}"
    SURVIVORS="${SURVIVORS} ${M}"
  elif ! printf '%s' "${CAUGHT}" | grep -F "${WANT}" >/dev/null 2>&1; then
    # Caught, but not by the half that claims to own it. Still red, and still a
    # finding: the declared division of labour is wrong.
    bad "CONTROL ${M}: caught by${CAUGHT}, but declares caught_by=${WANT}"
  else
    ok "CONTROL ${M}: red via${CAUGHT} — ${WHAT}"
  fi
done
if [ "${CONTROLS}" -lt 8 ]; then
  bad "only ${CONTROLS} negative control(s) exist — the battery has been gutted"
else
  ok "${CONTROLS} negative controls applied, each verified to have changed the file"
fi
[ -z "${SURVIVORS// /}" ] || echo "  SURVIVING MUTATIONS:${SURVIVORS}"

# ── 3b) the controls must anchor on CODE, not on a comment ───────────────────
# COMMENT-TOKEN INVERSION, which has bitten this repo repeatedly: an anchor that
# matches only a COMMENT still rewrites the file, so `cmp -s` above is satisfied,
# the control reports as applied, and the reporter it claims to have broken is
# byte-for-byte intact. e2e_reporter_mutate.py refuses such an anchor; this runs
# that refusal both ways so the refusal is not itself unexercised.
echo
echo "-- 3b) every control anchors on code, and a comment-only anchor is refused --"
if python3 "${MUTATE}" --selftest "${REPORTER}"; then
  ok "the mutator tells a comment from code: comment lines are refused as anchors, all shipped anchors are code"
else
  bad "the mutator's comment scanner is wrong (above) - a control could rewrite a comment and report as applied"
fi

# ── 4) the schema checker itself must be able to fail ────────────────────────
# jsonschema_min.py is hand-rolled. A validator that accepts everything would
# make check 1 vacuous without changing a line of the reporter.
echo
echo "-- 4) the schema checker is itself proven able to reject --"
BAD_DOC="${SCRATCH}/bad-summary.json"
python3 - "${SUM}" "${BAD_DOC}" <<'PY'
import json, sys
s = json.load(open(sys.argv[1], encoding="utf-8"))
s.pop("perSpec", None)                     # a required key
s["tests"][0]["status"] = "nearly"         # outside the enum
s["passed"] = -1                           # below minimum
s["surpriseKey"] = True                    # additionalProperties is false
json.dump(s, open(sys.argv[2], "w", encoding="utf-8"), indent=1)
PY
if [ -f "${BAD_DOC}" ]; then
  OUTPUT="$(python3 "${SCHEMA_CHECK}" "${SCHEMA}" "${BAD_DOC}" 2>&1)"
  RC=$?
  N="$(printf '%s\n' "${OUTPUT}" | grep -c . )"
  if [ "${RC}" -eq 0 ]; then
    bad "the schema checker ACCEPTED a document missing a required key, with a "
    bad "  status outside the enum, a negative count and an unknown key"
  elif [ "${N}" -lt 4 ]; then
    bad "the schema checker reported only ${N} problem(s) in a document with 4"
    printf '         %s\n' "${OUTPUT}"
  else
    ok "the schema checker rejects a missing key, a bad enum, a negative count and an unknown key"
  fi
else
  bad "could not synthesise the invalid document"
fi

echo
echo "== e2e reporter shape: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
