#!/usr/bin/env bash
# test-edge-ai-ollama-pin.sh — the mesh's Ollama runtime is a PINNED version, and the two
# places that name it agree.
#
# WHY. specs/cluster/manifests/edge-ai ran `ollama/ollama:latest`. A pod restart then changed
# the inference runtime under a running mesh, and an older Ollama refuses newer models at pull
# time (HTTP 412 "requires a newer version of Ollama"), so "latest" fails in both directions:
# unreproducible when it moves, stale when a cached image is reused. The image is now pinned.
# The tag lives in two files — deployment.yaml (`image:`) and kustomization.yaml (`images:`
# newTag, which rewrites the Deployment's image at render time) — and they must be the same,
# or the rendered cluster runs a different version from the one a reader sees in the Deployment.
#
# THE RULE (checked on the live tree, then on doctored copies so a broken checker cannot vouch):
#   1) the Deployment's `ollama` container image is `ollama/ollama:<MAJOR.MINOR.PATCH>`;
#   2) kustomization.yaml's `ollama/ollama` entry has newTag equal to that tag;
#   3) neither is `latest`, empty, a branch name or a digest-less floating tag.
#
# AND THE MODEL CACHE MUST BE ABLE TO BIND (same Deployment, so it lives in this already-wired
# suite). pvc.yaml named storageClassName `local-path` — the class k3s ships — while the mesh's
# only class is `hugmesh-local` (manifests/local-path). On a real cluster the claim then never
# bound ("storageclass.storage.k8s.io "local-path" not found") and the edge-ai pod never
# scheduled, even on a ready GPU node. The rule:
#   4) every PersistentVolumeClaim under manifests/edge-ai either names no storageClassName (the
#      cluster default) or names a StorageClass that some manifest under specs/cluster/manifests
#      defines.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

# problems <manifest dir> -> prints one line per violation (nothing = clean)
problems() {
  python3 - "$1" <<'PY'
import re, sys, yaml
d = sys.argv[1]
def load(name):
    with open(f"{d}/{name}") as fh:
        return [x for x in yaml.safe_load_all(fh) if x]
img = None
for doc in load("deployment.yaml"):
    if doc.get("kind") != "Deployment":
        continue
    for c in doc["spec"]["template"]["spec"].get("containers", []):
        if c.get("name") == "ollama":
            img = c.get("image")
tag = None
for doc in load("kustomization.yaml"):
    for e in doc.get("images", []) or []:
        if e.get("name") == "ollama/ollama":
            tag = e.get("newTag")
semver = re.compile(r"^\d+\.\d+\.\d+$")
if img is None:
    print("deployment.yaml has no container named ollama")
else:
    name, _, dtag = img.partition(":")
    if name != "ollama/ollama":
        print(f"deployment image is {img!r}, expected ollama/ollama:<version>")
    elif not semver.match(dtag):
        print(f"deployment image tag {dtag!r} is not a pinned MAJOR.MINOR.PATCH version")
if tag is None:
    print("kustomization.yaml has no images entry for ollama/ollama (newTag)")
elif not semver.match(str(tag)):
    print(f"kustomization newTag {tag!r} is not a pinned MAJOR.MINOR.PATCH version")
if img and tag and img.partition(":")[2] != str(tag):
    print(f"deployment tag {img.partition(':')[2]!r} differs from kustomization newTag {tag!r}")
PY
}

SRC=$REPO/specs/cluster/manifests/edge-ai
echo "== live tree"
out=$(problems "$SRC")
if [ -z "$out" ]; then ok "deployment.yaml and kustomization.yaml pin the same ollama/ollama version"; else bad "live tree: $out"; fi

