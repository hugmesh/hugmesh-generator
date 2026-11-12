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
#      `secrets.` is referenced, and no VM step sets `envs:` or overrides the action's
#      token. (The pinned actions still send GITHUB_* and CI to the guest over ssh
#      SendEnv whatever `envs:` says; no secret is among them.)
#   3. every `uses:` is pinned to a 40-hex commit SHA;
#   4. every checkout sets persist-credentials: false (the workspace is rsynced into
#      the guest, and a persisted token would travel in .git/config);
#   5. the matrix is exactly the seven guests, and each guest has exactly one VM step
#      whose pin, release and collect.sh argument agree with its matrix row;
#   6. the image digest is recorded on the runner and every guest's facts are
#      uploaded even when the VM step failed (if: always());
#   6a. every VM step sets disable-cache: 'true' (with the cache on, anyvm MOVES the
#      qcow2 into the cache dir and the digest step finds nothing) and data-dir:
#      $HOME/vm-data, the same directory the digest step hashes. The actions rsync
#      $HOME/work into the guest excluding only _actions and _PipelineMapping, so a
#      data-dir under runner.temp (<work>/_temp) or the workspace would copy the
#      guest's own boot image and ssh key into the guest;
#   6b. the summary job runs if: always(), lays the fixtures out under
#      out/tests/guest-facts/fixtures and uploads `out` as guest-host-facts, so the
#      artifact is a plain unzip at the repository root.
# It also pins the helpers the workflow runs:
#   7. collect.sh is POSIX sh (`sh -n`), never `set -e`, and every `exit` in it is
#      `exit 0` (no `${1:?}` aborts either), so a failed probe is data and the action
#      still copies the facts back; it builds the venv with --system-site-packages,
#      runs the stock --self-check before the first install line, searches the
#      urwid/PySide6/PyQt6 catalogs even when no Python 3.11+ appeared, and reads no
#      GUEST_FACTS_* knob (no VM step sets `envs:`, so only GITHUB_* and CI reach a
#      guest and such a knob could never be set). Its try_line/imports
#      pair is run with stubs: a line whose module does not import is recorded
#      imports=no, one whose module imports is recorded imports=yes;
#   7a. argv_session.py, run against a fake studio package, logs the argv of the
#      processes each step starts, under that step's name, with the checkout path
#      scrubbed;
#   8. size_contract.py `candidates` drops a test file that names a Qt binding, a Qt
#      module, the qtbot fixture or the GUI package and keeps one that does not;
#   9. runner_side.py `summarize` reports a guest with no fixtures as missing (never a
#      filled-in row), states the DragonFly OS-package result as FOUND or NOT FOUND,
#      checks PyQt6 (not PySide6) for DragonFly's GUI, says NOT TRIED (never NOT
#      FOUND) when no line was tried, and cuts contract-list.txt only from guests
#      whose sizing run finished; `image` refuses (rc 1) when no image file was found
#      to hash, even when it found anyvm.py, and records the sha256 of one it did find.
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

DATA_DIR = "$HOME/vm-data"
for s in vm_steps:
    w = s.get("with") or {}
    if str(w.get("disable-cache", "")).strip().lower() != "true":
        problems.append(f"cache: VM step {s.get('name')!r} does not set disable-cache: 'true'")
    dd = str(w.get("data-dir", ""))
    if dd != DATA_DIR:
        problems.append(f"data-dir: VM step {s.get('name')!r} data-dir is {dd!r}, want {DATA_DIR!r} (outside the synced work tree)")
if len(img) == 1 and f'--data-dir "{DATA_DIR}"' not in str(img[0].get("run", "")):
    problems.append(f"data-dir: the image digest step does not hash --data-dir \"{DATA_DIR}\"")

summary = (wf.get("jobs") or {}).get("summary") or {}
if str(summary.get("if", "")).strip() != "always()" or summary.get("needs") != "guest":
    problems.append("summary: the summary job must need guest and run if: always()")
sruns = " ".join(str(st.get("run", "")) for st in summary.get("steps") or [])
if "root=out/tests/guest-facts/fixtures" not in sruns or 'runner_side.py summarize --root "$root"' not in sruns:
    problems.append("summary: fixtures are not laid out under out/tests/guest-facts/fixtures and summarized there")
