#!/usr/bin/env python3
"""optional_service_slug_closure.py — pin the OPTIONAL-service slug set across ALL
FIVE surfaces that must agree about it.

THE SET IS DERIVED, NEVER LISTED. The governable set is

    G = { slug : slug has a 13a ApplicationSet element
                 AND an installed-services ConfigMap boolean }

because that is exactly what the admin-bff OptionalServiceReconciler can actuate: it
needs the element to create/prune the Application and the boolean to mirror the
greying. Nothing in this file hard-codes G, so adding a slug to those two places
automatically widens what every other surface must carry. A hard-coded expected list
would have to be edited in lockstep with the thing it checks, which is the defect.

THE FIVE SURFACES
  1. specs/cluster/apps/13a-optional-services.yaml        (ApplicationSet elements)
  2. specs/cluster/manifests/policy/installed-services-configmap.yaml (booleans)
  3. .../optional-services-operator/crd-optionalservice.yaml          (spec.slug enum)
  4. .../optional-services-operator/seed-optionalservices.yaml        (seed CRs)
  5. hugmesh-admin-bff-api OptionalServiceRegistry.java               (Java registry)

WHY SURFACE 5 IS PART OF THE GATE AND NOT A CONVENIENCE. The three defects this guard
exists for are all cross-surface, and the worst one is only visible from surface 5:

  * character-forge is in the CRD enum, the ConfigMap, 13a and the seed CRs but NOT in
    the Java registry. That does not fail — it succeeds silently. The API server
    ACCEPTS the write (the enum allows it), `kubectl get optionalservices` shows
    enabled:true, and the reconciler logs "unknown slug — ignoring", writes NEITHER
    target, and `continue`s past the CR's status update so not even .status.phase
    records that nothing happened. A slug present in the enum but absent from the
    registry is strictly worse than one missing from both.
  * meshbridge had a 13a element + ConfigMap key and was in neither the enum nor the
    seed CRs, so the API server rejected it outright (loud, at least).
  * apps/16's ignoreDifferences carried 12 pointers against 14 elements, so a
    successful runtime toggle of the two unlisted slugs would be selfHealed back to
    git's baseline inside a sync interval.

Without the checkout there is nothing to compare on surface 5, so an absent checkout
is INCOMPLETE (rc 3) and the calling suite FAILS. It never degrades to "checked four
of five" — that is how (a) survived a review that looked at the four in-repo surfaces
and found them consistent.

EVERY DERIVED LIST IS CHECKED FOR EMPTINESS BEFORE IT IS ASSERTED OVER. A parse that
silently yields [] would make every set comparison below trivially true; each
extractor raises Incomplete instead.

Exit: 0 pass, 1 violations found, 2 usage/internal, 3 INCOMPLETE (nothing compared).
Offline: reads files only. No cluster, no kubectl, no network.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("FAIL PyYAML not available (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

# The one service repo this gate reads. Consumed by --list-repos so the CI clone loop
# and the checker cannot disagree about which checkout is required.
SERVICE_REPO = "hugmesh-admin-bff-api"
REGISTRY_REL = "src/main/java/net/hugmesh/adminbff/optionalservices/OptionalServiceRegistry.java"

# The reconciler master switch. It must be DECLARED in the Deployment: until 2026-08-26
# it existed only as the ":false" default inside the BFF's own application.yml, settable
# from no manifest, no builder and no flag — a feature with no reachable lever.
FLAG_ENV = "APP_OPTIONAL_SERVICES_RECONCILE_ENABLED"

# Slugs that legitimately have an installed-services boolean but NO 13a element,
# because their Application is HARDCODED rather than ApplicationSet-generated. They are
# outside G by construction. This list is pinned so that adding a ConfigMap boolean
# without a 13a element FAILS here instead of quietly creating a sixth cardinality.
BUILD_DETERMINED = {
    "workloadConsole": "apps/14-workload-console-rbac.yaml",
    "headwind": "apps/23-headwind.yaml",
    "attestation-server": "apps/24-attestation-server.yaml",
}


class Incomplete(Exception):
    """Nothing could be compared. Never a pass."""


FAILURES: list[str] = []
CHECKS = [0]


def fail(msg: str) -> None:
    FAILURES.append(msg)


def check(msg: str, ok: bool) -> None:
    CHECKS[0] += 1
    if not ok:
        fail(msg)


def _load(path: Path):
    if not path.is_file():
        raise Incomplete(f"missing surface: {path}")
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        raise Incomplete(f"{path} is not parseable YAML: {e}") from e


# ───────────────────────────── the five extractors ──────────────────────────────
# Each returns a NON-EMPTY structure or raises Incomplete. An extractor that returns
# [] turns every downstream set comparison into a vacuous pass.


def read_appset_elements(cluster: Path) -> list[dict]:
    """Surface 1: the 13a ApplicationSet list-generator elements, in file order."""
    p = cluster / "apps" / "13a-optional-services.yaml"
    doc = _load(p)
    try:
        els = doc["spec"]["generators"][0]["list"]["elements"]
    except (KeyError, IndexError, TypeError) as e:
        raise Incomplete(f"{p}: no spec.generators[0].list.elements ({e})") from e
    if not isinstance(els, list) or not els:
        raise Incomplete(f"{p}: the ApplicationSet element list is empty")
    out = []
    for el in els:
        if not isinstance(el, dict) or "slug" not in el:
            raise Incomplete(f"{p}: element without a slug: {el!r}")
        out.append(el)
    return out


def read_configmap(cluster: Path) -> tuple[list[str], dict]:
    """Surface 2: the installed-services per-slug booleans + the services.json rows."""
    p = cluster / "manifests" / "policy" / "installed-services-configmap.yaml"
    doc = _load(p)
    data = (doc or {}).get("data")
    if not isinstance(data, dict) or not data:
        raise Incomplete(f"{p}: no data block")
    # Booleans only. services.json is a block scalar, not an install flag.
    bools = [k for k, v in data.items() if isinstance(v, str) and v in ("true", "false")]
    if not bools:
        raise Incomplete(f"{p}: no per-slug boolean keys — nothing to compare")
    rows = {}
    raw = data.get("services.json")
    if raw:
        try:
            parsed = yaml.safe_load(raw)  # JSON is a YAML subset
        except yaml.YAMLError as e:
            raise Incomplete(f"{p}: services.json is not parseable: {e}") from e
        if isinstance(parsed, list):
            rows = {r["slug"]: r for r in parsed if isinstance(r, dict) and "slug" in r}
    if not rows:
        raise Incomplete(f"{p}: services.json parsed to no rows")
    return bools, rows


def read_crd_enum(cluster: Path) -> list[str]:
    """Surface 3: the OptionalService CRD spec.slug enum."""
    p = cluster / "manifests" / "optional-services-operator" / "crd-optionalservice.yaml"
    doc = _load(p)
    try:
        vers = doc["spec"]["versions"][0]
        enum = vers["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["slug"]["enum"]
    except (KeyError, IndexError, TypeError) as e:
        raise Incomplete(f"{p}: no spec.slug enum ({e})") from e
    if not isinstance(enum, list) or not enum:
        raise Incomplete(f"{p}: the spec.slug enum is empty")
    return list(enum)


def read_seed_crs(cluster: Path) -> list[tuple[str, str]]:
    """Surface 4: the seed OptionalService CRs, as (metadata.name, spec.slug)."""
    p = cluster / "manifests" / "optional-services-operator" / "seed-optionalservices.yaml"
    if not p.is_file():
        raise Incomplete(f"missing surface: {p}")
    try:
        docs = [d for d in yaml.safe_load_all(p.read_text(encoding="utf-8")) if d]
    except yaml.YAMLError as e:
        raise Incomplete(f"{p} is not parseable YAML: {e}") from e
    out = []
    for d in docs:
        if d.get("kind") != "OptionalService":
            continue
        slug = (d.get("spec") or {}).get("slug")
        name = (d.get("metadata") or {}).get("name")
        if not slug:
            raise Incomplete(f"{p}: an OptionalService with no spec.slug")
        out.append((name, slug))
    if not out:
        raise Incomplete(f"{p}: no OptionalService documents — nothing to compare")
    return out


def read_ignore_pointers(cluster: Path) -> list[str]:
    """apps/16's ignoreDifferences jsonPointers for the installed-services ConfigMap."""
    p = cluster / "apps" / "16-reserved-prefixes-policy.yaml"
    doc = _load(p)
    entries = ((doc or {}).get("spec") or {}).get("ignoreDifferences")
    if not isinstance(entries, list) or not entries:
        raise Incomplete(f"{p}: no spec.ignoreDifferences — nothing to compare")
    for e in entries:
        if e.get("kind") == "ConfigMap" and e.get("name") == "installed-services":
            ptrs = e.get("jsonPointers")
            if not isinstance(ptrs, list) or not ptrs:
                raise Incomplete(f"{p}: the installed-services entry has no jsonPointers")
            return list(ptrs)
    raise Incomplete(f"{p}: no ignoreDifferences entry for the installed-services ConfigMap")


