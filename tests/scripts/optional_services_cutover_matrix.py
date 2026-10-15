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
nothing is vacuous, never a pass). Every one has an ISOLATING negative control in
tests/scripts/test-optional-services-cutover-matrix.sh (a plant that trips exactly that
invariant and no other), so a dead check cannot hide behind a live one:
  I1 every element path is a non-empty, relative path whose RESOLVED location (symlinks and
     `..` followed) is an existing directory strictly inside the tree. The tree root itself
     fails: '', '.', './' and 'specs/..' all resolve to it and would pass isdir; so does a
     symlink whose target is outside the tree, and any path that BEGINS with '..' (it can
     resolve back inside on one checkout directory name and nowhere on another). Claims (I2, I4, I6) compare the same resolved
     key, so two spellings, or a symlink and its target, are one directory
  I2 every owner of an element's path is one of THAT slug's registry apps (no cross-slug
     ownership of a directory)
  I3 every registry app of an element slug exists and parses as an Application (or, for
     13c games-instances, an ApplicationSet that generates its own Applications)
  I4 a slug with registry apps has an owner for the element path (else the element and the
     registry disagree about which app is the slug's main workload)
  I5 element namespace == the owner's destination.namespace
  I6 no manifest directory is claimed twice, ACROSS elements as well as within one. Per
     path, the claimants are the set of hardcoded owner files plus every element with
     installed:"true"; more than one claimant is a violation. Two elements that name the
     same path are a violation even when both are "false" (flipping either is the
     reconciler's job, and the second flip would double-manage the directory)
  I7 every element slug exists in the registry (I7 no-entry); every element has every key
     the template renders or the selector reads (I7 key; the set is DERIVED from the
     ApplicationSet, not listed here); `installed` is the STRING "true" or "false" and
     nothing else (I7 value: the selector matches the string, and the generator's own sed
     only rewrites the quoted form, so a bare `installed: true` is a flag nothing flips)
  I8 the generated Application name optional-<slug> is unique: no slug appears on two
     elements or twice in the registry, and no hardcoded Application already carries
     that name

Usage:
  optional_services_cutover_matrix.py --root <repo> check            print + enforce
  optional_services_cutover_matrix.py --root <repo> emit             the matrix text block
"""
import argparse
import collections
import glob
import os
import re
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
# keys this checker itself reads from every element; the set checked in I7 is these PLUS
# every key the template renders ({{ .key }}) or the selector reads (matchLabels), derived
READ_KEYS = ("slug", "path", "namespace", "installed")


def ckey(root, path):
    """a path as a claim key: the RESOLVED location relative to the resolved tree root.
    'a/b/', './a/b', 'a//b', 'a/../a/b' and a symlink to a/b are all the same directory,
    and '.', './' and 'specs/..' are all the tree root ('.'); a location outside the tree
    starts with '..'."""
    if not path:
        return path
    real_root = os.path.realpath(root)
    return os.path.relpath(os.path.realpath(os.path.join(real_root, path)), real_root)


def template_keys(appset):
    """the element keys the ApplicationSet reads: {{ .key }} / index . "key" in the
    template, plus the generator selector's matchLabels keys"""
    spec = appset["spec"]
    keys = set(READ_KEYS)
    text = yaml.safe_dump(spec.get("template") or {})
    for expr in re.findall(r"\{\{(.*?)\}\}", text, re.S):
        keys.update(re.findall(r"(?<![\w.])\.([A-Za-z_]\w*)", expr))
        keys.update(re.findall(r"index\s+\.\s+[\"']([A-Za-z_]\w*)[\"']", expr))
    gens = spec.get("generators") or [{}]
    for k in (((gens[0].get("selector") or {}).get("matchLabels")) or {}):
        keys.add(k)
    return sorted(keys)


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


def registry_slug_list(root):
    reg = load(os.path.join(root, REGISTRY_REL))[0]
    return [s["slug"] for s in reg["spec"]["services"]]


def derive(root):
    services, elements, tpl, apps = load_corpus(root)
    keys = template_keys(load(os.path.join(root, APPSET_REL))[0])
    tpl_md = tpl.get("metadata") or {}
    tpl_sp = tpl.get("spec") or {}
    tpl_fin = list(tpl_md.get("finalizers") or [])
    tpl_wave = (tpl_md.get("annotations") or {}).get(WAVE)
    tpl_sync = sorted((tpl_sp.get("syncPolicy") or {}).get("syncOptions") or [])
    tpl_ign = bool(tpl_sp.get("ignoreDifferences"))
    rows, errors = [], []
    by_path = {}
    # I8: the generated Application is named optional-<slug>; that name must be unique
    for name, n in sorted(collections.Counter(registry_slug_list(root)).items()):
        if n > 1:
            errors.append("I8 registry slug %r is listed %d times" % (name, n))
    for name, n in sorted(collections.Counter(el.get("slug") for el in elements).items(),
                          key=lambda kv: str(kv[0])):
        if n > 1:
            errors.append("I8 element slug %r appears %d times: each generates Application optional-%s"
                          % (name, n, name))
    taken = {"optional-%s" % el.get("slug"): el.get("slug") for el in elements}
    for f, a in sorted(apps.items()):
        if a.get("name") in taken:
            errors.append("I8 %s is already named %s, the name the generated Application for %r takes"
                          % (f, a["name"], taken[a["name"]]))
    for el in elements:
        slug = el.get("slug")
        miss = [k for k in keys if k not in el]
        if miss:
            errors.append("I7 element %r lacks key(s) %s that the template or selector reads" % (slug, miss))
        if "installed" in el and not (isinstance(el["installed"], str) and el["installed"] in ("true", "false")):
            errors.append("I7 element %r installed is %r (%s): it must be the string \"true\" or \"false\""
                          % (slug, el["installed"], type(el["installed"]).__name__))
        svc = services.get(slug)
        if svc is None:
            errors.append("I7 element %r has no entry in %s" % (slug, REGISTRY_REL))
            svc = {}
        path = el.get("path") or ""
        reg_apps = [("specs/cluster/" + a) for a in (svc.get("apps") or [])]
        key = ckey(root, path)
        # a LEADING '..' is refused lexically, whatever it resolves to here: '../<this
        # checkout's directory name>/x' resolves back inside the tree on this machine, and
        # ArgoCD clones the repo into a directory with another name
        if (not path or os.path.isabs(path) or key == "." or key == ".." or key.startswith("../")
                or os.path.normpath(path).split("/")[0] == ".."):
            errors.append("I1 %s: element path %r is empty, absolute, the tree root or leaves the tree (resolves to %s)"
                          % (slug, path, key or "nothing"))
        elif not os.path.isdir(os.path.join(root, path)):
            errors.append("I1 %s: element path %s is not a directory" % (slug, path))
        for a in reg_apps:
            if a not in apps:
                errors.append("I3 %s: registry app %s does not exist as an Application" % (slug, a))
            elif "error" in apps[a]:
                errors.append("I3 %s: registry app %s does not parse (%s)" % (slug, a, apps[a]["error"]))
        owners = sorted(f for f, a in apps.items()
                        if a.get("path") and path and ckey(root, a["path"]) == key)
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
        # any spelling of true counts as a claim (a bare YAML true too): the I7 value check
        # reports the spelling, and the claim must not vanish because of it
        installed = el.get("installed") is True or el.get("installed") == "true"
        n_claims = len(owners) + (1 if installed else 0)
        if n_claims > 1:
            errors.append("I6 %s: manifest dir %s is claimed %d times (owners %s, element installed=%s)"
                          % (slug, path, n_claims, owners, installed))
        by_path.setdefault(key, {"owners": set(), "installed": [], "elements": []})
        by_path[key]["owners"].update(owners)
        by_path[key]["elements"].append(slug)
        if installed:
            by_path[key]["installed"].append(slug)
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
    # I6 across elements: the per-element check above cannot see two elements on one path
    for path, c in sorted(by_path.items()):
        if len(c["elements"]) > 1:
            errors.append("I6 elements %s all name manifest dir %s (installed: %s)"
                          % (c["elements"], path, c["installed"] or "none"))
    tpl_facts = {"finalizers": tpl_fin, "wave": tpl_wave,
                 "owner_finalizers": sorted({f for r in rows for o in r["owners"]
                                             for f in apps[o]["finalizers"]})}
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
