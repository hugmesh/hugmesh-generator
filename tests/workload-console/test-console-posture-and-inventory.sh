#!/usr/bin/env bash
# test-console-posture-and-inventory.sh — guards the two answers to the operator ask
# "how do I view stats on the running services, and which versions are running":
#
#   (A) scripts/workload-console-posture.sh — a FOUR-gate predicate. It must report LIT
#       only when ALL FOUR gates are open, must report DARK naming EVERY gate that is
#       not, and must never treat an UNMEASURED runtime gate as open.
#   (B) specs/cluster/contracts/fleet-inventory.v1.json — the aggregate running-version
#       contract, together with the two measured premises it rests on: that the spec
#       image string carries NO version information on this tree, and that the shipped
#       workload-console read Role already grants every read the contract needs.
#
# WHY (A) IS TESTED THE WAY IT IS. A four-gate predicate has one interesting failure and
# it is not "returns the wrong answer": it is "returns DARK for every input", which is
# indistinguishable from correct on a repo whose console ships dark, and which passes
# any test that only ever feeds it the shipped tree. So the FIRST assertion here is a
# POSITIVE control (all four open => LIT). Every other case is a MUTATION of a real
# production file or a real runtime input away from that lit state, and each mutation
# asserts the file actually changed before asserting the verdict flipped — a mutation
# that silently failed to apply would otherwise "prove" the guard catches it.
#
# The mutation that matters most is the THREE-SHUT case. A guard that reports the first
# problem it finds tells an operator who has just selected the slug that they are one
# step from stats when they are three, which is exactly the confusion the ask describes.
#
# Offline: bash + python3 + awk. No cluster, no kubectl, no network, no build.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
TOOL="${REPO}/scripts/workload-console-posture.sh"
SRC="${REPO}/specs/cluster"
CONTRACT="${REPO}/specs/cluster/contracts/fleet-inventory.v1.json"
READ_ROLE="${REPO}/specs/cluster/manifests/workload-console-rbac/read-role.yaml"
DOC="${REPO}/docs/WORKLOAD-CONSOLE-STATS-AND-VERSIONS.md"
# WHERE THE GATE LIVES IS NOT THIS SUITE'S BUSINESS TO HARDCODE. Main hoisted the
# prune helpers and the per-slug case bodies out of the two stage4 builders into
# scripts/_optional-services-lib.sh, which both builders source, and shipped ONE
# resolver for every suite that needs them. It reproduces bash's own resolution
# order (each sourced scripts/*-lib.sh, then the builder itself LAST), so a
# builder-local override is what gets loaded — which is the whole point: the
# per-builder parity check below still compares what each builder would REALLY
# run. Use it rather than awk-ing a path; three x86 defects shipped from the two
# builders' copies drifting, and that is what this resolver exists to catch.
source "${REPO}/tests/lib/opt-gate-source.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# A guard that skips is a guard that never guards.
for t in python3 awk; do
  command -v "$t" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip)" >&2; exit 1; }
done
for f in "${TOOL}" "${CONTRACT}" "${READ_ROLE}" "${DOC}"; do
  [ -r "${f}" ] || { echo "FATAL: cannot read ${f}" >&2; exit 1; }
done
[ -d "${SRC}" ] || { echo "FATAL: cannot read ${SRC}" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== workload console: four-gate posture + fleet-inventory contract =="

# ── helpers ────────────────────────────────────────────────────────────────────
# String containment WITHOUT grep: `| grep -q` under pipefail turns a FOUND match into a
# FAILED pipeline via SIGPIPE, which has already bitten this repo.
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac }

# Edit a file with python, never `sed -i`. busybox sed is BRE-only and its -i is not
# GNU's; the mutations below carry braces and quotes, and a sed pattern that quietly
# stopped matching on the CI image would turn every case that follows into a silent
# pass. `changed()` would catch that — but only after the run wasted its point.
edit() {  # $1 = file ; $2 = literal to find ; $3 = replacement ('' deletes the line)
  python3 - "$1" "$2" "$3" <<'PYEDIT'
import sys
path, find, repl = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").readlines()
out = []
for l in lines:
    if find in l:
        if repl == "":
            continue
        l = l.replace(find, repl)
    out.append(l)
open(path, "w", encoding="utf-8").writelines(out)
PYEDIT
}

sandbox() {  # $1 = destination name -> echoes the tree path
  local dest="${WORK}/$1"
  rm -rf "${dest}"; mkdir -p "${dest}"
  cp -a "${SRC}/." "${dest}/"
  printf '%s' "${dest}"
}

# Run the tool with gates 3+4 supplied as OPEN unless overridden, so a case can isolate
# exactly one gate. Always returns the report text; the exit code is checked separately.
posture() {  # $1 = tree ; rest = extra args
  local tree="$1"; shift
  bash "${TOOL}" --tree="${tree}" --db-admin-enabled=true --active-grants=1 "$@" 2>&1
}

