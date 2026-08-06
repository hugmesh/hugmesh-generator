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

# Reproduce the builder's workloadConsole gate branch.
gate_wc() {  # $1 = OPTIONAL_SERVICES ; uses ${tree}
  OPTIONAL_SERVICES="$1"
  local apps="${tree}/apps"
  if ! _opt_selected workloadConsole; then
    rm -f "${apps}/14-workload-console-rbac.yaml"
    rm -rf "${tree}/manifests/workload-console-rbac"
    rm -f "${tree}/manifests/admin-bff-api/workload-console-patch.yaml"
    _opt_drop_kustomize_line "${tree}/manifests/admin-bff-api/kustomization.yaml" 'path: workload-console-patch.yaml'
    _opt_drop_rows "${tree}/manifests/route-access/initdb/20-schema.sql" hugmesh-be-gateway \
      '/bff/superadmin/workloads/**' '/bff/admin/workloads/**'
  fi
}

# Count only the INSERT data rows (not the descriptive comment lines).
count_rows() { grep -cE "^\s*\('hugmesh-be-gateway',\s*'/bff/(super)?admin/workloads/\*\*'" "$1"; }

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
  python3 - "${PATCH}" "${RBAC}" <<'PY'
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

# 3. exec read-only allowlist: no shells / file-content readers / env dumpers.
FORBIDDEN_EXEC = {"sh","bash","dash","ash","zsh","env","printenv","cat","head","tail",
                  "kubectl","curl","wget","nc","ncat","socat","python","python3","perl"}
execs = set(filter(None, (env.get("WORKLOAD_CONSOLE_EXEC_READONLY") or "").split(",")))
hit = execs & FORBIDDEN_EXEC
(bad if hit else ok)(f"exec allowlist contains forbidden {sorted(hit)}" if hit
                     else "exec allowlist has no shell/file-reader/env-dumper")
(ok if execs else bad)("exec allowlist non-empty" if execs else "exec allowlist empty")

# 4. port-forward triples: complete per index, app-tier-only, never a datastore/
#    Vault/PKI/Casdoor workload.
PF = "APP_WORKLOADCONSOLE_PORTFORWARDALLOWLIST_"
idx = sorted({n[len(PF):].split("_")[0] for n in env if n.startswith(PF)})
(ok if idx else bad)("port-forward allowlist emitted (indexed envs)" if idx else "no port-forward triples emitted")
FORBIDDEN_WL = ("db","postgres","cassandra","clickhouse","kafka","redis","vault","casdoor","pki")
pf_ok = True
for i in idx:
    ns  = env.get(f"{PF}{i}_NAMESPACE"); wl = env.get(f"{PF}{i}_WORKLOAD"); pt = env.get(f"{PF}{i}_PORT")
    if not (ns and wl and pt and pt.isdigit()):
        bad(f"port-forward triple [{i}] incomplete (ns={ns} wl={wl} port={pt})"); pf_ok = False; continue
    if ns not in allow:
        bad(f"port-forward triple [{i}] namespace {ns} outside the allowlist"); pf_ok = False
    if any(t in wl for t in FORBIDDEN_WL):
        bad(f"port-forward triple [{i}] targets a forbidden workload {wl}"); pf_ok = False
if pf_ok and idx: ok(f"all {len(idx)} port-forward triples complete, app-tier-only, no datastore/Vault/PKI/Casdoor")

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

print(f"__SUB {P} {F}")
sys.exit(1 if F else 0)
PY
  rc=$?
  if [ "${rc}" -eq 0 ]; then ok "deployment overlay contract invariants (parsed YAML)"; else bad "deployment overlay contract invariants — see FAILs above"; fi
else
  echo "  SKIP overlay parsed-YAML checks (no python3)"
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
grep -q "workloadConsole)" "${BUILDER}" && ok "builder has the workloadConsole gate case" || bad "builder missing workloadConsole gate case"
grep -q "14-workload-console-rbac.yaml" "${BUILDER}" && ok "builder prunes the RBAC app on deselect" || bad "builder app prune missing"
grep -qE "for slug in .*workloadConsole" "${BUILDER}" && ok "builder render loop includes workloadConsole" || bad "render loop missing workloadConsole"
# BOTH builders must prune the deployment overlay (file + kustomization line) too —
# the gate_wc reproduction above can otherwise drift from the real builders.
for b in "${BUILDER}" "${REPO}/build-x86-host-stage4.sh"; do
  grep -q 'admin-bff-api/workload-console-patch.yaml' "${b}" \
    && grep -q '_opt_drop_kustomize_line "${tree}/manifests/admin-bff-api/kustomization.yaml"' "${b}" \
    && ok "$(basename "${b}") prunes the deployment overlay + kustomization line" \
    || bad "$(basename "${b}") missing the deployment-overlay prune"
done

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
