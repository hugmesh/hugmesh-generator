#!/usr/bin/env bash
# test-guest-host-facts.sh — pins the guest host-facts experiment (hugmesh-generator#1048,
# lane X0 of the platform expansion, docs/design/PLATFORM-EXPANSION.md sections 3, 4, 8).
#
# WHAT IS PINNED. .github/workflows/guest-host-facts.yml boots seven third-party BSD and
# SunOS guest images on hosted runners. The design's supply-chain rules for that are
# only true while this file keeps them true:
#   1. it runs ONLY on workflow_dispatch (no push, pull_request, schedule or
#      workflow_call), and no release workflow names it;
#   2. the token is read-only (top-level contents: read; no job widens it), no
#      `secrets.` is referenced, and no VM step forwards env into a guest (`envs:`)
#      or overrides the action's token;
#   3. every `uses:` is pinned to a 40-hex commit SHA;
#   4. every checkout sets persist-credentials: false (the workspace is rsynced into
#      the guest, and a persisted token would travel in .git/config);
#   5. the matrix is exactly the seven guests, and each guest has exactly one VM step
#      whose pin, release and collect.sh argument agree with its matrix row;
#   6. the image digest is recorded on the runner and every guest's facts are
#      uploaded even when the VM step failed (if: always()).
# It also pins the helpers the workflow runs:
#   7. collect.sh is POSIX sh (`sh -n`), never `set -e`, and always ends `exit 0`, so
#      a failed probe is data and the action still copies the facts back;
#   8. size_contract.py `candidates` drops a test file that names a Qt binding or the
#      GUI package and keeps one that does not;
#   9. runner_side.py `summarize` reports a guest with no fixtures as missing (never a
#      filled-in row), states the DragonFly OS-package result as FOUND or NOT FOUND,
#      and cuts contract-list.txt only from guests whose sizing run finished;
#      `image` refuses (rc 1) when no image file was found to hash.
#  10. FIXTURES: once tests/guest-facts/fixtures/ exists (committed from a dispatched
#      run), every one of the seven guests has an image.tsv with a 64-hex image
#      sha256, an install.tsv and uname output, and SUMMARY.md has a row per guest and
#      the DragonFly line. Until then this section prints PENDING, by design: the
#      fixtures can only come from a dispatch, and a dispatch needs the file on main.
#
# NEGATIVE CONTROLS. Checks 1-6 are run against mutated copies of the real workflow;
# each mutation must be refused with the expected reason, so a check that rots into
# a no-op fails here.
#
# Offline: bash, python3 + PyYAML, sh. No network, no runner, no guest.
#
#   bash tests/scripts/test-guest-host-facts.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${REPO}/.github/workflows/guest-host-facts.yml"
GF="${REPO}/tests/guest-facts"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pass=0; fail=0
ok(){ echo "  PASS $*"; pass=$((pass+1)); }
bad(){ echo "  FAIL $*"; fail=$((fail+1)); }

python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: python3 with PyYAML is required"; exit 1; }

cat > "${TMP}/check_wf.py" <<'PY'
"""Print one line per violated rule of the guest host-facts workflow; exit 1 if any."""
import re
import sys

import yaml

GUESTS = ["freebsd", "openbsd", "netbsd", "dragonfly", "solaris", "omnios", "openindiana"]
VM = {"freebsd": "vmactions/freebsd-vm", "openbsd": "vmactions/openbsd-vm",
      "netbsd": "vmactions/netbsd-vm", "dragonfly": "vmactions/dragonflybsd-vm",
      "solaris": "vmactions/solaris-vm", "omnios": "vmactions/omnios-vm",
      "openindiana": "vmactions/openindiana-vm"}
PIN = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
problems = []
try:
    wf = yaml.safe_load(text)
except yaml.YAMLError as exc:
    print(f"yaml: {exc}")
    sys.exit(1)

