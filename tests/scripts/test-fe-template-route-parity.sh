#!/usr/bin/env bash
# test-fe-template-route-parity.sh — the per-brand fe-gateway route table must
# match the primary one (hugmesh-generator#559).
#
# WHY. templates/apps/20-gateway-fe.yaml.hbs is the per-brand twin of
# specs/cluster/apps/20-gateway-fe.yaml, "kept in sync by hand". By hand it was
# not: the brand table had drifted to 17 routes against the primary's 40. It had
# no SPA deep-link route, no wiki/mesh/character-forge BFFs, no /bff/login,
# /bff/session, /bff/sessionOut or password-reset routes, so every one of those
# fell through to the /bff/** admin-bff catch-all. It also lacked BOTH carve-outs
# the primary carries above a subtree route (/bff/register/complete above
# /bff/register/**, /bff/me/appeal above /bff/me/**), and it still served the
# API docs remote at /apidocs/** after the primary and route-access moved to
# /api-docs/**. Every fix on the primary table had stopped at the primary table.
#
# WHAT. Renders brands/example.conf with BOTH engines (generate-brand-repos.sh,
# the default sed engine, and scripts/tooling/render-handlebars.sh), then hands
# the rendered apps/20-gateway-fe.yaml from each to fe_template_route_parity.py,
# which compares every route (id, path, predicates, uri, filters, order) with the
# primary table normalized to the brand, honouring the checked exclusion list
# tests/scripts/fe-template-route-exclusions.tsv, and refuses any route that an
# earlier plain route shadows.
#
# NEGATIVE CONTROLS (staged copies under mktemp; the repo tree is never mutated):
# a deleted route, each carve-out moved below its catch-all, a path drift, an
# unlisted extra route, and three bad exclusion lists (stale, unknown id, no
# reason) must each turn the guard RED, and a route that is both deleted and
# excluded must turn it GREEN. Every mutator proves it landed.
#
# Tools: bash >= 4, python3 + PyYAML, node + scripts/tooling/node_modules
# (`npm ci --prefix scripts/tooling`). A missing tool exits 2 — never a skip,
# because a guard that renders nothing compares nothing.
set -uo pipefail

_self="${BASH_SOURCE[0]}"; _selfdir="${_self%/*}"
[ "${_selfdir}" != "${_self}" ] || _selfdir="."
REPO="$(cd "${_selfdir}/../.." && pwd)"

PRIMARY="${REPO}/specs/cluster/apps/20-gateway-fe.yaml"
TEMPLATE="${REPO}/templates/apps/20-gateway-fe.yaml.hbs"
EXCLUSIONS="${REPO}/tests/scripts/fe-template-route-exclusions.tsv"
CHECK="${REPO}/tests/scripts/fe_template_route_parity.py"
CONF_REL="brands/example.conf"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# ── preflight ────────────────────────────────────────────────────────────────
[ -n "${BASH_VERSION:-}" ] && [ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "  FAIL bash >= 4 required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 missing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML missing (pip install pyyaml)"; exit 2; }
command -v node >/dev/null 2>&1 || { echo "  FAIL node missing — the handlebars engine cannot render"; exit 2; }
[ -d "${REPO}/scripts/tooling/node_modules/handlebars" ] || {
  echo "  FAIL handlebars not installed — run: npm ci --prefix scripts/tooling"; exit 2; }
for f in "${PRIMARY}" "${TEMPLATE}" "${EXCLUSIONS}" "${CHECK}" "${REPO}/${CONF_REL}" \
         "${REPO}/generate-brand-repos.sh" "${REPO}/scripts/tooling/render-handlebars.sh"; do
  [ -e "${f}" ] || { echo "  FAIL missing input ${f}"; exit 2; }
done