sup = [st for st in summary.get("steps") or [] if str(st.get("uses", "")).startswith("actions/upload-artifact@")]
if len(sup) != 1 or (sup[0].get("with") or {}).get("path") != "out" or (sup[0].get("with") or {}).get("name") != "guest-host-facts":
    problems.append("summary: the summary must upload `out` once as guest-host-facts")

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
  mutate no-datadir  "data-dir:"    "text.replace('          data-dir: \$HOME/vm-data\n', '', 1)"
  mutate temp-data   "data-dir:"    "text.replace('          data-dir: \$HOME/vm-data\n', '          data-dir: \${{ runner.temp }}/vm-data\n', 1)"
  mutate img-data    "data-dir:"    "text.replace('--data-dir \"\$HOME/vm-data\"', '--data-dir \"\$RUNNER_TEMP/vm-data\"', 1)"
  mutate cache-on    "cache:"       "text.replace(\"          disable-cache: 'true'\n\", '', 1)"
  mutate sum-always  "summary:"     "text.replace('    needs: guest\n    if: always()\n', '    needs: guest\n', 1)"
  mutate sum-root    "summary:"     "text.replace('root=out/tests/guest-facts/fixtures', 'root=out/fixtures', 1)"
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
  # Static rules on the code with comments stripped (a comment may say "exits 0").
  python3 - "${C}" > "${TMP}/collect-static.out" 2>&1 <<'PY'
import re
import sys

lines = []
for raw in open(sys.argv[1], encoding="utf-8").read().splitlines():
    code = re.sub(r"(^|\s)#.*$", "", raw)      # `${x##*y}` has no space before its #
    lines.append(code)
code = "\n".join(lines)
problems = []
exits = re.findall(r"(?<![\w-])exit\b[ \t]*([^\s;|&)}]*)", code)
if not exits or any(e != "0" for e in exits):
    problems.append(f"exit: every exit must be `exit 0`, found {['exit ' + e for e in exits]}")
if re.search(r"\$\{[A-Za-z0-9_]+:?\?", code):
    problems.append("exit: a ${VAR:?} expansion aborts the script with a non-zero status")
if not re.search(r'probe venv "\$py" -m venv --system-site-packages "\$venv"', code):
    problems.append("venv: the venv is not built with --system-site-packages (the design's install path)")
for comp in ("urwid", "pyside6", "pyqt6"):
    # the no-Python branch: the catalog is still searched, so NOT TRIED has evidence
    if not re.search(rf"^\s*search {comp} \"\$t_\w+\" > /dev/null$", code, re.M):
        problems.append(f"search: the {comp} catalog search does not run when no Python 3.11+ was found")
if re.search(r"GUEST_FACTS_", code):
    problems.append("knob: collect.sh reads a GUEST_FACTS_* variable, but no VM step sets envs: (only GITHUB_* and CI reach a guest)")
stock = [i for i, ln in enumerate(lines) if re.match(r"\s*probe selfcheck-stock .*--self-check", ln)]
first_install = [i for i, ln in enumerate(lines)
                 if re.match(r"\s*([\w|]+\)\s+)?install (python|urwid|pyside6|pyqt6) ", ln)]
if len(stock) != 1 or not first_install or stock[0] > first_install[0]:
    problems.append("self-check: the stock --self-check probe must run once, before the first install line")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
  if [ $? -eq 0 ]; then ok "collect.sh: every exit is exit 0, venv uses --system-site-packages, stock --self-check precedes the installs, catalogs searched without Python, no GUEST_FACTS_* knob"
  else while IFS= read -r line; do bad "collect.sh: ${line}"; done < "${TMP}/collect-static.out"; fi

  # Behaviour of try_line/imports, run with stubs (no package manager, no root):
  # the two functions are cut out of the real file, so a mutation there is seen here.
  B="${TMP}/tryline"; mkdir -p "${B}"
  awk '/^(imports|try_line)\(\) \{/{on=1} on{print} on&&/^}/{on=0}' "${C}" > "${B}/funcs.sh"
  printf '#!/bin/sh\n[ "$1" = -c ] && [ "$2" = "import goodmod" ]\n' > "${B}/py"; chmod +x "${B}/py"
  cat > "${B}/drive.sh" <<'SH'
