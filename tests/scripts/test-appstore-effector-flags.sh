#!/usr/bin/env bash
# test-appstore-effector-flags.sh — the APP-STORE / Service-Catalog effector
# enablement gate. Pure PyYAML + bash; no cluster, no kubectl, no network.
#
# WHY THIS EXISTS (D3, 2026-08-26).
#
# OBSERVED: the SUPERADMIN Service Catalog was completely inert. A provision
# reported success and created nothing in-cluster; every DOCKERFILE/ZIP source
# came back 400 "requires the in-cluster image builder". Root cause was not a
# defect in the flow: all three app.appstore.* gates default FALSE in the
# admin-BFF's application.yml and manifests/admin-bff-api/deployment.yaml never
# overrode them, so only the ships-dark Noop seams were ever wired
# (NoopArgoCdClient, NoopFederationModuleClient, no KanikoBuildLauncher bean).
#
# THE DEFECT CLASS THIS GATE ACTUALLY GUARDS is not "the flags are off". It is
# the ORDERING between APPSTORE_BUILDER_ENABLED and the registry push credential
# the Kaniko build pod mounts:
#
#   * builder=false  -> AddServiceEffector rejects DOCKERFILE/ZIP with a 400.
#                       An ERROR. The operator sees it immediately.
#   * builder=true, push Secret PRESENT in the BUILD NAMESPACE
#                    -> a real Kaniko Job runs.
#   * builder=true, push Secret ABSENT (or present only in some OTHER namespace)
#                    -> the Job is created, the pod is admitted, and the kubelet
#                       cannot populate the volume. The mount is NOT
#                       `optional: true`, so the pod does not fail — it sits in
#                       ContainerCreating until activeDeadlineSeconds (1800s)
#                       while the console shows a "build" in progress. A HANG,
#                       not an error, and nothing in the BFF logs says why.
#
# A hang is the failure mode this repo keeps getting bitten by, so the coupling
# is enforced here mechanically instead of living in a comment: flipping
# APPSTORE_BUILDER_ENABLED to true WITHOUT an APPLIED manifest that creates the
# mounted Secret — under the name the Kaniko template asks for, with the `items`
# key it asks for, IN THE NAMESPACE THE BUILD JOB LANDS IN — turns this suite RED.
#
# THREE THINGS THE FIRST CUT OF THIS GUARD GOT WRONG, and why each is now checked
# (an adversarial review re-broke production and these three mutations survived):
#
#   (a) NAMESPACE-BLINDNESS. The inventory was keyed on Secret NAME alone, so an
#       ExternalSecret with the right name and the right key but targeting the
#       WRONG namespace read as satisfied. That is not a hypothetical: the file a
#       follow-up unit is told to copy — external-secrets/image-builder-
#       externalsecrets.yaml — hardcodes `namespace: hugmesh-image-builds` and its
#       own comment says the service-catalog builder secret "follows the same
#       shape". Copy-paste-and-forget-the-namespace is THE default error, and this
#       tree already carries four Secret names duplicated across namespaces
#       (harbor-registry x4, cassandra-app-creds x3, bff-internal-token x2,
#       clickhouse-auth x2). The inventory is now keyed on (namespace, name) and
#       the requirement is derived from APPSTORE_BUILDER_NAMESPACE.
#
#   (b) COUNTING MANIFESTS NOTHING APPLIES. The inventory globbed every *.yaml
#       under specs/cluster. But external-secrets/kustomization.yaml enumerates
#       `resources:` explicitly (azure-intune-externalsecrets.yaml is present on
#       disk and deliberately COMMENTED OUT of that list), service-catalog-builder/
#       kustomization.yaml lists only namespace-and-netpol.yaml, and *.tpl.yaml
#       files are templates a controller instantiates, not objects ArgoCD syncs
#       (device-ssh-externalsecret.tpl.yaml was being counted as a real Secret
#       literally named `device-ssh-<deviceId>`). A Secret written into a file
#       nothing applies does not exist. Reachability is now computed: Application/
#       ApplicationSet `path:` roots -> kustomization `resources:` chain, with
#       *.tpl.yaml / *.template.yaml excluded outright.
#
#   (c) THE FAIL MESSAGE STATED SPRING'S SEMANTICS BACKWARDS. See the
#       APPSTORE_BUILDER_ENABLED branch below — the correction is written there,
#       next to the check it describes, because this repo has inverted a check off
#       comment prose four times and the fix is never to trust the prose.
#
# The Secret name and its required keys are DERIVED FROM THE KANIKO TEMPLATE, not
# written here as a literal, so renaming the volume in the template moves the
# requirement with it instead of leaving the guard checking a stale string.
#
# SECOND SOURCE, and the reason derivation matters: the template this repo ships
# (specs/cluster/manifests/service-catalog-builder/) is NOT the one the runtime
# instantiates. KanikoBuildLauncher loads its own CLASSPATH copy from the
# admin-BFF jar (resources/kaniko/service-catalog-build-job.template.yaml), and
# as of 2026-08-26 the two DISAGREE on both the Secret name and its key:
#
#     this repo : service-catalog-builder-registry     key .dockerconfigjson
#     runtime   : service-catalog-registry-credentials key config.json
#
# Either mismatch reproduces the wedge on its own (a missing name and a missing
# `items` key both leave the pod in ContainerCreating). So when the sibling
# admin-BFF checkout is readable this suite derives from BOTH templates and
# requires BOTH contracts to be satisfied before the builder may be enabled; when
# it is not readable it says so LOUDLY and names what it could not check, rather
# than quietly asserting half the requirement.
#
# WHAT THIS SUITE PROVES:      the three flags are set to the intended values; the
#   build namespace the builder flag names is really created; the push-credential
#   mount is really non-optional (the premise of the whole guard); and the
#   builder flag cannot be enabled without its credential landing, in the right
#   namespace, in an APPLIED manifest, in the same change.
# WHAT IT DOES NOT PROVE:      that the effector works. There is no cluster in
#   this environment. It is a static manifest gate — it cannot see ArgoCD, the
#   federation API, a build node, or a single running pod.
#
# APPSTORE_FLAGS_REPO overrides the repo root so the mutation battery can run the
# REAL assertions against a mutated COPY without touching the working tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${APPSTORE_FLAGS_REPO:-$(cd "${HERE}/../.." && pwd)}"
# shellcheck source=../lib/guard-preflight.sh
. "${HERE}/../lib/guard-preflight.sh"

