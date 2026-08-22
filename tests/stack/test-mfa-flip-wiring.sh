#!/usr/bin/env bash
# test-mfa-flip-wiring.sh — the INERT-TOGGLE gate for the MFA operational flip
# (issue #47): one switch, MFA=1, three lanes — and EVERY consumer of the gateway
# MFA env trio must provably receive it when the switch is on.
#
# WHY THIS GATE EXISTS. This repo has shipped a flag that wired only half its
# consumers TWICE: the gateway MFA trio itself appeared in ZERO files while the
# feature was "done" (see tests/stack/test-gateway-mfa-env.sh's header), and the
# AI-cloak lane needed BOTH the worker and the BFF flag before POISONER=1 did
# anything. A switch that reaches some consumers and not others does not fail —
# it ships dark, and nothing tells you. So this gate ENUMERATES the consumers of
# the flip per lane, RE-DERIVES each set from the artifact itself (never only
# from a hand-written list), and proves the switch lands on every one:
#
#   lane A — compose dev stack (`make stack-up MFA=1`)
#     switch:    Makefile MFA ?= -> STACK_MFA_ENV -> APP_MFA_ENABLED='true'
#     consumers: every gateway service in tests/stack/compose.local.yaml
#                (re-derived via gateway_mfa_env.py compose-gateways), each of
#                which must read the env through ${APP_MFA_ENABLED...}
#                interpolation — a hardcoded value would disconnect the switch.
#   lane B — kind SSO slice (`make kind-up MFA=1`)
#     switch:    Makefile threads MFA into bootstrap-kind.sh, which appends a
#                mfa.enabled=true HELM PARAMETER to the gateway Application
#                patch (committed chart/apps stay untouched and default-OFF).
#     consumers: every gateway Application bootstrap-kind.sh APPLIES (re-derived
#                from its own SSO_APPS array). Each must be patched EXACTLY ONCE
#                (`--type merge` REPLACES spec.source.helm.parameters wholesale,
#                so a second patch of the same list silently drops the first
#                one's entries), the mfa.enabled append must feed that same
#                patch, and it must sit INSIDE the `if [ -n "${MFA}" ]` guard —
#                an unguarded append is a kind default-ON regression.
#     verifier:  `make kind-e2e-mfa` must run the MFA spec (29) against the
#                cluster, and must take the spec's APP_MFA_ENABLED from the
#                RUNNING gateway pod (scripts/kind-mfa-posture.sh) rather than
#                from $(MFA) or a literal. A flip nobody can observe is the same
#                shipped-dark failure one step later: kind-e2e runs spec 27 only,
#                so until this target existed NEITHER kind posture was ever
#                asserted end to end. Threading $(MFA) instead would look
#                equivalent and is not — kind-up is a SEPARATE invocation and the
#                cluster outlives it, so the caller's shell describes a cluster
#                it may never have flipped. The helper itself is proven
#                FAIL-CLOSED by EXECUTION against a stub kubectl (empty /
#                unparseable / erroring reads must all exit non-zero), because
#                "assume off" would report a clean pass for the posture the
#                cluster is NOT holding.
#   lane C — per-domain / tenant render (brands/<brand>.conf MFA=1)
#     switch:    generate-brand-repos.sh derives {{MFA_ENABLED}} from the brand
#                profile (conf-only: ambient env must NOT leak in).
#     consumers: every RENDERED Application that deploys the shared gateway
#                chart (re-derived from the rendered tree's `path:` lines). This
#                lane is proven on the REAL renderer output, not on greps of the
#                templates: the gate runs generate-brand-repos.sh (sed engine)
#                with the knob off, on, invalid, and ambient-env-only.
#
# WHAT THIS GATE DOES NOT OWN: the default-OFF *posture* of the chart, the four
# cluster Applications and the compose trio — tests/stack/test-gateway-mfa-env.sh
# pins all of that (and test-mfa-required-rules.sh pins the rules + the
# no-Application-flips-it rule). This gate re-pins only the two posture facts the
# flip itself could regress (chart mfa.enabled false; no committed brand profile
# ships MFA on) and otherwise checks WIRING.
#
# NEGATIVE CONTROLS (staged copies under mktemp; the repo tree is NEVER
# mutated): every wiring assertion above is exercised against a mutant that
# breaks exactly it — a gateway template stripped of its mfa block, a renderer
# missing the {{MFA_ENABLED}} substitution, a Makefile that defines but never
# threads STACK_MFA_ENV, a bootstrap without the mfa append / with the append
# UNGUARDED / with a second clobbering patch, a compose gateway hardcoding the
# env, a committed brand profile shipping MFA=1, a Makefile with no kind-e2e-mfa
# target, a kind-e2e-mfa that STILL calls the posture helper but overrides its
# answer with $(MFA), and a posture helper that answers "false" for a cluster it
# could not read. Every mutator PROVES IT LANDED (exits non-zero when its target
# text is absent) — a mutator that silently no-ops turns its control into a fake
# pass.
#
# Tools: bash>=4, python3 + PyYAML (reuses tests/stack/gateway_mfa_env.py for the
# compose model), coreutils/sed/grep/awk. No cluster, no docker, no network — the
# live-posture helper is exercised against a STUB kubectl on a scratch PATH, never
# against a real one, so this gate stays runnable on a laptop with no kubeconfig.
set -uo pipefail

_self="${BASH_SOURCE[0]}"; _selfdir="${_self%/*}"
[ "${_selfdir}" != "${_self}" ] || _selfdir="."
REPO="$(cd "${_selfdir}/../.." && pwd)"

MAKEFILE="${REPO}/Makefile"
COMPOSE="${REPO}/tests/stack/compose.local.yaml"
EXTRACT="${REPO}/tests/stack/gateway_mfa_env.py"
BOOTSTRAP="${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
GENBRAND="${REPO}/generate-brand-repos.sh"
TEMPLATES="${REPO}/templates"
BRANDS="${REPO}/brands"
CHART_VALUES="${REPO}/specs/cluster/charts/hugmesh-gateway/values.yaml"
APPS_DIR="${REPO}/specs/cluster/apps"
CHART_REL="specs/cluster/charts/hugmesh-gateway"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# ── preflight (this runs without -e: a missing tool would DISTORT the tally,
#    not stop it — refuse to produce a meaningless count) ─────────────────────
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 missing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML missing (pip install pyyaml)"; exit 2; }
missing=""
for t in awk find sort sed grep wc mktemp cp rm mkdir realpath; do
  command -v "${t}" >/dev/null 2>&1 || missing="${missing} ${t}"
