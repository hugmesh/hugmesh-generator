#!/usr/bin/env bash
# test-e2e-docker-base-url-parity.sh — ONE fallback, FOUR copies, and they drifted.
#
# THE DEFECT. The compose stack publishes `${PUBLIC_HTTPS_PORT:-8488}:8443`, so
# 8443 is the port INSIDE the container and the host door is 8488. Four separate
# places carried a bare fallback for the docker lane and all four said 8443:
#
#   tests/e2e/steps/dimensions.ts            (fixed by PR #203)
#   tests/e2e/playwright.config.ts           (`baseURL`)
#   studio/hugmesh_studio/core/e2e_environments.py  (`default_pin`)
#   tests/e2e/run.sh                         (found 2026-09-01: its env table, its
#                                             usage text AND its bundled-browser
#                                             `docker run -e SNAP_BASE_URL=` all
#                                             still said 8443 after the other
#                                             three were fixed — the CLI drove one
#                                             mesh while the harness described
#                                             another, and only the cli-lane
#                                             guard's agree spec noticed)
#
# Every run THROUGH the Makefile sets SNAP_BASE_URL from $(PUBLIC_HTTPS_PORT) and
# was always right, so the drift was invisible to the lanes anyone watches. What
# made it harmful is that on a developer box :8443 is published by the KIND NODE.
# MEASURED here 2026-08-27 with both lanes up:
#     https://localhost:8443/ -> 404  (kind node's nginx)
#     https://localhost:8488/ -> 200  (hugmesh-https-front, the platform shell)
# So the fallback did not merely miss the mesh — it named a DIFFERENT ONE, and the
# Studio's e2e chooser handed that address to the spawned runner as the docker lane.
#
# WHAT IS ASSERTED. Not "the files contain 8488" — that is a grep, and a grep is
# satisfied by a commented-out line. The port is DERIVED from the Makefile, the
# Python site is EXECUTED (its real default_pin, imported from the file), the
# TypeScript sites are EVALUATED IN NODE after their comments are stripped, and
# the bash site is RUN (`run.sh --print-command --env docker` and `--help`, which
# execute nothing and need no node_modules) — each twice: once with a scrubbed
# environment (must give the Makefile's port) and once with PUBLIC_HTTPS_PORT
# overridden (must follow it — which proves the indirection is live rather than
# decorative). run.sh is also comment-stripped and scanned for a literal host
# port, which is the only static check that reaches its `docker run` argv.
#
# It also pins that the docker and kind lanes do NOT resolve to the same port:
# their colliding on 8443 is the precondition that turned a wrong default into a
# run against the wrong mesh.
#
# Offline. No stack, no cluster, no network. Tools: bash, python3, node.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

STUDIO_REL="studio/hugmesh_studio/core/e2e_environments.py"
TS_SITES="tests/e2e/playwright.config.ts tests/e2e/steps/dimensions.ts"
KIND_REL="specs/cluster/bootstrap/kind-local/kind-local.yaml"
RUNSH_REL="tests/e2e/run.sh"
PRINTPLAN_REL="tests/e2e/print-plan.mjs"   # run.sh --print-command serialises through it

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