DEPLOY="${REPO}/specs/cluster/manifests/admin-bff-api/deployment.yaml"
TMPL="${REPO}/specs/cluster/manifests/service-catalog-builder/kaniko-build-job.template.yaml"
# The RUNTIME template, in the sibling admin-BFF checkout. READ-ONLY, and optional:
# absent on a machine that only has the generator cloned.
BFF_TMPL="${APPSTORE_BFF_TMPL:-/home/magus/Github/hugmesh-admin-bff-api/src/main/resources/kaniko/service-catalog-build-job.template.yaml}"

PY="${PYTHON:-python3}"

echo "== app-store effector enablement gate =="

# A missing interpreter or a missing PyYAML would make EVERY assertion below
# vacuous. This suite is in both CI batch lists, so it uses the repo's own
# preflight (tests/lib/guard-preflight.sh) rather than a hand-rolled skip: a guard
# that cannot run goes RED, and only a human at a terminal may opt out with
# GUARD_TOOLING_ALLOW_SKIP=1 (a variable test-guard-integrity.sh proves CI never
# sets). The old shape here — `echo SKIP…; exit 0` — turned "this runner has no
# PyYAML" into "the appstore flags are correct" for every pipeline on that image.
guard_require_tools "${PY}"
"${PY}" -c 'import yaml' >/dev/null 2>&1 \
  || guard_require_capability "${PY} has no PyYAML (the manifests cannot be parsed)"

[ -f "${DEPLOY}" ] || { echo "  FAIL admin-bff deployment missing: ${DEPLOY}"; exit 1; }
[ -f "${TMPL}" ]   || { echo "  FAIL service-catalog kaniko template missing: ${TMPL}"; exit 1; }

REPO="${REPO}" DEPLOY="${DEPLOY}" TMPL="${TMPL}" BFF_TMPL="${BFF_TMPL}" "${PY}" - <<'PY'
import os, sys, glob, yaml

REPO, DEPLOY, TMPL, BFF_TMPL = (os.environ[k] for k in ("REPO", "DEPLOY", "TMPL", "BFF_TMPL"))

P = F = 0
def ok(m):
    global P; P += 1; print("  PASS " + m)
