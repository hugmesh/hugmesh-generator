#!/usr/bin/env bash
# test-eso-target-collisions.sh — an ExternalSecret may not aim at a Secret name
# somebody ELSE owns, and no workload may name a pull secret nothing materializes.
#
# THE BUG THIS EXISTS TO KILL
# ---------------------------
# manifests/external-secrets/secretstore.yaml declared
#
#     kind: ExternalSecret
#     metadata: { name: harbor-registry, namespace: hugmesh-pki }
#     spec.target: { name: harbor-registry, creationPolicy: Owner,
#                    template.type: kubernetes.io/dockerconfigjson }
#
# to give the hugmesh-pki workloads an imagePullSecret. But hugmesh-pki is the
# namespace the HARBOR HELM CHART is released into (apps/03a-harbor.yaml,
# releaseName `harbor`), and that chart already creates a Secret of exactly that
# name — harbor/templates/registry/registry-secret.yaml:
#
#     metadata.name: "{{ template "harbor.registry" . }}"      type: Opaque
#
# with `harbor.registry` = `printf "%s-registry" (include "harbor.fullname" .)`
# (templates/_helpers.tpl) and fullname collapsing to the release name `harbor`.
# It holds REGISTRY_HTTP_SECRET + REGISTRY_REDIS_PASSWORD and BOTH containers of
# the harbor-registry Deployment `envFrom` it.
#
# Three consequences, all observed on the live kind cluster:
#   1. The ExternalSecret could NEVER converge — a Secret's `type` is immutable:
#        Secret "harbor-registry" is invalid: type: Invalid value:
#        "kubernetes.io/dockerconfigjson": field is immutable
#      so the pull secret it existed to create was never created and the pods it
#      existed to unblock would still ImagePullBackOff. The fix never worked.
#   2. `creationPolicy: Owner` means ESO was actively trying to TAKE OWNERSHIP of
#      a Helm-managed object. The ONLY thing that stopped it overwriting Harbor's
#      own registry credentials was the type-immutability rule in (1) — an
#      unrelated coincidence. Had the types matched, ESO would have clobbered the
#      registry's credentials and ESO's deletionPolicy would have governed an
#      object Helm believes it owns.
#   3. A permanently-failing ExternalSecret sat in the namespace from bootstrap
#      onward, which is exactly the noise a real failure hides in.
#
# Nothing in CI could see any of it, because seeing it requires knowing what the
# UPSTREAM CHART creates — a fact that lives in neither this repo's manifests nor
# any lint that reads them one file at a time.
#
# WHAT IS ASSERTED (the invariant, not a literal)
# -----------------------------------------------
#   (A) THIRD-PARTY OWNERSHIP. For every ArgoCD Application in this repo whose
#       source is an EXTERNAL Helm chart, the chart is rendered — real `helm
#       template`, its own committed values, its own destination namespace — and
#       no ExternalSecret target in that namespace may equal a Secret name the
#       chart creates. This is derived from the chart, so it tracks upstream: if
#       a future Harbor/Cassandra/GitLab/Velero release adds a Secret that lands
#       on one of our names, this goes red without anybody editing a list.
#   (B) SINGLE OWNER inside this repo. An ExternalSecret target may not equal the
#       name of a plain `kind: Secret` manifest in the same namespace either —
#       same defect, first-party flavour: two writers, one object.
#   (C) THE CONSUMER SIDE. Every imagePullSecrets name a workload in this repo
#       references — in a manifest, in a kustomize patch, or in the values of a
#       first-party chart release — must actually be materialized in that
#       workload's namespace (an ExternalSecret target or a literal Secret).
#       (A) alone would have let the collision be "fixed" by renaming the
#       ExternalSecret and leaving every consumer pointing at Harbor's Secret.
#
# SCOPE IS DERIVED, NOT LISTED. A chart is rendered when its destination
# namespace contains at least one ExternalSecret target — the only way a
# collision is possible. Add an ExternalSecret to `devops` and the GitLab chart
# starts being rendered against it automatically.
#
# HOW IT CANNOT GO VACUOUSLY GREEN
#   * a chart that renders ZERO objects is a FAILURE, not "no collisions found";
#   * a tree with ZERO ExternalSecret targets is a FAILURE, not "nothing to check";
#   * the analyser is re-run against five deliberately-broken copies of the tree
#     (including the EXACT pre-fix manifest) and each one must bite;
#   * one control aims an ExternalSecret at a chart-owned name that is NOT the
#     historical one, so the check cannot be a memorised special case.
#
# A MISSING TOOL IS A HARD FAILURE, never a skip — see tests/lib/guard-preflight.sh.
# Needs: bash, python3 + PyYAML, helm (and network the first time, to fetch the
# charts; set ESO_COLLISION_CHART_CACHE to a persistent dir to run offline after).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=../lib/guard-preflight.sh
. "${HERE}/../lib/guard-preflight.sh"

