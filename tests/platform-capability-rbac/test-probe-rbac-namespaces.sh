#!/usr/bin/env bash
# test-probe-rbac-namespaces.sh — guards the ADMIN-BFF PLATFORM-CAPABILITY PROBE RBAC
# against the failure that made its ArgoCD half inert: a namespaced Role/RoleBinding
# aimed at a namespace THIS PLATFORM NEVER CREATES.
#
# WHY THIS EXISTS. specs/cluster/apps/31a-admin-bff-platform-capability-rbac.yaml syncs
# with CreateNamespace=false. A namespaced resource whose namespace nothing creates can
# therefore never apply — ArgoCD fails that sync forever with `namespaces "<ns>" not
# found`, which names Kubernetes rather than the cause. The repo has already been bitten
# by exactly this (see the ensure-namespaces loop in bootstrap-kind.sh, added after
# external-secrets-config and workload-console-rbac sat unsynced FOR MONTHS). The probe
# RBAC shipped a Role + RoleBinding in an `argocd` namespace, but this platform installs
# ArgoCD into `devops` (bootstrap.sh and bootstrap-kind.sh both default ARGOCD_NS=devops
# and re-namespace the upstream install, which hardcodes `argocd`), and no `argocd`
# namespace is declared or created anywhere. That grant was a permanent phantom.
#
# WHAT IS ASSERTED (post-conditions on the committed manifests, not an exit code):
#   1. The Application still syncs CreateNamespace=false — the premise every other
#      assertion rests on. If that flips, this guard is measuring the wrong property.
#   2. Every namespaced resource in the probe RBAC targets a namespace that already
#      EXISTS when this Application first reconciles. The inventory is DERIVED, never
#      hand-listed: the deriver finds every `kind: Namespace` manifest under specs/,
#      every Argo Application syncing CreateNamespace=true (recording whether it is
#      automated), and both bootstraps' ensure-namespaces loops — and then applies the
#      rule that only ONE of those promises pre-existence.
#   3. That one is specs/cluster/namespaces/namespaces.yaml, which BOTH bootstraps
#      `kubectl apply` BEFORE ArgoCD is installed (bootstrap.sh:19, bootstrap-kind.sh
#      :265). Nothing else qualifies. An Application with CreateNamespace=true creates
#      the namespace only when IT syncs — unordered w.r.t. this one, and apps/55-velero
#      .yaml is deliberately NON-automated, so on a mesh nobody has synced it that never
#      happens. The kind-local bootstrap's imperative `kubectl create namespace` loops
#      run only on the kind lane; bootstrap.sh applies namespaces.yaml and nothing else.
#      Deriving the rule this way — rather than "is the name mentioned anywhere?" — is
#      what makes deleting a namespace from namespaces.yaml ALONE go RED, instead of
#      staying green propped up by a loop that never runs in production. It is also
#      what found the second live instance of this bug: `velero` was created only by
#      the kind bootstrap's loop, so the velero half of this very file was a phantom
#      on every non-kind mesh. namespaces.yaml now declares it.
#   4. No resource anywhere in that file targets `argocd` (the specific phantom).
#   5. PAIRING. The original defect was TWO lines — the Role's namespace AND the
#      RoleBinding's. Every RoleBinding whose roleRef.kind is Role must find that Role
#      in its OWN namespace, and the set of Role namespaces must equal the set of
#      RoleBinding namespaces. A half-applied fix that moves one of a pair is a
#      RoleBinding that binds nothing, and it applies cleanly and silently.
#   6. The namespace carrying the argocd-server Deployment grant EQUALS the namespace
#      the bootstrap installs ArgoCD into (ARGOCD_NS default) — the two-sided
#      consistency check. Both bootstrap scripts are read; they must agree.
#   7. Every ServiceAccount subject namespace is likewise a real, declared namespace.
#
# WHAT THIS DOES NOT PROVE: nothing here contacts a cluster, so it cannot show the
# grant actually authorizes the probe at runtime. It also CANNOT see the OTHER half of
# this bug, which lives in another repo — hugmesh-admin-bff-api's
# Fabric8PlatformCapabilityProbe.ARGOCD_NAMESPACE is still the string "argocd". Until
# that constant becomes "devops" the probe's Deployment leg still cannot fire; this test
# guards the GRANT half only. It does NOT test the ArgoCD admin dashboard.
#
# NON-VACUITY. The deriver below is a python program whose stdout this script parses.
# An exception in it used to leave the report EMPTY and this suite exited 0 printing
# "0 passed, 0 failed" — the silent-green shape the house rules forbid, and it hid both
# a YAML SyntaxError and a UnicodeDecodeError under review. Three things now close it:
# the deriver's rc is checked, its stderr is captured and any byte of it is a FAILURE,
# and the number of PASS/FAIL rows it emitted is asserted to be non-zero.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RBAC="${REPO}/specs/cluster/manifests/admin-bff-platform-capability-rbac/rbac.yaml"
APP="${REPO}/specs/cluster/apps/31a-admin-bff-platform-capability-rbac.yaml"
NSFILE="${REPO}/specs/cluster/namespaces/namespaces.yaml"
BOOT="${REPO}/specs/cluster/bootstrap/bootstrap.sh"
BOOTKIND="${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"