def bad(m):
    global F; F += 1; print("  FAIL " + m)
def note(m):
    print("  NOTE " + m)

def docs_of(path):
    try:
        return [d for d in yaml.safe_load_all(open(path)) if isinstance(d, dict)], None
    except Exception as exc:
        return [], str(exc).split("\n")[0]

# ── the admin-BFF container env, parsed as YAML ───────────────────────────────
# Parsing (rather than grepping) is deliberate: this file carries long WHY blocks
# that NAME every one of these env vars in prose. A grep for APPSTORE_BUILDER_
# ENABLED matches four comment lines here, and this repo has inverted exactly that
# kind of check four times. YAML parsing drops comments by construction.
env = {}
bff_ns = None
for doc in yaml.safe_load_all(open(DEPLOY)):
    if doc and doc.get("kind") == "Deployment":
        bff_ns = (doc.get("metadata") or {}).get("namespace")
        for c in doc["spec"]["template"]["spec"]["containers"]:
            for e in c.get("env", []):
                env[e["name"]] = e
if not env:
    bad("no Deployment container env parsed out of %s" % DEPLOY); print(); sys.exit(1)

def value_of(name):
    e = env.get(name)
    return None if e is None or "value" not in e else str(e["value"]).strip()

# ── 1. the flags are set, to the values this change intends ───────────────────
for name, want, why in (
        ("APPSTORE_EFFECTOR_ENABLED",   "true",
         "ArgoCdConfig swaps NoopArgoCdClient -> RestArgoCdClient"),
        ("APPSTORE_FEDERATION_ENABLED", "true",
         "FederationModuleClientConfig swaps Noop -> RestFederationModuleClient"),
):
    got = value_of(name)
    if got is None:
        bad("%s is not set in the deployment — the BFF default (false) wins and the "
            "leg stays dark (%s)" % (name, why))
    elif got != want:
        bad("%s is %r, expected %r (%s)" % (name, got, want, why))
    else:
        ok("%s=%s — %s" % (name, want, why))

builder = value_of("APPSTORE_BUILDER_ENABLED")
if builder is None:
    bad("APPSTORE_BUILDER_ENABLED is not set at all. Leave it EXPLICITLY false "
        "rather than absent: the whole point of this gate is that its state is "
        "reviewable in the manifest next to the credential it depends on.")
elif builder not in ("true", "false"):
    # READ THE ANNOTATION, NOT THIS COMMENT — and the annotation is:
    #   KanikoBuildLauncher.java:60   @ConditionalOnProperty("app.appstore.builder.enabled")
    # The single-argument form carries NO havingValue, and Spring's
    # OnPropertyCondition matches, when havingValue is empty, for any present value
    # that is not "false" (case-insensitive):
    #     if (StringUtils.hasLength(requiredValue)) return requiredValue.equalsIgnoreCase(value);
    #     return !"false".equalsIgnoreCase(value);
    # So "TRUE", "True", "yes", "1" and even "" all ENABLE the Kaniko builder —
    # they do NOT ship dark. (ArgoCdConfig.java:38 uses havingValue="true", also
    # compared with equalsIgnoreCase, so "TRUE" enables the real ArgoCD client too.)
    # The literal check on this line is the ONLY thing standing between a typo and
    # the ContainerCreating wedge. DO NOT "fix" it into a case-insensitive compare:
    # that would make every value the annotation accepts pass this guard.
    bad("APPSTORE_BUILDER_ENABLED is %r — must be the literal \"true\" or \"false\". "
        "KanikoBuildLauncher's @ConditionalOnProperty carries no havingValue, so "
        "Spring ENABLES the builder for ANY value other than \"false\" "
        "(case-insensitive): TRUE/True/yes/1/empty all switch it ON. A typo here "
        "does not ship dark — it silently arms the wedge this guard exists to "
        "prevent. Write the literal." % builder)
else:
    ok("APPSTORE_BUILDER_ENABLED=%s (explicit literal)" % builder)
builder_on = (builder == "true")

