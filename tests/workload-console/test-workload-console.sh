#!/usr/bin/env bash
# test-workload-console.sh — unit test for the WORKLOAD CONSOLE generator wiring:
#   * the two-SA RBAC manifests least-privilege invariants (the security acceptance bar);
#   * the optional-services.yaml registration (default off);
#   * the gate, in EVERY builder that has one: NOT selected => prune the RBAC app +
#     manifests + deployment overlay + route-access rows; selected => keep them;
#   * the deploy-provenance Kyverno policy requires digest-pinned (@sha256:) images;
#   * the route-access rows + the ArgoCD Application exist with the right shape;
#   * the lit overlay's two allowlists — the read-only exec forms (judged by a PROPERTY
#     re-derived per run from each command's own --help and its live behaviour against
#     canaries, NOT by a hand-list of banned names: see exec_argv_property.py) and the
#     curated port-forward triples (judged against the documented app-tier-BFF
#     ALLOWLIST, not a denylist of datastore-ish substrings).
#
# Proves the security invariants WITHOUT a full cross-build: the workloadConsole gate
# branch is not re-implemented here, it is EXTRACTED FROM EACH REAL BUILDER AND EXECUTED
# against a sandbox tree, and what is asserted is its EFFECT on that tree.
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
eval "$(extract_fn _opt_drop_kustomize_line)"
type _opt_selected >/dev/null 2>&1 || { echo "  FAIL could not extract _opt_selected"; exit 1; }
type _opt_drop_rows >/dev/null 2>&1 || { echo "  FAIL could not extract _opt_drop_rows"; exit 1; }
type _opt_drop_kustomize_line >/dev/null 2>&1 || { echo "  FAIL could not extract _opt_drop_kustomize_line"; exit 1; }

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
assert wc.get("namespace") == "hugmesh-backend", f"bad ns: {wc.get('namespace')}"
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
APP_TIER = {"hugmesh-backend","hugmesh-frontend","hugmesh-forum",
            "hugmesh-games","hugmesh-games-instances","hugmesh-tube","hugmesh-owncast"}
INFRA = {"hugmesh-pki","hugmesh-policy","vault","devops","observability","kube-system"}
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

# THE INVARIANT THAT MAKES Enforce SAFE — and the one this policy broke.
#
# The rule used to match all seven app tiers. That is not what "console deploy
# provenance" means, and it was not survivable: when Kyverno was actually
# installed (2026-08-22) the webhook began denying ArgoCD's own patches, because
# every repo-managed workload in those tiers is tag-based. Four Applications
# went un-syncable — the policy blocked the platform it was meant to protect.
#
# So the scope is not asserted as a hardcoded list (which would just re-encode
# today's answer). It is DERIVED: for every namespace the rule matches, every
# workload this repo defines in that namespace must itself be digest-pinned.
# Widening the rule back over a tier full of tag-based platform Deployments
# fails here by name, and so does dropping a tag-based workload INTO a matched
# tier. Both are the same defect from opposite directions.
if ! python3 -c 'import yaml' 2>/dev/null; then
  bad "PyYAML absent — the policy-scope invariant did not run (it would have passed vacuously)"
else
  scope_out="$(POLICY="${POLICY}" MANIFESTS="${RBAC}/.." python3 - <<'PYEOF'
import os, sys, yaml, glob

pol = list(yaml.safe_load_all(open(os.environ["POLICY"], encoding="utf-8")))
rules = [d for d in pol if d and d.get("kind") == "ClusterPolicy"]
if not rules:
    sys.exit("NOSCOPE no ClusterPolicy in the file")
matched = set()
for d in rules:
    for r in d["spec"].get("rules", []):
        for m in (r.get("match", {}).get("any") or []):
            matched.update((m.get("resources") or {}).get("namespaces") or [])
if not matched:
    sys.exit("NOSCOPE the rule matches no namespace at all — it would enforce nothing")

root = os.environ["MANIFESTS"]
bad, seen = [], 0
for f in glob.glob(os.path.join(root, "**", "*.y*ml"), recursive=True):
    try:
        docs = list(yaml.safe_load_all(open(f, encoding="utf-8")))
    except Exception:
        continue
    for d in docs:
        if not isinstance(d, dict):
            continue
        if d.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet", "Pod"):
            continue
        ns = (d.get("metadata") or {}).get("namespace")
        if ns not in matched:
            continue
        spec = d["spec"]
        pod = spec.get("template", {}).get("spec") if "template" in spec else spec
        for c in (pod or {}).get("containers", []) or []:
            seen += 1
            if "@sha256:" not in c.get("image", ""):
                bad.append("%s/%s image=%s (%s)" % (ns, d["metadata"].get("name"),
                           c.get("image"), os.path.relpath(f, root)))
print("MATCHED %s" % ",".join(sorted(matched)))
print("CHECKED %d" % seen)
for b in bad:
    print("VIOLATION %s" % b)