BRAND="$(set +u; source "${REPO}/${CONF_REL}" >/dev/null 2>&1; printf '%s' "${BRAND:-}")"
DOMAIN="$(set +u; source "${REPO}/${CONF_REL}" >/dev/null 2>&1; printf '%s' "${CLUSTER_DOMAIN:-}")"
[ -n "${BRAND}" ] && [ -n "${DOMAIN}" ] || { echo "  FAIL ${CONF_REL} yields no BRAND/CLUSTER_DOMAIN"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== fe-gateway brand template route parity (#559; brand=${BRAND}, domain=${DOMAIN}) =="

# Stage the repo slice both engines need: the sed script, the templates, the brand
# profile and the render tooling (node_modules linked, not copied).
stage() { # <name> -> echoes dir
  local d="${WORK}/repo-$1"
  rm -rf "${d}"; mkdir -p "${d}/brands" "${d}/scripts/tooling"
  cp "${REPO}/generate-brand-repos.sh" "${d}/generate-brand-repos.sh"
  cp -a "${REPO}/templates" "${d}/templates"
  cp "${REPO}/${CONF_REL}" "${d}/${CONF_REL}"
  find "${REPO}/scripts/tooling" -maxdepth 1 -type f -exec cp {} "${d}/scripts/tooling/" \;
  ln -s "${REPO}/scripts/tooling/node_modules" "${d}/scripts/tooling/node_modules"
  echo "${d}"
}

# Render the staged tree with both engines and run the comparator. Prints the
# comparator's output into <log>; returns its rc (2 when a render failed).
check_stage() { # <stage> <exclusions> <log>
  local d="$1" ex="$2" log="$3" out
  out="${d}/out"; rm -rf "${out}"; mkdir -p "${out}/sed" "${out}/hbs"
  if ! ( cd "${d}" && ./generate-brand-repos.sh "${CONF_REL}" --out-dir "${out}/sed" ) >"${log}" 2>&1; then
    echo "  RENDER-FAIL sed engine" >>"${log}"; return 2
  fi
  if ! ( cd "${d}" && scripts/tooling/render-handlebars.sh "${CONF_REL}" --out-dir "${out}/hbs" ) >>"${log}" 2>&1; then
    echo "  RENDER-FAIL handlebars engine" >>"${log}"; return 2
  fi
  python3 "${CHECK}" --primary "${PRIMARY}" --exclusions "${ex}" --brand "${BRAND}" --domain "${DOMAIN}" \
    "${out}/sed/${BRAND}-gitops/apps/20-gateway-fe.yaml" \
    "${out}/hbs/${BRAND}-gitops/apps/20-gateway-fe.yaml" >"${log}" 2>&1
}

# Template mutators (python, exact text; exit 3 when the target is absent so a
# no-op mutation can never pass as a bitten control).
mutate() { # <file> <op> [args...]
  python3 - "$@" <<'PY'
import sys
path, op, args = sys.argv[1], sys.argv[2], sys.argv[3:]
lines = open(path, encoding="utf-8").read().split("\n")
IND = "          - id: "
def block(rid):
    start = next((i for i, l in enumerate(lines) if l == IND + rid), None)
    if start is None:
        sys.exit(3)
    end = start + 1
    while end < len(lines) and lines[end].startswith("            "):
        end += 1
    return start, end
if op == "delete":
    s, e = block(args[0]); del lines[s:e]
elif op == "move-after":           # move route args[0] to just after route args[1]
    s, e = block(args[0]); chunk = lines[s:e]; del lines[s:e]
    s2, e2 = block(args[1]); lines[e2:e2] = chunk
elif op == "replace":              # exact one-occurrence text replacement
    text = "\n".join(lines)
    if text.count(args[0]) != 1:
        sys.exit(3)
    lines = text.replace(args[0], args[1]).split("\n")
elif op == "insert-before":        # insert raw route lines before route args[0]
    s, _ = block(args[0]); lines[s:s] = args[1].split("\n")
else:
    sys.exit(4)
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}

mut_ok() { # <rc> <label>
  [ "$1" -eq 0 ] && return 0
  bad "($2) MUTATOR DID NOT LAND (rc=$1, target text absent) — control NOT exercised"
  return 1
}

# expect_red <label> <stage> <exclusions> <must-contain>
expect_red() {
  local label="$1" d="$2" ex="$3" needle="$4" log rc
  log="${WORK}/${label}.log"
  check_stage "${d}" "${ex}" "${log}"; rc=$?
  if [ "${rc}" -eq 1 ] && grep -F -- "${needle}" "${log}" >/dev/null; then
    ok "(${label}) guard goes RED and names it: $(grep -F -- "${needle}" "${log}" | head -1 | sed 's/^ *//')"
  else
    bad "(${label}) expected rc=1 naming '${needle}', got rc=${rc}:"
    sed 's/^/        /' "${log}" | head -15
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# 1) the real tree
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 1) the committed template, both engines, against the primary table --"
R="$(stage real)"
check_stage "${R}" "${EXCLUSIONS}" "${WORK}/real.log"; rc=$?
sed 's/^/    /' "${WORK}/real.log"
if [ "${rc}" -eq 0 ]; then
  ok "rendered brand table == primary table (minus listed exclusions), in order, both engines"
else
  bad "rendered brand table diverges from the primary table (rc=${rc}) — see above"
fi

# The carve-outs by name, so a reader of the log sees the two the issue named.
python3 - "${R}/out/sed/${BRAND}-gitops/apps/20-gateway-fe.yaml" "${BRAND}" >"${WORK}/carve.out" 2>&1 <<'PY'
import sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
ids = [r["id"] for r in yaml.safe_load(app["spec"]["source"]["helm"]["values"])["routes"]]
b = sys.argv[2]
for carve, catch in (("admin-bff-api-register-complete", "user-bff-api-register"),
                     ("admin-bff-api-me-appeal", "user-bff-api-me"),
                     ("user-bff-api-me", "admin-bff-api")):
    c, k = f"{b}-{carve}", f"{b}-{catch}"
    if c in ids and k in ids and ids.index(c) < ids.index(k):
        print(f"OK {c} (#{ids.index(c)}) above {k} (#{ids.index(k)})")
    else:
        print(f"BAD {c} not declared above {k}")
PY
while IFS= read -r line; do
  case "${line}" in
    OK*) ok "carve-out order: ${line#OK }" ;;
    *)   bad "carve-out order: ${line#BAD }" ;;
  esac
