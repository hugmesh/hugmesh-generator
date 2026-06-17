#!/usr/bin/env bash
# test-appset.sh — logic test for the NODE-STORAGE ApplicationSet (node-storage PR7).
# Runs ANYWHERE with bash + python3(yaml). NO live ArgoCD. Validates the 13b ApplicationSet
# is modelled on 13a (list generator + state-selector + prune:true), ships INERT (zero
# elements), and that the selector lever does what the design requires (active -> rendered,
# revoked -> pruned). The selector semantics are exercised by replaying ArgoCD's documented
# list-generator + matchLabels filter in python (the same filter ArgoCD applies).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPSET="${REPO}/specs/cluster/apps/13b-node-storage.yaml"
APPSET_13A="${REPO}/specs/cluster/apps/13a-optional-services.yaml"
OVERLAY="${REPO}/specs/cluster/manifests/node-storage-placement"

command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "pyyaml required"; exit 2; }
[ -r "${APPSET}" ] || { echo "missing ${APPSET}"; exit 2; }

echo "== node-storage PR7: apps/13b ApplicationSet =="
python3 - "$APPSET" "$APPSET_13A" "$OVERLAY" <<'PY'
import sys, yaml, os
appset_p, a13a_p, overlay = sys.argv[1], sys.argv[2], sys.argv[3]
P=[0]; F=[0]
def ok(m): print("  PASS "+m); P[0]+=1
def bad(m): print("  FAIL "+m); F[0]+=1
def check(cond, okmsg, badmsg):
    ok(okmsg) if cond else bad(badmsg)

a = yaml.safe_load(open(appset_p))

# 1. it IS an ApplicationSet named node-storage in devops.
check(a.get("kind")=="ApplicationSet" and a["metadata"]["name"]=="node-storage" and a["metadata"]["namespace"]=="devops",
      "13b is an ApplicationSet 'node-storage' in devops", "13b must be ApplicationSet node-storage/devops")

gens = a["spec"]["generators"]
listgen = gens[0]["list"]

# 2. ships INERT: zero elements.
check(listgen.get("elements")==[], "ships INERT: elements: [] (zero placements = today's behaviour)", "elements must be empty (inert): %r" % listgen.get("elements"))

# 3. selector gates on state:active (the place/unplace lever), like 13a's installed:true.
sel = gens[0]["selector"]["matchLabels"]
check(sel=={"state":"active"}, "generator selector matchLabels state:active (the place/unplace lever)", "selector must be {state: active}: %r" % sel)

# 4. prune:true (a revoked assignment's Application is pruned).
sp = a["spec"]["template"]["spec"]["syncPolicy"]["automated"]
check(sp.get("prune") is True, "syncPolicy automated prune:true (revoke -> placement pruned)", "prune must be true")

# 5. template name keyed on the assignment id (unique per assignment).
nm = a["spec"]["template"]["metadata"]["name"]
check("{{ .id }}" in nm, "template name keyed on assignment id: %s" % nm, "template name must include .id: %s" % nm)

# 6. the source path is the placement overlay (nodeAffinity + PVC injection).
path = a["spec"]["template"]["spec"]["source"]["path"]
check(path.endswith("node-storage-placement"), "source path is the placement overlay (nodeAffinity+PVC)", "source path wrong: %s" % path)

# 7. modelled on 13a: same generator SHAPE (a single list generator + a sibling selector +
#    prune:true). Compare structural keys, not values.
b = yaml.safe_load(open(a13a_p))
def shape(doc):
    g = doc["spec"]["generators"][0]
    return ("list" in g, "selector" in g,
            doc["spec"]["template"]["spec"]["syncPolicy"]["automated"].get("prune"))
check(shape(a)==shape(b), "modelled on 13a: list-generator + sibling selector + prune:true", "13b generator shape diverges from 13a: %r vs %r" % (shape(a), shape(b)))

# 8. SELECTOR LEVER semantics — replay ArgoCD's list-generator + matchLabels filter.
def argocd_select(elements, match):
    # ArgoCD keeps an element iff ALL matchLabels key==value (string compare).
    return [e for e in elements if all(str(e.get(k))==str(v) for k,v in match.items())]
elems = [
    {"id":"a-1","service":"owncast","state":"active"},
    {"id":"a-2","service":"db","state":"revoked"},   # a revoked assignment
]
kept = argocd_select(elems, sel)
check(len(kept)==1 and kept[0]["id"]=="a-1", "selector keeps ACTIVE assignment, drops the revoked one (place vs unplace)", "selector lever wrong: kept=%r" % kept)
# a single active element renders exactly one Application name.
name_for = a["spec"]["template"]["metadata"]["name"].replace("{{ .id }}", kept[0]["id"]).replace("{{ .service }}","").strip()
check("node-storage-a-1" == a["spec"]["template"]["metadata"]["name"].replace("{{ .id }}", "a-1"), "an ACTIVE assignment renders Application node-storage-<id>", "application name render wrong")

# 9. the placement overlay exists with the PVC + nodeAffinity patch + kustomization.
for f in ("kustomization.yaml","pvc.yaml","placement-patch.yaml"):
    check(os.path.isfile(os.path.join(overlay,f)), "placement overlay has %s" % f, "placement overlay missing %s" % f)
pvc = yaml.safe_load(open(os.path.join(overlay,"pvc.yaml")))
check(pvc["kind"]=="PersistentVolumeClaim" and pvc["spec"]["storageClassName"]=="snapdragon-local", "PVC binds the node-pinned snapdragon-local StorageClass (WaitForFirstConsumer)", "PVC must use snapdragon-local")
patch = yaml.safe_load(open(os.path.join(overlay,"placement-patch.yaml")))
na = patch["spec"]["template"]["spec"]["affinity"]["nodeAffinity"]
keys = [m["key"] for term in na["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"] for m in term["matchExpressions"]]
check("kubernetes.io/hostname" in keys, "placement patch pins the pod to the pool's node via nodeAffinity (PV binds to correct node)", "placement patch must pin kubernetes.io/hostname")

print()
print("node-storage PR7 appset: %d passed, %d failed" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
echo "---EXIT $?---"