#!/usr/bin/env bash
# test-governance-flags-visible.sh — the desktop-governance go-live flags must be
# VISIBLE and OVERRIDABLE in the cluster manifest and the compose stack, and must
# stay dark until someone flips them on purpose.
#
# WHY THIS EXISTS. Three admin-BFF flags decide whether the platform can open a
# shell or run an install on a tenant device:
#
#   app.device-terminal.enabled        env DEVICE_TERMINAL_ENABLED
#   app.device-terminal.dial.enabled   env DEVICE_TERMINAL_DIAL_ENABLED
#   app.desktop.remote-install.enabled env DESKTOP_REMOTE_INSTALL_ENABLED
#
# All three default OFF, and until this change nothing in any manifest named them:
# the third had no application.yml entry at all (only a
# @ConditionalOnProperty(matchIfMissing = true) bean condition), so a reader of the
# platform could not find the switch, and a deployment had no name to override. A
# flag nobody can see is not "dark by design", it is unreachable. This suite pins:
#
#   A. CLUSTER  — specs/cluster/manifests/admin-bff-api/deployment.yaml declares each
#      of the three exactly once, as the QUOTED STRING "false". Quoted, because the
#      API server rejects an unquoted YAML boolean in an env value, and a literal
#      rather than a valueFrom so the lever is one reviewable line.
#   B. COMPOSE  — tests/stack/compose.local.yaml's hugmesh-admin-bff-api service
#      reads each through ${NAME:-false}. Interpolated, not hardcoded: a hardcoded
#      "false" is visible but not overridable, which is the half this change adds.
#   C. COUPLING — if the cluster ever sets DEVICE_TERMINAL_DIAL_ENABLED to "true" the
#      Deployment must mount the per-device dial-key Secrets under
#      /var/run/secrets/device-ssh-dial. Without that mount the flag wires the
#      pinned factory, every dial then fails closed on a missing key file, and the
#      flag looks live while doing nothing. (Measured 2026-10-14: no manifest in
#      this tree mounts them today.)
#   D. DOCS     — docs/CLIENT-IMAGES.md carries the go-live preconditions section
#      the manifest comment points at (the security re-review and the
#      device_ssh_dial rows), so the pointer cannot dangle.
#
# THE POSTURE PIN IS DELIBERATE. Check A fails if a flag is "true". Flipping one is
# a go-live decision with preconditions (docs/CLIENT-IMAGES.md section 7); the
# commit that flips it must update this suite in the same change, which is the
# review point. This suite does NOT flip anything.
#
# THE OTHER END of the contract (the BFF's application.yml carrying these three
# placeholders with default false) is pinned in hugmesh-admin-bff-api by
# DesktopRemoteInstallYamlDefaultTest, not here: a hosted generator runner cannot
# be assumed to have that checkout, and a check that skips without it is the
# failure shape tests/scripts/test-guard-integrity.sh exists to stop.
#
# NEGATIVE CONTROLS: every check above is re-run against a copy of the real files
# with exactly one defect planted; each must go red with the matching message, and
# each plant is verified to have CHANGED the file (a mutation that is a no-op would
# make its control vacuously green).
#
# Offline: bash + python3 + PyYAML. No cluster, no network, no root, no docker.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOV_ROOT="${GOV_ROOT:-${REPO}}"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }

# ── the analyser: one python program, run against the real tree and then against
#    mutated copies. Prints "  PASS ..." / "  FAIL ..." lines; exits 1 on any FAIL.
analyse() {
  GOV_ROOT="$1" python3 - <<'PY'
import os, re, sys
import yaml

ROOT = os.environ["GOV_ROOT"]
CLUSTER = os.path.join(ROOT, "specs/cluster/manifests/admin-bff-api/deployment.yaml")
COMPOSE = os.path.join(ROOT, "tests/stack/compose.local.yaml")
DOCS = os.path.join(ROOT, "docs/CLIENT-IMAGES.md")
FLAGS = ["DEVICE_TERMINAL_ENABLED", "DEVICE_TERMINAL_DIAL_ENABLED",
         "DESKTOP_REMOTE_INSTALL_ENABLED"]
DIAL_MOUNT = "/var/run/secrets/device-ssh-dial"

fails = 0
def ok(m):
    print("  PASS " + m)
def bad(m):
    global fails
    fails += 1
    print("  FAIL " + m)

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return list(yaml.safe_load_all(f))
    except Exception as e:
        bad("cannot read/parse %s: %s" % (os.path.relpath(path, ROOT), e))
        return []

# ── A. cluster ───────────────────────────────────────────────────────────────
dep = None
for d in load(CLUSTER):
    if isinstance(d, dict) and d.get("kind") == "Deployment":
        dep = d
        break
if dep is None:
    bad("A: no Deployment in specs/cluster/manifests/admin-bff-api/deployment.yaml")
    containers = []
else:
    containers = dep["spec"]["template"]["spec"].get("containers") or []
# the env of the container that carries the BFF's other flags
main = None
for c in containers:
    names = [e.get("name") for e in (c.get("env") or [])]
    if "APP_BFF_EXCHANGE_ENABLED" in names:
        main = c
        break
if main is None:
    bad("A: could not find the admin-bff container (the one carrying APP_BFF_EXCHANGE_ENABLED); "
        "every cluster check would be vacuous")
    env = []
else:
    env = main.get("env") or []

cluster_val = {}
for flag in FLAGS:
    hits = [e for e in env if e.get("name") == flag]
    if len(hits) != 1:
        bad("A: %s is declared %d times in the admin-bff Deployment env (want exactly 1) — "
            "the go-live flag is %s" % (flag, len(hits),
            "INVISIBLE to an operator reading the manifest" if not hits else "ambiguous"))
        continue
    e = hits[0]
    if "value" not in e:
        bad("A: %s has no literal value (valueFrom?) — the lever must be one reviewable line" % flag)
        continue
    v = e["value"]
    if not isinstance(v, str):
        bad("A: %s value is %s %r, not the quoted string — the API server rejects an unquoted "
            "boolean env value" % (flag, type(v).__name__, v))
        continue
    cluster_val[flag] = v
    if v == "false":
        ok("A: %s is declared in the cluster manifest and is \"false\"" % flag)
    elif v == "true":
        bad("A: %s is \"true\" — flipping a desktop-governance go-live flag needs the "
            "preconditions in docs/CLIENT-IMAGES.md section 7 and a matching update of this suite"
            % flag)
    else:
        bad("A: %s value %r is neither \"true\" nor \"false\"" % (flag, v))

# ── C. coupling: dial flag on => the dial-key Secrets are mounted ────────────
if cluster_val.get("DEVICE_TERMINAL_DIAL_ENABLED") == "true":
    mounts = [m.get("mountPath", "") for m in ((main or {}).get("volumeMounts") or [])]
    if any(m == DIAL_MOUNT or m.startswith(DIAL_MOUNT + "/") for m in mounts):
        ok("C: dial flag is on and %s is mounted" % DIAL_MOUNT)
    else:
        bad("C: DEVICE_TERMINAL_DIAL_ENABLED is \"true\" but the Deployment mounts nothing under "
            "%s — every dial fails closed on a missing per-device key file, so the flag looks "
            "live and does nothing" % DIAL_MOUNT)
else:
    ok("C: dial flag is off, so no dial-key mount is required yet")

# ── B. compose ───────────────────────────────────────────────────────────────
svc = None
for d in load(COMPOSE):
    if isinstance(d, dict):
        svc = (d.get("services") or {}).get("hugmesh-admin-bff-api")
        break
if svc is None:
    bad("B: no hugmesh-admin-bff-api service in tests/stack/compose.local.yaml")
    cenv = {}
else:
    cenv = svc.get("environment") or {}
    if isinstance(cenv, list):
        cenv = dict(x.split("=", 1) for x in cenv if "=" in x)
for flag in FLAGS:
    if flag not in cenv:
        bad("B: %s is absent from the compose admin-bff service — not visible, not overridable" % flag)
        continue
    want = "${%s:-false}" % flag
    got = cenv[flag]
    if str(got) == want:
        ok("B: compose reads %s through %s" % (flag, want))
    else:
        bad("B: compose sets %s to %r, want %s — a hardcoded value is visible but cannot be "
            "overridden, and a non-false default ships the flag lit" % (flag, got, want))

# ── D. docs ──────────────────────────────────────────────────────────────────
try:
    with open(DOCS, encoding="utf-8") as f:
        docs = f.read()
except OSError as e:
    docs = ""
    bad("D: cannot read docs/CLIENT-IMAGES.md: %s" % e)
m = re.search(r"(?ms)^#{2,4} [^\n]*Go-live preconditions[^\n]*\n(.*?)(?=^#{1,4} |\Z)", docs)
if not m:
    bad("D: docs/CLIENT-IMAGES.md has no 'Go-live preconditions' section, but the manifest "
        "comment and the compose comment point at it")
else:
    body = m.group(1)
    for what, pat in (("the mandatory security re-review", r"security re-review"),
                      ("the device_ssh_dial rows", r"device_ssh_dial"),
                      ("the pinned host_key_fp / no TOFU", r"host_key_fp"),
                      ("the three flag names", r"DESKTOP_REMOTE_INSTALL_ENABLED")):
        if re.search(pat, body):
            ok("D: go-live preconditions section covers %s" % what)
        else:
            bad("D: go-live preconditions section does not mention %s (/%s/)" % (what, pat))

sys.exit(1 if fails else 0)
PY
}