P=0; F=0; ASSERTS=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== admin-bff platform-capability probe RBAC: namespace reality check =="

# Loud, named failures — never a silent skip.
for f in "${RBAC}" "${APP}" "${NSFILE}" "${BOOT}" "${BOOTKIND}"; do
  [ -f "${f}" ] || { echo "  FAIL required input missing: ${f}"; exit 1; }
done
command -v python3 >/dev/null || { echo "  FAIL python3 unavailable — cannot parse the manifests; NOT skipping"; exit 1; }
python3 -c 'import yaml' 2>/dev/null \
  || { echo "  FAIL python3 yaml (PyYAML) unavailable — cannot parse the manifests; NOT skipping"; exit 1; }

ERRF="$(mktemp)" || { echo "  FAIL cannot create a temp file for the deriver's stderr"; exit 1; }
REPORT="$(python3 - "${REPO}" "${RBAC}" "${APP}" "${NSFILE}" "${BOOT}" "${BOOTKIND}" 2>"${ERRF}" <<'PY'
import os, re, sys, yaml

repo, rbac_p, app_p, ns_p, boot_p, bootkind_p = sys.argv[1:7]
out = []
def emit(status, msg): out.append(f"{status}\t{msg}")
def flush():
    print("\n".join(out))

def load_docs(path, label):
    """Parse a manifest, turning ANY failure into a FAIL ROW rather than a traceback.

    A traceback goes to stderr, leaves stdout empty, and used to read as
    '0 passed, 0 failed'. The bash side now also catches that, but a named row is
    the answer a reader can act on."""
    try:
        with open(path, encoding="utf-8") as fh:
            return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)], None
    except Exception as exc:                                  # noqa: BLE001 - deliberate
        emit("FAIL", f"{label} could not be parsed ({type(exc).__name__}: "
                     f"{str(exc).splitlines()[0][:160]}) — every assertion that reads "
                     f"it would otherwise pass vacuously")
        return None, exc

# ── Inventory: WHO creates each namespace, and WHEN ────────────────────────────
# The only thing that makes a namespace usable by THIS Application is that it
# already exists when the Application first reconciles. Exactly one source can
# promise that: specs/cluster/namespaces/namespaces.yaml, which BOTH bootstraps
# `kubectl apply` before ArgoCD is even installed (bootstrap.sh:19,
# bootstrap-kind.sh:265). Every other creator is recorded for the report but does
# NOT satisfy the rule:
#   * an Application with CreateNamespace=true creates the namespace only when IT
#     syncs, which is unordered with respect to 31a — and apps/55-velero.yaml is
#     deliberately NON-automated, so on a mesh nobody has synced it that never
#     happens at all;
#   * the kind-local bootstrap's imperative ensure-namespaces loops run only on the
#     kind lane; bootstrap.sh applies namespaces.yaml and nothing else, so an
#     imperative-only namespace is a phantom on every real mesh.
# Deriving the rule this way (rather than "is it mentioned anywhere?") is what makes
# deleting a namespace from namespaces.yaml alone go RED.
inventory = {}     # ns -> namespaces.yaml            (pre-ArgoCD; the rule)
other_mf  = {}     # ns -> other `kind: Namespace` manifests (ArgoCD-applied)
argo_made = {}     # ns -> Applications with CreateNamespace=true
boot_made = {}     # ns -> bootstrap ensure-namespaces loops
def add(bucket, ns, src): bucket.setdefault(str(ns), set()).add(src)

