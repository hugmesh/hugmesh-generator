#!/usr/bin/env python3
"""idp_issuer_render.py — what ArgoCD renders for a baked Application, as data.

Issue #530. rewrite_idp_sysroot() in the x86/rpi5 stage4 builders re-points the
issuer and JWKS literals of the BAKED cluster tree at an external IdP. ArgoCD
reads only the baked apps/*.yaml; every manifests/** directory comes from git.
This helper renders the way ArgoCD does (the Application's
spec.source.kustomize.patches appended to the git directory's kustomization.yaml,
then a real `kustomize build`) so a suite can compare that against what the
builder MEANT to write.

    idp_issuer_render.py env <application.yaml> <git-dir>
        JSON: {"error", "env": {"<Kind>/<name>/<container>/<ENV>": value},
               "patch_count", "sentinel_leak", "text_sha"}

    idp_issuer_render.py oracle <application.yaml> <git-dir> <baked-dir>
        Renders the baked Application against the GIT dir (what ArgoCD applies)
        and the BAKED copy of the dir on its own (what the builder's sed meant
        to apply, if anything read it). Prints JSON {"error", "diff": [paths]}:
        every leaf whose value differs between the two. Empty = the builder's
        intent reaches the cluster.

    idp_issuer_render.py count <application.yaml> <git-dir> <literal>...
        JSON {"error", "counts": {literal: occurrences in the render}}.

    idp_issuer_render.py match <application.yaml> <git-dir> <regex>
        JSON {"error", "matches": [group 1 of every match in the render]}.
        Used for Casdoor's app.conf `origin`, which lives inside a string.

    idp_issuer_render.py helm <application.yaml> <chart-dir>
        `helm template` of a git-served chart with the Application's inline
        spec.source.helm.values, as ArgoCD runs it. JSON as for `env`.

Fails (exit 2) rather than reporting a pass when kustomize/kubectl (or, for
`helm`, helm) is not on PATH.
"""
import hashlib
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
    print("FATAL: neither `kustomize` nor `kubectl` is on PATH; this helper cannot "
          "render what ArgoCD renders and must NOT report a pass", file=sys.stderr)
    sys.exit(2)


def build(dir_path, patches=None):
    """kustomize build of a COPY of dir_path with `patches` appended."""
    # The copy sits among SYMLINKS to its real siblings, so a resource such as
    # games' `../games-portal` resolves exactly as it does in the repo.
    tmp = tempfile.mkdtemp(prefix="idp-issuer-render.")
    try:
        dir_path = os.path.abspath(dir_path)
        parent, base = os.path.dirname(dir_path), os.path.basename(dir_path)
        for sib in os.listdir(parent):
            if sib != base:
                os.symlink(os.path.join(parent, sib), os.path.join(tmp, sib))
        work = os.path.join(tmp, base)
        shutil.copytree(dir_path, work)
        if patches:
            kpath = os.path.join(work, "kustomization.yaml")
            kust = yaml.safe_load(open(kpath))
            kust.setdefault("patches", []).extend(patches)
            yaml.safe_dump(kust, open(kpath, "w"), sort_keys=False)
        proc = subprocess.run(kustomize_cmd() + [work], capture_output=True, text=True)
        if proc.returncode != 0:
            return None, proc.stderr.strip()[:2000]
        return proc.stdout, None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def app_patches(app_path):
    app = yaml.safe_load(open(app_path))
    return app["spec"]["source"].get("kustomize", {}).get("patches", [])


def env_map(text):
    out = {}
    for doc in yaml.safe_load_all(text):
        if not doc:
            continue
        kind, name = doc.get("kind"), doc.get("metadata", {}).get("name")
        spec = doc.get("spec") or {}
        if kind == "CronJob":
            spec = spec.get("jobTemplate", {}).get("spec", {})
        pod = (spec.get("template") or {}).get("spec") or {}
        for grp in ("initContainers", "containers"):
            for c in pod.get(grp) or []:
                for e in c.get("env") or []:
                    if "value" in e:
                        out["%s/%s/%s/%s" % (kind, name, c.get("name"), e.get("name"))] = e["value"]
    return out


def leaves(node, prefix, out):
    if isinstance(node, dict):
        for k, v in node.items():
            leaves(v, "%s.%s" % (prefix, k), out)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            key = v.get("name") if isinstance(v, dict) and "name" in v else i
            leaves(v, "%s[%s]" % (prefix, key), out)
    else:
        out[prefix] = node


def flatten(text):
    out = {}
    for doc in yaml.safe_load_all(text):
        if doc:
            leaves(doc, "%s/%s" % (doc.get("kind"), doc.get("metadata", {}).get("name")), out)
    return out


def helm_render(app_path, chart):
    if not shutil.which("helm"):
        print("FATAL: helm is not on PATH; the gateway charts cannot be rendered "
              "and this helper must NOT report a pass", file=sys.stderr)
        sys.exit(2)
    src = yaml.safe_load(open(app_path))["spec"]["source"]["helm"]
    tmp = tempfile.mkdtemp(prefix="idp-issuer-helm.")
    try:
        vals = os.path.join(tmp, "values.yaml")
        open(vals, "w").write(src.get("values") or "")
        proc = subprocess.run(["helm", "template", src["releaseName"], chart, "-f", vals],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            return None, proc.stderr.strip()[:2000]
        return proc.stdout, None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    cmd = sys.argv[1]
    if cmd == "env":
        text, err = build(sys.argv[3], app_patches(sys.argv[2]))
        if err:
            print(json.dumps({"error": err}))
            return 1
        print(json.dumps({
            "error": None,
            "env": env_map(text),
            "patch_count": len(app_patches(sys.argv[2])),
            "sentinel_leak": bool(re.search(r"@@SDSYS[A-Z]*@@", text)),
            "text_sha": hashlib.sha256(text.encode()).hexdigest(),
        }))
        return 0
    if cmd == "oracle":
        actual, err = build(sys.argv[3], app_patches(sys.argv[2]))
        intended, err2 = (None, None) if err else build(sys.argv[4])
        if err or err2:
            print(json.dumps({"error": err or err2}))
            return 1
        a, i = flatten(actual), flatten(intended)
        diff = sorted(k for k in set(a) | set(i) if a.get(k) != i.get(k))
        print(json.dumps({"error": None, "diff": diff}))
        return 0
    if cmd == "count":
        text, err = build(sys.argv[3], app_patches(sys.argv[2]))
        if err:
            print(json.dumps({"error": err}))
            return 1
        print(json.dumps({"error": None, "counts": {lit: text.count(lit) for lit in sys.argv[4:]}}))
        return 0
    if cmd == "match":
        text, err = build(sys.argv[3], app_patches(sys.argv[2]))
        if err:
            print(json.dumps({"error": err}))
            return 1
        print(json.dumps({"error": None, "matches": re.findall(sys.argv[4], text)}))
        return 0
    if cmd == "helm":
        text, err = helm_render(sys.argv[2], sys.argv[3])
        if err:
            print(json.dumps({"error": err}))
            return 1
        print(json.dumps({"error": None, "env": env_map(text),
                          "text_sha": hashlib.sha256(text.encode()).hexdigest()}))
        return 0
    print("usage: idp_issuer_render.py env|oracle|count|match|helm ...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
