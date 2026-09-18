#!/usr/bin/env python3
"""eso_brand_render.py — render an ArgoCD git-path Application the way ArgoCD does.

ArgoCD fetches `spec.source.path` FROM `spec.source.repoURL` (never from the
device's baked tree) and, when `spec.source.kustomize.patches` is present, appends
those patches to that directory's kustomization.yaml before running `kustomize
build`. This reproduces exactly that, so a suite can measure what ESO will really
read on a rebranded mesh:

    eso_brand_render.py <application.yaml> <git-manifest-dir> [--json]

<application.yaml> is the Application object AS THE DEVICE HAS IT (i.e. after
rebrand_sysroot has run over the baked tree); <git-manifest-dir> is the upstream
git directory it points at, which a rebrand never touches.

Prints JSON: the ExternalSecret Vault-key base histogram, the full key list, the
harbor Job's VAULT_KV_BASE env value when the tree has one, and whether any
@@SDSYS…@@ rebrand sentinel leaked into the render.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml


def kustomize_cmd():
    if shutil.which("kustomize"):
        return ["kustomize", "build"]
    if shutil.which("kubectl"):
        return ["kubectl", "kustomize"]
    print("FATAL: neither `kustomize` nor `kubectl` is on PATH — this suite cannot "
          "render what ArgoCD renders and must NOT report a pass", file=sys.stderr)
    sys.exit(2)


def main():
    app_path, git_dir = sys.argv[1], sys.argv[2]
    app = yaml.safe_load(open(app_path))
    src = app["spec"]["source"]
    patches = src.get("kustomize", {}).get("patches", [])

    tmp = tempfile.mkdtemp(prefix="eso-brand-render.")
    try:
        work = os.path.join(tmp, "tree")
        shutil.copytree(git_dir, work)
        kpath = os.path.join(work, "kustomization.yaml")
        kust = yaml.safe_load(open(kpath))
        if patches:
            kust.setdefault("patches", []).extend(patches)
            yaml.safe_dump(kust, open(kpath, "w"), sort_keys=False)
        proc = subprocess.run(kustomize_cmd() + [work], capture_output=True, text=True)
        if proc.returncode != 0:
            print(json.dumps({"error": proc.stderr.strip()[:2000]}))
            return 1
        out = proc.stdout
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    bases, keys, harbor = {}, [], None
    for doc in yaml.safe_load_all(out):
        if not doc:
            continue
        if doc.get("kind") == "ExternalSecret":
            spec = doc.get("spec", {})
            for e in spec.get("data", []) or []:
                k = e.get("remoteRef", {}).get("key")
                if k:
                    keys.append(k)
                    bases[k.split("/")[0]] = bases.get(k.split("/")[0], 0) + 1
            for e in spec.get("dataFrom", []) or []:
                k = (e.get("extract") or {}).get("key")
                if k:
                    keys.append(k)
                    bases[k.split("/")[0]] = bases.get(k.split("/")[0], 0) + 1
        if doc.get("kind") == "Job":
            for c in doc["spec"]["template"]["spec"].get("containers", []):
                for env in c.get("env", []) or []:
                    if env.get("name") == "VAULT_KV_BASE":
                        harbor = env.get("value")

    print(json.dumps({
        "bases": bases,
        "keys": sorted(keys),
        "n_keys": len(keys),
        "harbor_vault_kv_base": harbor,
        "sentinel_leak": bool(re.search(r"@@SDSYS[A-Z]*@@", out)),
        "patch_count": len(patches),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