done <"${WORK}/carve.out"

# ═══════════════════════════════════════════════════════════════════════════
# 2) negative controls — each must turn the guard RED
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 2) negative controls (staged copies; each mutator proves it landed) --"
TPL_REL="templates/apps/20-gateway-fe.yaml.hbs"

M="$(stage del)"
mutate "${M}/${TPL_REL}" delete "{{BRAND}}-user-bff-api-sessionout"; mut_ok $? del \
  && expect_red del "${M}" "${EXCLUSIONS}" "route '${BRAND}-user-bff-api-sessionout' is in the primary table but MISSING"

M="$(stage appeal-below)"
mutate "${M}/${TPL_REL}" move-after "{{BRAND}}-admin-bff-api-me-appeal" "{{BRAND}}-user-bff-api-me"; mut_ok $? appeal-below \
  && expect_red appeal-below "${M}" "${EXCLUSIONS}" "route '${BRAND}-admin-bff-api-me-appeal' (/bff/me/appeal) is SHADOWED"

M="$(stage complete-below)"
mutate "${M}/${TPL_REL}" move-after "{{BRAND}}-admin-bff-api-register-complete" "{{BRAND}}-user-bff-api-register"; mut_ok $? complete-below \
  && expect_red complete-below "${M}" "${EXCLUSIONS}" "route '${BRAND}-admin-bff-api-register-complete' (/bff/register/complete) is SHADOWED"

M="$(stage catchall-up)"
mutate "${M}/${TPL_REL}" move-after "{{BRAND}}-admin-bff-api" "{{BRAND}}-user-bff-api"; mut_ok $? catchall-up \
  && expect_red catchall-up "${M}" "${EXCLUSIONS}" "ORDER differs from the primary"

M="$(stage path-drift)"
mutate "${M}/${TPL_REL}" replace "path: /api-docs/**" "path: /apidocs/**"; mut_ok $? path-drift \
  && expect_red path-drift "${M}" "${EXCLUSIONS}" "route 'api-docs' field 'path'"

M="$(stage extra)"
mutate "${M}/${TPL_REL}" insert-before "frontend-host" "$(printf '%s\n%s\n%s' \
  '          - id: brand-only-extra' \
  '            uri: http://{{BRAND}}-extra.{{BRAND}}-frontend.svc.cluster.local:80' \
  '            path: /extra/**')"; mut_ok $? extra \
  && expect_red extra "${M}" "${EXCLUSIONS}" "route 'brand-only-extra' is not in the primary table"

# exclusion-list controls run against the UNMUTATED template
X="$(stage excl)"
printf 'hugmesh-user-bff-api-sessionout\tpretend primary-only\n' >"${WORK}/ex-stale.tsv"
expect_red excl-stale "${X}" "${WORK}/ex-stale.tsv" "excluded route 'hugmesh-user-bff-api-sessionout' is still rendered (stale exclusion)"
printf 'no-such-route\tnot on the primary table\n' >"${WORK}/ex-unknown.tsv"
expect_red excl-unknown "${X}" "${WORK}/ex-unknown.tsv" "names 'no-such-route', which is not a route in the primary table"
M="$(stage excl-noreason)"
mutate "${M}/${TPL_REL}" delete "{{BRAND}}-user-bff-api-sessionout"; mut_ok $? excl-noreason \
  && { printf 'hugmesh-user-bff-api-sessionout\t\n' >"${WORK}/ex-noreason.tsv"
       expect_red excl-noreason "${M}" "${WORK}/ex-noreason.tsv" "(hugmesh-user-bff-api-sessionout) carries no reason"; }

# ═══════════════════════════════════════════════════════════════════════════
# 3) positive control — the exclusion mechanism actually excludes
# ═══════════════════════════════════════════════════════════════════════════
echo "-- 3) positive control: a deleted AND listed route passes --"
M="$(stage excl-ok)"
mutate "${M}/${TPL_REL}" delete "{{BRAND}}-user-bff-api-sessionout"; mut_ok $? excl-ok && {
  printf '# header\nhugmesh-user-bff-api-sessionout\tcontrol: listed with a reason\n' >"${WORK}/ex-ok.tsv"
  check_stage "${M}" "${WORK}/ex-ok.tsv" "${WORK}/excl-ok.log"; rc=$?
  if [ "${rc}" -eq 0 ]; then ok "(excl-ok) a route deleted from the template AND listed with a reason is accepted"
  else bad "(excl-ok) expected rc=0, got rc=${rc}:"; sed 's/^/        /' "${WORK}/excl-ok.log" | head -10; fi
}

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] && [ "${P}" -gt 0 ]