done
[ -z "${missing}" ] || { echo "  FAIL required tool(s) not on PATH:${missing} (realpath: generate-brand-repos.sh needs it)"; exit 2; }
[ -n "${BASH_VERSION:-}" ] && [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "  FAIL bash >= 4 required"; exit 2; }
for f in "${MAKEFILE}" "${COMPOSE}" "${EXTRACT}" "${BOOTSTRAP}" "${GENBRAND}" \
         "${CHART_VALUES}" "${TEMPLATES}/apps/20-gateway-fe.yaml.hbs" "${BRANDS}/example.conf"; do
  [ -e "${f}" ] || { echo "  FAIL missing input ${f}"; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT
mkdir -p "${WORK}/pre/d" && : > "${WORK}/pre/d/f"
{ cp -a "${WORK}/pre/d" "${WORK}/pre/copy" 2>/dev/null && [ -f "${WORK}/pre/copy/f" ]; } || {
  echo "  FAIL 'cp -a <dir> <dir>' does not work here — every negative control stages with it"; exit 2; }

echo "== MFA=1 operational-flip wiring gate (issue #47; every consumer, every lane) =="

# ═══════════════════════════════════════════════════════════════════════════
# helpers
# ═══════════════════════════════════════════════════════════════════════════

# lane A predicate over a compose file: every gateway service (RE-DERIVED from
# the file itself) must read APP_MFA_ENABLED through ${APP_MFA_ENABLED...}
# interpolation, so the Makefile-threaded env can actually land. Echoes nothing
# when good, else one human reason per problem. rc 0 iff clean AND non-vacuous.
compose_switch_reaches() { # <compose-file>
  local f="$1" svcs svc raw problems=""
  svcs="$(python3 "${EXTRACT}" compose-gateways "${f}" 2>/dev/null | awk -F'\t' '$1=="GWSVC"{print $2}' | sort -u)"
  if [ -z "${svcs}" ]; then echo "DISCOVERY-EMPTY: no gateway service found in ${f##*/} (vacuous)"; return 1; fi
  while IFS= read -r svc; do
    raw="$(python3 "${EXTRACT}" compose "${f}" "${svc}" 2>/dev/null \
           | awk -F'\t' -v s="${svc}" '$1==s && $2=="APP_MFA_ENABLED"{print $3}')"
    case "${raw}" in
      '${APP_MFA_ENABLED'*) : ;;  # interpolated -> the threaded env lands
      "") problems="${problems}${svc}: APP_MFA_ENABLED not set (switch reaches nothing); " ;;
      *)  problems="${problems}${svc}: APP_MFA_ENABLED is '${raw}' (hardcoded — MFA=1 cannot reach this service); " ;;
    esac
  done <<< "${svcs}"
  [ -z "${problems}" ] || { echo "${problems}"; return 1; }
  return 0
}

# lane B analyzer: emits TSV over a bootstrap-kind.sh + apps dir.
#   GWAPP <file> <app-name> PATCHES <n>
#   GWAPP <file> <app-name> MFA_PARAM <yes|no>
#   GWAPP <file> <app-name> MFA_GUARDED <yes|no|n/a>
#   FLOORREF <n>            (floor env/value spellings OUTSIDE comments)
#   NGW <n>                 (gateway files found in SSO_APPS — vacuity guard)
bootstrap_audit() { # <bootstrap.sh> <apps-dir>
  python3 - "$1" "$2" <<'PY'
import re, sys, yaml
script, appsdir = sys.argv[1], sys.argv[2]
lines = open(script, encoding="utf-8").read().splitlines()

# 1) SSO_APPS entries -> gateway app files (re-derived from the script itself)
entries, inarr = [], False
for ln in lines:
    if re.match(r'^\s*SSO_APPS=\(', ln): inarr = True; continue
    if inarr:
        if re.match(r'^\s*\)\s*$', ln): inarr = False; continue
        m = re.match(r'^\s*([0-9A-Za-z._-]+\.ya?ml)\b', ln)
        if m: entries.append(m.group(1))
gw_files = [e for e in entries if "gateway" in e]
print("NGW\t%d" % len(gw_files))

# 2) map each gateway file -> Application metadata.name
names = {}
for f in gw_files:
    try:
        docs = list(yaml.safe_load_all(open("%s/%s" % (appsdir, f), encoding="utf-8")))
    except Exception as e:
        print("GWAPP\t%s\tUNREADABLE\tPATCHES\t0" % f); continue
    app = next((d for d in docs if isinstance(d, dict) and d.get("kind") == "Application"), None)
    n = ((app or {}).get("metadata") or {}).get("name")
    if not n:
        print("GWAPP\t%s\tNO-NAME\tPATCHES\t0" % f); continue
    names[f] = n

# 3) join backslash continuations so a multi-line kubectl patch is one command
joined, buf = [], ""
for ln in lines:
    if ln.rstrip().endswith("\\"):
        buf += ln.rstrip()[:-1] + " "
    else:
        joined.append(buf + ln); buf = ""
if buf: joined.append(buf)

# 4) variable base-assignments and appends, with an `if [ -n "${MFA}" ]` guard
#    state machine (line-based; nested ifs push anonymous frames)
guard_stack, base, appends = [], {}, {}
mfa_guard_re = re.compile(r'^\s*if\s+\[\s+-n\s+"\$\{MFA\}"\s+\]')
for ln in joined:
    if mfa_guard_re.match(ln): guard_stack.append("MFA")
    elif re.match(r'^\s*if\b', ln): guard_stack.append("other")
    elif re.match(r'^\s*fi\b', ln) and guard_stack: guard_stack.pop()
    m = re.match(r"^\s*([A-Za-z_]\w*)='(.*)'\s*$", ln)
    if m: base[m.group(1)] = m.group(2)
    m = re.match(r'^\s*([A-Za-z_]\w*)="\$\{\1\},(.*)"\s*$', ln)
    if m:
        appends.setdefault(m.group(1), []).append(
            {"text": m.group(2), "mfa_guarded": "MFA" in guard_stack})

# 5) patch invocations: app name + payload (literal or ${VAR}-interpolated)
patches = {}
for ln in joined:
    m = re.search(r'\bpatch\s+application\s+([A-Za-z0-9.-]+)\b', ln)
    if not m: continue
    patches.setdefault(m.group(1), []).append(ln)

def payload_param_sources(cmdline):
    """Return (has_mfa_literal, [payload var names])."""
    vars_ = re.findall(r'parameters\\?":\s*\[\$\{([A-Za-z_]\w*)\}\]', cmdline)
    return ("mfa.enabled" in cmdline, vars_)

for f, n in names.items():
    cmds = patches.get(n, [])
    print("GWAPP\t%s\t%s\tPATCHES\t%d" % (f, n, len(cmds)))
    has_param, guarded = False, "n/a"
    for c in cmds:
        lit, pvars = payload_param_sources(c)
        if lit:
            has_param = True
            guarded = "no"  # literal mfa.enabled inside the patch = unguarded
        for v in pvars:
            for ap in appends.get(v, []):
                if "mfa.enabled" in ap["text"] and '"true"' in ap["text"].replace("\\", ""):
                    has_param = True
                    guarded = "yes" if ap["mfa_guarded"] else "no"
    print("GWAPP\t%s\t%s\tMFA_PARAM\t%s" % (f, n, "yes" if has_param else "no"))
    print("GWAPP\t%s\t%s\tMFA_GUARDED\t%s" % (f, n, guarded))

# 6) floor spellings outside comments (the flip must never touch the floor)
floor = 0
for ln in lines:
    code = ln.split("#", 1)[0] if ln.lstrip().startswith("#") is False else ""
    if ln.lstrip().startswith("#"): code = ""
    else: code = ln
    if "enforcePrivilegedFloor" in code or "APP_MFA_ENFORCE_PRIVILEGED_FLOOR" in code:
        floor += 1
print("FLOORREF\t%d" % floor)
PY
}