on = wf.get("on", wf.get(True))          # PyYAML reads a bare `on:` key as True
triggers = sorted(on) if isinstance(on, dict) else sorted([on] if isinstance(on, str) else (on or []))
if triggers != ["workflow_dispatch"]:
    problems.append(f"trigger: expected only workflow_dispatch, got {triggers}")

if wf.get("permissions") != {"contents": "read"}:
    problems.append(f"permissions: top level must be exactly contents: read, got {wf.get('permissions')!r}")
for jname, job in (wf.get("jobs") or {}).items():
    perms = job.get("permissions")
    if perms is not None and perms != {"contents": "read"} and perms != {}:
        problems.append(f"permissions: job {jname} widens the token: {perms!r}")

if re.search(r"\bsecrets\.", text) or "secrets[" in text:
    problems.append("secrets: the workflow references a secret")

steps_all = []
for jname, job in (wf.get("jobs") or {}).items():
    for step in job.get("steps") or []:
        steps_all.append((jname, step))
        uses = step.get("uses")
        if uses is None:
            continue
        if not PIN.match(uses):
            problems.append(f"pin: `{uses}` is not pinned to a 40-hex commit SHA")
        w = step.get("with") or {}
        if uses.split("@")[0].startswith("actions/checkout") and w.get("persist-credentials") is not False:
            problems.append(f"checkout: job {jname} does not set persist-credentials: false")
        if uses.startswith("vmactions/"):
            if "envs" in w:
                problems.append(f"envs: VM step {step.get('name')!r} forwards env into the guest")
            if "token" in w:
                problems.append(f"token: VM step {step.get('name')!r} overrides the action token")

guest_job = (wf.get("jobs") or {}).get("guest") or {}
rows = ((guest_job.get("strategy") or {}).get("matrix") or {}).get("include") or []
by_guest = {r.get("guest"): r for r in rows}
if sorted(by_guest) != sorted(GUESTS) or len(rows) != len(GUESTS):
    problems.append(f"matrix: expected exactly {GUESTS}, got {[r.get('guest') for r in rows]}")
vm_steps = [s for s in guest_job.get("steps") or [] if str(s.get("uses", "")).startswith("vmactions/")]
for g in GUESTS:
    row = by_guest.get(g) or {}
    mine = [s for s in vm_steps if re.fullmatch(rf"matrix\.guest\s*==\s*'{g}'", str(s.get("if", "")).strip())]
    if len(mine) != 1:
        problems.append(f"vm-step: guest {g} has {len(mine)} VM steps gated on matrix.guest == '{g}', want 1")
        continue
    s, w = mine[0], mine[0].get("with") or {}
    if s["uses"].split("@")[0] != VM[g]:
        problems.append(f"vm-step: guest {g} boots {s['uses']}, want {VM[g]}")
    if s["uses"] != row.get("action"):
        problems.append(f"vm-step: guest {g} pins {s['uses']} but its matrix row records {row.get('action')}")
    if str(w.get("release")) != str(row.get("release")) or not row.get("release"):
        problems.append(f"vm-step: guest {g} release {w.get('release')!r} != matrix release {row.get('release')!r}")
    if f"collect.sh {g} guest-facts-out/{g}" not in str(w.get("run", "")):
        problems.append(f"vm-step: guest {g} does not run collect.sh {g} guest-facts-out/{g}")
if len(vm_steps) != len(GUESTS):
    problems.append(f"vm-step: {len(vm_steps)} VM steps, want {len(GUESTS)}")

steps = guest_job.get("steps") or []
img = [s for s in steps if "runner_side.py image" in str(s.get("run", ""))]
if len(img) != 1 or str(img[0].get("if", "")).strip() != "always()":
    problems.append("digest: the image digest step must exist once and run if: always()")