ns_rel = os.path.relpath(ns_p, repo)
for root, _dirs, files in os.walk(os.path.join(repo, "specs")):
    for fn in files:
        if not fn.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(root, fn)
        rel = os.path.relpath(path, repo)
        try:
            with open(path, encoding="utf-8") as fh:
                mdocs = list(yaml.safe_load_all(fh))
        except Exception:
            continue  # non-manifest / templated YAML: other tests own those
        for d in mdocs:
            if not isinstance(d, dict):
                continue
            if d.get("kind") == "Namespace":
                name = (d.get("metadata") or {}).get("name")
                if name:
                    add(inventory if rel == ns_rel else other_mf, name, rel)
            if d.get("kind") == "Application":
                spec = d.get("spec") or {}
                opts = ((spec.get("syncPolicy") or {}).get("syncOptions")) or []
                dest = (spec.get("destination") or {}).get("namespace")
                if dest and any(str(o).strip() == "CreateNamespace=true" for o in opts):
                    auto = "automated" if (spec.get("syncPolicy") or {}).get("automated") \
                           else "NON-automated"
                    add(argo_made, dest, f"{rel} [{auto}]")

for p in (boot_p, bootkind_p):
    rel = os.path.relpath(p, repo)
    try:
        src = open(p, encoding="utf-8").read()
    except Exception as exc:                                  # noqa: BLE001
        emit("FAIL", f"{rel} could not be read ({type(exc).__name__})")
        flush(); sys.exit(1)
    for m in re.finditer(r"for\s+ns\s+in\s+(.*?)\s*;\s*do", src, re.S):
        for tok in m.group(1).replace("\\\n", " ").split():
            if re.fullmatch(r"[a-z0-9][a-z0-9-]*", tok):
                add(boot_made, tok, f"{rel} (ensure-namespaces loop)")
    for m in re.finditer(r"kubectl\s+create\s+namespace\s+([a-z0-9][a-z0-9-]*)", src):
        add(boot_made, m.group(1), f"{rel} (kubectl create namespace)")

real = set(inventory) | set(other_mf) | set(argo_made) | set(boot_made)
if not inventory:
    emit("FAIL", f"{ns_rel} declared ZERO namespaces — the deriver broke or the "
                 f"inventory was emptied; every assertion below would pass vacuously")
    flush(); sys.exit(1)
if not real:
    emit("FAIL", "derived namespace inventory is EMPTY — the deriver broke, "
                 "every assertion below would pass vacuously")
    flush(); sys.exit(1)
emit("INFO", f"{ns_rel} declares {len(inventory)} pre-ArgoCD namespaces "
             f"({', '.join(sorted(inventory))}); {len(real)} namespaces are created "
             f"by some source anywhere under specs/")

# ── PREMISE: the Application still syncs CreateNamespace=false ──────────────────
app_docs, err = load_docs(app_p, "the probe-RBAC Application (apps/31a-…)")
if app_docs is not None:
    apps = [d for d in app_docs if d.get("kind") == "Application"]
    if len(apps) != 1:
        emit("FAIL", f"expected exactly ONE Application in {os.path.basename(app_p)}, "
                     f"found {len(apps)} — cannot pin the sync premise")
    else:
        opts = [str(o).strip() for o in
                (((apps[0].get("spec") or {}).get("syncPolicy") or {}).get("syncOptions") or [])]
        if "CreateNamespace=false" in opts:
            emit("PASS", "the probe-RBAC Application still syncs CreateNamespace=false — "
                         "the premise of every namespace assertion below holds")
        else:
            emit("FAIL", f"the probe-RBAC Application no longer syncs CreateNamespace=false "
                         f"(syncOptions={opts}) — this guard is now measuring the wrong "
                         f"property; re-derive it before changing the number")