# lane B predicate over an audit TSV; echoes problems, rc 0 iff clean+non-vacuous
bootstrap_switch_reaches() { # <tsv>
  local t="$1" ngw problems=""
  ngw="$(awk -F'\t' '$1=="NGW"{print $2}' "${t}")"
  [ "${ngw:-0}" -ge 1 ] || { echo "DISCOVERY-EMPTY: no gateway file in SSO_APPS (vacuous)"; return 1; }
  while IFS=$'\t' read -r _ f n k v; do
    case "${k}" in
      PATCHES)     [ "${v}" = "1" ] || problems="${problems}${n} (${f}): ${v} patch-application commands (need exactly 1 — merge REPLACES helm.parameters wholesale, so 0 = unreachable and 2+ = clobber); " ;;
      MFA_PARAM)   [ "${v}" = "yes" ] || problems="${problems}${n} (${f}): no mfa.enabled=true parameter feeds its patch — MFA=1 flips NOTHING on this gateway; " ;;
      MFA_GUARDED) [ "${v}" = "yes" ] || problems="${problems}${n} (${f}): mfa.enabled append is ${v} w.r.t. the 'if [ -n \"\${MFA}\" ]' guard (unguarded = kind default-ON regression); " ;;
    esac
  done < <(awk -F'\t' '$1=="GWAPP"' "${t}")
  [ "$(awk -F'\t' '$1=="FLOORREF"{print $2}' "${t}")" = "0" ] \
    || problems="${problems}bootstrap references the privileged floor outside comments — the flip must never wire APP_MFA_ENFORCE_PRIVILEGED_FLOOR; "
  [ -z "${problems}" ] || { echo "${problems}"; return 1; }
  return 0
}

# lane C: render a brand conf with the STAGED repo slice and classify the output.
# Emits TSV: CONSUMERS <n>, WITH_MFA <n>, SETS_EQUAL yes|no, VALUES <csv of
# distinct enabled: values across gateway apps>, UNSUBST <n>, FLOOR <n>.
render_and_classify() { # <staged-repo-dir> <conf> <outdir> [env K=V...]
  local repo="$1" conf="$2" out="$3"; shift 3
  ( cd "${repo}" && env "$@" ./generate-brand-repos.sh "${conf}" --out-dir "${out}" ) >/dev/null 2>&1 || return 2
  python3 - "${out}" <<'PY'
import os, re, sys
root = sys.argv[1]
apps = []
for dirpath, _, files in os.walk(root):
    for fn in files:
        if fn.endswith((".yaml", ".yml")):
            apps.append(os.path.join(dirpath, fn))
gw, withmfa, values, unsubst, floor = set(), set(), set(), 0, 0
for p in apps:
    s = open(p, encoding="utf-8").read()
    if re.search(r'^\s*path:\s*specs/cluster/charts/hugmesh-gateway\s*$', s, re.M):
        gw.add(p)
    m = re.search(r'^\s*mfa:\s*\n\s*enabled:\s*(\S+)\s*$', s, re.M)
    if m:
        withmfa.add(p); values.add(m.group(1))
    unsubst += s.count("{{MFA_ENABLED}}")
    # floor/freshness may be NAMED in comments (the templates explain why they
    # are not templated) — count only NON-comment lines that set or mention them
    code = "\n".join(l for l in s.splitlines() if not l.lstrip().startswith("#"))
    floor += code.count("enforcePrivilegedFloor") + code.count("freshnessWindow")
print("CONSUMERS\t%d" % len(gw))
print("WITH_MFA\t%d" % len(withmfa))
print("SETS_EQUAL\t%s" % ("yes" if gw == withmfa else "no"))
print("VALUES\t%s" % ",".join(sorted(values)))
print("UNSUBST\t%d" % unsubst)
print("FLOOR\t%d" % floor)
PY
}
cval() { awk -F'\t' -v k="$2" '$1==k{print $2}' "$1"; }

