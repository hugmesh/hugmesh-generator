#!/usr/bin/env python3
"""image_builder_always_on.py — static gate for the ALWAYS-ON in-cluster Kaniko
image-build pipeline.

Nothing in CI referenced the image-builder at all before this: the flip from
`apps-optional/` (a directory no ArgoCD root recurses) to `apps/` (the set the root
app-of-apps syncs continuously) is a LIVE-BEHAVIOUR change that no gate could see, and
the CI dispatcher's defaults still named repos the org-wide rebrand retired.

Takes a root directory containing `.gitlab-ci.yml` and `specs/cluster/`, so the bash
driver can re-run it against a deliberately-corrupted staged copy (negative controls).
Prints one line per finding, tagged with the check name. Exit 0 = clean.
"""
from __future__ import annotations

import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the driver checks this first
    print("  FAIL PyYAML not available (pip install pyyaml)")
    sys.exit(2)

APP_NAME = "image-builder"
APP_BASENAME = "60-image-builder.yaml"
ALWAYS_SYNCED_DIR = "specs/cluster/apps"
MANIFEST_DIR = "specs/cluster/manifests/image-builder"
JOB_TEMPLATE = "kaniko-build-job.template.yaml"
ESO_FILE = "specs/cluster/manifests/external-secrets/image-builder-externalsecrets.yaml"
ROOT_APP = "specs/cluster/app-of-apps.yaml"
WAVED_ROOT = "specs/cluster/apps/00-app-of-apps-waved.yaml"
CI_FILE = ".gitlab-ci.yml"
CI_JOB = "build:images"

# Pre-rebrand scan. Two occurrences of the old brand are NOT stale and must survive —
# but ONLY IN ONE SYNTACTIC POSITION EACH:
#   * `snapdragon.systems/<name>:` as a YAML mapping KEY — the FROZEN label-KEY /
#     annotation namespace. It is wire identity, not brand: docs/BRANDING.md ("Never
#     rebranded … label KEYS") and scripts/tooling/tokens.json
#     ("label_key_namespaces": ["snapdragon.systems/"]), enforced fail-closed at render.
#   * `snapdragon-deploy.yaml` (and its `.example.` sibling) — the LEGACY service-catalog
#     deploy-descriptor filename, which 6 of the 9 adopting repos still ship on disk and
#     which both catalog generators deliberately still accept (#498).
# Everything else bearing the old brand in this surface is a rebrand miss.
#
# RETIRED ALLOWLIST ENTRY — `github.com/Snapdragon-Systems/` (was entry (b)). Git hosting
# has since moved: every repo's `origin` is `github.com/hugmesh/<repo>`, and no file in this
# scanned surface carries the old org path any more. Snapdragon-Systems remains only as a
# retained downstream FORK org, which is not a hugmesh source-of-truth path and must not be
# written into hugmesh's own specs. Keeping the exemption would silently re-admit that org
# segment anywhere under a `github.com/` host, so it is gone and such a path is now a
# finding like any other.
#
# POSITION MATTERS, AND THE FIRST VERSION OF THIS CHECK IGNORED IT. It held the RAW
# substrings ("snapdragon.systems/", "Snapdragon-Systems") and did
# `line.replace(frozen, "")` over the WHOLE line before running BRAND_RE. That strip is
# positional-blind, so it also deleted the token from every FUNCTIONAL identifier of the
# shape `<host-or-scheme>snapdragon.systems/<path>` — and those are exactly the shapes
# this check exists to catch:
#     DEST_REPO: "registry.snapdragon.systems/hugmesh/hugmesh-gateway"   (Kaniko PUSH target)
#     image:      registry.snapdragon.systems/hugmesh/…                  (Job template)
#     repoURL:    https://git.snapdragon.systems/hugmesh/hugmesh-generator.git  (ArgoCD source)
# All three passed the old check with exit 0. They are negative controls 9c/9e/9f now.
#
# So the allowlist is a list of ANCHORED regexes, and matching is POSITIONAL: a brand-token
# occurrence is exempt only when its span lies inside the span an allowlist pattern marks as
# frozen. An occurrence anywhere else is a finding, no matter what text surrounds it.
BRAND_RE = re.compile(r"snapdragon", re.IGNORECASE)
ALLOWLIST_RES = (
    # (a) the frozen label-KEY namespace, in mapping-KEY position only: nothing may precede
    #     it on the line except indentation / a YAML list dash, and a `:` must follow the
    #     label name. `registry.snapdragon.systems/…` and `…/snapdragon.systems/x` are NOT
    #     matched — the `^[ \t-]*` anchor is what makes this positional rather than textual.
    #     The label NAME is the Kubernetes grammar exactly (alphanumerics, `-`, `_`, `.`;
    #     NO further `/`), so that a registry path in key position —
    #     `snapdragon.systems/hugmesh/hugmesh-gateway:` — cannot borrow the frozen prefix to
    #     smuggle a `host/project/repo` identifier past the check. A wider charset here would
    #     re-open the very hole this allowlist was rewritten to close (negative control 9i).
    re.compile(r"^[ \t-]*(?P<tok>snapdragon\.systems)/[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?:"),
    # (c) the LEGACY DEPLOY-DESCRIPTOR FILENAME, which is still live on disk in other repos.
    #     The rebrand renamed it to `hugmesh-deploy.yaml` in only 3 of the 9 adopting repos;
    #     the other 6 still ship `snapdragon-deploy.yaml`, and the service-catalog generators
    #     deliberately accept BOTH spellings (#498 — dropping the legacy name makes those 6
    #     repos invisible to the catalog again). So it is a live filename, not a rebrand miss.
    #     Anchored to the WHOLE filename token — nothing of the `[\w.-]` class may precede it
    #     and no name character may follow — so `registry.snapdragon-deploy.yaml/hugmesh/…`
    #     cannot borrow it as a host prefix (negative control 9j).
    re.compile(r"(?<![\w.-])(?P<tok>snapdragon)-deploy(\.example)?\.yaml(?![\w-])"),
)