# doctored copies: each must be CAUGHT
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
doctored() { # name sed-expression file
  rm -rf "$T/$1"; mkdir -p "$T/$1"; cp "$SRC/deployment.yaml" "$SRC/kustomization.yaml" "$T/$1/"
  sed -i -E "$2" "$T/$1/$3"
}
expect_caught() { # name sed file why
  doctored "$1" "$2" "$3"
  out=$(problems "$T/$1")
  if [ -n "$out" ]; then ok "negative control: $4 — caught"; else bad "negative control: $4 — NOT caught (the checker is blind to it)"; fi
}
echo "== negative controls"
expect_caught latest-deploy 's#(image: ollama/ollama):[0-9.]+#\1:latest#' deployment.yaml "Deployment back on :latest"
expect_caught latest-kustomize 's#newTag: [0-9.]+#newTag: latest#' kustomization.yaml "kustomization back on latest"
expect_caught mismatch 's#newTag: [0-9.]+#newTag: 0.1.0#' kustomization.yaml "the two files disagree"
expect_caught branch-tag 's#(image: ollama/ollama):[0-9.]+#\1:main#' deployment.yaml "a branch name as the tag"
expect_caught no-tag 's#(image: ollama/ollama):[0-9.]+#\1#' deployment.yaml "no tag at all"
expect_caught other-image 's#image: ollama/ollama:#image: example/ollama:#' deployment.yaml "a different image"
# a doctored pair that AGREES must stay clean (the checker is not just always-failing)
doctored agree 's#[0-9]+\.[0-9]+\.[0-9]+#9.9.9#' deployment.yaml
sed -i -E 's#newTag: [0-9.]+#newTag: 9.9.9#' "$T/agree/kustomization.yaml"
out=$(problems "$T/agree"); if [ -z "$out" ]; then ok "negative control: two agreeing pins at another version — clean"; else bad "agreeing pins were flagged: $out"; fi

# storage_problems <edge-ai dir> <manifests root> -> one line per PVC naming an undefined class
storage_problems() {
  python3 - "$1" "$2" <<'PY2'
import glob, os, sys, yaml
d, root = sys.argv[1], sys.argv[2]
defined = set()
for f in glob.glob(os.path.join(root, "**", "*.y*ml"), recursive=True):
    try:
        with open(f) as fh:
            docs = list(yaml.safe_load_all(fh))
    except Exception:
        continue  # templated/placeholder files are not StorageClass sources
    for x in docs:
        if isinstance(x, dict) and x.get("kind") == "StorageClass":
            defined.add((x.get("metadata") or {}).get("name"))
if not defined:
    print(f"no StorageClass is defined anywhere under {root} (the checker cannot judge)")
claims = 0
for f in sorted(glob.glob(os.path.join(d, "*.y*ml"))):
    with open(f) as fh:
        for x in yaml.safe_load_all(fh):
            if not isinstance(x, dict) or x.get("kind") != "PersistentVolumeClaim":
                continue
            claims += 1
            sc = (x.get("spec") or {}).get("storageClassName")
            if sc is not None and sc not in defined:
                print(f"{os.path.basename(f)}: PVC {x['metadata']['name']} names storageClassName {sc!r}, "
                      f"which no manifest defines (defined: {sorted(defined)})")
if claims == 0:
    print(f"no PersistentVolumeClaim found under {d} (the model cache claim is gone)")
PY2
}

MANIFESTS=$REPO/specs/cluster/manifests
echo "== model cache storage class"
out=$(storage_problems "$SRC" "$MANIFESTS")
if [ -z "$out" ]; then ok "the edge-ai model cache PVC names a StorageClass the mesh defines"; else bad "live tree: $out"; fi
doctored_pvc() { # name sed-expression
  rm -rf "$T/$1"; mkdir -p "$T/$1"; cp "$SRC/pvc.yaml" "$T/$1/"; sed -i -E "$2" "$T/$1/pvc.yaml"
}
doctored_pvc k3s-class 's#storageClassName: [a-z-]+#storageClassName: local-path#'
out=$(storage_problems "$T/k3s-class" "$MANIFESTS")
if [ -n "$out" ]; then ok "negative control: PVC back on the k3s-only class local-path — caught"; else bad "negative control: PVC on local-path — NOT caught"; fi
doctored_pvc typo-class 's#storageClassName: [a-z-]+#storageClassName: hugmesh-locl#'
out=$(storage_problems "$T/typo-class" "$MANIFESTS")
if [ -n "$out" ]; then ok "negative control: a misspelt class — caught"; else bad "negative control: misspelt class — NOT caught"; fi
doctored_pvc default-class '/storageClassName:/d'
out=$(storage_problems "$T/default-class" "$MANIFESTS")
if [ -z "$out" ]; then ok "negative control: no storageClassName (cluster default) — clean"; else bad "a PVC on the cluster default was flagged: $out"; fi
mkdir -p "$T/empty-root"
out=$(storage_problems "$SRC" "$T/empty-root")
if [ -n "$out" ]; then ok "negative control: a tree defining no StorageClass at all — reported, not passed"; else bad "an empty class set passed silently"; fi

echo; echo "== edge-ai ollama pin: $P passed, $F failed =="
[ "$F" -eq 0 ]
