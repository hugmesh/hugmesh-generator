#!/usr/bin/env bash
# test-casdoor-domains-appset.sh — static gate for the per-domain Casdoor lane
# (issue #47, Domain.idp=own; docs/DOMAIN-IDP.md).
#
# THE FAILURE MODES THIS PINS, each shipped-or-nearly-shipped elsewhere in this
# repo and named at its check:
#   [scaffold]   the casdoor-domains ApplicationSet must carry ZERO elements in
#                git (the 13a-optional-services scaffold rule): a committed
#                element deploys an IdP for a domain nobody created, and — worse
#                — fights the runtime writer for the list.
#   [keystone]   BOTH roots (app-of-apps.yaml + apps/00-app-of-apps-waved.yaml)
#                must carry the casdoor-domains ignoreDifferences entry AND the
#                RespectIgnoreDifferences sync option. Without either half,
#                selfHeal reverts every runtime element write and the whole
#                add/remove mechanism is a silent no-op (docs/OPTIONAL-SERVICES.md
#                §7/§10 — the exact defect the optional-services keystone fixed).
#   [tokenless]  the ApplicationSet TEMPLATE must keep the literal GitHub
#                repoURL + `targetRevision: main`, and the file must be in
#                bootstrap-kind.sh's KIND_PROFILE=sso curated set — the issue-#48
#                sed retarget reaches ONLY bootstrap-applied files, and only on
#                those exact literals (PR #58 contract).
#   [pvc-prune]  the base's PVC must carry Prune=false: element removal prunes
#                the whole instance, and the PVC annotation is the only thing
#                between an accidental de-list and deleted identity data.
#   [placeholder] every ExternalSecret remoteRef key in the base must be the
#                classified placeholder hugmesh/casdoor-domain — the exact key
#                tests/scripts/eso_seed_contract.py excuses under
#                OPERATOR_SEEDED_PATHS; a drifted key resurrects the
#                never-materializing-Secret outage that gate exists to stop.
#   [base]       the base pins NO namespace anywhere (the per-domain namespace
#                arrives via the Application's kustomize.namespace) and every
#                kustomize-patch target/path in the ApplicationSet resolves to a
#                real object/field in the base — a typo'd patch target fails
#                every domain's sync at once, at runtime, on the live mesh.
#
# NEGATIVE CONTROLS: each structural check is re-run against a deliberately
# corrupted copy of the tree and must bite — a gate that cannot go red is
# theater (the repo's standing rule; see test-cluster-manifest-integrity.sh).
#
# Offline: bash + python3 + PyYAML. No cluster, no kubectl, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
CLUSTER="${REPO}/specs/cluster"
BOOT="${CLUSTER}/bootstrap/kind-local/bootstrap-kind.sh"

. "${HERE}/../lib/guard-preflight.sh"
guard_require_tools python3 sed grep
python3 -c 'import yaml' 2>/dev/null || {
  if guard_skip_allowed; then
    echo "SKIP (deliberate): python3 has no PyYAML"; exit 0
  fi
  echo "FATAL: python3 lacks PyYAML (pip install pyyaml) — refusing to skip" >&2
  exit 1
}

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# ── the checker: <specs/cluster dir> <bootstrap-kind.sh path> ────────────────
# Prints its findings; exit 0 = every invariant holds. Run once against the real
# tree (must pass) and against corrupted copies (must fail).
check() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml, re, os

cluster, boot = sys.argv[1], sys.argv[2]
bad = []

def load_all(p):
    with open(p, encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh) if d]

# ── the ApplicationSet ────────────────────────────────────────────────────────
appset_path = os.path.join(cluster, "apps", "05b-casdoor-domains.yaml")
try:
    docs = load_all(appset_path)
except Exception as e:
    print("FAIL [appset] cannot parse %s: %s" % (appset_path, e)); sys.exit(1)
appsets = [d for d in docs if d.get("kind") == "ApplicationSet"]
if len(appsets) != 1:
    print("FAIL [appset] expected exactly one ApplicationSet in 05b, got %d" % len(appsets)); sys.exit(1)
