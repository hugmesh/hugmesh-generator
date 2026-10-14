#!/usr/bin/env python3
"""optional_services_cutover_matrix.py - derive the 13a ApplicationSet CUT-OVER matrix
from the tree and check the invariants a cut-over depends on.

WHY. apps/13a-optional-services.yaml is the runtime add/remove ApplicationSet; every
element is held installed:"false" because a hardcoded apps/30-*/50-*/52-*/53-*/54-*/55-*
Application still owns the same manifest directory (two prune+selfHeal Applications on one
directory). docs/OPTIONAL-SERVICES.md section 10 names "the cut-over" as the remaining
step, and its slug list was hand-written: it omitted the three edge-ai apps, and it
described the cut-over as "delete the hardcoded apps" although one 13a element covers
exactly ONE manifest directory while phpbb owns 4 Applications, character-forge 3 and
games 3. Nothing derived the cut-over's actual shape, so nothing noticed.

EVERYTHING HERE IS DERIVED. Nothing hard-codes a slug, a path or a count. Inputs:
  specs/cluster/optional-services.yaml      registry: per slug `apps:` + `manifestPath`
  specs/cluster/apps/13a-optional-services.yaml   the elements + the template
  specs/cluster/apps/*.yaml                 the hardcoded Applications (name, path, wave)

THE MATRIX. For each 13a element:
  owners   hardcoded Applications whose source.path == the element path
  apps     the registry's `apps:` for the slug (the files the build-time prune removes)
  class    runtime-only   no owner and no registry apps (13a is the only wiring)
           single-app     exactly one registry app and it is the owner: mechanical cut-over
           multi-app      >1 registry app: the element covers ONE directory, so the other
                          apps are ORPHANED by a delete-the-hardcoded-apps cut-over
  loses    what the generated `optional-<slug>` Application would NOT carry that the owner
           did: its NAME, its argocd sync-wave annotation, any finalizer / ignoreDifferences
           / syncOptions the template does not repeat.

INVARIANTS (exit 1 on any violation; exit 3 when the corpus is empty - a derived guard over
nothing is vacuous, never a pass):
  I1 every element path is an existing directory under the tree
  I2 every owner of an element's path is one of THAT slug's registry apps (no cross-slug
     ownership of a directory)
  I3 every registry app of an element slug exists and parses as an Application (or, for
     13c games-instances, an ApplicationSet that generates its own Applications)
  I4 a slug with registry apps has an owner for the element path (else the element and the
     registry disagree about which app is the slug's main workload)
  I5 element namespace == the owner's destination.namespace
  I6 no manifest directory is claimed twice: owners + (element installed:"true") <= 1
  I7 every element slug exists in the registry; every element has the keys the template uses

Usage:
  optional_services_cutover_matrix.py --root <repo> check            print + enforce
  optional_services_cutover_matrix.py --root <repo> emit             the matrix text block
"""
import argparse
import glob
import os
import sys

try:
    import yaml
except ImportError:  # an absent parser is a FAIL, never a skip
    print("FAIL PyYAML is required")
    sys.exit(1)

APPSET_REL = "specs/cluster/apps/13a-optional-services.yaml"
REGISTRY_REL = "specs/cluster/optional-services.yaml"
APPS_REL = "specs/cluster/apps"
WAVE = "argocd.argoproj.io/sync-wave"
TEMPLATE_KEYS = ("slug", "path", "namespace", "installed")


def load(path):
    with open(path, encoding="utf-8") as f:
        return list(yaml.safe_load_all(f))


def load_apps(root):
    """name/path/namespace/wave/finalizers/syncOptions/ignoreDifferences per hardcoded
    Application file, keyed by the repo-relative file path."""
    apps = {}
    for f in sorted(glob.glob(os.path.join(root, APPS_REL, "*.yaml"))):
        rel = os.path.relpath(f, root)
        if os.path.basename(f) == os.path.basename(APPSET_REL):
            continue
        try:
            docs = load(f)
        except yaml.YAMLError as e:
            apps[rel] = {"error": str(e).splitlines()[0]}
            continue
        for d in docs:
            if isinstance(d, dict) and d.get("kind") == "ApplicationSet":
                # a sibling ApplicationSet (13c games-instances): it exists as a registry
                # app but generates its own Applications, so it owns no directory here.
                apps[rel] = {"name": (d.get("metadata") or {}).get("name"), "path": None,
                             "namespace": None, "wave": None, "finalizers": [],
                             "syncOptions": [], "ignoreDifferences": False,
                             "kind": "ApplicationSet"}
                continue
            if not isinstance(d, dict) or d.get("kind") != "Application":
                continue
            md, sp = d.get("metadata") or {}, d.get("spec") or {}
            src = sp.get("source") or {}
            apps[rel] = {
                "kind": "Application",
                "name": md.get("name"),
                "path": src.get("path"),
                "namespace": (sp.get("destination") or {}).get("namespace"),
                "wave": (md.get("annotations") or {}).get(WAVE),
                "finalizers": list(md.get("finalizers") or []),
                "syncOptions": sorted((sp.get("syncPolicy") or {}).get("syncOptions") or []),
                "ignoreDifferences": bool(sp.get("ignoreDifferences")),
            }
    return apps


def load_corpus(root):
    reg = load(os.path.join(root, REGISTRY_REL))[0]
    services = {s["slug"]: s for s in reg["spec"]["services"]}
    appset = load(os.path.join(root, APPSET_REL))[0]
    elements = appset["spec"]["generators"][0]["list"]["elements"]
    tpl = appset["spec"]["template"]
    return services, elements, tpl, load_apps(root)