echo "== ExternalSecret target ownership: no target may collide with an object we do not own =="

guard_require_tools python3 helm
python3 -c 'import yaml' >/dev/null 2>&1 \
  || guard_require_capability "python3 has no PyYAML (the manifests cannot be parsed)"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT
# Keep helm's own state inside the sandbox so a CI runner needs no HOME, but let
# an operator point the CHART cache at something persistent for offline re-runs.
export HELM_CONFIG_HOME="${WORK}/helm-config"
export HELM_DATA_HOME="${WORK}/helm-data"
export HELM_CACHE_HOME="${ESO_COLLISION_CHART_CACHE:-${WORK}/helm-cache}"
mkdir -p "${HELM_CACHE_HOME}"

P=0; F=0
ok(){   echo "  PASS $*"; P=$((P+1)); }
bad(){  echo "  FAIL $*"; F=$((F+1)); }

# ─────────────────────────────────────────────────────────────────────────────
# The RENDERER. Walks this repo's Applications, renders every external chart
# whose destination namespace we put ExternalSecrets in, and writes an inventory
# of the object names those charts OWN. Runs once, against the real tree — the
# negative controls below mutate OUR manifests, never upstream's charts, so the
# inventory is the same fact in every run and needs no re-fetch.
# ─────────────────────────────────────────────────────────────────────────────
echo "-- 0) render the third-party charts we release into our own namespaces --"
REPO="${REPO}" OUT="${WORK}/inventory.json" python3 - <<'PY'
import glob, json, os, subprocess, sys, tempfile
import yaml

repo = os.environ["REPO"]
out  = os.environ["OUT"]

# Namespaces we put ExternalSecrets in — the only namespaces a collision can
# happen in, and therefore the only charts worth rendering.
es_namespaces = set()
for f in glob.glob(os.path.join(repo, "specs/cluster/**/*.yaml"), recursive=True):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in docs:
        if isinstance(d, dict) and d.get("kind") == "ExternalSecret":
            es_namespaces.add((d.get("metadata") or {}).get("namespace"))

fatal = []
releases = []          # third-party helm releases we must render
for f in sorted(glob.glob(os.path.join(repo, "specs/cluster/**/*.yaml"), recursive=True)):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except Exception:
        continue
    for d in docs:
        if not isinstance(d, dict):
            continue
        rel = os.path.relpath(f, repo)
        if d.get("kind") == "ApplicationSet":
            # An ApplicationSet that templates a `chart:` source would generate
            # third-party releases this scanner never sees. None does today; if
            # one ever appears, FAIL rather than silently under-scan.
            tmpl = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
            srcs = tmpl.get("sources") or ([tmpl["source"]] if "source" in tmpl else [])
            for s in srcs:
                if isinstance(s, dict) and s.get("chart"):
                    fatal.append("%s: ApplicationSet templates a third-party chart "
                                 "source (%s) — this scanner only understands "
                                 "Applications, so it would under-scan" % (rel, s["chart"]))
            continue
        if d.get("kind") != "Application":
            continue
        spec = d.get("spec") or {}
        ns   = (spec.get("destination") or {}).get("namespace")
        srcs = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
        for s in srcs:
            if not isinstance(s, dict) or not s.get("chart"):
                continue
            helm = s.get("helm") or {}
            for unsupported in ("valuesObject", "valueFiles", "parameters",
                                "fileParameters"):
                if helm.get(unsupported):
                    fatal.append("%s: helm.%s is not understood by this scanner; the "
                                 "render would not match what ArgoCD deploys"
                                 % (rel, unsupported))
            releases.append({
                "file":    rel,
                "chart":   s["chart"],
                "repo":    s.get("repoURL"),
                "version": s.get("targetRevision"),
                "release": helm.get("releaseName") or (d.get("metadata") or {}).get("name"),
                "ns":      ns,
                "values":  helm.get("values") or "",
                "in_scope": ns in es_namespaces,
            })