PYEOF
)"; scope_rc=$?
  if [ "${scope_rc}" -ne 0 ]; then
    bad "deploy-provenance scope check could not run: ${scope_out}"
  else
    viol="$(printf '%s\n' "${scope_out}" | grep '^VIOLATION ' || true)"
    nsl="$(printf '%s\n' "${scope_out}" | sed -n 's/^MATCHED //p')"
    nchk="$(printf '%s\n' "${scope_out}" | sed -n 's/^CHECKED //p')"
    if [ -n "${viol}" ]; then
      bad "deploy-provenance is Enforce over namespaces holding TAG-BASED repo workloads — ArgoCD cannot sync them:"
      printf '%s\n' "${viol}" | sed 's/^VIOLATION /        /'
    elif [ "${nchk:-0}" -eq 0 ]; then
      bad "deploy-provenance matches ${nsl} but this repo defines NO workload there — the scope check inspected 0 containers and proves nothing"
    else
      ok "deploy-provenance Enforce scope is survivable: ${nchk} repo-managed container(s) in ${nsl}, all digest-pinned"
    fi
  fi
fi

# ── 5. ArgoCD Application shape ─────────────────────────────────────────────────
[ -f "${APP}" ] && ok "ArgoCD Application apps/14-workload-console-rbac.yaml exists" || bad "ArgoCD Application missing"
grep -q "prune: true" "${APP}" && grep -q "selfHeal: true" "${APP}" && ok "Application has prune+selfHeal" || bad "Application missing prune/selfHeal"
grep -q "workload-console-rbac" "${APP}" && ok "Application sources the RBAC manifest path" || bad "Application path wrong"

# ── 6. Route-access rows present in the canonical seed ──────────────────────────
# Match the INSERT data row (a leading "(" + the gateway literal), NOT the comment lines
# that merely describe the rows.
row_present() { grep -qE "^\s*\('hugmesh-be-gateway',\s*'$1'" "${SCHEMA}"; }
row_present "/bff/superadmin/workloads/\*\*" && ok "superadmin route-access INSERT row seeded" || bad "superadmin route row missing from schema"
row_present "/bff/admin/workloads/\*\*" && ok "admin route-access INSERT row seeded" || bad "admin route row missing from schema"

# ── 7. GATE: NOT selected => prune; selected => keep ────────────────────────────
seed_tree() {
  local tree="$1"
  mkdir -p "${tree}/apps" "${tree}/manifests/workload-console-rbac" \
           "${tree}/manifests/route-access/initdb" "${tree}/manifests/admin-bff-api"
  cp "${APP}" "${tree}/apps/14-workload-console-rbac.yaml"
  cp "${RBAC}/serviceaccounts.yaml" "${tree}/manifests/workload-console-rbac/"
  cp "${SCHEMA}" "${tree}/manifests/route-access/initdb/20-schema.sql"
  # The WHOLE admin-bff kustomize dir, so the deselected/selected trees can be
  # kustomize-RENDERED (not just file-diffed) when kubectl is available.
  cp -a "${REPO}/specs/cluster/manifests/admin-bff-api/." "${tree}/manifests/admin-bff-api/"
}

# The gate branch is not REPRODUCED here — it is EXECUTED, verbatim, out of each real
# builder. A reproduction can only ever be as good as whatever cross-checks it, and a
# grep that the builder still mentions the overlay filename is not one: it stays green
# through any change to the prune PATTERN (or to the shape of the line being pruned),
# which is exactly the drift it claims to prevent. So: extract the `workloadConsole)`
# case body + the helper functions it calls FROM THE BUILDER, run them against a sandbox
# tree seeded from the checked-in manifests, and assert the EFFECT.
extract_fn_of() {  # $1 = builder, $2 = function name
  awk "/^$2\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "$1"
}
extract_case_of() {  # $1 = builder, $2 = case label — body between `<label>)` and `;;`
  awk -v lbl="$2" '
    $0 ~ ("^[[:space:]]*" lbl "\\)[[:space:]]*$") { p=1; next }
    p && $0 ~ /^[[:space:]]*;;[[:space:]]*$/ { exit }
    p { print }
  ' "$1"
}

# Run the REAL builder's gate for one slug against ${tree}. Nothing about the prune is
# restated here: OPTIONAL_SERVICES, _opt_selected and the case body are all the builder's.
run_real_gate() {  # $1 = builder ; $2 = tree ; $3 = OPTIONAL_SERVICES
  local body; body="$(extract_case_of "$1" workloadConsole)"
  [ -n "${body}" ] || { echo "  FAIL could not extract the workloadConsole case body from $(basename "$1")"; return 2; }
  (
    set -uo pipefail
    OPTIONAL_SERVICES="$3"
    tree="$2"; apps="$2/apps"
    info() { :; }; warn() { :; }
    eval "$(extract_fn_of "$1" _opt_selected)"
    eval "$(extract_fn_of "$1" _opt_drop_kustomize_line)"
    eval "$(extract_fn_of "$1" _opt_drop_rows)"
    eval "$(extract_fn_of "$1" _opt_drop_route)"
    # The builder's own loop guard: `_opt_selected "${slug}" && continue`.
    _opt_selected workloadConsole && exit 0
    eval "${body}"
  )
}