a = appsets[0]
spec = a.get("spec") or {}
if (a.get("metadata") or {}).get("name") != "casdoor-domains":
    bad.append("[appset] name is not casdoor-domains")
if spec.get("goTemplate") is not True:
    bad.append("[appset] goTemplate must be true")
if "missingkey=error" not in (spec.get("goTemplateOptions") or []):
    bad.append("[appset] goTemplateOptions must carry missingkey=error")
gens = spec.get("generators") or []
lst = (gens[0].get("list") if gens else None) or {}
if lst.get("elements") != []:
    bad.append("[scaffold] generators[0].list.elements must be [] in git "
               "(the 13a scaffold rule; the build bake / DomainReconciler are the writers)")
sel = ((gens[0].get("selector") if gens else None) or {}).get("matchLabels") or {}
if sel.get("idp") != "own":
    bad.append("[appset] generator selector must be matchLabels idp: \"own\"")
tpl = spec.get("template") or {}
tsrc = (tpl.get("spec") or {}).get("source") or {}
if tsrc.get("repoURL") != "https://github.com/hugmesh/hugmesh-generator.git":
    bad.append("[tokenless] template repoURL must be the literal GitHub URL (the #48 sed contract)")
if tsrc.get("targetRevision") != "main":
    bad.append("[tokenless] template targetRevision must be the literal 'main'")
if tsrc.get("path") != "specs/cluster/manifests/casdoor-domain":
    bad.append("[appset] template source path must be specs/cluster/manifests/casdoor-domain")
kust = tsrc.get("kustomize") or {}
if kust.get("namespace") != "{{ .nsPrefix }}-pki":
    bad.append("[appset] template kustomize.namespace must be '{{ .nsPrefix }}-pki'")
tdst = ((tpl.get("spec") or {}).get("destination") or {})
if tdst.get("namespace") != "{{ .nsPrefix }}-pki":
    bad.append("[appset] template destination namespace must be '{{ .nsPrefix }}-pki'")
tsync = ((tpl.get("spec") or {}).get("syncPolicy") or {}).get("automated") or {}
if tsync.get("prune") is not True:
    bad.append("[appset] template syncPolicy.automated.prune must be true (element removal = GC)")