if fatal:
    for m in fatal:
        print("  FAIL " + m)
    sys.exit(1)

if not releases:
    print("  FAIL found ZERO third-party chart Applications under specs/cluster — "
          "the scanner is not reading the tree it thinks it is")
    sys.exit(1)

inventory = {}          # ns -> { secret-name -> "release (chart file)" }
rendered_objects = 0
rendered_secrets = 0
scanned = 0
for r in releases:
    if not r["in_scope"]:
        print("  ..  skip %-16s ns=%-22s (no ExternalSecret targets that namespace — "
              "no collision is possible)" % (r["chart"], r["ns"]))
        continue
    scanned += 1
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as vf:
        vf.write(r["values"])
        vpath = vf.name
    cmd = ["helm", "template", r["release"], r["chart"],
           "--repo", r["repo"], "--version", r["version"],
           "--namespace", r["ns"], "-f", vpath, "--include-crds"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    os.unlink(vpath)
    if proc.returncode != 0:
        print("  FAIL could not render %s %s from %s (%s)\n        %s"
              % (r["chart"], r["version"], r["repo"], r["file"],
                 (proc.stderr or "").strip().splitlines()[:1]))
        print("       A chart this repo deploys but CANNOT be rendered leaves its "
              "object names unknown, which would silently turn every collision "
              "check for that namespace into a no-op. That is a failure, not a skip.")
        sys.exit(1)
    objs = [o for o in yaml.safe_load_all(proc.stdout) if isinstance(o, dict) and o.get("kind")]
    if not objs:
        print("  FAIL %s rendered ZERO objects — a silently-empty render would read "
              "as 'no collisions' for the whole of %s" % (r["chart"], r["ns"]))
        sys.exit(1)
    secrets = sorted({o["metadata"]["name"] for o in objs
                      if o.get("kind") == "Secret" and (o.get("metadata") or {}).get("name")})
    rendered_objects += len(objs)
    rendered_secrets += len(secrets)
    inventory.setdefault(r["ns"], {})
    for name in secrets:
        inventory[r["ns"]][name] = "%s (chart %s %s, %s)" % (r["release"], r["chart"],
                                                            r["version"], r["file"])
    print("  ..  render %-16s ns=%-22s %3d objects, %d Secret name(s): %s"
          % (r["chart"], r["ns"], len(objs), len(secrets), ", ".join(secrets) or "-"))

if scanned == 0:
    print("  FAIL rendered NOTHING: no third-party chart shares a namespace with an "
          "ExternalSecret, so check (A) would be vacuous")
    sys.exit(1)
if rendered_secrets == 0:
    print("  FAIL the %d rendered chart(s) produced no Secret names at all — check (A) "
          "would have nothing to compare against and could not fail" % scanned)
    sys.exit(1)

json.dump({"owned": inventory,
           "stats": {"releases": scanned, "objects": rendered_objects,
                     "secrets": rendered_secrets}}, open(out, "w"), indent=1)
print("  ..  inventory: %d release(s), %d objects, %d third-party Secret name(s)"
      % (scanned, rendered_objects, rendered_secrets))
PY
if [ $? -ne 0 ] || [ ! -s "${WORK}/inventory.json" ]; then
  echo "  FAIL chart inventory could not be built (see above) — nothing below could have been checked"
  echo "== RESULT: 0 passed, 1 failed =="
  exit 1
fi
ok "(0) third-party chart inventory built from real helm renders"

# ─────────────────────────────────────────────────────────────────────────────
# The ANALYSER. Pure, offline, and re-runnable against any tree — which is what
# makes the negative controls below possible without re-fetching a single chart.
# Reads $ANALYSE_ROOT (a repo root) + $INVENTORY, prints findings, exits nonzero
# on any violation.
# ─────────────────────────────────────────────────────────────────────────────
cat > "${WORK}/analyse.py" <<'PY'
import glob, json, os, re, sys
import yaml

root = os.environ["ANALYSE_ROOT"]
owned = json.load(open(os.environ["INVENTORY"]))["owned"]
quiet = os.environ.get("ANALYSE_QUIET") == "1"

def say(msg):
    if not quiet:
        print(msg)

es_targets    = {}  # (ns, name) -> file
lit_secrets   = {}  # (ns, name) -> file
consumers     = []  # (ns, pull-secret-name, where)
fail_unparsed = []  # patches that set imagePullSecrets in an unreadable shape

def load(f):
    try:
        return [d for d in yaml.safe_load_all(open(f)) if isinstance(d, dict)]
    except Exception:
        return []

for f in sorted(glob.glob(os.path.join(root, "specs/cluster/**/*.yaml"), recursive=True)):
    rel = os.path.relpath(f, root)
    for d in load(f):
        md = d.get("metadata") or {}
        if d.get("kind") == "ExternalSecret":
            ns  = md.get("namespace")
            # ESO defaults target.name to the ExternalSecret's own name.
            tgt = ((d.get("spec") or {}).get("target") or {}).get("name") or md.get("name")
            if ns and tgt:
                es_targets[(ns, tgt)] = rel
        elif d.get("kind") == "Secret":
            if md.get("namespace") and md.get("name"):
                lit_secrets[(md["namespace"], md["name"])] = rel

# ── consumers: imagePullSecrets references, wherever this repo writes them ────
# STRUCTURAL, not textual. Every reference in this tree today is a JSON6902
# `op: add / path: /spec/template/spec/imagePullSecrets / value: [...]` written
# as a STRING inside kustomization.yaml, so a naive "grep for imagePullSecrets:
# followed by name:" finds none of them and check (C) silently checks nothing.
def pull_names(node):
    """Every imagePullSecrets entry name anywhere inside a parsed object."""
    found = []
    if isinstance(node, dict):
        v = node.get("imagePullSecrets")
        if isinstance(v, list):
            for e in v:
                if isinstance(e, dict) and e.get("name"):
                    found.append(e["name"])
        elif isinstance(v, dict) and v.get("name"):
            found.append(v["name"])
        for k, sub in node.items():
            if k != "imagePullSecrets":
                found += pull_names(sub)
    elif isinstance(node, list):
        for e in node:
            found += pull_names(e)
    return found

def patch_pull_names(patch_doc):
    """Names a kustomize patch adds, JSON6902 op-list or strategic-merge alike."""
    found = []
    if isinstance(patch_doc, list):                     # JSON6902 op list
        for op in patch_doc:
            if not isinstance(op, dict):
                continue
            path = str(op.get("path") or "")
            if not path.rstrip("/-").endswith("imagePullSecrets"):
                continue
            val = op.get("value")
            if isinstance(val, list):
                found += [e["name"] for e in val if isinstance(e, dict) and e.get("name")]
            elif isinstance(val, dict) and val.get("name"):
                found.append(val["name"])
    else:                                               # strategic-merge doc
        found += pull_names(patch_doc)
    return found

for kfile in sorted(glob.glob(os.path.join(root, "specs/cluster/manifests/*/kustomization.yaml"))):
    ks = (load(kfile) or [{}])[0]
    ns = ks.get("namespace")
    if not ns:
        continue
    krel = os.path.relpath(kfile, root)
    d = os.path.dirname(kfile)
    # plain manifests in the overlay
    for f in sorted(set(glob.glob(os.path.join(d, "**/*.yaml"), recursive=True))):
        for doc in load(f):
            for n in pull_names(doc):
                consumers.append((ns, n, os.path.relpath(f, root)))
    # inline patches (strings), all three spellings kustomize accepts
    for key in ("patches", "patchesJson6902", "patchesStrategicMerge"):
        for entry in (ks.get(key) or []):
            body = entry.get("patch") if isinstance(entry, dict) else entry
            if not isinstance(body, str):
                continue
            names = []
            try:
                for doc in yaml.safe_load_all(body):
                    names += patch_pull_names(doc)
            except Exception:
                names = []
            if "imagePullSecrets" in body and not names:
                # An unrecognised patch shape must go RED. Silently extracting
                # nothing from a patch that demonstrably sets imagePullSecrets is
                # how (C) would come to check nothing at all.
                print("  FAIL [C] %s: a %s entry sets imagePullSecrets in a shape this "
                      "scanner cannot read — it would be skipped, not checked" % (krel, key))
                fail_unparsed.append(krel)
            for n in names:
                consumers.append((ns, n, krel))
# 2. first-party Helm charts in this repo: the imagePullSecrets a release ends up
#    with is chart default + the Application's own values override. The default is
#    namespace-blind, so this is exactly where a per-namespace name gets forgotten.
for f in sorted(glob.glob(os.path.join(root, "specs/cluster/**/*.yaml"), recursive=True)):
    rel = os.path.relpath(f, root)
    for d in load(f):
        if d.get("kind") != "Application":
            continue
        spec = d.get("spec") or {}
        ns   = (spec.get("destination") or {}).get("namespace")
        srcs = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
        for s in srcs:
            path = s.get("path") or ""
            if not path.startswith("specs/cluster/charts/"):
                continue
            chart_values = os.path.join(root, path, "values.yaml")
            names = []
            if os.path.exists(chart_values):
                v = (load(chart_values) or [{}])[0]
                names = [e.get("name") for e in (v.get("imagePullSecrets") or []) if isinstance(e, dict)]
            try:
                ov = yaml.safe_load((s.get("helm") or {}).get("values") or "") or {}
            except Exception:
                ov = {}
            if isinstance(ov, dict) and "imagePullSecrets" in ov:
                names = [e.get("name") for e in (ov.get("imagePullSecrets") or []) if isinstance(e, dict)]
            for n in names:
                if n:
                    consumers.append((ns, n, "%s -> %s/values.yaml" % (rel, path)))

# ── vacuity gates: a scan that matched nothing has proved nothing ────────────
fail = 0
if not es_targets:
    print("  FAIL parsed ZERO ExternalSecret targets under specs/cluster — every check "
          "below would pass by having nothing to look at")
    fail += 1
if not consumers:
    print("  FAIL found ZERO imagePullSecrets references — check (C) would be vacuous")
    fail += 1
if fail:
    sys.exit(1)
say("  ..  %d ExternalSecret target(s), %d literal Secret manifest(s), "
    "%d imagePullSecrets reference(s)" % (len(es_targets), len(lit_secrets), len(consumers)))

# ── (A) an ExternalSecret target may not be a name a third-party chart owns ──
hits = 0
for (ns, name), where in sorted(es_targets.items()):
    ownerlist = owned.get(ns) or {}
    if name in ownerlist:
        hits += 1
        print("  FAIL [A] ExternalSecret target %s/%s (%s) is a Secret the Helm release "
              "%s already creates.\n"
              "         ESO would take ownership of an object this repo does not own; if "
              "the two types ever agree it CLOBBERS the chart's credentials, and while "
              "they disagree the ExternalSecret can never converge at all."
              % (ns, name, where, ownerlist[name]))
if hits:
    fail += 1
else:
    say("  ..  [A] no ExternalSecret target collides with a third-party chart's Secret")

# ── (B) two owners for one object inside this repo ───────────────────────────
hits = 0
for (ns, name), where in sorted(es_targets.items()):
    if (ns, name) in lit_secrets:
        hits += 1
        print("  FAIL [B] ExternalSecret target %s/%s (%s) is ALSO declared as a plain "
              "Secret manifest in %s — two writers, one object"
              % (ns, name, where, lit_secrets[(ns, name)]))
if hits:
    fail += 1
else:
    say("  ..  [B] no ExternalSecret target doubles as a literal Secret manifest")

# ── (C) every referenced pull secret is actually materialized ────────────────
hits = len(fail_unparsed)
for ns, name, where in sorted(set(consumers)):
    if (ns, name) in es_targets or (ns, name) in lit_secrets:
        continue
    hits += 1
    extra = ""
    if name in (owned.get(ns) or {}):
        extra = ("\n         Worse: that name belongs to %s, so the kubelet would find a "
                 "Secret of the WRONG type and fall back to an anonymous pull."
                 % owned[ns][name])
    print("  FAIL [C] %s references imagePullSecrets %s in namespace %s, but nothing in "
          "this repo materializes %s/%s — the pod pulls anonymously and "
          "ImagePullBackOffs against a private project.%s" % (where, name, ns, ns, name, extra))
if hits:
    fail += 1
else:
    say("  ..  [C] every imagePullSecrets reference is materialized in its own namespace")

sys.exit(1 if fail else 0)
PY

# ── the real tree ────────────────────────────────────────────────────────────
echo "-- 1) the repository as committed --"
if ANALYSE_ROOT="${REPO}" INVENTORY="${WORK}/inventory.json" python3 "${WORK}/analyse.py"; then
  ok "(1) no ExternalSecret target collides, and every pull-secret reference resolves"
else
  bad "(1) ownership/collision violations above"
fi

# ── negative controls ────────────────────────────────────────────────────────
# Each stages a COPY of specs/cluster carrying one defect on purpose. The repo
# tree is never mutated. A control that does NOT bite means the check above is
# decorative, so a silent control is itself a failure.
echo "-- 2) negative controls: each check must bite on a broken tree --"

SS="specs/cluster/manifests/external-secrets/secretstore.yaml"

stage() {  # <name> -> echoes a root dir holding a copy of specs/
  local d="${WORK}/mutant-$1"
  mkdir -p "${d}/specs"
  cp -a "${REPO}/specs/cluster" "${d}/specs/cluster"
  echo "${d}"
}
control() { # <label> <root> <expect-substring>
  local label="$1" root="$2" want="$3" outp
  outp="$(ANALYSE_ROOT="${root}" INVENTORY="${WORK}/inventory.json" ANALYSE_QUIET=1 \
          python3 "${WORK}/analyse.py" 2>&1)"
  local rc=$?
  if [ "${rc}" -eq 0 ]; then
    bad "(2) ${label}: the analyser PASSED a tree that is broken on purpose — the check is decorative"
  elif printf '%s' "${outp}" | grep -F "${want}" >/dev/null; then
    ok "(2) ${label}: bites (rc=${rc})"
  else
    bad "(2) ${label}: failed, but not for the staged reason (wanted ${want}); got: $(printf '%s' "${outp}" | head -2 | tr '\n' ' ')"
  fi
}

# (n1) THE EXACT PRE-FIX MANIFEST: aim the hugmesh-pki pull secret back at
#      harbor-registry, the name the Harbor chart owns.
M="$(stage prefix)"
python3 - "${M}/${SS}" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t = t.replace("name: hugmesh-registry-pull", "name: harbor-registry")
open(p, "w").write(t)
PY
# the consumers must move with it, or (C) would fire first and mask (A)
for f in "${M}/specs/cluster/manifests/headwind/kustomization.yaml" \
         "${M}/specs/cluster/manifests/attestation-server/kustomization.yaml" \
         "${M}/specs/cluster/apps/20-gateway-pki.yaml" \
         "${M}/specs/cluster/apps/22-gateway-superadmin.yaml"; do
  python3 - "${f}" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("hugmesh-registry-pull", "harbor-registry")
open(p, "w").write(t)
PY
done
control "n1 pre-fix manifest (ExternalSecret aimed at Harbor's harbor-registry)" \
        "${M}" "[A] ExternalSecret target hugmesh-pki/harbor-registry"

# (n2) A DIFFERENT chart-owned name — proves (A) is derived from the render and
#      not a memorised special case for the one name that bit us.
M="$(stage othername)"
python3 - "${M}/${SS}" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("name: hugmesh-registry-pull", "name: harbor-jobservice")
open(p, "w").write(t)
PY
control "n2 a DIFFERENT chart-owned name (harbor-jobservice)" \
        "${M}" "[A] ExternalSecret target hugmesh-pki/harbor-jobservice"

# (n3) two owners inside this repo: a literal Secret manifest on an ES target name
M="$(stage doubleowner)"
cat > "${M}/specs/cluster/manifests/headwind/zz-control-secret.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: hugmesh-registry-pull
  namespace: hugmesh-pki
type: Opaque
YAML
control "n3 literal Secret manifest duplicating an ExternalSecret target" \
        "${M}" "[B] ExternalSecret target hugmesh-pki/hugmesh-registry-pull"

# (n4) consumer left behind: the ExternalSecret is renamed, the workload is not
M="$(stage staleconsumer)"
python3 - "${M}/specs/cluster/manifests/headwind/kustomization.yaml" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("- name: hugmesh-registry-pull", "- name: harbor-registry")
open(p, "w").write(t)
PY
control "n4 workload still pointing at the chart-owned name" \
        "${M}" "[C] specs/cluster/manifests/headwind/kustomization.yaml references imagePullSecrets harbor-registry"

# (n5) VACUITY: a tree the scan matches nothing in must FAIL, not pass.
M="$(stage vacuous)"
find "${M}/specs/cluster" -name '*.yaml' -delete
control "n5 vacuity — an empty tree must FAIL, not report 'no collisions'" \
        "${M}" "parsed ZERO ExternalSecret targets"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