# Count only the INSERT data rows (not the descriptive comment lines).
count_rows() { grep -cE "^\s*\('hugmesh-be-gateway',\s*'/bff/(super)?admin/workloads/\*\*'" "$1"; }

# The EFFECT of a deselected build, asserted on the pruned tree: nothing the slug owns
# survives, and — the assertion the grep could never make — the kustomization that is
# left still resolves. `kustomize build` reads every `resources:` entry and every
# `patches[].path`; a prune that deletes the overlay FILE but leaves its line (a typo'd
# pattern, a re-ordered `- target:`/`path:` mapping, any change the line-oriented sed
# stops matching) yields a dangling reference and the dark admin-bff stops rendering at
# all. That is checked structurally, so it fails whether or not kubectl is installed.
assert_pruned() {  # $1 = label ; $2 = tree
  local lbl="$1" t="$2"
  [ ! -f "${t}/apps/14-workload-console-rbac.yaml" ] && ok "${lbl}: prunes the RBAC Application" || bad "${lbl}: RBAC app NOT pruned"
  [ ! -d "${t}/manifests/workload-console-rbac" ] && ok "${lbl}: prunes the RBAC manifests" || bad "${lbl}: RBAC manifests NOT pruned"
  [ ! -f "${t}/manifests/admin-bff-api/workload-console-patch.yaml" ] && ok "${lbl}: prunes the deployment overlay file" || bad "${lbl}: deployment overlay NOT pruned"
  [ "$(count_rows "${t}/manifests/route-access/initdb/20-schema.sql")" -eq 0 ] \
    && ok "${lbl}: drops both route-access INSERT rows" || bad "${lbl}: route-access rows NOT dropped"
  if grep -rqi "workload.console" "${t}/manifests/admin-bff-api" 2>/dev/null; then
    bad "${lbl}: the pruned admin-bff kustomize dir STILL references workload-console"
  else
    ok "${lbl}: no workload-console reference survives in the admin-bff kustomize dir"
  fi
  if command -v python3 >/dev/null; then
    python3 - "${lbl}" "${t}/manifests/admin-bff-api" <<'PY'
import os, sys, yaml
lbl, d = sys.argv[1], sys.argv[2]
k = yaml.safe_load(open(os.path.join(d, "kustomization.yaml")))
missing = []
# EVERY manifest path the file still names, in whatever field names it — resources:,
# patches[].path:, the older patchesStrategicMerge:, components:, bases:, crds: … The
# walk is by VALUE shape, not by field name, so a kustomization that is later rewritten
# into another (equally valid) form cannot slip a dangling reference past this.
def walk(node, where):
    if isinstance(node, dict):
        for kk, vv in node.items(): walk(vv, f"{where}.{kk}")
    elif isinstance(node, list):
        for i, vv in enumerate(node): walk(vv, f"{where}[{i}]")
    elif isinstance(node, str) and node.endswith((".yaml", ".yml")):
        if not os.path.exists(os.path.join(d, node)):
            missing.append(f"{where}: {node}")
walk(k, "kustomization")
if missing:
    print(f"  FAIL {lbl}: pruned kustomization references file(s) that no longer exist "
          f"-> `kustomize build` fails, the dark admin-bff does not render: {missing}")
    sys.exit(1)
print(f"  PASS {lbl}: every path the pruned kustomization still references exists "
      f"(it renders)")
PY
    if [ $? -eq 0 ]; then P=$((P+1)); else F=$((F+1)); fi
  fi
}

# DESELECTED (default) — run the real branch of EVERY builder that has the gate
# (discovered, not listed: a new platform builder cannot quietly opt out).
gate_builders=()
for b in "${REPO}"/build-*-stage4.sh; do
  grep -q '^gate_optional_services() {' "${b}" && gate_builders+=("${b}")
done
for b in "${gate_builders[@]}"; do
  bn="$(basename "${b}")"
  tree="${WORK}/off-${bn}"; seed_tree "${tree}"
  if run_real_gate "${b}" "${tree}" "akkoma tuwunel phpbb games"; then
    assert_pruned "${bn} (real gate branch, deselected)" "${tree}"
  else
    bad "${bn}: the real workloadConsole gate branch could not be executed"
  fi
done
# Every builder must prune IDENTICALLY — a divergence means one platform ships a tree
# the other never renders.
ref_bn="$(basename "${gate_builders[0]}")"
for b in "${gate_builders[@]:1}"; do
  bn="$(basename "${b}")"
  diff -r "${WORK}/off-${ref_bn}" "${WORK}/off-${bn}" >/dev/null 2>&1 \
    && ok "${bn}: real gate branch produces a tree identical to ${ref_bn}'s" \
    || bad "${bn}: gate branch produces a DIFFERENT pruned tree than ${ref_bn}"
done
# The canonical dark tree for the sections below.
tree="${WORK}/off"; seed_tree "${tree}"
run_real_gate "${BUILDER}" "${tree}" "akkoma tuwunel phpbb games"