P=0; F=0
tally() {  # read analyser output on stdin, echo it, count PASS/FAIL
  local line
  while IFS= read -r line; do
    echo "${line}"
    case "${line}" in
      "  PASS "*) P=$((P+1)) ;;
      "  FAIL "*) F=$((F+1)) ;;
    esac
  done
}

echo "== desktop-governance go-live flags: visible, overridable, dark =="
echo "-- positive: the repo's own files --"
tally < <(analyse "${GOV_ROOT}" 2>&1)
# A passing run must have checked all of it, not nothing.
N_PASS_REAL="${P}"
if [ "${N_PASS_REAL}" -lt 11 ] || [ "${F}" -ne 0 ]; then
  [ "${F}" -eq 0 ] && { echo "  FAIL positive run produced only ${P} checks (want >= 11): the analyser went vacuous"; F=$((F+1)); }
  echo; echo "== ${P} passed, ${F} failed =="; exit 1
fi

# ── negative controls ────────────────────────────────────────────────────────
echo "-- negative controls: each planted defect must turn the analyser red --"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/govflags.XXXXXX")"
trap 'rm -rf "${SCRATCH}"' EXIT
REL_CLUSTER="specs/cluster/manifests/admin-bff-api/deployment.yaml"
REL_COMPOSE="tests/stack/compose.local.yaml"
REL_DOCS="docs/CLIENT-IMAGES.md"

fresh() {  # a pristine copy of the three inputs
  rm -rf "${SCRATCH}/t"; mkdir -p "${SCRATCH}/t"
  local rel
  for rel in "${REL_CLUSTER}" "${REL_COMPOSE}" "${REL_DOCS}"; do
    mkdir -p "${SCRATCH}/t/$(dirname "${rel}")"
    cp "${GOV_ROOT}/${rel}" "${SCRATCH}/t/${rel}"
  done
}

# control NAME REL SED_EXPR EXPECTED_FAIL_REGEX
control() {
  local name="$1" rel="$2" expr="$3" want="$4" before out rc
  fresh
  before="$(cksum < "${SCRATCH}/t/${rel}")"
  sed -i -E "${expr}" "${SCRATCH}/t/${rel}"
  if [ "$(cksum < "${SCRATCH}/t/${rel}")" = "${before}" ]; then
    echo "  FAIL control '${name}': the mutation did not change ${rel} (vacuous control)"; F=$((F+1)); return
  fi
  out="$(analyse "${SCRATCH}/t" 2>&1)"; rc=$?
  if [ "${rc}" -ne 0 ] && printf '%s\n' "${out}" | grep -E "^  FAIL .*${want}" >/dev/null; then
    echo "  PASS negative control bites: ${name}"; P=$((P+1))
  else
    echo "  FAIL negative control did NOT bite: ${name} (rc=${rc}, wanted /${want}/)"; F=$((F+1))
  fi
}