# The Java registry. Parsed from the ENTRIES table, not from prose: a slug named only
# in a javadoc paragraph must not count as registered (comment-token inversion is a
# catalogued failure mode in this org, and this file's javadoc names slugs it does
# NOT carry — workloadConsole, egress-vpn, tor — precisely as exclusions).
_ENTRY_RE = re.compile(
    r"""new\s+Entry\s*\(\s*
        "(?P<slug>[^"]+)"\s*,\s*
        "(?P<ns>[^"]+)"\s*,\s*
        (?:"(?P<mount>[^"]*)"|(?P<null>null))\s*\)""",
    re.X,
)


def read_java_registry(src_root: Path) -> dict[str, tuple[str, str | None]]:
    """Surface 5. Raises Incomplete when the checkout is absent — never returns {}."""
    p = src_root / SERVICE_REPO / REGISTRY_REL
    if not p.is_file():
        raise Incomplete(f"{SERVICE_REPO}: no {REGISTRY_REL} at {p}")
    text = p.read_text(encoding="utf-8", errors="replace")
    # Strip comments so prose naming a slug cannot register it.
    stripped = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    stripped = re.sub(r"//[^\n]*", " ", stripped)
    out: dict[str, tuple[str, str | None]] = {}
    for m in _ENTRY_RE.finditer(stripped):
        out[m.group("slug")] = (m.group("ns"), None if m.group("null") else m.group("mount"))
    if not out:
        raise Incomplete(
            f"{p}: parsed ZERO registry entries. Either the ENTRIES table moved or its "
            "shape changed — a green run on an empty registry would compare nothing."
        )
    return out