out=$1 py=$1/py n_try=0
probe() { shift; "$@" > /dev/null 2>&1; }
as_root() { "$@"; }
. "$out/funcs.sh"
printf 'component\tkind\tinstall_rc\timports\tline\n' > "$out/install.tsv"
try_line urwid static badmod "true"; echo "bad=$?"
try_line urwid static goodmod "exit 3"; echo "good=$?"
SH
  if sh "${B}/drive.sh" "${B}" > "${B}/drive.out" 2>&1 \
     && grep -qx 'bad=1' "${B}/drive.out" && grep -qx 'good=0' "${B}/drive.out" \
     && [ "$(sed -n 2p "${B}/install.tsv")" = "$(printf 'urwid\tstatic\t0\tno\ttrue')" ] \
     && [ "$(sed -n 3p "${B}/install.tsv")" = "$(printf 'urwid\tstatic\t3\tyes\texit 3')" ]; then
    ok "try_line records imports=no for a module that does not import and imports=yes (with the line's rc) for one that does"
  else bad "try_line/imports: $(tr '\n' ' ' < "${B}/drive.out") | $(tr '\t\n' ', ' < "${B}/install.tsv" 2>/dev/null)"; fi
fi

# ── 7a: argv_session.py against a fake studio package ───────────────────────
echo "== argv_session.py =="
A="${TMP}/argv"; mkdir -p "${A}/repo/studio/hugmesh_studio"
: > "${A}/repo/studio/hugmesh_studio/__init__.py"
cat > "${A}/repo/studio/hugmesh_studio/tui.py" <<'PY'
import os, subprocess, sys
sys.stdin.read()
subprocess.run([sys.executable, "-c", "pass", "marker-tui", os.getcwd()], check=True)
PY
cat > "${A}/repo/studio/hugmesh_studio/__main__.py" <<'PY'
import os
os.system("true marker-print")
PY
if python3 "${GF}/argv_session.py" --repo "${A}/repo" --out "${A}/out" --timeout 60 > "${A}/run.out" 2>&1; then
  python3 - "${A}/out" > "${A}/check.out" 2>&1 <<'PY'
import json
import sys

out = sys.argv[1]
recs = [json.loads(ln) for ln in open(f"{out}/argv-log.jsonl", encoding="utf-8") if ln.strip()]
tui = [r for r in recs if r["step"] == "tui" and r["event"] == "subprocess.Popen" and "marker-tui" in r["argv"]]
prt = [r for r in recs if r["step"] == "print" and r["event"] == "os.system" and r["argv"] == ["true marker-print"]]
problems = []
if not tui or tui[0]["argv"][-1] != "<repo>/studio":
    problems.append(f"the tui step's child argv is not logged with <repo> scrubbed: {recs}")
if not prt:
    problems.append(f"the print step's os.system argv is not logged: {recs}")
if any(set(r) != {"step", "event", "argv"} for r in recs):
    problems.append("a log record carries more than step, event and argv")