# Assert a mutation actually landed. A mutation that did not change the file proves
# nothing about the guard, and a `sed -i` whose pattern stopped matching is silent.
changed() {  # $1 = label ; $2 = before-hash ; $3 = file (may now be absent)
  local after=""
  [ -e "$3" ] && after="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$3")"
  if [ "$2" = "${after}" ]; then bad "$1: MUTATION DID NOT CHANGE THE FILE — the case below proves nothing"; return 1; fi
  return 0
}
hash_of() { [ -e "$1" ] && python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1" || printf ''; }

# Assert a report's verdict and that a given gate is named in the DARK-BECAUSE line.
expect_dark_naming() {  # $1 = label ; $2 = report ; rest = gate tokens that MUST appear
  local lbl="$1" rep="$2"; shift 2
  if ! has "WORKLOAD_CONSOLE_POSTURE=DARK" "${rep}"; then
    bad "${lbl}: expected DARK, got: $(printf '%s' "${rep}" | awk '/WORKLOAD_CONSOLE_POSTURE=/{print}')"
    return
  fi
  local because g missing=""
  because="$(printf '%s\n' "${rep}" | awk '/^DARK BECAUSE/{print}')"
  for g in "$@"; do has "${g}" "${because}" || missing="${missing} ${g}"; done
  if [ -n "${missing}" ]; then
    bad "${lbl}: DARK, but the reason line does not name:${missing}  (line was: ${because})"
  else
    local named=""
    for g in "$@"; do named="${named} ${g}"; done
    ok "${lbl}: DARK, and the reason names${named}"
  fi
}

# ── 1. POSITIVE CONTROL — without this, a constant-DARK tool passes everything ──
LIT_TREE="$(sandbox lit)"
REP="$(posture "${LIT_TREE}")"
if has "WORKLOAD_CONSOLE_POSTURE=LIT" "${REP}"; then
  ok "positive control: an all-four-open tree reports LIT (the tool is not constant-DARK)"
else
  bad "positive control FAILED: an all-four-open tree did not report LIT — every DARK case below is now vacuous. Report:
${REP}"
fi

# ── 2. The SHIPPED default: runtime gates unmeasured => DARK, and NOT open ──────
REP="$(bash "${TOOL}" --tree="${SRC}" 2>&1)"
expect_dark_naming "shipped tree with gates 3+4 unmeasured" "${REP}" "gate-3" "gate-4"
if has "UNKNOWN" "${REP}"; then
  ok "an unmeasured runtime gate reports UNKNOWN, never OPEN (an unproven gate is not an open one)"
else
  bad "unmeasured runtime gates did not report UNKNOWN"
fi

# --help must print the WHOLE header, not a hardcoded line range. The header carries
# the caveats (UNKNOWN is never OPEN; envFrom and cluster drift are not measured) and it
# has already grown twice; a `sed -n '1,NNp'` would now stop mid-sentence and the
# operator would read a tool that claims more than it measures. Measured on the LAST
# header line, so any growth that outruns the range is caught.
HELP="$(bash "${TOOL}" --help 2>&1)"
if has "Exit codes: 0 posture determined and printed" "${HELP}" \
   && has "STILL NOT MEASURED" "${HELP}" \
   && has "UNKNOWN IS NEVER TREATED AS OPEN" "${HELP}"; then
  ok "--help prints the header through its LAST line, caveats included (no truncating line range)"
else
  bad "--help is truncated — it stops before the caveats or the exit codes: ${HELP}"
fi
if has "set -uo pipefail" "${HELP}"; then
  bad "--help spilled past the header into the script body"
else
  ok "--help stops where the comments stop"
fi

# ── 3. MUTATION BATTERY on real production files ───────────────────────────────
# M1 — the deployment overlay is gone (what deselecting the slug actually does).
T="$(sandbox m1)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"; rm -f "${OV}"
if changed "M1 overlay removed" "${H}" "${OV}"; then
  expect_dark_naming "M1 overlay file removed" "$(posture "${T}")" "gate-1" "gate-2"
fi

# M2 — the overlay is present but the generator gate env is false.
T="$(sandbox m2)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
edit "${OV}" 'name: WORKLOAD_CONSOLE_ENABLED,     value: "true"' 'name: WORKLOAD_CONSOLE_ENABLED,     value: "false"'
if changed "M2 WORKLOAD_CONSOLE_ENABLED=false" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M2 WORKLOAD_CONSOLE_ENABLED=false" "${REP}" "gate-1"
  # and gate 2 must NOT be dragged down with it — the two gates are independent, and a
  # tool that collapses them cannot tell an operator which one to open.
  if has "gate-2" "$(printf '%s\n' "${REP}" | awk '/^DARK BECAUSE/{print}')"; then
    bad "M2: flipping ONLY the generator gate also reported the k8s seam shut — the gates are not independent in the report"
  else
    ok "M2: the k8s seam stays OPEN when only the generator gate is flipped (gates reported independently)"
  fi
fi

# M3 — the kustomization no longer applies the overlay (the file survives, unused).
T="$(sandbox m3)"; K="${T}/manifests/admin-bff-api/kustomization.yaml"
H="$(hash_of "${K}")"
edit "${K}" 'workload-console-patch.yaml' ''
if changed "M3 kustomization line dropped" "${H}" "${K}"; then
  expect_dark_naming "M3 overlay present but never applied by the kustomization" "$(posture "${T}")" "gate-1"
fi

# M4 — the route-access rows are dropped by the REAL builder helper (not a re-implementation).
T="$(sandbox m4)"; SQL="${T}/manifests/route-access/initdb/20-schema.sql"
H="$(hash_of "${SQL}")"
# Load _opt_drop_rows as build-rpi5-stage4.sh itself resolves it (today: from the
# shared library it sources). opt_gate_load fails loudly rather than leaving the
# case below to run against an undefined name.
opt_gate_load "${REPO}/build-rpi5-stage4.sh" _opt_drop_rows \
  || bad "could not load _opt_drop_rows from build-rpi5-stage4.sh's source chain"
_opt_drop_rows "${SQL}" hugmesh-be-gateway '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
if changed "M4 route rows dropped" "${H}" "${SQL}"; then
  expect_dark_naming "M4 route-access rows dropped by the builder's own _opt_drop_rows" "$(posture "${T}")" "gate-1"
  # THE TRAP CONTROL. 20-schema.sql discusses both console patterns in PROSE, and the
  # builder removes only the INSERT tuples. A check that grepped for the pattern would
  # be green on this very tree. Assert the surviving prose did not rescue the gate.
  BODY="$(cat "${SQL}")"
  if has "/bff/admin/workloads/**" "${BODY}"; then
    ok "M4 trap control: the pattern still appears in ${SQL##*/} as a COMMENT, and the gate is still reported SHUT (a grep-based check would be green here)"
  else
    bad "M4 trap control is vacuous: no commented mention of the pattern survived the prune, so this case no longer proves comments are stripped"
  fi
fi

# M4b — COMMENT-TOKEN INVERSION, PLANTED rather than hoped for. gate_optional_services
# removes the INSERT tuples and leaves prose behind, and M4 above proves the surviving
# PROSE does not rescue the gate. But prose is the easy case: it never looks like a row.
# This case appends a commented-out copy of the exact TUPLE SYNTAX the parser matches on,
# in both the flush-left and the indented spelling, on a tree whose real rows are gone.
# A parser that stopped stripping comments — or that leaned only on its `^\(` anchor
# — would count these as seeded rows and report gate 1 OPEN on a tree that seeds
# NOTHING. Comment-token inversion has bitten this repo repeatedly; it is planted here so
# the stripping is load-bearing and a mutation that removes it goes RED.
T="$(sandbox m4b)"; SQL="${T}/manifests/route-access/initdb/20-schema.sql"
_opt_drop_rows "${SQL}" hugmesh-be-gateway '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
H="$(hash_of "${SQL}")"
cat >> "${SQL}" <<'SQLPLANT'
-- ('hugmesh-be-gateway',  '/bff/admin/workloads/**',      'ROLE_ADMIN',      true),
  -- ('hugmesh-be-gateway',  '/bff/superadmin/workloads/**', 'ROLE_SUPERADMIN', true),
SQLPLANT
if changed "M4b commented-out tuples planted" "${H}" "${SQL}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M4b a commented-out INSERT TUPLE must not rescue gate 1" "${REP}" "gate-1"
  if has "route-access row for /bff/admin/workloads/** is not seeded" "${REP}" \
     && has "route-access row for /bff/superadmin/workloads/** is not seeded" "${REP}"; then
    ok "M4b: neither commented tuple is counted as a seeded row — the tuple scan is unanchored, so stripping is what rejects them"
  else
    bad "M4b: gate 1 is shut but not for the missing rows — comment-token inversion may be back: ${REP}"
  fi
fi

# M4c — THE BLOCK-COMMENT FORM. `--` and `/* … */` are separate legs of the strip and
# fail separately, so both are planted. MEASURED before this leg existed — with
# the two real rows pruned and a block-commented copy appended, the parser counted both
# as seeded and the whole tool printed LIT on a tree that seeds NOTHING.
# The plant also proves the strip does not use `re.sub(r"/\*.*?\*/")`: the route patterns
# CONTAIN `/**`, so that regex opens a block comment inside a quoted pattern and eats
# every real row — a tree with a block comment ANYWHERE would then read as fully pruned.
T="$(sandbox m4c)"; SQL="${T}/manifests/route-access/initdb/20-schema.sql"
_opt_drop_rows "${SQL}" hugmesh-be-gateway '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
H="$(hash_of "${SQL}")"
cat >> "${SQL}" <<'SQLPLANT'
/* superseded by the workloadConsole slug, kept for history:
('hugmesh-be-gateway',  '/bff/admin/workloads/**',      'ROLE_ADMIN',      true),
('hugmesh-be-gateway',  '/bff/superadmin/workloads/**', 'ROLE_SUPERADMIN', true),
*/
SQLPLANT
if changed "M4c block-commented tuples planted" "${H}" "${SQL}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M4c a /* block-commented */ INSERT TUPLE must not rescue gate 1" "${REP}" "gate-1"
  if has "route-access row for /bff/admin/workloads/** is not seeded" "${REP}" \
     && has "route-access row for /bff/superadmin/workloads/** is not seeded" "${REP}"; then
    ok "M4c: a block-commented tuple at column 0 is not counted as a seeded row — comment stripping is the only thing that can reject this one"
  else
    bad "M4c: COMMENT-TOKEN INVERSION — a /* */ block made the tool report seeded rows that do not exist: ${REP}"
  fi
fi

# M4d — the OVER-STRIP control for M4c. A block-comment stripper written as a regex
# would swallow the real rows because the patterns contain `/**`; this case adds a block
# comment that touches nothing and asserts the gate stays OPEN. Without it, "strip
# everything" would pass M4b and M4c and quietly report every tree as pruned.
T="$(sandbox m4d)"; SQL="${T}/manifests/route-access/initdb/20-schema.sql"
H="$(hash_of "${SQL}")"
cat >> "${SQL}" <<'SQLPLANT2'
/* an ordinary block comment that seeds nothing */
SQLPLANT2
if changed "M4d harmless block comment appended" "${H}" "${SQL}"; then
  REP="$(posture "${T}")"
  has "WORKLOAD_CONSOLE_POSTURE=LIT" "${REP}" \
    && ok "M4d over-strip control: a harmless /* */ comment does NOT swallow the real rows (the strip is a quote-aware scanner, not a regex over patterns containing /**)" \
    || bad "M4d over-strip control FAILED: adding an inert block comment turned a lit tree dark — the comment strip is eating real rows: ${REP}"
fi

# M4e — THE FALSE-DARK CONTROL, and the case that keeps the comment strip load-bearing.
# The rows ship one tuple per line today, but the same INSERT can be written
# `VALUES ('a', …), ('b', …);` on ONE line. Those rows ARE seeded; a parser anchored to
# `^\(`, or one taking only the first tuple per line, calls them missing and reports a
# console DARK that actually works. Prune the real rows, re-seed them in the one-line
# spelling, and gate 1 must come back OPEN. With this case present, comment stripping is
# the ONLY thing standing between the parser and prose — which is what makes a mutation
# that removes the stripping go RED instead of being covered for free by the anchor.
T="$(sandbox m4e)"; SQL="${T}/manifests/route-access/initdb/20-schema.sql"
_opt_drop_rows "${SQL}" hugmesh-be-gateway '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
REP="$(posture "${T}")"
if has "WORKLOAD_CONSOLE_POSTURE=DARK" "${REP}"; then
  ok "M4e setup: with the rows pruned the tree is DARK (so the re-seed below is what flips it back, not the tree)"
else
  bad "M4e setup failed: the pruned tree is not DARK, so the re-seed proves nothing"
fi
H="$(hash_of "${SQL}")"
cat >> "${SQL}" <<'SQLPLANT3'
INSERT INTO route_access (service, pattern, role, mfa_required) VALUES ('hugmesh-be-gateway', '/bff/superadmin/workloads/**', 'ROLE_SUPERADMIN', true), ('hugmesh-be-gateway', '/bff/admin/workloads/**', 'ROLE_ADMIN', true);
SQLPLANT3
if changed "M4e rows re-seeded in the one-line VALUES spelling" "${H}" "${SQL}"; then
  REP="$(posture "${T}")"
  has "WORKLOAD_CONSOLE_POSTURE=LIT" "${REP}" \
    && ok "M4e: rows written as one-line VALUES (...), (...); are recognised as SEEDED — no false DARK from a line-anchored or first-match-only parser" \
    || bad "M4e FALSE DARK: the rows are seeded but the tool reports them missing — the tuple parser is anchored to the file's current formatting: ${REP}"
fi

# M5 — the k8s seam env is false (generator gate untouched).
T="$(sandbox m5)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
edit "${OV}" 'name: WORKLOAD_CONSOLE_K8S_ENABLED, value: "true"' 'name: WORKLOAD_CONSOLE_K8S_ENABLED, value: "false"'
if changed "M5 WORKLOAD_CONSOLE_K8S_ENABLED=false" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M5 k8s seam disabled (NoopWorkloadClient 503s)" "${REP}" "gate-2"
  if has "gate-1" "$(printf '%s\n' "${REP}" | awk '/^DARK BECAUSE/{print}')"; then
    bad "M5: flipping ONLY the k8s seam also reported the generator gate shut"
  else
    ok "M5: the generator gate stays OPEN when only the k8s seam is flipped"
  fi
fi

# M6 — the read half of the k8s seam, taken apart ONE PIECE AT A TIME.
# A REVIEW FINDING lives here. The first version of this suite had a single M6 that
# deleted every line containing "/var/run/secrets/workload-console-read" — which is
# BOTH the WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE env value AND the volumeMount line —
# and the tool passed it while measuring only the env. The full token path is a FILE and
# a mountPath is its PARENT DIRECTORY, so the only line in the overlay carrying the full
# string is the env var: `path in text` could never have seen the mount. Deleting both
# volumeMounts, or the entire `volumes:` block, left the old tool reporting LIT.
# The pieces are therefore mutated SEPARATELY, and each must go SHUT on its own.

# M6a — the env var that NAMES the read token file (mount left intact).
T="$(sandbox m6a)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
edit "${OV}" 'name: WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE,   value: "/var/run/secrets/workload-console-read/token"' ''
if changed "M6a read token-file env removed" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M6a WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE unset (mount still present)" "${REP}" "gate-2"
  has "WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE does not name the contract path" "${REP}" \
    && ok "M6a: the reason blames the ENV VAR specifically, not the mount" \
    || bad "M6a: gate 2 is shut but the reason does not identify the env var: ${REP}"
fi

# M6b — the MOUNTS, and ONLY the mounts. The env vars stay, spelling the contract
# paths exactly as the shipped file does. This is the case the reviewer proved did not
# exist: on the old tool it stayed green and printed LIT on a console that 503s.
T="$(sandbox m6b)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
python3 - "${OV}" <<'PYM6B'
import sys
p = sys.argv[1]
out = []
for l in open(p, encoding="utf-8"):
    if l.lstrip().startswith("#"):
        out.append(l); continue
    if "mountPath: /var/run/secrets/workload-console-" in l:
        continue          # the volumeMounts entries, and nothing else
    out.append(l)
open(p, "w", encoding="utf-8").write("".join(out))
PYM6B
if changed "M6b both volumeMounts removed" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  # The premise of the case: the env vars naming the token paths MUST still be there,
  # or this is just M6a again and proves nothing about the mount.
  if has 'WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE,   value: "/var/run/secrets/workload-console-read/token"' "$(cat "${OV}")"; then
    ok "M6b premise: the token-file env vars survive the mutation, so ONLY the mount is missing"
  else
    bad "M6b premise broken: the env var went with the mount, so this case cannot isolate the mount"
  fi
  expect_dark_naming "M6b volumeMounts deleted, env intact (the reviewer's mutation)" "${REP}" "gate-2"
  has "NO volumeMount delivers /var/run/secrets/workload-console-read/token" "${REP}" \
    && ok "M6b: the reason blames the MOUNT — a mountPath is the token's PARENT DIRECTORY, so a substring test for the full path can only ever see the env var" \
    || bad "M6b: gate 2 shut but no mount-specific reason was printed: ${REP}"
fi

# M6c — the pod `volumes:` block. The mounts still name their volumes; nothing
# declares them. kubelet rejects the pod, and on the old tool this too reported LIT.
T="$(sandbox m6c)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
python3 - "${OV}" <<'PYM6C'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
marker = "\n      volumes:"
assert marker in t, "the overlay no longer has a volumes: block — re-read this case"
open(p, "w", encoding="utf-8").write(t[:t.index(marker)] + "\n")
PYM6C
if changed "M6c volumes: block removed" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M6c volumes: block deleted, volumeMounts intact" "${REP}" "gate-2"
  has "declares no such volume" "${REP}" \
    && ok "M6c: the reason blames the missing pod volume, separately from the mount and the env" \
    || bad "M6c: gate 2 shut but no volume-specific reason was printed: ${REP}"
fi

# M6d — the volume exists but is backed by a Secret token-secrets.yaml does not mint.
# optional:true means this mounts EMPTY and the pod starts perfectly happily.
T="$(sandbox m6d)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
edit "${OV}" 'secretName: workload-console-read-token' 'secretName: workload-console-read-token-WRONG'
if changed "M6d read volume points at an unminted Secret" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M6d volume mounts a Secret nothing mints (optional:true => mounts EMPTY)" "${REP}" "gate-2"
  has "does not mint" "${REP}" \
    && ok "M6d: the Secret name is cross-checked against what token-secrets.yaml actually mints" \
    || bad "M6d: gate 2 shut but the unminted Secret is not named: ${REP}"
fi

# M6e — the volume EXISTS, is named correctly, and delivers no token: it is an
# emptyDir instead of a secret volume. The mount is satisfied, the pod starts, the
# directory is there and the token file inside it is not — the same silent
# 503-per-call degradation as an unminted Secret, reached a different way. Asserted on
# the SPECIFIC reason, because a check that merely noticed "this is not the Secret we
# expect" would blame the wrong thing and send the operator to token-secrets.yaml,
# which is fine.
T="$(sandbox m6e)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
python3 - "${OV}" <<'PYM6E'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
old = """        - name: workload-console-read-token
          secret:
            secretName: workload-console-read-token
            optional: true
"""
assert old in t, "the read token volume's spelling moved — re-read this case"
new = """        - name: workload-console-read-token
          emptyDir: {}
"""
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PYM6E
if changed "M6e read volume turned into an emptyDir" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M6e the token volume is not a secret volume at all" "${REP}" "gate-2"
  has "is not a secret volume" "${REP}" \
    && ok "M6e: the reason says the VOLUME delivers no token — not 'the Secret is unminted', which would send the operator to the wrong file" \
    || bad "M6e: gate 2 shut but the reason misidentifies an emptyDir volume: ${REP}"
fi

# M7 — the RBAC Application is gone, so the token Secrets are never created.
T="$(sandbox m7)"; A="${T}/apps/14-workload-console-rbac.yaml"
H="$(hash_of "${A}")"; rm -f "${A}"
if changed "M7 RBAC Application removed" "${H}" "${A}"; then
  expect_dark_naming "M7 RBAC Application absent (no ServiceAccounts, no token Secrets)" "$(posture "${T}")" "gate-2"
fi

# M8 — the token Secrets manifest is gone (volumes are optional:true, so they mount EMPTY
# and the pod starts perfectly happily — the failure is silent without this check).
T="$(sandbox m8)"; S="${T}/manifests/workload-console-rbac/token-secrets.yaml"
H="$(hash_of "${S}")"; rm -f "${S}"
if changed "M8 token-secrets.yaml removed" "${H}" "${S}"; then
  expect_dark_naming "M8 token Secrets never minted (optional:true volumes mount empty, silently)" "$(posture "${T}")" "gate-2"
fi

# M9 — A DUPLICATE env ENTRY, appended LAST. The kubelet takes the last value; the
# old tool's line scanner returned the FIRST and was blind to this. The console is off
# and nothing in the file looks wrong. (tests/scripts/test-no-duplicate-env.sh catches a
# duplicate in THIS repo — but it never runs against an operator's rendered device
# tree, which is the only tree this tool is ever pointed at.)
T="$(sandbox m9)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
python3 - "${OV}" <<'PYM9'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
anchor = '            - { name: APP_WORKLOADCONSOLE_PORTFORWARDALLOWLIST_2_PORT,      value: "8080" }\n'
assert anchor in t, "the append anchor moved — re-read this case before trusting it"
t = t.replace(anchor, anchor
              + '            - { name: WORKLOAD_CONSOLE_ENABLED,     value: "false" }\n'
              + '            - { name: WORKLOAD_CONSOLE_K8S_ENABLED, value: "false" }\n')
open(p, "w", encoding="utf-8").write(t)
PYM9
if changed "M9 duplicate env entries appended (false wins)" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M9 a later duplicate turns both build-time gates off" "${REP}" "gate-1" "gate-2"
  has "is declared 2 times in the same container env list" "${REP}" \
    && ok "M9: the duplicate is reported as its own reason (last-wins is kubelet semantics, not a tie-break the tool invented)" \
    || bad "M9: the gates are shut but the duplicate itself is never named: ${REP}"
  has 'name: WORKLOAD_CONSOLE_ENABLED,     value: "true"' "$(cat "${OV}")" \
    && ok "M9 premise: the original value=true entry is untouched — a first-match scanner reads this tree as LIT" \
    || bad "M9 premise broken: the original true entry is gone, so this is not a duplicate case"
  # LAST-WINS, asserted on the reported VALUE and not merely on the verdict. Reporting a
  # duplicate as shut is right either way, so the verdict alone cannot tell first-match
  # from last-match; the effective value can, and it is what an operator acts on.
  has "effective value 'false'" "${REP}" \
    && ok "M9: the EFFECTIVE value reported is the LAST entry's ('false'), which is what the kubelet gives the container" \
    || bad "M9: the report does not name 'false' as the effective value — the tool is resolving the duplicate the wrong way round: ${REP}"
fi

# M9b — THE DUPLICATE THAT RESOLVES *OPEN*, which is why the duplicate is a reason of
# its own and not merely a way of computing the value. Here both duplicates say "true":
# the kubelet's effective env is identical to the shipped tree's, so a tool that only
# ever compared the effective VALUE would report LIT and never mention that the file
# says the same thing twice. It is reported SHUT deliberately — the reviewer's own
# suggested fix ("report a duplicate as its own SHUT reason") — because a container env
# list with two entries for one gate is a tree whose posture depends on line ORDER, and
# an operator editing the entry they can see may be editing the dead one. Without this
# case, deleting either gate's `if n > 1:` reason is invisible: M9 above flips the
# values to false, so both gates are shut for the VALUE anyway and the duplicate reason
# is never load-bearing there. Both gates are duplicated so neither reason is covered
# only by the other.
T="$(sandbox m9b)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
python3 - "${OV}" <<'PYM9B'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
anchor = '            - { name: APP_WORKLOADCONSOLE_PORTFORWARDALLOWLIST_2_PORT,      value: "8080" }\n'
assert anchor in t, "the append anchor moved — re-read this case before trusting it"
t = t.replace(anchor, anchor
              + '            - { name: WORKLOAD_CONSOLE_ENABLED,     value: "true" }\n'
              + '            - { name: WORKLOAD_CONSOLE_K8S_ENABLED, value: "true" }\n'
              # ... and the env that NAMES a token file, duplicated with the SAME
              # correct path, so the value check cannot be what fires for this one.
              + '            - { name: WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE,   value: "/var/run/secrets/workload-console-read/token" }\n')
open(p, "w", encoding="utf-8").write(t)
PYM9B
if changed "M9b duplicate env entries appended (both say true)" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M9b a duplicate whose effective value is still true" "${REP}" "gate-1" "gate-2"
  if has "WORKLOAD_CONSOLE_ENABLED is declared 2 times" "${REP}" \
     && has "WORKLOAD_CONSOLE_K8S_ENABLED is declared 2 times" "${REP}" \
     && has "WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE is declared 2 times" "${REP}"; then
    ok "M9b: all THREE duplicated variables name their own duplicate — no reason here is covered only by another"
  else
    bad "M9b: the tree is shut but one of the three duplicates is never named: ${REP}"
  fi
  has "effective value" "${REP}" \
    && bad "M9b: a duplicate that resolves to 'true' must not ALSO be reported as a wrong value — the reason would be false: ${REP}" \
    || ok "M9b: the duplicate is the ONLY reason given (the effective value really is true), so the operator is told the true defect"
fi

# M10 — the patch TARGETS NOTHING. One character in metadata.name and the strategic
# merge matches no resource. Measured here with kubectl kustomize: the build FAILS ("no
# resource matches strategic merge patch ... no matches for Id"), so ArgoCD cannot sync
# the admin-bff at all and not one WORKLOAD_CONSOLE_* var is ever rendered.
T="$(sandbox m10)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
python3 - "${OV}" <<'PYM10'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
old = "\n  name: hugmesh-admin-bff-api\n"
assert old in t, "the overlay's metadata.name spelling moved — re-read this case"
open(p, "w", encoding="utf-8").write(t.replace(old, "\n  name: hugmesh-admin-bff-api-TYPO\n", 1))
PYM10
if changed "M10 overlay metadata.name no longer matches the Deployment" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M10 strategic-merge patch targets no resource" "${REP}" "gate-1" "gate-2"
  has "matches NO resource" "${REP}" \
    && ok "M10: the mismatch itself is named, and BOTH build-time gates go shut (nothing renders, so neither can be open)" \
    || bad "M10: gates shut but the target mismatch is not named: ${REP}"
  # Do not take the failure mode on faith: if kustomize is on this box, prove it.
  if command -v kubectl >/dev/null 2>&1; then
    if ( cd "${T}/manifests/admin-bff-api" && kubectl kustomize . >/dev/null 2>&1 ); then
      bad "M10 external control: kubectl kustomize BUILT the mutated tree — the reason line's claim that the build fails is wrong and must be reworded"
    else
      ok "M10 external control: kubectl kustomize refuses the mutated tree, so 'the patch matches no resource' is measured, not asserted"
    fi
  else
    echo "  note: kubectl absent, M10's external kustomize control was not run (the tool-side assertion above still ran)"
  fi
fi

# M10b — the patch targets the right DEPLOYMENT but the WRONG CONTAINER. This one
# renders perfectly: `kustomize build` succeeds, ArgoCD syncs, and the operator sees a
# healthy admin-bff. MEASURED here, not assumed — a strategic merge on `containers` is
# keyed on `name`, so an unmatched name is not an error and not an override: kustomize
# ADDS A SECOND CONTAINER carrying every WORKLOAD_CONSOLE_* var, and the real
# hugmesh-admin-bff-api container is rendered with NONE of them. The console is dark
# and every text-level check in this file — the env is present, the mounts are present,
# the volumes are present — is satisfied by that render.
T="$(sandbox m10b)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
python3 - "${OV}" <<'PYM10B'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
old = "\n        - name: hugmesh-admin-bff-api\n          env:\n"
assert old in t, "the overlay's patched container name moved — re-read this case"
open(p, "w", encoding="utf-8").write(t.replace(old, "\n        - name: hugmesh-admin-bff-api-sidecar\n          env:\n", 1))
PYM10B
if changed "M10b overlay patches a container the Deployment does not have" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M10b patch lands on a container that is not the app" "${REP}" "gate-1" "gate-2"
  has "would ADD a second container" "${REP}" \
    && ok "M10b: the reason names the container mismatch — not the env, which is present and correct" \
    || bad "M10b: gates shut but the container mismatch is not named: ${REP}"
  # EXTERNAL CONTROL. The claim above is about kustomize's behaviour, so kustomize is
  # asked. Asserted on the RENDER, never on a build exit code.
  if command -v kubectl >/dev/null 2>&1; then
    RENDER="$( cd "${T}/manifests/admin-bff-api" && kubectl kustomize . 2>/dev/null )"
    VERDICT="$(printf '%s' "${RENDER}" | python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
for d in docs:
    if d.get("kind") == "Deployment" and d.get("metadata", {}).get("name") == "hugmesh-admin-bff-api":
        cs = d["spec"]["template"]["spec"]["containers"]
        app = [c for c in cs if c["name"] == "hugmesh-admin-bff-api"]
        if not app:
            print("NO-APP-CONTAINER"); break
        names = [e.get("name") for e in app[0].get("env", []) if isinstance(e, dict)]
        print("APP-HAS-GATE" if "WORKLOAD_CONSOLE_ENABLED" in names else "APP-HAS-NOTHING/%d-containers" % len(cs))
        break
else:
    print("NO-DEPLOYMENT")
' 2>/dev/null )"
    case "${VERDICT}" in
      APP-HAS-NOTHING/*)
        ok "M10b external control: kustomize RENDERS this tree happily (${VERDICT}) and the real app container gets NO WORKLOAD_CONSOLE_ENABLED — the console is dark on a cluster that looks healthy" ;;
      APP-HAS-GATE)
        bad "M10b external control: the app container DID get the gate env — the reason line's claim is wrong and must be reworded" ;;
      *)
        bad "M10b external control: could not read the render (${VERDICT:-empty})" ;;
    esac
  else
    echo "  note: kubectl absent, M10b's external kustomize control was not run (the tool-side assertion above still ran)"
  fi
fi

# M11 — the overlay is PRESENT but not parseable. Absent, present-and-broken, and
# present-and-wrong are three different states and an operator has to be told which one
# they are in: a YAML error is a build that will never render, not a slug that was
# deselected. A loader that swallowed the error and returned an empty document would
# still land on DARK — by accident, for the wrong stated reason — so the REASON is
# asserted here, not just the verdict.
T="$(sandbox m11)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
printf '%s\n' "this: is: not: valid: yaml" >> "${OV}"
if changed "M11 overlay corrupted" "${H}" "${OV}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M11 overlay present but unparseable" "${REP}" "gate-1" "gate-2"
  has "unparseable" "${REP}" \
    && ok "M11: a broken overlay is reported as UNPARSEABLE, distinct from absent (pruned) and from wrong-valued" \
    || bad "M11: the overlay is broken but the report does not say so — the reason an operator reads is wrong: ${REP}"
fi

# M12 — the PyYAML dependency must be LOUD, never a fallback. The mount, duplicate-env
# and patch-target checks are structural; a tool that quietly degraded to the old line
# scanner when PyYAML was missing would print exactly the LIT-on-a-dark-console verdict
# the review found, on the one machine where nobody would look. An operator's rendered
# device tree is where this runs, so the missing-dependency path is exercised here.
POISON="${WORK}/no-yaml"; mkdir -p "${POISON}"
printf 'raise ImportError("PyYAML deliberately unavailable for this case")\n' > "${POISON}/yaml.py"
REP="$(PYTHONPATH="${POISON}" bash "${TOOL}" --tree="${SRC}" --db-admin-enabled=true --active-grants=1 2>&1)"
RC=$?
if [ "${RC}" -eq 1 ] && has "PyYAML is required" "${REP}"; then
  ok "M12: with PyYAML absent the tool EXITS 1 and says so — it does not fall back to a line scanner"
else
  bad "M12: PyYAML absent gave rc=${RC} and: ${REP}"
fi
if has "WORKLOAD_CONSOLE_POSTURE=" "${REP}"; then
  bad "M12: the tool printed a POSTURE without the parser it needs — that verdict is a guess"
else
  ok "M12: no posture is printed at all when the parse cannot be done (an undeterminable posture is not DARK and not LIT)"
fi

# M13 — the kustomization builds NO Deployment for the overlay to patch. The overlay
# is present, correct and applied; there is simply nothing under it. `kustomize build`
# emits a Service, an HPA and a PDB pointing at a workload that does not exist, so
# there is no admin-bff pod at all, never mind a lit console. Without this case the
# tool's "nothing to patch" branch is dead code that could be deleted silently.
T="$(sandbox m13)"; KU="${T}/manifests/admin-bff-api/kustomization.yaml"
H="$(hash_of "${KU}")"
edit "${KU}" '  - deployment.yaml' ''
if changed "M13 deployment.yaml dropped from the kustomization resources" "${H}" "${KU}"; then
  REP="$(posture "${T}")"
  expect_dark_naming "M13 the kustomization builds no Deployment" "${REP}" "gate-1" "gate-2"
  has "builds no Deployment this overlay could patch" "${REP}" \
    && ok "M13: the reason says there is nothing to patch, rather than blaming the overlay that is in fact correct" \
    || bad "M13: gates shut but the missing Deployment is never named: ${REP}"
fi

# ── 4. THE THREE-SHUT CASE — the failure the ask actually describes ─────────────
# An operator selects the slug (gates 1+2 open) and expects stats. Three gates are open
# in this tree and the two runtime gates are shut; the report must name BOTH, not one.
T="$(sandbox three)"
REP="$(bash "${TOOL}" --tree="${T}" --db-admin-enabled=false --active-grants=0 2>&1)"
expect_dark_naming "slug selected, both runtime gates shut" "${REP}" "gate-3" "gate-4"
COUNT_LINE="$(printf '%s\n' "${REP}" | awk '/^DARK BECAUSE/{print}')"
if has "2 of 4 gates" "${COUNT_LINE}"; then
  ok "the report COUNTS the shut gates (2 of 4), so 'I enabled it' cannot read as 'one step left'"
else
  bad "the report does not count the shut gates: ${COUNT_LINE}"
fi

# And the worst case: only gate 1 survives. All three others must be named.
T="$(sandbox one)"; OV="${T}/manifests/admin-bff-api/workload-console-patch.yaml"
H="$(hash_of "${OV}")"
edit "${OV}" 'name: WORKLOAD_CONSOLE_K8S_ENABLED, value: "true"' 'name: WORKLOAD_CONSOLE_K8S_ENABLED, value: "false"'
if changed "three-of-four-shut setup" "${H}" "${OV}"; then
  REP="$(bash "${TOOL}" --tree="${T}" --db-admin-enabled=false --active-grants=0 2>&1)"
  expect_dark_naming "only the generator gate open" "${REP}" "gate-2" "gate-3" "gate-4"
  COUNT_LINE="$(printf '%s\n' "${REP}" | awk '/^DARK BECAUSE/{print}')"
  has "3 of 4 gates" "${COUNT_LINE}" \
    && ok "three shut gates are reported as 3 of 4 — the guard does NOT go green when three of four are shut" \
    || bad "three shut gates were not counted as 3 of 4: ${COUNT_LINE}"
fi

# ── 5. Runtime-gate semantics, each direction ─────────────────────────────────
T="$(sandbox rt)"
REP="$(bash "${TOOL}" --tree="${T}" --db-admin-enabled=false --active-grants=1 2>&1)"
expect_dark_naming "DB master flag false alone" "${REP}" "gate-3"
REP="$(bash "${TOOL}" --tree="${T}" --db-admin-enabled=true --active-grants=0 2>&1)"
expect_dark_naming "no active grant alone" "${REP}" "gate-4"
REP="$(bash "${TOOL}" --tree="${T}" --db-admin-enabled=true --active-grants=1 2>&1)"
has "WORKLOAD_CONSOLE_POSTURE=LIT" "${REP}" \
  && ok "both runtime gates measured open + a lit tree => LIT" \
  || bad "both runtime gates open on a lit tree did not report LIT"
# --require-lit is a documented scripting contract: exit 3 on DARK, 0 on LIT.
bash "${TOOL}" --tree="${T}" --db-admin-enabled=false --active-grants=0 --require-lit >/dev/null 2>&1
[ "$?" -eq 3 ] && ok "--require-lit exits 3 on DARK" || bad "--require-lit did not exit 3 on DARK"
bash "${TOOL}" --tree="${T}" --db-admin-enabled=true --active-grants=1 --require-lit >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "--require-lit exits 0 on LIT" || bad "--require-lit did not exit 0 on LIT"

# ── 6. END TO END: the REAL builder gate, executed, then measured ─────────────
# Not a re-implementation of the prune — the builder's own case body against a sandbox.
# WHERE THESE COME FROM MOVED, and the loop below is UNCHANGED because of it.
# Both extractors now follow the builder's SOURCE CHAIN (each scripts/*-lib.sh it
# sources, then the builder itself last) instead of awk-ing the builder file, so
# they keep working now that the prune lives in scripts/_optional-services-lib.sh.
# Semantics are identical for a builder that defines a function locally: last
# definition wins, exactly as bash resolves it. That is what preserves the check
# this loop exists for — iterating BOTH builders still asks whether each one, as
# it would really run, prunes the console. If one grows a local override, the
# override is what loads here and this loop goes red for that builder alone.
extract_fn_of()   { opt_gate_extract_fn "$1" "$2"; }   # $1 = builder, $2 = function name
extract_case_of() { opt_gate_case_body  "$1" "$2"; }   # $1 = builder, $2 = case label
for B in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
  BUILDER="${REPO}/${B}"
  [ -r "${BUILDER}" ] || { bad "builder ${B} unreadable"; continue; }
  T="$(sandbox "gate-${B}")"
  BODY="$(extract_case_of "${BUILDER}" workloadConsole)"
  if [ -z "${BODY}" ]; then bad "${B}: could not extract the workloadConsole case body"; continue; fi
  (
    set -uo pipefail
    OPTIONAL_SERVICES=""          # the DEFAULT: slug deselected
    tree="${T}"; apps="${T}/apps"
    info() { :; }; warn() { :; }
    eval "$(extract_fn_of "${BUILDER}" _opt_selected)"
    eval "$(extract_fn_of "${BUILDER}" _opt_drop_kustomize_line)"
    eval "$(extract_fn_of "${BUILDER}" _opt_drop_rows)"
    eval "$(extract_fn_of "${BUILDER}" _opt_drop_route)"
    _opt_selected workloadConsole && exit 0
    eval "${BODY}"
  ) || bad "${B}: the extracted gate body failed to run"
  # gates 3+4 handed OPEN so ONLY the builder's effect can decide the verdict here.
  expect_dark_naming "${B}: default (deselected) build renders a tree that is still dark" \
    "$(posture "${T}")" "gate-1" "gate-2"
done

# ── 7. FLEET INVENTORY CONTRACT ───────────────────────────────────────────────
CONTRACT_OUT="$(python3 - "${CONTRACT}" <<'PY'
import json, sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
P = F = 0
def ok(m):
    global P; print("  PASS " + m); P += 1
def bad(m):
    global F; print("  FAIL " + m); F += 1

if c["properties"]["contract"].get("const") == "fleet-inventory/v1":
    ok("contract is versioned (fleet-inventory/v1) so a consumer can refuse an unknown shape")
else:
    bad("contract const is not fleet-inventory/v1")

cv = c["$defs"]["containerVersion"]
req = set(cv["required"])
# The whole point: a row may not omit the resolved digest or say where it came from.
for f in ("specImage", "resolvedDigest", "digestSource"):
    if f in req:
        ok("containerVersion REQUIRES %s" % f)
    else:
        bad("containerVersion does not require %s — a row could answer the version question with nothing" % f)

pat = cv["properties"]["resolvedDigest"].get("pattern", "")
if pat == "^sha256:[a-f0-9]{64}$":
    ok("resolvedDigest is pinned to a bare sha256:<64 hex> form (a repo@sha ref would carry the moving name back in)")
else:
    bad("resolvedDigest pattern is %r" % pat)

srcs = set(cv["properties"]["digestSource"]["enum"])
if srcs == {"pod-status", "spec-digest", "unavailable"}:
    ok("digestSource enumerates exactly pod-status / spec-digest / unavailable")
else:
    bad("digestSource enum drifted: %s" % sorted(srcs))

wr = c["$defs"]["workloadRow"]
for f in ("replicasDesired", "replicasReady", "versionKnown"):
    if f in set(wr["required"]):
        ok("workloadRow REQUIRES %s" % f)
    else:
        bad("workloadRow does not require %s" % f)
if "digestSkew" in wr["properties"]:
    ok("workloadRow carries digestSkew — the one bit no existing surface has")
else:
    bad("workloadRow has no digestSkew field")
# Metrics must be NULLABLE: a 0 on a cluster with no metrics-server reads as an idle fleet.
for f in ("cpuMillicores", "memoryBytes"):
    t = wr["properties"][f]["type"]
    if isinstance(t, list) and "null" in t:
        ok("%s is nullable (an absent metrics-server is null, never 0)" % f)
    else:
        bad("%s is not nullable — a metrics-less cluster would report an idle fleet" % f)
print("__SUB %d %d" % (P, F))
PY
)"
printf '%s\n' "${CONTRACT_OUT}" | awk '!/^__SUB /'
CSUB="$(printf '%s\n' "${CONTRACT_OUT}" | awk '/^__SUB /{print $2" "$3}')"
if [ -z "${CSUB}" ]; then
  bad "the fleet-inventory contract check did not run to completion"
else
  P=$((P + ${CSUB%% *})); F=$((F + ${CSUB##* }))
fi

# ── 8. THE MEASURED PREMISE: specImage carries no version on this tree ────────
# If this ever goes RED the contract's rationale must be re-read, not the test relaxed:
# a digest-pinned fleet would make specImage a real version and change the whole design.
MEAS="$(python3 - "${SRC}" <<'PY'
import glob, os, sys, re
root = sys.argv[1]
moving = pinned = 0
for f in sorted(glob.glob(os.path.join(root, "manifests", "*", "kustomization.yaml"))):
    txt = "\n".join(l for l in open(f, encoding="utf-8", errors="replace") if not l.lstrip().startswith("#"))
    # every `images:` entry naming the platform's own registry
    for m in re.finditer(r"newName:\s*(registry\.hugmesh\.net/\S+)", txt):
        seg = txt[m.start():m.start()+400]
        if re.search(r"digest:\s*sha256:", seg[:200]): pinned += 1
        else: moving += 1
print("%d %d" % (moving, pinned))
PY
)"
MOVING="${MEAS%% *}"; PINNED="${MEAS##* }"
if [ "${PINNED}" = "0" ] && [ "${MOVING}" -ge 20 ]; then
  ok "measured premise holds: ${MOVING} first-party image refs on this tree, ${PINNED} digest-pinned — the spec image string distinguishes no two builds, which is why resolvedDigest is required"
else
  bad "measured premise CHANGED: ${MOVING} moving-tag / ${PINNED} digest-pinned first-party refs. Re-read the fleet-inventory rationale before touching this assertion."
fi

# ── 9. RBAC COUPLING: the contract needs no new permission — assert, don't assume ─
rbac_check() {  # $1 = role file ; echoes OK or the missing verbs
  python3 - "$1" <<'PY'
import sys, yaml
need = [("", "pods", {"get", "list"}),
        ("apps", "deployments", {"get", "list"}),
        ("apps", "statefulsets", {"get", "list"}),
        ("apps", "daemonsets", {"get", "list"}),
        ("metrics.k8s.io", "pods", {"get", "list"})]
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
rules = doc.get("rules") or []
missing = []
for grp, res, verbs in need:
    got = set()
    for r in rules:
        if grp in (r.get("apiGroups") or []) and res in (r.get("resources") or []):
            got |= set(r.get("verbs") or [])
    if not verbs <= got:
        missing.append("%s/%s needs %s, has %s" % (grp or "core", res, sorted(verbs), sorted(got)))
print("OK" if not missing else "; ".join(missing))
PY
}
if command -v python3 >/dev/null && python3 -c "import yaml" 2>/dev/null; then
  R="$(rbac_check "${READ_ROLE}")"
  [ "${R}" = "OK" ] \
    && ok "the shipped read Role already grants every read fleet-inventory/v1 needs — the contract adds NO privilege" \
    || bad "the read Role no longer covers the fleet-inventory contract: ${R}"
  # MUTATION: trim pods out of the read Role and confirm the coupling check goes RED.
  MR="${WORK}/read-role-mutated.yaml"
  python3 - "${READ_ROLE}" "${MR}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for r in d["rules"]:
    if "" in (r.get("apiGroups") or []):
        r["resources"] = [x for x in r["resources"] if x != "pods"]
yaml.safe_dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PY
  if [ "$(hash_of "${MR}")" = "$(hash_of "${READ_ROLE}")" ]; then
    bad "RBAC mutation did not change the file — the coupling check below proves nothing"
  else
    R2="$(rbac_check "${MR}")"
    [ "${R2}" != "OK" ] \
      && ok "RBAC coupling mutation control: dropping core/pods from the read Role makes the check RED (${R2})" \
      || bad "RBAC coupling mutation control FAILED: the check stayed green with core/pods removed"
  fi
else
  echo "FATAL: python3 + PyYAML required for the RBAC coupling leg (refusing to skip)" >&2
  F=$((F+1))
fi

# ── 10. DOC COUPLING — the runbook must name every artefact it tells you to run ─
DOCTXT="$(cat "${DOC}")"
for needle in "scripts/workload-console-posture.sh" \
              "specs/cluster/contracts/fleet-inventory.v1.json" \
              "workload_console_config" "workload_console_grant" \
              "WORKLOAD_CONSOLE_K8S_ENABLED" "containerStatuses"; do
  has "${needle}" "${DOCTXT}" \
    && ok "runbook names ${needle}" \
    || bad "runbook does not name ${needle}"
done

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