def read_reconciler_flag(cluster: Path) -> tuple[int, list[str]]:
    """The reconciler's master switch as DECLARED in the admin-bff Deployment, plus any
    index-addressed env jsonPointer in apps/31.

    Returns (declaration_count, offending_pointers). Raises Incomplete if the Deployment
    or its container env cannot be read at all — an unreadable manifest must not read as
    "the flag is fine".
    """
    dp = cluster / "manifests" / "admin-bff-api" / "deployment.yaml"
    doc = _load(dp)
    try:
        containers = doc["spec"]["template"]["spec"]["containers"]
    except (KeyError, TypeError) as e:
        raise Incomplete(f"{dp}: no containers ({e})") from e
    envs = []
    for c in containers:
        for e in (c.get("env") or []):
            if isinstance(e, dict):
                envs.append(e)
    if not envs:
        raise Incomplete(f"{dp}: no container env entries — nothing to check the flag against")
    decls = [e for e in envs if e.get("name") == FLAG_ENV and "value" in e]
    ap = cluster / "apps" / "31-admin-bff-api.yaml"
    offending: list[str] = []
    if ap.is_file():
        adoc = _load(ap)
        for entry in ((adoc or {}).get("spec") or {}).get("ignoreDifferences") or []:
            for ptr in entry.get("jsonPointers") or []:
                if re.search(r"/containers/\d+/env/\d+", str(ptr)) or str(ptr).rstrip("/").endswith("/env"):
                    offending.append(str(ptr))
    return len(decls), offending