# SELECTED: the real gate keeps everything.
tree="${WORK}/on"; seed_tree "${tree}"
run_real_gate "${BUILDER}" "${tree}" "akkoma tuwunel phpbb games workloadConsole"
[ -f "${tree}/apps/14-workload-console-rbac.yaml" ] && ok "gate KEEPS the RBAC Application when selected" || bad "RBAC app wrongly pruned when selected"
[ "$(count_rows "${tree}/manifests/route-access/initdb/20-schema.sql")" -eq 2 ] \
  && ok "gate KEEPS both route-access INSERT rows when selected" \
  || bad "route rows wrongly dropped when selected"

# ── 7b. Admin-bff deployment overlay: dark default byte-identical; lit contract ─
# The workloadConsole slug also owns manifests/admin-bff-api/workload-console-patch.yaml
# (+ its one kustomization `- path:` line): deselected => BOTH pruned and the admin-bff
# render is byte-identical to a tree that never had the feature; selected => the overlay
# mounts both SA tokens at the CONTRACT paths and emits every WORKLOAD_CONSOLE_* env.
DEPLOY_DIR="${REPO}/specs/cluster/manifests/admin-bff-api"
PATCH="${DEPLOY_DIR}/workload-console-patch.yaml"
OFF_BFF="${WORK}/off/manifests/admin-bff-api"
ON_BFF="${WORK}/on/manifests/admin-bff-api"

[ -f "${PATCH}" ] && ok "deployment overlay workload-console-patch.yaml exists" || bad "deployment overlay missing"

# DESELECTED: overlay + kustomization line pruned; the SURVIVING files are byte-identical
# to the checked-in tree (deployment.yaml untouched; kustomization == checked-in minus
# exactly the one overlay line) — i.e. the dark default renders exactly today's admin-bff.
[ ! -f "${OFF_BFF}/workload-console-patch.yaml" ] && ok "gate prunes the deployment overlay when deselected" || bad "deployment overlay NOT pruned"
cmp -s "${OFF_BFF}/deployment.yaml" "${DEPLOY_DIR}/deployment.yaml" \
  && ok "dark deployment.yaml byte-identical (gate never touches it)" || bad "dark deployment.yaml differs from the checked-in one"
grep -vF 'workload-console-patch.yaml' "${DEPLOY_DIR}/kustomization.yaml" > "${WORK}/kustomization.expected.yaml"
cmp -s "${OFF_BFF}/kustomization.yaml" "${WORK}/kustomization.expected.yaml" \
  && ok "dark kustomization.yaml == checked-in minus EXACTLY the one overlay line" || bad "dark kustomization.yaml not byte-identical minus the overlay line"
grep -q "workload-console" "${OFF_BFF}/kustomization.yaml" \
  && bad "dark kustomization still references workload-console" || ok "dark kustomization has NO workload-console reference"

# SELECTED: overlay + line survive.
[ -f "${ON_BFF}/workload-console-patch.yaml" ] && ok "gate KEEPS the deployment overlay when selected" || bad "deployment overlay wrongly pruned when selected"
grep -q "workload-console-patch.yaml" "${ON_BFF}/kustomization.yaml" \
  && ok "gate KEEPS the kustomization overlay line when selected" || bad "kustomization overlay line wrongly dropped when selected"

# Contract + least-privilege invariants of the LIT wiring (parsed YAML, not grep).
if command -v python3 >/dev/null; then
  python3 - "${PATCH}" "${RBAC}" "${REPO}/specs/cluster/manifests" <<'PY'
import sys, yaml
patch_f, rbac = sys.argv[1], sys.argv[2]
P=F=0
def ok(m):
    global P; P+=1; print("  PASS "+m)
def bad(m):
    global F; F+=1; print("  FAIL "+m)

INFRA = {"hugmesh-pki","hugmesh-policy","vault","devops","observability","kube-system"}
READ_MOUNT   = "/var/run/secrets/workload-console-read"
MUTATE_MOUNT = "/var/run/secrets/workload-console-mutate"

patch = yaml.safe_load(open(patch_f))
spec = patch["spec"]["template"]["spec"]
ctr = next(c for c in spec["containers"] if c["name"] == "hugmesh-admin-bff-api")
env = {e["name"]: e.get("value") for e in ctr.get("env", [])}

# 1. every documented WORKLOAD_CONSOLE_* env is emitted, gate + seam lit.
required = {
    "WORKLOAD_CONSOLE_ENABLED": "true",
    "WORKLOAD_CONSOLE_K8S_ENABLED": "true",
    "WORKLOAD_CONSOLE_NAMESPACE_ALLOWLIST": None,
    "WORKLOAD_CONSOLE_EXEC_READONLY": None,
    "WORKLOAD_CONSOLE_GRANT_TTL_HOURS": None,
    "WORKLOAD_CONSOLE_EXPIRY_INTERVAL_MS": None,
    "WORKLOAD_CONSOLE_EXPIRY_INITIAL_DELAY_MS": None,
    "WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE": READ_MOUNT + "/token",
    "WORKLOAD_CONSOLE_K8S_MUTATE_TOKEN_FILE": MUTATE_MOUNT + "/token",
}
for name, want in required.items():
    if name not in env: bad(f"env {name} missing"); continue
    if want is not None and env[name] != want: bad(f"env {name}={env[name]!r}, want {want!r}"); continue
    ok(f"env {name} emitted" + (f"={want}" if want else ""))