for t in python3 node; do
  command -v "${t}" >/dev/null 2>&1 || {
    echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING." >&2
    exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── the model ────────────────────────────────────────────────────────────────
# Written once, run against the real tree AND against every staged mutant, so the
# controls exercise the same code the positive run does.
cat > "${WORK}/model.py" <<'PYEOF'
"""Grade one tree's docker-lane base-URL fallbacks. Prints PASS/FAIL per check."""
import importlib.util
import json
import os
import re
import subprocess
import sys

root = os.path.abspath(sys.argv[1])
STUDIO = os.path.join(root, "studio/hugmesh_studio/core/e2e_environments.py")
# (relative path, anchor) — the anchor names the DOCKER-lane site inside a file
# that also carries kind and qemu fallbacks on other ports. Taking "every
# localhost template in the file" would grade the qemu one too and fail on a
# correct tree; taking the first template AFTER the anchor grades exactly the
# lane this file is about. The PORT is still derived, never listed.
TS_SITES = [("tests/e2e/playwright.config.ts", r"\bbaseURL\s*:"),
            ("tests/e2e/steps/dimensions.ts", r"^\s*docker:\s*\{")]
TS = [os.path.join(root, rel) for rel, _a in TS_SITES]
MAKEFILE = os.path.join(root, "Makefile")
KIND = os.path.join(root, "specs/cluster/bootstrap/kind-local/kind-local.yaml")
RUNSH = os.path.join(root, "tests/e2e/run.sh")
PRINTPLAN = os.path.join(root, "tests/e2e/print-plan.mjs")

results = []
def check(cid, passed, detail=""):
    results.append((cid, bool(passed), detail))

def incomplete(msg):
    print("INCOMPLETE %s" % msg, file=sys.stderr)
    sys.exit(3)

for p in [STUDIO, MAKEFILE, KIND, RUNSH, PRINTPLAN] + TS:
    if not os.path.isfile(p):
        incomplete("%s is missing — nothing to grade" % p)


def strip_ts_comments(text):
    """Remove // and /* */ comments WITHOUT touching string/template contents.

    This is the whole reason the checks below are not greps: a fallback fixed in
    a comment and broken in code reads identical to `grep 8488`.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in "'\"`":
            q = c
            out.append(c); i += 1
            while i < n:
                if text[i] == "\\":
                    out.append(text[i:i + 2]); i += 2; continue
                out.append(text[i])
                if text[i] == q:
                    i += 1; break
                i += 1
            continue
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = j + 2 if j >= 0 else n
            continue
        out.append(c); i += 1
    return "".join(out)


# ── C1: the port, derived from the Makefile ──────────────────────────────────
m = re.search(r"^PUBLIC_HTTPS_PORT\s*\?=\s*(\d+)\s*$", open(MAKEFILE).read(), re.M)
check("C1-makefile-port", m is not None,
      "Makefile must declare `PUBLIC_HTTPS_PORT ?= <n>` — everything else is derived from it")
PORT = m.group(1) if m else ""
if not PORT:
    incomplete("PUBLIC_HTTPS_PORT could not be derived — the rest would be vacuous")

# The kind door is the mapping for containerPort 443, not the first hostPort in
# the file (that one is :80 -> 8080). Pairing them is the difference between
# grading the ingress and grading an unrelated port.
kind_m = re.search(r"containerPort:\s*443\s*\n\s*hostPort:\s*(\d+)", open(KIND).read())
KIND_PORT = kind_m.group(1) if kind_m else ""
if not KIND_PORT:
    incomplete("kind-local.yaml declares no hostPort — the collision check would be vacuous")

# ── C2: no hardcoded host port survives comment-stripping ────────────────────
hardcoded = {}
for p in TS + [STUDIO, RUNSH]:
    text = open(p).read()
    if p.endswith(".ts"):
        text = strip_ts_comments(text)
    else:
        # Python and bash both comment with a leading '#'. run.sh's qemu row is
        # `localhost:${SNAP_QEMU_UI_PORT:-${UI_PORT:-8443}}` — a knob, not a
        # literal, and `localhost:(\d+)` does not match it; its kind row is on
        # hugmesh.net. So the only thing this can find in run.sh is exactly the
        # defect: a bare `localhost:NNNN` in the env table, the usage text or the
        # `docker run -e SNAP_BASE_URL=` argv.
        text = re.sub(r"(?m)^\s*#.*$", "", text)
        text = re.sub(r'(?s)"""..*?"""', '""', text)
    hits = sorted(set(re.findall(r"localhost:(\d+)", text)))
    if hits:
        hardcoded[os.path.relpath(p, root)] = hits
check("C2-no-hardcoded-port", not hardcoded,
      "a docker-lane fallback must not hardcode a host port; found %s" % json.dumps(hardcoded))

# ── C3/C4: the Python site, EXECUTED ─────────────────────────────────────────
spec = importlib.util.spec_from_file_location("_e2e_env_under_test", STUDIO)
mod = importlib.util.module_from_spec(spec)
# Register before exec: @dataclass resolves annotations through sys.modules, and
# without this the import dies with a bare AttributeError that reads like a broken
# source file rather than a harness bug.
sys.modules[spec.name] = mod
try:
    spec.loader.exec_module(mod)
except Exception as exc:  # a broken module is a FAIL, never a skip
    incomplete("%s could not be imported: %r" % (STUDIO, exc))

def studio_url(env_id, ambient):
    return mod.default_pin(mod.BASE_URL_VAR, env_id, ambient)

def port_of(url):
    mm = re.search(r":(\d+)(?:/|$)", url or "")
    return mm.group(1) if mm else ""

docker_default = studio_url("docker", {})
check("C3-studio-default", port_of(docker_default) == PORT,
      "default_pin(docker) must resolve to the Makefile's %s; got %r" % (PORT, docker_default))

docker_override = studio_url("docker", {"PUBLIC_HTTPS_PORT": "9999"})
check("C4-studio-honours-env", port_of(docker_override) == "9999",
      "default_pin(docker) must follow PUBLIC_HTTPS_PORT; got %r" % (docker_override,))

# ── C5/C6: the TypeScript sites, EVALUATED IN NODE ───────────────────────────
templates = []
anchorless = []
templateless = []
for rel, anchor in TS_SITES:
    body = strip_ts_comments(open(os.path.join(root, rel)).read())
    am = re.search(anchor, body, re.M)
    if not am:
        # The site itself has moved: the model can no longer say anything about
        # this file, and saying nothing quietly is the failure mode this repo
        # keeps relapsing into. INCOMPLETE, never green.
        anchorless.append(rel); continue
    tm = re.search(r"`https://localhost:\$\{[^`]*\}`", body[am.start():am.start() + 600])
    if not tm:
        templateless.append(rel); continue
    templates.append((rel, tm.group(0)))
if anchorless:
    incomplete("the docker-lane anchor is gone from %s — this model would grade nothing"
               % ", ".join(anchorless))

def eval_templates(env_extra):
    script = "const out=[];\n"
    for _rel, tmpl in templates:
        script += "out.push(%s);\n" % tmpl
    script += "console.log(JSON.stringify(out));\n"
    env = {k: v for k, v in os.environ.items() if not k.startswith("SNAP_")}
    env.pop("PUBLIC_HTTPS_PORT", None)
    env.update(env_extra)
    proc = subprocess.run(["node", "-e", script], capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        incomplete("node could not evaluate the extracted templates: %s"
                   % proc.stderr.strip()[:400])
    return json.loads(proc.stdout)

vals = eval_templates({}) if templates else []
bad_default = [(rel, v) for (rel, _t), v in zip(templates, vals) if port_of(v) != PORT]
bad_default += [(rel, "<no interpolated fallback at the docker site>") for rel in templateless]
check("C5-ts-default", not bad_default,
      "every TS docker fallback must evaluate to the Makefile's %s; wrong: %s"
      % (PORT, json.dumps(bad_default)))

vals9 = eval_templates({"PUBLIC_HTTPS_PORT": "9999"}) if templates else []
bad_env = [(rel, v) for (rel, _t), v in zip(templates, vals9) if port_of(v) != "9999"]
bad_env += [(rel, "<no interpolated fallback at the docker site>") for rel in templateless]
check("C6-ts-honours-env", not bad_env,
      "every TS docker fallback must follow PUBLIC_HTTPS_PORT; wrong: %s" % json.dumps(bad_env))

# ── C8/C9/C10: the bash site, RUN ────────────────────────────────────────────
# tests/e2e/run.sh resolves the docker door BEFORE playwright starts (it must
# export SNAP_BASE_URL for the runner), so it cannot ask the TypeScript and keeps
# its own table. --print-command executes nothing and prints the plan as JSON;
# --help prints the usage text. Both are run with SNAP_* and PUBLIC_HTTPS_PORT
# scrubbed, then with the knob overridden.
def run_sh(args, env_extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith("SNAP_")}
    env.pop("PUBLIC_HTTPS_PORT", None); env.pop("UI_PORT", None)
    env.update(env_extra)
    proc = subprocess.run(["bash", RUNSH] + args, capture_output=True, text=True,
                          env=env, cwd=root)
    if proc.returncode != 0:
        incomplete("`run.sh %s` exited %d: %s" % (" ".join(args), proc.returncode,
                                                  (proc.stderr or proc.stdout).strip()[:400]))
    return proc.stdout

def plan_base_url(env_extra):
    last = [l for l in run_sh(["--print-command", "--env", "docker"], env_extra).splitlines() if l.strip()]
    try:
        return json.loads(last[-1]).get("baseUrl") or ""
    except (IndexError, ValueError) as exc:
        incomplete("run.sh --print-command did not end with a JSON plan: %r" % (exc,))

runsh_default = plan_base_url({})
check("C8-runsh-default", port_of(runsh_default) == PORT,
      "run.sh --env docker must resolve to the Makefile's %s; got %r" % (PORT, runsh_default))

runsh_override = plan_base_url({"PUBLIC_HTTPS_PORT": "9999"})
check("C9-runsh-honours-env", port_of(runsh_override) == "9999",
      "run.sh --env docker must follow PUBLIC_HTTPS_PORT; got %r" % (runsh_override,))

# The usage text is what a human reads before typing anything. It must name the
# door the table resolves and move with the knob — a literal that happens to
# equal the Makefile today is the exact shape that drifted.
help_default = run_sh(["--help"], {})
help_override = run_sh(["--help"], {"PUBLIC_HTTPS_PORT": "9999"})
check("C10-runsh-help",
      ("localhost:%s" % PORT) in help_default and "localhost:9999" in help_override,
      "run.sh --help must advertise localhost:%s and follow PUBLIC_HTTPS_PORT (9999); "
      "default mentions it: %s, override mentions 9999: %s"
      % (PORT, ("localhost:%s" % PORT) in help_default, "localhost:9999" in help_override))

# ── C7: the two lanes must not resolve to the same door ──────────────────────
kind_url = studio_url("kind", {})
check("C7-lanes-differ",
      port_of(kind_url) == KIND_PORT and port_of(kind_url) != PORT,
      "the kind lane must stay on kind-local.yaml's hostPort %s and must differ from "
      "the docker lane's %s; got %r" % (KIND_PORT, PORT, kind_url))

failed = 0
for cid, passed, detail in results:
    print("%s %s%s" % ("PASS" if passed else "FAIL", cid, "" if passed else " — " + detail))
    failed += 0 if passed else 1
print("-- %d check(s), %d failed" % (len(results), failed))
sys.exit(1 if failed else 0)
PYEOF

echo "== e2e docker base-URL parity: one fallback, four copies =="

OUT="$(python3 "${WORK}/model.py" "${REPO}" 2>&1)"; RC=$?
echo "${OUT}" | sed 's/^/     /'
if [ "${RC}" -eq 3 ]; then
  echo; echo "== e2e docker base-URL parity: INCOMPLETE — a source the model needs is missing =="
  echo "   A green run without it would be a lie, so this is a FAIL."
  exit 1
fi
[ "${RC}" -eq 0 ] && ok "the repo tree keeps all four docker fallbacks (studio, playwright.config, dimensions, run.sh) on the Makefile's port" \
                 || bad "the repo tree does NOT (see above)"

# ── the mutant harness ───────────────────────────────────────────────────────
stage() {
  local dst
  dst="$1"
  mkdir -p "${dst}/studio/hugmesh_studio/core" "${dst}/tests/e2e/steps" \
           "${dst}/specs/cluster/bootstrap/kind-local"
  cp "${REPO}/Makefile"            "${dst}/Makefile"
  cp "${REPO}/${STUDIO_REL}"       "${dst}/${STUDIO_REL}"
  cp "${REPO}/${KIND_REL}"         "${dst}/${KIND_REL}"
  cp "${REPO}/${RUNSH_REL}"        "${dst}/${RUNSH_REL}"
  cp "${REPO}/${PRINTPLAN_REL}"    "${dst}/${PRINTPLAN_REL}"
  for f in ${TS_SITES}; do cp "${REPO}/${f}" "${dst}/${f}"; done
}

# control <id> <expected failing check> <python mutator on stdin>
control() {
  local cid want dir mout mrc gout grc
  cid="$1"; want="$2"
  dir="${WORK}/${cid}"
  rm -rf "${dir}"; stage "${dir}"
  mout="$(python3 - "${dir}" 2>&1)"; mrc=$?
  if [ "${mrc}" -ne 0 ]; then
    bad "${cid}: the mutator did not land (${mout}) — the control proves nothing"; return
  fi
  gout="$(python3 "${WORK}/model.py" "${dir}" 2>&1)"; grc=$?
  if [ "${grc}" -eq 0 ]; then
    bad "${cid}: the model stayed GREEN with ${want} broken"
    echo "${gout}" | sed 's/^/       /'
  elif [ "${grc}" -eq 3 ]; then
    bad "${cid}: the model reported INCOMPLETE instead of failing ${want}"
    echo "${gout}" | sed 's/^/       /'
  else
    case "${gout}" in
      *"FAIL ${want}"*) ok "${cid}: ${want} goes RED when its invariant is broken" ;;
      *) bad "${cid}: the model went red but NOT on ${want}"
         echo "${gout}" | sed 's/^/       /' ;;
    esac
  fi
}

echo
echo "-- negative controls: restore the defect, prove the model notices --"

control M1-studio-8443 C2-no-hardcoded-port <<'PY'
import sys
p = sys.argv[1] + "/studio/hugmesh_studio/core/e2e_environments.py"; s = open(p).read()
old = 'return "https://localhost:%s" % (amb.get("PUBLIC_HTTPS_PORT") or "8488")'
assert s.count(old) == 1, "M1 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, 'return "https://localhost:8443"'))
PY

control M2-playwright-8443 C2-no-hardcoded-port <<'PY'
import sys
p = sys.argv[1] + "/tests/e2e/playwright.config.ts"; s = open(p).read()
old = """    baseURL: process.env.SNAP_BASE_URL
      || `https://localhost:${process.env.PUBLIC_HTTPS_PORT || '8488'}`,"""
assert s.count(old) == 1, "M2 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, "    baseURL: process.env.SNAP_BASE_URL || 'https://localhost:8443',"))
PY

control M3-dimensions-8443 C2-no-hardcoded-port <<'PY'
import sys
p = sys.argv[1] + "/tests/e2e/steps/dimensions.ts"; s = open(p).read()
old = """      process.env.SNAP_ENV_DOCKER_BASE_URL || process.env.SNAP_BASE_URL
        || `https://localhost:${process.env.PUBLIC_HTTPS_PORT || '8488'}`,"""
assert s.count(old) == 1, "M3 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(
    old,
    "      process.env.SNAP_ENV_DOCKER_BASE_URL || process.env.SNAP_BASE_URL || 'https://localhost:8443',"))
PY

# The one that makes this a guard rather than a grep: the CORRECT line is present,
# but only as a comment, and the live code is wrong.
control M4-fixed-only-in-a-comment C2-no-hardcoded-port <<'PY'
import sys
p = sys.argv[1] + "/tests/e2e/playwright.config.ts"; s = open(p).read()
old = """    baseURL: process.env.SNAP_BASE_URL
      || `https://localhost:${process.env.PUBLIC_HTTPS_PORT || '8488'}`,"""
assert s.count(old) == 1, "M4 anchor not unique: %d" % s.count(old)
new = ("    // baseURL: process.env.SNAP_BASE_URL\n"
       "    //   || `https://localhost:${process.env.PUBLIC_HTTPS_PORT || '8488'}`,\n"
       "    baseURL: process.env.SNAP_BASE_URL || 'https://localhost:8443',")
open(p, "w").write(s.replace(old, new))
PY

# Indirection that is decorative: no hardcoded `localhost:NNNN` literal, and the
# env variable is still ignored. C2 cannot see this one; C4 must.
control M5-decorative-indirection C4-studio-honours-env <<'PY'
import sys
p = sys.argv[1] + "/studio/hugmesh_studio/core/e2e_environments.py"; s = open(p).read()
old = 'return "https://localhost:%s" % (amb.get("PUBLIC_HTTPS_PORT") or "8488")'
assert s.count(old) == 1, "M5 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, 'return "https://localhost:%s" % "8488"'))
PY

control M6-lanes-collide C7-lanes-differ <<'PY'
import sys
p = sys.argv[1] + "/studio/hugmesh_studio/core/e2e_environments.py"; s = open(p).read()
old = 'return "https://hugmesh.net:8443"'
assert s.count(old) == 1, "M6 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, 'return "https://hugmesh.net:8488"'))
PY

control M7-makefile-port-drift C5-ts-default <<'PY'
import re, sys
p = sys.argv[1] + "/Makefile"; s = open(p).read()
new = re.sub(r"(?m)^PUBLIC_HTTPS_PORT\s*\?=\s*\d+\s*$", "PUBLIC_HTTPS_PORT ?= 8555", s, count=1)
assert new != s, "M7 did not land: no PUBLIC_HTTPS_PORT declaration to move"
open(p, "w").write(new)
PY

# The bash site, restored to each of its three 2026-09-01 shapes.
control M9-runsh-table-8443 C2-no-hardcoded-port <<'PY'
import sys
p = sys.argv[1] + "/tests/e2e/run.sh"; s = open(p).read()
old = 'docker) url="${SNAP_ENV_DOCKER_BASE_URL:-${SNAP_BASE_URL:-${DOCKER_DEFAULT_BASE_URL}}}" ;;'
assert s.count(old) == 1, "M9 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, 'docker) url="${SNAP_ENV_DOCKER_BASE_URL:-${SNAP_BASE_URL:-https://localhost:8443}}" ;;'))
PY

control M10-runsh-help-8443 C2-no-hardcoded-port <<'PY'
import sys
p = sys.argv[1] + "/tests/e2e/run.sh"; s = open(p).read()
old = "  __DOCKER_DEFAULT_BASE_URL__ "
assert s.count(old) == 1, "M10 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, "  https://localhost:8443 "))
PY

control M11-runsh-docker-argv-8443 C2-no-hardcoded-port <<'PY'
import sys
p = sys.argv[1] + "/tests/e2e/run.sh"; s = open(p).read()
old = '-e SNAP_BASE_URL="${SNAP_BASE_URL:-$(env_base_url docker)}"'
assert s.count(old) == 1, "M11 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, '-e SNAP_BASE_URL="${SNAP_BASE_URL:-https://localhost:8443}"'))
PY

# Decorative indirection in bash: the knob is named, and ignored. C2 cannot see
# it (no literal `localhost:NNNN`); C9 must.
control M12-runsh-decorative-indirection C9-runsh-honours-env <<'PY'
import sys
p = sys.argv[1] + "/tests/e2e/run.sh"; s = open(p).read()
old = 'DOCKER_HOST_PORT="${PUBLIC_HTTPS_PORT:-8488}"'
assert s.count(old) == 1, "M12 anchor not unique: %d" % s.count(old)
open(p, "w").write(s.replace(old, 'DOCKER_HOST_PORT="8488"'))
PY

# ── the sources going missing must be INCOMPLETE, never green ────────────────
INC="${WORK}/incomplete"; rm -rf "${INC}"; stage "${INC}"
rm -f "${INC}/${STUDIO_REL}"
python3 "${WORK}/model.py" "${INC}" >/dev/null 2>&1; INC_RC=$?
[ "${INC_RC}" -eq 3 ] \
  && ok "M8: a missing source is INCOMPLETE (exit 3), not a silent pass" \
  || bad "M8: a missing source exited ${INC_RC} — it must be 3 (INCOMPLETE)"

# ── positive control ─────────────────────────────────────────────────────────
CLEAN="${WORK}/clean"; rm -rf "${CLEAN}"; stage "${CLEAN}"
python3 "${WORK}/model.py" "${CLEAN}" >/dev/null 2>&1; CLEAN_RC=$?
[ "${CLEAN_RC}" -eq 0 ] \
  && ok "positive control: an UNMUTATED staged copy passes (the mutants are what bite)" \
  || bad "positive control: an unmutated staged copy failed (rc=${CLEAN_RC}) — staging is wrong, every control above is meaningless"

echo
echo "== e2e docker base-URL parity: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