steps = [ln.split("\t")[:2] for ln in open(f"{out}/steps.tsv", encoding="utf-8").read().splitlines()[1:]]
if steps != [["tui", "0"], ["print", "0"]]:
    problems.append(f"steps.tsv: {steps}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
  if [ $? -eq 0 ]; then ok "argv_session logs each step's child argv (subprocess and os.system) under its step, scrubbed, argv only"
  else while IFS= read -r line; do bad "argv_session: ${line}"; done < "${A}/check.out"; fi
else bad "argv_session failed: $(head -1 "${A}/run.out")"; fi

# ── 8: contract candidates ───────────────────────────────────────────────────
echo "== size_contract.py candidates =="
mkdir -p "${TMP}/cand/studio/tests"
printf 'import io\n\ndef test_plain():\n    assert io\n' > "${TMP}/cand/studio/tests/test_plain_cli.py"
printf 'import PySide6\n' > "${TMP}/cand/studio/tests/test_qt_pyside.py"
printf 'from PyQt6 import sip\n' > "${TMP}/cand/studio/tests/test_qt_pyqt.py"
printf 'app = QApplication([])\n' > "${TMP}/cand/studio/tests/test_qt_app.py"
printf 'from hugmesh_studio.gui.pages import role\n' > "${TMP}/cand/studio/tests/test_gui_role.py"
printf 'from hugmesh_studio import config, gui\n' > "${TMP}/cand/studio/tests/test_gui_import.py"
printf 'def test_w(qtbot):\n    pass\n' > "${TMP}/cand/studio/tests/test_qt_qtbot.py"
printf 'from PySide6 import QtWidgets\n' > "${TMP}/cand/studio/tests/test_qt_widgets.py"
printf 'from ..gui import main_window\n' > "${TMP}/cand/studio/tests/test_gui_relative.py"
printf 'x = 1\n' > "${TMP}/cand/studio/tests/helper_not_a_test.py"
if python3 "${GF}/size_contract.py" candidates --repo "${TMP}/cand" > "${TMP}/cand.out" 2>&1; then
  if [ "$(cat "${TMP}/cand.out")" = "tests/test_plain_cli.py" ]; then
    ok "candidates keeps the Qt-free test file and drops PySide6, PyQt6, QApplication, qtbot, gui-package and non-test files"
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
# DragonFly's GUI binding is PyQt6 (design section 3): a working PySide6 must not count.
printf 'pyside6\tstatic\t0\tyes\tpkg install -y py311-pyside6\n' >> "${R}/dragonfly/install.tsv"
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
# A DragonFly guest where no Python 3.11+ appeared, so no urwid/PyQt6 line was tried:
# the summary must say NOT TRIED, never NOT FOUND (nothing was measured).
R2="${TMP}/sum-untried"; mkdir -p "${R2}/dragonfly"
printf '$ uname -r\n6.4-RELEASE\nrc=0\n' > "${R2}/dragonfly/uname-r.txt"
{
  printf 'component\tkind\tinstall_rc\timports\tline\n'
  printf 'python\tstatic\t1\tno\tpkg install -y python311\n'
  printf 'python\tstatic\t1\tno\tpkg install -y python312\n'
} > "${R2}/dragonfly/install.tsv"
# The urwid catalog search was recorded and the PyQt6 one was not: each is cited as it is.
printf '$ pkg search -q urwid\npy39-urwid-2.1.2\nrc=0\n' > "${R2}/dragonfly/search-urwid.txt"
if python3 "${GF}/runner_side.py" summarize --root "${R2}" > "${TMP}/sum2.out" 2>&1; then
  if grep -q '^DragonFly .*urwid from the OS packages: NOT TRIED (no Python 3.11+ after 2 python line(s); catalog search rc 0, first line: py39-urwid-2.1.2, in search-urwid.txt).*PyQt6 from the OS packages: NOT TRIED (no Python 3.11+ after 2 python line(s); catalog search not recorded)' "${R2}/SUMMARY.md" \
     && ! grep -q 'NOT FOUND' "${R2}/SUMMARY.md"; then
    ok "the DragonFly line says NOT TRIED (not NOT FOUND) when no Python 3.11+ let a line be tried, citing only the searches recorded"
  else bad "DragonFly untried line: $(grep '^DragonFly' "${R2}/SUMMARY.md")"; fi
else bad "summarize (untried) failed: $(head -1 "${TMP}/sum2.out")"; fi

mkdir -p "${TMP}/empty-data"
if python3 "${GF}/runner_side.py" image --out "${TMP}/img" --action vmactions/x@y --release 1 \
     --data-dir "${TMP}/empty-data" --actions-dir "${TMP}/none" > "${TMP}/img.out" 2>&1; then
  bad "image exited 0 with no image file to hash"
elif grep -q "no image file" "${TMP}/img.out"; then ok "image refuses (rc 1) when there is no image file to hash"
else bad "image failed for another reason: $(head -1 "${TMP}/img.out")"; fi
# anyvm.py alone (the action is there, the image is not) is still no image.
mkdir -p "${TMP}/acts/vmactions/x/y/anyvm"
head -c 2097152 /dev/zero > "${TMP}/acts/vmactions/x/y/anyvm/anyvm.py"
if python3 "${GF}/runner_side.py" image --out "${TMP}/img2" --action vmactions/x@y --release 1 \
     --data-dir "${TMP}/empty-data" --actions-dir "${TMP}/acts" > "${TMP}/img2.out" 2>&1; then
  bad "image exited 0 having found only anyvm.py"
else ok "image refuses (rc 1) when it found anyvm.py but no image"; fi
# A real image file is hashed on the runner and recorded.
mkdir -p "${TMP}/data/v1"
head -c 1048576 /dev/zero > "${TMP}/data/v1/guest.qcow2"; printf 'x' >> "${TMP}/data/v1/guest.qcow2"
want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${TMP}/data/v1/guest.qcow2")
if python3 "${GF}/runner_side.py" image --out "${TMP}/img3" --action vmactions/x@y --release 1 \
     --data-dir "${TMP}/data" --actions-dir "${TMP}/acts" > "${TMP}/img3.out" 2>&1 \
   && grep -q "^image	v1/guest.qcow2	1048577	${want}\$" "${TMP}/img3/image.tsv"; then
  ok "image records the sha256 of the image it found"
else bad "image did not record the image digest: $(head -1 "${TMP}/img3.out") $(tr '\t\n' ', ' < "${TMP}/img3/image.tsv" 2>/dev/null)"; fi

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