def resolve_src_root(repo_root: Path, explicit: str | None) -> Path:
    """A tree carrying the service checkout this gate reads.

    An EXPLICIT --src-root is authoritative and never falls back. This was a real bug
    caught by the suite's absent-checkout control: with fallbacks still in play, a
    control that deleted the staged checkout to prove "absent is INCOMPLETE" silently
    resolved to the REAL sibling tree instead and reported rc 1 for the live defect. A
    checker that can wander out of the corpus it was pointed at makes every negative
    control conditional on the machine it runs on.
    """
    if explicit:
        cand = Path(explicit)
        if (cand / SERVICE_REPO / REGISTRY_REL).is_file():
            return cand
        raise Incomplete(
            f"--src-root {cand} does not carry {SERVICE_REPO}/{REGISTRY_REL} "
            "(explicit roots are authoritative and are never fallen back from)"
        )
    candidates: list[Path] = []
    raw = os.environ.get("SERVICE_SRC_ROOT")
    if raw:
        candidates.append(Path(raw))
    candidates += [repo_root / ".service-src", repo_root / ".stack-src", repo_root.parent]
    tried: list[str] = []
    for cand in candidates:
        if not cand.is_dir():
            tried.append(f"{cand} (absent)")
            continue
        if (cand / SERVICE_REPO / REGISTRY_REL).is_file():
            return cand
        tried.append(f"{cand} (no {SERVICE_REPO}/{REGISTRY_REL})")
    raise Incomplete(
        f"no tree carries {SERVICE_REPO}/{REGISTRY_REL}. Tried: " + "; ".join(tried)
    )


# ────────────────────────────────── the gate ────────────────────────────────────


