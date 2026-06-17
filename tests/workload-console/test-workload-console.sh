#!/usr/bin/env bash
# test-workload-console.sh — unit test for the WORKLOAD CONSOLE generator wiring:
#   * the two-SA RBAC manifests least-privilege invariants (the security acceptance bar);
#   * the optional-services.yaml registration (default off);
#   * the gate (build-rpi5-stage4.sh): NOT selected => prune the RBAC app + manifests +
#     route-access rows; selected => keep them;
#   * the deploy-provenance Kyverno policy requires digest-pinned (@sha256:) images;
#   * the route-access rows + the ArgoCD Application exist with the right shape.
#
# Proves the security invariants WITHOUT a full cross-build, by sourcing the REAL helper
# functions from the builder + reproducing the workloadConsole gate branch against a sandbox.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
REG="${REPO}/specs/cluster/optional-services.yaml"
RBAC="${REPO}/specs/cluster/manifests/workload-console-rbac"
APP="${REPO}/specs/cluster/apps/14-workload-console-rbac.yaml"
SCHEMA="${REPO}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

extract_fn() { awk "/^$1\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "${BUILDER}"; }
eval "$(extract_fn _opt_selected)"
eval "$(extract_fn _opt_drop_rows)"
type _opt_selected >/dev/null 2>&1 || { echo "  FAIL could not extract _opt_selected"; exit 1; }
type _opt_drop_rows >/dev/null 2>&1 || { echo "  FAIL could not extract _opt_drop_rows"; exit 1; }

echo "== workload-console generator unit test =="

# ── 1. Registry: workloadConsole present + default off ──────────────────────────
if command -v python3 >/dev/null; then
  python3 - "${REG}" <<'PY' && ok "registered in optional-services.yaml as default: off" || bad "workloadConsole not registered default:off"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
svcs = {s["slug"]: s for s in d["spec"]["services"]}
wc = svcs.get("workloadConsole")
assert wc is not None, "workloadConsole slug missing"
assert wc["default"] in (False, "off"), f"default not off: {wc['default']!r}"
assert wc.get("namespace") == "snapdragon-backend", f"bad ns: {wc.get('namespace')}"
assert "apps/14-workload-console-rbac.yaml" in wc.get("apps", []), "app missing"
rows = wc.get("routeAccessRows", [])
pats = {r["urlPattern"] for r in rows}
assert "/bff/superadmin/workloads/**" in pats, "superadmin route row missing"
assert "/bff/admin/workloads/**" in pats, "admin route row missing"
assert wc.get("federationModule") is None, "must be a HIDDEN module, not an auto-mounted federationModule"
assert wc.get("hiddenModule") is not None, "hiddenModule missing"
sys.exit(0)
PY
else
  echo "  SKIP registry assertion (no python3)"
fi

# ── 2. RBAC least-privilege invariants (the security acceptance bar) ────────────
# Parsed-YAML checks ONLY (never raw grep — comments mention "NO secrets" etc, which a
# grep would false-positive on; the rules themselves are the source of truth).
[ -d "${RBAC}" ] || bad "RBAC manifest dir missing"
BIND="${RBAC}/bindings.yaml"
CLUSTER="${RBAC}/clusterread.yaml"

if command -v python3 >/dev/null; then
  python3 - "${RBAC}" <<'PY'
import sys, os, glob, yaml
rbac = sys.argv[1]
APP_TIER = {"snapdragon-backend","snapdragon-frontend","snapdragon-forum",
            "snapdragon-games","snapdragon-games-instances","snapdragon-tube","snapdragon-owncast"}
INFRA = {"snapdragon-pki","snapdragon-policy","vault","devops","observability","kube-system"}
P=F=0
def ok(m):
    global P; P+=1; print("  PASS "+m)
def bad(m):
    global F; F+=1; print("  FAIL "+m)

docs=[]
for f in sorted(glob.glob(os.path.join(rbac,"*.yaml"))):
    docs += [d for d in yaml.safe_load_all(open(f)) if d]

def rules_of(kind, name_pred):
    out=[]
    for d in docs:
        if d.get("kind")==kind and name_pred(d.get("metadata",{}).get("name","")):
            out += d.get("rules",[]) or []
    return out

def flat(rules):
    res=set(); verbs=set()
    for r in rules:
        for x in (r.get("resources") or []): res.add(x)
        for v in (r.get("verbs") or []): verbs.add(v)
    return res,verbs

# 2a. read Roles + the cluster-read ClusterRole: NO secrets/configmaps/exec/portforward;
#     NO delete/create/update/patch.
read_rules = rules_of("Role", lambda n: n=="workload-console-read") \
           + rules_of("ClusterRole", lambda n: n=="workload-console-superadmin-read")
res,verbs = flat(read_rules)
for forbidden in ("secrets","configmaps","pods/exec","pods/portforward"):
    (bad if forbidden in res else ok)(f"read/cluster-read does {'' if forbidden in res else 'NOT '}grant {forbidden}")
for v in ("delete","create","update","patch"):
    (bad if v in verbs else ok)(f"read/cluster-read does {'' if v in verbs else 'NOT '}grant verb {v}")

# 2b. mutate Roles: ONLY pods (delete) + pods/exec + pods/portforward; NO secrets/configmaps;
#     NO write on apps (deployment patch).
mut_rules = rules_of("Role", lambda n: n=="workload-console-mutate")
mres,mverbs = flat(mut_rules)
(ok if "pods/exec" in mres else bad)("mutate has pods/exec" if "pods/exec" in mres else "mutate missing pods/exec")
(ok if "pods/portforward" in mres else bad)("mutate has pods/portforward" if "pods/portforward" in mres else "mutate missing pods/portforward")
(ok if "delete" in mverbs else bad)("mutate has delete" if "delete" in mverbs else "mutate missing delete")
for forbidden in ("secrets","configmaps","deployments"):
    (bad if forbidden in mres else ok)(f"mutate does {'' if forbidden in mres else 'NOT '}grant {forbidden}")

# 2c. every Role/RoleBinding is in an app-tier ns; nothing in an infra tier.
infra_hit=False
for d in docs:
    if d.get("kind") in ("Role","RoleBinding"):
        ns=d.get("metadata",{}).get("namespace")
        if ns in INFRA: infra_hit=True; bad(f"{d['kind']} in INFRA ns {ns}")
        elif ns not in APP_TIER: bad(f"{d['kind']} in non-app-tier ns {ns}")
    for s in (d.get("subjects") or []):
        if s.get("namespace") in INFRA: infra_hit=True; bad(f"subject in INFRA ns {s.get('namespace')}")
if not infra_hit: ok("no Role/RoleBinding/subject in any infra tier")

print(f"__SUB {P} {F}")
sys.exit(1 if F else 0)
PY
  rc=$?
  # fold the python sub-results into the parent counters
  if [ "${rc}" -eq 0 ]; then ok "RBAC least-privilege invariants (parsed YAML)"; else bad "RBAC least-privilege invariants (parsed YAML) — see FAILs above"; fi
else
  echo "  SKIP RBAC parsed-YAML checks (no python3)"
fi

# ── 3. Superadmin path uses a ClusterRole; admin path does NOT ──────────────────
grep -q "kind: ClusterRole" "${CLUSTER}" && ok "superadmin path has a cluster-read ClusterRole" || bad "superadmin ClusterRole missing"
if grep -q "kind: ClusterRole" "${RBAC}/read-role.yaml" "${BIND}" 2>/dev/null; then
  bad "the ADMIN read path must NOT use a ClusterRole"
else
  ok "the ADMIN read path uses per-namespace Roles only (no ClusterRole)"
fi

# ── 4. Deploy-provenance Kyverno policy requires digest-pinned images ───────────
POLICY="${RBAC}/deploy-provenance-policy.yaml"
grep -q "ClusterPolicy" "${POLICY}" && ok "deploy-provenance ClusterPolicy exists" || bad "deploy-provenance policy missing"
grep -q "sha256" "${POLICY}" && ok "deploy-provenance policy enforces @sha256: digest" || bad "deploy-provenance policy does not require a digest"
grep -q "Enforce" "${POLICY}" && ok "deploy-provenance policy is Enforce" || bad "deploy-provenance policy is not Enforce"

# ── 5. ArgoCD Application shape ─────────────────────────────────────────────────
[ -f "${APP}" ] && ok "ArgoCD Application apps/14-workload-console-rbac.yaml exists" || bad "ArgoCD Application missing"
grep -q "prune: true" "${APP}" && grep -q "selfHeal: true" "${APP}" && ok "Application has prune+selfHeal" || bad "Application missing prune/selfHeal"
grep -q "workload-console-rbac" "${APP}" && ok "Application sources the RBAC manifest path" || bad "Application path wrong"

# ── 6. Route-access rows present in the canonical seed ──────────────────────────
# Match the INSERT data row (a leading "(" + the gateway literal), NOT the comment lines
# that merely describe the rows.
row_present() { grep -qE "^\s*\('snapdragon-be-gateway',\s*'$1'" "${SCHEMA}"; }
row_present "/bff/superadmin/workloads/\*\*" && ok "superadmin route-access INSERT row seeded" || bad "superadmin route row missing from schema"
row_present "/bff/admin/workloads/\*\*" && ok "admin route-access INSERT row seeded" || bad "admin route row missing from schema"

# ── 7. GATE: NOT selected => prune; selected => keep ────────────────────────────
seed_tree() {
  local tree="$1"
  mkdir -p "${tree}/apps" "${tree}/manifests/workload-console-rbac" \
           "${tree}/manifests/route-access/initdb"
  cp "${APP}" "${tree}/apps/14-workload-console-rbac.yaml"
  cp "${RBAC}/serviceaccounts.yaml" "${tree}/manifests/workload-console-rbac/"
  cp "${SCHEMA}" "${tree}/manifests/route-access/initdb/20-schema.sql"
}

# Reproduce the builder's workloadConsole gate branch.
gate_wc() {  # $1 = OPTIONAL_SERVICES ; uses ${tree}
  OPTIONAL_SERVICES="$1"
  local apps="${tree}/apps"
  if ! _opt_selected workloadConsole; then
    rm -f "${apps}/14-workload-console-rbac.yaml"
    rm -rf "${tree}/manifests/workload-console-rbac"
    _opt_drop_rows "${tree}/manifests/route-access/initdb/20-schema.sql" snapdragon-be-gateway \
      '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
  fi
}

# Count only the INSERT data rows (not the descriptive comment lines).
count_rows() { grep -cE "^\s*\('snapdragon-be-gateway',\s*'/bff/(super)?admin/workloads/\*\*'" "$1"; }

# DESELECTED (default): prune everything.
tree="${WORK}/off"; seed_tree "${tree}"
gate_wc "akkoma tuwunel phpbb games"
[ ! -f "${tree}/apps/14-workload-console-rbac.yaml" ] && ok "gate prunes the RBAC Application when deselected" || bad "RBAC app NOT pruned"
[ ! -d "${tree}/manifests/workload-console-rbac" ] && ok "gate prunes the RBAC manifests when deselected" || bad "RBAC manifests NOT pruned"
[ "$(count_rows "${tree}/manifests/route-access/initdb/20-schema.sql")" -eq 0 ] \
  && ok "gate drops both route-access INSERT rows when deselected" \
  || bad "route-access rows NOT dropped when deselected"

# SELECTED: keep everything.
tree="${WORK}/on"; seed_tree "${tree}"
gate_wc "akkoma tuwunel phpbb games workloadConsole"
[ -f "${tree}/apps/14-workload-console-rbac.yaml" ] && ok "gate KEEPS the RBAC Application when selected" || bad "RBAC app wrongly pruned when selected"
[ "$(count_rows "${tree}/manifests/route-access/initdb/20-schema.sql")" -eq 2 ] \
  && ok "gate KEEPS both route-access INSERT rows when selected" \
  || bad "route rows wrongly dropped when selected"

# ── 8. The builder actually wires the gate + render loop ────────────────────────
grep -q "workloadConsole)" "${BUILDER}" && ok "builder has the workloadConsole gate case" || bad "builder missing workloadConsole gate case"
grep -q "14-workload-console-rbac.yaml" "${BUILDER}" && ok "builder prunes the RBAC app on deselect" || bad "builder app prune missing"
grep -qE "for slug in .*workloadConsole" "${BUILDER}" && ok "builder render loop includes workloadConsole" || bad "render loop missing workloadConsole"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