# stage the minimal repo slice the sed renderer needs (script + templates + brands)
stage_render_repo() { # <name> -> echoes dir
  local d="${WORK}/repo-$1"; rm -rf "${d}"; mkdir -p "${d}"
  cp "${GENBRAND}" "${d}/generate-brand-repos.sh"
  cp -a "${TEMPLATES}" "${d}/templates"
  mkdir -p "${d}/brands"; cp "${BRANDS}/example.conf" "${d}/brands/example.conf"
  echo "${d}"
}

mut_ok() { # <rc> <label>
  [ "$1" -eq 0 ] && return 0
  bad "($2) MUTATOR DID NOT LAND (target text absent) — control NOT exercised"
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# 1) the switch itself: declared, default-off, threaded into both make lanes
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 1) the MFA switch in the Makefile --"
grep -qE '^MFA \?=[[:space:]]*$' "${MAKEFILE}" \
  && ok "(1a) Makefile declares 'MFA ?=' with an EMPTY default (the switch ships off)" \
  || bad "(1a) Makefile does not declare 'MFA ?=' empty — the switch is gone or defaulted on"
grep -qE "^STACK_MFA_ENV := \\\$\(if \\\$\(strip \\\$\(MFA\)\), APP_MFA_ENABLED='true',\)$" "${MAKEFILE}" \
  && ok "(1b) STACK_MFA_ENV threads APP_MFA_ENABLED='true' iff MFA is set (empty expands to NOTHING)" \
  || bad "(1b) STACK_MFA_ENV definition missing/changed — compose lane switch broken"

# 1c: $(STACK_MFA_ENV) must be referenced inside the STACK_ENV := assignment
# (defining a knob nobody threads is the inert-toggle failure mode itself).
stack_env_block() { # <makefile>
  awk '/^STACK_ENV :=/{grab=1} grab{print; if ($0 !~ /\\$/) exit}' "$1"
}
stack_env_block "${MAKEFILE}" | grep '\$(STACK_MFA_ENV)' >/dev/null \
  && ok "(1c) STACK_ENV threads \$(STACK_MFA_ENV) into every compose invocation" \
  || bad "(1c) STACK_ENV does NOT reference \$(STACK_MFA_ENV) — MFA=1 would define an env nobody passes to compose"
awk '/^kind-up:/{grab=1; next} grab{print; exit}' "${MAKEFILE}" | grep "MFA='\$(MFA)'.*bootstrap-kind.sh" >/dev/null \
  && ok "(1d) kind-up threads MFA='\$(MFA)' into bootstrap-kind.sh" \
  || bad "(1d) kind-up recipe does not thread MFA into bootstrap-kind.sh — the kind lane switch is disconnected"

# ═══════════════════════════════════════════════════════════════════════════
# 2) lane A: every compose gateway service can receive the threaded env
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 2) compose lane consumers --"
why="$(compose_switch_reaches "${COMPOSE}")"
[ -z "${why}" ] \
  && ok "(2) every compose gateway service reads APP_MFA_ENABLED via \${...} interpolation (switch lands on all; set re-derived from the file)" \
  || bad "(2) compose lane: ${why}"

# ═══════════════════════════════════════════════════════════════════════════
# 3) lane B: every gateway Application the kind bootstrap applies gets the flip
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 3) kind SSO lane consumers --"
if bootstrap_audit "${BOOTSTRAP}" "${APPS_DIR}" > "${WORK}/boot.tsv" 2>"${WORK}/boot.err"; then
  why="$(bootstrap_switch_reaches "${WORK}/boot.tsv")"
  [ -z "${why}" ] \
    && ok "(3) every SSO_APPS gateway Application is patched exactly once, with a GUARDED mfa.enabled=true parameter, and the floor is untouched" \
    || bad "(3) kind lane: ${why}"
else
  bad "(3) bootstrap audit FAILED: $(tr -d '\n' <"${WORK}/boot.err" | cut -c1-300)"
fi
grep -q 'MFA="\${MFA:-}"' "${BOOTSTRAP}" && grep -qE 'MFA must be empty/0/false/off or 1/true/on' "${BOOTSTRAP}" \
  && ok "(3b) bootstrap parses MFA fail-closed (unknown spelling exits, never silently 'off')" \
  || bad "(3b) bootstrap-kind.sh lost its fail-closed MFA value parse"
grep -q 'MFA=1 needs KIND_PROFILE=sso' "${BOOTSTRAP}" \
  && ok "(3c) MFA=1 under KIND_PROFILE=core refuses loudly (no gateway is applied there — kind-honesty rule)" \
  || bad "(3c) bootstrap-kind.sh no longer refuses MFA=1 under the core profile — it would exit 0 having flipped nothing"

# ── 3d/3e/3f: lane B's VERIFIER. A flip nobody can observe is the same shipped-dark
# failure one step later: `make kind-up MFA=1` flipped the cluster and, until
# kind-e2e-mfa existed, the kind lane's only e2e target ran spec 27 — so the MFA spec
# had no kind lane at all and NEITHER kind posture was ever asserted end to end.
#
# The posture MUST come from the running cluster, not from the caller. Threading
# $(MFA) here would look equivalent and is not: kind-up is a SEPARATE invocation and
# the cluster outlives it, so `make kind-e2e-mfa MFA=1` against a cluster brought up
# without the flag would hand spec 29 the enforcement block and fail for a reason that
# has nothing to do with MFA — while `make kind-e2e-mfa` against a cluster brought up
# WITH it would run the OFF block and report a clean pass for a posture the cluster is
# not holding. The repo cannot answer it either: kind-up flips through an ArgoCD helm
# PARAMETER, so the committed chart reads false on an enforcing cluster.
recipe_of() { # <makefile> <target> — the recipe lines (TAB-prefixed) of one target
  awk -v t="$2" 'BEGIN{re="^" t ":"} $0 ~ re {grab=1; next} grab { if ($0 ~ /^\t/) {print; next} exit }' "$1"
}
KIND_MFA_RECIPE="$(recipe_of "${MAKEFILE}" kind-e2e-mfa)"
if [ -z "${KIND_MFA_RECIPE}" ]; then
  bad "(3d) no 'kind-e2e-mfa' target in the Makefile — the kind lane can flip MFA on but has no way to run the MFA spec against either posture"
  bad "(3e) …and therefore nothing derives the spec's APP_MFA_ENABLED from the live cluster"