def run(cluster: Path, src_root: Path) -> None:
    elements = read_appset_elements(cluster)
    cm_bools, services_json = read_configmap(cluster)
    enum = read_crd_enum(cluster)
    seeds = read_seed_crs(cluster)
    pointers = read_ignore_pointers(cluster)
    registry = read_java_registry(src_root)

    el_slugs = [e["slug"] for e in elements]
    el_by_slug = {e["slug"]: e for e in elements}

    # ── DERIVE G ────────────────────────────────────────────────────────────────
    G = [s for s in el_slugs if s in cm_bools]
    gset = set(G)
    if not G:
        raise Incomplete(
            "the derived governable set is EMPTY (no slug has both a 13a element and a "
            "ConfigMap boolean). Every comparison below would pass vacuously."
        )

    print(f"  derived governable set G ({len(G)}): {' '.join(G)}")
    print(f"  surfaces: 13a={len(el_slugs)} configmap-bools={len(cm_bools)} "
          f"crd-enum={len(enum)} seed-crs={len(seeds)} apps16-pointers={len(pointers)} "
          f"java-registry={len(registry)}")

    # ── 0. duplicates anywhere would make the set comparisons lie ───────────────
    for label, items in (("13a elements", el_slugs), ("CRD enum", enum),
                         ("seed CRs", [s for _, s in seeds]),
                         ("apps/16 pointers", pointers)):
        dupes = sorted({x for x in items if items.count(x) > 1})
        check(f"[dupes] {label} contains duplicate entries: {dupes}", not dupes)

    # ── 1. every 13a element must have a ConfigMap boolean ─────────────────────
    orphan_elements = [s for s in el_slugs if s not in cm_bools]
    check(
        "[13a->configmap] 13a element(s) with NO installed-services boolean: "
        f"{orphan_elements}. The ApplicationSet could create the Application while the "
        "greying mirror has no key to flip, so the console would never grey it.",
        not orphan_elements,
    )

    # ── 2. a ConfigMap boolean with no 13a element must be a KNOWN exclusion ────
    cm_only = [s for s in cm_bools if s not in el_slugs]
    unexpected = [s for s in cm_only if s not in BUILD_DETERMINED]
    check(
        "[configmap->13a] installed-services boolean(s) with no 13a element and no "
        f"recorded reason: {unexpected}. Either give the slug a 13a element (making it "
        "governable) or record it in BUILD_DETERMINED with the hardcoded Application "
        "that owns it. Silently adding a boolean creates another cardinality.",
        not unexpected,
    )
    stale = [s for s in BUILD_DETERMINED if s not in cm_bools]
    check(
        f"[configmap->13a] BUILD_DETERMINED names slug(s) with no ConfigMap boolean: "
        f"{stale}. The exclusion list has gone stale and is now excusing nothing.",
        not stale,
    )
    promoted = [s for s in BUILD_DETERMINED if s in el_slugs]
    check(
        f"[configmap->13a] BUILD_DETERMINED slug(s) that HAVE gained a 13a element: "
        f"{promoted}. They are governable now — drop them from BUILD_DETERMINED so the "
        "enum/seed/pointer/registry legs start demanding them.",
        not promoted,
    )

    # ── 3. CRD enum == G ───────────────────────────────────────────────────────
    check(
        f"[crd-enum] spec.slug enum does not equal G. missing={sorted(gset - set(enum))} "
        f"extra={sorted(set(enum) - gset)}. A slug in G but not the enum is REJECTED by "
        "the API server; a slug in the enum but not G is accepted and un-actuatable.",
        set(enum) == gset,
    )

    # ── 4. seed CRs == G, and metadata.name == spec.slug ───────────────────────
    seed_slugs = [s for _, s in seeds]
    check(
        f"[seed-crs] seed OptionalService set does not equal G. "
        f"missing={sorted(gset - set(seed_slugs))} extra={sorted(set(seed_slugs) - gset)}. "
        "A slug with no seed CR has no row in `kubectl get optionalservices`, so the "
        "in-place edit the seeds exist to enable is impossible for it.",
        set(seed_slugs) == gset,
    )
    misnamed = [(n, s) for n, s in seeds if n != s]
    check(
        f"[seed-crs] CR metadata.name != spec.slug: {misnamed}. The reconciler reports "
        "status by CR name; a mismatch makes the audit trail name the wrong service.",
        not misnamed,
    )

    # ── 5. apps/16 ignoreDifferences pointers == {/data/<g>} ───────────────────
    want_ptrs = {f"/data/{s}" for s in G}
    got_ptrs = set(pointers)
    check(
        f"[apps16-ignorediff] ignoreDifferences pointers do not equal /data/<G>. "
        f"missing={sorted(want_ptrs - got_ptrs)} extra={sorted(got_ptrs - want_ptrs)}. "
        "A MISSING pointer means selfHeal reverts that slug's runtime toggle back to "
        "git within a sync interval while the CR still claims enabled:true. An EXTRA "
        "pointer un-enforces a key no controller owns.",
        got_ptrs == want_ptrs,
    )

    # ── 6. Java registry == G ──────────────────────────────────────────────────
    reg_slugs = set(registry)
    inert = sorted(gset - reg_slugs)
    check(
        f"[java-registry] {SERVICE_REPO} OptionalServiceRegistry does not equal G. "
        f"missing={inert} extra={sorted(reg_slugs - gset)}. A slug in the CRD enum but "
        "missing here is a SILENTLY INERT toggle: the API accepts the write, the "
        "reconciler logs 'unknown slug — ignoring', writes neither target, and skips "
        "the CR's /status so nothing records that the toggle did nothing.",
        reg_slugs == gset,
    )

    # ── 7. namespace / mountAt agreement across the surfaces that carry them ───
    for slug in G:
        el_ns = el_by_slug[slug].get("namespace")
        row = services_json.get(slug)
        if row is None:
            check(f"[services.json] {slug} is in G but has no services.json row — the "
                  "console has no displayName/mountAt for it.", False)
            continue
        check(
            f"[namespace] {slug}: 13a namespace {el_ns!r} != services.json namespace "
            f"{row.get('namespace')!r}. The ApplicationSet would deploy it somewhere the "
            "console does not look.",
            el_ns == row.get("namespace"),
        )
        if slug in registry:
            r_ns, r_mount = registry[slug]
            check(
                f"[namespace] {slug}: services.json namespace {row.get('namespace')!r} != "
                f"Java registry namespace {r_ns!r}.",
                row.get("namespace") == r_ns,
            )
            check(
                f"[mountAt] {slug}: services.json mountAt {row.get('mountAt')!r} != Java "
                f"registry mountAt {r_mount!r}. The registry backs status/audit and "
                "applicationName; a drifted mount misreports where a service lives.",
                row.get("mountAt") == r_mount,
            )

    # ── 8. the reconciler master switch must have a reachable, GitOps-only lever ──
    decls, offending = read_reconciler_flag(cluster)
    check(
        f"[reconciler-flag] {FLAG_ENV} is declared {decls} time(s) with a literal value in "
        "manifests/admin-bff-api/deployment.yaml; expected exactly 1. Zero means the "
        "reconciler is dark with no supported way to turn it on (its only other mention is "
        "the ':false' default inside the BFF's own application.yml, which no operator can "
        "reach); more than one means a strategic-merge patch will keep an arbitrary one.",
        decls == 1,
    )
    check(
        f"[reconciler-flag] apps/31-admin-bff-api.yaml exempts container env from selfHeal "
        f"via {offending}. ArgoCD addresses env by ARRAY INDEX, so such a pointer starts "
        "covering a DIFFERENT variable the moment anything is inserted above it — and this "
        "container's env carries secretKeyRefs. The flag is GitOps-only by decision: flip "
        "the value in the Deployment, do not exempt it from enforcement.",
        not offending,
    )

    print(f"  ran {CHECKS[0]} assertion(s) over {len(G)} governable slug(s)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("cluster", nargs="?", help="path to specs/cluster")
    ap.add_argument("--src-root", help="tree containing the service checkout(s)")
    ap.add_argument("--list-repos", action="store_true",
                    help="print the service repos this gate needs, one per line")
    args = ap.parse_args()

    if args.list_repos:
        print(SERVICE_REPO)
        return 0

    if not args.cluster:
        ap.error("cluster path is required")
    cluster = Path(args.cluster).resolve()
    repo_root = cluster.parent.parent
    if not cluster.is_dir():
        print(f"INCOMPLETE: no cluster tree at {cluster}")
        return 3

    try:
        src_root = resolve_src_root(repo_root, args.src_root)
        print(f"  sources: {src_root}")
        run(cluster, src_root)
    except Incomplete as e:
        print(f"INCOMPLETE: {e}")
        print("       Nothing was compared, so this is a FAILURE (rc 3), not a skip.")
        return 3

    if FAILURES:
        for f in FAILURES:
            print(f"  FAIL {f}")
        print(f"== slug closure: {CHECKS[0] - len(FAILURES)} passed, {len(FAILURES)} failed ==")
        return 1
    print(f"== slug closure: all {CHECKS[0]} assertion(s) passed ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