# 2. namespace allowlist == EXACTLY the namespaces the read Role is bound in.
bind_ns = set()
for d in yaml.safe_load_all(open(f"{rbac}/bindings.yaml")):
    if d and d.get("kind") == "RoleBinding" and d["metadata"]["name"] == "workload-console-read":
        bind_ns.add(d["metadata"]["namespace"])
allow = set(filter(None, (env.get("WORKLOAD_CONSOLE_NAMESPACE_ALLOWLIST") or "").split(",")))
(ok if allow == bind_ns else bad)(
    f"namespace allowlist mirrors the read RoleBindings exactly ({sorted(allow)})" if allow == bind_ns
    else f"allowlist {sorted(allow)} != read RoleBinding namespaces {sorted(bind_ns)}")
hit = allow & INFRA
(bad if hit else ok)(f"allowlist contains INFRA ns {sorted(hit)}" if hit else "allowlist contains no infra-tier namespace")

# 3. exec read-only allowlist — see §3b below. The allowlist is judged by a PROPERTY
#    (exec_argv_property.py), not here, because the previous shape of this check was a
#    hand-written list of banned command names and a hand-written list of "safe" ones.
#    That shape cannot work: it passed `du` — whose `--files0-from=F` echoes the
#    contents of F back as `du: cannot access '<line>'` — while the very same round
#    was removing `ps` for `ps eww` and `date` for `date -f`, three instances of one
#    class. A name list is always exactly one command behind. Only the ARGV-INDEPENDENT
#    structure is asserted here; everything about what a command can be MADE to do is
#    re-derived per run from that command's own documentation and its live behaviour.
raw = env.get("WORKLOAD_CONSOLE_EXEC_READONLY") or ""
entries = [e.strip() for e in raw.split(",") if e.strip()]
(ok if entries else bad)("exec allowlist non-empty" if entries else "exec allowlist empty")

# 4. port-forward triples: the documented curation rule is "app-tier BFFs ONLY", so it
#    is checked as an ALLOWLIST. A denylist of datastore-ish substrings ("db","postgres",
#    "cassandra","clickhouse","kafka","redis","vault","casdoor","pki") is NOT that rule
#    and never was: every app-tier workload whose name happens to miss all nine sails
#    through it — tuwunel (the Matrix homeserver: access tokens + registration token),
#    akkoma, hugmesh-coturn (TURN shared secret), egress-proxy, hugmesh-media-poisoner…
#    all live in an ALLOWLISTED namespace and match none of the nine. So a triple is
#    accepted only if:
#      (a) its namespace is in the emitted namespace allowlist (and not infra-tier),
#      (b) the workload matches the first-party BFF naming contract,
#      (c) that exact workload REALLY EXISTS in this shipped cluster tree, in that
#          namespace (no ghost/typo/foreign target), and
#      (d) the port is one that workload actually declares (no reaching a debug/JMX
#          port that merely happens to be open in the pod).
#    The nine substrings are kept below only as a subordinate second opinion.
import re, glob, os
BFF_NAME = re.compile(r"^hugmesh-(?:[a-z0-9]+-)*bff-api$")
manifests = sys.argv[3]
declared = {}   # (ns, name) -> set(ports)
for f in sorted(glob.glob(os.path.join(manifests, "**", "*.yaml"), recursive=True)):
    try:
        mdocs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in mdocs:
        if not isinstance(d, dict):
            continue
        meta = d.get("metadata") or {}
        key = (meta.get("namespace"), meta.get("name"))
        if d.get("kind") in ("Deployment", "StatefulSet"):
            pods = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
            ports = declared.setdefault(key, set())
            for c in (pods.get("containers") or []):
                for p in (c.get("ports") or []):
                    if isinstance(p, dict) and p.get("containerPort") is not None:
                        ports.add(int(p["containerPort"]))
        elif d.get("kind") == "Service":
            ports = declared.setdefault(key, set())
            for p in ((d.get("spec") or {}).get("ports") or []):
                if isinstance(p, dict) and p.get("port") is not None:
                    ports.add(int(p["port"]))