def unallowlisted_brand_spans(line: str) -> list[tuple[int, int]]:
    """Spans of every pre-rebrand brand token on `line` that is NOT in a frozen position.

    Positional, not substring-stripping: each BRAND_RE hit is kept unless it falls inside
    a span an ALLOWLIST_RES pattern marked frozen. See the block comment above for why the
    substring-strip form was blind to every functional `…snapdragon.systems/<path>`.
    """
    frozen_spans = [
        m.span("tok") for rx in ALLOWLIST_RES for m in rx.finditer(line)
    ]
    return [
        m.span()
        for m in BRAND_RE.finditer(line)
        if not any(lo <= m.start() and m.end() <= hi for lo, hi in frozen_spans)
    ]

findings: list[str] = []


def fail(check: str, msg: str) -> None:
    findings.append(f"  FAIL [{check}] {msg}")


def load_yaml_docs(path: str):
    with open(path, encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]


# Top-level `.gitlab-ci.yml` keys that configure the pipeline rather than declare a job.
CI_GLOBAL_KEYS = frozenset(
    {
        "stages", "variables", "default", "include", "workflow", "image", "services",
        "before_script", "after_script", "cache", "pages",
    }
)


def ci_jobs(ci: dict) -> dict:
    """Every real job in a parsed .gitlab-ci.yml, with `extends:` resolved.

    Resolution matters here: `dast:main-baseline`, `dast:main-full` and `load:main` carry no
    `stage:` of their own — they inherit it from the hidden `.dast-base` / `.load-base`
    templates. A naive walk over top-level keys with a `stage` would skip all three, i.e.
    skip most of what the ordering check below exists to protect.
    """

    def resolve(name: str, seen: frozenset) -> dict:
        raw = ci.get(name)
        if not isinstance(raw, dict) or name in seen:
            return {}
        seen = seen | {name}
        parents = raw.get("extends")
        if isinstance(parents, str):
            parents = [parents]
        merged: dict = {}
        for parent in parents or []:
            merged.update(resolve(parent, seen))
        merged.update({k: v for k, v in raw.items() if k != "extends"})
        return merged

    out: dict = {}
    for name, raw in ci.items():
        # Keys starting with '.' are hidden templates, never scheduled as jobs.
        if name in CI_GLOBAL_KEYS or name.startswith(".") or not isinstance(raw, dict):
            continue
        job = resolve(name, frozenset())
        if "script" in job or "trigger" in job or "stage" in job:
            out[name] = job
    return out