# ── 2. derive the push-credential contract FROM THE KANIKO TEMPLATE(S) ────────
def derive(path, label):
    """(secretName, required_keys, optional_flag, label) for the volume mounted at
    /kaniko/.docker — derived, never hardcoded."""
    d = yaml.safe_load(open(path))
    spec = d["spec"]["template"]["spec"]
    vols = {v["name"]: v for v in spec.get("volumes", [])}
    for c in spec["containers"]:
        for m in c.get("volumeMounts", []):
            if m["mountPath"].rstrip("/").startswith("/kaniko/.docker"):
                v = vols.get(m["name"], {}).get("secret")
                if v is None:
                    return None
                keys = {i["key"] for i in v.get("items", []) if "key" in i}
                return (v.get("secretName"), keys, bool(v.get("optional", False)), label)
    return None

contracts = []
c = derive(TMPL, "this repo's template")
if c is None:
    bad("could not derive the /kaniko/.docker Secret from %s — the guard below "
        "would be vacuous, so this is a hard failure, not a skip" % TMPL)
else:
    contracts.append(c)
    ok("derived push credential from %s: Secret %r, required keys %s"
       % (os.path.relpath(TMPL, REPO), c[0], sorted(c[1]) or "(whole secret)"))

# The RUNTIME template lives in the sibling admin-BFF checkout and is the one
# KanikoBuildLauncher actually loads. Its absence is a real hole in coverage, so
# say which requirement went unchecked instead of passing quietly.
if os.path.isfile(BFF_TMPL):
    cb = derive(BFF_TMPL, "admin-BFF runtime template")
    if cb is None:
        bad("could not derive the /kaniko/.docker Secret from the runtime template "
            "%s" % BFF_TMPL)
    else:
        contracts.append(cb)
        ok("derived push credential from the RUNTIME template %s: Secret %r, "
           "required keys %s" % (BFF_TMPL, cb[0], sorted(cb[1]) or "(whole secret)"))
        if c is not None and (cb[0] != c[0] or cb[1] != c[1]):
            note("the two templates DISAGREE (%r keys %s  vs  %r keys %s). "
                 "KanikoBuildLauncher loads the RUNTIME one, so satisfying only this "
                 "repo's name still wedges the build pod. Both contracts are required "
                 "below before the builder may be enabled."
                 % (c[0], sorted(c[1]), cb[0], sorted(cb[1])))
else:
    note("UNCHECKED: the admin-BFF runtime Kaniko template is not readable at %s "
         "(sibling checkout absent). The runtime Secret contract could NOT be "
         "verified from here — only this repo's template was used. Set "
         "APPSTORE_BFF_TMPL to point at it." % BFF_TMPL)

# ── 3. the mount really is non-optional — the PREMISE of the wedge ───────────
# If someone sets `optional: true` the pod starts with no credential and the push
# FAILS loudly instead of hanging. That is a different (better) failure mode and
# would make the coupling guard unnecessary — so the premise is asserted, not
# assumed, and a change to it has to be deliberate.
for name, keys, is_optional, label in contracts:
    if is_optional:
        bad("%s: the /kaniko/.docker secret volume is `optional: true`. This guard "
            "exists because a NON-optional mount of a missing Secret HANGS the pod "
            "in ContainerCreating. If the mount is now optional, re-derive whether "
            "this coupling is still the right gate." % label)
    else:
        ok("%s: the /kaniko/.docker mount is NON-optional — a missing Secret wedges "
           "the pod, which is why the coupling below is enforced" % label)

# ── 4. WHICH MANIFESTS ARE ACTUALLY APPLIED ───────────────────────────────────
# A Secret written into a file nothing syncs does not exist in the cluster, so
# counting it would be a false GREEN on the one question this suite is for.
# Reachability, deliberately conservative:
#
#   root      = every `path:` an Application / ApplicationSet source names
#               (specs/cluster/apps/*.yaml). A directory no Application points at
#               is not synced by ArgoCD.
#   within a root directory:
#       - kustomization.yaml present -> ONLY the files its `resources:` list names
#         are applied. Parsing it as YAML is what makes a COMMENTED-OUT entry
#         (azure-intune-externalsecrets.yaml) correctly read as not-applied; a grep
#         would have counted it. `resources:` entries that are directories are
#         followed, inheriting the `namespace:` transformer.
#       - no kustomization.yaml -> ArgoCD's plain directory sync applies the *.yaml
#         in that directory (recursively only when directory.recurse is set).
#   *.tpl.yaml / *.template.yaml are NEVER applied: they are templates a
#   controller instantiates per object (device-ssh-externalsecret.tpl.yaml would
#   otherwise register a Secret literally named `device-ssh-<deviceId>`).
TEMPLATE_SUFFIXES = (".tpl.yaml", ".template.yaml")
SPECS = os.path.join(REPO, "specs/cluster")