else
  printf '%s\n' "${KIND_MFA_RECIPE}" | grep '29-mfa-privileged-floor.spec.ts' >/dev/null \
    && ok "(3d) kind-e2e-mfa runs the MFA spec (29) against the kind cluster — the flip has a verifier" \
    || bad "(3d) kind-e2e-mfa does not run specs/29-mfa-privileged-floor.spec.ts — the target exists but verifies something else"
  if ! printf '%s\n' "${KIND_MFA_RECIPE}" | grep 'kind-mfa-posture.sh' >/dev/null; then
    bad "(3e) kind-e2e-mfa does not read the posture via scripts/kind-mfa-posture.sh — it is guessing at the cluster's state"
  elif printf '%s\n' "${KIND_MFA_RECIPE}" | grep -E "APP_MFA_ENABLED=[\"']?(\\\$\(MFA\)|true|false)" >/dev/null; then
    bad "(3e) kind-e2e-mfa hands spec 29 a CALLER-supplied APP_MFA_ENABLED (\$(MFA) or a literal) — the live posture is overridden by a guess"
  else
    ok "(3e) kind-e2e-mfa derives APP_MFA_ENABLED from the RUNNING gateway pod (scripts/kind-mfa-posture.sh), not from \$(MFA) or a literal"
  fi
fi

# 3f: and that helper is FAIL-CLOSED, proven by EXECUTING it against a stub kubectl
# rather than by grepping it. "Assume off" would be the friendly behaviour and the
# wrong one — it hands spec 29 the OFF block against a cluster that is enforcing and
# reports a clean pass for the posture the cluster is NOT holding.
POSTURE_SH="${REPO}/scripts/kind-mfa-posture.sh"
# <stub-dir> <mode>: writes a fake kubectl that emits/exits as `mode` demands.
stub_kubectl() { # <dir> <empty|garbage|rc1|true|false>
  local d="$1" mode="$2"
  mkdir -p "${d}"
  { echo '#!/usr/bin/env bash'
    case "${mode}" in
      empty)   echo 'exit 0' ;;
      garbage) echo "printf 'maybe'" ;;
      rc1)     echo 'echo "Error from server (NotFound)" >&2; exit 1' ;;
      true)    echo "printf 'true'" ;;
      false)   echo "printf 'false'" ;;
    esac
  } > "${d}/kubectl"
  chmod +x "${d}/kubectl"
}
# rc + stdout of the helper with only <dir> plus the base tools on PATH
run_posture() { # <helper> <stub-dir>
  PATH="$2:/usr/bin:/bin" bash "$1" --value 2>/dev/null
}
if [ ! -f "${POSTURE_SH}" ]; then
  bad "(3f) scripts/kind-mfa-posture.sh is missing — the live-posture read has no implementation"
else
  fc_problems=""
  for mode in empty garbage rc1; do
    stub_kubectl "${WORK}/stub-${mode}" "${mode}"
    out="$(run_posture "${POSTURE_SH}" "${WORK}/stub-${mode}")"; rc=$?
    [ "${rc}" -ne 0 ] || fc_problems="${fc_problems}${mode}: exited 0 printing '${out}' instead of failing; "
  done
  for mode in true false; do
    stub_kubectl "${WORK}/stub-${mode}" "${mode}"
    out="$(run_posture "${POSTURE_SH}" "${WORK}/stub-${mode}")"; rc=$?
    { [ "${rc}" -eq 0 ] && [ "${out}" = "${mode}" ]; } \
      || fc_problems="${fc_problems}${mode}: expected rc0 + '${mode}', got rc${rc} + '${out}'; "
  done
  [ -z "${fc_problems}" ] \
    && ok "(3f) kind-mfa-posture.sh is fail-closed AND non-vacuous, EXECUTED against a stub kubectl: empty / unparseable / erroring reads all exit non-zero, true and false both round-trip" \
    || bad "(3f) kind-mfa-posture.sh posture read: ${fc_problems}"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 4) lane C: the per-domain flip, proven on REAL renderer output
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 4) tenant/per-domain lane (rendered output of generate-brand-repos.sh) --"
R="$(stage_render_repo real)"

# 4a: knob OFF (committed example profile as-is)
if render_and_classify "${R}" brands/example.conf "${WORK}/out-off" > "${WORK}/off.tsv"; then
  n="$(cval "${WORK}/off.tsv" CONSUMERS)"
  [ "${n:-0}" -ge 3 ] \
    && ok "(4a) rendered tree has ${n} gateway-chart consumers (>=3 — discovery non-vacuous)" \
    || bad "(4a) only ${n:-0} rendered Applications deploy ${CHART_REL} — consumer discovery vacuous/broken"
  [ "$(cval "${WORK}/off.tsv" SETS_EQUAL)" = "yes" ] \
    && ok "(4a) {gateway-chart apps} == {apps carrying the mfa block} — no consumer misses the flip, none gains it elsewhere" \
    || bad "(4a) consumer set != mfa-block set: a rendered gateway app misses the flip (or a non-gateway app grew one)"
  [ "$(cval "${WORK}/off.tsv" VALUES)" = "false" ] \
    && ok "(4a) knob absent -> every rendered gateway app has mfa.enabled: false (DEFAULT OFF)" \
    || bad "(4a) knob absent renders mfa.enabled values '[$(cval "${WORK}/off.tsv" VALUES)]' — default-OFF broken"
  [ "$(cval "${WORK}/off.tsv" UNSUBST)" = "0" ] \
    && ok "(4a) no unsubstituted {{MFA_ENABLED}} token in the rendered tree" \
    || bad "(4a) rendered tree still contains literal {{MFA_ENABLED}} — the renderer does not substitute the token"
  [ "$(cval "${WORK}/off.tsv" FLOOR)" = "0" ] \
    && ok "(4a) rendered tree never touches enforcePrivilegedFloor/freshnessWindow (chart defaults preserved)" \
    || bad "(4a) a rendered app overrides the floor or the freshness window — the per-domain flip must set ONLY mfa.enabled"