# ── The RBAC file under guard ───────────────────────────────────────────────────
docs, err = load_docs(rbac_p, "the probe RBAC")
if docs is None:
    flush(); sys.exit(1)
if not docs:
    emit("FAIL", "probe RBAC parsed to ZERO documents — assertions would be vacuous")
    flush(); sys.exit(1)
emit("INFO", f"probe RBAC parsed: {len(docs)} documents")

def other_sources(ns):
    bits = []
    for label, bucket in (("Namespace manifest", other_mf),
                          ("Application CreateNamespace=true", argo_made),
                          ("bootstrap", boot_made)):
        if ns in bucket:
            bits.append(f"{label}: " + ", ".join(sorted(bucket[ns])))
    return "; ".join(bits) or "nothing, anywhere"

def check_ns(ns, what):
    """The namespace must PRE-EXIST this Application's first reconcile."""
    if ns in inventory:
        emit("PASS", f"{what} -> namespace '{ns}' is declared in {ns_rel}, which both "
                     f"bootstraps apply BEFORE ArgoCD exists")
    elif ns in real:
        emit("FAIL", f"{what} -> namespace '{ns}' is NOT declared in {ns_rel}. Its only "
                     f"creators are [{other_sources(ns)}], none of which is guaranteed to "
                     f"have run when this CreateNamespace=false Application first "
                     f"reconciles — so the sync fails with `namespaces \"{ns}\" not found`")
    else:
        emit("FAIL", f"{what} -> namespace '{ns}', which this platform NEVER creates "
                     f"— with CreateNamespace=false this can never apply")

NAMESPACED = {"Role", "RoleBinding"}
checked_ns = 0
for d in docs:
    kind = d.get("kind"); md = d.get("metadata") or {}
    name = md.get("name"); ns = md.get("namespace")
    if kind in NAMESPACED:
        checked_ns += 1
        if not ns:
            emit("FAIL", f"{kind}/{name} is namespaced but declares no namespace")
        else:
            check_ns(ns, f"{kind}/{name}")
    # subjects must also live in a real namespace
    for s in d.get("subjects") or []:
        if not isinstance(s, dict):
            continue
        sns = s.get("namespace")
        if s.get("kind") == "ServiceAccount" and sns:
            check_ns(sns, f"{kind}/{name} subject ServiceAccount/{s.get('name')}")

if checked_ns == 0:
    emit("FAIL", "no namespaced Role/RoleBinding found in the probe RBAC — "
                 "the guard matched nothing and proved nothing")
else:
    emit("PASS", f"{checked_ns} namespaced RBAC resources checked")

# ── PAIRING: a RoleBinding binds a Role IN ITS OWN NAMESPACE ────────────────────
# RBAC is namespace-local: a RoleBinding can only reference a Role in the SAME
# namespace. Moving one of the pair leaves a binding that resolves to nothing, and
# Kubernetes applies it without complaint — the half-applied form of the very fix
# this file guards.
roles = [d for d in docs if d.get("kind") == "Role"]
bindings = [d for d in docs if d.get("kind") == "RoleBinding"]
role_index = {((d.get("metadata") or {}).get("namespace"),
               (d.get("metadata") or {}).get("name")) for d in roles}
if not bindings:
    emit("FAIL", "no RoleBinding in the probe RBAC — the Roles grant nothing to anyone")
else:
    broken = []
    for b in bindings:
        md = b.get("metadata") or {}
        bns, bname = md.get("namespace"), md.get("name")
        ref = b.get("roleRef") or {}
        if ref.get("kind") != "Role":
            continue
        if (bns, ref.get("name")) not in role_index:
            broken.append(f"RoleBinding/{bname} in '{bns}' references Role/"
                          f"{ref.get('name')}, which does not exist in '{bns}'")
    if broken:
        for b in broken:
            emit("FAIL", b + " — RBAC is namespace-local, so this binding grants NOTHING")
    else:
        emit("PASS", f"all {len(bindings)} RoleBinding(s) reference a Role that exists "
                     f"in their OWN namespace")