def derive(root):
    services, elements, tpl, apps = load_corpus(root)
    tpl_md = tpl.get("metadata") or {}
    tpl_sp = tpl.get("spec") or {}
    tpl_fin = list(tpl_md.get("finalizers") or [])
    tpl_wave = (tpl_md.get("annotations") or {}).get(WAVE)
    tpl_sync = sorted((tpl_sp.get("syncPolicy") or {}).get("syncOptions") or [])
    tpl_ign = bool(tpl_sp.get("ignoreDifferences"))
    rows, errors = [], []
    claimed = {}
    for el in elements:
        slug = el.get("slug")
        miss = [k for k in TEMPLATE_KEYS if k not in el]
        if miss:
            errors.append("I7 element %r lacks key(s) %s that the template renders" % (slug, miss))
        svc = services.get(slug)
        if svc is None:
            errors.append("I7 element %r has no entry in %s" % (slug, REGISTRY_REL))
            svc = {}
        path = el.get("path") or ""
        reg_apps = [("specs/cluster/" + a) for a in (svc.get("apps") or [])]
        if not os.path.isdir(os.path.join(root, path)):
            errors.append("I1 %s: element path %s is not a directory" % (slug, path))
        for a in reg_apps:
            if a not in apps:
                errors.append("I3 %s: registry app %s does not exist as an Application" % (slug, a))
            elif "error" in apps[a]:
                errors.append("I3 %s: registry app %s does not parse (%s)" % (slug, a, apps[a]["error"]))
        owners = sorted(f for f, a in apps.items() if a.get("path") == path)
        for o in owners:
            if o not in reg_apps:
                errors.append("I2 %s: %s owns %s but is not among its registry apps %s"
                              % (slug, o, path, reg_apps))
        if reg_apps and not owners:
            errors.append("I4 %s: registry lists apps %s but none owns the element path %s"
                          % (slug, reg_apps, path))
        for o in owners:
            ns = apps[o].get("namespace")
            if ns != el.get("namespace"):
                errors.append("I5 %s: element namespace %r != %s destination %r"
                              % (slug, el.get("namespace"), o, ns))
        installed = str(el.get("installed")) == "true"
        n_claims = len(owners) + (1 if installed else 0)
        claimed[path] = claimed.get(path, 0) + n_claims
        if n_claims > 1:
            errors.append("I6 %s: manifest dir %s is claimed %d times (owners %s, element installed=%s)"
                          % (slug, path, n_claims, owners, installed))
        orphans = [a for a in reg_apps if a not in owners]
        if not reg_apps and not owners:
            klass = "runtime-only"
        elif len(reg_apps) > 1:
            klass = "multi-app"
        else:
            klass = "single-app"
        loses = []
        for o in owners:
            a = apps[o]
            loses.append("name %s -> optional-%s" % (a["name"], slug))
            if a["wave"] is not None and a["wave"] != tpl_wave:
                loses.append("sync-wave %s" % a["wave"])
            if a["finalizers"] and a["finalizers"] != tpl_fin:
                loses.append("finalizers %s" % a["finalizers"])
            if a["ignoreDifferences"] and not tpl_ign:
                loses.append("ignoreDifferences")
            if a["syncOptions"] != tpl_sync:
                loses.append("syncOptions %s vs template %s" % (a["syncOptions"], tpl_sync))
        rows.append({"slug": slug, "path": path, "klass": klass, "owners": owners,
                     "orphans": orphans, "loses": loses, "installed": installed,
                     "kinds": {o: apps[o].get("kind") for o in orphans if o in apps}})
    tpl_facts = {"finalizers": tpl_fin, "wave": tpl_wave,
                 "owner_finalizers": sorted({f for a in apps.values()
                                             for f in a.get("finalizers", [])
                                             if a.get("path") in {r["path"] for r in rows}})}
    return rows, errors, tpl_facts


def emit(rows, tpl_facts):
    out = []
    out.append("| slug | class | hardcoded owner of the element dir | apps the element does NOT cover (orphaned by a plain delete) | what the generated Application loses |")
    out.append("|---|---|---|---|---|")
    for r in rows:
        own = ", ".join("`%s`" % o.split("/")[-1] for o in r["owners"]) or "none"
        orp = ", ".join("`%s`%s" % (o.split("/")[-1], " (ApplicationSet)" if r["kinds"].get(o) == "ApplicationSet" else "")
                        for o in r["orphans"]) or "-"
        los = "; ".join(r["loses"]) or "-"
        out.append("| %s | %s | %s | %s | %s |" % (r["slug"], r["klass"], own, orp, los))
    n = {k: sum(1 for r in rows if r["klass"] == k) for k in ("single-app", "multi-app", "runtime-only")}
    out.append("")
    out.append("elements: %d (single-app %d, multi-app %d, runtime-only %d)"
               % (len(rows), n["single-app"], n["multi-app"], n["runtime-only"]))
    out.append("13a template finalizers: %s; template sync-wave: %s"
               % (tpl_facts["finalizers"] or "none", tpl_facts["wave"] or "none"))
    out.append("finalizers on the hardcoded owners: %s" % (tpl_facts["owner_finalizers"] or "none"))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("mode", choices=("check", "emit"))
    a = ap.parse_args()
    try:
        rows, errors, tpl_facts = derive(a.root)
    except (OSError, KeyError, IndexError, TypeError, yaml.YAMLError) as e:
        print("FAIL cannot derive the matrix: %s: %s" % (type(e).__name__, e))
        return 1
    if not rows:
        print("INCOMPLETE derived zero 13a elements - a guard over nothing proves nothing")
        return 3
    if a.mode == "emit":
        print(emit(rows, tpl_facts))
        return 0
    print(emit(rows, tpl_facts))
    for e in errors:
        print("  VIOLATION " + e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