else
  bad "(4a) baseline render FAILED — cannot audit the tenant lane"
fi

# 4b: knob ON (MFA=1 in the brand profile)
cp "${R}/brands/example.conf" "${R}/brands/mfa-on.conf"; echo 'MFA=1' >> "${R}/brands/mfa-on.conf"
if render_and_classify "${R}" brands/mfa-on.conf "${WORK}/out-on" > "${WORK}/on.tsv"; then
  { [ "$(cval "${WORK}/on.tsv" SETS_EQUAL)" = "yes" ] && [ "$(cval "${WORK}/on.tsv" VALUES)" = "true" ] \
    && [ "$(cval "${WORK}/on.tsv" CONSUMERS)" = "$(cval "${WORK}/off.tsv" CONSUMERS)" ]; } \
    && ok "(4b) MFA=1 -> EVERY rendered gateway app flips to mfa.enabled: true (same consumer set as off)" \
    || bad "(4b) MFA=1 render: consumers=$(cval "${WORK}/on.tsv" CONSUMERS) sets_equal=$(cval "${WORK}/on.tsv" SETS_EQUAL) values=[$(cval "${WORK}/on.tsv" VALUES)] — the flip does not reach every consumer"
  [ "$(cval "${WORK}/on.tsv" FLOOR)" = "0" ] \
    && ok "(4b) MFA=1 still never touches the floor/freshness window" \
    || bad "(4b) MFA=1 render overrides floor/freshness — the flip must set ONLY mfa.enabled"
else
  bad "(4b) MFA=1 render FAILED — the documented flip does not work"
fi

# 4c: invalid knob value must FAIL the render (never silently mean 'off')
cp "${R}/brands/example.conf" "${R}/brands/mfa-bad.conf"; echo 'MFA=yes' >> "${R}/brands/mfa-bad.conf"
render_and_classify "${R}" brands/mfa-bad.conf "${WORK}/out-bad" > "${WORK}/bad.tsv" 2>/dev/null
rc=$?
[ "${rc}" -eq 2 ] \
  && ok "(4c) MFA=yes (unknown spelling) refuses to render — fail-closed, not silently off" \
  || bad "(4c) MFA=yes rendered anyway (rc=${rc}) — an operator typo silently disables enforcement"

# 4d: ambient environment must NOT flip a brand whose profile did not ask
if render_and_classify "${R}" brands/example.conf "${WORK}/out-env" MFA=1 > "${WORK}/env.tsv"; then
  [ "$(cval "${WORK}/env.tsv" VALUES)" = "false" ] \
    && ok "(4d) exported MFA=1 with a profile that does not set it renders false — the knob is conf-only (root-cron reconcile safety)" \
    || bad "(4d) AMBIENT ENV LEAK: exported MFA=1 flipped a brand whose profile never set it (values=[$(cval "${WORK}/env.tsv" VALUES)])"
else
  bad "(4d) ambient-env render failed to run — control not exercised"
fi

# 4e: the handlebars twin stays in sync (statically here; scripts/parity-gate.sh
# byte-compares the two engines' output wherever node is available)
if grep -q 'MFA=""' "${REPO}/scripts/tooling/render-handlebars.sh" \
   && grep -q 'MFA_ENABLED="true"' "${REPO}/scripts/tooling/render-handlebars.sh" \
   && grep -q "'MFA_ENABLED'," "${REPO}/scripts/tooling/render-handlebars.js" \
   && grep -q '"MFA_ENABLED"' "${REPO}/scripts/tooling/tokens.json"; then
  ok "(4e) handlebars engine derives+exports MFA_ENABLED and allowlists the token (parity with the sed engine; byte-proof in scripts/parity-gate.sh)"
else
  bad "(4e) the handlebars engine / token allowlist lost MFA_ENABLED — the two renderers diverge and parity-gate.sh (or the render) will fail"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 5) posture the flip could regress (heavy pins live in test-gateway-mfa-env.sh)
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 5) default-OFF posture the flip touches --"
python3 - "${CHART_VALUES}" <<'PY' >"${WORK}/chart.txt" 2>&1
import sys, yaml
v = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
print("enabled=%r" % ((v.get("mfa") or {}).get("enabled", "MISSING"),))
PY
grep -qx 'enabled=False' "${WORK}/chart.txt" \
  && ok "(5a) shared chart mfa.enabled is still boolean false (the cluster ships dark; flips are per-run/per-brand)" \
  || bad "(5a) chart values mfa.enabled changed: $(cat "${WORK}/chart.txt")"