PF = "APP_WORKLOADCONSOLE_PORTFORWARDALLOWLIST_"
idx = sorted({n[len(PF):].split("_")[0] for n in env if n.startswith(PF)})
(ok if idx else bad)("port-forward allowlist emitted (indexed envs)" if idx else "no port-forward triples emitted")
FORBIDDEN_WL = ("db","postgres","cassandra","clickhouse","kafka","redis","vault","casdoor","pki")
pf_ok = True
for i in idx:
    ns  = env.get(f"{PF}{i}_NAMESPACE"); wl = env.get(f"{PF}{i}_WORKLOAD"); pt = env.get(f"{PF}{i}_PORT")
    if not (ns and wl and pt and pt.isdigit()):
        bad(f"port-forward triple [{i}] incomplete (ns={ns} wl={wl} port={pt})"); pf_ok = False; continue
    if ns not in allow or ns in INFRA:
        bad(f"port-forward triple [{i}] namespace {ns} outside the allowlist"); pf_ok = False; continue
    if not BFF_NAME.match(wl):
        bad(f"port-forward triple [{i}] workload {wl!r} is NOT an app-tier BFF "
            f"(the curated rule is app-tier BFFs only: ^hugmesh-(<seg>-)*bff-api$)")
        pf_ok = False; continue
    if (ns, wl) not in declared:
        bad(f"port-forward triple [{i}] targets {ns}/{wl}, which is not a "
            f"Deployment/StatefulSet in the shipped cluster tree"); pf_ok = False; continue
    if int(pt) not in declared[(ns, wl)]:
        bad(f"port-forward triple [{i}] port {pt} is not declared by {ns}/{wl} "
            f"(declared: {sorted(declared[(ns, wl)])})"); pf_ok = False; continue
    if any(t in wl for t in FORBIDDEN_WL):
        bad(f"port-forward triple [{i}] targets a forbidden workload {wl}"); pf_ok = False
if pf_ok and idx:
    ok(f"all {len(idx)} port-forward triples are app-tier BFFs that exist in the "
       f"shipped tree, on a port they declare")

# 5. BOTH tokens mounted read-only at the CONTRACT paths, wired to Secret volumes
#    whose secretNames are MINTED in token-secrets.yaml for the RIGHT SAs.
mounts = {m["mountPath"]: m for m in ctr.get("volumeMounts", [])}
vols = {v["name"]: v for v in spec.get("volumes", [])}
secrets = {}
for d in yaml.safe_load_all(open(f"{rbac}/token-secrets.yaml")):
    if d and d.get("kind") == "Secret":
        secrets[d["metadata"]["name"]] = d
for mp, sa in ((READ_MOUNT, "workload-console-read"), (MUTATE_MOUNT, "workload-console-mutate")):
    m = mounts.get(mp)
    if not m: bad(f"no volumeMount at contract path {mp}"); continue
    if not m.get("readOnly"): bad(f"mount {mp} not readOnly"); continue
    v = vols.get(m["name"])
    if not v or "secret" not in v: bad(f"mount {mp} volume {m.get('name')} is not a Secret volume"); continue
    sname = v["secret"]["secretName"]
    s = secrets.get(sname)
    if s is None: bad(f"mount {mp} references Secret {sname} NOT minted in token-secrets.yaml"); continue
    if s.get("type") != "kubernetes.io/service-account-token":
        bad(f"Secret {sname} wrong type {s.get('type')}"); continue
    ann = s["metadata"].get("annotations", {}).get("kubernetes.io/service-account.name")
    if ann != sa: bad(f"Secret {sname} bound to SA {ann}, want {sa}"); continue
    if s["metadata"].get("namespace") != "hugmesh-backend":
        bad(f"Secret {sname} in ns {s['metadata'].get('namespace')}, want hugmesh-backend"); continue
    # The Secrets come from a SEPARATE, unwaved ArgoCD Application (apps/14) and are
    # populated asynchronously by the token controller. A NON-optional volume would let
    # this OPTIONAL feature block the ALWAYS-PRESENT admin-bff pod from starting
    # (ContainerCreating, "secret not found") instead of degrading that half to the
    # contracted 503.
    if v["secret"].get("optional") is not True:
        bad(f"volume {m['name']} (Secret {sname}) is NOT optional:true — a missing/"
            f"unsynced Secret would wedge the always-present admin-bff pod"); continue
    ok(f"token mounted read-only at {mp} <- optional Secret {sname} (SA {sa})")

# 6. No container in the BASE deployment may declare the same env name twice.
#    This is a structural restatement of the render-level "lit is purely ADDITIVE"
#    check below, and it exists because that check SKIPs when kubectl is absent —
#    which is exactly the case in CI (python:3-slim). A guard that only runs on a
#    developer's laptop is not the guard, it is the rehearsal.
#    A strategic-merge patch merges a container's env list BY `name`, so a base that
#    declares one name twice collapses to a single entry the moment the overlay is
#    applied: the lit render then REMOVES a line the dark render had, the overlay is
#    no longer additive, and which of the two values survives is decided by the merge
#    rather than by either manifest. (Kubernetes itself takes the last one, so a
#    duplicate is already a silent, order-dependent config even before kustomize.)
import collections
dep_f = f"{sys.argv[3]}/admin-bff-api/deployment.yaml"
dep = yaml.safe_load(open(dep_f))
dspec = dep["spec"]["template"]["spec"]
dup_hit = False
for cl in ("initContainers", "containers"):
    for c in (dspec.get(cl) or []):
        names = [e["name"] for e in (c.get("env") or [])]
        dups = sorted(n for n, k in collections.Counter(names).items() if k > 1)
        if dups:
            dup_hit = True
            bad(f"deployment.yaml {cl}/{c['name']} declares {dups} more than once — a "
                f"strategic-merge overlay merges env by name, so the lit render would "
                f"DROP one of them and stop being additive over the dark render")