all_yaml = sorted(glob.glob(os.path.join(SPECS, "**", "*.yaml"), recursive=True))
unparseable = []
parsed = {}
for path in all_yaml:
    ds, err = docs_of(path)
    if err is not None:
        unparseable.append((os.path.relpath(path, REPO), err))
        continue
    parsed[path] = ds

roots = {}            # abs dir -> recurse?
templated_roots = []
for path, ds in parsed.items():
    for d in ds:
        kind = d.get("kind")
        if kind == "Application":
            specs_ = [d.get("spec") or {}]
        elif kind == "ApplicationSet":
            specs_ = [((d.get("spec") or {}).get("template") or {}).get("spec") or {}]
        else:
            continue
        for sp in specs_:
            srcs = sp.get("sources") or ([sp["source"]] if "source" in sp else [])
            for s in srcs:
                if not isinstance(s, dict) or not s.get("path"):
                    continue
                p = str(s["path"]).strip("/")
                if "{{" in p:
                    templated_roots.append((os.path.relpath(path, REPO), p))
                    continue
                if not p.startswith("specs/cluster"):
                    continue     # another repo's path (e.g. the service-catalog's own)
                ab = os.path.normpath(os.path.join(REPO, p))
                rec = bool((s.get("directory") or {}).get("recurse"))
                roots[ab] = roots.get(ab, False) or rec

applied = {}          # abs file -> namespace transformer inherited from kustomize
def walk_dir(d, ns, recurse, seen):
    if d in seen or not os.path.isdir(d):
        return
    seen.add(d)
    kust = os.path.join(d, "kustomization.yaml")
    if os.path.isfile(kust):
        k = parsed.get(kust)
        k = k[0] if k else {}
        kns = k.get("namespace") or ns
        for r in (k.get("resources") or []):
            if not isinstance(r, str) or "://" in r:
                continue        # remote base — out of this repo, cannot be scanned
            t = os.path.normpath(os.path.join(d, r))
            if os.path.isdir(t):
                walk_dir(t, kns, False, seen)
            elif os.path.isfile(t):
                applied[t] = kns
        return
    for f in sorted(os.listdir(d)):
        ab = os.path.join(d, f)
        if os.path.isdir(ab):
            if recurse:
                walk_dir(ab, ns, recurse, seen)
        elif f.endswith(".yaml") and f != "kustomization.yaml":
            applied[ab] = ns

for ab, rec in roots.items():
    walk_dir(ab, None, rec, set())

def is_template(p):
    return any(os.path.basename(p).endswith(s) for s in TEMPLATE_SUFFIXES)

# ── 5. inventory every Secret / ExternalSecret specs/cluster actually creates ──
# Keyed on (NAMESPACE, name). Name alone is not an identity here: this tree
# already ships harbor-registry in four namespaces, cassandra-app-creds in three,
# bff-internal-token and clickhouse-auth in two each — and a build Job can only
# mount a Secret that lives in ITS OWN namespace.
def inventory(paths, ns_of):
    created = {}
    for path in sorted(paths):
        if is_template(path):
            continue
        for d in parsed.get(path, ()):
            kind = d.get("kind")
            meta = d.get("metadata") or {}
            if kind == "Secret":
                ns = meta.get("namespace") or ns_of(path)
                keys = set((d.get("data") or {})) | set((d.get("stringData") or {}))
                created.setdefault((ns, meta.get("name")), set()).update(keys or {"*"})
            elif kind == "ExternalSecret":
                spec = d.get("spec") or {}
                target = spec.get("target") or {}
                # ESO materializes the target Secret in the ExternalSecret's OWN
                # namespace; v1beta1 has no cross-namespace target. target.namespace
                # is still honoured if a future CRD grows one.
                ns = target.get("namespace") or meta.get("namespace") or ns_of(path)
                nm = target.get("name") or meta.get("name")
                tmplD = ((target.get("template") or {}).get("data") or {})
                keys = set(tmplD) | {x.get("secretKey") for x in (spec.get("data") or [])
                                     if x.get("secretKey")}
                if spec.get("dataFrom") and not tmplD:
                    keys.add("*")      # extract/find: contents unknown statically
                created.setdefault((ns, nm), set()).update(keys or {"*"})
    return created

