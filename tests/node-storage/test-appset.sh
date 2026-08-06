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

# The 13b generator is a ConfigMap-source matrix: a SOURCE list element carrying the
# `elements` JSON-array string mirrored from the node-storage-assignments ConfigMap, paired
# with an expansion list that parses it via elementsYaml.
matrix = gens[0]["matrix"]
mgens = matrix["generators"]
source_gen = mgens[0]["list"]
expand_gen = mgens[1]["list"]

# 2a. ConfigMap-source: the source step carries an `elements` JSON-array string (the ConfigMap
#     .data.elements mirror), and the expansion step parses it via elementsYaml.
src_elems = source_gen.get("elements")
check(isinstance(src_elems, list) and len(src_elems)==1 and "elements" in src_elems[0],
      "ConfigMap-source: source list carries the node-storage-assignments `elements` key",
      "source list must carry an `elements` key (the ConfigMap mirror): %r" % src_elems)
check(expand_gen.get("elementsYaml")=="{{ .elements }}",
      "expansion via elementsYaml '{{ .elements }}' (parses the ConfigMap JSON array)",
      "expansion must be elementsYaml '{{ .elements }}': %r" % expand_gen.get("elementsYaml"))

# 2b. ships INERT: the source `elements` value is the empty JSON array `[]` (zero placements).
check(src_elems[0].get("elements")=="[]",
      "ships INERT: source elements value is `[]` (empty ConfigMap => zero placements)",
      "source elements must default to '[]' (inert): %r" % src_elems[0].get("elements"))

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

# 7. modelled on 13a: a sibling state-selector + prune:true (13b adds the ConfigMap-source
#    matrix wrapper around the proven list-generator + selector + prune lever).
b = yaml.safe_load(open(a13a_p))
g13a = b["spec"]["generators"][0]
check("list" in g13a and "selector" in g13a, "13a is the proven list-generator + sibling selector pattern", "13a shape unexpected")
# 13b wraps the same list mechanism in a matrix (ConfigMap-source) but keeps the SAME sibling
# selector + prune:true lever.
check("selector" in gens[0]
      and a["spec"]["template"]["spec"]["syncPolicy"]["automated"].get("prune") is True
      and b["spec"]["template"]["spec"]["syncPolicy"]["automated"].get("prune") is True,
      "modelled on 13a: sibling state-selector + prune:true (matrix-wrapped list source)",
      "13b must keep the 13a sibling selector + prune:true lever")

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
check(pvc["kind"]=="PersistentVolumeClaim" and pvc["spec"]["storageClassName"]=="hugmesh-local", "PVC binds the node-pinned hugmesh-local StorageClass (WaitForFirstConsumer)", "PVC must use hugmesh-local")
patch = yaml.safe_load(open(os.path.join(overlay,"placement-patch.yaml")))
na = patch["spec"]["template"]["spec"]["affinity"]["nodeAffinity"]
keys = [m["key"] for term in na["requiredDuringSchedulingIgnoredDuringExecution"]["nodeSelectorTerms"] for m in term["matchExpressions"]]
check("kubernetes.io/hostname" in keys, "placement patch pins the pod to the pool's node via nodeAffinity (PV binds to correct node)", "placement patch must pin kubernetes.io/hostname")

print()
print("node-storage PR7 appset: %d passed, %d failed" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
# The python leg's exit status IS this suite's verdict. It used to be echoed and
# then thrown away — `echo "---EXIT $?---"` is the LAST command, so the script
# exited with echo's status (always 0) and node-storage-verify's fourth leg could
# not fail no matter how badly 13b drifted. Capture, print, and RE-RAISE it.
rc=$?
echo "---EXIT ${rc}---"
exit "${rc}"