wave = ((tpl.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-wave")
if wave != "1":
    bad.append("[appset] template sync-wave must be \"1\" (IdP before consumers — the 06-casdoor-games rule)")

# ── patch targets resolve against the base ───────────────────────────────────
base = os.path.join(cluster, "manifests", "casdoor-domain")
objs = {}
for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
    if not name.endswith((".yaml", ".yml")):
        continue
    for d in load_all(os.path.join(base, name)):
        meta = d.get("metadata") or {}
        objs[(d.get("kind"), meta.get("name"))] = (d, name)
        if meta.get("namespace"):
            bad.append("[base] %s %s pins metadata.namespace %r — the per-domain "
                       "namespace must come from kustomize.namespace only"
                       % (d.get("kind"), meta.get("name"), meta["namespace"]))
kz = os.path.join(base, "kustomization.yaml")
try:
    kzdoc = yaml.safe_load(open(kz, encoding="utf-8")) or {}
except Exception as e:
    kzdoc = {}
    bad.append("[base] cannot parse %s: %s" % (kz, e))
if kzdoc.get("namespace"):
    bad.append("[base] kustomization.yaml pins namespace %r" % kzdoc["namespace"])
for r in kzdoc.get("resources") or []:
    if not os.path.exists(os.path.join(base, r)):
        bad.append("[base] kustomization resource %r does not exist" % r)

def jptr_exists(doc, ptr):
    cur = doc
    for seg in ptr.lstrip("/").split("/"):
        if isinstance(cur, list):
            try:
                cur = cur[int(seg)]
            except (ValueError, IndexError):
                return False
        elif isinstance(cur, dict):
            if seg not in cur:
                return False
            cur = cur[seg]
        else:
            return False
    return True

for p in kust.get("patches") or []:
    tgt = p.get("target") or {}
    key = (tgt.get("kind"), tgt.get("name"))
    if key not in objs:
        bad.append("[base] patch target %s/%s names no object in the base" % key)
        continue
    doc, fname = objs[key]
    try:
        ops = yaml.safe_load(p.get("patch") or "") or []
    except Exception as e:
        bad.append("[appset] unparseable patch for %s/%s: %s" % (key + (e,)))
        continue
    for op in ops:
        if op.get("op") == "replace" and not jptr_exists(doc, op.get("path", "")):
            bad.append("[base] patch path %s missing in %s/%s (%s) — a replace "
                       "on an absent path fails every domain's sync"
                       % (op.get("path"), key[0], key[1], fname))
        # an ADD needs its PARENT: adding a key under a map the base never declares
        # fails every domain's sync exactly like a replace on an absent path
        if op.get("op") == "add":
            parent = op.get("path", "").rsplit("/", 1)[0]
            if not jptr_exists(doc, parent):
                bad.append("[base] patch add-parent %s missing in %s/%s (%s) — an "
                           "add under an absent map fails every domain's sync"
                           % (parent, key[0], key[1], fname))

# ── PVC prune protection ──────────────────────────────────────────────────────
pvcs = [(k, v) for k, v in objs.items() if k[0] == "PersistentVolumeClaim"]
if not pvcs:
    bad.append("[pvc-prune] the base carries no PVC at all")
for (kind, name), (doc, fname) in pvcs:
    ann = ((doc.get("metadata") or {}).get("annotations") or {})
    if "Prune=false" not in str(ann.get("argocd.argoproj.io/sync-options", "")):
        bad.append("[pvc-prune] PVC %s (%s) lacks argocd.argoproj.io/sync-options "
                   "Prune=false — element removal would delete identity data" % (name, fname))

# ── ExternalSecret placeholder keys ──────────────────────────────────────────
es_keys = set()
for (kind, name), (doc, fname) in objs.items():
    if kind != "ExternalSecret":
        continue
    for e in ((doc.get("spec") or {}).get("data") or []):
        es_keys.add(((e.get("remoteRef") or {}).get("key")))
if not es_keys:
    bad.append("[placeholder] the base declares no ExternalSecret data at all")
elif es_keys != {"hugmesh/casdoor-domain"}:
    bad.append("[placeholder] ExternalSecret remoteRef keys %s != {'hugmesh/casdoor-domain'} "
               "(the OPERATOR_SEEDED_PATHS-classified placeholder)" % sorted(es_keys))

# ── the keystone on BOTH roots ───────────────────────────────────────────────
for root_rel in ("app-of-apps.yaml", os.path.join("apps", "00-app-of-apps-waved.yaml")):
    rp = os.path.join(cluster, root_rel)
    try:
        rdocs = load_all(rp)
    except Exception as e:
        bad.append("[keystone] cannot parse %s: %s" % (root_rel, e))
        continue
    apps = [d for d in rdocs if d.get("kind") == "Application"]
    if not apps:
        bad.append("[keystone] %s carries no Application" % root_rel)
        continue
    r = apps[0].get("spec") or {}
    if "RespectIgnoreDifferences=true" not in (r.get("syncPolicy") or {}).get("syncOptions", []):
        bad.append("[keystone] %s lacks RespectIgnoreDifferences=true" % root_rel)
    hit = False
    for ig in r.get("ignoreDifferences") or []:
        if (ig.get("kind") == "ApplicationSet" and ig.get("name") == "casdoor-domains"
                and "/spec/generators/0/list/elements" in (ig.get("jsonPointers") or [])):
            hit = True
    if not hit:
        bad.append("[keystone] %s lacks the casdoor-domains ignoreDifferences entry "
                   "(jsonPointers /spec/generators/0/list/elements) — selfHeal would "
                   "revert every runtime element write" % root_rel)

# ── kind curated set (the tokenless sed reach) ───────────────────────────────
boot_text = open(boot, encoding="utf-8").read()
m = re.search(r"^SSO_APPS=\((.*?)^\)", boot_text, re.M | re.S)
# Strip comments first (the closure gate's list_profile does the same): a
# commented-out entry is NOT membership.
sso_body = re.sub(r"#.*", "", m.group(1)) if m else ""
if "05b-casdoor-domains.yaml" not in sso_body:
    bad.append("[tokenless] bootstrap-kind.sh SSO_APPS does not list "
               "05b-casdoor-domains.yaml — the #48 sed retarget never reaches "
               "its template and kind-generated Applications cannot fetch")

for b in bad:
    print("FAIL %s" % b)
if bad:
    sys.exit(1)
print("ok: casdoor-domains lane invariants hold "
      "(%d base objects, %d kustomize patches checked)" % (len(objs), len(kust.get("patches") or [])))
PY
}

echo "== casdoor-domains per-domain-IdP gate =="

# ── 1) the real tree must pass ───────────────────────────────────────────────
if out="$(check "${CLUSTER}" "${BOOT}" 2>&1)"; then
  ok "real tree: ${out##*$'\n'}"
else
  echo "${out}" | sed 's/^/     /'
  bad "real tree violates the casdoor-domains lane invariants (above)"
fi

# ── 2) negative controls: each corruption must go RED ────────────────────────
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

corrupt() { # <label> <sed-script> <target-rel-under-specs/cluster or BOOT>
  local label="$1" script="$2" rel="$3"
  local croot="${WORK}/${label}"
  mkdir -p "${croot}"
  cp -a "${CLUSTER}" "${croot}/cluster"
  local cboot="${croot}/cluster/bootstrap/kind-local/bootstrap-kind.sh"
  if [ "${rel}" = "BOOT" ]; then
    sed -i -e "${script}" "${cboot}"
  else
    sed -i -e "${script}" "${croot}/cluster/${rel}"
  fi
  if check "${croot}/cluster" "${cboot}" >/dev/null 2>&1; then
    bad "control '${label}' did NOT bite — the gate cannot go red on this corruption"
  else
    ok "control '${label}' bites"
  fi
}

# a committed element (scaffold violation)
corrupt "scaffold-element" \
  's|elements: \[\]|elements: [{slug: rogue, clusterDomain: rogue.test, casdoorOrg: rogue, nsPrefix: rogue, selinuxLevel: "s0:c99", selinuxLevelPg: "s0:c100", idp: "own"}]|' \
  "apps/05b-casdoor-domains.yaml"
# keystone dropped from the recurse root
corrupt "keystone-dropped" \
  's|name: casdoor-domains|name: casdoor-domains-GONE|' \
  "app-of-apps.yaml"
# tokenless literal reworded in the template
corrupt "tokenless-reworded" \
  's|repoURL: https://github.com/hugmesh/hugmesh-generator.git|repoURL: https://example.com/fork.git|' \
  "apps/05b-casdoor-domains.yaml"
# PVC prune protection dropped
corrupt "pvc-prune-dropped" \
  's|argocd.argoproj.io/sync-options: Prune=false|argocd.argoproj.io/sync-options: Replace=true|' \
  "manifests/casdoor-domain/pg.yaml"
# ESO placeholder key drifted away from the classified path
corrupt "eso-key-drift" \
  's|key: hugmesh/casdoor-domain|key: hugmesh/casdoor-typo|' \
  "manifests/casdoor-domain/external-secrets.yaml"
# curated-set membership dropped
corrupt "kind-set-dropped" \
  's|^  05b-casdoor-domains.yaml$|  # 05b-casdoor-domains.yaml|' \
  "BOOT"
# a patch path that resolves nowhere in the base
corrupt "patch-path-typo" \
  's|path: /data/CASDOOR_ORIGIN|path: /data/CASDOOR_ORIGIN_TYPO|' \
  "apps/05b-casdoor-domains.yaml"

# an add whose parent map the base never declares (the pod domain label's add)
corrupt "add-parent-missing" \
  's|path: /spec/template/metadata/labels/hugmesh.net~1domain|path: /spec/template/metadata/labelz/hugmesh.net~1domain|' \
  "apps/05b-casdoor-domains.yaml"

echo "== ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