created = inventory(applied.keys(), lambda p: applied.get(p))
# Everything on disk, applied or not — used ONLY to make a failure say WHY, never
# to satisfy a requirement.
on_disk = inventory(parsed.keys(), lambda p: None)

if unparseable:
    # Fail-closed by construction (an unreadable file can only make a required
    # Secret look ABSENT, never present) but say so — a parse regression that hid
    # half the tree would otherwise look like a clean run.
    note("%d file(s) under specs/cluster did not parse and were not scanned for "
         "Secrets: %s" % (len(unparseable), ", ".join(p for p, _ in unparseable[:5])))
if templated_roots:
    note("%d Application source path(s) are Go-templated and could not be resolved "
         "to a directory (%s) — manifests under them are treated as NOT applied, "
         "which can only make a required Secret look absent, never present"
         % (len(templated_roots), ", ".join("%s -> %s" % t for t in templated_roots[:3])))

# The reachability walk above is the load-bearing new machinery. If it ever
# returns (almost) nothing — a renamed apps/ directory, a kustomize field this
# parser stops understanding — every coupling assertion below would go vacuously
# "ABSENT" and the ARMED line would lie about what is present. Assert it found the
# tree it thinks it is reading.
if len(applied) < 50 or len(created) < 20:
    bad("the applied-manifest walk found only %d file(s) and %d Secret/ExternalSecret "
        "target(s) under specs/cluster — that is not this repo, so the reachability "
        "filter is broken and every check below would be vacuous"
        % (len(applied), len(created)))
else:
    ok("applied-manifest walk: %d file(s) reachable from %d ArgoCD path root(s), "
       "producing %d (namespace, Secret) target(s); %d on-disk target(s) are NOT "
       "reachable and do not count"
       % (len(applied), len(roots), len(created), len(set(on_disk) - set(created))))

# ── 6. the build namespace the flag names must actually be created ────────────
# A Job created into a namespace that does not exist is REJECTED by the API
# server — the same defect one layer up from the missing Secret, but a LOUD one.
namespaces_applied, namespaces_any = set(), {}
for path, ds in parsed.items():
    if is_template(path):
        continue
    for d in ds:
        if d.get("kind") == "Namespace" and (d.get("metadata") or {}).get("name"):
            n = d["metadata"]["name"]
            namespaces_any.setdefault(n, os.path.relpath(path, REPO))
            if path in applied:
                namespaces_applied.add(n)

bns = value_of("APPSTORE_BUILDER_NAMESPACE")
if bns is None:
    note("APPSTORE_BUILDER_NAMESPACE unset; the BFF default applies")
elif bns in namespaces_applied:
    ok("build namespace %s is created by an APPLIED manifest under specs/cluster" % bns)
elif bns in namespaces_any:
    # specs/cluster/namespaces/ is applied by bootstrap.sh, not by an ArgoCD
    # Application, so "not reachable from a path root" is not proof of absence for
    # a Namespace. Say which file, and do not fail on it.
    note("build namespace %s is created by %s, which is not reachable from any "
         "ArgoCD Application path (bootstrap-applied dirs legitimately are not) — "
         "existence NOT proven from here" % (bns, namespaces_any[bns]))
else:
    bad("APPSTORE_BUILDER_NAMESPACE=%s but no Namespace manifest under specs/cluster "
        "creates it — every Kaniko Job would be rejected by the API server" % bns)

# ── 7. THE COUPLING GUARD ─────────────────────────────────────────────────────
# The Kaniko Job is created INTO APPSTORE_BUILDER_NAMESPACE, and a pod can only
# mount a Secret from its own namespace. So the requirement is the TUPLE.
required = [(n, k, label) for (n, k, _o, label) in contracts]

def elsewhere(name):
    other = sorted(ns for (ns, nm) in on_disk if nm == name)
    return ", ".join("%s" % (ns,) for ns in other) if other else ""

if builder_on and bns is None:
    bad("APPSTORE_BUILDER_ENABLED=true but APPSTORE_BUILDER_NAMESPACE is not set in "
        "the deployment, so the namespace the push credential must live in cannot "
        "be determined from here and the coupling check below would be vacuous. "
        "Pin the namespace explicitly.")