control "cluster drops DESKTOP_REMOTE_INSTALL_ENABLED" "${REL_CLUSTER}" \
  '/name: DESKTOP_REMOTE_INSTALL_ENABLED,/d' 'A: DESKTOP_REMOTE_INSTALL_ENABLED is declared 0 times'
control "cluster drops DEVICE_TERMINAL_ENABLED" "${REL_CLUSTER}" \
  '/name: DEVICE_TERMINAL_ENABLED,/d' 'A: DEVICE_TERMINAL_ENABLED is declared 0 times'
control "cluster renames the dial flag (typo)" "${REL_CLUSTER}" \
  's/name: DEVICE_TERMINAL_DIAL_ENABLED,/name: DEVICE_TERMINAL_DIAL_ENABLE,/' 'A: DEVICE_TERMINAL_DIAL_ENABLED is declared 0 times'
control "cluster flips remote-install to \"true\"" "${REL_CLUSTER}" \
  's/(name: DESKTOP_REMOTE_INSTALL_ENABLED, +value: )"false"/\1"true"/' 'A: DESKTOP_REMOTE_INSTALL_ENABLED is "true"'
control "cluster tidies \"false\" to an unquoted boolean" "${REL_CLUSTER}" \
  's/(name: DEVICE_TERMINAL_ENABLED, +value: )"false"/\1false/' 'A: DEVICE_TERMINAL_ENABLED value is bool'
control "cluster flips the dial flag with no key mount" "${REL_CLUSTER}" \
  's/(name: DEVICE_TERMINAL_DIAL_ENABLED, +value: )"false"/\1"true"/' 'C: DEVICE_TERMINAL_DIAL_ENABLED is "true" but the Deployment mounts nothing'
control "compose drops a flag" "${REL_COMPOSE}" \
  '/^      DEVICE_TERMINAL_DIAL_ENABLED:/d' 'B: DEVICE_TERMINAL_DIAL_ENABLED is absent from the compose'
control "compose hardcodes a flag (visible, not overridable)" "${REL_COMPOSE}" \
  's/^(      DESKTOP_REMOTE_INSTALL_ENABLED:).*/\1 "false"/' 'B: compose sets DESKTOP_REMOTE_INSTALL_ENABLED'
control "compose defaults a flag ON" "${REL_COMPOSE}" \
  's/^(      DEVICE_TERMINAL_ENABLED:) .*/\1 ${DEVICE_TERMINAL_ENABLED:-true}/' 'B: compose sets DEVICE_TERMINAL_ENABLED'
control "docs lose the go-live preconditions section" "${REL_DOCS}" \
  's/Go-live preconditions/Rollout notes/' "D: docs/CLIENT-IMAGES.md has no 'Go-live preconditions'"
control "docs drop the security re-review" "${REL_DOCS}" \
  's/security re-review/security look/g' 'D: go-live preconditions section does not mention the mandatory security re-review'

# The coupling's POSITIVE half: dial flag on AND the mount present must satisfy C
# (and is still red on A, the posture pin — that is the point of the pin).
fresh
sed -i -E 's/(name: DEVICE_TERMINAL_DIAL_ENABLED, +value: )"false"/\1"true"/' "${SCRATCH}/t/${REL_CLUSTER}"
python3 - "${SCRATCH}/t/${REL_CLUSTER}" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = "          volumeMounts:\n"
i = s.rindex(needle)         # the main container's volumeMounts (the last block)
s = s[:i + len(needle)] + "            - { name: dial-keys, mountPath: /var/run/secrets/device-ssh-dial, readOnly: true }\n" + s[i + len(needle):]
open(p, "w", encoding="utf-8").write(s)
PY
out="$(analyse "${SCRATCH}/t" 2>&1)"
if printf '%s\n' "${out}" | grep -F "  PASS C: dial flag is on and /var/run/secrets/device-ssh-dial is mounted" >/dev/null; then
  echo "  PASS coupling accepts the dial flag once the per-device mount exists"; P=$((P+1))
else
  echo "  FAIL coupling did not accept a present dial-key mount"; printf '%s\n' "${out}" | grep -E "C:" ; F=$((F+1))
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