role_ns_set = {(d.get("metadata") or {}).get("namespace") for d in roles}
bind_ns_set = {(d.get("metadata") or {}).get("namespace") for d in bindings}
if role_ns_set != bind_ns_set:
    emit("FAIL", f"Role namespaces {sorted(x for x in role_ns_set if x)} != RoleBinding "
                 f"namespaces {sorted(x for x in bind_ns_set if x)} — one half of a pair "
                 f"was moved; a Role nobody binds grants nothing and a RoleBinding with "
                 f"no Role binds nothing")
else:
    emit("PASS", f"Role and RoleBinding namespace sets are IDENTICAL "
                 f"({sorted(x for x in role_ns_set if x)}) — neither half was moved alone")

# ── The specific phantom ────────────────────────────────────────────────────────
raw_ns = {(d.get("metadata") or {}).get("namespace") for d in docs}
raw_ns.discard(None)
if "argocd" in raw_ns:
    emit("FAIL", "a resource still targets the 'argocd' namespace; this platform "
                 "installs ArgoCD into 'devops'")
else:
    emit("PASS", "no resource targets the phantom 'argocd' namespace")

# ── Two-sided: RBAC's argocd-server namespace == bootstrap's ARGOCD_NS ──────────
argocd_ns_defaults = set()
for p in (boot_p, bootkind_p):
    for m in re.finditer(r'ARGOCD_NS="\$\{ARGOCD_NS:-([a-z0-9-]+)\}"',
                         open(p, encoding="utf-8").read()):
        argocd_ns_defaults.add(m.group(1))
if len(argocd_ns_defaults) != 1:
    emit("FAIL", f"could not pin a single ARGOCD_NS default from the bootstrap scripts: "
                 f"{sorted(argocd_ns_defaults)}")
else:
    boot_ns = argocd_ns_defaults.pop()
    if boot_ns not in role_ns_set:
        emit("FAIL", f"bootstrap installs ArgoCD into '{boot_ns}' but the probe RBAC has "
                     f"no Role in that namespace (has: {sorted(x for x in role_ns_set if x)})")
    elif boot_ns not in bind_ns_set:
        emit("FAIL", f"bootstrap installs ArgoCD into '{boot_ns}' and a Role lives there, "
                     f"but NO RoleBinding does (has: {sorted(x for x in bind_ns_set if x)}) "
                     f"— the grant is unbound")
    else:
        emit("PASS", f"argocd-server Deployment grant namespace == bootstrap ARGOCD_NS "
                     f"default ('{boot_ns}'), Role AND RoleBinding — the two sides agree")

flush()
PY
)"
RC=$?

if [ "${RC}" -ne 0 ]; then
  bad "the deriver exited ${RC} — it crashed rather than reporting; NOT skipping"
fi
if [ -s "${ERRF}" ]; then
  bad "the deriver wrote to stderr — a traceback or warning was about to be discarded:"
  sed 's/^/         | /' "${ERRF}"
fi
rm -f "${ERRF}"

while IFS=$'\t' read -r status msg; do
  case "${status}" in
    PASS) ok  "${msg}"; ASSERTS=$((ASSERTS+1)) ;;
    FAIL) bad "${msg}"; ASSERTS=$((ASSERTS+1)) ;;
    INFO) echo "  ---- ${msg}" ;;
    *)    [ -n "${status}" ] && bad "unparsed deriver output: ${status} ${msg}" ;;
  esac
done <<< "${REPORT}"

# NON-VACUITY GATE. Without this an exception in the deriver printed
# "== 0 passed, 0 failed ==" and exited 0.
if [ "${ASSERTS}" -eq 0 ]; then
  bad "the deriver emitted NO PASS/FAIL rows — it produced no verdict at all; NOT skipping"
fi

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