elif builder_on:
    for name, keys, label in required:
        have = created.get((bns, name))
        if have is None:
            other = elsewhere(name)
            bad("APPSTORE_BUILDER_ENABLED=true but NO APPLIED manifest under "
                "specs/cluster creates the Secret %r IN NAMESPACE %s, which %s "
                "requires. This is the WEDGE: the Kaniko build pod mounts it "
                "non-optionally and a pod can only mount a Secret from its own "
                "namespace, so a build will sit in ContainerCreating for 1800s "
                "instead of failing.%s Land the ExternalSecret first (unit D1), "
                "then flip the flag."
                % (name, bns, label,
                   (" A Secret of that name IS declared in namespace(s) [%s] — "
                    "copying image-builder-externalsecrets.yaml and leaving its "
                    "`namespace: hugmesh-image-builds` in place is exactly this "
                    "mistake." % other) if other else
                   " (No manifest declares that name in any namespace, applied or "
                   "not.)"))
            continue
        missing = {k for k in keys if k not in have} if "*" not in have else set()
        if missing:
            bad("APPSTORE_BUILDER_ENABLED=true and Secret %r exists in namespace %s, "
                "but it does not produce the key(s) %s that %s mounts via `items`. A "
                "missing `items` key wedges the pod in ContainerCreating exactly like "
                "a missing Secret does — the kubelet cannot populate the volume."
                % (name, bns, sorted(missing), label))
        else:
            ok("builder enabled AND its push credential %r (keys %s, %s) is created "
               "by an applied manifest in namespace %s"
               % (name, sorted(keys) or "(whole secret)", label, bns))
else:
    # Not a skip: the guard ran, the premise is simply not met yet. Name exactly
    # what must land before the flag may flip so this is actionable from the log.
    ok("APPSTORE_BUILDER_ENABLED is false — DOCKERFILE/ZIP stay 400-guarded (the "
       "SAFE state). Coupling guard is ARMED: flipping it true requires, in "
       "namespace %s, " % bns
       + "; ".join("Secret %r with key(s) %s (%s)"
                   % (n, sorted(k) or "(whole secret)", label)
                   for n, k, label in required)
       + " — " + ", ".join("%r: %s" % (n, "PRESENT" if (bns, n) in created else
                                       ("ABSENT here (declared in [%s])" % elsewhere(n)
                                        if elsewhere(n) else "ABSENT"))
                           for n, _k, _l in required))

# ── 8. no appstore token may be a secretKeyRef to a Secret nothing creates ────
# The same hang, one layer up and aimed at the admin-BFF pod itself: a
# non-optional secretKeyRef naming a Secret that does not exist leaves THIS
# deployment in CreateContainerConfigError. Both appstore bearer tokens are
# currently unset (empty default -> a real call that 401s, which is LOUD); this
# assertion is what stops a follow-up from "fixing" that with a dangling ref.
# Namespace-keyed for the same reason as above: the admin-BFF pod can only read a
# Secret in its OWN namespace.
for name in ("APPSTORE_ARGOCD_AUTH_TOKEN", "APPSTORE_FEDERATION_AUTH_TOKEN"):
    e = env.get(name)
    if e is None:
        note("%s is not set — the leg makes a real call with an empty Bearer and "
             "gets 401 until a token is provisioned. LOUD, not a hang." % name)
        continue
    ref = ((e.get("valueFrom") or {}).get("secretKeyRef") or {})
    if not ref:
        ok("%s is set inline (no dangling secretKeyRef)" % name)
    elif ref.get("optional") is True:
        ok("%s secretKeyRef is optional — a missing Secret cannot wedge the pod" % name)
    elif (bff_ns, ref.get("name")) in created:
        ok("%s secretKeyRef -> Secret %r in %s, which an applied manifest creates"
           % (name, ref.get("name"), bff_ns))
    else:
        other = elsewhere(ref.get("name"))
        bad("%s is a NON-optional secretKeyRef to Secret %r, which no applied "
            "manifest under specs/cluster creates in the admin-BFF's own namespace "
            "(%s)%s — the admin-BFF pod would wedge in CreateContainerConfigError"
            % (name, ref.get("name"), bff_ns,
               " (it is declared in [%s])" % other if other else ""))

print()
print("  %d passed, %d failed" % (P, F))
sys.exit(1 if F else 0)
PY