up = [s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
if len(up) != 1 or str(up[0].get("if", "")).strip() != "always()":
    problems.append("upload: the per-guest upload must exist once and run if: always()")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY

# ── 1-6: the real workflow ───────────────────────────────────────────────────
echo "== workflow rules =="
if [ ! -f "${WF}" ]; then
  bad "missing ${WF#"${REPO}"/}"
else
  if python3 "${TMP}/check_wf.py" "${WF}" > "${TMP}/real.out" 2>&1; then
    ok "guest-host-facts.yml: dispatch only, read-only token, no secrets, SHA pins, no persisted credentials, seven guests agree with their VM steps, digest+upload always run"
  else
    while IFS= read -r line; do bad "guest-host-facts.yml: ${line}"; done < "${TMP}/real.out"
  fi
  # A reusable-workflow call (`uses: ./.github/workflows/guest-host-facts.yml`) is the
  # only way another workflow could run it; shell-suites naming THIS suite is not one.
  others=$(grep -l 'guest-host-facts\.yml' "${REPO}"/.github/workflows/*.yml 2>/dev/null | grep -v '/guest-host-facts\.yml$' || true)
  if [ -z "${others}" ]; then ok "no other workflow (release workflows included) calls guest-host-facts.yml"
  else bad "another workflow names guest-host-facts.yml: ${others#"${REPO}"/}"; fi
fi

# ── negative controls: each rule must refuse its own mutation ────────────────
echo "== negative controls (mutated copies of the real workflow) =="
# mutate NAME EXPECTED-PREFIX PYTHON-EXPRESSION-ON-text. The expression is one of the
# fixed literals below (a text.replace on the real file), never input from outside.
mutate() {
  local name=$1 expect=$2 expr=$3
  python3 - "${WF}" "${TMP}/m-${name}.yml" "${expr}" <<'PY'
import sys
src, dst, expr = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
new = eval(expr, {"text": text})
if new == text:
    sys.exit(f"mutation did not change the file: {expr}")
open(dst, "w", encoding="utf-8").write(new)
PY
  if [ $? -ne 0 ]; then bad "control ${name}: the mutation did not apply"; return; fi
  if python3 "${TMP}/check_wf.py" "${TMP}/m-${name}.yml" > "${TMP}/m-${name}.out" 2>&1; then
    bad "control ${name}: the mutated workflow PASSED"
  elif grep -q "^${expect}" "${TMP}/m-${name}.out"; then
    ok "control ${name}: refused (${expect})"
  else
    bad "control ${name}: refused for the wrong reason: $(head -1 "${TMP}/m-${name}.out")"
  fi
}
if [ -f "${WF}" ]; then
  mutate pr-trigger  "trigger:"     "text.replace('on:\n  workflow_dispatch:\n', 'on:\n  workflow_dispatch:\n  pull_request:\n', 1)"
  mutate call        "trigger:"     "text.replace('on:\n  workflow_dispatch:\n', 'on:\n  workflow_call:\n', 1)"
  mutate write-perm  "permissions:" "text.replace('permissions:\n  contents: read\n', 'permissions:\n  contents: write\n', 1)"
  mutate job-perm    "permissions:" "text.replace('    runs-on: ubuntu-latest\n    timeout-minutes: 150\n', '    runs-on: ubuntu-latest\n    permissions:\n      contents: write\n    timeout-minutes: 150\n', 1)"
  mutate secret      "secrets:"     "text.replace('ACTION: \${{ matrix.action }}', 'ACTION: \${{ secrets.X }}', 1)"
  mutate tag-pin     "pin:"         "text.replace('actions/checkout@11d5960a326750d5838078e36cf38b85af677262', 'actions/checkout@v4', 1)"
  mutate creds       "checkout:"    "text.replace('persist-credentials: false', 'persist-credentials: true', 1)"
  mutate envs        "envs:"        "text.replace(\"          release: '15.1'\n          sync: rsync\n\", \"          release: '15.1'\n          envs: 'GITHUB_TOKEN'\n          sync: rsync\n\", 1)"
  mutate token       "token:"       "text.replace(\"          release: '8.0'\n          sync: rsync\n\", \"          release: '8.0'\n          token: x\n          sync: rsync\n\", 1)"
  mutate drop-guest  "matrix:"      "text.replace(\"          - guest: dragonfly\n            release: '6.4.2'\n            action: vmactions/dragonflybsd-vm@4ab776fa9f914fbea72f13715b451e77e7ef5c41\n\", '', 1)"
  mutate pin-drift   "vm-step:"     "text.replace('uses: vmactions/netbsd-vm@5957cf330aef2e6ddc63c604364c99ce2e02b91d', 'uses: vmactions/netbsd-vm@0000000000000000000000000000000000000000', 1)"
  mutate rel-drift   "vm-step:"     "text.replace(\"          release: 'r151060'\n          sync\", \"          release: 'r151058'\n          sync\", 1)"
  mutate wrong-arg   "vm-step:"     "text.replace('collect.sh solaris guest-facts-out/solaris', 'collect.sh omnios guest-facts-out/solaris', 1)"
  mutate no-always   "digest:"      "text.replace('      - name: Record the guest image digest\n        if: always()\n', '      - name: Record the guest image digest\n', 1)"
  mutate up-always   "upload:"      "text.replace('      - name: Upload this guest\\'s facts\n        if: always()\n', '      - name: Upload this guest\\'s facts\n', 1)"
fi

# ── 7: collect.sh ────────────────────────────────────────────────────────────
echo "== collect.sh =="
C="${GF}/collect.sh"
if [ ! -f "${C}" ]; then bad "missing tests/guest-facts/collect.sh"; else
  [ "$(head -1 "${C}")" = "#!/bin/sh" ] && ok "collect.sh is a #!/bin/sh script" || bad "collect.sh shebang is not #!/bin/sh"
  # A strict POSIX parser when one exists: a bash-linked /bin/sh accepts arrays. The
  # alpine CI leg's sh IS busybox ash; tests/posix-sh-no-arrays.sh covers the rest.
  psh="sh"
  for cand in dash "busybox sh" posh; do
    if command -v "${cand%% *}" >/dev/null 2>&1; then psh="${cand}"; break; fi
  done
  if ${psh} -n "${C}" 2>"${TMP}/shn.err"; then ok "collect.sh parses under ${psh} -n"; else bad "collect.sh: ${psh} -n: $(head -1 "${TMP}/shn.err")"; fi
  if grep -Eq '^[[:space:]]*set[[:space:]]+-[a-z]*e' "${C}"; then bad "collect.sh uses set -e: one failed probe would abort the facts"; else ok "collect.sh never uses set -e"; fi
  [ "$(grep -v '^[[:space:]]*$' "${C}" | tail -1)" = "exit 0" ] && ok "collect.sh ends with exit 0" || bad "collect.sh does not end with exit 0"
fi

# ── 8: contract candidates ───────────────────────────────────────────────────
echo "== size_contract.py candidates =="
mkdir -p "${TMP}/cand/studio/tests"
printf 'import io\n\ndef test_plain():\n    assert io\n' > "${TMP}/cand/studio/tests/test_plain_cli.py"
printf 'import PySide6\n' > "${TMP}/cand/studio/tests/test_qt_pyside.py"
printf 'from PyQt6 import sip\n' > "${TMP}/cand/studio/tests/test_qt_pyqt.py"
printf 'app = QApplication([])\n' > "${TMP}/cand/studio/tests/test_qt_app.py"
printf 'from hugmesh_studio.gui.pages import role\n' > "${TMP}/cand/studio/tests/test_gui_role.py"
printf 'from hugmesh_studio import config, gui\n' > "${TMP}/cand/studio/tests/test_gui_import.py"
printf 'x = 1\n' > "${TMP}/cand/studio/tests/helper_not_a_test.py"
if python3 "${GF}/size_contract.py" candidates --repo "${TMP}/cand" > "${TMP}/cand.out" 2>&1; then
  if [ "$(cat "${TMP}/cand.out")" = "tests/test_plain_cli.py" ]; then
    ok "candidates keeps the Qt-free test file and drops PySide6, gui-package and non-test files"
  else bad "candidates listed: $(tr '\n' ' ' < "${TMP}/cand.out")"; fi
else bad "candidates failed: $(head -1 "${TMP}/cand.out")"; fi

# ── 9: runner_side.py ────────────────────────────────────────────────────────
echo "== runner_side.py =="
R="${TMP}/sum"
mk_guest() {   # mk_guest NAME URWID_OK PYQT_OK SIZING(finished|budget)
  local d="${R}/$1"; mkdir -p "${d}/session"
  printf '$ uname -s\nSynthOS\nrc=0\n' > "${d}/uname-s.txt"
  printf '$ uname -r\n9.9\nrc=0\n' > "${d}/uname-r.txt"
  printf '$ uname -p\namd64\nrc=0\n' > "${d}/uname-p.txt"
  printf '$ isainfo -k\nsh: isainfo: not found\nrc=127\n' > "${d}/isainfo-k.txt"
  printf '$ x\nrc=1\n' > "${d}/selfcheck-stock.txt"
  printf '$ x\nrc=0\n' > "${d}/selfcheck-installed.txt"
  printf 'step\trc\tseconds\targv\ntui\t0\t1.0\tx\nprint\t0\t1.0\tx\n' > "${d}/session/steps.tsv"
  printf 'kind\tpath\tbytes\tsha256\naction\tvmactions/x@y\t\t\nimage\tsynth.qcow2\t2\t%s\n' "$(printf 'a%.0s' $(seq 64))" > "${d}/image.tsv"
  {
    printf 'component\tkind\tinstall_rc\timports\tline\n'
    printf 'python\tstatic\t0\tyes\tpkg install -y python311\n'
    printf 'urwid\tstatic\t%s\t%s\tpkg install -y py311-urwid\n' "$([ "$2" = yes ] && echo 0 || echo 1)" "$2"
    [ "$2" = yes ] || printf 'urwid\tpip\t0\tyes\tVENV/bin/python -m pip install urwid\n'
    printf 'pyqt6\tstatic\t%s\t%s\tpkg install -y py311-qt6-pyqt\n' "$([ "$3" = yes ] && echo 0 || echo 1)" "$3"
  } > "${d}/install.tsv"
  {
    printf 'file\trc\tverdict\tpassed\tfailed\tskipped\terrors\tseconds\tsummary\n'
    # a budget-cut run never reached test_a: were it counted, test_a would leave the list
    if [ "$4" = budget ]; then printf 'tests/test_a.py\t\tnot-run\t0\t0\t0\t0\t0.0\tbudget\n'
    else printf 'tests/test_a.py\t0\tgreen\t1\t0\t0\t0\t1.0\t1 passed\n'; fi
    printf 'tests/test_b.py\t0\tgreen\t1\t0\t0\t0\t1.0\t1 passed\n'
    printf 'tests/test_c.py\t1\tred\t0\t1\t0\t0\t1.0\t1 failed\n'
  } > "${d}/contract-sizing.tsv"
}
mk_guest freebsd yes yes finished
mk_guest dragonfly no no finished
mk_guest openbsd yes yes budget
# netbsd finished but test_b is red there: it must leave the all-guest list
mk_guest netbsd yes no finished
{
  printf 'file\trc\tverdict\tpassed\tfailed\tskipped\terrors\tseconds\tsummary\n'
  printf 'tests/test_a.py\t0\tgreen\t1\t0\t0\t0\t1.0\t1 passed\n'
  printf 'tests/test_b.py\t1\tred\t0\t1\t0\t0\t1.0\t1 failed\n'
} > "${R}/netbsd/contract-sizing.tsv"
if python3 "${GF}/runner_side.py" summarize --root "${R}" > "${TMP}/sum.out" 2>&1; then
  S="${R}/SUMMARY.md"
  grep -q '^| solaris | (missing) |' "${S}" && ok "a guest with no fixtures is reported (missing)" || bad "solaris (no fixtures) is not reported as missing"
  grep -q '^| freebsd | SynthOS 9.9 |' "${S}" && ok "a guest row is read from its uname fixtures" || bad "freebsd row not read from its fixtures"
  grep -q "^| freebsd .*$(printf 'a%.0s' $(seq 64))" "${S}" && ok "the image sha256 is carried into the table" || bad "image sha256 missing from the freebsd row"
  grep -q '^DragonFly 9.9 .*urwid from the OS packages: NOT FOUND.*PyQt6 from the OS packages: NOT FOUND' "${S}" \
    && ok "the DragonFly line says NOT FOUND for OS packages even when pip supplied urwid" \
    || bad "DragonFly line wrong: $(grep '^DragonFly' "${S}")"
  grep -q '^| freebsd .* `pkg install -y py311-qt6-pyqt` (static) ' "${S}" && ok "the install line that worked is quoted per guest" || bad "freebsd PyQt6 install line not quoted"
  if [ "$(cat "${R}/contract-list.txt")" = "tests/test_a.py" ]; then
    ok "contract-list.txt = green on every FINISHED sizing run (budget-cut openbsd excluded, netbsd red drops test_b)"
  else bad "contract-list.txt: $(tr '\n' ' ' < "${R}/contract-list.txt")"; fi
else bad "summarize failed: $(head -1 "${TMP}/sum.out")"; fi
mkdir -p "${TMP}/empty-data"
if python3 "${GF}/runner_side.py" image --out "${TMP}/img" --action vmactions/x@y --release 1 \
     --data-dir "${TMP}/empty-data" --actions-dir "${TMP}/none" > "${TMP}/img.out" 2>&1; then
  bad "image exited 0 with no image file to hash"
elif grep -q "no image file" "${TMP}/img.out"; then ok "image refuses (rc 1) when there is no image file to hash"
else bad "image failed for another reason: $(head -1 "${TMP}/img.out")"; fi

# ── 10: committed fixtures ───────────────────────────────────────────────────
echo "== fixtures =="
FX="${GF}/fixtures"
if [ ! -d "${FX}" ]; then
  echo "  PENDING tests/guest-facts/fixtures/ is not committed yet: dispatch guest-host-facts.yml on main and commit its guest-host-facts artifact"
else
  for g in freebsd openbsd netbsd dragonfly solaris omnios openindiana; do
    d="${FX}/${g}"
    if awk -F'\t' '$1=="image" && $4 ~ /^[0-9a-f]{64}$/ {f=1} END {exit !f}' "${d}/image.tsv" 2>/dev/null \
       && [ -s "${d}/install.tsv" ] && [ -s "${d}/uname-a.txt" ]; then
      ok "fixtures/${g}: image sha256, install.tsv and uname recorded"
    else bad "fixtures/${g}: missing an image sha256, install.tsv or uname-a.txt"; fi
    grep -q "^| ${g} | " "${FX}/SUMMARY.md" 2>/dev/null && ! grep -q "^| ${g} | (missing)" "${FX}/SUMMARY.md" \
      && ok "SUMMARY.md has a measured row for ${g}" || bad "SUMMARY.md has no measured row for ${g}"
  done
  grep -Eq '^DragonFly .*(FOUND|NOT FOUND).*PyQt6' "${FX}/SUMMARY.md" 2>/dev/null \
    && ok "SUMMARY.md states DragonFly's package availability" || bad "SUMMARY.md lacks the DragonFly line"
fi

echo
echo "== guest host facts: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