def stage_order_blockers(job: dict, candidate: str) -> set:
    """Jobs that must succeed before `job` starts, as far as `candidate` is concerned.

    GitLab semantics: a job with NO `needs:` waits for every job in every earlier stage, so
    it is blocked by `candidate`. A job WITH `needs:` runs as soon as exactly those jobs are
    done — so it is blocked only if `candidate` is named in them (and an entry may be a bare
    string or a mapping with `job:`).
    """
    needs = job.get("needs")
    if needs is None:
        return {candidate}
    if not isinstance(needs, list):
        return set()
    named = {n if isinstance(n, str) else (n or {}).get("job") for n in needs}
    return {candidate} & named


def main(root: str) -> int:
    def p(*parts: str) -> str:
        return os.path.join(root, *parts)

    # ── 1) [app-location] the Application is in the always-synced set ───────────
    # Find every ArgoCD Application named `image-builder` anywhere under specs/cluster,
    # so renaming/relocating the file cannot make this check silently vacuous.
    located: list[str] = []
    cluster_root = p("specs", "cluster")
    for dirpath, _dirnames, filenames in os.walk(cluster_root):
        for fn in filenames:
            if not fn.endswith((".yaml", ".yml")):
                continue
            full = os.path.join(dirpath, fn)
            try:
                docs = load_yaml_docs(full)
            except Exception:
                continue  # parse errors are lint:cluster-manifest-integrity's job
            for doc in docs:
                if (
                    doc.get("kind") == "Application"
                    and str(doc.get("apiVersion", "")).startswith("argoproj.io/")
                    and (doc.get("metadata") or {}).get("name") == APP_NAME
                ):
                    located.append(os.path.relpath(full, root))

    if not located:
        fail("app-location", f"no ArgoCD Application named {APP_NAME!r} found under specs/cluster")
    elif len(located) > 1:
        fail("app-location", f"{APP_NAME!r} Application defined more than once: {sorted(located)}")
    else:
        rel = located[0].replace(os.sep, "/")
        if os.path.dirname(rel) != ALWAYS_SYNCED_DIR:
            fail(
                "app-location",
                f"the {APP_NAME!r} Application is at {rel} — it must live directly in "
                f"{ALWAYS_SYNCED_DIR}/ to be synced by the root app-of-apps; a sibling "
                f"directory (e.g. apps-optional/) is NOT recursed by any root, so the "
                f"pipeline would ship dark again",
            )

    stray = p("specs", "cluster", "apps-optional", APP_BASENAME)
    if os.path.exists(stray):
        fail("app-location", "specs/cluster/apps-optional/%s still exists (the opt-in copy)" % APP_BASENAME)

    # ── 2) [always-synced] apps/ really IS the always-synced set ────────────────
    # Without this, check 1 is a naked filename assertion: it would keep passing even if
    # someone narrowed the root's path or turned recursion off.
    if not os.path.exists(p(ROOT_APP)):
        fail("always-synced", f"missing {ROOT_APP}")
    else:
        roots = [d for d in load_yaml_docs(p(ROOT_APP)) if d.get("kind") == "Application"]
        if not roots:
            fail("always-synced", f"{ROOT_APP} declares no Application")
        for doc in roots:
            src = (doc.get("spec") or {}).get("source") or {}
            if src.get("path") != ALWAYS_SYNCED_DIR:
                fail(
                    "always-synced",
                    f"root app-of-apps source.path is {src.get('path')!r}, expected "
                    f"{ALWAYS_SYNCED_DIR!r} — the image-builder Application would not be synced",
                )
            if (src.get("directory") or {}).get("recurse") is not True:
                fail("always-synced", "root app-of-apps no longer sets directory.recurse: true")
            auto = ((doc.get("spec") or {}).get("syncPolicy") or {}).get("automated")
            if not auto:
                fail("always-synced", "root app-of-apps is no longer automated (syncPolicy.automated absent)")

    # The waved alternative root syncs the same directory; its exclude must not hide us.
    if os.path.exists(p(WAVED_ROOT)):
        for doc in load_yaml_docs(p(WAVED_ROOT)):
            if doc.get("kind") != "Application":
                continue
            src = (doc.get("spec") or {}).get("source") or {}
            exclude = (src.get("directory") or {}).get("exclude") or ""
            if APP_BASENAME in exclude:
                fail(
                    "always-synced",
                    f"the waved root excludes {APP_BASENAME} ({exclude!r}) — it would not sync "
                    f"under the waved topology",
                )

    # ── 3) [app-structure] the Application is structurally valid ───────────────
    app_path = p(ALWAYS_SYNCED_DIR, APP_BASENAME)
    if not os.path.exists(app_path):
        fail("app-structure", f"missing {ALWAYS_SYNCED_DIR}/{APP_BASENAME}")
    else:
        docs = [d for d in load_yaml_docs(app_path) if d.get("kind") == "Application"]
        if len(docs) != 1:
            fail("app-structure", f"{APP_BASENAME} must declare exactly one Application, found {len(docs)}")
        for doc in docs:
            meta, spec = doc.get("metadata") or {}, doc.get("spec") or {}
            if meta.get("namespace") != "devops":
                fail("app-structure", f"Application metadata.namespace is {meta.get('namespace')!r}, expected 'devops'")
            src = spec.get("source") or {}
            for key in ("repoURL", "targetRevision", "path"):
                if not src.get(key):
                    fail("app-structure", f"Application spec.source.{key} is missing/empty")
            if not (spec.get("destination") or {}).get("server"):
                fail("app-structure", "Application spec.destination.server is missing/empty")
            src_path = src.get("path") or ""
            if src_path:
                if src_path != MANIFEST_DIR:
                    fail("app-structure", f"Application source.path is {src_path!r}, expected {MANIFEST_DIR!r}")
                if not os.path.isdir(p(src_path)):
                    fail("app-structure", f"Application source.path {src_path!r} is not a directory in this repo")
                elif not os.path.exists(p(src_path, "kustomization.yaml")):
                    fail("app-structure", f"Application source.path {src_path!r} has no kustomization.yaml")
            opts = (spec.get("syncPolicy") or {}).get("syncOptions") or []
            if "CreateNamespace=false" not in opts:
                fail(
                    "app-structure",
                    "Application must set syncOptions CreateNamespace=false — the kustomization "
                    "creates the namespace itself, so ArgoCD must not also try",
                )

    # ── 4) [manifests] the synced manifests are structurally valid + agree ─────
    kust_path = p(MANIFEST_DIR, "kustomization.yaml")
    resources: list[str] = []
    if not os.path.exists(kust_path):
        fail("manifests", f"missing {MANIFEST_DIR}/kustomization.yaml")
    else:
        kust = load_yaml_docs(kust_path)[0]
        resources = list(kust.get("resources") or [])
        if not resources:
            fail("manifests", "the image-builder kustomization lists no resources")
        for res in resources:
            if not os.path.exists(p(MANIFEST_DIR, res)):
                fail("manifests", f"kustomization resource {res!r} does not exist")

    ns_names: set[str] = set()
    netpols: list[tuple[str, str]] = []
    for res in resources:
        res_path = p(MANIFEST_DIR, res)
        if not os.path.exists(res_path):
            continue
        try:
            docs = load_yaml_docs(res_path)
        except Exception as exc:
            fail("manifests", f"{res} is not parseable YAML: {exc}")
            continue
        for doc in docs:
            meta = doc.get("metadata") or {}
            if doc.get("kind") == "Namespace":
                ns_names.add(meta.get("name"))
                labels = meta.get("labels") or {}
                if labels.get("pod-security.kubernetes.io/enforce") != "restricted":
                    fail(
                        "manifests",
                        f"namespace {meta.get('name')!r} does not enforce Pod Security "
                        f"'restricted' — build pods run arbitrary Dockerfiles",
                    )
            elif doc.get("kind") == "NetworkPolicy":
                netpols.append((meta.get("name"), meta.get("namespace")))
                spec = doc.get("spec") or {}
                if "Ingress" in (spec.get("policyTypes") or []) and spec.get("ingress"):
                    fail(
                        "manifests",
                        f"NetworkPolicy {meta.get('name')!r} is not default-deny ingress "
                        f"(build pods serve nothing)",
                    )

    if len(ns_names) != 1:
        fail("manifests", f"expected exactly one Namespace in the synced manifests, found {sorted(ns_names)}")
    build_ns = next(iter(ns_names), None)
    if not netpols:
        fail("manifests", "no NetworkPolicy in the synced manifests")
    for name, ns in netpols:
        if ns != build_ns:
            fail("manifests", f"NetworkPolicy {name!r} is in namespace {ns!r}, not the build namespace {build_ns!r}")

    # ── 5) [ships-dark] the Kaniko Job stays a template ────────────────────────
    if not os.path.exists(p(MANIFEST_DIR, JOB_TEMPLATE)):
        fail("ships-dark", f"missing {MANIFEST_DIR}/{JOB_TEMPLATE}")
    if JOB_TEMPLATE in resources:
        fail(
            "ships-dark",
            f"{JOB_TEMPLATE} is listed in the kustomization — ArgoCD would apply an "
            f"unrendered Job (with literal ${{...}} placeholders) on every sync",
        )

    # ── 6) [eso] the push credential targets the namespace this app creates ────
    if not os.path.exists(p(ESO_FILE)):
        fail("eso", f"missing {ESO_FILE}")
    elif build_ns:
        targets = set()
        for doc in load_yaml_docs(p(ESO_FILE)):
            if doc.get("kind") == "ExternalSecret":
                targets.add((doc.get("metadata") or {}).get("namespace"))
        if targets and targets != {build_ns}:
            fail(
                "eso",
                f"the image-builder ExternalSecret targets {sorted(targets)}, but the "
                f"Application creates namespace {build_ns!r} — the push secret would never "
                f"materialize where the build pod mounts it",
            )

    # ── 7) [ci-guard] the opt-in guard is gone ─────────────────────────────────
    ci_path = p(CI_FILE)
    ci_text = ""
    ci: dict = {}
    ci_job: dict = {}
    if not os.path.exists(ci_path):
        fail("ci-guard", f"missing {CI_FILE}")
    else:
        ci_text = open(ci_path, encoding="utf-8").read()
        if "IMAGE_BUILDER_ENABLED" in ci_text:
            fail(
                "ci-guard",
                "IMAGE_BUILDER_ENABLED still appears in .gitlab-ci.yml — the pipeline is "
                "always-on, so the opt-in guard must be gone (a stale guard silently no-ops "
                "every build)",
            )
        try:
            ci = yaml.safe_load(ci_text) or {}
        except Exception as exc:
            fail("ci-guard", f"{CI_FILE} is not parseable YAML: {exc}")
            ci = {}
        ci_job = ci.get(CI_JOB) or {}
        if not ci_job:
            fail("ci-guard", f"{CI_FILE} has no {CI_JOB} job")

    # ── 8) [ci-contract] CI and the Job template agree ────────────────────────
    # The template's ${...} set and the dispatcher's `sed -e` bindings are two
    # independently-maintained lists; a placeholder bound by neither ships a Job with a
    # literal ${...} in an image ref or a namespace.
    script_text = ""
    if ci_job:
        script = ci_job.get("script") or []
        script_text = "\n".join(script if isinstance(script, list) else [str(script)])
        job_vars = ci_job.get("variables") or {}
        if build_ns and job_vars.get("BUILD_NAMESPACE") != build_ns:
            fail(
                "ci-contract",
                f"{CI_JOB} BUILD_NAMESPACE is {job_vars.get('BUILD_NAMESPACE')!r} but the "
                f"synced Namespace is {build_ns!r} — the dispatcher would apply into a "
                f"namespace that does not exist",
            )
        ctx = str(job_vars.get("IMAGE_CONTEXT", ""))
        if "CI_COMMIT_SHA" in ctx:
            fail(
                "ci-contract",
                "IMAGE_CONTEXT pins the Kaniko git context to this repo's CI_COMMIT_SHA, "
                "which does not exist as a ref in the app repo being built — every "
                "dispatched build fails in Kaniko's clone",
            )

    tmpl_path = p(MANIFEST_DIR, JOB_TEMPLATE)
    if os.path.exists(tmpl_path) and script_text:
        tmpl_text = open(tmpl_path, encoding="utf-8").read()
        body = tmpl_text.split("\n")
        # Only the manifest body binds placeholders; the header comment documents them.
        manifest_body = "\n".join(l for l in body if not l.lstrip().startswith("#"))
        placeholders = set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)\}", manifest_body))
        # BOTH SIDES of each `s|\${PLACEHOLDER}|REPLACEMENT|g`. Scraping only the PATTERN
        # side makes this assertion one-sided: swapping the replacements for ${DEST_IMAGE}
        # and ${DEST_IMAGE_MOVING} inverts the immutable and the moving push destination —
        # the immutable tag is then never pushed and the moving tag is written twice — while
        # leaving the pattern set byte-identical. That mutation survived the first version of
        # this check; it is negative control 8d now.
        binds = re.findall(r"s\|\\\$\{([A-Z_][A-Z0-9_]*)\}\|([^|]*)\|g", script_text)
        bound = {name for name, _repl in binds}
        # ANTI-VACUITY: comparing two empty sets always "passes". If either side scrapes
        # to nothing the check has stopped measuring anything (a reformatted sed block, a
        # template that stopped being a template) — say so instead of going green.
        if not placeholders:
            fail("ci-contract", f"scraped ZERO ${{...}} placeholders from {JOB_TEMPLATE} — the check is vacuous")
        if not bound:
            fail("ci-contract", f"scraped ZERO sed bindings from {CI_JOB} — the check is vacuous")
        for missing in sorted(placeholders - bound):
            fail(
                "ci-contract",
                f"the Job template uses ${{{missing}}} but {CI_JOB} binds no sed "
                f"substitution for it — the applied Job would carry the literal placeholder",
            )
        for extra in sorted(bound - placeholders):
            fail(
                "ci-contract",
                f"{CI_JOB} binds ${{{extra}}} but the Job template no longer uses it "
                f"(dead binding — the two lists have drifted)",
            )
        # Each placeholder must be substituted with ITS OWN shell variable. The dispatcher
        # prefixes some of them (`${CONTEXT}` <- ${IMAGE_CONTEXT}, `${DOCKERFILE}` <-
        # ${IMAGE_DOCKERFILE}) to keep the CI variable namespace distinct, so the rule is
        # "the same name, optionally IMAGE_-prefixed" — not blind identity, and not a
        # hard-coded answer key either.
        for name, repl in sorted(binds):
            if repl not in ("${%s}" % name, "${IMAGE_%s}" % name):
                fail(
                    "ci-contract",
                    f"{CI_JOB} substitutes ${{{name}}} with {repl!r}, which is neither "
                    f"${{{name}}} nor ${{IMAGE_{name}}} — the placeholder is bound to the "
                    f"wrong value (e.g. swapping the immutable and moving push destinations)",
                )

    # ── 8b) [ci-pipeline] a failing dispatch must not take the pipeline with it ──
    # Retiring the opt-in guard turned build:images from a job that always `exit 0`-ed into
    # one that really dispatches — and therefore one that FAILS whenever its operator
    # preconditions (KUBECONFIG, a synced Application, the ESO push secret) are absent.
    # `stages:` runs sca and dast AFTER images, and a job with no `needs:` waits for every
    # job in every earlier stage, so a hard-failing build:images silently stops the OWASP
    # Dependency-Check SCA and the ZAP DAST stages from running on the default branch. That
    # collateral is invisible in the diff — nothing in the image-builder surface mentions
    # those jobs — which is exactly why it belongs in this gate rather than in a comment.
    if ci:
        jobs = ci_jobs(ci)
        stages = ci.get("stages")
        # ANTI-VACUITY: if the job walk or the stage list scrapes to nothing (a `default:`
        # refactor, an `include:`-ed stage list, a renamed template) this check silently
        # measures nothing. Say so rather than going green.
        if not isinstance(stages, list) or not stages:
            fail("ci-pipeline", f"{CI_FILE} declares no `stages:` list — the ordering check is vacuous")
        elif not jobs:
            fail("ci-pipeline", f"resolved ZERO jobs from {CI_FILE} — the ordering check is vacuous")
        elif CI_JOB not in jobs:
            pass  # already reported by [ci-guard]
        elif jobs[CI_JOB].get("stage") not in stages:
            fail(
                "ci-pipeline",
                f"{CI_JOB} declares stage {jobs[CI_JOB].get('stage')!r}, which is not in "
                f"`stages:` {stages}",
            )
        else:
            later = set(stages[stages.index(jobs[CI_JOB]["stage"]) + 1:])
            blocked = sorted(
                name
                for name, job in jobs.items()
                if job.get("stage") in later and CI_JOB in stage_order_blockers(job, CI_JOB)
            )
            if blocked and jobs[CI_JOB].get("allow_failure") is not True:
                fail(
                    "ci-pipeline",
                    f"{CI_JOB} can fail the pipeline (allow_failure is "
                    f"{jobs[CI_JOB].get('allow_failure')!r}) and these later-stage jobs would "
                    f"never run when it does: {blocked}. It dispatches into a cluster, so it "
                    f"fails whenever the operator preconditions are absent — set "
                    f"allow_failure: true on {CI_JOB}, or give each of those jobs a `needs:` "
                    f"that excludes it. Losing the sca/dast security stages to an image build "
                    f"is not an acceptable silent trade.",
                )

    # ── 9) [pre-rebrand] no retired brand identifier in this surface ──────────
    surface = [CI_FILE, f"{ALWAYS_SYNCED_DIR}/{APP_BASENAME}", ESO_FILE]
    if os.path.isdir(p(MANIFEST_DIR)):
        for fn in sorted(os.listdir(p(MANIFEST_DIR))):
            surface.append(f"{MANIFEST_DIR}/{fn}")
    # ANTI-VACUITY: scanning an empty file list always "passes".
    scanned = 0
    frozen_seen = 0
    for rel in surface:
        full = p(rel)
        if not os.path.isfile(full):
            continue
        scanned += 1
        for lineno, line in enumerate(open(full, encoding="utf-8"), 1):
            for rx in ALLOWLIST_RES:
                frozen_seen += len(rx.findall(line))
            for lo, _hi in unallowlisted_brand_spans(line):
                fail(
                    "pre-rebrand",
                    f"{rel}:{lineno}:{lo + 1} carries a retired pre-rebrand identifier in a "
                    f"NON-frozen position (the org renamed every repo to hugmesh-*; only the "
                    f"snapdragon.systems/ label KEY and the github.com/Snapdragon-Systems/ org "
                    f"segment survive): {line.strip()[:120]}",
                )
    if scanned < 4:
        fail("pre-rebrand", f"only {scanned} file(s) of the image-builder surface were scanned — the check is vacuous")
    # ANTI-VACUITY for the ALLOWLIST: if the frozen forms ever vanish from the surface, the
    # positional patterns stop being exercised by the positive run and could rot into
    # never-matching regexes without anyone noticing (at which point a real regression in
    # them would only ever be visible as a false FAIL, never as this silent false PASS).
    if frozen_seen < 2:
        fail(
            "pre-rebrand",
            f"only {frozen_seen} frozen-position brand occurrence(s) found in the surface — the "
            f"allowlist patterns are no longer exercised, so the positional check is unproven",
        )

    for f in findings:
        print(f)
    if findings:
        print(f"  -- {len(findings)} finding(s)")
        return 1
    print("  PASS image-builder always-on: app in apps/, manifests valid, CI un-guarded, no pre-rebrand identifiers")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