if not dup_hit:
    ok("no container in the base deployment declares an env name twice "
       "(strategic-merge would collapse it and break overlay additivity)")

print(f"__SUB {P} {F}")
sys.exit(1 if F else 0)
PY
  rc=$?
  if [ "${rc}" -eq 0 ]; then ok "deployment overlay contract invariants (parsed YAML)"; else bad "deployment overlay contract invariants — see FAILs above"; fi
else
  echo "  SKIP overlay parsed-YAML checks (no python3)"
fi

# ── 7c. The read-only exec allowlist, judged as a PROPERTY ──────────────────────
# NOT a list of banned command names. The property is: no entry can be induced to
# print the contents of an arbitrary file — or ANY transform of them, since base64,
# hex and a checksum hand the bytes over just as completely as cat does — to print an
# environment, to execute another program, or to write, under EVERY argv the shipped
# first-token matcher licenses for it. "Every argv" includes the OPERAND half: a bare
# name licenses `<cmd> /var/run/secrets/workload-console-read/token` with no flag in
# sight. Decided by two independent oracles that both re-derive their answer from the
# command itself: its own --help (option surface AND synopsis operands), and its live
# behaviour against freshly generated file/environment/exec canaries on a pty, plus a
# differential canary that catches a leak in any encoding. See the module header.
#
# There is no `command -v python3` guard here on purpose: the two checks above may
# degrade to a SKIP because they only read YAML, but this one is the security
# acceptance bar for the exec seam. If it cannot run, the suite must go red rather
# than print a reassuring line about a property nobody checked.
PROP="${REPO}/tests/workload-console/exec_argv_property.py"
if [ -f "${PROP}" ] && command -v python3 >/dev/null; then
  python3 "${PROP}" "${PATCH}"
  if [ $? -eq 0 ]; then
    ok "exec allowlist holds property P (no entry can be argued into reading a file, dumping an environment, executing, or writing)"
  else
    bad "exec allowlist VIOLATES property P — see the FAILs above"
  fi
else
  bad "exec_argv_property.py or python3 missing — the exec allowlist property is UNPROVEN"
fi

# ── 7d. Controls: the property check above must be able to FAIL, and to PASS ────
# The shipped allowlist holding property P is only good news if the check that says
# so could have said otherwise. Both controls name the MECHANISM they expect in the
# output, not merely a non-zero exit: an entry whose binary is missing also exits
# non-zero, and a control satisfied by that would be green while proving nothing.
# Both commands are coreutils, so they are present wherever this suite can run at all.
if [ -f "${PROP}" ] && command -v python3 >/dev/null; then
  ctl() {  # $1 = label ; $2 = entries ; $3 = expected mechanism (grep -F) ; $4 = expect fail|pass
    local out rc
    out="$(python3 "${PROP}" --entries "$2" 2>&1)"; rc=$?
    if [ "$4" = "fail" ]; then
      if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -F "$3" >/dev/null; then
        ok "control: $1 — the property check catches it, via ${3}"
      else
        bad "control: $1 — the property check did NOT catch it (rc=${rc}); a check that cannot fail is not a check"
      fi
    else
      if [ "${rc}" -eq 0 ]; then
        ok "control: $1 — the property check accepts it (not failing everything)"
      else
        bad "control: $1 — the property check rejects a command that holds P: ${out}"
      fi
    fi
  }
  # The two oracles are controlled SEPARATELY, on purpose. A control that only says
  # "du is rejected" stays green when one of the legs is deleted, because the other
  # still rejects it — the guard would quietly become half a guard while every line it
  # prints stayed reassuring. So each negative names the LEG and the MECHANISM, across
  # two different sub-classes of the defect.
  #
  # NEGATIVE 1a/1b — a path-valued flag. `du` is off the allowlist precisely because of
  # this, and it is kept here as the standing control for that whole class.
  ctl "path-valued flag, DOCUMENTATION leg (du)" "du" \
      '[docs] `du --files0-from` takes a PATH-valued argument' fail
  ctl "path-valued flag, BEHAVIOUR leg (du)" "du" \
      'printed the CONTENTS of the file it was pointed at' fail
  # NEGATIVE 2a/2b — a different sub-class: a head whose own synopsis takes a program,
  # so one positional argument turns it into arbitrary execution.
  ctl "executes its argument, DOCUMENTATION leg (nice)" "nice" \
      'executes that command — its own synopsis takes a program positionally' fail
  ctl "executes its argument, BEHAVIOUR leg (nice)" "nice" \
      'EXECUTED another program' fail
  # NEGATIVE 3 — fail-closed on an entry that cannot be probed at all.
  ctl "an entry whose binary is absent" "hugmesh-no-such-command" "unprobed entry is an unproven entry" fail
  # NEGATIVE 4a/4b — the OPERAND sub-class: a reader that needs NO FLAG AT ALL.
  # `base64 /var/run/secrets/workload-console-read/token` is the whole exploit, and
  # both legs used to wave it through — the doc leg because it only ever read the
  # OPTION surface, the behaviour leg because it only ever searched for the canary
  # STRING and base64 hands the bytes over in another alphabet.
  #
  # The two commands are chosen so that each control can only be satisfied by the
  # leg it names. `cut` trips the DOCUMENTATION leg alone: its behaviour leg stays
  # silent because `cut <file>` without -c/-f/-b is an error, so if the operand rule
  # is deleted `cut` passes outright and this control goes red. `base64` names the
  # DIFFERENTIAL mechanism, which exists nowhere else: delete that leg and the
  # string disappears even though the doc leg still exits non-zero.
  ctl "a positional file reader, DOCUMENTATION leg (cut)" "cut" \
      'takes FILE as a PLAIN POSITIONAL operand' fail
  ctl "a positional file reader, DIFFERENTIAL BEHAVIOUR leg (base64)" "base64" \
      'printed a TRANSFORM of the CONTENTS of the file it was pointed at' fail
  # VACUITY — the check is not simply rejecting everything. `stat` is the pointed
  # one: it takes a FILE operand positionally, exactly like base64 does, and must
  # still pass — the corrected property forbids reading a file's BYTES, not naming
  # a file. A guard that failed `stat` would be rejecting the operand rather than
  # the leak, and every metadata tool on the list would have to be exempted by name.
  ctl "a command that really does hold P (uname)" "uname" "" pass
  ctl "a FILE-operand command that leaks no bytes (stat)" "stat" "" pass