brand_mfa_on_hits() { # <brands-dir> — committed profiles that ship the flip ON
  grep -HnE '^[[:space:]]*MFA=' "$1"/*.conf 2>/dev/null \
    | grep -vE "MFA=[\"']?(0|false|off)?[\"']?[[:space:]]*(#.*)?$" || true
}
hits="$(brand_mfa_on_hits "${BRANDS}")"
[ -z "${hits}" ] \
  && ok "(5b) no committed brand profile ships MFA on (the per-domain flip is an operator edit, never a repo default)" \
  || bad "(5b) a COMMITTED brand profile ships the MFA flip on: ${hits}"

# ═══════════════════════════════════════════════════════════════════════════
# 6) negative controls (staged copies; each mutator proves it landed)
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 6) negative controls: every wiring assertion must bite --"

# 6a: one gateway template stripped of its mfa block -> (4a/4b) set-equality fails
M="$(stage_render_repo mut-tpl)"
python3 - "${M}/templates/apps/22-gateway-superadmin.yaml.hbs" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
blk = "        mfa:\n          enabled: {{MFA_ENABLED}}\n"
if blk not in s: raise SystemExit("6a: mfa block not found in the superadmin template")
open(p, "w", encoding="utf-8").write(s.replace(blk, "", 1))
PY
if mut_ok $? 6a; then
  if render_and_classify "${M}" brands/example.conf "${WORK}/out-6a" > "${WORK}/m6a.tsv"; then
    [ "$(cval "${WORK}/m6a.tsv" SETS_EQUAL)" = "no" ] \
      && ok "(6a) consumer-set check BITES: a gateway template without the mfa block fails set-equality" \
      || bad "(6a) VACUOUS: a gateway app with no mfa block still passed the consumer-set check"
  else
    bad "(6a) mutant render failed to run — control not exercised"
  fi
fi

# 6b: renderer loses the {{MFA_ENABLED}} substitution -> (4a) unsubst / (4b) values fail
M="$(stage_render_repo mut-sed)"
python3 - "${M}/generate-brand-repos.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
row = '    -e "s|{{MFA_ENABLED}}|$(_sed_rep_escape "${MFA_ENABLED}")|g" \\\n'
if row not in s: raise SystemExit("6b: the MFA_ENABLED sed line not found")
open(p, "w", encoding="utf-8").write(s.replace(row, "", 1))
PY
if mut_ok $? 6b; then
  cp "${M}/brands/example.conf" "${M}/brands/mfa-on.conf"; echo 'MFA=1' >> "${M}/brands/mfa-on.conf"
  if render_and_classify "${M}" brands/mfa-on.conf "${WORK}/out-6b" > "${WORK}/m6b.tsv"; then
    { [ "$(cval "${WORK}/m6b.tsv" UNSUBST)" != "0" ] || [ "$(cval "${WORK}/m6b.tsv" VALUES)" != "true" ]; } \
      && ok "(6b) substitution check BITES: a renderer that drops the token leaves {{MFA_ENABLED}} and fails" \
      || bad "(6b) VACUOUS: renderer without the substitution still passed"
  else
    bad "(6b) mutant render failed to run — control not exercised"
  fi
fi

# 6c: Makefile defines the knob but never threads it -> (1c) fails
sed 's|$(STACK_MFA_FLOOR_ENV)$(STACK_MFA_ENV)|$(STACK_MFA_FLOOR_ENV)|' "${MAKEFILE}" > "${WORK}/Makefile.6c"
if grep -q '\$(STACK_MFA_ENV)' "${MAKEFILE}" && ! stack_env_block "${WORK}/Makefile.6c" | grep '\$(STACK_MFA_ENV)' >/dev/null; then
  ok "(6c) thread check BITES: STACK_ENV without \$(STACK_MFA_ENV) fails (the defined-but-unthreaded inert toggle)"
else
  bad "(6c) VACUOUS or mutator did not land: STACK_ENV check passed without the reference"
fi

# 6d: bootstrap without the mfa.enabled append -> (3) fails
sed '/GW_FE_PARAMS="\${GW_FE_PARAMS},{\\"name\\":\\"mfa.enabled\\"/d' "${BOOTSTRAP}" > "${WORK}/boot.6d.sh"
if ! grep -q 'mfa.enabled' <(grep -v '^\s*#' "${WORK}/boot.6d.sh" | grep 'GW_FE_PARAMS='); then
  bootstrap_audit "${WORK}/boot.6d.sh" "${APPS_DIR}" > "${WORK}/m6d.tsv" 2>/dev/null
  bootstrap_switch_reaches "${WORK}/m6d.tsv" >/dev/null \
    && bad "(6d) VACUOUS: bootstrap without the mfa append still passed the kind-lane check" \
    || ok "(6d) kind-lane check BITES: dropping the mfa.enabled append fails it"
else
  bad "(6d) MUTATOR DID NOT LAND (append line still present)"
fi

# 6e: a SECOND merge patch of the same Application -> (3) exactly-once fails
python3 - "${BOOTSTRAP}" "${WORK}/boot.6e.sh" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
needle = 'kubectl -n "${ARGOCD_NS}" patch application hugmesh-gateway-fe --type merge -p \\'
if needle not in s: raise SystemExit("6e: patch command not found")
extra = ('\n  kubectl -n "${ARGOCD_NS}" patch application hugmesh-gateway-fe --type merge -p \\\n'
         '    \'{"spec":{"source":{"helm":{"parameters":[{"name":"mfa.enabled","value":"true"}]}}}}\' >/dev/null\n')
i = s.index(needle)
j = s.index("\n", s.index(">/dev/null", i))
open(dst, "w", encoding="utf-8").write(s[:j] + extra + s[j:])
PY
if mut_ok $? 6e; then
  bootstrap_audit "${WORK}/boot.6e.sh" "${APPS_DIR}" > "${WORK}/m6e.tsv" 2>/dev/null
  bootstrap_switch_reaches "${WORK}/m6e.tsv" >/dev/null \
    && bad "(6e) VACUOUS: a second merge patch (which would CLOBBER helm.parameters) still passed" \
    || ok "(6e) exactly-once check BITES: a second patch of the same Application fails it"
fi

# 6f: the append moved OUTSIDE the MFA guard (kind default-ON) -> (3) fails
python3 - "${BOOTSTRAP}" "${WORK}/boot.6f.sh" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines(keepends=True)
app_i = guard_i = fi_i = None
for i, l in enumerate(lines):
    if re.match(r'^\s*if\s+\[\s+-n\s+"\$\{MFA\}"\s+\]', l) and guard_i is None and app_i is None:
        # find the guard that contains the append
        for j in range(i + 1, len(lines)):
            if 'mfa.enabled' in lines[j] and 'GW_FE_PARAMS=' in lines[j]:
                app_i, guard_i = j, i
                for k in range(j + 1, len(lines)):
                    if re.match(r'^\s*fi\b', lines[k]): fi_i = k; break
                break
if app_i is None or fi_i is None: raise SystemExit("6f: guarded append not found")
append = lines[app_i]
del lines[app_i]
# fi_i shifted by one after the delete
lines.insert(fi_i, append)
open(dst, "w", encoding="utf-8").writelines(lines)
PY
if mut_ok $? 6f; then
  bootstrap_audit "${WORK}/boot.6f.sh" "${APPS_DIR}" > "${WORK}/m6f.tsv" 2>/dev/null
  bootstrap_switch_reaches "${WORK}/m6f.tsv" >/dev/null \
    && bad "(6f) VACUOUS: an UNGUARDED mfa.enabled append (kind default-ON) still passed" \
    || ok "(6f) guard check BITES: moving the append outside the MFA guard fails it"
fi

# 6g: a compose gateway hardcodes APP_MFA_ENABLED -> (2) fails
python3 - "${COMPOSE}" "${WORK}/compose.6g.yaml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
old = "APP_MFA_ENABLED: ${APP_MFA_ENABLED:-true}"
if old not in s: raise SystemExit("6g: interpolated APP_MFA_ENABLED not found")
open(dst, "w", encoding="utf-8").write(s.replace(old, 'APP_MFA_ENABLED: "true"', 1))
PY
if mut_ok $? 6g; then
  compose_switch_reaches "${WORK}/compose.6g.yaml" >/dev/null \
    && bad "(6g) VACUOUS: a hardcoded compose APP_MFA_ENABLED (switch cannot reach it) still passed" \
    || ok "(6g) compose interpolation check BITES: hardcoding the env on one gateway fails it"
fi

# 6h: a committed brand profile shipping MFA=1 -> (5b) fails
mkdir -p "${WORK}/brands-6h"; cp "${BRANDS}"/*.conf "${WORK}/brands-6h/" 2>/dev/null
printf '\nMFA=1\n' >> "${WORK}/brands-6h/example.conf"
hits="$(brand_mfa_on_hits "${WORK}/brands-6h")"
[ -n "${hits}" ] \
  && ok "(6h) committed-profile check BITES: a brands/*.conf with MFA=1 is caught" \
  || bad "(6h) VACUOUS: a committed profile with MFA=1 was not caught"

# 6i: the verifier target deleted -> (3d) fails
sed '/^kind-e2e-mfa:/,/^$/d' "${MAKEFILE}" > "${WORK}/Makefile.6i"
if [ -n "$(recipe_of "${MAKEFILE}" kind-e2e-mfa)" ] && [ -z "$(recipe_of "${WORK}/Makefile.6i" kind-e2e-mfa)" ]; then
  ok "(6i) verifier check BITES: a Makefile with no kind-e2e-mfa target leaves the kind flip unobservable and fails (3d)"
else
  bad "(6i) MUTATOR DID NOT LAND: kind-e2e-mfa still extractable from the mutant (or absent from the real Makefile)"
fi

# 6j: the posture threaded from the CALLER instead of the cluster -> (3e) fails.
# The subtle one, and the reason (3e) is written as a NEGATIVE match: this mutant
# still calls the helper, so a check that only asserted "the helper is referenced"
# would pass it while the caller's $(MFA) silently wins the assignment.
sed 's|APP_MFA_ENABLED="$${posture}"|APP_MFA_ENABLED="$(MFA)"|' "${MAKEFILE}" > "${WORK}/Makefile.6j"
mut_recipe="$(recipe_of "${WORK}/Makefile.6j" kind-e2e-mfa)"
if printf '%s\n' "${mut_recipe}" | grep 'APP_MFA_ENABLED="$(MFA)"' >/dev/null; then
  { printf '%s\n' "${mut_recipe}" | grep 'kind-mfa-posture.sh' >/dev/null; } \
    && { printf '%s\n' "${mut_recipe}" | grep -E "APP_MFA_ENABLED=[\"']?(\\\$\(MFA\)|true|false)" >/dev/null; } \
    && ok "(6j) live-posture check BITES: threading \$(MFA) into the spec's env fails (3e) even though the helper is still called" \
    || bad "(6j) VACUOUS: a caller-supplied APP_MFA_ENABLED passed the live-posture check"
else
  bad "(6j) MUTATOR DID NOT LAND (the recipe's APP_MFA_ENABLED assignment was not rewritten)"
fi

# 6k: a posture helper that DEFAULTS instead of dying -> (3f) fails
if [ -f "${POSTURE_SH}" ]; then
  python3 - "${POSTURE_SH}" "${WORK}/posture.6k.sh" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
# the unreadable-value catch-all becomes a silent default…
s2 = re.sub(r'\n\s*\*\) die "deploy/', '\n  *) posture=false ;;\n  __never__) die "deploy/', s, count=1)
if s2 == s: raise SystemExit("6k: the case catch-all was not found")
# …and an empty read falls through to it instead of dying.
s3 = s2.replace('[ -n "${raw}" ] \\\n', '[ -n "${raw}" ] || raw=nonsense\n[ -n "${raw}" ] \\\n', 1)
if s3 == s2: raise SystemExit("6k: the empty-read guard was not found")
open(dst, "w", encoding="utf-8").write(s3)
PY
  if mut_ok $? 6k; then
    stub_kubectl "${WORK}/stub-6k" empty
    out="$(run_posture "${WORK}/posture.6k.sh" "${WORK}/stub-6k")"; rc=$?
    { [ "${rc}" -eq 0 ] && [ "${out}" = "false" ]; } \
      && ok "(6k) fail-closed check BITES: a helper that answers 'false' for an unreadable cluster passes ITSELF and fails (3f)'s empty-read case" \
      || bad "(6k) VACUOUS or mutator inert: the defaulting helper did not answer 'false' on an empty read (rc${rc} '${out}')"
  fi
else
  bad "(6k) control not exercised: scripts/kind-mfa-posture.sh is missing"
fi

# ── tally guard ───────────────────────────────────────────────────────────────
MIN_CHECKS=30
TOTAL=$((P + F))
echo ""
if [ "${TOTAL}" -lt "${MIN_CHECKS}" ]; then
  echo "  FAIL only ${TOTAL} checks ran (floor ${MIN_CHECKS}) — assertions silently stopped counting"
  F=$((F + 1))
fi
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