fi

# RENDER-level proof when kubectl is available: the dark render carries ZERO
# workload-console content, and the lit render is purely ADDITIVE over it.
if command -v kubectl >/dev/null 2>&1 && kubectl kustomize "${OFF_BFF}" > "${WORK}/dark.render.yaml" 2>/dev/null; then
  if grep -qiE "workload.console|WORKLOAD_CONSOLE" "${WORK}/dark.render.yaml"; then
    bad "dark render still carries workload-console content"
  else
    ok "dark render (kubectl kustomize) carries ZERO workload-console content"
  fi
  if kubectl kustomize "${ON_BFF}" > "${WORK}/lit.render.yaml" 2>/dev/null; then
    if [ "$(diff "${WORK}/dark.render.yaml" "${WORK}/lit.render.yaml" | grep -c '^<')" -eq 0 ]; then
      ok "lit render is purely ADDITIVE over the dark render (no line removed/changed)"
    else
      bad "lit render REMOVES/ALTERS dark-render lines (overlay must be additive)"
    fi
    if grep -q "mountPath: /var/run/secrets/workload-console-read" "${WORK}/lit.render.yaml" \
       && grep -q "mountPath: /var/run/secrets/workload-console-mutate" "${WORK}/lit.render.yaml"; then
      ok "lit render mounts BOTH tokens at the contract paths"
    else
      bad "lit render missing a contract token mount"
    fi
  else
    bad "lit tree does not kustomize-render"
  fi
else
  echo "  SKIP render-level checks (no kubectl kustomize)"
fi

# ── 8. The builder actually wires the gate + render loop ────────────────────────
# Every builder that HAS gate_optional_services must also carry the workloadConsole
# case — discovered, not listed, so a new builder cannot quietly ship without it. The
# prune itself is not grepped for: §7 executed each of these builders' real branches and
# asserted what it did to a tree. (A grep for the overlay FILENAME survives any change
# to the prune PATTERN — it matches the `rm -f` line — and a grep for the
# `_opt_drop_kustomize_line "<file>"` call ignores the pattern argument entirely, which
# is the only argument that decides whether the kustomization line goes.)
grep -qE "for slug in .*workloadConsole" "${BUILDER}" && ok "builder render loop includes workloadConsole" || bad "render loop missing workloadConsole"
[ "${#gate_builders[@]}" -ge 2 ] && ok "found ${#gate_builders[@]} builders with gate_optional_services" \
  || bad "expected >=2 builders with gate_optional_services, found ${#gate_builders[@]}"
for b in "${gate_builders[@]}"; do
  grep -qE "^[[:space:]]*workloadConsole\)[[:space:]]*$" "${b}" \
    && ok "$(basename "${b}") carries the workloadConsole gate case" \
    || bad "$(basename "${b}") has gate_optional_services but NO workloadConsole case"
done
# §7 must have EXECUTED every one of them, not just the two it names.
for b in "${gate_builders[@]}"; do
  bn="$(basename "${b}")"
  [ -d "${WORK}/off-${bn}" ] && ok "${bn}: its real gate branch was executed + effect-asserted in §7" \
    || bad "${bn}: has a workloadConsole case that §7 never executed"
done

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
